import Foundation

struct CuratedModelNote: Equatable {
    let id: String
    let titleKey: String
    let bodyKey: String
    let systemImage: String
}

enum CuratedModelNotes {
    static func note(for modelID: String) -> CuratedModelNote? {
        let normalized = modelID
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("apple") || normalized.contains("foundation-model") {
            return CuratedModelNote(
                id: "apple-foundation",
                titleKey: "Apple Foundation Models",
                bodyKey: "System models are private and fast when available, but only expose the fixed Apple runtime and context window.",
                systemImage: "apple.intelligence"
            )
        }

        if normalized.contains("deepseek") {
            return CuratedModelNote(
                id: "deepseek",
                titleKey: "DeepSeek family",
                bodyKey: "DeepSeek models are useful for reasoning and coding; choose smaller distilled builds when memory is tight.",
                systemImage: "brain.head.profile"
            )
        }

        if normalized.contains("qwen") {
            return CuratedModelNote(
                id: "qwen",
                titleKey: "Qwen family",
                bodyKey: "Qwen models are strong general assistants with good coding and multilingual coverage; prefer recent instruct builds for chat.",
                systemImage: "globe.asia.australia.fill"
            )
        }

        if normalized.contains("llama") {
            return CuratedModelNote(
                id: "llama",
                titleKey: "Llama family",
                bodyKey: "Llama models are widely supported by GGUF tooling and make good default chat models when the quant fits your device.",
                systemImage: "message.fill"
            )
        }

        if normalized.contains("gemma") {
            return CuratedModelNote(
                id: "gemma",
                titleKey: "Gemma family",
                bodyKey: "Gemma models are compact and capable; check the repository notes for the recommended prompt template and license terms.",
                systemImage: "sparkle"
            )
        }

        if normalized.contains("mistral") || normalized.contains("mixtral") {
            return CuratedModelNote(
                id: "mistral",
                titleKey: "Mistral family",
                bodyKey: "Mistral-family models often run efficiently at small sizes; Mixtral variants may need extra RAM because they use MoE routing.",
                systemImage: "wind"
            )
        }

        if normalized.contains("phi") {
            return CuratedModelNote(
                id: "phi",
                titleKey: "Phi family",
                bodyKey: "Phi models are tuned for compact devices and quick responses, but quality varies strongly by task and quantization.",
                systemImage: "speedometer"
            )
        }

        return nil
    }
}
