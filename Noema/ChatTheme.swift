import SwiftUI

@MainActor
enum ChatTheme {
    // MARK: - Layout

    /// Maximum readable width of the conversation column.
    static let conversationMaxWidth: CGFloat = 760
    /// Maximum width of a user bubble inside the conversation column.
    static let userBubbleMaxWidth: CGFloat = 520
    /// Maximum width of the centered composer on the new-chat canvas.
    static let heroComposerMaxWidth: CGFloat = 660
    /// Horizontal breathing room around the conversation column (macOS).
    static let conversationHorizontalInset: CGFloat = 28

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24

    // MARK: - Radii

    static let controlRadius: CGFloat = 10
    static let surfaceRadius: CGFloat = 14
    static let composerRadius: CGFloat = 18
    static let bubbleRadius: CGFloat = 16

    // MARK: - Strokes & surfaces

    /// Hairline border for cards and capsules.
    static var hairline: Color { Color.primary.opacity(0.08) }
    /// Slightly stronger border for focused/keyed surfaces.
    static var hairlineStrong: Color { Color.primary.opacity(0.14) }
    /// Quiet fill for secondary chips, rows, and icon wells.
    static var quietSurface: Color { Color.primary.opacity(0.05) }
    /// Hover state for rows and quiet buttons.
    static var hoverSurface: Color { Color.primary.opacity(0.04) }
    /// Selection state for sidebar rows — pale, low-contrast.
    static var selectionSurface: Color { Color.primary.opacity(0.07) }

    /// Solid raised surface (composer, popovers, cards).
    static var cardSurface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #elseif os(visionOS)
        Color.clear
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    /// User bubble fill — soft, low-saturation accent wash.
    static func userBubble(_ colorScheme: ColorScheme) -> Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.10)
    }

    // MARK: - Status tints

    static let readyTint: Color = .green
    static let busyTint: Color = .orange
    static let idleTint: Color = Color.secondary.opacity(0.5)
}

// MARK: - Motion

/// Shared, reduce-motion-aware animation tokens for page and submenu transitions.
/// Kept lightweight (spring/opacity/scale) so transitions stay smooth even while
/// the chat or explore content underneath is rendering.
enum AppMotion {
    /// Switching between the top-level pages (chat / stored / explore / settings).
    static var page: Animation { .spring(response: 0.40, dampingFraction: 0.86) }
    /// Pushing / popping a settings submenu.
    static var submenu: Animation { .spring(response: 0.36, dampingFraction: 0.88) }
    /// Quick micro-interactions (chips, disclosure rows).
    static var snappy: Animation { .snappy(duration: 0.26, extraBounce: 0.02) }

    /// Returns `animation` unless Reduce Motion is enabled, in which case the
    /// change applies instantly. Callers pass `\.accessibilityReduceMotion`.
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Gentle cross-page transition: fade + a hair of scale. Direction-agnostic
    /// so it reads well regardless of which page you came from, and cheap enough
    /// not to stutter when heavy content mounts behind it.
    static var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
            removal: .opacity
        )
    }
}

// MARK: - Reusable components

/// Low-contrast metadata line under messages (timestamp, generation stats).
struct ChatMetadataText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

/// Quiet capsule badge used for per-message annotations (privacy, evidence).
struct ChatQuietBadge: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint.opacity(0.85))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.08)))
        .overlay(Capsule().stroke(tint.opacity(0.16), lineWidth: 0.5))
    }
}

#if os(macOS)
/// Quiet square icon button used in the macOS chat toolbar and composer.
struct ChatToolbarIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    var isActive: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive
                              ? Color.accentColor.opacity(0.12)
                              : (hovering ? ChatTheme.hoverSurface : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
#endif
