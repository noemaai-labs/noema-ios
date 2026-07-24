import Foundation

enum WhisperRuntimeFormat: String, Codable, CaseIterable, Sendable {
    case whisperKit
    case ggml
}

enum WhisperModelInstallState: Equatable, Sendable {
    case ready
    case missing
    case incomplete
}

struct WhisperArtifact: Identifiable, Codable, Equatable, Sendable {
    /// Stable identifier unique within a record/runtime combination.
    let id: String
    let runtime: WhisperRuntimeFormat
    /// Approximate on-disk size, used for download progress + RAM estimation.
    let sizeBytes: Int64
    /// Hugging Face repo ID. WhisperKit models live under argmaxinc/whisperkit-coreml,
    /// ggml models live under ggerganov/whisper.cpp.
    let repoID: String
    /// Within the repo. For WhisperKit this is a directory under `openai_whisper-*/`.
    /// For ggml this is a single `.bin` filename.
    let resourcePath: String
    /// Direct download URL. For WhisperKit packages we rely on the runtime's
    /// own download machinery, so this may be nil.
    let downloadURL: URL?
}

struct WhisperModelRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let sizeTier: String
    let summary: String
    /// True if the model includes non-English training data.
    let multilingual: Bool
    /// Preferred locale for UX surfaces — e.g. "en-US" for English-only,
    /// "auto" for multilingual variants.
    let defaultLocale: String
    let isRecommended: Bool
    let artifacts: [WhisperArtifact]

    func artifact(for runtime: WhisperRuntimeFormat) -> WhisperArtifact? {
        artifacts.first { $0.runtime == runtime }
    }

    func directoryURL(runtime: WhisperRuntimeFormat) -> URL {
        WhisperModelCatalog.directoryURL(recordID: id, runtime: runtime)
    }

    func installedURL(runtime: WhisperRuntimeFormat) -> URL? {
        guard let artifact = artifact(for: runtime) else { return nil }
        switch runtime {
        case .whisperKit:
            return WhisperModelCatalog.whisperKitModelFolderURL(recordID: id, artifact: artifact)
        case .ggml:
            let dir = directoryURL(runtime: runtime)
            return dir.appendingPathComponent(URL(fileURLWithPath: artifact.resourcePath).lastPathComponent)
        }
    }

    func isInstalled(runtime: WhisperRuntimeFormat) -> Bool {
        WhisperModelCatalog.installationState(for: self, runtime: runtime) == .ready
    }
}

enum WhisperModelCatalog {
    static var baseDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMModels/Whisper", isDirectory: true)
    }

    static func directoryURL(recordID: String, runtime: WhisperRuntimeFormat) -> URL {
        baseDirectory
            .appendingPathComponent(runtime.rawValue, isDirectory: true)
            .appendingPathComponent(recordID, isDirectory: true)
    }

    static func whisperKitModelFolderURL(recordID: String, artifact: WhisperArtifact) -> URL {
        let repoComponents = artifact.repoID.split(separator: "/").map(String.init)
        var url = directoryURL(recordID: recordID, runtime: .whisperKit)
            .appendingPathComponent("models", isDirectory: true)
        for component in repoComponents {
            url.appendPathComponent(component, isDirectory: true)
        }
        return url.appendingPathComponent(artifact.resourcePath, isDirectory: true)
    }

    private final class InstallStateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (state: WhisperModelInstallState, time: Date)] = [:]
        func get(_ k: String) -> WhisperModelInstallState? {
            lock.lock(); defer { lock.unlock() }
            if let e = map[k], Date().timeIntervalSince(e.time) < 1.5 { return e.state }
            return nil
        }
        func set(_ k: String, _ v: WhisperModelInstallState) {
            lock.lock(); defer { lock.unlock() }
            map[k] = (v, Date())
        }
    }
    private static let installStateCache = InstallStateCache()

    /// Throttled cache (~1.5s). The underlying check walks the WhisperKit package directory
    /// recursively and is read from StoredView.body on every render (~5Hz while a download is
    /// active), which stalled the main thread. The brief staleness is fine for an install badge.
    static func installationState(for record: WhisperModelRecord, runtime: WhisperRuntimeFormat) -> WhisperModelInstallState {
        let key = "\(record.id)|\(runtime)"
        if let cached = installStateCache.get(key) { return cached }
        let result = computeInstallationState(for: record, runtime: runtime)
        installStateCache.set(key, result)
        return result
    }
    private static func computeInstallationState(for record: WhisperModelRecord, runtime: WhisperRuntimeFormat) -> WhisperModelInstallState {
        guard record.artifact(for: runtime) != nil,
              let installedURL = record.installedURL(runtime: runtime) else {
            return .missing
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        switch runtime {
        case .ggml:
            guard fm.fileExists(atPath: installedURL.path, isDirectory: &isDir) else {
                return .missing
            }
            if isDir.boolValue { return .incomplete }
            let size = (try? installedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 0 ? .ready : .incomplete

        case .whisperKit:
            let runtimeDir = record.directoryURL(runtime: .whisperKit)
            guard fm.fileExists(atPath: runtimeDir.path, isDirectory: &isDir), isDir.boolValue else {
                return .missing
            }
            guard fm.fileExists(atPath: installedURL.path, isDirectory: &isDir), isDir.boolValue else {
                return containsIncompleteWhisperKitDownload(in: runtimeDir) ? .incomplete : .missing
            }
            return whisperKitPackageLooksUsable(at: installedURL, fileManager: fm) ? .ready : .incomplete
        }
    }

    static func containsIncompleteWhisperKitDownload(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else {
            return false
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent.contains(".incomplete") ||
                url.path.contains("/.cache/huggingface/download/") {
                return true
            }
        }
        return false
    }

    private static func whisperKitPackageLooksUsable(at modelFolder: URL, fileManager fm: FileManager) -> Bool {
        guard let enumerator = fm.enumerator(
            at: modelFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var hasModelDirectory = false
        var hasWeightsFile = false
        for case let url as URL in enumerator where url.pathExtension == "mlmodelc" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                hasModelDirectory = true
                let weightsDir = url.appendingPathComponent("weights", isDirectory: true)
                if let files = try? fm.contentsOfDirectory(
                    at: weightsDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ), files.contains(where: { fileURL in
                    (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }) {
                    hasWeightsFile = true
                }
            }
        }

        return hasModelDirectory && hasWeightsFile
    }

    static func record(for id: String) -> WhisperModelRecord? {
        records.first { $0.id == id }
    }

    static func activeRecordID(for engineID: TranscriptionEngineID) -> String {
        let key = activeKey(for: engineID)
        if let stored = UserDefaults.standard.string(forKey: key),
           record(for: stored) != nil {
            return stored
        }
        return defaultRecordID(for: engineID)
    }

    static func activeRecord(for engineID: TranscriptionEngineID) -> WhisperModelRecord? {
        record(for: activeRecordID(for: engineID))
    }

    static func setActiveRecordID(_ id: String, for engineID: TranscriptionEngineID) {
        UserDefaults.standard.set(id, forKey: activeKey(for: engineID))
    }

    private static func activeKey(for engineID: TranscriptionEngineID) -> String {
        switch engineID {
        case .whisperKit:
            return TranscriptionSettings.whisperKitActiveModelKey
        case .whisperCpp:
            return TranscriptionSettings.whisperCppActiveModelKey
        default:
            return TranscriptionSettings.whisperKitActiveModelKey
        }
    }

    private static func defaultRecordID(for engineID: TranscriptionEngineID) -> String {
        "whisper-tiny"
    }

    static func runtimeFormat(for engineID: TranscriptionEngineID) -> WhisperRuntimeFormat? {
        switch engineID {
        case .whisperKit: return .whisperKit
        case .whisperCpp: return .ggml
        default: return nil
        }
    }

    /// Curated Whisper models. Sizes are approximate and are used only for
    /// UI feedback (device-fit badge). The ggml URLs are served from the
    /// official whisper.cpp release bucket at HuggingFace.
    static let records: [WhisperModelRecord] = [
        WhisperModelRecord(
            id: "whisper-tiny",
            displayName: "Whisper Tiny",
            sizeTier: "Tiny",
            summary: "Fast, low-accuracy multilingual baseline. Good for real-time drafts.",
            multilingual: true,
            defaultLocale: "auto",
            isRecommended: true,
            artifacts: [
                WhisperArtifact(
                    id: "whisperkit-openai-whisper-tiny",
                    runtime: .whisperKit,
                    sizeBytes: 80_000_000,
                    repoID: "argmaxinc/whisperkit-coreml",
                    resourcePath: "openai_whisper-tiny",
                    downloadURL: nil
                ),
                WhisperArtifact(
                    id: "ggml-tiny",
                    runtime: .ggml,
                    sizeBytes: 77_700_000,
                    repoID: "ggerganov/whisper.cpp",
                    resourcePath: "ggml-tiny.bin",
                    downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin?download=1")
                )
            ]
        ),
        WhisperModelRecord(
            id: "whisper-tiny-en",
            displayName: "Whisper Tiny (English)",
            sizeTier: "Tiny",
            summary: "English-only variant. Lower WER than multilingual tiny on English audio.",
            multilingual: false,
            defaultLocale: "en-US",
            isRecommended: false,
            artifacts: [
                WhisperArtifact(
                    id: "whisperkit-openai-whisper-tiny.en",
                    runtime: .whisperKit,
                    sizeBytes: 80_000_000,
                    repoID: "argmaxinc/whisperkit-coreml",
                    resourcePath: "openai_whisper-tiny.en",
                    downloadURL: nil
                ),
                WhisperArtifact(
                    id: "ggml-tiny.en",
                    runtime: .ggml,
                    sizeBytes: 77_700_000,
                    repoID: "ggerganov/whisper.cpp",
                    resourcePath: "ggml-tiny.en.bin",
                    downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin?download=1")
                )
            ]
        ),
        WhisperModelRecord(
            id: "whisper-base",
            displayName: "Whisper Base",
            sizeTier: "Base",
            summary: "Solid multilingual tradeoff between speed and accuracy.",
            multilingual: true,
            defaultLocale: "auto",
            isRecommended: false,
            artifacts: [
                WhisperArtifact(
                    id: "whisperkit-openai-whisper-base",
                    runtime: .whisperKit,
                    sizeBytes: 145_000_000,
                    repoID: "argmaxinc/whisperkit-coreml",
                    resourcePath: "openai_whisper-base",
                    downloadURL: nil
                ),
                WhisperArtifact(
                    id: "ggml-base",
                    runtime: .ggml,
                    sizeBytes: 147_000_000,
                    repoID: "ggerganov/whisper.cpp",
                    resourcePath: "ggml-base.bin",
                    downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin?download=1")
                )
            ]
        ),
        WhisperModelRecord(
            id: "whisper-small",
            displayName: "Whisper Small",
            sizeTier: "Small",
            summary: "Noticeably more accurate than base; still comfortable on phones.",
            multilingual: true,
            defaultLocale: "auto",
            isRecommended: false,
            artifacts: [
                WhisperArtifact(
                    id: "whisperkit-openai-whisper-small",
                    runtime: .whisperKit,
                    sizeBytes: 484_000_000,
                    repoID: "argmaxinc/whisperkit-coreml",
                    resourcePath: "openai_whisper-small",
                    downloadURL: nil
                ),
                WhisperArtifact(
                    id: "ggml-small",
                    runtime: .ggml,
                    sizeBytes: 488_000_000,
                    repoID: "ggerganov/whisper.cpp",
                    resourcePath: "ggml-small.bin",
                    downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin?download=1")
                )
            ]
        ),
        WhisperModelRecord(
            id: "whisper-medium",
            displayName: "Whisper Medium",
            sizeTier: "Medium",
            summary: "Strong multilingual accuracy. Best suited for macOS and high-RAM iPads.",
            multilingual: true,
            defaultLocale: "auto",
            isRecommended: false,
            artifacts: [
                WhisperArtifact(
                    id: "whisperkit-openai-whisper-medium",
                    runtime: .whisperKit,
                    sizeBytes: 1_528_000_000,
                    repoID: "argmaxinc/whisperkit-coreml",
                    resourcePath: "openai_whisper-medium",
                    downloadURL: nil
                ),
                WhisperArtifact(
                    id: "ggml-medium",
                    runtime: .ggml,
                    sizeBytes: 1_530_000_000,
                    repoID: "ggerganov/whisper.cpp",
                    resourcePath: "ggml-medium.bin",
                    downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin?download=1")
                )
            ]
        ),
        WhisperModelRecord(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            sizeTier: "Large",
            summary: "Near-large-v3 quality at roughly 4x real-time. Recommended for Macs.",
            multilingual: true,
            defaultLocale: "auto",
            isRecommended: false,
            artifacts: [
                WhisperArtifact(
                    id: "whisperkit-openai-whisper-large-v3_turbo",
                    runtime: .whisperKit,
                    sizeBytes: 1_620_000_000,
                    repoID: "argmaxinc/whisperkit-coreml",
                    resourcePath: "openai_whisper-large-v3-v20240930_turbo",
                    downloadURL: nil
                ),
                WhisperArtifact(
                    id: "ggml-large-v3-turbo",
                    runtime: .ggml,
                    sizeBytes: 1_620_000_000,
                    repoID: "ggerganov/whisper.cpp",
                    resourcePath: "ggml-large-v3-turbo.bin",
                    downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=1")
                )
            ]
        ),
    ]
}
