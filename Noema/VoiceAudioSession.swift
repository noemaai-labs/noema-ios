import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Cross-thread flag other audio features (AppSoundPlayer) consult so they
/// never flip the shared AVAudioSession category while a voice feature holds it.
final class VoiceSessionOwnership: @unchecked Sendable {
    static let shared = VoiceSessionOwnership()
    private let lock = NSLock()
    private var owned = false

    var isOwned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return owned
    }

    func setOwned(_ value: Bool) {
        lock.lock()
        owned = value
        lock.unlock()
    }
}

/// Owns the audio session for the lifetime of a voice-mode session: one
/// activation, one deactivation, interruption and route-loss surfaced as
/// callbacks. No-ops on macOS (no shared session there).
@MainActor
final class VoiceAudioSessionCoordinator {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    var onRouteLost: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func activate() async throws {
#if os(iOS) || os(visionOS)
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        }.value
#if os(iOS)
        // A crash mid-capture can leave the app's input-mute latched, which
        // yields perfectly-timed buffers of pure silence.
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.isInputMuted {
                await logger.log("[Voice] input was muted at session start — unmuting")
                try? AVAudioApplication.shared.setInputMuted(false)
            }
        }
#endif
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        await logger.log("[Voice] session route inputs=[\(inputs.isEmpty ? "none" : inputs)] sampleRate=\(session.sampleRate)")
        installObservers()
#endif
        VoiceSessionOwnership.shared.setOwned(true)
    }

    func deactivate() {
        VoiceSessionOwnership.shared.setOwned(false)
#if os(iOS) || os(visionOS)
        removeObservers()
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
#endif
    }

#if os(iOS) || os(visionOS)
    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let userInfo = notification.userInfo
            guard let rawType = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let shouldResume: Bool = {
                guard let rawOptions = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return false }
                return AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            }()
            Task { @MainActor [weak self] in
                switch type {
                case .began:
                    self?.onInterruptionBegan?()
                case .ended:
                    self?.onInterruptionEnded?(shouldResume)
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                  reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                self?.onRouteLost?()
            }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
#endif
}
