import Foundation

enum FlashcardResponseParser {
    struct DraftCard: Equatable, Sendable {
        var front: String
        var back: String
        var hint: String?
    }

    static let maxFrontLength = 300
    static let maxBackLength = 2000

    static func parse(_ raw: String) -> [DraftCard] {
        let cleaned = stripFences(stripThinkBlocks(raw))
        var drafts: [DraftCard] = []

        if let fastPath = decodeFastPath(cleaned) {
            drafts = fastPath
        } else {
            drafts = salvageCards(from: cleaned)
        }

        return dedupe(drafts.compactMap(validated))
    }

    // MARK: Think / fence stripping

    static func stripThinkBlocks(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>", options: .caseInsensitive) {
            if let close = result.range(of: "</think>", options: .caseInsensitive, range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Unclosed think block: the answer never started.
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
        }
        // Implicit-open reasoning (template pre-opens <think>, so only the
        // closing tag appears): everything up to the LAST close is reasoning.
        if let lastClose = result.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            result.removeSubrange(result.startIndex..<lastClose.upperBound)
        }
        return result
    }

    static func stripFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<tool_call>", "</tool_call>"] {
            result = result.replacingOccurrences(of: tag, with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let newline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newline)...])
            } else {
                result = ""
            }
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Fast path

    private struct CardsEnvelope: Decodable {
        let cards: [LenientCard]
    }

    private struct LenientCard: Decodable {
        let front: String?
        let back: String?
        let hint: String?
        let question: String?
        let answer: String?

        var draft: DraftCard? {
            guard let front = front ?? question, let back = back ?? answer else { return nil }
            return DraftCard(front: front, back: back, hint: hint)
        }
    }

    private static func decodeFastPath(_ text: String) -> [DraftCard]? {
        let data = Data(text.utf8)
        if let envelope = try? JSONDecoder().decode(CardsEnvelope.self, from: data) {
            return envelope.cards.compactMap(\.draft)
        }
        if let array = try? JSONDecoder().decode([LenientCard].self, from: data) {
            return array.compactMap(\.draft)
        }
        return nil
    }

    // MARK: Salvage

    private static func salvageCards(from text: String) -> [DraftCard] {
        let chars = Array(text)
        var start = 0
        if let cardsKey = text.range(of: "\"cards\"") {
            let offset = text.distance(from: text.startIndex, to: cardsKey.upperBound)
            if let bracket = firstIndex(of: "[", in: chars, from: offset) {
                start = bracket + 1
            }
        } else if let bracket = firstIndex(of: "[", in: chars, from: 0) {
            start = bracket + 1
        }
        // No array found: fall through scanning the whole text as a stream of
        // bare {...} objects (some models emit objects without the envelope).

        var drafts: [DraftCard] = []
        var index = start
        while let objectStart = firstIndex(of: "{", in: chars, from: index) {
            guard let objectEnd = matchingBraceEnd(in: chars, from: objectStart) else {
                break // truncated tail — everything complete is already salvaged
            }
            let slice = String(chars[objectStart...objectEnd])
            if let card = try? JSONDecoder().decode(LenientCard.self, from: Data(slice.utf8)),
               let draft = card.draft {
                drafts.append(draft)
            }
            index = objectEnd + 1
        }
        return drafts
    }

    private static func firstIndex(of char: Character, in chars: [Character], from start: Int) -> Int? {
        var i = max(0, start)
        while i < chars.count {
            if chars[i] == char { return i }
            i += 1
        }
        return nil
    }

    /// String-aware balanced-brace scan: returns the index of the `}` matching
    /// the `{` at `start`, or nil if the object is truncated.
    static func matchingBraceEnd(in chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: Validation / dedupe

    private static func validated(_ draft: DraftCard) -> DraftCard? {
        let front = clamp(draft.front.trimmingCharacters(in: .whitespacesAndNewlines), to: maxFrontLength)
        let back = clamp(draft.back.trimmingCharacters(in: .whitespacesAndNewlines), to: maxBackLength)
        guard !front.isEmpty, !back.isEmpty else { return nil }
        let hint = draft.hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DraftCard(front: front, back: back, hint: (hint?.isEmpty ?? true) ? nil : hint)
    }

    private static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    static func normalizedFront(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        let collapsed = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var trimmed = collapsed
        while let last = trimmed.last, "?.!:;,".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func dedupe(_ drafts: [DraftCard]) -> [DraftCard] {
        var seen = Set<String>()
        var unique: [DraftCard] = []
        for draft in drafts {
            let key = normalizedFront(draft.front)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(draft)
        }
        return unique
    }
}

/// Incremental card counter fed each streamed chunk; drives generation
/// progress. Exact for any well-formed prefix; on garbage it just stops
/// counting (the char-based fraction still moves).
struct FlashcardStreamCardCounter {
    private(set) var cardsCompleted = 0

    private var buffer: [Character] = []
    private var processed = 0
    private var inThink = false
    private var armed = false
    private var finishedArray = false
    private var objectDepth = 0
    private var inString = false
    private var escaped = false

    // Long enough to hold a split "</think>" across chunk boundaries.
    private static let tagHoldback = 8

    mutating func feed(_ chunk: String) {
        buffer.append(contentsOf: chunk)
        process(upTo: max(0, buffer.count - Self.tagHoldback))
    }

    mutating func finalize() {
        process(upTo: buffer.count)
    }

    private mutating func process(upTo limit: Int) {
        while processed < limit {
            if inThink {
                if matchesTag("</think>", at: processed) {
                    inThink = false
                    processed += 8
                    continue
                }
                processed += 1
                continue
            }
            let c = buffer[processed]
            if !inString {
                if c == "<" {
                    if matchesTag("<think>", at: processed) {
                        inThink = true
                        processed += 7
                        continue
                    }
                    if matchesTag("</think>", at: processed) {
                        // Implicit-open reasoning: everything so far was
                        // preamble — restart counting from scratch.
                        resetScanState()
                        processed += 8
                        continue
                    }
                }
            }
            defer { processed += 1 }
            guard !finishedArray else { continue }
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            switch c {
            case "\"":
                if armed || objectDepth > 0 { inString = true }
            case "[":
                if !armed { armed = true }
            case "{":
                if armed { objectDepth += 1 }
            case "}":
                if armed, objectDepth > 0 {
                    objectDepth -= 1
                    if objectDepth == 0 { cardsCompleted += 1 }
                }
            case "]":
                if armed, objectDepth == 0 { finishedArray = true }
            default:
                break
            }
        }
    }

    private mutating func resetScanState() {
        cardsCompleted = 0
        armed = false
        finishedArray = false
        objectDepth = 0
        inString = false
        escaped = false
    }

    private func matchesTag(_ tag: String, at index: Int) -> Bool {
        let tagChars = Array(tag)
        guard index + tagChars.count <= buffer.count else { return false }
        for (offset, expected) in tagChars.enumerated() {
            let actual = buffer[index + offset]
            if Character(String(actual).lowercased()) != expected { return false }
        }
        return true
    }
}
