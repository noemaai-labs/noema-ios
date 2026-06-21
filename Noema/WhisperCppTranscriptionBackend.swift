import Foundation

extension NoemaWhisperCpp: @unchecked Sendable {}
extension NoemaWhisperCppSegment: @unchecked Sendable {}

/// On-device transcription backed by whisper.cpp. Uses the NoemaWhisperCpp
/// Objective-C++ shim; audio is decoded to 16 kHz mono Float32 with
/// MediaAudioExtractor. When whisper.cpp is not linked into the build, the
/// shim reports `isAvailable == false` and any transcribe call throws
/// `WhisperCppError.notLinked`.
final class WhisperCppTranscriptionBackend: TranscriptionBackend {
    let engineID: TranscriptionEngineID = .whisperCpp

    nonisolated init() {}

    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool { true }

    func transcribe(
        mediaURL: URL,
        originalFilename: String,
        options: TranscriptionRequestOptions,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> TranscriptArtifact {
        let requestedLocale = options.localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        await logger.log("[ASR][WhisperCpp] start name=\(originalFilename) locale=\(requestedLocale.isEmpty ? "auto" : requestedLocale)")

        guard NoemaWhisperCpp.isAvailable() else {
            await logger.log("[ASR][WhisperCpp] runtime.unavailable")
            throw WhisperCppError.notLinked
        }

        let activeID = WhisperModelCatalog.activeRecordID(for: .whisperCpp)
        guard let record = WhisperModelCatalog.record(for: activeID),
              let installedURL = record.installedURL(runtime: .ggml),
              WhisperModelCatalog.installationState(for: record, runtime: .ggml) == .ready else {
            await logger.log("[ASR][WhisperCpp] model.missing active_id=\(activeID)")
            throw WhisperCppError.modelMissing
        }
        await logger.log("[ASR][WhisperCpp] model.ready id=\(record.id) file=\(installedURL.lastPathComponent)")

        let prepared = try await MediaAudioExtractor.prepareAudioSource(from: mediaURL)
        defer { prepared.cleanup?() }
        let preparedBytes = (try? FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size] as? NSNumber)?.int64Value ?? -1
        await logger.log("[ASR][WhisperCpp] audio.prepared source_ext=\(mediaURL.pathExtension) prepared_ext=\(prepared.url.pathExtension) bytes=\(preparedBytes)")

        let samples = try MediaAudioExtractor.decodeMonoPCM16k(from: prepared.url)
        await logger.log("[ASR][WhisperCpp] audio.decoded samples=\(samples.count) seconds=\(String(format: "%.2f", Double(samples.count) / 16_000.0))")
        guard !samples.isEmpty else {
            await logger.log("[ASR][WhisperCpp] audio.empty")
            throw TranscriptionError.emptyTranscript
        }

        let whisper = try NoemaWhisperCpp(modelPath: installedURL.path)
        let language: String? = AppleSpeechLocaleHelper.shortLanguageCode(from: options.localeIdentifier)
            ?? (record.multilingual ? nil : "en")

        let partials = WhisperPartialAccumulatorStore()
        let result: (text: String, segments: [NoemaWhisperCppSegment])
        do {
            result = try await withTaskCancellationHandler {
                try await runBlocking(
                    whisper: whisper,
                    samples: samples,
                    language: language,
                    onPartial: { partial in
                        let update = partials.ingest(partial)
                        if let text = update.partial {
                            onEvent(.partial(text))
                        }
                        Task {
                            await logger.log("[ASR][WhisperCpp] partial raw_chars=\(partial.count) promoted=\(update.partial != nil) received=\(update.received) promoted_count=\(update.promoted) chunks=\(update.chunks)")
                        }
                    }
                )
            } onCancel: {
                Task { await logger.log("[ASR][WhisperCpp] cancelled name=\(originalFilename)") }
                whisper.cancel()
            }
        } catch {
            if Task.isCancelled {
                await logger.log("[ASR][WhisperCpp] cancelled name=\(originalFilename)")
            } else {
                await logger.log("[ASR][WhisperCpp] transcribe.failed error_type=\(String(describing: type(of: error))) message=\(error.localizedDescription)")
            }
            throw error
        }

        let chunks = [
            WhisperTranscriptionChunk(
                text: result.text,
                segments: result.segments.map {
                    WhisperTranscriptionSegment(
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime
                    )
                }
            )
        ]
        let fallback = partials.snapshotText
        let usesPartialFallback = WhisperTranscriptionFinalizer.wouldUsePartialFallback(chunks: chunks, partialFallbackText: fallback)
        let counts = partials.counts
        let artifact: TranscriptArtifact
        do {
            artifact = try WhisperTranscriptionFinalizer.artifact(
                engineID: .whisperCpp,
                localeIdentifier: language ?? options.localeIdentifier,
                originalFilename: originalFilename,
                sourceMediaPath: mediaURL.path,
                chunks: chunks,
                partialFallbackText: fallback
            )
        } catch {
            await logger.log("[ASR][WhisperCpp] final.failed segments=\(result.segments.count) partial_received=\(counts.received) partial_promoted=\(counts.promoted) partial_chunks=\(counts.chunks) partial_fallback=\(usesPartialFallback) error_type=\(String(describing: type(of: error))) message=\(error.localizedDescription)")
            throw error
        }
        await logger.log("[ASR][WhisperCpp] final segments=\(result.segments.count) chars=\(artifact.transcriptText.count) partial_received=\(counts.received) partial_promoted=\(counts.promoted) partial_chunks=\(counts.chunks) partial_fallback=\(usesPartialFallback)")
        onEvent(.completed(artifact))
        return artifact
    }

    private func runBlocking(
        whisper: NoemaWhisperCpp,
        samples: [Float],
        language: String?,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> (text: String, segments: [NoemaWhisperCppSegment]) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(text: String, segments: [NoemaWhisperCppSegment]), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var outSegments: NSArray?
                var outText: NSString?
                do {
                    try samples.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else {
                            throw WhisperCppError.transcriptionFailed("Empty sample buffer")
                        }
                        try whisper.transcribeSamples(
                            base,
                            length: UInt(samples.count),
                            language: language,
                            translate: false,
                            partialHandler: { partial in
                                onPartial(partial)
                            },
                            segments: &outSegments,
                            fullText: &outText
                        )
                    }
                    let text = (outText as String?) ?? ""
                    let segs = (outSegments as? [NoemaWhisperCppSegment]) ?? []
                    continuation.resume(returning: (text, segs))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum WhisperCppError: LocalizedError {
    case notLinked
    case modelMissing
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLinked:
            return String(localized: "whisper.cpp is not linked in this build.")
        case .modelMissing:
            return String(localized: "Download a Whisper model in Settings → Whisper Model before transcribing.")
        case .transcriptionFailed(let msg):
            return String.localizedStringWithFormat(
                String(localized: "whisper.cpp transcription failed: %@"),
                msg
            )
        }
    }
}
