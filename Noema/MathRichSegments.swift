// MathRichSegments.swift
//  MathRichSegments.swift
//  Noema
//
//  Platform-neutral segmentation of mixed text + LaTeX sources, shared by the
//  SwiftUI renderer (iOS/visionOS) and the AppKit selectable renderer (macOS).
//  Also hosts the copy transform that substitutes math attachments with their
//  original LaTeX source when text is copied out of the macOS chat.

import Foundation

/// One inline run inside a paragraph.
enum MathRichInlineToken: Equatable {
    case text(String)
    /// `hadDelimiters` records provenance: tokens recognized via explicit
    /// `\(...\)` delimiters copy back out wrapped in delimiters, while
    /// heuristic matches (bare `\frac{..}{..}` in prose) copy bare.
    case inlineMath(latex: String, hadDelimiters: Bool)
}

/// A renderable block produced from one MathRichText source string.
enum MathRichSegment: Equatable {
    case paragraph(marker: String?, headingLevel: Int?, tokens: [MathRichInlineToken])
    case block(latex: String)
    case incomplete(String)
}

enum MathRichSegmenter {
    /// Detects a list-item prefix ("• ", "1. ", "2) ", "3] ") at the start of a
    /// paragraph so it can render with a hanging indent like a native list.
    static func bulletPrefix(of s: String) -> (marker: String, content: String)? {
        if s.hasPrefix("• ") { return ("•", String(s.dropFirst(2))) }
        // Ordered markers: digits followed by '.', ')' or ']' and a space.
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber, digits.count < 3 {
            digits.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !digits.isEmpty, idx < s.endIndex else { return nil }
        let punct = s[idx]
        guard punct == "." || punct == ")" || punct == "]" else { return nil }
        let afterPunct = s.index(after: idx)
        guard afterPunct < s.endIndex, s[afterPunct] == " " else { return nil }
        return (digits + String(punct), String(s[s.index(after: afterPunct)...]))
    }

    /// Detects a markdown heading prefix ("# " … "###### ") at the start of a
    /// paragraph. Returns the level and the remaining content.
    static func headingPrefix(of s: String) -> (level: Int, content: String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1
            idx = s.index(after: idx)
        }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        let content = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (level, content)
    }

    /// Re-attaches punctuation/openers that fragment splitting (or model
    /// output) left floating, e.g. "word ," → "word,". Shared by the SwiftUI
    /// fragment renderer and the macOS attributed-string builder.
    static func normalizeInlineSpacing(_ s: String) -> String {
        var t = s
        let punct = [",", ".", ";", ":", "!", "?", ")", "]", "}"]
        for p in punct { t = t.replacingOccurrences(of: " " + p, with: p) }
        t = t.replacingOccurrences(of: "( ", with: "(")
        t = t.replacingOccurrences(of: "[ ", with: "[")
        t = t.replacingOccurrences(of: "{ ", with: "{")
        return t
    }

    static func segments(from source: String) -> [MathRichSegment] {
        let tokens = MathTokenizer.tokenize(source)
        var out: [MathRichSegment] = []
        var currentInline: [MathRichInlineToken] = []
        var currentMarker: String? = nil
        var currentHeadingLevel: Int? = nil

        func flushInline() {
            if !currentInline.isEmpty {
                out.append(.paragraph(marker: currentMarker, headingLevel: currentHeadingLevel, tokens: currentInline))
                currentInline.removeAll(keepingCapacity: true)
            }
            currentMarker = nil
            currentHeadingLevel = nil
        }

        for t in tokens {
            switch t {
            case .block(let latex):
                flushInline()
                out.append(.block(latex: latex))

            case .inline(let latex):
                currentInline.append(.inlineMath(latex: latex, hadDelimiters: true))

            case .incomplete(let s):
                // Flush any inline content first, then record incomplete LaTeX
                flushInline()
                out.append(.incomplete(s))

            case .text(let s):
                if s.isEmpty { continue }
                // Treat single newlines as soft spaces so inline math does not
                // force awkward line breaks (e.g., when models add stray \n).
                // Preserve paragraph breaks only for 2+ consecutive newlines.
                let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
                let paragraphs = normalized.components(separatedBy: "\n\n")
                for (idx, para) in paragraphs.enumerated() {
                    var inlinePara = para.replacingOccurrences(of: "\n", with: " ")
                    if !inlinePara.isEmpty {
                        // A paragraph that starts with a list marker renders as
                        // a hanging-indent row instead of inline "• text"; a
                        // "#"-prefixed paragraph renders as a heading.
                        if currentInline.isEmpty, currentMarker == nil, currentHeadingLevel == nil {
                            if let heading = headingPrefix(of: inlinePara) {
                                currentHeadingLevel = heading.level
                                inlinePara = heading.content
                            } else if let item = bulletPrefix(of: inlinePara) {
                                currentMarker = item.marker
                                inlinePara = item.content
                            }
                        }
                        let split = MathTokenizer.splitHeuristicInlineLatex(in: inlinePara)
                        if split.isEmpty {
                            currentInline.append(.text(inlinePara))
                        } else {
                            for piece in split {
                                switch piece {
                                case .text(let t): currentInline.append(.text(t))
                                case .inline(let latex): currentInline.append(.inlineMath(latex: latex, hadDelimiters: false))
                                case .block(let latex): currentInline.append(.inlineMath(latex: latex, hadDelimiters: false))
                                case .incomplete(let raw): currentInline.append(.text(raw))
                                }
                            }
                        }
                    }
                    if idx < paragraphs.count - 1 { flushInline() }
                }
            }
        }
        flushInline()
        return out
    }
}

// MARK: - LaTeX-aware copy transform

extension NSAttributedString.Key {
    /// Original LaTeX source (with delimiters where the author wrote them) for
    /// a math attachment character. Consulted when copying selected text so the
    /// pasteboard receives LaTeX instead of the object-replacement character.
    static let noemaLatexSource = NSAttributedString.Key("NoemaLatexSource")
    /// Bool — true for display (block) math attachments.
    static let noemaLatexBlock = NSAttributedString.Key("NoemaLatexBlock")
    /// Bare LaTeX source (no delimiters) for a math attachment — used by the
    /// hover/context-menu "Copy LaTeX" affordances.
    static let noemaLatexRaw = NSAttributedString.Key("NoemaLatexRaw")
}

enum LatexCopyTransform {
    /// Plain-text rendition of `attributed` where every run carrying
    /// `.noemaLatexSource` is replaced by that LaTeX source string.
    static func plainText(from attributed: NSAttributedString) -> String {
        var result = ""
        result.reserveCapacity(attributed.length)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.noemaLatexSource, in: full) { value, range, _ in
            if let latex = value as? String {
                result += latex
            } else {
                result += attributed.attributedSubstring(from: range).string
            }
        }
        return result
    }

    /// Transform for a (possibly discontiguous) selection; ranges are joined
    /// with a newline, matching NSTextView's multi-range copy behavior.
    static func plainText(from attributed: NSAttributedString, ranges: [NSRange]) -> String {
        let full = NSRange(location: 0, length: attributed.length)
        let pieces = ranges.compactMap { range -> String? in
            guard let clamped = range.intersection(full), clamped.length > 0 else { return nil }
            return plainText(from: attributed.attributedSubstring(from: clamped))
        }
        return pieces.joined(separator: "\n")
    }
}
