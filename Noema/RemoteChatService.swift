import Foundation
import RelayKit
#if os(iOS) || os(visionOS)
#if canImport(NetworkExtension)
import NetworkExtension
#endif
#if canImport(SystemConfiguration)
import SystemConfiguration.CaptiveNetwork
#endif
#if canImport(UIKit)
import UIKit
#endif
#endif

actor RemoteChatService {
    struct RequestOptions {
        var stops: [String] = []
        var temperature: Double?
        var contextLength: Double?
        var topP: Double?
        var topK: Int?
        var minP: Double?
        var repeatPenalty: Double?
        var includeTools: Bool = false
    }

    private enum EndpointKind { case chat, completion }

    enum RemoteChatError: Error, LocalizedError {
        case invalidEndpoint
        case invalidResponse
        case httpError(Int, String)
        case missingModelIdentifier

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Could not build the remote chat endpoint URL."
            case .invalidResponse:
                return "Remote server returned an unexpected response."
            case .httpError(let code, let body):
                if body.isEmpty { return "Remote server responded with status code \(code)." }
                return "Remote server responded with status code \(code): \(body)"
            case .missingModelIdentifier:
                return "No remote model identifier provided."
            }
        }
    }

    private struct ToolCallAccumulator {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    private struct ToolCallChunk: Decodable {
        struct FunctionFragment: Decodable {
            let name: String?
            let arguments: String?

            enum CodingKeys: String, CodingKey {
                case name
                case arguments
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decodeIfPresent(String.self, forKey: .name)
                if let string = try container.decodeIfPresent(String.self, forKey: .arguments) {
                    arguments = string
                } else if let map = try? container.decode([String: AnyCodable].self, forKey: .arguments) {
                    let jsonObject = map.mapValues { $0.value }
                    if JSONSerialization.isValidJSONObject(jsonObject),
                       let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
                       let jsonString = String(data: data, encoding: .utf8) {
                        arguments = jsonString
                    } else {
                        arguments = nil
                    }
                } else if let any = try? container.decode(AnyCodable.self, forKey: .arguments) {
                    let value = any.value
                    if let json = value as? [Any], JSONSerialization.isValidJSONObject(json),
                       let data = try? JSONSerialization.data(withJSONObject: json, options: []),
                       let jsonString = String(data: data, encoding: .utf8) {
                        arguments = jsonString
                    } else if let json = value as? [String: Any], JSONSerialization.isValidJSONObject(json),
                              let data = try? JSONSerialization.data(withJSONObject: json, options: []),
                              let jsonString = String(data: data, encoding: .utf8) {
                        arguments = jsonString
                    } else {
                        arguments = nil
                    }
                } else {
                    arguments = nil
                }
            }
        }

        let index: Int?
        let id: String?
        let type: String?
        let function: FunctionFragment?

        enum CodingKeys: String, CodingKey {
            case index
            case id
            case type
            case function
        }
    }

    private struct FunctionCallChunk: Decodable {
        let name: String?
        let arguments: String?

        enum CodingKeys: String, CodingKey {
            case name
            case arguments
        }
    }

    private struct ChatChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let role: String?
                let content: String?
                // OpenRouter streams chain-of-thought as `reasoning`;
                // DeepSeek-style providers use `reasoning_content`.
                let reasoning: String?
                let reasoningContent: String?
                let toolCalls: [ToolCallChunk]?
                let functionCall: FunctionCallChunk?
            }

            struct Message: Decodable {
                let role: String?
                let content: String?
                let reasoning: String?
                let reasoningContent: String?
                let toolCalls: [ToolCallChunk]?
                let functionCall: FunctionCallChunk?
            }

            let index: Int?
            let delta: Delta?
            let message: Message?
            let text: String?
            let completion: String?
            let finishReason: String?
        }

        let choices: [Choice]
    }

    private struct OllamaChatChunk: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
            let toolCalls: [ToolCallChunk]?
        }

        let model: String?
        let createdAt: String?
        let message: Message?
        let done: Bool?
        let doneReason: String?
    }

    private var backend: RemoteBackend
    private var modelID: String
    private var toolSpecs: [ToolSpec]
    private var options = RequestOptions()
    private var cancellationHandler: (id: UUID, cancel: @Sendable () -> Void)?
    private let decoder: JSONDecoder
    private var bufferedToolTokens: [String] = []
#if os(iOS) || os(visionOS)
    private let relayOutbox = RelayOutbox()
    private var relayFullHistory: [(role: String, text: String)]?
    private let clientIdentity = RemoteChatService.makeClientIdentity()
    private var lanMonitorTask: Task<Void, Never>?
    private var lanRefreshHandler: (@Sendable () async -> RemoteBackend?)?
    private var lanLastMatchedSSID: String?
    private var lanLastRefresh: Date?
    private var lanLastObservedLocalSSID: String?
    private var lanManualOverride = false
    private static let lanRefreshMinimumInterval: TimeInterval = 30
#endif
    private var relayContainerID: String?
    private var conversationID: UUID?
    private var transportObserver: (@Sendable (RemoteSessionTransport, Bool) async -> Void)?

    init(backend: RemoteBackend, modelID: String, toolSpecs: [ToolSpec]) {
        self.backend = backend
        self.modelID = modelID
        self.toolSpecs = toolSpecs
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    deinit {
#if os(iOS) || os(visionOS)
        lanMonitorTask?.cancel()
#endif
    }

    func updateBackend(_ backend: RemoteBackend) {
        self.backend = backend
#if os(iOS) || os(visionOS)
        if backend.endpointType != .noemaRelay {
            cancelLANMonitor()
        } else if lanRefreshHandler != nil {
            startLANMonitor()
        }
#endif
    }

    func updateModelID(_ id: String) {
        self.modelID = id
    }

    func updateToolSpecs(_ specs: [ToolSpec]) {
        self.toolSpecs = specs
    }

    func updateOptions(
        stops: [String],
        temperature: Double?,
        contextLength: Double?,
        topP: Double?,
        topK: Int?,
        minP: Double?,
        repeatPenalty: Double?,
        includeTools: Bool
    ) {
        options = RequestOptions(
            stops: stops,
            temperature: temperature,
            contextLength: contextLength,
            topP: topP,
            topK: topK,
            minP: minP,
            repeatPenalty: repeatPenalty,
            includeTools: includeTools
        )
    }

#if os(iOS) || os(visionOS)
    // Exposed preflight to adopt LAN before first message.
    // Refreshes metadata and computes an immediate LAN match if possible.
    func preflightLANAdoption() async -> String? {
        await refreshRelayMetadata(reason: "activate-session-preflight", allowThrottle: false)
        return await currentLANMatch()
    }

    func updateRelayFullHistory(_ history: [(role: String, text: String)]) {
        relayFullHistory = history
    }

    func setLANRefreshHandler(_ handler: (@Sendable () async -> RemoteBackend?)?) {
        lanRefreshHandler = handler
        if handler == nil {
            cancelLANMonitor()
        } else {
            startLANMonitor()
            Task {
                await refreshRelayMetadata(reason: "handler-installed", allowThrottle: false)
            }
        }
    }
#endif

    func updateRelayContainerID(_ identifier: String?) {
        relayContainerID = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateConversationID(_ id: UUID?) {
        conversationID = id
    }

    func setTransportObserver(_ observer: (@Sendable (RemoteSessionTransport, Bool) async -> Void)?) {
        transportObserver = observer
    }

    func cancelActiveStream() {
        let handler = cancellationHandler
        cancellationHandler = nil
        handler?.cancel()
    }

    func stream(for input: LLMInput) -> AsyncThrowingStream<String, Error> {
        let streamID = UUID()
        let taskBox = LockIsolated<Task<Void, Never>?>(nil)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                await self.performStream(for: input, continuation: continuation)
                await self.clearCancellationHandler(streamID: streamID)
            }
            taskBox.withMutableValue { $0 = task }
            continuation.onTermination = { _ in
                taskBox.withValue { $0?.cancel() }
                Task { await self.clearCancellationHandler(streamID: streamID) }
            }
        }
        // This actor remains occupied until `stream(for:)` returns, so the child task
        // cannot finish and clear its handler before registration completes.
        cancellationHandler = (
            id: streamID,
            cancel: { taskBox.withValue { $0?.cancel() } }
        )
        return stream
    }

    private func clearCancellationHandler(streamID: UUID) {
        guard cancellationHandler?.id == streamID else { return }
        cancellationHandler = nil
    }

    private func relayParameters() -> [String: String] {
        var params: [String: String] = [:]
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            params["model"] = trimmedModel
        }
        params["backend"] = backend.endpointType.rawValue
        params["backendName"] = backend.name
        if let temperature = options.temperature {
            params["temperature"] = String(temperature)
        }
        if let topP = options.topP {
            params["top_p"] = String(topP)
        }
        if let topK = options.topK {
            params["top_k"] = String(topK)
        }
        if !options.stops.isEmpty {
            params["stop"] = options.stops.joined(separator: ",")
        }
        return params
    }

#if os(iOS) || os(visionOS)
    private func startLANMonitor() {
        guard lanMonitorTask == nil,
              lanRefreshHandler != nil,
              backend.endpointType == .noemaRelay else { return }
        Task {
            await logger.log("[RemoteChat] [LAN] Starting LAN monitor for backend '\(backend.name)' (handler installed: \(lanRefreshHandler != nil))")
        }
        lanLastRefresh = nil
        lanLastObservedLocalSSID = nil
        lanMonitorTask = Task { [weak self] in
            await self?.refreshRelayMetadata(reason: "monitor-start", allowThrottle: false)
            await self?.lanMonitorIteration()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await self?.lanMonitorIteration()
            }
        }
    }

    private func cancelLANMonitor() {
        lanMonitorTask?.cancel()
        lanMonitorTask = nil
        lanLastMatchedSSID = nil
        lanLastObservedLocalSSID = nil
        Task {
            await logger.log("[RemoteChat] [LAN] Cancelled LAN monitor for backend '\(backend.name)'")
        }
    }

    private func lanMonitorIteration() async {
        guard backend.endpointType == .noemaRelay else {
            cancelLANMonitor()
            return
        }

        let now = Date()
        let localSSIDRaw = await WiFiSSIDProvider.shared.currentSSID()
        let localSSID = sanitizedSSID(localSSIDRaw)

        if lanLastObservedLocalSSID != localSSID {
            let previous = lanLastObservedLocalSSID ?? "nil"
            let current = localSSID ?? "nil"
            lanLastObservedLocalSSID = localSSID
            await logger.log("[RemoteChat] [LAN] Local Wi-Fi changed for '\(backend.name)' (previous=\(previous), current=\(current))")
            await refreshRelayMetadata(reason: "local-wifi-change", allowThrottle: false)
        }

        let metadataMissing = backend.relayLANChatEndpointURL == nil || backend.relayAuthorizationHeader == nil
        let expectedSSID = sanitizedSSID(backend.relayWiFiSSID)

        await logger.log(
            "[RemoteChat] [LAN] Monitor tick for '\(backend.name)': localSSID=\(localSSID ?? "nil"), expectedSSID=\(expectedSSID ?? "nil"), hasLANURL=\(backend.relayLANChatEndpointURL != nil), metadataMissing=\(metadataMissing)"
        )

        if lanLastRefresh == nil,
           metadataMissing,
           shouldAllowLANRefresh(at: now) {
            await refreshRelayMetadata(reason: "monitor-initial", allowThrottle: false)
        }

        let matchedSSID = await matchedLANSSID(localSSID: localSSID)

        if let matchedSSID {
            if lanLastMatchedSSID != matchedSSID {
                lanLastMatchedSSID = matchedSSID
                await logger.log("[RemoteChat] [LAN] Matched LAN for '\(backend.name)' using SSID token '\(matchedSSID.isEmpty ? "<unknown>" : matchedSSID)'")
                await notifyTransport(.lan(ssid: matchedSSID), streaming: false)
                if lanManualOverride {
                    lanManualOverride = false
                    await logger.log("[RemoteChat] [LAN] Manual override cleared after successful LAN match for '\(backend.name)'")
                }
            }
        } else if lanLastMatchedSSID != nil {
            await logger.log("[RemoteChat] [LAN] Lost LAN match for '\(backend.name)'; reverting to Cloud Relay")
            lanLastMatchedSSID = nil
            await notifyTransport(.cloudRelay, streaming: false)
        }
    }

    private func shouldAllowLANRefresh(at now: Date) -> Bool {
        guard let last = lanLastRefresh else { return true }
        return now.timeIntervalSince(last) >= Self.lanRefreshMinimumInterval
    }

    func forceLANRefresh(reason: String) async {
        guard backend.endpointType == .noemaRelay else { return }
        await logger.log("[RemoteChat] [LAN] Forcing LAN monitor iteration (\(reason)) for '\(backend.name)'")
        if lanMonitorTask == nil {
            startLANMonitor()
        }
        await refreshRelayMetadata(reason: "force-\(reason)", allowThrottle: false)
        await lanMonitorIteration()
    }

    func setLANManualOverride(_ enabled: Bool, reason: String) async {
        guard backend.endpointType == .noemaRelay else { return }
        lanManualOverride = enabled
        await logger.log("[RemoteChat] [LAN] Manual override \(enabled ? "enabled" : "disabled") (\(reason)) for '\(backend.name)'")
        if enabled {
            await forceLANRefresh(reason: "manual-override")
        }
    }

    private func refreshRelayMetadata(reason: String, allowThrottle: Bool) async {
        guard backend.endpointType == .noemaRelay else { return }
        guard let handler = lanRefreshHandler else { return }
        let now = Date()
        if allowThrottle, let last = lanLastRefresh, now.timeIntervalSince(last) < Self.lanRefreshMinimumInterval {
            await logger.log("[RemoteChat] [LAN] Skipping Cloud Relay metadata refresh (\(reason)) for '\(backend.name)' (throttled)")
            return
        }
        await logger.log("[RemoteChat] [LAN] Requesting Cloud Relay metadata refresh (\(reason)) for '\(backend.name)'")
        if let updated = await handler() {
            self.backend = updated
        }
        lanLastRefresh = now
        let lanURL = backend.relayLANChatEndpointURL?.absoluteString ?? "nil"
        let hostSSID = sanitizedSSID(backend.relayWiFiSSID) ?? "nil"
        await logger.log("[RemoteChat] [LAN] Metadata received (\(reason)) for '\(backend.name)': hostSSID=\(hostSSID), lanURL=\(lanURL)")

#if os(iOS) || os(visionOS)
        // If we still don't have a LAN endpoint (e.g., CloudKit timed out or
        // SSID is unavailable), try Bonjour discovery as a local fallback so
        // we can switch transports immediately.
        if backend.relayLANChatEndpointURL == nil {
            if let url = await LANServiceDiscovery.shared.discoverNoemaLANURL(timeout: 2.5) {
                var adopted = backend
                adopted.relayLANURLString = url
                self.backend = adopted
                await logger.log("[RemoteChat] [LAN] Bonjour fallback discovered \(url) for '\(backend.name)'")
            }
        }
#endif
    }

    private func sanitizedSSID(_ ssid: String?) -> String? {
        guard let value = ssid?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private struct ClientIdentity {
        let id: String
        let name: String
        let model: String
        let platform: String
    }

    private static func makeClientIdentity() -> ClientIdentity {
#if canImport(UIKit)
        let device = UIDevice.current
        let name = device.name
        let model = device.model
        let idiom = device.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionLabel = "\(idiom) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let provider = SystemTimeProvider()
        let identifier = provider.currentIDFV() ?? UUID().uuidString
        return ClientIdentity(id: identifier, name: name, model: model, platform: versionLabel)
#else
        return ClientIdentity(id: UUID().uuidString, name: "Noema Device", model: "Unknown", platform: "iOS")
#endif
    }
#endif

#if os(iOS) || os(visionOS)
    private func performRelayStream(
        for input: LLMInput,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        await logger.log("[RemoteChat] [Cloud] Performing Cloud Relay request for '\(backend.name)' model '\(modelID)'")
        await notifyTransport(.cloudRelay, streaming: false)
        do {
            guard !NetworkKillSwitch.isEnabled else {
                throw URLError(.notConnectedToInternet)
            }
            guard let containerID = relayContainerID, !containerID.isEmpty else {
                throw InferenceError.notConfigured
            }
            guard let conversationID else {
                throw InferenceError.other("Missing conversation identifier for relay")
            }
            let history = relayHistory(from: input)
            var parameters = relayParameters()
            if backend.endpointType == .noemaRelay {
                parameters["transport"] = "cloud"
                parameters["clientId"] = clientIdentity.id
                parameters["clientName"] = clientIdentity.name
                parameters["clientModel"] = clientIdentity.model
                parameters["clientPlatform"] = clientIdentity.platform
                if let rawSSID = await WiFiSSIDProvider.shared.currentSSID(),
                   let ssid = sanitizedSSID(rawSSID) {
                    parameters["clientSSID"] = ssid
                }
            }
            _ = try await relayOutbox.sendAndStreamReply(
                containerID: containerID,
                conversationID: conversationID,
                history: history,
                parameters: parameters,
                onDelta: { delta in
                    _ = continuation.yield(delta)
                }
            )
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func relayHistory(from input: LLMInput) -> [(role: String, text: String, fullText: String?)] {
        let sanitizedEntries: [(role: String, text: String)]
        switch input.content {
        case .messages(let messages):
            sanitizedEntries = messages.map { ($0.role, $0.content) }
        case .plain(let text):
            sanitizedEntries = [(role: "user", text: text)]
        case .multimodal(let text, let paths):
            if !paths.isEmpty {
                Task { await logger.log("[RemoteChat] [Images] Cloud Relay transport can't carry images; sending text only.") }
            }
            sanitizedEntries = [(role: "user", text: text)]
        case .multimodalMessages(let messages, let paths):
            if !paths.isEmpty {
                Task { await logger.log("[RemoteChat] [Images] Cloud Relay transport can't carry images; sending text only.") }
            }
            sanitizedEntries = messages.map { ($0.role, $0.content) }
        }
#if os(iOS) || os(visionOS)
        let rawEntries = relayFullHistory
        relayFullHistory = nil
#else
        let rawEntries: [(role: String, text: String)]? = nil
#endif
        guard let rawEntries, rawEntries.count == sanitizedEntries.count else {
            return sanitizedEntries.map { ($0.role, $0.text, $0.text) }
        }
        return zip(sanitizedEntries, rawEntries).map { sanitized, raw in
            (sanitized.role, sanitized.text, raw.text)
        }
    }

    private func matchedLANSSID() async -> String? {
        let localRaw = await WiFiSSIDProvider.shared.currentSSID()
        let localSSID = sanitizedSSID(localRaw)
        return await matchedLANSSID(localSSID: localSSID)
    }

    private func matchedLANSSID(localSSID: String?) async -> String? {
        guard backend.endpointType == .noemaRelay else { return nil }
        guard backend.relayLANChatEndpointURL != nil else { return nil }

        if lanManualOverride {
            if await isLANHostReachable() {
                let overrideSSID = sanitizedSSID(backend.relayWiFiSSID)
                await logger.log("[RemoteChat] [LAN] Manual override using LAN endpoint for '\(backend.name)' (reportedSSID=\(overrideSSID ?? "<unknown>"))")
                if let overrideSSID { return overrideSSID }
                if let localSSID { return localSSID }
                // Do not surface transport medium (Ethernet/Wi‑Fi) as a label
                return ""
            } else {
                await logger.log("[RemoteChat] [LAN] Manual override requested for '\(backend.name)' but LAN host is unreachable")
                return nil
            }
        }

        if let expectedSSID = sanitizedSSID(backend.relayWiFiSSID),
           let localSSID,
           LANSubnet.ssidsMatch(expectedSSID, localSSID) {
            await logger.log("[RemoteChat] [LAN] SSID match for '\(backend.name)' (expected=\(expectedSSID), local=\(localSSID))")
            return localSSID
        }

        // If the host is on Ethernet (no SSID) but we share the same subnet,
        // treat it as a LAN match.
        if sanitizedSSID(backend.relayWiFiSSID) == nil,
           let host = backend.relayLANChatEndpointURL?.host,
           LANSubnet.isSameSubnet(host: host) {
            await logger.log("[RemoteChat] [LAN] Same-subnet match for '\(backend.name)' (host=\(host)); using LAN")
            if let localSSID { return localSSID }
            // Do not surface transport medium (Ethernet/Wi‑Fi) as a label
            return ""
        }

        // No Wi-Fi means no local network — skip the reachability probe that
        // wastes ~7 seconds going through iCloud Private Relay on cellular.
        if localSSID == nil { return nil }

        guard await isLANHostReachable() else { return nil }
        await logger.log("[RemoteChat] [LAN] Reachability probe succeeded for '\(backend.name)' (SSID unavailable, using empty token)")
        if let localSSID { return localSSID }
        // Do not surface transport medium (Ethernet/Wi‑Fi) as a label
        return ""
    }

    private func currentLANMatch() async -> String? {
        let localRaw = await WiFiSSIDProvider.shared.currentSSID()
        let localSSID = sanitizedSSID(localRaw)
        return await matchedLANSSID(localSSID: localSSID)
    }

    private func isLANHostReachable() async -> Bool {
        guard backend.endpointType == .noemaRelay else { return false }
        // Prefer a lightweight unauthenticated health check first.
        if let healthURL = backend.relayLANHealthEndpointURL {
            var req = URLRequest(url: healthURL)
            req.httpMethod = "GET"
            req.timeoutInterval = 3
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 3
            cfg.timeoutIntervalForResource = 3
            cfg.waitsForConnectivity = false
            let session = URLSession(configuration: cfg)
            NetworkKillSwitch.track(session: session)
            defer { session.invalidateAndCancel() }
            await logger.log("[RemoteChat] [LAN] Health probe → \(healthURL.absoluteString) for '\(backend.name)'")
            do {
                guard !NetworkKillSwitch.shouldBlock(request: req) else { return false }
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    return true
                }
            } catch { /* fall through to chat HEAD */ }
        }

        guard let url = backend.relayLANChatEndpointURL else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = backend.relayAuthorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        defer { session.invalidateAndCancel() }
        let hostDescription = url.absoluteString
        await logger.log("[RemoteChat] [LAN] HEAD probe → \(hostDescription) for '\(backend.name)'")
        do {
            guard !NetworkKillSwitch.shouldBlock(request: request) else { return false }
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<400, 401, 403, 405:
                    return true
                default:
                    await logger.log("[RemoteChat] [LAN] HEAD probe failed with status #\(http.statusCode) for '\(backend.name)'; treating as unreachable")
                    return false
                }
            }
        } catch {
            if let urlError = error as? URLError,
               urlError.code == .badServerResponse || urlError.code == .cannotDecodeRawData {
                return true
            }
        }
        return false
    }
#endif

    private func currentEndpointKind() -> EndpointKind {
        let rawPath: String
        if let url = backend.chatEndpointURL {
            rawPath = url.path.lowercased()
        } else {
            rawPath = backend.normalizedChatPath.lowercased()
        }
        if rawPath.contains("/chat/") || rawPath.hasSuffix("/chat") {
            return .chat
        }
        return .completion
    }

    private func performStream(for input: LLMInput, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        bufferedToolTokens.removeAll(keepingCapacity: false)

#if os(iOS) || os(visionOS)
        var usedLANTransport = false
        var lanTransportSSID: String?
        var receivedLANPayload = false
#endif

        do {
            let prompt = input.prompt
            let imagePaths = Self.imagePaths(from: input)
            let structuredMessages = Self.structuredMessages(from: input)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continuation.finish()
                return
            }

#if os(iOS) || os(visionOS)
            if backend.endpointType == .noemaRelay {
                if lanLastRefresh == nil {
                    await refreshRelayMetadata(reason: "stream-preflight", allowThrottle: false)
                }
                if let matchedSSID = await currentLANMatch() {
                    lanTransportSSID = matchedSSID
                    cancelLANMonitor()
                } else {
                    await logger.log("[RemoteChat] [Cloud] No LAN match available for '\(backend.name)' – streaming via Cloud Relay")
                    startLANMonitor()
                    await notifyTransport(.cloudRelay, streaming: false)
                    await performRelayStream(for: input, continuation: continuation)
                    return
                }
            } else if backend.endpointType == .cloudRelay {
                await logger.log("[RemoteChat] [Cloud] Backend '\(backend.name)' configured for Cloud Relay; streaming via CloudKit")
                await notifyTransport(.cloudRelay, streaming: false)
                await performRelayStream(for: input, continuation: continuation)
                return
            }
#endif
            if backend.endpointType == .ollama {
                await notifyTransport(.direct, streaming: true)
                try await performOllamaStream(prompt: prompt, imagePaths: imagePaths, continuation: continuation)
                return
            }

#if os(iOS) || os(visionOS)
            var kind: EndpointKind
            var request: URLRequest
            if backend.endpointType == .noemaRelay {
                guard let matchedSSID = lanTransportSSID else {
                    throw RemoteChatError.invalidEndpoint
                }
                kind = .chat
                Task {
                    let ssidLabel = matchedSSID.isEmpty ? "<unknown>" : matchedSSID
                    await logger.log("[RemoteChat] [LAN] Switching transport from Cloud Relay to direct LAN for '\(backend.name)' (SSID \(ssidLabel))")
                }
                request = try buildRelayLANRequest(prompt: prompt, matchedSSID: matchedSSID, imagePaths: imagePaths)
                usedLANTransport = true
                await notifyTransport(.lan(ssid: matchedSSID), streaming: true)
                Task {
                    await logger.log("[RemoteChat] Using LAN transport for \(backend.name) (SSID \(matchedSSID))")
                }
            } else {
                kind = currentEndpointKind()
                request = try buildRequest(
                    prompt: prompt,
                    kind: kind,
                    imagePaths: imagePaths,
                    structuredMessages: structuredMessages
                )
                await notifyTransport(.direct, streaming: true)
            }
#else
            let kind = currentEndpointKind()
            let request = try buildRequest(
                prompt: prompt,
                kind: kind,
                imagePaths: imagePaths,
                structuredMessages: structuredMessages
            )
            await notifyTransport(.direct, streaming: true)
#endif
            let isLMStudioNativeV1Stream = backend.endpointType == .lmStudio
                && (request.url?.path.lowercased().contains("/api/v1/chat") ?? false)
            guard !NetworkKillSwitch.shouldBlock(request: request) else {
                throw URLError(.notConnectedToInternet)
            }
            NetworkKillSwitch.track(session: URLSession.shared)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw RemoteChatError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                var buffer = Data()
                var iterator = bytes.makeAsyncIterator()
                while let byte = try await iterator.next() {
                    buffer.append(byte)
                    if buffer.count >= 4096 { break }
                }
                let body = String(data: buffer, encoding: .utf8) ?? ""
                throw RemoteChatError.httpError(http.statusCode, body)
            }

            let isChat = kind == .chat
            var accumulators: [String: ToolCallAccumulator] = [:]
            var lastEmittedToolJSON: [String: String] = [:]
            var responseItemIndex: [String: String] = [:]
            var responseOutputActiveKey: [Int: String] = [:]
            var nextResponseAccumulatorID = 0
            var sawToolCallFinish = false
            var activeLMStudioToolKey: String?
            var streamedLMStudioMessageDelta = false
            var streamedLMStudioReasoningDelta = false
            var lmStudioReasoningOpen = false
            var sawValidPayload = false

            func closeReasoningStreamIfNeeded() {
                guard lmStudioReasoningOpen else { return }
                lmStudioReasoningOpen = false
                continuation.yield("</think>")
            }

            func registerItemID(_ id: String?, key: String) {
                guard let id, !id.isEmpty else { return }
                responseItemIndex[id] = key
            }

            func emitToolCallUpdate(
                for key: String,
                force: Bool = false,
                requestStatus: String = "requesting",
                error: String? = nil
            ) {
                guard let accumulator = accumulators[key],
                      let jsonString = makeToolCallJSON(
                        from: accumulator,
                        fallbackToolCallID: key,
                        requestStatus: requestStatus,
                        error: error
                      ) else { return }
                if !force, lastEmittedToolJSON[key] == jsonString { return }
                lastEmittedToolJSON[key] = jsonString
                logToolCallPayload(jsonString)
                // Native tool calls are outside the reasoning channel. Close it
                // before ChatVM cancels this stream for tool execution, otherwise
                // the next continuation's <think> nests inside the prior block.
                closeReasoningStreamIfNeeded()
                let token = "TOOL_CALL: \(jsonString)"
                let result = continuation.yield(token)
                switch result {
                case .enqueued:
                    break
                case .dropped, .terminated:
                    bufferedToolTokens.append(token)
                @unknown default:
                    bufferedToolTokens.append(token)
                }
            }

            func callKey(forIndex index: Int) -> String {
                "idx:\(index)"
            }

            func newResponseAccumulatorKey() -> String {
                defer { nextResponseAccumulatorID += 1 }
                return "response:\(nextResponseAccumulatorID)"
            }

            func updateAccumulator(_ call: ToolCallChunk, fallbackIndex: Int, replaceArguments: Bool) {
                let idx = call.index ?? fallbackIndex
                let key = callKey(forIndex: idx)
                var accumulator = accumulators[key, default: ToolCallAccumulator()]
                registerItemID(call.id, key: key)
                if let id = call.id, !id.isEmpty { accumulator.id = id }
                if let name = call.function?.name, !name.isEmpty { accumulator.name = name }
                if let fragment = call.function?.arguments, !fragment.isEmpty {
                    if replaceArguments {
                        accumulator.arguments = fragment
                    } else {
                        accumulator.arguments.append(fragment)
                    }
                }
                accumulators[key] = accumulator
                emitToolCallUpdate(
                    for: key,
                    force: replaceArguments,
                    requestStatus: replaceArguments ? "ready" : "requesting"
                )
            }

            func updateFunctionAccumulator(_ call: FunctionCallChunk, replaceArguments: Bool) {
                let key = callKey(forIndex: 0)
                var accumulator = accumulators[key, default: ToolCallAccumulator()]
                if let name = call.name, !name.isEmpty { accumulator.name = name }
                if let fragment = call.arguments, !fragment.isEmpty {
                    if replaceArguments {
                        accumulator.arguments = fragment
                    } else {
                        accumulator.arguments.append(fragment)
                    }
                }
                accumulators[key] = accumulator
                emitToolCallUpdate(
                    for: key,
                    force: replaceArguments,
                    requestStatus: replaceArguments ? "ready" : "requesting"
                )
            }

            func intFromAny(_ value: Any?) -> Int? {
                if let int = value as? Int { return int }
                if let double = value as? Double { return Int(double) }
                if let string = value as? String, let int = Int(string) { return int }
                return nil
            }

            func stringFromJSONValue(_ value: Any) -> String? {
                if let string = value as? String { return string }
                if JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                   let string = String(data: data, encoding: .utf8) {
                    return string
                }
                return nil
            }

            func stringFromDeltaValue(_ value: Any) -> String? {
                if let string = value as? String { return string }
                if let dict = value as? [String: Any] {
                    if let text = dict["text"] as? String { return text }
                    if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
                       let string = String(data: data, encoding: .utf8) {
                        return string
                    }
                }
                return nil
            }

            func handleResponseEvent(_ event: [String: Any]) -> Error? {
                guard let type = event["type"] as? String else { return nil }
                switch type {
                case "response.output_text.delta":
                    if let deltaValue = event["delta"],
                       let text = stringFromDeltaValue(deltaValue),
                       !text.isEmpty {
                        closeReasoningStreamIfNeeded()
                        continuation.yield(text)
                    }
                case "response.output_item.added":
                    guard let item = event["item"] as? [String: Any],
                          let itemType = item["type"] as? String else { break }
                    let defaultIndex = intFromAny(event["output_index"]) ?? 0
                    if itemType == "function_call" {
                        let existingKey: String? = {
                            if let id = item["id"] as? String, let key = responseItemIndex[id] { return key }
                            if let callID = item["call_id"] as? String, let key = responseItemIndex[callID] { return key }
                            return nil
                        }()
                        let key = existingKey ?? newResponseAccumulatorKey()
                        registerItemID(item["id"] as? String, key: key)
                        registerItemID(item["call_id"] as? String, key: key)
                        responseOutputActiveKey[defaultIndex] = key
                        var accumulator = accumulators[key, default: ToolCallAccumulator()]
                        if let id = item["id"] as? String, !id.isEmpty {
                            accumulator.id = id
                        } else if let callID = item["call_id"] as? String, !callID.isEmpty {
                            accumulator.id = callID
                        }
                        if let name = item["name"] as? String, !name.isEmpty { accumulator.name = name }
                        if let argumentsValue = item["arguments"],
                           let arguments = stringFromJSONValue(argumentsValue) {
                            accumulator.arguments = arguments
                        }
                        accumulators[key] = accumulator
                        emitToolCallUpdate(for: key, force: true, requestStatus: "requesting")
                    }
                case "response.function_call_arguments.delta":
                    let defaultIndex = intFromAny(event["output_index"]) ?? 0
                    let key: String = {
                        if let itemID = event["item_id"] as? String,
                           let mapped = responseItemIndex[itemID] {
                            return mapped
                        }
                        if let mapped = responseOutputActiveKey[defaultIndex] {
                            return mapped
                        }
                        let newKey = newResponseAccumulatorKey()
                        responseOutputActiveKey[defaultIndex] = newKey
                        return newKey
                    }()
                    registerItemID(event["item_id"] as? String, key: key)
                    var accumulator = accumulators[key, default: ToolCallAccumulator()]
                    if let itemID = event["item_id"] as? String, !itemID.isEmpty,
                       accumulator.id == nil {
                        accumulator.id = itemID
                    }
                    if let deltaValue = event["delta"],
                       let fragment = stringFromDeltaValue(deltaValue),
                       !fragment.isEmpty {
                        accumulator.arguments.append(fragment)
                    }
                    accumulators[key] = accumulator
                    emitToolCallUpdate(for: key, requestStatus: "requesting")
                case "response.function_call_arguments.done":
                    let defaultIndex = intFromAny(event["output_index"]) ?? 0
                    let key: String = {
                        if let itemID = event["item_id"] as? String,
                           let mapped = responseItemIndex[itemID] {
                            return mapped
                        }
                        if let mapped = responseOutputActiveKey[defaultIndex] {
                            return mapped
                        }
                        let newKey = newResponseAccumulatorKey()
                        responseOutputActiveKey[defaultIndex] = newKey
                        return newKey
                    }()
                    registerItemID(event["item_id"] as? String, key: key)
                    var accumulator = accumulators[key, default: ToolCallAccumulator()]
                    if let itemID = event["item_id"] as? String, !itemID.isEmpty,
                       accumulator.id == nil {
                        accumulator.id = itemID
                    }
                    if let argumentsValue = event["arguments"],
                       let arguments = stringFromJSONValue(argumentsValue) {
                        accumulator.arguments = arguments
                    }
                    accumulators[key] = accumulator
                    emitToolCallUpdate(for: key, force: true, requestStatus: "ready")
                    sawToolCallFinish = true
                case "response.completed":
                    sawToolCallFinish = sawToolCallFinish || !accumulators.isEmpty
                case "response.error":
                    if let errorDict = event["error"] as? [String: Any] {
                        let message = errorDict["message"] as? String ?? "Remote server error"
                        let codeValue = errorDict["code"]
                        let code: Int = {
                            if let int = codeValue as? Int { return int }
                            if let string = codeValue as? String, let parsed = Int(string) { return parsed }
                            return -1
                        }()
                        return RemoteChatError.httpError(code, message)
                    }
                default:
                    break
                }
                return nil
            }

            func handleLMStudioStreamEvent(_ event: [String: Any]) -> Error? {
                guard let type = event["type"] as? String else { return nil }
                switch type {
                case "reasoning.start":
                    if !lmStudioReasoningOpen {
                        lmStudioReasoningOpen = true
                        continuation.yield("<think>")
                    }
                case "reasoning.delta":
                    if let content = (event["content"] as? String) ?? (event["delta"] as? String),
                       !content.isEmpty {
                        streamedLMStudioReasoningDelta = true
                        if !lmStudioReasoningOpen {
                            lmStudioReasoningOpen = true
                            continuation.yield("<think>")
                        }
                        continuation.yield(content)
                    }
                case "reasoning.end":
                    if lmStudioReasoningOpen {
                        lmStudioReasoningOpen = false
                        continuation.yield("</think>")
                    }
                case "message.delta":
                    if let content = (event["content"] as? String) ?? (event["delta"] as? String),
                       !content.isEmpty {
                        streamedLMStudioMessageDelta = true
                        closeReasoningStreamIfNeeded()
                        continuation.yield(content)
                    }
                case "tool_call.start":
                    let key = activeLMStudioToolKey ?? newResponseAccumulatorKey()
                    activeLMStudioToolKey = key
                    var accumulator = accumulators[key, default: ToolCallAccumulator()]
                    if let toolName = event["tool"] as? String, !toolName.isEmpty {
                        accumulator.name = toolName
                    }
                    if let toolID = event["tool_call_id"] as? String, !toolID.isEmpty {
                        accumulator.id = toolID
                    }
                    accumulators[key] = accumulator
                    emitToolCallUpdate(for: key, force: true, requestStatus: "requesting")
                case "tool_call.arguments":
                    let key = activeLMStudioToolKey ?? newResponseAccumulatorKey()
                    activeLMStudioToolKey = key
                    var accumulator = accumulators[key, default: ToolCallAccumulator()]
                    if let toolName = event["tool"] as? String, !toolName.isEmpty {
                        accumulator.name = toolName
                    }
                    if let argumentsValue = event["arguments"],
                       let arguments = stringFromJSONValue(argumentsValue) {
                        accumulator.arguments = arguments
                    }
                    accumulators[key] = accumulator
                    emitToolCallUpdate(for: key, force: true, requestStatus: "requesting")
                case "tool_call.success":
                    let key = activeLMStudioToolKey ?? newResponseAccumulatorKey()
                    activeLMStudioToolKey = key
                    var accumulator = accumulators[key, default: ToolCallAccumulator()]
                    if let toolName = event["tool"] as? String, !toolName.isEmpty {
                        accumulator.name = toolName
                    }
                    if let argumentsValue = event["arguments"],
                       let arguments = stringFromJSONValue(argumentsValue) {
                        accumulator.arguments = arguments
                    }
                    accumulators[key] = accumulator
                    emitToolCallUpdate(for: key, force: true, requestStatus: "ready")
                    sawToolCallFinish = true
                case "tool_call.failure":
                    let key = activeLMStudioToolKey ?? newResponseAccumulatorKey()
                    activeLMStudioToolKey = key
                    var accumulator = accumulators[key, default: ToolCallAccumulator()]
                    if let toolName = event["tool"] as? String, !toolName.isEmpty {
                        accumulator.name = toolName
                    }
                    if let toolID = event["tool_call_id"] as? String, !toolID.isEmpty {
                        accumulator.id = toolID
                    }
                    accumulators[key] = accumulator
                    let reason = (event["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    emitToolCallUpdate(
                        for: key,
                        force: true,
                        requestStatus: "failed",
                        error: (reason?.isEmpty == false) ? reason : "Tool call failed"
                    )
                    if let reason, !reason.isEmpty {
                        Task {
                            await logger.log("[RemoteChat] [LMStudio] Tool call failure: \(reason)")
                        }
                    }
                case "error":
                    if let errorDict = event["error"] as? [String: Any] {
                        let message = (errorDict["message"] as? String) ?? "Remote server error"
                        let codeValue = errorDict["code"]
                        let code: Int = {
                            if let int = codeValue as? Int { return int }
                            if let string = codeValue as? String, let parsed = Int(string) { return parsed }
                            return -1
                        }()
                        return RemoteChatError.httpError(code, message)
                    }
                case "chat.end":
                    if let result = event["result"] as? [String: Any],
                       let output = result["output"] as? [[String: Any]] {
                        for item in output {
                            guard let itemType = item["type"] as? String else { continue }
                            if itemType == "message" {
                                if !streamedLMStudioMessageDelta,
                                   let content = item["content"] as? String,
                                   !content.isEmpty {
                                    closeReasoningStreamIfNeeded()
                                    continuation.yield(content)
                                }
                            } else if itemType == "reasoning" {
                                if !streamedLMStudioReasoningDelta,
                                   let content = item["content"] as? String,
                                   !content.isEmpty {
                                    if !lmStudioReasoningOpen {
                                        lmStudioReasoningOpen = true
                                        continuation.yield("<think>")
                                    }
                                    continuation.yield(content)
                                }
                            } else if itemType == "tool_call" {
                                let key = activeLMStudioToolKey ?? newResponseAccumulatorKey()
                                activeLMStudioToolKey = key
                                var accumulator = accumulators[key, default: ToolCallAccumulator()]
                                if let toolName = item["tool"] as? String, !toolName.isEmpty {
                                    accumulator.name = toolName
                                }
                                if let argumentsValue = item["arguments"],
                                   let arguments = stringFromJSONValue(argumentsValue) {
                                    accumulator.arguments = arguments
                                }
                                accumulators[key] = accumulator
                                emitToolCallUpdate(for: key, force: true)
                                sawToolCallFinish = true
                            }
                        }
                    }
                default:
                    break
                }
                return nil
            }

            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8) else { continue }
                if let streamError = Self.openRouterStreamError(from: data) {
                    throw streamError
                }
                if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = jsonObject["type"] as? String,
                   type.hasPrefix("response.") {
                    sawValidPayload = true
#if os(iOS) || os(visionOS)
                    if usedLANTransport { receivedLANPayload = true }
#endif
                    if let error = handleResponseEvent(jsonObject) {
                        throw error
                    }
                    continue
                }
                if isLMStudioNativeV1Stream,
                   let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = jsonObject["type"] as? String {
                    let lmStudioPrefixes = [
                        "chat.", "model_load.", "prompt_processing.",
                        "reasoning.", "tool_call.", "message.", "error"
                    ]
                    if lmStudioPrefixes.contains(where: { type.hasPrefix($0) }) {
                        sawValidPayload = true
#if os(iOS) || os(visionOS)
                        if usedLANTransport { receivedLANPayload = true }
#endif
                        if let error = handleLMStudioStreamEvent(jsonObject) {
                            throw error
                        }
                        continue
                    }
                }
                let chunk: ChatChunk
                do {
                    chunk = try decoder.decode(ChatChunk.self, from: data)
                } catch {
                    // A chunk that doesn't match our schema is skipped (providers send
                    // keep-alives, role-only deltas, and vendor-specific events), but log
                    // it so genuinely malformed/truncated streams are diagnosable instead
                    // of silently disappearing.
                    let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                    await logger.log("[RemoteChatService] skipped undecodable stream chunk: \(error.localizedDescription) — \(preview)")
                    continue
                }
                sawValidPayload = true
#if os(iOS) || os(visionOS)
                if usedLANTransport { receivedLANPayload = true }
#endif

                for choice in chunk.choices {
                    if let delta = choice.delta {
                        // Bridge streamed chain-of-thought into the same
                        // <think> stream local models use, reusing the shared
                        // open/close state (closed at content start and at
                        // stream end below).
                        let reasoningDelta = (delta.reasoning ?? "") + (delta.reasoningContent ?? "")
                        if isChat, !reasoningDelta.isEmpty {
                            if !lmStudioReasoningOpen {
                                lmStudioReasoningOpen = true
                                continuation.yield("<think>")
                            }
                            continuation.yield(reasoningDelta)
                        }
                        if let content = delta.content, !content.isEmpty {
                            closeReasoningStreamIfNeeded()
                            continuation.yield(content)
                        }
                        if isChat, let toolCalls = delta.toolCalls, !toolCalls.isEmpty {
                            for call in toolCalls {
                                let fallback = call.index ?? 0
                                updateAccumulator(call, fallbackIndex: fallback, replaceArguments: false)
                            }
                        }
                        if isChat, let fnCall = delta.functionCall {
                            updateFunctionAccumulator(fnCall, replaceArguments: false)
                        }
                    }
                    if isChat, let messageToolCalls = choice.message?.toolCalls, !messageToolCalls.isEmpty {
                        for (relativeIndex, call) in messageToolCalls.enumerated() {
                            updateAccumulator(call, fallbackIndex: call.index ?? relativeIndex, replaceArguments: true)
                        }
                        sawToolCallFinish = true
                    }
                    if isChat, let messageFnCall = choice.message?.functionCall {
                        updateFunctionAccumulator(messageFnCall, replaceArguments: true)
                        sawToolCallFinish = true
                    }
                    if !isChat {
                        if let text = choice.text, !text.isEmpty {
                            continuation.yield(text)
                        }
                        if let completion = choice.completion, !completion.isEmpty {
                            continuation.yield(completion)
                        }
                        if let messageContent = choice.message?.content, !messageContent.isEmpty {
                            continuation.yield(messageContent)
                        }
                    }
                    if isChat, let reason = choice.finishReason {
                        if reason == "tool_calls" || reason == "function_call" {
                            sawToolCallFinish = true
                        }
                    }
                }
            }

            guard sawValidPayload else {
                throw RemoteChatError.invalidResponse
            }

            closeReasoningStreamIfNeeded()

            if isChat && (sawToolCallFinish || !accumulators.isEmpty) {
                for (key, _) in accumulators.sorted(by: { $0.key < $1.key }) {
                    emitToolCallUpdate(for: key, force: true, requestStatus: "ready")
                }
            }

            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
#if os(iOS) || os(visionOS)
            if usedLANTransport && !receivedLANPayload {
                let ssidDescription = lanTransportSSID ?? "unknown SSID"
                Task {
                    await logger.log("[RemoteChat] ⚠️ LAN transport failed for \(backend.name) on \(ssidDescription): \(error.localizedDescription). Falling back to Cloud Relay.")
                }
                startLANMonitor()
                await notifyTransport(.cloudRelay, streaming: false)
                await performRelayStream(for: input, continuation: continuation)
                return
            }
#endif
            continuation.finish(throwing: error)
        }
    }

    private func performOllamaStream(prompt: String, imagePaths: [String] = [], continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        bufferedToolTokens.removeAll(keepingCapacity: false)

        let request = try buildOllamaRequest(prompt: prompt, imagePaths: imagePaths)
        guard !NetworkKillSwitch.shouldBlock(request: request) else {
            throw URLError(.notConnectedToInternet)
        }
        NetworkKillSwitch.track(session: URLSession.shared)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw RemoteChatError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            var buffer = Data()
            var iterator = bytes.makeAsyncIterator()
            while let byte = try await iterator.next() {
                buffer.append(byte)
                if buffer.count >= 4096 { break }
            }
            let body = String(data: buffer, encoding: .utf8) ?? ""
            throw RemoteChatError.httpError(http.statusCode, body)
        }

        var accumulators: [Int: ToolCallAccumulator] = [:]
        var lastEmittedToolJSON: [Int: String] = [:]
        var sawValidPayload = false

        func emitToolCallUpdate(
            for index: Int,
            force: Bool = false,
            requestStatus: String = "requesting",
            error: String? = nil
        ) {
            guard let accumulator = accumulators[index],
                  let jsonString = makeToolCallJSON(
                    from: accumulator,
                    fallbackToolCallID: "ollama:\(index)",
                    requestStatus: requestStatus,
                    error: error
                  ) else { return }
            if !force, lastEmittedToolJSON[index] == jsonString { return }
            lastEmittedToolJSON[index] = jsonString
            logToolCallPayload(jsonString)
            let token = "TOOL_CALL: \(jsonString)"
            let result = continuation.yield(token)
            switch result {
            case .enqueued:
                break
            case .dropped, .terminated:
                bufferedToolTokens.append(token)
            @unknown default:
                bufferedToolTokens.append(token)
            }
        }

        func updateAccumulator(_ call: ToolCallChunk, fallbackIndex: Int, replaceArguments: Bool) {
            let idx = call.index ?? fallbackIndex
            var accumulator = accumulators[idx, default: ToolCallAccumulator()]
            if let id = call.id, !id.isEmpty { accumulator.id = id }
            if let name = call.function?.name, !name.isEmpty { accumulator.name = name }
                if let fragment = call.function?.arguments, !fragment.isEmpty {
                    if replaceArguments {
                        accumulator.arguments = fragment
                    } else {
                        accumulator.arguments.append(fragment)
                }
                }
                accumulators[idx] = accumulator
            emitToolCallUpdate(
                for: idx,
                force: replaceArguments,
                requestStatus: replaceArguments ? "ready" : "requesting"
            )
        }

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            let chunk: OllamaChatChunk
            do {
                chunk = try decoder.decode(OllamaChatChunk.self, from: data)
            } catch {
                continue
            }
            sawValidPayload = true

            if let content = chunk.message?.content, !content.isEmpty {
                continuation.yield(content)
            }

            if let toolCalls = chunk.message?.toolCalls, !toolCalls.isEmpty {
                for (index, call) in toolCalls.enumerated() {
                    updateAccumulator(call, fallbackIndex: call.index ?? index, replaceArguments: true)
                }
            }

            if chunk.done == true {
                break
            }
        }

        guard sawValidPayload else {
            throw RemoteChatError.invalidResponse
        }

        if !accumulators.isEmpty {
            for (index, _) in accumulators.sorted(by: { $0.key < $1.key }) {
                emitToolCallUpdate(for: index, force: true, requestStatus: "ready")
            }
        }

        continuation.finish()
    }

#if os(iOS) || os(visionOS)
    private func buildRelayLANRequest(prompt: String, matchedSSID: String, imagePaths: [String] = []) throws -> URLRequest {
        guard let url = backend.relayLANChatEndpointURL else {
            throw RemoteChatError.invalidEndpoint
        }

        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelValue: String = {
            if !trimmedModel.isEmpty { return trimmedModel }
            if let fallback = backend.customModelIDs.first { return fallback }
            return trimmedModel
        }()
        guard !modelValue.isEmpty else {
            throw RemoteChatError.missingModelIdentifier
        }

        // The relay host's own HTTP server rejects image content parts with
        // 400 ("Images are not supported by Noema Relay endpoints"), which
        // would silently degrade the turn to CloudKit relay — text only here.
        if !imagePaths.isEmpty {
            Task { await logger.log("[RemoteChat] [Images] Noema Relay LAN endpoint can't accept image parts; sending text only.") }
        }
        var body: [String: Any] = [
            "model": modelValue,
            "stream": true,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ]

        if !options.stops.isEmpty {
            body["stop"] = options.stops
        }
        if let temperature = options.temperature {
            body["temperature"] = temperature
        }
        if options.includeTools && !toolSpecs.isEmpty {
            body["tools"] = try toolsPayload(from: toolSpecs)
            body["tool_choice"] = "auto"
        }

        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = backend.relayAuthorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.setValue(clientIdentity.id, forHTTPHeaderField: "X-Noema-Client-ID")
        request.setValue(clientIdentity.name, forHTTPHeaderField: "X-Noema-Client-Name")
        request.setValue(clientIdentity.model, forHTTPHeaderField: "X-Noema-Client-Model")
        request.setValue(clientIdentity.platform, forHTTPHeaderField: "X-Noema-Client-Platform")
        request.setValue("lan", forHTTPHeaderField: "X-Noema-Transport")
        if !matchedSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(matchedSSID, forHTTPHeaderField: "X-Noema-Client-SSID")
        }
        if let hostID = backend.relayHostDeviceID {
            request.setValue(hostID, forHTTPHeaderField: "X-Noema-Relay-Device")
        }
        Task {
            await logger.log("[RemoteChat] [LAN] Issuing chat request to \(url.absoluteString) for '\(backend.name)' (SSID token: \(matchedSSID.isEmpty ? "<unknown>" : matchedSSID))")
        }
        return request
    }
#endif

    private func notifyTransport(_ transport: RemoteSessionTransport, streaming: Bool) async {
        guard let observer = transportObserver else { return }
        await observer(transport, streaming)
    }

    private func buildRequest(
        prompt: String,
        kind: EndpointKind,
        imagePaths: [String] = [],
        structuredMessages: [ChatMessage]? = nil
    ) throws -> URLRequest {
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelValue: String = {
            if !trimmedModel.isEmpty { return trimmedModel }
            if let fallback = backend.customModelIDs.first { return fallback }
            return trimmedModel
        }()
        guard !modelValue.isEmpty else {
            throw RemoteChatError.missingModelIdentifier
        }

        let wantsTools = options.includeTools && !toolSpecs.isEmpty
        let wantsImages = !imagePaths.isEmpty
        // Both tools and image content parts need the OpenAI chat shape; LM
        // Studio's native /api/v1/chat takes a flat "input" string only.
        let lmStudioOpenAIFallback = backend.endpointType == .lmStudio && (wantsTools || wantsImages)
        let url: URL
        if lmStudioOpenAIFallback {
            guard let fallbackURL = backend.absoluteURL(for: "/v1/chat/completions") else {
                throw RemoteChatError.invalidEndpoint
            }
            Task {
                await logger.log("[RemoteChat] [LMStudio] Tools or images present; routing request through OpenAI-compatible /v1/chat/completions fallback.")
            }
            url = fallbackURL
        } else {
            guard let endpointURL = backend.chatEndpointURL else {
                throw RemoteChatError.invalidEndpoint
            }
            url = endpointURL
        }
        let requestKind: EndpointKind = lmStudioOpenAIFallback ? .chat : kind
        let openRouterSupportedParameters = backend.isOpenRouter
            ? supportedOpenRouterParameters(for: modelValue)
            : nil
        let allowTools = wantsTools
            && requestKind == .chat
            && openRouterAllowsParameter("tools",
                                         supportedParameters: openRouterSupportedParameters,
                                         defaultWhenUnknown: false)

        var body: [String: Any] = [
            "model": modelValue,
            "stream": true
        ]

        if backend.endpointType == .lmStudio && !lmStudioOpenAIFallback {
            body["input"] = prompt
        } else {
            switch requestKind {
            case .chat:
                if let structuredMessages, !structuredMessages.isEmpty {
                    body["messages"] = Self.chatMessagePayloads(
                        structuredMessages,
                        imagePaths: imagePaths
                    )
                } else {
                    body["messages"] = [["role": "user", "content": Self.userContentValue(prompt: prompt, imagePaths: imagePaths)]]
                }
                if allowTools {
                    body["tools"] = try toolsPayload(from: toolSpecs)
                    body["tool_choice"] = "auto"
                }
            case .completion:
                if wantsImages {
                    Task { await logger.log("[RemoteChat] [Images] completion-style endpoint can't carry image parts; sending text only.") }
                }
                body["prompt"] = prompt
            }
        }
        if !options.stops.isEmpty &&
            !(backend.endpointType == .lmStudio && !lmStudioOpenAIFallback) &&
            openRouterAllowsParameter("stop",
                                      supportedParameters: openRouterSupportedParameters,
                                      defaultWhenUnknown: false) {
            body["stop"] = options.stops
        }
        if let temperature = options.temperature,
           openRouterAllowsParameter("temperature",
                                     supportedParameters: openRouterSupportedParameters,
                                     defaultWhenUnknown: true) {
            body["temperature"] = temperature
        }
        if backend.endpointType == .lmStudio {
            // Same LM Studio server whether native /api/v1/chat or the
            // OpenAI-compat fallback (tools/images) — saved sampling settings
            // apply to both; without this the fallback silently dropped them.
            // Context length is applied at LM Studio model load time to avoid spawning
            // a second loaded instance when chat-time context differs from load config.
            if let temperature = options.temperature {
                body["temperature"] = lmStudioDecimal(temperature, lowerBound: 0.0, upperBound: 2.0)
            }
            if let topP = options.topP {
                body["top_p"] = lmStudioDecimal(topP, lowerBound: 0.0, upperBound: 1.0)
            }
            if let topK = options.topK {
                body["top_k"] = max(1, topK)
            }
            if let minP = options.minP {
                body["min_p"] = lmStudioDecimal(minP, lowerBound: 0.0, upperBound: 1.0)
            }
            if let repeatPenalty = options.repeatPenalty {
                body["repeat_penalty"] = lmStudioDecimal(repeatPenalty, lowerBound: 0.1, upperBound: 3.0)
            }
        } else if backend.isOpenRouter {
            if let topP = options.topP,
               openRouterAllowsParameter("top_p",
                                         supportedParameters: openRouterSupportedParameters,
                                         defaultWhenUnknown: true) {
                body["top_p"] = topP
            }
            if let topK = options.topK,
               openRouterAllowsParameter("top_k",
                                         supportedParameters: openRouterSupportedParameters,
                                         defaultWhenUnknown: false) {
                body["top_k"] = max(1, topK)
            }
            if let minP = options.minP,
               openRouterAllowsParameter("min_p",
                                         supportedParameters: openRouterSupportedParameters,
                                         defaultWhenUnknown: false) {
                body["min_p"] = minP
            }
            if let repeatPenalty = options.repeatPenalty,
               openRouterAllowsParameter("repetition_penalty",
                                         supportedParameters: openRouterSupportedParameters,
                                         defaultWhenUnknown: false) {
                body["repetition_penalty"] = repeatPenalty
            }
            // Ask OpenRouter to include the model's chain-of-thought in the
            // stream so the think box renders for cloud answers too. Only
            // sent when the catalog advertises the parameter — it never
            // forces reasoning on, it just stops it being stripped.
            if openRouterAllowsParameter("include_reasoning",
                                         supportedParameters: openRouterSupportedParameters,
                                         defaultWhenUnknown: false) {
                body["include_reasoning"] = true
            }
        }

        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = try backend.resolvedAuthorizationHeader(), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in backend.openRouterAttributionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func supportedOpenRouterParameters(for modelValue: String) -> Set<String>? {
        guard backend.isOpenRouter else { return nil }
        let normalizedModelID = normalizedOpenRouterParameter(modelValue)
        guard !normalizedModelID.isEmpty else { return nil }
        guard let model = backend.cachedModels.first(where: {
            normalizedOpenRouterParameter($0.id) == normalizedModelID
        }) else {
            return nil
        }
        let params = Set(model.normalizedSupportedParameters)
        return params.isEmpty ? nil : params
    }

    private func openRouterAllowsParameter(_ parameter: String,
                                           supportedParameters: Set<String>?,
                                           defaultWhenUnknown: Bool) -> Bool {
        guard backend.isOpenRouter else { return true }
        guard let supportedParameters else { return defaultWhenUnknown }
        return supportedParameters.contains(normalizedOpenRouterParameter(parameter))
    }

    private func normalizedOpenRouterParameter(_ parameter: String) -> String {
        parameter
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private func lmStudioDecimal(_ value: Double, lowerBound: Double, upperBound: Double, decimals: Int = 2) -> NSDecimalNumber {
        let clamped = max(lowerBound, min(upperBound, value))
        let factor = pow(10.0, Double(decimals))
        let rounded = (clamped * factor).rounded() / factor
        let format = "%.\(max(0, decimals))f"
        let text = String(format: format, locale: Locale(identifier: "en_US_POSIX"), rounded)
        return NSDecimalNumber(string: text)
    }

    static func openRouterStreamError(from data: Data) -> RemoteChatError? {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorDict = event["error"] as? [String: Any] else { return nil }
        let message = (errorDict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let codeValue = errorDict["code"]
        let code: Int = {
            if let int = codeValue as? Int { return int }
            if let string = codeValue as? String, let parsed = Int(string) { return parsed }
            return -1
        }()
        let resolvedMessage = message.isEmpty ? "Remote server error" : message
        return .httpError(code, resolvedMessage)
    }

    private func buildOllamaRequest(prompt: String, imagePaths: [String] = []) throws -> URLRequest {
        guard let url = backend.chatEndpointURL else {
            throw RemoteChatError.invalidEndpoint
        }

        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw RemoteChatError.missingModelIdentifier
        }

        // Ollama's chat API takes bare base64 strings on the message, not
        // OpenAI content parts.
        var userMessage: [String: Any] = [
            "role": "user",
            "content": prompt
        ]
        let encodedImages = imagePaths.compactMap { RemoteImageEncoding.base64Payload(forPath: $0) }
        if !encodedImages.isEmpty {
            userMessage["images"] = encodedImages
        }

        var body: [String: Any] = [
            "model": trimmedModel,
            "stream": true,
            "messages": [userMessage],
            "keep_alive": "5m"
        ]

        var optionsPayload: [String: Any] = [:]
        if !options.stops.isEmpty {
            optionsPayload["stop"] = options.stops
        }
        if let temperature = options.temperature {
            optionsPayload["temperature"] = temperature
        }
        if !optionsPayload.isEmpty {
            body["options"] = optionsPayload
        }

        if options.includeTools && !toolSpecs.isEmpty {
            body["tools"] = try toolsPayload(from: toolSpecs)
        }

        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = try backend.resolvedAuthorizationHeader(), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in backend.openRouterAttributionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    func drainBufferedToolTokens() -> [String] {
        let tokens = bufferedToolTokens
        bufferedToolTokens.removeAll(keepingCapacity: false)
        return tokens
    }

    func buildChatRequestForTesting(prompt: String) throws -> URLRequest {
        try buildRequest(prompt: prompt, kind: .chat)
    }

    func buildChatRequestForTesting(input: LLMInput) throws -> URLRequest {
        try buildRequest(
            prompt: input.prompt,
            kind: .chat,
            imagePaths: Self.imagePaths(from: input),
            structuredMessages: Self.structuredMessages(from: input)
        )
    }

    private func logToolCallPayload(_ jsonString: String) {
        let backendName = backend.name
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackModel = backend.customModelIDs.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelLabel: String
        if !trimmedModel.isEmpty {
            modelLabel = trimmedModel
        } else if let fallbackModel, !fallbackModel.isEmpty {
            modelLabel = fallbackModel
        } else {
            modelLabel = "(unspecified model)"
        }
        Task {
            await logger.logFull("[Remote][Tool][\(backendName)][\(modelLabel)] Endpoint requested tool call: \(jsonString)")
        }
    }

    private func toolsPayload(from specs: [ToolSpec]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(specs)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return json
    }

    /// Preserve role-tagged input for chat endpoints. `LLMInput.prompt` remains
    /// the fallback for completion-style endpoints and legacy adapters only.
    static func structuredMessages(from input: LLMInput) -> [ChatMessage]? {
        switch input.content {
        case .messages(let messages), .multimodalMessages(let messages, _):
            return messages
        case .plain, .multimodal:
            return nil
        }
    }

    /// OpenAI-compatible message payload that retains assistant tool calls and
    /// the matching tool_call_id on role:"tool" results. Images attach only to
    /// the final user turn without flattening the rest of the transcript.
    static func chatMessagePayloads(
        _ messages: [ChatMessage],
        imagePaths: [String] = []
    ) -> [[String: Any]] {
        let finalUserIndex = messages.lastIndex { $0.role.lowercased() == "user" }
        return messages.enumerated().map { index, message in
            var payload: [String: Any] = ["role": message.role]
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                payload["tool_calls"] = toolCalls.map { toolCall in
                    [
                        "id": toolCall.id,
                        "type": toolCall.type,
                        "function": [
                            "name": toolCall.function.name,
                            "arguments": toolCall.function.arguments
                        ]
                    ]
                }
                let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                payload["content"] = trimmedContent.isEmpty ? NSNull() : message.content
            } else if index == finalUserIndex, !imagePaths.isEmpty {
                payload["content"] = userContentValue(prompt: message.content, imagePaths: imagePaths)
            } else {
                payload["content"] = message.content
            }
            if let toolCallID = message.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !toolCallID.isEmpty {
                payload["tool_call_id"] = toolCallID
            }
            return payload
        }
    }

    /// `LLMInput.prompt` flattens multimodal content to text; image paths must
    /// be pulled from the content enum directly.
    static func imagePaths(from input: LLMInput) -> [String] {
        switch input.content {
        case .plain, .messages:
            return []
        case .multimodal(_, let paths), .multimodalMessages(_, let paths):
            return paths
        }
    }

    /// Chat-completions user-message content: a plain string normally, an
    /// OpenAI content-parts array when images ride along. Unencodable images
    /// are skipped rather than failing the send.
    static func userContentValue(prompt: String, imagePaths: [String]) -> Any {
        guard !imagePaths.isEmpty else { return prompt }
        let imageObjects = imagePaths.compactMap { RemoteImageEncoding.imageContentObject(forPath: $0) }
        guard !imageObjects.isEmpty else { return prompt }
        var parts: [[String: Any]] = [["type": "text", "text": prompt]]
        parts.append(contentsOf: imageObjects)
        return parts
    }

    private func makeToolCallJSON(
        from accumulator: ToolCallAccumulator,
        fallbackToolCallID: String,
        requestStatus: String,
        error: String? = nil
    ) -> String? {
        guard let name = accumulator.name, !name.isEmpty else { return nil }
        let argumentsString = accumulator.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        var argumentsObject: Any = [:]
        if let data = argumentsString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            argumentsObject = obj
        }

        let toolCallID = {
            let trimmed = accumulator.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? fallbackToolCallID : trimmed
        }()

        var payload: [String: Any] = [
            "tool": name,
            "tool_name": name,
            "args": argumentsObject,
            "arguments": argumentsObject,
            "id": toolCallID,
            "tool_call_id": toolCallID,
            "request_status": requestStatus
        ]

        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            payload["error"] = error
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return jsonString
    }
}

#if os(iOS) || os(visionOS)
actor WiFiSSIDProvider {
    static let shared = WiFiSSIDProvider()

    private var cachedSSID: String?
    private var lastFetch: Date?
    private var hotspotFailureUntil: Date?

    func currentSSID() async -> String? {
        if #available(iOS 14.0, visionOS 1.0, *) {
            if let failureUntil = hotspotFailureUntil, failureUntil > Date() {
                return cachedSSID
            }
            let ssid = await withCheckedContinuation { continuation in
                NEHotspotNetwork.fetchCurrent { network in
                    continuation.resume(returning: network?.ssid)
                }
            }
            cachedSSID = ssid
            lastFetch = Date()
            if ssid == nil {
                hotspotFailureUntil = Date().addingTimeInterval(60)
            } else {
                hotspotFailureUntil = nil
            }
            return ssid
        } else if let ssid = fetchSSIDViaCaptiveNetwork() {
            cachedSSID = ssid
            lastFetch = Date()
            return ssid
        }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 10, let cachedSSID {
            return cachedSSID
        }
        return cachedSSID
    }
#if !os(visionOS)
    private func fetchSSIDViaCaptiveNetwork() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for interface in interfaces {
            if let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [CFString: Any],
               let ssid = info[kCNNetworkInfoKeySSID] as? String {
                return ssid
            }
        }
        return nil
    }
#else
    private func fetchSSIDViaCaptiveNetwork() -> String? { nil }
#endif
}
#endif
