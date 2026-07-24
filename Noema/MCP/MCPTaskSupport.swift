#if os(macOS)
import Foundation
import Logging
import MCP

struct MCPNegotiatedTaskSupport: Sendable {
    var available = false
    var toolsCall = false
    var list = false
    var cancel = false
}

/// Injects and observes the experimental 2025-11-25 task capability without
/// leaking that protocol-specific workaround into the rest of Noema. SDK 0.12.1
/// intentionally drops unknown server capability keys while decoding.
actor MCPTaskNegotiatingTransport<Base: MCP.Transport>: MCP.Transport {
    nonisolated let logger: Logging.Logger
    private let base: Base
    private let enabled: Bool
    private var support = MCPNegotiatedTaskSupport()

    init(base: Base, enabled: Bool, logger: Logging.Logger) {
        self.base = base; self.enabled = enabled; self.logger = logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }

    func send(_ data: Foundation.Data) async throws {
        guard enabled,
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "initialize",
              var params = object["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any] else {
            try await base.send(data); return
        }
        capabilities["tasks"] = [
            "requests": [
                "sampling": ["createMessage": [:]],
                "elicitation": ["create": [:]]
            ]
        ]
        params["capabilities"] = capabilities; object["params"] = params
        try await base.send(try JSONSerialization.data(withJSONObject: object))
    }

    func receive() -> AsyncThrowingStream<Foundation.Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = await base.receive()
                    for try await data in stream {
                        if enabled { await inspect(data) }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func negotiatedSupport() -> MCPNegotiatedTaskSupport { support }

    private func inspect(_ data: Foundation.Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let capabilities = result["capabilities"] as? [String: Any],
              let tasks = capabilities["tasks"] as? [String: Any] else { return }
        support.available = true
        support.list = tasks["list"] != nil
        support.cancel = tasks["cancel"] != nil
        let requests = tasks["requests"] as? [String: Any]
        let tools = requests?["tools"] as? [String: Any]
        support.toolsCall = tools?["call"] != nil
    }
}

struct MCPWireTask: Codable, Hashable, Sendable {
    var taskId: String
    var status: String
    var statusMessage: String?
    var createdAt: String
    var lastUpdatedAt: String
    var ttl: Int?
    var pollInterval: Int?

    func reference(serverID: String) -> MCPTaskReference {
        let formatter = ISO8601DateFormatter()
        let created = formatter.date(from: createdAt) ?? Date()
        let updated = formatter.date(from: lastUpdatedAt) ?? created
        let state = MCPTaskReference.State(rawValue: status) ?? .failed
        return .init(
            id: taskId, serverID: serverID, state: state, statusMessage: statusMessage,
            createdAt: created, updatedAt: updated,
            expiresAt: ttl.map { created.addingTimeInterval(Double($0) / 1_000) },
            pollIntervalMilliseconds: pollInterval
        )
    }
}

struct MCPTaskParameters: Codable, Hashable, Sendable { var ttl: Int? }

enum MCPTaskCallTool: MCP.Method {
    static let name = "tools/call"
    struct Parameters: Codable, Hashable, Sendable {
        var name: String
        var arguments: [String: MCP.Value]?
        var _meta: MCP.Metadata?
        var task: MCPTaskParameters
    }
    enum Result: Codable, Hashable, Sendable {
        case task(MCPWireTask)
        case result(MCP.CallTool.Result)
        private enum CodingKeys: String, CodingKey { case task }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let task = try container.decodeIfPresent(MCPWireTask.self, forKey: .task) { self = .task(task) }
            else { self = .result(try MCP.CallTool.Result(from: decoder)) }
        }
        func encode(to encoder: Encoder) throws {
            switch self {
            case .task(let task): var container = encoder.container(keyedBy: CodingKeys.self); try container.encode(task, forKey: .task)
            case .result(let result): try result.encode(to: encoder)
            }
        }
    }
}

enum MCPGetTask: MCP.Method {
    static let name = "tasks/get"
    struct Parameters: Codable, Hashable, Sendable { var taskId: String }
    typealias Result = MCPWireTask
}

enum MCPGetTaskResult: MCP.Method {
    static let name = "tasks/result"
    struct Parameters: Codable, Hashable, Sendable { var taskId: String }
    typealias Result = MCP.CallTool.Result
}

enum MCPCancelTask: MCP.Method {
    static let name = "tasks/cancel"
    struct Parameters: Codable, Hashable, Sendable { var taskId: String }
    typealias Result = MCPWireTask
}

actor MCPTaskStore {
    static let shared = MCPTaskStore()
    private var tasks: [String: MCPTaskReference] = [:]
    private var didLoad = false
    private var fileURL: URL { MCPConfigurationStore.directory.appendingPathComponent("mcp.tasks.json") }

    func values(serverID: String? = nil) -> [MCPTaskReference] {
        loadIfNeeded()
        return tasks.values.filter { serverID == nil || $0.serverID == serverID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ task: MCPTaskReference) {
        loadIfNeeded(); tasks[key(serverID: task.serverID, id: task.id)] = task; persist()
    }

    func remove(serverID: String, id: String) {
        loadIfNeeded(); tasks.removeValue(forKey: key(serverID: serverID, id: id)); persist()
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }; didLoad = true
        guard let data = try? Foundation.Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MCPTaskReference].self, from: data) else { return }
        tasks = Dictionary(uniqueKeysWithValues: decoded.map { (key(serverID: $0.serverID, id: $0.id), $0) })
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: MCPConfigurationStore.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(tasks.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func key(serverID: String, id: String) -> String { "\(serverID)\u{0}\(id)" }
}
#endif
