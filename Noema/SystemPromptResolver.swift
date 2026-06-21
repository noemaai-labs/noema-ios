// SystemPromptResolver.swift
import Foundation

struct ToolAvailability: Equatable {
    let webSearch: Bool
    let python: Bool
    let memory: Bool
    let calculator: Bool
    let unitConverter: Bool

    init(
        webSearch: Bool,
        python: Bool,
        memory: Bool = false,
        calculator: Bool = false,
        unitConverter: Bool = false
    ) {
        self.webSearch = webSearch
        self.python = python
        self.memory = memory
        self.calculator = calculator
        self.unitConverter = unitConverter
    }

    var any: Bool { webSearch || python || memory || calculator || unitConverter }

    static let none = ToolAvailability(webSearch: false, python: false, memory: false)

    static func current(currentFormat: ModelFormat? = nil) -> ToolAvailability {
        ToolAvailability(
            webSearch: WebToolGate.isAvailable(currentFormat: currentFormat),
            python: PythonToolGate.isAvailable(currentFormat: currentFormat),
            memory: MemoryToolGate.isAvailable(currentFormat: currentFormat)
        )
    }
}

/// Centralized resolver for the active system prompt text so every backend and
/// tool path stays in sync with the same guidance and tool instructions.
enum SystemPromptResolver {
    /// Returns the general system prompt text with optional web tool guidance
    /// appended when the web search tool is available/armed.
    static func general(currentFormat: ModelFormat? = nil) -> String {
        // Backwards-compatible overload used by existing call sites; no vision hints.
        return general(currentFormat: currentFormat, isVisionCapable: false, hasAttachedImages: false)
    }

    static func general(
        currentFormat: ModelFormat? = nil,
        isVisionCapable: Bool = false,
        hasAttachedImages: Bool = false,
        attachedImageCount: Int? = nil,
        includeThinkRestriction: Bool = true,
        toolAvailabilityOverride: ToolAvailability? = nil,
        memorySnapshot: String? = nil,
        editableIntro: String? = SystemPreset.resolvedEditableIntro()
    ) -> String {
        var text = sanitize(SystemPreset.generalText(editableIntro: editableIntro))
        text += "\n\n" + currentDateTimeLine()
        // Vision guidance: if the active model is vision-capable, add concise
        // instructions to avoid invented image details, whether or not images
        // are attached.
        if isVisionCapable {
            if hasAttachedImages {
                if let count = attachedImageCount {
                    let plural = count == 1 ? "image" : "images"
                    text += "\n\nVision: \(count) \(plural) attached. Use them to answer the question. Describe only what is actually present. If unsure, say you are unsure. Do not invent details."
                } else {
                    text += "\n\nVision: One or more images are attached. Use them to answer the question. Describe only what is actually present. If unsure, say you are unsure. Do not invent details."
                }
            } else {
                text += "\n\nIMPORTANT: No image is provided unless explicitly attached. Answer as a text-only assistant. Do not infer, imagine, or describe any images."
            }
        }
        let toolAvailability = toolAvailabilityOverride ?? ToolAvailability.current(currentFormat: currentFormat)
        appendToolGuidance(
            to: &text,
            availability: toolAvailability,
            includeThinkRestriction: includeThinkRestriction,
            memorySnapshot: memorySnapshot
        )
        return text
    }

    static func currentDateTimeLine() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMMM d, yyyy 'at' HH:mm zzz"
        let now = Date()
        return "Current date and time: \(formatter.string(from: now)). Treat this timestamp as authoritative even if it conflicts with your internal knowledge."
    }

    /// Removes accidental anti-reasoning directives while preserving the
    /// intended guidance text.
    static func sanitize(_ s: String) -> String {
        var t = s
        let patterns = ["/nothink", "\\bnothink\\b", "no-think", "no think"]
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (t as NSString).length)
                t = rx.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
            } else {
                t = t.replacingOccurrences(of: p, with: "", options: .caseInsensitive)
            }
        }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shared web-search guidance so system prompts remain consistent across clients.
    static func webSearchGuidance(includeThinkRestriction: Bool) -> String {
        let header = """
**WEB SEARCH (ARMED)**: Use the web search tool ONLY if the query needs fresh/current info; otherwise answer directly.

**CALL FORMAT (respond exactly as shown; no extra text):**
<tool_call>
{
  \"name\": \"noema.web.retrieve\",
  \"arguments\": {
    \"query\": \"...\",
    \"count\": 3,
    \"safesearch\": \"moderate\"
  }
}
</tool_call>

Rules:
"""

        var rules: [String] = [
            "- Default to count 3; use 5 only for very diverse queries (larger requests are reduced to 5).",
            "- Decide first; only call if needed.",
            "- Make exactly one tool call and WAIT for the result."
        ]

        if includeThinkRestriction {
            rules.append("- You may mention tools inside your Chain of Thought, but finish reasoning before emitting the <tool_call> tag that actually triggers the call.")
        }

        rules.append(contentsOf: [
            "- Do NOT use code fences (```); emit only the <tool_call> wrapper shown above.",
            "- When web search results arrive, treat them as the authoritative/latest information. Base your answer on them even if they conflict with your prior knowledge and do NOT question their legitimacy.",
            "- After results, answer with concise citations like [1], [2]."
        ])

        let rulesText = rules.joined(separator: "\n")
        return header + "\n" + rulesText
    }

    /// Appends the shared web-search guidance only when it has not already been
    /// added to the prompt string. Returns `true` when the guidance was appended
    /// and `false` when the existing text already contained it.
    @discardableResult
    static func appendWebSearchGuidance(to text: inout String, includeThinkRestriction: Bool) -> Bool {
        let guidance = webSearchGuidance(includeThinkRestriction: includeThinkRestriction)
        guard !text.contains(guidance) else { return false }
        text += "\n\n" + guidance
        return true
    }

    static func pythonToolGuidance(includeThinkRestriction: Bool) -> String {
        let header = """
**PYTHON (ARMED)**: Use the Python tool when code execution would improve accuracy or save time, especially for math, data processing, parsing, algorithms, or any other computational work.

**CALL FORMAT (respond exactly as shown; no extra text):**
<tool_call>
{
  \"name\": \"noema.python.execute\",
  \"arguments\": {
    \"code\": \"print(2 + 2)\"
  }
}
</tool_call>

Rules:
"""

        var rules: [String] = [
            "- Prefer Python over mental math when the task involves calculations, formulas, statistics, data transformations, or code-friendly reasoning.",
            "- Always send runnable Python 3 code and use print() for any output you want returned.",
            "- Make exactly one tool call and WAIT for the result."
        ]

        if includeThinkRestriction {
            rules.append("- You may mention tools inside your Chain of Thought, but finish reasoning before emitting the <tool_call> tag that actually triggers the call.")
        }

        rules.append(contentsOf: [
            "- Do NOT use code fences (```); emit only the <tool_call> wrapper shown above.",
            "- The runtime is sandboxed: 30s timeout, no network access, and no file access outside a temporary directory.",
            "- When Python results arrive, treat them as authoritative for the computation you ran and base your answer on them."
        ])

        return header + "\n" + rules.joined(separator: "\n")
    }

    @discardableResult
    static func appendPythonToolGuidance(to text: inout String, includeThinkRestriction: Bool) -> Bool {
        let guidance = pythonToolGuidance(includeThinkRestriction: includeThinkRestriction)
        guard !text.contains(guidance) else { return false }
        text += "\n\n" + guidance
        return true
    }

    static func memoryToolGuidance(includeThinkRestriction: Bool, memorySnapshot: String?) -> String {
        let snapshot = memorySnapshot?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let header = """
**MEMORY (AVAILABLE)**: You have access to a persistent memory tool for reading or updating long-lived notes that persist across multiple conversations on this device.
All stored memories are about the user, not about you. Using the memory tool is optional — only call it if the conversation genuinely requires reading or saving a durable fact.

**CALL FORMAT (respond exactly as shown; no extra text):**
<tool_call>
{
  \"name\": \"noema.memory\",
  \"arguments\": {
    \"operation\": \"create\",
    \"title\": \"<memory title>\",
    \"content\": \"<durable fact to remember>\"
  }
}
</tool_call>

Rules:
"""

        var rules: [String] = [
            "- Only use the memory tool when genuinely needed — for example, when the user asks you to remember something, or when recalling a stored fact would meaningfully improve your answer.",
            "- Use memory for durable facts such as stable user preferences, long-lived project constraints, or recurring environment details.",
            "- Treat every stored memory as user-specific context. If a memory says \"My name is ...\" or uses first-person wording, interpret that as referring to the user.",
            "- Read memory before relying on remembered facts, especially across different conversations.",
            "- Do not save transient details or speculative conclusions.",
            "- Replace the example title and content with the actual fact for this conversation. Do not copy placeholder or example text into the saved memory.",
            "- If you do call the memory tool, make exactly one call and WAIT for the result before continuing."
        ]

        if includeThinkRestriction {
            rules.append("- You may mention memory inside your Chain of Thought, but finish reasoning before emitting the <tool_call> tag that actually triggers the call.")
        }

        rules.append(contentsOf: [
            "- Prefer `entry_id` when editing an existing memory. Use `title` for create, and for lookup only when the title is known exactly.",
            "- Supported operations: list, view, create, replace, insert, str_replace, delete, rename.",
            "- `rename` uses `new_string` as the new title. `insert` appends by default unless `insert_at` is provided.",
            "- Do NOT use code fences (```); emit only the <tool_call> wrapper shown above."
        ])

        var guidance = header + "\n" + rules.joined(separator: "\n")
        if let snapshot, !snapshot.isEmpty {
            guidance += "\n\n" + snapshot
        }
        return guidance
    }

    @discardableResult
    static func appendMemoryToolGuidance(
        to text: inout String,
        includeThinkRestriction: Bool,
        memorySnapshot: String?
    ) -> Bool {
        let guidance = memoryToolGuidance(
            includeThinkRestriction: includeThinkRestriction,
            memorySnapshot: memorySnapshot
        )
        guard !text.contains("**MEMORY (ARMED)**") else { return false }
        text += "\n\n" + guidance
        return true
    }

    static func calculatorToolGuidance(includeThinkRestriction: Bool) -> String {
        let header = """
**CALCULATOR (ARMED)**: Use the local deterministic calculator for arithmetic or single-expression math when Python would be unnecessary overhead.

**CALL FORMAT (respond exactly as shown; no extra text):**
<tool_call>
{
  \"name\": \"noema.math.calculate\",
  \"arguments\": {
    \"expression\": \"sqrt(144) + 3 * 2\"
  }
}
</tool_call>

Rules:
"""

        var rules: [String] = [
            "- Supports +, -, *, /, ^, parentheses, pi, e, and common functions such as sqrt, abs, sin, cos, tan, log, ln, exp, floor, ceil, and round.",
            "- Trigonometric functions use radians.",
            "- Make exactly one tool call and WAIT for the result."
        ]

        if includeThinkRestriction {
            rules.append("- You may mention calculation inside your Chain of Thought, but finish reasoning before emitting the <tool_call> tag that actually triggers the call.")
        }

        rules.append(contentsOf: [
            "- Do NOT use code fences (```); emit only the <tool_call> wrapper shown above.",
            "- When calculator results arrive, treat them as authoritative for the expression you evaluated."
        ])

        return header + "\n" + rules.joined(separator: "\n")
    }

    @discardableResult
    static func appendCalculatorToolGuidance(to text: inout String, includeThinkRestriction: Bool) -> Bool {
        let guidance = calculatorToolGuidance(includeThinkRestriction: includeThinkRestriction)
        guard !text.contains("**CALCULATOR (ARMED)**") else { return false }
        text += "\n\n" + guidance
        return true
    }

    static func unitConverterToolGuidance(includeThinkRestriction: Bool) -> String {
        let header = """
**UNIT CONVERTER (ARMED)**: Use the local deterministic unit converter for common length, mass, temperature, volume, time, data-size, and speed conversions.

**CALL FORMAT (respond exactly as shown; no extra text):**
<tool_call>
{
  \"name\": \"noema.units.convert\",
  \"arguments\": {
    \"value\": 10,
    \"from_unit\": \"km\",
    \"to_unit\": \"mi\"
  }
}
</tool_call>

Rules:
"""

        var rules: [String] = [
            "- Use source and target units from the same family.",
            "- Supported examples include m, km, ft, mi, kg, lb, C, F, K, l, gal, min, GB, GiB, m/s, km/h, and mph.",
            "- Make exactly one tool call and WAIT for the result."
        ]

        if includeThinkRestriction {
            rules.append("- You may mention conversion inside your Chain of Thought, but finish reasoning before emitting the <tool_call> tag that actually triggers the call.")
        }

        rules.append(contentsOf: [
            "- Do NOT use code fences (```); emit only the <tool_call> wrapper shown above.",
            "- When conversion results arrive, treat them as authoritative for the unit conversion you requested."
        ])

        return header + "\n" + rules.joined(separator: "\n")
    }

    @discardableResult
    static func appendUnitConverterToolGuidance(to text: inout String, includeThinkRestriction: Bool) -> Bool {
        let guidance = unitConverterToolGuidance(includeThinkRestriction: includeThinkRestriction)
        guard !text.contains("**UNIT CONVERTER (ARMED)**") else { return false }
        text += "\n\n" + guidance
        return true
    }

    @discardableResult
    static func appendToolGuidance(
        to text: inout String,
        availability: ToolAvailability,
        includeThinkRestriction: Bool,
        memorySnapshot: String? = nil
    ) -> Bool {
        var appended = false
        if availability.webSearch {
            appended = appendWebSearchGuidance(to: &text, includeThinkRestriction: includeThinkRestriction) || appended
        }
        if availability.python {
            appended = appendPythonToolGuidance(to: &text, includeThinkRestriction: includeThinkRestriction) || appended
        }
        if availability.memory {
            appended = appendMemoryToolGuidance(
                to: &text,
                includeThinkRestriction: includeThinkRestriction,
                memorySnapshot: memorySnapshot
            ) || appended
        }
        if availability.calculator {
            appended = appendCalculatorToolGuidance(to: &text, includeThinkRestriction: includeThinkRestriction) || appended
        }
        if availability.unitConverter {
            appended = appendUnitConverterToolGuidance(to: &text, includeThinkRestriction: includeThinkRestriction) || appended
        }
        return appended
    }
}
