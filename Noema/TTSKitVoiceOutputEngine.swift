import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(TTSKit) && !arch(x86_64)
import TTSKit

enum NeuralVoiceError: LocalizedError {
    case modelMissing
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return String(localized: "The neural voice model is not downloaded.")
        case .engineUnavailable:
            return String(localized: "The neural voice engine is unavailable.")
        }
    }
}

/// Qwen3-TTS 0.6B on CoreML/ANE via the TTSKit product of the pinned WhisperKit
/// package. Synthesis runs per sentence; playback goes through our own
/// `VoicePCMPlayer` because `TTSKit.play()` would flip the shared audio session
/// to `.playback` and kill the mic.
@MainActor
final class TTSKitVoiceOutputEngine: VoiceOutputEngine {
    let id: VoiceOutputEngineID = .neural
    var statusDescription: String {
        "Qwen3 TTS · \(VoiceModelCatalog.activeSpeaker.displayName)"
    }
    var levelHandler: (@MainActor (Float) -> Void)? {
        didSet { player.levelHandler = levelHandler }
    }

    /// Owns the generate calls so their synchronous work never runs on the
    /// main actor (an inline `Task {}` would inherit MainActor and stall the
    /// UI for the whole multi-second synthesis).
    private final class SynthWorker: @unchecked Sendable {
        private let tts: TTSKit

        init(tts: TTSKit) {
            self.tts = tts
        }

        func synthesize(text: String, voice: String, language: String) async throws -> SpeechResult {
            try await tts.generate(text: text, voice: voice, language: language)
        }
    }

    private var tts: TTSKit?
    private var worker: SynthWorker?
    private let player = VoicePCMPlayer()
    private var generationTask: Task<SpeechResult, Error>?
    private var stopped = false

    func prepare() async throws {
        guard tts == nil else { return }
        guard let folder = VoiceModelCatalog.installedModelFolder() else {
            await logger.log("[Voice][TTS] prepare: no installed model folder")
            throw NeuralVoiceError.modelMissing
        }
        await logger.log("[Voice][TTS] loading models folder=\(folder.path)")
        let started = ContinuousClock.now
        let instance = try await TTSKit(
            model: .qwen3TTS_0_6b,
            modelFolder: folder,
            download: false
        )
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        await logger.log("[Voice][TTS] models loaded in \(String(format: "%.1f", elapsed))s")
        tts = instance
        worker = SynthWorker(tts: instance)
    }

    func prepareUtterance(_ sentence: String, localeHint: Locale) async throws -> PreparedSpeech {
        guard let worker else { throw NeuralVoiceError.engineUnavailable }
        stopped = false
        let language = VoiceModelCatalog.qwenLanguage(for: localeHint) ?? .english
        let voice = VoiceModelCatalog.activeSpeaker
        let started = ContinuousClock.now
        let task = Task {
            try await worker.synthesize(text: sentence, voice: voice.rawValue, language: language.rawValue)
        }
        generationTask = task
        defer { generationTask = nil }
        let result = try await task.value
        let synthSeconds = (ContinuousClock.now - started) / .seconds(1)
        let rtf = result.audioDuration > 0 ? synthSeconds / result.audioDuration : 0
        await logger.log("[Voice][TTS] synth chars=\(sentence.count) audio=\(String(format: "%.1f", result.audioDuration))s in \(String(format: "%.1f", synthSeconds))s rtf=\(String(format: "%.2f", rtf))")
        return PreparedSpeech(
            sentence: sentence,
            samples: result.audio,
            sampleRate: Double(result.sampleRate)
        )
    }

    func play(_ prepared: PreparedSpeech) async throws {
        guard !stopped, let samples = prepared.samples, let sampleRate = prepared.sampleRate else { return }
        try await player.play(samples: samples, sampleRate: sampleRate)
    }

    func stopSpeaking() {
        stopped = true
        generationTask?.cancel()
        generationTask = nil
        player.stop()
    }

    func unload() async {
        stopSpeaking()
        player.shutdown()
        await tts?.unloadModels()
        tts = nil
    }
}
#endif

#if canImport(AVFoundation)
/// Minimal session-free PCM playback: schedule mono float buffers on an
/// `AVAudioPlayerNode`, await completion, meter the mixer for the orb. Owning
/// this (instead of TTSKit's AudioOutput) is what keeps a future echo-cancelled
/// barge-in path a plumbing swap.
@MainActor
final class VoicePCMPlayer {
    private final class LevelBox: @unchecked Sendable {
        var handler: (@Sendable (Float) -> Void)?
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let levelBox = LevelBox()
    private var connectedSampleRate: Double?
    private var tapInstalled = false

    var levelHandler: (@MainActor (Float) -> Void)? {
        didSet {
            if let levelHandler {
                let forward: @Sendable (Float) -> Void = { level in
                    Task { @MainActor in levelHandler(level) }
                }
                levelBox.handler = forward
            } else {
                levelBox.handler = nil
            }
        }
    }

    func play(samples: [Float], sampleRate: Double) async throws {
        guard !samples.isEmpty else { return }
        try ensureRunning(sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "VoicePCMPlayer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Audio playback failed.")
            ])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, let channel = buffer.floatChannelData?.pointee {
                channel.update(from: base, count: samples.count)
            }
        }
        node.play()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Formed via a nonisolated factory: the completion parameter isn't
            // @Sendable, so an inline closure would inherit MainActor isolation
            // and dispatch-assert on the player's internal queue.
            node.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: Self.makePlaybackCompletion(continuation)
            )
        }
        levelBox.handler?(0)
    }

    private nonisolated static func makePlaybackCompletion(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in continuation.resume() }
    }

    func stop() {
        // Stopping the node fires pending completion handlers, resuming play().
        guard engine.isRunning || node.isPlaying else { return }
        node.stop()
        levelBox.handler?(0)
    }

    func shutdown() {
        stop()
        if tapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        connectedSampleRate = nil
    }

    private func ensureRunning(sampleRate: Double) throws {
        if connectedSampleRate != sampleRate {
            if node.engine != nil {
                node.stop()
                engine.disconnectNodeOutput(node)
            } else {
                engine.attach(node)
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw NSError(domain: "VoicePCMPlayer", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Audio playback failed.")
                ])
            }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedSampleRate = sampleRate
        }
        if !tapInstalled {
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.makeMeterTap(box: levelBox))
            tapInstalled = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private nonisolated static func makeMeterTap(box: LevelBox) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let data = buffer.floatChannelData?.pointee else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for i in 0..<frames {
                let sample = data[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frames))
            let db = 20 * log10(max(rms, .leastNonzeroMagnitude))
            box.handler?(max(0, min(1, (db + 55) / 55)))
        }
    }
}
#endif
