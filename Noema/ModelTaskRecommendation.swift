import Foundation
import SwiftUI

enum ModelTaskRecommendation: String, CaseIterable, Identifiable, Equatable {
    case generalChat
    case coding
    case reasoning
    case vision
    case math
    case multilingual
    case toolUse
    case quickLocal

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .generalChat:
            return LocalizedStringKey("General chat")
        case .coding:
            return LocalizedStringKey("Coding")
        case .reasoning:
            return LocalizedStringKey("Reasoning")
        case .vision:
            return LocalizedStringKey("Vision")
        case .math:
            return LocalizedStringKey("Math")
        case .multilingual:
            return LocalizedStringKey("Multilingual")
        case .toolUse:
            return LocalizedStringKey("Tool use")
        case .quickLocal:
            return LocalizedStringKey("Quick local tasks")
        }
    }

    var systemImage: String {
        switch self {
        case .generalChat:
            return "bubble.left.and.bubble.right.fill"
        case .coding:
            return "chevron.left.forwardslash.chevron.right"
        case .reasoning:
            return "brain"
        case .vision:
            return "eye.fill"
        case .math:
            return "function"
        case .multilingual:
            return "globe"
        case .toolUse:
            return "wrench.and.screwdriver.fill"
        case .quickLocal:
            return "bolt.fill"
        }
    }
}

enum ModelTaskRecommendationClassifier {
    static func recommendations(for details: ModelDetails) -> [ModelTaskRecommendation] {
        let text = searchableText(for: details)
        var recommendations: [ModelTaskRecommendation] = [.generalChat]

        if containsAny(text, ["code", "coder", "coding", "programming", "starcoder", "codestral", "devstral", "deepseek-coder"]) {
            recommendations.append(.coding)
        }

        if containsAny(text, ["reasoning", "reason", "r1", "thinking", "think", "qwq", "deepseek", "qwen3", "cot"]) || details.isMoE {
            recommendations.append(.reasoning)
        }

        if details.isVision || containsAny(text, ["vision", "vlm", "multimodal", "image-text", "llava", "pixtral", "gemma-3n"]) {
            recommendations.append(.vision)
        }

        if containsAny(text, ["math", "gsm8k", "olympiad", "aime", "numina"]) {
            recommendations.append(.math)
        }

        if containsAny(text, ["multilingual", "multi-lingual", "translation", "translate", "polyglot", "bilingual", "aya", "qwen", "mistral", "gemma"]) {
            recommendations.append(.multilingual)
        }

        if containsAny(text, ["tool", "function", "function-calling", "json", "structured"]) {
            recommendations.append(.toolUse)
        }

        if details.quants.contains(where: { $0.format == .afm || $0.format == .ane || $0.format == .et })
            || (smallestQuantSize(in: details).map { $0 <= 3_000_000_000 } ?? false) {
            recommendations.append(.quickLocal)
        }

        return deduplicated(recommendations)
    }

    private static func searchableText(for details: ModelDetails) -> String {
        [
            details.id,
            details.summary ?? "",
            details.parameterCountLabel ?? "",
            details.promptTemplate ?? "",
            details.quants.map(\.label).joined(separator: " ")
        ]
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
    }

    private static func smallestQuantSize(in details: ModelDetails) -> Int64? {
        details.quants
            .map(\.sizeBytes)
            .filter { $0 > 0 }
            .min()
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func deduplicated(_ recommendations: [ModelTaskRecommendation]) -> [ModelTaskRecommendation] {
        var seen = Set<ModelTaskRecommendation>()
        return recommendations.filter { seen.insert($0).inserted }
    }
}
