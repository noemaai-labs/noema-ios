// DownloadController.swift
#if canImport(UIKit) || os(macOS)
import Foundation
import SwiftUI
import Combine
import Network
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class DownloadController: ObservableObject {
	// Smoothing constant for download speed (EMA). Lower = steadier.
    private let speedEMAAlpha: Double = 0.30
	// Consider speeds stale if no update arrives within this window
	private let speedStaleAfter: TimeInterval = 1.25
	// Clamp unrealistically large instantaneous spikes (in B/s)
    // Upper bound for instantaneous samples to avoid UI spikes; set high enough to not mask real speeds
    private let maxInstantaneousSpeed: Double = 512 * 1024 * 1024 // ~512 MB/s

    // Track last time we updated a speed sample per item category
    private var lastModelSpeedSampleAt: [String: Date] = [:]
    private var lastLeapSpeedSampleAt: [String: Date] = [:]
    private var lastDatasetSpeedSampleAt: [String: Date] = [:]
    private var speedCoastTask: Task<Void, Never>? = nil
    // Per-main-model speed sampling state (computed from fraction * expected)
    private var lastMainSpeedSampleAt: [String: Date] = [:]
    private var lastMainBytesSample: [String: Int64] = [:]
    // Per-mmproj speed sampling state (computed from delegate byte deltas)
    private var lastMMProjSpeedSampleAt: [String: Date] = [:]
    private var lastMMProjBytesSample: [String: Int64] = [:]
    // Per-iMatrix speed sampling state (computed from delegate byte deltas)
    private var lastIMatrixSpeedSampleAt: [String: Date] = [:]
    private var lastIMatrixBytesSample: [String: Int64] = [:]
    // Track the last expected size we surfaced per download kind to avoid log spam
    private var loggedMainExpected: [String: Int64] = [:]
    private var loggedMMProjExpected: [String: Int64] = [:]
    private var loggedIMatrixExpected: [String: Int64] = [:]
    private var loggedDatasetExpected: [String: Int64] = [:]
    private var loggedLeapExpected: [String: Int64] = [:]
    private var loggedEmbedExpected: [String: Int64] = [:]
    // Throttle expensive disk probing in refreshCombinedProgress to avoid main-thread I/O jank
    private var lastDiskProbeAt: [String: Date] = [:]
    private let diskProbeInterval: TimeInterval = 2.0

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()
	struct Item: Identifiable, Equatable {
        var jobID: String? = nil
		let detail: ModelDetails
		let quant: QuantInfo
        var status: DownloadJobState = .queued
        var canPause: Bool = true
        var canResume: Bool = false
        var progress: Double = 0
        var speed: Double = 0
        // Track per-transfer instantaneous speeds (EMA-smoothed)
        var mainSpeed: Double = 0
        var mmprojSpeed: Double = 0
        var imatrixSpeed: Double = 0
		var completed = false
		var error: DownloadError? = nil
		var retryCount: Int = 0
		// Track per-part progress for combined progress computation
        var mainProgress: Double = 0
        var mmprojProgress: Double = 0
        var imatrixProgress: Double = 0
        var mmprojSize: Int64 = 0
        var imatrixSize: Int64 = 0
        // Remember projector filename so on-disk size probes can find the right file after completion.
        var mmprojFilename: String? = nil
        // Relative path of the iMatrix companion under the model directory.
        var imatrixPath: String? = nil
        // Absolute byte accounting for more accurate combined progress
        var mainExpectedBytes: Int64 = 0
        var mainBytesWritten: Int64 = 0
        var mmprojBytesWritten: Int64 = 0
        var imatrixBytesWritten: Int64 = 0
		// Destination of an in-flight mmproj background download (if any); used to pause/cancel correctly
		var mmprojDestination: URL? = nil
        // Destination of an in-flight iMatrix background download (if any); used to pause/cancel correctly
        var imatrixDestination: URL? = nil

		var id: String { "\(detail.id)-\(quant.label)" }

		var isRetryable: Bool {
			error?.isRetryable == true
		}
	}

	enum DownloadError: Equatable {
		case networkError(String)
		case permanentError(String)

		var isRetryable: Bool {
			switch self {
			case .networkError: return true
			case .permanentError: return false
			}
		}

		var localizedDescription: String {
			switch self {
			case .networkError(let message): return message
			case .permanentError(let message): return message
			}
		}
	}

	struct LeapItem: Identifiable, Equatable {
        var jobID: String? = nil
		let entry: LeapCatalogEntry
        var status: DownloadJobState = .queued
        var canPause: Bool = true
        var canResume: Bool = false
		var progress: Double = 0
		var speed: Double = 0
		/// Expected total bytes for this ET bundle. Filled when download starts or on first progress event.
		var expectedBytes: Int64 = 0
		var completed = false
		var verifying = false
		/// Number of consecutive retries for backoff
		var retryCount: Int = 0

		var id: String { entry.slug }
	}

        struct DatasetItem: Identifiable, Equatable {
                var jobID: String? = nil
                let detail: DatasetDetails
                var status: DownloadJobState = .queued
                var canPause: Bool = true
                var canResume: Bool = false
                var progress: Double = 0
                var speed: Double = 0
                /// Expected total bytes for this dataset download (if known)
                var expectedBytes: Int64 = 0
                /// Bytes downloaded so far for this dataset
                var downloadedBytes: Int64 = 0
                var completed = false
                var error: DownloadError? = nil

                var id: String { detail.id }
        }

	struct EmbeddingItem: Identifiable, Equatable {
        var jobID: String? = nil
        let recordID: String
		let repoID: String
        let displayName: String
        var status: DownloadJobState = .queued
        var canPause: Bool = true
        var canResume: Bool = false
		var progress: Double = 0
		var speed: Double = 0
		var completed = false
		var error: DownloadError? = nil
        /// Expected total bytes for this embedding model download (if known)
        var expectedBytes: Int64 = 0

        init(record: EmbeddingModelRecord) {
            self.recordID = record.id
            self.repoID = record.primaryArtifact?.repoID ?? record.id
            self.displayName = record.displayName
            self.expectedBytes = record.primaryArtifact?.sizeBytes ?? 0
        }

        init(repoID: String) {
            let record = EmbeddingModelCatalog.record(matchingDownloadIdentifier: repoID)
            self.recordID = record?.id ?? repoID
            self.repoID = record?.primaryArtifact?.repoID ?? repoID
            self.displayName = record?.displayName ?? repoID
            self.expectedBytes = record?.primaryArtifact?.sizeBytes ?? 0
        }

		var id: String { recordID }
	}

    struct WhisperItem: Identifiable, Equatable {
        var jobID: String? = nil
        let recordID: String
        let runtime: WhisperRuntimeFormat
        let displayName: String
        let repoID: String
        var status: DownloadJobState = .queued
        var canPause: Bool = true
        var canResume: Bool = false
        var progress: Double = 0
        var speed: Double = 0
        var completed = false
        var error: DownloadError? = nil
        var expectedBytes: Int64 = 0
        var downloadedBytes: Int64 = 0

        init(record: WhisperModelRecord, runtime: WhisperRuntimeFormat) {
            self.recordID = record.id
            self.runtime = runtime
            self.displayName = record.displayName
            let artifact = record.artifact(for: runtime)
            self.repoID = artifact?.repoID ?? record.id
            self.expectedBytes = artifact?.sizeBytes ?? 0
        }

        var id: String {
            DownloadController.whisperExternalID(recordID: recordID, runtime: runtime)
        }
    }

    struct MaintenanceResult: Sendable {
        var removedOrphanFiles = 0
        var removedResumeData = 0
        var removedJobs = 0
        var repairedArtifacts = 0
        var repairedCompletions = 0
    }

	/// Active downloads keyed by "<modelID>-<quantLabel>"
	///
	/// These arrays are mutated on every progress tick (up to 10 Hz per artifact).
	/// They are intentionally NOT @Published: each @Published mutation fires
	/// objectWillChange immediately, which re-evaluates every view observing this
	/// controller (MainView, ExploreView, StoredView, overlay, popup) and makes the
	/// whole UI lag during downloads. Instead, didSet funnels into a coalesced
	/// publish that emits at most once per `publishInterval`.
	private(set) var items: [Item] = [] { didSet { scheduleCoalescedPublish() } }
	private(set) var leapItems: [LeapItem] = [] { didSet { scheduleCoalescedPublish() } }
	private(set) var datasetItems: [DatasetItem] = [] { didSet { scheduleCoalescedPublish() } }
	private(set) var embeddingItems: [EmbeddingItem] = [] { didSet { scheduleCoalescedPublish() } }
    private(set) var whisperItems: [WhisperItem] = [] { didSet { scheduleCoalescedPublish() } }

    // Replacements for the synthesized $items / $leapItems publishers; they emit the
    // current value on subscribe and then at the coalesced cadence.
    private let itemsSubject = CurrentValueSubject<[Item], Never>([])
    private let leapItemsSubject = CurrentValueSubject<[LeapItem], Never>([])
    var itemsPublisher: AnyPublisher<[Item], Never> { itemsSubject.eraseToAnyPublisher() }
    var leapItemsPublisher: AnyPublisher<[LeapItem], Never> { leapItemsSubject.eraseToAnyPublisher() }

    private var publishScheduled = false
    private var lastPublishAt: Date = .distantPast
    private let publishInterval: TimeInterval = 0.2

    private func scheduleCoalescedPublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        let delay = max(0, publishInterval - Date().timeIntervalSince(lastPublishAt))
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            self.publishScheduled = false
            self.lastPublishAt = Date()
            self.objectWillChange.send()
            self.itemsSubject.send(self.items)
            self.leapItemsSubject.send(self.leapItems)
        }
    }
	@Published var showOverlay = false
	@Published var showPopup = false
	/// When set, ExploreView should present the associated details
	@Published var navigateToDetail: ModelDetails?

	private let manager = ModelDownloadManager()
	private var tasks: [String: Task<Void, Never>] = [:]
	// Track pause state per download id
	@Published private(set) var paused: Set<String> = []
	// Tombstones for downloads the user stopped. Engine snapshots refresh the UI and the
	// auto-resume/scheduler paths restart jobs asynchronously; without this guard a job that
	// is still being torn down resurrects its row (or the whole download) right after Stop.
	private var cancelledExternalIDs: Set<String> = []
	// User pause intent, recorded synchronously at tap time. Unlike `paused`, this set is
	// never rebuilt from engine snapshots, so it stays authoritative while the async pause
	// writes are still in flight. Download tasks check it at phase boundaries so a pause
	// pressed during the preparing phase actually stops the work instead of letting the
	// next transfer start and erase the pause.
	private var pauseRequestedIDs: Set<String> = []
	// Resume intent recorded when Resume is tapped while the previous pause is still tearing
	// down (the old wrapper task is still registered, so start() can't run yet). The late
	// pause/cancel event from the dying transfer consumes this and restarts the download
	// instead of settling the row back to paused/failed.
	private var resumePendingIDs: Set<String> = []
	// Explicit module qualification avoids ambiguity with similarly named types
#if os(macOS) && !canImport(UIKit)
	private weak var modelManager: AnyObject?
#else
	private weak var modelManager: AppModelManager?
#endif
	private weak var datasetManager: DatasetManager?
    private var engineObservers: [NSObjectProtocol] = []
    private let scheduleNetworkQueue = DispatchQueue(label: "download.schedule.network")
    private var schedulePathMonitor: NWPathMonitor?
    private var scheduleNetworkPath: NWPath?
    private var hasBootstrappedDownloads = false
    private var lastAutomaticMaintenanceAt: Date? = nil
    private let automaticMaintenanceInterval: TimeInterval = 30

	init() {
		// Periodically zero speeds that have gone stale (e.g., pause, network stall)
        speedCoastTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let now = Date()
            		// Models – batch mutations to avoid separate @Published emissions per property
            		for i in items.indices {
            			let id = items[i].id
            			if let t = lastModelSpeedSampleAt[id], now.timeIntervalSince(t) > speedStaleAfter || paused.contains(id) {
                            var item = items[i]
                            item.speed = 0
                            item.mainSpeed = 0
                            item.mmprojSpeed = 0
                            item.imatrixSpeed = 0
                            items[i] = item
            			}
            		}
					// Leaps
					for i in leapItems.indices {
						let id = leapItems[i].id
						if let t = lastLeapSpeedSampleAt[id], now.timeIntervalSince(t) > speedStaleAfter {
							leapItems[i].speed = 0
						}
					}
					// Datasets
            		for i in datasetItems.indices {
            			let id = datasetItems[i].id
            			if let t = lastDatasetSpeedSampleAt[id], now.timeIntervalSince(t) > speedStaleAfter {
            				datasetItems[i].speed = 0
            			}
            		}
                    for i in whisperItems.indices {
                        let id = whisperItems[i].id
                        if let t = lastDatasetSpeedSampleAt[id], now.timeIntervalSince(t) > speedStaleAfter {
                            whisperItems[i].speed = 0
                        }
                    }
                    // If a download reached 100% but never fired .finished (e.g., delegate lost),
                    // finalize it when the on-disk files are present.
                    autoFinalizeCompletedOnDisk()
                }
            }
        }

		// Observe background download completion notifications so we can
		// finalize installs even if the original async continuation was lost.
        NotificationCenter.default.addObserver(forName: .backgroundDownloadCompleted, object: nil, queue: .main) { [weak self] note in
            let destinationURL = note.userInfo?["destinationURL"] as? URL
            let jobID = note.userInfo?["jobID"] as? String
            let artifactID = note.userInfo?["artifactID"] as? String
            let errorMessage = (note.userInfo?["error"] as? Error).map { ($0 as NSError).localizedDescription }
            Task { @MainActor [weak self] in
                await self?.applyBackgroundNotificationToEngine(
                    destinationURL: destinationURL,
                    jobID: jobID,
                    artifactID: artifactID,
                    errorMessage: errorMessage
                )
                await self?.handleBackgroundDownloadCompletion(destinationURL: destinationURL, errorMessage: errorMessage)
                if errorMessage == nil, let destinationURL {
                    await BackgroundJobNotificationService.scheduleDownloadCompleted(destinationURL: destinationURL)
                }
                await self?.reconcileLiveBackgroundSnapshots()
                await self?.resumeRecoverableJobsFromEngine()
            }
        }

        engineObservers.append(NotificationCenter.default.addObserver(forName: .downloadEngineDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshFromEngineSnapshot()
            }
        })
        // A transfer restarted from byte zero (server rejected/ignored a resume). Engine
        // byte counts are monotonic, so reset the artifact explicitly — otherwise the
        // visible progress freezes at the stale value while the new transfer catches up.
        engineObservers.append(NotificationCenter.default.addObserver(forName: .backgroundDownloadRestarted, object: nil, queue: .main) { [weak self] note in
            let jobID = note.userInfo?["jobID"] as? String
            let artifactID = note.userInfo?["artifactID"] as? String
            let destinationURL = note.userInfo?["destinationURL"] as? URL
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let jobID, let artifactID {
                    await DownloadEngine.shared.resetArtifactProgress(jobID: jobID, artifactID: artifactID)
                } else if let destinationURL,
                          let job = await DownloadEngine.shared.job(matching: destinationURL),
                          let artifact = job.artifacts.first(where: {
                              $0.stagingURL.path == destinationURL.path || $0.finalURL.path == destinationURL.path
                          }) {
                    await DownloadEngine.shared.resetArtifactProgress(jobID: job.id, artifactID: artifact.id)
                }
                await self.refreshFromEngineSnapshot()
            }
        })
        engineObservers.append(NotificationCenter.default.addObserver(forName: .downloadMaintenanceRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.runDownloadMaintenance(manual: false, force: true)
                await self?.reconcileLiveBackgroundSnapshots()
                await self?.resumeScheduledJobsFromEngine()
                await self?.resumeRecoverableJobsFromEngine()
            }
        })
#if canImport(UIKit) && !os(visionOS)
        engineObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.runDownloadMaintenance(manual: false)
                await self?.reconcileLiveBackgroundSnapshots()
                await self?.resumeScheduledJobsFromEngine()
                self?.updateWakeLock()
            }
        })
        engineObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            ForegroundDownloadWakeLock.shared.release()
        })
#endif
        startScheduleConditionMonitoring()
    }

    private func hasGGUFMagic(at url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let magic = (try? fh.read(upToCount: 4)) ?? Data()
        return magic == Data("GGUF".utf8)
    }

    private func updateArtifactsJSON(in dir: URL, _ mutate: (inout [String: Any]) -> Void) {
        let artifactsURL = dir.appendingPathComponent("artifacts.json")
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: artifactsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        mutate(&obj)
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? out.write(to: artifactsURL)
        }
    }

    private func preflightFail(_ error: Error, itemID: String) {
        let nsError = error as NSError
        let isIntentionalPause = nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
            && (paused.contains(itemID) || pauseRequestedIDs.contains(itemID))

        let mapped = categorizeError(error)
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].imatrixDestination = nil
            items[idx].error = isIntentionalPause ? nil : mapped
            items[idx].speed = 0
            items[idx].mainSpeed = 0
            items[idx].mmprojSpeed = 0
            items[idx].imatrixSpeed = 0
            if isIntentionalPause || mapped.isRetryable {
                paused.insert(itemID)
            } else {
                paused.remove(itemID)
            }
        }
        tasks[itemID] = nil
        Task {
            if isIntentionalPause || mapped.isRetryable {
                await self.setAllArtifacts(externalID: itemID, state: .paused, manualPause: isIntentionalPause)
                await DownloadEngine.shared.updateJobState(externalID: itemID, state: .paused, manualPause: isIntentionalPause)
            } else {
                await self.setAllArtifacts(externalID: itemID, state: .failed, manualPause: false, errorMessage: mapped.localizedDescription)
                await DownloadEngine.shared.updateJobState(
                    externalID: itemID,
                    state: .failed,
                    manualPause: false,
                    errorMessage: mapped.localizedDescription
                )
            }
        }
    }

    private func prepareImportanceMatrixIfNeeded(itemID: String, jobID: String?, quant: QuantInfo, llmDir: URL) async throws {
        guard quant.format == .gguf, let imatrix = quant.importanceMatrix else { return }
        let relPath = imatrix.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relPath.isEmpty else { return }

        let dest = llmDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].imatrixPath = relPath
            items[idx].imatrixSize = max(items[idx].imatrixSize, imatrix.sizeBytes)
            if imatrix.sizeBytes > 0, loggedIMatrixExpected[itemID] != imatrix.sizeBytes {
                loggedIMatrixExpected[itemID] = imatrix.sizeBytes
                logDetectedSize(kind: "iMatrix", id: itemID, bytes: imatrix.sizeBytes, source: "catalog")
            }
        }
        updateArtifactsJSON(in: llmDir) { obj in
            obj["imatrixChecked"] = true
            obj["imatrixRequired"] = true
            if obj["imatrix"] == nil { obj["imatrix"] = NSNull() }
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path), !hasGGUFMagic(at: dest) {
            try? fm.removeItem(at: dest)
        }

        if fm.fileExists(atPath: dest.path) {
            let onDiskBytes = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? max(imatrix.sizeBytes, 0)
            if let idx = items.firstIndex(where: { $0.id == itemID }) {
                items[idx].imatrixProgress = 1
                items[idx].imatrixSize = max(items[idx].imatrixSize, onDiskBytes)
                items[idx].imatrixBytesWritten = max(items[idx].imatrixBytesWritten, onDiskBytes)
                items[idx].imatrixDestination = nil
                items[idx].imatrixSpeed = 0
                refreshCombinedProgress(at: idx)
            }
            updateArtifactsJSON(in: llmDir) { obj in
                obj["imatrix"] = relPath
                obj["imatrixChecked"] = true
                obj["imatrixRequired"] = true
            }
            return
        }

        var req = URLRequest(url: imatrix.downloadURL)
        if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")

        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].imatrixProgress = 0
            items[idx].imatrixDestination = dest
        }

        var lastProgressTickAt: Date = .distantPast
        var lastProgressReported: Double = 0

        await DownloadEngine.shared.updateArtifactState(
            externalID: itemID,
            artifactID: DurableArtifactID.importanceMatrix,
            state: .downloading,
            manualPause: false
        )

        do {
            try await BackgroundDownloadManager.shared.download(
                request: req,
                to: dest,
                jobID: jobID,
                artifactID: DurableArtifactID.importanceMatrix,
                expectedSize: (imatrix.sizeBytes > 0 ? imatrix.sizeBytes : nil),
                progress: { prog in
                    let now = Date()
                    let clamped = min(prog, 0.999)
                    let shouldTick = now.timeIntervalSince(lastProgressTickAt) >= 0.10 || (clamped - lastProgressReported) >= 0.01
                    guard shouldTick else { return }
                    lastProgressTickAt = now
                    lastProgressReported = clamped
                    Task { @MainActor in
                        guard let idx = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                        var item = self.items[idx]
                        item.imatrixProgress = clamped
                        item.imatrixDestination = dest
                        let totalExpected = max(Int64(1), item.mainExpectedBytes + item.mmprojSize + item.imatrixSize)
                        let doneBytes = item.mainBytesWritten + item.mmprojBytesWritten + item.imatrixBytesWritten
                        item.progress = Double(doneBytes) / Double(totalExpected)
                        self.items[idx] = item
                    }
                },
                progressBytes: { written, expected in
                    Task {
                        await DownloadEngine.shared.updateArtifactProgressLive(
                            externalID: itemID,
                            artifactID: DurableArtifactID.importanceMatrix,
                            written: written,
                            expected: expected > 0 ? expected : imatrix.sizeBytes
                        )
                    }
                    Task { @MainActor in
                        guard let idx = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                        var item = self.items[idx]

                        item.imatrixBytesWritten = written
                        if expected > 0 {
                            let previous = item.imatrixSize
                            item.imatrixSize = expected
                            if self.loggedIMatrixExpected[itemID] != expected || previous != expected {
                                self.loggedIMatrixExpected[itemID] = expected
                                self.logDetectedSize(kind: "iMatrix", id: itemID, bytes: expected, source: "Content-Length")
                            }
                        }
                        let effectiveExpected = max(item.imatrixSize, expected, written, 1)
                        item.imatrixProgress = min(0.999, Double(written) / Double(effectiveExpected))
                        item.imatrixDestination = dest
                        let now = Date()
                        let totalExpected = max(Int64(1), item.mainExpectedBytes + item.mmprojSize + item.imatrixSize)
                        let doneBytes = item.mainBytesWritten + item.mmprojBytesWritten + item.imatrixBytesWritten
                        item.progress = Double(doneBytes) / Double(totalExpected)

                        let lastTime = self.lastIMatrixSpeedSampleAt[itemID]
                        let lastBytesVal = self.lastIMatrixBytesSample[itemID]
                        if lastTime == nil || lastBytesVal == nil {
                            self.lastIMatrixSpeedSampleAt[itemID] = now
                            self.lastIMatrixBytesSample[itemID] = written
                            self.items[idx] = item
                            return
                        }

                        let dt = now.timeIntervalSince(lastTime!)
                        if dt >= 0.25 {
                            let bytesDelta = written - lastBytesVal!
                            let rawSpeed = dt > 0 ? Double(bytesDelta) / dt : 0.0
                            let instSpeed = max(0, min(rawSpeed, self.maxInstantaneousSpeed))

                            self.lastIMatrixSpeedSampleAt[itemID] = now
                            self.lastIMatrixBytesSample[itemID] = written

                            let alpha = self.speedEMAAlpha
                            let prev = item.imatrixSpeed
                            let newSpeed = (prev > 0) ? (1 - alpha) * prev + alpha * instSpeed : instSpeed
                            item.imatrixSpeed = newSpeed
                            item.speed = min(self.maxInstantaneousSpeed, item.mainSpeed + item.mmprojSpeed + item.imatrixSpeed)
                            self.lastModelSpeedSampleAt[itemID] = now
                        }

                        self.items[idx] = item
                    }
                }
            )
        } catch {
            let nsError = error as NSError
            let pausedByUser = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled && paused.contains(itemID)
            await DownloadEngine.shared.updateArtifactState(
                externalID: itemID,
                artifactID: DurableArtifactID.importanceMatrix,
                state: pausedByUser ? .paused : (categorizeError(error).isRetryable ? .retrying : .failed),
                errorMessage: pausedByUser ? nil : error.localizedDescription,
                manualPause: pausedByUser
            )
            throw error
        }

        guard hasGGUFMagic(at: dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw URLError(.cannotParseResponse)
        }

        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].imatrixProgress = 1
            items[idx].imatrixPath = relPath
            items[idx].imatrixBytesWritten = max(items[idx].imatrixBytesWritten, items[idx].imatrixSize)
            items[idx].imatrixDestination = nil
            items[idx].imatrixSpeed = 0
            items[idx].speed = min(maxInstantaneousSpeed, items[idx].mainSpeed + items[idx].mmprojSpeed + items[idx].imatrixSpeed)
            refreshCombinedProgress(at: idx)
        }

        updateArtifactsJSON(in: llmDir) { obj in
            obj["imatrix"] = relPath
            obj["imatrixChecked"] = true
            obj["imatrixRequired"] = true
        }
        let finalBytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? imatrix.sizeBytes
        await DownloadEngine.shared.markArtifactCompleted(
            externalID: itemID,
            artifactID: DurableArtifactID.importanceMatrix,
            finalBytes: finalBytes
        )
    }

    @MainActor
    private func handleBackgroundDownloadCompletion(destinationURL: URL?, errorMessage: String?) async {
        if let msg = errorMessage { print("[DownloadController] Background download failed: \(msg)"); return }
        guard let destinationURL else { return }
        let resolvedDestinationURL = await finalizeBackgroundArtifactIfNeeded(observedURL: destinationURL)

        // Try to reconcile main model weights completed via BackgroundDownloadManager.
        if let index = items.firstIndex(where: { item in
            let baseDir = InstalledModelsStore.baseDir(for: item.quant.format, modelID: item.detail.id)
            if item.quant.isMultipart {
                return item.quant.allRelativeDownloadPaths.contains { relPath in
                    let final = baseDir.appendingPathComponent(relPath)
                    let tmp = baseDir.appendingPathComponent(relPath + ".download")
                    return resolvedDestinationURL.path == final.path || resolvedDestinationURL.path == tmp.path
                }
            }
            let rel = item.quant.primaryDownloadRelativePath
            let tmpURL = baseDir.appendingPathComponent(rel + ".download")
            let finalURL = baseDir.appendingPathComponent(rel)
            return resolvedDestinationURL.path == tmpURL.path || resolvedDestinationURL.path == finalURL.path
        }) {
            if items[index].quant.isMultipart {
                refreshCombinedProgress(at: index)
                return
            }
            finalizeModelAfterBackgroundCompletion(itemIndex: index, tmpOrFinalURL: resolvedDestinationURL)
            return
        }

        // If an MTP companion finished, record it for future GGUF startup.
        if let index = items.firstIndex(where: {
            guard let mtp = $0.quant.mtp else { return false }
            let baseDir = InstalledModelsStore.baseDir(for: $0.quant.format, modelID: $0.detail.id)
            let rel = QuantInfo.relativeDownloadPath(path: mtp.path, fallbackURL: mtp.downloadURL)
            let finalPath = baseDir.appendingPathComponent(rel).path
            return finalPath == resolvedDestinationURL.path
        }) {
            if let mtp = items[index].quant.mtp {
                let baseDir = InstalledModelsStore.baseDir(for: items[index].quant.format, modelID: items[index].detail.id)
                let rel = QuantInfo.relativeDownloadPath(path: mtp.path, fallbackURL: mtp.downloadURL)
                updateArtifactsJSON(in: baseDir) { obj in
                    obj["mtp"] = rel
                    obj["mtpChecked"] = true
                }
            }
            return
        }

        // If an iMatrix companion finished, update its part progress.
        if let index = items.firstIndex(where: {
            let baseDir = InstalledModelsStore.baseDir(for: $0.quant.format, modelID: $0.detail.id)
            let finalPath = ($0.imatrixPath ?? $0.quant.importanceMatrix?.path).map { baseDir.appendingPathComponent($0).path }
            return $0.imatrixDestination?.path == resolvedDestinationURL.path || finalPath == resolvedDestinationURL.path
        }) {
            items[index].imatrixProgress = 1
            if items[index].imatrixPath == nil {
                items[index].imatrixPath = items[index].quant.importanceMatrix?.path
            }
            if let rel = items[index].imatrixPath {
                let baseDir = InstalledModelsStore.baseDir(for: items[index].quant.format, modelID: items[index].detail.id)
                updateArtifactsJSON(in: baseDir) { obj in
                    obj["imatrix"] = rel
                    obj["imatrixChecked"] = true
                    obj["imatrixRequired"] = true
                }
            }
            if items[index].imatrixBytesWritten == 0 {
                items[index].imatrixBytesWritten = max(items[index].imatrixBytesWritten, items[index].imatrixSize)
            }
            items[index].imatrixSpeed = 0
            items[index].imatrixDestination = nil
            items[index].speed = min(maxInstantaneousSpeed, items[index].mainSpeed + items[index].mmprojSpeed + items[index].imatrixSpeed)
            refreshCombinedProgress(at: index)
            return
        }

        // If an mmproj projector finished, update its part progress.
        if let index = items.firstIndex(where: {
            let baseDir = InstalledModelsStore.baseDir(for: $0.quant.format, modelID: $0.detail.id)
            let finalPath = $0.mmprojFilename.map { baseDir.appendingPathComponent($0).path }
            return $0.mmprojDestination?.path == resolvedDestinationURL.path || finalPath == resolvedDestinationURL.path
        }) {
            // Mark projector done and recompute aggregate progress.
            items[index].mmprojProgress = 1
            items[index].mmprojFilename = resolvedDestinationURL.lastPathComponent
            if items[index].mmprojBytesWritten == 0 { items[index].mmprojBytesWritten = max(items[index].mmprojBytesWritten, items[index].mmprojSize) }
            items[index].mmprojSpeed = 0
            items[index].mmprojDestination = nil
            items[index].speed = min(maxInstantaneousSpeed, items[index].mainSpeed + items[index].mmprojSpeed + items[index].imatrixSpeed)
            refreshCombinedProgress(at: index)
            return
        }

        // Dataset file finished — best-effort UI update if we still have a matching item.
        if let index = datasetItems.firstIndex(where: {
            let basePath = Self.datasetBaseDir(for: $0.id).standardizedFileURL.path
            let destPath = resolvedDestinationURL.standardizedFileURL.path
            return destPath == basePath || destPath.hasPrefix(basePath + "/")
        }) {
            guard !datasetItems[index].completed else { return }
            let removedID = datasetItems[index].id
            datasetItems[index].completed = true
            datasetItems[index].status = .completed
            datasetItems[index].canPause = false
            datasetItems[index].canResume = false
            datasetItems[index].progress = 1.0
            datasetItems[index].speed = 0
            Task {
                await DownloadEngine.shared.updateJobState(externalID: removedID, state: .completed, manualPause: false)
            }
            Haptics.success()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.datasetItems.removeAll { $0.id == removedID }
                if self.allItems.isEmpty { self.showOverlay = false }
            }
            scheduleJobRemoval(externalID: removedID, delay: 3)
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let job = await DownloadEngine.shared.job(matching: resolvedDestinationURL) else { return }
            switch job.owner {
            case .embedding(let owner):
                if let record = EmbeddingModelCatalog.record(matchingDownloadIdentifier: owner.externalID) ?? EmbeddingModelCatalog.record(matchingDownloadIdentifier: owner.repoID) {
                    UserDefaults.standard.set(true, forKey: "hasInstalledEmbedModel:\(record.installedURL.path)")
                    NotificationCenter.default.post(
                        name: .embeddingModelAvailabilityChanged,
                        object: nil,
                        userInfo: ["available": record.id == EmbeddingModelCatalog.activeRecord().id, "recordID": record.id]
                    )
                }
                if let idx = self.embeddingItems.firstIndex(where: { $0.id == owner.externalID || $0.repoID == owner.repoID }) {
                    self.embeddingItems[idx].status = .completed
                    self.embeddingItems[idx].canPause = false
                    self.embeddingItems[idx].canResume = false
                    self.embeddingItems[idx].progress = 1
                    self.embeddingItems[idx].completed = true
                }
                await DownloadEngine.shared.updateJobState(externalID: owner.externalID, state: .completed, manualPause: false)
                self.scheduleJobRemoval(externalID: owner.externalID, delay: 1.2)
            case .dataset(let owner):
                self.datasetManager?.handleDatasetDownloadCompleted(datasetID: owner.detail.id)
                await DownloadEngine.shared.updateJobState(externalID: owner.detail.id, state: .completed, manualPause: false)
                self.scheduleJobRemoval(externalID: owner.detail.id, delay: 3)
            case .leap(let owner):
                let modelURL: URL
                switch owner.entry.artifactKind {
                case .bundle:
                    modelURL = resolvedDestinationURL
                case .manifest:
                    let installDir = InstalledModelsStore.baseDir(for: .et, modelID: owner.entry.modelID)
                        .appendingPathComponent(owner.entry.slug, isDirectory: true)
                    if resolvedDestinationURL.pathExtension.lowercased() == "gguf" {
                        modelURL = resolvedDestinationURL
                    } else if let candidate = (try? FileManager.default.contentsOfDirectory(at: installDir, includingPropertiesForKeys: nil))?.first(where: {
                        let lower = $0.lastPathComponent.lowercased()
                        return lower.hasSuffix(".gguf") && !lower.contains("mmproj") && !lower.contains("projector")
                    }) {
                        modelURL = candidate
                    } else {
                        modelURL = resolvedDestinationURL
                    }
                }
                let installed = InstalledModel(
                    modelID: owner.entry.modelID,
                    quantLabel: owner.entry.quantization,
                    url: modelURL,
                    format: .et,
                    sizeBytes: (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? owner.entry.sizeBytes,
                    lastUsed: nil,
                    installDate: Date(),
                    checksum: owner.entry.sha256,
                    isFavourite: false,
                    totalLayers: 0,
                    isMultimodal: owner.entry.isVision,
                    isToolCapable: true,
                    moeInfo: nil
                )
#if os(macOS) && !canImport(UIKit)
                if let manager = self.modelManager as? AppModelManager {
                    manager.install(installed)
                }
#else
                self.modelManager?.install(installed)
#endif
                await DownloadEngine.shared.updateJobState(externalID: owner.entry.slug, state: .completed, manualPause: false)
                self.scheduleJobRemoval(externalID: owner.entry.slug, delay: 3)
            case .whisper(let owner):
                if let idx = self.whisperItems.firstIndex(where: { $0.id == owner.externalID }) {
                    self.whisperItems[idx].status = .completed
                    self.whisperItems[idx].canPause = false
                    self.whisperItems[idx].canResume = false
                    self.whisperItems[idx].progress = 1
                    self.whisperItems[idx].completed = true
                    self.whisperItems[idx].downloadedBytes = self.whisperItems[idx].expectedBytes
                    self.whisperItems[idx].speed = 0
                }
                await DownloadEngine.shared.updateJobState(externalID: owner.externalID, state: .completed, manualPause: false)
                self.scheduleJobRemoval(externalID: owner.externalID, delay: 1.2)
            case .model:
                break
            }
            await self.refreshFromEngineSnapshot()
        }
    }

    private func finalizeModelAfterBackgroundCompletion(itemIndex: Int, tmpOrFinalURL: URL) {
        var item = items[itemIndex]
        guard !item.completed else { return }
        // Compute canonical directories and destination names
        let dir = InstalledModelsStore.baseDir(for: item.quant.format, modelID: item.detail.id)
        let primaryRelativePath = item.quant.primaryDownloadRelativePath
        let finalURL = dir.appendingPathComponent(primaryRelativePath)
        // If the completed file is still under the temporary ".download" name, rename it now
        let fm = FileManager.default
        if tmpOrFinalURL.lastPathComponent.hasSuffix(".download") {
            try? fm.removeItemIfExists(at: finalURL)
            do { try fm.moveItem(at: tmpOrFinalURL, to: finalURL) } catch {
                print("[DownloadController] Failed to move completed file: \(error)")
            }
        }
        // Update artifacts.json to point at the weights for later recovery
        do {
            let artifactsURL = dir.appendingPathComponent("artifacts.json")
            var obj: [String: Any] = [:]
            if let data = try? Data(contentsOf: artifactsURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj = parsed
            }
            obj["weights"] = primaryRelativePath
            if item.quant.isMultipart {
                obj["weightShards"] = item.quant.allRelativeDownloadPaths
            } else {
                obj.removeValue(forKey: "weightShards")
            }
            if obj["mmproj"] == nil { obj["mmproj"] = NSNull() }
            if let mtp = item.quant.mtp {
                obj["mtp"] = QuantInfo.relativeDownloadPath(path: mtp.path, fallbackURL: mtp.downloadURL)
                obj["mtpChecked"] = true
            } else if obj["mtp"] == nil {
                obj["mtp"] = NSNull()
            }
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            try? out.write(to: artifactsURL)
        } catch {}

        // Mark UI state
        items[itemIndex].status = .completed
        items[itemIndex].canPause = false
        items[itemIndex].canResume = false
        items[itemIndex].completed = true
        items[itemIndex].progress = 1.0
        items[itemIndex].speed = 0
        items[itemIndex].error = nil
        Task {
            await DownloadEngine.shared.updateJobState(externalID: item.id, state: .completed, manualPause: false)
        }
        Haptics.success()

        let counts = byteCounts(for: items[itemIndex])
        let installedMainBytes = counts.mainWritten > 0 ? counts.mainWritten : item.quant.sizeBytes

        // Register minimal InstalledModel; deeper metadata (layers, capabilities) will be scanned later.
        let installed = InstalledModel(
            modelID: item.detail.id,
            quantLabel: item.quant.label,
            url: finalURL,
            format: item.quant.format,
            sizeBytes: installedMainBytes,
            lastUsed: nil,
            installDate: Date(),
            checksum: item.quant.sha256,
            isFavourite: false,
            totalLayers: 0
        )
#if os(macOS) && !canImport(UIKit)
        if let manager = self.modelManager as? AppModelManager { manager.install(installed) }
#else
        self.modelManager?.install(installed)
#endif
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.items.removeAll { $0.id == item.id }
            if self.allItems.isEmpty { self.showOverlay = false }
        }
        scheduleJobRemoval(externalID: item.id, delay: 3)
    }

#if os(macOS) && !canImport(UIKit)
    func configure(modelManager: AnyObject, datasetManager: DatasetManager) {
		self.modelManager = modelManager
		self.datasetManager = datasetManager
	}
#else
    func configure(modelManager: AppModelManager, datasetManager: DatasetManager) {
		self.modelManager = modelManager
		self.datasetManager = datasetManager
	}
#endif

    /// Returns the best-known byte counts for main weights and auxiliary GGUF sidecars, grounded in on-disk
    /// file sizes to avoid UI desync when delegate progress callbacks are delayed or missing.
    private func byteCounts(for item: Item) -> (mainWritten: Int64, mainExpected: Int64, mmWritten: Int64, mmExpected: Int64, imWritten: Int64, imExpected: Int64) {
        let fm = FileManager.default
        let baseDir = InstalledModelsStore.baseDir(for: item.quant.format, modelID: item.detail.id)
        // Main weights: multipart GGUF quants aggregate all shard temp/final files.
        var mainBytes = item.mainBytesWritten
        if item.quant.isMultipart {
            var sumWritten: Int64 = 0
            let partNames = item.quant.allRelativeDownloadPaths
            for relPath in partNames {
                let finalURL = baseDir.appendingPathComponent(relPath)
                let tmpURL = baseDir.appendingPathComponent(relPath + ".download")
                var partWritten: Int64 = 0
                if let attrs = try? fm.attributesOfItem(atPath: tmpURL.path),
                   let sz = attrs[.size] as? Int64 {
                    partWritten = max(partWritten, sz)
                }
                if let attrs = try? fm.attributesOfItem(atPath: finalURL.path),
                   let sz = attrs[.size] as? Int64 {
                    partWritten = max(partWritten, sz)
                }
                sumWritten += max(partWritten, 0)
            }
            if partNames.isEmpty == false {
                mainBytes = max(mainBytes, sumWritten)
            }
        } else {
            // Single-file main weights: prefer the temp ".download" file if present, else the final weights path.
            let relPath = item.quant.primaryDownloadRelativePath
            let mainTmp = baseDir.appendingPathComponent(relPath + ".download")
            if let attrs = try? fm.attributesOfItem(atPath: mainTmp.path),
               let sz = attrs[.size] as? Int64 {
                mainBytes = max(mainBytes, sz)
            } else {
                let mainFinal = baseDir.appendingPathComponent(relPath)
                if let attrs = try? fm.attributesOfItem(atPath: mainFinal.path),
                   let sz = attrs[.size] as? Int64 {
                    mainBytes = max(mainBytes, sz)
                }
            }
        }

        // Projector: check the in-flight destination first, then the final path.
        var mmBytes = item.mmprojBytesWritten
        let artifacts: [String: Any]? = {
            let artifactsURL = baseDir.appendingPathComponent("artifacts.json")
            if let data = try? Data(contentsOf: artifactsURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parsed
            }
            return nil
        }()
        let mmNameFromArtifacts: String? = {
            guard let name = artifacts?["mmproj"] as? String, !name.isEmpty, name != "<null>" else { return nil }
            return name
        }()
        let mmName = item.mmprojDestination?.lastPathComponent ?? item.mmprojFilename ?? mmNameFromArtifacts
        func probe(_ url: URL) {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let sz = attrs[.size] as? Int64 {
                mmBytes = max(mmBytes, sz)
            }
        }
        if let dest = item.mmprojDestination { probe(dest) }
        if let name = mmName {
            probe(baseDir.appendingPathComponent(name))
            probe(baseDir.appendingPathComponent(name + ".download"))
        }
        // Fallback: heuristic search for any mmproj-like file in the model directory
        if mmBytes == item.mmprojBytesWritten && mmBytes == 0 && item.mmprojSize > 0 {
            if let contents = try? fm.contentsOfDirectory(atPath: baseDir.path) {
                if let first = contents.first(where: { $0.localizedCaseInsensitiveContains("mmproj") || $0.localizedCaseInsensitiveContains("projector") }) {
                    probe(baseDir.appendingPathComponent(first))
                    probe(baseDir.appendingPathComponent(first + ".download"))
                }
            }
        }

        // iMatrix companion: check in-flight destination, tracked path, then artifacts.json hint.
        var imBytes = item.imatrixBytesWritten
        let imPathFromArtifacts: String? = {
            guard let p = artifacts?["imatrix"] as? String, !p.isEmpty, p != "<null>" else { return nil }
            return p
        }()
        let imPath = item.imatrixPath ?? imPathFromArtifacts
        func probeIMatrix(_ url: URL) {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let sz = attrs[.size] as? Int64 {
                imBytes = max(imBytes, sz)
            }
        }
        if let dest = item.imatrixDestination { probeIMatrix(dest) }
        if let rel = imPath {
            let final = baseDir.appendingPathComponent(rel)
            probeIMatrix(final)
            probeIMatrix(final.appendingPathExtension("download"))
        }
        // Fallback: look for imatrix files one level deep if we know one is expected.
        if imBytes == item.imatrixBytesWritten && imBytes == 0 && (item.imatrixSize > 0 || item.quant.requiresImportanceMatrix) {
            if let files = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) {
                for file in files {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
                        if let subfiles = try? fm.contentsOfDirectory(at: file, includingPropertiesForKeys: nil),
                           let match = subfiles.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains("imatrix") }) {
                            probeIMatrix(match)
                            probeIMatrix(match.appendingPathExtension("download"))
                            break
                        }
                    } else if file.lastPathComponent.localizedCaseInsensitiveContains("imatrix") {
                        probeIMatrix(file)
                        probeIMatrix(file.appendingPathExtension("download"))
                        break
                    }
                }
            }
        }

        // Expected totals should never be smaller than bytes already written.
        let mainExpected: Int64 = {
            if item.quant.isMultipart {
                let partsExpected = item.quant.allDownloadParts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }
                return max(item.mainExpectedBytes, partsExpected, mainBytes)
            }
            return max(item.mainExpectedBytes, mainBytes)
        }()
        let mmExpected = max(item.mmprojSize, mmBytes)
        let imExpected = max(item.imatrixSize, imBytes)

        return (mainBytes, mainExpected, mmBytes, mmExpected, imBytes, imExpected)
    }

    private func allMainShardFilesPresent(for item: Item) -> Bool {
        guard item.quant.isMultipart else { return true }
        let fm = FileManager.default
        let baseDir = InstalledModelsStore.baseDir(for: item.quant.format, modelID: item.detail.id)
        let names = item.quant.allRelativeDownloadPaths
        guard !names.isEmpty else { return false }
        return names.allSatisfy { name in
            let finalURL = baseDir.appendingPathComponent(name)
            return fm.fileExists(atPath: finalURL.path)
        }
    }

    /// Recompute combined progress for a given item index using absolute bytes.
    private func refreshCombinedProgress(at index: Int) {
        let counts = byteCounts(for: items[index])
        items[index].mainBytesWritten = counts.mainWritten
        items[index].mainExpectedBytes = counts.mainExpected
        items[index].mmprojBytesWritten = counts.mmWritten
        items[index].mmprojSize = counts.mmExpected // keep expected in sync if it grew via on-disk probe
        items[index].imatrixBytesWritten = counts.imWritten
        items[index].imatrixSize = counts.imExpected // keep expected in sync if it grew via on-disk probe

        let totalExpected = max(1, counts.mainExpected + counts.mmExpected + counts.imExpected)
        let doneBytes = counts.mainWritten + counts.mmWritten + counts.imWritten
        items[index].progress = Double(doneBytes) / Double(totalExpected)
    }

    /// Best-effort fallback: if the files exist on disk and progress is ~done but the stream
    /// never emitted `.finished`, finalize and install the model.
    private func autoFinalizeCompletedOnDisk() {
        guard !items.isEmpty else { return }
        let fm = FileManager.default
        for idx in items.indices {
            if items[idx].completed { continue }
            // Require near-complete progress to avoid hijacking active downloads.
            if items[idx].progress < 0.995 { continue }
            let baseDir = InstalledModelsStore.baseDir(for: items[idx].quant.format, modelID: items[idx].detail.id)
            let finalURL = baseDir.appendingPathComponent(items[idx].quant.primaryDownloadRelativePath)
            guard fm.fileExists(atPath: finalURL.path) else { continue }
            guard allMainShardFilesPresent(for: items[idx]) else { continue }

            let counts = byteCounts(for: items[idx])

            // If an iMatrix is required for this IQ quant, ensure the final companion exists.
            if items[idx].quant.requiresImportanceMatrix {
                let rel = items[idx].imatrixPath ?? items[idx].quant.importanceMatrix?.path
                let finalIMatrix = rel.map { baseDir.appendingPathComponent($0) }
                let imPresent = finalIMatrix.map { fm.fileExists(atPath: $0.path) && hasGGUFMagic(at: $0) } ?? false
                if !imPresent { continue }
            }

            // If a projector is expected, ensure it exists (or we at least have bytes for it).
            if items[idx].mmprojSize > 0 {
                let mmName = items[idx].mmprojFilename
                let mmURL = mmName != nil ? baseDir.appendingPathComponent(mmName!) : nil
                let mmPresent = (counts.mmWritten > 0) || (mmURL != nil && fm.fileExists(atPath: mmURL!.path))
                if !mmPresent { continue }
            }

            finalizeModelAfterBackgroundCompletion(itemIndex: idx, tmpOrFinalURL: finalURL)
        }
    }

	private func key(for detail: ModelDetails, quant: QuantInfo) -> String {
		"\(detail.id)-\(quant.label)"
	}

	func start(detail: ModelDetails, quant: QuantInfo) {
		let id = key(for: detail, quant: quant)
		if tasks[id] != nil { return }
		cancelledExternalIDs.remove(id)
		pauseRequestedIDs.remove(id)
		resumePendingIDs.remove(id)

		if !items.contains(where: { $0.id == id }) {
			var item = Item(detail: detail, quant: quant)
            item.status = .preparing
			items.append(item)
		}
		showOverlay = true

			let t = Task { [weak self] in
				guard let self else { return }
                // Curated CoreML entries may carry only a repo-root URL; resolve the full
                // artifact list (model containers + tokenizer sidecars) before creating the
                // job so the engine tracks every file. Label is preserved, so `id` is stable.
                let quant = await self.manager.resolveANEQuantIfNeeded(quant, modelID: detail.id)
                await MainActor.run {
                    if let idx = self.items.firstIndex(where: { $0.id == id }), self.items[idx].quant != quant {
                        var refreshed = Item(detail: detail, quant: quant)
                        refreshed.status = self.items[idx].status
                        self.items[idx] = refreshed
                    }
                }
                var job = await self.ensureModelJob(detail: detail, quant: quant)
                // Stop may have raced the upsert above and re-created the job after the
                // engine removed it; tear the zombie down instead of continuing.
                if Task.isCancelled {
                    if self.tasks[id] == nil {
                        await DownloadEngine.shared.removeJob(externalID: id)
                    }
                    return
                }
                if self.pauseRequestedIDs.contains(id) {
                    await self.holdModelTaskForPause(itemID: id)
                    return
                }
                await MainActor.run {
                    if let idx = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[idx].jobID = job.id
                        self.items[idx].status = .preparing
                        self.items[idx].canPause = true
                        self.items[idx].canResume = false
                    }
                }
				// Always check for an mmproj companion when downloading GGUF models.
				if quant.format == .gguf {
					let llmDir = InstalledModelsStore.baseDir(for: .gguf, modelID: detail.id)
					do {
						try FileManager.default.createDirectory(at: llmDir, withIntermediateDirectories: true)
						// Persist a repo hint to help re-home after relaunch/sandbox change
						let repoFile = llmDir.appendingPathComponent("repo.txt")
					if !FileManager.default.fileExists(atPath: repoFile.path) {
						try? detail.id.data(using: .utf8)?.write(to: repoFile)
					}
				} catch {
					await MainActor.run {
						if let idx = self.items.firstIndex(where: { $0.id == id }) {
							self.items[idx].error = .permanentError("Failed to create model directory")
						}
						self.tasks[id] = nil
					}
					return
					}
                    do {
                        try await self.prepareImportanceMatrixIfNeeded(itemID: id, jobID: job.id, quant: quant, llmDir: llmDir)
                    } catch {
                        await self.preflightFail(error, itemID: id)
                        return
                    }
					// Discover mmproj via HF API file list; search the quant's repo first, then fall back to the base repo
					var selected: (name: String, url: URL, size: Int64)? = nil
					var repoCandidates: [String] = []
                    if let quantRepo = self.huggingFaceRepoID(from: quant.downloadURL) {
					repoCandidates.append(quantRepo)
				}
					if !repoCandidates.contains(detail.id) {
						repoCandidates.append(detail.id)
					}
					let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
					for repo in repoCandidates {
						if let proj = await VisionModelDetector.projectorMetadata(repoId: repo, token: token) {
							let escapedRepo = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
							let url = URL(string: "https://huggingface.co/\(escapedRepo)/resolve/main/\(proj.filename)?download=1")!
							var size = proj.size
							if size <= 0 {
								let headSize = await self.fetchRemoteSize(url)
								if headSize > 0 { size = headSize }
							}
							selected = (proj.filename, url, size)
							break
						}
					}
                await MainActor.run {
                    if let idx = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[idx].mmprojSize = selected?.size ?? 0
                        self.items[idx].mmprojFilename = selected?.name
                        if let size = selected?.size, size > 0, self.loggedMMProjExpected[id] != size {
                            self.loggedMMProjExpected[id] = size
                            self.logDetectedSize(kind: "Projector", id: id, bytes: size, source: "catalog")
                        }
                    }
				}
				// Persist that we checked for mmproj
				do {
					let artifactsURL = llmDir.appendingPathComponent("artifacts.json")
					var obj: [String: Any] = [:]
					if let data = try? Data(contentsOf: artifactsURL),
					   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
						obj = parsed
					}
					obj["mmprojChecked"] = true
					// If not found, set explicit null for mmproj so UI can report absence
					if selected == nil {
						obj["mmproj"] = NSNull()
					}
					let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
					try? out.write(to: artifactsURL)
				} catch {}
                // If a projector file is offered, download it even if size is unknown (we'll learn expected via the task)
                if let sel = selected {
                    job = await self.ensureProjectorArtifact(
                        detail: detail,
                        quant: quant,
                        filename: sel.name,
                        remoteURL: sel.url,
                        expectedBytes: sel.size
                    )
                    if Task.isCancelled {
                        if self.tasks[id] == nil {
                            await DownloadEngine.shared.removeJob(externalID: id)
                        }
                        return
                    }
                    if self.pauseRequestedIDs.contains(id) {
                        await self.holdModelTaskForPause(itemID: id)
                        return
                    }
                    await MainActor.run {
                        if let idx = self.items.firstIndex(where: { $0.id == id }) {
                            self.items[idx].jobID = job.id
                        }
					}
					let mmprojFile = sel.name
					let mmprojURL = sel.url
					let mmprojFinalURL = llmDir.appendingPathComponent(mmprojFile)
                    let mmprojStageURL = Self.stagingURL(for: mmprojFinalURL)
					if !FileManager.default.fileExists(atPath: mmprojFinalURL.path) {
						do {
                            var req = URLRequest(url: mmprojURL)
                            // Pass auth if available
                            if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                            }
                            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                            req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
							print("[Downloader] ▶︎ Downloading \(mmprojFile)…")
                        // Background download to staging destination; compute smoothed progress / speed
                        // Throttle for visible progress ticks (bytes sampling handled via @MainActor properties)
                        var lastProgressTickAt: Date = .distantPast
                        var lastProgressReported: Double = 0
                        // Record destination immediately so cancel can remove partial file even before first progress tick
                        Task { @MainActor in
                            if let i = self.items.firstIndex(where: { $0.id == id }) {
                                self.items[i].mmprojDestination = mmprojStageURL
                            }
                        }
                        try await BackgroundDownloadManager.shared.download(
                            request: req,
                            to: mmprojStageURL,
                            jobID: job.id,
                            artifactID: DurableArtifactID.projector,
                            expectedSize: (sel.size > 0 ? sel.size : nil),
                            progress: { prog in
                                let now = Date()
                                let pmm = min(prog, 0.999)
                                // Throttle UI updates independent of speed sampling
                                let shouldTick = now.timeIntervalSince(lastProgressTickAt) >= 0.10 || (prog - lastProgressReported) >= 0.01
                                guard shouldTick else { return }
                                lastProgressTickAt = now
                                lastProgressReported = prog
                                Task { @MainActor in
                                    if let idx = self.items.firstIndex(where: { $0.id == id }) {
                                        var item = self.items[idx]
                                        item.mmprojProgress = pmm
                                        item.mmprojDestination = mmprojStageURL
                                        let totalExpected = max(Int64(1), item.mainExpectedBytes + item.mmprojSize + item.imatrixSize)
                                        let doneBytes = item.mainBytesWritten + item.mmprojBytesWritten + item.imatrixBytesWritten
                                        item.progress = Double(doneBytes) / Double(totalExpected)
                                        self.items[idx] = item
                                    }
                                }
                            },
                            progressBytes: { written, expected in
                                Task {
                                    await DownloadEngine.shared.updateArtifactProgressLive(
                                        externalID: id,
                                        artifactID: DurableArtifactID.projector,
                                        written: written,
                                        expected: expected > 0 ? expected : sel.size
                                    )
                                }
                                Task { @MainActor in
                                    guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                                    var item = self.items[idx]

                                    // 1) Progress using absolute bytes
                                    item.mmprojBytesWritten = written
                                    if expected > 0 {
                                        let previous = item.mmprojSize
                                        item.mmprojSize = expected
                                        if self.loggedMMProjExpected[id] != expected || previous != expected {
                                            self.loggedMMProjExpected[id] = expected
                                            self.logDetectedSize(kind: "Projector", id: id, bytes: expected, source: "Content-Length")
                                        }
                                    }
                                    let now = Date()
                                    let totalExpected = max(Int64(1), item.mainExpectedBytes + item.mmprojSize + item.imatrixSize)
                                    let doneBytes = item.mainBytesWritten + item.mmprojBytesWritten + item.imatrixBytesWritten
                                    item.progress = Double(doneBytes) / Double(totalExpected)

                                    // 2) Speed calculation using per-item samplers (EMA)
                                    let lastTime = self.lastMMProjSpeedSampleAt[id]
                                    let lastBytesVal = self.lastMMProjBytesSample[id]

                                    if lastTime == nil || lastBytesVal == nil {
                                        self.lastMMProjSpeedSampleAt[id] = now
                                        self.lastMMProjBytesSample[id] = written
                                        self.items[idx] = item
                                        return
                                    }

                                    let dt = now.timeIntervalSince(lastTime!)
                                    if dt >= 0.25 { // ~4 Hz
                                        let bytesDelta = written - lastBytesVal!
                                        let rawSpeed = dt > 0 ? Double(bytesDelta) / dt : 0.0
                                        let instSpeed = max(0, min(rawSpeed, self.maxInstantaneousSpeed))

                                        self.lastMMProjSpeedSampleAt[id] = now
                                        self.lastMMProjBytesSample[id] = written

                                        let alpha = self.speedEMAAlpha
                                        let prevSpeed = item.mmprojSpeed
                                        let newSpeed = (prevSpeed > 0) ? (1 - alpha) * prevSpeed + alpha * instSpeed : instSpeed
                                        item.mmprojSpeed = newSpeed
                                        item.speed = min(self.maxInstantaneousSpeed, item.mainSpeed + item.mmprojSpeed + item.imatrixSpeed)
                                        self.lastModelSpeedSampleAt[id] = now
                                    }

                                    self.items[idx] = item
                                }
                            }
                        )
                        try self.finalizeStagedDownload(from: mmprojStageURL, to: mmprojFinalURL)
                        // Validate GGUF magic to avoid saving HTML error pages
                        if let fh = try? FileHandle(forReadingFrom: mmprojFinalURL) {
                            defer { try? fh.close() }
                            let magic = try fh.read(upToCount: 4) ?? Data()
                            if magic != Data("GGUF".utf8) { throw URLError(.cannotParseResponse) }
                        }
                            let mmprojBytes = (try? FileManager.default.attributesOfItem(atPath: mmprojFinalURL.path)[.size] as? Int64) ?? sel.size
                            await DownloadEngine.shared.markArtifactCompleted(
                                externalID: id,
                                artifactID: DurableArtifactID.projector,
                                finalBytes: mmprojBytes
                            )
                            // Update artifacts.json with mmproj reference
                            do {
                                let artifactsURL = llmDir.appendingPathComponent("artifacts.json")
                                var obj: [String: Any] = [:]
                                if let data = try? Data(contentsOf: artifactsURL),
                                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                    obj = parsed
                                }
                                obj["mmproj"] = mmprojFinalURL.lastPathComponent
                                obj["mmprojChecked"] = true
                                let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
                                try? out.write(to: artifactsURL)
                            } catch {}
                            print("[Downloader] ✓ \(mmprojFile) downloaded successfully.")
                            await MainActor.run {
                                if let idx = self.items.firstIndex(where: { $0.id == id }) {
                                    self.items[idx].mmprojProgress = 1
                                    self.items[idx].mmprojFilename = mmprojFinalURL.lastPathComponent
                                    self.items[idx].mmprojBytesWritten = max(self.items[idx].mmprojBytesWritten, self.items[idx].mmprojSize)
                                    self.items[idx].mmprojDestination = nil
                                    self.items[idx].mmprojSpeed = 0
                                    // Recompute combined progress (main could still be 0 here) using absolute bytes
                                    self.refreshCombinedProgress(at: idx)
                                }
                            }
						} catch {
                            let nsError = error as NSError
                            let pausedByUser = nsError.domain == NSURLErrorDomain
                                && nsError.code == NSURLErrorCancelled
                                && (self.pauseRequestedIDs.contains(id) || self.paused.contains(id))
                            if pausedByUser {
                                await DownloadEngine.shared.updateArtifactState(
                                    externalID: id,
                                    artifactID: DurableArtifactID.projector,
                                    state: .paused,
                                    manualPause: true
                                )
                                await self.holdModelTaskForPause(itemID: id)
                                return
                            }
                            let mapped = self.categorizeError(error)
                            await DownloadEngine.shared.updateArtifactState(
                                externalID: id,
                                artifactID: DurableArtifactID.projector,
                                state: mapped.isRetryable ? .retrying : .failed,
                                errorMessage: error.localizedDescription,
                                manualPause: false
                            )
							// Best-effort: proceed without mmproj on failure
							print("[Downloader] ⚠︎ mmproj download failed: \(error.localizedDescription)")
						}
					} else {
                        let existingBytes = (try? FileManager.default.attributesOfItem(atPath: mmprojFinalURL.path)[.size] as? Int64) ?? sel.size
                        await DownloadEngine.shared.markArtifactCompleted(
                            externalID: id,
                            artifactID: DurableArtifactID.projector,
                            finalBytes: existingBytes
                        )
						// mmproj already present
						// Ensure artifacts.json reflects presence
                    do {
                        let artifactsURL = llmDir.appendingPathComponent("artifacts.json")
                        var obj: [String: Any] = [:]
                        if let data = try? Data(contentsOf: artifactsURL),
                           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            obj = parsed
                        }
                        obj["mmproj"] = mmprojFinalURL.lastPathComponent
                        obj["mmprojChecked"] = true
                        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
                        try? out.write(to: artifactsURL)
                    } catch {}
                    await MainActor.run {
                        if let idx = self.items.firstIndex(where: { $0.id == id }) {
                            self.items[idx].mmprojProgress = 1
                            // Treat an already-present projector as completed bytes so the combined
                            // progress denominator doesn’t make the main weights look “stuck”.
                            // Previously we set only the progress flag, leaving `mmprojBytesWritten`
                            // at zero, which understated overall progress by the projector size.
                            let existingBytes = self.items[idx].mmprojSize
                            if existingBytes > 0 {
                                self.items[idx].mmprojBytesWritten = existingBytes
                                self.items[idx].mmprojSpeed = 0
                                let mainExpected = (self.items[idx].mainExpectedBytes > 0)
                                    ? self.items[idx].mainExpectedBytes
                                    : self.items[idx].quant.sizeBytes
                                self.items[idx].mainExpectedBytes = mainExpected
                                self.items[idx].mmprojFilename = mmprojFinalURL.lastPathComponent
                                self.refreshCombinedProgress(at: idx)
                            }
                        }
                    }
                }
            }
        }
		// A pause or stop pressed during the preparing phase must not let the main
		// weights transfer start: it would run unowned and clear the pause state.
		if Task.isCancelled {
			if self.tasks[id] == nil {
				await DownloadEngine.shared.removeJob(externalID: id)
			}
			return
		}
		if self.pauseRequestedIDs.contains(id) {
			await self.holdModelTaskForPause(itemID: id)
			return
		}
		let stream = await manager.download(quant, for: detail.id, jobID: job.id)
		for await event in stream {
			await MainActor.run {
				guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
				switch event {
                        case .started(let expected):
                            if self.pauseRequestedIDs.contains(id) {
                                // A pause raced the transfer start; stop the fresh transfer
                                // instead of letting it erase the user's pause.
                                Task { await self.manager.pause(modelID: detail.id, quantLabel: quant.label) }
                            } else {
                                self.items[idx].status = .downloading
                                self.items[idx].canPause = true
                                self.items[idx].canResume = false
                                Task {
                                    await DownloadEngine.shared.updateJobState(externalID: id, state: .downloading, manualPause: false)
                                }
                            }
                            let detected = expected ?? 0
                            if detected > 0 {
                                let previous = self.items[idx].mainExpectedBytes
                                self.items[idx].mainExpectedBytes = detected
                                if self.loggedMainExpected[id] != detected || previous != detected {
                                    self.loggedMainExpected[id] = detected
                                    self.logDetectedSize(kind: "Model", id: id, bytes: detected, source: "metadata")
                                }
                            }
                        case .progress(let p, let bytesReported, let expectedFromSession, let managerSpeed):
                            // Don't let trailing progress from a transfer that is being torn
                            // down flip a pause-pending row back to "downloading".
                            if self.pauseRequestedIDs.contains(id) { return }
                            // Batch all mutations into a local copy to emit a single @Published update.
                            var item = self.items[idx]
                            item.status = .downloading
                            let pClamped = min(p, 0.999)
                            item.mainProgress = pClamped
                            let candidate: Int64 = {
                                if expectedFromSession > 0 { return expectedFromSession }
                                if item.mainExpectedBytes > 0 { return item.mainExpectedBytes }
                                return item.quant.sizeBytes
                            }()
                            let bytesSoFar = max(0, bytesReported)
                            let previousExpected = item.mainExpectedBytes
                            if candidate > 0 {
                                item.mainExpectedBytes = candidate
                                if self.loggedMainExpected[id] != candidate || previousExpected != candidate {
                                    self.loggedMainExpected[id] = candidate
                                    let source = expectedFromSession > 0 ? "Content-Length" : "metadata"
                                    self.logDetectedSize(kind: "Model", id: id, bytes: candidate, source: source)
                                }
                            }
                            let now = Date()
                            item.mainBytesWritten = max(bytesSoFar, item.mainBytesWritten)
                            // Use manager-reported instantaneous speed; EMA smooth and aggregate
                            let prev = item.mainSpeed
                            let alpha = self.speedEMAAlpha
                            let inst = max(0, min(managerSpeed, self.maxInstantaneousSpeed))
                            item.mainSpeed = prev > 0 ? (1 - alpha) * prev + alpha * inst : inst
                            item.speed = min(self.maxInstantaneousSpeed, item.mainSpeed + item.mmprojSpeed + item.imatrixSpeed)
                            self.lastModelSpeedSampleAt[item.id] = now
                            self.lastMainSpeedSampleAt[id] = now
                            self.lastMainBytesSample[id] = bytesSoFar
                            let totalExpected = max(Int64(1), item.mainExpectedBytes + item.mmprojSize + item.imatrixSize)
                            let doneBytes = item.mainBytesWritten + item.mmprojBytesWritten + item.imatrixBytesWritten
                            item.progress = Double(doneBytes) / Double(totalExpected)
                            // Single write-back: one @Published emission instead of ~13.
                            self.items[idx] = item
					case .finished(let installed):
						self.items[idx].mainProgress = 1
						self.items[idx].progress = 1
						self.items[idx].speed = 0
                        self.items[idx].status = .completed
                        self.items[idx].canPause = false
                        self.items[idx].canResume = false
						self.items[idx].completed = true
						self.items[idx].error = nil
                        Task {
                            await DownloadEngine.shared.updateJobState(externalID: id, state: .completed, manualPause: false)
                        }
                        Haptics.success()
#if os(macOS) && !canImport(UIKit)
						if let manager = self.modelManager as? AppModelManager {
							manager.install(installed)
						}
#else
						self.modelManager?.install(installed)
#endif
						// If a dataset was just downloaded via dataset flow, DatasetManager triggers indexing itself.
						self.tasks[id] = nil
						self.resumePendingIDs.remove(id)
						// Clear per-item main speed samplers
						self.lastMainSpeedSampleAt[id] = nil
						self.lastMainBytesSample[id] = nil
                        self.scheduleJobRemoval(externalID: id, delay: 3)
						Task { @MainActor in
							try? await Task.sleep(for: .seconds(3))
							self.items.removeAll { $0.id == id }
							if self.allItems.isEmpty {
								self.showOverlay = false
							}
						}
					case .cancelled:
						self.items.removeAll { $0.id == id }
						self.tasks[id] = nil
						self.resumePendingIDs.remove(id)
                        Task {
                            await DownloadEngine.shared.removeJob(externalID: id)
                        }
						// Clear main speed samplers for this id
						self.lastMainSpeedSampleAt[id] = nil
						self.lastMainBytesSample[id] = nil
						if self.allItems.isEmpty { self.showOverlay = false }
                                        case .paused(let p):
                                                // Resume was tapped while this pause was still settling;
                                                // restart now instead of flipping the row back to paused.
                                                if self.resumePendingIDs.remove(id) != nil,
                                                   !self.cancelledExternalIDs.contains(id),
                                                   !self.pauseRequestedIDs.contains(id) {
                                                        self.tasks[id] = nil
                                                        let item = self.items[idx]
                                                        Task {
                                                            await DownloadEngine.shared.updateJobState(externalID: id, state: .queued, manualPause: false)
                                                        }
                                                        self.start(detail: item.detail, quant: item.quant)
                                                        return
                                                }
                                                let pClamped = min(p, 0.999)
                                                self.items[idx].mainProgress = pClamped
                                                self.items[idx].speed = 0
                                                // Scheduling cancels the live transfer, which surfaces here as a
                                                // pause; don't let that downgrade a scheduled item back to paused.
                                                if self.items[idx].status != .scheduled {
                                                    self.items[idx].status = .paused
                                                    Task {
                                                        await DownloadEngine.shared.updateJobState(externalID: id, state: .paused, manualPause: true)
                                                    }
                                                }
                                                self.items[idx].canPause = false
                                                self.items[idx].canResume = true
                                                self.items[idx].error = nil
                                                self.paused.insert(id)
                                                // Recompute combined progress using absolute bytes
                                                self.refreshCombinedProgress(at: idx)
                                                // Clear task so resume can restart
                                                self.tasks[id] = nil
					case .failed(let error):
						self.items[idx].speed = 0
						self.tasks[id] = nil
						self.resumePendingIDs.remove(id)

						// Categorize error type
						let downloadError = self.categorizeError(error)
						self.items[idx].error = downloadError
                        self.items[idx].status = downloadError.isRetryable ? .retrying : .failed
                        self.items[idx].canPause = false
                        self.items[idx].canResume = downloadError.isRetryable
                        Task {
                            await DownloadEngine.shared.updateJobState(
                                externalID: id,
                                state: downloadError.isRetryable ? .retrying : .failed,
                                manualPause: false,
                                errorMessage: error.localizedDescription
                            )
                        }

						if downloadError.isRetryable {
							// Network errors are retryable - keep in paused state
							self.paused.insert(id)
						} else {
							// Permanent errors - remove after delay
							Task { @MainActor in
								try? await Task.sleep(for: .seconds(5))
								self.items.removeAll { $0.id == id }
								self.lastMainSpeedSampleAt[id] = nil
								self.lastMainBytesSample[id] = nil
								if self.allItems.isEmpty {
									self.showOverlay = false
								}
							}
						}
                                        case .networkError(let error, let progress):
                                                if self.pauseRequestedIDs.contains(id) {
                                                        // The user paused while the transfer was failing;
                                                        // settle as paused instead of scheduling a retry.
                                                        Task { await self.holdModelTaskForPause(itemID: id) }
                                                        return
                                                }
                                                let pClamped = min(progress, 0.999)
                                                self.items[idx].mainProgress = pClamped
                                                self.items[idx].speed = 0
                                                self.items[idx].status = .retrying
                                                self.items[idx].canPause = false
                                                self.items[idx].canResume = true
                                                self.items[idx].retryCount += 1
                                                let delay = min(pow(2.0, Double(self.items[idx].retryCount)), 60)
                                                Task {
                                                    await DownloadEngine.shared.updateJobState(
                                                        externalID: id,
                                                        state: .retrying,
                                                        manualPause: false,
                                                        errorMessage: error.localizedDescription
                                                    )
                                                }
                                                // Recompute combined progress from on-disk bytes (multipart-aware)
                                                self.refreshCombinedProgress(at: idx)
                                                // Clear current task to allow restart
                                                self.tasks[id] = nil
                                                // Backoff grows but caps at 60s
                                                Task { @MainActor in
                                                        try? await Task.sleep(for: .seconds(delay))
                                                        await self.waitForNetworkConnectivity()
                                                        if let item = self.items.first(where: { $0.id == id }),
                                                           !self.pauseRequestedIDs.contains(id) {
                                                                self.start(detail: item.detail, quant: item.quant)
                                                        }
                                                }
					default:
						break
					}
				}
			}
		}

		tasks[id] = t
	}

func pause(itemID: String) {
		pauseRequestedIDs.insert(itemID)
		resumePendingIDs.remove(itemID)
		paused.insert(itemID)
		if let item = items.first(where: { $0.id == itemID }) {
            if let idx = items.firstIndex(where: { $0.id == itemID }) {
                items[idx].status = .paused
                items[idx].canPause = false
                items[idx].canResume = true
            }
			Task {
                await manager.pause(modelID: item.detail.id, quantLabel: item.quant.label)
                if let dest = item.mmprojDestination {
                    await BackgroundDownloadManager.shared.pause(destination: dest)
                }
                if let dest = item.imatrixDestination {
                    await BackgroundDownloadManager.shared.pause(destination: dest)
                }
                // Also fan out over engine-tracked artifacts to catch transfers whose
                // in-memory destinations haven't been recorded on the item yet.
                if let job = await DownloadEngine.shared.job(forExternalID: itemID) {
                    for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
                        await BackgroundDownloadManager.shared.pause(destination: artifact.destinationURL)
                    }
                }
                await self.setAllArtifacts(externalID: itemID, state: .paused, manualPause: true)
                await DownloadEngine.shared.updateJobState(externalID: itemID, state: .paused, manualPause: true)
            }
            return
		}
        if let idx = leapItems.firstIndex(where: { $0.id == itemID }) {
            leapItems[idx].status = .paused
            leapItems[idx].canPause = false
            leapItems[idx].canResume = true
            LeapBundleDownloader.shared.pause(slug: itemID)
            tasks[itemID] = nil
            return
        }
        if let idx = datasetItems.firstIndex(where: { $0.id == itemID }) {
            datasetItems[idx].status = .paused
            datasetItems[idx].canPause = false
            datasetItems[idx].canResume = true
        }
        if let idx = embeddingItems.firstIndex(where: { $0.id == itemID }) {
            embeddingItems[idx].status = .paused
            embeddingItems[idx].canPause = false
            embeddingItems[idx].canResume = true
        }
        if let idx = whisperItems.firstIndex(where: { $0.id == itemID }) {
            whisperItems[idx].status = .paused
            whisperItems[idx].canPause = false
            whisperItems[idx].canResume = true
        }
        Task {
            guard let job = await DownloadEngine.shared.job(forExternalID: itemID) else { return }
            for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
                await BackgroundDownloadManager.shared.pause(destination: artifact.destinationURL)
            }
            await self.setAllArtifacts(externalID: itemID, state: .paused, manualPause: true)
            await DownloadEngine.shared.updateJobState(externalID: itemID, state: .paused, manualPause: true)
        }
}

    func schedule(itemID: String) {
        pauseRequestedIDs.insert(itemID)
        resumePendingIDs.remove(itemID)
        paused.insert(itemID)
        markVisibleItemScheduled(itemID)
        Task {
            await self.pauseLiveTransfersForScheduling(itemID: itemID)
            await self.setAllArtifacts(externalID: itemID, state: .paused, manualPause: true)
            await DownloadEngine.shared.updateJobState(externalID: itemID, state: .scheduled, manualPause: true)
            await BackgroundDownloadManager.shared.scheduleMaintenance()
            await self.refreshFromEngineSnapshot()
        }
    }

	func resume(itemID: String) {
		pauseRequestedIDs.remove(itemID)
		paused.remove(itemID)
		// Resume tapped while the previous pause is still tearing down: the old wrapper
		// task blocks start(), so record the intent — the dying transfer's late pause
		// event will restart the download instead of settling it back to paused.
		if tasks[itemID] != nil {
			resumePendingIDs.insert(itemID)
		}
        Task {
            await DownloadEngine.shared.updateJobState(externalID: itemID, state: .queued, manualPause: false)
        }
		if let idx = items.firstIndex(where: { $0.id == itemID }) {
			items[idx].error = nil // Clear error state
			items[idx].retryCount = 0 // Reset retry count on manual resume
            items[idx].status = .queued
            items[idx].canPause = true
            items[idx].canResume = false
			let item = items[idx]
			start(detail: item.detail, quant: item.quant)
            return
		}
        if let idx = leapItems.firstIndex(where: { $0.id == itemID }) {
            leapItems[idx].status = .queued
            leapItems[idx].canPause = true
            leapItems[idx].canResume = false
            let item = leapItems[idx]
            startLeap(entry: item.entry)
            return
        }
        if let idx = datasetItems.firstIndex(where: { $0.id == itemID }) {
            datasetItems[idx].error = nil
            datasetItems[idx].status = .queued
            datasetItems[idx].canPause = true
            datasetItems[idx].canResume = false
            let item = datasetItems[idx]
            startDataset(detail: item.detail)
            return
        }
        if let idx = embeddingItems.firstIndex(where: { $0.id == itemID }) {
            embeddingItems[idx].error = nil
            embeddingItems[idx].status = .queued
            embeddingItems[idx].canPause = true
            embeddingItems[idx].canResume = false
            let item = embeddingItems[idx]
            startEmbedding(recordID: item.recordID)
        }
        if let idx = whisperItems.firstIndex(where: { $0.id == itemID }) {
            whisperItems[idx].error = nil
            whisperItems[idx].status = .queued
            whisperItems[idx].canPause = true
            whisperItems[idx].canResume = false
            let item = whisperItems[idx]
            startWhisper(recordID: item.recordID, runtime: item.runtime)
        }
	}

    private func markVisibleItemScheduled(_ itemID: String) {
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].status = .scheduled
            items[idx].canPause = false
            items[idx].canResume = true
            items[idx].speed = 0
            items[idx].mainSpeed = 0
            items[idx].mmprojSpeed = 0
            items[idx].imatrixSpeed = 0
        }
        if let idx = leapItems.firstIndex(where: { $0.id == itemID }) {
            leapItems[idx].status = .scheduled
            leapItems[idx].canPause = false
            leapItems[idx].canResume = true
            leapItems[idx].speed = 0
            LeapBundleDownloader.shared.pause(slug: itemID)
        }
        if let idx = datasetItems.firstIndex(where: { $0.id == itemID }) {
            datasetItems[idx].status = .scheduled
            datasetItems[idx].canPause = false
            datasetItems[idx].canResume = true
            datasetItems[idx].speed = 0
        }
        if let idx = embeddingItems.firstIndex(where: { $0.id == itemID }) {
            embeddingItems[idx].status = .scheduled
            embeddingItems[idx].canPause = false
            embeddingItems[idx].canResume = true
            embeddingItems[idx].speed = 0
        }
        if let idx = whisperItems.firstIndex(where: { $0.id == itemID }) {
            whisperItems[idx].status = .scheduled
            whisperItems[idx].canPause = false
            whisperItems[idx].canResume = true
            whisperItems[idx].speed = 0
        }
    }

    /// Settles a model download task that observed a pause request at a phase boundary:
    /// stops the task, surfaces the paused (or scheduled) state, and persists it to the engine.
    private func holdModelTaskForPause(itemID: String) async {
        tasks[itemID] = nil
        let isScheduled = items.first(where: { $0.id == itemID })?.status == .scheduled
        if let idx = items.firstIndex(where: { $0.id == itemID }), !isScheduled {
            items[idx].status = .paused
            items[idx].canPause = false
            items[idx].canResume = true
            items[idx].speed = 0
            items[idx].mainSpeed = 0
            items[idx].mmprojSpeed = 0
            items[idx].imatrixSpeed = 0
        }
        await setAllArtifacts(externalID: itemID, state: .paused, manualPause: true)
        // schedule() already wrote the .scheduled job state; don't downgrade it.
        if !isScheduled {
            await DownloadEngine.shared.updateJobState(externalID: itemID, state: .paused, manualPause: true)
        }
    }

    /// Settles a dataset/embedding/whisper download task that observed a pause request
    /// at a phase boundary, mirroring `holdModelTaskForPause` for the auxiliary flows.
    private func holdAuxTaskForPause(itemID: String) async {
        tasks[itemID] = nil
        if let idx = datasetItems.firstIndex(where: { $0.id == itemID }), datasetItems[idx].status != .scheduled {
            datasetItems[idx].status = .paused
            datasetItems[idx].canPause = false
            datasetItems[idx].canResume = true
            datasetItems[idx].speed = 0
        }
        if let idx = embeddingItems.firstIndex(where: { $0.id == itemID }), embeddingItems[idx].status != .scheduled {
            embeddingItems[idx].status = .paused
            embeddingItems[idx].canPause = false
            embeddingItems[idx].canResume = true
            embeddingItems[idx].speed = 0
        }
        if let idx = whisperItems.firstIndex(where: { $0.id == itemID }), whisperItems[idx].status != .scheduled {
            whisperItems[idx].status = .paused
            whisperItems[idx].canPause = false
            whisperItems[idx].canResume = true
            whisperItems[idx].speed = 0
        }
        await setAllArtifacts(externalID: itemID, state: .paused, manualPause: true)
        if await DownloadEngine.shared.job(forExternalID: itemID)?.state != .scheduled {
            await DownloadEngine.shared.updateJobState(externalID: itemID, state: .paused, manualPause: true)
        }
    }

    private func pauseLiveTransfersForScheduling(itemID: String) async {
        if let item = items.first(where: { $0.id == itemID }) {
            await manager.pause(modelID: item.detail.id, quantLabel: item.quant.label)
            if let dest = item.mmprojDestination {
                await BackgroundDownloadManager.shared.pause(destination: dest)
            }
            if let dest = item.imatrixDestination {
                await BackgroundDownloadManager.shared.pause(destination: dest)
            }
            return
        }
        if let job = await DownloadEngine.shared.job(forExternalID: itemID) {
            for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
                await BackgroundDownloadManager.shared.pause(destination: artifact.destinationURL)
            }
        }
    }

	private func categorizeError(_ error: Error) -> DownloadError {
		let nsError = error as NSError

		// Network-related errors that should be retryable
		let networkErrorCodes: Set<Int> = [
			NSURLErrorNotConnectedToInternet,
			NSURLErrorTimedOut,
			NSURLErrorCannotConnectToHost,
			NSURLErrorNetworkConnectionLost,
			NSURLErrorDNSLookupFailed,
			NSURLErrorCannotFindHost,
			NSURLErrorInternationalRoamingOff,
			NSURLErrorCallIsActive,
			NSURLErrorDataNotAllowed
		]

		if nsError.domain == NSURLErrorDomain && networkErrorCodes.contains(nsError.code) {
			let message: String
			switch nsError.code {
			case NSURLErrorNotConnectedToInternet:
				message = "No internet connection"
			case NSURLErrorTimedOut:
				message = "Connection timed out"
			case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
				message = "Cannot reach server"
			case NSURLErrorNetworkConnectionLost:
				message = "Connection lost"
			case NSURLErrorDNSLookupFailed:
				message = "DNS lookup failed"
			default:
				message = "Network error"
			}
			return .networkError(message)
		}

		// HTTP 5xx and rate limiting are transient — retry instead of failing permanently.
		if let status = BackgroundDownloadManager.httpRejectionStatus(from: error),
		   status >= 500 || status == 429 {
			return .networkError("Server error (\(status))")
		}

		// HTTP errors that might be retryable
		if let httpError = error as? URLError,
		   let code = (httpError.userInfo["NSErrorFailingURLStringKey"] as? String),
		   let response = httpError.userInfo["NSErrorFailingURLKey"] as? HTTPURLResponse {
			if response.statusCode >= 500 { // Server errors
				return .networkError("Server error (\(response.statusCode))")
			}
		}

		// All other errors are permanent
		return .permanentError(error.localizedDescription)
	}

        private func networkErrorMessage(_ error: Error) -> String {
                let nsError = error as NSError

		if nsError.domain == NSURLErrorDomain {
			switch nsError.code {
			case NSURLErrorNotConnectedToInternet:
				return "No internet connection"
			case NSURLErrorTimedOut:
				return "Connection timed out"
			case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
				return "Cannot reach server"
			case NSURLErrorNetworkConnectionLost:
				return "Connection lost"
			case NSURLErrorDNSLookupFailed:
				return "DNS lookup failed"
			default:
				return "Network error"
			}
		}

                return "Connection failed"
        }

        private func waitForNetworkConnectivity() async {
                await withCheckedContinuation { continuation in
                        let monitor = NWPathMonitor()
                        let queue = DispatchQueue(label: "noema.network.monitor")
                        monitor.pathUpdateHandler = { path in
                                if path.status == .satisfied {
                                        monitor.cancel()
                                        continuation.resume()
                                }
                        }
                        monitor.start(queue: queue)
                }
        }

    func startLeap(entry: LeapCatalogEntry) {
        let id = entry.slug
        if tasks[id] != nil { return }
        cancelledExternalIDs.remove(id)
        pauseRequestedIDs.remove(id)
        resumePendingIDs.remove(id)
        // Ensure single UI entry per slug
        if !leapItems.contains(where: { $0.id == id }) {
            var item = LeapItem(entry: entry)
            item.status = .preparing
            leapItems.append(item)
        }
        showOverlay = true

		let t = Task { [weak self] in
			guard let self else { return }
            let job = await self.ensureLeapJob(entry: entry)
            if Task.isCancelled {
                if self.tasks[id] == nil {
                    await DownloadEngine.shared.removeJob(externalID: id)
                }
                return
            }
            await MainActor.run {
                if let idx = self.leapItems.firstIndex(where: { $0.id == id }) {
                    self.leapItems[idx].jobID = job.id
                    self.leapItems[idx].status = .preparing
                    self.leapItems[idx].canPause = true
                    self.leapItems[idx].canResume = false
                }
            }
			for await event in LeapBundleDownloader.shared.download(entry, jobID: job.id) {
				await MainActor.run {
					guard let idx = self.leapItems.firstIndex(where: { $0.id == id }) else { return }
                switch event {
                case .started(let total):
                    self.leapItems[idx].status = .downloading
                    self.leapItems[idx].canPause = true
                    self.leapItems[idx].canResume = false
                    Task {
                        await DownloadEngine.shared.updateJobState(externalID: id, state: .downloading, manualPause: false)
                    }
                    if let t = total, t > 0 {
                        self.leapItems[idx].expectedBytes = t
                        if self.loggedLeapExpected[id] != t {
                            self.loggedLeapExpected[id] = t
                            self.logDetectedSize(kind: "ET", id: id, bytes: t, source: "metadata")
                        }
                    }
                case .progress(let p, _, let expected, let speed):
                    self.leapItems[idx].status = .downloading
                    let pClamped = min(p, 0.999)
                    self.leapItems[idx].progress = pClamped
                    let previous = self.leapItems[idx].speed
                    let alpha = self.speedEMAAlpha
                    let clipped = min(speed, self.maxInstantaneousSpeed)
                    self.leapItems[idx].speed = previous * (1 - alpha) + clipped * alpha
                    self.lastLeapSpeedSampleAt[self.leapItems[idx].id] = Date()
                    self.leapItems[idx].verifying = false
                    if expected > 0 {
                        let prev = self.leapItems[idx].expectedBytes
                        self.leapItems[idx].expectedBytes = expected
                        if self.loggedLeapExpected[id] != expected || prev != expected {
                            self.loggedLeapExpected[id] = expected
                            self.logDetectedSize(kind: "ET", id: id, bytes: expected, source: "Content-Length")
                        }
                    }
                case .finished(let installed):
                    self.leapItems[idx].progress = 1
                    self.leapItems[idx].speed = 0
                    self.leapItems[idx].status = .completed
                    self.leapItems[idx].canPause = false
                    self.leapItems[idx].canResume = false
                    self.leapItems[idx].completed = true
                    self.leapItems[idx].verifying = false
                    Task {
                        await DownloadEngine.shared.updateJobState(externalID: id, state: .completed, manualPause: false)
                    }
                    Haptics.success()
                    if self.leapItems[idx].expectedBytes <= 0 { self.leapItems[idx].expectedBytes = Int64(installed.sizeBytes) }
#if os(macOS) && !canImport(UIKit)
                    if let manager = self.modelManager as? AppModelManager {
                        manager.install(installed)
                    }
#else
                    self.modelManager?.install(installed)
#endif
                    self.tasks[id] = nil
                    self.scheduleJobRemoval(externalID: id, delay: 3)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        self.leapItems.removeAll { $0.id == id }
                        if self.allItems.isEmpty { self.showOverlay = false }
                    }
                case .cancelled:
                    self.leapItems.removeAll { $0.id == id }
                    self.tasks[id] = nil
                    Task {
                        await DownloadEngine.shared.removeJob(externalID: id)
                    }
                    if self.allItems.isEmpty { self.showOverlay = false }
                case .paused(let progress):
                    self.leapItems[idx].progress = progress
                    self.leapItems[idx].speed = 0
                    self.leapItems[idx].status = .paused
                    self.leapItems[idx].canPause = false
                    self.leapItems[idx].canResume = true
                    self.leapItems[idx].verifying = false
                    self.tasks[id] = nil
                    self.paused.insert(id)
                    Task {
                        await DownloadEngine.shared.updateJobState(externalID: id, state: .paused, manualPause: true)
                    }
                case .networkError(_, let progress):
                    // Keep the item and schedule a retry with backoff
                    self.leapItems[idx].progress = progress
                    self.leapItems[idx].speed = 0
                    self.leapItems[idx].status = .retrying
                    self.leapItems[idx].canPause = false
                    self.leapItems[idx].canResume = true
                    self.leapItems[idx].verifying = false
                    self.tasks[id] = nil
                    self.leapItems[idx].retryCount += 1
                    Task {
                        await DownloadEngine.shared.updateJobState(externalID: id, state: .retrying, manualPause: false)
                    }
                    let delay = min(pow(2.0, Double(self.leapItems[idx].retryCount)), 60)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        await self.waitForNetworkConnectivity()
                        if self.tasks[id] == nil && self.leapItems.contains(where: { $0.id == id }) {
                            self.startLeap(entry: entry)
                        }
                    }
                case .failed(_):
                    self.leapItems[idx].completed = false
                    self.leapItems[idx].status = .failed
                    self.leapItems[idx].canPause = false
                    self.leapItems[idx].canResume = true
                    self.leapItems[idx].verifying = false
                    self.tasks[id] = nil
                    Task {
                        await DownloadEngine.shared.updateJobState(externalID: id, state: .failed, manualPause: false)
                    }
                    if self.allItems.isEmpty { self.showOverlay = false }
                default:
                    break
                }
				}
			}
		}

		tasks[id] = t
	}

        func startDataset(detail: DatasetDetails) {
                let id = detail.id
                if tasks[id] != nil { return }
                cancelledExternalIDs.remove(id)
                pauseRequestedIDs.remove(id)
                resumePendingIDs.remove(id)
                // Determine upfront file list and expected size using any known lengths from `detail`
                var filesToDownload: [DatasetFile] = detail.files.filter { DatasetFileSupport.isSupported($0) }
                // For OTL datasets, prefer the PDF file to match the size shown in search results
                if detail.id.hasPrefix("OTL/"),
                   let pdf = filesToDownload.first(where: {
                           DatasetFileSupport.fileExtension(name: $0.name, downloadURL: $0.downloadURL) == "pdf"
                   }) {
                        filesToDownload = [pdf]
                }
                var upfrontTotal: Int64 = filesToDownload.reduce(0) { $0 + $1.sizeBytes }

                var item = DatasetItem(detail: detail)
                item.status = .preparing
                if upfrontTotal > 0 {
                        item.expectedBytes = upfrontTotal
                        if loggedDatasetExpected[id] != upfrontTotal {
                                loggedDatasetExpected[id] = upfrontTotal
                                logDetectedSize(kind: "Dataset", id: id, bytes: upfrontTotal, source: "metadata")
                        }
                }
                item.downloadedBytes = 0
                if let idxExisting = datasetItems.firstIndex(where: { $0.id == id }) {
                        datasetItems[idxExisting] = item
                } else {
                        datasetItems.append(item)
                }
                showOverlay = true

                let t = Task { [weak self] in
                        guard let self else { return }
                        // Outer do/catch not required; inner operations handle their own errors
                                var filesToDownload = filesToDownload
                                // Some sources (e.g., OTL manual entries or landing pages) lack a file extension.
                                // Try to resolve a direct PDF/EPUB URL via HEAD/partial GET when nothing matched.
                                if filesToDownload.isEmpty {
                                        func resolveDirectURL(_ original: URL) async -> (URL, Int64)? {
                                                // 1) HEAD
                                                var head = URLRequest(url: original)
                                                head.httpMethod = "HEAD"
                                                head.setValue("application/pdf, application/epub+zip;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
                                                head.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
						do {
							if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
							NetworkKillSwitch.track(session: URLSession.shared)
							let (_, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(head))
							if let http = resp as? HTTPURLResponse {
								if let lenStr = http.value(forHTTPHeaderField: "Content-Length"), let len = Int64(lenStr), len > 0 { return (original, len) }
								if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let len = Int64(total) { return (original, len) }
								if http.expectedContentLength > 0 { return (original, http.expectedContentLength) }
							}
						} catch {}
						// 2) naive fetch
						var get = URLRequest(url: original)
						get.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
						if NetworkKillSwitch.isEnabled { return nil }
						NetworkKillSwitch.track(session: URLSession.shared)
						if let (data, resp) = try? await URLSession.shared.data(for: HFEndpoint.rewrite(get)), let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
							// crude content-sniffing
							let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
							let isPDF = mime.contains("pdf") || data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46])
							let isEPUB = mime.contains("epub") || data.starts(with: Data([0x50, 0x4b])) // zip signature
							if isPDF || isEPUB {
								return (original, Int64(data.count))
							}
						}
						return nil
					}
					// Use the first available file URL as a candidate landing URL
					if let candidate = detail.files.first,
					   let (resolved, size) = await resolveDirectURL(candidate.downloadURL) {
						filesToDownload = [DatasetFile(id: resolved.absoluteString, name: resolved.lastPathComponent, sizeBytes: size, downloadURL: resolved)]
                                        }
                                }

                                let job = await self.ensureDatasetJob(detail: detail, files: filesToDownload)
                                if Task.isCancelled {
                                        if self.tasks[id] == nil {
                                                await DownloadEngine.shared.removeJob(externalID: id)
                                        }
                                        return
                                }
                                await DownloadEngine.shared.updateJobState(externalID: id, state: .preparing, manualPause: false)
                                await MainActor.run {
                                        if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                self.datasetItems[idx].jobID = job.id
                                                self.datasetItems[idx].status = .preparing
                                                self.datasetItems[idx].canPause = true
                                                self.datasetItems[idx].canResume = false
                                        }
                                }

                                // Ensure target dataset directory exists
                                let baseDir = DownloadController.datasetBaseDir(for: id)
				do { try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true) } catch { return }
				// Persist a human-readable title alongside the dataset when available
				if let title = detail.displayName, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					let titleURL = DatasetIndexIO.titleURL(for: baseDir)
                                        try? title.data(using: .utf8)?.write(to: titleURL)
                                }

                                var totalSize: Int64 = upfrontTotal
                                if totalSize == 0 {
                                        for file in filesToDownload {
                                                totalSize += await self.fetchRemoteSize(file.downloadURL)
                                        }
                                        await MainActor.run {
                                                if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                        self.datasetItems[idx].expectedBytes = totalSize
                                                        if totalSize > 0, self.loggedDatasetExpected[id] != totalSize {
                                                                self.loggedDatasetExpected[id] = totalSize
                                                                self.logDetectedSize(kind: "Dataset", id: id, bytes: totalSize, source: "HEAD")
                                                        }
                                                }
                                        }
                                }

                                var completedBytes: Int64 = 0
                                // Fallback tracker for unknown total sizes: equal-share per file
                                let fileCount = max(filesToDownload.count, 1)
                                var completedFiles: Int = 0

                                // Download each file sequentially for now (can parallelize later)
                                for file in filesToDownload {
                                        let fileURL = file.downloadURL
                    let relativePath = Self.datasetRelativePath(for: file)
                    let artifactID = Self.datasetArtifactID(relativePath: relativePath)
                                        var req = URLRequest(url: fileURL)
                    req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
                                        var knownExpected: Int64 = file.sizeBytes
                                        if knownExpected <= 0 { knownExpected = await self.fetchRemoteSize(fileURL) }
                                        let finalDest = Self.datasetDestinationURL(for: id, relativePath: relativePath)
                                        let stagedDest = Self.stagingURL(for: finalDest)
                                        try? FileManager.default.createDirectory(at: finalDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                                        var speedLastTime: Date? = nil
                                        var lastBytes: Int64 = 0
                                        var lastProgressTickAt: Date = .distantPast
                                        var attempt = 0
                                        retryLoop: while true {
                                        if Task.isCancelled {
                                                await MainActor.run {
                                                        self.tasks[id] = nil
                                                        if self.allItems.isEmpty { self.showOverlay = false }
                                                }
                                                return
                                        }
                                        if self.pauseRequestedIDs.contains(id) {
                                                await self.holdAuxTaskForPause(itemID: id)
                                                return
                                        }
                                        do {
                                        await DownloadEngine.shared.updateArtifactState(
                                            externalID: id,
                                            artifactID: artifactID,
                                            state: .downloading,
                                            manualPause: false
                                        )
                                        await DownloadEngine.shared.updateJobState(externalID: id, state: .downloading, manualPause: false)
                                        await MainActor.run {
                                            if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                self.datasetItems[idx].status = .downloading
                                                self.datasetItems[idx].canPause = true
                                                self.datasetItems[idx].canResume = false
                                            }
                                        }
                                        try await BackgroundDownloadManager.shared.download(
                                            request: req,
                                            to: stagedDest,
                                            jobID: job.id,
                                            artifactID: artifactID,
                                            expectedSize: knownExpected,
                                            progress: { [weak self] frac in
                                                guard let self else { return }
                                                // Avoid reporting 100% until completion to prevent perceived stalls at 100%
                                                let f = max(0, min(frac, 0.999))
                                                let now = Date()
                                                if now.timeIntervalSince(lastProgressTickAt) < 0.10 { return }
                                                lastProgressTickAt = now
                                                // Progress callback may be non-async; hop to main safely.
                                                Task { @MainActor in
                                                    if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                        if totalSize > 0 {
                                                            let already = completedBytes
                                                            let cur = Int64(Double(max(knownExpected, 0)) * f)
                                                            self.datasetItems[idx].downloadedBytes = already + cur
                                                            let denom = Double(totalSize)
                                                            let prog = denom > 0 ? Double(self.datasetItems[idx].downloadedBytes) / denom : 0
                                                            self.datasetItems[idx].progress = max(0, min(1, prog))
                                                        } else {
                                                            // Unknown total size (e.g., OTL). Use per-file equal-share fallback
                                                            let prog = (Double(completedFiles) + Double(f)) / Double(fileCount)
                                                            self.datasetItems[idx].progress = max(0, min(1, prog))
                                                        }
                                                    }
                                                }
                                            },
                                            progressBytes: { [weak self] written, expected in
                                                guard let self else { return }
                                                Task {
                                                    await DownloadEngine.shared.updateArtifactProgressLive(
                                                        externalID: id,
                                                        artifactID: artifactID,
                                                        written: written,
                                                        expected: expected > 0 ? expected : knownExpected
                                                    )
                                                }
                                                let now = Date()
                                                // Initialize sampler on the first callback to avoid dt==0 loop
                                                if speedLastTime == nil {
                                                    speedLastTime = now
                                                    lastBytes = written
                                                }
                                                // If we didn't know total size, adopt the expected value from the task
                                                if expected > 0 && totalSize == 0 {
                                                    totalSize = expected
                                                    Task { @MainActor in
                                                        if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                            self.datasetItems[idx].expectedBytes = expected
                                                            if self.loggedDatasetExpected[id] != expected {
                                                                self.loggedDatasetExpected[id] = expected
                                                                self.logDetectedSize(kind: "Dataset", id: id, bytes: expected, source: "Content-Length")
                                                            }
                                                        }
                                                    }
                                                }
                                                let lastT = speedLastTime ?? now
                                                let dt = now.timeIntervalSince(lastT)
                                                guard dt >= 0.25 else { return }
                                                let raw = Double(written - lastBytes) / dt
                                                let instSpeed = max(0, min(raw, self.maxInstantaneousSpeed))
                                                speedLastTime = now
                                                lastBytes = written
                                                Task { @MainActor in
                                                    if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                        let previous = self.datasetItems[idx].speed
                                                        let alpha = self.speedEMAAlpha
                                                        let clipped = min(instSpeed, self.maxInstantaneousSpeed)
                                                        self.datasetItems[idx].speed = previous * (1 - alpha) + clipped * alpha
                                                        self.lastDatasetSpeedSampleAt[self.datasetItems[idx].id] = Date()
                                                    }
                                                }
                                            })
                                        try self.finalizeStagedDownload(from: stagedDest, to: finalDest)
                                        let finalBytes = (try? FileManager.default.attributesOfItem(atPath: finalDest.path)[.size] as? Int64) ?? knownExpected
                                        await DownloadEngine.shared.markArtifactCompleted(
                                            externalID: id,
                                            artifactID: artifactID,
                                            finalBytes: finalBytes
                                        )
                                        // Advance the per-file baseline on success. This must happen before
                                        // `break retryLoop`: every other exit from the do-catch returns or
                                        // continues, so code placed after the loop body's do-catch never runs
                                        // and later files' progress would restart from a stale baseline.
                                        completedBytes += max(knownExpected, 0)
                                        if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                self.datasetItems[idx].downloadedBytes = completedBytes
                                        }
                                        if totalSize == 0 { completedFiles += 1 }
                                        break retryLoop
                                        } catch {
                                            // Ensure this Task remains non-throwing so it fits `Task<Void, Never>`.
                                            if Task.isCancelled {
                                                // Exit quietly on cancellation; overlay cleanup happens via cancel().
                                                await MainActor.run {
                                                    self.tasks[id] = nil
                                                    if self.allItems.isEmpty { self.showOverlay = false }
                                                }
                                                return
                                            }
                                            let nsError = error as NSError
                                            if nsError.domain == NSURLErrorDomain,
                                               nsError.code == NSURLErrorCancelled,
                                               self.resumePendingIDs.remove(id) != nil {
                                                // Resume was tapped while the pause was still settling;
                                                // retry the same file now instead of failing permanently.
                                                continue retryLoop
                                            }
                                            let pausedByUser = nsError.domain == NSURLErrorDomain
                                                && nsError.code == NSURLErrorCancelled
                                                && (self.paused.contains(id) || self.pauseRequestedIDs.contains(id))
                                            let errType = self.categorizeError(error)
                                            if pausedByUser {
                                                await DownloadEngine.shared.updateArtifactState(
                                                    externalID: id,
                                                    artifactID: artifactID,
                                                    state: .paused,
                                                    manualPause: true
                                                )
                                                await DownloadEngine.shared.updateJobState(externalID: id, state: .paused, manualPause: true)
                                                await MainActor.run {
                                                    if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                        self.datasetItems[idx].status = .paused
                                                        self.datasetItems[idx].canPause = false
                                                        self.datasetItems[idx].canResume = true
                                                        self.datasetItems[idx].speed = 0
                                                    }
                                                    self.tasks[id] = nil
                                                }
                                                return
                                            } else if errType.isRetryable {
                                                // Exponential backoff, then retry the same file.
                                                attempt += 1
                                                await DownloadEngine.shared.updateArtifactState(
                                                    externalID: id,
                                                    artifactID: artifactID,
                                                    state: .retrying,
                                                    retryCount: attempt,
                                                    nextRetryAt: Date().addingTimeInterval(min(pow(2.0, Double(attempt)), 60)),
                                                    errorMessage: errType.localizedDescription,
                                                    manualPause: false
                                                )
                                                await DownloadEngine.shared.updateJobState(
                                                    externalID: id,
                                                    state: .retrying,
                                                    manualPause: false,
                                                    errorMessage: errType.localizedDescription
                                                )
                                                let delay = min(pow(2.0, Double(attempt)), 60)
                                                try? await Task.sleep(for: .seconds(delay))
                                                await self.waitForNetworkConnectivity()
                                                continue retryLoop
                                            } else {
                                                // Non-retryable: surface error and terminate the dataset task gracefully.
                                                await DownloadEngine.shared.updateArtifactState(
                                                    externalID: id,
                                                    artifactID: artifactID,
                                                    state: .failed,
                                                    errorMessage: errType.localizedDescription,
                                                    manualPause: false
                                                )
                                                await DownloadEngine.shared.updateJobState(
                                                    externalID: id,
                                                    state: .failed,
                                                    manualPause: false,
                                                    errorMessage: errType.localizedDescription
                                                )
                                                await MainActor.run {
                                                    if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                        self.datasetItems[idx].error = errType
                                                        self.datasetItems[idx].speed = 0
                                                        self.datasetItems[idx].status = .failed
                                                        self.datasetItems[idx].canPause = false
                                                        self.datasetItems[idx].canResume = true
                                                    }
                                                    self.tasks[id] = nil
                                                    if self.allItems.isEmpty { self.showOverlay = false }
                                                }
                                                return
                                            }
                                        }
                                }

                                await MainActor.run {
                                        if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                self.datasetItems[idx].progress = 1
                                                self.datasetItems[idx].downloadedBytes = totalSize
                                                self.datasetItems[idx].speed = 0
                                                self.datasetItems[idx].status = .completed
                                                self.datasetItems[idx].canPause = false
                                                self.datasetItems[idx].canResume = false
                                                self.datasetItems[idx].completed = true
                                        }
                                        Haptics.success()
                                        // Make the dataset show up in Stored immediately (and trigger indexing prompt).
                                        self.datasetManager?.handleDatasetDownloadCompleted(datasetID: id)
                                        // Keep the item visible briefly to avoid flicker back to a button
                                        self.tasks[id] = nil
                                        self.scheduleJobRemoval(externalID: id, delay: 3)
                                        Task { @MainActor in
                                                try? await Task.sleep(for: .seconds(3))
                                                self.datasetItems.removeAll { $0.id == id }
                                                if self.allItems.isEmpty { self.showOverlay = false }
                                        }
                                }
                                await DownloadEngine.shared.updateJobState(externalID: id, state: .completed, manualPause: false)
                        }
                }

		tasks[id] = t
	}

	func startEmbedding(repoID: String) {
        let record = EmbeddingModelCatalog.record(matchingDownloadIdentifier: repoID) ?? EmbeddingModelCatalog.activeRecord()
        startEmbedding(recordID: record.id)
    }

    func startEmbedding(recordID: String) {
        guard let record = EmbeddingModelCatalog.record(for: recordID),
              record.isInstallable,
              let artifact = record.primaryArtifact,
              let remote = artifact.downloadURL else {
            Task { await logger.log("[DownloadController] Embedding model is not installable: \(recordID)") }
            return
        }
		let id = record.id
		if tasks[id] != nil { return }
        cancelledExternalIDs.remove(id)
        pauseRequestedIDs.remove(id)
        resumePendingIDs.remove(id)
        let finalDest = artifact.localURL(recordID: record.id)
		if FileManager.default.fileExists(atPath: finalDest.path) {
			Task { await logger.log("[DownloadController] Embedding model already installed; skipping download request for \(record.id)") }
			NotificationCenter.default.post(
                name: .embeddingModelAvailabilityChanged,
                object: nil,
                userInfo: ["available": record.id == EmbeddingModelCatalog.activeRecord().id, "recordID": record.id]
            )
			return
		}

		var item = EmbeddingItem(record: record)
        item.status = .preparing
        if let idx = embeddingItems.firstIndex(where: { $0.id == id }) {
            embeddingItems[idx] = item
        } else {
		    embeddingItems.append(item)
        }
		showOverlay = true

		let t = Task { [weak self] in
			guard let self else { return }
			do {
                let job = await self.ensureEmbeddingJob(record: record, artifact: artifact)
                if Task.isCancelled {
                    if self.tasks[id] == nil {
                        await DownloadEngine.shared.removeJob(externalID: id)
                    }
                    return
                }
                await DownloadEngine.shared.updateJobState(externalID: id, state: .preparing, manualPause: false)
                await MainActor.run {
                    if let idx = self.embeddingItems.firstIndex(where: { $0.id == id }) {
                        self.embeddingItems[idx].jobID = job.id
                        self.embeddingItems[idx].status = .preparing
                        self.embeddingItems[idx].canPause = true
                        self.embeddingItems[idx].canResume = false
                    }
                }
				// Attempt to discover expected content length via HEAD/Range
				let knownExpected = await self.fetchRemoteSize(remote)
				if knownExpected > 0 && self.loggedEmbedExpected[id] != knownExpected {
					self.loggedEmbedExpected[id] = knownExpected
					self.logDetectedSize(kind: "Embed", id: id, bytes: knownExpected, source: "HEAD")
				}
				// Record expected bytes for aggregation if known
				await MainActor.run {
					if let idx = self.embeddingItems.firstIndex(where: { $0.id == id }) {
						self.embeddingItems[idx].expectedBytes = max(knownExpected, artifact.sizeBytes)
					}
				}
                var completed: Int64 = 0
                // Ensure destination directory exists before moving
                try FileManager.default.createDirectory(at: artifact.directoryURL(recordID: record.id), withIntermediateDirectories: true)
                let stagedDest = Self.stagingURL(for: finalDest)
                var req = URLRequest(url: remote)
                req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
                if Task.isCancelled {
                    if self.tasks[id] == nil {
                        await DownloadEngine.shared.removeJob(externalID: id)
                    }
                    return
                }
                if self.pauseRequestedIDs.contains(id) {
                    await self.holdAuxTaskForPause(itemID: id)
                    return
                }
                await DownloadEngine.shared.updateArtifactState(
                    externalID: id,
                    artifactID: DurableArtifactID.embedding,
                    state: .downloading,
                    manualPause: false
                )
                await DownloadEngine.shared.updateJobState(externalID: id, state: .downloading, manualPause: false)
                try await BackgroundDownloadManager.shared.download(
                    request: req,
                    to: stagedDest,
                    jobID: job.id,
                    artifactID: DurableArtifactID.embedding,
                    expectedSize: knownExpected,
                    progress: { [weak self] prog in
                        guard let self else { return }
                        Task { @MainActor in
                            if let idx = self.embeddingItems.firstIndex(where: { $0.id == id }) {
                                self.embeddingItems[idx].status = .downloading
                                let expected = max(knownExpected, artifact.sizeBytes)
                                let cur = Int64(Double(max(expected, 0)) * min(prog, 0.999))
                                let total = max(expected, 1)
                                self.embeddingItems[idx].progress = max(0, min(1, Double(cur) / Double(total)))
                            }
                        }
                    },
                    progressBytes: { [weak self] written, _ in
                        guard let self else { return }
                        Task {
                            await DownloadEngine.shared.updateArtifactProgressLive(
                                externalID: id,
                                artifactID: DurableArtifactID.embedding,
                                written: written,
                                expected: knownExpected > 0 ? knownExpected : artifact.sizeBytes
                            )
                        }
                        // Keep speed optional for embed download UI; we don't show it, but we can later
                        _ = written
                    })
                try self.finalizeStagedDownload(from: stagedDest, to: finalDest)
                await DownloadEngine.shared.markArtifactCompleted(
                    externalID: id,
                    artifactID: DurableArtifactID.embedding,
                    finalBytes: knownExpected > 0 ? knownExpected : fileSize(at: finalDest)
                )
                UserDefaults.standard.set(true, forKey: "hasInstalledEmbedModel:\(finalDest.path)")
                NotificationCenter.default.post(
                    name: .embeddingModelAvailabilityChanged,
                    object: nil,
                    userInfo: ["available": record.id == EmbeddingModelCatalog.activeRecord().id, "recordID": record.id]
                )
                completed = knownExpected

					await MainActor.run {
						if let idx = self.embeddingItems.firstIndex(where: { $0.id == id }) {
							self.embeddingItems[idx].progress = 1
							self.embeddingItems[idx].speed = 0
                            self.embeddingItems[idx].status = .completed
                            self.embeddingItems[idx].canPause = false
                            self.embeddingItems[idx].canResume = false
							self.embeddingItems[idx].completed = true
							if self.embeddingItems[idx].expectedBytes == 0 { self.embeddingItems[idx].expectedBytes = completed }
						}
                        Haptics.success()
						// Keep the item visible briefly to avoid flicker back to a button
						self.tasks[id] = nil
                        self.scheduleJobRemoval(externalID: id, delay: 1.2)
						Task { @MainActor in
							try? await Task.sleep(for: .seconds(1.2))
						self.embeddingItems.removeAll { $0.id == id }
						if self.allItems.isEmpty { self.showOverlay = false }
					}
				}
                await DownloadEngine.shared.updateJobState(externalID: id, state: .completed, manualPause: false)
			} catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain,
                   nsError.code == NSURLErrorCancelled,
                   self.resumePendingIDs.remove(id) != nil {
                    // Resume was tapped while the pause was still settling; restart now
                    // instead of marking the download failed.
                    await MainActor.run { self.tasks[id] = nil }
                    self.startEmbedding(recordID: record.id)
                    return
                }
                let pausedByUser = nsError.domain == NSURLErrorDomain
                    && nsError.code == NSURLErrorCancelled
                    && (self.paused.contains(id) || self.pauseRequestedIDs.contains(id))
                await DownloadEngine.shared.updateArtifactState(
                    externalID: id,
                    artifactID: DurableArtifactID.embedding,
                    state: pausedByUser ? .paused : .failed,
                    errorMessage: pausedByUser ? nil : error.localizedDescription,
                    manualPause: pausedByUser
                )
                await DownloadEngine.shared.updateJobState(
                    externalID: id,
                    state: pausedByUser ? .paused : .failed,
                    manualPause: pausedByUser,
                    errorMessage: pausedByUser ? nil : error.localizedDescription
                )
				await MainActor.run {
					if let idx = self.embeddingItems.firstIndex(where: { $0.id == id }) {
                        self.embeddingItems[idx].status = pausedByUser ? .paused : .failed
                        self.embeddingItems[idx].canPause = false
                        self.embeddingItems[idx].canResume = true
						self.embeddingItems[idx].error = pausedByUser ? nil : .permanentError("Failed to download embedding model: \(error.localizedDescription)")
					}
					self.tasks[id] = nil
					if self.allItems.isEmpty { self.showOverlay = false }
				}
			}
		}

		tasks[id] = t
	}

    nonisolated static func whisperExternalID(recordID: String, runtime: WhisperRuntimeFormat) -> String {
        "whisper:\(runtime.rawValue):\(recordID)"
    }

    func startWhisper(recordID: String, runtime: WhisperRuntimeFormat) {
        guard let record = WhisperModelCatalog.record(for: recordID),
              let artifact = record.artifact(for: runtime),
              let remote = artifact.downloadURL else {
            Task { await logger.log("[DownloadController] Whisper model is not directly downloadable: \(recordID) runtime=\(runtime.rawValue)") }
            return
        }

        let id = Self.whisperExternalID(recordID: record.id, runtime: runtime)
        if tasks[id] != nil { return }
        cancelledExternalIDs.remove(id)
        pauseRequestedIDs.remove(id)
        resumePendingIDs.remove(id)
        let finalDest = record.directoryURL(runtime: runtime)
            .appendingPathComponent(URL(fileURLWithPath: artifact.resourcePath).lastPathComponent)
        if FileManager.default.fileExists(atPath: finalDest.path) {
            Task { await logger.log("[DownloadController] Whisper model already installed; skipping download request for \(record.id)") }
            return
        }

        var item = WhisperItem(record: record, runtime: runtime)
        item.status = .preparing
        if let idx = whisperItems.firstIndex(where: { $0.id == id }) {
            whisperItems[idx] = item
        } else {
            whisperItems.append(item)
        }
        showOverlay = true

        let t = Task { [weak self] in
            guard let self else { return }
            do {
                let job = await self.ensureWhisperJob(record: record, artifact: artifact)
                if Task.isCancelled {
                    if self.tasks[id] == nil {
                        await DownloadEngine.shared.removeJob(externalID: id)
                    }
                    return
                }
                await DownloadEngine.shared.updateJobState(externalID: id, state: .preparing, manualPause: false)
                await MainActor.run {
                    if let idx = self.whisperItems.firstIndex(where: { $0.id == id }) {
                        self.whisperItems[idx].jobID = job.id
                        self.whisperItems[idx].status = .preparing
                        self.whisperItems[idx].canPause = true
                        self.whisperItems[idx].canResume = false
                    }
                }

                let knownExpected = await self.fetchRemoteSize(remote)
                await MainActor.run {
                    if let idx = self.whisperItems.firstIndex(where: { $0.id == id }) {
                        self.whisperItems[idx].expectedBytes = max(knownExpected, artifact.sizeBytes)
                    }
                }

                try FileManager.default.createDirectory(at: finalDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let stagedDest = Self.stagingURL(for: finalDest)
                var req = URLRequest(url: remote)
                req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")

                if Task.isCancelled {
                    if self.tasks[id] == nil {
                        await DownloadEngine.shared.removeJob(externalID: id)
                    }
                    return
                }
                if self.pauseRequestedIDs.contains(id) {
                    await self.holdAuxTaskForPause(itemID: id)
                    return
                }
                await DownloadEngine.shared.updateArtifactState(
                    externalID: id,
                    artifactID: DurableArtifactID.whisper,
                    state: .downloading,
                    manualPause: false
                )
                await DownloadEngine.shared.updateJobState(externalID: id, state: .downloading, manualPause: false)

                var speedLastTime: Date?
                var lastBytes: Int64 = 0
                try await BackgroundDownloadManager.shared.download(
                    request: req,
                    to: stagedDest,
                    jobID: job.id,
                    artifactID: DurableArtifactID.whisper,
                    expectedSize: knownExpected > 0 ? knownExpected : artifact.sizeBytes,
                    progress: { [weak self] prog in
                        guard let self else { return }
                        Task { @MainActor in
                            guard let idx = self.whisperItems.firstIndex(where: { $0.id == id }) else { return }
                            self.whisperItems[idx].status = .downloading
                            let expected = max(knownExpected, artifact.sizeBytes)
                            if expected > 0 {
                                self.whisperItems[idx].progress = max(0, min(1, Double(Int64(Double(expected) * min(prog, 0.999))) / Double(expected)))
                            } else {
                                self.whisperItems[idx].progress = max(0, min(0.999, prog))
                            }
                        }
                    },
                    progressBytes: { [weak self] written, expected in
                        guard let self else { return }
                        Task {
                            await DownloadEngine.shared.updateArtifactProgressLive(
                                externalID: id,
                                artifactID: DurableArtifactID.whisper,
                                written: written,
                                expected: expected > 0 ? expected : (knownExpected > 0 ? knownExpected : artifact.sizeBytes)
                            )
                        }
                        let now = Date()
                        if speedLastTime == nil {
                            speedLastTime = now
                            lastBytes = written
                        }
                        let lastT = speedLastTime ?? now
                        let dt = now.timeIntervalSince(lastT)
                        guard dt >= 0.25 else { return }
                        let raw = Double(written - lastBytes) / dt
                        speedLastTime = now
                        lastBytes = written
                        Task { @MainActor in
                            guard let idx = self.whisperItems.firstIndex(where: { $0.id == id }) else { return }
                            self.whisperItems[idx].downloadedBytes = written
                            self.whisperItems[idx].speed = max(0, min(raw, self.maxInstantaneousSpeed))
                            self.lastDatasetSpeedSampleAt[id] = Date()
                        }
                    }
                )

                try self.finalizeStagedDownload(from: stagedDest, to: finalDest)
                let finalBytes = fileSize(at: finalDest) ?? max(knownExpected, artifact.sizeBytes)
                await DownloadEngine.shared.markArtifactCompleted(
                    externalID: id,
                    artifactID: DurableArtifactID.whisper,
                    finalBytes: finalBytes
                )
                await DownloadEngine.shared.updateJobState(externalID: id, state: .completed, manualPause: false)
                await MainActor.run {
                    if let idx = self.whisperItems.firstIndex(where: { $0.id == id }) {
                        self.whisperItems[idx].progress = 1
                        self.whisperItems[idx].downloadedBytes = finalBytes
                        self.whisperItems[idx].speed = 0
                        self.whisperItems[idx].status = .completed
                        self.whisperItems[idx].canPause = false
                        self.whisperItems[idx].canResume = false
                        self.whisperItems[idx].completed = true
                        if self.whisperItems[idx].expectedBytes == 0 { self.whisperItems[idx].expectedBytes = finalBytes }
                    }
                    Haptics.success()
                    self.tasks[id] = nil
                    self.scheduleJobRemoval(externalID: id, delay: 1.2)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        self.whisperItems.removeAll { $0.id == id }
                        if self.allItems.isEmpty { self.showOverlay = false }
                    }
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain,
                   nsError.code == NSURLErrorCancelled,
                   self.resumePendingIDs.remove(id) != nil {
                    // Resume was tapped while the pause was still settling; restart now
                    // instead of marking the download failed.
                    await MainActor.run { self.tasks[id] = nil }
                    self.startWhisper(recordID: record.id, runtime: runtime)
                    return
                }
                let pausedByUser = nsError.domain == NSURLErrorDomain
                    && nsError.code == NSURLErrorCancelled
                    && (self.paused.contains(id) || self.pauseRequestedIDs.contains(id))
                await DownloadEngine.shared.updateArtifactState(
                    externalID: id,
                    artifactID: DurableArtifactID.whisper,
                    state: pausedByUser ? .paused : .failed,
                    errorMessage: pausedByUser ? nil : error.localizedDescription,
                    manualPause: pausedByUser
                )
                await DownloadEngine.shared.updateJobState(
                    externalID: id,
                    state: pausedByUser ? .paused : .failed,
                    manualPause: pausedByUser,
                    errorMessage: pausedByUser ? nil : error.localizedDescription
                )
                await MainActor.run {
                    if let idx = self.whisperItems.firstIndex(where: { $0.id == id }) {
                        self.whisperItems[idx].status = pausedByUser ? .paused : .failed
                        self.whisperItems[idx].canPause = false
                        self.whisperItems[idx].canResume = true
                        self.whisperItems[idx].speed = 0
                        self.whisperItems[idx].error = pausedByUser ? nil : .permanentError("Failed to download Whisper model: \(error.localizedDescription)")
                    }
                    self.tasks[id] = nil
                    if self.allItems.isEmpty { self.showOverlay = false }
                }
            }
        }

        tasks[id] = t
    }

		// HEAD size helper
	private func fetchRemoteSize(_ url: URL) async -> Int64 {
		var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		var items = comps.queryItems ?? []
		if !items.contains(where: { $0.name == "download" }) {
			items.append(URLQueryItem(name: "download", value: "1"))
		}
		comps.queryItems = items
		var req = URLRequest(url: comps.url!)
		req.httpMethod = "HEAD"
		if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		do {
			if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
			NetworkKillSwitch.track(session: URLSession.shared)
			let (_, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
			if let http = resp as? HTTPURLResponse {
				if let lenStr = http.value(forHTTPHeaderField: "Content-Length"), let len = Int64(lenStr), len > 0 { return len }
				if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let len = Int64(total) { return len }
				if http.expectedContentLength > 0 { return http.expectedContentLength }
			}
		} catch {}
		return 0
	}

	// Extract "owner/repo" from a Hugging Face URL if present
    private func huggingFaceRepoID(from url: URL) -> String? {
                guard let host = url.host, host.contains("huggingface.co") else { return nil }
                var parts = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
                let prefixes: Set<String> = ["repos", "api", "models"]
                while parts.count > 2, let first = parts.first, prefixes.contains(first) {
                        parts.removeFirst()
                }
                guard parts.count >= 2 else { return nil }
                let owner = parts[0]
                let repo = parts[1]
                guard !owner.isEmpty && !repo.isEmpty else { return nil }
                return "\(owner)/\(repo)"
        }

	private func logDetectedSize(kind: String, id: String, bytes: Int64, source: String) {
        guard bytes > 0 else { return }
        let human = Self.byteFormatter.string(fromByteCount: bytes)
        Task { await logger.log("[Download][Size][\(kind)] id=\(id) size=\(human) (\(bytes)B) source=\(source)") }
    }

    private func finalizeStagedDownload(from stagingURL: URL, to finalURL: URL) throws {
        guard stagingURL.path != finalURL.path else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.removeItemIfExists(at: finalURL)
        if fm.fileExists(atPath: stagingURL.path) {
            try fm.moveItem(at: stagingURL, to: finalURL)
        }
    }

    private func finalizeBackgroundArtifactIfNeeded(observedURL: URL) async -> URL {
        guard let job = await DownloadEngine.shared.job(matching: observedURL),
              let artifact = job.artifacts.first(where: {
                  $0.stagingURL.path == observedURL.path || $0.finalURL.path == observedURL.path
              }) else {
            return observedURL
        }
        guard artifact.stagingURL.path == observedURL.path else { return observedURL }
        do {
            try finalizeStagedDownload(from: artifact.stagingURL, to: artifact.finalURL)
            return artifact.finalURL
        } catch {
            Task { await logger.log("[Download][Finalize] failed staging=\(artifact.stagingURL.lastPathComponent) error=\(error.localizedDescription)") }
            return observedURL
        }
    }

	func cancel(itemID: String) {
		cancelledExternalIDs.insert(itemID)
		pauseRequestedIDs.remove(itemID)
		resumePendingIDs.remove(itemID)
		tasks[itemID]?.cancel()
		tasks[itemID] = nil
        Task {
            // Snapshot the artifacts before flipping states: markCancelled sets every
            // artifact to .cancelled, which would hide the live transfers from the loop below.
            let job = await DownloadEngine.shared.job(forExternalID: itemID)
            // Mark cancelled first so engine-change refreshes and the auto-resume/scheduler
            // paths stop considering this job while teardown is still in flight.
            await DownloadEngine.shared.markCancelled(externalID: itemID)
            if let job {
                let jobCompleted = job.state == .completed || job.artifacts.allSatisfy { $0.state == .completed }
                if !jobCompleted {
                    var cleanupURLs: [URL] = []
                    for artifact in job.artifacts where artifact.state != .cancelled {
                        await MainActor.run {
                            BackgroundDownloadManager.shared.cancel(destination: artifact.destinationURL)
                        }
                        cleanupURLs.append(artifact.stagingURL)
                        cleanupURLs.append(artifact.finalURL)
                    }
                    _ = ModelStorageCleanup.deleteURLs(cleanupURLs)
                } else {
                    for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
                        await MainActor.run {
                            BackgroundDownloadManager.shared.cancel(destination: artifact.destinationURL)
                        }
                    }
                }
            }
            await DownloadEngine.shared.removeJobIfCancelled(externalID: itemID)
            // Keep the tombstone briefly: a still-unwinding download task can write one last
            // engine update after removeJob; the guards in the start bodies clean that up,
            // and the tombstone keeps the row hidden until they run.
            try? await Task.sleep(for: .seconds(2))
            self.cancelledExternalIDs.remove(itemID)
        }
		if let idx = items.firstIndex(where: { $0.id == itemID }) {
			let item = items.remove(at: idx)
			Task { await manager.cancel(modelID: item.detail.id, quantLabel: item.quant.label) }
			if let dest = item.mmprojDestination {
				BackgroundDownloadManager.shared.cancel(destination: dest)
			}
            if let dest = item.imatrixDestination {
                BackgroundDownloadManager.shared.cancel(destination: dest)
            }
			// Stop should not delete an already-installed model. Incomplete downloads
            // are cleaned aggressively so completed parts do not become storage orphans.
            if item.status != .completed {
                let base = InstalledModelsStore.baseDir(for: item.quant.format, modelID: item.detail.id)
                var cleanupURLs = item.quant.allRelativeDownloadPaths.map { base.appendingPathComponent($0) }
                if let rel = item.imatrixPath ?? item.quant.importanceMatrix?.path {
                    cleanupURLs.append(base.appendingPathComponent(rel))
                } else if let dest = item.imatrixDestination {
                    cleanupURLs.append(dest)
                }
                if let mtp = item.quant.mtp {
                    cleanupURLs.append(base.appendingPathComponent(QuantInfo.relativeDownloadPath(path: mtp.path, fallbackURL: mtp.downloadURL)))
                }
                if let filename = item.mmprojFilename {
                    cleanupURLs.append(base.appendingPathComponent(filename))
                } else if let dest = item.mmprojDestination {
                    cleanupURLs.append(dest)
                }
                _ = ModelStorageCleanup.deleteURLs(cleanupURLs)
            }
		}
		if let idx = leapItems.firstIndex(where: { $0.id == itemID }) {
			leapItems.remove(at: idx)
			LeapBundleDownloader.shared.cancel(slug: itemID)
		}
		if let idx = datasetItems.firstIndex(where: { $0.id == itemID }) {
			datasetItems.remove(at: idx)
		}
		if let idx = embeddingItems.firstIndex(where: { $0.id == itemID }) {
			embeddingItems.remove(at: idx)
		}
        if let idx = whisperItems.firstIndex(where: { $0.id == itemID }) {
            whisperItems.remove(at: idx)
        }
        paused.remove(itemID)
		if allItems.isEmpty { showOverlay = false }
	}

	/// Called when user taps overlay
        func openList() {
                showPopup = true
        }

        func closeList() {
                showPopup = false
        }

	var overallProgress: Double {
		let bytesGGUF = items.reduce(0.0) {
			let expected = max(Int64(1), $1.mainExpectedBytes + $1.mmprojSize + $1.imatrixSize)
			return $0 + Double(expected)
		}
                let bytesSLM  = leapItems.reduce(0.0) { acc, li in
                        let expected = li.expectedBytes > 0
                                ? li.expectedBytes
                                : (li.entry.sizeBytes > 0 ? li.entry.sizeBytes : 1)
                        return acc + Double(expected)
                }
                let bytesDS   = datasetItems.reduce(0.0) { res, item in
                        let expected = item.expectedBytes > 0 ? Double(item.expectedBytes) :
                                Double(DatasetFileSupport.totalSupportedSize(files: item.detail.files))
                        return res + expected
                }
		// Include embedding model downloads in aggregation; fallback to weight=1 when expected unknown
			let bytesEMB  = embeddingItems.reduce(0.0) { res, item in
				let expected = item.expectedBytes > 0 ? Double(item.expectedBytes) : 1.0
				return res + expected
			}
            let bytesWhisper = whisperItems.reduce(0.0) { res, item in
                let expected = item.expectedBytes > 0 ? Double(item.expectedBytes) : 1.0
                return res + expected
            }
			let total = bytesGGUF + bytesSLM + bytesDS + bytesEMB + bytesWhisper
		guard total > 0 else { return 0 }
		let completedGGUF = items.reduce(0.0) {
			let written = $1.mainBytesWritten + $1.mmprojBytesWritten + $1.imatrixBytesWritten
			return $0 + Double(written)
		}
                let completedSLM  = leapItems.reduce(0.0) { acc, li in
                        let expected = li.expectedBytes > 0
                                ? li.expectedBytes
                                : (li.entry.sizeBytes > 0 ? li.entry.sizeBytes : 1)
                        return acc + Double(expected) * li.progress
                }
                let completedDS   = datasetItems.reduce(0.0) { res, item in
                        let expected = item.expectedBytes > 0 ? Double(item.expectedBytes) :
                                Double(DatasetFileSupport.totalSupportedSize(files: item.detail.files))
                        let done = item.expectedBytes > 0 ? Double(item.downloadedBytes) : expected * item.progress
                        return res + done
                }
			let completedEMB = embeddingItems.reduce(0.0) { res, item in
				let expected = item.expectedBytes > 0 ? Double(item.expectedBytes) : 1.0
				return res + expected * item.progress
			}
            let completedWhisper = whisperItems.reduce(0.0) { res, item in
                let expected = item.expectedBytes > 0 ? Double(item.expectedBytes) : 1.0
                return res + expected * item.progress
            }
			return (completedGGUF + completedSLM + completedDS + completedEMB + completedWhisper) / total
		}

		var allItems: [Any] {
			return items as [Any] + leapItems as [Any] + datasetItems as [Any] + embeddingItems as [Any] + whisperItems as [Any]
		}

		var allCompleted: Bool {
			!allItems.isEmpty && items.allSatisfy({ $0.completed }) && leapItems.allSatisfy({ $0.completed }) && datasetItems.allSatisfy({ $0.completed }) && embeddingItems.allSatisfy({ $0.completed }) && whisperItems.allSatisfy({ $0.completed })
		}

	// Aggregation for embedding progress (bytes)
	private var embedTotalBytes: Double = 0
	private var embedCompletedBytes: Double = 0

    nonisolated static func datasetBaseDir(for datasetID: String) -> URL {
		var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		url.appendPathComponent("LocalLLMDatasets", isDirectory: true)
		for comp in datasetID.split(separator: "/").map(String.init) {
			url.appendPathComponent(comp, isDirectory: true)
		}
        return url
    }

    nonisolated static func datasetRelativePath(for file: DatasetFile) -> String {
        let fallback = file.downloadURL.lastPathComponent
        let raw = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.isEmpty ? fallback : raw
        let normalized = DatasetPathing.normalizeRelativePath(candidate)
        return normalized.isEmpty ? DatasetPathing.normalizeRelativePath(fallback) : normalized
    }

    nonisolated static func datasetDestinationURL(for datasetID: String, relativePath: String) -> URL {
        DatasetPathing.destinationURL(for: relativePath, in: datasetBaseDir(for: datasetID))
    }

    nonisolated static func datasetArtifactID(relativePath: String) -> String {
        DatasetPathing.durableArtifactID(forDatasetRelativePath: relativePath)
    }

    nonisolated static func stagingURL(for finalURL: URL) -> URL {
        finalURL.appendingPathExtension("download")
    }
}

extension DownloadController {
    nonisolated static func shouldBlockAutoResume(hasInMemoryTask: Bool, hasLiveTask: Bool) -> Bool {
        hasInMemoryTask || hasLiveTask
    }

    nonisolated static func aggregateModelProgress(mainWritten: Int64,
                                                   mainExpected: Int64,
                                                   projectorWritten: Int64,
                                                   projectorExpected: Int64,
                                                   imatrixWritten: Int64,
                                                   imatrixExpected: Int64) -> Double {
        let totalExpected = max(Int64(1), mainExpected + projectorExpected + imatrixExpected)
        let totalWritten = max(Int64(0), mainWritten + projectorWritten + imatrixWritten)
        return min(1, max(0, Double(totalWritten) / Double(totalExpected)))
    }

    nonisolated static func stateAfterLiveSnapshot(current: DownloadJobState, manualPause: Bool) -> DownloadJobState {
        if current == .scheduled {
            return .scheduled
        }
        if manualPause {
            return .paused
        }
        switch current {
        case .queued, .preparing, .failed:
            return .downloading
        default:
            return current
        }
    }

	    private enum DurableArtifactID {
	        static let main = "main"
	        static let projector = "projector"
	        static let importanceMatrix = "imatrix"
            static let mtp = "mtp"
	        static let leapBundle = "bundle"
	        static let embedding = "embedding"
            static let whisper = "whisper"

        static func shard(_ relativePath: String) -> String {
            "shard:\(relativePath)"
        }

        static func dataset(_ relativePath: String) -> String {
            DatasetPathing.durableArtifactID(forDatasetRelativePath: relativePath)
        }

        static func leapAsset(_ name: String) -> String {
            "leap:\(name)"
        }
    }

    func bootstrapIfNeeded() {
        if hasBootstrappedDownloads {
            Task { @MainActor [weak self] in
                await self?.reattachActiveBackgroundObservers()
                await self?.reconcileLiveBackgroundSnapshots()
                await self?.resumeRecoverableJobsFromEngine()
            }
            return
        }
        hasBootstrappedDownloads = true
        Task { @MainActor [weak self] in
            await DownloadEngine.shared.bootstrap()
            _ = await self?.runDownloadMaintenance(manual: false, force: true)
            await self?.reattachActiveBackgroundObservers()
            await self?.reconcileLiveBackgroundSnapshots()
            await self?.resumeRecoverableJobsFromEngine()
        }
    }

    private func applyBackgroundNotificationToEngine(destinationURL: URL?,
                                                     jobID: String?,
                                                     artifactID: String?,
                                                     errorMessage: String?) async {
        let job: DownloadJob?
        if let jobID {
            job = await DownloadEngine.shared.job(id: jobID)
        } else if let destinationURL {
            job = await DownloadEngine.shared.job(matching: destinationURL)
        } else {
            job = nil
        }

        guard let job else { return }

        if let errorMessage {
            if let artifactID {
                await DownloadEngine.shared.updateArtifactState(
                    externalID: job.externalID,
                    artifactID: artifactID,
                    state: job.manualPause ? .paused : .failed,
                    errorMessage: errorMessage,
                    manualPause: job.manualPause
                )
            } else {
                await DownloadEngine.shared.updateJobState(
                    externalID: job.externalID,
                    state: job.manualPause ? .paused : .failed,
                    manualPause: job.manualPause,
                    errorMessage: errorMessage
                )
            }
            return
        }

        guard let destinationURL else { return }
        if let artifact = job.artifacts.first(where: {
            $0.stagingURL.path == destinationURL.path || $0.finalURL.path == destinationURL.path || $0.id == artifactID
        }) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
            await DownloadEngine.shared.markArtifactCompleted(
                externalID: job.externalID,
                artifactID: artifact.id,
                finalBytes: bytes
            )
            if let refreshed = await DownloadEngine.shared.job(forExternalID: job.externalID),
               refreshed.artifacts.allSatisfy({ $0.state == .completed }) {
                await DownloadEngine.shared.updateJobState(externalID: job.externalID, state: .finalizing)
            }
        }
    }

    private func refreshFromEngineSnapshot() async {
        let jobs = await DownloadEngine.shared.snapshots().filter {
            $0.state != .cancelled && !cancelledExternalIDs.contains($0.externalID)
        }
        let existingModels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let existingLeap = Dictionary(uniqueKeysWithValues: leapItems.map { ($0.id, $0) })
        let existingDatasets = Dictionary(uniqueKeysWithValues: datasetItems.map { ($0.id, $0) })
        let existingEmbeddings = Dictionary(uniqueKeysWithValues: embeddingItems.map { ($0.id, $0) })
        let existingWhisper = Dictionary(uniqueKeysWithValues: whisperItems.map { ($0.id, $0) })

        var newItems: [Item] = []
        var newLeapItems: [LeapItem] = []
        var newDatasetItems: [DatasetItem] = []
        var newEmbeddingItems: [EmbeddingItem] = []
        var newWhisperItems: [WhisperItem] = []
        var newPaused: Set<String> = []

        for job in jobs {
            var job = job
            // Overlay locally-recorded pause intent: the engine may not have persisted the
            // user's pause yet, and surfacing the stale "downloading" state makes the
            // pause/resume buttons flicker. manualPause drives status, canPause and canResume.
            if pauseRequestedIDs.contains(job.externalID), job.state != .completed {
                job.manualPause = true
            }
            switch job.owner {
            case .model(let owner):
                var item = existingModels[job.externalID] ?? Item(detail: owner.detail, quant: owner.quant)
                item.jobID = job.id
                item.status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
                item.canPause = job.canPause
                item.canResume = job.canResume
                item.completed = job.state == .completed
                item.error = job.state == .failed ? .permanentError(job.lastErrorDescription ?? "Download failed") : nil
                applyModelArtifacts(job.artifacts, to: &item)
                newItems.append(item)
            case .leap(let owner):
                var item = existingLeap[job.externalID] ?? LeapItem(entry: owner.entry)
                item.jobID = job.id
                item.status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
                item.canPause = job.canPause
                item.canResume = job.canResume
                item.completed = job.state == .completed
                let total = max(job.totalExpectedBytes, Int64(owner.entry.sizeBytes))
                if total > 0 {
                    item.expectedBytes = total
                    item.progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(total)))
                }
                if job.state == .completed { item.progress = 1 }
                newLeapItems.append(item)
            case .dataset(let owner):
                var item = existingDatasets[job.externalID] ?? DatasetItem(detail: owner.detail)
                item.jobID = job.id
                item.status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
                item.canPause = job.canPause
                item.canResume = job.canResume
                item.completed = job.state == .completed
                item.error = job.state == .failed ? .permanentError(job.lastErrorDescription ?? "Download failed") : nil
                item.expectedBytes = job.totalExpectedBytes
                item.downloadedBytes = job.totalDownloadedBytes
                if item.expectedBytes > 0 {
                    item.progress = min(1, max(0, Double(item.downloadedBytes) / Double(item.expectedBytes)))
                }
                if job.state == .completed { item.progress = 1 }
                newDatasetItems.append(item)
            case .embedding(let owner):
                var item = existingEmbeddings[job.externalID] ?? EmbeddingItem(repoID: owner.externalID)
                item.jobID = job.id
                item.status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
                item.canPause = job.canPause
                item.canResume = job.canResume
                item.completed = job.state == .completed
                item.error = job.state == .failed ? .permanentError(job.lastErrorDescription ?? "Download failed") : nil
                item.expectedBytes = job.totalExpectedBytes
                if item.expectedBytes > 0 {
                    item.progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(item.expectedBytes)))
                }
                if job.state == .completed { item.progress = 1 }
                newEmbeddingItems.append(item)
            case .whisper(let owner):
                let record = WhisperModelCatalog.record(for: owner.recordID)
                var item = existingWhisper[job.externalID] ?? record.map { WhisperItem(record: $0, runtime: owner.runtime) } ?? WhisperItem(
                    record: WhisperModelRecord(
                        id: owner.recordID,
                        displayName: owner.recordID,
                        sizeTier: "",
                        summary: "",
                        multilingual: true,
                        defaultLocale: "auto",
                        isRecommended: false,
                        artifacts: []
                    ),
                    runtime: owner.runtime
                )
                item.jobID = job.id
                item.status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
                item.canPause = job.canPause
                item.canResume = job.canResume
                item.completed = job.state == .completed
                item.error = job.state == .failed ? .permanentError(job.lastErrorDescription ?? "Download failed") : nil
                item.expectedBytes = job.totalExpectedBytes
                item.downloadedBytes = job.totalDownloadedBytes
                if item.expectedBytes > 0 {
                    item.progress = min(1, max(0, Double(item.downloadedBytes) / Double(item.expectedBytes)))
                }
                if job.state == .completed { item.progress = 1 }
                newWhisperItems.append(item)
            }
            if job.manualPause {
                newPaused.insert(job.externalID)
            }
        }

        items = newItems
        leapItems = newLeapItems
        datasetItems = newDatasetItems
        embeddingItems = newEmbeddingItems
        whisperItems = newWhisperItems
        paused = newPaused
        if allItems.isEmpty {
            showOverlay = false
        } else {
            showOverlay = true
        }
        autoFinalizeCompletedOnDisk()
        updateWakeLock()
    }

    private func applyModelArtifacts(_ artifacts: [DownloadArtifact], to item: inout Item) {
        let mainArtifacts = artifacts.filter { $0.role == .mainWeights || $0.role == .weightShard }
        let projector = artifacts.first(where: { $0.role == .projector })
        let imatrix = artifacts.first(where: { $0.role == .importanceMatrix })

        item.mainExpectedBytes = mainArtifacts.reduce(0) { partial, artifact in
            partial + max(artifact.expectedBytes ?? 0, artifact.downloadedBytes)
        }
        item.mainBytesWritten = mainArtifacts.reduce(0) { $0 + max(0, $1.downloadedBytes) }
        if item.mainExpectedBytes > 0 {
            item.mainProgress = min(1, max(0, Double(item.mainBytesWritten) / Double(item.mainExpectedBytes)))
        }

        if let projector {
            item.mmprojSize = max(projector.expectedBytes ?? 0, projector.downloadedBytes)
            item.mmprojBytesWritten = max(0, projector.downloadedBytes)
            item.mmprojProgress = item.mmprojSize > 0 ? min(1, max(0, Double(item.mmprojBytesWritten) / Double(item.mmprojSize))) : 0
            item.mmprojDestination = projector.state == .completed ? nil : projector.stagingURL
            item.mmprojFilename = projector.finalURL.lastPathComponent
        } else {
            item.mmprojDestination = nil
        }

        if let imatrix {
            item.imatrixSize = max(imatrix.expectedBytes ?? 0, imatrix.downloadedBytes)
            item.imatrixBytesWritten = max(0, imatrix.downloadedBytes)
            item.imatrixProgress = item.imatrixSize > 0 ? min(1, max(0, Double(item.imatrixBytesWritten) / Double(item.imatrixSize))) : 0
            item.imatrixDestination = imatrix.state == .completed ? nil : imatrix.stagingURL
            item.imatrixPath = item.imatrixPath ?? item.quant.importanceMatrix?.path
        } else {
            item.imatrixDestination = nil
        }

        let totalExpected = max(1, item.mainExpectedBytes + item.mmprojSize + item.imatrixSize)
        let totalWritten = item.mainBytesWritten + item.mmprojBytesWritten + item.imatrixBytesWritten
        item.progress = min(1, max(0, Double(totalWritten) / Double(totalExpected)))
        if totalWritten > 0,
           item.status != .paused,
           item.status != .failed,
           item.status != .scheduled,
           item.status != .completed,
           item.status != .verifying,
           item.status != .finalizing {
            item.status = .downloading
        }

        if item.status == .paused || item.status == .failed || item.status == .completed {
            item.speed = 0
            item.mainSpeed = 0
            item.mmprojSpeed = 0
            item.imatrixSpeed = 0
        }
    }

    private func applyLiveProgressToVisibleState(externalID: String) async {
        guard var job = await DownloadEngine.shared.job(forExternalID: externalID) else { return }
        if pauseRequestedIDs.contains(externalID), job.state != .completed {
            job.manualPause = true
        }
        switch job.owner {
        case .model:
            guard let idx = items.firstIndex(where: { $0.id == externalID }) else { return }
            var item = items[idx]
            item.status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
            item.canPause = job.canPause
            item.canResume = job.canResume
            if item.status != .failed {
                item.error = nil
            }
            applyModelArtifacts(job.artifacts, to: &item)
            items[idx] = item
        case .leap:
            guard let idx = leapItems.firstIndex(where: { $0.id == externalID }) else { return }
            leapItems[idx].status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
            leapItems[idx].canPause = job.canPause
            leapItems[idx].canResume = job.canResume
            let total = max(job.totalExpectedBytes, Int64(leapItems[idx].entry.sizeBytes), 1)
            leapItems[idx].expectedBytes = total
            leapItems[idx].progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(total)))
        case .dataset:
            guard let idx = datasetItems.firstIndex(where: { $0.id == externalID }) else { return }
            datasetItems[idx].status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
            datasetItems[idx].canPause = job.canPause
            datasetItems[idx].canResume = job.canResume
            datasetItems[idx].expectedBytes = job.totalExpectedBytes
            datasetItems[idx].downloadedBytes = job.totalDownloadedBytes
            if job.totalExpectedBytes > 0 {
                datasetItems[idx].progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(job.totalExpectedBytes)))
            }
        case .embedding:
            guard let idx = embeddingItems.firstIndex(where: { $0.id == externalID }) else { return }
            embeddingItems[idx].status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
            embeddingItems[idx].canPause = job.canPause
            embeddingItems[idx].canResume = job.canResume
            embeddingItems[idx].expectedBytes = max(job.totalExpectedBytes, embeddingItems[idx].expectedBytes)
            let total = max(embeddingItems[idx].expectedBytes, 1)
            embeddingItems[idx].progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(total)))
        case .whisper:
            guard let idx = whisperItems.firstIndex(where: { $0.id == externalID }) else { return }
            whisperItems[idx].status = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
            whisperItems[idx].canPause = job.canPause
            whisperItems[idx].canResume = job.canResume
            whisperItems[idx].expectedBytes = max(job.totalExpectedBytes, whisperItems[idx].expectedBytes)
            whisperItems[idx].downloadedBytes = job.totalDownloadedBytes
            let total = max(whisperItems[idx].expectedBytes, 1)
            whisperItems[idx].progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(total)))
        }
    }

    private func reattachActiveBackgroundObservers() async {
        let jobs = await DownloadEngine.shared.snapshots()
        for job in jobs {
            for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled && artifact.state != .failed {
                let isLive = await BackgroundDownloadManager.shared.hasLiveTask(for: artifact.destinationURL)
                guard isLive else { continue }
                BackgroundDownloadManager.shared.attachObservers(
                    jobID: job.id,
                    artifactID: artifact.id,
                    destination: artifact.destinationURL,
                    expectedSize: artifact.expectedBytes,
                    progress: nil,
                    progressBytes: { [weak self] written, expected in
                        Task { @MainActor [weak self] in
                            await DownloadEngine.shared.updateArtifactProgressLive(
                                externalID: job.externalID,
                                artifactID: artifact.id,
                                written: written,
                                expected: expected > 0 ? expected : artifact.expectedBytes
                            )
                            await self?.applyLiveProgressToVisibleState(externalID: job.externalID)
                        }
                    },
                    completion: { [weak self] result in
                        Task { @MainActor [weak self] in
                            switch result {
                            case .success(let destination):
                                let finalBytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
                                await DownloadEngine.shared.markArtifactCompleted(
                                    externalID: job.externalID,
                                    artifactID: artifact.id,
                                    finalBytes: finalBytes
                                )
                                await self?.handleBackgroundDownloadCompletion(destinationURL: destination, errorMessage: nil)
                            case .failure(let error):
                                await DownloadEngine.shared.updateArtifactState(
                                    externalID: job.externalID,
                                    artifactID: artifact.id,
                                    state: job.manualPause ? .paused : .failed,
                                    errorMessage: (error as NSError).localizedDescription,
                                    manualPause: job.manualPause
                                )
                            }
                            await self?.refreshFromEngineSnapshot()
                            await self?.resumeRecoverableJobsFromEngine()
                        }
                    }
                )
            }
        }
    }

    private func reconcileLiveBackgroundSnapshots() async {
        let snapshots = await BackgroundDownloadManager.shared.snapshots()
        for snapshot in snapshots where snapshot.hasLiveTask {
            guard let jobID = snapshot.jobID,
                  let artifactID = snapshot.artifactID,
                  let job = await DownloadEngine.shared.job(id: jobID) else {
                continue
            }

            await logger.log(
                "[Download][Snapshot] jobID=\(jobID) artifactID=\(artifactID) bytesReceived=\(snapshot.bytesReceived) resumeOffset=\(snapshot.resumeOffset) normalizedWritten=\(snapshot.writtenTotal) normalizedExpected=\(snapshot.fullExpected ?? 0)"
            )

            await DownloadEngine.shared.updateArtifactProgress(
                externalID: job.externalID,
                artifactID: artifactID,
                written: snapshot.writtenTotal,
                expected: snapshot.fullExpected
            )

            let reconciledState = Self.stateAfterLiveSnapshot(current: job.state, manualPause: job.manualPause)
            if reconciledState != job.state {
                await DownloadEngine.shared.updateJobState(
                    externalID: job.externalID,
                    state: reconciledState,
                    manualPause: job.manualPause
                )
            }
        }
        await refreshFromEngineSnapshot()
    }

    private func resumeRecoverableJobsFromEngine() async {
        let jobs = await DownloadEngine.shared.autoResumableJobs()
        for job in jobs {
            if cancelledExternalIDs.contains(job.externalID) { continue }
            let hasInMemoryTask = tasks[job.externalID] != nil
            let hasLiveTask = await hasLiveBackgroundTask(for: job)
            if Self.shouldBlockAutoResume(hasInMemoryTask: hasInMemoryTask, hasLiveTask: hasLiveTask) {
                if hasLiveTask {
                    await logger.log("[Download][Resume] skip externalID=\(job.externalID) reason=live-task")
                }
                continue
            }
            switch job.owner {
            case .model(let owner):
                start(detail: owner.detail, quant: owner.quant)
            case .leap(let owner):
                startLeap(entry: owner.entry)
            case .dataset(let owner):
                startDataset(detail: owner.detail)
            case .embedding(let owner):
                let recordID = EmbeddingModelCatalog.record(matchingDownloadIdentifier: owner.externalID)?.id ?? owner.externalID
                startEmbedding(recordID: recordID)
            case .whisper(let owner):
                startWhisper(recordID: owner.recordID, runtime: owner.runtime)
            }
        }
    }

    private func resumeScheduledJobsFromEngine() async {
        let jobs = await DownloadEngine.shared.scheduledJobs()
        guard !jobs.isEmpty else { return }

        let scheduleEnvironment = currentScheduleEnvironment()
        guard Self.shouldResumeScheduledDownloads(environment: scheduleEnvironment) else {
            await logger.log("[Download][Schedule] hold scheduled downloads overnight=\(DownloadSchedulePolicy.isOvernight(scheduleEnvironment.date, calendar: scheduleEnvironment.calendar)) charging=\(scheduleEnvironment.isCharging) wifi=\(scheduleEnvironment.isOnWiFi)")
            return
        }

        for job in jobs {
            if cancelledExternalIDs.contains(job.externalID) { continue }
            let hasInMemoryTask = tasks[job.externalID] != nil
            let hasLiveTask = await hasLiveBackgroundTask(for: job)
            if Self.shouldBlockAutoResume(hasInMemoryTask: hasInMemoryTask, hasLiveTask: hasLiveTask) {
                continue
            }
            pauseRequestedIDs.remove(job.externalID)
            paused.remove(job.externalID)
            await DownloadEngine.shared.updateJobState(externalID: job.externalID, state: .queued, manualPause: false)
            switch job.owner {
            case .model(let owner):
                start(detail: owner.detail, quant: owner.quant)
            case .leap(let owner):
                startLeap(entry: owner.entry)
            case .dataset(let owner):
                startDataset(detail: owner.detail)
            case .embedding(let owner):
                let recordID = EmbeddingModelCatalog.record(matchingDownloadIdentifier: owner.externalID)?.id ?? owner.externalID
                startEmbedding(recordID: recordID)
            case .whisper(let owner):
                startWhisper(recordID: owner.recordID, runtime: owner.runtime)
            }
        }
    }

    nonisolated static func shouldResumeScheduledDownloads(environment: DownloadSchedulePolicy.Environment) -> Bool {
        DownloadSchedulePolicy.canResumeScheduledDownloads(in: environment)
    }

    private func startScheduleConditionMonitoring() {
        let monitor = NWPathMonitor()
        schedulePathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleNetworkPath = path
                await self.resumeScheduledJobsFromEngine()
            }
        }
        monitor.start(queue: scheduleNetworkQueue)
    }

    private func currentScheduleEnvironment(now: Date = Date()) -> DownloadSchedulePolicy.Environment {
        DownloadSchedulePolicy.Environment(
            date: now,
            calendar: .current,
            isCharging: Self.isDeviceChargingForScheduledDownloads(),
            isOnWiFi: Self.isWiFiPath(scheduleNetworkPath)
        )
    }

    private static func isWiFiPath(_ path: NWPath?) -> Bool {
        guard let path, path.status == .satisfied else { return false }
        return path.usesInterfaceType(.wifi)
    }

    private static func isDeviceChargingForScheduledDownloads() -> Bool {
#if canImport(UIKit) && !os(visionOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .charging, .full:
            return true
        case .unplugged, .unknown:
            return false
        @unknown default:
            return false
        }
#else
        return true
#endif
    }

    private func hasLiveBackgroundTask(for job: DownloadJob) async -> Bool {
        for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
            if await BackgroundDownloadManager.shared.hasLiveTask(for: artifact.destinationURL) {
                return true
            }
        }
        return false
    }

    func runDownloadMaintenance(manual: Bool, force: Bool = false) async -> MaintenanceResult {
        let now = Date()
        if !manual && !force,
           let lastAutomaticMaintenanceAt,
           now.timeIntervalSince(lastAutomaticMaintenanceAt) < automaticMaintenanceInterval {
            return MaintenanceResult()
        }
        if !manual {
            lastAutomaticMaintenanceAt = now
        }

        let fm = FileManager.default
        let liveTaskPaths = Set((await BackgroundDownloadManager.shared.snapshots())
            .filter(\.hasLiveTask)
            .map { $0.destination.standardizedFileURL.path })
        let jobs = await DownloadEngine.shared.snapshots()
        var referencedStagingPaths = Set<String>()
        var validResumePaths = Set<String>()
        var repairedCompletionURLs: [URL] = []
        var result = MaintenanceResult()

        for job in jobs {
            for artifact in job.artifacts {
                referencedStagingPaths.insert(artifact.stagingURL.standardizedFileURL.path)
                validResumePaths.insert(
                    DownloadPersistencePaths.resumeDataURL(jobID: job.id, artifactID: artifact.id)
                        .standardizedFileURL.path
                )
            }
        }

            for job in jobs {
            var shouldRemoveJob = job.state != .completed
            var repairedJob = false

            for artifact in job.artifacts {
                let stagePath = artifact.stagingURL.standardizedFileURL.path
                let finalPath = artifact.finalURL.standardizedFileURL.path
                let hasStage = fm.fileExists(atPath: stagePath)
                let hasFinal = fm.fileExists(atPath: finalPath)
                let hasLiveTask = liveTaskPaths.contains(stagePath)
                let resumeURL = DownloadPersistencePaths.resumeDataURL(jobID: job.id, artifactID: artifact.id)
                let hasResumeData = fm.fileExists(atPath: resumeURL.path)
                let shouldPreserve = job.manualPause || job.state.autoResumeEligible || hasLiveTask || hasResumeData

                if hasFinal {
                    shouldRemoveJob = false
                    if artifact.state != .completed {
                        let finalBytes = fileSize(at: artifact.finalURL) ?? 0
                        await DownloadEngine.shared.markArtifactCompleted(
                            externalID: job.externalID,
                            artifactID: artifact.id,
                            finalBytes: finalBytes
                        )
                        result.repairedArtifacts += 1
                        repairedJob = true
                    }
                    continue
                }

                if hasStage || hasLiveTask || hasResumeData || artifact.state == .completed {
                    shouldRemoveJob = false
                }

                if (job.state == .cancelled || job.state == .failed) && hasStage && !shouldPreserve {
                    try? fm.removeItemIfExists(at: artifact.stagingURL)
                    result.removedOrphanFiles += 1
                }
            }

            if job.state == .completed || job.artifacts.allSatisfy({ $0.state == .completed }) {
                shouldRemoveJob = true
            }

            if repairedJob,
               let completionURL = job.artifacts
                .map(\.finalURL)
                .first(where: { fm.fileExists(atPath: $0.path) }) {
                repairedCompletionURLs.append(completionURL)
            }

            if shouldRemoveJob {
                await DownloadEngine.shared.removeJob(externalID: job.externalID)
                result.removedJobs += 1
            }
        }

        if let resumeFiles = try? fm.contentsOfDirectory(
            at: DownloadPersistencePaths.resumeDataDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in resumeFiles {
                let path = file.standardizedFileURL.path
                guard !validResumePaths.contains(path) else { continue }
                try? fm.removeItem(at: file)
                result.removedResumeData += 1
            }
        }

        for root in maintenanceRoots() {
            guard fm.fileExists(atPath: root.path) else { continue }
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension.lowercased() == "download" else { continue }
                let path = file.standardizedFileURL.path
                guard !referencedStagingPaths.contains(path) else { continue }
                guard !liveTaskPaths.contains(path) else { continue }
                try? fm.removeItem(at: file)
                result.removedOrphanFiles += 1
            }
        }

        let activeDownloadPaths = referencedStagingPaths.union(liveTaskPaths)
        let storageCleanup = ModelStorageCleanup.pruneOrphanedModelDirectories(
            installedModels: InstalledModelsStore().all(),
            activeDownloadURLs: activeDownloadPaths
        )
        result.removedOrphanFiles += storageCleanup.removedFiles + storageCleanup.removedDirectories + storageCleanup.removedDownloadArtifacts

        await refreshFromEngineSnapshot()
        for url in repairedCompletionURLs {
            await handleBackgroundDownloadCompletion(destinationURL: url, errorMessage: nil)
            result.repairedCompletions += 1
        }
        await refreshFromEngineSnapshot()
        await logger.log(
            "[Download][Maintenance] manual=\(manual) removedFiles=\(result.removedOrphanFiles) removedResume=\(result.removedResumeData) removedJobs=\(result.removedJobs) repairedArtifacts=\(result.repairedArtifacts) repairedCompletions=\(result.repairedCompletions)"
        )
        return result
    }

    private func maintenanceRoots() -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [
            documents.appendingPathComponent("LocalLLMModels", isDirectory: true),
            documents.appendingPathComponent("LocalLLMDatasets", isDirectory: true)
        ]
    }

    private func updateWakeLock() {
#if canImport(UIKit) && !os(visionOS)
        let hasActive = items.contains(where: { isWakeLockStatus($0.status) }) ||
            leapItems.contains(where: { isWakeLockStatus($0.status) }) ||
            datasetItems.contains(where: { isWakeLockStatus($0.status) }) ||
            embeddingItems.contains(where: { isWakeLockStatus($0.status) })
        let isSceneActive = UIApplication.shared.applicationState == .active
        ForegroundDownloadWakeLock.shared.update(hasActiveForegroundDownloads: hasActive, isSceneActive: isSceneActive)
#else
        ForegroundDownloadWakeLock.shared.update(hasActiveForegroundDownloads: false, isSceneActive: false)
#endif
    }

    private func isWakeLockStatus(_ status: DownloadJobState) -> Bool {
        switch status {
        case .queued, .preparing, .downloading, .waitingForConnectivity, .retrying, .verifying, .finalizing:
            return true
        case .scheduled, .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    private func setAllArtifacts(externalID: String,
                                 state: DownloadArtifactState,
                                 manualPause: Bool? = nil,
                                 errorMessage: String? = nil) async {
        guard let job = await DownloadEngine.shared.job(forExternalID: externalID) else { return }
        for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
            await DownloadEngine.shared.updateArtifactState(
                externalID: externalID,
                artifactID: artifact.id,
                state: state,
                retryCount: artifact.retryCount,
                errorMessage: errorMessage,
                manualPause: manualPause
            )
        }
    }

    private func scheduleJobRemoval(externalID: String, delay seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await DownloadEngine.shared.removeJob(externalID: externalID)
            await self?.refreshFromEngineSnapshot()
        }
    }

    private func modelJobArtifacts(detail: ModelDetails, quant: QuantInfo) -> [DownloadArtifact] {
        let baseDir = InstalledModelsStore.baseDir(for: quant.format, modelID: detail.id)
        let mainArtifacts: [DownloadArtifact] = quant.isMultipart
            ? quant.allRelativeDownloadPaths.map { relativePath in
                let finalURL = baseDir.appendingPathComponent(relativePath)
                return DownloadArtifact(
                    id: DurableArtifactID.shard(relativePath),
                    role: .weightShard,
                    remoteURL: quant.allDownloadParts.first(where: {
                        QuantInfo.relativeDownloadPath(path: $0.path, fallbackURL: $0.downloadURL) == relativePath
                    })?.downloadURL,
                    stagingURL: Self.stagingURL(for: finalURL),
                    finalURL: finalURL,
                    expectedBytes: quant.allDownloadParts.first(where: {
                        QuantInfo.relativeDownloadPath(path: $0.path, fallbackURL: $0.downloadURL) == relativePath
                    })?.sizeBytes,
                    downloadedBytes: 0,
                    checksum: quant.allDownloadParts.first(where: {
                        QuantInfo.relativeDownloadPath(path: $0.path, fallbackURL: $0.downloadURL) == relativePath
                    })?.sha256,
                    state: .queued,
                    retryCount: 0,
                    nextRetryAt: nil,
                    lastErrorDescription: nil,
                    manualPause: false
                )
            }
            : [
                {
                    let finalURL = baseDir.appendingPathComponent(quant.primaryDownloadRelativePath)
                    return DownloadArtifact(
                        id: DurableArtifactID.main,
                        role: .mainWeights,
                        remoteURL: quant.downloadURL,
                        stagingURL: Self.stagingURL(for: finalURL),
                        finalURL: finalURL,
                        expectedBytes: quant.sizeBytes,
                        downloadedBytes: 0,
                        checksum: quant.sha256,
                        state: .queued,
                        retryCount: 0,
                        nextRetryAt: nil,
                        lastErrorDescription: nil,
                        manualPause: false
                    )
                }()
            ]

        var artifacts = mainArtifacts
        if let imatrix = quant.importanceMatrix {
            let relative = imatrix.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalURL = baseDir.appendingPathComponent(relative)
            artifacts.append(
                DownloadArtifact(
                    id: DurableArtifactID.importanceMatrix,
                    role: .importanceMatrix,
                    remoteURL: imatrix.downloadURL,
                    stagingURL: Self.stagingURL(for: finalURL),
                    finalURL: finalURL,
                    expectedBytes: imatrix.sizeBytes,
                    downloadedBytes: 0,
                    checksum: imatrix.sha256,
                    state: .queued,
                    retryCount: 0,
                    nextRetryAt: nil,
                    lastErrorDescription: nil,
                    manualPause: false
                )
            )
        }
        if let mtp = quant.mtp {
            let relative = QuantInfo.relativeDownloadPath(path: mtp.path, fallbackURL: mtp.downloadURL)
            let finalURL = baseDir.appendingPathComponent(relative)
            artifacts.append(
                DownloadArtifact(
                    id: DurableArtifactID.mtp,
                    role: .mtp,
                    remoteURL: mtp.downloadURL,
                    stagingURL: Self.stagingURL(for: finalURL),
                    finalURL: finalURL,
                    expectedBytes: mtp.sizeBytes,
                    downloadedBytes: 0,
                    checksum: mtp.sha256,
                    state: .queued,
                    retryCount: 0,
                    nextRetryAt: nil,
                    lastErrorDescription: nil,
                    manualPause: false
                )
            )
        }
        return artifacts
    }

    private func ensureModelJob(detail: ModelDetails, quant: QuantInfo) async -> DownloadJob {
        await DownloadEngine.shared.upsertJob(
            owner: .model(ModelDownloadOwner(detail: detail, quant: quant)),
            artifacts: modelJobArtifacts(detail: detail, quant: quant),
            state: .preparing
        )
    }

    private func ensureProjectorArtifact(detail: ModelDetails,
                                         quant: QuantInfo,
                                         filename: String,
                                         remoteURL: URL,
                                         expectedBytes: Int64) async -> DownloadJob {
        let baseDir = InstalledModelsStore.baseDir(for: quant.format, modelID: detail.id)
        let finalURL = baseDir.appendingPathComponent(filename)
        let artifact = DownloadArtifact(
            id: DurableArtifactID.projector,
            role: .projector,
            remoteURL: remoteURL,
            stagingURL: Self.stagingURL(for: finalURL),
            finalURL: finalURL,
            expectedBytes: expectedBytes > 0 ? expectedBytes : nil,
            downloadedBytes: 0,
            checksum: nil,
            state: .queued,
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorDescription: nil,
            manualPause: false
        )
        return await DownloadEngine.shared.upsertJob(
            owner: .model(ModelDownloadOwner(detail: detail, quant: quant)),
            artifacts: modelJobArtifacts(detail: detail, quant: quant) + [artifact],
            state: .preparing
        )
    }

    private func ensureDatasetJob(detail: DatasetDetails, files: [DatasetFile]) async -> DownloadJob {
        let baseDir = Self.datasetBaseDir(for: detail.id)
        let artifacts: [DownloadArtifact] = files.map { file in
            let relativePath = Self.datasetRelativePath(for: file)
            let finalURL = DatasetPathing.destinationURL(for: relativePath, in: baseDir)
            return DownloadArtifact(
                id: DurableArtifactID.dataset(relativePath),
                role: .datasetFile,
                remoteURL: file.downloadURL,
                stagingURL: Self.stagingURL(for: finalURL),
                finalURL: finalURL,
                expectedBytes: file.sizeBytes > 0 ? file.sizeBytes : nil,
                downloadedBytes: 0,
                checksum: nil,
                state: .queued,
                retryCount: 0,
                nextRetryAt: nil,
                lastErrorDescription: nil,
                manualPause: false
            )
        }
        return await DownloadEngine.shared.upsertJob(
            owner: .dataset(DatasetDownloadOwner(detail: detail)),
            artifacts: artifacts,
            state: .queued
        )
    }

	    private func ensureEmbeddingJob(record: EmbeddingModelRecord, artifact embeddingArtifact: EmbeddingModelArtifact) async -> DownloadJob {
        let finalURL = embeddingArtifact.localURL(recordID: record.id)
        let artifact = DownloadArtifact(
            id: DurableArtifactID.embedding,
            role: .embeddingModel,
            remoteURL: embeddingArtifact.downloadURL,
            stagingURL: Self.stagingURL(for: finalURL),
            finalURL: finalURL,
            expectedBytes: embeddingArtifact.sizeBytes > 0 ? embeddingArtifact.sizeBytes : nil,
            downloadedBytes: 0,
            checksum: nil,
            state: .queued,
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorDescription: nil,
            manualPause: false
        )
        return await DownloadEngine.shared.upsertJob(
            owner: .embedding(EmbeddingDownloadOwner(record: record, artifact: embeddingArtifact)),
            artifacts: [artifact],
            state: .queued
	        )
	    }

    private func ensureWhisperJob(record: WhisperModelRecord, artifact whisperArtifact: WhisperArtifact) async -> DownloadJob {
        let finalURL = record.directoryURL(runtime: whisperArtifact.runtime)
            .appendingPathComponent(URL(fileURLWithPath: whisperArtifact.resourcePath).lastPathComponent)
        let artifact = DownloadArtifact(
            id: DurableArtifactID.whisper,
            role: .whisperModel,
            remoteURL: whisperArtifact.downloadURL,
            stagingURL: Self.stagingURL(for: finalURL),
            finalURL: finalURL,
            expectedBytes: whisperArtifact.sizeBytes > 0 ? whisperArtifact.sizeBytes : nil,
            downloadedBytes: 0,
            checksum: nil,
            state: .queued,
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorDescription: nil,
            manualPause: false
        )
        return await DownloadEngine.shared.upsertJob(
            owner: .whisper(WhisperDownloadOwner(record: record, artifact: whisperArtifact)),
            artifacts: [artifact],
            state: .queued
        )
    }

    private func ensureLeapJob(entry: LeapCatalogEntry) async -> DownloadJob {
        let baseDir = InstalledModelsStore.baseDir(for: .et, modelID: entry.modelID)
        let artifacts: [DownloadArtifact]
        switch entry.artifactKind {
        case .bundle:
            let finalURL = baseDir.appendingPathComponent(entry.slug + ".bundle")
            artifacts = [
                DownloadArtifact(
                    id: DurableArtifactID.leapBundle,
                    role: .leapBundle,
                    remoteURL: nil,
                    stagingURL: Self.stagingURL(for: finalURL),
                    finalURL: finalURL,
                    expectedBytes: entry.sizeBytes > 0 ? entry.sizeBytes : nil,
                    downloadedBytes: 0,
                    checksum: entry.sha256,
                    state: .queued,
                    retryCount: 0,
                    nextRetryAt: nil,
                    lastErrorDescription: nil,
                    manualPause: false
                )
            ]
        case .manifest:
            let installDir = baseDir.appendingPathComponent(entry.slug, isDirectory: true)
            let finalURL = installDir.appendingPathComponent(entry.quantization + ".json")
            artifacts = [
                DownloadArtifact(
                    id: "manifest",
                    role: .leapManifest,
                    remoteURL: nil,
                    stagingURL: Self.stagingURL(for: finalURL),
                    finalURL: finalURL,
                    expectedBytes: nil,
                    downloadedBytes: 0,
                    checksum: nil,
                    state: .queued,
                    retryCount: 0,
                    nextRetryAt: nil,
                    lastErrorDescription: nil,
                    manualPause: false
                )
            ]
        }
        return await DownloadEngine.shared.upsertJob(
            owner: .leap(LeapDownloadOwner(entry: entry)),
            artifacts: artifacts,
            state: .queued
        )
    }
    }

#endif
