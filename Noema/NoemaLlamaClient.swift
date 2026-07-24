import Foundation
import Dispatch
import os
import NoemaPackages
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum LoopbackVisionState {
    private static let stateLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    static func setEnabled(_ enabled: Bool) {
        stateLock.withLock { state in
            state = enabled
        }
    }

    static func isEnabled() -> Bool {
        stateLock.withLock { $0 }
    }
}

actor GenerationCoordinator {
    private var isGenerationActive = false
    private var isUnloading = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireGeneration() async {
        if isUnloading || isGenerationActive {
            await withCheckedContinuation { continuation in
                generationWaiters.append(continuation)
            }
        }
        isGenerationActive = true
    }

    func releaseGeneration() {
        guard isGenerationActive else { return }
        isGenerationActive = false
        if let continuation = unloadWaiters.first {
            unloadWaiters.removeFirst()
            continuation.resume()
        } else if let continuation = generationWaiters.first {
            generationWaiters.removeFirst()
            isGenerationActive = true
            continuation.resume()
        }
    }

    func beginUnload() async {
        if isUnloading {
            await withCheckedContinuation { continuation in
                unloadWaiters.append(continuation)
            }
            return
        }
        isUnloading = true
        if isGenerationActive {
            await withCheckedContinuation { continuation in
                unloadWaiters.append(continuation)
            }
        }
    }

    // Returns true if this caller acquired the unload lock and is responsible for
    // performing the unload. Returns false if it only waited for another unload
    // already in progress to finish.
    func beginUnloadAcquiring() async -> Bool {
        if isUnloading {
            await withCheckedContinuation { continuation in
                unloadWaiters.append(continuation)
            }
            return false
        }
        isUnloading = true
        if isGenerationActive {
            await withCheckedContinuation { continuation in
                unloadWaiters.append(continuation)
            }
        }
        return true
    }

    func endUnload() {
        isUnloading = false

        let waitingUnloaders = unloadWaiters
        unloadWaiters.removeAll()
        for continuation in waitingUnloaders {
            continuation.resume()
        }

        if !isGenerationActive, let continuation = generationWaiters.first {
            generationWaiters.removeFirst()
            isGenerationActive = true
            continuation.resume()
        }
    }
}

private actor GenerationReleaseToken {
    private var coordinator: GenerationCoordinator?
    private var onRelease: (@Sendable () -> Void)?

    init(coordinator: GenerationCoordinator,
         onRelease: @escaping @Sendable () -> Void = {}) {
        self.coordinator = coordinator
        self.onRelease = onRelease
    }

    func release() async {
        guard let coordinator else { return }
        self.coordinator = nil
        let onRelease = self.onRelease
        self.onRelease = nil
        onRelease?()
        await coordinator.releaseGeneration()
    }
}

private actor StreamState {
    private var didStartGeneration = false

    func markStarted() {
        didStartGeneration = true
    }

    func hasStarted() -> Bool {
        didStartGeneration
    }
}

private actor LoopbackSessionState {
    private var activeSession: URLSession?

    func set(_ session: URLSession) {
        activeSession = session
    }

    func clearIfMatching(_ session: URLSession) {
        if activeSession === session {
            activeSession = nil
        }
    }

    func cancelActive() {
        let session = activeSession
        activeSession = nil
        session?.invalidateAndCancel()
    }
}

enum LoopbackOutputCapturePolicy: Equatable, Sendable {
    case none
    case characterCount
    case fullText
}

struct LoopbackGenerationResult: Equatable, Sendable {
    let text: String?
    let characterCount: Int
}

struct LoopbackOutputCapture: Sendable {
    let policy: LoopbackOutputCapturePolicy
    private(set) var text: String?
    private(set) var characterCount = 0

    init(policy: LoopbackOutputCapturePolicy) {
        self.policy = policy
        self.text = policy == .fullText ? "" : nil
    }

    mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        switch policy {
        case .none:
            break
        case .characterCount:
            characterCount += chunk.count
        case .fullText:
            characterCount += chunk.count
            text?.append(chunk)
        }
    }

    var result: LoopbackGenerationResult {
        LoopbackGenerationResult(text: text, characterCount: characterCount)
    }
}

enum BoundedLoopbackStreamEmitter {
    static let capacity = 16

    static func yield(
        _ chunk: String,
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(chunk) {
            case .enqueued:
                return
            case .dropped:
                // `.bufferingOldest` rejects this newest element when full. Wait
                // for the consumer and retry the same chunk to preserve ordering.
                try await Task.sleep(nanoseconds: 1_000_000)
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }
}

// MARK: - Errors

enum NoemaLlamaError: Error, LocalizedError {
    case modelLoadFailed
    case contextCreationFailed
    case samplerCreationFailed
    case generationFailed
    case invalidParameters
    
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load model"
        case .contextCreationFailed: return "Failed to create context"
        case .samplerCreationFailed: return "Failed to create sampler"
        case .generationFailed: return "Text generation failed"
        case .invalidParameters: return "Invalid parameters"
        }
    }
}

// MARK: - LLM Input/Output Types

public enum LLMResponseFormat: Sendable {
    case jsonSchema(name: String, schema: [String: AnyCodable])

    fileprivate var requestPayload: [String: Any] {
        switch self {
        case .jsonSchema(let name, let schema):
            return [
                "type": "json_schema",
                "json_schema": [
                    "name": name,
                    "schema": schema.plainJSONObject,
                    "strict": true
                ]
            ]
        }
    }
}

/// Distinguishes user-visible chat generations from internal maintenance work.
/// Auxiliary requests must never become the durable prompt/cache checkpoint for
/// a conversation, especially for single-slot paged runtimes.
public enum LLMRequestPurpose: Sendable, Equatable {
    case chat
    case auxiliary
}

public struct LLMGenerationOptions: Sendable {
    public var reasoningEnabled: Bool?
    public var maxOutputTokens: Int?
    public var thinkingBudgetTokens: Int?
    public var responseFormat: LLMResponseFormat?
    /// Request-scoped sampling overrides. These avoid mutating the process-wide
    /// llama environment when Relay serves concurrent callers.
    public var seed: Int?
    public var temperature: Double?
    public var topK: Int?
    public var topP: Double?
    public var minP: Double?
    public var repeatPenalty: Double?
    public var repeatLastN: Int?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var logitBias: [Int: Double]?
    public var promptCache: Bool?
    public var requestPurpose: LLMRequestPurpose
    /// OpenAI-style tool schemas to send as the request `tools` array so the model's
    /// own chat template renders them natively (llama.cpp requires --jinja). When set,
    /// the loopback stops relying on hand-written prompt tool guidance.
    public var tools: [ToolSpec]?

    public init(
        reasoningEnabled: Bool? = nil,
        maxOutputTokens: Int? = nil,
        thinkingBudgetTokens: Int? = nil,
        responseFormat: LLMResponseFormat? = nil,
        seed: Int? = nil,
        temperature: Double? = nil,
        topK: Int? = nil,
        topP: Double? = nil,
        minP: Double? = nil,
        repeatPenalty: Double? = nil,
        repeatLastN: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        logitBias: [Int: Double]? = nil,
        promptCache: Bool? = nil,
        requestPurpose: LLMRequestPurpose = .chat,
        tools: [ToolSpec]? = nil
    ) {
        self.reasoningEnabled = reasoningEnabled
        self.maxOutputTokens = maxOutputTokens
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.responseFormat = responseFormat
        self.seed = seed
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.logitBias = logitBias
        self.promptCache = promptCache
        self.requestPurpose = requestPurpose
        self.tools = tools
    }
}

public struct LLMInput: Sendable {
    public enum Content: Sendable {
        case plain(String)
        case messages([ChatMessage])
        case multimodal(text: String, imagePaths: [String])
        case multimodalMessages(messages: [ChatMessage], imagePaths: [String])
    }
    
    public let content: Content
    public let generationOptions: LLMGenerationOptions
    
    public init(_ content: Content, generationOptions: LLMGenerationOptions = LLMGenerationOptions()) {
        self.content = content
        self.generationOptions = generationOptions
    }
    
    var prompt: String {
        switch content {
        case .plain(let text):
            return text
        case .messages(let messages):
            return messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        case .multimodal(let text, _):
            // For llama.cpp we inject an image placeholder token per image; adapters will handle real images
            return text
        case .multimodalMessages(let messages, _):
            return messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        }
    }
}

public extension LLMInput {
    static func plain(_ text: String, generationOptions: LLMGenerationOptions = LLMGenerationOptions()) -> LLMInput {
        LLMInput(.plain(text), generationOptions: generationOptions)
    }

    static func multimodal(
        text: String,
        imagePaths: [String],
        generationOptions: LLMGenerationOptions = LLMGenerationOptions()
    ) -> LLMInput {
        LLMInput(.multimodal(text: text, imagePaths: imagePaths), generationOptions: generationOptions)
    }

    static func multimodal(
        messages: [ChatMessage],
        imagePaths: [String],
        generationOptions: LLMGenerationOptions = LLMGenerationOptions()
    ) -> LLMInput {
        LLMInput(.multimodalMessages(messages: messages, imagePaths: imagePaths), generationOptions: generationOptions)
    }
}

struct LoopbackSpeculativeTimings: Codable, Equatable, Sendable {
    let speculativeType: String?
    let speculativeState: String?
    let draftAttempts: Int?
    let draftEmptyAttempts: Int?
    let cacheN: Int?
    let promptN: Int?
    let promptMS: Double?
    let promptPerSecond: Double?
    let predictedN: Int?
    let predictedMS: Double?
    let predictedPerSecond: Double?
    let draftN: Int?
    let draftNAccepted: Int?
    let draftNBudget: Int?
    let draftMS: Double?
    let draftVerificationMS: Double?
    let draftRollbackMS: Double?
    let draftAcceptedPerPosition: [Int]?
    /// Current dynamic draft length when the auto-tuner is on; 0 = speculation
    /// temporarily paused, nil = static drafting.
    let draftNDyn: Int?

    init(
        cacheN: Int?,
        promptN: Int?,
        promptMS: Double?,
        promptPerSecond: Double?,
        predictedN: Int?,
        predictedMS: Double?,
        predictedPerSecond: Double?,
        draftN: Int?,
        draftNAccepted: Int?,
        draftNDyn: Int?,
        speculativeType: String? = nil,
        speculativeState: String? = nil,
        draftAttempts: Int? = nil,
        draftEmptyAttempts: Int? = nil,
        draftNBudget: Int? = nil,
        draftMS: Double? = nil,
        draftVerificationMS: Double? = nil,
        draftRollbackMS: Double? = nil,
        draftAcceptedPerPosition: [Int]? = nil
    ) {
        self.speculativeType = speculativeType
        self.speculativeState = speculativeState
        self.draftAttempts = draftAttempts
        self.draftEmptyAttempts = draftEmptyAttempts
        self.cacheN = cacheN
        self.promptN = promptN
        self.promptMS = promptMS
        self.promptPerSecond = promptPerSecond
        self.predictedN = predictedN
        self.predictedMS = predictedMS
        self.predictedPerSecond = predictedPerSecond
        self.draftN = draftN
        self.draftNAccepted = draftNAccepted
        self.draftNBudget = draftNBudget
        self.draftMS = draftMS
        self.draftVerificationMS = draftVerificationMS
        self.draftRollbackMS = draftRollbackMS
        self.draftAcceptedPerPosition = draftAcceptedPerPosition
        self.draftNDyn = draftNDyn
    }

    var acceptanceRate: Double? {
        guard let draftN, draftN > 0, let draftNAccepted else { return nil }
        return Double(draftNAccepted) / Double(draftN)
    }

    enum CodingKeys: String, CodingKey {
        case speculativeType = "speculative_type"
        case speculativeState = "speculative_state"
        case draftAttempts = "draft_attempts"
        case draftEmptyAttempts = "draft_empty_attempts"
        case cacheN = "cache_n"
        case promptN = "prompt_n"
        case promptMS = "prompt_ms"
        case promptPerSecond = "prompt_per_second"
        case predictedN = "predicted_n"
        case predictedMS = "predicted_ms"
        case predictedPerSecond = "predicted_per_second"
        case draftN = "draft_n"
        case draftNAccepted = "draft_n_accepted"
        case draftNBudget = "draft_n_budget"
        case draftMS = "draft_ms"
        case draftVerificationMS = "draft_verification_ms"
        case draftRollbackMS = "draft_rollback_ms"
        case draftAcceptedPerPosition = "draft_accepted_per_position"
        case draftNDyn = "draft_n_dyn"
    }
}

/// Synchronous mirror of the most recent response timings. Written on the
/// stream-parsing task before the request finishes, so a reader that runs
/// after stream completion (e.g. ChatVM perf finalization) always sees the
/// values for the response that just ended.
enum LoopbackLatestTimings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: LoopbackSpeculativeTimings?

    static func record(_ timings: LoopbackSpeculativeTimings) {
        lock.lock()
        value = timings
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        value = nil
        lock.unlock()
    }

    static func snapshot() -> LoopbackSpeculativeTimings? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct LoopbackResponseDiagnostics: Equatable, Sendable {
    let completedAt: Date
    let endpoint: String
    let requestMode: String
    let streaming: Bool
    let modelIdentifier: String
    let speculativeType: String?
    let timings: LoopbackSpeculativeTimings?
    let finishReason: String?
    let outputCharacters: Int
}

actor LoopbackRuntimeDiagnostics {
    static let shared = LoopbackRuntimeDiagnostics()

    private var latestResponse: LoopbackResponseDiagnostics?

    func resetLatestResponse() {
        latestResponse = nil
    }

    func recordResponse(_ response: LoopbackResponseDiagnostics) {
        latestResponse = response
    }

    func latestResponseSnapshot() -> LoopbackResponseDiagnostics? {
        latestResponse
    }
}

struct LoopbackReadyProbeResult: Equatable, Sendable {
    let ready: Bool
    let statusCode: Int?
    let attempts: Int
    let elapsedMs: Int
    let usedBridgeFallback: Bool
}

enum LoopbackReadinessProbe {
    static func run(
        timeout: TimeInterval,
        intervalNanos: UInt64,
        now: @Sendable @escaping () -> Date = Date.init,
        bridgeReady: @Sendable @escaping () async -> Bool,
        healthStatus: @Sendable @escaping () async -> Int?,
        sleep: @Sendable @escaping (UInt64) async -> Void = { nanos in
            try? await Task.sleep(nanoseconds: nanos)
        }
    ) async -> LoopbackReadyProbeResult {
        let started = now()
        let clampedTimeout = max(0.5, timeout)
        let deadline = started.addingTimeInterval(clampedTimeout)
        var attempts = 0
        var lastStatus: Int?
        var bridgeReadyState = await bridgeReady()

        while now() < deadline {
            attempts += 1
            lastStatus = await healthStatus()
            if lastStatus == 200 {
                return LoopbackReadyProbeResult(
                    ready: true,
                    statusCode: 200,
                    attempts: attempts,
                    elapsedMs: max(0, Int(now().timeIntervalSince(started) * 1000)),
                    usedBridgeFallback: false
                )
            }

            if !bridgeReadyState {
                bridgeReadyState = await bridgeReady()
            }

            if bridgeReadyState, attempts >= 5 {
                return LoopbackReadyProbeResult(
                    ready: true,
                    statusCode: lastStatus,
                    attempts: attempts,
                    elapsedMs: max(0, Int(now().timeIntervalSince(started) * 1000)),
                    usedBridgeFallback: true
                )
            }

            await sleep(intervalNanos)
        }

        if bridgeReadyState {
            return LoopbackReadyProbeResult(
                ready: true,
                statusCode: lastStatus,
                attempts: attempts,
                elapsedMs: max(0, Int(now().timeIntervalSince(started) * 1000)),
                usedBridgeFallback: true
            )
        }

        return LoopbackReadyProbeResult(
            ready: false,
            statusCode: lastStatus,
            attempts: attempts,
            elapsedMs: max(0, Int(now().timeIntervalSince(started) * 1000)),
            usedBridgeFallback: false
        )
    }
}

enum LoopbackRetryDecision: Equatable {
    case retryWithoutRestart
    case restartAndRetry(port: Int)
    case fail
}

enum LoopbackRetryPlanner {
    static func decision(
        preRestartProbe: LoopbackReadyProbeResult,
        restartedPort: Int?,
        postRestartProbe: LoopbackReadyProbeResult?
    ) -> LoopbackRetryDecision {
        if preRestartProbe.ready {
            return .retryWithoutRestart
        }
        guard let restartedPort, restartedPort > 0, postRestartProbe?.ready == true else {
            return .fail
        }
        return .restartAndRetry(port: restartedPort)
    }
}

func logLastLoopbackStartOptions(prefix: String = "[Loopback][StartOptions]") {
    guard let options = LlamaServerBridge.lastStartOptions() else { return }
    let spec = options.speculativeType.isEmpty ? "none" : options.speculativeType
    let draft = options.mtpPath.isEmpty ? "embedded-or-none" : URL(fileURLWithPath: options.mtpPath).lastPathComponent
    let paged = options.pagedMode.map {
        " mode=\($0) io=\(options.pagedIOThreads ?? 0)x\(options.pagedIODepth ?? 0)"
            + " waves=\(options.pagedWaves ?? false)"
            + " expertMajor=\(options.pagedExpertMajor ?? false)"
    } ?? ""
    let argv = options.argv.joined(separator: " ")
    Task {
        await logger.log("\(prefix) port=\(options.port) spec=\(spec) mtp=\(draft) specDraftNMax=\(options.specDraftNMax.map(String.init) ?? "nil") specDraftNMin=\(options.specDraftNMin.map(String.init) ?? "nil") specDraftPMin=\(options.specDraftPMin.map { "\($0)" } ?? "nil") specDynamic=\(options.specDynamic.map(String.init) ?? "nil")\(paged) argv=\(argv)")
    }
}

public struct ChatMessage: Sendable {
    public let role: String
    public let content: String
    public let toolCalls: [ToolCall]?
    public let toolCallId: String?

    public init(
        role: String,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

private extension Dictionary where Key == String, Value == AnyCodable {
    var plainJSONObject: [String: Any] {
        mapValues { Self.plainJSONValue($0.value) }
    }

    static func plainJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: AnyCodable]:
            return dictionary.plainJSONObject
        case let dictionary as [String: Any]:
            return dictionary.mapValues { plainJSONValue($0) }
        case let array as [AnyCodable]:
            return array.map { plainJSONValue($0.value) }
        case let array as [Any]:
            return array.map { plainJSONValue($0) }
        default:
            return value
        }
    }
}

// MARK: - NoemaLlamaClient

public final class NoemaLlamaClient: @unchecked Sendable {
    private struct LoopbackLease: Sendable {
        let ownerID: UUID
        let port: Int32
        let ggufPath: String
    }

    /// Ownership token for a raw loopback consumer that does not wrap its
    /// server in `NoemaLlamaClient` (currently LocalVLM).
    struct StandaloneLoopbackLease: Sendable {
        fileprivate let ownerID: UUID
        let port: Int32
        fileprivate let ggufPath: String
    }

    /// Identifies the newest `NoemaLlamaClient` to claim the process-global
    /// loopback. Port and path alone are not sufficient: the bridge can reuse
    /// both for a later server instance, and a stale client's deinit must not
    /// stop that replacement.
    private static let activeLoopbackOwner = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    /// Serializes use of the process-global bridge across distinct client
    /// instances. Per-client GenerationCoordinator is not sufficient when a
    /// utility such as Pass Scanner creates its own temporary GGUF client.
    private enum BridgeUseState: Sendable {
        case idle
        case generation
        case mutation
    }
    private static let bridgeUseState = OSAllocatedUnfairLock<BridgeUseState>(initialState: .idle)

    private static func beginBridgeGeneration() -> Bool {
        bridgeUseState.withLock { state in
            guard case .idle = state else { return false }
            state = .generation
            return true
        }
    }

    private static func endBridgeGeneration() {
        bridgeUseState.withLock { state in
            if case .generation = state { state = .idle }
        }
    }

    private static func beginBridgeMutation() -> Bool {
        bridgeUseState.withLock { state in
            guard case .idle = state else { return false }
            state = .mutation
            return true
        }
    }

    private static func endBridgeMutation() {
        bridgeUseState.withLock { state in
            if case .mutation = state { state = .idle }
        }
    }

    private static func waitForBridgeMutation() async -> Bool {
        while true {
            guard !Task.isCancelled else { return false }
            if beginBridgeMutation() {
                if Task.isCancelled {
                    endBridgeMutation()
                    return false
                }
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
    }

    final class BridgeMutationReservation: @unchecked Sendable {
        private let active: OSAllocatedUnfairLock<Bool>

        fileprivate init(isActive: Bool) {
            active = OSAllocatedUnfairLock(initialState: isActive)
        }

        var isActive: Bool {
            active.withLock { $0 }
        }

        func release() {
            let shouldRelease = active.withLock { active in
                guard active else { return false }
                active = false
                return true
            }
            if shouldRelease {
                NoemaLlamaClient.endBridgeMutation()
            }
        }

        deinit { release() }
    }

    final class BridgeGenerationReservation: @unchecked Sendable {
        private let active = OSAllocatedUnfairLock<Bool>(initialState: true)

        func release() {
            let shouldRelease = active.withLock { active in
                guard active else { return false }
                active = false
                return true
            }
            if shouldRelease {
                NoemaLlamaClient.endBridgeGeneration()
            }
        }

        deinit { release() }
    }

    static func reserveLoopbackBridge() async -> BridgeMutationReservation {
        BridgeMutationReservation(isActive: await waitForBridgeMutation())
    }

    /// Entry point for app subsystems that intentionally replace the embedded
    /// server without creating a NoemaLlamaClient first (resident loader,
    /// Relay vision, LocalVLM). It waits for any active GGUF response, clears
    /// stale client ownership, then performs one serialized replacement.
    static func replaceLoopbackServer(
        with configuration: LlamaServerBridge.StartConfiguration
    ) async -> Int32 {
        let reservation = await reserveLoopbackBridge()
        defer { reservation.release() }
        return replaceLoopbackServer(with: configuration, reservation: reservation)
    }

    static func replaceLoopbackServer(
        with configuration: LlamaServerBridge.StartConfiguration,
        reservation: BridgeMutationReservation
    ) -> Int32 {
        guard reservation.isActive else { return -1 }
        LlamaServerBridge.stop()
        LoopbackVisionState.setEnabled(false)
        activeLoopbackOwner.withLock { $0 = nil }
        return LlamaServerBridge.start(configuration)
    }

    static func stopLoopbackServerExclusively() async {
        let reservation = await reserveLoopbackBridge()
        defer { reservation.release() }
        guard reservation.isActive else { return }
        LlamaServerBridge.stop()
        LoopbackVisionState.setEnabled(false)
        activeLoopbackOwner.withLock { $0 = nil }
    }

    /// Starts a loopback server for a raw HTTP consumer and publishes an exact
    /// UUID lease. A later GGUF replacement invalidates the lease, so that
    /// consumer can neither send to nor stop the replacement model by mistake.
    static func startStandaloneLoopbackServer(
        with configuration: LlamaServerBridge.StartConfiguration,
        visionEnabled: Bool = false
    ) async -> StandaloneLoopbackLease? {
        let reservation = await reserveLoopbackBridge()
        defer { reservation.release() }
        guard reservation.isActive else { return nil }

        LlamaServerBridge.stop()
        LoopbackVisionState.setEnabled(false)
        activeLoopbackOwner.withLock { $0 = nil }
        let port = LlamaServerBridge.start(configuration)
        guard port > 0 else { return nil }

        let lease = StandaloneLoopbackLease(
            ownerID: UUID(),
            port: port,
            ggufPath: canonicalLoopbackPath(configuration.ggufPath)
        )
        activeLoopbackOwner.withLock { $0 = lease.ownerID }
        LoopbackVisionState.setEnabled(visionEnabled)
        return lease
    }

    static func reserveStandaloneLoopbackGeneration(
        for lease: StandaloneLoopbackLease
    ) -> BridgeGenerationReservation? {
        guard beginBridgeGeneration() else { return nil }
        let reservation = BridgeGenerationReservation()
        guard standaloneLoopbackIsCurrent(lease) else {
            reservation.release()
            return nil
        }
        return reservation
    }

    static func stopStandaloneLoopbackServer(ifOwned lease: StandaloneLoopbackLease) async {
        let reservation = await reserveLoopbackBridge()
        defer { reservation.release() }
        guard reservation.isActive else { return }
        activeLoopbackOwner.withLock { activeOwner in
            guard activeOwner == lease.ownerID,
                  standaloneLoopbackIsCurrent(lease, activeOwner: activeOwner) else { return }
            LlamaServerBridge.stop()
            LoopbackVisionState.setEnabled(false)
            activeOwner = nil
        }
    }

    private let modelURL: URL
    private let contextLength: Int32
    private let mmprojPath: String?
    private let allowProjectorAutoDiscovery: Bool
    private let explicitThreadCount: Int32?
    private let preferParameterContextOverEnvironment: Bool
    private let forceFreshLoopback: Bool
    private let serverConfiguration: LlamaServerBridge.StartConfiguration?
    private struct PagedTelemetrySnapshot {
        var waves: Int64
        var prefillBytes: Int64
        var hits: Int64
        var misses: Int64
        var decodeHits: Int64
        var decodeMisses: Int64
        var decodeBytes: Int64
        var decodeStallNs: Int64
        var historyPredictions: Int64
        var historyPredictionMatches: Int64
        var checksumVerifications: Int64
        var checksumCacheHits: Int64
    }
    /// Previous completion's boot-cumulative paged counters, so the telemetry
    /// line can report per-completion deltas. Lives here because extensions
    /// cannot hold stored properties.
    private let pagedTelemetrySnapshot =
        OSAllocatedUnfairLock<PagedTelemetrySnapshot?>(initialState: nil)
    // Keep loopback requests effectively unbounded for long local generations.
    private static let loopbackRequestTimeout: TimeInterval = 60 * 60 * 24 * 365 * 10
    private static let loopbackResourceTimeout: TimeInterval = 60 * 60 * 24 * 365 * 10
    private static let loopbackReadyProbeTimeout: TimeInterval = 30
    private static let loopbackRetryProbeTimeout: TimeInterval = 4
    private static let loopbackReadyProbeRequestTimeout: TimeInterval = 1.5
    private static let loopbackReadyProbeIntervalNanos: UInt64 = 200_000_000
    // Snapshot of effective load-time knobs for richer logging
    private var effectiveContext: Int32 = 0
    private var effectiveMMProj: String? = nil
    private let generationCoordinator = GenerationCoordinator()
    private let loopbackSessionState = LoopbackSessionState()
    /// Synchronous completion metadata for the most recently finished request.
    /// ChatVM uses `length` to resume generation when the native runtime cannot
    /// shift its KV context (for example, multimodal and some hybrid memories).
    private let latestFinishReason = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// `NoemaLlamaClient` talks to a process-global embedded server. Remember
    /// which concrete server instance this client loaded/reused so a stale
    /// client can never stop a newer model that has since taken over the bridge.
    private let loopbackLease = OSAllocatedUnfairLock<LoopbackLease?>(initialState: nil)
    /// Explicit unload is idempotent. The deinit fallback snapshots and clears
    /// the lease separately so it cannot race a later model load.
    private let unloadRequested = OSAllocatedUnfairLock<Bool>(initialState: false)

    private static func canonicalLoopbackPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func standaloneLoopbackIsCurrent(
        _ lease: StandaloneLoopbackLease,
        activeOwner suppliedOwner: UUID? = nil
    ) -> Bool {
        let activeOwner = suppliedOwner ?? activeLoopbackOwner.withLock { $0 }
        let options = LlamaServerBridge.lastStartOptions()
        return activeOwner == lease.ownerID
            && lease.port > 0
            && lease.port == LlamaServerBridge.port()
            && options?.port == Int(lease.port)
            && lease.ggufPath == options.map { canonicalLoopbackPath($0.ggufPath) }
    }

    /// True only while this client still owns the exact process-global server
    /// generation it loaded. Relay uses this to reject stale cache entries
    /// after another GGUF utility has replaced the bridge.
    func isCurrentLoopbackOwner() -> Bool {
        guard !unloadRequested.withLock({ $0 }),
              let lease = loopbackLease.withLock({ $0 }) else { return false }
        return Self.activeLoopbackOwner.withLock { activeOwner in
            let options = LlamaServerBridge.lastStartOptions()
            return activeOwner == lease.ownerID
                && lease.port > 0
                && lease.port == LlamaServerBridge.port()
                && options?.port == Int(lease.port)
                && lease.ggufPath == options.map { Self.canonicalLoopbackPath($0.ggufPath) }
        }
    }

    private func checkedLoopbackPath(port: Int) throws -> String {
        let requestedPath = Self.canonicalLoopbackPath(modelURL.path)
        let options = LlamaServerBridge.lastStartOptions()
        guard port > 0,
              LlamaServerBridge.port() == Int32(port),
              options?.port == port,
              options.map({ Self.canonicalLoopbackPath($0.ggufPath) }) == requestedPath else {
            throw NSError(
                domain: "Noema",
                code: 2002,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The GGUF server is already running a different model.",
                        locale: LocalizationManager.preferredLocale()
                    )
                ]
            )
        }
        return requestedPath
    }

    /// Claims a newly loaded/restarted bridge generation for this client.
    private func claimLoopbackLease(
        port: Int,
        allowReplacingExistingOwner: Bool = false
    ) throws {
        // Serialize check + generation publication against other clients. The
        // instance lease is written immediately afterward without nesting two
        // unfair-lock closures (which Swift 6 rejects for captured inout state).
        let priorOwner = loopbackLease.withLock { $0?.ownerID }
        let claimed = try Self.activeLoopbackOwner.withLock { activeOwner in
            guard activeOwner == nil
                    || activeOwner == priorOwner
                    || allowReplacingExistingOwner else {
                throw loopbackOwnershipError()
            }
            let requestedPath = try checkedLoopbackPath(port: port)
            let lease = LoopbackLease(
                ownerID: UUID(),
                port: Int32(port),
                ggufPath: requestedPath
            )
            activeOwner = lease.ownerID
            return lease
        }
        loopbackLease.withLock { lease in
            lease = claimed
        }
    }

    private func loopbackOwnershipError() -> NSError {
        NSError(
            domain: "Noema",
            code: 2002,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "The GGUF runtime is already in use.",
                    locale: LocalizationManager.preferredLocale()
                )
            ]
        )
    }

    /// Stops the bridge only when the supplied lease is still the published
    /// owner of the exact server generation. Caller must hold bridge mutation.
    private static func stopLoopbackIfOwned(_ lease: LoopbackLease?) -> Bool {
        activeLoopbackOwner.withLock { activeOwner in
            let options = LlamaServerBridge.lastStartOptions()
            guard let lease,
                  activeOwner == lease.ownerID,
                  lease.port > 0,
                  lease.port == LlamaServerBridge.port(),
                  options?.port == Int(lease.port),
                  lease.ggufPath == options.map({ canonicalLoopbackPath($0.ggufPath) }) else {
                return false
            }
            LlamaServerBridge.stop()
            LoopbackVisionState.setEnabled(false)
            activeOwner = nil
            return true
        }
    }

    /// Atomically stops and restarts only the generation this client still
    /// owns. A stale request may not kill a replacement client's bridge while
    /// recovering from a connection reset.
    private func restartOwnedLoopback(mmprojPath: String?) throws -> Int {
        guard let existing = loopbackLease.withLock({ $0 }) else {
            throw loopbackOwnershipError()
        }
        let result: (port: Int, lease: LoopbackLease)? = try Self.activeLoopbackOwner.withLock { activeOwner in
            let requestedPath = try checkedLoopbackPath(port: Int(existing.port))
            guard activeOwner == existing.ownerID,
                  existing.ggufPath == requestedPath else {
                throw loopbackOwnershipError()
            }

            LlamaServerBridge.stop()
            LoopbackVisionState.setEnabled(false)
            let restarted = Int(LlamaServerBridge.start(
                loopbackStartConfiguration(mmprojPath: mmprojPath)
            ))
            guard restarted > 0 else {
                activeOwner = nil
                return nil
            }
            let restartedPath = try checkedLoopbackPath(port: restarted)
            let lease = LoopbackLease(
                ownerID: UUID(),
                port: Int32(restarted),
                ggufPath: restartedPath
            )
            activeOwner = lease.ownerID
            return (restarted, lease)
        }
        guard let result else { return 0 }
        loopbackLease.withLock { $0 = result.lease }
        LoopbackVisionState.setEnabled(true)
        return result.port
    }

    /// Validates an already-running bridge without stealing ownership from a
    /// newer client that happens to use the same model path and port.
    private func validateLoopbackLease(port: Int) throws {
        let lease = loopbackLease.withLock { $0 }
        let ownsGeneration = try Self.activeLoopbackOwner.withLock { activeOwner in
            let requestedPath = try checkedLoopbackPath(port: port)
            guard let lease else { return false }
            return activeOwner == lease.ownerID
                && lease.port == Int32(port)
                && lease.ggufPath == requestedPath
        }
        guard ownsGeneration else {
            throw NSError(
                domain: "Noema",
                code: 2002,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The GGUF runtime is already in use.",
                        locale: LocalizationManager.preferredLocale()
                    )
                ]
            )
        }
    }

    private var templateProfile: TemplateDrivenModelSupport.Profile {
        TemplateDrivenModelSupport.resolvedProfile(modelURL: modelURL)
    }

    private var usesTemplateDrivenMessages: Bool {
        templateProfile.usesTemplateDrivenMessages
    }

    private var isQwen35Model: Bool {
        templateProfile == .qwen35
    }

    private var isGemma4Model: Bool {
        templateProfile == .gemma4
    }

    private func performCoordinatedUnload(completionMessage: String) async -> Bool {
        // Enter the coordinator before consulting idempotence. A second caller
        // must wait for an unload already in progress rather than returning
        // while the bridge is still being torn down.
        let acquired = await generationCoordinator.beginUnloadAcquiring()
        guard acquired else { return false }

        let shouldUnload = unloadRequested.withLock { alreadyRequested in
            guard !alreadyRequested else { return false }
            alreadyRequested = true
            return true
        }
        guard shouldUnload else {
            await generationCoordinator.endUnload()
            return false
        }

        // Another client may be finishing a request or changing bridge
        // ownership. Wait for the process-global bridge itself, not only this
        // client's coordinator, before checking and stopping its generation.
        let bridgeReservation = await Self.reserveLoopbackBridge()
        defer { bridgeReservation.release() }

        let lease = loopbackLease.withLock { current -> LoopbackLease? in
            defer { current = nil }
            return current
        }
        let stillOwnsLoopback = Self.stopLoopbackIfOwned(lease)

        if !stillOwnsLoopback, lease != nil {
            fputs("[NoemaLlamaClient] Unload skipped: loopback ownership moved to another model.\n", stderr)
        }
        await generationCoordinator.endUnload()
        fputs(completionMessage, stderr)
        return stillOwnsLoopback
    }

    /// Whether requests from this client hit a paged (Overfit) loopback
    /// server. The explicit StartConfiguration wins when it says paged;
    /// otherwise fall back to the live bridge snapshot for THIS model, then
    /// to the install shape itself. Clients constructed without a
    /// StartConfiguration (or with a stale non-paged copy) must still detect
    /// a paged session: any positive signal is enough, because pinning
    /// cache_prompt=true on a resident server matches the server default
    /// (harmless), while a false negative re-prefills the whole transcript
    /// every paged turn — minutes of TTFT on an overfit model.
    var isPagedLoopbackSession: Bool {
        if let pagedMode = serverConfiguration?.pagedMode, pagedMode != .off { return true }
        if let options = LlamaServerBridge.lastStartOptions(),
           options.ggufPath == modelURL.path,
           let rawMode = options.pagedMode, rawMode != 0 {
            return true
        }
        return PagedPackageLocator.isPagedInstall(modelURL)
    }

    private func loopbackStartConfiguration(mmprojPath: String?) -> LlamaServerBridge.StartConfiguration {
        if let serverConfiguration { return serverConfiguration }
        let threads = explicitThreadCount
            ?? max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))
        return TemplateDrivenModelSupport.loopbackStartConfiguration(
            modelURL: modelURL,
            ggufPath: modelURL.path,
            mmprojPath: mmprojPath,
            contextSize: contextLength,
            threads: threads,
            threadsBatch: threads
        )
    }
    
    public init(
        url: URL,
        contextLength: Int32 = 2048,
        mmprojPath: String? = nil,
        allowProjectorAutoDiscovery: Bool = true,
        threadCount: Int32? = nil,
        preferParameterContextOverEnvironment: Bool = false,
        forceFreshLoopback: Bool = false,
        serverConfiguration: LlamaServerBridge.StartConfiguration? = nil
    ) {
        self.modelURL = url
        self.contextLength = contextLength
        self.mmprojPath = mmprojPath
        self.allowProjectorAutoDiscovery = allowProjectorAutoDiscovery
        self.preferParameterContextOverEnvironment = preferParameterContextOverEnvironment
        self.forceFreshLoopback = forceFreshLoopback
        self.serverConfiguration = serverConfiguration
        if let threadCount, threadCount > 0 {
            self.explicitThreadCount = threadCount
        } else {
            self.explicitThreadCount = nil
        }
    }
    
    deinit {
        // `unload()` captures self weakly and cannot be relied on once deinit
        // has begun. Snapshot the value state and perform an ownership-checked
        // fallback without retaining or dereferencing this instance.
        let lease = loopbackLease.withLock { current -> LoopbackLease? in
            defer { current = nil }
            return current
        }
        guard lease != nil else { return }
        Task.detached(priority: .utility) {
            let bridgeReservation = await Self.reserveLoopbackBridge()
            defer { bridgeReservation.release() }
            _ = Self.stopLoopbackIfOwned(lease)
        }
    }
    
    // MARK: - Loading/Unloading
    
    public func load() async throws {
        let reservation = await Self.reserveLoopbackBridge()
        try await load(using: reservation)
    }

    private func load(using reservation: BridgeMutationReservation) async throws {
        try await Task.detached { [weak self] in
            defer { reservation.release() }
            guard let self else { return }
            guard reservation.isActive else {
                throw self.loopbackOwnershipError()
            }
            guard FileManager.default.fileExists(atPath: self.modelURL.path) else {
                throw NoemaLlamaError.invalidParameters
            }
            let requestedCtx = self.serverConfiguration?.contextSize ?? self.contextLength
            let nCtx = max(Int32(1), requestedCtx)
            self.effectiveContext = nCtx

            // Resolve projector (if any) so a lazy-start fallback can enable vision.
            self.effectiveMMProj = self.allowProjectorAutoDiscovery
                ? ((self.mmprojPath?.isEmpty == false ? self.mmprojPath : nil)
                    ?? ProjectorLocator.projectorPath(alongside: self.modelURL))
                : nil

            // Ensure the loopback server is running. ChatVM normally starts it during model load,
            // but we keep a defensive fallback here.
            if self.forceFreshLoopback, Int(LlamaServerBridge.port()) > 0 {
                LlamaServerBridge.stop()
                LoopbackVisionState.setEnabled(false)
                Self.activeLoopbackOwner.withLock { $0 = nil }
            }
            var port = Int(LlamaServerBridge.port())
            if port <= 0 {
                let startConfiguration = self.loopbackStartConfiguration(mmprojPath: self.effectiveMMProj)
                let fitAssessment = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
                    contextLength: Int(nCtx),
                    kvCacheEstimate: .resolved(from: startConfiguration),
                    runtimeConfiguration: .resolved(from: startConfiguration),
                    serverConfiguration: startConfiguration
                )
                if fitAssessment.status == .doesNotFit,
                   !UserDefaults.standard.bool(forKey: "bypassRAMCheck") {
                    throw NSError(
                        domain: "Noema",
                        code: 2003,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "Model likely exceeds memory budget. Lower context or choose a smaller quant.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                // No concrete server exists, so any published owner is stale.
                Self.activeLoopbackOwner.withLock { $0 = nil }
                let baselineFootprint = ModelRAMAdvisor.processFootprintBytes()
                let peakSampler = Task.detached(priority: .utility) {
                    var peak = baselineFootprint
                    while !Task.isCancelled {
                        peak = max(peak, ModelRAMAdvisor.processFootprintBytes())
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    return max(peak, ModelRAMAdvisor.processFootprintBytes())
                }
                port = Int(LlamaServerBridge.start(startConfiguration))
                peakSampler.cancel()
                let peakFootprint = await peakSampler.value
                if port > 0 {
                    if let exactBytes = fitAssessment.estimatedIncrementalBytes {
                        ModelRAMAdvisor.recordSuccessfulGGUFLaunch(
                            estimatedIncrementalBytes: exactBytes,
                            baselineFootprintBytes: baselineFootprint,
                            peakFootprintBytes: peakFootprint
                        )
                    }
                    LoopbackVisionState.setEnabled(true)
                }
            }
            if port <= 0 {
                let diagnostics = LlamaServerBridge.lastStartDiagnostics()
                throw NSError(
                    domain: "Noema",
                    code: 2001,
                    userInfo: [
                        NSLocalizedDescriptionKey: LoopbackStartupPlanner.formatFailureMessage(diagnostics)
                    ]
                )
            }

            try self.claimLoopbackLease(
                port: port,
                allowReplacingExistingOwner: self.forceFreshLoopback
            )

            if getenv("NOEMA_LLAMA_VERBOSE") != nil {
                let threads = self.serverConfiguration?.threads ?? self.explicitThreadCount ?? 0
                let mm = self.effectiveMMProj.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? (GGUFMetadata.hasMultimodalProjector(at: self.modelURL) ? "merged" : "none")
                fputs("[NoemaLlamaClient] Loopback ready port=\(port) gguf=\(self.modelURL.lastPathComponent) ctx=\(nCtx) threads=\(threads) mmproj=\(mm)\n", stderr)
            }
        }.value
    }
    
    public func unload() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            fputs("[NoemaLlamaClient] Unload requested. Waiting for active generation to finish...\n", stderr)
            _ = await self.performCoordinatedUnload(
                completionMessage: "[NoemaLlamaClient] Unloaded and resources released.\n"
            )
        }
        // Optionally allow the global backend to free when app is truly going idle via notification
    }

    // Explicit unload that only returns once resources are released.
    // Performs work off the main actor and coordinates with any in-flight unload.
    public func unloadAndWait() async {
        // Execute heavy teardown work on a utility-priority task.
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.performCoordinatedUnload(
                completionMessage: "[NoemaLlamaClient] Unloaded and resources released (awaited).\n"
            )
        }.value
    }

    // MARK: - Cancellation
    public func cancel() {
        Task { await loopbackSessionState.cancelActive() }
        // Killing the HTTP stream is not enough for Overfit paged (mode 2)
        // runs: the server only notices the disconnect when writing a chunk,
        // so a cancelled prefill would keep paging expert reads for minutes.
        // Fail the active generation at the runtime too (safe no-op when
        // nothing is generating).
        if isPagedLoopbackSession {
            LlamaServerBridge.pagedCancel()
        }
    }
    
    // MARK: - Text Generation
    
#if false
    public func textStream(
        from input: LLMInput,
        onPromptProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        // If configured to use the loopback server for all requests, bypass the runner.
        if routeAllViaLoopback {
            await generationCoordinator.acquireGeneration()
            if Task.isCancelled { await generationCoordinator.releaseGeneration(); throw CancellationError() }
            let releaseToken = GenerationReleaseToken(coordinator: generationCoordinator)
            let streamState = StreamState()
            return AsyncThrowingStream<String, Error>(bufferingPolicy: .bufferingOldest(16)) { @Sendable continuation in
                Task { [weak self, input, releaseToken, streamState] in
                    do {
                        guard let self = self else {
                            await releaseToken.release();
                            continuation.finish(throwing: NoemaLlamaError.invalidParameters)
                            return
                        }
                        let prompt = input.prompt
                        guard !prompt.isEmpty else {
                            await releaseToken.release();
                            continuation.finish(throwing: NoemaLlamaError.invalidParameters)
                            return
                        }
                        let imagePaths: [String] = {
                            switch input.content { case .multimodal(_, let paths): return paths; default: return [] }
                        }()
                        let responseText = try await self.generateViaLoopbackServer(prompt: prompt, imagePaths: imagePaths)
                        await streamState.markStarted()
                        for word in responseText.split(separator: " ") { continuation.yield(String(word) + " ") }
                        continuation.finish()
                        Task { await releaseToken.release() }
                    } catch {
                        Task { await logger.log("[Llama][ServerError] \(error.localizedDescription)") }
                        await releaseToken.release()
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { [releaseToken, streamState] _ in
                    Task { if await !streamState.hasStarted() { await releaseToken.release() } }
                }
            }
        }

        guard runner != nil else { throw NoemaLlamaError.invalidParameters }
        await generationCoordinator.acquireGeneration()
        if Task.isCancelled { await generationCoordinator.releaseGeneration(); throw CancellationError() }
        let releaseToken = GenerationReleaseToken(coordinator: generationCoordinator)
        let streamState = StreamState()

        return AsyncThrowingStream<String, Error>(bufferingPolicy: .bufferingOldest(16)) { @Sendable continuation in
            // Bridge llama.cpp callbacks into an async throwing stream. Tie stream lifetime
            // to underlying generation by cancelling the runner when the stream terminates.
            Task { [weak self, input, releaseToken, streamState] in
                do {
                    guard let self = self, let runner = self.runner else {
                        await releaseToken.release()
                        continuation.finish(throwing: NoemaLlamaError.invalidParameters)
                        return
                    }

                    let prompt = input.prompt
                    guard !prompt.isEmpty else {
                        await releaseToken.release()
                        continuation.finish(throwing: NoemaLlamaError.invalidParameters)
                        return
                    }

                    let imagePaths: [String]? = {
                        switch input.content {
                        case .multimodal(_, let paths):
                            return paths
                        default:
                            return nil
                        }
                    }()

                    // Log the prompt and any image attachments being sent to the model
                    let promptPreviewLimit = 1000
                    let promptPreview = prompt.count > promptPreviewLimit ? String(prompt.prefix(promptPreviewLimit)) + "… [truncated]" : prompt
                    let modelName = self.modelURL.lastPathComponent
                    // Build a comprehensive flag summary from env + load snapshot
                    let summary = Self.makeGenerationFlagSummary(
                        modelName: modelName,
                        ctx: self.effectiveContext > 0 ? self.effectiveContext : self.contextLength,
                        threads: self.effectiveThreads,
                        gpuLayers: self.effectiveGpuLayers,
                        mmproj: self.effectiveMMProj,
                        hasVisionOps: self.hasVisionOpsFlag,
                        probe: self.lastVisionProbe
                    )
                    Task { await logger.log("[Llama][Start] \(summary)") }
                    Task { await logger.log("[Llama][Prompt] \(promptPreview)") }
                    if let paths = imagePaths, !paths.isEmpty {
                        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
                        Task { await logger.log("[Llama][Images] count=\(paths.count) names=\(names.joined(separator: ", "))") }
                        // Log runtime probe details so mismatches are visible next to attachments
                        let mm = self.effectiveMMProj != nil ? URL(fileURLWithPath: self.effectiveMMProj!).lastPathComponent : (GGUFMetadata.hasMultimodalProjector(at: self.modelURL) ? "merged" : "none")
                        let probeDesc: String = {
                            switch self.lastVisionProbe {
                            case .OK: return "OK"
                            case .noProjector: return "noProjector"
                            case .unavailable: return "unavailable"
                            @unknown default: return "unknown"
                            }
                        }()
                        Task { await logger.log("[Images][Probe] compiled=\(self.hasVisionOpsFlag) mmproj=\(mm) result=\(probeDesc)") }
                    }

                    let serverVisionEnabled = LoopbackVisionState.isEnabled()
                    let loopbackAvailable = self.routeAllViaLoopback || serverVisionEnabled || Int(LlamaServerBridge.port()) > 0

                    // If images are present, prefer loopback because the in-process llama backend may not include vision ops on iOS.
                    if let paths = imagePaths, !paths.isEmpty, loopbackAvailable {
                        do {
                            let imgCount = paths.count
                            let reason = self.routeAllViaLoopback ? "all" : "vision-loopback"
                            Task { await logger.log("[Loopback] route reason=\(reason) images=\(imgCount) port=\(Int(LlamaServerBridge.port()))") }
                            let responseText = try await self.generateViaLoopbackServer(prompt: prompt, imagePaths: paths)
                            // Simulate streaming by chunking on whitespace
                            let words = responseText.split(separator: " ")
                            for word in words { continuation.yield(String(word) + " ") }
                            continuation.finish()
                            Task { await releaseToken.release() }
                            return
                        } catch {
                            Task { await logger.log("[Llama][ServerFallbackError] \(error.localizedDescription)") }
                            await releaseToken.release()
                            continuation.finish(throwing: error)
                            return
                        }
                    }

                    if let paths = imagePaths, !paths.isEmpty, !self.visionImagesSupported {
                        let reason: String = {
                            #if canImport(Foundation)
                            if let r = self.runner?.probeVision() {
                                switch r {
                                case .noProjector:
                                    return "Loaded model is missing a matching projector (.gguf). Place the projector next to the model or use merged VLM weights."
                                case .unavailable:
                                    return "This llama.cpp build lacks vision support (llava/clip not available). Use a vision-enabled build."
                                default:
                                    return "Vision is unavailable for this model/build. Ensure a vision-capable GGUF and matching projector are present."
                                }
                            }
                            #endif
                            return "Vision is unavailable for this model/build. Ensure a vision-capable GGUF and matching projector are present."
                        }()
                        await releaseToken.release()
                        continuation.finish(throwing: NSError(domain: "Llama", code: 1001, userInfo: [NSLocalizedDescriptionKey: reason]))
                        return
                    }
                    
                    // Route all requests via loopback when configured.
                    if loopbackAvailable {
                        do {
                            let imgCount = imagePaths?.count ?? 0
                            let reason = self.routeAllViaLoopback ? "all" : "vision-loopback"
                            Task { await logger.log("[Loopback] route reason=\(reason) images=\(imgCount) port=\(Int(LlamaServerBridge.port()))") }
                            let responseText = try await self.generateViaLoopbackServer(prompt: prompt, imagePaths: imagePaths ?? [])
                            // Simulate streaming by chunking on whitespace
                            let words = responseText.split(separator: " ")
                            for word in words { continuation.yield(String(word) + " ") }
                            continuation.finish()
                            Task { await releaseToken.release() }
                            return
                        } catch {
                            Task { await logger.log("[Llama][ServerFallbackError] \(error.localizedDescription)") }
                            await releaseToken.release()
                            continuation.finish(throwing: error)
                            return
                        }
                    }

                    // Run token generation on a background queue; stream tokens via callback
                    await streamState.markStarted()
                    var aggregated = ""
                    if let paths = imagePaths, !paths.isEmpty {
                        runner.generate(withPrompt: prompt, imagePaths: paths, maxTokens: 0, onToken: { token in
                            continuation.yield(token)
                            aggregated += token
                        }, onDone: {
                            let outPreviewLimit = 20000
                            let outPreview = aggregated.count > outPreviewLimit ? String(aggregated.prefix(outPreviewLimit)) + "… [truncated]" : aggregated
                            Task { await logger.log("[Llama][Result] \(outPreview)") }
                            continuation.finish()
                            Task { await releaseToken.release() }
                        }, onError: { error in
                            Task { await logger.log("[Llama][Error] \(error.localizedDescription)") }
                            Task { await releaseToken.release() }
                            continuation.finish(throwing: error)
                        })
                    } else {
                        runner.generate(withPrompt: prompt, maxTokens: 0, onToken: { token in
                            continuation.yield(token)
                            aggregated += token
                        }, onDone: {
                            let outPreviewLimit = 20000
                            let outPreview = aggregated.count > outPreviewLimit ? String(aggregated.prefix(outPreviewLimit)) + "… [truncated]" : aggregated
                            Task { await logger.log("[Llama][Result] \(outPreview)") }
                            continuation.finish()
                            Task { await releaseToken.release() }
                        }, onError: { error in
                            Task { await logger.log("[Llama][Error] \(error.localizedDescription)") }
                            Task { await releaseToken.release() }
                            continuation.finish(throwing: error)
                        })
                    }
                } catch {
                    Task { await logger.log("[Llama][Error] \(error.localizedDescription)") }
                    await releaseToken.release()
                    continuation.finish(throwing: error)
                }
            }
            // If the consumer cancels the task iterating this stream, terminate generation.
            continuation.onTermination = { [weak self, releaseToken, streamState] termination in
                Task {
                    if case .cancelled = termination {
                        await logger.log("[Llama][Cancel] Stream terminated by consumer")
                        self?.runner?.cancelCurrent()
                        if await !streamState.hasStarted() {
                            await releaseToken.release()
                        }
                    } else if await !streamState.hasStarted() {
                        await releaseToken.release()
                    }
                }
            }
        }
    }
#endif

    public func textStream(
        from input: LLMInput,
        onPromptProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        await generationCoordinator.acquireGeneration()
        if Task.isCancelled { await generationCoordinator.releaseGeneration(); throw CancellationError() }
        guard Self.beginBridgeGeneration() else {
            await generationCoordinator.releaseGeneration()
            throw loopbackOwnershipError()
        }
        let bridgeGenerationReservation = BridgeGenerationReservation()
        let releaseToken = GenerationReleaseToken(
            coordinator: generationCoordinator,
            onRelease: { bridgeGenerationReservation.release() }
        )
        let streamState = StreamState()

        return AsyncThrowingStream<String, Error>(
            bufferingPolicy: .bufferingOldest(BoundedLoopbackStreamEmitter.capacity)
        ) { @Sendable continuation in
            let generationTask = Task { [weak self, input, releaseToken, streamState] in
                do {
                    try Task.checkCancellation()
                    guard let self else {
                        await releaseToken.release()
                        continuation.finish(throwing: NoemaLlamaError.invalidParameters)
                        return
                    }
                    let hasContent: Bool = {
                        switch input.content {
                        case .plain(let text):
                            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        case .messages(let messages):
                            return !messages.isEmpty
                        case .multimodal(let text, let paths):
                            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !paths.isEmpty
                        case .multimodalMessages(let messages, let paths):
                            return !messages.isEmpty || !paths.isEmpty
                        }
                    }()
                    guard hasContent else {
                        await releaseToken.release()
                        continuation.finish(throwing: NoemaLlamaError.invalidParameters)
                        return
                    }
                    try Task.checkCancellation()
                    await streamState.markStarted()
                    try Task.checkCancellation()
                    _ = try await self.generateViaLoopbackServer(
                        input: input,
                        onToken: { chunk in
                            try await BoundedLoopbackStreamEmitter.yield(chunk, to: continuation)
                        },
                        onPromptProgress: onPromptProgress,
                        capturePolicy: .characterCount
                    )
                    continuation.finish()
                    await releaseToken.release()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        await releaseToken.release()
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    Task { await logger.log("[Loopback][Error] \(error.localizedDescription)") }
                    await releaseToken.release()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    generationTask.cancel()
                    self?.cancel()
                }
            }
        }
    }
    
    public func text(from input: LLMInput) async throws -> String {
        await generationCoordinator.acquireGeneration()
        if Task.isCancelled {
            await generationCoordinator.releaseGeneration()
            throw CancellationError()
        }
        guard Self.beginBridgeGeneration() else {
            await generationCoordinator.releaseGeneration()
            throw loopbackOwnershipError()
        }
        let reservation = BridgeGenerationReservation()
        let release = GenerationReleaseToken(
            coordinator: generationCoordinator,
            onRelease: { reservation.release() }
        )
        do {
            let result = try await generateViaLoopbackServer(
                input: input,
                forceNonStreaming: true,
                capturePolicy: .fullText
            )
            await release.release()
            return result.text ?? ""
        } catch {
            await release.release()
            throw UserFacingErrorFormatter.normalizedTransportError(error, context: .localModel)
        }
    }
}

// MARK: - Static Factory Method (LocalLLMClient compatibility)

extension NoemaLlamaClient {
    public static func llama(url: URL) async throws -> NoemaLlamaClient {
        let client = NoemaLlamaClient(url: url)
        try await client.load()
        return client
    }
    
    public static func llama(
        url: URL,
        parameter: LlamaParameter
    ) async throws -> NoemaLlamaClient {
        let context = parameter.contextLength ?? 2048
        let context32 = Int32(clamping: max(1, context))
        let threadOverride = parameter.threadCount.flatMap { value -> Int32? in
            guard value > 0 else { return nil }
            return Int32(clamping: value)
        }
        let client = NoemaLlamaClient(
            url: url,
            contextLength: context32,
            mmprojPath: parameter.mmproj,
            allowProjectorAutoDiscovery: parameter.loadVisionProjector,
            threadCount: threadOverride,
            preferParameterContextOverEnvironment: parameter.preferContextOverEnvironment,
            forceFreshLoopback: parameter.forceFreshLoopback,
            serverConfiguration: parameter.serverConfiguration
        )
        try await client.load()
        return client
    }

    static func llama(
        url: URL,
        parameter: LlamaParameter,
        bridgeReservation: BridgeMutationReservation
    ) async throws -> NoemaLlamaClient {
        let context = parameter.contextLength ?? 2048
        let context32 = Int32(clamping: max(1, context))
        let threadOverride = parameter.threadCount.flatMap { value -> Int32? in
            guard value > 0 else { return nil }
            return Int32(clamping: value)
        }
        let client = NoemaLlamaClient(
            url: url,
            contextLength: context32,
            mmprojPath: parameter.mmproj,
            allowProjectorAutoDiscovery: parameter.loadVisionProjector,
            threadCount: threadOverride,
            preferParameterContextOverEnvironment: parameter.preferContextOverEnvironment,
            forceFreshLoopback: parameter.forceFreshLoopback,
            serverConfiguration: parameter.serverConfiguration
        )
        try await client.load(using: bridgeReservation)
        return client
    }
}

// MARK: - Parameter Types (LocalLLMClient compatibility)

public struct LlamaParameter {
    public let contextLength: Int?
    public let options: LlamaOptions?
    public let threadCount: Int?
    public let mmproj: String?
    public let loadVisionProjector: Bool
    public let preferContextOverEnvironment: Bool
    public let forceFreshLoopback: Bool
    public let serverConfiguration: LlamaServerBridge.StartConfiguration?
    
    public init(
        options: LlamaOptions? = nil,
        contextLength: Int? = nil,
        threadCount: Int? = nil,
        mmproj: String? = nil,
        loadVisionProjector: Bool = true,
        preferContextOverEnvironment: Bool = false,
        forceFreshLoopback: Bool = false,
        serverConfiguration: LlamaServerBridge.StartConfiguration? = nil
    ) {
        self.options = options
        self.contextLength = contextLength
        self.threadCount = threadCount
        self.mmproj = mmproj
        self.loadVisionProjector = loadVisionProjector
        self.preferContextOverEnvironment = preferContextOverEnvironment
        self.forceFreshLoopback = forceFreshLoopback
        self.serverConfiguration = serverConfiguration
    }
}

public struct LlamaOptions {
    public let extraEOSTokens: [String]
    public let verbose: Bool
    
    public init(extraEOSTokens: [String] = [], verbose: Bool = false) {
        self.extraEOSTokens = extraEOSTokens
        self.verbose = verbose
        if verbose { setenv("NOEMA_LLAMA_VERBOSE", "1", 1) }
    }
}

// MARK: - AnyLLMClient Wrapper

public struct AnyLLMClient: Sendable {
    private let textStreamClosure: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error>
    private let textStreamWithProgressClosure: @Sendable (LLMInput, (@Sendable (Double) -> Void)?) async throws -> AsyncThrowingStream<String, Error>
    private let textClosure: @Sendable (LLMInput) async throws -> String
    private let tokenCountClosure: (@Sendable (String) async throws -> Int)?
    private let cancelClosure: (@Sendable () -> Void)?
    private let unloadClosure: (@Sendable () -> Void)?
    private let unloadAsyncClosure: (@Sendable () async -> Void)?
    private let resetClosure: (@Sendable () async -> Void)?
    private let syncSystemPromptClosure: (@Sendable (String?) async -> Void)?
    private let runtimeIsCurrentClosure: (@Sendable () -> Bool)?
    private let finishReasonClosure: (@Sendable () -> String?)?
    
    public init(_ client: NoemaLlamaClient) {
        let streamWithProgressClosure: @Sendable (LLMInput, (@Sendable (Double) -> Void)?) async throws -> AsyncThrowingStream<String, Error> = { input, onPromptProgress in
            try await client.textStream(from: input, onPromptProgress: onPromptProgress)
        }
        let streamClosure: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error> = { input in
            try await streamWithProgressClosure(input, nil)
        }
        self.textStreamWithProgressClosure = streamWithProgressClosure
        self.textStreamClosure = streamClosure
        self.textClosure = { input in
            var result = ""
            for try await token in try await streamClosure(input) {
                result += token
            }
            return result
        }
        self.tokenCountClosure = nil
        self.cancelClosure = { [weak client] in client?.cancel() }
        self.unloadClosure = { [weak client] in client?.unload() }
        self.unloadAsyncClosure = { [weak client] in await client?.unloadAndWait() }
        self.resetClosure = nil
        self.syncSystemPromptClosure = nil
        self.runtimeIsCurrentClosure = { [weak client] in
            client?.isCurrentLoopbackOwner() ?? false
        }
        self.finishReasonClosure = { [weak client] in
            client?.mostRecentFinishReason()
        }
    }
    
    // Removed LocalLLMClient bridging initializer to avoid undefined symbols
    
    

    @available(macOS 13.0, iOS 16.0, *)
    public init(_ client: MLXTextClient) {
        let streamClosure: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error> = { input in
            try await client.textStream(from: input)
        }
        self.textStreamWithProgressClosure = { input, _ in
            try await streamClosure(input)
        }
        self.textStreamClosure = streamClosure
        self.textClosure = { input in
            var result = ""
            for try await token in try await streamClosure(input) {
                result += token
            }
            return result
        }
        self.tokenCountClosure = nil
        self.cancelClosure = { client.cancel() }
        self.unloadClosure = { [weak client] in client?.unload() }
        self.unloadAsyncClosure = nil
        self.resetClosure = { [weak client] in client?.resetPromptCache() }
        self.syncSystemPromptClosure = nil
        self.runtimeIsCurrentClosure = nil
        self.finishReasonClosure = nil
    }

    @available(macOS 13.0, iOS 16.0, *)
    public init(_ client: MLXVLMClient) {
        let streamClosure: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error> = { input in
            try await client.textStream(from: input)
        }
        self.textStreamWithProgressClosure = { input, _ in
            try await streamClosure(input)
        }
        self.textStreamClosure = streamClosure
        self.textClosure = { input in
            var result = ""
            for try await token in try await streamClosure(input) {
                result += token
            }
            return result
        }
        self.tokenCountClosure = nil
        self.cancelClosure = { client.cancel() }
        self.unloadClosure = { [weak client] in client?.unload() }
        self.unloadAsyncClosure = nil
        self.resetClosure = nil
        self.syncSystemPromptClosure = nil
        self.runtimeIsCurrentClosure = nil
        self.finishReasonClosure = nil
    }

    // Convenience initializer to build a failing client for unimplemented adapters.
    public static func makeFailing(message: String) -> AnyLLMClient {
        let stream: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error> = { _ in
            AsyncThrowingStream<String, Error> { continuation in
                continuation.finish(throwing: NSError(domain: "Noema", code: -999, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
        return AnyLLMClient(unsafeStream: stream)
    }

    static func makeDeterministicFake(
        chunks: [String],
        delayNanoseconds: UInt64 = 0,
        finishReason: String? = nil,
        probe: DeterministicLLMClientProbe = DeterministicLLMClientProbe()
    ) -> AnyLLMClient {
        let stream: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error> = { input in
            probe.record(input: input)
            return AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    for chunk in chunks {
                        if Task.isCancelled || probe.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.yield(chunk)
                        if delayNanoseconds > 0 {
                            do {
                                try await Task.sleep(nanoseconds: delayNanoseconds)
                            } catch {
                                continuation.finish(throwing: CancellationError())
                                return
                            }
                        } else {
                            await Task.yield()
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }
        return AnyLLMClient(
            textStream: stream,
            textStreamWithProgress: { input, onPromptProgress in
                onPromptProgress?(0)
                let result = try await stream(input)
                onPromptProgress?(1)
                return result
            },
            cancel: {
                probe.cancel()
            },
            unload: {
                probe.recordUnload()
            },
            unloadAsync: {
                probe.recordAsyncUnload()
            },
            reset: {
                probe.reset()
            },
            finishReason: {
                finishReason
            },
            tokenCount: { text in
                max(1, text.split { $0.isWhitespace || $0.isNewline }.count)
            }
        )
    }

    // Unsafe convenience init to build AnyLLMClient from a custom stream.
    init(unsafeStream: @escaping @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error>) {
        self.textStreamWithProgressClosure = { input, _ in
            try await unsafeStream(input)
        }
        self.textStreamClosure = unsafeStream
        self.textClosure = { input in
            var result = ""
            for try await token in try await unsafeStream(input) {
                result += token
            }
            return result
        }
        self.tokenCountClosure = nil
        self.cancelClosure = nil
        self.unloadClosure = nil
        self.unloadAsyncClosure = nil
        self.resetClosure = nil
        self.syncSystemPromptClosure = nil
        self.runtimeIsCurrentClosure = nil
        self.finishReasonClosure = nil
    }

    public init(
        textStream: @escaping @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error>,
        textStreamWithProgress: (@Sendable (LLMInput, (@Sendable (Double) -> Void)?) async throws -> AsyncThrowingStream<String, Error>)? = nil,
        text: (@Sendable (LLMInput) async throws -> String)? = nil,
        cancel: (@Sendable () -> Void)? = nil,
        unload: (@Sendable () -> Void)? = nil,
        unloadAsync: (@Sendable () async -> Void)? = nil,
        reset: (@Sendable () async -> Void)? = nil,
        syncSystemPrompt: (@Sendable (String?) async -> Void)? = nil,
        runtimeIsCurrent: (@Sendable () -> Bool)? = nil,
        finishReason: (@Sendable () -> String?)? = nil,
        tokenCount: (@Sendable (String) async throws -> Int)? = nil
    ) {
        self.textStreamClosure = textStream
        self.textStreamWithProgressClosure = textStreamWithProgress ?? { input, _ in
            try await textStream(input)
        }
        if let text {
            self.textClosure = text
        } else {
            self.textClosure = { input in
                var result = ""
                for try await token in try await textStream(input) {
                    result += token
                }
                return result
            }
        }
        self.tokenCountClosure = tokenCount
        self.cancelClosure = cancel
        self.unloadClosure = unload
        self.unloadAsyncClosure = unloadAsync
        self.resetClosure = reset
        self.syncSystemPromptClosure = syncSystemPrompt
        self.runtimeIsCurrentClosure = runtimeIsCurrent
        self.finishReasonClosure = finishReason
    }
    
    public func textStream(from input: LLMInput) async throws -> AsyncThrowingStream<String, Error> {
        try await textStreamClosure(input)
    }

    public func textStream(
        from input: LLMInput,
        onPromptProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await textStreamWithProgressClosure(input, onPromptProgress)
    }
    
    public func text(from input: LLMInput) async throws -> String {
        try await textClosure(input)
    }

    public func countTokens(in text: String) async -> Int? {
        guard let tokenCountClosure else { return nil }
        return try? await tokenCountClosure(text)
    }

    public func cancelActive() {
        cancelClosure?()
    }

    public func unload() {
        unloadClosure?()
    }

    public func unloadAndWait() async {
        if let unloadAsyncClosure {
            await unloadAsyncClosure()
        } else {
            unloadClosure?()
        }
    }

    public func reset() async {
        await resetClosure?()
    }

    public func syncSystemPrompt(_ prompt: String?) async {
        await syncSystemPromptClosure?(prompt)
    }

    /// `nil` for instance-scoped backends; GGUF returns whether its exact UUID
    /// lease still owns the process-global loopback generation.
    func isCurrentRuntime() -> Bool? {
        runtimeIsCurrentClosure?()
    }

    /// OpenAI-style reason reported by the last completed generation when the
    /// backend exposes it (`stop`, `length`, or `tool_calls`).
    func mostRecentFinishReason() -> String? {
        finishReasonClosure?()
    }

    // Reset behavior is backend dependent.
}

final class DeterministicLLMClientProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedInputs: [LLMInput] = []
    private var cancelled = false
    private var unloads = 0
    private var asyncUnloads = 0
    private var resets = 0

    var inputs: [LLMInput] {
        lock.lock()
        defer { lock.unlock() }
        return capturedInputs
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var unloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unloads
    }

    var asyncUnloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return asyncUnloads
    }

    var resetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resets
    }

    func record(input: LLMInput) {
        lock.lock()
        capturedInputs.append(input)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func recordUnload() {
        lock.lock()
        unloads += 1
        lock.unlock()
    }

    func recordAsyncUnload() {
        lock.lock()
        asyncUnloads += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        resets += 1
        lock.unlock()
    }
}

// MARK: - Loopback server multimodal fallback (member of NoemaLlamaClient)
extension NoemaLlamaClient {
    private struct LoopbackChatChunk: Decodable {
        struct PromptProgress: Decodable {
            let total: Int?
            let cache: Int?
            let processed: Int?
            let timeMs: Int64?

            enum CodingKeys: String, CodingKey {
                case total
                case cache
                case processed
                case timeMs = "time_ms"
            }
        }

        // One streamed/complete tool call fragment from the server (OpenAI shape).
        // In streaming mode `function.arguments` arrives as string fragments to be
        // concatenated per `index`; `function.name` typically arrives once.
        struct ToolCallFragment: Decodable {
            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }
            let index: Int?
            let id: String?
            let function: Function?
        }

        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoningContent: String?
                let toolCalls: [ToolCallFragment]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                    case toolCalls = "tool_calls"
                }
            }

            struct Message: Decodable {
                let content: String?
                let reasoningContent: String?
                let toolCalls: [ToolCallFragment]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                    case toolCalls = "tool_calls"
                }
            }

            let delta: Delta?
            let message: Message?
            let text: String?
            let completion: String?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case message
                case text
                case completion
                case finishReason = "finish_reason"
            }
        }

        let choices: [Choice]
        let promptProgress: PromptProgress?
        let timings: LoopbackSpeculativeTimings?

        enum CodingKeys: String, CodingKey {
            case choices
            case promptProgress = "prompt_progress"
            case timings
        }
    }

    /// Response chunk from the raw `/completion` endpoint (non-OAI format).
    private struct LoopbackCompletionChunk: Decodable {
        let content: String?
        let stop: Bool?
        let stopType: String?
        let truncated: Bool?
        let timings: LoopbackSpeculativeTimings?

        enum CodingKeys: String, CodingKey {
            case content
            case stop
            case stopType = "stop_type"
            case truncated
            case timings
        }
    }

    private struct LoopbackErrorEnvelope: Decodable {
        struct LoopbackError: Decodable {
            let message: String?
        }

        let error: LoopbackError?
    }

    struct LoopbackRequestPlan {
        let endpoint: String
        let body: [String: Any]
        let imagePaths: [String]
        let requestMode: String
    }

    struct LoopbackImagePayload {
        let data: Data
        let mime: String
        let pixelWidth: Int
        let pixelHeight: Int
        let originalPixelWidth: Int?
        let originalPixelHeight: Int?
        let wasClamped: Bool
        let suspiciouslyLargeSource: Bool
    }

    private func makeLoopbackImageObject(from path: String) -> [String: Any] {
        let payload = loopbackImagePayload(for: path)
        let b64 = payload.data.base64EncodedString()
        return [
            "type": "image_url",
            "image_url": ["url": "data:\(payload.mime);base64,\(b64)"]
        ]
    }

    private func buildLoopbackChatMessages(from messages: [ChatMessage]) -> [[String: Any]] {
        messages.map { message in
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
            } else {
                payload["content"] = message.content
            }

            if let toolCallId = message.toolCallId,
               !toolCallId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload["tool_call_id"] = toolCallId
            }

            return payload
        }
    }

    /// Server-side context-shift anchor matching the user's overflow strategy.
    /// When generation reaches n_ctx the server discards tokens after the first
    /// `n_keep`: -1 keeps the whole prompt (truncate-middle: drop oldest generated
    /// tokens), 0 keeps nothing (rolling window: drop the oldest tokens overall).
    /// Stop at Limit runs the server with context shift disabled instead.
    private var contextOverflowNKeep: Int? {
        let raw = UserDefaults.standard.string(forKey: "contextOverflowStrategy") ?? ""
        switch ContextOverflowStrategy.from(raw) {
        case .truncateMiddle: return -1
        case .rollingWindow: return 0
        case .stopAtLimit: return nil
        }
    }

    private func applyGenerationOptions(_ options: LLMGenerationOptions, to body: inout [String: Any]) {
        if let nKeep = contextOverflowNKeep {
            body["n_keep"] = nKeep
        }
        if let maxOutputTokens = options.maxOutputTokens {
            let clamped = max(1, maxOutputTokens)
            body["n_predict"] = clamped
            body["max_tokens"] = clamped
        }
        if let thinkingBudgetTokens = options.thinkingBudgetTokens {
            body["thinking_budget_tokens"] = max(0, thinkingBudgetTokens)
        }
        if let responseFormat = options.responseFormat {
            body["response_format"] = responseFormat.requestPayload
        }
        if let seed = options.seed { body["seed"] = seed }
        if let temperature = options.temperature { body["temperature"] = temperature }
        if let topK = options.topK { body["top_k"] = topK }
        if let topP = options.topP { body["top_p"] = topP }
        if let minP = options.minP { body["min_p"] = minP }
        if let repeatPenalty = options.repeatPenalty { body["repeat_penalty"] = repeatPenalty }
        if let repeatLastN = options.repeatLastN { body["repeat_last_n"] = repeatLastN }
        if let presencePenalty = options.presencePenalty { body["presence_penalty"] = presencePenalty }
        if let frequencyPenalty = options.frequencyPenalty { body["frequency_penalty"] = frequencyPenalty }
        if let logitBias = options.logitBias, !logitBias.isEmpty {
            body["logit_bias"] = Dictionary(
                uniqueKeysWithValues: logitBias.map { (String($0.key), $0.value) }
            )
        }
        if options.requestPurpose == .auxiliary {
            // Never restore or publish the conversation slot for an internal
            // summarization/classification request. The next user-visible turn
            // will establish the durable prompt state again.
            body["cache_prompt"] = false
        } else if isPagedLoopbackSession {
            // Paged launches run with cache-ram 0 but ctx-checkpoints ON
            // (hybrid architectures cannot roll a sequence back partially, so
            // a restored checkpoint is the only route to prefix reuse). Both
            // slot prefix reuse and checkpoint restore are gated per-request
            // by `cache_prompt`. The options seed derives from
            // settings.promptCacheEnabled (off in several presets), and
            // sending false here makes every paged turn re-prefill the entire
            // transcript — minutes of TTFT per follow-up on an overfit model.
            // Reuse costs nothing, so always ask for it — and detect "paged"
            // robustly (isPagedLoopbackSession), not only via this instance's
            // StartConfiguration copy.
            body["cache_prompt"] = true
        } else if let promptCache = options.promptCache {
            body["cache_prompt"] = promptCache
        }
    }

    /// One self-explaining line per paged completion: whether the slot prefix
    /// was reused (prompt_n/cache_n and the first progress report), whether
    /// wave-split prefill engaged (waveCount, and if not, WHY via the
    /// runtime's wavesRejectedReason), and the expert-I/O cost of the prefill
    /// (prefillBytesRead, hits/misses). This is the line a user log needs to
    /// diagnose paged TTFT without a debugger.
    private func logPagedCompletionTelemetry(
        timings: LoopbackSpeculativeTimings?,
        promptCached: Int?,
        promptTotal: Int?
    ) {
        var waveCount: Int64 = -1
        var prefillBytesRead: Int64 = -1
        var hits: Int64 = -1
        var misses: Int64 = -1
        var decodeHits: Int64 = -1
        var decodeMisses: Int64 = -1
        var decodeBytes: Int64 = -1
        var decodeStallNs: Int64 = -1
        var historyPredictions: Int64 = -1
        var historyPredictionMatches: Int64 = -1
        var checksumVerifications: Int64 = -1
        var checksumCacheHits: Int64 = -1
        var wavesReason = "unavailable"
        if let raw = LlamaServerBridge.pagedStatsJSON(),
           let data = raw.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let stream = json["stream"] as? [String: Any] {
            wavesReason = (stream["wavesRejectedReason"] as? String) ?? "unavailable"
            let phases = json["phases"] as? [String: Any]
            let decode = phases?["ordinaryDecode"] as? [String: Any]
            // The runtime's counters are boot-cumulative (reset only at server
            // teardown), so a turn-2 line would otherwise repeat turn-1's
            // multi-GB prefill — the exact signature of the re-prefill bug
            // this line exists to rule out. Diff against the previous
            // completion; a counter that shrank means the server restarted,
            // in which case the raw value is itself the per-completion figure.
            let current = PagedTelemetrySnapshot(
                waves: (stream["waveCount"] as? NSNumber)?.int64Value ?? -1,
                prefillBytes: (stream["prefillBytesRead"] as? NSNumber)?.int64Value ?? -1,
                hits: (stream["hits"] as? NSNumber)?.int64Value ?? -1,
                misses: (stream["misses"] as? NSNumber)?.int64Value ?? -1,
                decodeHits: (decode?["hits"] as? NSNumber)?.int64Value ?? -1,
                decodeMisses: (decode?["misses"] as? NSNumber)?.int64Value ?? -1,
                decodeBytes: (decode?["bytesRead"] as? NSNumber)?.int64Value ?? -1,
                decodeStallNs: (decode?["stallNs"] as? NSNumber)?.int64Value ?? -1,
                historyPredictions: (stream["historyPredictions"] as? NSNumber)?.int64Value ?? -1,
                historyPredictionMatches: (stream["historyPredictionMatches"] as? NSNumber)?.int64Value ?? -1,
                checksumVerifications: (stream["checksumVerifications"] as? NSNumber)?.int64Value ?? -1,
                checksumCacheHits: (stream["checksumCacheHits"] as? NSNumber)?.int64Value ?? -1
            )
            let previous = pagedTelemetrySnapshot.withLock { snapshot -> PagedTelemetrySnapshot? in
                let held = snapshot
                snapshot = current
                return held
            }
            func perCompletion(_ cur: Int64, _ prev: Int64?) -> Int64 {
                guard cur >= 0 else { return cur }
                guard let prev, prev >= 0, cur >= prev else { return cur }
                return cur - prev
            }
            waveCount = perCompletion(current.waves, previous?.waves)
            prefillBytesRead = perCompletion(current.prefillBytes, previous?.prefillBytes)
            hits = perCompletion(current.hits, previous?.hits)
            misses = perCompletion(current.misses, previous?.misses)
            decodeHits = perCompletion(current.decodeHits, previous?.decodeHits)
            decodeMisses = perCompletion(current.decodeMisses, previous?.decodeMisses)
            decodeBytes = perCompletion(current.decodeBytes, previous?.decodeBytes)
            decodeStallNs = perCompletion(current.decodeStallNs, previous?.decodeStallNs)
            historyPredictions = perCompletion(
                current.historyPredictions, previous?.historyPredictions)
            historyPredictionMatches = perCompletion(
                current.historyPredictionMatches, previous?.historyPredictionMatches)
            checksumVerifications = perCompletion(
                current.checksumVerifications, previous?.checksumVerifications)
            checksumCacheHits = perCompletion(
                current.checksumCacheHits, previous?.checksumCacheHits)
        }
        let promptN = timings?.promptN.map(String.init) ?? "-"
        let cacheN = timings?.cacheN.map(String.init) ?? "-"
        let progress = "\(promptCached.map(String.init) ?? "-")/\(promptTotal.map(String.init) ?? "-")"
        let line = "[Loopback][PagedTelemetry] prompt_n=\(promptN) cache_n=\(cacheN)"
            + " progress_cached=\(progress) waves=\(waveCount) waves_reason=\(wavesReason)"
            + " prefill_bytes=\(prefillBytesRead) stream_hits=\(hits) stream_misses=\(misses)"
            + " decode_hits=\(decodeHits) decode_misses=\(decodeMisses)"
            + " decode_bytes=\(decodeBytes) decode_stall_ms=\(decodeStallNs >= 0 ? decodeStallNs / 1_000_000 : -1)"
            + " history_predictions=\(historyPredictions) history_matches=\(historyPredictionMatches)"
            + " checksum_verified=\(checksumVerifications) checksum_cached=\(checksumCacheHits)"
        Task { await logger.log(line) }
    }

    private func buildLoopbackChatBody(
        messages: [[String: Any]],
        forceNonStreaming: Bool,
        options: LLMGenerationOptions
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": self.modelURL.lastPathComponent,
            "messages": messages,
            "stream": !forceNonStreaming,
            "n_predict": -1,
            "return_progress": true,
        ]
        if !forceNonStreaming {
            body["stream_options"] = ["include_usage": true]
        }
        var templateKwargs: [String: Bool] = [:]
        let reasoningEnabled = options.reasoningEnabled ?? true
        if isQwen35Model, reasoningEnabled {
            // Ask the server to split <think> reasoning into reasoning_content for the
            // profiles whose parsing we trust; other reasoning models stream <think>
            // inline and the app's own parser separates it.
            body["reasoning_format"] = "deepseek"
        }
        // enable_thinking is a harmless no-op for templates that don't branch on it, so
        // send it for every GGUF: any thinking-capable model then honors the user's
        // reasoning toggle (ReasoningCapabilityDetector only surfaces the control when the
        // template actually reads this kwarg).
        templateKwargs["enable_thinking"] = reasoningEnabled
        // llama.cpp chat-template kwarg: when true, prior assistant turns' reasoning
        // (<think>/reasoning_content) is kept in the serialized prompt instead of being
        // dropped, so the model can build on its own earlier thinking across turns
        // (measurably better multi-turn reasoning recall, at a small prompt-token cost).
        // Global user setting; default ON. Harmless for templates that don't read it.
        let preserveThinking = (UserDefaults.standard.object(forKey: "preserveThinking") as? Bool) ?? true
        templateKwargs["preserve_thinking"] = preserveThinking
        if !templateKwargs.isEmpty {
            body["chat_template_kwargs"] = templateKwargs
        }
        if usesTemplateDrivenMessages {
            body["add_generation_prompt"] = true
        }
        // Native tool calling: pass the OpenAI-style tools array so the server's Jinja
        // template renders tool schemas and the model emits its native tool-call format
        // (returned as structured tool_calls, consumed in emitChoice). Requires --jinja.
        // Sort by tool name: the server parses request JSON as ordered_json, so the
        // tools' array order flows byte-for-byte into the rendered prompt. Registry
        // enumeration order is not stable across catalog rebuilds, and an unstable
        // tools section breaks the slot KV common prefix at the very start of the
        // prompt — every turn then re-prefills the full transcript.
        if let tools = options.tools, !tools.isEmpty,
           let data = try? JSONEncoder().encode(tools.sorted(by: { $0.function.name < $1.function.name })),
           let toolsArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            body["tools"] = toolsArray
            body["tool_choice"] = "auto"
        }
        applyGenerationOptions(options, to: &body)
        return body
    }

    private func buildLoopbackMultimodalMessages(from messages: [ChatMessage], imagePaths: [String]) -> [[String: Any]] {
        var payloads = buildLoopbackChatMessages(from: messages)
        var content: [[String: Any]] = []

        if let userIndex = payloads.lastIndex(where: { (($0["role"] as? String) ?? "").lowercased() == "user" }) {
            if let text = payloads[userIndex]["content"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content.append(["type": "text", "text": text])
            }
            content.append(contentsOf: imagePaths.map(makeLoopbackImageObject(from:)))
            payloads[userIndex]["content"] = content
            return payloads
        }

        content.append(contentsOf: imagePaths.map(makeLoopbackImageObject(from:)))
        payloads.append([
            "role": "user",
            "content": content
        ])
        return payloads
    }

    func buildLoopbackRequestPlan(for input: LLMInput, forceNonStreaming: Bool) -> LoopbackRequestPlan {
        switch input.content {
        case .plain(let prompt):
            var body: [String: Any] = [
                "prompt": prompt,
                "stream": !forceNonStreaming,
                "n_predict": -1,
                "return_progress": true,
            ]
            applyGenerationOptions(input.generationOptions, to: &body)
            return LoopbackRequestPlan(
                endpoint: "/completion",
                body: body,
                imagePaths: [],
                requestMode: "completion"
            )
        case .messages(let messages):
            let body = buildLoopbackChatBody(
                messages: buildLoopbackChatMessages(from: messages),
                forceNonStreaming: forceNonStreaming,
                options: input.generationOptions
            )
            return LoopbackRequestPlan(
                endpoint: "/v1/chat/completions",
                body: body,
                imagePaths: [],
                requestMode: "chat_completions"
            )
        case .multimodal(let prompt, let paths):
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            content.append(contentsOf: paths.map(makeLoopbackImageObject(from:)))
            var body = buildLoopbackChatBody(
                messages: [["role": "user", "content": content]],
                forceNonStreaming: forceNonStreaming,
                options: input.generationOptions
            )
            body["speculative"] = false
            return LoopbackRequestPlan(
                endpoint: "/v1/chat/completions",
                body: body,
                imagePaths: paths,
                requestMode: "chat_completions"
            )
        case .multimodalMessages(let messages, let paths):
            var body = buildLoopbackChatBody(
                messages: buildLoopbackMultimodalMessages(from: messages, imagePaths: paths),
                forceNonStreaming: forceNonStreaming,
                options: input.generationOptions
            )
            body["speculative"] = false
            return LoopbackRequestPlan(
                endpoint: "/v1/chat/completions",
                body: body,
                imagePaths: paths,
                requestMode: "chat_completions"
            )
        }
    }

    func loopbackImagePayload(for path: String) -> LoopbackImagePayload {
        let fileURL = URL(fileURLWithPath: path)
        let ext = fileURL.pathExtension.lowercased()

        if let data = try? Data(contentsOf: fileURL),
           let normalized = AttachmentImageNormalizer.normalizeAttachmentData(data) {
            let originalWidth = normalized.originalPixelWidth ?? normalized.pixelWidth
            let originalHeight = normalized.originalPixelHeight ?? normalized.pixelHeight
            Task {
                await logger.log(
                    "[Images][Reencode] src=\(ext) original=\(originalWidth)x\(originalHeight) normalized=\(normalized.pixelWidth)x\(normalized.pixelHeight) clamped=\(normalized.wasClamped) suspicious=\(normalized.suspiciouslyLargeSource) bytes=\(normalized.data.count) name=\(fileURL.lastPathComponent)"
                )
            }
            return LoopbackImagePayload(
                data: normalized.data,
                mime: "image/jpeg",
                pixelWidth: normalized.pixelWidth,
                pixelHeight: normalized.pixelHeight,
                originalPixelWidth: normalized.originalPixelWidth,
                originalPixelHeight: normalized.originalPixelHeight,
                wasClamped: normalized.wasClamped,
                suspiciouslyLargeSource: normalized.suspiciouslyLargeSource
            )
        }

        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        let metadata = AttachmentImageNormalizer.metadata(forFileAt: fileURL)
        let mime: String
        switch ext {
        case "png":
            mime = "image/png"
        case "jpg", "jpeg":
            mime = "image/jpeg"
        case "webp":
            mime = "image/webp"
        default:
            mime = "image/jpeg"
        }
        Task {
            await logger.log(
                "[Images][Reencode] fallback src=\(ext) original=\(metadata?.pixelWidth ?? 0)x\(metadata?.pixelHeight ?? 0) normalized=\(metadata?.pixelWidth ?? 0)x\(metadata?.pixelHeight ?? 0) clamped=false suspicious=\(((metadata?.fileBytes) ?? data.count) > AttachmentImageNormalizer.suspiciousFileSizeBytes) bytes=\(data.count) name=\(fileURL.lastPathComponent)"
            )
        }
        return LoopbackImagePayload(
            data: data,
            mime: mime,
            pixelWidth: metadata?.pixelWidth ?? 0,
            pixelHeight: metadata?.pixelHeight ?? 0,
            originalPixelWidth: metadata?.pixelWidth,
            originalPixelHeight: metadata?.pixelHeight,
            wasClamped: false,
            suspiciouslyLargeSource: ((metadata?.fileBytes) ?? data.count) > AttachmentImageNormalizer.suspiciousFileSizeBytes
        )
    }

    private func loopbackStillLoadingError() -> NSError {
        NSError(
            domain: "Noema",
            code: 2004,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "The on-device model is still loading. Please try again in a moment.",
                    locale: LocalizationManager.preferredLocale()
                )
            ]
        )
    }

    private func bridgeReportsLoopbackReady(expectedPort: Int?) -> Bool {
        let bridgePort = Int(LlamaServerBridge.port())
        guard bridgePort > 0 else { return false }
        if let expectedPort, expectedPort > 0, bridgePort != expectedPort {
            return false
        }
        if LlamaServerBridge.isLoading() {
            return false
        }
        return LlamaServerBridge.loadProgress() >= 0.999
    }

    private func probeLoopbackHealthStatus(baseURL: URL) async -> Int? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.loopbackReadyProbeRequestTimeout
        configuration.timeoutIntervalForResource = Self.loopbackReadyProbeRequestTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        defer { session.finishTasksAndInvalidate() }

        for path in ["health", "v1/health"] {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "GET"
            request.timeoutInterval = Self.loopbackReadyProbeRequestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    return http.statusCode
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func waitForLoopbackReady(baseURL: URL, timeout: TimeInterval) async -> LoopbackReadyProbeResult {
        let expectedPort = baseURL.port
        return await LoopbackReadinessProbe.run(
            timeout: timeout,
            intervalNanos: Self.loopbackReadyProbeIntervalNanos,
            bridgeReady: { [weak self] in
                self?.bridgeReportsLoopbackReady(expectedPort: expectedPort) ?? false
            },
            healthStatus: { [weak self] in
                await self?.probeLoopbackHealthStatus(baseURL: baseURL)
            }
        )
    }

    fileprivate func generateViaLoopbackServer(
        input: LLMInput,
        onToken: (@Sendable (String) async throws -> Void)? = nil,
        onPromptProgress: (@Sendable (Double) -> Void)? = nil,
        forceNonStreaming: Bool = false,
        allowRetry: Bool = true,
        capturePolicy: LoopbackOutputCapturePolicy = .fullText
    ) async throws -> LoopbackGenerationResult {
        latestFinishReason.withLock { $0 = nil }
        let bypassRAMCheck = UserDefaults.standard.bool(forKey: "bypassRAMCheck")
        let ctxForRAM = Int(self.effectiveContext > 0 ? self.effectiveContext : self.contextLength)
        var port = Int(LlamaServerBridge.port())
        let mm = self.allowProjectorAutoDiscovery
            ? (self.effectiveMMProj ?? ProjectorLocator.projectorPath(alongside: self.modelURL))
            : nil
        var fitAssessment: ModelRAMAdvisor.GGUFLaunchFitAssessment?
        // Only enforce the RAM safety guard when we are about to start the embedded server.
        // Once the server is already running, available memory will naturally be lower (because
        // the model/KV/vision buffers are already allocated), so a "can we load?" check here
        // becomes a false-positive gate.
        if port <= 0 {
            let startConfiguration = self.loopbackStartConfiguration(mmprojPath: mm)
            let assessment = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
                contextLength: ctxForRAM,
                kvCacheEstimate: .resolved(from: startConfiguration),
                runtimeConfiguration: .resolved(from: startConfiguration),
                serverConfiguration: startConfiguration
            )
            fitAssessment = assessment
            if !bypassRAMCheck, assessment.status == .doesNotFit {
                Task { await logger.log("[Loopback][RAMGuard] blocked exact=true model=\(self.modelURL.lastPathComponent) ctx=\(ctxForRAM)") }
                throw NSError(
                    domain: "Noema",
                    code: 2003,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "The on-device model runtime was blocked by the RAM safety guard for this model and context. Lower the context length or bypass the safety check.",
                            locale: LocalizationManager.preferredLocale()
                        )
                    ]
                )
            }
        }
        var startedLoopback = false
        if port <= 0 {
            // Best-effort lazy start: ChatVM normally starts loopback during model load, but
            // keep a defensive fallback here for race conditions.
            Self.activeLoopbackOwner.withLock { $0 = nil }
            let baselineFootprint = ModelRAMAdvisor.processFootprintBytes()
            let peakSampler = Task.detached(priority: .utility) {
                var peak = baselineFootprint
                while !Task.isCancelled {
                    peak = max(peak, ModelRAMAdvisor.processFootprintBytes())
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return max(peak, ModelRAMAdvisor.processFootprintBytes())
            }
            let p = Int(LlamaServerBridge.start(self.loopbackStartConfiguration(mmprojPath: mm)))
            peakSampler.cancel()
            let peakFootprint = await peakSampler.value
            if p > 0 {
                if let exactBytes = fitAssessment?.estimatedIncrementalBytes {
                    ModelRAMAdvisor.recordSuccessfulGGUFLaunch(
                        estimatedIncrementalBytes: exactBytes,
                        baselineFootprintBytes: baselineFootprint,
                        peakFootprintBytes: peakFootprint
                    )
                }
                LoopbackVisionState.setEnabled(true)
                let projName = mm.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? (GGUFMetadata.hasMultimodalProjector(at: self.modelURL) ? "merged" : "none")
                let templateLabel = self.templateProfile.templateLabel
                Task { await logger.log("[Loopback] lazyStart ok port=\(p) gguf=\(self.modelURL.lastPathComponent) mmproj=\(projName) template=\(templateLabel)") }
                logLastLoopbackStartOptions(prefix: "[Loopback][StartOptions][LazyStart]")
                port = p
                startedLoopback = true
            } else {
                let diagnostics = LlamaServerBridge.lastStartDiagnostics()
                let reason = diagnostics?.message.isEmpty == false
                    ? diagnostics!.message
                    : (diagnostics?.code ?? "startup_failed")
                Task { await logger.log("[Loopback] lazyStart failed gguf=\(self.modelURL.lastPathComponent) reason=\(reason)") }
            }
        }
        guard port > 0, let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            let diagnostics = LlamaServerBridge.lastStartDiagnostics()
            throw NSError(
                domain: "Noema",
                code: 2001,
                userInfo: [
                    NSLocalizedDescriptionKey: LoopbackStartupPlanner.formatFailureMessage(diagnostics)
                ]
            )
        }
        if startedLoopback {
            try claimLoopbackLease(port: port)
        } else {
            try validateLoopbackLease(port: port)
        }
        let preflightProbe = await waitForLoopbackReady(baseURL: baseURL, timeout: Self.loopbackReadyProbeTimeout)
        let preflightStatus = preflightProbe.statusCode.map(String.init) ?? "-1"
        Task {
            await logger.log(
                "[Loopback][ReadyProbe] preflight ready=\(preflightProbe.ready) status=\(preflightStatus) elapsed_ms=\(preflightProbe.elapsedMs) attempts=\(preflightProbe.attempts) bridge_fallback=\(preflightProbe.usedBridgeFallback)"
            )
        }
        guard preflightProbe.ready else {
            throw loopbackStillLoadingError()
        }
        // If readiness came from bridge state (not an HTTP 200 probe), pause briefly
        // so the server main loop can finish its first scheduling turn.
        if preflightProbe.usedBridgeFallback {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let requestPlan = buildLoopbackRequestPlan(for: input, forceNonStreaming: forceNonStreaming)
        let endpoint = requestPlan.endpoint
        let body = requestPlan.body
        let imagePaths = requestPlan.imagePaths
        let requestMode = requestPlan.requestMode
        let requestModelIdentifier = modelURL.path
        let requestSpeculativeType = LlamaServerBridge.lastStartOptions()?.speculativeType

        var req = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        req.httpMethod = "POST"
        req.setValue(forceNonStreaming ? "application/json" : "text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("close", forHTTPHeaderField: "Connection")
        // .sortedKeys is load-bearing, not cosmetic: the server parses the body as
        // nlohmann::ordered_json, so OBJECT KEY ORDER inside tool schemas flows into
        // the Jinja-rendered prompt. NSDictionary serialization order is not stable
        // across rebuilt dictionaries, and any byte drift at the tools section
        // invalidates the slot KV prefix (full re-prefill per turn on paged models).
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        req.timeoutInterval = Self.loopbackRequestTimeout
        if NetworkKillSwitch.shouldBlock(request: req) {
            Task { await logger.log("[Loopback] blocked by off-grid/kill-switch url=\(req.url?.absoluteString ?? "nil")") }
            throw URLError(.notConnectedToInternet)
        }
        let approxBytes: Int = imagePaths.reduce(0) { acc, path in
            let fileURL = URL(fileURLWithPath: path)
            let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let (total, overflow) = acc.addingReportingOverflow(max(0, bytes))
            return overflow ? .max : total
        }
        let modeLabel = forceNonStreaming ? "json" : "sse"
        let templateLabel = templateProfile.templateLabel
        let structuredMultimodal: Bool = {
            if case .multimodalMessages = input.content { return true }
            return false
        }()
        Task {
            await logger.log(
                "[Loopback] request url=\(baseURL)\(endpoint) mode=\(modeLabel) request_mode=\(requestMode) template=\(templateLabel) qwen35=\(isQwen35Model) structured_multimodal=\(structuredMultimodal) images=\(imagePaths.count) bytes=\(approxBytes)"
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.loopbackRequestTimeout
        configuration.timeoutIntervalForResource = Self.loopbackResourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        await loopbackSessionState.set(session)
        defer {
            Task { await self.loopbackSessionState.clearIfMatching(session) }
            session.finishTasksAndInvalidate()
        }

        let decoder = JSONDecoder()
        var outputCapture = LoopbackOutputCapture(policy: capturePolicy)
        var deliveredCharacterCount = 0
        var bufferedNonSSEPayload = ""
        var sawSSEPayload = false
        var thinkOpen = false
        var finishReason: String?
        var sawReasoning = false
        var sawContent = false
        var reasoningArrivedBeforeContent = false
        var latestTimings: LoopbackSpeculativeTimings?
        var didReportPromptCache = false
        var reportedPromptCached: Int?
        var reportedPromptTotal: Int?
        LoopbackLatestTimings.reset()

        func emit(_ token: String) async throws {
            guard !token.isEmpty else { return }
            deliveredCharacterCount += token.count
            outputCapture.append(token)
            try await onToken?(token)
        }

        // Native tool calls arrive as structured `tool_calls` (streamed as fragments per
        // `index`). Accumulate them, then bridge each completed call into the existing
        // dispatch path by emitting a `TOOL_CALL: {json}` sentinel (the downstream loop
        // already handles that reliably — no regex scan of model prose needed).
        var toolCallAcc: [Int: (id: String?, name: String, args: String)] = [:]
        var toolCallOrder: [Int] = []
        var flushedToolCalls = false

        func accumulateToolCalls(_ fragments: [LoopbackChatChunk.ToolCallFragment]?) {
            guard let fragments else { return }
            for frag in fragments {
                let idx = frag.index ?? 0
                if toolCallAcc[idx] == nil { toolCallOrder.append(idx) }
                var entry = toolCallAcc[idx] ?? (id: nil, name: "", args: "")
                if let id = frag.id, !id.isEmpty { entry.id = id }
                if let name = frag.function?.name, !name.isEmpty { entry.name = name }
                if let args = frag.function?.arguments { entry.args += args }
                toolCallAcc[idx] = entry
            }
        }

        func flushToolCalls() async throws {
            guard !flushedToolCalls, !toolCallOrder.isEmpty else { return }
            flushedToolCalls = true
            // Close any open reasoning block FIRST. Native tool calls often arrive with
            // only reasoning_content (no visible content), so </think> hasn't been emitted
            // yet. The downstream loop ignores TOOL_CALL sentinels seen inside an open
            // <think> block, so emitting the sentinel here without closing think would make
            // the call silently dropped (model appears to stop right after thinking).
            if thinkOpen {
                try await emit("</think>")
                thinkOpen = false
            }
            for idx in toolCallOrder {
                guard let entry = toolCallAcc[idx], !entry.name.isEmpty else { continue }
                let argsValue: Any
                if entry.args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    argsValue = [String: Any]()
                } else if let d = entry.args.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) {
                    argsValue = obj
                } else {
                    argsValue = entry.args
                }
                let payload: [String: Any] = ["name": entry.name, "arguments": argsValue]
                // sortedKeys: this sentinel is stored in the transcript and re-serialized
                // into later prompts, so its byte shape must be launch-stable.
                if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                   let json = String(data: d, encoding: .utf8) {
                    try await emit("TOOL_CALL: " + json)
                }
            }
        }

        func emitChoice(_ choice: LoopbackChatChunk.Choice) async throws {
            if let reason = choice.finishReason, !reason.isEmpty {
                finishReason = reason
            }

            accumulateToolCalls(choice.delta?.toolCalls ?? choice.message?.toolCalls)

            if let reasoning = choice.delta?.reasoningContent ?? choice.message?.reasoningContent,
               !reasoning.isEmpty {
                if !sawContent {
                    reasoningArrivedBeforeContent = true
                }
                sawReasoning = true
                if !thinkOpen {
                    try await emit("<think>")
                    thinkOpen = true
                }
                try await emit(reasoning)
            }

            if let contentChunk = choice.delta?.content ?? choice.message?.content ?? choice.text ?? choice.completion,
               !contentChunk.isEmpty {
                sawContent = true
                if thinkOpen {
                    try await emit("</think>")
                    thinkOpen = false
                }
                try await emit(contentChunk)
            }

            // Flush native tool calls LAST, after this chunk's reasoning/content, so the
            // TOOL_CALL sentinel is always emitted outside <think> and after any prose.
            if finishReason == "tool_calls" { try await flushToolCalls() }
        }

        func reportPromptProgress(_ progress: LoopbackChatChunk.PromptProgress?) {
            guard
                let progress,
                let total = progress.total,
                let processed = progress.processed,
                total > 0
            else { return }

            let fraction = min(1.0, max(0.0, Double(processed) / Double(total)))
            onPromptProgress?(fraction)

            if !didReportPromptCache {
                didReportPromptCache = true
                let cached = min(total, max(0, progress.cache ?? 0))
                reportedPromptCached = cached
                reportedPromptTotal = total
                let remaining = max(0, total - cached)
                let reusePercent = Int((Double(cached) / Double(total) * 100).rounded())
                let timeMs = progress.timeMs ?? 0
                Task {
                    await logger.log(
                        "[Loopback][PromptCache] cached=\(cached) total=\(total) remaining=\(remaining) reuse=\(reusePercent)% first_progress_ms=\(timeMs)"
                    )
                }
            }
        }

        func recordTimings(_ timings: LoopbackSpeculativeTimings?) {
            guard let timings else { return }
            latestTimings = timings
            LoopbackLatestTimings.record(timings)
        }

        func decodeServerErrorMessage(from data: Data) -> String? {
            if let envelope = try? decoder.decode(LoopbackErrorEnvelope.self, from: data),
               let message = envelope.error?.message,
               !message.isEmpty {
                return message
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String,
                   !message.isEmpty {
                    return message
                }
                if let message = json["message"] as? String, !message.isEmpty {
                    return message
                }
            }
            return nil
        }

        func finalizeResponseLog() async throws {
            if thinkOpen {
                try await emit("</think>")
            }
            // Safety net: emit any accumulated native tool calls that weren't flushed by a
            // finish_reason=="tool_calls" chunk (some templates/servers close with "stop").
            try await flushToolCalls()
            let resolvedFinishReason = finishReason
            latestFinishReason.withLock { $0 = resolvedFinishReason }
            let outCount = deliveredCharacterCount
            let reasonSuffix = finishReason.map { " finish_reason=\($0)" } ?? ""
            let draftSuffix: String = {
                guard let latestTimings else { return "" }
                let draftN = latestTimings.draftN ?? 0
                let accepted = latestTimings.draftNAccepted ?? 0
                guard draftN > 0 else { return " draft=0" }
                let rate = latestTimings.acceptanceRate.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
                return " draft=\(accepted)/\(draftN) accept=\(rate)"
            }()
            let speedSuffix: String = {
                guard let perSecond = latestTimings?.predictedPerSecond else { return "" }
                return " predicted_tps=\(String(format: "%.2f", perSecond))"
            }()
            let logMessage = "[Loopback] response ok chars=\(outCount) reasoning=\(sawReasoning) reasoning_first=\(reasoningArrivedBeforeContent)\(reasonSuffix)\(draftSuffix)\(speedSuffix)"
            Task { [logMessage] in
                await logger.log(logMessage)
            }
            let diagnostics = LoopbackResponseDiagnostics(
                completedAt: Date(),
                endpoint: endpoint,
                requestMode: requestMode,
                streaming: !forceNonStreaming,
                modelIdentifier: requestModelIdentifier,
                speculativeType: requestSpeculativeType?.isEmpty == false ? requestSpeculativeType : nil,
                timings: latestTimings,
                finishReason: finishReason,
                outputCharacters: outCount
            )
            Task {
                await LoopbackRuntimeDiagnostics.shared.recordResponse(diagnostics)
            }
            // Paged sessions persist the newest prompt KV and SWA/hybrid
            // checkpoints after each successful completion. The cache
            // coalesces overlapping saves and the server waits for slot idle.
            if isPagedLoopbackSession,
               input.generationOptions.requestPurpose == .chat {
                OverfitPromptStateCache.shared.noteSuccessfulPagedCompletion(
                    port: Int32(port),
                    promptCacheTokens: latestTimings?.cacheN
                )
                logPagedCompletionTelemetry(
                    timings: latestTimings,
                    promptCached: reportedPromptCached,
                    promptTotal: reportedPromptTotal
                )
            }
        }

        func parseJSONBody(_ data: Data) async throws {
            // Try OAI chat/completion format first (has "choices" array)
            if let chunk = try? decoder.decode(LoopbackChatChunk.self, from: data) {
                recordTimings(chunk.timings)
                reportPromptProgress(chunk.promptProgress)
                for choice in chunk.choices {
                    try await emitChoice(choice)
                }
                return
            }
            // Try raw /completion format (has "content" field directly)
            if let raw = try? decoder.decode(LoopbackCompletionChunk.self, from: data) {
                recordTimings(raw.timings)
                if let content = raw.content, !content.isEmpty {
                    try await emit(content)
                }
                if raw.stop == true {
                    finishReason = raw.stopType == "limit" || raw.truncated == true
                        ? "length"
                        : "stop"
                }
                return
            }
            if let message = decodeServerErrorMessage(from: data) {
                throw NSError(
                    domain: "Noema",
                    code: 2002,
                    userInfo: [
                        NSLocalizedDescriptionKey: String.localizedStringWithFormat(
                            String(localized: "Model runtime error: %@", locale: LocalizationManager.preferredLocale()),
                            message
                        )
                    ]
                )
            }
            let plain = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                try await emit(plain)
            }
        }

        if forceNonStreaming {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw NoemaLlamaError.generationFailed
            }
            guard (200...299).contains(http.statusCode) else {
                let message = decodeServerErrorMessage(from: data) ?? String(decoding: data.prefix(4096), as: UTF8.self)
                throw NSError(
                    domain: "Noema",
                    code: 2002,
                    userInfo: [
                        NSLocalizedDescriptionKey: String.localizedStringWithFormat(
                            String(localized: "Model runtime error: %@", locale: LocalizationManager.preferredLocale()),
                            message
                        )
                    ]
                )
            }
            try await parseJSONBody(data)
            try await finalizeResponseLog()
            return outputCapture.result
        }

        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw NoemaLlamaError.generationFailed
            }
            guard (200...299).contains(http.statusCode) else {
                var buffer = Data()
                var iterator = bytes.makeAsyncIterator()
                while let byte = try await iterator.next() {
                    buffer.append(byte)
                    if buffer.count >= 4096 { break }
                }
                let message = decodeServerErrorMessage(from: buffer) ?? String(decoding: buffer, as: UTF8.self)
                throw NSError(
                    domain: "Noema",
                    code: 2002,
                    userInfo: [
                        NSLocalizedDescriptionKey: String.localizedStringWithFormat(
                            String(localized: "Model runtime error: %@", locale: LocalizationManager.preferredLocale()),
                            message
                        )
                    ]
                )
            }

            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard line.hasPrefix("data:") else {
                    bufferedNonSSEPayload.append(line)
                    continue
                }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payload.isEmpty else { continue }
                sawSSEPayload = true
                if payload == "[DONE]" { break }
                guard let payloadData = payload.data(using: .utf8) else { continue }
                // Try OAI chat format (choices array)
                if let chunk = try? decoder.decode(LoopbackChatChunk.self, from: payloadData) {
                    recordTimings(chunk.timings)
                    reportPromptProgress(chunk.promptProgress)
                    for choice in chunk.choices {
                        try await emitChoice(choice)
                    }
                    continue
                }
                // Try raw /completion format (content + stop)
                if let raw = try? decoder.decode(LoopbackCompletionChunk.self, from: payloadData) {
                    recordTimings(raw.timings)
                    if raw.stop == true {
                        finishReason = raw.stopType == "limit" || raw.truncated == true
                            ? "length"
                            : "stop"
                        break
                    }
                    if let content = raw.content, !content.isEmpty {
                        try await emit(content)
                    }
                    continue
                }
                if let message = decodeServerErrorMessage(from: payloadData) {
                    throw NSError(
                        domain: "Noema",
                        code: 2002,
                        userInfo: [
                            NSLocalizedDescriptionKey: String.localizedStringWithFormat(
                                String(localized: "Model runtime error: %@", locale: LocalizationManager.preferredLocale()),
                                message
                            )
                        ]
                    )
                }
            }

            if !sawSSEPayload, !bufferedNonSSEPayload.isEmpty,
               let data = bufferedNonSSEPayload.data(using: .utf8) {
                try await parseJSONBody(data)
            }

            try await finalizeResponseLog()
            return outputCapture.result
        } catch {
            // Diagnostic logging for connection failures
            let errNS = error as NSError
            let errCode = errNS.code
            let errDomain = errNS.domain
            let errDesc = errNS.localizedDescription
            let charsReceived = deliveredCharacterCount
            let mode = forceNonStreaming ? "json" : "sse"
            let ep = endpoint
            Task {
                await logger.log(
                    "[Loopback][Error] domain=\(errDomain) code=\(errCode) endpoint=\(ep) mode=\(mode) chars_received=\(charsReceived) description=\(errDesc)"
                )
            }

            let retryCode: URLError.Code? = {
                if let urlError = error as? URLError {
                    return urlError.code
                }
                let nsError = error as NSError
                guard nsError.domain == NSURLErrorDomain else { return nil }
                return URLError.Code(rawValue: nsError.code)
            }()

            if allowRetry, deliveredCharacterCount == 0, let retryCode {
                let isRetryableConnectionError =
                    retryCode == .networkConnectionLost ||
                    retryCode == .cannotConnectToHost ||
                    retryCode == .cannotFindHost ||
                    retryCode == .timedOut
                if isRetryableConnectionError {
                    let preRestartProbe = await waitForLoopbackReady(baseURL: baseURL, timeout: Self.loopbackRetryProbeTimeout)
                    let preRestartStatus = preRestartProbe.statusCode.map(String.init) ?? "-1"
                    Task {
                        await logger.log(
                            "[Loopback][Retry] code=\(retryCode.rawValue) pre_restart_ready=\(preRestartProbe.ready) status=\(preRestartStatus) elapsed_ms=\(preRestartProbe.elapsedMs) attempts=\(preRestartProbe.attempts) bridge_fallback=\(preRestartProbe.usedBridgeFallback)"
                        )
                    }

                    if LoopbackRetryPlanner.decision(
                        preRestartProbe: preRestartProbe,
                        restartedPort: nil,
                        postRestartProbe: nil
                    ) == .retryWithoutRestart {
                        Task {
                            await logger.log(
                                "[Loopback][Retry] decision=retry_non_stream_without_restart code=\(retryCode.rawValue)"
                            )
                        }
                        return try await self.generateViaLoopbackServer(
                            input: input,
                            onToken: onToken,
                            onPromptProgress: onPromptProgress,
                            forceNonStreaming: true,
                            allowRetry: false,
                            capturePolicy: capturePolicy
                        )
                    }

                    let mm = self.allowProjectorAutoDiscovery
                        ? (self.effectiveMMProj ?? ProjectorLocator.projectorPath(alongside: self.modelURL))
                        : nil
                    let restarted = try self.restartOwnedLoopback(mmprojPath: mm)
                    if restarted > 0 {
                        let restartedURL = URL(string: "http://127.0.0.1:\(restarted)")
                        let postRestartProbe: LoopbackReadyProbeResult
                        if let restartedURL {
                            postRestartProbe = await waitForLoopbackReady(
                                baseURL: restartedURL,
                                timeout: Self.loopbackReadyProbeTimeout
                            )
                        } else {
                            postRestartProbe = LoopbackReadyProbeResult(
                                ready: false,
                                statusCode: nil,
                                attempts: 0,
                                elapsedMs: 0,
                                usedBridgeFallback: false
                            )
                        }
                        let postStatus = postRestartProbe.statusCode.map(String.init) ?? "-1"
                        Task {
                            await logger.log(
                                "[Loopback][Retry] decision=restart_and_retry code=\(retryCode.rawValue) restart_port=\(restarted) ready=\(postRestartProbe.ready) status=\(postStatus) elapsed_ms=\(postRestartProbe.elapsedMs) attempts=\(postRestartProbe.attempts) bridge_fallback=\(postRestartProbe.usedBridgeFallback)"
                            )
                        }
                        guard LoopbackRetryPlanner.decision(
                            preRestartProbe: preRestartProbe,
                            restartedPort: restarted,
                            postRestartProbe: postRestartProbe
                        ) == .restartAndRetry(port: restarted) else {
                            throw loopbackStillLoadingError()
                        }
                    } else {
                        Task { await logger.log("[Loopback][Retry] decision=restart_failed code=\(retryCode.rawValue)") }
                        throw NSError(
                            domain: "Noema",
                            code: 2005,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "The on-device model runtime could not recover. Reload the model and try again.",
                                    locale: LocalizationManager.preferredLocale()
                                )
                            ]
                        )
                    }
                    return try await self.generateViaLoopbackServer(
                        input: input,
                        onToken: onToken,
                        onPromptProgress: onPromptProgress,
                        forceNonStreaming: true,
                        allowRetry: false,
                        capturePolicy: capturePolicy
                    )
                }
            }
            throw UserFacingErrorFormatter.normalizedTransportError(error, context: .localModel)
        }
    }

    fileprivate func mostRecentFinishReason() -> String? {
        latestFinishReason.withLock { $0 }
    }
}
