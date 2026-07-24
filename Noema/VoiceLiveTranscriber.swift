import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

enum VoiceTranscriberEvent: Sendable {
    case partial(String)
    case level(Float)
    case finalized(String)
    case failed(String)
}

/// Live microphone transcription for dictation and voice mode. Implementations
/// keep their recognizer warm across utterances; the audio session is owned by
/// the caller. `events` is a single-consumer stream.
@MainActor
protocol VoiceLiveTranscriber: AnyObject {
    var events: AsyncStream<VoiceTranscriberEvent> { get }
    func prepare() async throws
    func startUtterance() async throws
    func stopAndFinalize() async
    func cancelUtterance()
    func suspend()
    func tearDown()
}

/// Carries audio objects (AVAudioEngine, SFSpeechRecognizer) across the
/// detached tasks that keep their blocking setup/teardown off the main thread.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

enum VoiceTranscriberError: LocalizedError {
    case microphonePermissionDenied
    case speechPermissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return String(localized: "Microphone permission is required to record audio.")
        case .speechPermissionDenied:
            return String(localized: "Speech recognition permission is required for dictation.")
        case .recognizerUnavailable:
            return String(localized: "Speech recognition is unavailable for the selected language.")
        case .onDeviceRecognitionUnavailable:
            return String(localized: "On-device speech recognition is unavailable for the selected language.")
        }
    }
}

#if canImport(AVFoundation)
enum VoiceMicrophonePermission {
    static func request() async -> Bool {
#if os(iOS)
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
#elseif os(visionOS)
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
#elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
#else
        return false
#endif
    }
}
#endif

#if canImport(Speech) && canImport(AVFoundation)
/// Streams `SFSpeechAudioBufferRecognitionRequest` partials from an
/// `AVAudioEngine` mic tap. With `autoEndpointing` on, an utterance finalizes
/// itself once the partial transcript has been stable and the mic quiet for a
/// beat; otherwise it runs until `stopAndFinalize()`.
@MainActor
final class AppleSpeechLiveTranscriber: VoiceLiveTranscriber {
    let events: AsyncStream<VoiceTranscriberEvent>
    private let eventsContinuation: AsyncStream<VoiceTranscriberEvent>.Continuation
    private let autoEndpointing: Bool

    private nonisolated static let partialStableInterval: Duration = .milliseconds(900)
    private nonisolated static let silenceInterval: Duration = .milliseconds(700)
    // Ambient noise can keep the energy gate "voiced" indefinitely; a
    // transcript that stopped changing for this long finalizes regardless.
    private nonisolated static let longStableInterval: Duration = .milliseconds(1600)
    private nonisolated static let minUtteranceDuration: Duration = .milliseconds(1200)
    private nonisolated static let voiceGateLevel: Float = 0.3

    private final class TapBox: @unchecked Sendable {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var onLevel: (@Sendable (Float) -> Void)?
    }

    private var recognizer: SFSpeechRecognizer?
    private var wantsOnDevice = false
    private var engine: AVAudioEngine?
    private let tapBox = TapBox()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var endpointWatchTask: Task<Void, Never>?
    private var finalizeFallbackTask: Task<Void, Never>?
    private var utteranceGeneration = 0
    private var utteranceActive = false
    private var lastPartial = ""
    private var lastPartialAt = ContinuousClock.now
    private var lastVoiceAt = ContinuousClock.now
    private var utteranceStartedAt = ContinuousClock.now
    private var finalizeWaiters: [CheckedContinuation<Void, Never>] = []

    init(autoEndpointing: Bool) {
        self.autoEndpointing = autoEndpointing
        var continuation: AsyncStream<VoiceTranscriberEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    func prepare() async throws {
        guard await VoiceMicrophonePermission.request() else {
            throw VoiceTranscriberError.microphonePermissionDenied
        }
        try await Self.requestSpeechAuthorization()

        let localeID = AppleSpeechTranscriptionBackend.resolveLocaleIdentifier(
            TranscriptionSettings.preferredLocaleIdentifier
        )
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        let needsOnDevice = TranscriptionSettings.requiresOnDeviceRecognition(offGrid: offGrid)
        // Recognizer init and the availability probes talk to the speech
        // daemon over XPC; keep them off the main thread.
        let recognizerBox = try await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<SFSpeechRecognizer> in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
                  recognizer.isAvailable else {
                throw VoiceTranscriberError.recognizerUnavailable
            }
            if needsOnDevice && !recognizer.supportsOnDeviceRecognition {
                Task { await logger.log("[Voice][AppleSpeech] on-device required but unsupported for locale=\(localeID)") }
                throw VoiceTranscriberError.onDeviceRecognitionUnavailable
            }
            return UncheckedSendable(value: recognizer)
        }.value
        wantsOnDevice = needsOnDevice
        recognizer = recognizerBox.value
        Task { await logger.log("[Voice][AppleSpeech] ready locale=\(localeID) onDevice=\(needsOnDevice)") }
    }

    func startUtterance() async throws {
        guard recognizer != nil else { throw VoiceTranscriberError.recognizerUnavailable }
        cancelUtteranceInternals()

        try await startEngineIfNeeded()
        // tearDown() may have raced the engine spin-up (user toggled straight off).
        guard let recognizer else {
            stopEngine()
            throw CancellationError()
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if wantsOnDevice {
            request.requiresOnDeviceRecognition = true
        }
        tapBox.request = request

        utteranceGeneration += 1
        let generation = utteranceGeneration
        utteranceActive = true
        lastPartial = ""
        let now = ContinuousClock.now
        lastPartialAt = now
        lastVoiceAt = now
        utteranceStartedAt = now

        recognitionTask = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeRecognitionHandler(generation: generation, owner: self)
        )

        if autoEndpointing {
            startEndpointWatcher(generation: generation)
        }
    }

    func stopAndFinalize() async {
        guard utteranceActive else { return }
        requestFinalization(generation: utteranceGeneration, fallbackAfter: .milliseconds(500))
        await withCheckedContinuation { continuation in
            if utteranceActive {
                finalizeWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func cancelUtterance() {
        cancelUtteranceInternals()
    }

    func suspend() {
        cancelUtteranceInternals()
        stopEngine()
    }

    func tearDown() {
        cancelUtteranceInternals()
        stopEngine()
        recognizer = nil
        eventsContinuation.finish()
    }

    // MARK: - Internals

    // Speech and AVFAudio callback parameters predate Sendable annotations;
    // closures formed inside this @MainActor class would inherit its isolation
    // and trip dispatch_assert_queue on the frameworks' private queues. These
    // factories are nonisolated so the returned closures carry no isolation.
    private nonisolated static func makeRecognitionHandler(
        generation: Int,
        owner: AppleSpeechLiveTranscriber
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak owner] in
                owner?.handleRecognition(
                    generation: generation,
                    transcript: transcript,
                    isFinal: isFinal,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private nonisolated static func makeTapBlock(box: TapBox) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            box.request?.append(buffer)
            box.onLevel?(normalizedLevel(from: buffer))
        }
    }

    private func handleRecognition(generation: Int, transcript: String?, isFinal: Bool, errorMessage: String?) {
        guard generation == utteranceGeneration, utteranceActive else { return }

        if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if transcript != lastPartial {
                lastPartial = transcript
                lastPartialAt = .now
                eventsContinuation.yield(.partial(transcript))
            }
            if isFinal {
                finalize(generation: generation, text: transcript)
                return
            }
        } else if isFinal {
            finalize(generation: generation, text: lastPartial)
            return
        }

        if let errorMessage {
            // A cancelled/finished task surfaces a benign error; only report when
            // nothing was transcribed and the utterance is still considered live.
            if lastPartial.isEmpty {
                finalizeInternalState()
                eventsContinuation.yield(.failed(errorMessage))
            } else {
                finalize(generation: generation, text: lastPartial)
            }
        }
    }

    private func startEndpointWatcher(generation: Int) {
        endpointWatchTask?.cancel()
        endpointWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.utteranceActive, self.utteranceGeneration == generation else { return }
                let now = ContinuousClock.now
                guard !self.lastPartial.isEmpty,
                      now - self.utteranceStartedAt > Self.minUtteranceDuration else { continue }
                let stableFor = now - self.lastPartialAt
                let quietFor = now - self.lastVoiceAt
                let quietEndpoint = stableFor > Self.partialStableInterval && quietFor > Self.silenceInterval
                let stableEndpoint = stableFor > Self.longStableInterval
                guard quietEndpoint || stableEndpoint else { continue }
                Task { await logger.log("[Voice][AppleSpeech] endpoint stable=\(stableFor) quiet=\(quietFor)") }
                self.requestFinalization(generation: generation, fallbackAfter: .milliseconds(1500))
                return
            }
        }
    }

    private func requestFinalization(generation: Int, fallbackAfter: Duration) {
        guard utteranceActive, generation == utteranceGeneration else { return }
        tapBox.request?.endAudio()
        recognitionTask?.finish()
        finalizeFallbackTask?.cancel()
        finalizeFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: fallbackAfter)
            guard let self, !Task.isCancelled else { return }
            self.finalize(generation: generation, text: self.lastPartial)
        }
    }

    private func finalize(generation: Int, text: String) {
        guard utteranceActive, generation == utteranceGeneration else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await logger.log("[Voice][AppleSpeech] finalized chars=\(trimmed.count)") }
        // Yield before resuming stopAndFinalize() waiters: both land on the main
        // actor in enqueue order, so the consumer applies the final transcript
        // before a stop-then-send flow reads the prompt.
        eventsContinuation.yield(.finalized(trimmed))
        finalizeInternalState()
    }

    private func finalizeInternalState() {
        utteranceActive = false
        endpointWatchTask?.cancel()
        endpointWatchTask = nil
        finalizeFallbackTask?.cancel()
        finalizeFallbackTask = nil
        tapBox.request = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        let waiters = finalizeWaiters
        finalizeWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func cancelUtteranceInternals() {
        guard utteranceActive || recognitionTask != nil else {
            finalizeInternalState()
            return
        }
        finalizeInternalState()
    }

    // Engine setup and start touch the audio HAL (`inputNode`, `start()`) and
    // routinely block for hundreds of milliseconds — never on the main thread.
    private func startEngineIfNeeded() async throws {
        tapBox.onLevel = { [eventsContinuation, weak self] level in
            eventsContinuation.yield(.level(level))
            if level > Self.voiceGateLevel {
                Task { @MainActor [weak self] in self?.lastVoiceAt = .now }
            }
        }
        if let engine {
            let box = UncheckedSendable(value: engine)
            try await Task.detached(priority: .userInitiated) {
                box.value.prepare()
                try box.value.start()
            }.value
            return
        }
        let tapBox = tapBox
        let box = try await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<AVAudioEngine> in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTapBlock(box: tapBox))
            engine.prepare()
            try engine.start()
            return UncheckedSendable(value: engine)
        }.value
        if recognizer == nil {
            // Torn down while the engine was spinning up; kill the orphan.
            Task.detached(priority: .userInitiated) {
                box.value.inputNode.removeTap(onBus: 0)
                box.value.stop()
            }
            throw CancellationError()
        }
        engine = box.value
    }

    private func stopEngine() {
        tapBox.onLevel = nil
        guard let engine else { return }
        self.engine = nil
        let box = UncheckedSendable(value: engine)
        Task.detached(priority: .userInitiated) {
            box.value.inputNode.removeTap(onBus: 0)
            box.value.stop()
        }
    }

    private nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?.pointee else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            let sample = data[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        let db = 20 * log10(max(rms, .leastNonzeroMagnitude))
        return max(0, min(1, (db + 55) / 55))
    }

    private nonisolated static func requestSpeechAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw VoiceTranscriberError.speechPermissionDenied
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard status == .authorized else {
                throw VoiceTranscriberError.speechPermissionDenied
            }
        @unknown default:
            throw VoiceTranscriberError.speechPermissionDenied
        }
    }
}
#endif
