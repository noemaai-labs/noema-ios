import SwiftUI

#if canImport(UIKit) || os(macOS)
/// A chronological, model-runtime receipt placed at the exact point where an
/// answer paused for a fresh context window. It follows the same quiet row and
/// disclosure treatment as tool calls and rolling thought.
struct OutputContinuationReceiptView: View {
    let event: ChatVM.Msg.OutputContinuationEvent

    @State private var isExpanded = false
    @State private var dotPulsing = false

    private var title: LocalizedStringKey {
        switch event.phase {
        case .preparing:
            return "Making room to continue"
        case .continued:
            return "Response continued"
        case .unavailable:
            return "Automatic continuation unavailable"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch event.phase {
        case .preparing:
            return "No action needed — Noema will resume automatically"
        case .continued:
            return "Earlier working context was reduced; your chat is unchanged"
        case .unavailable:
            return "The response could not resume automatically"
        }
    }

    private var detail: LocalizedStringKey {
        switch event.phase {
        case .preparing:
            return "The model filled its current context window. Noema is reducing earlier model-facing context and will continue this same answer automatically."
        case .continued:
            switch ContextOverflowStrategy.from(event.contextStrategyRaw) {
            case .truncateMiddle:
                return "The model filled its context window, so Noema reduced older middle working context and resumed this answer. Messages shown in the chat were not deleted."
            case .rollingWindow:
                return "The model filled its context window, so Noema reduced the earliest working context and resumed this answer. Messages shown in the chat were not deleted."
            case .stopAtLimit:
                return "Noema resumed this answer in a fresh model context. Messages shown in the chat were not deleted."
            }
        case .unavailable:
            return "Noema tried to make room after the model filled its context window, but there was not enough space for a useful continuation. The partial answer remains visible."
        }
    }

    private var continuationDetailsAccessibilityHint: LocalizedStringKey {
        isExpanded ? "Collapse continuation details" : "Expand continuation details"
    }

    private var dotGradient: LinearGradient {
        let colors: [Color]
        switch event.phase {
        case .preparing:
            colors = [.blue, .indigo]
        case .continued:
            colors = [.cyan, .blue]
        case .unavailable:
            colors = [.orange, .red]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotGradient)
                        .frame(width: 6, height: 6)
                        .opacity(dotPulsing ? 0.35 : 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .textCase(.uppercase)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(2)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    if event.phase == .preparing {
                        TimelineView(.periodic(from: event.startedAt, by: 1)) { context in
                            Text(durationString(to: context.date))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppTheme.tertiaryText)
                                .opacity(dotPulsing ? 0.45 : 1)
                        }
                    } else if let completedAt = event.completedAt {
                        Text(durationString(to: completedAt))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppTheme.tertiaryText)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(subtitle))
            .accessibilityHint(Text(continuationDetailsAccessibilityHint))

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .padding(.leading, 14)
                .padding(.bottom, 8)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { syncPulse() }
        .onChangeCompat(of: event.phase) { _, _ in syncPulse() }
    }

    private func durationString(to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(event.startedAt).rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func syncPulse() {
        guard event.phase == .preparing else {
            dotPulsing = false
            return
        }
        dotPulsing = false
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            dotPulsing = true
        }
    }
}
#endif
