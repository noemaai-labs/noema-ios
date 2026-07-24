import Foundation

public enum MathToken: Equatable {
    case text(String)
    case inline(String)
    case block(String)
    /// Represents an unterminated/incomplete LaTeX segment (e.g., unclosed $$, \(, or \[).
    /// Renderers should show this as plain red text without attempting LaTeX formatting.
    case incomplete(String)
}

public struct MathTokenizer {
    // MARK: - Minimal inline LaTeX heuristics (no $ delimiters)
    /// Splits a plain text run into `.text` and `.inline` tokens by recognizing
    /// specific TeX macros even when they are not wrapped in `\(...\)`.
    ///
    /// Currently supported:
    /// - `\frac{numerator}{denominator}` (ends the inline span at the closing brace
    ///   of the second argument, even when additional prose follows immediately).
    /// - `\boxed{...}` / `\fbox{...}` — models often emit final answers this way
    ///   without any math delimiters.
    ///
    /// This is conservative and only fires when the brace groups are complete.
    /// Malformed macros are left as plain text.
    public static func splitHeuristicInlineLatex(in text: String) -> [MathToken] {
        guard !text.isEmpty else { return [] }

        var tokens: [MathToken] = []
        var cursor = text.startIndex
        var lastEmit = text.startIndex
        let end = text.endIndex

        while cursor < end {
            let remain = text[cursor..<end]
            // Support \frac, \dfrac, \tfrac variants
            let macroLen: Int? = {
                if remain.hasPrefix("\\frac") { return 5 }
                if remain.hasPrefix("\\dfrac") { return 6 }
                if remain.hasPrefix("\\tfrac") { return 6 }
                return nil
            }()
            if let mlen = macroLen {
                // Move past the fraction macro
                var i = text.index(cursor, offsetBy: mlen)
                // Skip optional whitespace
                while i < end, text[i].isWhitespace { i = text.index(after: i) }
                guard i < end, text[i] == "{" else {
                    cursor = text.index(after: cursor)
                    continue
                }
                // Parse numerator
                guard let numClose = findMatchingBrace(in: text, from: i) else {
                    cursor = text.index(after: cursor)
                    continue
                }
                var j = text.index(after: numClose)
                while j < end, text[j].isWhitespace { j = text.index(after: j) }
                guard j < end, text[j] == "{" else {
                    cursor = text.index(after: cursor)
                    continue
                }
                // Parse denominator
                guard let denClose = findMatchingBrace(in: text, from: j) else {
                    cursor = text.index(after: cursor)
                    continue
                }
                // We have a complete \frac{..}{..}. Emit preceding text then the inline span.
                if lastEmit < cursor { tokens.append(.text(String(text[lastEmit..<cursor]))) }

                let latex = String(text[cursor...denClose])
                tokens.append(.inline(normalizeBoxing(latex)))
                cursor = text.index(after: denClose)
                lastEmit = cursor
                continue
            }
            if let spanEnd = matchBoxMacroSpan(in: text, at: cursor) {
                if lastEmit < cursor { tokens.append(.text(String(text[lastEmit..<cursor]))) }
                tokens.append(.inline(normalizeBoxing(String(text[cursor..<spanEnd]))))
                cursor = spanEnd
                lastEmit = cursor
                continue
            }
            cursor = text.index(after: cursor)
        }
        // Append any tail text
        if lastEmit < end { tokens.append(.text(String(text[lastEmit..<end]))) }
        // If no heuristic match, return a single text token
        if tokens.isEmpty { return [.text(text)] }
        // Merge adjacent text tokens
        var merged: [MathToken] = []
        for t in tokens {
            if case .text(let s) = t, case .text(let prev)? = merged.last {
                merged.removeLast(); merged.append(.text(prev + s))
            } else { merged.append(t) }
        }
        return merged
    }
    /// Find the matching closing '}' for a brace group starting at `openIdx`
    /// (which must point to '{'), honoring backslash escapes.
    private static func findMatchingBrace(in text: String, from openIdx: String.Index) -> String.Index? {
        precondition(text[openIdx] == "{", "findMatchingBrace must start at '{'")
        var depth = 0
        var i = openIdx
        let end = text.endIndex
        while i < end {
            let ch = text[i]
            if ch == "\\" { // skip escaped next character
                let next = text.index(after: i)
                if next < end { i = text.index(after: next); continue }
            }
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            if i < end { i = text.index(after: i) }
        }
        return nil
    }

    /// Boxing macros that renderers can draw as an actual border when they wrap
    /// an entire math span.
    private static let boxWrapperMacros = ["\\boxed", "\\fbox"]

    /// If `text` at `start` begins a complete `\boxed{...}`/`\fbox{...}` macro,
    /// returns the index just past its closing brace.
    private static func matchBoxMacroSpan(in text: String, at start: String.Index) -> String.Index? {
        let remain = text[start...]
        for name in boxWrapperMacros {
            guard remain.hasPrefix(name) else { continue }
            var i = text.index(start, offsetBy: name.count)
            // The macro name must end here (rejects e.g. \fboxsep).
            if i < text.endIndex, text[i].isLetter { continue }
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "{",
                  let close = findMatchingBrace(in: text, from: i) else { continue }
            return text.index(after: close)
        }
        return nil
    }

    /// If the entire (trimmed) span is a single boxing macro, returns its inner
    /// content with `boxed == true`; nested wrappers (`\boxed{\fbox{x}}`) are
    /// peeled fully. Renderers use this to draw the box host-side, since
    /// SwiftMath cannot typeset `\boxed` itself.
    ///
    /// Sentence punctuation after the closing brace (`\boxed{X}.`) is folded
    /// inside the box rather than defeating the whole-span check — losing the
    /// border entirely is worse than a period inside it.
    public static func unwrapBoxed(_ input: String) -> (latex: String, boxed: Bool) {
        let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var boxed = false
        while true {
            var peeled = false
            for name in boxWrapperMacros where s.hasPrefix(name) {
                var i = s.index(s.startIndex, offsetBy: name.count)
                if i < s.endIndex, s[i].isLetter { continue }
                while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
                guard i < s.endIndex, s[i] == "{",
                      let close = findMatchingBrace(in: s, from: i) else { continue }
                let trailing = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard trailing.allSatisfy({ trailingPunctuation.contains($0) }) else { continue }
                s = String(s[s.index(after: i)..<close]).trimmingCharacters(in: .whitespacesAndNewlines) + trailing
                boxed = true
                peeled = true
                break
            }
            if !peeled { break }
        }
        return (s, boxed)
    }

    /// Canonicalizes boxing for SwiftMath: interior boxes are stripped (the
    /// engine cannot render them mid-expression), while a box wrapping the
    /// whole span is preserved as `\boxed{...}` so renderers can draw it.
    /// Also rewrites AMS numbering commands SwiftMath cannot parse.
    static func normalizeBoxing(_ input: String) -> String {
        let (inner, boxed) = unwrapBoxed(input)
        let stripped = sanitizeUnsupportedCommands(stripBoxing(inner))
        return boxed ? "\\boxed{" + stripped + "}" : stripped
    }

    /// SwiftMath errors out on unknown commands, which drops the *entire* span
    /// to the raw red-text fallback. Models routinely emit AMS equation
    /// numbering (`... \tag{1}`), so rewrite what we can and drop the rest:
    /// - `\tag{X}` / `\tag*{X}` → `\qquad (\text{X})` (number stays visible)
    /// - `\label{...}`, `\notag`, `\nonumber` → removed
    static func sanitizeUnsupportedCommands(_ input: String) -> String {
        guard input.contains("\\") else { return input }
        var s = replaceCommand("\\dots", with: "\\ldots", in: input)
        s = rewriteTagMacros(in: s)
        s = removeMacro("\\label", takesBraceArg: true, in: s)
        s = removeMacro("\\notag", takesBraceArg: false, in: s)
        s = removeMacro("\\nonumber", takesBraceArg: false, in: s)
        return s
    }

    /// Rewrites one complete TeX command name without touching longer commands
    /// that merely share the same prefix (for example, `\dotsb`).
    private static func replaceCommand(_ name: String, with replacement: String, in text: String) -> String {
        var s = text
        var searchFrom = s.startIndex

        while let range = s.range(of: name, range: searchFrom..<s.endIndex) {
            if range.upperBound < s.endIndex, s[range.upperBound].isLetter {
                searchFrom = range.upperBound
                continue
            }

            let replacementStartOffset = s.distance(from: s.startIndex, to: range.lowerBound)
            s.replaceSubrange(range, with: replacement)
            searchFrom = s.index(s.startIndex, offsetBy: replacementStartOffset + replacement.count)
        }

        return s
    }

    private static func rewriteTagMacros(in text: String) -> String {
        var s = text
        var searchFrom = s.startIndex
        while let r = s.range(of: "\\tag", range: searchFrom..<s.endIndex) {
            var i = r.upperBound
            if i < s.endIndex, s[i] == "*" { i = s.index(after: i) }
            // Reject longer command names (e.g. \tagged) and malformed tags.
            if i < s.endIndex, s[i].isLetter { searchFrom = r.upperBound; continue }
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex, s[i] == "{",
                  let close = findMatchingBrace(in: s, from: i) else {
                searchFrom = r.upperBound
                continue
            }
            let label = String(s[s.index(after: i)..<close])
            let replacement = "\\qquad (\\text{" + label + "})"
            let nextOffset = s.distance(from: s.startIndex, to: r.lowerBound) + replacement.count
            s.replaceSubrange(r.lowerBound...close, with: replacement)
            searchFrom = s.index(s.startIndex, offsetBy: nextOffset)
        }
        return s
    }

    private static func removeMacro(_ name: String, takesBraceArg: Bool, in text: String) -> String {
        var s = text
        var searchFrom = s.startIndex
        while let r = s.range(of: name, range: searchFrom..<s.endIndex) {
            var removeEnd = r.upperBound
            if removeEnd < s.endIndex, s[removeEnd].isLetter { searchFrom = r.upperBound; continue }
            if takesBraceArg {
                var i = removeEnd
                while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
                guard i < s.endIndex, s[i] == "{",
                      let close = findMatchingBrace(in: s, from: i) else {
                    searchFrom = r.upperBound
                    continue
                }
                removeEnd = s.index(after: close)
            }
            let nextOffset = s.distance(from: s.startIndex, to: r.lowerBound)
            s.removeSubrange(r.lowerBound..<removeEnd)
            searchFrom = s.index(s.startIndex, offsetBy: nextOffset)
        }
        return s
    }

    /// Removes LaTeX boxing macros while preserving their contents.
    /// Supported patterns:
    /// - \boxed{arg}
    /// - \fbox{arg}
    /// - \framebox[...][...]{arg} (drops optional args)
    /// - \colorbox{color}{arg}
    /// - \fcolorbox{border}{bg}{arg}
    /// The transformation is applied recursively until no more box macros remain.
    private static func stripBoxing(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var s = input

        // Parse optional bracket group like [ ... ] starting at idx if present.
        func skipOptionalBracket(in text: String, from idx: String.Index) -> String.Index {
            guard idx < text.endIndex, text[idx] == "[" else { return idx }
            var i = idx
            let end = text.endIndex
            var depth = 0
            while i < end {
                let ch = text[i]
                if ch == "\\" {
                    let n = text.index(after: i)
                    if n < end { i = text.index(after: n); continue }
                }
                if ch == "[" { depth += 1 }
                if ch == "]" {
                    depth -= 1
                    if depth == 0 { return text.index(after: i) }
                }
                i = text.index(after: i)
            }
            return idx // malformed; do not advance
        }

        func replaceFirstSingleArgMacro(name: String, in text: String) -> (String, Bool) {
            guard let range = text.range(of: "\\" + name) else { return (text, false) }
            var i = range.upperBound
            // Skip whitespace
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "{" else { return (text, false) }
            guard let close = findMatchingBrace(in: text, from: i) else { return (text, false) }
            let inner = text[text.index(after: i)..<close]
            let before = text[..<range.lowerBound]
            let after = text[text.index(after: close)..<text.endIndex]
            return (String(before) + String(inner) + String(after), true)
        }

        func replaceFirstFramebox(in text: String) -> (String, Bool) {
            guard let range = text.range(of: "\\framebox") else { return (text, false) }
            var i = range.upperBound
            // Skip whitespace
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            // Optional [ ... ] width
            i = skipOptionalBracket(in: text, from: i)
            // Optional [ ... ] position
            i = skipOptionalBracket(in: text, from: i)
            // Required { ... } content
            guard i < text.endIndex, text[i] == "{" else { return (text, false) }
            guard let close = findMatchingBrace(in: text, from: i) else { return (text, false) }
            let inner = text[text.index(after: i)..<close]
            let before = text[..<range.lowerBound]
            let after = text[text.index(after: close)..<text.endIndex]
            return (String(before) + String(inner) + String(after), true)
        }

        func replaceFirstColorbox(in text: String) -> (String, Bool) {
            guard let range = text.range(of: "\\colorbox") else { return (text, false) }
            var i = range.upperBound
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            // {color}
            guard i < text.endIndex, text[i] == "{" else { return (text, false) }
            guard let colorClose = findMatchingBrace(in: text, from: i) else { return (text, false) }
            var j = text.index(after: colorClose)
            while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
            guard j < text.endIndex, text[j] == "{" else { return (text, false) }
            guard let textClose = findMatchingBrace(in: text, from: j) else { return (text, false) }
            let inner = text[text.index(after: j)..<textClose]
            let before = text[..<range.lowerBound]
            let after = text[text.index(after: textClose)..<text.endIndex]
            return (String(before) + String(inner) + String(after), true)
        }

        func replaceFirstFColorbox(in text: String) -> (String, Bool) {
            guard let range = text.range(of: "\\fcolorbox") else { return (text, false) }
            var i = range.upperBound
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            // {border}
            guard i < text.endIndex, text[i] == "{" else { return (text, false) }
            guard let borderClose = findMatchingBrace(in: text, from: i) else { return (text, false) }
            var j = text.index(after: borderClose)
            while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
            // {bg}
            guard j < text.endIndex, text[j] == "{" else { return (text, false) }
            guard let bgClose = findMatchingBrace(in: text, from: j) else { return (text, false) }
            var k = text.index(after: bgClose)
            while k < text.endIndex, text[k].isWhitespace { k = text.index(after: k) }
            // {text}
            guard k < text.endIndex, text[k] == "{" else { return (text, false) }
            guard let textClose = findMatchingBrace(in: text, from: k) else { return (text, false) }
            let inner = text[text.index(after: k)..<textClose]
            let before = text[..<range.lowerBound]
            let after = text[text.index(after: textClose)..<text.endIndex]
            return (String(before) + String(inner) + String(after), true)
        }

        while true {
            var changed = false
            // Single-arg boxers
            for name in ["boxed", "fbox"] {
                let (t, did) = replaceFirstSingleArgMacro(name: name, in: s)
                if did { s = t; changed = true }
            }
            // framebox with optional args
            do {
                let (t, did) = replaceFirstFramebox(in: s)
                if did { s = t; changed = true }
            }
            // colorbox and fcolorbox (keep only text argument)
            do {
                let (t, did) = replaceFirstColorbox(in: s)
                if did { s = t; changed = true }
            }
            do {
                let (t, did) = replaceFirstFColorbox(in: s)
                if did { s = t; changed = true }
            }
            if !changed { break }
        }
        return s
    }

    /// Currency guard for single-`$` spans: decides whether the text between two
    /// `$` delimiters reads as math (render as LaTeX) or as an amount/prose
    /// (leave literal). Errs toward leaving number-led or multi-word content as
    /// plain text, since unclosed `$5`, `$20`, and `$70 million` are far more
    /// common in chat than bare-dollar math. Explicitly closed numeric spans
    /// (`$4$`, `$-3$`, `$3, -2, 5$`) count as math; ordinary currency remains
    /// literal because it has no closing delimiter. Content carrying explicit
    /// TeX structure (`\`, `^`, `_`, `{`, `}`) always counts as math. A
    /// comma-separated list of single-symbol variables (`u, v`) also counts as
    /// math, without turning ordinary comma-separated prose (`hello, world`)
    /// into LaTeX.
    static func dollarSpanIsMath(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        // Unambiguous TeX structure → always math (e.g. \lambda, x^2, \mathbf{v}).
        let structural: Set<Character> = ["\\", "^", "_", "{", "}"]
        if s.contains(where: { structural.contains($0) }) { return true }
        // A tightly delimited number or comma-separated numeric list is
        // intentional math. Currency in prose normally has only an opening
        // dollar sign, so it never reaches this classification as a closed
        // span.
        if isNumericMathSpan(s) { return true }
        // Number-led prose ("70 million") still reads as currency, not math.
        if let first = s.first, first.isNumber { return false }
        // A symbol/variable/expression needs at least one letter.
        guard s.contains(where: { $0.isLetter }) else { return false }
        // Multi-word plain prose ("the value") is not math unless it carries an
        // arithmetic/relational operator ("a + b", "x = 5").
        if s.contains(" ") {
            let operators: Set<Character> = ["+", "-", "=", "*", "/", "<", ">", "|"]
            if s.contains(where: { operators.contains($0) }) { return true }

            // Models commonly emit variable lists such as `$u, v$`. Require
            // every comma-separated item to be exactly one letter (including
            // Unicode symbols such as `α`) so prose like `$hello, world$`
            // remains literal.
            let commaSeparatedVariables = s.split(separator: ",", omittingEmptySubsequences: false)
            if commaSeparatedVariables.count > 1 {
                return commaSeparatedVariables.allSatisfy { item in
                    let symbol = item.trimmingCharacters(in: .whitespacesAndNewlines)
                    return symbol.count == 1 && symbol.first?.isLetter == true
                }
            }
            return false
        }
        // Single symbolic token starting with a letter (A, x, pi, theta, …).
        return true
    }

    private static func isNumericMathSpan(_ text: String) -> Bool {
        let items = text.split(separator: ",", omittingEmptySubsequences: false)
        guard !items.isEmpty else { return false }

        return items.allSatisfy { rawItem in
            var item = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return false }

            if item.first == "+" || item.first == "-" {
                item.removeFirst()
            }
            guard !item.isEmpty else { return false }

            var sawDigit = false
            var sawDecimalPoint = false
            for character in item {
                if character.isNumber {
                    sawDigit = true
                } else if character == ".", !sawDecimalPoint {
                    sawDecimalPoint = true
                } else {
                    return false
                }
            }
            return sawDigit
        }
    }

    public static func tokenize(_ input: String) -> [MathToken] {
        guard !input.isEmpty else { return [] }
        var tokens: [MathToken] = []
        let end = input.endIndex
        var cursor = input.startIndex
        var textStart = cursor

        func isEscaped(_ idx: String.Index) -> Bool {
            if idx == input.startIndex { return false }
            var backslashes = 0
            var j = input.index(before: idx)
            while true {
                if input[j] == "\\" { backslashes += 1 } else { break }
                if j == input.startIndex { break }
                j = input.index(before: j)
            }
            return backslashes % 2 == 1
        }

        func flushText(upTo idx: String.Index) {
            if idx > textStart {
                tokens.append(.text(String(input[textStart..<idx])))
            }
        }

        while cursor < end {
            let ch = input[cursor]

            // Block $$ ... $$  or inline $ ... $
            if ch == "$" && !isEscaped(cursor) {
                let next = input.index(after: cursor)
                if next < end && input[next] == "$" && !isEscaped(next) {
                    var i = input.index(after: next)
                    var close: String.Index?
                    while i < end {
                        if input[i] == "$" && !isEscaped(i) {
                            let i2 = input.index(after: i)
                            if i2 < end && input[i2] == "$" && !isEscaped(i2) { close = i; break }
                        }
                        i = input.index(after: i)
                    }
                    if let k = close {
                        flushText(upTo: cursor)
                        let contentStart = input.index(after: next)
                        let rawContent = input[contentStart..<k]
                        let trimmed = String(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
                        tokens.append(.block(normalizeBoxing(trimmed)))
                        cursor = input.index(after: input.index(after: k))
                        textStart = cursor
                        continue
                    } else {
                        // Incomplete $$ ... at end of input — treat remainder as incomplete LaTeX
                        flushText(upTo: cursor)
                        tokens.append(.incomplete(String(input[cursor..<end])))
                        cursor = end
                        textStart = cursor
                        break
                    }
                } else if next < end, !input[next].isWhitespace {
                    // Inline single-$ math. Pandoc-style delimiter rules + currency
                    // guard keep amounts like "$70 million ... $20" literal:
                    //   • the opening `$` is followed by a non-space (checked above);
                    //   • the next unescaped `$` on this line must close it, with a
                    //     non-space immediately before it and no digit immediately
                    //     after it;
                    //   • the span content must read as math (dollarSpanIsMath).
                    // Only the first `$` can close, so a stray `$` can't swallow
                    // trailing text (e.g. "$70 million ... $20").
                    var i = next
                    var matched = false
                    while i < end {
                        let c = input[i]
                        if c == "\n" || c == "\r" { break }
                        if c == "$" && !isEscaped(i) {
                            let beforeIdx = input.index(before: i)
                            let afterIdx = input.index(after: i)
                            let closerOK = !input[beforeIdx].isWhitespace
                                && !(afterIdx < end && input[afterIdx].isNumber)
                            if closerOK {
                                let content = String(input[next..<i])
                                if dollarSpanIsMath(content) {
                                    flushText(upTo: cursor)
                                    tokens.append(.inline(normalizeBoxing(content)))
                                    cursor = input.index(after: i)
                                    textStart = cursor
                                    matched = true
                                }
                            }
                            break
                        }
                        i = input.index(after: i)
                    }
                    if matched { continue }
                }
            }

            // Block \[ ... \] or inline \( ... \)
            if ch == "\\" {
                let remain = input[cursor..<end]
                if remain.hasPrefix("\\[") {
                    var i = input.index(cursor, offsetBy: 2)
                    var close: String.Index?
                    while i < end {
                        if input[i] == "\\" {
                            let n = input.index(after: i)
                            if n < end && input[n] == "]" { close = i; break }
                        }
                        i = input.index(after: i)
                    }
                    if let k = close {
                        flushText(upTo: cursor)
                        let contentStart = input.index(cursor, offsetBy: 2)
                        let content = input[contentStart..<k]
                        let trimmed = String(content).trimmingCharacters(in: .whitespacesAndNewlines)
                        tokens.append(.block(normalizeBoxing(trimmed)))
                        cursor = input.index(after: input.index(after: k))
                        textStart = cursor
                        continue
                    } else {
                        // Incomplete \[ ... at end of input — treat remainder as incomplete LaTeX
                        flushText(upTo: cursor)
                        tokens.append(.incomplete(String(input[cursor..<end])))
                        cursor = end
                        textStart = cursor
                        break
                    }
                } else if remain.hasPrefix("\\(") {
                    var i = input.index(cursor, offsetBy: 2)
                    var close: String.Index?
                    while i < end {
                        if input[i] == "\\" {
                            let n = input.index(after: i)
                            if n < end && input[n] == ")" { close = i; break }
                        }
                        i = input.index(after: i)
                    }
                    if let k = close {
                        flushText(upTo: cursor)
                        let contentStart = input.index(cursor, offsetBy: 2)
                        let content = input[contentStart..<k]
                        tokens.append(.inline(normalizeBoxing(String(content))))
                        cursor = input.index(after: input.index(after: k))
                        textStart = cursor
                        continue
                    } else {
                        // Incomplete \( ... at end of input — treat remainder as incomplete LaTeX
                        flushText(upTo: cursor)
                        tokens.append(.incomplete(String(input[cursor..<end])))
                        cursor = end
                        textStart = cursor
                        break
                    }
                }
            }

            cursor = input.index(after: cursor)
        }

        flushText(upTo: end)
        return tokens
    }

    // Helper to compute text length already captured so we can slice remaining prefix when building tokens incrementally.
    // We only subtract lengths of consecutive leading .text tokens since we push prefixes eagerly.
    private static func tokenTextLength<T>(_: T) -> Int { 0 }
}
