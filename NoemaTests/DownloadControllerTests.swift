import XCTest
@testable import Noema

final class DownloadControllerTests: XCTestCase {
    func testStagingURLAppendsDownloadExtension() {
        let finalURL = URL(fileURLWithPath: "/tmp/model.gguf")

        XCTAssertEqual(
            DownloadController.stagingURL(for: finalURL),
            URL(fileURLWithPath: "/tmp/model.gguf.download")
        )
    }

    func testAutoResumeIsBlockedWhenLiveTaskExists() {
        XCTAssertTrue(
            DownloadController.shouldBlockAutoResume(
                hasInMemoryTask: false,
                hasLiveTask: true
            )
        )
        XCTAssertTrue(
            DownloadController.shouldBlockAutoResume(
                hasInMemoryTask: true,
                hasLiveTask: false
            )
        )
        XCTAssertFalse(
            DownloadController.shouldBlockAutoResume(
                hasInMemoryTask: false,
                hasLiveTask: false
            )
        )
    }

    func testAggregateModelProgressUsesInMemoryArtifactBytes() {
        let progress = DownloadController.aggregateModelProgress(
            mainWritten: 4_000,
            mainExpected: 8_000,
            projectorWritten: 500,
            projectorExpected: 1_000,
            imatrixWritten: 250,
            imatrixExpected: 1_000
        )

        XCTAssertEqual(progress, 4_750.0 / 10_000.0, accuracy: 0.0001)
    }

    func testManualPauseWinsWhenLiveSnapshotIsPresent() {
        XCTAssertEqual(
            DownloadController.stateAfterLiveSnapshot(
                current: .failed,
                manualPause: true
            ),
            .paused
        )
    }

    func testScheduledStateWinsOverManualPausePresentation() {
        XCTAssertEqual(
            DownloadController.stateAfterLiveSnapshot(
                current: .scheduled,
                manualPause: true
            ),
            .scheduled
        )
    }

    func testScheduledDownloadStateIsResumableButNotAutoResumable() {
        let job = DownloadJob(
            id: "scheduled-job",
            owner: .embedding(EmbeddingDownloadOwner(repoID: "example/embedding")),
            state: .scheduled,
            artifacts: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastErrorDescription: nil,
            manualPause: true
        )

        XCTAssertTrue(job.canResume)
        XCTAssertFalse(job.canPause)
        XCTAssertFalse(DownloadJobState.scheduled.autoResumeEligible)
        XCTAssertEqual(DownloadJobState.scheduled.statusLabelKey, "Download Status Scheduled")
    }

    func testScheduledDownloadsResumeOnlyOvernightOnWiFiWhileCharging() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let eligible = DownloadSchedulePolicy.Environment(
            date: date(hour: 23, calendar: calendar),
            calendar: calendar,
            isCharging: true,
            isOnWiFi: true
        )
        XCTAssertTrue(DownloadController.shouldResumeScheduledDownloads(environment: eligible))

        let morningWindow = DownloadSchedulePolicy.Environment(
            date: date(hour: 6, calendar: calendar),
            calendar: calendar,
            isCharging: true,
            isOnWiFi: true
        )
        XCTAssertTrue(DownloadController.shouldResumeScheduledDownloads(environment: morningWindow))

        let daytime = DownloadSchedulePolicy.Environment(
            date: date(hour: 12, calendar: calendar),
            calendar: calendar,
            isCharging: true,
            isOnWiFi: true
        )
        XCTAssertFalse(DownloadController.shouldResumeScheduledDownloads(environment: daytime))

        let unplugged = DownloadSchedulePolicy.Environment(
            date: date(hour: 23, calendar: calendar),
            calendar: calendar,
            isCharging: false,
            isOnWiFi: true
        )
        XCTAssertFalse(DownloadController.shouldResumeScheduledDownloads(environment: unplugged))

        let cellular = DownloadSchedulePolicy.Environment(
            date: date(hour: 23, calendar: calendar),
            calendar: calendar,
            isCharging: true,
            isOnWiFi: false
        )
        XCTAssertFalse(DownloadController.shouldResumeScheduledDownloads(environment: cellular))
    }

    func testLiveSnapshotPromotesRecoverableStatesToDownloading() {
        XCTAssertEqual(
            DownloadController.stateAfterLiveSnapshot(
                current: .queued,
                manualPause: false
            ),
            .downloading
        )
        XCTAssertEqual(
            DownloadController.stateAfterLiveSnapshot(
                current: .preparing,
                manualPause: false
            ),
            .downloading
        )
        XCTAssertEqual(
            DownloadController.stateAfterLiveSnapshot(
                current: .failed,
                manualPause: false
            ),
            .downloading
        )
        XCTAssertEqual(
            DownloadController.stateAfterLiveSnapshot(
                current: .verifying,
                manualPause: false
            ),
            .verifying
        )
    }

    private func date(hour: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 6
        components.day = 7
        components.hour = hour
        return components.date!
    }

    func testSupportModelStateMappingPreservesPausedAndFailedDownloads() {
        XCTAssertEqual(
            SupportModelInventory.supportState(downloadState: .paused, installed: false),
            .paused
        )
        XCTAssertEqual(
            SupportModelInventory.supportState(downloadState: .scheduled, installed: false),
            .paused
        )
        XCTAssertEqual(
            SupportModelInventory.supportState(downloadState: .failed, installed: false),
            .failed
        )
        XCTAssertEqual(
            SupportModelInventory.supportState(downloadState: .downloading, installed: false),
            .downloading
        )
    }

    func testCompletedWhisperDownloadStillRequiresValidInstall() {
        XCTAssertEqual(
            SupportModelInventory.supportState(downloadState: .completed, installState: .incomplete),
            .incomplete
        )
        XCTAssertEqual(
            SupportModelInventory.supportState(downloadState: .completed, installState: .ready),
            .ready
        )
    }

    func testWhisperKitProgressEstimateUsesObservedPackageBytes() throws {
        XCTAssertNil(WhisperModelDownloadStore.estimatedProgress(observedBytes: 0, expectedBytes: 80_000_000))
        XCTAssertEqual(
            try XCTUnwrap(WhisperModelDownloadStore.estimatedProgress(observedBytes: 4_000_000, expectedBytes: 80_000_000)),
            0.05,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(WhisperModelDownloadStore.estimatedProgress(observedBytes: 40_000_000, expectedBytes: 80_000_000)),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(WhisperModelDownloadStore.estimatedProgress(observedBytes: 90_000_000, expectedBytes: 80_000_000)),
            0.97,
            accuracy: 0.0001
        )
    }

    @MainActor
    func testCancelIncompleteJobRemovesCompletedAndStagedArtifacts() async throws {
        let controller = DownloadController()
        let externalID = "noema-tests-cancel-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaCancelTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            Task { await DownloadEngine.shared.removeJob(externalID: externalID) }
            _ = controller
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let completedFinal = root.appendingPathComponent("part-a.gguf")
        let stagedFinal = root.appendingPathComponent("part-b.gguf")
        let stagedPartial = URL(fileURLWithPath: stagedFinal.path + ".download")
        try Data("done".utf8).write(to: completedFinal)
        try Data("partial".utf8).write(to: stagedPartial)

        let artifacts = [
            makeDownloadArtifact(id: "a", finalURL: completedFinal, state: .completed),
            makeDownloadArtifact(id: "b", finalURL: stagedFinal, state: .downloading)
        ]
        _ = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: artifacts,
            state: .downloading
        )

        controller.cancel(itemID: externalID)
        try await waitForCondition {
            await DownloadEngine.shared.job(forExternalID: externalID) == nil
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: completedFinal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPartial.path))
    }

    @MainActor
    func testCancelCompletedJobKeepsInstalledFinalArtifact() async throws {
        let controller = DownloadController()
        let externalID = "noema-tests-completed-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaCompletedCancelTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            Task { await DownloadEngine.shared.removeJob(externalID: externalID) }
            _ = controller
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let finalURL = root.appendingPathComponent("model.gguf")
        try Data("installed".utf8).write(to: finalURL)
        let artifact = makeDownloadArtifact(id: "main", finalURL: finalURL, state: .completed)
        _ = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: [artifact],
            state: .completed
        )

        controller.cancel(itemID: externalID)
        try await waitForCondition {
            await DownloadEngine.shared.job(forExternalID: externalID) == nil
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    }

    @MainActor
    func testDownloadMaintenanceRemovesUnreferencedModelStagingFiles() async throws {
        try await removeAllDownloadJobs()
        let controller = DownloadController()
        let modelID = "noema/tests/orphan-staging-\(UUID().uuidString)"
        let baseDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
        let stagingURL = baseDir.appendingPathComponent("model.gguf.download")
        defer {
            try? FileManager.default.removeItem(at: baseDir)
        }

        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stagingURL)

        let result = await controller.runDownloadMaintenance(manual: true, force: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertGreaterThanOrEqual(result.removedOrphanFiles, 1)
    }

    @MainActor
    func testDownloadMaintenancePreservesReferencedModelStagingFiles() async throws {
        try await removeAllDownloadJobs()
        let controller = DownloadController()
        let modelID = "noema/tests/referenced-staging-\(UUID().uuidString)"
        let externalID = "\(modelID)-Q4_K_M"
        let baseDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
        let finalURL = baseDir.appendingPathComponent("model.gguf")
        let stagingURL = DownloadController.stagingURL(for: finalURL)
        let quant = QuantInfo(
            label: "Q4_K_M",
            format: .gguf,
            sizeBytes: 7,
            downloadURL: URL(string: "https://example.com/model.gguf")!,
            sha256: nil,
            configURL: nil
        )
        let detail = ModelDetails(
            id: modelID,
            summary: "Referenced staging test",
            quants: [quant],
            promptTemplate: nil
        )
        let artifact = DownloadArtifact(
            id: "main",
            role: .mainWeights,
            remoteURL: quant.downloadURL,
            stagingURL: stagingURL,
            finalURL: finalURL,
            expectedBytes: 7,
            downloadedBytes: 0,
            checksum: nil,
            state: .downloading,
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorDescription: nil,
            manualPause: false
        )
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            Task { await DownloadEngine.shared.removeJob(externalID: externalID) }
        }

        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stagingURL)
        _ = await DownloadEngine.shared.upsertJob(
            owner: .model(ModelDownloadOwner(detail: detail, quant: quant)),
            artifacts: [artifact],
            state: .downloading
        )

        let result = await controller.runDownloadMaintenance(manual: true, force: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(result.removedOrphanFiles, 0)
        await DownloadEngine.shared.removeJob(externalID: externalID)
    }

    @MainActor
    func testMultipartCMLSnapshotShowsVisibleProgressAndOverlay() async throws {
        let jobs = await DownloadEngine.shared.snapshots()
        for job in jobs {
            await DownloadEngine.shared.removeJob(externalID: job.externalID)
        }

        let controller = DownloadController()
        let modelID = "noema/tests/cml-\(UUID().uuidString)"
        let externalID = "\(modelID)-CML"
        let partA = QuantInfo.DownloadPart(
            path: "bundle/model.mlmodelc/weights.bin",
            sizeBytes: 8_192,
            sha256: nil,
            downloadURL: URL(string: "https://example.com/bundle/model.mlmodelc/weights.bin")!
        )
        let partB = QuantInfo.DownloadPart(
            path: "bundle/tokenizer/vocab.json",
            sizeBytes: 4_096,
            sha256: nil,
            downloadURL: URL(string: "https://example.com/bundle/tokenizer/vocab.json")!
        )
        let quant = QuantInfo(
            label: "CML",
            format: .ane,
            sizeBytes: 12_288,
            downloadURL: partA.downloadURL,
            sha256: nil,
            configURL: nil,
            downloadParts: [partA, partB]
        )
        let detail = ModelDetails(
            id: modelID,
            summary: "Multipart CML test",
            quants: [quant],
            promptTemplate: nil
        )
        let baseDir = InstalledModelsStore.baseDir(for: .ane, modelID: modelID)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let artifacts = quant.allRelativeDownloadPaths.map { relativePath in
            let finalURL = baseDir.appendingPathComponent(relativePath)
            return DownloadArtifact(
                id: "shard:\(relativePath)",
                role: .weightShard,
                remoteURL: nil,
                stagingURL: DownloadController.stagingURL(for: finalURL),
                finalURL: finalURL,
                expectedBytes: relativePath.contains("weights") ? 8_192 : 4_096,
                downloadedBytes: 0,
                checksum: nil,
                state: .preparing,
                retryCount: 0,
                nextRetryAt: nil,
                lastErrorDescription: nil,
                manualPause: false
            )
        }

        _ = await DownloadEngine.shared.upsertJob(
            owner: .model(ModelDownloadOwner(detail: detail, quant: quant)),
            artifacts: artifacts,
            state: .preparing
        )
        await DownloadEngine.shared.updateArtifactProgress(
            externalID: externalID,
            artifactID: artifacts[0].id,
            written: 4_096,
            expected: 8_192
        )
        var item: DownloadController.Item?
        for _ in 0..<20 {
            item = controller.items.first(where: { $0.id == externalID })
            if (item?.progress ?? 0) > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let unwrappedItem = try XCTUnwrap(item)
        XCTAssertEqual(unwrappedItem.status, .downloading)
        XCTAssertGreaterThan(unwrappedItem.progress, 0)
        XCTAssertGreaterThan(controller.overallProgress, 0)
        XCTAssertTrue(controller.showOverlay)

        await DownloadEngine.shared.removeJob(externalID: externalID)
    }

    func testCancelledJobIgnoresLateStateUpdatesUntilRemoved() async throws {
        let externalID = "noema-tests-cancel-race-\(UUID().uuidString)"
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(externalID).bin")
        defer { Task { await DownloadEngine.shared.removeJob(externalID: externalID) } }

        _ = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: [makeDownloadArtifact(id: "main", finalURL: finalURL, state: .downloading)],
            state: .downloading
        )
        await DownloadEngine.shared.markCancelled(externalID: externalID)

        // Simulate the torn-down transfer surfacing NSURLErrorCancelled as a manual pause.
        await DownloadEngine.shared.updateJobState(externalID: externalID, state: .paused, manualPause: true)
        await DownloadEngine.shared.updateArtifactState(
            externalID: externalID,
            artifactID: "main",
            state: .paused,
            manualPause: true
        )
        await DownloadEngine.shared.updateArtifactProgress(
            externalID: externalID,
            artifactID: "main",
            written: 6,
            expected: 10
        )

        let jobSnapshot = await DownloadEngine.shared.job(forExternalID: externalID)
        let job = try XCTUnwrap(jobSnapshot)
        XCTAssertEqual(job.state, .cancelled)
        let autoResumable = await DownloadEngine.shared.autoResumableJobs()
        XCTAssertTrue(autoResumable.allSatisfy { $0.externalID != externalID })

        await DownloadEngine.shared.removeJob(externalID: externalID)
        let removed = await DownloadEngine.shared.job(forExternalID: externalID)
        XCTAssertNil(removed)
    }

    func testManuallyPausedJobIgnoresTrailingProgressBytes() async throws {
        let externalID = "noema-tests-pause-race-\(UUID().uuidString)"
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(externalID).bin")
        defer { Task { await DownloadEngine.shared.removeJob(externalID: externalID) } }

        _ = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: [makeDownloadArtifact(id: "main", finalURL: finalURL, state: .downloading)],
            state: .downloading
        )
        await DownloadEngine.shared.updateJobState(externalID: externalID, state: .paused, manualPause: true)

        // Bytes from the transfer that is still settling must be recorded without
        // flipping the job back to .downloading (which made pause "not stick").
        await DownloadEngine.shared.updateArtifactProgress(
            externalID: externalID,
            artifactID: "main",
            written: 8,
            expected: 10
        )

        let jobSnapshot = await DownloadEngine.shared.job(forExternalID: externalID)
        let job = try XCTUnwrap(jobSnapshot)
        XCTAssertEqual(job.state, .paused)
        XCTAssertTrue(job.manualPause)
        XCTAssertEqual(job.totalDownloadedBytes, 8)
        let autoResumable = await DownloadEngine.shared.autoResumableJobs()
        XCTAssertTrue(autoResumable.allSatisfy { $0.externalID != externalID })

        await DownloadEngine.shared.removeJob(externalID: externalID)
    }

    func testScheduledJobSurvivesLateArtifactPause() async throws {
        let externalID = "noema-tests-schedule-race-\(UUID().uuidString)"
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(externalID).bin")
        defer { Task { await DownloadEngine.shared.removeJob(externalID: externalID) } }

        _ = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: [makeDownloadArtifact(id: "main", finalURL: finalURL, state: .downloading)],
            state: .downloading
        )
        await DownloadEngine.shared.updateJobState(externalID: externalID, state: .scheduled, manualPause: true)

        // Scheduling cancels the live transfer; the resulting pause event must not
        // downgrade the job back to .paused.
        await DownloadEngine.shared.updateArtifactState(
            externalID: externalID,
            artifactID: "main",
            state: .paused,
            manualPause: true
        )

        let jobSnapshot = await DownloadEngine.shared.job(forExternalID: externalID)
        let job = try XCTUnwrap(jobSnapshot)
        XCTAssertEqual(job.state, .scheduled)

        await DownloadEngine.shared.removeJob(externalID: externalID)
    }

    @MainActor
    func testStopDoesNotResurrectRowFromLateEngineEvents() async throws {
        let controller = DownloadController()
        let externalID = "noema-tests-stop-resurrect-\(UUID().uuidString)"
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(externalID).bin")
        defer {
            try? FileManager.default.removeItem(at: finalURL)
            Task { await DownloadEngine.shared.removeJob(externalID: externalID) }
            _ = controller
        }

        _ = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: [makeDownloadArtifact(id: "main", finalURL: finalURL, state: .downloading)],
            state: .downloading
        )

        controller.cancel(itemID: externalID)
        // Race a late pause event against the asynchronous teardown.
        await DownloadEngine.shared.updateJobState(externalID: externalID, state: .paused, manualPause: true)

        try await waitForCondition {
            await DownloadEngine.shared.job(forExternalID: externalID) == nil
        }
        // Allow any pending engine-change refreshes to land.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(controller.embeddingItems.contains(where: { $0.id == externalID }))
    }

    func testResetArtifactProgressLowersMonotonicByteCountAfterRestart() async throws {
        let externalID = "noema-tests-restart-reset-\(UUID().uuidString)"
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(externalID).bin")
        defer { Task { await DownloadEngine.shared.removeJob(externalID: externalID) } }

        let job = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: [makeDownloadArtifact(id: "main", finalURL: finalURL, state: .downloading)],
            state: .downloading
        )
        await DownloadEngine.shared.updateArtifactProgress(
            externalID: externalID,
            artifactID: "main",
            written: 8,
            expected: 10
        )

        // The server rejected/ignored a resume and restarted the transfer from byte zero.
        // Progress updates are monotonic, so without an explicit reset the stale 8 bytes
        // freeze the visible progress until the new transfer catches up.
        await DownloadEngine.shared.resetArtifactProgress(jobID: job.id, artifactID: "main")

        var maybeSnapshot = await DownloadEngine.shared.job(forExternalID: externalID)
        var snapshot = try XCTUnwrap(maybeSnapshot)
        XCTAssertEqual(snapshot.totalDownloadedBytes, 0)

        await DownloadEngine.shared.updateArtifactProgress(
            externalID: externalID,
            artifactID: "main",
            written: 3,
            expected: 10
        )
        maybeSnapshot = await DownloadEngine.shared.job(forExternalID: externalID)
        snapshot = try XCTUnwrap(maybeSnapshot)
        XCTAssertEqual(snapshot.totalDownloadedBytes, 3)

        await DownloadEngine.shared.removeJob(externalID: externalID)
    }

    func testResetArtifactProgressLeavesCompletedArtifactsAlone() async throws {
        let externalID = "noema-tests-restart-completed-\(UUID().uuidString)"
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(externalID).bin")
        defer { Task { await DownloadEngine.shared.removeJob(externalID: externalID) } }

        let job = await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(repoID: externalID)),
            artifacts: [makeDownloadArtifact(id: "main", finalURL: finalURL, state: .completed)],
            state: .completed
        )

        await DownloadEngine.shared.resetArtifactProgress(jobID: job.id, artifactID: "main")

        let maybeSnapshot = await DownloadEngine.shared.job(forExternalID: externalID)
        let snapshot = try XCTUnwrap(maybeSnapshot)
        XCTAssertEqual(snapshot.totalDownloadedBytes, 10)

        await DownloadEngine.shared.removeJob(externalID: externalID)
    }

    private func makeDownloadArtifact(id: String, finalURL: URL, state: DownloadArtifactState) -> DownloadArtifact {
        DownloadArtifact(
            id: id,
            role: .mainWeights,
            remoteURL: URL(string: "https://example.com/\(id)")!,
            stagingURL: DownloadController.stagingURL(for: finalURL),
            finalURL: finalURL,
            expectedBytes: 10,
            downloadedBytes: state == .completed ? 10 : 4,
            checksum: nil,
            state: state,
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorDescription: nil,
            manualPause: false
        )
    }

    private func waitForCondition(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<40 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Condition was not met before timeout")
    }

    private func removeAllDownloadJobs() async throws {
        let jobs = await DownloadEngine.shared.snapshots()
        for job in jobs {
            await DownloadEngine.shared.removeJob(externalID: job.externalID)
        }
    }
}
