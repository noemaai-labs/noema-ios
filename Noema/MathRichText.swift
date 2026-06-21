// MathRichText.swift
//  MathRichText.swift
//  Noema
//
//  Renders mixed text with inline and block LaTeX using MathTokenizer and
//  SwiftMath-backed views. Keeps baseline alignment for inline math and flows
//  across lines.

import SwiftUI
import Foundation

enum BlockMathWidthBehavior: Equatable {
    case intrinsic
    case wrapThenScroll
}

struct BlockMathStyle: Equatable {
    let fontSize: CGFloat
    let widthBehavior: BlockMathWidthBehavior
    let useCache: Bool

    static func standard(bodyFontSize: CGFloat) -> BlockMathStyle {
#if os(macOS)
        let fontSize = bodyFontSize * 1.5
#else
        let fontSize = preferredFontSize(.title3)
#endif
        return BlockMathStyle(fontSize: fontSize, widthBehavior: .intrinsic, useCache: true)
    }

    static func chat(bodyFontSize: CGFloat) -> BlockMathStyle {
#if os(macOS)
        let fontSize = bodyFontSize * 1.4
#else
        let fontSize = max(preferredFontSize(.title2), bodyFontSize * 1.35)
#endif
        return BlockMathStyle(fontSize: fontSize, widthBehavior: .wrapThenScroll, useCache: false)
    }
}

struct MessageHoverCopySuppressionKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

extension EnvironmentValues {
    var messageHoverCopySuppression: Binding<Bool>? {
        get { self[MessageHoverCopySuppressionKey.self] }
        set { self[MessageHoverCopySuppressionKey.self] = newValue }
    }
}
#if os(macOS)
import AppKit
#endif

struct MathRichText: View {
    let source: String
    var bodyFont: Font
    /// Explicit point size/weight for the macOS AppKit renderer (SwiftUI `Font`
    /// can't be converted to `NSFont`). Ignored on iOS/visionOS, which use
    /// `bodyFont` directly.
    var bodyPointSize: CGFloat
    var bodyWeight: Font.Weight
    private let blockMathStyle: BlockMathStyle

#if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.messageHoverCopySuppression) private var messageHoverCopySuppression
#endif

    init(source: String, bodyFont: Font = .body, bodyPointSize: CGFloat? = nil,
         bodyWeight: Font.Weight = .regular, blockMathStyle: BlockMathStyle? = nil) {
        self.source = source
        self.bodyFont = bodyFont
        self.bodyPointSize = bodyPointSize ?? preferredFontSize(.body)
        self.bodyWeight = bodyWeight
        self.blockMathStyle = blockMathStyle ?? .standard(bodyFontSize: preferredFontSize(.body))
    }

    var body: some View {
        content
            // VoiceOver was focusing on every tiny fragment because the composed
            // view tree breaks text into many subviews. Combine/override so the
            // whole paragraph is a single readable element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityString)
    }

    @ViewBuilder
    private var content: some View {
#if os(macOS)
        // One selectable NSTextView per block: continuous drag-selection and
        // LaTeX-aware copy. EquatableView skips re-renders during ~30 Hz
        // streaming when the source/style/appearance is unchanged.
        MacSelectableMathText(
            source: source,
            bodyPointSize: bodyPointSize,
            bodyWeight: macFontWeight(from: bodyWeight),
            blockMathFontSize: blockMathStyle.fontSize,
            isDark: colorScheme == .dark,
            messageHoverCopySuppression: messageHoverCopySuppression
        )
        .equatable()
#else
        RichMathTextLabel(source: source, bodyFont: bodyFont, blockMathStyle: blockMathStyle)
            // The streaming message re-renders its whole block list ~30 Hz; the
            // tokenizer-heavy label only needs to re-run for the block whose text
            // actually changed. EquatableView lets SwiftUI skip the rest.
            .equatable()
#endif
    }

    private var accessibilityString: String {
        // Flatten excessive whitespace so the spoken output is natural.
        // (Plain split/join — this runs on every body evaluation, so avoid
        // spinning up NSRegularExpression per render.)
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct RichMathTextLabel: View, Equatable {
    let source: String
    var bodyFont: Font
    let blockMathStyle: BlockMathStyle

    /// Vertical gap between paragraphs/list items inside one rich-text block.
    /// Gives the conversation a readable rhythm instead of stacked lines.
    private var paragraphSpacing: CGFloat {
#if os(macOS)
        8
#else
        6
#endif
    }

    /// Reconstruct the legacy `[MathToken]` inline list for the SwiftUI
    /// `InlineLine` view tree from the shared segmenter tokens.
    private func legacyTokens(from tokens: [MathRichInlineToken], headingLevel: Int?) -> [MathToken] {
        var out: [MathToken] = tokens.map { token in
            switch token {
            case .text(let s): return .text(s)
            case .inlineMath(let latex, _): return .inline(latex)
            }
        }
        // Headings never reach this path in practice (the planner strips the
        // "#"-prefix and renders headings as separate MathRichText views), but
        // if a literal "# "-prefixed line ever leaks, render it byte-identically
        // to the pre-segmenter behavior by restoring the marker text.
        if let level = headingLevel {
            let prefix = String(repeating: "#", count: level) + " "
            if case .text(let first)? = out.first {
                out[0] = .text(prefix + first)
            } else {
                out.insert(.text(prefix), at: 0)
            }
        }
        return out
    }

    var body: some View {
        let segments = MathRichSegmenter.segments(from: source)

        return VStack(alignment: .leading, spacing: paragraphSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .paragraph(let marker, let headingLevel, let tokens):
                    let inlineTokens = legacyTokens(from: tokens, headingLevel: headingLevel)
                    if let marker {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(marker)
                                .font(bodyFont)
                                .foregroundStyle(.secondary)
                            InlineLine(tokens: inlineTokens, bodyFont: bodyFont)
                        }
                        .padding(.leading, 8)
                    } else {
                        InlineLine(tokens: inlineTokens, bodyFont: bodyFont)
                    }
                case .block(let latex):
                    BlockMathView(
                        latex: latex,
                        fontSize: blockMathStyle.fontSize,
                        useCache: blockMathStyle.useCache,
                        widthBehavior: blockMathStyle.widthBehavior
                    )
                case .incomplete(let raw):
                    Text(raw)
                        .foregroundStyle(Color.red)
                }
            }
        }
    }
}

private struct InlineLine: View {
    let tokens: [MathToken]
    var bodyFont: Font
    @ScaledMetric(wrappedValue: preferredFontSize(.body), relativeTo: .body) private var inlineSize: CGFloat

    init(tokens: [MathToken], bodyFont: Font) {
        self.tokens = tokens
        self.bodyFont = bodyFont
#if os(macOS)
        let baseSize = preferredFontSize(.body) * 1.4
#else
        let baseSize = preferredFontSize(.body)
#endif
        _inlineSize = ScaledMetric(wrappedValue: baseSize, relativeTo: .body)
    }

    var body: some View {
        // Wrap inline runs naturally across lines using Text + inline images/views
        // We compose as HStack with text wrapping via flexible Text segments
        // and InlineMathView kept small enough to fit within line height.
        // SwiftUI doesn't allow inline baseline directly in Text; we approximate with alignment guides.
        // We split consecutive text tokens to reduce view count.
        let runs = mergeText(tokens)
        WrappedInline(runs: runs, font: bodyFont, fontSize: inlineSize)
    }

    private func mergeText(_ tokens: [MathToken]) -> [MathToken] {
        var out: [MathToken] = []
        for t in tokens {
            switch t {
            case .text(let s):
                if case .text(let prev)? = out.last {
                    out.removeLast()
                    out.append(.text(prev + s))
                } else { out.append(.text(s)) }
            default:
                out.append(t)
            }
        }
        return out
    }
}

private struct WrappedInline: View {
    let runs: [MathToken]
    let font: Font
    let fontSize: CGFloat

    private enum DisplayRun: Equatable {
        case text(AttributedString)
        case inline(String)
        case block(String)
        case incomplete(String)
    }

    // Split text into small fragments at whitespace and punctuation boundaries
    // so punctuation isn't glued to words (which can cause unwanted wrapping
    // after inline LaTeX). This lets commas or periods remain with the
    // preceding word when there's room.
    private func splitFragments(_ s: String) -> [String] {
        func chunkLongFragment(_ fragment: String, maxChunkLength: Int = 22) -> [String] {
            guard !fragment.contains(where: \.isWhitespace), fragment.count > maxChunkLength else {
                return [fragment]
            }
            var chunks: [String] = []
            chunks.reserveCapacity((fragment.count / maxChunkLength) + 1)
            var current = ""
            for ch in fragment {
                current.append(ch)
                if current.count >= maxChunkLength {
                    chunks.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            }
            if !current.isEmpty {
                chunks.append(current)
            }
            return chunks
        }

        guard !s.isEmpty else { return [] }
        let punctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "-", "—", "–", ")", "]", "}", "\"", "'"]
        let openers: Set<Character> = ["(", "[", "{"]
        var frags: [String] = []
        var current = ""
        enum Kind { case space, other }
        func kind(of ch: Character) -> Kind { ch.isWhitespace ? .space : .other }
        var lastKind: Kind? = nil
        for ch in s {
            // Attach closing punctuation to the previous token to avoid starting
            // a new line with "," or "." after an inline formula.
            if punctuation.contains(ch) && !current.isEmpty {
                current.append(ch)
                lastKind = .other
                continue
            }
            // If an opener follows a space, start a new fragment so it can stick
            // to the following word on the same line.
            if openers.contains(ch) {
                if !current.isEmpty { frags.append(current) }
                current = String(ch)
                lastKind = .other
                continue
            }
            let k = kind(of: ch)
            if let lk = lastKind, lk != k {
                if !current.isEmpty { frags.append(current) }
                current = String(ch)
            } else {
                current.append(ch)
            }
            lastKind = k
        }
        if !current.isEmpty { frags.append(current) }
        let chunked = frags.flatMap { chunkLongFragment($0) }
        var attachedWhitespace: [String] = []
        for fragment in chunked {
            if fragment.allSatisfy(\.isWhitespace), !attachedWhitespace.isEmpty {
                attachedWhitespace[attachedWhitespace.count - 1] += fragment
            } else {
                attachedWhitespace.append(fragment)
            }
        }
        return attachedWhitespace
    }

    private func normalizeInlineSpacing(_ s: String) -> String {
        var t = s
        let punct = [",", ".", ";", ":", "!", "?", ")", "]", "}"]
        for p in punct { t = t.replacingOccurrences(of: " " + p, with: p) }
        t = t.replacingOccurrences(of: "( ", with: "(")
        t = t.replacingOccurrences(of: "[ ", with: "[")
        t = t.replacingOccurrences(of: "{ ", with: "{")
        return t
    }

    private func attributedMarkdown(_ s: String, isStrong: Bool) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let normalized = normalizeInlineSpacing(s)
        var attributed = (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(normalized)
        if isStrong {
            attributed.inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }

    private func splitAttributedFragments(_ attributed: AttributedString) -> [AttributedString] {
        guard !attributed.characters.isEmpty else { return [] }
        let plain = String(attributed.characters)
        let parts = splitFragments(plain)
        var result: [AttributedString] = []
        var cursor = attributed.startIndex
        for part in parts {
            if part.isEmpty { continue }
            let end = attributed.index(cursor, offsetByCharacters: part.count)
            result.append(AttributedString(attributed[cursor..<end]))
            cursor = end
        }
        return result
    }

    private func textDisplayRuns(from text: String, strong: inout Bool) -> [DisplayRun] {
        guard !text.isEmpty else { return [] }
        var result: [DisplayRun] = []
        var buffer = ""
        var cursor = text.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let attributed = attributedMarkdown(buffer, isStrong: strong)
            result.append(contentsOf: splitAttributedFragments(attributed).map(DisplayRun.text))
            buffer.removeAll(keepingCapacity: true)
        }

        while cursor < text.endIndex {
            if text[cursor...].hasPrefix("**") {
                flushBuffer()
                strong.toggle()
                cursor = text.index(cursor, offsetBy: 2)
            } else {
                buffer.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        flushBuffer()
        return result
    }

    private func displayRuns() -> [DisplayRun] {
        var result: [DisplayRun] = []
        var strong = false

        for token in runs {
            switch token {
            case .text(let s):
                result.append(contentsOf: textDisplayRuns(from: s, strong: &strong))
            case .inline(let latex):
                result.append(.inline(latex))
            case .block(let latex):
                result.append(.block(latex))
            case .incomplete(let raw):
                result.append(.incomplete(raw))
            }
        }

        return result
    }

    var body: some View {
        // Wrap inline elements so math spans don't force a single ultra-wide line.
        // Zero horizontal spacing so inline math does not insert visual gaps
        // between adjacent text segments; a few points of line spacing give
        // wrapped paragraphs a comfortable reading rhythm.
        let displayRuns = displayRuns()
        InlineWrap(spacing: 0, lineSpacing: 3.5) {
            ForEach(Array(displayRuns.enumerated()), id: \.offset) { _, run in
                Group {
                    switch run {
                    case .text(let text):
                        Text(text)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                    case .inline(let latex):
                        InlineMathView(latex: latex, fontSize: fontSize)
                    case .block(let latex):
                        // Should not appear here; render inline-sized just in case.
                        InlineMathView(latex: latex, fontSize: fontSize)
                    case .incomplete(let raw):
                        Text(raw)
                            .foregroundStyle(Color.red)
                    }
                }
                // Streaming polish: appended fragments are *inserted* views
                // (stable offsets for the prefix), so they fade in whenever the
                // update runs inside an animated transaction — which only the
                // live streaming bubble provides (see ActiveStreamingMessageView).
                // Static messages render without a transaction: zero cost.
                // Removal is identity so re-splits never leave fading ghosts.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        // Apply base font to the container so inline Markdown keeps its
        // styles but inherits the body size/weight.
        .font(font)
    }
}

// MARK: - Inline wrapping layout
private struct InlineWrap: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2
    // Disable pre-wrap by default so LaTeX spans do not alter where text wraps.
    // When set > 0, the layout will pre-wrap if the remaining space is below
    // this threshold.
    var minResidualWrapWidth: CGFloat = 0

    // Provide a reasonable finite fallback width when the parent offers
    // an unbounded width. This prevents pathological reflow that can occur
    // when measuring with .infinity, ensuring inline math truly stays inline
    // and the surrounding text keeps its normal wrapping behavior.
    private var fallbackWidth: CGFloat {
        #if os(visionOS)
        return 480
        #elseif os(iOS)
        // Leave comfortable margins inside chat bubbles
        return max(320, UIScreen.main.bounds.width - 64)
        #else
        return 480
        #endif
    }

    private struct LineItem {
        let index: Int
        let size: CGSize
        let baseline: CGFloat?
    }

    private struct Line {
        var items: [LineItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var baseline: CGFloat? = nil
    }

    private func measure(_ subview: LayoutSubview, width: CGFloat) -> (CGSize, CGFloat?) {
        let proposed = ProposedViewSize(width: width, height: nil)
        let size = subview.sizeThatFits(proposed)
        let dims = subview.dimensions(in: ProposedViewSize(width: size.width, height: size.height))
        let baseline = dims[VerticalAlignment.firstTextBaseline]
        let validBaseline = baseline.isFinite ? baseline : nil
        return (size, validBaseline)
    }

    private func buildLines(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        var cursorX: CGFloat = 0

        func pushLine() {
            guard !current.items.isEmpty else { return }
            let maxBaseline = current.items.compactMap { $0.baseline }.max()
            let maxDescent = current.items.compactMap { item -> CGFloat? in
                guard let base = item.baseline else { return nil }
                return item.size.height - base
            }.max()
            let maxHeight = current.items.map(\.size.height).max() ?? 0
            if let base = maxBaseline, let desc = maxDescent {
                current.baseline = base
                current.height = max(maxHeight, base + desc)
            } else {
                current.baseline = nil
                current.height = maxHeight
            }
            current.width = max(0, cursorX - spacing)
            lines.append(current)
            current = Line()
            cursorX = 0
        }

        for index in subviews.indices {
            let available = maxWidth.isFinite ? max(0, maxWidth - cursorX) : .infinity

            if minResidualWrapWidth > 0 && maxWidth.isFinite && cursorX > 0 && available < minResidualWrapWidth {
                pushLine()
            }

            var (size, baseline) = measure(subviews[index], width: max(0, maxWidth - cursorX))
            if maxWidth.isFinite && cursorX > 0 && size.width > available + 0.5 {
                pushLine()
                (size, baseline) = measure(subviews[index], width: maxWidth)
            }

            current.items.append(LineItem(index: index, size: size, baseline: baseline))
            cursorX += size.width + spacing
        }
        pushLine()
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? fallbackWidth
        let lines = buildLines(subviews: subviews, maxWidth: maxWidth)

        var totalHeight: CGFloat = 0
        for (idx, line) in lines.enumerated() {
            totalHeight += line.height
            if idx < lines.count - 1 { totalHeight += lineSpacing }
        }
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width > 0 ? bounds.width : fallbackWidth
        let lines = buildLines(subviews: subviews, maxWidth: maxWidth)

        var cursorY = bounds.minY
        for line in lines {
            let baselineY: CGFloat = {
                if let base = line.baseline { return cursorY + base }
                return cursorY + (line.height / 2)
            }()

            var cursorX = bounds.minX
            for item in line.items {
                let y: CGFloat
                if let itemBaseline = item.baseline, let lineBaseline = line.baseline {
                    y = baselineY - itemBaseline
                } else {
                    y = cursorY + (line.height - item.size.height) / 2
                }
                subviews[item.index].place(at: CGPoint(x: cursorX, y: y),
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                cursorX += item.size.width + spacing
            }
            cursorY += line.height + lineSpacing
        }
    }
}
