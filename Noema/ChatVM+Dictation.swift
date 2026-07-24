import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Speech) && canImport(AVFoundation)
extension ChatVM {
    @MainActor
    func toggleLiveDictation() async {
        if isDictating {
            await stopLiveDictation()
        } else {
            await startLiveDictation()
        }
    }

    @MainActor
    func startLiveDictation() async {
        guard !isDictating, !isRecordingAudio else { return }
        dictationError = nil
        // Flip the UI immediately; the audio pipeline spins up behind it. Every
        // await below re-checks `isDictating` so a quick toggle-off unwinds the
        // half-built pipeline instead of leaving the mic running.
        isDictating = true
        micLevelMeter.reset()
        Haptics.successLight()

        let transcriber = AppleSpeechLiveTranscriber(autoEndpointing: false)
        do {
            try await transcriber.prepare()
        } catch {
            transcriber.tearDown()
            abortDictationStart(error.localizedDescription)
            return
        }
        guard isDictating else {
            transcriber.tearDown()
            return
        }

#if os(iOS) || os(visionOS)
        do {
            // Activation blocks; keep it off the main thread (same pattern as the
            // voice-note recorder).
            try await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
            }.value
        } catch {
            transcriber.tearDown()
            abortDictationStart(error.localizedDescription)
            return
        }
        guard isDictating else {
            transcriber.tearDown()
            deactivateDictationAudioSession()
            return
        }
#endif

        do {
            try await transcriber.startUtterance()
        } catch {
            transcriber.tearDown()
            deactivateDictationAudioSession()
            if isDictating {
                abortDictationStart(error.localizedDescription)
            }
            return
        }
        guard isDictating else {
            transcriber.tearDown()
            deactivateDictationAudioSession()
            return
        }

        liveDictationTranscriber = transcriber
        dictationBaseText = prompt
        VoiceSessionOwnership.shared.setOwned(true)
        AccessibilityAnnouncer.announceLocalized("Dictation started")

        dictationEventsTask = Task { @MainActor [weak self] in
            for await event in transcriber.events {
                guard let self else { break }
                switch event {
                case .partial(let text):
                    self.prompt = Self.joinedDictationText(base: self.dictationBaseText, addition: text)
                case .level(let level):
                    self.micLevelMeter.push(level)
                case .finalized(let text):
                    self.prompt = Self.joinedDictationText(base: self.dictationBaseText, addition: text)
                case .failed(let message):
                    self.dictationError = message
                    await self.stopLiveDictation()
                }
            }
        }
    }

    @MainActor
    func stopLiveDictation() async {
        guard isDictating else { return }
        isDictating = false
        guard let transcriber = liveDictationTranscriber else {
            // Still spinning up; startLiveDictation sees the flag flip and unwinds.
            Haptics.successLight()
            return
        }
        await transcriber.stopAndFinalize()
        transcriber.tearDown()
        dictationEventsTask = nil
        liveDictationTranscriber = nil
        micLevelMeter.reset()
        VoiceSessionOwnership.shared.setOwned(false)
        deactivateDictationAudioSession()
        Haptics.successLight()
        AccessibilityAnnouncer.announceLocalized("Dictation stopped")
    }

    @MainActor
    private func abortDictationStart(_ message: String) {
        isDictating = false
        micLevelMeter.reset()
        dictationError = message
        Haptics.error()
        AccessibilityAnnouncer.announce(message)
    }

    private func deactivateDictationAudioSession() {
#if os(iOS) || os(visionOS)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
#endif
    }

    nonisolated static func joinedDictationText(base: String, addition: String) -> String {
        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddition.isEmpty else { return base }
        guard !base.isEmpty else { return trimmedAddition }
        let needsSpace = !(base.last?.isWhitespace ?? false)
        return base + (needsSpace ? " " : "") + trimmedAddition
    }
}
#endif
