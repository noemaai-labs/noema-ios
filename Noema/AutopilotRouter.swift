import Foundation

// Per-turn routing pipeline: hard gates → selected router brain → heuristic
// fallback. The actor holds remote-router health state; AFM owns its separate
// single-flight runtime. Policy gates are computed by the MainActor caller and
// passed in so decisions stay pure and testable.

struct PolicyGates: Sendable, Equatable {
    var offGrid: Bool
    /// No viable network interface right now. Distinct from `offGrid` (a user
    /// policy) but shares its receipt: with no connectivity there is nothing
    /// to route to, so the verdict is forced local without paying the router
    /// timeout or accruing cool-down strikes.
    var offline: Bool = false
    var killSwitch: Bool
    var enterpriseRemoteAllowed: Bool
    var enterpriseAllowsRouterBackend: Bool
    var enterpriseAllowsEscalationBackend: Bool
    /// Escalation runs on a second local model (macOS): network/enterprise/RAG
    /// gates stop vetoing the escalation itself — only the router brain still
    /// needs connectivity, and its failure path is the offline heuristic.
    var escalationIsLocal: Bool = false
}

struct AutopilotResolvedTargets: Sendable {
    var routerBackend: RemoteBackend?
    var routerModel: RemoteModel?
    var escalationBackend: RemoteBackend?
    var escalationModel: RemoteModel?
    var localEscalation: AutopilotLocalEscalationSelection? = nil
}

struct AutopilotRouteResult: Sendable {
    var decision: AutoRouteDecision
    var routerPromptTokens: Int?
    var routerCompletionTokens: Int?
}

actor AutopilotRouter {
    static let shared = AutopilotRouter()

    private var consecutiveTimeouts = 0
    private var degradedUntil: ContinuousClock.Instant?
    private static let degradeAfterTimeouts = 2
    private static let degradeDuration: Duration = .seconds(300)
    /// Obvious heuristic verdicts do not need to stall generation on AFM. The
    /// on-device model is reserved for the ambiguous band near the threshold.
    private static let afmFastPathConfidence = 0.84

    func decide(_ inputs: AutoRouteInputs,
                config: AutopilotConfig,
                targets: AutopilotResolvedTargets,
                gates: PolicyGates) async -> AutopilotRouteResult {
        if let forced = forcedDecision(inputs, config: config, targets: targets, gates: gates) {
            return AutopilotRouteResult(decision: forced)
        }

        var result: AutopilotRouteResult
        let degraded = isDegraded
        // With a local escalation target the network gates no longer force an
        // early local verdict. This reachability check applies only to the
        // remote router branch below; AFM remains available offline.
        let brainReachable = !(gates.offGrid || gates.offline || gates.killSwitch)
            && gates.enterpriseRemoteAllowed
        if config.routerKind == .appleFoundationModel {
            let heuristic = AutopilotHeuristic.decide(inputs, aggressiveness: config.aggressiveness)
            // If AFM itself is the resident answer model, a second AFM routing
            // session would contend with the response session immediately after
            // the verdict. Keep that combination deterministic and single-model.
            if inputs.localModel.format == .afm {
                result = AutopilotRouteResult(decision: heuristic)
            } else if heuristic.confidence >= Self.afmFastPathConfidence {
                result = AutopilotRouteResult(decision: heuristic)
            } else if AutopilotAFMBrain.isAvailableNow {
                do {
                    let verdict = try await AutopilotAFMBrain.decide(
                        inputs: inputs,
                        aggressiveness: config.aggressiveness
                    )
                    let decision = AutopilotVerdictGate.apply(
                        verdict,
                        inputs: inputs,
                        aggressiveness: config.aggressiveness
                    )
                    result = AutopilotRouteResult(decision: decision)
                } catch is CancellationError {
                    result = AutopilotRouteResult(decision: heuristic)
                } catch let error as AutopilotBrainError {
                    logBrainFailure(error)
                    result = AutopilotRouteResult(decision: heuristicDecision(inputs, config: config, cause: error))
                } catch {
                    Task { await logger.log("[Autopilot][AFM] unexpected framework error") }
                    result = AutopilotRouteResult(decision: heuristicDecision(inputs, config: config, cause: .unavailable))
                }
            } else {
                result = AutopilotRouteResult(decision: heuristicDecision(inputs, config: config, cause: .unavailable))
            }
        } else if config.routerKind == .privateCloudCompute {
            let heuristic = AutopilotHeuristic.decide(inputs, aggressiveness: config.aggressiveness)
            if brainReachable, AutopilotPCCBrain.isAvailableNow {
                do {
                    let verdict = try await AutopilotPCCBrain.decide(
                        inputs: inputs,
                        aggressiveness: config.aggressiveness
                    )
                    result = AutopilotRouteResult(
                        decision: AutopilotVerdictGate.apply(
                            verdict,
                            inputs: inputs,
                            aggressiveness: config.aggressiveness
                        )
                    )
                } catch is CancellationError {
                    result = AutopilotRouteResult(decision: heuristic)
                } catch let error as AutopilotBrainError {
                    logBrainFailure(error)
                    result = AutopilotRouteResult(
                        decision: heuristicDecision(inputs, config: config, cause: error)
                    )
                } catch {
                    result = AutopilotRouteResult(
                        decision: heuristicDecision(inputs, config: config, cause: .unavailable)
                    )
                }
            } else {
                result = AutopilotRouteResult(
                    decision: heuristicDecision(inputs, config: config, cause: .unavailable)
                )
            }
        } else if let routerBackend = targets.routerBackend,
           let routerModel = targets.routerModel,
           gates.enterpriseAllowsRouterBackend,
           brainReachable,
           !degraded {
            do {
                let outcome = try await AutopilotBrainClient.decide(
                    inputs: inputs,
                    backend: routerBackend,
                    model: routerModel,
                    aggressiveness: config.aggressiveness
                )
                consecutiveTimeouts = 0
                let decision = AutopilotVerdictGate.apply(outcome.decision, inputs: inputs,
                                                          aggressiveness: config.aggressiveness)
                result = AutopilotRouteResult(decision: decision,
                                              routerPromptTokens: outcome.promptTokens,
                                              routerCompletionTokens: outcome.completionTokens)
            } catch let error as AutopilotBrainError {
                logBrainFailure(error)
                // Timeouts AND provider 5xx both count toward degradation: when
                // the router's provider is down, paying ~2s per message for a
                // guaranteed failure is worse than quietly using the heuristic.
                var isTransportFailure = false
                if case .timedOut = error { isTransportFailure = true }
                if case .httpError(let code, _) = error, (500...599).contains(code) { isTransportFailure = true }
                if isTransportFailure {
                    consecutiveTimeouts += 1
                    if consecutiveTimeouts >= Self.degradeAfterTimeouts {
                        degradedUntil = .now + Self.degradeDuration
                    }
                } else {
                    consecutiveTimeouts = 0
                }
                result = AutopilotRouteResult(decision: heuristicDecision(inputs, config: config, cause: error))
            } catch {
                let description = error.localizedDescription
                Task { await logger.log("[Autopilot][Brain] transport error: \(description)") }
                result = AutopilotRouteResult(decision: heuristicDecision(inputs, config: config, cause: .invalidEndpoint))
            }
        } else {
            result = AutopilotRouteResult(decision: heuristicDecision(inputs, config: config, cause: nil, degraded: degraded))
        }

        if result.decision.target == .cloud && config.pauseCloudEscalation && !gates.escalationIsLocal {
            // The verdict still records what the router wanted; the answer stays local.
            result.decision.target = .local
            result.decision.reasonKey = AutopilotReasonKey.escalationPaused
            result.decision.reason = AutopilotReasonKey.localized(AutopilotReasonKey.escalationPaused)
        }
        return result
    }

    func resetDegradation() async {
        consecutiveTimeouts = 0
        degradedUntil = nil
        await AutopilotAFMBrain.resetHealth()
    }

    private func logBrainFailure(_ error: AutopilotBrainError) {
        let detail: String
        switch error {
        case .httpError(let code, let body):
            detail = "http \(code): \(String(body.prefix(300)))"
        case .timedOut: detail = "timeout"
        case .unparseable: detail = "unparseable reply"
        case .invalidEndpoint: detail = "invalid endpoint"
        case .blockedByPolicy: detail = "blocked by policy"
        case .unavailable: detail = "temporarily unavailable"
        }
        Task { await logger.log("[Autopilot][Brain] decision failed: \(detail)") }
    }

    private var isDegraded: Bool {
        guard let until = degradedUntil else { return false }
        if ContinuousClock.now >= until {
            degradedUntil = nil
            consecutiveTimeouts = 0
            return false
        }
        return true
    }

    private func forcedDecision(_ inputs: AutoRouteInputs,
                                config: AutopilotConfig,
                                targets: AutopilotResolvedTargets,
                                gates: PolicyGates) -> AutoRouteDecision? {
        if !gates.escalationIsLocal {
            if gates.offGrid || gates.offline {
                return .forced(.local, reasonKey: AutopilotReasonKey.offGrid)
            }
            if gates.killSwitch {
                return .forced(.local, reasonKey: AutopilotReasonKey.killSwitch)
            }
            if !gates.enterpriseRemoteAllowed || !gates.enterpriseAllowsEscalationBackend {
                return .forced(.local, reasonKey: AutopilotReasonKey.enterprise)
            }
        }
        let escalationTargetMissing: Bool
        switch config.escalationTarget {
        case .localModel:
            escalationTargetMissing = targets.localEscalation == nil
        case .privateCloudCompute:
            escalationTargetMissing = !AutopilotPCCBrain.isSelectable
        case .remote:
            escalationTargetMissing = targets.escalationBackend == nil || targets.escalationModel == nil
        }
        if escalationTargetMissing {
            return .forced(.local, reasonKey: AutopilotReasonKey.noEscalationTarget)
        }
        if inputs.hasImages && !inputs.escalationModel.isVisionCapable {
            return .forced(.local, reasonKey: AutopilotReasonKey.imagesLocalOnly)
        }
        // Knowledge-base turns stay local for privacy — unless the escalation
        // model is itself local, in which case nothing leaves the device.
        if inputs.ragArmed && !config.allowCloudForRAGTurns && !gates.escalationIsLocal {
            return .forced(.local, reasonKey: AutopilotReasonKey.ragPrivacy)
        }
        if !config.pauseCloudEscalation || gates.escalationIsLocal,
           let promptTokens = inputs.promptTokenEstimate,
           promptTokens + AutopilotHeuristic.reservedResponseTokens > inputs.localModel.contextLength,
           let cloudContext = inputs.escalationModel.contextLength,
           promptTokens + AutopilotHeuristic.reservedResponseTokens <= cloudContext {
            var decision = AutoRouteDecision.forced(.cloud, reasonKey: AutopilotReasonKey.contextOverflow, confidence: 0.95)
            decision.category = .longContext
            decision.reason = AutopilotReasonKey.localized(AutopilotReasonKey.contextOverflow)
            return decision
        }
        return nil
    }

    private func heuristicDecision(_ inputs: AutoRouteInputs,
                                   config: AutopilotConfig,
                                   cause: AutopilotBrainError?,
                                   degraded: Bool = false) -> AutoRouteDecision {
        var decision = AutopilotHeuristic.decide(inputs, aggressiveness: config.aggressiveness)
        // Only surface the fallback cause when the LLM was expected to decide;
        // the heuristic's own reason stays when there was never a router configured.
        let key: String?
        if let cause {
            switch cause {
            case .timedOut: key = AutopilotReasonKey.routerTimeout
            case .unparseable: key = AutopilotReasonKey.routerUnparseable
            case .httpError(let code, _) where [401, 402, 403].contains(code):
                key = AutopilotReasonKey.routerKeyRejected
            case .httpError(let code, _) where (500...599).contains(code):
                key = AutopilotReasonKey.routerProviderError
            default: key = AutopilotReasonKey.routerUnreachable
            }
        } else if degraded {
            // Inside the failure cool-down window the router is deliberately
            // skipped; the receipt must say so, not pose as a plain heuristic
            // verdict.
            key = AutopilotReasonKey.routerCoolingDown
        } else {
            key = nil
        }
        if let key, decision.target == .local {
            decision.reasonKey = key
            decision.reason = AutopilotReasonKey.localized(key)
        }
        return decision
    }
}
