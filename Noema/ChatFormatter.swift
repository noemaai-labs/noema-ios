import Foundation

/// Chat formatting layer that prepares inputs for generation while honoring
/// runtime system prompts and model-specific chat templates.
final class ChatFormatter: @unchecked Sendable {
    struct Message: Sendable {
        let role: String
        let content: String
        init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    enum RenderedPrompt: Sendable {
        case messages([Message])
        case plain(String)
    }

    enum Capability: Sendable {
        case supportsSystemRole
        case inlineSystemInFirstUser
        case noTemplate
    }

    static let shared = ChatFormatter()

    /// In-memory capability cache keyed by model identifier
    private var capabilityCache: [String: Capability] = [:]
    private let capabilityCacheLock = NSLock()

    func prepareForGeneration(
        modelId: String,
        template rawTemplate: String?,
        family: ModelKind,
        messages inputMessages: [Message],
        system: String,
        forceInlineWhenTemplatePresent: Bool = false
    ) -> RenderedPrompt {
        let systemText = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = normalizeTemplate(rawTemplate)

        // Resolve capability (based on explicit template tokens when present,
        // otherwise fall back to family heuristics). Cache per-model for speed.
        let capability: Capability
        var cachedCapability: Capability?
        capabilityCacheLock.lock()
        cachedCapability = capabilityCache[modelId]
        capabilityCacheLock.unlock()
        if let cached = cachedCapability {
            capability = cached
        } else {
            let detected = detectCapability(template: template, family: family)
            capabilityCacheLock.lock()
            capabilityCache[modelId] = detected
            capabilityCacheLock.unlock()
            capability = detected
        }

        // If there's no system text, select representation based on capability:
        // chat-capable families should keep message form even without an explicit template.
        if systemText.isEmpty {
            switch capability {
            case .supportsSystemRole, .inlineSystemInFirstUser:
                return .messages(inputMessages)
            case .noTemplate:
                return .plain(buildPlainCompletion(messages: inputMessages, system: ""))
            }
        }

        // Do NOT force plain fallback just because template == nil. For chat-capable
        // families (e.g., Qwen, Gemma, Phi, Llama3) we return a messages array so the
        // downstream PromptBuilder can serialize using family defaults (ChatML, etc.).
        if forceInlineWhenTemplatePresent {
            // Conservative fallback path: always inline system into first user
            let transformed = inlineSystemInFirstUser(messages: inputMessages, system: systemText, template: template)
            return .messages(transformed)
        }

        switch capability {
        case .supportsSystemRole:
            let prepared = injectSystemRoleIfNeeded(messages: inputMessages, system: systemText)
            return .messages(prepared)
        case .inlineSystemInFirstUser:
            let transformed = inlineSystemInFirstUser(messages: inputMessages, system: systemText, template: template)
            // Cache for speed next time
            capabilityCacheLock.lock()
            capabilityCache[modelId] = .inlineSystemInFirstUser
            capabilityCacheLock.unlock()
            return .messages(transformed)
        case .noTemplate:
            return .plain(buildPlainCompletion(messages: inputMessages, system: systemText))
        }
    }

    // MARK: - Detection & Normalization

    private func normalizeTemplate(_ t: String?) -> String? {
        guard let s = t?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private func detectCapability(template: String?, family: ModelKind) -> Capability {
        guard let tmpl = template?.lowercased() else {
            // Fall back by family when no explicit template string
            switch family {
            case .llama3, .qwen, .smol, .lfm, .phi, .gemma, .internlm, .deepseek, .yi:
                return .supportsSystemRole
            case .mistral:
                return .inlineSystemInFirstUser
            default:
                return .inlineSystemInFirstUser
            }
        }

        // Explicit system role tokens
        let hasSystemTokens = (
            tmpl.contains("<|start_header_id|>system") ||
            tmpl.contains("<|im_start|>") && tmpl.contains("system") ||
            tmpl.contains("<|system|>") ||
            tmpl.contains("<start_of_turn>system") ||
            tmpl.range(of: #"role\s*==\s*['\"]system['\"]"#, options: .regularExpression) != nil
        )
        if hasSystemTokens { return .supportsSystemRole }

        // Legacy instruction patterns without a formal system role
        if tmpl.contains("[inst]") || tmpl.contains("<<sys>>") || tmpl.contains("[/inst]") {
            return .inlineSystemInFirstUser
        }
        // DeepSeek heuristics: presence of fullwidth markers/BOS or DeepSeek tool tags implies chat formatting
        if tmpl.contains("<｜user｜>") || tmpl.contains("<｜assistant｜>") || tmpl.contains("<｜begin▁of▁sentence｜>") || tmpl.contains("tool▁calls▁begin｜") || tmpl.contains("tool▁outputs▁begin｜") {
            return .supportsSystemRole
        }
        // Heuristic: template branches on user/assistant but not system
        if tmpl.range(of: #"role\s*==\s*['\"](user|assistant)['\"]"#, options: .regularExpression) != nil {
            return .inlineSystemInFirstUser
        }
        // Conservative fallback: defer to family rather than forcing plain/noTemplate
        switch family {
        case .llama3, .qwen, .smol, .lfm, .phi, .gemma, .internlm, .deepseek, .yi:
            return .supportsSystemRole
        case .mistral:
            return .inlineSystemInFirstUser
        default:
            return .inlineSystemInFirstUser
        }
    }

    // MARK: - Transformations

    private func injectSystemRoleIfNeeded(messages: [Message], system: String) -> [Message] {
        guard !system.isEmpty else { return messages }
        var msgs = messages
        if let first = msgs.first, first.role.lowercased() == "system" {
            // Prefer explicit message; if differs, append ours separated by two newlines
            if !first.content.trimmingCharacters(in: .whitespacesAndNewlines).contains(system) {
                let combined = first.content + "\n\n" + system
                msgs[0] = Message(role: "system", content: combined)
            }
            return msgs
        } else {
            // Insert our system as the first turn
            var out = [Message(role: "system", content: system)]
            out.append(contentsOf: msgs)
            return out
        }
    }

    private func inlineSystemInFirstUser(messages: [Message], system: String, template: String?) -> [Message] {
        guard !system.isEmpty else { return messages }
        var msgs = messages
        // If first is system, fold into first user then drop system
        var systemPrefix = system
        if let first = msgs.first, first.role.lowercased() == "system" {
            let explicit = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if explicit.isEmpty {
                systemPrefix = system
            } else if explicit == system {
                systemPrefix = explicit
            } else {
                systemPrefix = explicit + "\n\n" + system
            }
            msgs.removeFirst()
        }
        // Find first user
        if let idx = msgs.firstIndex(where: { $0.role.lowercased() == "user" }) {
            var content = msgs[idx].content
            // For Llama-2 style, prefer <<SYS>> wrapper when template hints at it
            let lower = (template ?? "").lowercased()
            if lower.contains("<<sys>>") || lower.contains("[inst]") {
                if !content.contains("<<SYS>>") {
                    content = "<<SYS>>\n" + systemPrefix + "\n<</SYS>>\n\n" + content
                } else {
                    // Already contains SYS wrapper; keep as-is
                }
            } else {
                content = "System: " + systemPrefix + "\n\n" + content
            }
            msgs[idx] = Message(role: "user", content: content)
        } else {
            // No user turn found; insert one
            msgs.insert(Message(role: "user", content: "System: " + systemPrefix + "\n\n"), at: 0)
        }
        return msgs
    }

    private func buildPlainCompletion(messages: [Message], system: String) -> String {
        var s = ""
        if !system.isEmpty {
            s += "System: " + system + "\n\n"
        }
        // Append conversation in simple role-tagged format
        for m in messages {
            let role = m.role.lowercased()
            switch role {
            case "system":
                // Already captured above; skip to avoid duplication
                continue
            case "user":
                s += "User: " + (m.content) + "\n\n"
            case "assistant":
                s += "Assistant: " + (m.content) + "\n\n"
            case "tool":
                s += "User: Tool Result:\n" + (m.content) + "\n\n"
            default:
                s += m.role + ": " + m.content + "\n\n"
            }
        }
        s += "Assistant: "
        return s
    }
}
