import Foundation

// Deterministic fallback router used when the LLM router brain is unavailable,
// times out, or returns garbage. Pure function so it unit-tests everywhere
// as a pure function. Reasons come from the fixed
// AutopilotReasonKey set — heuristic verdicts must be explainable and
// translatable, never free text.

enum AutopilotHeuristic {
    /// Room the reply needs
    /// before we call the local context overflowed.
    static let reservedResponseTokens = 1024

    private static let heavyCodeMarkers = [
        "implement", "refactor", "write a program", "full code", "debug",
        "stack trace", "segfault", "unit tests", "compile error"
    ]

    private static let mathMarkers = [
        "prove", "deriv", "theorem", "integral", "differential",
        "big-o", "induction", "optimize subject to", "probability that",
        "\\frac", "\\sum"
    ]

    private static let highStakesMarkers = [
        "dosage", "diagnos", "contract", "lawsuit", "tax", "medication", "legal advice"
    ]

    static func decide(_ x: AutoRouteInputs, aggressiveness: RouterAggressiveness) -> AutoRouteDecision {
        let started = ContinuousClock.now

        // Content-dependent forced conditions (the static gates run before us).
        if let promptTokens = x.promptTokenEstimate,
           promptTokens + reservedResponseTokens > x.localModel.contextLength,
           let cloudContext = x.escalationModel.contextLength,
           promptTokens + reservedResponseTokens <= cloudContext {
            return decision(.cloud, key: AutopilotReasonKey.contextOverflow,
                            category: .longContext, confidence: 0.95, score: 10,
                            aggressiveness: aggressiveness, started: started)
        }

        var score = 0
        var dominantKey = AutopilotReasonKey.simpleLocal
        var dominantCategory: AutoRouteDecision.Category = .casualChat
        let text = x.userMessage.lowercased()
        let draftTokens = x.userMessage.count * 2 / 7  // chars ÷ 3.5, the repo's estimator

        if draftTokens > 400 {
            score += 2
            dominantKey = AutopilotReasonKey.longRequest
            dominantCategory = .multiStep
        } else if draftTokens > 150 {
            score += 1
        }

        if text.contains("```") || heavyCodeMarkers.contains(where: text.contains) {
            score += 3
            dominantKey = AutopilotReasonKey.heavyCode
            dominantCategory = .codingHeavy
        }

        if mathMarkers.contains(where: text.contains) {
            score += 3
            dominantKey = AutopilotReasonKey.hardMath
            dominantCategory = .mathReasoning
        }

        if highStakesMarkers.contains(where: text.contains) {
            score += 2
            dominantKey = AutopilotReasonKey.highStakes
            dominantCategory = .highStakes
        }

        let questionMarks = x.userMessage.filter { $0 == "?" }.count
        let enumerated = x.userMessage.contains("\n1.") || x.userMessage.contains("\n2.") || x.userMessage.contains("(a)")
        if questionMarks >= 3 || enumerated { score += 1 }

        if x.conversationTurnCount > 24 { score += 1 }

        // Smaller local models get less benefit of the doubt.
        if x.localModel.sizeGB < 1.5 { score += 2 }
        else if x.localModel.sizeGB < 3.0 { score += 1 }
        else if x.localModel.sizeGB >= 8.0 { score -= 1 }

        // Local generation costs the device right now.
        if x.thermalState == .serious { score += 1 }
        if x.thermalState == .critical {
            score += 2
            dominantKey = AutopilotReasonKey.deviceHot
        }
        if x.batteryLevel >= 0 && x.batteryLevel < 0.15 && !x.isCharging { score += 1 }
        if x.lowPowerMode && x.localModel.sizeGB > 3 { score += 1 }

        let threshold = aggressiveness.heuristicThreshold
        if score >= threshold {
            let confidence = min(0.9, 0.55 + Double(score - threshold) * 0.1)
            // Size, prompt length, and device pressure can cross the cloud
            // threshold without assigning a semantic cloud reason. Never emit
            // the initial `simpleLocal` key for a cloud verdict.
            let cloudKey = dominantKey == AutopilotReasonKey.simpleLocal
                ? AutopilotReasonKey.cloudCapable
                : dominantKey
            return decision(.cloud, key: cloudKey, category: dominantCategory,
                            confidence: confidence, score: score,
                            aggressiveness: aggressiveness, started: started)
        }

        let localKey = score <= 1 ? AutopilotReasonKey.simpleLocal : AutopilotReasonKey.localCapable
        let confidence = min(0.9, 0.6 + Double(threshold - score) * 0.08)
        return decision(.local, key: localKey, category: dominantCategory,
                        confidence: confidence, score: score,
                        aggressiveness: aggressiveness, started: started)
    }

    private static func decision(_ target: AutoRouteTarget,
                                 key: String,
                                 category: AutoRouteDecision.Category,
                                 confidence: Double,
                                 score: Int,
                                 aggressiveness: RouterAggressiveness,
                                 started: ContinuousClock.Instant) -> AutoRouteDecision {
        let elapsed = started.duration(to: .now)
        let ms = Int(Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15)
        return AutoRouteDecision(
            target: target,
            confidence: confidence,
            reason: AutopilotReasonKey.localized(key),
            reasonKey: key,
            category: category,
            estDifficulty: min(5, 1 + max(0, score) / 2),
            latencyMs: ms,
            decidedBy: .heuristic
        )
    }
}
