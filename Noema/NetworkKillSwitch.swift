// NetworkKillSwitch.swift
import Foundation

final class LockIsolated<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withValue<R>(_ body: (Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(value)
    }

    @discardableResult
    func withMutableValue<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// URLProtocol that denies all HTTP/HTTPS requests when the kill switch is enabled.
final class NetworkBlockedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        NetworkKillSwitch.shouldBlock(request: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Fail immediately without performing any network I/O
        let error = URLError(.notConnectedToInternet)
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

struct NetworkBlockedAttempt: Identifiable, Hashable {
    let id: UUID
    let urlString: String
    let host: String
    let blockedAt: Date

    init(url: URL, blockedAt: Date = Date()) {
        self.id = UUID()
        self.urlString = url.absoluteString
        self.host = url.host ?? url.absoluteString
        self.blockedAt = blockedAt
    }
}

enum NetworkKillSwitch {
    private static let enabledState = LockIsolated(false)
    private static let allowedLoopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
    private static let blockedAttempts = LockIsolated<[NetworkBlockedAttempt]>([])
    private static let maxBlockedAttempts = 25
    /// HTTPS hosts exempt from the kill switch while an enterprise off-grid policy is
    /// active — only the workspace policy server, so policy sync and revocation can still
    /// reach a device that policy forced off-grid. Set by EnterprisePolicyManager.
    private static let enterpriseAllowedHosts = LockIsolated<Set<String>>([])

    /// Weakly-held set of URLSession instances to cancel when the switch is enabled
    private static let trackedSessions = LockIsolated(NSHashTable<AnyObject>.weakObjects())

    static var isEnabled: Bool {
        enabledState.withValue { $0 }
    }

    static func isLoopback(url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url?.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }

        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let withoutZone = host.split(separator: "%", maxSplits: 1).first {
            host = String(withoutZone)
        }
        if allowedLoopbackHosts.contains(host) {
            return true
        }
        if host.hasPrefix("::ffff:") {
            let mapped = String(host.dropFirst("::ffff:".count))
            return mapped == "127.0.0.1"
        }
        return false
    }

    /// True when `url` targets an HTTPS host on the enterprise policy-server allowlist.
    static func isEnterpriseAllowed(url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased(), scheme == "https",
              let host = url?.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return enterpriseAllowedHosts.withValue { $0.contains(host) }
    }

    /// Replace the enterprise allowlist (empty set clears it). HTTPS only.
    static func setEnterpriseAllowedHosts(_ hosts: Set<String>) {
        enterpriseAllowedHosts.withMutableValue { $0 = Set(hosts.map { $0.lowercased() }) }
    }

    static func shouldBlock(url: URL?) -> Bool {
        guard isEnabled else { return false }
        guard let scheme = url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let blocked = !isLoopback(url: url) && !isEnterpriseAllowed(url: url)
        if blocked, let url {
            recordBlockedAttempt(url)
        }
        return blocked
    }

    static func shouldBlock(request: URLRequest) -> Bool {
        shouldBlock(url: request.url)
    }

    /// Register a session to be cancelled if off-grid is turned on while it's active.
    static func track(session: URLSession) {
        trackedSessions.withMutableValue { $0.add(session) }
    }

    static var recentBlockedAttempts: [NetworkBlockedAttempt] {
        blockedAttempts.withValue { $0 }
    }

    static func clearBlockedAttempts() {
        blockedAttempts.withMutableValue { $0.removeAll() }
    }

    static func wouldBlock(url: URL?, assumingEnabled: Bool = true) -> Bool {
        guard assumingEnabled else { return false }
        guard let scheme = url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return !isLoopback(url: url) && !isEnterpriseAllowed(url: url)
    }

    /// Enable or disable the global kill switch.
    static func setEnabled(_ enabled: Bool) {
        let wasEnabled = enabledState.withValue { $0 }
        guard enabled != wasEnabled else { return }
        enabledState.withMutableValue { $0 = enabled }

        if enabled {
            URLProtocol.registerClass(NetworkBlockedURLProtocol.self)

            // Cancel tasks on shared session
            URLSession.shared.getAllTasks { tasks in
                tasks
                    .filter { shouldBlock(url: $0.currentRequest?.url ?? $0.originalRequest?.url) }
                    .forEach { $0.cancel() }
            }

            // Cancel tasks on tracked sessions
            let sessions = trackedSessions.withValue { $0.allObjects.compactMap { $0 as? URLSession } }
            for session in sessions {
                session.getAllTasks { tasks in
                    let blockedTasks = tasks.filter {
                        shouldBlock(url: $0.currentRequest?.url ?? $0.originalRequest?.url)
                    }
                    blockedTasks.forEach { $0.cancel() }
                    if !blockedTasks.isEmpty, blockedTasks.count == tasks.count {
                        session.invalidateAndCancel()
                    }
                }
            }

            // Cancel inflight hub requests
            Task { await HFHubRequestManager.shared.cancelAll() }

            // Cancel Leap polling tasks (LeapModelDownloader handles its own lifecycle)
            Task { LeapBundleDownloader.shared.cancelAll() }
        } else {
            URLProtocol.unregisterClass(NetworkBlockedURLProtocol.self)
        }
    }

    private static func recordBlockedAttempt(_ url: URL) {
        blockedAttempts.withMutableValue { attempts in
            attempts.insert(NetworkBlockedAttempt(url: url), at: 0)
            if attempts.count > maxBlockedAttempts {
                attempts.removeLast(attempts.count - maxBlockedAttempts)
            }
        }
    }
}
