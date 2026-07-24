#if os(macOS)
import SwiftUI

struct JSpaceCounterfactualPanel: View {
    /// The run this panel renders — observing it directly keeps per-token streaming
    /// from re-rendering everything else that watches the lens controller.
    @ObservedObject var run: JSpaceLensController.CounterfactualRun
    /// Re-run the counterfactual with the current interventions.
    var rerun: () -> Void
    /// Cancel any in-flight run and dismiss the panel.
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            IndustrialHairline()
            content(run)
        }
        .frame(minWidth: 320, idealWidth: 364, maxWidth: 440, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Color.primary.opacity(0.08).frame(width: 1).ignoresSafeArea()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(run.isRunning ? Color.blue : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text("Counterfactual")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            IndustrialIconButton(systemImage: "xmark", help: "Close") { close() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Content

    private func content(_ cf: JSpaceLensController.CounterfactualRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                promptBlock(cf.prompt)
                if !cf.interventions.isEmpty { interventionChips(cf.interventions) }

                answerBlock(title: "ORIGINAL", subtitle: "as generated in your chat",
                            text: cf.original, tint: .secondary, running: false, error: nil)

                answerBlock(title: "STEERED", subtitle: "same prompt, interventions active",
                            text: cf.steered, tint: .blue, running: cf.isRunning, error: cf.error)

                Button {
                    rerun()
                } label: {
                    HStack(spacing: 5) {
                        if cf.isRunning { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                        Text(cf.isRunning ? "Running…" : "Re-run")
                    }
                }
                .buttonStyle(.industrial(.tinted))
                .disabled(cf.isRunning)

                Text("Sampling still applies, so some wording differs run-to-run; a strong steer changes the substance, not just the phrasing.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private func promptBlock(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IndustrialSectionHeader("Prompt")
            Text(verbatim: prompt)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private func interventionChips(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IndustrialSectionHeader("Interventions")
            FlowChips(items: items)
        }
    }

    private func answerBlock(title: LocalizedStringKey, subtitle: String, text: String,
                             tint: Color, running: Bool, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IndustrialSectionHeader(title, detail: subtitle, dotColor: running ? tint : nil)
            if let error {
                Text(verbatim: error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if text.isEmpty && running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Generating…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Text(verbatim: text.isEmpty ? "—" : text)
                    .font(.system(size: 12))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tint.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(tint.opacity(0.18), lineWidth: 1))
                    )
            }
        }
    }
}

/// A minimal wrapping row of monospace chips (intervention summaries).
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        // Vertical stack keeps it dead simple and always fits the narrow panel.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(verbatim: item)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                    .foregroundStyle(.primary)
            }
        }
    }
}
#endif
