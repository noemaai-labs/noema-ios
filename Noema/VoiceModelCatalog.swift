import Foundation
#if canImport(TTSKit)
import TTSKit
#endif

enum VoiceModelInstallState: Equatable, Sendable {
    case missing
    case incomplete
    case ready
}

/// Storage + selection bookkeeping for the neural TTS weights, mirroring
/// `WhisperModelCatalog`. Weights live under Documents/LocalLLMModels/TTS so
/// they sit beside the Whisper models in the user's model storage.
enum VoiceModelCatalog {
    /// Short-TTL memo so per-render callers (Stored rows, Settings labels)
    /// don't hit the disk every body evaluation.
    private final class StateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var state: (value: VoiceModelInstallState, at: Date)?
        private var size: (value: Int64, at: Date)?
        private let ttl: TimeInterval = 2

        func cachedState() -> VoiceModelInstallState? {
            lock.lock()
            defer { lock.unlock() }
            guard let state, Date().timeIntervalSince(state.at) < ttl else { return nil }
            return state.value
        }

        func store(state value: VoiceModelInstallState) {
            lock.lock()
            state = (value, Date())
            lock.unlock()
        }

        func cachedSize() -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            guard let size, Date().timeIntervalSince(size.at) < ttl else { return nil }
            return size.value
        }

        func store(size value: Int64) {
            lock.lock()
            size = (value, Date())
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            state = nil
            size = nil
            lock.unlock()
        }
    }

    private static let cache = StateCache()

    static let recordID = "qwen3-tts-0.6b"
    static let displayName = "Qwen3 TTS 0.6B"
    /// Rough W8A16 component total, for UI copy before a download begins.
    static let approximateSizeBytes: Int64 = 1_050_000_000

    static let installedRelativePathKey = "voiceModelInstalledRelativePath"

    static var baseDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMModels/TTS", isDirectory: true)
    }

    /// Records the model folder returned by `TTSKit.download`, stored relative
    /// to Documents so container migrations don't invalidate it.
    static func recordInstalled(folder: URL) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folderPath = folder.standardizedFileURL.path
        let documentsPath = documents.standardizedFileURL.path
        if folderPath.hasPrefix(documentsPath + "/") {
            let relative = String(folderPath.dropFirst(documentsPath.count + 1))
            UserDefaults.standard.set(relative, forKey: installedRelativePathKey)
        } else {
            UserDefaults.standard.set(folderPath, forKey: installedRelativePathKey)
        }
        cache.invalidate()
    }

    static func clearInstalledRecord() {
        UserDefaults.standard.removeObject(forKey: installedRelativePathKey)
        cache.invalidate()
    }

    static func installedModelFolder() -> URL? {
        guard let stored = UserDefaults.standard.string(forKey: installedRelativePathKey) else { return nil }
        let url: URL
        if stored.hasPrefix("/") {
            url = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(stored, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    static func installState() -> VoiceModelInstallState {
        if let cached = cache.cachedState() { return cached }
        let resolved = resolveInstallState()
        cache.store(state: resolved)
        return resolved
    }

    private static func resolveInstallState() -> VoiceModelInstallState {
        if let folder = installedModelFolder() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return contents.isEmpty ? .incomplete : .ready
        }
        // Self-heal: adopt a completed download whose record was lost — e.g.
        // the app died between the Hub download finishing and the record write,
        // or the container path changed. Saves re-downloading ~1 GB.
        if let adopted = probeForExistingInstall() {
            recordInstalled(folder: adopted)
            Task { await logger.log("[Voice] adopted stranded voice model install at \(adopted.path)") }
            return .ready
        }
        return UserDefaults.standard.string(forKey: installedRelativePathKey) == nil ? .missing : .incomplete
    }

    /// Hub layout under `baseDirectory` is `models/<org>/<repo>/qwen3_tts/…`;
    /// a non-empty `qwen3_tts` directory identifies a usable model folder.
    private static func probeForExistingInstall() -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 400 { return nil }
            guard url.lastPathComponent == "qwen3_tts",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let contents = try? fm.contentsOfDirectory(atPath: url.path),
                  !contents.isEmpty else { continue }
            return url.deletingLastPathComponent()
        }
        return nil
    }

    static func deleteInstalledModel() {
        if let folder = installedModelFolder() {
            try? FileManager.default.removeItem(at: folder)
        }
        try? FileManager.default.removeItem(at: baseDirectory)
        clearInstalledRecord()
    }

    static var installedSizeBytes: Int64 {
        if let cached = cache.cachedSize() { return cached }
        let computed = computeInstalledSizeBytes()
        cache.store(size: computed)
        return computed
    }

    private static func computeInstalledSizeBytes() -> Int64 {
        guard let folder = installedModelFolder(),
              let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
              ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

#if canImport(TTSKit)
    static var activeSpeaker: Qwen3Speaker {
        guard let raw = VoiceOutputSettings.selectedVoiceID,
              let speaker = Qwen3Speaker(rawValue: raw) else { return .ryan }
        return speaker
    }

    static func qwenLanguage(for locale: Locale) -> Qwen3Language? {
        switch locale.language.languageCode?.identifier {
        case "en": return .english
        case "zh": return .chinese
        case "ja": return .japanese
        case "ko": return .korean
        case "de": return .german
        case "fr": return .french
        case "ru": return .russian
        case "pt": return .portuguese
        case "es": return .spanish
        case "it": return .italian
        default: return nil
        }
    }
#endif
}
