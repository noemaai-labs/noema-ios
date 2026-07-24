import SwiftUI

/// A quiet, versioned release-note surface shared by launch and Settings.
struct NoemaUpdateView: View {
    static let releaseVersion = "3.5"
    static let lastPresentedVersionDefaultsKey = "lastPresentedNoemaUpdateVersion"

    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private let highlights: [Highlight] = [
        Highlight(
            systemImage: "square.stack.3d.up",
            tint: .orange,
            title: "Noema Overfit",
            detail: "Noema Overfit expands the models your device can run by keeping only the experts needed at each step in memory. It adds capacity, not guaranteed speed."
        ),
        Highlight(
            systemImage: "text.line.first.and.arrowtriangle.forward",
            tint: .blue,
            title: "Chat Compaction",
            detail: "Long chats can compact completed older turns into a durable recap, keeping the full transcript visible while making room to continue."
        ),
        Highlight(
            systemImage: "rectangle.3.group.bubble.left",
            tint: .indigo,
            title: "Better Context Handling",
            detail: "Important instructions, recent turns, and document context are budgeted more carefully, with clearer handling when a model reaches its context limit."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(highlights.enumerated()), id: \.offset) { index, highlight in
                            highlightRow(highlight, index: index)

                            if index < highlights.count - 1 {
                                Divider()
                                    .padding(.leading, 46)
                            }
                        }
                    }

                    documentationLink
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button(LocalizedStringKey("Continue"), action: onContinue)
                    .buttonStyle(.industrial(.prominent))
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .background(AppTheme.windowBackground.ignoresSafeArea())
#if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 580, idealHeight: 640)
#endif
        .onAppear {
            hasAppeared = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image("Noema")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("What's New")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.accentColor)

                Text(verbatim: "Noema \(Self.releaseVersion)")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.text)

                Text("Bigger local possibilities and steadier conversations.")
                    .font(.title3)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: hasAppeared)
    }

    private func highlightRow(_ highlight: Highlight, index: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: highlight.systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(highlight.tint)
                .frame(width: 30, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(highlight.title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.text)

                Text(highlight.detail)
                    .font(.body)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 17)
        .accessibilityElement(children: .combine)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 8)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.06 * Double(index + 1)),
            value: hasAppeared
        )
    }

    private var documentationLink: some View {
        Link(destination: URL(string: "https://noemaai.com/docs")!) {
            HStack(spacing: 8) {
                Text("More information at noemaai.com/docs")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hasAppeared ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.26), value: hasAppeared)
    }

    private struct Highlight {
        let systemImage: String
        let tint: Color
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }
}
