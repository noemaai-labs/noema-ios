import XCTest
@testable import Noema

final class TranscriptionTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.onDeviceOnlyKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.localeIdentifierKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineIDKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.autoTranscribeAttachmentsKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.includeTimestampsInPromptKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.audioLMEndpointURLKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.audioLMModelIDKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.whisperKitActiveModelKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.whisperCppActiveModelKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.remoteUploadConfirmedKey)
        super.tearDown()
    }

    func testOnDeviceRecognitionPolicyIsForcedByOffGrid() {
        UserDefaults.standard.set(false, forKey: TranscriptionSettings.onDeviceOnlyKey)

        XCTAssertFalse(TranscriptionSettings.requiresOnDeviceRecognition(offGrid: false))
        XCTAssertTrue(TranscriptionSettings.requiresOnDeviceRecognition(offGrid: true))
    }

    func testAutoTranscribeAttachmentSettingDefaultsOff() {
        XCTAssertFalse(TranscriptionSettings.autoTranscribesAttachments)

        UserDefaults.standard.set(true, forKey: TranscriptionSettings.autoTranscribeAttachmentsKey)

        XCTAssertTrue(TranscriptionSettings.autoTranscribesAttachments)
    }

    func testTranscriptArtifactRoundTripsAndFormatsSegments() throws {
        let artifact = TranscriptArtifact(
            engineID: .appleSpeech,
            localeIdentifier: "en_US",
            originalFilename: "lecture.m4a",
            sourceMediaPath: "/tmp/lecture.m4a",
            transcriptText: "Hello world.",
            segments: [
                TranscriptSegment(text: "Hello", startTime: 1.2, duration: 0.4, confidence: 0.9),
                TranscriptSegment(text: "world", startTime: 62.0, duration: 0.5, confidence: 0.8),
            ],
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(TranscriptArtifact.self, from: data)

        XCTAssertEqual(decoded, artifact)
        XCTAssertTrue(decoded.segmentText.contains("[0:01] Hello"))
        XCTAssertTrue(decoded.segmentText.contains("[1:02] world"))
        XCTAssertTrue(decoded.promptBlock.contains("lecture.m4a"))
    }

    func testTranscriptSegmentCoalescerGroupsWordLevelSegmentsIntoReadablePhrases() {
        let segments = [
            TranscriptSegment(text: "Welcome", startTime: 0.1, duration: 0.15, confidence: 0.9),
            TranscriptSegment(text: "in", startTime: 0.3, duration: 0.1, confidence: 0.8),
            TranscriptSegment(text: "this", startTime: 0.45, duration: 0.1, confidence: 0.8),
            TranscriptSegment(text: "video", startTime: 0.62, duration: 0.2, confidence: 0.9),
            TranscriptSegment(text: "we", startTime: 1.0, duration: 0.12, confidence: 0.7),
            TranscriptSegment(text: "are", startTime: 1.2, duration: 0.1, confidence: 0.7),
            TranscriptSegment(text: "going", startTime: 1.4, duration: 0.2, confidence: 0.8),
            TranscriptSegment(text: "to", startTime: 1.7, duration: 0.1, confidence: 0.8),
            TranscriptSegment(text: "create", startTime: 1.9, duration: 0.2, confidence: 0.9),
            TranscriptSegment(text: "an", startTime: 2.3, duration: 0.1, confidence: 0.8),
            TranscriptSegment(text: "activated", startTime: 2.6, duration: 0.25, confidence: 0.8),
            TranscriptSegment(text: "charcoal", startTime: 2.9, duration: 0.25, confidence: 0.8),
            TranscriptSegment(text: "air", startTime: 3.3, duration: 0.18, confidence: 0.8),
            TranscriptSegment(text: "battery.", startTime: 3.6, duration: 0.3, confidence: 0.8)
        ]

        let coalesced = TranscriptSegmentCoalescer.coalesce(segments)

        XCTAssertEqual(coalesced.count, 1)
        XCTAssertEqual(coalesced[0].text, "Welcome in this video we are going to create an activated charcoal air battery.")
        XCTAssertEqual(coalesced[0].timestampLabel, "0:00")
        XCTAssertEqual(coalesced[0].duration, 3.8, accuracy: 0.0001)
        XCTAssertEqual(coalesced[0].confidence ?? 0, 0.8071, accuracy: 0.0001)
    }

    func testTranscriptSegmentCoalescerSplitsOnSentenceBoundaryAndLongGap() {
        let segments = [
            TranscriptSegment(text: "First", startTime: 0, duration: 0.2),
            TranscriptSegment(text: "sentence.", startTime: 0.3, duration: 0.3),
            TranscriptSegment(text: "Second", startTime: 0.7, duration: 0.2),
            TranscriptSegment(text: "phrase", startTime: 0.9, duration: 0.2),
            TranscriptSegment(text: "after", startTime: 4.0, duration: 0.2),
            TranscriptSegment(text: "pause", startTime: 4.3, duration: 0.2)
        ]

        let coalesced = TranscriptSegmentCoalescer.coalesce(segments)

        XCTAssertEqual(coalesced.map(\.text), ["First sentence.", "Second phrase", "after pause"])
        XCTAssertEqual(coalesced.map(\.timestampLabel), ["0:00", "0:00", "0:04"])
    }

    func testMediaSupportClassifiesAudioAndVideo() {
        XCTAssertEqual(TranscriptionMediaSupport.kind(for: URL(fileURLWithPath: "/tmp/a.m4a")), .audio)
        XCTAssertEqual(TranscriptionMediaSupport.kind(for: URL(fileURLWithPath: "/tmp/a.WAV")), .audio)
        XCTAssertEqual(TranscriptionMediaSupport.kind(for: URL(fileURLWithPath: "/tmp/v.mov")), .video)
        XCTAssertEqual(TranscriptionMediaSupport.kind(for: URL(fileURLWithPath: "/tmp/v.mp4")), .video)
        XCTAssertNil(TranscriptionMediaSupport.kind(for: URL(fileURLWithPath: "/tmp/note.txt")))
    }

    func testChatMessageDecodesLegacyImagePathsWithoutMediaAttachments() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "role": "🧑‍💻",
          "text": "hello",
          "timestamp": 0,
          "imagePaths": ["/tmp/image.jpg"]
        }
        """

        let data = Data(json.utf8)
        let msg = try JSONDecoder().decode(ChatVM.Msg.self, from: data)

        XCTAssertEqual(msg.imagePaths, ["/tmp/image.jpg"])
        XCTAssertNil(msg.mediaAttachments)
    }

    func testPromptTextIncludesTranscriptBlocks() {
        let artifact = TranscriptArtifact(
            engineID: .appleSpeech,
            localeIdentifier: "en_US",
            originalFilename: "meeting.m4a",
            sourceMediaPath: "/tmp/meeting.m4a",
            transcriptText: "Budget review notes.",
            segments: []
        )
        let attachment = ChatMediaAttachment(
            kind: .audio,
            originalFilename: "meeting.m4a",
            storedPath: "/tmp/meeting.m4a",
            fileSizeBytes: 2048,
            durationSeconds: 65,
            status: .completed,
            transcript: artifact
        )

        let prompt = ChatVM.promptText(userText: "Summarize this.", mediaAttachments: [attachment])

        XCTAssertTrue(prompt.contains("Summarize this."))
        XCTAssertTrue(prompt.contains("[Transcript: meeting.m4a]"))
        XCTAssertTrue(prompt.contains("Budget review notes."))
        XCTAssertEqual(attachment.durationLabel, "1:05")
        XCTAssertNotNil(attachment.mediaDetailLabel)
    }

    func testModelFacingHistoryUsesTranscriptExpandedPrompt() {
        let visibleHistory = [
            ChatVM.Msg(role: "🧑‍💻", text: "Summarize this transcript.", timestamp: Date()),
            ChatVM.Msg(role: "🤖", text: "", timestamp: Date(), streaming: true)
        ]
        let modelInput = """
        Summarize this transcript.

        [Transcript: Chem Final video.mp4]
        Transcript body.
        """

        let modelHistory = ChatVM.modelFacingHistory(visibleHistory: visibleHistory, modelInput: modelInput)

        XCTAssertEqual(visibleHistory[0].text, "Summarize this transcript.")
        XCTAssertEqual(modelHistory[0].text, modelInput)
        XCTAssertEqual(modelHistory[1].role, "🤖")
    }

    func testPromptTextCanIncludeTranscriptTimestamps() {
        let artifact = TranscriptArtifact(
            engineID: .whisperCpp,
            localeIdentifier: "en_US",
            originalFilename: "interview.wav",
            sourceMediaPath: "/tmp/interview.wav",
            transcriptText: "Opening question. Answer.",
            segments: [
                TranscriptSegment(text: "Opening question.", startTime: 3, duration: 1.5),
                TranscriptSegment(text: "Answer.", startTime: 65, duration: 2)
            ]
        )
        let attachment = ChatMediaAttachment(
            kind: .audio,
            originalFilename: "interview.wav",
            storedPath: "/tmp/interview.wav",
            status: .completed,
            transcript: artifact
        )

        UserDefaults.standard.set(true, forKey: TranscriptionSettings.includeTimestampsInPromptKey)

        let prompt = ChatVM.promptText(userText: "Use the transcript.", mediaAttachments: [attachment])

        XCTAssertTrue(prompt.contains("[0:03] Opening question."))
        XCTAssertTrue(prompt.contains("[1:05] Answer."))
    }

    func testWhisperFinalizerPreservesMultipleChunksAndSegments() throws {
        let artifact = try WhisperTranscriptionFinalizer.artifact(
            engineID: .whisperKit,
            localeIdentifier: "en",
            originalFilename: "lecture.mp4",
            sourceMediaPath: "/tmp/lecture.mp4",
            chunks: [
                WhisperTranscriptionChunk(
                    text: " First sentence. ",
                    segments: [
                        WhisperTranscriptionSegment(text: " First sentence. ", startTime: 0.2, endTime: 1.7)
                    ]
                ),
                WhisperTranscriptionChunk(
                    text: "Second sentence.",
                    segments: [
                        WhisperTranscriptionSegment(text: "Second sentence.", startTime: 2.1, endTime: 4.0)
                    ]
                )
            ]
        )

        XCTAssertEqual(artifact.transcriptText, "First sentence. Second sentence.")
        XCTAssertEqual(artifact.segments.map(\.text), ["First sentence.", "Second sentence."])
        XCTAssertEqual(artifact.segments.map(\.timestampLabel), ["0:00", "0:02"])
        XCTAssertEqual(artifact.segments[0].duration, 1.5, accuracy: 0.0001)
        XCTAssertEqual(artifact.segments[1].duration, 1.9, accuracy: 0.0001)
        XCTAssertEqual(artifact.sourceMediaPath, "/tmp/lecture.mp4")
    }

    func testWhisperFinalizerFallsBackToSegmentsAndRejectsEmptyOutput() throws {
        let artifact = try WhisperTranscriptionFinalizer.artifact(
            engineID: .whisperCpp,
            localeIdentifier: "en_US",
            originalFilename: "interview.wav",
            sourceMediaPath: "/tmp/interview.wav",
            chunks: [
                WhisperTranscriptionChunk(
                    text: "   ",
                    segments: [
                        WhisperTranscriptionSegment(text: "Recovered segment text.", startTime: 1, endTime: 3)
                    ]
                )
            ]
        )

        XCTAssertEqual(artifact.transcriptText, "Recovered segment text.")
        XCTAssertEqual(artifact.segments.count, 1)
        XCTAssertThrowsError(
            try WhisperTranscriptionFinalizer.artifact(
                engineID: .whisperCpp,
                localeIdentifier: "en_US",
                originalFilename: "empty.wav",
                sourceMediaPath: "/tmp/empty.wav",
                chunks: [WhisperTranscriptionChunk(text: " ", segments: [])]
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, TranscriptionError.emptyTranscript.localizedDescription)
        }
    }

    func testWhisperPartialAccumulatorRejectsTrivialPartials() {
        var accumulator = WhisperPartialAccumulator()

        XCTAssertNil(accumulator.ingest(" "))
        XCTAssertNil(accumulator.ingest("e"))
        XCTAssertNil(accumulator.ingest("..."))
        XCTAssertEqual(accumulator.receivedCount, 3)
        XCTAssertEqual(accumulator.promotedCount, 0)
        XCTAssertNil(accumulator.lastMeaningfulPartial)
    }

    func testWhisperPartialAccumulatorPromotesMeaningfulPartialOnce() {
        var accumulator = WhisperPartialAccumulator()

        XCTAssertEqual(accumulator.ingest("  First visible words  "), "First visible words")
        XCTAssertNil(accumulator.ingest("First visible words"))
        XCTAssertEqual(accumulator.receivedCount, 2)
        XCTAssertEqual(accumulator.promotedCount, 1)
        XCTAssertEqual(accumulator.lastMeaningfulPartial, "First visible words")
    }

    func testWhisperPartialAccumulatorPreservesResetChunks() {
        var accumulator = WhisperPartialAccumulator()

        XCTAssertEqual(accumulator.ingest("First visible chunk"), "First visible chunk")
        XCTAssertEqual(
            accumulator.ingest("First visible chunk keeps growing with enough words for one decode window."),
            "First visible chunk keeps growing with enough words for one decode window."
        )
        XCTAssertEqual(
            accumulator.ingest("Second visible chunk."),
            "First visible chunk keeps growing with enough words for one decode window.\n\nSecond visible chunk."
        )
        XCTAssertEqual(accumulator.chunkCount, 2)
        XCTAssertEqual(accumulator.snapshotText, "First visible chunk keeps growing with enough words for one decode window.\n\nSecond visible chunk.")
    }

    func testWhisperPartialAccumulatorTreatsGrowingPartialsAsReplacement() {
        var accumulator = WhisperPartialAccumulator()

        XCTAssertEqual(accumulator.ingest("First"), "First")
        XCTAssertEqual(accumulator.ingest("First chunk"), "First chunk")
        XCTAssertEqual(accumulator.ingest("First chunk grows."), "First chunk grows.")

        XCTAssertEqual(accumulator.chunkCount, 1)
        XCTAssertEqual(accumulator.snapshotText, "First chunk grows.")
    }

    func testWhisperFinalizerUsesMeaningfulPartialFallbackWhenFinalOutputIsEmpty() throws {
        let artifact = try WhisperTranscriptionFinalizer.artifact(
            engineID: .whisperKit,
            localeIdentifier: "en",
            originalFilename: "lecture.mp4",
            sourceMediaPath: "/tmp/lecture.mp4",
            chunks: [WhisperTranscriptionChunk(text: " ", segments: [])],
            partialFallbackText: "Recovered from partial output."
        )

        XCTAssertEqual(artifact.transcriptText, "Recovered from partial output.")
        XCTAssertTrue(artifact.segments.isEmpty)
        XCTAssertTrue(
            WhisperTranscriptionFinalizer.wouldUsePartialFallback(
                chunks: [WhisperTranscriptionChunk(text: " ", segments: [])],
                partialFallbackText: "Recovered from partial output."
            )
        )
    }

    func testWhisperFinalizerUsesAccumulatedPartialWhenFinalOutputIsOnlyLastWindow() throws {
        let accumulatedPartial = [
            "First window has enough lecture text to represent the beginning of the recording.",
            "Second window has enough lecture text to make the final short result clearly incomplete.",
            "Last window only."
        ].joined(separator: "\n\n")

        let artifact = try WhisperTranscriptionFinalizer.artifact(
            engineID: .whisperKit,
            localeIdentifier: "en",
            originalFilename: "lecture.mp4",
            sourceMediaPath: "/tmp/lecture.mp4",
            chunks: [
                WhisperTranscriptionChunk(
                    text: "Last window only.",
                    segments: [
                        WhisperTranscriptionSegment(text: "Last window only.", startTime: 90, endTime: 92)
                    ]
                )
            ],
            partialFallbackText: accumulatedPartial
        )

        XCTAssertEqual(artifact.transcriptText, accumulatedPartial)
        XCTAssertTrue(artifact.segments.isEmpty)
        XCTAssertTrue(
            WhisperTranscriptionFinalizer.wouldUsePartialFallback(
                chunks: [
                    WhisperTranscriptionChunk(
                        text: "Last window only.",
                        segments: [
                            WhisperTranscriptionSegment(text: "Last window only.", startTime: 90, endTime: 92)
                        ]
                    )
                ],
                partialFallbackText: accumulatedPartial
            )
        )
    }

    func testWhisperFinalizerUsesDiscoveredSegmentsWhenResultsAreEmpty() throws {
        let artifact = try WhisperTranscriptionFinalizer.artifact(
            engineID: .whisperKit,
            localeIdentifier: "en",
            originalFilename: "lecture.mp4",
            sourceMediaPath: "/tmp/lecture.mp4",
            chunks: [],
            discoveredSegments: [
                WhisperTranscriptionSegment(text: "First discovered segment.", startTime: 0, endTime: 2),
                WhisperTranscriptionSegment(text: "Second discovered segment.", startTime: 32, endTime: 35)
            ]
        )

        XCTAssertEqual(artifact.transcriptText, "First discovered segment. Second discovered segment.")
        XCTAssertEqual(artifact.segments.map(\.text), ["First discovered segment.", "Second discovered segment."])
        XCTAssertEqual(artifact.segments.map(\.timestampLabel), ["0:00", "0:32"])
    }

    func testTranscriptReviewRowsUseTimestampsOrParagraphFallback() {
        let timestamped = TranscriptArtifact(
            engineID: .whisperKit,
            localeIdentifier: "en",
            originalFilename: "lecture.mp4",
            sourceMediaPath: "/tmp/lecture.mp4",
            transcriptText: "First. Second.",
            segments: [
                TranscriptSegment(text: "First.", startTime: 1, duration: 1),
                TranscriptSegment(text: "Second.", startTime: 61, duration: 1)
            ]
        )
        XCTAssertEqual(
            timestamped.reviewSegmentRows,
            [
                TranscriptReviewDisplayRow(label: "0:01", text: "First."),
                TranscriptReviewDisplayRow(label: "1:01", text: "Second.")
            ]
        )
        XCTAssertEqual(timestamped.reviewSegmentText, "[0:01] First.\n[1:01] Second.")

        let paragraphFallback = TranscriptArtifact(
            engineID: .whisperKit,
            localeIdentifier: "en",
            originalFilename: "lecture.mp4",
            sourceMediaPath: "/tmp/lecture.mp4",
            transcriptText: "First paragraph.\n\nSecond paragraph.",
            segments: []
        )
        XCTAssertEqual(
            paragraphFallback.reviewSegmentRows,
            [
                TranscriptReviewDisplayRow(label: "1", text: "First paragraph."),
                TranscriptReviewDisplayRow(label: "2", text: "Second paragraph.")
            ]
        )
        XCTAssertEqual(paragraphFallback.reviewSegmentText, "[1] First paragraph.\n[2] Second paragraph.")
    }

    func testWhisperFinalizerRejectsEmptyOutputWhenPartialFallbackIsTrivial() {
        XCTAssertThrowsError(
            try WhisperTranscriptionFinalizer.artifact(
                engineID: .whisperKit,
                localeIdentifier: "en",
                originalFilename: "empty.mp4",
                sourceMediaPath: "/tmp/empty.mp4",
                chunks: [WhisperTranscriptionChunk(text: " ", segments: [])],
                partialFallbackText: "e"
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, TranscriptionError.emptyTranscript.localizedDescription)
        }
    }

    func testWhisperCppDecodeEstimateRejectsOversizedFullBufferInput() {
        let smallClipBytes = MediaAudioExtractor.estimatedFullBufferDecodeBytes(
            sourceFrameCount: 44_100 * 60,
            sourceSampleRate: 44_100,
            sourceBytesPerFrame: 8
        )
        let longVideoBytes = MediaAudioExtractor.estimatedFullBufferDecodeBytes(
            sourceFrameCount: 44_100 * 60 * 60,
            sourceSampleRate: 44_100,
            sourceBytesPerFrame: 8
        )

        XCTAssertLessThan(smallClipBytes, MediaAudioExtractor.whisperCppFullBufferDecodeLimitBytes)
        XCTAssertGreaterThan(longVideoBytes, MediaAudioExtractor.whisperCppFullBufferDecodeLimitBytes)
        XCTAssertEqual(
            MediaAudioExtractorError.oversizedForFullBufferDecode.localizedDescription,
            "This media is too long for whisper.cpp's memory-safe decoder. Trim it or use Apple Speech/WhisperKit, then retry."
        )
    }

    func testTranscriptProvenanceIsAddedForSelectedEngine() {
        UserDefaults.standard.set("remote-whisper", forKey: TranscriptionSettings.audioLMModelIDKey)
        let options = TranscriptionRequestOptions(
            localeIdentifier: "en_US",
            requiresOnDeviceRecognition: false,
            reportsPartialResults: true
        )
        let artifact = TranscriptArtifact(
            engineID: .appleSpeech,
            localeIdentifier: "en_US",
            originalFilename: "call.m4a",
            sourceMediaPath: "/tmp/call.m4a",
            transcriptText: "Discussed launch.",
            segments: [TranscriptSegment(text: "Discussed launch.", startTime: 0, duration: 1)]
        ).withProvenance(engineID: .audioLanguageModel, options: options)

        XCTAssertEqual(artifact.engineID, .audioLanguageModel)
        XCTAssertEqual(artifact.engineDisplayName, TranscriptionEngineID.audioLanguageModel.displayName)
        XCTAssertEqual(artifact.modelIdentifier, "remote-whisper")
        XCTAssertEqual(artifact.modelDisplayName, "remote-whisper")
        XCTAssertEqual(artifact.recognitionMode, .remote)
        XCTAssertEqual(artifact.hasTimestampSegments, true)
        XCTAssertTrue(artifact.provenanceSummary.contains("remote-whisper"))
    }

    func testEditedTranscriptPromptUsesEditedTextAndKeepsMetadata() {
        let artifact = TranscriptArtifact(
            engineID: .whisperCpp,
            localeIdentifier: "en_US",
            originalFilename: "meeting.wav",
            sourceMediaPath: "/tmp/meeting.wav",
            transcriptText: "Original transcript.",
            segments: [TranscriptSegment(text: "Original transcript.", startTime: 0, duration: 1)],
            engineDisplayName: "whisper.cpp",
            modelIdentifier: "whisper-base",
            modelDisplayName: "Whisper Base",
            recognitionMode: .onDevice
        ).updatingReview(title: "Edited meeting", transcriptText: "Edited transcript.")

        let prompt = artifact.promptBlock(includeTimestamps: true)

        XCTAssertTrue(prompt.contains("[Transcript: Edited meeting]"))
        XCTAssertTrue(prompt.contains("Edited transcript."))
        XCTAssertFalse(prompt.contains("[0:00] Original transcript."))
        XCTAssertTrue(prompt.contains("Model: Whisper Base (whisper-base)"))
        XCTAssertEqual(artifact.originalFilename, "meeting.wav")
    }

    func testRemoteUploadConfirmationPersistsFirstUseGate() {
        XCTAssertFalse(TranscriptionSettings.hasConfirmedRemoteUpload)

        TranscriptionSettings.confirmRemoteUpload()

        XCTAssertTrue(TranscriptionSettings.hasConfirmedRemoteUpload)
    }

    func testPrimaryASREngineChoicesHideAdvancedRemoteBackend() {
        let choices = TranscriptionBackendFactory.primaryEngineChoices()

        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices.contains { $0.id == .appleSpeech })
        XCTAssertTrue(choices.contains { $0.id.isLocalWhisper })
        XCTAssertFalse(choices.contains { $0.id == .audioLanguageModel })
    }

    func testLocalWhisperPreferenceResolvesToWhisperRuntime() {
        let preferred = TranscriptionBackendFactory.preferredLocalWhisperEngineID()

        XCTAssertTrue(preferred.isLocalWhisper)
        XCTAssertTrue(TranscriptionBackendFactory.primaryEngineChoices().contains { $0.id == preferred })
    }

    func testStoredWhisperRuntimeSelectionsResolveSafely() {
        UserDefaults.standard.set(TranscriptionEngineID.whisperKit.rawValue, forKey: TranscriptionSettings.engineIDKey)
        XCTAssertTrue(TranscriptionSettings.selectedEngineID.isLocalWhisper)

        UserDefaults.standard.set(TranscriptionEngineID.whisperCpp.rawValue, forKey: TranscriptionSettings.engineIDKey)
        XCTAssertTrue(TranscriptionSettings.selectedEngineID.isLocalWhisper)
    }

    func testUnconfiguredRemoteASRSelectionResolvesToAppleSpeech() {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.audioLMEndpointURLKey)
        UserDefaults.standard.set(TranscriptionEngineID.audioLanguageModel.rawValue, forKey: TranscriptionSettings.engineIDKey)

        XCTAssertEqual(TranscriptionSettings.selectedEngineID, .appleSpeech)
    }

    func testRecoveryActionsMapCommonFailureTypes() {
        XCTAssertEqual(
            ASRRecoveryAction.actions(for: "On-device transcription is unavailable for zz_ZZ.", includeRetry: true),
            [.chooseLocale, .openSettings, .retry]
        )
        XCTAssertTrue(
            ASRRecoveryAction.actions(for: "Whisper model is missing. Download a model.", includeRetry: true)
                .contains(.downloadWhisperModel)
        )
        XCTAssertFalse(
            ASRRecoveryAction.actions(for: "Remote endpoint failed.", includeRetry: true)
                .contains(.configureEndpoint)
        )
        XCTAssertTrue(
            ASRRecoveryAction.actions(for: "Remote endpoint failed.", includeRetry: true, includeRemoteEndpoint: true)
                .contains(.configureEndpoint)
        )
    }

    func testWhisperActiveRecordsPersistSeparatelyByRuntime() {
        WhisperModelCatalog.setActiveRecordID("whisper-small", for: .whisperKit)
        WhisperModelCatalog.setActiveRecordID("whisper-base", for: .whisperCpp)

        XCTAssertEqual(WhisperModelCatalog.activeRecordID(for: .whisperKit), "whisper-small")
        XCTAssertEqual(WhisperModelCatalog.activeRecordID(for: .whisperCpp), "whisper-base")
        XCTAssertEqual(UserDefaults.standard.string(forKey: TranscriptionSettings.whisperKitActiveModelKey), "whisper-small")
        XCTAssertEqual(UserDefaults.standard.string(forKey: TranscriptionSettings.whisperCppActiveModelKey), "whisper-base")
    }

    func testWhisperCppInstallStateRequiresModelFile() throws {
        let record = try XCTUnwrap(WhisperModelCatalog.record(for: "whisper-tiny"))
        let dir = record.directoryURL(runtime: .ggml)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(WhisperModelCatalog.installationState(for: record, runtime: .ggml), .missing)

        let fileURL = try XCTUnwrap(record.installedURL(runtime: .ggml))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ggml".utf8).write(to: fileURL)

        XCTAssertEqual(WhisperModelCatalog.installationState(for: record, runtime: .ggml), .ready)
    }

    func testWhisperKitDirectoryWithoutPackageIsIncomplete() throws {
        let record = try XCTUnwrap(WhisperModelCatalog.record(for: "whisper-tiny"))
        let dir = record.directoryURL(runtime: .whisperKit)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".cache/huggingface/download", isDirectory: true),
            withIntermediateDirectories: true
        )
        let incomplete = dir.appendingPathComponent(".cache/huggingface/download/weight.bin.incomplete")
        try Data("partial".utf8).write(to: incomplete)

        XCTAssertEqual(WhisperModelCatalog.installationState(for: record, runtime: .whisperKit), .incomplete)
    }

    func testWhisperKitInstallStateRequiresCoreMLWeights() throws {
        let record = try XCTUnwrap(WhisperModelCatalog.record(for: "whisper-tiny"))
        let artifact = try XCTUnwrap(record.artifact(for: .whisperKit))
        let dir = record.directoryURL(runtime: .whisperKit)
        let modelFolder = WhisperModelCatalog.whisperKitModelFolderURL(recordID: record.id, artifact: artifact)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: modelFolder.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(WhisperModelCatalog.installationState(for: record, runtime: .whisperKit), .incomplete)

        let weights = modelFolder.appendingPathComponent("TextDecoder.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: weights.appendingPathComponent("weight.bin"))

        XCTAssertEqual(WhisperModelCatalog.installationState(for: record, runtime: .whisperKit), .ready)
    }

    func testSupportInventorySurfacesPausedAndFailedWhisperDownloads() throws {
        let record = try XCTUnwrap(WhisperModelCatalog.record(for: "whisper-tiny"))
        WhisperModelCatalog.setActiveRecordID(record.id, for: .whisperCpp)

        var pausedItem = DownloadController.WhisperItem(record: record, runtime: .ggml)
        pausedItem.status = .paused
        XCTAssertEqual(
            SupportModelInventory.speechItem(selectedEngineID: .whisperCpp, whisperItems: [pausedItem]).state,
            .paused
        )

        var failedItem = DownloadController.WhisperItem(record: record, runtime: .ggml)
        failedItem.status = .failed
        XCTAssertEqual(
            SupportModelInventory.speechItem(selectedEngineID: .whisperCpp, whisperItems: [failedItem]).state,
            .failed
        )
    }

    #if canImport(WhisperKit)
    func testWhisperKitBackendDoesNotDownloadImplicitlyWhenModelIsMissing() async throws {
        let record = try XCTUnwrap(WhisperModelCatalog.record(for: "whisper-tiny"))
        WhisperModelCatalog.setActiveRecordID(record.id, for: .whisperKit)
        let dir = record.directoryURL(runtime: .whisperKit)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaTranscriptionTests-\(UUID().uuidString).wav")
        try Data("not real audio".utf8).write(to: mediaURL)
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let backend = WhisperKitTranscriptionBackend()
        do {
            _ = try await backend.transcribe(
                mediaURL: mediaURL,
                originalFilename: "missing.wav",
                options: TranscriptionRequestOptions(localeIdentifier: "en_US", requiresOnDeviceRecognition: true, reportsPartialResults: true),
                onEvent: { _ in }
            )
            XCTFail("Expected missing model error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Download a Whisper model"))
            XCTAssertTrue(
                ASRRecoveryAction.actions(for: error.localizedDescription, includeRetry: true)
                    .contains(.downloadWhisperModel)
            )
        }
    }
    #endif

    @MainActor
    func testDatasetMediaImportUsesConfiguredTranscriptionBackend() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mediaURL = tempDir.appendingPathComponent("meeting.wav")
        try Data("not real audio".utf8).write(to: mediaURL)

        let storedEngine = TranscriptionEngineID.whisperCpp
        let expectedEngine = TranscriptionBackendFactory.resolvedLocalWhisperEngineID(preferred: storedEngine)
        UserDefaults.standard.set(storedEngine.rawValue, forKey: TranscriptionSettings.engineIDKey)

        var routedEngine: TranscriptionEngineID?
        DatasetManager.makeTranscriptionBackend = { engineID in
            routedEngine = engineID
            return StubTranscriptionBackend(engineID: engineID)
        }
        defer {
            DatasetManager.makeTranscriptionBackend = {
                try TranscriptionBackendFactory.makeBackend(for: $0)
            }
        }

        let manager = DatasetManager()
        let dataset = await manager.importDocuments(from: [mediaURL], suggestedName: "ASR Route \(UUID().uuidString)")
        defer {
            if let dataset {
                try? FileManager.default.removeItem(at: dataset.url)
            }
        }

        XCTAssertEqual(routedEngine, expectedEngine)
        let unwrapped = try XCTUnwrap(dataset)
        let metadataDir = DatasetIndexIO.transcriptMetadataDirectoryURL(for: unwrapped.url)
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: metadataDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(metadataFiles.filter { $0.pathExtension == "json" }.count, 1)
        XCTAssertEqual(manager.mediaImportProgressItems.count, 1)
        XCTAssertEqual(manager.mediaImportProgressItems.first?.state, .succeeded)
    }

    func testUnavailableAudioLanguageEngineDoesNotFallBackToAppleSpeech() {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.audioLMEndpointURLKey)

        XCTAssertThrowsError(try TranscriptionBackendFactory.makeBackend(for: .audioLanguageModel)) { error in
            guard case TranscriptionError.engineUnavailable(let engineName, let reason) = error else {
                return XCTFail("Expected engineUnavailable, got \(error)")
            }
            XCTAssertEqual(engineName, TranscriptionEngineID.audioLanguageModel.displayName)
            XCTAssertTrue(reason.contains("Configure a remote endpoint"))
        }
    }

    func testEngineUnavailableErrorIsUserFacing() {
        let error = TranscriptionError.engineUnavailable("whisper.cpp", "whisper.cpp is not linked in this build.")

        XCTAssertEqual(error.errorDescription, "whisper.cpp is unavailable. whisper.cpp is not linked in this build.")
    }

    func testCompletedMediaBadgeUsesTranscribedKey() {
        XCTAssertEqual(ChatMediaTranscriptionStatus.completed.badgeLocalizationKey, "Transcribed")
    }

    func testTranscribingMediaStatusUsesInlineProgressOnly() {
        XCTAssertFalse(ChatMediaTranscriptionStatus.transcribing.showsStandaloneStatusLabel)
        XCTAssertTrue(ChatMediaTranscriptionStatus.notStarted.showsStandaloneStatusLabel)
        XCTAssertTrue(ChatMediaTranscriptionStatus.completed.showsStandaloneStatusLabel)
        XCTAssertTrue(ChatMediaTranscriptionStatus.failed.showsStandaloneStatusLabel)
    }

    func testAppleSpeechUsesLastPartialWhenFinalTranscriptIsEmpty() {
        XCTAssertEqual(
            AppleSpeechTranscriptionBackend.resolvedTranscriptText(
                finalTranscript: "   ",
                lastPartialTranscript: "Visible partial transcript."
            ),
            "Visible partial transcript."
        )
    }

    func testAppleSpeechEmptyFinalWithoutPartialRemainsNoSpeech() {
        XCTAssertNil(
            AppleSpeechTranscriptionBackend.resolvedTranscriptText(
                finalTranscript: "\n",
                lastPartialTranscript: nil
            )
        )
        XCTAssertNil(
            AppleSpeechTranscriptionBackend.resolvedTranscriptText(
                finalTranscript: "",
                lastPartialTranscript: "   "
            )
        )
    }

    func testAppleSpeechAccumulatorPreservesNonCumulativeChunksAndSegments() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.ingest(
            transcript: "First chunk.",
            segments: [TranscriptSegment(text: "First chunk.", startTime: 0, duration: 1)]
        )
        let partial = accumulator.ingest(
            transcript: "Second chunk.",
            segments: [TranscriptSegment(text: "Second chunk.", startTime: 12, duration: 1)]
        )
        let final = accumulator.finalSnapshot(finalTranscript: "", finalSegments: [])

        XCTAssertEqual(partial.text, "First chunk.\n\nSecond chunk.")
        XCTAssertEqual(final.text, "First chunk.\n\nSecond chunk.")
        XCTAssertEqual(final.segments.map(\.text), ["First chunk.", "Second chunk."])
    }

    func testAppleSpeechAccumulatorTreatsGrowingPartialsAsReplacement() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        _ = accumulator.ingest(
            transcript: "First",
            segments: [TranscriptSegment(text: "First", startTime: 0, duration: 0.5)]
        )
        let partial = accumulator.ingest(
            transcript: "First chunk.",
            segments: [
                TranscriptSegment(text: "First", startTime: 0, duration: 0.5),
                TranscriptSegment(text: "chunk.", startTime: 0.6, duration: 0.5)
            ]
        )

        XCTAssertEqual(partial.text, "First chunk.")
        XCTAssertEqual(partial.segments.map(\.text), ["First", "chunk."])
    }

    @MainActor
    func testDatasetMediaImportReportsTranscriptionFailures() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mediaURL = tempDir.appendingPathComponent("failed-meeting.wav")
        try Data("not real audio".utf8).write(to: mediaURL)

        DatasetManager.makeTranscriptionBackend = { _ in
            ThrowingTranscriptionBackend(error: .emptyTranscript)
        }
        defer {
            DatasetManager.makeTranscriptionBackend = {
                try TranscriptionBackendFactory.makeBackend(for: $0)
            }
        }

        let manager = DatasetManager()
        let suggestedName = "ASR Failure \(UUID().uuidString)"
        let dataset = await manager.importDocuments(from: [mediaURL], suggestedName: suggestedName)
        defer { Self.removeImportedDataset(named: suggestedName) }

        XCTAssertNil(dataset)
        let message = try XCTUnwrap(manager.embedAlert?.message)
        XCTAssertTrue(message.contains("Media could not be transcribed"))
        XCTAssertTrue(message.contains("failed-meeting.wav"))
        XCTAssertTrue(message.contains("No speech was recognized"))
        XCTAssertEqual(manager.mediaImportProgressItems.first?.state, .failed("No speech was recognized in this media."))
    }

    @MainActor
    func testDatasetMediaImportKeepsPartialSuccessAndWarns() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let goodURL = tempDir.appendingPathComponent("good.wav")
        let badURL = tempDir.appendingPathComponent("bad.wav")
        try Data("not real audio".utf8).write(to: goodURL)
        try Data("not real audio".utf8).write(to: badURL)

        DatasetManager.makeTranscriptionBackend = { engineID in
            SelectiveTranscriptionBackend(engineID: engineID, failingFilename: "bad.wav")
        }
        defer {
            DatasetManager.makeTranscriptionBackend = {
                try TranscriptionBackendFactory.makeBackend(for: $0)
            }
        }

        let manager = DatasetManager()
        let suggestedName = "ASR Partial \(UUID().uuidString)"
        let dataset = await manager.importDocuments(from: [goodURL, badURL], suggestedName: suggestedName)
        defer {
            if let dataset {
                try? FileManager.default.removeItem(at: dataset.url)
            } else {
                Self.removeImportedDataset(named: suggestedName)
            }
        }

        let unwrapped = try XCTUnwrap(dataset)
        let transcriptDir = unwrapped.url.appendingPathComponent("Media Transcripts", isDirectory: true)
        let transcripts = try FileManager.default.contentsOfDirectory(at: transcriptDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(transcripts.filter { $0.pathExtension == "txt" }.count, 1)
        let message = try XCTUnwrap(manager.embedAlert?.message)
        XCTAssertTrue(message.contains("Some media could not be transcribed"))
        XCTAssertTrue(message.contains("bad.wav"))
        XCTAssertEqual(manager.mediaImportProgressItems.count, 2)
        XCTAssertTrue(manager.mediaImportProgressItems.contains { $0.filename == "good.wav" && $0.state == .succeeded })
        XCTAssertTrue(manager.mediaImportProgressItems.contains { item in
            if case .failed = item.state, item.filename == "bad.wav" { return true }
            return false
        })
    }

    func testOnDeviceUnavailableErrorIsUserFacing() {
        let error = TranscriptionError.onDeviceRecognitionUnavailable("zz_ZZ")

        XCTAssertEqual(error.errorDescription, "On-device transcription is unavailable for zz_ZZ.")
    }

    func testSpeechDaemonErrorIsUserFacing() {
        let error = TranscriptionError.speechDaemonUnavailable("en_US")

        XCTAssertEqual(
            error.errorDescription,
            "Apple Speech could not start transcription for en_US. Try another ASR locale, or turn off on-device transcription only when Off-grid Mode is disabled."
        )
    }

    private struct StubTranscriptionBackend: TranscriptionBackend {
        let engineID: TranscriptionEngineID

        func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
            true
        }

        func transcribe(
            mediaURL: URL,
            originalFilename: String,
            options: TranscriptionRequestOptions,
            onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
        ) async throws -> TranscriptArtifact {
            let artifact = TranscriptArtifact(
                engineID: engineID,
                localeIdentifier: options.localeIdentifier,
                originalFilename: originalFilename,
                sourceMediaPath: mediaURL.path,
                transcriptText: "Stub transcript.",
                segments: [
                    TranscriptSegment(text: "Stub transcript.", startTime: 0, duration: 1)
                ]
            )
            onEvent(.completed(artifact))
            return artifact
        }
    }

    private struct ThrowingTranscriptionBackend: TranscriptionBackend {
        let engineID: TranscriptionEngineID = .appleSpeech
        let error: TranscriptionError

        func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
            true
        }

        func transcribe(
            mediaURL: URL,
            originalFilename: String,
            options: TranscriptionRequestOptions,
            onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
        ) async throws -> TranscriptArtifact {
            throw error
        }
    }

    private struct SelectiveTranscriptionBackend: TranscriptionBackend {
        let engineID: TranscriptionEngineID
        let failingFilename: String

        func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool {
            true
        }

        func transcribe(
            mediaURL: URL,
            originalFilename: String,
            options: TranscriptionRequestOptions,
            onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
        ) async throws -> TranscriptArtifact {
            if originalFilename == failingFilename {
                throw TranscriptionError.emptyTranscript
            }
            let artifact = TranscriptArtifact(
                engineID: engineID,
                localeIdentifier: options.localeIdentifier,
                originalFilename: originalFilename,
                sourceMediaPath: mediaURL.path,
                transcriptText: "Stub transcript.",
                segments: [
                    TranscriptSegment(text: "Stub transcript.", startTime: 0, duration: 1)
                ]
            )
            onEvent(.completed(artifact))
            return artifact
        }
    }

    private static func removeImportedDataset(named name: String) {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMDatasets", isDirectory: true)
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}
