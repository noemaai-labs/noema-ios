// MacSelectableMathText.swift
//  MacSelectableMathText.swift
//  Noema
//
//  macOS-only. Renders one MathRichText block as a single, continuously
//  selectable NSTextView (TextKit 1). Text is one NSAttributedString;
//  inline/block LaTeX become NSTextAttachment images, and the original LaTeX
//  source is stored on each attachment so copying a selection yields the real
//  LaTeX instead of the object-replacement character.
//
//  This replaces the per-word fragmented SwiftUI renderer on macOS, which
//  stopped drag-selection at every word boundary.

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Font weight bridge

/// Maps a SwiftUI `Font.Weight` to the AppKit `NSFont.Weight` used by the
/// attributed-string builder. SwiftUI's `Font.Weight` is not switchable, so we
/// compare against the known static values.
func macFontWeight(from weight: Font.Weight) -> NSFont.Weight {
    if weight == .ultraLight { return .ultraLight }
    if weight == .thin { return .thin }
    if weight == .light { return .light }
    if weight == .medium { return .medium }
    if weight == .semibold { return .semibold }
    if weight == .bold { return .bold }
    if weight == .heavy { return .heavy }
    if weight == .black { return .black }
    return .regular
}

// MARK: - Block math attachment (downscales to fit width)

/// A display-math attachment that shrinks to the available line width instead
/// of being clipped or forcing a horizontal scroll.
final class MathBlockAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return super.attachmentBounds(for: textContainer,
                                          proposedLineFragment: lineFrag,
                                          glyphPosition: position,
                                          characterIndex: charIndex)
        }
        let natural = image.size
        let maxWidth = lineFrag.width > 1 ? lineFrag.width : natural.width
        guard natural.width > maxWidth else {
            return CGRect(x: 0, y: 0, width: natural.width, height: natural.height)
        }
        let scale = maxWidth / natural.width
        return CGRect(x: 0, y: 0,
                      width: floor(natural.width * scale),
                      height: floor(natural.height * scale))
    }
}

// MARK: - Attributed string builder

@MainActor
enum MacMathAttributedStringBuilder {
    struct Style: Equatable {
        var bodyPointSize: CGFloat
        var bodyWeight: NSFont.Weight
        var inlineMathFontSize: CGFloat
        var blockMathFontSize: CGFloat
        var isDark: Bool
        var paragraphSpacing: CGFloat = 8
        var lineSpacing: CGFloat = 3.5

        /// Math glyphs are rendered into bitmaps, so their color is baked in and
        /// must follow the appearance. Matches `resolvedMathColor` in MathViews.
        var mathColor: NSColor { isDark ? .white : .labelColor }

        var key: String {
            "\(bodyPointSize)|\(bodyWeight.rawValue)|\(inlineMathFontSize)|\(blockMathFontSize)|\(isDark)|\(paragraphSpacing)|\(lineSpacing)"
        }
    }

    // Main-actor-isolated cache: building touches MathImageCache /
    // MTMathUILabel, all of which are @MainActor, so keep the cache here too
    // rather than routing through the non-isolated TextComputationCache.
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256
        return cache
    }()

    static func build(source: String, style: Style) -> NSAttributedString {
        let key = (style.key + "\u{1}" + source) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let built = buildUncached(source: source, style: style)
        cache.setObject(built, forKey: key)
        return built
    }

    private static func buildUncached(source: String, style: Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var isFirst = true
        for segment in MathRichSegmenter.segments(from: source) {
            let spacingBefore: CGFloat = isFirst ? 0 : style.paragraphSpacing
            switch segment {
            case .paragraph(let marker, let headingLevel, let tokens):
                appendParagraph(marker: marker, headingLevel: headingLevel,
                                tokens: tokens, style: style,
                                spacingBefore: spacingBefore, into: result)
            case .block(let latex):
                appendBlock(latex: latex, style: style,
                            spacingBefore: spacingBefore, into: result)
            case .incomplete(let raw):
                appendIncomplete(raw, style: style,
                                 spacingBefore: spacingBefore, into: result)
            }
            isFirst = false
        }
        // Trailing newline would add a phantom line fragment to usedRect.
        while result.length > 0, (result.string as NSString).hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    // MARK: Paragraph

    private static func appendParagraph(marker: String?, headingLevel: Int?,
                                        tokens: [MathRichInlineToken], style: Style,
                                        spacingBefore: CGFloat, into result: NSMutableAttributedString) {
        let baseFont: NSFont = {
            if let level = headingLevel {
                return NSFont.boldSystemFont(ofSize: headingPointSize(level: level))
            }
            return NSFont.systemFont(ofSize: style.bodyPointSize, weight: style.bodyWeight)
        }()
        let markerFont = NSFont.systemFont(ofSize: style.bodyPointSize, weight: style.bodyWeight)

        let para = NSMutableAttributedString()
        if let marker {
            para.append(NSAttributedString(string: marker + "\t",
                                           attributes: [.font: markerFont,
                                                        .foregroundColor: NSColor.secondaryLabelColor]))
        }

        var strong = false
        for token in tokens {
            switch token {
            case .text(let s):
                appendText(s, strong: &strong, baseFont: baseFont, into: para)
            case .inlineMath(let latex, let hadDelimiters):
                appendInlineMath(latex: latex, hadDelimiters: hadDelimiters,
                                 style: style, into: para)
            }
        }
        para.append(NSAttributedString(string: "\n"))

        let pstyle = NSMutableParagraphStyle()
        pstyle.lineSpacing = style.lineSpacing
        pstyle.paragraphSpacingBefore = spacingBefore
        if let marker {
            let markerWidth = (marker as NSString).size(withAttributes: [.font: markerFont]).width
            let leading: CGFloat = 8
            let gap: CGFloat = 8
            let indent = leading + markerWidth + gap
            pstyle.firstLineHeadIndent = leading
            pstyle.headIndent = indent
            pstyle.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        } else if headingLevel != nil {
            // A touch more air above headings.
            pstyle.paragraphSpacingBefore = max(spacingBefore, style.paragraphSpacing)
        }
        para.addAttribute(.paragraphStyle, value: pstyle,
                          range: NSRange(location: 0, length: para.length))
        result.append(para)
    }

    /// Mirrors `WrappedInline.textDisplayRuns`: `**` toggles strong across the
    /// whole run; each chunk is parsed as inline-only markdown.
    private static func appendText(_ text: String, strong: inout Bool,
                                   baseFont: NSFont, into result: NSMutableAttributedString) {
        guard !text.isEmpty else { return }
        var buffer = ""
        var cursor = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            appendMarkdown(buffer, strong: strong, baseFont: baseFont, into: result)
            buffer.removeAll(keepingCapacity: true)
        }

        while cursor < text.endIndex {
            if text[cursor...].hasPrefix("**") {
                flush()
                strong.toggle()
                cursor = text.index(cursor, offsetBy: 2)
            } else {
                buffer.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        flush()
    }

    private static func appendMarkdown(_ s: String, strong: Bool,
                                       baseFont: NSFont, into result: NSMutableAttributedString) {
        let normalized = MathRichSegmenter.normalizeInlineSpacing(s)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: normalized, options: options))
            ?? AttributedString(normalized)

        for run in attributed.runs {
            let substring = String(attributed[run.range].characters)
            guard !substring.isEmpty else { continue }

            var font = baseFont
            let intent = run.inlinePresentationIntent ?? []
            var isCode = false

            if strong || intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                isCode = true
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attrs[.link] = link
            }
            if isCode {
                attrs[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            }
            result.append(NSAttributedString(string: substring, attributes: attrs))
        }
    }

    // MARK: Inline math

    private static func appendInlineMath(latex: String, hadDelimiters: Bool,
                                         style: Style, into result: NSMutableAttributedString) {
        let fontSize = style.inlineMathFontSize
        let insets = MathRenderTuning.inlineInsets(for: fontSize)
        guard let img = renderMathImage(latex: latex, fontSize: fontSize,
                                        isDisplayMode: false, color: style.mathColor,
                                        insets: insets) else {
            result.append(NSAttributedString(string: latex, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: style.bodyPointSize, weight: style.bodyWeight)
            ]))
            return
        }
        let attachment = NSTextAttachment()
        attachment.image = img
        // Lower the glyph so its baseline aligns with the surrounding text.
        let baselineOffset = insets.bottom + fontSize * 0.22
        attachment.bounds = CGRect(x: 0, y: -baselineOffset,
                                   width: img.size.width, height: img.size.height)
        let attaStr = NSMutableAttributedString(attachment: attachment)
        let full = NSRange(location: 0, length: attaStr.length)
        attaStr.addAttribute(.noemaLatexSource,
                             value: hadDelimiters ? "\\(" + latex + "\\)" : latex,
                             range: full)
        attaStr.addAttribute(.noemaLatexRaw, value: latex, range: full)
        result.append(attaStr)
    }

    // MARK: Block math

    private static func appendBlock(latex: String, style: Style,
                                    spacingBefore: CGFloat, into result: NSMutableAttributedString) {
        let fontSize = style.blockMathFontSize
        let insets = MathRenderTuning.blockInsets(for: fontSize)
        let para = NSMutableAttributedString()

        if let img = renderMathImage(latex: latex, fontSize: fontSize,
                                     isDisplayMode: true, color: style.mathColor,
                                     insets: insets) {
            let attachment = MathBlockAttachment()
            attachment.image = img
            let attaStr = NSMutableAttributedString(attachment: attachment)
            let full = NSRange(location: 0, length: attaStr.length)
            attaStr.addAttribute(.noemaLatexSource, value: "$$\n" + latex + "\n$$", range: full)
            attaStr.addAttribute(.noemaLatexRaw, value: latex, range: full)
            attaStr.addAttribute(.noemaLatexBlock, value: true, range: full)
            para.append(attaStr)
        } else {
            para.append(NSAttributedString(string: latex, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: style.bodyPointSize, weight: style.bodyWeight)
            ]))
        }
        para.append(NSAttributedString(string: "\n"))

        let pstyle = NSMutableParagraphStyle()
        pstyle.lineSpacing = style.lineSpacing
        pstyle.paragraphSpacingBefore = spacingBefore
        para.addAttribute(.paragraphStyle, value: pstyle,
                          range: NSRange(location: 0, length: para.length))
        result.append(para)
    }

    private static func appendIncomplete(_ raw: String, style: Style,
                                         spacingBefore: CGFloat, into result: NSMutableAttributedString) {
        let para = NSMutableAttributedString(string: raw + "\n", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: style.bodyPointSize, weight: style.bodyWeight)
        ])
        let pstyle = NSMutableParagraphStyle()
        pstyle.lineSpacing = style.lineSpacing
        pstyle.paragraphSpacingBefore = spacingBefore
        para.addAttribute(.paragraphStyle, value: pstyle,
                          range: NSRange(location: 0, length: para.length))
        result.append(para)
    }

    private static func headingPointSize(level: Int) -> CGFloat {
        switch level {
        case 1: return preferredFontSize(.largeTitle)
        case 2: return preferredFontSize(.title2)
        case 3: return preferredFontSize(.title3)
        default: return preferredFontSize(.headline)
        }
    }
}

// MARK: - Hover "Copy LaTeX" capsule

private struct LatexCopyCapsule: View {
    let latex: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(latex, forType: .string)
            withAnimation(.easeInOut(duration: 0.16)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(Color.accentColor)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy LaTeX")
    }
}

// MARK: - Selectable text view

final class MacLatexTextView: NSTextView {
    var messageHoverCopySuppression: Binding<Bool>?

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverHost: NSHostingView<LatexCopyCapsule>?
    private var hoverCharIndex: Int?

    // MARK: Copy — substitute LaTeX for math attachments

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return false }
        let ranges = selectedRanges.map { $0.rangeValue }
        let text = LatexCopyTransform.plainText(from: storage, ranges: ranges)
        pboard.setString(text, forType: .string)
        return true
    }

    // MARK: Context menu — Copy LaTeX

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        if let latex = latexAttribute(.noemaLatexRaw, at: point) as? String {
            let item = NSMenuItem(title: NSLocalizedString("Copy LaTeX", comment: "Copy raw LaTeX source"),
                                  action: #selector(copyLatexAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = latex
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func copyLatexAction(_ sender: NSMenuItem) {
        guard let latex = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latex, forType: .string)
    }

    // MARK: Hover (block-math copy capsule)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    func teardownHover() {
        clearHover()
    }

    private func updateHover(at point: CGPoint) {
        guard let storage = textStorage, storage.length > 0,
              let charIndex = latexCharacterIndex(at: point),
              (storage.attribute(.noemaLatexBlock, at: charIndex, effectiveRange: nil) as? Bool) == true,
              let latex = storage.attribute(.noemaLatexRaw, at: charIndex, effectiveRange: nil) as? String,
              let rect = boundingRect(forCharacterAt: charIndex) else {
            clearHover()
            return
        }
        showHover(latex: latex, rect: rect, charIndex: charIndex)
    }

    private func showHover(latex: String, rect: CGRect, charIndex: Int) {
        if hoverCharIndex == charIndex, hoverHost != nil { return }
        hoverCharIndex = charIndex
        let capsule = LatexCopyCapsule(latex: latex)
        let host: NSHostingView<LatexCopyCapsule>
        if let existing = hoverHost {
            host = existing
            host.rootView = capsule
        } else {
            host = NSHostingView(rootView: capsule)
            addSubview(host)
            hoverHost = host
        }
        let size = host.fittingSize
        host.frame = CGRect(x: rect.maxX - size.width - 6,
                            y: rect.minY + 6,
                            width: size.width, height: size.height)
        host.isHidden = false
        messageHoverCopySuppression?.wrappedValue = true
    }

    private func clearHover() {
        guard hoverHost != nil || hoverCharIndex != nil else { return }
        hoverCharIndex = nil
        hoverHost?.removeFromSuperview()
        hoverHost = nil
        messageHoverCopySuppression?.wrappedValue = false
    }

    // MARK: Geometry helpers

    private func latexCharacterIndex(at point: CGPoint) -> Int? {
        guard let lm = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = lm.glyphIndex(for: local, in: container)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }
        // Reject points that aren't actually over the glyph (the layout manager
        // snaps to the nearest glyph otherwise).
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1),
                                       actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        guard rect.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return charIndex
    }

    private func latexAttribute(_ key: NSAttributedString.Key, at point: CGPoint) -> Any? {
        guard let storage = textStorage, let charIndex = latexCharacterIndex(at: point) else { return nil }
        return storage.attribute(key, at: charIndex, effectiveRange: nil)
    }

    /// Bounding rect of a single character, in view coordinates.
    private func boundingRect(forCharacterAt charIndex: Int) -> CGRect? {
        guard let lm = layoutManager, let container = textContainer else { return nil }
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1),
                                       actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }
}

// MARK: - SwiftUI bridge

struct MacSelectableMathText: NSViewRepresentable, Equatable {
    let source: String
    let bodyPointSize: CGFloat
    let bodyWeight: NSFont.Weight
    let blockMathFontSize: CGFloat
    let isDark: Bool
    var messageHoverCopySuppression: Binding<Bool>?

    static func == (lhs: MacSelectableMathText, rhs: MacSelectableMathText) -> Bool {
        lhs.source == rhs.source
            && lhs.bodyPointSize == rhs.bodyPointSize
            && lhs.bodyWeight == rhs.bodyWeight
            && lhs.blockMathFontSize == rhs.blockMathFontSize
            && lhs.isDark == rhs.isDark
    }

    private var style: MacMathAttributedStringBuilder.Style {
        MacMathAttributedStringBuilder.Style(
            bodyPointSize: bodyPointSize,
            bodyWeight: bodyWeight,
            inlineMathFontSize: preferredFontSize(.body) * 1.4,
            blockMathFontSize: blockMathFontSize,
            isDark: isDark
        )
    }

    private var buildKey: String { style.key + "\u{1}" + source }

    final class Coordinator {
        var buildKey = ""
        var sizeCache: [String: CGSize] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MacLatexTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: CGFloat(480), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = MacLatexTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.focusRingType = .none
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.displaysLinkToolTips = true
        textView.messageHoverCopySuppression = messageHoverCopySuppression

        let attributed = MacMathAttributedStringBuilder.build(source: source, style: style)
        textView.textStorage?.setAttributedString(attributed)
        context.coordinator.buildKey = buildKey
        applyAppearance(to: textView)
        return textView
    }

    func updateNSView(_ nsView: MacLatexTextView, context: Context) {
        nsView.messageHoverCopySuppression = messageHoverCopySuppression
        applyAppearance(to: nsView)

        let newKey = buildKey
        guard context.coordinator.buildKey != newKey else { return }

        let saved = nsView.selectedRanges
        let attributed = MacMathAttributedStringBuilder.build(source: source, style: style)
        nsView.textStorage?.setAttributedString(attributed)
        context.coordinator.buildKey = newKey
        context.coordinator.sizeCache.removeAll()

        // Streaming swaps the whole string ~30 Hz; keep an in-progress selection.
        let length = nsView.textStorage?.length ?? 0
        let clamped: [NSValue] = saved.compactMap { value in
            let range = value.rangeValue
            guard range.location <= length else { return nil }
            return NSValue(range: NSRange(location: range.location,
                                          length: min(range.length, length - range.location)))
        }
        if !clamped.isEmpty { nsView.selectedRanges = clamped }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacLatexTextView,
                      context: Context) -> CGSize? {
        let proposed = proposal.width
        let width: CGFloat = {
            guard let proposed, proposed.isFinite, proposed > 0 else { return 480 }
            return proposed
        }()
        let key = "\(buildKey)#\(Int(width.rounded()))"
        if let cached = context.coordinator.sizeCache[key] { return cached }

        guard let lm = nsView.layoutManager, let container = nsView.textContainer else {
            return nil
        }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        let result = CGSize(width: min(ceil(used.width), width), height: ceil(used.height))
        context.coordinator.sizeCache[key] = result
        return result
    }

    static func dismantleNSView(_ nsView: MacLatexTextView, coordinator: Coordinator) {
        nsView.teardownHover()
    }

    private func applyAppearance(to textView: MacLatexTextView) {
        let name: NSAppearance.Name = isDark ? .darkAqua : .aqua
        if textView.appearance?.name != name {
            textView.appearance = NSAppearance(named: name)
        }
    }
}
#endif
