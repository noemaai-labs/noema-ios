import Foundation
import RelayKit
import NoemaPackages

actor RelayServerEngine {
    private struct LoadedClient {
        var client: AnyLLMClient
        var descriptor: RelayModelDescriptor
        var lastUsed: Date
        var evictionTask: Task<Void, Never>?
    }

    private struct ResponseSession {
        var id: UUID
        var modelID: String
        var messages: [ChatMessage]
        var updatedAt: Date
    }

    enum ClientTransport: String, Codable, Sendable {
        case lan
        case cloud
    }

    struct ConnectedClient: Identifiable, Sendable, Equatable {
        var id: String
        var clientIdentifier: String
        var name: String
        var model: String?
        var platform: String?
        var transport: ClientTransport
        var ssid: String?
        var address: String?
        var lastSeen: Date
    }

    struct RequestMetadata {
        var clientAddress: String?
        var origin: String?
        var userAgent: String?
        var clientID: String?
        var clientName: String?
        var clientModel: String?
        var clientPlatform: String?
        var clientSSID: String?
        var transport: ClientTransport?
    }

    struct NormalizedParameters {
        var temperature: Double?
        var topP: Double?
        var topK: Int?
        var maxTokens: Int?
        var stop: [String]
        var presencePenalty: Double?
        var frequencyPenalty: Double?
        var seed: Int?

        init(temperature: Double? = nil,
             topP: Double? = nil,
             topK: Int? = nil,
             maxTokens: Int? = nil,
             stop: [String] = [],
             presencePenalty: Double? = nil,
             frequencyPenalty: Double? = nil,
             seed: Int? = nil) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.maxTokens = maxTokens
            self.stop = stop
            self.presencePenalty = presencePenalty
            self.frequencyPenalty = frequencyPenalty
            self.seed = seed
        }
    }

    struct ChatCompletionRequest {
        var requestID: String
        var modelID: String
        var messages: [ChatMessage]
        var parameters: NormalizedParameters
        var stream: Bool
        var user: String?
        var metadata: RequestMetadata
    }

    struct TextCompletionRequest {
        var requestID: String
        var modelID: String
        var prompt: String
        var parameters: NormalizedParameters
        var stream: Bool
        var user: String?
        var metadata: RequestMetadata
    }

    struct ChatCompletionResult {
        var id: String
        var created: Date
        var modelID: String
        var message: ChatMessage
        var usage: TokenUsage
        var finishReason: String
    }

    struct ModelSnapshot {
        var id: String
        var displayName: String
        var ownedBy: String
        var created: Date
        var isLoaded: Bool
        var contextLength: Int?
        var quant: String?
        var sizeBytes: Int64?
        var provider: RelayProviderKind
        var descriptor: RelayModelDescriptor
    }

    struct TokenUsage {
        var promptTokens: Int
        var completionTokens: Int
        var totalTokens: Int
    }

    enum StreamEvent {
        case delta(String)
        case completion(ChatCompletionResult)
    }

    struct ResponsesRequest {
        var requestID: String
        var modelID: String
        var message: ChatMessage
        var previousResponseID: String?
        var parameters: NormalizedParameters
        var stream: Bool
        var user: String?
        var metadata: RequestMetadata
    }

    struct ResponsesResult {
        var responseID: String
        var chatResult: ChatCompletionResult
        var sessionID: UUID
    }

    private var descriptors: [String: RelayModelDescriptor] = [:]
    private var activeModelID: String?
    private var localClients: [String: LoadedClient] = [:]
    // Models explicitly loaded by the user (manual/pinned). These should not be auto-unloaded
    // by JIT policies or idle TTL timers.
    private var pinnedModelIDs: Set<String> = []
    private var catalogEntries: [String: RelayCatalogEntry] = [:]
    private var config: RelayServerConfiguration = .load()
    private var sessions: [UUID: ResponseSession] = [:]
    private let sessionLimit = 64
    private var connectedClients: [String: ConnectedClient] = [:]
    private let connectedClientExpiry: TimeInterval = 180

    func updateDescriptors(_ descriptors: [RelayModelDescriptor]) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        let validIDs = Set(self.descriptors.keys)
        let staleIDs = localClients.keys.filter { !validIDs.contains($0) }
        for id in staleIDs {
            if let entry = localClients.removeValue(forKey: id) {
                entry.evictionTask?.cancel()
                entry.client.unload()
            }
            pinnedModelIDs.remove(id)
        }
        for (id, descriptor) in self.descriptors {
            if var entry = localClients[id] {
                entry.descriptor = descriptor
                localClients[id] = entry
            }
        }
    }

    func updateCatalogEntries(_ entries: [RelayCatalogEntry]) {
        catalogEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.modelID, $0) })
    }

    func updateActiveModel(_ id: String?) {
        activeModelID = id
    }

    func updateConfiguration(_ config: RelayServerConfiguration) {
        self.config = config
        for (id, var entry) in localClients {
            entry.evictionTask?.cancel()
            entry.evictionTask = scheduleEvictionTimer(for: id)
            localClients[id] = entry
        }
    }

    func registerClient(metadata: RequestMetadata) {
        recordConnectedClient(from: metadata)
    }

    func connectedClientsSnapshot() -> [ConnectedClient] {
        pruneStaleConnectedClients()
        return connectedClients.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    private func recordConnectedClient(from metadata: RequestMetadata) {
        guard let transport = metadata.transport else { return }
        updateConnectedClient(id: metadata.clientID,
                              name: metadata.clientName,
                              model: metadata.clientModel,
                              platform: metadata.clientPlatform,
                              ssid: metadata.clientSSID,
                              transport: transport,
                              address: metadata.clientAddress)
    }

    private func updateConnectedClient(id: String?,
                                       name: String?,
                                       model: String?,
                                       platform: String?,
                                       ssid: String?,
                                       transport: ClientTransport,
                                       address: String?) {
        let identifier = trimmedNonEmpty(id) ?? trimmedNonEmpty(address) ?? UUID().uuidString
        let key = transport.rawValue + ":" + identifier
        var entry = connectedClients[key] ?? ConnectedClient(
            id: key,
            clientIdentifier: identifier,
            name: trimmedNonEmpty(name) ?? defaultClientName(for: transport, address: address),
            model: trimmedNonEmpty(model),
            platform: trimmedNonEmpty(platform),
            transport: transport,
            ssid: trimmedNonEmpty(ssid),
            address: trimmedNonEmpty(address),
            lastSeen: Date()
        )
        entry.lastSeen = Date()
        if let newName = trimmedNonEmpty(name) { entry.name = newName }
        if let newModel = trimmedNonEmpty(model) { entry.model = newModel }
        if let newPlatform = trimmedNonEmpty(platform) { entry.platform = newPlatform }
        if let newSSID = trimmedNonEmpty(ssid) { entry.ssid = newSSID }
        if let addr = trimmedNonEmpty(address) { entry.address = addr }
        connectedClients[key] = entry
        pruneStaleConnectedClients()
    }

    private func pruneStaleConnectedClients() {
        let cutoff = Date().addingTimeInterval(-connectedClientExpiry)
        connectedClients = connectedClients.filter { $0.value.lastSeen >= cutoff }
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private func defaultClientName(for transport: ClientTransport, address: String?) -> String {
        switch transport {
        case .lan:
            if let address = trimmedNonEmpty(address) { return "LAN · \(address)" }
            return "LAN Client"
        case .cloud:
            return "Cloud Relay Client"
        }
    }

    func modelSnapshots() -> [ModelSnapshot] {
        descriptors.values.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }).map { descriptor in
            let isLoaded = localClients[descriptor.id] != nil
            let created = catalogEntries[descriptor.id]?.lastChecked ?? Date()
            return ModelSnapshot(
                id: descriptor.identifier,
                displayName: descriptor.displayName,
                ownedBy: descriptor.provider.displayName,
                created: created,
                isLoaded: isLoaded,
                contextLength: descriptor.context,
                quant: descriptor.quant,
                sizeBytes: descriptor.sizeBytes,
                provider: descriptor.provider,
                descriptor: descriptor
            )
        }
    }

    func unloadAllClients() {
        for entry in localClients.values {
            entry.evictionTask?.cancel()
            Task { await entry.client.unloadAndWait() }
        }
        localClients.removeAll()
        pinnedModelIDs.removeAll()
        stopLoopbackIfIdle()
    }

    enum LoadOrigin { case manual, jit }

    func ensureModelLoaded(_ modelID: String, origin: LoadOrigin = .jit) async throws {
        guard let descriptor = descriptor(for: modelID) else {
            throw InferenceError.notConfigured
        }
        switch descriptor.kind {
        case .local:
            var entry = try await loadLocalClient(for: descriptor, origin: origin)
            entry.lastUsed = Date()
            entry.evictionTask?.cancel()
            // Only schedule eviction for JIT loads when policy allows it; manual loads are pinned
            if origin == .jit {
                entry.evictionTask = scheduleEvictionTimer(for: descriptor.id)
            }
            updateEntry(entry, for: descriptor.id)
            if origin == .manual { pinnedModelIDs.insert(descriptor.id) }
        case .remote:
            RelayLog.record(category: "RelayServerEngine", message: "Remote model \(descriptor.displayName) does not require local load")
        }
    }

    func unloadModel(_ modelID: String, reason: String = "manual unload") async {
        guard let descriptor = descriptor(for: modelID) else { return }
        // Remove manual pin, then evict the client if present
        pinnedModelIDs.remove(descriptor.id)
        await evictLoadedModel(id: descriptor.id, reason: reason)
        stopLoopbackIfIdle()
    }

    func generateReply(for envelope: RelayEnvelope) async throws -> String {
        try await produceReply(for: envelope, onPartial: nil)
    }

    /// Streaming entry point used by the Cloud Relay transport. Behaves like
    /// `generateReply` but invokes `onPartial` with the accumulated text as it
    /// is produced (local models only; remote/catalog responses arrive whole).
    func streamReply(for envelope: RelayEnvelope,
                     onPartial: @Sendable @escaping (String) -> Void) async throws -> String {
        try await produceReply(for: envelope, onPartial: onPartial)
    }

    private func recordCloudClient(from envelope: RelayEnvelope) {
        let cloudMetadata = RequestMetadata(
            clientAddress: nil,
            origin: nil,
            userAgent: nil,
            clientID: envelope.parameters["clientId"],
            clientName: envelope.parameters["clientName"],
            clientModel: envelope.parameters["clientModel"],
            clientPlatform: envelope.parameters["clientPlatform"],
            clientSSID: envelope.parameters["clientSSID"],
            transport: .cloud
        )
        if [cloudMetadata.clientID, cloudMetadata.clientName, cloudMetadata.clientModel, cloudMetadata.clientPlatform, cloudMetadata.clientSSID].contains(where: { trimmedNonEmpty($0) != nil }) {
            recordConnectedClient(from: cloudMetadata)
        }
    }

    private func produceReply(for envelope: RelayEnvelope,
                              onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        recordCloudClient(from: envelope)
        if let action = envelope.parameters["relayAction"], action == "catalog" {
            return try catalogResponseJSON()
        }
        // Honor the model the client selected (sent via parameters["model"]).
        // Fall back to the host's active model only when none was requested or
        // the requested one is unknown.
        let requestedModel = envelope.parameters["model"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor: RelayModelDescriptor
        if let requestedModel, !requestedModel.isEmpty, let resolved = self.descriptor(for: requestedModel) {
            descriptor = resolved
        } else if let id = activeModelID, let resolved = descriptors[id] {
            descriptor = resolved
        } else {
            throw InferenceError.notConfigured
        }
        switch descriptor.kind {
        case .local:
            var entry = try await loadLocalClient(for: descriptor)
            let messages = envelope.messages.map { ChatMessage(role: $0.role, content: $0.text) }
            let input = LLMInput(.messages(messages))
            var accumulated = ""
            let yield: ((String) -> Void)?
            if let onPartial {
                yield = { chunk in
                    accumulated += chunk
                    onPartial(accumulated)
                }
            } else {
                yield = nil
            }
            let (text, _, _) = try await collectText(
                entry: &entry,
                modelID: descriptor.id,
                input: input,
                parameters: NormalizedParameters(),
                yield: yield
            )
            entry.lastUsed = Date()
            updateEntry(entry, for: descriptor.id)
            return text
        case .remote(let backend, let remoteModel):
            let text = try await generateRemoteReply(backend: backend,
                                                     descriptor: descriptor,
                                                     remoteModel: remoteModel,
                                                     envelope: envelope)
            onPartial?(text)
            return text
        }
    }

    func performChat(_ request: ChatCompletionRequest) async throws -> ChatCompletionResult {
        let start = Date()
        guard let descriptor = descriptor(for: request.modelID) else {
            throw InferenceError.notConfigured
        }
        switch descriptor.kind {
        case .local:
            var entry = try await loadLocalClient(for: descriptor)
            if let settings = effectiveSettings(for: descriptor, parameters: request.parameters) {
                applyEnvironmentVariables(from: settings)
            }
            let input = LLMInput(.messages(request.messages))
            let promptTokens = estimateTokens(for: request.messages)
            let (text, finishReason, tokenCount) = try await collectText(
                entry: &entry,
                modelID: descriptor.id,
                input: input,
                parameters: request.parameters,
                yield: nil
            )
            entry.lastUsed = Date()
            entry.evictionTask?.cancel()
            entry.evictionTask = scheduleEvictionTimer(for: descriptor.id)
            updateEntry(entry, for: descriptor.id)

            let completionTokens = max(tokenCount, estimateTokens(for: text))
            let usage = TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
            let result = ChatCompletionResult(
                id: "chatcmpl_\(UUID().uuidString.prefix(8))",
                created: Date(),
                modelID: descriptor.identifier,
                message: ChatMessage(role: "assistant", content: text),
                usage: usage,
                finishReason: finishReason
            )
            let latency = Date().timeIntervalSince(start)
            logRequest(event: "chat",
                       descriptor: descriptor,
                       metadata: request.metadata,
                       requestID: request.requestID,
                       promptTokens: promptTokens,
                       completionTokens: completionTokens,
                       finishReason: finishReason,
                       latency: latency)
            return result
        case .remote(let backend, let remoteModel):
            let messages = request.messages
            let conversationID = UUID()
            let relayMessages = messages.map { message in
                RelayMessage(conversationID: conversationID,
                             role: message.role,
                             text: message.content,
                             fullText: message.content)
            }
            let envelope = RelayEnvelope(
                conversationID: conversationID,
                messages: relayMessages,
                needsResponse: true,
                parameters: [:]
            )
            let text = try await generateRemoteReply(backend: backend,
                                                     descriptor: descriptor,
                                                     remoteModel: remoteModel,
                                                     envelope: envelope)
            let promptTokens = estimateTokens(for: messages)
            let completionTokens = estimateTokens(for: text)
            let usage = TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
            let result = ChatCompletionResult(
                id: "chatcmpl_\(UUID().uuidString.prefix(8))",
                created: Date(),
                modelID: descriptor.identifier,
                message: ChatMessage(role: "assistant", content: text),
                usage: usage,
                finishReason: "stop"
            )
            let latency = Date().timeIntervalSince(start)
            logRequest(event: "remote",
                       descriptor: descriptor,
                       metadata: request.metadata,
                       requestID: request.requestID,
                       promptTokens: promptTokens,
                       completionTokens: completionTokens,
                       finishReason: "stop",
                       latency: latency)
            return result
        }
    }

    func streamChat(_ request: ChatCompletionRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let start = Date()
        guard let descriptor = descriptor(for: request.modelID) else {
            throw InferenceError.notConfigured
        }
        switch descriptor.kind {
        case .local:
            var entry = try await loadLocalClient(for: descriptor)
            if let settings = effectiveSettings(for: descriptor, parameters: request.parameters) {
                applyEnvironmentVariables(from: settings)
            }
            let promptTokens = estimateTokens(for: request.messages)
            let input = LLMInput(.messages(request.messages))
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let (text, finishReason, completionTokens) = try await self.collectText(
                            entry: &entry,
                            modelID: descriptor.id,
                            input: input,
                            parameters: request.parameters,
                            yield: { chunk in
                                continuation.yield(.delta(chunk))
                            }
                        )
                        entry.lastUsed = Date()
                        entry.evictionTask?.cancel()
                        entry.evictionTask = await self.scheduleEvictionTimer(for: descriptor.id)
                        await self.updateAfterStreaming(entry: entry, id: descriptor.id)
                        let completionEstimate = max(completionTokens, self.estimateTokens(for: text))
                        let usage = TokenUsage(
                            promptTokens: promptTokens,
                            completionTokens: completionEstimate,
                            totalTokens: promptTokens + completionEstimate
                        )
                        let result = ChatCompletionResult(
                            id: "chatcmpl_\(UUID().uuidString.prefix(8))",
                            created: Date(),
                            modelID: descriptor.identifier,
                            message: ChatMessage(role: "assistant", content: text),
                            usage: usage,
                            finishReason: finishReason
                        )
                        let latency = Date().timeIntervalSince(start)
                        logRequest(event: "chat-stream",
                                   descriptor: descriptor,
                                   metadata: request.metadata,
                                   requestID: request.requestID,
                                   promptTokens: promptTokens,
                                   completionTokens: completionEstimate,
                                   finishReason: finishReason,
                                   latency: latency)
                        continuation.yield(.completion(result))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        case .remote:
            throw InferenceError.other("Streaming is not available for remote relay models")
        }
    }

    func performTextCompletion(_ request: TextCompletionRequest) async throws -> ChatCompletionResult {
        let message = ChatMessage(role: "user", content: request.prompt)
        let chat = ChatCompletionRequest(
            requestID: request.requestID,
            modelID: request.modelID,
            messages: [message],
            parameters: request.parameters,
            stream: request.stream,
            user: request.user,
            metadata: request.metadata
        )
        return try await performChat(chat)
    }

    func streamTextCompletion(_ request: TextCompletionRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let message = ChatMessage(role: "user", content: request.prompt)
        let chat = ChatCompletionRequest(
            requestID: request.requestID,
            modelID: request.modelID,
            messages: [message],
            parameters: request.parameters,
            stream: request.stream,
            user: request.user,
            metadata: request.metadata
        )
        return try await streamChat(chat)
    }

    func performResponse(_ request: ResponsesRequest) async throws -> ResponsesResult {
        let (sessionID, history) = sessionContext(for: request)
        let chatRequest = ChatCompletionRequest(
            requestID: request.requestID,
            modelID: request.modelID,
            messages: history,
            parameters: request.parameters,
            stream: false,
            user: request.user,
            metadata: request.metadata
        )
        let result = try await performChat(chatRequest)
        persistSession(id: sessionID,
                       modelID: request.modelID,
                       userMessage: request.message,
                       assistantMessage: result.message)
        return ResponsesResult(responseID: sessionID.uuidString,
                               chatResult: result,
                               sessionID: sessionID)
    }

    func streamResponse(_ request: ResponsesRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let (sessionID, history) = sessionContext(for: request)
        let chatRequest = ChatCompletionRequest(
            requestID: request.requestID,
            modelID: request.modelID,
            messages: history,
            parameters: request.parameters,
            stream: true,
            user: request.user,
            metadata: request.metadata
        )
        let baseStream = try await streamChat(chatRequest)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var finalResult: ChatCompletionResult?
                    for try await event in baseStream {
                        switch event {
                        case .delta(let chunk):
                            continuation.yield(.delta(chunk))
                        case .completion(let result):
                            finalResult = result
                            continuation.yield(.completion(result))
                        }
                    }
                    if let finalResult {
                        await self.persistSession(id: sessionID,
                                                  modelID: request.modelID,
                                                  userMessage: request.message,
                                                  assistantMessage: finalResult.message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func catalogResponseJSON() throws -> String {
        let exposedEntries = catalogEntries.values.filter { $0.exposed && $0.health != .error }
        let models = exposedEntries.compactMap { entry -> CatalogModel? in
            guard let descriptor = descriptors[entry.modelID] else { return nil }
            return CatalogModel(
                modelID: entry.modelID,
                identifier: descriptor.identifier,
                displayName: entry.displayName,
                provider: descriptor.provider.rawValue,
                providerDisplayName: descriptor.provider.displayName,
                endpointID: descriptor.endpointID,
                context: descriptor.context,
                quant: descriptor.quant,
                sizeBytes: descriptor.sizeBytes.flatMap { Int($0) },
                tags: descriptor.tags,
                health: entry.health.rawValue,
                recordName: "model-\(entry.modelID)"
            )
        }
        let response = CatalogResponse(models: models)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        guard let string = String(data: data, encoding: .utf8) else {
            throw InferenceError.other("Failed to encode relay catalog response")
        }
        RelayLog.record(
            category: "RelayServerEngine",
            message: "Catalog response contains \(models.count) model(s)",
            suppressConsole: true
        )
        return string
    }

    private struct CatalogResponse: Codable {
        var models: [CatalogModel]
    }

    private struct CatalogModel: Codable {
        var modelID: String
        var identifier: String
        var displayName: String
        var provider: String
        var providerDisplayName: String
        var endpointID: String?
        var context: Int?
        var quant: String?
        var sizeBytes: Int?
        var tags: [String]
        var health: String
        var recordName: String
    }

    private func loadLocalClient(for descriptor: RelayModelDescriptor, origin: LoadOrigin = .jit) async throws -> LoadedClient {
        if var cached = localClients[descriptor.id] {
            cached.lastUsed = Date()
            cached.evictionTask?.cancel()
            // Preserve eviction policy on cache hit: re-arm TTL only for JIT-managed entries
            if origin == .jit && !pinnedModelIDs.contains(descriptor.id) {
                cached.evictionTask = scheduleEvictionTimer(for: descriptor.id)
            } else {
                cached.evictionTask = nil
            }
            // If this model is multimodal and loopback isn’t running, spin it up.
            if needsLoopback(for: cached.descriptor),
               Int(LlamaServerBridge.port()) <= 0 {
                startLoopbackServer(for: cached.descriptor)
            }
            localClients[descriptor.id] = cached
            return cached
        }
        guard case .local(let model) = descriptor.kind else {
            throw InferenceError.notConfigured
        }
        NotificationCenter.default.post(name: .relayWillLoadLocalModel, object: nil)
        applyEnvironmentVariables(from: descriptor.settings)

        let client: AnyLLMClient
        switch model.format {
        case .gguf:
            let context = descriptor.settings.map { settings -> Int in
                let clamped = max(1.0, min(settings.contextLength, Double(Int32.max)))
                return Int(clamped)
            }
            let threads = descriptor.settings.map { settings -> Int in
                let requested = settings.cpuThreads > 0 ? settings.cpuThreads : ModelSettings.recommendedInferenceThreadCount
                // Hard-clamp so inference always leaves a core for the UI, even for
                // older persisted settings that requested every processor.
                return min(max(1, requested), ModelSettings.maxInferenceThreadCount)
            }
            // Pass explicit projector when available so remote worker uses the intended mmproj
            let explicitMMProj = ProjectorLocator.projectorPath(alongside: model.url)
            let hasMergedProjector = GGUFMetadata.hasMultimodalProjector(at: model.url)
            if explicitMMProj != nil || hasMergedProjector {
                startLoopbackServer(for: descriptor, explicitMMProj: explicitMMProj)
            }
            let parameter = LlamaParameter(
                options: LlamaOptions(extraEOSTokens: ["<|im_end|>", "<end_of_turn>"]),
                contextLength: context,
                threadCount: threads,
                mmproj: explicitMMProj
            )
            let llama = try await NoemaLlamaClient.llama(url: model.url, parameter: parameter)
            client = AnyLLMClient(llama)
        case .mlx:
            client = try await MLXBridge.makeTextClient(url: model.url, settings: descriptor.settings)
        case .et:
            throw InferenceError.other("ET models are not supported by relay yet")
        case .ane:
            throw InferenceError.other("Apple Core ML models are not supported by relay")
        case .afm:
            throw InferenceError.other("Apple Foundation Models are not supported by relay")
        case .coreai:
            throw InferenceError.other("Core AI models are not supported by relay")
        }

        var entry = LoadedClient(client: client, descriptor: descriptor, lastUsed: Date(), evictionTask: nil)
        if origin == .jit && !pinnedModelIDs.contains(descriptor.id) {
            entry.evictionTask = scheduleEvictionTimer(for: descriptor.id)
        }
        localClients[descriptor.id] = entry
        if origin == .jit && config.onlyKeepLastJITModel {
            await unloadOtherClients(keeping: descriptor.id)
        }
        return entry
    }

    private func applyEnvironmentVariables(from settings: ModelSettings?) {
        guard let settings else {
            unsetenv("LLAMA_CONTEXT_SIZE")
            unsetenv("LLAMA_CONTEXT_SHIFT")
            unsetenv("LLAMA_N_GPU_LAYERS")
            unsetenv("LLAMA_THREADS")
            unsetenv("LLAMA_THREADS_BATCH")
            unsetenv("LLAMA_KV_OFFLOAD")
            unsetenv("LLAMA_MMAP")
            unsetenv("LLAMA_KEEP")
            unsetenv("LLAMA_WARMUP")
            unsetenv("LLAMA_SEED")
            unsetenv("LLAMA_FLASH_ATTENTION")
            unsetenv("LLAMA_V_QUANT")
            unsetenv("LLAMA_K_QUANT")
            unsetenv("LLAMA_MOE_EXPERTS")
            unsetenv("LLAMA_TOKENIZER_PATH")
            return
        }

        setenv("LLAMA_CONTEXT_SIZE", String(Int(settings.contextLength)), 1)
        // Relay serves remote clients: always allow context shifting so their
        // long generations keep going, regardless of the local chat strategy
        // (the env is process-global and ChatVM may have set it to 0).
        setenv("LLAMA_CONTEXT_SHIFT", "1", 1)

        let supportsOffload = DeviceGPUInfo.supportsGPUOffload
        let gpuLayers: Int
        if !supportsOffload {
            gpuLayers = 0
        } else if settings.gpuLayers < 0 {
            gpuLayers = 1_000_000
        } else {
            gpuLayers = settings.gpuLayers
        }
        setenv("LLAMA_N_GPU_LAYERS", String(gpuLayers), 1)

        let threads = settings.cpuThreads > 0 ? settings.cpuThreads : ModelSettings.recommendedInferenceThreadCount
        // Hard-clamp so inference always leaves a core free for the UI.
        let clampedThreads = min(max(1, threads), ModelSettings.maxInferenceThreadCount)
        setenv("LLAMA_THREADS", String(clampedThreads), 1)
        setenv("LLAMA_THREADS_BATCH", String(clampedThreads), 1)
        // Backward-compat: a few builds key off GGML_* env vars
        setenv("GGML_NUM_THREADS", String(clampedThreads), 1)
        setenv("GGML_NUM_THREADS_BATCH", String(clampedThreads), 1)

        let kvOffload = supportsOffload && gpuLayers > 0 && settings.kvCacheOffload
        setenv("LLAMA_KV_OFFLOAD", kvOffload ? "1" : "0", 1)
        setenv("LLAMA_MMAP", settings.useMmap ? "1" : "0", 1)
        setenv("LLAMA_KEEP", settings.keepInMemory ? "1" : "0", 1)
        if settings.disableWarmup {
            setenv("LLAMA_WARMUP", "0", 1)
        } else {
            unsetenv("LLAMA_WARMUP")
        }

        if let seed = settings.seed {
            setenv("LLAMA_SEED", String(seed), 1)
        } else {
            unsetenv("LLAMA_SEED")
        }

        if settings.flashAttention {
            setenv("LLAMA_FLASH_ATTENTION", "1", 1)
            setenv("LLAMA_V_QUANT", settings.vCacheQuant.rawValue, 1)
        } else {
            unsetenv("LLAMA_FLASH_ATTENTION")
            unsetenv("LLAMA_V_QUANT")
        }

        setenv("LLAMA_K_QUANT", settings.kCacheQuant.rawValue, 1)

        if let tokenizer = settings.tokenizerPath, !tokenizer.isEmpty {
            setenv("LLAMA_TOKENIZER_PATH", tokenizer, 1)
        } else {
            unsetenv("LLAMA_TOKENIZER_PATH")
        }

        if let experts = settings.moeActiveExperts, experts > 0 {
            setenv("LLAMA_MOE_EXPERTS", String(experts), 1)
        } else {
            unsetenv("LLAMA_MOE_EXPERTS")
        }
    }

    private func generateRemoteReply(backend: RemoteBackend,
                                     descriptor: RelayModelDescriptor,
                                     remoteModel: RemoteModel,
                                     envelope: RelayEnvelope) async throws -> String {
        guard let url = backend.chatEndpointURL else {
            throw InferenceError.notConfigured
        }
        switch backend.endpointType {
        case .ollama:
            return try await callOllama(url: url, backend: backend, modelID: descriptor.identifier, envelope: envelope)
        case .lmStudio, .openAI:
            return try await callOpenAIStyle(url: url, backend: backend, modelID: descriptor.identifier, envelope: envelope)
        default:
            throw InferenceError.other("Relay does not support \(backend.endpointType.displayName) endpoints yet")
        }
    }

    private func callOpenAIStyle(url: URL,
                                 backend: RemoteBackend,
                                 modelID: String,
                                 envelope: RelayEnvelope) async throws -> String {
        var body: [String: Any] = [
            "model": modelID,
            "messages": envelope.messages.map { ["role": $0.role, "content": $0.text] },
            "stream": false
        ]
        if let temperatureString = envelope.parameters["temperature"],
           let temperature = Double(temperatureString) {
            body["temperature"] = temperature
        }
        if let topPString = envelope.parameters["top_p"], let topP = Double(topPString) {
            body["top_p"] = topP
        }
        if let topKString = envelope.parameters["top_k"], let topK = Int(topKString) {
            body["top_k"] = topK
        }
        if let stopString = envelope.parameters["stop"], !stopString.isEmpty {
            body["stop"] = stopString.split(separator: ",").map(String.init)
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = backend.authHeader, !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InferenceError.network("Invalid response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: responseData, encoding: .utf8) ?? ""
            throw InferenceError.network("HTTP \(http.statusCode) \(message)")
        }
        struct ChoiceMessage: Decodable {
            let content: String?
        }
        struct Choice: Decodable {
            let message: ChoiceMessage?
            let text: String?
        }
        struct ChatResponse: Decodable {
            let choices: [Choice]
        }
        if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: responseData) {
            if let content = decoded.choices.first?.message?.content, !content.isEmpty {
                return content
            }
            if let text = decoded.choices.first?.text, !text.isEmpty {
                return text
            }
        }
        if let fallback = String(data: responseData, encoding: .utf8), !fallback.isEmpty {
            return fallback
        }
        throw InferenceError.other("Remote server returned an empty response")
    }

    private func callOllama(url: URL,
                            backend: RemoteBackend,
                            modelID: String,
                            envelope: RelayEnvelope) async throws -> String {
        let messages = envelope.messages.map { ["role": $0.role, "content": $0.text] }
        var body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "stream": false
        ]
        var ollamaOptions: [String: Any] = [:]
        if let temperatureString = envelope.parameters["temperature"],
           let temperature = Double(temperatureString) {
            ollamaOptions["temperature"] = temperature
        }
        if let topPString = envelope.parameters["top_p"], let topP = Double(topPString) {
            ollamaOptions["top_p"] = topP
        }
        if let topKString = envelope.parameters["top_k"], let topK = Int(topKString) {
            ollamaOptions["top_k"] = topK
        }
        if let stopString = envelope.parameters["stop"], !stopString.isEmpty {
            ollamaOptions["stop"] = stopString.split(separator: ",").map(String.init)
        }
        if !ollamaOptions.isEmpty {
            body["options"] = ollamaOptions
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = backend.authHeader, !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InferenceError.network("Invalid response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: responseData, encoding: .utf8) ?? ""
            throw InferenceError.network("HTTP \(http.statusCode) \(message)")
        }
        struct OllamaMessage: Decodable {
            let content: String?
        }
        struct OllamaResponse: Decodable {
            let message: OllamaMessage?
            let response: String?
        }
        if let decoded = try? JSONDecoder().decode(OllamaResponse.self, from: responseData) {
            if let content = decoded.message?.content, !content.isEmpty {
                return content
            }
            if let response = decoded.response, !response.isEmpty {
                return response
            }
        }
        if let fallback = String(data: responseData, encoding: .utf8), !fallback.isEmpty {
            return fallback
        }
        throw InferenceError.other("Ollama returned an empty response")
    }

    private func descriptor(for modelID: String) -> RelayModelDescriptor? {
        if let descriptor = descriptors[modelID] { return descriptor }
        return descriptors.values.first { candidate in
            candidate.identifier == modelID || candidate.displayName == modelID
        }
    }

    private func effectiveSettings(for descriptor: RelayModelDescriptor,
                                   parameters: NormalizedParameters) -> ModelSettings? {
        guard case .local(let model) = descriptor.kind else { return nil }
        var settings = descriptor.settings ?? ModelSettings.default(for: model.format)
        if let temperature = parameters.temperature {
            settings.temperature = temperature
        }
        if let topP = parameters.topP {
            settings.topP = max(0.0, min(topP, 1.0))
        }
        if let topK = parameters.topK {
            settings.topK = max(1, topK)
        }
        if let presence = parameters.presencePenalty {
            settings.presencePenalty = Float(presence)
        }
        if let frequency = parameters.frequencyPenalty {
            settings.frequencyPenalty = Float(frequency)
        }
        if let seed = parameters.seed {
            settings.seed = seed
        }
        return settings
    }

    private func promptString(for messages: [ChatMessage]) -> String {
        messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
    }

    private func estimateTokens(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let charEstimate = max(1, trimmed.count / 4)
        let wordEstimate = max(1, trimmed.split { $0.isWhitespace || $0.isNewline }.count * 3 / 2)
        return max(charEstimate, wordEstimate)
    }

    private func estimateTokens(for messages: [ChatMessage]) -> Int {
        estimateTokens(for: promptString(for: messages))
    }

    private func updateEntry(_ entry: LoadedClient, for id: String) {
        localClients[id] = entry
    }

    private func sessionContext(for request: ResponsesRequest) -> (UUID, [ChatMessage]) {
        if let prev = request.previousResponseID,
           let id = UUID(uuidString: prev),
           let session = sessions[id],
           session.modelID == request.modelID {
            var history = session.messages
            history.append(request.message)
            return (id, history)
        }
        let newID = UUID()
        return (newID, [request.message])
    }

    private func persistSession(id: UUID,
                                modelID: String,
                                userMessage: ChatMessage,
                                assistantMessage: ChatMessage) {
        var session = sessions[id] ?? ResponseSession(id: id, modelID: modelID, messages: [], updatedAt: Date())
        session.modelID = modelID
        session.messages.append(userMessage)
        session.messages.append(assistantMessage)
        session.updatedAt = Date()
        sessions[id] = session
        trimSessionsIfNeeded()
    }

    private func trimSessionsIfNeeded() {
        guard sessions.count > sessionLimit else { return }
        let excess = sessions.count - sessionLimit
        let sorted = sessions.values.sorted { $0.updatedAt < $1.updatedAt }
        for session in sorted.prefix(excess) {
            sessions.removeValue(forKey: session.id)
        }
    }

    private func collectText(entry: inout LoadedClient,
                              modelID: String,
                              input: LLMInput,
                              parameters: NormalizedParameters,
                              yield: ((String) -> Void)?) async throws -> (String, String, Int) {
        // Serialize generations per model: a single llama.cpp context is not
        // safe to drive from two concurrent requests. Other models (and all
        // non-generation actor work) remain free while one request generates.
        await acquireGenerationSlot(modelID)
        defer { releaseGenerationSlot(modelID) }

        let stream = try await entry.client.textStream(from: input)
        var buffer = ""
        var finishReason = "stop"
        var tokenCount = 0
        let stopSequences = parameters.stop
        let maxTokens = parameters.maxTokens
        var shouldCancel = false

        do {
            for try await chunk in stream {
                tokenCount += 1
                buffer.append(chunk)
                yield?(chunk)
                if let match = stopSequences.first(where: { buffer.hasSuffix($0) }) {
                    buffer.removeLast(match.count)
                    finishReason = "stop"
                    shouldCancel = true
                    break
                }
                if let maxTokens, maxTokens > 0, tokenCount >= maxTokens {
                    finishReason = "length"
                    shouldCancel = true
                    break
                }
            }
        } catch is CancellationError {
            shouldCancel = true
            finishReason = "cancelled"
        }

        if shouldCancel {
            entry.client.cancelActive()
        }

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, finishReason, tokenCount)
    }

    // MARK: - Per-model generation serialization

    private var busyModels: Set<String> = []
    private var generationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var pendingEvictions: [String: String] = [:]

    private func acquireGenerationSlot(_ id: String) async {
        if !busyModels.contains(id) {
            busyModels.insert(id)
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            generationWaiters[id, default: []].append(cont)
        }
    }

    private func releaseGenerationSlot(_ id: String) {
        if var waiters = generationWaiters[id], !waiters.isEmpty {
            let next = waiters.removeFirst()
            generationWaiters[id] = waiters.isEmpty ? nil : waiters
            // The resumed waiter inherits the busy slot; keep busyModels set.
            next.resume()
            return
        }
        busyModels.remove(id)
        if let reason = pendingEvictions.removeValue(forKey: id) {
            Task { await self.evictLoadedModel(id: id, reason: reason) }
        }
    }

    private func isModelBusy(_ id: String) -> Bool {
        busyModels.contains(id)
    }

    private func updateAfterStreaming(entry: LoadedClient, id: String) {
        updateEntry(entry, for: id)
    }

    private func scheduleEvictionTimer(for id: String) -> Task<Void, Never>? {
        guard config.justInTimeLoading, config.autoUnloadJIT else { return nil }
        // Never schedule TTL for pinned/manual models
        if pinnedModelIDs.contains(id) { return nil }
        let ttl = config.idleTTL
        guard ttl > 0 else { return nil }
        return Task { [id, ttl] in
            do {
                let nanos = UInt64(ttl * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }
            await self.evictLoadedModel(id: id, reason: "Idle TTL reached after \(Int(ttl))s")
        }
    }

    private func evictLoadedModel(id: String, reason: String) async {
        // Never pull a model out from under an active generation. Defer the
        // eviction; releaseGenerationSlot() will retry once the model is idle.
        if isModelBusy(id) {
            pendingEvictions[id] = reason
            RelayLog.record(category: "RelayServerEngine",
                            message: "Deferring eviction of \(id) until active generation completes (\(reason))",
                            suppressConsole: true)
            return
        }
        guard let entry = localClients.removeValue(forKey: id) else { return }
        entry.evictionTask?.cancel()
        await entry.client.unloadAndWait()
        RelayLog.record(category: "RelayServerEngine", message: "Evicted model \(entry.descriptor.displayName) – \(reason)")
        stopLoopbackIfIdle()
    }

    private func unloadOtherClients(keeping keepID: String) {
        // Unload only non-pinned (JIT) models; preserve manually loaded models
        // and any model currently servicing a request.
        let otherIDs = localClients.keys.filter { $0 != keepID && !pinnedModelIDs.contains($0) }
        for id in otherIDs {
            if isModelBusy(id) {
                pendingEvictions[id] = "JIT policy (deferred: model busy)"
                continue
            }
            if let entry = localClients.removeValue(forKey: id) {
                entry.evictionTask?.cancel()
                Task { await entry.client.unloadAndWait() }
                RelayLog.record(category: "RelayServerEngine", message: "Unloaded model \(entry.descriptor.displayName) to honour JIT policy")
            }
        }
        stopLoopbackIfIdle()
    }

    private func needsLoopback(for descriptor: RelayModelDescriptor) -> Bool {
        // Tag-based heuristic plus file inspection for GGUF
        let tagHasVision = descriptor.tags.contains { $0.caseInsensitiveCompare("multimodal") == .orderedSame }
        guard case .local(let model) = descriptor.kind else { return false }
        if model.format != .gguf { return tagHasVision }
        let hasMergedProjector = GGUFMetadata.hasMultimodalProjector(at: model.url)
        let explicitMMProj = ProjectorLocator.projectorPath(alongside: model.url)
        return tagHasVision || hasMergedProjector || explicitMMProj != nil
    }

    private func startLoopbackServer(for descriptor: RelayModelDescriptor, explicitMMProj: String? = nil) {
        guard case .local(let model) = descriptor.kind else { return }
        guard needsLoopback(for: descriptor) else { return }
        LlamaServerBridge.stop()
        let resolvedMMProj = explicitMMProj ?? ProjectorLocator.projectorPath(alongside: model.url)
        let port = LlamaServerBridge.start(
            TemplateDrivenModelSupport.loopbackStartConfiguration(
                modelID: model.modelID,
                modelURL: model.url,
                ggufPath: model.url.path,
                mmprojPath: resolvedMMProj
            )
        )
        if port > 0 {
            let projName = resolvedMMProj.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? (GGUFMetadata.hasMultimodalProjector(at: model.url) ? "merged" : "none")
            let templateLabel = TemplateDrivenModelSupport.templateLabel(modelID: model.modelID, modelURL: model.url)
            RelayLog.record(category: "RelayServerEngine",
                            message: "Loopback vision server started on 127.0.0.1:\(port) (\(projName)) template=\(templateLabel)",
                            suppressConsole: true)
        } else {
            RelayLog.record(category: "RelayServerEngine",
                            message: "Loopback vision server failed to start for \(descriptor.displayName)",
                            suppressConsole: true)
        }
    }

    private func stopLoopbackIfIdle() {
        if localClients.isEmpty {
            LlamaServerBridge.stop()
        }
    }

    private func logRequest(event: String,
                            descriptor: RelayModelDescriptor,
                            metadata: RequestMetadata,
                            requestID: String,
                            promptTokens: Int,
                            completionTokens: Int,
                            finishReason: String,
                            latency: TimeInterval) {
        let client = metadata.clientAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientLabel = client?.isEmpty == false ? client! : "unknown"
        var parts: [String] = []
        parts.append("event=\(event)")
        parts.append("req=\(requestID.prefix(8))")
        parts.append("client=\(clientLabel)")
        if let origin = metadata.origin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty {
            parts.append("origin=\(origin)")
        }
        parts.append("model=\(descriptor.displayName)")
        parts.append("prompt≈\(promptTokens)")
        parts.append("completion≈\(completionTokens)")
        parts.append("finish=\(finishReason)")
        parts.append(String(format: "latency=%.2fs", latency))
        RelayLog.record(category: "RelayServerEngine", message: parts.joined(separator: " "))
    }
}
