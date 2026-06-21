import Foundation

#if canImport(Speech)
import Speech
#endif

#if canImport(Speech)
final class AppleSpeechTranscriptionBackend: TranscriptionBackend {
    let engineID: TranscriptionEngineID = .appleSpeech

    nonisolated init() {}

    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            return false
        }
        #if os(iOS) || os(tvOS)
        if #available(iOS 13.0, tvOS 18.0, *) {
            return recognizer.supportsOnDeviceRecognition
        }
        return false
        #else
        return false
        #endif
    }

    func transcribe(
        mediaURL: URL,
        originalFilename: String,
        options: TranscriptionRequestOptions,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> TranscriptArtifact {
        try await requestAuthorizationIfNeeded()

        let resolvedLocaleID = Self.resolveLocaleIdentifier(options.localeIdentifier)
        let locale = Locale(identifier: resolvedLocaleID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable(resolvedLocaleID)
        }

        if options.requiresOnDeviceRecognition && !supportsOnDeviceRecognition(localeIdentifier: resolvedLocaleID) {
            throw TranscriptionError.onDeviceRecognitionUnavailable(resolvedLocaleID)
        }

        let preparedAudio = try await MediaAudioExtractor.prepareAudioSource(from: mediaURL)
        defer { preparedAudio.cleanup?() }

        let request = SFSpeechURLRecognitionRequest(url: preparedAudio.url)
        request.shouldReportPartialResults = options.reportsPartialResults
        if options.requiresOnDeviceRecognition {
            #if os(iOS) || os(tvOS)
            if #available(iOS 13.0, tvOS 18.0, *) {
                request.requiresOnDeviceRecognition = true
            }
            #else
            throw TranscriptionError.onDeviceRecognitionUnavailable(resolvedLocaleID)
            #endif
        }

        final class TaskBox: @unchecked Sendable {
            var task: SFSpeechRecognitionTask?
        }
        let taskBox = TaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var didResume = false
                var transcriptAccumulator = AppleSpeechTranscriptAccumulator()

                taskBox.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let transcript = result.bestTranscription.formattedString
                        let transcriptSegments = Self.transcriptSegments(from: result.bestTranscription.segments)
                        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            let snapshot = transcriptAccumulator.ingest(transcript: transcript, segments: transcriptSegments)
                            onEvent(.partial(snapshot.text))
                        }

                        guard result.isFinal else { return }
                        let snapshot = transcriptAccumulator.finalSnapshot(finalTranscript: transcript, finalSegments: transcriptSegments)
                        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            if !didResume {
                                didResume = true
                                continuation.resume(throwing: TranscriptionError.emptyTranscript)
                            }
                            return
                        }
                        let artifact = TranscriptArtifact(
                            engineID: .appleSpeech,
                            localeIdentifier: resolvedLocaleID,
                            originalFilename: originalFilename,
                            sourceMediaPath: mediaURL.path,
                            transcriptText: snapshot.text,
                            segments: snapshot.segments
                        )
                        if !didResume {
                            didResume = true
                            onEvent(.completed(artifact))
                            continuation.resume(returning: artifact)
                        }
                    } else if let error, !didResume {
                        didResume = true
                        continuation.resume(throwing: Self.mapRecognitionError(error, localeIdentifier: resolvedLocaleID, requiresOnDeviceRecognition: options.requiresOnDeviceRecognition))
                    }
                }
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }

    /// Resolves a user-supplied locale identifier against on-device Speech
    /// support. Accepts "auto" or an empty string (both pick the current system
    /// language). Full identifiers like "en-US" pass through when supported;
    /// bare language codes like "en" are expanded to the first supported
    /// recognizer locale for that language. Falls back to the input verbatim
    /// if nothing better matches.
    static func resolveLocaleIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = SFSpeechRecognizer.supportedLocales()

        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            let preferred = Locale.current.identifier
            if supported.contains(where: { $0.identifier == preferred }) {
                return preferred
            }
            let lang = Locale.current.language.languageCode?.identifier ?? ""
            if !lang.isEmpty,
               let match = supported.first(where: { $0.language.languageCode?.identifier == lang }) {
                return match.identifier
            }
            return preferred
        }

        if supported.contains(where: { $0.identifier == trimmed }) {
            return trimmed
        }

        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        if let match = supported.first(where: { $0.identifier.compare(normalized, options: .caseInsensitive) == .orderedSame }) {
            return match.identifier
        }

        if let match = supported.first(where: { $0.language.languageCode?.identifier.compare(normalized, options: .caseInsensitive) == .orderedSame }) {
            return match.identifier
        }

        return trimmed
    }

    private static func mapRecognitionError(
        _ error: Error,
        localeIdentifier: String,
        requiresOnDeviceRecognition: Bool
    ) -> Error {
        let nsError = error as NSError
        if nsError.domain == "com.apple.accounts", nsError.code == 7 {
            return requiresOnDeviceRecognition
                ? TranscriptionError.onDeviceRecognitionUnavailable(localeIdentifier)
                : TranscriptionError.speechDaemonUnavailable(localeIdentifier)
        }
        if requiresOnDeviceRecognition,
           nsError.localizedDescription.localizedCaseInsensitiveContains("daemon") {
            return TranscriptionError.onDeviceRecognitionUnavailable(localeIdentifier)
        }
        return error
    }

    private static func transcriptSegments(from segments: [SFTranscriptionSegment]) -> [TranscriptSegment] {
        let wordSegments = segments.map {
            TranscriptSegment(
                text: $0.substring,
                startTime: $0.timestamp,
                duration: $0.duration,
                confidence: Double($0.confidence)
            )
        }
        return TranscriptSegmentCoalescer.coalesce(wordSegments)
    }

    private func requestAuthorizationIfNeeded() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw TranscriptionError.authorizationDenied
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard status == .authorized else {
                throw TranscriptionError.authorizationDenied
            }
        @unknown default:
            throw TranscriptionError.authorizationDenied
        }
    }
}
#else
struct AppleSpeechTranscriptionBackend: TranscriptionBackend {
    let engineID: TranscriptionEngineID = .appleSpeech

    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool { false }

    func transcribe(
        mediaURL: URL,
        originalFilename: String,
        options: TranscriptionRequestOptions,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> TranscriptArtifact {
        throw TranscriptionError.unsupportedPlatform
    }
}
#endif

extension AppleSpeechTranscriptionBackend {
    static func resolvedTranscriptText(finalTranscript: String, lastPartialTranscript: String?) -> String? {
        let trimmedFinal = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFinal.isEmpty {
            return finalTranscript
        }

        let trimmedPartial = lastPartialTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedPartial.isEmpty ? nil : lastPartialTranscript
    }
}

struct AppleSpeechTranscriptAccumulator: Sendable {
    private struct Chunk: Sendable {
        var text: String
        var segments: [TranscriptSegment]

        var normalizedText: String {
            text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .lowercased()
        }

        var segmentStartTime: TimeInterval? {
            segments.map(\.startTime).min()
        }

        var segmentEndTime: TimeInterval? {
            segments.map { $0.startTime + max(0, $0.duration) }.max()
        }
    }

    private var committedChunks: [Chunk] = []
    private var currentChunk: Chunk?

    mutating func ingest(transcript: String, segments: [TranscriptSegment]) -> (text: String, segments: [TranscriptSegment]) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snapshot() }

        let next = Chunk(text: transcript, segments: segments)
        guard let current = currentChunk else {
            currentChunk = next
            return snapshot()
        }

        if Self.startsNewChunk(previous: current, next: next) {
            commitCurrentChunk()
        }
        currentChunk = next
        return snapshot()
    }

    mutating func finalSnapshot(finalTranscript: String, finalSegments: [TranscriptSegment]) -> (text: String, segments: [TranscriptSegment]) {
        _ = ingest(transcript: finalTranscript, segments: finalSegments)
        return snapshot()
    }

    private mutating func commitCurrentChunk() {
        guard let currentChunk else { return }
        if committedChunks.last?.normalizedText != currentChunk.normalizedText {
            committedChunks.append(currentChunk)
        }
    }

    private func snapshot() -> (text: String, segments: [TranscriptSegment]) {
        let chunks = committedChunks + [currentChunk].compactMap(\.self)
        let text = chunks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let segments = chunks.flatMap(\.segments)
        return (text, segments)
    }

    private static func startsNewChunk(previous: Chunk, next: Chunk) -> Bool {
        let previousText = previous.normalizedText
        let nextText = next.normalizedText
        guard !previousText.isEmpty, !nextText.isEmpty else { return false }

        if nextText.hasPrefix(previousText) || previousText.hasPrefix(nextText) || nextText.contains(previousText) {
            return false
        }

        if let previousEnd = previous.segmentEndTime, let nextStart = next.segmentStartTime {
            if nextStart > previousEnd + 0.25 {
                return true
            }
            return false
        }

        return Self.leadingWordOverlap(previousText: previousText, nextText: nextText) < 3
    }

    private static func leadingWordOverlap(previousText: String, nextText: String) -> Int {
        let previousWords = previousText.split(separator: " ")
        let nextWords = nextText.split(separator: " ")
        guard !previousWords.isEmpty, !nextWords.isEmpty else { return 0 }
        let maxCount = min(previousWords.count, nextWords.count)
        guard maxCount > 0 else { return 0 }
        for count in stride(from: maxCount, through: 1, by: -1) {
            if Array(previousWords.suffix(count)) == Array(nextWords.prefix(count)) {
                return count
            }
        }
        return 0
    }
}
