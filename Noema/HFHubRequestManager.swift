import Foundation

actor HFHubRequestManager {
	static let shared = HFHubRequestManager(maxConcurrent: 2)
	
	private let maxConcurrent: Int
	private var availablePermits: Int
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private var inflight: [String: Task<(Data, URLResponse), Error>] = [:]
	
	init(maxConcurrent: Int = 2) {
		self.maxConcurrent = maxConcurrent
		self.availablePermits = maxConcurrent
	}
	
	private func acquire() async {
		if availablePermits > 0 {
			availablePermits -= 1
			return
		}
		await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
			waiters.append(cont)
		}
	}
	
	private func release() {
		if !waiters.isEmpty {
			let cont = waiters.removeFirst()
			cont.resume()
		} else {
			availablePermits = min(availablePermits + 1, maxConcurrent)
		}
	}
	
	func data(for url: URL,
	          token: String? = nil,
	          accept: String? = nil,
	          method: String = "GET",
	          timeout: TimeInterval? = nil,
	          key: String? = nil,
	          headers: [String: String] = [:]) async throws -> (Data, URLResponse) {
		// Enforce off-grid: fail fast with no network
		if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
		let url = HFEndpoint.rewrite(url)
		let cacheKey = key ?? "\(url.absoluteString)|\(accept ?? "")|\(method)|\(token ?? "")"
		if let existing = inflight[cacheKey] {
			return try await existing.value
		}
		let task = Task<(Data, URLResponse), Error> { [accept, method, timeout, token, headers] in
			let maxAttempts = 5
			var attempt = 0
			var lastError: Error?
			while attempt < maxAttempts {
				attempt += 1
				await acquire()
				var req = URLRequest(url: url)
				req.httpMethod = method
				if let timeout { req.timeoutInterval = timeout }
				if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
				for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
				if let token, !token.isEmpty, HFEndpoint.shouldSendAuthorization(to: url) {
					req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
				}
				do {
					// Track shared session to allow cancellation
					NetworkKillSwitch.track(session: URLSession.shared)
					let (data, resp) = try await URLSession.shared.data(for: req)
					defer { release() }
					if let http = resp as? HTTPURLResponse {
						let code = http.statusCode
						if code == 429 || (500...599).contains(code) {
							var delay: Double = 0
							if let ra = http.value(forHTTPHeaderField: "Retry-After"), let secs = Double(ra) {
								delay = min(max(secs, 0.5), 10.0)
							} else {
								let base = pow(2.0, Double(attempt - 1))
								delay = min(base, 8.0) + Double.random(in: 0...0.25)
							}
							if attempt >= maxAttempts {
								return (data, resp)
							}
							try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
							continue
						}
					}
					return (data, resp)
				} catch {
					defer { release() }
					lastError = error
					if let ue = error as? URLError {
						let transient: Set<URLError.Code> = [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .resourceUnavailable, .notConnectedToInternet]
						if transient.contains(ue.code), attempt < maxAttempts {
							let base = pow(2.0, Double(attempt - 1))
							let delay = min(base, 8.0) + Double.random(in: 0...0.25)
							try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
							continue
						}
					}
					throw error
				}
			}
			throw lastError ?? URLError(.cannotLoadFromNetwork)
		}
		inflight[cacheKey] = task
		defer { inflight[cacheKey] = nil }
		return try await task.value
	}

	/// Cancel all inflight tasks and drop waiters. Used when enabling off-grid.
	func cancelAll() {
		for (_, t) in inflight { t.cancel() }
		inflight.removeAll()
		// Wake all waiters so callers can fail fast
		while !waiters.isEmpty { waiters.removeFirst().resume() }
		availablePermits = maxConcurrent
	}
}