#if os(macOS)
import AppKit
import AuthenticationServices
import Foundation
import Logging
import MCP

/// SDK 0.12.1 exposes the stable unsubscribe method but not a public parameter
/// initializer. Keep this wire-compatible shim inside the protocol adapter so
/// it can disappear when a later SDK publishes the initializer.
private enum NoemaResourceUnsubscribe: MCP.Method {
    static let name = "resources/unsubscribe"
    struct Parameters: Codable, Hashable, Sendable {
        let uri: String
    }
    typealias Result = MCP.Empty
}

protocol MCPProtocolClient: Actor {
    func connectHTTP(url: URL, headers: [String: String], legacySSE: Bool) async throws -> MCPCapabilitySnapshot
    func connectStdio(inputDescriptor: Int32, outputDescriptor: Int32) async throws -> MCPCapabilitySnapshot
    func disconnect() async
    func ping() async throws
    func listTools() async throws -> [MCPToolDescriptor]
    func listResources() async throws -> [MCPResourceDescriptor]
    func listPrompts() async throws -> [MCPPromptDescriptor]
    func callTool(_ tool: MCPToolDescriptor, arguments: JSONValue, invocationID: String) async throws -> MCPToolResultEnvelope
    func cancel(invocationID: String) async
    func readResource(uri: String) async throws -> [MCPContent]
    func subscribe(uri: String) async throws
    func unsubscribe(uri: String) async throws
    func getPrompt(name: String, arguments: [String: String]) async throws -> [MCPContent]
    func completePrompt(name: String, argument: String, value: String, context: [String: String]) async throws -> [String]
    func completeResource(uri: String, argument: String, value: String, context: [String: String]) async throws -> [String]
    func notifyRootsChanged() async throws
}

private final class MCPKeychainTokenStorage: MCP.TokenStorage, @unchecked Sendable {
    private let key: String
    init(serverID: String) { key = "oauth.\(serverID)" }
    func save(_ token: MCP.OAuthAccessToken) {
        guard let data = try? JSONEncoder().encode(token), let value = String(data: data, encoding: .utf8) else { return }
        try? MCPKeychain.set(value, named: key)
    }
    func load() -> MCP.OAuthAccessToken? {
        guard let value = try? MCPKeychain.value(named: key),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MCP.OAuthAccessToken.self, from: data)
    }
    func clear() { MCPKeychain.remove(named: key) }
}

private struct MCPOAuthDelegate: MCP.OAuthAuthorizationDelegate {
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        try await MCPOAuthBrowser.shared.present(url)
    }
}

@MainActor
private final class MCPOAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPOAuthBrowser()
    private var session: ASWebAuthenticationSession?

    func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "noema-mcp") { callback, error in
                self.session = nil
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? CancellationError()) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: ToolError.executionFailed(String(localized: "Could not start secure sign-in.")))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

actor MCPSwiftSDKClient: MCPProtocolClient {
    private let serverID: String
    private let policy: MCPServerPolicy
    private let client: MCP.Client
    private var initializeResult: MCP.Initialize.Result?
    private var activeRequests: [String: MCP.ID] = [:]
    private var activeTasks: [String: String] = [:]
    private var taskSupport = MCPNegotiatedTaskSupport()
    private let activity: @Sendable (MCPActivityEntry) async -> Void
    private let catalogChanged: @Sendable () async -> Void

    init(
        serverID: String,
        policy: MCPServerPolicy,
        activity: @escaping @Sendable (MCPActivityEntry) async -> Void,
        catalogChanged: @escaping @Sendable () async -> Void
    ) {
        self.serverID = serverID; self.policy = policy; self.activity = activity; self.catalogChanged = catalogChanged
        let capabilities = MCP.Client.Capabilities(
            sampling: policy.allowSampling && EnterprisePolicyGate.mcpSamplingAllowed ? .init() : nil,
            elicitation: policy.allowElicitation && EnterprisePolicyGate.mcpElicitationAllowed ? .init(form: .init(), url: .init()) : nil,
            experimental: policy.experimentalTasks ? ["tasks": "2025-11-25"] : nil,
            roots: .init(listChanged: true)
        )
        client = MCP.Client(
            name: "noema-mac", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
            title: "Noema", description: "Private on-device assistant", capabilities: capabilities, configuration: .strict
        )
    }

    func connectHTTP(url: URL, headers: [String: String], legacySSE: Bool) async throws -> MCPCapabilitySnapshot {
        let resolved = try MCPReferenceResolver.resolve(headers)
        if legacySSE {
            return try await finishConnection(transport: MCPLegacySSETransport(url: url, headers: resolved))
        }
        let oauth = MCP.OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: ""),
            authorizationRedirectURI: URL(string: "noema-mcp://oauth/callback"),
            clientName: "Noema",
            authorizationDelegate: MCPOAuthDelegate()
        )
        let authorizer = MCP.OAuthAuthorizer(configuration: oauth, tokenStorage: MCPKeychainTokenStorage(serverID: serverID))
        let transport = MCP.HTTPClientTransport(
            endpoint: url,
            streaming: true,
            protocolVersion: "2025-11-25",
            authorizer: authorizer,
            requestModifier: { request in
                var request = request
                for (name, value) in resolved { request.setValue(value, forHTTPHeaderField: name) }
                return request
            }
        )
        do {
            return try await finishConnection(transport: transport)
        } catch {
            // Older servers expose the original GET-SSE/POST transport at the
            // same configured URL. Disconnect the failed session before trying
            // that protocol so the fallback never creates parallel clients.
            await client.disconnect()
            return try await finishConnection(transport: MCPLegacySSETransport(url: url, headers: resolved))
        }
    }

    func connectStdio(inputDescriptor: Int32, outputDescriptor: Int32) async throws -> MCPCapabilitySnapshot {
        let transport = MCP.StdioTransport(input: .init(rawValue: inputDescriptor), output: .init(rawValue: outputDescriptor))
        return try await finishConnection(transport: transport)
    }

    private func finishConnection<Base: MCP.Transport>(transport: Base) async throws -> MCPCapabilitySnapshot {
        await registerHandlers()
        let negotiating = MCPTaskNegotiatingTransport(
            base: transport,
            enabled: policy.experimentalTasks,
            logger: Logging.Logger(label: "ai.noema.mcp.tasks.\(serverID)")
        )
        let result = try await client.connect(transport: negotiating)
        initializeResult = result
        taskSupport = await negotiating.negotiatedSupport()
        var capabilities = snapshot(result)
        capabilities.supportsTasks = taskSupport.available && taskSupport.toolsCall
        if capabilities.supportsTasks { Task { await self.resumePersistedTasks() } }
        return capabilities
    }

    private func registerHandlers() async {
        await client.onNotification(MCP.ToolListChangedNotification.self) { [catalogChanged] _ in await catalogChanged() }
        await client.onNotification(MCP.ResourceListChangedNotification.self) { [catalogChanged] _ in await catalogChanged() }
        await client.onNotification(MCP.PromptListChangedNotification.self) { [catalogChanged] _ in await catalogChanged() }
        await client.onNotification(MCP.ResourceUpdatedNotification.self) { [activity] message in
            await activity(.init(kind: .request, message: "Resource updated: \(message.params.uri)"))
        }
        await client.onNotification(MCP.ProgressNotification.self) { [activity] message in
            let detail = message.params.message ?? "\(Int(message.params.progress))"
            await activity(.init(kind: .progress, message: detail))
        }
        await client.onNotification(MCP.LogMessageNotification.self) { [activity] message in
            await activity(.init(kind: .log, message: Self.redacted(Self.json(message.params.data).prettyPrinted)))
        }
        await client.withRootsHandler { [serverID, policy] in
            policy.roots.compactMap { path in
                let expanded = NSString(string: path).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
                guard url.isFileURL else { return nil }
                return MCP.Root(uri: url.absoluteString, name: url.lastPathComponent.isEmpty ? serverID : url.lastPathComponent)
            }
        }
        if policy.allowSampling && EnterprisePolicyGate.mcpSamplingAllowed {
            await client.withSamplingHandler { [serverID] parameters in
                guard EnterprisePolicyGate.mcpSamplingAllowed else {
                    throw ToolError.executionFailed(String(localized: "Your workspace policy does not allow MCP sampling."))
                }
                let prompt = Self.samplingPrompt(parameters)
                let output = try await MCPHumanInteractionCenter.shared.sample(
                    serverID: serverID, prompt: prompt, maxTokens: parameters.maxTokens, temperature: parameters.temperature
                )
                return .init(model: "Noema On-Device", stopReason: .endTurn, role: .assistant, content: .text(output))
            }
        }
        if policy.allowElicitation && EnterprisePolicyGate.mcpElicitationAllowed {
            await client.withElicitationHandler { [serverID] parameters in
                guard EnterprisePolicyGate.mcpElicitationAllowed else {
                    throw ToolError.executionFailed(String(localized: "Your workspace policy does not allow MCP requests."))
                }
                let decision: MCPElicitationDecision
                switch parameters {
                case .form(let request):
                    let schema = Self.json(request.requestedSchema)
                    decision = try await MCPHumanInteractionCenter.shared.elicit(serverID: serverID, message: request.message, mode: .form(schema: schema))
                case .url(let request):
                    guard let url = URL(string: request.url) else { return .init(action: .cancel) }
                    decision = try await MCPHumanInteractionCenter.shared.elicit(serverID: serverID, message: request.message, mode: .url(url))
                }
                switch decision {
                case .accept(let content):
                    return .init(action: .accept, content: try content.mapValues(Self.mcpValue))
                case .decline: return .init(action: .decline)
                case .cancel: return .init(action: .cancel)
                }
            }
        }
    }

    func disconnect() async {
        await client.disconnect()
        activeRequests.removeAll()
        activeTasks.removeAll()
    }
    func ping() async throws { try await client.ping() }

    func listTools() async throws -> [MCPToolDescriptor] {
        var cursor: String?; var result: [MCPToolDescriptor] = []; var aliases = Set<String>()
        repeat {
            let page = try await client.listTools(cursor: cursor)
            for tool in page.tools {
                let alias = MCPAlias.make(serverID: serverID, toolName: tool.name, existing: aliases); aliases.insert(alias)
                result.append(.init(
                    serverID: serverID, originalName: tool.name, alias: alias, title: tool.title,
                    description: tool.description ?? tool.title ?? tool.name,
                    inputSchema: Self.json(tool.inputSchema), outputSchema: tool.outputSchema.map(Self.json),
                    readOnly: tool.annotations.readOnlyHint, destructive: tool.annotations.destructiveHint,
                    openWorld: tool.annotations.openWorldHint
                ))
            }
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    func listResources() async throws -> [MCPResourceDescriptor] {
        var cursor: String?; var result: [MCPResourceDescriptor] = []
        repeat {
            let page = try await client.listResources(cursor: cursor)
            result += page.resources.map { .init(serverID: serverID, uri: $0.uri, name: $0.name, title: $0.title, description: $0.description, mimeType: $0.mimeType, isTemplate: false) }
            cursor = page.nextCursor
        } while cursor != nil
        cursor = nil
        repeat {
            let page = try await client.listResourceTemplates(cursor: cursor)
            result += page.templates.map { .init(serverID: serverID, uri: $0.uriTemplate, name: $0.name, title: $0.title, description: $0.description, mimeType: $0.mimeType, isTemplate: true) }
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    func listPrompts() async throws -> [MCPPromptDescriptor] {
        var cursor: String?; var result: [MCPPromptDescriptor] = []
        repeat {
            let page = try await client.listPrompts(cursor: cursor)
            result += page.prompts.map { prompt in
                .init(serverID: serverID, name: prompt.name, title: prompt.title, description: prompt.description, arguments: (prompt.arguments ?? []).map {
                    .init(name: $0.name, title: $0.title, description: $0.description, required: $0.required ?? false)
                })
            }
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    func callTool(_ tool: MCPToolDescriptor, arguments: JSONValue, invocationID: String) async throws -> MCPToolResultEnvelope {
        guard let object = arguments.objectValue else { throw ToolError.invalidArguments(String(localized: "Tool arguments must be a JSON object.")) }
        let values = try object.mapValues(Self.mcpValue)
        if taskSupport.toolsCall {
            return try await callToolAsTask(tool, arguments: values, invocationID: invocationID)
        }
        let context: MCP.RequestContext<MCP.CallTool.Result> = try await client.callTool(
            name: tool.originalName, arguments: values, meta: .init(progressToken: .string(invocationID))
        )
        activeRequests[invocationID] = context.requestID
        defer { activeRequests.removeValue(forKey: invocationID) }
        let result = try await context.value
        return Self.envelope(serverID: serverID, toolName: tool.originalName, result: result)
    }

    func cancel(invocationID: String) async {
        if let id = activeRequests.removeValue(forKey: invocationID) {
            try? await client.cancelRequest(id, reason: "Cancelled in Noema")
        }
        if let taskID = activeTasks.removeValue(forKey: invocationID), taskSupport.cancel {
            if let context = try? await client.send(MCPCancelTask.request(.init(taskId: taskID))) {
                _ = try? await context.value
            }
            await MCPTaskStore.shared.remove(serverID: serverID, id: taskID)
        }
    }

    func readResource(uri: String) async throws -> [MCPContent] { try await client.readResource(uri: uri).map(Self.resourceContent) }
    func subscribe(uri: String) async throws { try await client.subscribeToResource(uri: uri) }
    func unsubscribe(uri: String) async throws {
        let context = try await client.send(NoemaResourceUnsubscribe.request(.init(uri: uri)))
        _ = try await context.value
    }
    func getPrompt(name: String, arguments: [String: String]) async throws -> [MCPContent] {
        let result = try await client.getPrompt(name: name, arguments: arguments)
        return result.messages.map { message in
            let prefix = message.role == .user ? "User" : "Assistant"
            return .text("\(prefix): \(Self.promptContent(message.content))")
        }
    }
    func completePrompt(name: String, argument: String, value: String, context: [String: String]) async throws -> [String] {
        try await client.complete(promptName: name, argumentName: argument, argumentValue: value, context: context).values
    }
    func completeResource(uri: String, argument: String, value: String, context: [String: String]) async throws -> [String] {
        try await client.complete(resourceURI: uri, argumentName: argument, argumentValue: value, context: context).values
    }
    func notifyRootsChanged() async throws { try await client.notifyRootsChanged() }

    private func snapshot(_ result: MCP.Initialize.Result) -> MCPCapabilitySnapshot {
        .init(
            protocolVersion: result.protocolVersion, serverName: result.serverInfo.title ?? result.serverInfo.name,
            serverVersion: result.serverInfo.version, supportsCompletions: result.capabilities.completions != nil,
            supportsResourceSubscriptions: result.capabilities.resources?.subscribe == true,
            supportsLogging: result.capabilities.logging != nil, supportsSampling: policy.allowSampling,
            supportsElicitation: policy.allowElicitation, supportsRoots: true,
            supportsTasks: false
        )
    }

    private func callToolAsTask(
        _ tool: MCPToolDescriptor,
        arguments: [String: MCP.Value],
        invocationID: String
    ) async throws -> MCPToolResultEnvelope {
        let request = MCPTaskCallTool.request(.init(
            name: tool.originalName,
            arguments: arguments,
            _meta: .init(progressToken: .string(invocationID)),
            task: .init(ttl: 300_000)
        ))
        let context = try await client.send(request)
        activeRequests[invocationID] = context.requestID
        defer {
            activeRequests.removeValue(forKey: invocationID)
            activeTasks.removeValue(forKey: invocationID)
        }
        switch try await context.value {
        case .result(let result):
            return Self.envelope(serverID: serverID, toolName: tool.originalName, result: result)
        case .task(let task):
            activeTasks[invocationID] = task.taskId
            return try await awaitTask(task, toolName: tool.originalName, invocationID: invocationID)
        }
    }

    private func awaitTask(
        _ initial: MCPWireTask,
        toolName: String,
        invocationID: String
    ) async throws -> MCPToolResultEnvelope {
        var wire = initial
        while true {
            try Task.checkCancellation()
            let reference = wire.reference(serverID: serverID)
            await MCPTaskStore.shared.upsert(reference)
            await activity(.init(kind: .progress, message: reference.statusMessage ?? "Task \(reference.state.rawValue)"))
            switch reference.state {
            case .completed:
                let result = try await fetchTaskResult(id: wire.taskId, invocationID: invocationID)
                await MCPTaskStore.shared.remove(serverID: serverID, id: wire.taskId)
                return Self.envelope(serverID: serverID, toolName: toolName, result: result, task: reference)
            case .failed:
                throw ToolError.executionFailed(reference.statusMessage ?? String(localized: "The MCP task failed."))
            case .cancelled:
                throw CancellationError()
            case .inputRequired:
                // tasks/result remains pending while any sampling or elicitation
                // request is handled through Noema's visible interaction lane.
                let result = try await fetchTaskResult(id: wire.taskId, invocationID: invocationID)
                await MCPTaskStore.shared.remove(serverID: serverID, id: wire.taskId)
                return Self.envelope(serverID: serverID, toolName: toolName, result: result, task: reference)
            case .working:
                let delay = max(100, min(wire.pollInterval ?? 1_000, 30_000))
                try await Task.sleep(for: .milliseconds(delay))
                let context = try await client.send(MCPGetTask.request(.init(taskId: wire.taskId)))
                activeRequests[invocationID] = context.requestID
                wire = try await context.value
            }
        }
    }

    private func fetchTaskResult(id: String, invocationID: String) async throws -> MCP.CallTool.Result {
        let context = try await client.send(MCPGetTaskResult.request(.init(taskId: id)))
        activeRequests[invocationID] = context.requestID
        return try await context.value
    }

    private func resumePersistedTasks() async {
        let saved = await MCPTaskStore.shared.values(serverID: serverID)
        for task in saved where task.state == .working || task.state == .inputRequired {
            do {
                let context = try await client.send(MCPGetTask.request(.init(taskId: task.id)))
                let current = try await context.value.reference(serverID: serverID)
                await MCPTaskStore.shared.upsert(current)
                await activity(.init(kind: .progress, message: current.statusMessage ?? "Resumed task \(current.id)"))
            } catch {
                await activity(.init(kind: .error, message: "Could not resume task \(task.id): \(error.localizedDescription)"))
            }
        }
    }

    private static func envelope(
        serverID: String,
        toolName: String,
        result: MCP.CallTool.Result,
        task: MCPTaskReference? = nil
    ) -> MCPToolResultEnvelope {
        .init(
            serverID: serverID,
            toolName: toolName,
            content: result.content.map(content),
            structuredContent: result.structuredContent.map(json),
            isError: result.isError ?? false,
            task: task ?? Self.task(from: result._meta)
        )
    }

    private static func mcpValue(_ value: JSONValue) throws -> MCP.Value {
        try JSONDecoder().decode(MCP.Value.self, from: JSONEncoder().encode(value))
    }
    private static func json<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
    }
    private static func content(_ value: MCP.Tool.Content) -> MCPContent {
        switch value {
        case .text(let text, _, _): .text(text)
        case .image(let data, let mimeType, _, _): .image(data: Foundation.Data(base64Encoded: data) ?? Foundation.Data(), mimeType: mimeType)
        case .audio(let data, let mimeType, _, _): .audio(data: Foundation.Data(base64Encoded: data) ?? Foundation.Data(), mimeType: mimeType)
        case .resource(let resource, _, _): resourceContent(resource)
        case .resourceLink(let uri, let name, _, let description, let mimeType, _): .resourceLink(uri: uri, name: name, description: description, mimeType: mimeType)
        }
    }
    private static func resourceContent(_ value: MCP.Resource.Content) -> MCPContent {
        .embeddedResource(uri: value.uri, mimeType: value.mimeType, text: value.text, data: value.blob.flatMap { Foundation.Data(base64Encoded: $0) })
    }
    private static func promptContent(_ value: MCP.Prompt.Message.Content) -> String {
        switch value {
        case .text(let text): text
        case .image(_, let mime): "[Image: \(mime)]"
        case .audio(_, let mime): "[Audio: \(mime)]"
        case .resource(let value, _, _): value.text ?? "Resource: \(value.uri)"
        case .resourceLink(let uri, let name, _, _, _, _): "\(name): \(uri)"
        }
    }
    private static func samplingPrompt(_ parameters: MCP.CreateSamplingMessage.Parameters) -> String {
        var pieces: [String] = []
        if let system = parameters.systemPrompt { pieces.append(system) }
        pieces += parameters.messages.map { "\($0.role.rawValue): \(json($0.content).prettyPrinted)" }
        return pieces.joined(separator: "\n\n")
    }
    private static func task(from metadata: MCP.Metadata?) -> MCPTaskReference? {
        guard let metadata, let raw = json(metadata).objectValue?["task"] else { return nil }
        return try? JSONDecoder().decode(MCPTaskReference.self, from: JSONEncoder().encode(raw))
    }
    private static func redacted(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)(authorization|token|secret|password)\s*[:=]\s*[^\s,}]+"#, with: "$1=[REDACTED]", options: .regularExpression)
    }
}
#endif
