import XCTest
@testable import Noema

final class BackgroundDownloadManagerTests: XCTestCase {
    func testCompleteStagingFileIsAdoptedOnlyAtExactKnownSize() {
        XCTAssertTrue(
            BackgroundDownloadManager.canAdoptCompletedStagingFile(
                existingBytes: 10_000,
                expectedBytes: 10_000
            )
        )
        XCTAssertFalse(
            BackgroundDownloadManager.canAdoptCompletedStagingFile(
                existingBytes: 9_999,
                expectedBytes: 10_000
            )
        )
        XCTAssertFalse(
            BackgroundDownloadManager.canAdoptCompletedStagingFile(
                existingBytes: 10_000,
                expectedBytes: nil
            )
        )
    }

    func testTransportPolicyKeepsEveryActiveIOSVersionOnFastSession() {
        XCTAssertEqual(
            DownloadTransportPolicy.preferred(
                isAppActive: true,
                supportsContinuedProcessing: false,
                hasContinuedProcessingTask: false
            ),
            .foreground
        )
        XCTAssertEqual(
            DownloadTransportPolicy.preferred(
                isAppActive: true,
                supportsContinuedProcessing: true,
                hasContinuedProcessingTask: false
            ),
            .foreground
        )
    }

    func testMacOSActiveProcessAlwaysUsesFastSession() {
        XCTAssertEqual(DownloadTransportPolicy.macOSActiveProcess, .foreground)
    }

    func testTransportPolicyUsesContinuedProcessingOnlyWhileBackgroundedAndProtected() {
        XCTAssertEqual(
            DownloadTransportPolicy.preferred(
                isAppActive: false,
                supportsContinuedProcessing: true,
                hasContinuedProcessingTask: true
            ),
            .foreground
        )
        XCTAssertEqual(
            DownloadTransportPolicy.preferred(
                isAppActive: false,
                supportsContinuedProcessing: true,
                hasContinuedProcessingTask: false
            ),
            .background
        )
        XCTAssertEqual(
            DownloadTransportPolicy.preferred(
                isAppActive: false,
                supportsContinuedProcessing: false,
                hasContinuedProcessingTask: true
            ),
            .background
        )
    }

    func testProgressThrottlerCoalescesTicksAndAllowsForcedCompletion() {
        var now = 100.0
        let throttler = ProgressThrottler<String>(interval: 0.5, nowSeconds: { now })

        XCTAssertTrue(throttler.shouldAllow(key: "download"))
        now += 0.1
        XCTAssertFalse(throttler.shouldAllow(key: "download"))
        now += 0.4
        XCTAssertTrue(throttler.shouldAllow(key: "download"))
        now += 0.01
        XCTAssertTrue(throttler.shouldAllow(key: "download", force: true))

        throttler.clear(key: "download")
        XCTAssertTrue(throttler.shouldAllow(key: "download"))
    }

    func testTaskSnapshotIncludesResumeOffsetInWrittenTotal() {
        let snapshot = BackgroundDownloadManager.makeTaskSnapshot(
            jobID: "job-1",
            artifactID: "artifact-1",
            destination: URL(fileURLWithPath: "/tmp/model.gguf"),
            resumeOffset: 4_000,
            bytesReceived: 2_000,
            taskExpected: 6_000,
            recordedExpected: 10_000,
            hasLiveTask: true
        )

        XCTAssertEqual(snapshot.jobID, "job-1")
        XCTAssertEqual(snapshot.artifactID, "artifact-1")
        XCTAssertEqual(snapshot.resumeOffset, 4_000)
        XCTAssertEqual(snapshot.bytesReceived, 2_000)
        XCTAssertEqual(snapshot.writtenTotal, 6_000)
        XCTAssertEqual(snapshot.fullExpected, 10_000)
        XCTAssertTrue(snapshot.hasLiveTask)
    }

    func testTaskSnapshotIncludesByteAccountingDetails() throws {
        let snapshot = BackgroundDownloadManager.makeTaskSnapshot(
            jobID: "job-raw",
            artifactID: "main",
            destination: URL(fileURLWithPath: "/tmp/model.gguf"),
            resumeOffset: 4_000,
            bytesReceived: 2_000,
            taskExpected: 6_000,
            recordedExpected: 10_000,
            hasLiveTask: true,
            lastChunkBytes: 512,
            httpStatusCode: 206
        )

        let accounting = try XCTUnwrap(snapshot.byteAccounting)
        XCTAssertEqual(accounting.lastChunkBytes, 512)
        XCTAssertEqual(accounting.taskBytesWritten, 2_000)
        XCTAssertEqual(accounting.taskExpectedBytes, 6_000)
        XCTAssertEqual(accounting.resumeOffset, 4_000)
        XCTAssertEqual(accounting.recordedExpectedBytes, 10_000)
        XCTAssertEqual(accounting.httpStatusCode, 206)
        XCTAssertEqual(accounting.normalizedWrittenTotal, 6_000)
        XCTAssertEqual(accounting.normalizedFullExpected, 10_000)
        XCTAssertEqual(accounting.normalizationMode, .resumeRemainingBytes)
    }

    func testTaskSnapshotPreservesRecordedExpectedWhenResumeTaskReportsRemainingBytes() {
        let snapshot = BackgroundDownloadManager.makeTaskSnapshot(
            jobID: "job-2",
            artifactID: "artifact-2",
            destination: URL(fileURLWithPath: "/tmp/model-part.gguf"),
            resumeOffset: 4_000,
            bytesReceived: 1_000,
            taskExpected: 6_000,
            recordedExpected: 10_000,
            hasLiveTask: true
        )

        XCTAssertEqual(snapshot.writtenTotal, 5_000)
        XCTAssertEqual(snapshot.fullExpected, 10_000)
        XCTAssertEqual(snapshot.taskExpectedBytes, 6_000)
        XCTAssertEqual(snapshot.recordedExpectedBytes, 10_000)
    }

    func testNormalizeProgressUsesTaskExpectedForFreshDownloads() {
        let result = BackgroundDownloadManager.normalizeProgressTotals(
            resumeOffset: 0,
            totalBytesWritten: 256,
            taskExpected: 1024,
            recordedExpected: 2048
        )

        XCTAssertEqual(result.writtenTotal, 256)
        XCTAssertEqual(result.fullExpected, 1024)
        XCTAssertEqual(result.mode, .freshTask)
    }

    func testNormalizeProgressTreatsApproximateResumeExpectedAsFullSize() {
        let result = BackgroundDownloadManager.normalizeProgressTotals(
            resumeOffset: 4_000,
            totalBytesWritten: 2_000,
            taskExpected: 10_050,
            recordedExpected: 10_000
        )

        XCTAssertEqual(result.writtenTotal, 6_000)
        XCTAssertEqual(result.fullExpected, 10_000)
        XCTAssertEqual(result.mode, .resumeFullSize)
    }

    func testNormalizeProgressTreatsSmallerResumeExpectedAsRemainingBytes() {
        let result = BackgroundDownloadManager.normalizeProgressTotals(
            resumeOffset: 4_000,
            totalBytesWritten: 2_000,
            taskExpected: 6_000,
            recordedExpected: 10_000
        )

        XCTAssertEqual(result.writtenTotal, 6_000)
        XCTAssertEqual(result.fullExpected, 10_000)
        XCTAssertEqual(result.mode, .resumeRemainingBytes)
    }

    func testNormalizeProgressFallsBackToLargestReasonableResumeTotal() {
        let result = BackgroundDownloadManager.normalizeProgressTotals(
            resumeOffset: 4_000,
            totalBytesWritten: 2_000,
            taskExpected: 8_500,
            recordedExpected: 10_000
        )

        XCTAssertEqual(result.writtenTotal, 6_000)
        XCTAssertEqual(result.fullExpected, 12_500)
        XCTAssertEqual(result.mode, .resumeFallback)
    }

    func testNormalizeProgressUsesRecordedExpectedWhenResumeOnlyHasPersistedSize() {
        let result = BackgroundDownloadManager.normalizeProgressTotals(
            resumeOffset: 4_000,
            totalBytesWritten: 2_000,
            taskExpected: nil,
            recordedExpected: 10_000
        )

        XCTAssertEqual(result.writtenTotal, 6_000)
        XCTAssertEqual(result.fullExpected, 10_000)
        XCTAssertEqual(result.mode, .resumeRecordedOnly)
    }

    func testServerRejectionErrorRoundTripsStatusCode() {
        let error = BackgroundDownloadManager.serverRejectionError(statusCode: 403)
        XCTAssertEqual(BackgroundDownloadManager.httpRejectionStatus(from: error), 403)
        XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
        XCTAssertEqual((error as NSError).code, NSURLErrorBadServerResponse)
    }

    func testHttpRejectionStatusIgnoresErrorsWithoutStatusInfo() {
        XCTAssertNil(BackgroundDownloadManager.httpRejectionStatus(from: URLError(.cancelled)))
        XCTAssertNil(BackgroundDownloadManager.httpRejectionStatus(from: URLError(.badServerResponse)))
        XCTAssertNil(BackgroundDownloadManager.httpRejectionStatus(from: URLError(.networkConnectionLost)))
    }

    func testNormalizeProgressDoesNotAddOffsetForAbsoluteCountingResumeTasks() {
        // Resume-data tasks report didWriteData totals that already include the resumed
        // bytes; the caller must therefore pass resumeOffset == 0 (absolute counting).
        // Passing the resume point as an additive offset double-counts: paused at 4_000
        // of 10_000, the first resumed tick (totalBytesWritten ≈ 4_100) would report
        // 8_100 instead of 4_100 and the visible progress freezes near the ceiling.
        let result = BackgroundDownloadManager.normalizeProgressTotals(
            resumeOffset: 0,
            totalBytesWritten: 4_100,
            taskExpected: 10_000,
            recordedExpected: 10_000
        )

        XCTAssertEqual(result.writtenTotal, 4_100)
        XCTAssertEqual(result.fullExpected, 10_000)
        XCTAssertEqual(result.mode, .freshTask)
    }

    func testNormalizeProgressSaturatesMalformedOverflowingTotals() {
        let result = BackgroundDownloadManager.normalizeProgressTotals(
            resumeOffset: Int64.max,
            totalBytesWritten: Int64.max,
            taskExpected: Int64.max,
            recordedExpected: Int64.max
        )

        XCTAssertEqual(result.writtenTotal, Int64.max)
        XCTAssertEqual(result.fullExpected, Int64.max)
        XCTAssertEqual(result.mode, .resumeFullSize)
    }

    func testDownloadArtifactDecodesLegacyDestinationIntoStagingAndFinalURLs() throws {
        let legacyDestination = URL(fileURLWithPath: "/tmp/model.gguf.download")
        let payload: [String: Any] = [
            "id": "artifact-legacy",
            "role": "mainWeights",
            "remoteURL": "https://example.com/model.gguf",
            "destinationURL": legacyDestination.absoluteString,
            "expectedBytes": 10_000,
            "downloadedBytes": 4_000,
            "state": "paused",
            "retryCount": 1,
            "manualPause": true
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let artifact = try JSONDecoder().decode(DownloadArtifact.self, from: data)

        XCTAssertEqual(artifact.stagingURL, legacyDestination)
        XCTAssertEqual(artifact.finalURL, legacyDestination.deletingPathExtension())
        XCTAssertEqual(artifact.destinationURL, legacyDestination)
        XCTAssertEqual(artifact.state, .paused)
        XCTAssertTrue(artifact.manualPause)
    }

    func testDownloadJobTotalsSaturateInsteadOfOverflowing() {
        let finalURL = URL(fileURLWithPath: "/tmp/model.gguf")
        let artifacts = ["a", "b"].map { id in
            DownloadArtifact(
                id: id,
                role: .mainWeights,
                remoteURL: nil,
                stagingURL: finalURL.appendingPathExtension("download"),
                finalURL: finalURL,
                expectedBytes: Int64.max,
                downloadedBytes: Int64.max,
                checksum: nil,
                state: .downloading,
                retryCount: 0,
                nextRetryAt: nil,
                lastErrorDescription: nil,
                manualPause: false
            )
        }
        let job = DownloadJob(
            id: "overflow",
            owner: .embedding(EmbeddingDownloadOwner(repoID: "test/overflow")),
            state: .downloading,
            artifacts: artifacts,
            createdAt: Date(),
            updatedAt: Date(),
            lastErrorDescription: nil,
            manualPause: false
        )

        XCTAssertEqual(job.totalExpectedBytes, Int64.max)
        XCTAssertEqual(job.totalDownloadedBytes, Int64.max)
        XCTAssertEqual(job.progress, 1)
    }
}
