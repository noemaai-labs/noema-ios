import Foundation

/// Converts streamed assistant markdown into plain speakable prose: reasoning
/// blocks vanish, code/math/tables become short spoken placeholders, and
/// markdown syntax is stripped so TTS never reads formatting aloud.
enum SpeechTextSanitizer {
    struct Replacements: Sendable {
        var codeOmitted: String
        var formulaOmitted: String
        var tableOmitted: String

        static let spoken = Replacements(
            codeOmitted: String(localized: "Code omitted."),
            formulaOmitted: String(localized: "Formula omitted."),
            tableOmitted: String(localized: "Table omitted.")
        )
    }

    static func sanitize(_ text: String, replacements: Replacements = .spoken) -> String {
        var result = stripThinkBlocks(from: text)
        result = result.replacingOccurrences(of: noemaToolAnchorToken, with: "")
        result = replaceFencedCode(in: result, with: replacements.codeOmitted)
        result = replaceDelimited(in: result, open: "$$", close: "$$", with: replacements.formulaOmitted)
        result = replaceDelimited(in: result, open: "\\[", close: "\\]", with: replacements.formulaOmitted)
        result = replaceInlineMath(in: result, with: replacements.formulaOmitted)
        result = replaceTables(in: result, with: replacements.tableOmitted)
        result = stripInlineMarkdown(from: result)
        return collapseWhitespace(in: result)
    }

    private static func stripThinkBlocks(from text: String) -> String {
        var rest = Substring(text)
        // A close tag with no opener means the model streamed reasoning from the
        // very first token; everything before the tag is thought, not answer.
        if let firstClose = rest.range(of: "</think>"),
           rest[..<firstClose.lowerBound].range(of: "<think>") == nil {
            rest = rest[firstClose.upperBound...]
        }
        var output = ""
        while let start = rest.range(of: "<think>") {
            output += rest[..<start.lowerBound]
            rest = rest[start.upperBound...]
            guard let end = rest.range(of: "</think>") else { return output }
            rest = rest[end.upperBound...]
        }
        output += rest
        return output
    }

    private static func replaceFencedCode(in text: String, with replacement: String) -> String {
        var output: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !inFence { output.append(replacement) }
                inFence.toggle()
                continue
            }
            if !inFence { output.append(line) }
        }
        return output.joined(separator: "\n")
    }

    private static func replaceDelimited(in text: String, open: String, close: String, with replacement: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let start = rest.range(of: open) {
            output += rest[..<start.lowerBound]
            output += replacement
            let afterOpen = rest[start.upperBound...]
            guard let end = afterOpen.range(of: close) else { return output }
            rest = afterOpen[end.upperBound...]
        }
        output += rest
        return output
    }

    private static func replaceInlineMath(in text: String, with replacement: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let start = rest.range(of: "\\(") {
            output += rest[..<start.lowerBound]
            let afterOpen = rest[start.upperBound...]
            guard let end = afterOpen.range(of: "\\)") else {
                output += replacement
                return output
            }
            let inner = String(afterOpen[..<end.lowerBound])
            output += inner.contains("\\") ? replacement : inner
            rest = afterOpen[end.upperBound...]
        }
        output += rest
        return output
    }

    private static func replaceTables(in text: String, with replacement: String) -> String {
        var output: [String] = []
        var inTable = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                if !inTable {
                    inTable = true
                    output.append(replacement)
                }
                continue
            }
            inTable = false
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func stripInlineMarkdown(from text: String) -> String {
        var lines: [String] = []
        for var line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isHorizontalRule(trimmed) { continue }
            line = strippingLinePrefixes(line)
            lines.append(line)
        }
        var result = lines.joined(separator: "\n")

        result = replacingRegex(in: result, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, template: "$1")
        result = replacingRegex(in: result, pattern: #"\[([^\]]+)\]\([^)]*\)"#, template: "$1")
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "~~", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        return result
    }

    private static func strippingLinePrefixes(_ line: String) -> String {
        var s = Substring(line)
        let indent = s.prefix(while: { $0 == " " || $0 == "\t" })
        s = s.dropFirst(indent.count)
        while s.first == ">" {
            s = s.dropFirst()
            if s.first == " " { s = s.dropFirst() }
        }
        if s.first == "#" {
            let hashes = s.prefix(while: { $0 == "#" })
            if hashes.count <= 6, s.dropFirst(hashes.count).first == " " {
                s = s.dropFirst(hashes.count + 1)
            }
        } else if s.hasPrefix("- ") || s.hasPrefix("+ ") {
            s = s.dropFirst(2)
        } else if let match = firstRegexMatch(in: String(s), pattern: #"^\d{1,3}[.)]\s+"#) {
            s = s.dropFirst(match.count)
        }
        return String(s)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for symbol: Character in ["-", "*", "_"] where trimmed.allSatisfy({ $0 == symbol }) {
            return true
        }
        return false
    }

    private static func collapseWhitespace(in text: String) -> String {
        var result = replacingRegex(in: text, pattern: #"[ \t]+"#, template: " ")
        result = replacingRegex(in: result, pattern: #" ?\n ?"#, template: "\n")
        result = replacingRegex(in: result, pattern: #"\n{2,}"#, template: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingRegex(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

/// Splits sanitized prose into sentences that are safe to hand to TTS while the
/// tail of the text is still streaming in.
enum SpeechSentenceChunker {
    private static let terminals: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let cjkTerminals: Set<Character> = ["。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»", "」", "』"]

    /// A boundary is "stable" once at least two non-whitespace characters exist
    /// beyond it, so partially streamed continuations ("$5." before ".99", "…"
    /// mid-ellipsis) never get spoken too early. `isFinal` flushes the tail.
    static func stableSentences(in text: String, isFinal: Bool) -> (sentences: [String], consumedCount: Int) {
        let chars = Array(text)
        var sentences: [String] = []
        var segmentStart = 0
        var consumed = 0
        var i = 0

        while i < chars.count {
            let c = chars[i]
            var boundary: Int? = nil

            if terminals.contains(c) {
                let prevIsDigit = i > 0 && chars[i - 1].isNumber
                let nextIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
                if !(c == "." && prevIsDigit && nextIsDigit) {
                    var end = i + 1
                    while end < chars.count, closers.contains(chars[end]) { end += 1 }
                    let atEnd = end >= chars.count
                    let followedBySpace = !atEnd && chars[end].isWhitespace
                    if followedBySpace || cjkTerminals.contains(c) || (atEnd && isFinal) {
                        boundary = end
                    }
                }
            } else if c == "\n" {
                boundary = i
            }

            if let b = boundary {
                var lookahead = b
                while lookahead < chars.count, chars[lookahead].isWhitespace { lookahead += 1 }
                let remainingNonWhitespace = chars.count - lookahead
                let stable = isFinal || remainingNonWhitespace >= 2
                let segment = String(chars[segmentStart..<min(b, chars.count)])
                let speakable = segment.contains(where: { $0.isLetter || $0.isNumber })

                if stable && speakable {
                    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { sentences.append(trimmed) }
                    segmentStart = lookahead
                    consumed = lookahead
                    i = lookahead
                    continue
                }
            }
            i += 1
        }

        if isFinal {
            let tail = String(chars[segmentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.contains(where: { $0.isLetter || $0.isNumber }) {
                sentences.append(tail)
            }
            consumed = chars.count
        }

        return (sentences, consumed)
    }
}

/// Per-turn glue: feeds each `visibleText` snapshot through the sanitizer,
/// tracks what has already been spoken, and survives mid-stream rewrites
/// (tool-anchor replacements can shrink the text) by resyncing to the longest
/// common prefix instead of re-speaking.
final class SpeechStreamComposer {
    private var spokenPrefix = ""
    private let replacements: SpeechTextSanitizer.Replacements

    init(replacements: SpeechTextSanitizer.Replacements = .spoken) {
        self.replacements = replacements
    }

    func reset() {
        spokenPrefix = ""
    }

    func ingest(_ visibleText: String, isFinal: Bool = false) -> [String] {
        let sanitized = SpeechTextSanitizer.sanitize(visibleText, replacements: replacements)
        if !sanitized.hasPrefix(spokenPrefix) {
            spokenPrefix = String(zip(sanitized, spokenPrefix).prefix(while: { $0 == $1 }).map(\.0))
        }
        let remainder = String(sanitized.dropFirst(spokenPrefix.count))
        let (sentences, consumed) = SpeechSentenceChunker.stableSentences(in: remainder, isFinal: isFinal)
        spokenPrefix += String(remainder.prefix(consumed))
        return sentences
    }

    func flush(_ finalText: String) -> [String] {
        ingest(finalText, isFinal: true)
    }
}
