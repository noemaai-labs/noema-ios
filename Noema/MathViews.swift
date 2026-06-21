// MathViews.swift
//  MathViews.swift
//  Noema
//
//  SwiftUI bridges for SwiftMath (MTMathUILabel) with optional image caching
//  for performance. Provides inline and block math rendering with baseline
//  alignment and accessibility labels.

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

@MainActor final class MathImageCache {
    @MainActor static let shared = MathImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
    }
    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    func insert(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * (image.scale * image.scale))
        cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
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

@MainActor func renderMathImage(latex: String, fontSize: CGFloat, isDisplayMode: Bool, color: UIColor, insets: UIEdgeInsets = .zero) -> UIImage? {
    // Cache key includes mode, font size, insets and a resolved color signature so
    // light/dark appearance swaps never reuse stale glyph images.
    let insetKey = "t:\(Int(insets.top))|l:\(Int(insets.left))|b:\(Int(insets.bottom))|r:\(Int(insets.right))"
    let colorKey = colorSignature(for: color)
    let renderVersion = "v2"
    let key = "\(renderVersion):\(isDisplayMode ? "D" : "I"):\(Int(fontSize)):\(colorKey):\(insetKey):\(latex)"
    if let img = MathImageCache.shared.image(for: key) { return img }

#if os(macOS)
    let label = MTMathUILabel()
    label.latex = latex
    label.labelMode = isDisplayMode ? MTMathUILabelMode.display : MTMathUILabelMode.text
    label.textAlignment = .left
    label.fontSize = fontSize
    label.textColor = color
    label.contentInsets = insets
    label.font = MTFontManager().termesFont(withSize: fontSize)

    let fittingSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    let size = CGSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
    guard size.width > 0, size.height > 0 else { return nil }

    let view = MTMathUILabel(frame: CGRect(origin: .zero, size: size))
    view.latex = latex
    view.labelMode = isDisplayMode ? MTMathUILabelMode.display : MTMathUILabelMode.text
    view.fontSize = fontSize
    view.textColor = color
    view.contentInsets = insets
    view.font = MTFontManager().termesFont(withSize: fontSize)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    MathImageCache.shared.insert(image, for: key)
    return image
#else
    // SwiftMath's MTMathImage renders via the internal display list and applies
    // the correct CoreText coordinate transforms, avoiding flipped superscripts
    // that can occur when snapshotting MTMathUILabel offscreen.
    let img = MTMathImage(
        latex: latex,
        fontSize: fontSize,
        textColor: color,
        labelMode: isDisplayMode ? .display : .text,
        textAlignment: .left
    )
    img.contentInsets = insets
    img.font = MTFontManager().termesFont(withSize: fontSize)

    let (_, rendered) = img.asImage()
    guard let rendered else { return nil }
    MathImageCache.shared.insert(rendered, for: key)
    return rendered
#endif
}

struct InlineMathView: View {
    let latex: String
    var fontSize: CGFloat = preferredFontSize(.body)
    var useCache: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    private var uiColor: UIColor { resolvedMathColor(for: colorScheme) }
    private var inlineInsets: UIEdgeInsets { MathRenderTuning.inlineInsets(for: fontSize) }
    private var baselineOffset: CGFloat { inlineInsets.bottom + fontSize * 0.22 }

    var body: some View {
        if useCache, let img = renderMathImage(latex: latex, fontSize: fontSize, isDisplayMode: false, color: uiColor, insets: inlineInsets) {
            cachedMathImage(img)
        } else {
            liveMathLabel
        }
    }

    private var liveMathLabel: some View {
        InlineMathUILabel(latex: latex, fontSize: fontSize, color: uiColor, insets: inlineInsets)
            .alignmentGuide(.firstTextBaseline) { d in
                d[VerticalAlignment.bottom] - baselineOffset
            }
            .accessibilityLabel(Text(plainAccessibilityLabel(from: latex)))
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
            // Approximate baseline alignment; keep a small descent tweak.
            .alignmentGuide(.firstTextBaseline) { d in
                d[VerticalAlignment.bottom] - baselineOffset
            }
            .accessibilityLabel(Text(plainAccessibilityLabel(from: latex)))
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
        content
            // Align leading without forcing full-width occupation and avoid extra vertical padding
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.top] }
            .padding(.vertical, 0)
    }

    @ViewBuilder
    private var content: some View {
        switch widthBehavior {
        case .intrinsic:
            if useCache, let img = renderMathImage(latex: latex, fontSize: fontSize, isDisplayMode: true, color: uiColor, insets: blockInsets) {
                cachedMathImage(img)
            } else {
                liveMathLabel(preferredMaxLayoutWidth: nil)
            }
        case .wrapThenScroll:
            wrappedScrollableMathLabel
        }
    }

    private func liveMathLabel(preferredMaxLayoutWidth: CGFloat?) -> some View {
        BlockMathUILabel(
            latex: latex,
            fontSize: fontSize,
            color: uiColor,
            insets: blockInsets,
            preferredMaxLayoutWidth: preferredMaxLayoutWidth
        )
            .accessibilityLabel(Text(plainAccessibilityLabel(from: latex)))
    }

    private var wrappedScrollableMathLabel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            liveMathLabel(preferredMaxLayoutWidth: availableWidth)
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
            .accessibilityLabel(Text(plainAccessibilityLabel(from: latex)))
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
