// NoemaEmbeddingActivityLiveActivity.swift
//
//  NoemaEmbeddingActivityLiveActivity.swift
//  NoemaEmbeddingActivity
//
//  Live Activity UI for dataset embedding progress: lock screen banner and
//  Dynamic Island (compact / minimal / expanded). All user-facing strings
//  arrive pre-localized inside the content state; this widget only renders.
//  When `isPaused` is set (app backgrounded, GPU work suspended) the activity
//  flips to an amber call-to-action urging the user to reopen the app.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct NoemaEmbeddingActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DatasetIndexingAttributes.self) { context in
            LockScreenView(context: context)
                .activitySystemActionForegroundColor(Palette.activeBlue)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StageIcon(state: context.state, size: 18)
                        .padding(.leading, 6)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percentText(context.state.progress))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.tint(for: context.state))
                        .padding(.trailing, 6)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressBar(progress: context.state.progress, tint: Palette.tint(for: context.state), height: 4.5)

                        HStack(spacing: 6) {
                            statusLine(for: context.state)
                                .font(.caption2)
                                .foregroundStyle(statusLineStyle(for: context.state))
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            if let eta = context.state.etaText {
                                Text(eta)
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
            } compactLeading: {
                StageIcon(state: context.state, size: 14)
            } compactTrailing: {
                if context.state.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.pausedTint)
                } else {
                    ProgressRing(progress: context.state.progress, tint: Palette.tint(for: context.state), lineWidth: 2.2)
                        .frame(width: 16, height: 16)
                }
            } minimal: {
                if context.state.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.pausedTint)
                } else {
                    ProgressRing(progress: context.state.progress, tint: Palette.tint(for: context.state), lineWidth: 2.2)
                        .frame(width: 16, height: 16)
                }
            }
            .keylineTint(context.state.isPaused ? Palette.pausedTint : Palette.activeBlue)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let context: ActivityViewContext<DatasetIndexingAttributes>

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                StageIcon(state: context.state, size: 15)

                Text(context.attributes.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(percentText(context.state.progress))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tint(for: context.state))
            }

            ProgressBar(progress: context.state.progress, tint: Palette.tint(for: context.state), height: 4.5)

            HStack(spacing: 6) {
                statusLine(for: context.state)
                    .font(context.state.isPaused ? .caption2.weight(.semibold) : .caption2)
                    .foregroundStyle(statusLineStyle(for: context.state))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let eta = context.state.etaText {
                    Text(eta)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // The system default leaves lock-screen activities very dark even in
        // light mode; tint explicitly so the card follows the appearance.
        .activityBackgroundTint(
            colorScheme == .dark
                ? Color.black.opacity(0.45)
                : Color.white.opacity(0.82)
        )
    }
}

// MARK: - Shared components

/// "Embedding · Preparing chunks" — or "Paused · Open Noema to continue" —
/// as a single caption line.
private func statusLine(for state: DatasetIndexingAttributes.ContentState) -> Text {
    var line = Text(state.stageTitle).fontWeight(.medium)
    if let detail = state.detail, !detail.isEmpty {
        line = line + Text(verbatim: " · ") + Text(detail)
    }
    return line
}

private func statusLineStyle(for state: DatasetIndexingAttributes.ContentState) -> AnyShapeStyle {
    state.isPaused ? AnyShapeStyle(Palette.pausedTint) : AnyShapeStyle(.secondary)
}

private enum Palette {
    static let activeBlue = Color(red: 0.07, green: 0.56, blue: 1.0)
    static let pausedTint = Color.orange

    static func tint(for state: DatasetIndexingAttributes.ContentState) -> Color {
        state.isPaused ? pausedTint : tint(for: state.stage)
    }

    static func tint(for stage: DatasetProcessingStage) -> Color {
        switch stage {
        case .extracting, .compressing, .embedding:
            return activeBlue
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }

    static func symbol(for state: DatasetIndexingAttributes.ContentState) -> String {
        state.isPaused ? "pause.circle.fill" : symbol(for: state.stage)
    }

    static func symbol(for stage: DatasetProcessingStage) -> String {
        switch stage {
        case .extracting:
            return "doc.text.magnifyingglass"
        case .compressing:
            return "text.line.first.and.arrowtriangle.forward"
        case .embedding:
            return "sparkles"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct StageIcon: View {
    let state: DatasetIndexingAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Image(systemName: Palette.symbol(for: state))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Palette.tint(for: state))
    }
}

private struct ProgressRing: View {
    let progress: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 4.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.18))

                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
    }
}

private func percentText(_ progress: Double) -> String {
    "\(Int(max(0, min(1, progress)) * 100))%"
}

// MARK: - Previews

extension DatasetIndexingAttributes {
    fileprivate static var preview: DatasetIndexingAttributes {
        DatasetIndexingAttributes(datasetID: "HF/the-ds", name: "Sample Dataset")
    }
}

extension DatasetIndexingAttributes.ContentState {
    fileprivate static var embedding: DatasetIndexingAttributes.ContentState {
        DatasetIndexingAttributes.ContentState(stage: .embedding, progress: 0.54, stageTitle: "Embedding", detail: "Preparing chunks", etaText: "~3m 24s", isPaused: false)
    }
    fileprivate static var paused: DatasetIndexingAttributes.ContentState {
        DatasetIndexingAttributes.ContentState(stage: .embedding, progress: 0.54, stageTitle: "Paused", detail: "Open Noema to continue", etaText: nil, isPaused: true)
    }
    fileprivate static var completed: DatasetIndexingAttributes.ContentState {
        DatasetIndexingAttributes.ContentState(stage: .completed, progress: 1.0, stageTitle: "Ready", detail: "Embedding complete", etaText: nil, isPaused: false)
    }
}

#Preview("Lock Screen", as: .content, using: DatasetIndexingAttributes.preview) {
    NoemaEmbeddingActivityLiveActivity()
} contentStates: {
    DatasetIndexingAttributes.ContentState.embedding
    DatasetIndexingAttributes.ContentState.paused
    DatasetIndexingAttributes.ContentState.completed
}
