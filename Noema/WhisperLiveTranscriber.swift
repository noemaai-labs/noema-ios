import Foundation
#if canImport(WhisperKit) && canImport(AVFoundation)
import AVFoundation
import WhisperKit

/// Live utterance transcription on the user's selected WhisperKit model: one
/// warm pipe per voice session, mic capture via WhisperKit's `AudioProcessor`,
/// energy-based endpointing, periodic partial passes over the growing buffer,
/// and a full-buffer pass on endpoint for the final text.
@MainActor
final class WhisperLiveTranscriber: VoiceLiveTranscriber {
    let events: AsyncStream<VoiceTranscriberEvent>
    private let eventsContinuation: AsyncStream<VoiceTranscriberEvent>.Continuation

    private nonisolated static let silenceThreshold: Float = 0.22
    private nonisolated static let endpointSilenceSeconds: Double = 1.0
    private nonisolated static let minVoicedSeconds: Double = 0.6
    private nonisolated static let maxUtteranceSeconds: Double = 30
    private nonisolated static let partialInterval: Duration = .milliseconds(900)
    private nonisolated static let pollInterval: Duration = .milliseconds(250)
    private nonisolated static let sampleRate = 16_000

    /// Owns the async transcription calls so the non-Sendable pipe never has
    /// to cross out of the MainActor region (region-isolation would reject a
    /// direct `pipe.transcribe` while `pipe` stays stored on this class).
    private final class TranscribeWorker: @unchecked Sendable {
        private let pipe: WhisperKit
        private let languageCode: String?

        init(pipe: WhisperKit, languageCode: String?) {
            self.pipe = pipe
            self.languageCode = languageCode
        }

        func transcribe(samples: [Float]) async throws -> String {
            guard Double(samples.count) / Double(WhisperLiveTranscriber.sampleRate) >= 0.4 else { return "" }
            var options = DecodingOptions()
            options.task = .transcribe
            options.language = languageCode
            options.temperature = 0
            options.skipSpecialTokens = true
            options.withoutTimestamps = true
            let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            return results
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var pipe: WhisperKit?
    private var worker: TranscribeWorker?
    private var languageCode: String?
    private var utteranceTask: Task<Void, Never>?
    private var generation = 0
    private var stopRequested = false
    private var utteranceActive = false
    private var finalizeWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastPartial = ""
    private var partialPassBusy = false

    init() {
        var continuation: AsyncStream<VoiceTranscriberEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    func prepare() async throws {
        guard await VoiceMicrophonePermission.request() else {
            throw VoiceTranscriberError.microphonePermissionDenied
        }
        guard pipe == nil else { return }
        let activeID = WhisperModelCatalog.activeRecordID(for: .whisperKit)
        guard let record = WhisperModelCatalog.record(for: activeID),
              let artifact = record.artifact(for: .whisperKit),
              WhisperModelCatalog.installationState(for: record, runtime: .whisperKit) == .ready else {
            throw VoiceTranscriberError.recognizerUnavailable
        }
        let folder = WhisperModelCatalog.whisperKitModelFolderURL(recordID: record.id, artifact: artifact)
        await logger.log("[Voice][Whisper] loading model=\(record.id)")
        let started = ContinuousClock.now
        let loaded = try await WhisperKit(modelFolder: folder.path)
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        await logger.log("[Voice][Whisper] model loaded in \(String(format: "%.1f", elapsed))s")
        let language = record.multilingual
            ? AppleSpeechLocaleHelper.shortLanguageCode(from: TranscriptionSettings.preferredLocaleIdentifier)
            : "en"
        pipe = loaded
        languageCode = language
        worker = TranscribeWorker(pipe: loaded, languageCode: language)
    }

    func startUtterance() async throws {
        guard let pipe else { throw VoiceTranscriberError.recognizerUnavailable }
        cancelUtterance()

        generation += 1
        let currentGeneration = generation
        stopRequested = false
        utteranceActive = true
        lastPartial = ""
        partialPassBusy = false

        let processor = pipe.audioProcessor
        processor.purgeAudioSamples(keepingLast: 0)
        // The callback parameter predates Sendable annotations, so a closure
        // literal formed here would inherit MainActor isolation and trip
        // dispatch_assert_queue when the audio tap thread invokes it.
        try processor.startRecordingLive(
            inputDeviceID: nil,
            callback: Self.makeLevelCallback(continuation: eventsContinuation)
        )

        utteranceTask = Task { @MainActor [weak self] in
            await self?.runUtteranceLoop(generation: currentGeneration)
        }
    }

    func stopAndFinalize() async {
        guard utteranceActive else { return }
        stopRequested = true
        await withCheckedContinuation { continuation in
            if utteranceActive {
                finalizeWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func cancelUtterance() {
        generation += 1
        utteranceTask?.cancel()
        utteranceTask = nil
        pipe?.audioProcessor.stopRecording()
        pipe?.audioProcessor.purgeAudioSamples(keepingLast: 0)
        settleUtterance()
    }

    func suspend() {
        cancelUtterance()
    }

    func tearDown() {
        cancelUtterance()
        pipe = nil
        eventsContinuation.finish()
    }

    // MARK: - Internals

    private func runUtteranceLoop(generation: Int) async {
        var lastPartialPass = ContinuousClock.now - Self.partialInterval
        var pollCount = 0
        var deadInputChecked = false

        while !Task.isCancelled, self.generation == generation, let pipe {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled, self.generation == generation else { return }

            let processor = pipe.audioProcessor
            let energies = processor.relativeEnergy
            // audioEnergy (raw RMS tuples) lives on the concrete class only.
            let rawEnergies = (processor as? AudioProcessor)?.audioEnergy.map { $0.avg } ?? []
            let sampleCount = processor.audioSamples.count
            let seconds = Double(sampleCount) / Double(Self.sampleRate)

            // Raw RMS separates "true digital silence" (dead route / muted
            // input) from quiet-but-live audio, which relative energy cannot.
            let peakRawEnergy = rawEnergies.max() ?? 0
            if !deadInputChecked, seconds >= 3 {
                deadInputChecked = true
                if peakRawEnergy < 1e-7 {
#if os(iOS) || os(visionOS)
                    let route = AVAudioSession.sharedInstance().currentRoute.inputs
                        .map { $0.portType.rawValue }
                        .joined(separator: ",")
#else
                    let route = "n/a"
#endif
                    Task { await logger.log("[Voice][Whisper] input DEAD peak=\(peakRawEnergy) route=[\(route)] — aborting utterance") }
                    processor.stopRecording()
                    processor.purgeAudioSamples(keepingLast: 0)
                    utteranceTask = nil
                    settleUtterance()
                    eventsContinuation.yield(.failed(String(localized: "The microphone is delivering silence. Check the mic mute in Control Center or disconnect Bluetooth audio devices.")))
                    return
                }
            }

            // Energy entries are one per tap buffer, and iOS taps don't honor
            // the requested 100 ms size — derive the real per-frame duration
            // from the data instead of assuming it.
            let frameDuration = energies.isEmpty
                ? 0.1
                : max(0.02, min(0.5, seconds / Double(energies.count)))
            let voicedFrames = energies.filter { $0 > Self.silenceThreshold }.count
            let voicedSeconds = Double(voicedFrames) * frameDuration

            // Judge the trailing window as a whole, tolerating isolated spikes
            // (a breath or rustle must not reset the silence run).
            let windowFrames = max(2, Int((Self.endpointSilenceSeconds / frameDuration).rounded()))
            let tail = energies.suffix(windowFrames)
            let tailVoiced = tail.filter { $0 > Self.silenceThreshold }.count
            let tailIsSilent = tail.count >= windowFrames && tailVoiced <= max(1, windowFrames / 8)

            let naturalEndpoint = voicedSeconds >= Self.minVoicedSeconds && tailIsSilent
            let forcedEndpoint = stopRequested || seconds >= Self.maxUtteranceSeconds

            pollCount += 1
            if pollCount % 8 == 0 {
                let recentPeak = rawEnergies.suffix(8).max() ?? 0
                let recentDB = Int(20 * log10(Double(max(recentPeak, 1e-9))))
                let summary = "buffer=\(String(format: "%.1f", seconds))s frames=\(energies.count) frameDur=\(Int(frameDuration * 1000))ms voiced=\(String(format: "%.1f", voicedSeconds))s tailVoiced=\(tailVoiced)/\(tail.count) peakDB=\(recentDB) partialBusy=\(partialPassBusy)"
                Task { await logger.log("[Voice][Whisper] listening \(summary)") }
            }

            if naturalEndpoint || forcedEndpoint {
                processor.pauseRecording()
                Task { await logger.log("[Voice][Whisper] endpoint voiced=\(String(format: "%.1f", voicedSeconds))s tailVoiced=\(tailVoiced)/\(tail.count) forced=\(forcedEndpoint) buffer=\(String(format: "%.1f", seconds))s") }
                // Let an in-flight partial pass drain so the pipe never runs
                // two transcriptions at once.
                while partialPassBusy, self.generation == generation, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard self.generation == generation else { return }
                let samples = Array(processor.audioSamples)
                var text = lastPartial
                if let worker, let result = try? await worker.transcribe(samples: samples), !result.isEmpty {
                    text = result
                }
                guard self.generation == generation else { return }
                Task { await logger.log("[Voice][Whisper] final chars=\(text.count)") }
                finish(with: text)
                return
            }

            let now = ContinuousClock.now
            if voicedSeconds >= Self.minVoicedSeconds,
               !partialPassBusy,
               now - lastPartialPass >= Self.partialInterval {
                partialPassBusy = true
                lastPartialPass = now
                startPartialPass(generation: generation, samples: Array(processor.audioSamples), bufferSeconds: seconds)
            }
        }
    }

    /// Partial passes run detached from the poll loop: a slow model must never
    /// starve the endpoint detector, or the session sits in "listening" long
    /// after the user stopped talking.
    private func startPartialPass(generation: Int, samples: [Float], bufferSeconds: Double) {
        let worker = worker
        Task { @MainActor [weak self] in
            let started = ContinuousClock.now
            var partial = ""
            if let worker, let result = try? await worker.transcribe(samples: samples) {
                partial = result
            }
            let passSeconds = (ContinuousClock.now - started) / .seconds(1)
            guard let self, self.generation == generation else { return }
            self.partialPassBusy = false
            if passSeconds > 2 {
                Task { await logger.log("[Voice][Whisper] slow partial pass \(String(format: "%.1f", passSeconds))s buffer=\(String(format: "%.1f", bufferSeconds))s") }
            }
            if self.utteranceActive, !partial.isEmpty, partial != self.lastPartial {
                self.lastPartial = partial
                self.eventsContinuation.yield(.partial(partial))
            }
        }
    }

    private func finish(with text: String) {
        pipe?.audioProcessor.stopRecording()
        pipe?.audioProcessor.purgeAudioSamples(keepingLast: 0)
        utteranceTask = nil
        settleUtterance()
        eventsContinuation.yield(.finalized(text))
    }

    private func settleUtterance() {
        utteranceActive = false
        let waiters = finalizeWaiters
        finalizeWaiters = []
        waiters.forEach { $0.resume() }
    }

    private nonisolated static func makeLevelCallback(
        continuation: AsyncStream<VoiceTranscriberEvent>.Continuation
    ) -> ([Float]) -> Void {
        { buffer in
            continuation.yield(.level(normalizedLevel(of: buffer)))
        }
    }

    private nonisolated static func normalizedLevel(of buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in buffer {
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(buffer.count))
        let db = 20 * log10(max(rms, .leastNonzeroMagnitude))
        return max(0, min(1, (db + 55) / 55))
    }
}
#endif
