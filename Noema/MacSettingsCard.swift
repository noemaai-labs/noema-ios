import SwiftUI

#if os(macOS)

/// Scrolling column of cards on the window background — the outer scaffold for a
/// Mac settings drill-in. The presenting sheet governs the window size; add an
/// explicit `.frame(minWidth:minHeight:)` only when hosting outside
/// `macSettingsSheet`.
struct MacSettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.windowBackground.ignoresSafeArea())
    }
}

/// A bordered section card: `IndustrialSectionHeader` over its rows.
struct MacSettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    var detail: String?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IndustrialSectionHeader(title, detail: detail)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Row scaffold shared by every row type: an optional leading hairline plus the
/// standard vertical padding. Build bespoke rows on top of this to keep the
/// separators and rhythm consistent with the built-in rows.
struct MacSettingsRowContainer<Content: View>: View {
    var divider: Bool = true
    @ViewBuilder let content: () -> Content

    init(divider: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.divider = divider
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            content()
                .padding(.vertical, 8)
        }
    }
}

/// CAPS mono label on the left, mono value on the right.
struct MacSettingsKeyValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var divider: Bool = true

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text(verbatim: value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Icon + CAPS label on the left, an `IndustrialBadge` status pill on the right.
struct MacSettingsStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    var systemImage: String? = nil
    var tint: Color = .secondary
    var divider: Bool = true

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .frame(width: 18)
                }
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                IndustrialBadge(verbatim: value, tint: tint, dot: true)
            }
        }
    }
}

/// CAPS label on the left, an arbitrary control (Picker / Toggle / Stepper /
/// TextField) on the right. Give the control `.labelsHidden()` and, where it
/// helps, an IndustrialControls style (`.industrialField()`,
/// `IndustrialToggleStyle()`, `.buttonStyle(.industrial(...))`).
struct MacSettingsControlRow<Control: View>: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var divider: Bool = true
    @ViewBuilder let control: () -> Control

    init(_ title: LocalizedStringKey, systemImage: String? = nil, divider: Bool = true, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.systemImage = systemImage
        self.divider = divider
        self.control = control
    }

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .frame(width: 18)
                }
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                control()
            }
        }
    }
}

/// A muted mono note / empty-state line.
struct MacSettingsNoteRow: View {
    let text: LocalizedStringKey
    var divider: Bool = true

    init(_ text: LocalizedStringKey, divider: Bool = true) {
        self.text = text
        self.divider = divider
    }

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A left-aligned row of buttons (industrial buttons hug their content).
struct MacSettingsActionRow<Content: View>: View {
    var divider: Bool = true
    @ViewBuilder let content: () -> Content

    init(divider: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.divider = divider
        self.content = content
    }

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 0)
            }
        }
    }
}

#endif
