import SwiftUI

enum IndustrialButtonRole {
    case prominent
    case tinted
    case quiet
    case destructive
}

struct IndustrialButtonStyle: PrimitiveButtonStyle {
    var role: IndustrialButtonRole = .tinted
    var tint: Color = .accentColor

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
#if os(macOS)
        Button(configuration)
            .buttonStyle(MacIndustrialButtonStyle(role: role, tint: tint))
#else
        Button(configuration)
            .buttonStyle(TouchIndustrialButtonStyle(role: role, tint: tint))
#endif
    }
}

extension PrimitiveButtonStyle where Self == IndustrialButtonStyle {
    static var industrial: IndustrialButtonStyle { IndustrialButtonStyle() }
    static func industrial(_ role: IndustrialButtonRole, tint: Color = .accentColor) -> IndustrialButtonStyle {
        IndustrialButtonStyle(role: role, tint: tint)
    }
}

#if !os(macOS)
private struct TouchIndustrialButtonStyle: ButtonStyle {
    let role: IndustrialButtonRole
    let tint: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        let large = controlSize == .large

        configuration.label
            .font(FontTheme.caption(size: large ? 15 : 13))
            .tracking(0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minHeight: large ? 28 : 24)
            .padding(.horizontal, large ? 20 : 16)
            .padding(.vertical, large ? 9 : 7)
            .foregroundStyle(foreground)
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: hasStroke ? 1 : 0))
            .contentShape(shape)
            .compositingGroup()
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var hasStroke: Bool { role != .prominent }

    private var fill: Color {
        switch role {
        case .prominent: return tint
        case .tinted: return tint.opacity(0.12)
        case .quiet: return .clear
        case .destructive: return Color.red.opacity(0.08)
        }
    }

    private var stroke: Color {
        switch role {
        case .prominent: return .clear
        case .tinted: return tint.opacity(0.45)
        case .quiet: return Color.primary.opacity(0.18)
        case .destructive: return Color.red.opacity(0.4)
        }
    }

    private var foreground: Color {
        switch role {
        case .prominent: return .white
        case .tinted: return tint
        case .quiet: return Color.primary.opacity(0.75)
        case .destructive: return Color.red.opacity(0.9)
        }
    }
}
#endif

#if os(macOS)
private struct MacIndustrialButtonStyle: ButtonStyle {
    let role: IndustrialButtonRole
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        MacIndustrialBody(configuration: configuration, role: role, tint: tint)
    }
}

private struct MacIndustrialBody: View {
    let configuration: ButtonStyleConfiguration
    let role: IndustrialButtonRole
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
    }

    var body: some View {
        configuration.label
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.5)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: hasStroke ? 1 : 0))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .onHover { hovering = $0 && isEnabled }
    }

    private var hasStroke: Bool {
        role == .quiet || role == .destructive
    }

    private var fill: Color {
        switch role {
        case .prominent:
            return hovering ? tint.opacity(0.85) : tint
        case .tinted:
            return tint.opacity(hovering ? 0.22 : 0.14)
        case .quiet:
            return hovering ? Color.primary.opacity(0.05) : .clear
        case .destructive:
            return hovering ? Color.red.opacity(0.1) : .clear
        }
    }

    private var stroke: Color {
        switch role {
        case .quiet:
            return Color.primary.opacity(0.15)
        case .destructive:
            return Color.red.opacity(0.35)
        default:
            return .clear
        }
    }

    private var foreground: Color {
        switch role {
        case .prominent:
            return .white
        case .tinted:
            return tint
        case .quiet:
            return Color.primary.opacity(0.75)
        case .destructive:
            return Color.red.opacity(0.9)
        }
    }
}
#endif

extension View {
    /// Full-width CTA labels stay full-width on touch platforms; on Mac the
    /// industrial buttons hug their content.
    @ViewBuilder
    func industrialCTAWidth() -> some View {
#if os(macOS)
        self
#else
        self.frame(maxWidth: .infinity)
#endif
    }
}

struct IndustrialHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}

struct IndustrialSectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var detail: String? = nil
    var dotColor: Color? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: LocalizedStringKey,
         detail: String? = nil,
         dotColor: Color? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.detail = detail
        self.dotColor = dotColor
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail, !detail.isEmpty {
                    Text(verbatim: "· \(detail)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.vertical, 7)
            IndustrialHairline()
        }
    }
}

extension IndustrialSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, detail: String? = nil, dotColor: Color? = nil) {
        self.init(title, detail: detail, dotColor: dotColor) { EmptyView() }
    }
}

struct IndustrialBadge: View {
    private let text: Text
    var tint: Color = .secondary
    var systemImage: String? = nil
    var dot: Bool = false

    init(_ title: LocalizedStringKey, tint: Color = .secondary, systemImage: String? = nil, dot: Bool = false) {
        self.text = Text(title)
        self.tint = tint
        self.systemImage = systemImage
        self.dot = dot
    }

    init(verbatim: String, tint: Color = .secondary, systemImage: String? = nil, dot: Bool = false) {
        self.text = Text(verbatim: verbatim)
        self.tint = tint
        self.systemImage = systemImage
        self.dot = dot
    }

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            text
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

extension View {
    func industrialStat() -> some View {
        self
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.4))
    }
}

struct IndustrialStatPair: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .textCase(.uppercase)
                .foregroundStyle(Color.primary.opacity(0.4))
            Text(verbatim: value)
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }
}

/// Collapsible section in the activity-row anatomy: dot · CAPS title ·
/// mono headline · chevron · hairline. The headline carries the section's
/// key data so collapsed never means hidden.
struct IndustrialDisclosureRow<Content: View>: View {
    let title: LocalizedStringKey
    var headline: String? = nil
    var dotColor: Color? = nil
    var initiallyExpanded: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isExpanded: Bool

    init(_ title: LocalizedStringKey,
         headline: String? = nil,
         dotColor: Color? = nil,
         initiallyExpanded: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.headline = headline
        self.dotColor = dotColor
        self.initiallyExpanded = initiallyExpanded
        self.content = content
        _isExpanded = State(initialValue: initiallyExpanded)
    }

#if os(macOS)
    private let rowVerticalPadding: CGFloat = 7
#else
    private let rowVerticalPadding: CGFloat = 11
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if let dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(title)
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let headline, !headline.isEmpty {
                        Text(verbatim: "· \(headline)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, rowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            IndustrialHairline()

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
        }
    }
}

/// Single-line slider: label · rail · mono value.
struct IndustrialSliderRow: View {
    var label: LocalizedStringKey? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var display: String? = nil

#if os(macOS)
    private let labelFont = Font.system(size: 13)
#else
    private let labelFont = Font.body
#endif

    var body: some View {
        HStack(spacing: 10) {
            if let label {
                Text(label)
                    .font(labelFont)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            slider
#if os(macOS)
                .controlSize(.small)
#endif
            if let display {
                Text(verbatim: display)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var slider: some View {
#if os(macOS)
        // A stepped Slider draws tick marks on macOS; quantize in the binding
        // instead so the rail stays clean.
        if let step {
            Slider(
                value: Binding(
                    get: { value },
                    set: { value = ($0 / step).rounded() * step }
                ),
                in: range
            )
        } else {
            Slider(value: $value, in: range)
        }
#else
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
#endif
    }
}

/// Single-line stepper: label · mono value · − +.
struct IndustrialStepperRow<V: Strideable>: View {
    let label: LocalizedStringKey
    let display: String
    @Binding var value: V
    let range: ClosedRange<V>
    var step: V.Stride = 1

#if os(macOS)
    private let labelFont = Font.system(size: 13)
#else
    private let labelFont = Font.body
#endif

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(labelFont)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: display)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.7))
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
#if os(macOS)
                .controlSize(.small)
#endif
        }
    }
}

struct IndustrialProgressBar: View {
    let value: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 2)
    }
}

#if os(macOS)
struct IndustrialHoverRow<Content: View>: View {
    var selected: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected
                          ? Color.primary.opacity(0.07)
                          : (hovering ? Color.primary.opacity(0.045) : .clear))
            )
            .onHover { hovering = $0 }
    }
}

struct IndustrialIconButton: View {
    let systemImage: String
    var help: LocalizedStringKey? = nil
    var tint: Color = .secondary
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(shape.fill(hovering && isEnabled ? Color.primary.opacity(0.05) : .clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }

        if let help {
            button.help(help)
        } else {
            button
        }
    }
}

struct IndustrialToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.15))
                .frame(width: 34, height: 18)
                .overlay(
                    Circle()
                        .fill(.white)
                        .padding(2)
                        .frame(maxWidth: .infinity, alignment: configuration.isOn ? .trailing : .leading)
                )
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

extension View {
    func industrialField(width: CGFloat? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return self
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(shape.fill(Color.primary.opacity(0.05)))
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .frame(width: width)
    }
}
#endif
