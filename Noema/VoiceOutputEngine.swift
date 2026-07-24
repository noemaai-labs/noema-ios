import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

enum VoiceOutputEngineID: String, CaseIterable, Sendable {
    case neural = "neural_tts"
    case system = "system"
}

enum VoiceOutputSettings {
    static let engineKey = "voiceOutputEngine"
    static let voiceIDKey = "voiceModelVoiceID"
    static let systemRateKey = "voiceSystemRate"

    static var preferredEngineID: VoiceOutputEngineID {
        let raw = UserDefaults.standard.string(forKey: engineKey) ?? VoiceOutputEngineID.neural.rawValue
        return VoiceOutputEngineID(rawValue: raw) ?? .neural
    }

    static var selectedVoiceID: String? {
        UserDefaults.standard.string(forKey: voiceIDKey)
    }

#if canImport(AVFoundation)
    static var systemRate: Float {
        guard let stored = UserDefaults.standard.object(forKey: systemRateKey) as? Double else {
            return AVSpeechUtteranceDefaultSpeechRate
        }
        return Float(max(Double(AVSpeechUtteranceMinimumSpeechRate), min(Double(AVSpeechUtteranceMaximumSpeechRate), stored)))
    }
#endif
}

/// One spoken sentence at a time; `speak` suspends until playback ends or
/// `stopSpeaking` cuts it off. Engines keep whatever they load warm across
/// sentences within a voice session.
/// Synthesized-but-not-yet-played sentence. Neural engines carry PCM; the
/// system engine synthesizes at play time and carries only the text.
final class PreparedSpeech: @unchecked Sendable {
    let sentence: String
    let samples: [Float]?
    let sampleRate: Double?

    init(sentence: String, samples: [Float]? = nil, sampleRate: Double? = nil) {
        self.sentence = sentence
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

// Sendable is trivially satisfied (all conformers are @MainActor classes) and
// lets `any VoiceOutputEngine` cross into task groups for timed prepare.
// Synthesis (prepareUtterance) and playback (play) are split so the caller can
// synthesize the next sentence while the current one is still playing —
// essential when synthesis runs below realtime.
@MainActor
protocol VoiceOutputEngine: AnyObject, Sendable {
    var id: VoiceOutputEngineID { get }
    var statusDescription: String { get }
    var levelHandler: (@MainActor (Float) -> Void)? { get set }
    func prepare() async throws
    func prepareUtterance(_ sentence: String, localeHint: Locale) async throws -> PreparedSpeech
    func play(_ prepared: PreparedSpeech) async throws
    func stopSpeaking()
    func unload() async
}

enum VoiceEngineResolution {
    case engine(any VoiceOutputEngine)
    case needsVoiceModel
}

enum VoiceOutputEngineFactory {
    /// Fallback ladder: neural (TTSKit, Apple silicon, enough RAM, weights
    /// installed) → system voice. `.needsVoiceModel` only when neural is viable
    /// on this device but the weights haven't been downloaded yet.
    @MainActor
    static func resolve() -> VoiceEngineResolution {
#if canImport(TTSKit) && !arch(x86_64)
        if VoiceOutputSettings.preferredEngineID == .neural, neuralHardwareSupported {
            switch VoiceModelCatalog.installState() {
            case .ready:
                return .engine(TTSKitVoiceOutputEngine())
            case .missing, .incomplete:
                return .needsVoiceModel
            }
        }
#endif
        return .engine(SystemVoiceOutputEngine())
    }

    @MainActor
    static var neuralHardwareSupported: Bool {
#if canImport(TTSKit) && !arch(x86_64)
        return ProcessInfo.processInfo.physicalMemory >= 4 * 1_073_741_824
#else
        return false
#endif
    }
}

/// Speaks a short sample through the currently-resolved engine for the
/// Settings preview button. Neural engines are loaded for the preview and
/// unloaded right after — the 0.6B pipeline is too big to keep resident for a
/// settings screen.
@MainActor
final class VoiceSamplePreviewer: ObservableObject {
    static let shared = VoiceSamplePreviewer()

    @Published private(set) var isBusy = false

    func preview() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let engine: any VoiceOutputEngine
        switch VoiceOutputEngineFactory.resolve() {
        case .engine(let resolved):
            engine = resolved
        case .needsVoiceModel:
            // Neural is selected but its weights aren't installed. Don't pass the
            // system voice off as a neural preview — Settings gates this button and
            // prompts the user to download the model first.
            return
        }
        do {
            try await engine.prepare()
        } catch {
            await engine.unload()
            return
        }
#if canImport(Speech)
        let localeID = AppleSpeechTranscriptionBackend.resolveLocaleIdentifier(
            TranscriptionSettings.preferredLocaleIdentifier
        )
#else
        let localeID = Locale.current.identifier
#endif
        let sample = String(localized: "Hi! This is your Noema voice.")
        if let prepared = try? await engine.prepareUtterance(sample, localeHint: Locale(identifier: localeID)) {
            try? await engine.play(prepared)
        }
        await engine.unload()
    }
}

#if canImport(AVFoundation)
@MainActor
final class SystemVoiceOutputEngine: NSObject, VoiceOutputEngine {
    let id: VoiceOutputEngineID = .system
    var statusDescription: String { String(localized: "System Voice") }
    var levelHandler: (@MainActor (Float) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var completion: CheckedContinuation<Void, Never>?
    private var pulseTask: Task<Void, Never>?
    private var lastLocaleHint = Locale.current

    override init() {
        super.init()
        synthesizer.delegate = self
#if os(iOS) || os(visionOS)
        synthesizer.usesApplicationAudioSession = true
#endif
    }

    func prepare() async throws {}

    func prepareUtterance(_ sentence: String, localeHint: Locale) async throws -> PreparedSpeech {
        lastLocaleHint = localeHint
        return PreparedSpeech(sentence: sentence)
    }

    func play(_ prepared: PreparedSpeech) async throws {
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: prepared.sentence)
        utterance.rate = VoiceOutputSettings.systemRate
        if let voice = Self.resolveVoice(for: lastLocaleHint) {
            utterance.voice = voice
        }
        startLevelPulse()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion = continuation
            synthesizer.speak(utterance)
        }
        stopLevelPulse()
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        finishCurrent()
    }

    func unload() async {
        stopSpeaking()
    }

    private func finishCurrent() {
        stopLevelPulse()
        completion?.resume()
        completion = nil
    }

    // AVSpeechSynthesizer exposes no output metering, so fake a gentle pulse
    // for the speaking orb.
    private func startLevelPulse() {
        pulseTask?.cancel()
        let start = ContinuousClock.now
        pulseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let elapsed = (ContinuousClock.now - start) / .seconds(1)
                let level = 0.45 + 0.3 * Float(sin(elapsed * 5.2)) * Float(0.5 + 0.5 * sin(elapsed * 1.7))
                self?.levelHandler?(max(0, min(1, level)))
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopLevelPulse() {
        pulseTask?.cancel()
        pulseTask = nil
        levelHandler?(0)
    }

    private static func resolveVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: locale.identifier.replacingOccurrences(of: "_", with: "-")) {
            return exact
        }
        if let language = locale.language.languageCode?.identifier {
            return AVSpeechSynthesisVoice(language: language)
        }
        return nil
    }
}

extension SystemVoiceOutputEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishCurrent() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishCurrent() }
    }
}
#endif
