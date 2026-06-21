import Foundation
import UniformTypeIdentifiers

enum TranscriptionEngineID: String, Codable, CaseIterable, Sendable {
    case appleSpeech = "apple_speech"
    case whisperKit = "whisper_kit"
    case whisperCpp = "whisper_cpp"
    case audioLanguageModel = "audio_language_model"

    var isLocalWhisper: Bool {
        self == .whisperKit || self == .whisperCpp
    }

    var displayName: String {
        switch self {
        case .appleSpeech:
            return String(localized: "Apple Speech")
        case .whisperKit:
            return "WhisperKit"
        case .whisperCpp:
            return "whisper.cpp"
        case .audioLanguageModel:
            return String(localized: "Audio-language model")
        }
    }
}

enum TranscriptionMediaKind: String, Codable, Sendable {
    case audio
    case video

    var iconName: String {
        switch self {
        case .audio: return "waveform"
        case .video: return "film"
        }
    }

    var title: String {
        switch self {
        case .audio: return String(localized: "Audio")
        case .video: return String(localized: "Video")
        }
    }
}

struct TranscriptSegment: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var text: String
    var startTime: TimeInterval
    var duration: TimeInterval
    var confidence: Double?

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        confidence: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.confidence = confidence
    }

    var timestampLabel: String {
        Self.timestampLabel(for: startTime)
    }

    static func timestampLabel(for seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct TranscriptReviewDisplayRow: Equatable, Sendable {
    var label: String
    var text: String

    static func rows(from text: String) -> [TranscriptReviewDisplayRow] {
        let chunks = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return chunks.enumerated().map { index, chunk in
            TranscriptReviewDisplayRow(label: "\(index + 1)", text: chunk)
        }
    }
}

enum TranscriptSegmentCoalescer {
    private static let maxPhraseDuration: TimeInterval = 8
    private static let maxGapBetweenWords: TimeInterval = 0.85
    private static let maxWordsPerPhrase = 14
    private static let maxCharactersPerPhrase = 96

    static func coalesce(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let cleaned = segments
            .map { segment -> TranscriptSegment in
                var updated = segment
                updated.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.duration = max(0, segment.duration)
                updated.startTime = max(0, segment.startTime)
                return updated
            }
            .filter { !$0.text.isEmpty }

        guard cleaned.count > 1 else { return cleaned }

        var phrases: [TranscriptSegment] = []
        var current = SegmentBuilder(first: cleaned[0])
        for segment in cleaned.dropFirst() {
            if current.shouldAppend(segment) {
                current.append(segment)
            } else {
                phrases.append(current.segment)
                current = SegmentBuilder(first: segment)
            }
        }
        phrases.append(current.segment)
        return phrases
    }

    private struct SegmentBuilder {
        private(set) var text: String
        private(set) var startTime: TimeInterval
        private(set) var endTime: TimeInterval
        private(set) var confidenceTotal: Double
        private(set) var confidenceCount: Int
        private(set) var wordCount: Int

        init(first: TranscriptSegment) {
            text = first.text
            startTime = first.startTime
            endTime = first.startTime + max(0, first.duration)
            confidenceTotal = first.confidence ?? 0
            confidenceCount = first.confidence == nil ? 0 : 1
            wordCount = Self.wordCount(in: first.text)
        }

        var segment: TranscriptSegment {
            TranscriptSegment(
                text: text,
                startTime: startTime,
                duration: max(0, endTime - startTime),
                confidence: confidenceCount > 0 ? confidenceTotal / Double(confidenceCount) : nil
            )
        }

        func shouldAppend(_ next: TranscriptSegment) -> Bool {
            guard !Self.endsSentence(text) else { return false }
            let gap = next.startTime - endTime
            if gap > TranscriptSegmentCoalescer.maxGapBetweenWords { return false }
            let nextEnd = next.startTime + max(0, next.duration)
            if nextEnd - startTime > TranscriptSegmentCoalescer.maxPhraseDuration { return false }
            if wordCount + Self.wordCount(in: next.text) > TranscriptSegmentCoalescer.maxWordsPerPhrase { return false }
            let joinedLength = text.count + 1 + next.text.count
            return joinedLength <= TranscriptSegmentCoalescer.maxCharactersPerPhrase
        }

        mutating func append(_ next: TranscriptSegment) {
            text = Self.join(text, next.text)
            endTime = max(endTime, next.startTime + max(0, next.duration))
            if let confidence = next.confidence {
                confidenceTotal += confidence
                confidenceCount += 1
            }
            wordCount += Self.wordCount(in: next.text)
        }

        private static func join(_ lhs: String, _ rhs: String) -> String {
            guard !lhs.isEmpty else { return rhs }
            guard !rhs.isEmpty else { return lhs }
            let noLeadingSpaceBefore = CharacterSet(charactersIn: ".,!?;:%)]}")
            if let first = rhs.unicodeScalars.first, noLeadingSpaceBefore.contains(first) {
                return lhs + rhs
            }
            return lhs + " " + rhs
        }

        private static func wordCount(in text: String) -> Int {
            max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
        }

        private static func endsSentence(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = trimmed.unicodeScalars.last else { return false }
            return CharacterSet(charactersIn: ".!?").contains(last)
        }
    }
}

enum TranscriptRecognitionMode: String, Equatable, Codable, Sendable {
    case onDevice
    case networkAllowed
    case remote

    var displayName: String {
        switch self {
        case .onDevice:
            return String(localized: "On-device")
        case .networkAllowed:
            return String(localized: "Network allowed")
        case .remote:
            return String(localized: "Remote")
        }
    }
}

struct TranscriptArtifact: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var engineID: TranscriptionEngineID
    var localeIdentifier: String
    var originalFilename: String
    var sourceMediaPath: String
    var transcriptText: String
    var segments: [TranscriptSegment]
    var createdAt: Date
    var displayTitle: String?
    var editedTranscriptText: String?
    var engineDisplayName: String?
    var modelIdentifier: String?
    var modelDisplayName: String?
    var recognitionMode: TranscriptRecognitionMode?
    var hasTimestampSegments: Bool?

    init(
        id: UUID = UUID(),
        engineID: TranscriptionEngineID,
        localeIdentifier: String,
        originalFilename: String,
        sourceMediaPath: String,
        transcriptText: String,
        segments: [TranscriptSegment],
        createdAt: Date = Date(),
        displayTitle: String? = nil,
        editedTranscriptText: String? = nil,
        engineDisplayName: String? = nil,
        modelIdentifier: String? = nil,
        modelDisplayName: String? = nil,
        recognitionMode: TranscriptRecognitionMode? = nil,
        hasTimestampSegments: Bool? = nil
    ) {
        self.id = id
        self.engineID = engineID
        self.localeIdentifier = localeIdentifier
        self.originalFilename = originalFilename
        self.sourceMediaPath = sourceMediaPath
        self.transcriptText = transcriptText
        self.segments = segments
        self.createdAt = createdAt
        self.displayTitle = displayTitle
        self.editedTranscriptText = editedTranscriptText
        self.engineDisplayName = engineDisplayName
        self.modelIdentifier = modelIdentifier
        self.modelDisplayName = modelDisplayName
        self.recognitionMode = recognitionMode
        self.hasTimestampSegments = hasTimestampSegments
    }

    var promptBlock: String {
        promptBlock(includeTimestamps: false)
    }

    func promptBlock(includeTimestamps: Bool) -> String {
        var body = effectiveTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeTimestamps, editedTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false, !segments.isEmpty {
            body = segmentText
        }
        var lines = [
            "[Transcript: \(displaySourceName)]",
            "Engine: \(engineDisplayName ?? engineID.displayName)",
            "Locale: \(localeIdentifier)",
            body
        ]
        if let modelLabel {
            lines.insert("Model: \(modelLabel)", at: 2)
        }
        if let recognitionMode {
            lines.insert("Mode: \(recognitionMode.displayName)", at: modelLabel == nil ? 2 : 3)
        }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    var effectiveTranscriptText: String {
        let edited = editedTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return edited.isEmpty ? transcriptText : edited
    }

    var displaySourceName: String {
        let title = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? originalFilename : title
    }

    var modelLabel: String? {
        let display = modelDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = modelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !display.isEmpty, !identifier.isEmpty, display != identifier {
            return "\(display) (\(identifier))"
        }
        if !display.isEmpty { return display }
        if !identifier.isEmpty { return identifier }
        return nil
    }

    var provenanceLines: [String] {
        var lines = [
            String.localizedStringWithFormat(String(localized: "Engine: %@"), engineDisplayName ?? engineID.displayName),
            String.localizedStringWithFormat(String(localized: "Locale: %@"), localeIdentifier)
        ]
        if let modelLabel {
            lines.append(String.localizedStringWithFormat(String(localized: "Model: %@"), modelLabel))
        }
        if let recognitionMode {
            lines.append(String.localizedStringWithFormat(String(localized: "Mode: %@"), recognitionMode.displayName))
        }
        lines.append(String.localizedStringWithFormat(String(localized: "Source: %@"), originalFilename))
        lines.append(String.localizedStringWithFormat(String(localized: "Created: %@"), createdAt.formatted(date: .abbreviated, time: .shortened)))
        let timestampsAvailable = (hasTimestampSegments ?? !segments.isEmpty) && !segments.isEmpty
        lines.append(String.localizedStringWithFormat(
            String(localized: "Timestamps: %@"),
            timestampsAvailable ? String(localized: "Available") : String(localized: "Unavailable")
        ))
        if editedTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append(String(localized: "Edited transcript"))
        }
        return lines
    }

    var provenanceSummary: String {
        provenanceLines.joined(separator: " / ")
    }

    var segmentText: String {
        guard !segments.isEmpty else { return effectiveTranscriptText }
        return segments.map { segment in
            "[\(segment.timestampLabel)] \(segment.text)"
        }.joined(separator: "\n")
    }

    var reviewSegmentRows: [TranscriptReviewDisplayRow] {
        if !segments.isEmpty {
            return segments.map { segment in
                TranscriptReviewDisplayRow(label: segment.timestampLabel, text: segment.text)
            }
        }
        return TranscriptReviewDisplayRow.rows(from: effectiveTranscriptText)
    }

    var reviewSegmentText: String {
        reviewSegmentRows.map { row in
            "[\(row.label)] \(row.text)"
        }.joined(separator: "\n")
    }

    var exportText: String {
        if editedTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return effectiveTranscriptText
        }
        return segmentText
    }

    func withProvenance(engineID selectedEngineID: TranscriptionEngineID, options: TranscriptionRequestOptions) -> TranscriptArtifact {
        var updated = self
        updated.engineID = selectedEngineID
        updated.engineDisplayName = selectedEngineID.displayName
        updated.modelIdentifier = TranscriptionSettings.modelIdentifier(for: selectedEngineID)
        updated.modelDisplayName = TranscriptionSettings.modelDisplayName(for: selectedEngineID)
        updated.recognitionMode = TranscriptionSettings.recognitionMode(for: selectedEngineID, options: options)
        updated.hasTimestampSegments = !segments.isEmpty
        return updated
    }

    func updatingReview(title: String, transcriptText: String) -> TranscriptArtifact {
        var updated = self
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.displayTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        let trimmedTranscript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.editedTranscriptText = trimmedTranscript.isEmpty || trimmedTranscript == self.transcriptText ? nil : transcriptText
        return updated
    }
}

enum ChatMediaTranscriptionStatus: String, Equatable, Codable, Sendable {
    case notStarted
    case transcribing
    case completed
    case failed

    var badgeLocalizationKey: String {
        switch self {
        case .notStarted:
            return "Ready"
        case .transcribing:
            return "Transcribing"
        case .completed:
            return "Transcribed"
        case .failed:
            return "Needs attention"
        }
    }

    var showsStandaloneStatusLabel: Bool {
        self != .transcribing
    }
}

struct ChatMediaAttachment: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var kind: TranscriptionMediaKind
    var originalFilename: String
    var storedPath: String
    var fileSizeBytes: Int64?
    var durationSeconds: TimeInterval?
    var createdAt: Date
    var status: ChatMediaTranscriptionStatus
    var partialTranscript: String?
    var transcript: TranscriptArtifact?
    var transcriptSidecarPath: String?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        kind: TranscriptionMediaKind,
        originalFilename: String,
        storedPath: String,
        fileSizeBytes: Int64? = nil,
        durationSeconds: TimeInterval? = nil,
        createdAt: Date = Date(),
        status: ChatMediaTranscriptionStatus = .notStarted,
        partialTranscript: String? = nil,
        transcript: TranscriptArtifact? = nil,
        transcriptSidecarPath: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.originalFilename = originalFilename
        self.storedPath = storedPath
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.status = status
        self.partialTranscript = partialTranscript
        self.transcript = transcript
        self.transcriptSidecarPath = transcriptSidecarPath
        self.errorMessage = errorMessage
    }

    var hasCompletedTranscript: Bool {
        status == .completed && transcript?.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var fileSizeLabel: String? {
        guard let fileSizeBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }

    var durationLabel: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return TranscriptSegment.timestampLabel(for: durationSeconds)
    }

    var mediaDetailLabel: String? {
        let label = [durationLabel, fileSizeLabel].compactMap(\.self).joined(separator: " / ")
        return label.isEmpty ? nil : label
    }

    var promptBlock: String? {
        transcript?.promptBlock
    }

    func promptBlock(includeTimestamps: Bool) -> String? {
        transcript?.promptBlock(includeTimestamps: includeTimestamps)
    }
}

enum TranscriptionMediaSupport {
    static let audioExtensions: Set<String> = ["aac", "aif", "aiff", "caf", "m4a", "mp3", "wav"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let supportedExtensions = audioExtensions.union(videoExtensions)

    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.audio, .movie]
        for ext in supportedExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    static func kind(for url: URL) -> TranscriptionMediaKind? {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    static func isSupported(_ url: URL) -> Bool {
        kind(for: url) != nil
    }
}

enum TranscriptionSettings {
    static let onDeviceOnlyKey = "asrOnDeviceOnly"
    static let localeIdentifierKey = "asrLocaleIdentifier"
    static let engineIDKey = "asrEngineID"
    static let autoTranscribeAttachmentsKey = "asrAutoTranscribeAttachments"
    static let includeTimestampsInPromptKey = "asrIncludeTimestampsInPrompt"
    static let audioLMEndpointURLKey = "asrAudioLMEndpointURL"
    static let audioLMModelIDKey = "asrAudioLMModelID"
    static let audioLMKeychainKey = "asrAudioLMAPIKey"
    static let whisperKitActiveModelKey = "asrWhisperKitActiveModelID"
    static let whisperCppActiveModelKey = "asrWhisperCppActiveModelID"
    static let remoteUploadConfirmedKey = "asrRemoteUploadConfirmed"

    static var selectedEngineID: TranscriptionEngineID {
        let raw = UserDefaults.standard.string(forKey: engineIDKey) ?? TranscriptionEngineID.appleSpeech.rawValue
        let stored = TranscriptionEngineID(rawValue: raw) ?? .appleSpeech
        switch stored {
        case .appleSpeech:
            return .appleSpeech
        case .whisperKit, .whisperCpp:
            return TranscriptionBackendFactory.resolvedLocalWhisperEngineID(preferred: stored)
        case .audioLanguageModel:
            return AudioLMRemoteBackend.isConfigured ? .audioLanguageModel : .appleSpeech
        }
    }

    static var preferredLocaleIdentifier: String {
        let stored = UserDefaults.standard.string(forKey: localeIdentifierKey) ?? ""
        if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return Locale.current.identifier
    }

    static func requiresOnDeviceRecognition(offGrid: Bool) -> Bool {
        offGrid || (UserDefaults.standard.object(forKey: onDeviceOnlyKey) as? Bool ?? true)
    }

    static var autoTranscribesAttachments: Bool {
        UserDefaults.standard.object(forKey: autoTranscribeAttachmentsKey) as? Bool ?? false
    }

    static var includesTimestampsInPrompt: Bool {
        UserDefaults.standard.object(forKey: includeTimestampsInPromptKey) as? Bool ?? false
    }

    static func requestOptions(offGrid: Bool) -> TranscriptionRequestOptions {
        TranscriptionRequestOptions(
            localeIdentifier: preferredLocaleIdentifier,
            requiresOnDeviceRecognition: requiresOnDeviceRecognition(offGrid: offGrid),
            reportsPartialResults: true
        )
    }

    static func modelIdentifier(for engineID: TranscriptionEngineID) -> String? {
        switch engineID {
        case .appleSpeech:
            return nil
        case .whisperKit, .whisperCpp:
            return WhisperModelCatalog.activeRecordID(for: engineID)
        case .audioLanguageModel:
            return AudioLMRemoteBackend.storedModelID
        }
    }

    static func modelDisplayName(for engineID: TranscriptionEngineID) -> String? {
        switch engineID {
        case .appleSpeech:
            return nil
        case .whisperKit, .whisperCpp:
            return WhisperModelCatalog.activeRecord(for: engineID)?.displayName
        case .audioLanguageModel:
            return AudioLMRemoteBackend.storedModelID
        }
    }

    static func recognitionMode(for engineID: TranscriptionEngineID, options: TranscriptionRequestOptions) -> TranscriptRecognitionMode {
        switch engineID {
        case .audioLanguageModel:
            return .remote
        case .whisperKit, .whisperCpp:
            return .onDevice
        case .appleSpeech:
            return options.requiresOnDeviceRecognition ? .onDevice : .networkAllowed
        }
    }

    static var hasConfirmedRemoteUpload: Bool {
        UserDefaults.standard.object(forKey: remoteUploadConfirmedKey) as? Bool ?? false
    }

    static func confirmRemoteUpload() {
        UserDefaults.standard.set(true, forKey: remoteUploadConfirmedKey)
    }
}

struct TranscriptionRequestOptions: Equatable, Sendable {
    var localeIdentifier: String
    var requiresOnDeviceRecognition: Bool
    var reportsPartialResults: Bool
}

enum TranscriptionEvent: Equatable, Sendable {
    case partial(String)
    case completed(TranscriptArtifact)
}

protocol TranscriptionBackend: Sendable {
    var engineID: TranscriptionEngineID { get }
    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool
    func transcribe(
        mediaURL: URL,
        originalFilename: String,
        options: TranscriptionRequestOptions,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> TranscriptArtifact
}

enum TranscriptionError: LocalizedError, Equatable, Sendable {
    case authorizationDenied
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnavailable(String)
    case speechDaemonUnavailable(String)
    case engineUnavailable(String, String)
    case emptyTranscript
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return String(localized: "Speech recognition permission is required to transcribe media.")
        case .recognizerUnavailable(let locale):
            return String.localizedStringWithFormat(String(localized: "Speech recognition is unavailable for %@."), locale)
        case .onDeviceRecognitionUnavailable(let locale):
            return String.localizedStringWithFormat(String(localized: "On-device transcription is unavailable for %@."), locale)
        case .speechDaemonUnavailable(let locale):
            return String.localizedStringWithFormat(String(localized: "Apple Speech could not start transcription for %@. Try another ASR locale, or turn off on-device transcription only when Off-grid Mode is disabled."), locale)
        case .engineUnavailable(let engineName, let reason):
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedReason.isEmpty {
                return String.localizedStringWithFormat(String(localized: "%@ is unavailable."), engineName)
            }
            return String.localizedStringWithFormat(String(localized: "%@ is unavailable. %@"), engineName, trimmedReason)
        case .emptyTranscript:
            return String(localized: "No speech was recognized in this media.")
        case .unsupportedPlatform:
            return String(localized: "Transcription is not supported on this platform.")
        }
    }
}
