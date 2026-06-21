import Foundation
import SwiftUI

enum ModelCollection: String, CaseIterable, Identifiable {
    case tinyFast
    case reasoning
    case vision
    case coding
    case math
    case multilingual
    case toolCapable

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .tinyFast:
            return LocalizedStringKey("Tiny Fast")
        case .reasoning:
            return LocalizedStringKey("Reasoning")
        case .vision:
            return LocalizedStringKey("Vision")
        case .coding:
            return LocalizedStringKey("Coding")
        case .math:
            return LocalizedStringKey("Math")
        case .multilingual:
            return LocalizedStringKey("Multilingual")
        case .toolCapable:
            return LocalizedStringKey("Tool-capable")
        }
    }

    var systemImage: String {
        switch self {
        case .tinyFast:
            return "bolt.fill"
        case .reasoning:
            return "brain"
        case .vision:
            return "eye.fill"
        case .coding:
            return "chevron.left.forwardslash.chevron.right"
        case .math:
            return "function"
        case .multilingual:
            return "globe"
        case .toolCapable:
            return "wrench.and.screwdriver.fill"
        }
    }
}

enum ModelCollectionClassifier {
    static func collections(for record: ModelRecord) -> Set<ModelCollection> {
        let searchable = [
            record.id,
            record.displayName,
            record.publisher,
            record.summary ?? "",
            record.pipeline_tag ?? "",
            (record.tags ?? []).joined(separator: " ")
        ]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        var result: Set<ModelCollection> = []

        if record.supportsVision || record.pipeline_tag == "image-text-to-text" || containsAny(searchable, ["vision", "vlm", "multimodal", "image-text-to-text", "llava", "pixtral"]) {
            result.insert(.vision)
        }

        if containsAny(searchable, ["reasoning", "reason", "r1", "thinking", "think", "deepseek", "qwq", "o1", "cot"]) {
            result.insert(.reasoning)
        }

        if containsAny(searchable, ["code", "coder", "coding", "programming", "starcoder", "codestral", "devstral", "deepseek-coder"]) {
            result.insert(.coding)
        }

        if containsAny(searchable, ["math", "gsm8k", "olympiad", "aime", "numina"]) {
            result.insert(.math)
        }

        if containsAny(searchable, ["multilingual", "multi-lingual", "translation", "translate", "polyglot", "bilingual", "aya", "qwen", "mistral"]) {
            result.insert(.multilingual)
        }

        if containsAny(searchable, ["tool", "function", "function-calling", "tools", "json"]) {
            result.insert(.toolCapable)
        }

        if record.formats.contains(.afm) || isSmallParameterModel(searchable) || (record.minRAMBytes.map { $0 <= 3_000_000_000 } ?? false) {
            result.insert(.tinyFast)
        }

        return result
    }

    static func record(_ record: ModelRecord, matches collection: ModelCollection?) -> Bool {
        guard let collection else { return true }
        return collections(for: record).contains(collection)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func isSmallParameterModel(_ text: String) -> Bool {
        if text.contains("mini") || text.contains("small") || text.contains("tiny") || text.contains("1.5b") || text.contains("1_5b") {
            return true
        }

        let pattern = #"(?<!\d)(0\.\d|1(\.\d)?|2(\.\d)?|3(\.\d)?)[\s_-]*b(?![a-z])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
