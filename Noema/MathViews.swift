import SwiftUI
import SwiftMath
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor struct MathRenderTuning {
    // Provide safe insets to avoid top/bottom glyph clipping. Some SwiftMath
    // layouts (integrals with limits, tall fractions) can extend to the
    // very edge of their measured bounds on iOS, so we slightly over-pad.
    static func inlineInsets(for fontSize: CGFloat) -> UIEdgeInsets {
        let pad = max(4, ceil(fontSize * 0.20))
        return UIEdgeInsets(top: pad, left: 0, bottom: pad, right: 0)
    }

    static func blockInsets(for fontSize: CGFloat) -> UIEdgeInsets {
        let pad = max(6, ceil(fontSize * 0.22))
        return UIEdgeInsets(top: pad, left: 0, bottom: pad, right: 0)
    }
}

/// Shared metrics for the border drawn around `\boxed{...}` math. SwiftMath
/// cannot typeset the box itself, so hosts draw it: SwiftUI overlays on
/// iOS/visionOS, composited into the attachment image on macOS.
enum MathBoxStyle {
    static let lineWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 5
    static let strokeOpacity: CGFloat = 0.35
    static func padding(for fontSize: CGFloat) -> (h: CGFloat, v: CGFloat) {
        (max(5, ceil(fontSize * 0.30)), max(3, ceil(fontSize * 0.18)))
    }
}

/// Draws the `\boxed{...}` border around an already-rendered math view.
private struct MathBoxBorder: ViewModifier {
    let enabled: Bool
    let fontSize: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            let pad = MathBoxStyle.padding(for: fontSize)
            content
                .padding(.horizontal, pad.h)
                .padding(.vertical, pad.v)
                .overlay(
                    RoundedRectangle(cornerRadius: MathBoxStyle.cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(MathBoxStyle.strokeOpacity),
                                lineWidth: MathBoxStyle.lineWidth)
                )
        } else {
            content
        }
    }
}

/// A rendered math bitmap plus the metric hosts need to sit it on the text
/// baseline: the distance from the image's bottom edge up to the typeset
/// baseline. Derived from the real per-expression descent, so `m` and `y_b`
/// both align exactly instead of sharing one approximate offset.
struct RenderedMathImage {
    let image: UIImage
    let baselineFromBottom: CGFloat
}

@MainActor final class MathImageCache {
    @MainActor static let shared = MathImageCache()
    private final class Entry {
        let rendered: RenderedMathImage
        init(_ rendered: RenderedMathImage) { self.rendered = rendered }
    }
    private let cache = NSCache<NSString, Entry>()
    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
    }
    func rendered(for key: String) -> RenderedMathImage? {
        cache.object(forKey: key as NSString)?.rendered
    }
    func insert(_ rendered: RenderedMathImage, for key: String) {
        let image = rendered.image
        let cost = Int(image.size.width * image.size.height * (image.scale * image.scale))
        cache.setObject(Entry(rendered), forKey: key as NSString, cost: max(cost, 1))
    }
}

private struct BlockMathAvailableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private func resolvedMathColor(for colorScheme: ColorScheme) -> UIColor {
#if os(macOS)
    // Prefer explicit static colors so caching stays deterministic per scheme.
    return colorScheme == .dark ? UIColor.white : UIColor.label
#else
    let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    let trait = UITraitCollection(userInterfaceStyle: style)
    return UIColor.label.resolvedColor(with: trait)
#endif
}

private func colorSignature(for color: UIColor) -> String {
#if os(macOS)
    let converted = color.usingColorSpace(.sRGB) ?? color
    let components = converted.cgColor.components ?? []
#else
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)
    let converted = color.cgColor.converted(to: srgb ?? color.cgColor.colorSpace ?? CGColorSpaceCreateDeviceRGB(), intent: .relativeColorimetric, options: nil) ?? color.cgColor
    let components = converted.components ?? []
#endif
    let rounded = components.map { String(format: "%.4f", Double($0)) }.joined(separator: "|")
#if os(macOS)
    let spaceName = converted.cgColor.colorSpace?.name as String? ?? "cs"
#else
    let spaceName = converted.colorSpace?.name as String? ?? "cs"
#endif
    return "\(spaceName)|\(rounded)"
}

/// SwiftMath centers the glyphs inside the (inset) content box, so the
/// baseline's distance from the image bottom depends on the expression's own
/// ascent/descent. This mirrors the positioning in `MTMathUILabel`/`MathImage`
/// (`textY = (availableHeight - height)/2 + descent + insets.bottom`, with
/// `height` clamped to `fontSize/2` for tiny spans).
private func mathBaselineFromBottom(ascent: CGFloat, descent: CGFloat,
                                    imageHeight: CGFloat, fontSize: CGFloat,
                                    insets: UIEdgeInsets) -> CGFloat {
    let availableHeight = imageHeight - insets.top - insets.bottom
    var glyphHeight = ascent + descent
    if glyphHeight < fontSize / 2 { glyphHeight = fontSize / 2 }
    return (availableHeight - glyphHeight) / 2 + descent + insets.bottom
}

@MainActor func renderMathImage(latex: String, fontSize: CGFloat, isDisplayMode: Bool, color: UIColor, insets: UIEdgeInsets = .zero) -> RenderedMathImage? {
    // Cache key includes mode, font size, insets and a resolved color signature so
    // light/dark appearance swaps never reuse stale glyph images.
    let insetKey = "t:\(Int(insets.top))|l:\(Int(insets.left))|b:\(Int(insets.bottom))|r:\(Int(insets.right))"
    let colorKey = colorSignature(for: color)
    // v4 switches every platform to SwiftMath's unconstrained MathImage path.
    // The old macOS MTMathUILabel snapshot measured the formula without a
    // width constraint, then laid it out again inside a finite-width view. The
    // second pass could activate SwiftMath's line fitter and push the tail of
    // an equation onto another row while the bitmap still had the first-pass
    // height, clipping expressions such as long energy equations.
    let renderVersion = "v4-unconstrained"
    let key = "\(renderVersion):\(isDisplayMode ? "D" : "I"):\(Int(fontSize)):\(colorKey):\(insetKey):\(latex)"
    if let hit = MathImageCache.shared.rendered(for: key) { return hit }

    // SwiftMath's MathImage typesets with maxWidth == 0 (explicitly meaning
    // unconstrained), creates the bitmap from that same display list, and
    // reports its ascent/descent. Keeping measurement and drawing in one pass
    // prevents display math from being internally reflowed and then cropped.
    // The enclosing chat renderer remains responsible for fitting an oversized
    // block attachment to the available transcript width.
    var img = MathImage(
        latex: latex,
        fontSize: fontSize,
        textColor: color,
        labelMode: isDisplayMode ? .display : .text,
        textAlignment: .left
    )
    img.contentInsets = insets
    img.font = .termesFont

    let (_, rendered, layout) = img.asImage()
    guard let rendered, let layout else { return nil }
    let baseline = mathBaselineFromBottom(ascent: layout.ascent, descent: layout.descent,
                                          imageHeight: rendered.size.height, fontSize: fontSize,
                                          insets: insets)
    let result = RenderedMathImage(image: rendered, baselineFromBottom: baseline)
    MathImageCache.shared.insert(result, for: key)
    return result
}

struct InlineMathView: View {
    let latex: String
    var fontSize: CGFloat = preferredFontSize(.body)
    var useCache: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    private var uiColor: UIColor { resolvedMathColor(for: colorScheme) }
    private var inlineInsets: UIEdgeInsets { MathRenderTuning.inlineInsets(for: fontSize) }
    /// Approximation for the live-label path, where no typeset metrics are
    /// available. The cached-image path uses the exact per-expression baseline.
    private var heuristicBaseline: CGFloat { inlineInsets.bottom + fontSize * 0.22 }

    var body: some View {
        let (inner, boxed) = MathTokenizer.unwrapBoxed(latex)
        let rendered = useCache
            ? renderMathImage(latex: inner, fontSize: fontSize, isDisplayMode: false, color: uiColor, insets: inlineInsets)
            : nil
        // The box padding extends the view below the glyphs, so the baseline
        // moves up by the same amount relative to the (padded) bottom edge.
        let offset = (rendered?.baselineFromBottom ?? heuristicBaseline)
            + (boxed ? MathBoxStyle.padding(for: fontSize).v : 0)
        content(rendered: rendered, inner: inner, boxed: boxed)
            .alignmentGuide(.firstTextBaseline) { d in
                d[VerticalAlignment.bottom] - offset
            }
            .accessibilityLabel(Text(plainAccessibilityLabel(from: inner)))
    }

    @ViewBuilder
    private func content(rendered: RenderedMathImage?, inner: String, boxed: Bool) -> some View {
        if let rendered {
            cachedMathImage(rendered.image)
                .modifier(MathBoxBorder(enabled: boxed, fontSize: fontSize))
        } else {
            // The image renderer and live label use the same SwiftMath parser.
            // If parsing failed, the live label can measure as an empty view and
            // silently hide the model's formula. Keep the source visible so an
            // unsupported command never turns into a blank line.
            Text(verbatim: latex)
                .font(.system(size: fontSize))
                .foregroundStyle(Color.red)
                .modifier(MathBoxBorder(enabled: boxed, fontSize: fontSize))
        }
    }

    private func cachedMathImage(_ img: UIImage) -> some View {
        // Render at the label's natural size (which already reflects fontSize and contentInsets)
        // so tall formulas can naturally expand the line box instead of being clipped.
        let size = img.size
        let base = Image(platformImage: img)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .renderingMode(.original)
#if canImport(UIKit)
            .flipsForRightToLeftLayoutDirection(false)
#endif

        return base
            .frame(width: size.width, height: size.height, alignment: .leading)
    }
}

#if os(macOS)
private struct InlineMathUILabel: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let color: UIColor
    let insets: UIEdgeInsets

    func makeNSView(context: Context) -> MTMathUILabel {
        let v = MTMathUILabel()
        v.labelMode = .text
        v.textAlignment = .left
        v.fontSize = fontSize
        v.textColor = color
        v.contentInsets = insets
        v.font = MTFontManager().termesFont(withSize: fontSize)
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.latex = latex
        return v
    }

    func updateNSView(_ nsView: MTMathUILabel, context: Context) {
        nsView.fontSize = fontSize
        nsView.textColor = color
        nsView.contentInsets = insets
        nsView.latex = latex
    }
}
#else
private struct InlineMathUILabel: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let color: UIColor
    let insets: UIEdgeInsets

    func makeUIView(context: Context) -> MTMathUILabel {
        let v = MTMathUILabel()
        v.labelMode = .text
        v.textAlignment = .left
#if canImport(UIKit)
        v.semanticContentAttribute = .forceLeftToRight
#endif
        v.fontSize = fontSize
        v.textColor = color
        v.contentInsets = insets
        v.font = MTFontManager().termesFont(withSize: fontSize)
        // Ensure the label reports its intrinsic width so it stays inline
        // instead of expanding to fill the row and forcing a line break.
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.latex = latex
        return v
    }
    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        uiView.fontSize = fontSize
        uiView.textColor = color
        uiView.contentInsets = insets
        uiView.latex = latex
    }
}
#endif

struct BlockMathView: View {
    let latex: String
    var fontSize: CGFloat = preferredFontSize(.title3)
    var useCache: Bool = true
    var widthBehavior: BlockMathWidthBehavior = .intrinsic
    @Environment(\.colorScheme) private var colorScheme
    private var uiColor: UIColor { resolvedMathColor(for: colorScheme) }
    private var blockInsets: UIEdgeInsets { MathRenderTuning.blockInsets(for: fontSize) }
    @State private var availableWidth: CGFloat = 1

    // Added helper to compute display size preserving intrinsic aspect ratio without expanding to full width.
    private func displaySize(for image: UIImage) -> CGSize {
        let height = fontSize * 1.2 // slightly larger than surrounding text for display math
        guard image.size.height > 0 else { return CGSize(width: height, height: height) }
        let aspect = image.size.width / image.size.height
        return CGSize(width: height * aspect, height: height)
    }

    var body: some View {
        let (inner, boxed) = MathTokenizer.unwrapBoxed(latex)
        Group { content(inner: inner, boxed: boxed) }
            .accessibilityLabel(Text(plainAccessibilityLabel(from: inner)))
            // Align leading without forcing full-width occupation and avoid extra vertical padding
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.top] }
            .padding(.vertical, 0)
    }

    @ViewBuilder
    private func content(inner: String, boxed: Bool) -> some View {
        switch widthBehavior {
        case .intrinsic:
            if useCache, let rendered = renderMathImage(latex: inner, fontSize: fontSize, isDisplayMode: true, color: uiColor, insets: blockInsets) {
                cachedMathImage(rendered.image)
                    .modifier(MathBoxBorder(enabled: boxed, fontSize: fontSize))
            } else {
                liveMathLabel(inner, preferredMaxLayoutWidth: nil)
                    .modifier(MathBoxBorder(enabled: boxed, fontSize: fontSize))
            }
        case .wrapThenScroll:
            wrappedScrollableMathLabel(inner: inner, boxed: boxed)
        }
    }

    private func liveMathLabel(_ inner: String, preferredMaxLayoutWidth: CGFloat?) -> some View {
        BlockMathUILabel(
            latex: inner,
            fontSize: fontSize,
            color: uiColor,
            insets: blockInsets,
            preferredMaxLayoutWidth: preferredMaxLayoutWidth
        )
    }

    private func wrappedScrollableMathLabel(inner: String, boxed: Bool) -> some View {
        // Wrap a bit narrower when boxed so the border still fits the bubble.
        let boxPadH = boxed ? MathBoxStyle.padding(for: fontSize).h * 2 : 0
        return ScrollView(.horizontal, showsIndicators: false) {
            liveMathLabel(inner, preferredMaxLayoutWidth: max(availableWidth - boxPadH, 1))
                .modifier(MathBoxBorder(enabled: boxed, fontSize: fontSize))
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: availableWidth, alignment: .leading)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: BlockMathAvailableWidthKey.self, value: max(proxy.size.width, 1))
            }
        }
        .onPreferenceChange(BlockMathAvailableWidthKey.self) { width in
            availableWidth = max(width, 1)
        }
    }

    private func cachedMathImage(_ img: UIImage) -> some View {
        let size = displaySize(for: img)
        let base = Image(platformImage: img)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .renderingMode(.original)
#if canImport(UIKit)
            .flipsForRightToLeftLayoutDirection(false)
#endif

        return base
            .frame(width: size.width, height: size.height, alignment: .leading)
    }
}

private func plainAccessibilityLabel(from latex: String) -> String {
    // Simple fallback: strip common TeX control chars for a readable label
    var s = latex
    let patterns: [String] = ["\\\\", "\\[", "\\]", "\\(", "\\)", "{", "}", "$", "^", "_", "\\\nfrac", "\\sum", "\\int", "\\cdot"]
    for p in patterns { s = s.replacingOccurrences(of: p, with: " ") }
    s = s.replacingOccurrences(of: "  ", with: " ")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

#if os(macOS)
private struct BlockMathUILabel: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let color: UIColor
    let insets: UIEdgeInsets
    let preferredMaxLayoutWidth: CGFloat?

    func makeNSView(context: Context) -> MTMathUILabel {
        let v = MTMathUILabel()
        v.labelMode = .display
        v.textAlignment = .left
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.fontSize = fontSize
        v.textColor = color
        v.contentInsets = insets
        v.font = MTFontManager().termesFont(withSize: fontSize)
        v.preferredMaxLayoutWidth = preferredMaxLayoutWidth ?? 0
        v.latex = latex
        return v
    }
    func updateNSView(_ nsView: MTMathUILabel, context: Context) {
        nsView.fontSize = fontSize
        nsView.textColor = color
        nsView.contentInsets = insets
        nsView.preferredMaxLayoutWidth = preferredMaxLayoutWidth ?? 0
        nsView.latex = latex
    }

    static func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        if let width = proposal.width, width.isFinite, width > 0 {
            nsView.preferredMaxLayoutWidth = width
            return nsView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        nsView.preferredMaxLayoutWidth = 0
        let size = nsView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}
#else
private struct BlockMathUILabel: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let color: UIColor
    let insets: UIEdgeInsets
    let preferredMaxLayoutWidth: CGFloat?

    func makeUIView(context: Context) -> MTMathUILabel {
        let v = MTMathUILabel()
        v.labelMode = .display
        v.textAlignment = .left
#if canImport(UIKit)
        v.semanticContentAttribute = .forceLeftToRight
#endif
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.fontSize = fontSize
        v.textColor = color
        v.contentInsets = insets
        v.font = MTFontManager().termesFont(withSize: fontSize)
        v.preferredMaxLayoutWidth = preferredMaxLayoutWidth ?? 0
        v.latex = latex
        return v
    }
    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        uiView.fontSize = fontSize
        uiView.textColor = color
        uiView.contentInsets = insets
        uiView.preferredMaxLayoutWidth = preferredMaxLayoutWidth ?? 0
        uiView.latex = latex
    }

    static func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        if let width = proposal.width, width.isFinite, width > 0 {
            uiView.preferredMaxLayoutWidth = width
            return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        uiView.preferredMaxLayoutWidth = 0
        let size = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}
#endif
