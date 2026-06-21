import Foundation

#if canImport(WhisperKit)
import WhisperKit

/// On-device transcription backed by WhisperKit (Core ML Whisper). The SDK
/// downloads model artifacts on first use; progress is reported via the
/// backend's own `download` closure. Partial results are emitted while the
/// SDK streams segments.
final class WhisperKitTranscriptionBackend: TranscriptionBackend {
    let engineID: TranscriptionEngineID = .whisperKit

    nonisolated init() {}

    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool { true }

    func transcribe(
        mediaURL: URL,
        originalFilename: String,
        options: TranscriptionRequestOptions,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> TranscriptArtifact {
        let requestedLocale = options.localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        await logger.log("[ASR][WhisperKit] start name=\(originalFilename) locale=\(requestedLocale.isEmpty ? "auto" : requestedLocale)")

        let activeID = WhisperModelCatalog.activeRecordID(for: .whisperKit)
        guard let record = WhisperModelCatalog.record(for: activeID),
              let artifact = record.artifact(for: .whisperKit) else {
            await logger.log("[ASR][WhisperKit] model.missing active_id=\(activeID)")
            throw WhisperKitError.noModelSelected
        }

        let modelFolder = WhisperModelCatalog.whisperKitModelFolderURL(recordID: record.id, artifact: artifact)
        let installState = WhisperModelCatalog.installationState(for: record, runtime: .whisperKit)
        guard installState == .ready else {
            await logger.log("[ASR][WhisperKit] model.not_ready id=\(record.id) state=\(installState)")
            throw WhisperKitError.modelMissing(installState)
        }
        await logger.log("[ASR][WhisperKit] model.ready id=\(record.id) folder=\(modelFolder.lastPathComponent)")

        let pipe: WhisperKit
        do {
            pipe = try await WhisperKit(modelFolder: modelFolder.path)
        } catch {
            await logger.log("[ASR][WhisperKit] load.failed id=\(record.id) error_type=\(String(describing: type(of: error))) message=\(error.localizedDescription)")
            throw WhisperKitError.loadFailed(error.localizedDescription)
        }

        let prepared = try await MediaAudioExtractor.prepareAudioSource(from: mediaURL)
        defer { prepared.cleanup?() }
        let preparedBytes = (try? FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size] as? NSNumber)?.int64Value ?? -1
        await logger.log("[ASR][WhisperKit] audio.prepared source_ext=\(mediaURL.pathExtension) prepared_ext=\(prepared.url.pathExtension) bytes=\(preparedBytes)")

        let locale = AppleSpeechLocaleHelper.shortLanguageCode(from: options.localeIdentifier)

        var decoderOptions = DecodingOptions()
        decoderOptions.task = .transcribe
        decoderOptions.language = record.multilingual ? locale : "en"
        decoderOptions.temperature = 0
        decoderOptions.skipSpecialTokens = true
        decoderOptions.withoutTimestamps = false
        decoderOptions.noSpeechThreshold = nil

        let partials = WhisperPartialAccumulatorStore()
        let discoveredSegments = WhisperDiscoveredSegmentsStore()
        pipe.segmentDiscoveryCallback = { segments in
            discoveredSegments.ingest(
                segments.map { segment in
                    WhisperTranscriptionSegment(
                        text: segment.text,
                        startTime: TimeInterval(segment.start),
                        endTime: TimeInterval(segment.end)
                    )
                }
            )
        }
        let callback: @Sendable (TranscriptionProgress) -> Bool? = { progress in
            let update = partials.ingest(progress.text)
            if let text = update.partial {
                onEvent(.partial(text))
            }
            Task {
                await logger.log("[ASR][WhisperKit] partial raw_chars=\(progress.text.count) promoted=\(update.partial != nil) received=\(update.received) promoted_count=\(update.promoted) chunks=\(update.chunks)")
            }
            return !Task.isCancelled
        }

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioPath: prepared.url.path,
                decodeOptions: decoderOptions,
                callback: callback
            )
        } catch {
            if Task.isCancelled {
                await logger.log("[ASR][WhisperKit] cancelled name=\(originalFilename)")
            } else {
                await logger.log("[ASR][WhisperKit] transcribe.failed error_type=\(String(describing: type(of: error))) message=\(error.localizedDescription)")
            }
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }

        let chunks = results.map { result in
            WhisperTranscriptionChunk(
                text: result.text,
                segments: result.segments.map { segment in
                    WhisperTranscriptionSegment(
                        text: segment.text,
                        startTime: TimeInterval(segment.start),
                        endTime: TimeInterval(segment.end)
                    )
                }
            )
        }
        let fallback = partials.snapshotText
        let discovered = discoveredSegments.segments
        let usesPartialFallback = WhisperTranscriptionFinalizer.wouldUsePartialFallback(
            chunks: chunks,
            discoveredSegments: discovered,
            partialFallbackText: fallback
        )
        let counts = partials.counts
        let decision: WhisperTranscriptionFinalizer.Decision
        do {
            decision = try WhisperTranscriptionFinalizer.finalize(
                engineID: .whisperKit,
                localeIdentifier: decoderOptions.language ?? options.localeIdentifier,
                originalFilename: originalFilename,
                sourceMediaPath: mediaURL.path,
                chunks: chunks,
                discoveredSegments: discovered,
                partialFallbackText: fallback
            )
        } catch {
            await logger.log("[ASR][WhisperKit] final.failed chunks=\(chunks.count) result_segments=\(chunks.reduce(0) { $0 + $1.segments.count }) discovered_segments=\(discovered.count) partial_received=\(counts.received) partial_promoted=\(counts.promoted) partial_chunks=\(counts.chunks) partial_fallback=\(usesPartialFallback) error_type=\(String(describing: type(of: error))) message=\(error.localizedDescription)")
            throw error
        }
        await logger.log("[ASR][WhisperKit] final chunks=\(chunks.count) result_segments=\(chunks.reduce(0) { $0 + $1.segments.count }) discovered_segments=\(discovered.count) raw_segments=\(decision.rawSegmentCount) usable_segments=\(decision.usableSegmentCount) source=\(decision.source.rawValue) chunk_chars=\(decision.chunkTextCount) segment_chars=\(decision.segmentTextCount) partial_chars=\(decision.partialTextCount) chars=\(decision.artifact.transcriptText.count) partial_received=\(counts.received) partial_promoted=\(counts.promoted) partial_chunks=\(counts.chunks) partial_fallback=\(usesPartialFallback)")
        onEvent(.completed(decision.artifact))
        return decision.artifact
    }
}

enum WhisperKitError: LocalizedError {
    case noModelSelected
    case modelMissing(WhisperModelInstallState)
    case loadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return String(localized: "Pick a Whisper model in Settings before transcribing.")
        case .modelMissing(let state):
            switch state {
            case .incomplete:
                return String(localized: "Whisper model download is incomplete. Repair and download it in Settings before transcribing.")
            case .missing, .ready:
                return String(localized: "Download a Whisper model in Settings before transcribing.")
            }
        case .loadFailed(let message):
            return String.localizedStringWithFormat(
                String(localized: "Failed to load Whisper model: %@"),
                message
            )
        case .transcriptionFailed(let message):
            return String.localizedStringWithFormat(
                String(localized: "Whisper transcription failed: %@"),
                message
            )
        }
    }
}

#endif

struct WhisperTranscriptionSegment: Equatable, Sendable {
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
}

struct WhisperTranscriptionChunk: Equatable, Sendable {
    var text: String
    var segments: [WhisperTranscriptionSegment]
}

enum WhisperTranscriptionFinalizer {
    enum Source: String, Sendable {
        case chunks
        case segments
        case partialFallback
    }

    struct Decision: Sendable {
        var artifact: TranscriptArtifact
        var source: Source
        var chunkTextCount: Int
        var segmentTextCount: Int
        var partialTextCount: Int
        var rawSegmentCount: Int
        var usableSegmentCount: Int
    }

    static func artifact(
        engineID: TranscriptionEngineID,
        localeIdentifier: String,
        originalFilename: String,
        sourceMediaPath: String,
        chunks: [WhisperTranscriptionChunk],
        discoveredSegments: [WhisperTranscriptionSegment] = [],
        partialFallbackText: String? = nil
    ) throws -> TranscriptArtifact {
        try finalize(
            engineID: engineID,
            localeIdentifier: localeIdentifier,
            originalFilename: originalFilename,
            sourceMediaPath: sourceMediaPath,
            chunks: chunks,
            discoveredSegments: discoveredSegments,
            partialFallbackText: partialFallbackText
        ).artifact
    }

    static func finalize(
        engineID: TranscriptionEngineID,
        localeIdentifier: String,
        originalFilename: String,
        sourceMediaPath: String,
        chunks: [WhisperTranscriptionChunk],
        discoveredSegments: [WhisperTranscriptionSegment] = [],
        partialFallbackText: String? = nil
    ) throws -> Decision {
        let chunkText = chunks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawSegments = normalizedSegments(from: chunks.flatMap(\.segments) + discoveredSegments)
        let segments = TranscriptSegmentCoalescer.coalesce(rawSegments)

        let segmentFallbackText = segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let partialFallback = WhisperPartialAccumulator.normalizedMeaningfulTranscriptText(partialFallbackText ?? "")
        let realCandidate = bestRealCandidate(chunkText: chunkText, segmentText: segmentFallbackText)
        let selection: (text: String, source: Source)
        if let partialFallback,
           shouldPreferPartialFallback(realText: realCandidate?.text, partialText: partialFallback) {
            selection = (partialFallback, .partialFallback)
        } else if let realCandidate {
            selection = realCandidate
        } else {
            selection = (partialFallback ?? "", .partialFallback)
        }

        let transcriptText: String
        transcriptText = selection.text
        guard !transcriptText.isEmpty else {
            throw TranscriptionError.emptyTranscript
        }

        let artifactSegments = shouldDropShortSegments(
            source: selection.source,
            segmentText: segmentFallbackText,
            transcriptText: transcriptText
        ) ? [] : segments
        let artifact = TranscriptArtifact(
            engineID: engineID,
            localeIdentifier: localeIdentifier,
            originalFilename: originalFilename,
            sourceMediaPath: sourceMediaPath,
            transcriptText: transcriptText,
            segments: artifactSegments
        )
        return Decision(
            artifact: artifact,
            source: selection.source,
            chunkTextCount: chunkText.count,
            segmentTextCount: segmentFallbackText.count,
            partialTextCount: partialFallback?.count ?? 0,
            rawSegmentCount: rawSegments.count,
            usableSegmentCount: artifactSegments.count
        )
    }

    static func wouldUsePartialFallback(
        chunks: [WhisperTranscriptionChunk],
        discoveredSegments: [WhisperTranscriptionSegment] = [],
        partialFallbackText: String?
    ) -> Bool {
        let chunkText = chunks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let segmentText = normalizedSegments(from: chunks.flatMap(\.segments) + discoveredSegments)
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let partialText = WhisperPartialAccumulator.normalizedMeaningfulTranscriptText(partialFallbackText ?? "")
        guard let partialText else { return false }
        let realCandidate = bestRealCandidate(chunkText: chunkText, segmentText: segmentText)
        return shouldPreferPartialFallback(realText: realCandidate?.text, partialText: partialText)
    }

    private static func bestRealCandidate(chunkText: String, segmentText: String) -> (text: String, source: Source)? {
        let hasChunkText = !chunkText.isEmpty
        let hasSegmentText = !segmentText.isEmpty
        switch (hasChunkText, hasSegmentText) {
        case (false, false):
            return nil
        case (true, false):
            return (chunkText, .chunks)
        case (false, true):
            return (segmentText, .segments)
        case (true, true):
            return segmentText.count > chunkText.count + 80 ? (segmentText, .segments) : (chunkText, .chunks)
        }
    }

    private static func shouldPreferPartialFallback(realText: String?, partialText: String) -> Bool {
        guard !partialText.isEmpty else { return false }
        guard let realText, !realText.isEmpty else { return true }
        let minimumMissingCharacters = 80
        return partialText.count > realText.count + minimumMissingCharacters
            && Double(partialText.count) >= Double(realText.count) * 1.2
    }

    private static func shouldDropShortSegments(source: Source, segmentText: String, transcriptText: String) -> Bool {
        guard source == .partialFallback, !segmentText.isEmpty else { return false }
        return shouldPreferPartialFallback(realText: segmentText, partialText: transcriptText)
    }

    private static func normalizedSegments(from segments: [WhisperTranscriptionSegment]) -> [TranscriptSegment] {
        var seen = Set<String>()
        return segments.compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = max(0, segment.startTime)
            let end = max(start, segment.endTime)
            let key = "\(Int((start * 10).rounded()))|\(Int((end * 10).rounded()))|\(text.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            return TranscriptSegment(
                text: text,
                startTime: start,
                duration: max(0, end - start),
                confidence: nil
            )
        }
    }
}

/// Utility shared between WhisperKit and whisper.cpp backends. Always
/// compiled so non-WhisperKit targets can still use it.
enum AppleSpeechLocaleHelper {
    static func shortLanguageCode(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            return nil
        }
        return String(trimmed.split(separator: "-").first ?? Substring(trimmed))
            .lowercased()
    }
}

struct WhisperPartialAccumulator: Equatable, Sendable {
    private(set) var receivedCount = 0
    private(set) var promotedCount = 0
    private var committedChunks: [String] = []
    private var currentChunk: String?
    private var lastEmittedSnapshot: String?

    var lastMeaningfulPartial: String? {
        currentChunk
    }

    var snapshotText: String? {
        let chunks = snapshotChunks
        guard !chunks.isEmpty else { return nil }
        return chunks.joined(separator: "\n\n")
    }

    var chunkCount: Int {
        snapshotChunks.count
    }

    private var snapshotChunks: [String] {
        committedChunks + [currentChunk].compactMap(\.self)
    }

    mutating func ingest(_ rawText: String) -> String? {
        receivedCount += 1
        guard let text = Self.normalizedMeaningfulText(rawText) else {
            return nil
        }
        if let currentChunk, Self.startsNewChunk(previous: currentChunk, next: text) {
            commitCurrentChunk()
            self.currentChunk = text
        } else {
            self.currentChunk = text
        }

        guard let snapshot = snapshotText, snapshot != lastEmittedSnapshot else {
            return nil
        }
        lastEmittedSnapshot = snapshot
        promotedCount += 1
        return snapshot
    }

    static func normalizedMeaningfulText(_ rawText: String) -> String? {
        let collapsed = rawText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isMeaningful(collapsed) ? collapsed : nil
    }

    static func normalizedMeaningfulTranscriptText(_ rawText: String) -> String? {
        let paragraphs = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let text = paragraphs.joined(separator: "\n\n")
        return isMeaningful(text) ? text : nil
    }

    private static func isMeaningful(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let significantScalars = text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard significantScalars.count >= 2 else { return false }

        let punctuationAndSymbols = CharacterSet.punctuationCharacters.union(.symbols)
        guard significantScalars.contains(where: { !punctuationAndSymbols.contains($0) }) else {
            return false
        }

        return true
    }

    private mutating func commitCurrentChunk() {
        guard let currentChunk else { return }
        if committedChunks.last != currentChunk {
            committedChunks.append(currentChunk)
        }
    }

    private static func startsNewChunk(previous: String, next: String) -> Bool {
        let previousText = previous.lowercased()
        let nextText = next.lowercased()
        guard !previousText.isEmpty, !nextText.isEmpty else { return false }
        if nextText == previousText || nextText.hasPrefix(previousText) || previousText.hasPrefix(nextText) || nextText.contains(previousText) {
            return false
        }

        let overlap = leadingWordOverlap(previousText: previousText, nextText: nextText)
        let previousWords = previousText.split(separator: " ").count
        let shrankHard = nextText.count < Int(Double(previousText.count) * 0.7)
        return previousWords >= 3 && shrankHard && overlap < 3
    }

    private static func leadingWordOverlap(previousText: String, nextText: String) -> Int {
        let previousWords = previousText.split(separator: " ")
        let nextWords = nextText.split(separator: " ")
        var overlap = 0
        for nextWord in nextWords {
            guard previousWords.contains(nextWord) else { break }
            overlap += 1
        }
        return overlap
    }
}

final class WhisperPartialAccumulatorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = WhisperPartialAccumulator()

    func ingest(_ rawText: String) -> (partial: String?, received: Int, promoted: Int, chunks: Int) {
        lock.lock()
        defer { lock.unlock() }
        let partial = accumulator.ingest(rawText)
        return (partial, accumulator.receivedCount, accumulator.promotedCount, accumulator.chunkCount)
    }

    var snapshotText: String? {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.snapshotText
    }

    var counts: (received: Int, promoted: Int, chunks: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (accumulator.receivedCount, accumulator.promotedCount, accumulator.chunkCount)
    }
}

final class WhisperDiscoveredSegmentsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSegments: [WhisperTranscriptionSegment] = []

    func ingest(_ segments: [WhisperTranscriptionSegment]) {
        guard !segments.isEmpty else { return }
        lock.lock()
        storedSegments.append(contentsOf: segments)
        lock.unlock()
    }

    var segments: [WhisperTranscriptionSegment] {
        lock.lock()
        defer { lock.unlock() }
        return storedSegments
    }
}
