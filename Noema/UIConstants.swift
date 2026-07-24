import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct UIConstants {
    // Feature flag to show/hide multimodal UI (images, vision badges, type picker)
    static let showMultimodalUI: Bool = true

    private static var isPadInterface: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    static var cornerRadius: CGFloat {
        isPadInterface ? 16 : 12
    }

    static var smallCornerRadius: CGFloat {
        isPadInterface ? 12 : 8
    }

    static var largeCornerRadius: CGFloat {
        isPadInterface ? 20 : 15
    }

    static var extraLargeCornerRadius: CGFloat {
        isPadInterface ? 24 : 18
    }

    static var defaultPadding: CGFloat {
        isPadInterface ? 24 : 20 // Increased for "generous negative space"
    }

    static var compactPadding: CGFloat {
        isPadInterface ? 16 : 12
    }

    static var widePadding: CGFloat {
        isPadInterface ? 48 : 32 // Significantly increased for margins
    }

    static func adaptiveComposerCornerRadius(
        currentHeight: CGFloat,
        collapsedHeight: CGFloat,
        expandedHeight: CGFloat,
        expandedRadius: CGFloat
    ) -> CGFloat {
        let minHeight = Swift.min(collapsedHeight, expandedHeight)
        let maxHeight = Swift.max(collapsedHeight, expandedHeight)
        let clampedHeight = currentHeight.clamped(to: minHeight...maxHeight)
        let progress = (clampedHeight - collapsedHeight) / Swift.max(expandedHeight - collapsedHeight, 1)
        let collapsedRadius = collapsedHeight / 2
        return collapsedRadius + ((expandedRadius - collapsedRadius) * progress)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension View {
    func adaptiveCornerRadius(_ size: AdaptiveCornerSize = .medium) -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: size.value))
    }
}

@MainActor
enum AdaptiveCornerSize {
    case small
    case medium
    case large
    case extraLarge
    
    var value: CGFloat {
        switch self {
        case .small:
            return UIConstants.smallCornerRadius
        case .medium:
            return UIConstants.cornerRadius
        case .large:
            return UIConstants.largeCornerRadius
        case .extraLarge:
            return UIConstants.extraLargeCornerRadius
        }
    }
}

extension View {
    @ViewBuilder
    func glassifyIfAvailable<S: Shape>(in shape: S) -> some View {
        #if os(visionOS)
        self.background(.regularMaterial, in: shape)
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
        #elseif os(macOS)
        // Use a lightweight semi-transparent background on macOS for better scroll performance.
        // Material blur effects (.ultraThinMaterial) are expensive during scrolling.
        self.background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: shape)
        #endif
    }
}

extension View {
    /// Ensures the system hover tint matches the view's actual rounded shape on visionOS.
    @ViewBuilder
    func visionHoverHighlight(cornerRadius: CGFloat) -> some View {
        #if os(visionOS)
        self
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

@MainActor
struct AppTheme {
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var sidebarBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor).opacity(0.3)
        #elseif os(visionOS)
        Color.clear
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    static var cardBackground: Material {
        #if os(macOS)
        .ultraThinMaterial
        #elseif os(visionOS)
        .regular
        #else
        .regularMaterial
        #endif
    }
    
    static var cardFill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor).opacity(0.4)
        #elseif os(visionOS)
        Color.black.opacity(0.1)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    static var cardStroke: Color {
        Color.primary.opacity(0.06)
    }
    
    static var separator: Color {
        Color.primary.opacity(0.08)
    }

    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 24
    
    struct HighContrast {
        static var lightBackground: Color { Color(white: 0.98) }
        static var lightText: Color { Color(white: 0.1) }
        static var darkBackground: Color { Color(white: 0.05) }
        static var darkText: Color { Color.white }
    }

    // Primary text colors tuned for the high-contrast palette.
    static var text: Color {
        Color.primary
    }

    static var secondaryText: Color {
        Color.primary.opacity(0.6)
    }

    static var tertiaryText: Color {
        Color.primary.opacity(0.4)
    }
}

@MainActor
struct FontTheme {
    // Default sizes chosen for the "luxury minimalist" aesthetic.
    static var heading: Font { heading(size: 26) }
    static var largeTitle: Font { heading(size: 30) }
    static var body: Font { body(size: 15) }
    static var subheadline: Font { body(size: 14).weight(.medium) }
    static var caption: Font { caption(size: 12) }

    static func heading(size: CGFloat) -> Font {
        // System Sans-serif for an industrial minimalist look
        .system(size: size, weight: .semibold, design: .default)
    }
    
    static func body(size: CGFloat) -> Font {
        // System Sans-serif (SF Pro) for neutral, readable text
        .system(size: size, weight: .regular, design: .default)
    }
    
    static func caption(size: CGFloat) -> Font {
        // Uppercase, tracked out
        .system(size: size, weight: .medium, design: .default)
    }
}
