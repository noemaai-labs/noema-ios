#if os(macOS)
import Combine
import Foundation

enum MCPChatDefaults {
    private static let key = "mcpDefaultSelectedServerIDs"
    private static let knownKey = "mcpKnownServerIDs"
    private static let pendingKey = "mcpPendingServerIDs"
    static var selectedServerIDs: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func setSelected(_ serverID: String, enabled: Bool) {
        let updated = enabled
            ? selectedServerIDs.union([serverID])
            : selectedServerIDs.subtracting([serverID])
        UserDefaults.standard.set(Array(updated).sorted(), forKey: key)
    }

    static func select(_ serverID: String) { setSelected(serverID, enabled: true) }

    @discardableResult
    static func register(_ serverID: String) -> Bool {
        var known = Set(UserDefaults.standard.stringArray(forKey: knownKey) ?? [])
        guard known.insert(serverID).inserted else { return false }
        UserDefaults.standard.set(Array(known).sorted(), forKey: knownKey)
        select(serverID)
        var pending = Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
        pending.insert(serverID)
        UserDefaults.standard.set(Array(pending).sorted(), forKey: pendingKey)
        return true
    }

    static func remove(_ serverID: String) {
        setSelected(serverID, enabled: false)
        var known = Set(UserDefaults.standard.stringArray(forKey: knownKey) ?? [])
        known.remove(serverID)
        UserDefaults.standard.set(Array(known).sorted(), forKey: knownKey)
        var pending = Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
        pending.remove(serverID)
        UserDefaults.standard.set(Array(pending).sorted(), forKey: pendingKey)
    }

    static func consumePendingServerIDs() -> Set<String> {
        let pending = Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return pending
    }
}

extension Notification.Name {
    static let mcpServerAdded = Notification.Name("noemaMCPServerAdded")
    static let mcpCatalogChanged = Notification.Name("noemaMCPCatalogChanged")
    static let mcpInsertComposerText = Notification.Name("noemaMCPInsertComposerText")
    static let mcpToolApprovalResolved = Notification.Name("noemaMCPToolApprovalResolved")
}

enum MCPApprovalDecision: Sendable { case allowOnce, alwaysAllow, deny }

struct MCPApprovalRequest: Identifiable, Sendable {
    let id: UUID
    let serverID: String
    let serverName: String
    let tool: MCPToolDescriptor
    let arguments: JSONValue
}

@MainActor
final class MCPApprovalCenter: ObservableObject {
    static let shared = MCPApprovalCenter()
    @Published private(set) var request: MCPApprovalRequest?
    private var continuation: CheckedContinuation<MCPApprovalDecision, Never>?

    func ask(server: MCPServerConfiguration, tool: MCPToolDescriptor, arguments: JSONValue) async -> MCPApprovalDecision {
        guard request == nil else { return .deny }
        request = .init(id: UUID(), serverID: server.id, serverName: server.displayName, tool: tool, arguments: arguments)
        return await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ decision: MCPApprovalDecision) {
        request = nil; continuation?.resume(returning: decision); continuation = nil
    }

    func cancel() { answer(.deny) }
}

actor MCPServerConnection {
    typealias UpdateSink = @Sendable (MCPConnectionState?, MCPCapabilitySnapshot?, [MCPToolDescriptor]?, [MCPResourceDescriptor]?, [MCPPromptDescriptor]?, String?, MCPActivityEntry?) async -> Void

    private var configuration: MCPServerConfiguration
    private var client: MCPSwiftSDKClient?
    private var process: MCPHostedProcess?
    private var stderrTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectionAttemptInProgress = false
    private var state: MCPConnectionState = .stopped
    private let update: UpdateSink

    init(configuration: MCPServerConfiguration, update: @escaping UpdateSink) {
        self.configuration = configuration; self.update = update
    }

    func replaceConfiguration(_ configuration: MCPServerConfiguration) async {
        let previous = self.configuration
        let rootsChanged = previous.policy.roots != configuration.policy.roots
        let negotiatedCapabilitiesChanged =
            previous.policy.allowSampling != configuration.policy.allowSampling ||
            previous.policy.allowElicitation != configuration.policy.allowElicitation ||
            previous.policy.experimentalTasks != configuration.policy.experimentalTasks
        let connectionContractChanged = previous.transport != configuration.transport || negotiatedCapabilitiesChanged
        self.configuration = configuration
        if !configuration.policy.enabled {
            if state != .stopped { await stop() }
            return
        }
        if connectionContractChanged, state == .ready {
            await stop(); await connect()
        } else if rootsChanged, state == .ready {
            try? await client?.notifyRootsChanged()
        }
    }

    func connect() async {
        guard configuration.policy.enabled, state != .ready, !NetworkKillSwitch.isEnabled,
              !connectionAttemptInProgress else { return }
        connectionAttemptInProgress = true
        defer { connectionAttemptInProgress = false }
        guard EnterprisePolicyGate.allowsMCP(serverID: configuration.id, transport: configuration.transport) else {
            let message = String(localized: "Your workspace policy does not allow this MCP server.")
            state = .failed(message)
            await update(state, nil, nil, nil, nil, nil, .init(kind: .warning, message: message))
            return
        }
        if case .reconnecting = state {
            // This is the bounded reconnect task itself. Do not cancel it.
        } else {
            reconnectTask?.cancel(); reconnectTask = nil
        }
        do {
            let sdk = MCPSwiftSDKClient(
                serverID: configuration.id, policy: configuration.policy,
                activity: { [update] entry in await update(nil, nil, nil, nil, nil, nil, entry) },
                catalogChanged: { [weak self] in await self?.refreshCatalogs() }
            )
            client = sdk
            let snapshot: MCPCapabilitySnapshot
            switch configuration.transport {
            case .stdio:
                await transition(.resolving)
                let runtime = try MCPRuntimeResolver.resolve(configuration: configuration.transport)
                if let package = runtime.packageSpecification,
                   package != configuration.policy.approvedPackageSpecification {
                    throw ToolError.executionFailed(String(localized: "Confirm the requested npx package before this server can run: \(package)"))
                }
                await transition(.starting, runtime: runtime.summary)
                let hosted = try await MCPDirectProcessLauncher.launch(runtime)
                process = hosted
                captureStderr(hosted.standardError)
                await transition(.connecting)
                snapshot = try await sdk.connectStdio(
                    inputDescriptor: hosted.standardOutput.fileDescriptor,
                    outputDescriptor: hosted.standardInput.fileDescriptor
                )
            case .streamableHTTP(let url, let headers):
                await transition(.connecting)
                snapshot = try await sdk.connectHTTP(url: url, headers: headers, legacySSE: false)
            case .legacySSE(let url, let headers):
                await transition(.connecting)
                snapshot = try await sdk.connectHTTP(url: url, headers: headers, legacySSE: true)
            }
            state = .ready
            reconnectTask = nil
            await update(.ready, snapshot, nil, nil, nil, nil, .init(kind: .lifecycle, message: String(localized: "Connected using MCP \(snapshot.protocolVersion).")))
            await refreshCatalogs()
        } catch {
            await fail(error)
        }
    }

    func reconnect() async {
        await stop()
        await connect()
    }

    func stop() async {
        reconnectTask?.cancel(); reconnectTask = nil
        await transition(.stopping)
        stderrTask?.cancel(); stderrTask = nil
        await client?.disconnect(); client = nil
        await process?.terminate(); process = nil
        state = .stopped
        await update(.stopped, nil, [], [], [], nil, .init(kind: .lifecycle, message: String(localized: "Disconnected.")))
    }

    func ping() async throws { try await ensureReady(); try await client?.ping() }

    func refreshCatalogs() async {
        guard let client, state == .ready else { return }
        do {
            let tools = try await client.listTools()
            let resources = (try? await client.listResources()) ?? []
            let prompts = (try? await client.listPrompts()) ?? []
            await update(nil, nil, tools, resources, prompts, nil, .init(kind: .lifecycle, message: String(localized: "Capabilities refreshed.")))
        } catch { await fail(error) }
    }

    func call(_ tool: MCPToolDescriptor, arguments: JSONValue, invocationID: String) async throws -> MCPToolResultEnvelope {
        try await ensureReady()
        guard let client else { throw ToolError.executionFailed(String(localized: "MCP server is not connected.")) }
        let result = try await client.callTool(tool, arguments: arguments, invocationID: invocationID)
        return result
    }

    func cancel(invocationID: String) async { await client?.cancel(invocationID: invocationID) }
    func readResource(_ uri: String) async throws -> [MCPContent] { try await ensureReady(); return try await client?.readResource(uri: uri) ?? [] }
    func subscribe(_ uri: String) async throws { try await ensureReady(); try await client?.subscribe(uri: uri) }
    func unsubscribe(_ uri: String) async throws { try await ensureReady(); try await client?.unsubscribe(uri: uri) }
    func prompt(_ name: String, arguments: [String: String]) async throws -> [MCPContent] { try await ensureReady(); return try await client?.getPrompt(name: name, arguments: arguments) ?? [] }
    func completePrompt(_ name: String, argument: String, value: String, context: [String: String]) async throws -> [String] { try await ensureReady(); return try await client?.completePrompt(name: name, argument: argument, value: value, context: context) ?? [] }
    func completeResource(_ uri: String, argument: String, value: String, context: [String: String]) async throws -> [String] { try await ensureReady(); return try await client?.completeResource(uri: uri, argument: argument, value: value, context: context) ?? [] }

    private func ensureReady() async throws {
        if state != .ready { await connect() }
        guard state == .ready else { throw ToolError.executionFailed(String(localized: "MCP server is not connected.")) }
    }

    private func fail(_ error: Error) async {
        stderrTask?.cancel(); stderrTask = nil; await client?.disconnect(); client = nil; await process?.terminate(); process = nil
        let message = MCPRedaction.redact(error.localizedDescription)
        state = .failed(message)
        await update(state, nil, nil, nil, nil, nil, .init(kind: .error, message: message))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard configuration.policy.enabled, reconnectTask == nil, !NetworkKillSwitch.isEnabled else { return }
        reconnectTask = Task { [weak self] in
            for attempt in 1...5 {
                guard !Task.isCancelled else { return }
                await self?.transition(.reconnecting(attempt: attempt))
                let delay = min(pow(2.0, Double(attempt - 1)), 30)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.connect()
                if await self?.isReady() == true { return }
            }
            await self?.finishedReconnecting()
        }
    }

    private func isReady() -> Bool { state == .ready }
    private func finishedReconnecting() { reconnectTask = nil }

    private func captureStderr(_ handle: FileHandle) {
        stderrTask?.cancel()
        stderrTask = Task { [update] in
            do {
                for try await byte in handle.bytes.lines {
                    guard !Task.isCancelled else { return }
                    await update(nil, nil, nil, nil, nil, nil, .init(kind: .log, message: MCPRedaction.redact(byte)))
                }
            } catch { }
        }
    }

    private func transition(_ next: MCPConnectionState, runtime: String? = nil) async {
        state = next; await update(next, nil, nil, nil, nil, runtime, nil)
    }
}

enum MCPRedaction {
    static func redact(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(authorization|token|secret|password|api[_-]?key)\s*[:=]\s*[^\s,}]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._~+/-]+=*"#,
            #"\$\{keychain:[^}]+\}"#
        ]
        for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression) }
        return result
    }
}

private final class MCPDynamicTool: Tool, @unchecked Sendable {
    let descriptor: MCPToolDescriptor
    var name: String { descriptor.alias }
    var description: String { descriptor.description }
    var schema: String { descriptor.inputSchema.prettyPrinted }
    init(_ descriptor: MCPToolDescriptor) { self.descriptor = descriptor }
    func call(args: Data) async throws -> Data {
        let arguments = try JSONDecoder().decode(JSONValue.self, from: args)
        let invocationID = UUID().uuidString
        let result = try await withTaskCancellationHandler {
            try await MCPServerManager.shared.callTool(alias: descriptor.alias, arguments: arguments, invocationID: invocationID)
        } onCancel: {
            Task { await MCPServerManager.shared.cancel(alias: descriptor.alias, invocationID: invocationID) }
        }
        var payload: [String: JSONValue] = [
            "serverID": .string(result.serverID), "tool": .string(result.toolName),
            "isError": .bool(result.isError), "text": .string(result.modelText),
            "content": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result.content)),
            "renderContent": .array(result.content.map(Self.renderContent))
        ]
        if let structured = result.structuredContent { payload["structuredContent"] = structured }
        if let task = result.task { payload["task"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(task)) }
        return try JSONEncoder().encode(JSONValue.object(payload))
    }

    private static func renderContent(_ content: MCPContent) -> JSONValue {
        switch content {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .structured(let value):
            return .object(["type": .string("structured"), "value": value])
        case .image(let data, let mimeType):
            return .object(["type": .string("image"), "mimeType": .string(mimeType), "data": .string(data.base64EncodedString())])
        case .audio(let data, let mimeType):
            return .object(["type": .string("audio"), "mimeType": .string(mimeType), "data": .string(data.base64EncodedString())])
        case .embeddedResource(let uri, let mimeType, let text, let data):
            var object: [String: JSONValue] = ["type": .string("embeddedResource"), "uri": .string(uri)]
            if let mimeType { object["mimeType"] = .string(mimeType) }
            if let text { object["text"] = .string(text) }
            if let data { object["data"] = .string(data.base64EncodedString()) }
            return .object(object)
        case .resourceLink(let uri, let name, let description, let mimeType):
            var object: [String: JSONValue] = ["type": .string("resourceLink"), "uri": .string(uri), "name": .string(name)]
            if let description { object["description"] = .string(description) }
            if let mimeType { object["mimeType"] = .string(mimeType) }
            return .object(object)
        }
    }
}

@MainActor
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()
    @Published private(set) var servers: [MCPServerStatus] = []

    private let configurationStore = MCPConfigurationStore.shared
    private var connections: [String: MCPServerConnection] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var activeChatSelectedServerIDs: Set<String> = []

    private init() {
        configurationStore.$servers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configurations in self?.apply(configurations) }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard UserDefaults.standard.bool(forKey: "offGrid") else { return }
                Task { @MainActor [weak self] in await self?.disconnectAllForOffGrid() }
            }
            .store(in: &subscriptions)
        apply(configurationStore.servers)
    }

    var connectedCount: Int { servers.filter { $0.state == .ready }.count }
    var attentionCount: Int { servers.filter { if case .failed = $0.state { true } else { false } }.count }

    func connect(serverID: String) async { await connections[serverID]?.connect() }
    func disconnect(serverID: String) async { await connections[serverID]?.stop() }
    func refreshConnection(serverID: String) async { await connections[serverID]?.reconnect() }
    func refresh(serverID: String) async { await connections[serverID]?.refreshCatalogs() }

    func setActiveChatSelection(serverIDs: Set<String>) {
        activeChatSelectedServerIDs = serverIDs
    }

    func connectConfiguredServers() {
        guard !NetworkKillSwitch.isEnabled else { return }
        for status in servers where status.configuration.policy.enabled {
            Task { await connections[status.id]?.connect() }
        }
    }

    func requestedPackageSpecification(serverID: String) -> String? {
        guard let transport = servers.first(where: { $0.id == serverID })?.configuration.transport else { return nil }
        return try? MCPRuntimeResolver.resolve(configuration: transport).packageSpecification
    }

    func approveCurrentPackage(serverID: String) throws {
        guard let package = requestedPackageSpecification(serverID: serverID) else { return }
        try configurationStore.updatePolicy(serverID: serverID) { $0.approvedPackageSpecification = package }
    }

    func disconnectAllForOffGrid() async {
        MCPApprovalCenter.shared.cancel(); MCPHumanInteractionCenter.shared.cancelAll()
        for connection in connections.values { await connection.stop() }
    }

    func callTool(alias: String, arguments: JSONValue, invocationID: String) async throws -> MCPToolResultEnvelope {
        guard let status = servers.first(where: { $0.tools.contains { $0.alias == alias } }),
              let tool = status.tools.first(where: { $0.alias == alias }),
              let connection = connections[status.id] else { throw ToolError.unknownTool(alias) }
        guard isToolSelectable(
            alias: alias,
            selectedServerIDs: activeChatSelectedServerIDs,
            remoteModel: UserDefaults.standard.bool(forKey: "currentModelIsRemote")
        ) else {
            throw ToolError.executionFailed(String(localized: "This MCP server is not enabled for this chat."))
        }
        guard status.configuration.policy.isToolEnabled(tool.originalName) else {
            throw ToolError.executionFailed(String(localized: "This MCP tool is disabled."))
        }
        guard EnterprisePolicyGate.allowsMCP(serverID: status.id, transport: status.configuration.transport, toolAlias: alias) else {
            throw ToolError.executionFailed(String(localized: "Your workspace policy does not allow this MCP tool."))
        }
        let policy = status.configuration.policy
        let canRunWithoutPrompt = policy.alwaysAllowsTool(tool.originalName)
        var rememberApproval = false
        if !canRunWithoutPrompt {
            let decision = await MCPApprovalCenter.shared.ask(server: status.configuration, tool: tool, arguments: arguments)
            switch decision {
            case .deny: throw CancellationError()
            case .alwaysAllow: rememberApproval = true
            case .allowOnce: break
            }
        }
        if rememberApproval {
            try configurationStore.updatePolicy(serverID: status.id) {
                $0.alwaysAllowedTools.insert(tool.originalName)
            }
        }
        NotificationCenter.default.post(name: .mcpToolApprovalResolved, object: alias)
        return try await connection.call(tool, arguments: arguments, invocationID: invocationID)
    }

    func cancel(serverID: String, invocationID: String) async { await connections[serverID]?.cancel(invocationID: invocationID) }
    func cancel(alias: String, invocationID: String) async {
        guard let serverID = servers.first(where: { $0.tools.contains { $0.alias == alias } })?.id else { return }
        await connections[serverID]?.cancel(invocationID: invocationID)
    }
    func readResource(serverID: String, uri: String) async throws -> [MCPContent] { try await connection(serverID).readResource(uri) }
    func subscribe(serverID: String, uri: String) async throws { try await connection(serverID).subscribe(uri) }
    func unsubscribe(serverID: String, uri: String) async throws { try await connection(serverID).unsubscribe(uri) }
    func prompt(serverID: String, name: String, arguments: [String: String]) async throws -> [MCPContent] { try await connection(serverID).prompt(name, arguments: arguments) }
    func completePrompt(serverID: String, name: String, argument: String, value: String, context: [String: String]) async throws -> [String] { try await connection(serverID).completePrompt(name, argument: argument, value: value, context: context) }
    func completeResource(serverID: String, uri: String, argument: String, value: String, context: [String: String]) async throws -> [String] { try await connection(serverID).completeResource(uri, argument: argument, value: value, context: context) }

    func tools(selectedServerIDs: Set<String>, allowCloudModel: Bool) -> [MCPToolDescriptor] {
        servers
            .filter { selectedServerIDs.contains($0.id) && $0.state == .ready && (!allowCloudModel || $0.configuration.policy.allowCloudModels) }
            .flatMap { server in server.tools.filter { server.configuration.policy.isToolEnabled($0.originalName) } }
    }

    func isToolSelectable(alias: String, selectedServerIDs: Set<String>, remoteModel: Bool) -> Bool {
        guard let server = servers.first(where: { $0.tools.contains { $0.alias == alias } }) else { return false }
        guard let tool = server.tools.first(where: { $0.alias == alias }) else { return false }
        return server.state == .ready
            && !NetworkKillSwitch.isEnabled
            && selectedServerIDs.contains(server.id)
            && server.configuration.policy.isToolEnabled(tool.originalName)
            && (!remoteModel || server.configuration.policy.allowCloudModels)
    }

    func descriptor(alias: String) -> (server: MCPServerStatus, tool: MCPToolDescriptor)? {
        guard let server = servers.first(where: { $0.tools.contains { $0.alias == alias } }),
              let tool = server.tools.first(where: { $0.alias == alias }) else { return nil }
        return (server, tool)
    }

    func isToolSelectableForActiveChat(alias: String) -> Bool {
        isToolSelectable(
            alias: alias,
            selectedServerIDs: activeChatSelectedServerIDs,
            remoteModel: UserDefaults.standard.bool(forKey: "currentModelIsRemote")
        )
    }

    func activeChatTools(matching query: String) -> [MCPToolDescriptor] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let remoteModel = UserDefaults.standard.bool(forKey: "currentModelIsRemote")
        return servers
            .filter {
                activeChatSelectedServerIDs.contains($0.id)
                    && $0.state == .ready
                    && (!remoteModel || $0.configuration.policy.allowCloudModels)
            }
            .flatMap { server in
                server.tools.filter { server.configuration.policy.isToolEnabled($0.originalName) }
            }
            .filter { tool in
                let haystack = "\(tool.serverID) \(tool.originalName) \(tool.title ?? "") \(tool.description)".lowercased()
                return words.isEmpty || words.allSatisfy(haystack.contains)
            }
            .prefix(20)
            .map { $0 }
    }

    private func connection(_ id: String) throws -> MCPServerConnection {
        guard let connection = connections[id] else { throw ToolError.executionFailed(String(localized: "MCP server is not configured.")) }
        return connection
    }

    private func apply(_ configurations: [MCPServerConfiguration]) {
        let ids = Set(configurations.map(\.id))
        for removed in Set(connections.keys).subtracting(ids) {
            let connection = connections.removeValue(forKey: removed)
            Task { await connection?.stop() }
            ToolRegistry.shared.unregisterTools(from: "noema.mcp.\(removed)")
            MCPChatDefaults.remove(removed)
        }
        for configuration in configurations {
            var newConnectionToStart: MCPServerConnection?
            if let connection = connections[configuration.id] {
                Task {
                    await connection.replaceConfiguration(configuration)
                    if configuration.policy.enabled && !NetworkKillSwitch.isEnabled {
                        await connection.connect()
                    }
                }
            } else {
                let connection = MCPServerConnection(configuration: configuration) { [weak self] state, capabilities, tools, resources, prompts, runtime, activity in
                    await self?.receive(
                        serverID: configuration.id, state: state, capabilities: capabilities,
                        tools: tools, resources: resources, prompts: prompts, runtime: runtime, activity: activity
                    )
                }
                connections[configuration.id] = connection
                newConnectionToStart = connection
            }
            if let index = servers.firstIndex(where: { $0.id == configuration.id }) { servers[index].configuration = configuration }
            else { servers.append(.init(id: configuration.id, configuration: configuration, state: .stopped, capabilities: .empty, tools: [], resources: [], prompts: [], log: [])) }
            if let index = servers.firstIndex(where: { $0.id == configuration.id }) {
                let enabledTools = servers[index].tools.filter { configuration.policy.isToolEnabled($0.originalName) }
                ToolRegistry.shared.replaceTools(from: configuration.sourceID, with: enabledTools.map(MCPDynamicTool.init))
            }
            if MCPChatDefaults.register(configuration.id) {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .mcpServerAdded, object: configuration.id)
                }
            }
            if let connection = newConnectionToStart,
               configuration.policy.enabled,
               !NetworkKillSwitch.isEnabled {
                Task { await connection.connect() }
            }
        }
        servers.removeAll { !ids.contains($0.id) }
        servers.sort { $0.configuration.displayName.localizedStandardCompare($1.configuration.displayName) == .orderedAscending }
    }

    private func receive(
        serverID: String, state: MCPConnectionState?, capabilities: MCPCapabilitySnapshot?, tools: [MCPToolDescriptor]?,
        resources: [MCPResourceDescriptor]?, prompts: [MCPPromptDescriptor]?, runtime: String?, activity: MCPActivityEntry?
    ) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        if let state { servers[index].state = state }
        if let capabilities {
            var merged = capabilities
            if capabilities.tools == 0 { merged.tools = servers[index].tools.count }
            if capabilities.resources == 0 { merged.resources = servers[index].resources.filter { !$0.isTemplate }.count }
            if capabilities.resourceTemplates == 0 { merged.resourceTemplates = servers[index].resources.filter(\.isTemplate).count }
            if capabilities.prompts == 0 { merged.prompts = servers[index].prompts.count }
            servers[index].capabilities = merged
        }
        if let tools {
            servers[index].tools = tools
            servers[index].capabilities.tools = tools.count
            let enabledTools = tools.filter { servers[index].configuration.policy.isToolEnabled($0.originalName) }
            ToolRegistry.shared.replaceTools(from: servers[index].configuration.sourceID, with: enabledTools.map(MCPDynamicTool.init))
            NotificationCenter.default.post(name: .mcpCatalogChanged, object: serverID)
        }
        if let resources {
            servers[index].resources = resources
            servers[index].capabilities.resources = resources.filter { !$0.isTemplate }.count
            servers[index].capabilities.resourceTemplates = resources.filter(\.isTemplate).count
        }
        if let prompts {
            servers[index].prompts = prompts
            servers[index].capabilities.prompts = prompts.count
        }
        if let runtime { servers[index].runtimeSummary = runtime }
        if let activity {
            servers[index].lastActivity = activity.date
            servers[index].log.append(activity)
            if servers[index].log.count > 300 { servers[index].log.removeFirst(servers[index].log.count - 300) }
        }
        if state == .ready { try? configurationStore.markLastKnownGood() }
    }
}
#endif
