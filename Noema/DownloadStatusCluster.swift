import SwiftUI

func downloadSpeedLabel(_ bytesPerSecond: Double) -> String {
    let kbps = bytesPerSecond / 1_024.0
    if kbps > 1_024.0 {
        return String(format: "%.1f MB/s", locale: Locale.current, kbps / 1_024.0)
    }
    return String(format: "%.0f KB/s", locale: Locale.current, kbps)
}

struct DownloadCapsuleBar: View {
    let value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.2), value: value)
    }
}

/// Bar + percent/speed line. Pass `statusKey` only for states the bar can't
/// express (Paused, Retrying, Verifying) — never for plain downloading.
struct DownloadProgressCluster: View {
    let progress: Double
    var speed: Double? = nil
    var statusKey: LocalizedStringKey? = nil
    var tint: Color = .accentColor

    private var clamped: Double { max(0, min(1, progress)) }

    private var speedText: String? {
        guard let speed, speed > 0 else { return nil }
        return downloadSpeedLabel(speed)
    }

    var body: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 5) {
            statsLine
            IndustrialProgressBar(value: clamped, tint: tint)
        }
#else
        VStack(alignment: .leading, spacing: 6) {
            statsLine
            DownloadCapsuleBar(value: clamped, tint: tint)
        }
#endif
    }

    private var statsLine: some View {
        HStack(spacing: 6) {
            if let statusKey {
                Text(statusKey)
                    .textCase(.uppercase)
            }
            Spacer(minLength: 6)
            if let speedText {
                Text(verbatim: speedText)
                    .foregroundStyle(statColor.opacity(0.75))
            }
            Text(verbatim: "\(Int(clamped * 100))%")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(statColor)
        .lineLimit(1)
    }

    private var statColor: Color {
#if os(macOS)
        Color.primary.opacity(0.5)
#else
        Color.secondary
#endif
    }
}

/// Pause/resume/retry/schedule/stop icon cluster with one look per platform.
struct DownloadActionCluster: View {
    var onResume: (() -> Void)? = nil
    var onPause: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onSchedule: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let onRetry {
                actionButton("arrow.clockwise", help: "Retry", tint: .accentColor, action: onRetry)
            }
            if let onResume {
                actionButton("play.fill", help: "Resume", tint: .accentColor, action: onResume)
            }
            if let onPause {
                actionButton("pause.fill", help: "Pause", tint: .accentColor, action: onPause)
            }
            if let onSchedule {
                actionButton("clock.badge.pause", help: "Schedule", tint: .secondary, action: onSchedule)
            }
            if let onCancel {
                actionButton("stop.fill", help: "Stop", tint: .red, action: onCancel)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ systemImage: String, help: LocalizedStringKey, tint: Color, action: @escaping () -> Void) -> some View {
#if os(macOS)
        IndustrialIconButton(systemImage: systemImage, help: help, tint: tint, action: action)
            .accessibilityLabel(Text(help))
#else
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(help))
#endif
    }
}
