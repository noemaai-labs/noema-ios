import Foundation

/// Exposes reasoning only when the runtime can switch it per request: GGUF
/// templates with `enable_thinking`, or Core AI tokenizers with `<think>`.
enum ReasoningCapabilityDetector {
    static func isReasoningCapableLocal(url: URL, format: ModelFormat) -> Bool {
        switch format {
        case .gguf:
            var ggufURL = url
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: ggufURL.path, isDirectory: &isDir), isDir.boolValue {
                if let f = try? FileManager.default.contentsOfDirectory(at: ggufURL, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                    ggufURL = f
                }
            }
            guard let template = GGUFMetadata.chatTemplate(at: ggufURL) else { return false }
            return templateExposesThinkingSwitch(template)
        case .coreai:
            var root = InstalledModelsStore.canonicalURL(for: url, format: .coreai)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) || !isDir.boolValue {
                root = root.deletingLastPathComponent()
            }
            // Core AI installs mirror the repo layout, so tokenizer sidecars can sit
            // several levels down. Walk the tree but never descend into .aimodel bundles.
            let candidateNames: Set<String> = [
                "tokenizer_config.json", "tokenizer.json", "added_tokens.json",
                "config.json", "chat_template.json"
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return false }
            for case let file as URL in enumerator {
                if ["aimodel", "aimodelc"].contains(file.pathExtension.lowercased()) {
                    enumerator.skipDescendants()
                    continue
                }
                guard candidateNames.contains(file.lastPathComponent.lowercased()) else { continue }
                if let data = try? Data(contentsOf: file),
                   let s = String(data: data, encoding: .utf8),
                   textExposesThinkToken(s) {
                    return true
                }
            }
            return false
        case .mlx, .et, .ane, .afm:
            // No per-request thinking switch is honored by these runtimes yet.
            return false
        }
    }

    /// True when the chat template branches on a runtime thinking switch the server
    /// can flip (Qwen3-style `enable_thinking`).
    private static func templateExposesThinkingSwitch(_ template: String) -> Bool {
        template.lowercased().contains("enable_thinking")
    }

    /// True when a tokenizer/config payload exposes a `<think>` token that the Core AI
    /// client can prime, or the template's `enable_thinking` switch.
    private static func textExposesThinkToken(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<think>") || lower.contains("enable_thinking")
    }
}
