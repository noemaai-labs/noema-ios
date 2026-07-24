import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// Used LanguageModelSession instances retain transcripts, so only an unused
// prewarmed session may be reused.

struct AFMDocumentPlanningResult: Sendable {
    let strategy: DocumentAccessStrategy
    let usedAFMDecision: Bool
}

#if canImport(FoundationModels)
#if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
private struct AFMDocumentAccessVerdict {
    @Guide(
        description: "How Noema should use the active document for this request",
        .anyOf(["none", "context", "navigate", "context_then_navigate"])
    )
    var documentAccess: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
private struct AFMRouteVerdict {
    @Guide(description: "Where the user's next answer should run", .anyOf(["local", "cloud"]))
    var route: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private enum AFMPlannerRequestKind: Sendable {
    case documentAccess
    case escalationRoute
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private enum AFMPlannerRawVerdict: Sendable {
    case documentAccess(DocumentAccessStrategy)
    case escalationRoute(AutoRouteTarget)
    case safetySignal
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private final class AFMRouterAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AFMPlannerRawVerdict, Error>?
    private var result: Result<AFMPlannerRawVerdict, Error>?

    func value() async throws -> AFMPlannerRawVerdict {
        if Task.isCancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func finish(_ result: Result<AFMPlannerRawVerdict, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private struct AFMRouterRequest: Sendable {
    let id: UUID
    let awaiter: AFMRouterAwaiter
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private actor AFMRouterRuntime {
    static let shared = AFMRouterRuntime()

    private static let quarantineAfterFailures = 2
    private static let quarantineDuration: Duration = .seconds(300)

    private var readySession: LanguageModelSession?
    private var readyFingerprint: String?
    private var warmRequested = false
    private var warmInstructions: String?

    private var currentRequestID: UUID?
    private var currentWorker: Task<Void, Never>?
    private var currentDeadlineTask: Task<Void, Never>?
    private var currentDeadlineExceeded = false
    private var currentCancelled = false

    private var consecutiveFailures = 0
    private var quarantinedUntil: ContinuousClock.Instant?

    func prewarm(instructions: String) {
        warmRequested = true
        warmInstructions = instructions
        guard currentRequestID == nil, !isQuarantined else { return }
        guard AutopilotAFMBrain.isAvailableNow else { return }
        if readySession != nil, readyFingerprint == instructions { return }

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )
        session.prewarm()
        readySession = session
        readyFingerprint = instructions
    }

    func release(cancelInFlight: Bool) {
        warmRequested = false
        warmInstructions = nil
        readySession = nil
        readyFingerprint = nil
        if cancelInFlight {
            currentCancelled = true
            currentWorker?.cancel()
        }
    }

    func resetHealth() {
        consecutiveFailures = 0
        quarantinedUntil = nil
        if warmRequested, let instructions = warmInstructions {
            prewarm(instructions: instructions)
        }
    }

    func begin(
        kind: AFMPlannerRequestKind,
        prompt: String,
        instructions: String,
        timeoutSeconds: Double,
        keepWarm: Bool
    ) throws -> AFMRouterRequest {
        if let until = quarantinedUntil, ContinuousClock.now >= until {
            quarantinedUntil = nil
            consecutiveFailures = 0
        }
        guard !isQuarantined, currentRequestID == nil else {
            throw AutopilotBrainError.unavailable
        }
        guard AutopilotAFMBrain.isAvailableNow else {
            throw AutopilotBrainError.unavailable
        }

        warmRequested = keepWarm
        warmInstructions = keepWarm ? instructions : nil

        let wasWarm = readySession != nil && readyFingerprint == instructions
        let session: LanguageModelSession
        if wasWarm, let prepared = readySession {
            session = prepared
        } else {
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: instructions
            )
        }
        readySession = nil
        readyFingerprint = nil

        let id = UUID()
        let awaiter = AFMRouterAwaiter()
        currentRequestID = id
        currentDeadlineExceeded = false
        currentCancelled = false

        let worker = Task { [session] in
            let result: Result<AFMPlannerRawVerdict, Error>
            do {
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
                switch kind {
                case .documentAccess:
                    let response = try await session.respond(
                        to: prompt,
                        generating: AFMDocumentAccessVerdict.self,
                        includeSchemaInPrompt: true,
                        options: options
                    )
                    guard let strategy = DocumentAccessStrategy(
                        rawValue: response.content.documentAccess.lowercased()
                    ) else {
                        throw AutopilotBrainError.unparseable
                    }
                    result = .success(.documentAccess(strategy))
                case .escalationRoute:
                    let response = try await session.respond(
                        to: prompt,
                        generating: AFMRouteVerdict.self,
                        includeSchemaInPrompt: true,
                        options: options
                    )
                    guard let target = AutoRouteTarget(rawValue: response.content.route.lowercased()) else {
                        throw AutopilotBrainError.unparseable
                    }
                    result = .success(.escalationRoute(target))
                }
            } catch is CancellationError {
                result = .failure(CancellationError())
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .refusal(_, _), .guardrailViolation(_):
                    // Sensitive prompts are legitimate classifier input. A refusal
                    // is useful conservative evidence after the privacy gates.
                    result = .success(.safetySignal)
                case .decodingFailure(_), .unsupportedGuide(_):
                    result = .failure(AutopilotBrainError.unparseable)
                default:
                    result = .failure(AutopilotBrainError.unavailable)
                }
            } catch let error as AutopilotBrainError {
                result = .failure(error)
            } catch {
                result = .failure(AutopilotBrainError.unavailable)
            }

            self.completeRequest(id: id, result: result, wasWarm: wasWarm)
            awaiter.finish(result)
        }
        currentWorker = worker

        currentDeadlineTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            } catch {
                return
            }
            self.deadlineReached(id: id, awaiter: awaiter)
        }

        return AFMRouterRequest(id: id, awaiter: awaiter)
    }

    func cancelWait(for id: UUID, awaiter: AFMRouterAwaiter) {
        guard currentRequestID == id else {
            awaiter.finish(.failure(CancellationError()))
            return
        }
        currentCancelled = true
        currentWorker?.cancel()
        awaiter.finish(.failure(CancellationError()))
    }

    private func deadlineReached(id: UUID, awaiter: AFMRouterAwaiter) {
        guard currentRequestID == id else { return }
        currentDeadlineExceeded = true
        currentWorker?.cancel()
        registerFailure()
        awaiter.finish(.failure(AutopilotBrainError.timedOut))
        Task { await logger.log("[AFMPlanner] soft deadline reached; using deterministic fallback") }
    }

    private func completeRequest(
        id: UUID,
        result: Result<AFMPlannerRawVerdict, Error>,
        wasWarm: Bool
    ) {
        guard currentRequestID == id else { return }
        currentDeadlineTask?.cancel()
        currentDeadlineTask = nil
        currentWorker = nil
        currentRequestID = nil

        let deadlineExceeded = currentDeadlineExceeded
        let cancelled = currentCancelled
        currentDeadlineExceeded = false
        currentCancelled = false

        if !deadlineExceeded, !cancelled {
            switch result {
            case .success:
                consecutiveFailures = 0
                quarantinedUntil = nil
            case .failure:
                registerFailure()
            }
        }

        Task {
            await logger.log(
                "[AFMPlanner] request retired warm=\(wasWarm) deadlineExceeded=\(deadlineExceeded) cancelled=\(cancelled)"
            )
        }

        // The used session is intentionally discarded. Prepare one fresh,
        // blank-transcript session only after the prior framework call exits.
        if warmRequested, let instructions = warmInstructions, !isQuarantined {
            prewarm(instructions: instructions)
        }
    }

    private func registerFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.quarantineAfterFailures {
            quarantinedUntil = .now + Self.quarantineDuration
            readySession = nil
            readyFingerprint = nil
        }
    }

    private var isQuarantined: Bool {
        guard let until = quarantinedUntil else { return false }
        return ContinuousClock.now < until
    }
}
#endif
#endif

enum AutopilotAFMBrain {
    /// Normal sends must not feel slower than beginning a local answer. Setup's
    /// explicit health test gets a larger cold-start allowance.
    static let turnTimeoutSeconds: Double = 3.0
    static let testTimeoutSeconds: Double = 8.0

    static var isSelectable: Bool {
        AppleFoundationModelAvailability.isSupportedDevice
    }

    static var isAvailableNow: Bool {
        guard AppleFoundationModelAvailability.isAvailableNow else { return false }
#if canImport(FoundationModels)
#if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return SystemLanguageModel.default.supportsLocale(LocalizationManager.preferredLocale())
        }
#endif
#endif
        return false
    }

    static var unavailableMessage: String? {
        if let reason = AppleFoundationModelAvailability.unavailableReason {
            return reason.message
        }
        if AppleFoundationModelAvailability.isAvailableNow, !isAvailableNow {
            return String(localized: "Apple Foundation Models do not support the current app language.")
        }
        return isAvailableNow ? nil : String(localized: "AFM currently unavailable")
    }

    static func syncWarmState(armed: Bool? = nil, cancelInFlight: Bool = false) {
#if canImport(FoundationModels)
#if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let config = AutopilotConfigStore.load()
            let shouldWarm = (armed ?? config.enabled)
                && config.system == .router
                && config.routerKind == .appleFoundationModel
            Task {
                if shouldWarm {
                    await AFMRouterRuntime.shared.prewarm(
                        instructions: AutopilotBrainClient.afmPlannerInstructions
                    )
                } else {
                    await AFMRouterRuntime.shared.release(cancelInFlight: cancelInFlight)
                }
            }
        }
#endif
#endif
    }

    static func prewarmForLikelyUse() {
#if canImport(FoundationModels)
#if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            Task {
                await AFMRouterRuntime.shared.prewarm(
                    instructions: AutopilotBrainClient.afmPlannerInstructions
                )
            }
        }
#endif
#endif
    }

    static func resetHealth() async {
#if canImport(FoundationModels)
#if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            await AFMRouterRuntime.shared.resetHealth()
        }
#endif
#endif
    }

    static func decide(
        inputs: AutoRouteInputs,
        aggressiveness: RouterAggressiveness,
        timeoutSeconds: Double = turnTimeoutSeconds
    ) async throws -> AutoRouteDecision {
#if canImport(FoundationModels)
#if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard isAvailableNow else { throw AutopilotBrainError.unavailable }
            let started = ContinuousClock.now
            let config = AutopilotConfigStore.load()
            let request = try await AFMRouterRuntime.shared.begin(
                kind: .escalationRoute,
                prompt: AutopilotBrainClient.afmRoutingPrompt(
                    inputs: inputs,
                    aggressiveness: aggressiveness
                ),
                instructions: AutopilotBrainClient.afmPlannerInstructions,
                timeoutSeconds: timeoutSeconds,
                keepWarm: config.enabled
                    && config.system == .router
                    && config.routerKind == .appleFoundationModel
            )

            let raw = try await withTaskCancellationHandler {
                try await request.awaiter.value()
            } onCancel: {
                request.awaiter.finish(.failure(CancellationError()))
                Task {
                    await AFMRouterRuntime.shared.cancelWait(
                        for: request.id,
                        awaiter: request.awaiter
                    )
                }
            }

            let latencyMs = milliseconds(since: started)
            switch raw {
            case .escalationRoute(let target):
                return resolvedDecision(
                    target: target,
                    inputs: inputs,
                    aggressiveness: aggressiveness,
                    latencyMs: latencyMs
                )
            case .safetySignal:
                return safetyEscalationDecision(latencyMs: latencyMs)
            case .documentAccess:
                throw AutopilotBrainError.unparseable
            }
        }
#endif
#endif
        throw AutopilotBrainError.unavailable
    }

    /// Independent document planning for every active-dataset chat. Autopilot is
    /// neither required nor consulted by this request.
    static func planDocumentAccess(
        context: DocumentAccessContext,
        userMessage: String,
        previousUserMessage: String?,
        timeoutSeconds: Double = turnTimeoutSeconds
    ) async throws -> AFMDocumentPlanningResult {
#if canImport(FoundationModels)
#if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard isAvailableNow else { throw AutopilotBrainError.unavailable }
            let request = try await AFMRouterRuntime.shared.begin(
                kind: .documentAccess,
                prompt: AutopilotBrainClient.afmDocumentPlanningPrompt(
                    context: context,
                    userMessage: userMessage,
                    previousUserMessage: previousUserMessage
                ),
                instructions: AutopilotBrainClient.afmPlannerInstructions,
                timeoutSeconds: timeoutSeconds,
                keepWarm: context.hasActiveDataset
            )
            let raw = try await withTaskCancellationHandler {
                try await request.awaiter.value()
            } onCancel: {
                request.awaiter.finish(.failure(CancellationError()))
                Task {
                    await AFMRouterRuntime.shared.cancelWait(
                        for: request.id,
                        awaiter: request.awaiter
                    )
                }
            }
            switch raw {
            case .documentAccess(let documentAccess):
                return AFMDocumentPlanningResult(
                    strategy: documentAccess,
                    usedAFMDecision: true
                )
            case .safetySignal:
                return AFMDocumentPlanningResult(
                    strategy: DocumentAccessPlanner.deterministic(
                        userMessage: userMessage,
                        previousUserMessage: previousUserMessage,
                        context: context
                    ),
                    usedAFMDecision: false
                )
            case .escalationRoute:
                throw AutopilotBrainError.unparseable
            }
        }
#endif
#endif
        throw AutopilotBrainError.unavailable
    }

    /// AFM supplies only constrained plan fields. Noema's deterministic heuristic
    /// supplies explainable, localizable route metadata and policy confidence;
    /// no free-form model text reaches the UI.
    static func resolvedDecision(
        target: AutoRouteTarget,
        inputs: AutoRouteInputs,
        aggressiveness: RouterAggressiveness,
        latencyMs: Int,
        decidedBy: AutoRouteDecision.DecidedBy = .afm
    ) -> AutoRouteDecision {
        let metadata = AutopilotHeuristic.decide(inputs, aggressiveness: aggressiveness)
        let agrees = metadata.target == target
        var reasonKey = agrees
            ? metadata.reasonKey
            : (target == .cloud ? AutopilotReasonKey.cloudCapable : AutopilotReasonKey.localCapable)
        // The route is authoritative. Keep a defensive boundary here so future
        // heuristic scoring changes cannot produce a receipt that describes the
        // opposite destination.
        if target == .cloud,
           reasonKey == AutopilotReasonKey.simpleLocal || reasonKey == AutopilotReasonKey.localCapable {
            reasonKey = AutopilotReasonKey.cloudCapable
        } else if target == .local, reasonKey == AutopilotReasonKey.cloudCapable {
            reasonKey = AutopilotReasonKey.localCapable
        }
        let difficulty = target == .cloud
            ? max(metadata.estDifficulty, AutopilotVerdictGate.difficultyFloor(aggressiveness))
            : metadata.estDifficulty
        return AutoRouteDecision(
            target: target,
            confidence: agrees ? max(0.85, metadata.confidence) : 0.65,
            reason: AutopilotReasonKey.localized(reasonKey ?? (target == .cloud
                ? AutopilotReasonKey.cloudCapable
                : AutopilotReasonKey.localCapable)),
            reasonKey: reasonKey,
            category: metadata.category,
            estDifficulty: difficulty,
            latencyMs: latencyMs,
            decidedBy: decidedBy
        )
    }

    static func safetyEscalationDecision(latencyMs: Int) -> AutoRouteDecision {
        let key = AutopilotReasonKey.highStakes
        return AutoRouteDecision(
            target: .cloud,
            confidence: 0.95,
            reason: AutopilotReasonKey.localized(key),
            reasonKey: key,
            category: .highStakes,
            estDifficulty: 4,
            latencyMs: latencyMs,
            decidedBy: .afm
        )
    }

    static func runConnectionTest() async -> Swift.Result<AutoRouteDecision, Error> {
        let sample = AutoRouteInputs(
            userMessage: "Rewrite this sentence to sound friendlier: Send me the report by Friday.",
            previousUserMessage: nil,
            conversationTurnCount: 0,
            historyTokenEstimate: 0,
            priorLocalRoutes: 0,
            priorCloudRoutes: 0,
            localModel: LocalModelCard(
                name: "Local model", format: .gguf, sizeGB: 2, quant: "Q4_K_M",
                parameterLabel: "", contextLength: 8192, isToolCapable: false,
                isMultimodal: false, moeSummary: nil, recentAvgTokPerSec: nil
            ),
            escalationModel: EscalationModelCard(name: "Stronger model", contextLength: nil,
                                                 promptPricePerMillion: nil, completionPricePerMillion: nil),
            hasImages: false, imageCount: 0, documentCount: 0,
            ragArmed: false, webSearchArmed: false, pythonArmed: false,
            promptTokenEstimate: 100,
            batteryLevel: -1, isCharging: false, lowPowerMode: false, thermalState: .nominal
        )
        do {
            return .success(try await decide(
                inputs: sample,
                aggressiveness: .balanced,
                timeoutSeconds: testTimeoutSeconds
            ))
        } catch {
            return .failure(error)
        }
    }

    private static func milliseconds(since started: ContinuousClock.Instant) -> Int {
        let elapsed = started.duration(to: .now)
        return Int(Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15)
    }
}
