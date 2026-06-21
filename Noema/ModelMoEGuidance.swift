import Foundation

struct ModelMoEGuidance: Equatable {
    struct Metric: Identifiable, Equatable {
        let id: String
        let titleKey: String
        let value: String
        let systemImage: String
    }

    let summaryKey: String
    let cautionKey: String
    let metrics: [Metric]

    static func make(for detail: ModelDetails) -> ModelMoEGuidance? {
        let normalized = detail.id
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard isLikelyMoE(normalized: normalized, detail: detail) else {
            return nil
        }

        let totalExperts = inferredTotalExperts(from: normalized)
        let activeExperts = inferredActiveExperts(from: normalized, totalExperts: totalExperts)

        return ModelMoEGuidance(
            summaryKey: "MoE models route each token through a subset of expert feed-forward networks. They can improve quality at a given active compute level, but expert weights still affect disk use and memory planning.",
            cautionKey: "Start with a balanced quant on memory-limited devices; raising active experts can increase RAM use and latency.",
            metrics: [
                Metric(
                    id: "routing",
                    titleKey: "Routing",
                    value: routingValue(activeExperts: activeExperts, totalExperts: totalExperts),
                    systemImage: "point.3.connected.trianglepath.dotted"
                ),
                Metric(
                    id: "memory",
                    titleKey: "Memory",
                    value: String(localized: "Expert-aware estimate"),
                    systemImage: "memorychip"
                ),
                Metric(
                    id: "behavior",
                    titleKey: "Behavior",
                    value: String(localized: "Sparse activation"),
                    systemImage: "speedometer"
                )
            ]
        )
    }

    private static func isLikelyMoE(normalized: String, detail: ModelDetails) -> Bool {
        if detail.isMoE { return true }
        if normalized.contains("mixtral") { return true }
        if normalized.contains("deepseek-v2") || normalized.contains("deepseek-v3") { return true }
        if normalized.contains("-moe") || normalized.contains("_moe") { return true }
        if normalized.contains("moe-") || normalized.contains("moe_") { return true }
        return normalized.hasSuffix("moe")
    }

    private static func inferredTotalExperts(from normalized: String) -> Int? {
        guard let range = normalized.range(
            of: #"(?<![a-z0-9])\d{1,3}x\d+(?:\.\d+)?b"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let token = normalized[range]
        guard let separator = token.firstIndex(of: "x"),
              let count = Int(token[..<separator]) else {
            return nil
        }
        return max(count, 1)
    }

    private static func inferredActiveExperts(from normalized: String, totalExperts: Int?) -> Int? {
        if let explicit = explicitActiveExperts(from: normalized, totalExperts: totalExperts) {
            return explicit
        }
        if normalized.contains("mixtral"), let totalExperts {
            return min(2, totalExperts)
        }
        return nil
    }

    private static func explicitActiveExperts(from normalized: String, totalExperts: Int?) -> Int? {
        guard let range = normalized.range(
            of: #"top[-_ ]?\d{1,2}"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let digits = normalized[range]
            .filter(\.isNumber)
        guard let count = Int(String(digits)) else {
            return nil
        }

        if let totalExperts {
            return min(max(count, 1), totalExperts)
        }
        return max(count, 1)
    }

    private static func routingValue(activeExperts: Int?, totalExperts: Int?) -> String {
        if let activeExperts, let totalExperts {
            return String.localizedStringWithFormat(
                String(localized: "Active experts per token: %@ of %@"),
                "\(activeExperts)",
                "\(totalExperts)"
            )
        }

        if let totalExperts {
            if totalExperts == 1 {
                return String(localized: "1 expert")
            }
            return String.localizedStringWithFormat(
                String(localized: "%@ experts"),
                "\(totalExperts)"
            )
        }

        if let activeExperts {
            if activeExperts == 1 {
                return String(localized: "1 expert")
            }
            return String.localizedStringWithFormat(
                String(localized: "%@ experts"),
                "\(activeExperts)"
            )
        }

        return String(localized: "Expert routed")
    }
}
