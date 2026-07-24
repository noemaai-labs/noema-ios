import Foundation

// Deterministic post-verdict gate for LLM/AFM router verdicts. The per-mode
// prompt rubric reduces over-escalation propensity; this gate bounds it.
// Forced and heuristic verdicts pass through untouched — they are already
// mode-aware. Demotions keep the router's confidence/category/difficulty
// (what it truthfully said) but must swap in an AutopilotReasonKey reason:
// the LLM's cloud justification on a local answer would be a lying receipt.

enum AutopilotVerdictGate {
    /// Minimum self-reported difficulty before a cloud verdict is honored.
    /// Conserve 4 keeps textbook/everyday work (2-3 per the prompt's
    /// difficulty anchor) local; frontier 1 is a deliberate no-op.
    static func difficultyFloor(_ aggressiveness: RouterAggressiveness) -> Int {
        switch aggressiveness {
        case .conserve: return 4
        case .balanced: return 2
        case .frontier: return 1
        }
    }

    static func apply(_ decision: AutoRouteDecision,
                      inputs: AutoRouteInputs,
                      aggressiveness: RouterAggressiveness) -> AutoRouteDecision {
        guard decision.target == .cloud,
              decision.decidedBy == .llm
                || decision.decidedBy == .afm
                || decision.decidedBy == .pcc else { return decision }

        // High-stakes and explicit user requests escalate in every mode,
        // subject only to a sanity floor (never stricter than the mode's own
        // gate). Asymmetric on purpose: a laundered routine question costs one
        // cloud call; a blocked dosage question or an overridden explicit ask
        // costs trust.
        if decision.category == .highStakes || decision.category == .explicitRequest {
            let floor = Swift.min(0.60, aggressiveness.cloudConfidenceGate)
            return decision.confidence >= floor
                ? decision
                : demoted(decision, key: AutopilotReasonKey.lowRouterConfidence)
        }
        if decision.confidence < aggressiveness.cloudConfidenceGate {
            return demoted(decision, key: AutopilotReasonKey.lowRouterConfidence)
        }
        // long_context skips the difficulty floor only when the prompt
        // actually crowds the local window; hard overflow is already forced
        // upstream of the brain.
        if decision.category == .longContext,
           let promptTokens = inputs.promptTokenEstimate,
           promptTokens + AutopilotHeuristic.reservedResponseTokens
               > (inputs.localModel.contextLength * 3) / 5 {
            return decision
        }
        if decision.estDifficulty < difficultyFloor(aggressiveness) {
            return demoted(decision, key: AutopilotReasonKey.routineForMode)
        }
        return decision
    }

    private static func demoted(_ decision: AutoRouteDecision, key: String) -> AutoRouteDecision {
        var out = decision
        out.target = .local
        out.reasonKey = key
        out.reason = AutopilotReasonKey.localized(key)
        return out
    }
}
