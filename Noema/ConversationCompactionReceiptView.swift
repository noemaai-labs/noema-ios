import SwiftUI

#if canImport(UIKit) || os(macOS)
/// A chronological context event rendered directly in the transcript. It uses
/// the same quiet, expandable visual language as tool activity without posing
/// as a model-authored message or an executable tool call.
struct ConversationCompactionReceiptView: View {
    let state: ConversationCompactionState

    @State private var isExpanded = false

    private var dotGradient: LinearGradient {
        LinearGradient(
            colors: [.blue, .indigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Preserve the recap's compact, selectable layout while honoring inline
    /// emphasis emitted by the summarizer. Block Markdown stays as plain text
    /// so this receipt does not grow into the full chat renderer.
    private var attributedSummary: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: state.summary, options: options))
            ?? AttributedString(state.summary)
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

                    Text("Context automatically compacted")
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Context automatically compacted"))
            .accessibilityHint(Text(isExpanded ? "Collapse retained summary" : "Expand retained summary"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Retained Summary")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .textCase(.uppercase)
                            .foregroundStyle(AppTheme.secondaryText)

                        Spacer(minLength: 8)

                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "%d earlier turns summarized"),
                                state.compactedTurnCount
                            )
                        )
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppTheme.tertiaryText)
                    }

                    Text(attributedSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(state.updatedAt, style: .time)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppTheme.tertiaryText)
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
    }
}
#endif
