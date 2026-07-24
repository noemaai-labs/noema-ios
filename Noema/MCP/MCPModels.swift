#if os(macOS)
import Foundation

enum MCPTransportConfiguration: Equatable, Sendable {
    case stdio(command: String, arguments: [String], workingDirectory: String?, environment: [String: String])
    case streamableHTTP(url: URL, headers: [String: String])
    case legacySSE(url: URL, headers: [String: String])

    var displayName: String {
        switch self {
        case .stdio: String(localized: "Local Process")
        case .streamableHTTP: String(localized: "Streamable HTTP")
        case .legacySSE: String(localized: "HTTP + SSE")
        }
    }

    var isRemote: Bool {
        switch self { case .stdio: false; case .streamableHTTP, .legacySSE: true }
    }
}

struct MCPServerPolicy: Codable, Equatable, Sendable {
    var enabled = true
    var trusted = false
    var allowCloudModels = false
    // Retained in the JSON model for backward compatibility. Configured servers
    // are lifecycle-managed and connected automatically by Noema.
    var startOnDemand = false
    var idleTimeoutSeconds: Int = 300
    var roots: [String] = []
    var allowAllTools = false
    var disabledTools: Set<String> = []
    var alwaysAllowedTools: Set<String> = []
    var allowSampling = false
    var allowElicitation = true
    var experimentalTasks = false
    var approvedPackageSpecification: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, trusted, allowCloudModels, startOnDemand, idleTimeoutSeconds
        case roots, allowAllTools, disabledTools, alwaysAllowedTools
        case allowSampling, allowElicitation, experimentalTasks
        case approvedPackageSpecification
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trusted = try container.decodeIfPresent(Bool.self, forKey: .trusted) ?? false
        allowCloudModels = try container.decodeIfPresent(Bool.self, forKey: .allowCloudModels) ?? false
        startOnDemand = try container.decodeIfPresent(Bool.self, forKey: .startOnDemand) ?? false
        idleTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .idleTimeoutSeconds) ?? 300
        roots = try container.decodeIfPresent([String].self, forKey: .roots) ?? []
        allowAllTools = try container.decodeIfPresent(Bool.self, forKey: .allowAllTools) ?? false
        disabledTools = try container.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? []
        alwaysAllowedTools = try container.decodeIfPresent(Set<String>.self, forKey: .alwaysAllowedTools) ?? []
        allowSampling = try container.decodeIfPresent(Bool.self, forKey: .allowSampling) ?? false
        allowElicitation = try container.decodeIfPresent(Bool.self, forKey: .allowElicitation) ?? true
        experimentalTasks = try container.decodeIfPresent(Bool.self, forKey: .experimentalTasks) ?? false
        approvedPackageSpecification = try container.decodeIfPresent(String.self, forKey: .approvedPackageSpecification)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(trusted, forKey: .trusted)
        try container.encode(allowCloudModels, forKey: .allowCloudModels)
        try container.encode(startOnDemand, forKey: .startOnDemand)
        try container.encode(idleTimeoutSeconds, forKey: .idleTimeoutSeconds)
        try container.encode(roots, forKey: .roots)
        try container.encode(allowAllTools, forKey: .allowAllTools)
        try container.encode(disabledTools, forKey: .disabledTools)
        try container.encode(alwaysAllowedTools, forKey: .alwaysAllowedTools)
        try container.encode(allowSampling, forKey: .allowSampling)
        try container.encode(allowElicitation, forKey: .allowElicitation)
        try container.encode(experimentalTasks, forKey: .experimentalTasks)
        try container.encodeIfPresent(approvedPackageSpecification, forKey: .approvedPackageSpecification)
    }

    func isToolEnabled(_ name: String) -> Bool { !disabledTools.contains(name) }
    func alwaysAllowsTool(_ name: String) -> Bool { allowAllTools || alwaysAllowedTools.contains(name) }
}

struct MCPServerConfiguration: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var transport: MCPTransportConfiguration
    var policy: MCPServerPolicy
    var raw: JSONValue

    var sourceID: String { "noema.mcp.\(id)" }
}

struct MCPCapabilitySnapshot: Codable, Equatable, Sendable {
    var protocolVersion = "2025-11-25"
    var serverName: String?
    var serverVersion: String?
    var tools = 0
    var resources = 0
    var resourceTemplates = 0
    var prompts = 0
    var supportsCompletions = false
    var supportsResourceSubscriptions = false
    var supportsLogging = false
    var supportsSampling = false
    var supportsElicitation = false
    var supportsRoots = false
    var supportsTasks = false

    static let empty = MCPCapabilitySnapshot()
}

enum MCPContent: Codable, Equatable, Sendable, Identifiable {
    case text(String)
    case structured(JSONValue)
    case image(data: Data, mimeType: String)
    case audio(data: Data, mimeType: String)
    case embeddedResource(uri: String, mimeType: String?, text: String?, data: Data?)
    case resourceLink(uri: String, name: String, description: String?, mimeType: String?)

    var id: String {
        switch self {
        case .text(let value): "text:\(value.hashValue)"
        case .structured(let value): "json:\(value.hashValue)"
        case .image(let data, let mime): "image:\(mime):\(data.hashValue)"
        case .audio(let data, let mime): "audio:\(mime):\(data.hashValue)"
        case .embeddedResource(let uri, _, _, _): "resource:\(uri)"
        case .resourceLink(let uri, _, _, _): "link:\(uri)"
        }
    }
}

struct MCPTaskReference: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case working
        case inputRequired = "input_required"
        case completed
        case failed
        case cancelled
    }
    var id: String
    var serverID: String
    var state: State
    var statusMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?
    var pollIntervalMilliseconds: Int?
}

struct MCPToolResultEnvelope: Codable, Equatable, Sendable {
    var serverID: String
    var toolName: String
    var content: [MCPContent]
    var structuredContent: JSONValue?
    var isError: Bool
    var task: MCPTaskReference?

    var modelText: String {
        var pieces = content.compactMap { item -> String? in
            switch item {
            case .text(let text): text
            case .structured(let value): value.prettyPrinted
            case .embeddedResource(let uri, _, let text, _): text ?? "Resource: \(uri)"
            case .resourceLink(let uri, let name, _, _): "\(name): \(uri)"
            case .image(_, let mimeType): "[Image: \(mimeType)]"
            case .audio(_, let mimeType): "[Audio: \(mimeType)]"
            }
        }
        if let structuredContent { pieces.append(structuredContent.prettyPrinted) }
        return pieces.joined(separator: "\n\n")
    }
}

struct MCPToolDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String { alias }
    var serverID: String
    var originalName: String
    var alias: String
    var title: String?
    var description: String
    var inputSchema: JSONValue
    var outputSchema: JSONValue?
    var readOnly: Bool?
    var destructive: Bool?
    var openWorld: Bool?
}

struct MCPResourceDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(serverID):\(uri)" }
    var serverID: String
    var uri: String
    var name: String
    var title: String?
    var description: String?
    var mimeType: String?
    var isTemplate: Bool
}

struct MCPPromptDescriptor: Codable, Equatable, Identifiable, Sendable {
    struct Argument: Codable, Equatable, Identifiable, Sendable {
        var id: String { name }
        var name: String
        var title: String?
        var description: String?
        var required: Bool
    }
    var id: String { "\(serverID):\(name)" }
    var serverID: String
    var name: String
    var title: String?
    var description: String?
    var arguments: [Argument]
}

enum MCPConnectionState: Equatable, Sendable {
    case resolving
    case starting
    case authenticating
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case stopping
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .resolving: String(localized: "Resolving")
        case .starting: String(localized: "Starting")
        case .authenticating: String(localized: "Authenticating")
        case .connecting: String(localized: "Connecting")
        case .ready: String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting")
        case .stopping: String(localized: "Stopping")
        case .stopped: String(localized: "Not Connected")
        case .failed: String(localized: "Needs Attention")
        }
    }
}

struct MCPServerStatus: Identifiable, Equatable, Sendable {
    var id: String
    var configuration: MCPServerConfiguration
    var state: MCPConnectionState
    var capabilities: MCPCapabilitySnapshot
    var tools: [MCPToolDescriptor]
    var resources: [MCPResourceDescriptor]
    var prompts: [MCPPromptDescriptor]
    var runtimeSummary: String?
    var lastActivity: Date?
    var log: [MCPActivityEntry]
}

struct MCPActivityEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case lifecycle, request, progress, log, warning, error }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var message: String
}

#endif
