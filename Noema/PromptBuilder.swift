import Foundation
import NoemaPackages

/// Builds prompts for different model templates and families.
struct PromptBuilder {
    /// Known template kinds that influence serialization.
    enum TemplateKind {
        case llama3
        case inst
        case chatml
        case qwen35
        case chatmlWithStartOfText // Liquid LFM: requires <|startoftext|> prefix
        case gemmaTurn
        case phi
        // New dedicated families
        case internlm
        case deepseek
        case yi
        case alpaca
        case vicuna
        case none
    }

    // MARK: - DeepSeek runtime markers (from tokenizer.json)
    private struct DSMarkers {
        let bos: String?
        let eos: String?
        let user: String?
        let assistant: String?
    }
    private static func loadDeepSeekMarkers(tokenizerPath: String? = nil) -> DSMarkers? {
        // GGUF tokenizers are interpreted inside llama-server. This optional
        // reader remains available only for a backend that explicitly supplies
        // a supported tokenizer path; process-wide environment state is ignored.
        guard let tokPath = tokenizerPath, !tokPath.isEmpty else { return nil }

        func readJSON(_ url: URL) -> Any? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        func normBars(_ s: String) -> String {
            // Normalize ASCII bars and common mojibake remnants to fullwidth bars
            var t = s
            t = t.replacingOccurrences(of: "|", with: "｜")
            // Common mojibake sequences seen in DeepSeek tokenizer dumps
            t = t.replacingOccurrences(of: "ï½œ", with: "｜") // mojibake fullwidth bar
            t = t.replacingOccurrences(of: "â–", with: "▁") // mojibake SPM block
            t = t.replacingOccurrences(of: "攼", with: "｜") // mojibake left bar
            t = t.replacingOccurrences(of: "放", with: "｜") // mojibake right bar
            // Collapse stray spaces just inside angle brackets
            t = t.replacingOccurrences(of: "<｜ ", with: "<｜")
            t = t.replacingOccurrences(of: " ｜>", with: "｜>")
            return t
        }
        func looks(_ s: String, contains needle: String) -> Bool {
            return normBars(s).contains(needle)
        }
        func gatherMarkers(from obj: Any, current: inout DSMarkers) {
            func consider(_ s: String) {
                let t = normBars(s)
                if t.contains("begin▁of▁sentence") {
                    if current.bos == nil { current = DSMarkers(bos: t, eos: current.eos, user: current.user, assistant: current.assistant) }
                }
                if t.contains("end▁of▁sentence") {
                    if current.eos == nil { current = DSMarkers(bos: current.bos, eos: t, user: current.user, assistant: current.assistant) }
                }
                if t.contains("<｜User｜>") || t.contains("<｜user｜>") || t == "<｜User｜>" || t.contains("<|User|>") {
                    if current.user == nil { current = DSMarkers(bos: current.bos, eos: current.eos, user: "<｜User｜>", assistant: current.assistant) }
                }
                if t.contains("<｜Assistant｜>") || t.contains("<｜assistant｜>") || t == "<｜Assistant｜>" || t.contains("<|Assistant|>") {
                    if current.assistant == nil { current = DSMarkers(bos: current.bos, eos: current.eos, user: current.user, assistant: "<｜Assistant｜>") }
                }
            }
            if let d = obj as? [String: Any] {
                // Common fields: added_tokens (list of dicts), special_tokens (list or dict), chat_template
                if let arr = d["added_tokens"] as? [Any] {
                    for e in arr {
                        if let m = e as? [String: Any], let s = m["content"] as? String { consider(s) }
                    }
                }
                if let sp = d["special_tokens"] {
                    if let arr = sp as? [Any] {
                        for e in arr { if let m = e as? [String: Any], let s = m["content"] as? String { consider(s) } }
                    } else if let map = sp as? [String: Any] {
                        for (_, v) in map { if let s = v as? String { consider(s) } }
                    }
                }
                if let ct = d["chat_template"] as? String {
                    consider(ct)
                }
                // Walk shallow values for strings
                for (_, v) in d { if let s = v as? String { consider(s) } }
            } else if let arr = obj as? [Any] {
                for v in arr { gatherMarkers(from: v, current: &current) }
            }
        }

        let url = URL(fileURLWithPath: tokPath)
        let dir = url.deletingLastPathComponent()
        let tokJSON: URL = {
            if url.lastPathComponent.lowercased() == "tokenizer.json" { return url }
            let cand = dir.appendingPathComponent("tokenizer.json")
            return FileManager.default.fileExists(atPath: cand.path) ? cand : url
        }()
        // Sidecar cache co-located with tokenizer to ensure it is deleted with the model directory
        let sidecar = dir.appendingPathComponent("ds_markers.cache.json")
        // If cache exists and matches tokenizer path + mtime, use it
        if FileManager.default.fileExists(atPath: sidecar.path) {
            if let attr = try? FileManager.default.attributesOfItem(atPath: tokJSON.path),
               let mtime = (attr[.modificationDate] as? Date)?.timeIntervalSince1970,
               let data = try? Data(contentsOf: sidecar),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let cachedPath = (obj["tokenizer_path"] as? String) ?? ""
                let cachedMTime = (obj["tokenizer_mtime"] as? Double) ?? -1
                if cachedPath == tokJSON.path && (cachedMTime - mtime).magnitude < 0.5,
                   let m = obj["markers"] as? [String: Any] {
                    let bos = m["bos"] as? String
                    let eos = m["eos"] as? String
                    let user = m["user"] as? String
                    let assistant = m["assistant"] as? String
                    return DSMarkers(bos: bos, eos: eos, user: user, assistant: assistant)
                }
            }
        }
        var found = DSMarkers(bos: nil, eos: nil, user: nil, assistant: nil)
        if let obj = readJSON(tokJSON) { gatherMarkers(from: obj, current: &found) }
        // Try neighbors for more hints
        let neighbors = ["tokenizer_config.json", "special_tokens_map.json"]
        for name in neighbors {
            let p = dir.appendingPathComponent(name)
            if let obj = readJSON(p) { gatherMarkers(from: obj, current: &found) }
        }
        // If only ASCII variants were present, normalize to canonical fullwidth
        func canon(_ s: String?) -> String? { s.map { normBars($0) } }
        let result = DSMarkers(
            bos: canon(found.bos),
            eos: canon(found.eos),
            user: found.user ?? (looks("<|User|>", contains: "<｜User｜>") ? "<｜User｜>" : nil),
            assistant: found.assistant ?? (looks("<|Assistant|>", contains: "<｜Assistant｜>") ? "<｜Assistant｜>" : nil)
        )
        // Persist sidecar cache with tokenizer path + mtime for invalidation on updates
        if let attr = try? FileManager.default.attributesOfItem(atPath: tokJSON.path),
           let mtime = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 {
            var dict: [String: Any] = [:]
            dict["tokenizer_path"] = tokJSON.path
            dict["tokenizer_mtime"] = mtime
            var markers: [String: Any] = [:]
            if let bos = result.bos { markers["bos"] = bos }
            if let eos = result.eos { markers["eos"] = eos }
            if let user = result.user { markers["user"] = user }
            if let assistant = result.assistant { markers["assistant"] = assistant }
            dict["markers"] = markers
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
                try? data.write(to: sidecar, options: .atomic)
            }
        }
        return result
    }

    /// Detects the template kind from a chat template string or model kind.
    static func detect(template: String?, family: ModelKind) -> TemplateKind {
        // If a template string is provided (e.g., curated ChatML), honor it first.
        if let t = template?.lowercased() {
            if t.contains("<tool_call>") && t.contains("<function=") && t.contains("<parameter=") && t.contains("enable_thinking") {
                return .qwen35
            }
            if t.contains("<|begin_of_text|>") { return .llama3 }
            if t.contains("<start_of_turn>") { return .gemmaTurn }
            // Prefer LFM-style when template explicitly uses <|startoftext|> token
            if t.contains("<|startoftext|>") { return .chatmlWithStartOfText }
            if t.contains("<|im_start|>") { return .chatml }
            if t.contains("[inst]") || t.contains("<<sys>>") { return .inst }
            if t.contains("<|system|>") && (t.contains("<|user|>") || t.contains("<|assistant|>")) { return .phi }
            // Basic heuristics for deepseek/yi/internlm tokens if present
            // DeepSeek R1 Distill commonly uses fullwidth role markers and BOS
            if (t.contains("<｜user｜>") && t.contains("<｜assistant｜>")) ||
               (t.contains("<|user|>") && t.contains("<|assistant|>")) ||
               t.contains("<｜begin▁of▁sentence｜>") {
                return .deepseek
            }
            if t.contains("<|startoftext|>") && (t.contains("yi") || t.contains("use_default_system_prompt")) { return .yi }
            if t.contains("### instruction") { return .alpaca }
            if t.contains("user:") && t.contains("assistant:") { return .vicuna }
        }
        // No explicit template: use tokenizer.json markers if present
        if let markers = loadDeepSeekMarkers() {
            if (markers.user != nil) || (markers.assistant != nil) || (markers.bos?.contains("begin▁of▁sentence") == true) {
                return .deepseek
            }
        }
        switch family {
        case .llama3: return .llama3
        case .mistral: return .inst
        case .gemma: return .gemmaTurn
        case .qwen: return .chatml
        case .smol: return .chatml
        case .lfm: return .chatmlWithStartOfText
        case .phi: return .phi
        case .internlm: return .internlm
        case .deepseek: return .deepseek
        case .yi: return .yi
        default: return .none
        }
    }

    #if os(iOS) || os(visionOS) || os(macOS)
    /// Builds the final prompt, stop tokens and optional max token limit.
    static func build(template: String?, family: ModelKind, history: [ChatVM.Msg], system: String) -> (String, [String], Int?) {
        let tmpl = detect(template: template, family: family)
        // Do not constrain completion length; let backends decide.
        let maxTokens: Int? = nil
        var msgs = history
        if msgs.last?.streaming == true { msgs.removeLast() }
        // Drop trailing empty assistant placeholder if present
        if let last = msgs.last, last.role.lowercased() == "assistant" && last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            msgs.removeLast()
        }

        var systemText = system
        // Always prefer the provided system prompt parameter when this variant is used.
        // Historical system messages (if any) are ignored in favor of the parameter.
        msgs.removeAll(where: { $0.role.lowercased() == "system" })

        // Gather any tool results that should be reinjected into the context for the next turn.
        // For non-ChatML templates we include these as additional user-side context blocks.
        let toolResults: [String] = msgs.filter { $0.role == "tool" }.map { $0.text }

        var pairs: [(String, String?)] = []
        var currentUser: String?
        for m in msgs {
            let lower = m.role.lowercased()
            if m.role == "🧑‍💻" || lower == "user" {
                if let u = currentUser { pairs.append((u, nil)) }
                currentUser = m.text
            } else if m.role == "🤖" || lower == "assistant" {
                if let u = currentUser { pairs.append((u, m.text)); currentUser = nil }
            }
        }
        if let u = currentUser { pairs.append((u, nil)) }
        guard let last = pairs.popLast() else { return ("", [], maxTokens) }

        let tmplIsDeepseekLlama: Bool = {
            let t = (template ?? "").lowercased()
            return t.contains("<｜assistant｜><think>")
        }()

        switch tmpl {
        case .gemmaTurn:
            var p = "<bos>"
            if !systemText.isEmpty {
                p += "<start_of_turn>system\n" + systemText + "<end_of_turn>\n"
            }
            for (u,a) in pairs {
                p += "<start_of_turn>user\n" + u + "<end_of_turn>\n"
                if let a { p += "<start_of_turn>model\n" + a + "<end_of_turn>\n" }
            }
            // Include any tool results as additional user-provided context before starting the model turn
            p += "<start_of_turn>user\n" + last.0
            if !toolResults.isEmpty {
                for t in toolResults { p += "\nTool Result:\n" + t + "\n" }
            }
            p += "<end_of_turn>\n<start_of_turn>model\n"
            return (p, ["<end_of_turn>", "<start_of_turn>user"], maxTokens)
        case .chatml:
            // Build sequentially from full message history to support tool results.
            var p = ""
            // SmolLM: insert default system when none provided.
            if family == .smol && systemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                systemText = "You are a helpful AI assistant named SmolLM, trained by Hugging Face"
            }
            if !systemText.isEmpty {
                p += "<|im_start|>system\n" + systemText + "\n<|im_end|>\n"
            }
            // Reconstruct a flat sequence from original msgs preserving order
            // We include all user/assistant turns, and map tool results to a user block with <tool_response> wrapper
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    // Insert tool response as a user message to provide context to the model
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            // Start assistant for next turn
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .qwen35:
            var p = ""
            if !systemText.isEmpty {
                p += "<|im_start|>system\n" + systemText + "\n<|im_end|>\n"
            }
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n<think>\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .chatmlWithStartOfText:
            // Liquid LFM variant: prefix with <|startoftext|> and default Liquid system prompt when none provided
            var p = "<|startoftext|>"
            let defaultLiquidSystem = "You are a helpful assistant trained by ExecuTorch."
            let sys = systemText.isEmpty ? defaultLiquidSystem : systemText
            p += "<|im_start|>system\n" + sys + "\n<|im_end|>\n"
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .llama3:
            var p = "<|begin_of_text|>"
            if !systemText.isEmpty {
                p += "<|start_header_id|>system<|end_header_id|>\n" + systemText + "<|eot_id|>"
            }
            for (u,a) in pairs {
                p += "<|start_header_id|>user<|end_header_id|>\n" + u + "<|eot_id|>"
                if let a { p += "<|start_header_id|>assistant<|end_header_id|>\n" + a + "<|eot_id|>" }
            }
            // Final user turn with optional tool results as additional user context blocks
            p += "<|start_header_id|>user<|end_header_id|>\n" + last.0 + "<|eot_id|>"
            if !toolResults.isEmpty {
                for t in toolResults {
                    p += "<|start_header_id|>user<|end_header_id|>\nTool Result:\n" + t + "\n<|eot_id|>"
                }
            }
            p += "<|start_header_id|>assistant<|end_header_id|>\n"
            return (p, ["<|eot_id|>", "<|end_of_text|>"], maxTokens)
        case .inst:
            var p = "<s>[INST] "
            if !systemText.isEmpty {
                p += "<<SYS>>\n" + systemText + "\n<</SYS>>\n\n"
            }
            for (u,a) in pairs {
                p += u + " [/INST] " + (a ?? "") + "</s><s>[INST] "
            }
            var finalUser = last.0
            if !toolResults.isEmpty {
                for t in toolResults { finalUser += "\nTool Result:\n" + t + "\n" }
            }
            p += finalUser + " [/INST]"
            return (p, ["</s>"], maxTokens)
        case .phi:
            var p = ""
            if !systemText.isEmpty { p += "<|system|>\n" + systemText + "\n" }
            for (u,a) in pairs {
                p += "<|user|>\n" + u + "\n<|assistant|>\n" + (a ?? "")
            }
            p += "<|user|>\n" + last.0 + "\n"
            if !toolResults.isEmpty {
                for t in toolResults { p += "<|user|>\nTool Result:\n" + t + "\n" }
            }
            p += "<|assistant|>\n"
            return (p, ["<|end|>", "<|user|>", "<|system|>", "<|endoftext|>"], maxTokens)
        case .internlm:
            // InternLM: follow official style; if no explicit system, insert default thinking system
            var p = ""
            var sys = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
            if sys.isEmpty {
                sys = "You are InternLM, a helpful assistant. Think step by step when needed."
            }
            p += "<|im_start|>system\n" + sys + "\n<|im_end|>\n"
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .deepseek:
            // DeepSeek R1 Distill (Qwen): Use BOS + raw system prompt, and
            // then alternate <｜User｜>user<｜Assistant｜> and assistant + <｜end▁of▁sentence｜>.
            let markers = loadDeepSeekMarkers()
            let bos = markers?.bos ?? "<｜begin▁of▁sentence｜>"
            let userTag = markers?.user ?? "<｜User｜>"
            let assistantTag = markers?.assistant ?? "<｜Assistant｜>"
            let eosTag = markers?.eos ?? "<｜end▁of▁sentence｜>"
            var p = bos
            let sys = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sys.isEmpty { p += sys }
            for m in msgs {
                let role = m.role.lowercased()
                if role == "user" || role == "🧑‍💻".lowercased() {
                    p += userTag + m.text + assistantTag
                } else if role == "assistant" || role == "🤖".lowercased() {
                    p += m.text + eosTag
                } else if role == "tool" {
                    p += "\n<tool_response>\n" + m.text + "\n</tool_response>\n"
                }
            }
            if let last = msgs.last, ["user", "🧑‍💻".lowercased()].contains(last.role.lowercased()) {
                p += assistantTag
            }
            // Prefer tokenizer-provided User marker for stopping; include ASCII fallback and eos if provided
            var stopList = [userTag, "<|User|>", "</s>", "<eos>", "</eos>"]
            if let eos = markers?.eos { stopList.append(eos) }
            return (p, stopList, maxTokens)
        case .yi:
            // Yi: respect default system prompt and BOS <|startoftext|>
            var p = "<|startoftext|>"
            var sys = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
            if sys.isEmpty {
                // Insert Yi's default if none supplied
                sys = "You are Yi, a helpful and harmless AI assistant."
            }
            p += "<|im_start|>system\n" + sys + "\n<|im_end|>\n"
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .alpaca:
            var instr = last.0
            if !systemText.isEmpty { instr = systemText + "\n" + instr }
            if !toolResults.isEmpty {
                for t in toolResults { instr += "\n\nTool Result:\n" + t }
            }
            let p = "### Instruction:\n" + instr + "\n\n### Response:\n"
            return (p, ["### Instruction:"], maxTokens)
        case .vicuna:
            var p = ""
            for (u,a) in pairs {
                p += "USER: " + u + "\nASSISTANT: " + (a ?? "") + "\n"
            }
            let lastUser = !systemText.isEmpty ? systemText + "\n" + last.0 : last.0
            p += "USER: " + lastUser + "\n"
            if !toolResults.isEmpty {
                for t in toolResults { p += "USER: Tool Result:\n" + t + "\n" }
            }
            p += "ASSISTANT: "
            return (p, ["USER:"], maxTokens)
        case .none:
            // Generic fallback using simple role tags.
            var p = ""
            if !systemText.isEmpty {
                p += "System:\n" + systemText + "\n"
            }
            for (u,a) in pairs {
                p += "User:\n" + u + "\n"
                if let a { p += "Assistant:\n" + a + "\n" }
            }
            p += "User:\n" + last.0 + "\n"
            if !toolResults.isEmpty {
                for t in toolResults { p += "User:\nTool Result:\n" + t + "\n" }
            }
            p += "Assistant:\n"
            return (p, ["User:"], maxTokens)
        }
    }
    #endif

    #if os(iOS) || os(visionOS) || os(macOS)
    /// Builds from explicit message turns. If a system message is present, it will be serialized
    /// according to the detected template; otherwise treated as a no-system template.
    static func build(template: String?, family: ModelKind, messages: [ChatVM.Msg]) -> (String, [String], Int?) {
        let tmpl = detect(template: template, family: family)
        let maxTokens: Int? = nil

        var msgs = messages
        if msgs.last?.streaming == true { msgs.removeLast() }
        // Drop trailing empty assistant placeholder if present
        if let last = msgs.last, last.role.lowercased() == "assistant" && last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            msgs.removeLast()
        }

        // Extract the first system message if present
        var systemText: String = msgs.first(where: { $0.role.lowercased() == "system" })?.text ?? ""
        // Remove system messages from the chat sequence for turn pairing
        msgs.removeAll(where: { $0.role.lowercased() == "system" })

        // Gather tool results for reinjection
        let toolResults: [String] = msgs.filter { $0.role.lowercased() == "tool" }.map { $0.text }

        // Pair user/assistant turns in order
        var pairs: [(String, String?)] = []
        var currentUser: String?
        for m in msgs {
            let lower = m.role.lowercased()
            if m.role == "🧑‍💻" || lower == "user" {
                if let u = currentUser { pairs.append((u, nil)) }
                currentUser = m.text
            } else if m.role == "🤖" || lower == "assistant" {
                if let u = currentUser { pairs.append((u, m.text)); currentUser = nil }
            }
        }
        if let u = currentUser { pairs.append((u, nil)) }
        guard let last = pairs.popLast() else { return ("", [], maxTokens) }

        // Some DeepSeek-distill templates (e.g., llama.cpp conversions) expect an assistant tag
        // right before think blocks; detect that form from the template string when available.
        let tmplIsDeepseekLlama: Bool = {
            let t = (template ?? "").lowercased()
            return t.contains("<｜assistant｜><think>")
        }()

        switch tmpl {
        case .gemmaTurn:
            var p = "<bos>"
            if !systemText.isEmpty { p += "<start_of_turn>system\n" + systemText + "<end_of_turn>\n" }
            for (u,a) in pairs {
                p += "<start_of_turn>user\n" + u + "<end_of_turn>\n"
                if let a { p += "<start_of_turn>model\n" + a + "<end_of_turn>\n" }
            }
            p += "<start_of_turn>user\n" + last.0
            if !toolResults.isEmpty {
                for t in toolResults { p += "\nTool Result:\n" + t + "\n" }
            }
            p += "<end_of_turn>\n<start_of_turn>model\n"
            return (p, ["<end_of_turn>", "<start_of_turn>user"], maxTokens)
        case .chatml:
            var p = ""
            // SmolLM: insert default system when none provided.
            if family == .smol && systemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                systemText = "You are a helpful AI assistant named SmolLM, trained by Hugging Face"
            }
            if !systemText.isEmpty { p += "<|im_start|>system\n" + systemText + "\n<|im_end|>\n" }
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .qwen35:
            var p = ""
            if !systemText.isEmpty { p += "<|im_start|>system\n" + systemText + "\n<|im_end|>\n" }
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n<think>\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .chatmlWithStartOfText:
            var p = "<|startoftext|>"
            let defaultLiquidSystem = "You are a helpful assistant trained by ExecuTorch."
            let sys = systemText.isEmpty ? defaultLiquidSystem : systemText
            p += "<|im_start|>system\n" + sys + "\n<|im_end|>\n"
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .llama3:
            var p = "<|begin_of_text|>"
            if !systemText.isEmpty { p += "<|start_header_id|>system<|end_header_id|>\n" + systemText + "<|eot_id|>" }
            for (u,a) in pairs {
                p += "<|start_header_id|>user<|end_header_id|>\n" + u + "<|eot_id|>"
                if let a { p += "<|start_header_id|>assistant<|end_header_id|>\n" + a + "<|eot_id|>" }
            }
            p += "<|start_header_id|>user<|end_header_id|>\n" + last.0 + "<|eot_id|>"
            if !toolResults.isEmpty {
                for t in toolResults {
                    p += "<|start_header_id|>user<|end_header_id|>\nTool Result:\n" + t + "\n<|eot_id|>"
                }
            }
            p += "<|start_header_id|>assistant<|end_header_id|>\n"
            return (p, ["<|eot_id|>", "<|end_of_text|>"], maxTokens)
        case .inst:
            var p = "<s>[INST] "
            if !systemText.isEmpty { p += "<<SYS>>\n" + systemText + "\n<</SYS>>\n\n" }
            for (u,a) in pairs {
                p += u + " [/INST] " + (a ?? "") + "</s><s>[INST] "
            }
            var finalUser = last.0
            if !toolResults.isEmpty {
                for t in toolResults { finalUser += "\nTool Result:\n" + t + "\n" }
            }
            p += finalUser + " [/INST]"
            return (p, ["</s>"], maxTokens)
        case .phi:
            var p = ""
            if !systemText.isEmpty { p += "<|system|>\n" + systemText + "\n" }
            for (u,a) in pairs {
                p += "<|user|>\n" + u + "\n<|assistant|>\n" + (a ?? "")
            }
            p += "<|user|>\n" + last.0 + "\n"
            if !toolResults.isEmpty {
                for t in toolResults { p += "<|user|>\nTool Result:\n" + t + "\n" }
            }
            p += "<|assistant|>\n"
            return (p, ["<|end|>", "<|user|>", "<|system|>", "<|endoftext|>"], maxTokens)
        case .internlm:
            var p = ""
            var systemText = systemText // shadow to allow mutation
            if systemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                systemText = "You are InternLM, a helpful assistant. Think step by step when needed."
            }
            p += "<|im_start|>system\n" + systemText + "\n<|im_end|>\n"
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .deepseek:
            let markers = loadDeepSeekMarkers()
            let bos = markers?.bos ?? "<｜begin▁of▁sentence｜>"
            let userTag = markers?.user ?? "<｜User｜>"
            let assistantTag = markers?.assistant ?? "<｜Assistant｜>"
            let eosTag = markers?.eos ?? "<｜end▁of▁sentence｜>"
            var p = bos
            let sys = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sys.isEmpty { p += sys }
            var insideToolOutputs = false
            var firstOutput = true
            func closeOutputsIfOpen() { if insideToolOutputs { p += "<｜tool▁outputs▁end｜>"; insideToolOutputs = false; firstOutput = true } }
            // Emit turns in the style of DeepSeek-distill-on-Qwen template:
            // user -> "<｜User｜>user_text<｜Assistant｜>"
            // assistant -> "assistant_text<｜end▁of▁sentence｜>"
            // tool   -> grouped within <｜tool▁outputs▁begin｜> ... <｜tool▁outputs▁end｜>
            for m in msgs {
                let role = m.role.lowercased()
                if role == "user" || role == "🧑‍💻".lowercased() {
                    closeOutputsIfOpen()
                    if tmplIsDeepseekLlama {
                        p += userTag + m.text
                    } else {
                        p += userTag + m.text + assistantTag
                    }
                } else if role == "assistant" || role == "🤖".lowercased() {
                    closeOutputsIfOpen()
                    if tmplIsDeepseekLlama {
                        p += assistantTag + m.text + eosTag
                    } else {
                        p += m.text + eosTag
                    }
                } else if role == "tool" {
                    let c = m.text
                    if !insideToolOutputs { p += "<｜tool▁outputs▁begin｜>"; insideToolOutputs = true; firstOutput = true }
                    if firstOutput {
                        p += "<｜tool▁output▁begin｜>" + c + "<｜tool▁output▁end｜>"
                        firstOutput = false
                    } else {
                        p += "\n<｜tool▁output▁begin｜>" + c + "<｜tool▁output▁end｜>"
                    }
                }
            }
            if insideToolOutputs { p += "<｜tool▁outputs▁end｜>" }
            // If the last message was a user, open a think block immediately after the assistant tag
            if let last = msgs.last, ["user", "🧑‍💻".lowercased()].contains(last.role.lowercased()) {
                if tmplIsDeepseekLlama {
                    p += assistantTag + "<think>\n"
                } else {
                    p += "<think>\n"
                }
            }
            var stopList = [userTag, "<|User|>", "</s>", "<eos>", "</eos>"]
            if let eos = markers?.eos { stopList.append(eos) }
            return (p, stopList, maxTokens)
        case .yi:
            var p = "<|startoftext|>"
            var sys = systemText
            if sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sys = "You are Yi, a helpful and harmless AI assistant."
            }
            p += "<|im_start|>system\n" + sys + "\n<|im_end|>\n"
            for m in msgs {
                let role = m.role.lowercased()
                if role == "🧑‍💻".lowercased() || role == "user" {
                    p += "<|im_start|>user\n" + m.text + "\n<|im_end|>\n"
                } else if role == "🤖".lowercased() || role == "assistant" {
                    p += "<|im_start|>assistant\n" + m.text + "\n<|im_end|>\n"
                } else if role == "tool" {
                    p += "<|im_start|>user\n<tool_response>\n" + m.text + "\n</tool_response><|im_end|>\n"
                }
            }
            p += "<|im_start|>assistant\n"
            return (p, ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"], maxTokens)
        case .alpaca:
            var instr = last.0
            if !systemText.isEmpty { instr = systemText + "\n" + instr }
            if !toolResults.isEmpty {
                for t in toolResults { instr += "\n\nTool Result:\n" + t }
            }
            let p = "### Instruction:\n" + instr + "\n\n### Response:\n"
            return (p, ["### Instruction:"], maxTokens)
        case .vicuna:
            var p = ""
            for (u,a) in pairs {
                p += "USER: " + u + "\nASSISTANT: " + (a ?? "") + "\n"
            }
            let lastUser = !systemText.isEmpty ? systemText + "\n" + last.0 : last.0
            p += "USER: " + lastUser + "\n"
            if !toolResults.isEmpty {
                for t in toolResults { p += "USER: Tool Result:\n" + t + "\n" }
            }
            p += "ASSISTANT: "
            return (p, ["USER:"], maxTokens)
        case .none:
            var p = ""
            if !systemText.isEmpty { p += "System:\n" + systemText + "\n" }
            for (u,a) in pairs {
                p += "User:\n" + u + "\n"
                if let a { p += "Assistant:\n" + a + "\n" }
            }
            p += "User:\n" + last.0 + "\n"
            if !toolResults.isEmpty {
                for t in toolResults { p += "User:\nTool Result:\n" + t + "\n" }
            }
            p += "Assistant:\n"
            return (p, ["User:"], maxTokens)
        }
    }
    #endif
}
