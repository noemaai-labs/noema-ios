#if os(macOS)
import Foundation
import Logging
import MCP

private struct MCPLegacySSEError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Wire-compatible client transport for the pre-Streamable-HTTP MCP HTTP+SSE
/// protocol. A GET event stream announces the exact POST endpoint; JSON-RPC is
/// then posted there without URL guessing or shell-like interpretation.
actor MCPLegacySSETransport: MCP.Transport {
    nonisolated let logger: Logging.Logger
    private let streamURL: URL
    private let headers: [String: String]
    private let session: URLSession
    private let inbound: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var postURL: URL?
    private var listener: Task<Void, Never>?

    init(url: URL, headers: [String: String]) {
        streamURL = url
        self.headers = headers
        logger = .init(label: "ai.noema.mcp.legacy-sse")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration)
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        inbound = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func connect() async throws {
        guard listener == nil else { return }
        listener = Task { [weak self] in await self?.listen() }
    }

    func disconnect() async {
        listener?.cancel()
        listener = nil
        postURL = nil
        session.invalidateAndCancel()
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        let endpoint = try await waitForEndpoint()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPError.transportError(MCPLegacySSEError(message: "Legacy SSE POST was not accepted"))
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> { inbound }

    private func waitForEndpoint() async throws -> URL {
        for _ in 0..<300 {
            if let postURL { return postURL }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MCPError.transportError(MCPLegacySSEError(message: "Legacy SSE server did not announce a message endpoint"))
    }

    private func listen() async {
        do {
            var request = URLRequest(url: streamURL)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                throw MCPError.transportError(MCPLegacySSEError(message: "Legacy MCP endpoint did not return an SSE stream"))
            }
            var event = "message"
            var dataLines: [String] = []
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.isEmpty {
                    dispatch(event: event, data: dataLines.joined(separator: "\n"))
                    event = "message"; dataLines.removeAll(keepingCapacity: true)
                } else if line.hasPrefix("event:") {
                    event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func dispatch(event: String, data: String) {
        guard !data.isEmpty else { return }
        if event == "endpoint" {
            postURL = URL(string: data, relativeTo: streamURL)?.absoluteURL
        } else if event == "message", let payload = data.data(using: .utf8) {
            continuation.yield(payload)
        }
    }
}
#endif
