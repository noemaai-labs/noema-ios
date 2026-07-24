import SwiftUI

#if canImport(UIKit) || os(macOS)
/// A chronological receipt for the moment a fully resident dataset is released
/// from model context and replaced by per-turn semantic retrieval.
struct DocumentContextTransitionReceiptView: View {
    let receipt: ChatVM.DocumentContextTransitionReceipt

    @State private var isExpanded = false

    private var dotGradient: LinearGradient {
        LinearGradient(
            colors: [.cyan, .blue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var contextDetailsAccessibilityHint: LocalizedStringKey {
        isExpanded ? "Collapse context details" : "Expand context details"
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

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full document released from context")
                            .textCase(.uppercase)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)

                        Text("Continuing with smart retrieval")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(1)
                    }
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Full document released from context"))
            .accessibilityValue(Text("Continuing with smart retrieval"))
            .accessibilityHint(Text(contextDetailsAccessibilityHint))

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Why this changed")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .textCase(.uppercase)
                        .foregroundStyle(AppTheme.secondaryText)

                    Text("Keeping the full document would leave too little room for the conversation, instructions, your message, and a useful response.")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 5) {
                        metricRow("Full document", value: receipt.fullDocumentTokens)
                        metricRow("Model context window", value: receipt.configuredContextTokens)
                        metricRow("Response reserve", value: receipt.reservedResponseTokens)
                        metricRow("Retrieved this turn", value: receipt.retrievedContextTokens)
                    }

                    Text("Your transcript is unchanged. Noema will use smart retrieval and can use PDF navigation for exact details when the dataset is a PDF.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.tertiaryText)
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
    }

    private func metricRow(_ title: LocalizedStringKey, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)

            Spacer(minLength: 8)

            Text(
                String.localizedStringWithFormat(
                    String(localized: "%lld tokens"),
                    Int64(value)
                )
            )
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(AppTheme.secondaryText)
        }
    }
}
#endif
