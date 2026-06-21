import Foundation

/// Central routing for transcription backends. Single integration point so
/// Noema.swift does not need to import every backend directly.
enum TranscriptionBackendFactory {
    static var localWhisperDisplayName: String {
        String(localized: "Local Whisper")
    }

    /// Returns the concrete backend for the engine the user has selected.
    /// Unavailable backends fail explicitly so user-selected privacy and
    /// engine behavior never change silently.
    static func makeBackend(for engineID: TranscriptionEngineID) throws -> any TranscriptionBackend {
        switch engineID {
        case .appleSpeech:
            return AppleSpeechTranscriptionBackend()
        case .whisperKit:
            #if canImport(WhisperKit)
            return WhisperKitTranscriptionBackend()
            #else
            throw unavailableError(for: engineID)
            #endif
        case .whisperCpp:
            if NoemaWhisperCpp.isAvailable() {
                return WhisperCppTranscriptionBackend()
            }
            throw unavailableError(for: engineID)
        case .audioLanguageModel:
            if let backend = AudioLMRemoteBackend.makeIfConfigured() {
                return backend
            }
            throw unavailableError(for: engineID)
        }
    }

    /// Primary engines shown in Settings. Whisper runtimes stay internal to the
    /// Local Whisper detail screen, and remote ASR is configured separately.
    static func primaryEngineChoices() -> [EngineAvailability] {
        let local = preferredLocalWhisperEngineID()
        return [
            EngineAvailability(id: .appleSpeech, isAvailable: true, unavailableReason: nil),
            EngineAvailability(id: local, isAvailable: isLocalWhisperAvailable, unavailableReason: localWhisperUnavailableReason)
        ]
    }

    /// Full backend list for diagnostics/tests. Settings should prefer
    /// `primaryEngineChoices()` so unavailable advanced engines stay hidden.
    static func availableEngines() -> [EngineAvailability] {
        TranscriptionEngineID.allCases.map { id in
            EngineAvailability(id: id, isAvailable: isAvailable(id), unavailableReason: unavailableReason(for: id))
        }
    }

    static var isLocalWhisperAvailable: Bool {
        isAvailable(.whisperKit) || isAvailable(.whisperCpp)
    }

    static var localWhisperUnavailableReason: String? {
        isLocalWhisperAvailable ? nil : String(localized: "No local Whisper runtime is available in this build.")
    }

    static func preferredLocalWhisperEngineID() -> TranscriptionEngineID {
        #if canImport(WhisperKit)
        return .whisperKit
        #else
        return NoemaWhisperCpp.isAvailable() ? .whisperCpp : .whisperKit
        #endif
    }

    static func resolvedLocalWhisperEngineID(preferred: TranscriptionEngineID? = nil) -> TranscriptionEngineID {
        if let preferred, preferred.isLocalWhisper, isAvailable(preferred) {
            return preferred
        }
        return preferredLocalWhisperEngineID()
    }

    static func isAvailable(_ engineID: TranscriptionEngineID) -> Bool {
        switch engineID {
        case .appleSpeech:
            return true
        case .whisperKit:
            #if canImport(WhisperKit)
            return true
            #else
            return false
            #endif
        case .whisperCpp:
            return NoemaWhisperCpp.isAvailable()
        case .audioLanguageModel:
            return AudioLMRemoteBackend.isConfigured
        }
    }

    static func unavailableReason(for engineID: TranscriptionEngineID) -> String? {
        guard !isAvailable(engineID) else { return nil }
        switch engineID {
        case .appleSpeech:
            return nil
        case .whisperKit:
            return String(localized: "WhisperKit is not linked in this build.")
        case .whisperCpp:
            return String(localized: "whisper.cpp is not linked in this build.")
        case .audioLanguageModel:
            return String(localized: "Configure a remote endpoint to enable this engine.")
        }
    }

    private static func unavailableError(for engineID: TranscriptionEngineID) -> TranscriptionError {
        TranscriptionError.engineUnavailable(
            engineID.displayName,
            unavailableReason(for: engineID) ?? String(localized: "Choose another transcription engine in Settings.")
        )
    }
}

struct EngineAvailability: Identifiable, Equatable, Sendable {
    let id: TranscriptionEngineID
    let isAvailable: Bool
    let unavailableReason: String?
}
