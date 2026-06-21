// ToolCapabilityDetector.swift
import Foundation

enum ToolCapabilityDetector {
    static func isToolCapable(repoId: String, token: String?) async -> Bool {
        // 1) Fast pass via Hub API tags
        if await hubApiSuggestsTools(repoId: repoId, token: token) { return true }
        // 1.5) Scan hub-hosted chat template and tokenizer added tokens for tool markers
        if await hubTemplatesOrTokensSuggestTools(repoId: repoId, token: token) { return true }
        // 2) Name-based heuristics for known tool-capable models
        if nameSuggestsTools(repoId.lowercased()) { return true }
        // 3) README text scan for tool-related keywords
        if await readmeSuggestsTools(repoId: repoId, token: token) { return true }
        return false
    }
    
    static func isToolCapableCachedOrHeuristic(repoId: String) async -> Bool {
        // 1) Cached hub metadata only (no network)
        if let cached = HuggingFaceMetadataCache.cached(repoId: repoId), let tags = cached.tags {
            let lowerTags = Set(tags.map { $0.lowercased() })
            let toolTags = ["tool-use", "function-calling", "agents", "tool-calling", "function-call"]
            if lowerTags.contains(where: { toolTags.contains($0) }) { return true }
        }
        // 2) Name heuristics
        if nameSuggestsTools(repoId.lowercased()) { return true }
        return false
    }
    
    // MARK: - Template/Token Scanning (Hub)

    private static let toolTemplateKeywords: [String] = [
        // Generic
        "tools", "tool_call", "tool_calls", "function_call", "function_calls",
        "tool_result", "tool_response", "function_response",
        "assistant_tools", "tool_call_id",
        // XML wrappers
        "<tool_call>", "</tool_call>", "<tools>", "</tools>",
        // Role markers
        #""role":\s*"tool"#,
        // Qwen/Qwen3 style tokens
        "<|tool_call|>", "<|tool_response|>", "<|im_start|>tool",
        // Llama 3.1/3.2 style
        "<|assistant_tools|>",
        // Gemma2/3 style
        "function_call", "function_response"
    ]

    private static func textContainsToolHints(_ text: String) -> Bool {
        let lower = text.lowercased()
        return toolTemplateKeywords.contains { lower.contains($0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)) }
    }

    private static func hubTemplatesOrTokensSuggestTools(repoId: String, token: String?) async -> Bool {
        let files = [
            "config.json",
            "tokenizer_config.json",
            "tokenizer.json",
            "added_tokens.json"
        ]
        for f in files {
            if let data = await fetchResolved(repoId: repoId, file: f, token: token),
               let s = String(data: data, encoding: .utf8) {
                if textContainsToolHints(s) { return true }
                // Look for explicit chat_template field
                if let tmpl = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ct = tmpl["chat_template"] as? String, textContainsToolHints(ct) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Local (on-disk) detection for installed models

    static func isToolCapableLocal(url: URL, format: ModelFormat) -> Bool {
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
            return GGUFMetadata.suggestsTools(at: ggufURL)
        case .mlx:
            var dir = url
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
                dir = dir.deletingLastPathComponent()
            }
            let candidates = ["config.json", "tokenizer_config.json", "tokenizer.json", "added_tokens.json"]
                .map { dir.appendingPathComponent($0) }
            for file in candidates where FileManager.default.fileExists(atPath: file.path) {
                if let data = try? Data(contentsOf: file), let s = String(data: data, encoding: .utf8) {
                    if textContainsToolHints(s) { return true }
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let ct = obj["chat_template"] as? String, textContainsToolHints(ct) {
                        return true
                    }
                }
            }
            return false
        case .et:
            return true // Allow Leap/ET to use tools by design
        case .ane:
            var root = InstalledModelsStore.canonicalURL(for: url, format: .ane)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) || !isDir.boolValue {
                root = root.deletingLastPathComponent()
            }

            var candidateDirs: [URL] = [root]
            if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for entry in entries {
                    var dirFlag: ObjCBool = false
                    if FileManager.default.fileExists(atPath: entry.path, isDirectory: &dirFlag), dirFlag.boolValue {
                        candidateDirs.append(entry)
                    }
                }
            }

            let candidateNames = ["config.json", "tokenizer_config.json", "tokenizer.json", "added_tokens.json", "chat_template.json"]
            for dir in candidateDirs {
                for name in candidateNames {
                    let file = dir.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    if let data = try? Data(contentsOf: file), let s = String(data: data, encoding: .utf8) {
                        if textContainsToolHints(s) { return true }
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let ct = obj["chat_template"] as? String, textContainsToolHints(ct) {
                            return true
                        }
                    }
                }
            }
            return false
        case .afm:
            return true
        case .coreai:
            var root = InstalledModelsStore.canonicalURL(for: url, format: .coreai)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) || !isDir.boolValue {
                root = root.deletingLastPathComponent()
            }

            // Core AI installs mirror the repo layout, so the tokenizer and any
            // config sidecars can sit several levels down (e.g. ios-ane/<variant>/).
            // Walk the tree, but never descend into the .aimodel(c) bundles.
            let candidateNames: Set<String> = [
                "config.json", "tokenizer_config.json", "tokenizer.json",
                "added_tokens.json", "chat_template.json"
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
                if let data = try? Data(contentsOf: file), let s = String(data: data, encoding: .utf8) {
                    if textContainsToolHints(s) { return true }
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let ct = obj["chat_template"] as? String, textContainsToolHints(ct) {
                        return true
                    }
                }
            }
            return false
        }
    }

    private static func hubApiSuggestsTools(repoId: String, token: String?) async -> Bool {
        if let cached = HuggingFaceMetadataCache.cached(repoId: repoId), let tags = cached.tags {
            let lowerTags = Set(tags.map { $0.lowercased() })
            let toolTags = ["tool-use", "function-calling", "agents", "tool-calling", "function-call"]
            if lowerTags.contains(where: { toolTags.contains($0) }) { return true }
        }
        if let meta = await HuggingFaceMetadataCache.fetchAndCache(repoId: repoId, token: token), let tags = meta.tags {
            let lowerTags = Set(tags.map { $0.lowercased() })
            let toolTags = ["tool-use", "function-calling", "agents", "tool-calling", "function-call"]
            if lowerTags.contains(where: { toolTags.contains($0) }) { return true }
        }
        return false
    }
    
    private static func nameSuggestsTools(_ lowerName: String) -> Bool {
        // Instruction-tuned naming hints (treat as tool-capable)
        if lowerName.contains("instruct") { return true }
        // Safe tokenized "it" (instruction-tuned) suffix/prefix detection: -it, _it, /it, or spaced
        if lowerName.range(of: #"(^|[^a-z0-9])it([^a-z0-9]|$)"#, options: .regularExpression) != nil { return true }

        // Known tool-capable model families and variants
        if lowerName.contains("tool") || lowerName.contains("function") || lowerName.contains("agent") { return true }
        if lowerName.contains("qwen") && (lowerName.contains("2.5") || lowerName.contains("2-5")) { return true }
        if lowerName.contains("llama-3.1") || lowerName.contains("llama3.1") { return true }
        if lowerName.contains("llama-3.2") || lowerName.contains("llama3.2") { return true }
        if lowerName.contains("mistral") && (lowerName.contains("7b") || lowerName.contains("8x7b")) { return true }
        if lowerName.contains("hermes") { return true }
        if lowerName.contains("nous") { return true }
        if lowerName.contains("dolphin") { return true }
        if lowerName.contains("openchat") { return true }
        if lowerName.contains("wizard") { return true }
        return false
    }
    
    private static func readmeSuggestsTools(repoId: String, token: String?) async -> Bool {
        let readmeFiles = ["README.md", "readme.md", "README.txt", "readme.txt"]
        for file in readmeFiles {
            if let readme = await fetchResolved(repoId: repoId, file: file, token: token),
               let text = String(data: readme, encoding: .utf8)?.lowercased() {
                if readmeContainsToolHints(text) { return true }
            }
        }
        return false
    }
    
    private static func readmeContainsToolHints(_ text: String) -> Bool {
        let toolKeywords = [
            "tool calling", "function calling", "tool use", "function call",
            "agents", "tool-use", "function-call", "api calls", "external tools",
            "tool integration", "function integration", "structured output",
            "json schema", "tool schema", "function schema"
        ]
        return toolKeywords.contains { text.contains($0) }
    }
    
    private static func resolvedURL(repoId: String, file: String) -> String {
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        return "https://huggingface.co/\(escaped)/resolve/main/\(file)"
    }
    
    private static func fetch(_ urlStr: String, token: String?) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, resp) = try await HFHubRequestManager.shared.data(for: url,
                                                                         token: token,
                                                                         accept: nil,
                                                                         timeout: 6)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) { return data }
        } catch { }
        return nil
    }
    
    private static func fetchResolved(repoId: String, file: String, token: String?) async -> Data? {
        let url = resolvedURL(repoId: repoId, file: file)
        return await fetch(url, token: token)
    }
}
