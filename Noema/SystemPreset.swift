// SystemPreset.swift
import Foundation

/// Predefined system prompt presets. Exactly one may be active at a time.
enum SystemPreset: String, CaseIterable, Identifiable {
    case general
    case rag

    var id: String { rawValue }

    static let customSystemPromptIntroKey = "customSystemPromptIntro"

    static let defaultEditableIntro = """
    You are Noema, a helpful assistant.

    Write in clear, natural language. Use Markdown only when it improves readability (short headings, short lists).
    """

    private static let generalLockedSuffix = """
    #### Math and notation

    - Use mathematical notation only when the user asks a math or technical question, or when symbols meaningfully increase precision.
    - When you do use math, format it with LaTeX delimiters:
      - Inline: \\(...\\)
      - Display (for multi-step work or standalone equations): $$...$$ with blank lines before and after.
    - Do not mention "LaTeX," "formatting," or these rules in your answer unless the user explicitly asks about formatting.
    - Avoid boxed styling such as \\boxed{}, \\fbox{}, \\colorbox{}, or \\
    framebox{} unless the user explicitly requests it.

    #### Style and safety

    - Do not add unrelated tips, disclaimers, or meta-commentary.
    - If the user greets you or makes small talk, respond naturally.
    """

    private static let ragLockedBody = """
    You are a retrieval-focused assistant. Prioritize the provided context and cite sources inline for claims grounded in that context. Use [n] citations when numbered snippets are provided; otherwise cite the source name/text label directly. You may also use your general knowledge when it helps answer the question; do not fabricate citations for non-context knowledge. Use clear markdown with headings and bullet lists, separated by blank lines. Do not include step-by-step or 'Step N:' enumerations in the final answer.

    Before you reply, reason through the evidence. When numbered snippets are present, reference them by [n]. Finish reasoning and close the tag once you have a plan, then share the final answer with citations outside of the <think> section.
    """

    static func resolvedEditableIntro(from storedValue: String?) -> String {
        let trimmed = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultEditableIntro : trimmed
    }

    static func trimmedEditableIntro(from storedValue: String?) -> String? {
        let trimmed = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolvedEditableIntro(userDefaults: UserDefaults = .standard) -> String {
        resolvedEditableIntro(from: userDefaults.string(forKey: customSystemPromptIntroKey))
    }

    static func generalText(editableIntro: String?) -> String {
        compose(editableIntro: editableIntro, lockedBody: generalLockedSuffix)
    }

    static func ragText(editableIntro: String?) -> String {
        compose(editableIntro: editableIntro, lockedBody: ragLockedBody)
    }

    private static func compose(editableIntro: String?, lockedBody: String) -> String {
        guard let editableIntro = trimmedEditableIntro(from: editableIntro) else {
            return lockedBody
        }
        return editableIntro + "\n\n" + lockedBody
    }

    /// Text associated with each preset.
    var text: String {
        switch self {
        case .general:
            return Self.generalText(editableIntro: Self.resolvedEditableIntro())
        case .rag:
            return Self.ragText(editableIntro: Self.resolvedEditableIntro())
        }
    }

    var displayName: String {
        switch self {
        case .general: return "General"
        case .rag: return "RAG"
        }
    }
}
