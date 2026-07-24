import SwiftUI

/// Latest microphone level shared between the audio pipeline and the composer
/// waveform. Deliberately not `@Published`: level ticks arrive at tap cadence
/// (~10 Hz on iOS) and must never invalidate ChatVM observers — `MicLevelBars`
/// polls this at display refresh instead.
final class MicLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var target: Float = 0

    var current: Float {
        lock.lock()
        defer { lock.unlock() }
        return target
    }

    func push(_ level: Float) {
        lock.lock()
        target = min(1, max(0, level))
        lock.unlock()
    }

    func reset() {
        push(0)
    }
}

/// Composer mic bars, rendered at display refresh via `TimelineView(.animation)`.
/// A fast-attack / slow-release envelope bridges the sparse tap levels so the
/// meter reads as continuous motion instead of stepping at the tap rate.
struct MicLevelBars: View {
    let meter: MicLevelMeter
    @State private var envelope = Envelope()

    /// Reference type so per-frame smoothing state survives re-renders without
    /// triggering them.
    final class Envelope {
        var displayed: Float = 0
        var lastTime: TimeInterval = 0
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let level = smoothedLevel(at: now)
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.78))
                        .frame(width: 3, height: barHeight(index: index, level: level, time: now))
                }
            }
            .frame(height: 18, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func smoothedLevel(at time: TimeInterval) -> Float {
        let dt = envelope.lastTime == 0 ? (1.0 / 60.0) : min(0.1, max(0.001, time - envelope.lastTime))
        envelope.lastTime = time
        let target = meter.current
        let tau: TimeInterval = target > envelope.displayed ? 0.05 : 0.25
        let alpha = Float(1 - exp(-dt / tau))
        envelope.displayed += (target - envelope.displayed) * alpha
        return envelope.displayed
    }

    private func barHeight(index: Int, level: Float, time: TimeInterval) -> CGFloat {
        // Same silhouette as the old static bars, with a slight per-bar ripple
        // so the columns don't move in rigid lockstep.
        let weight = CGFloat(index + 2) * 4
        let ripple = 0.85 + 0.15 * sin(time * 7.3 + Double(index) * 1.9)
        return max(3, CGFloat(level) * weight * CGFloat(ripple))
    }
}
