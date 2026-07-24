import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

enum AppSound: Hashable, Sendable {
    case error
    case loadPress
    case loadSuccess

    var resourceName: String {
        switch self {
        case .error:
            return "Error"
        case .loadPress:
            return "LoadPress"
        case .loadSuccess:
            return "LoadSuccess"
        }
    }

    var fileExtension: String {
        switch self {
        case .loadSuccess:
            return "mp3"
        default:
            return "wav"
        }
    }
}

@MainActor
enum AppSoundPlayer {
#if canImport(AVFoundation)
    private static var players: [AppSound: AVAudioPlayer] = [:]

    private static var soundsMuted: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "muteSoundEffects") as? Bool ?? false
    }

#if os(iOS)
    private static var playInSilentMode: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "playSoundEffectsInSilentMode") as? Bool ?? false
    }
#endif
#endif

    static func play(_ sound: AppSound) {
#if canImport(AVFoundation)
        guard !soundsMuted else { return }
        // Never flip the shared session category out from under a live voice
        // feature (dictation / voice mode) — it would silently kill the mic.
        guard !VoiceSessionOwnership.shared.isOwned else { return }
#if os(iOS)
        // AVAudioSession setCategory / setActive must NOT be called on the main thread
        // while the session is active — it can cause UI unresponsiveness. Move that work
        // to a background queue and bounce back to main only for the actual playback.
        let wantsSilentMode = playInSilentMode
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            do {
                let category: AVAudioSession.Category = wantsSilentMode ? .playback : .ambient
                try session.setCategory(category, mode: .default, options: [.mixWithOthers])
                try session.setActive(true, options: [])
            } catch {
                // If session setup fails, bail out silently.
                return
            }
            Task { @MainActor in
                guard let player = player(for: sound) else { return }
                player.currentTime = 0
                player.play()
            }
        }
#else
        guard let player = player(for: sound) else { return }
        player.currentTime = 0
        player.play()
#endif
#endif
    }
}

#if canImport(AVFoundation)
@MainActor
private extension AppSoundPlayer {
    static func player(for sound: AppSound) -> AVAudioPlayer? {
        if let existing = players[sound] {
            return existing
        }
        guard let url = resourceURL(for: sound) else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[sound] = player
            return player
        } catch {
            return nil
        }
    }

    static func resourceURL(for sound: AppSound) -> URL? {
        let subdirectories: [String?] = [
            nil,
            "sounds",
            "Sounds",
            "resources",
            "resources/sounds",
            "Resources",
            "Resources/sounds",
            "Resources/Sounds"
        ]
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: sound.resourceName,
                withExtension: sound.fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }
}
#endif
