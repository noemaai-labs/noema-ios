import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A reusable “liquid glass” pill background for inputs and controls.
/// On macOS it resolves to a flat industrial panel instead of glass.
struct GlassPill: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = UIConstants.extraLargeCornerRadius) {
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
#if os(macOS)
        let shape = RoundedRectangle(cornerRadius: min(cornerRadius, 10), style: .continuous)
        content
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(
                shape
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            )
#else
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .glassifyIfAvailable(in: shape)
#if os(iOS)
            .overlay(
                shape
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.04 : 0.12))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.34), lineWidth: 0.8)
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 14, x: 0, y: 8)
#else
            .overlay(
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.7),
                                Color.accentColor.opacity(0.4),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
#endif
#endif
    }
}

extension View {
    /// Applies a pill-shaped, frosted glass background suitable for an input field.
    func glassPill(cornerRadius: CGFloat = UIConstants.extraLargeCornerRadius) -> some View {
        modifier(GlassPill(cornerRadius: cornerRadius))
    }
}
