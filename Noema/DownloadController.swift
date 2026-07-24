#if canImport(UIKit) || os(macOS)
import Foundation
import SwiftUI
import Combine
import Network
#if canImport(UIKit)
import UIKit
#endif

/// High-frequency download presentation invalidations are deliberately separate
/// from DownloadController. The controller is injected above the whole tab tree;
/// broadcasting progress through it makes unrelated screens such as Settings
/// recompute while the user scrolls.
@MainActor
final class DownloadPresentationUpdates: ObservableObject {
    static let shared = DownloadPresentationUpdates()

    private init() {}

    fileprivate func publish() {
        objectWillChange.send()
    }
}

@MainActor
final class DownloadController: ObservableObject {
	private static func saturatingByteSum(_ values: Int64...) -> Int64 {
        values.reduce(into: Int64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            total = overflow ? .max : sum
        }
    }

    enum ProjectorDownloadDecision: Sendable {
        case automatic
        case selected(VisionProjectorArtifact)
        case skip
    }

	// Download speeds smooth through a time-based EMA: the blend factor derives from
	// elapsed time (1 - e^(-dt/τ)), not event count, so 10 Hz delegate ticks and
	// 0.25–0.5 s samplers converge identically instead of the fast tick rate
	// collapsing the EMA into the raw half-second window sample.
    private let speedSmoothingTimeConstant: TimeInterval = 2.5
    private var speedEMAs: [String: (value: Double, updatedAt: Date)] = [:]
	// Consider speeds stale if no update arrives within this window
	private let speedStaleAfter: TimeInterval = 5.0
	// Clamp unrealistically large instantaneous spikes (in B/s)
    // Upper bound for instantaneous samples to avoid UI spikes; set high enough to not mask real speeds
    private let maxInstantaneousSpeed: Double = 512 * 1024 * 1024 // ~512 MB/s

    // Track last time we updated a speed sample per item category
    private var lastModelSpeedSampleAt: [String: Date] = [:]
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
    private var loggedEmbedExpected: [String: Int64] = [:]
    // Last whole-percent surfaced per embedding download id. The delegate already caps
    // callbacks at 10 Hz; this suppresses redundant progress mutations that would otherwise
    // re-arm the 5 Hz coalesced publish (and its UI / VoiceOver re-render) on every tick.
    private var lastEmbedReportedPct: [String: Int] = [:]
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
	/// These arrays are mutated on coalesced progress ticks.
	/// They are intentionally NOT @Published: each @Published mutation fires
	/// objectWillChange immediately, which re-evaluates every view observing this
	/// controller (including the root tab hierarchy and Settings). Instead, didSet
	/// funnels into a scoped presentation update observed only by download UI.
	private(set) var items: [Item] = [] { didSet { scheduleCoalescedPublish() } }
	private(set) var datasetItems: [DatasetItem] = [] { didSet { scheduleCoalescedPublish() } }
	private(set) var embeddingItems: [EmbeddingItem] = [] { didSet { scheduleCoalescedPublish() } }
    private(set) var whisperItems: [WhisperItem] = [] { didSet { scheduleCoalescedPublish() } }

    // Replacement for the synthesized $items publisher; it emits the current value
    // on subscribe and then at the coalesced cadence.
    private let itemsSubject = CurrentValueSubject<[Item], Never>([])
    var itemsPublisher: AnyPublisher<[Item], Never> { itemsSubject.eraseToAnyPublisher() }

    private var publishScheduled = false
    private var forceNextUIPublish = false
    private var lastPublishAt: Date = .distantPast
    // Two SwiftUI invalidations per second keeps progress legible without making
    // every view observing this controller re-render continuously.
    private let publishInterval: TimeInterval = 0.5

    private func scheduleCoalescedPublish(forceUI: Bool = false) {
        if forceUI { forceNextUIPublish = true }
        guard !publishScheduled else { return }
        publishScheduled = true
        let delay = max(0, publishInterval - Date().timeIntervalSince(lastPublishAt))
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            self.publishScheduled = false
            self.lastPublishAt = Date()
            let shouldPublishUI: Bool = {
#if canImport(UIKit)
                self.forceNextUIPublish || UIApplication.shared.applicationState == .active
#else
                true
#endif
            }()
            self.forceNextUIPublish = false
            if shouldPublishUI {
                DownloadPresentationUpdates.shared.publish()
                self.itemsSubject.send(self.items)
            }
#if os(iOS)
            if #available(iOS 26.0, *) {
                ContinuedDownloadCoordinator.shared.updateProgress(self.overallProgress, title: nil)
            }
#endif
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
	// Consecutive GGUF-magic validation failures per item. Caps the background
	// redownload loop when a server persistently serves garbage with HTTP 200.
	private var ggufValidationFailures: [String: Int] = [:]
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
    private var scheduleRecheckTask: Task<Void, Never>? = nil
    private var hasBootstrappedDownloads = false
    private var lastAutomaticMaintenanceAt: Date? = nil
    private let automaticMaintenanceInterval: TimeInterval = 30
    private var lastAutoFinalizeSweepAt: Date = .distantPast
    private let autoFinalizeSweepInterval: TimeInterval = 5
    // IDs that participated in the current continued-processing batch. Retaining
    // this set through completion lets us report only this batch's failures rather
    // than letting an unrelated old failed row poison the system task result.
    private var continuedProcessingBatchIDs: Set<String> = []

    /// Folds an instantaneous sample into the per-transfer EMA using a time-based
    /// blend factor. Alpha is capped at 0.5 so the first sample after a long gap
    /// (network stall) can pull the average at most halfway: that sample's dt
    /// window spans the whole stall, so its byte rate is stall-diluted and would
    /// otherwise re-seed the EMA with a misleadingly tiny value.
    private func smoothedSpeed(key: String, instantaneous: Double, now: Date = Date()) -> Double {
        let inst = max(0, min(instantaneous, maxInstantaneousSpeed))
        guard let previous = speedEMAs[key] else {
            speedEMAs[key] = (inst, now)
            return inst
        }
        let dt = max(0, now.timeIntervalSince(previous.updatedAt))
        let alpha = min(0.5, 1 - exp(-dt / speedSmoothingTimeConstant))
        let value = previous.value + alpha * (inst - previous.value)
        speedEMAs[key] = (value, now)
        return value
    }

    private func clearSpeedSmoothing(for id: String) {
        speedEMAs[id] = nil
        speedEMAs["\(id)|main"] = nil
        speedEMAs["\(id)|mmproj"] = nil
        speedEMAs["\(id)|imatrix"] = nil
    }

    init() {
        speedCoastTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let now = Date()
                    // A stale display keeps its EMA; an explicit pause resets it.
                    for i in items.indices {
                        let id = items[i].id
                        if let t = lastModelSpeedSampleAt[id], now.timeIntervalSince(t) > speedStaleAfter || paused.contains(id) {
                            if items[i].speed != 0 || items[i].mainSpeed != 0 ||
                                items[i].mmprojSpeed != 0 || items[i].imatrixSpeed != 0 {
                                var item = items[i]
                                item.speed = 0
                                item.mainSpeed = 0
                                item.mmprojSpeed = 0
                                item.imatrixSpeed = 0
                                items[i] = item
                            }
                            if paused.contains(id) {
                                clearSpeedSmoothing(for: id)
                            }
                        }
                    }
                    for i in datasetItems.indices {
                        let id = datasetItems[i].id
                        if let t = lastDatasetSpeedSampleAt[id], now.timeIntervalSince(t) > speedStaleAfter {
                            if datasetItems[i].speed != 0 { datasetItems[i].speed = 0 }
                            if paused.contains(id) {
                                clearSpeedSmoothing(for: id)
                            }
                        }
                    }
                    for i in whisperItems.indices {
                        let id = whisperItems[i].id
                        if let t = lastDatasetSpeedSampleAt[id], now.timeIntervalSince(t) > speedStaleAfter {
                            if whisperItems[i].speed != 0 { whisperItems[i].speed = 0 }
                            if paused.contains(id) {
                                clearSpeedSmoothing(for: id)
                            }
                        }
                    }
                    // If a download reached 100% but never fired .finished (e.g., delegate lost),
                    // perform the on-disk fallback occasionally, not on every one-second
                    // speed tick. Its file probes are synchronous and only useful near 100%.
                    if now.timeIntervalSince(lastAutoFinalizeSweepAt) >= autoFinalizeSweepInterval,
                       items.contains(where: { !$0.completed && $0.progress >= 0.995 }) {
                        lastAutoFinalizeSweepAt = now
                        autoFinalizeCompletedOnDisk()
                    }
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
                self?.scheduleCoalescedPublish(forceUI: true)
                _ = await self?.runDownloadMaintenance(manual: false)
                await self?.reconcileLiveBackgroundSnapshots()
                await self?.resumeScheduledJobsFromEngine()
                self?.updateWakeLock()
            }
        })
#endif
#if canImport(UIKit)
        engineObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            ForegroundDownloadWakeLock.shared.release()
            Task { await DownloadEngine.shared.checkpointProgress() }
        })
#endif
        startScheduleConditionMonitoring()
        // NWPathMonitor only fires on network changes, and macOS/visionOS have no
        // BGProcessingTask or didBecomeActive maintenance hook, so entering the
        // overnight window would never be noticed there without a periodic recheck.
        scheduleRecheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.resumeScheduledJobsFromEngine()
            }
        }
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
            do {
                try out.write(to: artifactsURL)
                MtpLocator.invalidateCache()
            } catch {}
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

        // Download to the staging path the engine artifact declares (destinationURL ==
        // stagingURL); pause/cancel fanout and live-task lookups all key off that path.
        let stagedDest = Self.stagingURL(for: dest)
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].imatrixProgress = 0
            items[idx].imatrixDestination = stagedDest
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
                to: stagedDest,
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
                        item.imatrixDestination = stagedDest
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
                        item.imatrixDestination = stagedDest
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

                            self.lastIMatrixSpeedSampleAt[itemID] = now
                            self.lastIMatrixBytesSample[itemID] = written

                            item.imatrixSpeed = self.smoothedSpeed(key: "\(itemID)|imatrix", instantaneous: rawSpeed, now: now)
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

        try finalizeStagedDownload(from: stagedDest, to: dest)
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

    /// Marks the artifact that landed at `destinationURL` completed and reports whether every
    /// artifact of the job is now complete. A single finished file must not finalize a
    /// multi-artifact job: incomplete jobs are parked in `.retrying` (autoResumeEligible) and
    /// a resume pass is scheduled here — not every caller (e.g. maintenance repairs) follows
    /// up with one, and nothing else would restart the remainder.
    private func settleArtifactCompletion(externalID: String, destinationURL: URL) async -> Bool {
        guard let job = await DownloadEngine.shared.job(forExternalID: externalID) else { return true }
        if let artifact = job.artifacts.first(where: {
            $0.stagingURL.path == destinationURL.path || $0.finalURL.path == destinationURL.path
        }), artifact.state != .completed {
            await DownloadEngine.shared.markArtifactCompleted(
                externalID: externalID,
                artifactID: artifact.id,
                finalBytes: fileSize(at: destinationURL) ?? 0
            )
        }
        guard let refreshed = await DownloadEngine.shared.job(forExternalID: externalID) else { return true }
        let allCompleted = !refreshed.artifacts.isEmpty && refreshed.artifacts.allSatisfy { $0.state == .completed }
        if !allCompleted, tasks[externalID] == nil, !refreshed.manualPause, refreshed.state != .scheduled {
            await DownloadEngine.shared.updateJobState(externalID: externalID, state: .retrying, manualPause: false)
            Task { await self.resumeRecoverableJobsFromEngine() }
        }
        return allCompleted
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
            let recoveredItem = items[index]
            if let recoveredJob = await DownloadEngine.shared.job(forExternalID: recoveredItem.id),
               Self.requiresCanonicalModelFinalization(
                   state: recoveredJob.state,
                   allArtifactsCompleted: recoveredJob.artifacts.allSatisfy { $0.state == .completed }
               ) {
                if tasks[recoveredItem.id] == nil {
                    await logger.log("[Download][Recovery] resuming canonical model finalization externalID=\(recoveredItem.id)")
                    start(detail: recoveredItem.detail, quant: recoveredItem.quant, userInitiated: false)
                }
                return
            }
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
            // A multi-file dataset must not finalize (or start indexing) off a single
            // finished file; park it for auto-resume until every artifact completed.
            guard await settleArtifactCompletion(externalID: removedID, destinationURL: resolvedDestinationURL) else { return }
            // Re-check after the suspension: two straggler completion notifications can
            // both pass the guard above and both see allCompleted; only one may finalize.
            guard let idx = datasetItems.firstIndex(where: { $0.id == removedID }),
                  !datasetItems[idx].completed else { return }
            datasetItems[idx].completed = true
            datasetItems[idx].status = .completed
            datasetItems[idx].canPause = false
            datasetItems[idx].canResume = false
            datasetItems[idx].progress = 1.0
            datasetItems[idx].speed = 0
            await DownloadEngine.shared.updateJobState(externalID: removedID, state: .completed, manualPause: false)
            datasetManager?.handleDatasetDownloadCompleted(datasetID: removedID)
            Haptics.success()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.datasetItems.removeAll { $0.id == removedID }
                if self.allItems.isEmpty { self.showOverlay = false }
            }
            scheduleJobRemoval(externalID: removedID, delay: 3)
            return
        }

        // Awaited (not spawned) so job-state changes land before the caller's
        // resumeRecoverableJobsFromEngine pass evaluates this job.
        guard let job = await DownloadEngine.shared.job(matching: resolvedDestinationURL) else { return }
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
                guard await settleArtifactCompletion(externalID: owner.detail.id, destinationURL: resolvedDestinationURL) else { return }
                self.datasetManager?.handleDatasetDownloadCompleted(datasetID: owner.detail.id)
                await DownloadEngine.shared.updateJobState(externalID: owner.detail.id, state: .completed, manualPause: false)
                self.scheduleJobRemoval(externalID: owner.detail.id, delay: 3)
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
        await refreshFromEngineSnapshot()
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
        // Mirror the primary download path's validation: never install an HTML error page
        // or LFS pointer as model weights. Discard the file and let auto-resume redownload
        // once; a second bad payload means the server is persistently serving garbage, so
        // fail permanently instead of looping full-file redownloads.
        if item.quant.format == .gguf, !hasGGUFMagic(at: finalURL) {
            let externalID = item.id
            // Only an existing-but-invalid payload counts toward the cap; a duplicate
            // completion event for an already-discarded file must not burn retry budget.
            if fm.fileExists(atPath: finalURL.path) {
                try? fm.removeItem(at: finalURL)
                ggufValidationFailures[externalID, default: 0] += 1
            }
            if ggufValidationFailures[externalID, default: 0] >= 2 {
                ggufValidationFailures[externalID] = nil
                let downloadError = categorizeError(URLError(.cannotParseResponse))
                items[itemIndex].status = .failed
                items[itemIndex].error = downloadError
                items[itemIndex].canPause = false
                items[itemIndex].canResume = false
                items[itemIndex].speed = 0
                Task { @MainActor in
                    await logger.log("[DownloadController] GGUF magic check failed repeatedly for \(finalURL.lastPathComponent); marking failed")
                    if let job = await DownloadEngine.shared.job(forExternalID: externalID),
                       let artifact = job.artifacts.first(where: { $0.finalURL.path == finalURL.path }) {
                        await DownloadEngine.shared.updateArtifactState(
                            externalID: externalID,
                            artifactID: artifact.id,
                            state: .failed,
                            errorMessage: downloadError.localizedDescription,
                            manualPause: false
                        )
                    }
                    await DownloadEngine.shared.updateJobState(
                        externalID: externalID,
                        state: .failed,
                        manualPause: false,
                        errorMessage: downloadError.localizedDescription
                    )
                    try? await Task.sleep(for: .seconds(5))
                    self.items.removeAll { $0.id == externalID }
                    self.lastMainSpeedSampleAt[externalID] = nil
                    self.lastMainBytesSample[externalID] = nil
                    if self.allItems.isEmpty { self.showOverlay = false }
                }
                return
            }
            items[itemIndex].status = .retrying
            items[itemIndex].canPause = false
            items[itemIndex].canResume = true
            items[itemIndex].mainProgress = 0
            items[itemIndex].mainBytesWritten = 0
            refreshCombinedProgress(at: itemIndex)
            Task { @MainActor in
                await logger.log("[DownloadController] GGUF magic check failed for \(finalURL.lastPathComponent); discarding and retrying")
                if let job = await DownloadEngine.shared.job(forExternalID: externalID),
                   let artifact = job.artifacts.first(where: { $0.finalURL.path == finalURL.path }) {
                    await DownloadEngine.shared.updateArtifactState(
                        externalID: externalID,
                        artifactID: artifact.id,
                        state: .retrying,
                        downloadedBytes: 0,
                        manualPause: false
                    )
                }
                await DownloadEngine.shared.updateJobState(externalID: externalID, state: .retrying, manualPause: false)
                await self.resumeRecoverableJobsFromEngine()
            }
            return
        }
        ggufValidationFailures[item.id] = nil
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
            try out.write(to: artifactsURL)
            MtpLocator.invalidateCache()
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
            // This fallback is for orphaned rows only. An active wrapper owns validation,
            // metadata/sidecar work, and registration and must be allowed to finish them.
            if tasks[items[idx].id] != nil { continue }
            // A persisted verifying/finalizing job has canonical owner-specific work left
            // (metadata, sidecars, registration). Relaunch recovery will restart that owner;
            // the generic on-disk fallback must not short-circuit it into a minimal install.
            if items[idx].status == .verifying || items[idx].status == .finalizing { continue }
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

	func start(
        detail: ModelDetails,
        quant: QuantInfo,
        userInitiated: Bool = true,
        projectorDecision: ProjectorDownloadDecision = .automatic
    ) {
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
		updateWakeLock(userInitiated: userInitiated)

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
					// Resolve the projector using the global precision preference. Explore
                    // preflights exact preferences and passes the user's explicit fallback choice.
                    let repoCandidates = VisionModelDetector.repositoryCandidates(
                        modelID: detail.id,
                        downloadURL: quant.downloadURL
                    )
					let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let selectedArtifact: VisionProjectorArtifact?
                    switch projectorDecision {
                    case .selected(let artifact):
                        selectedArtifact = artifact
                    case .skip:
                        selectedArtifact = nil
                    case .automatic:
                        let plan = await VisionModelDetector.projectorDownloadPlan(
                            repoIDs: repoCandidates,
                            token: token,
                            preference: .current
                        )
                        selectedArtifact = plan.selected ?? plan.alternatives.first
                    }
                    var selected: (name: String, url: URL, size: Int64)? = nil
                    if let artifact = selectedArtifact {
                        let escapedRepo = artifact.repositoryID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artifact.repositoryID
                        let escapedFilename = artifact.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artifact.filename
                        if let url = URL(string: "https://huggingface.co/\(escapedRepo)/resolve/main/\(escapedFilename)?download=1") {
                            var size = artifact.size
                            if size <= 0 {
                                let headSize = await self.fetchRemoteSize(url)
                                if headSize > 0 { size = headSize }
                            }
                            selected = (artifact.filename, url, size)
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

                                        self.lastMMProjSpeedSampleAt[id] = now
                                        self.lastMMProjBytesSample[id] = written

                                        item.mmprojSpeed = self.smoothedSpeed(key: "\(id)|mmproj", instantaneous: rawSpeed, now: now)
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
                            item.mainSpeed = self.smoothedSpeed(key: "\(id)|main", instantaneous: managerSpeed, now: now)
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
						self.clearSpeedSmoothing(for: id)
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
						self.clearSpeedSmoothing(for: id)
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
                                                                self.start(detail: item.detail, quant: item.quant, userInitiated: false)
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
        prepareVisiblePause(itemID: itemID)
        Task { await pauseTransfersAndPersist(itemID: itemID) }
    }

    /// Called when iOS expires or the person cancels the user-visible continued
    /// processing task. Stop the underlying work cooperatively and retain resume
    /// state; silently moving it to another session would defeat system Cancel.
    func pauseActiveDownloadsForContinuedProcessingExpiration() async {
        let modelIDs = items.filter { isWakeLockStatus($0.status) }.map(\.id)
        let datasetIDs = datasetItems.filter { isWakeLockStatus($0.status) }.map(\.id)
        let embeddingIDs = embeddingItems.filter { isWakeLockStatus($0.status) }.map(\.id)
        let whisperIDs = whisperItems.filter { isWakeLockStatus($0.status) }.map(\.id)
        let activeIDs = Set(modelIDs + datasetIDs + embeddingIDs + whisperIDs)
        for itemID in activeIDs {
            prepareVisiblePause(itemID: itemID)
        }
        for itemID in activeIDs {
            await pauseTransfersAndPersist(itemID: itemID)
        }
        await refreshFromEngineSnapshot()
    }

    private func prepareVisiblePause(itemID: String) {
        pauseRequestedIDs.insert(itemID)
        resumePendingIDs.remove(itemID)
        paused.insert(itemID)

        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].status = .paused
            items[idx].canPause = false
            items[idx].canResume = true
            items[idx].speed = 0
            items[idx].mainSpeed = 0
            items[idx].mmprojSpeed = 0
            items[idx].imatrixSpeed = 0
        }
        if let idx = datasetItems.firstIndex(where: { $0.id == itemID }) {
            datasetItems[idx].status = .paused
            datasetItems[idx].canPause = false
            datasetItems[idx].canResume = true
            datasetItems[idx].speed = 0
        }
        if let idx = embeddingItems.firstIndex(where: { $0.id == itemID }) {
            embeddingItems[idx].status = .paused
            embeddingItems[idx].canPause = false
            embeddingItems[idx].canResume = true
            embeddingItems[idx].speed = 0
        }
        if let idx = whisperItems.firstIndex(where: { $0.id == itemID }) {
            whisperItems[idx].status = .paused
            whisperItems[idx].canPause = false
            whisperItems[idx].canResume = true
            whisperItems[idx].speed = 0
        }
    }

    private func pauseTransfersAndPersist(itemID: String) async {
        if let item = items.first(where: { $0.id == itemID }) {
            await manager.pause(modelID: item.detail.id, quantLabel: item.quant.label)
            if let destination = item.mmprojDestination {
                await BackgroundDownloadManager.shared.pause(destination: destination)
            }
            if let destination = item.imatrixDestination {
                await BackgroundDownloadManager.shared.pause(destination: destination)
            }
        }
        if let job = await DownloadEngine.shared.job(forExternalID: itemID) {
            for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
                await BackgroundDownloadManager.shared.pause(destination: artifact.destinationURL)
            }
        }
        await setAllArtifacts(externalID: itemID, state: .paused, manualPause: true)
        await DownloadEngine.shared.updateJobState(externalID: itemID, state: .paused, manualPause: true)
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

        func startDataset(detail: DatasetDetails, userInitiated: Bool = true) {
                let id = detail.id
                if tasks[id] != nil { return }
                cancelledExternalIDs.remove(id)
                pauseRequestedIDs.remove(id)
                resumePendingIDs.remove(id)
                clearSpeedSmoothing(for: id)
                lastDatasetSpeedSampleAt[id] = nil
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
                updateWakeLock(userInitiated: userInitiated)

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
						// 2) ranged sniff: only the leading bytes are needed to detect
						// PDF/EPUB signatures — never pull the whole file into RAM.
						var get = URLRequest(url: original)
						get.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
						get.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
						if NetworkKillSwitch.isEnabled { return nil }
						NetworkKillSwitch.track(session: URLSession.shared)
						do {
							let (bytes, resp) = try await URLSession.shared.bytes(for: HFEndpoint.rewrite(get))
							guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
							var prefix = Data()
							prefix.reserveCapacity(1024)
							for try await byte in bytes {
								prefix.append(byte)
								if prefix.count >= 1024 { break }
							}
							// Stop the transfer even when the server ignored the Range header.
							bytes.task.cancel()
							let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
							let isPDF = mime.contains("pdf") || prefix.prefix(4) == Data([0x25, 0x50, 0x44, 0x46])
							let isEPUB = mime.contains("epub") || prefix.starts(with: Data([0x50, 0x4b])) // zip signature
							guard isPDF || isEPUB else { return nil }
							let total: Int64 = {
								if let range = http.value(forHTTPHeaderField: "Content-Range"),
								   let tail = range.split(separator: "/").last, let len = Int64(tail) {
									return len
								}
								if http.statusCode == 200, http.expectedContentLength > 0 {
									return http.expectedContentLength
								}
								return Int64(prefix.count)
							}()
							return (original, total)
						} catch {
							return nil
						}
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

                                for file in filesToDownload {
                                        let fileURL = file.downloadURL
                    let relativePath = Self.datasetRelativePath(for: file)
                    let artifactID = Self.datasetArtifactID(relativePath: relativePath)
                                        let finalDest = Self.datasetDestinationURL(for: id, relativePath: relativePath)
                                        // A file already at its final path completed in a previous run
                                        // (finals only appear via finalizeStagedDownload); resuming a
                                        // multi-file dataset must not re-download it from scratch.
                                        if let onDisk = fileSize(at: finalDest), onDisk > 0,
                                           file.sizeBytes <= 0 || onDisk == file.sizeBytes {
                                                await DownloadEngine.shared.markArtifactCompleted(
                                                    externalID: id,
                                                    artifactID: artifactID,
                                                    finalBytes: onDisk
                                                )
                                                completedBytes += file.sizeBytes > 0 ? file.sizeBytes : onDisk
                                                if let idx = self.datasetItems.firstIndex(where: { $0.id == id }) {
                                                        self.datasetItems[idx].downloadedBytes = completedBytes
                                                }
                                                if totalSize == 0 { completedFiles += 1 }
                                                continue
                                        }
                                        var req = URLRequest(url: fileURL)
                    req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
                                        var knownExpected: Int64 = file.sizeBytes
                                        if knownExpected <= 0 { knownExpected = await self.fetchRemoteSize(fileURL) }
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
                                                        self.datasetItems[idx].speed = self.smoothedSpeed(key: id, instantaneous: instSpeed)
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

	func startEmbedding(repoID: String, userInitiated: Bool = true) {
        let record = EmbeddingModelCatalog.record(matchingDownloadIdentifier: repoID) ?? EmbeddingModelCatalog.activeRecord()
        startEmbedding(recordID: record.id, userInitiated: userInitiated)
    }

    func startEmbedding(recordID: String, userInitiated: Bool = true) {
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
        clearSpeedSmoothing(for: id)
        let finalDest = artifact.localURL(recordID: record.id)
        if FileManager.default.fileExists(atPath: finalDest.path) {
            Task { @MainActor [weak self] in
                await logger.log("[DownloadController] Embedding model already installed; reconciling download state for \(record.id)")
                await self?.handleBackgroundDownloadCompletion(destinationURL: finalDest, errorMessage: nil)
            }
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
		updateWakeLock(userInitiated: userInitiated)

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
                var attempt = 0
                retryLoop: while true {
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
                do {
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
                        // The delegate already caps callbacks at 10 Hz; only mutate published
                        // state when the displayed percent actually changes so we don't re-arm
                        // the 5 Hz coalesced publish (and its UI/VoiceOver re-render) per tick.
                        let pct = Int(min(prog, 0.999) * 100)
                        Task { @MainActor in
                            // Trailing ticks from a transfer that is being paused must not
                            // flip the row back to "downloading".
                            if self.pauseRequestedIDs.contains(id) { return }
                            if self.lastEmbedReportedPct[id] == pct { return }
                            self.lastEmbedReportedPct[id] = pct
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
                        _ = written
                    })
                break retryLoop
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain,
                       nsError.code == NSURLErrorCancelled,
                       self.resumePendingIDs.remove(id) != nil {
                        // Resume was tapped while the pause was still settling;
                        // retry now instead of failing permanently.
                        continue retryLoop
                    }
                    let pausedByUser = nsError.domain == NSURLErrorDomain
                        && nsError.code == NSURLErrorCancelled
                        && (self.paused.contains(id) || self.pauseRequestedIDs.contains(id))
                    let errType = self.categorizeError(error)
                    // Pauses, cancellations and permanent failures keep the existing
                    // handling in the outer catch; only transient errors retry here.
                    guard !pausedByUser, !Task.isCancelled, errType.isRetryable else { throw error }
                    attempt += 1
                    let delay = min(pow(2.0, Double(attempt)), 60)
                    await DownloadEngine.shared.updateArtifactState(
                        externalID: id,
                        artifactID: DurableArtifactID.embedding,
                        state: .retrying,
                        retryCount: attempt,
                        nextRetryAt: Date().addingTimeInterval(delay),
                        errorMessage: errType.localizedDescription,
                        manualPause: false
                    )
                    await DownloadEngine.shared.updateJobState(
                        externalID: id,
                        state: .retrying,
                        manualPause: false,
                        errorMessage: errType.localizedDescription
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    await self.waitForNetworkConnectivity()
                    continue retryLoop
                }
                }
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

    func startWhisper(recordID: String, runtime: WhisperRuntimeFormat, userInitiated: Bool = true) {
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
        clearSpeedSmoothing(for: id)
        lastDatasetSpeedSampleAt[id] = nil
        let finalDest = record.directoryURL(runtime: runtime)
            .appendingPathComponent(URL(fileURLWithPath: artifact.resourcePath).lastPathComponent)
        if FileManager.default.fileExists(atPath: finalDest.path) {
            Task { @MainActor [weak self] in
                await logger.log("[DownloadController] Whisper model already installed; reconciling download state for \(record.id)")
                await self?.handleBackgroundDownloadCompletion(destinationURL: finalDest, errorMessage: nil)
            }
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
        updateWakeLock(userInitiated: userInitiated)

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

                var speedLastTime: Date?
                var lastBytes: Int64 = 0
                var attempt = 0
                retryLoop: while true {
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
                do {
                await DownloadEngine.shared.updateArtifactState(
                    externalID: id,
                    artifactID: DurableArtifactID.whisper,
                    state: .downloading,
                    manualPause: false
                )
                await DownloadEngine.shared.updateJobState(externalID: id, state: .downloading, manualPause: false)
                try await BackgroundDownloadManager.shared.download(
                    request: req,
                    to: stagedDest,
                    jobID: job.id,
                    artifactID: DurableArtifactID.whisper,
                    expectedSize: knownExpected > 0 ? knownExpected : artifact.sizeBytes,
                    progress: { [weak self] prog in
                        guard let self else { return }
                        Task { @MainActor in
                            // Trailing ticks from a transfer that is being paused must not
                            // flip the row back to "downloading".
                            if self.pauseRequestedIDs.contains(id) { return }
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
                            self.whisperItems[idx].speed = self.smoothedSpeed(key: id, instantaneous: raw)
                            self.lastDatasetSpeedSampleAt[id] = Date()
                        }
                    }
                )
                break retryLoop
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain,
                       nsError.code == NSURLErrorCancelled,
                       self.resumePendingIDs.remove(id) != nil {
                        // Resume was tapped while the pause was still settling;
                        // retry now instead of failing permanently.
                        continue retryLoop
                    }
                    let pausedByUser = nsError.domain == NSURLErrorDomain
                        && nsError.code == NSURLErrorCancelled
                        && (self.paused.contains(id) || self.pauseRequestedIDs.contains(id))
                    let errType = self.categorizeError(error)
                    // Pauses, cancellations and permanent failures keep the existing
                    // handling in the outer catch; only transient errors retry here.
                    guard !pausedByUser, !Task.isCancelled, errType.isRetryable else { throw error }
                    attempt += 1
                    let delay = min(pow(2.0, Double(attempt)), 60)
                    await DownloadEngine.shared.updateArtifactState(
                        externalID: id,
                        artifactID: DurableArtifactID.whisper,
                        state: .retrying,
                        retryCount: attempt,
                        nextRetryAt: Date().addingTimeInterval(delay),
                        errorMessage: errType.localizedDescription,
                        manualPause: false
                    )
                    await DownloadEngine.shared.updateJobState(
                        externalID: id,
                        state: .retrying,
                        manualPause: false,
                        errorMessage: errType.localizedDescription
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    await self.waitForNetworkConnectivity()
                    continue retryLoop
                }
                }

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
		clearSpeedSmoothing(for: itemID)
		lastModelSpeedSampleAt[itemID] = nil
		lastMainSpeedSampleAt[itemID] = nil
		lastMainBytesSample[itemID] = nil
		lastDatasetSpeedSampleAt[itemID] = nil
		ggufValidationFailures[itemID] = nil
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
			let total = bytesGGUF + bytesDS + bytesEMB + bytesWhisper
		guard total > 0 else { return 0 }
		let completedGGUF = items.reduce(0.0) {
			let written = $1.mainBytesWritten + $1.mmprojBytesWritten + $1.imatrixBytesWritten
			return $0 + Double(written)
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
			return (completedGGUF + completedDS + completedEMB + completedWhisper) / total
		}

		var allItems: [Any] {
			return items as [Any] + datasetItems as [Any] + embeddingItems as [Any] + whisperItems as [Any]
		}

		var allCompleted: Bool {
			!allItems.isEmpty && items.allSatisfy({ $0.completed }) && datasetItems.allSatisfy({ $0.completed }) && embeddingItems.allSatisfy({ $0.completed }) && whisperItems.allSatisfy({ $0.completed })
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

    /// Returns the byte count that crash recovery can prove is still durable, or nil when
    /// the persisted count should remain untouched. URLSession progress is intentionally
    /// monotonic during a live transfer; relaunch is the one point where lowering a stale
    /// count is required so a restarted transfer does not appear frozen at (for example) 97%.
    nonisolated static func recoveredArtifactByteCount(state: DownloadArtifactState,
                                                        persistedBytes: Int64,
                                                        stagingBytes: Int64?,
                                                        hasFinalFile: Bool,
                                                        hasLiveTask: Bool,
                                                        hasResumeData: Bool) -> Int64? {
        guard state != .completed, state != .cancelled,
              !hasFinalFile, !hasLiveTask, !hasResumeData else {
            return nil
        }
        let durableBytes = max(0, stagingBytes ?? 0)
        return durableBytes == persistedBytes ? nil : durableBytes
    }

    nonisolated static func requiresCanonicalModelFinalization(state: DownloadJobState,
                                                               allArtifactsCompleted: Bool) -> Bool {
        state == .verifying || state == .finalizing || (allArtifactsCompleted && state.autoResumeEligible)
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

    /// Presentation mapping for engine snapshots with no live-transfer evidence. Unlike
    /// `stateAfterLiveSnapshot` (which reconciles jobs that verifiably have a running
    /// URLSession task), this must not promote failed/queued states to "downloading" —
    /// a failed job with no task would otherwise read as active forever.
    nonisolated static func displayState(for state: DownloadJobState, manualPause: Bool) -> DownloadJobState {
        if state == .scheduled { return .scheduled }
        if manualPause && state != .completed { return .paused }
        return state
    }

	    private enum DurableArtifactID {
	        static let main = "main"
	        static let projector = "projector"
	        static let importanceMatrix = "imatrix"
            static let mtp = "mtp"
		        static let embedding = "embedding"
            static let whisper = "whisper"

        static func shard(_ relativePath: String) -> String {
            "shard:\(relativePath)"
        }

        static func dataset(_ relativePath: String) -> String {
            DatasetPathing.durableArtifactID(forDatasetRelativePath: relativePath)
        }

    }

    func bootstrapIfNeeded() {
        if hasBootstrappedDownloads {
            Task { @MainActor [weak self] in
                await BackgroundDownloadManager.shared.prepareForActiveProcess()
                await self?.reattachActiveBackgroundObservers()
                await self?.reconcileLiveBackgroundSnapshots()
                await self?.resumeRecoverableJobsFromEngine()
            }
            return
        }
        hasBootstrappedDownloads = true
        Task { @MainActor [weak self] in
            await BackgroundDownloadManager.shared.prepareForActiveProcess()
            await DownloadEngine.shared.bootstrap()
            // Materialize persisted rows before maintenance dispatches any repaired
            // completion. Model finalization matches the completion URL to these rows.
            await self?.refreshFromEngineSnapshot()
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
        let existingModels = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let existingDatasets = Dictionary(datasetItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let existingEmbeddings = Dictionary(embeddingItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let existingWhisper = Dictionary(whisperItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        var newItems: [Item] = []
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
                item.status = Self.displayState(for: job.state, manualPause: job.manualPause)
                item.canPause = job.canPause
                item.canResume = job.canResume
                item.completed = job.state == .completed
                item.error = job.state == .failed ? .permanentError(job.lastErrorDescription ?? "Download failed") : nil
                applyModelArtifacts(job.artifacts, to: &item)
                newItems.append(item)
            case .dataset(let owner):
                var item = existingDatasets[job.externalID] ?? DatasetItem(detail: owner.detail)
                item.jobID = job.id
                item.status = Self.displayState(for: job.state, manualPause: job.manualPause)
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
                item.status = Self.displayState(for: job.state, manualPause: job.manualPause)
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
                item.status = Self.displayState(for: job.state, manualPause: job.manualPause)
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

        // A start call creates its visible `.preparing` row immediately, then the
        // wrapper asynchronously creates the durable engine job. An unrelated
        // engine notification can arrive inside that gap. Preserve rows that still
        // have a live wrapper so the refresh cannot momentarily erase the operation,
        // complete its continued-processing task, and lose user-initiation provenance.
        newItems.append(contentsOf: items.filter { item in
            tasks[item.id] != nil && !newItems.contains(where: { $0.id == item.id })
        })
        newDatasetItems.append(contentsOf: datasetItems.filter { item in
            tasks[item.id] != nil && !newDatasetItems.contains(where: { $0.id == item.id })
        })
        newEmbeddingItems.append(contentsOf: embeddingItems.filter { item in
            tasks[item.id] != nil && !newEmbeddingItems.contains(where: { $0.id == item.id })
        })
        newWhisperItems.append(contentsOf: whisperItems.filter { item in
            tasks[item.id] != nil && !newWhisperItems.contains(where: { $0.id == item.id })
        })
        newPaused.formUnion(paused.filter { tasks[$0] != nil })

        items = newItems
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
            item.status = Self.displayState(for: job.state, manualPause: job.manualPause)
            item.canPause = job.canPause
            item.canResume = job.canResume
            if item.status != .failed {
                item.error = nil
            }
            applyModelArtifacts(job.artifacts, to: &item)
            items[idx] = item
        case .dataset:
            guard let idx = datasetItems.firstIndex(where: { $0.id == externalID }) else { return }
            datasetItems[idx].status = Self.displayState(for: job.state, manualPause: job.manualPause)
            datasetItems[idx].canPause = job.canPause
            datasetItems[idx].canResume = job.canResume
            datasetItems[idx].expectedBytes = job.totalExpectedBytes
            datasetItems[idx].downloadedBytes = job.totalDownloadedBytes
            if job.totalExpectedBytes > 0 {
                datasetItems[idx].progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(job.totalExpectedBytes)))
            }
        case .embedding:
            guard let idx = embeddingItems.firstIndex(where: { $0.id == externalID }) else { return }
            embeddingItems[idx].status = Self.displayState(for: job.state, manualPause: job.manualPause)
            embeddingItems[idx].canPause = job.canPause
            embeddingItems[idx].canResume = job.canResume
            embeddingItems[idx].expectedBytes = max(job.totalExpectedBytes, embeddingItems[idx].expectedBytes)
            let total = max(embeddingItems[idx].expectedBytes, 1)
            embeddingItems[idx].progress = min(1, max(0, Double(job.totalDownloadedBytes) / Double(total)))
        case .whisper:
            guard let idx = whisperItems.firstIndex(where: { $0.id == externalID }) else { return }
            whisperItems[idx].status = Self.displayState(for: job.state, manualPause: job.manualPause)
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
        await reconcileRecoveredArtifactProgress()
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
                start(detail: owner.detail, quant: owner.quant, userInitiated: false)
            case .dataset(let owner):
                startDataset(detail: owner.detail, userInitiated: false)
            case .embedding(let owner):
                let recordID = EmbeddingModelCatalog.record(matchingDownloadIdentifier: owner.externalID)?.id ?? owner.externalID
                startEmbedding(recordID: recordID, userInitiated: false)
            case .whisper(let owner):
                startWhisper(recordID: owner.recordID, runtime: owner.runtime, userInitiated: false)
            }
        }
    }

    /// Reconcile persisted progress with evidence that survived the prior process. If there
    /// is no live task, resume blob, final file, or staged byte range, the next start is a
    /// fresh transfer and its visible progress must start at zero as well.
    private func reconcileRecoveredArtifactProgress() async {
        let jobs = await DownloadEngine.shared.autoResumableJobs()
        let fm = FileManager.default
        var changed = false

        for job in jobs {
            // Engine notifications can request a resume pass while an existing wrapper is
            // briefly between URLSession tasks (retry/backoff/finalization). That is not a
            // relaunch and must never lower its live in-memory progress.
            if tasks[job.externalID] != nil { continue }
            for artifact in job.artifacts where artifact.state != .completed && artifact.state != .cancelled {
                let hasLiveTask = await BackgroundDownloadManager.shared.hasLiveTask(for: artifact.destinationURL)
                let hasFinalFile = fm.fileExists(atPath: artifact.finalURL.path)
                let stagingBytes = fileSize(at: artifact.stagingURL)
                let resumeURL = DownloadPersistencePaths.resumeDataURL(jobID: job.id, artifactID: artifact.id)
                let hasResumeData = fm.fileExists(atPath: resumeURL.path)

                guard let durableBytes = Self.recoveredArtifactByteCount(
                    state: artifact.state,
                    persistedBytes: artifact.downloadedBytes,
                    stagingBytes: stagingBytes,
                    hasFinalFile: hasFinalFile,
                    hasLiveTask: hasLiveTask,
                    hasResumeData: hasResumeData
                ) else { continue }

                await DownloadEngine.shared.resetArtifactProgress(
                    jobID: job.id,
                    artifactID: artifact.id,
                    downloadedBytes: durableBytes
                )
                await logger.log(
                    "[Download][Recovery] reset stale progress externalID=\(job.externalID) artifactID=\(artifact.id) persisted=\(artifact.downloadedBytes) durable=\(durableBytes)"
                )
                changed = true
            }
        }

        if changed {
            await refreshFromEngineSnapshot()
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
                start(detail: owner.detail, quant: owner.quant, userInitiated: false)
            case .dataset(let owner):
                startDataset(detail: owner.detail, userInitiated: false)
            case .embedding(let owner):
                let recordID = EmbeddingModelCatalog.record(matchingDownloadIdentifier: owner.externalID)?.id ?? owner.externalID
                startEmbedding(recordID: recordID, userInitiated: false)
            case .whisper(let owner):
                startWhisper(recordID: owner.recordID, runtime: owner.runtime, userInitiated: false)
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
        // Wired Ethernet counts as "Wi-Fi" for scheduling: the policy really means
        // "unmetered", and desktop Macs on Ethernet would otherwise never qualify.
        return path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
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
            // Active, paused, scheduled, and finalizing jobs are durable work. Only terminal
            // records are maintenance candidates; an all-complete `.finalizing` job must stay
            // available so owner-specific registration can resume after a process exit.
            var shouldRemoveJob = job.state == .completed || job.state == .failed || job.state == .cancelled
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

            if job.state == .completed {
                shouldRemoveJob = true
            }

            if repairedJob {
                switch job.owner {
                case .model:
                    // ModelDownloadManager performs validation, metadata/sidecar backfill,
                    // and registration. Keep the repaired job in `.finalizing`; the normal
                    // auto-resume pass will re-enter that complete pipeline.
                    break
                default:
                    if let completionURL = job.artifacts
                        .map(\.finalURL)
                        .first(where: { fm.fileExists(atPath: $0.path) }) {
                        repairedCompletionURLs.append(completionURL)
                    }
                }
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

    private func updateWakeLock(userInitiated: Bool = false) {
        let modelActiveIDs = items.filter { isWakeLockStatus($0.status) }.map(\.id)
        let datasetActiveIDs = datasetItems.filter { isWakeLockStatus($0.status) }.map(\.id)
        let embeddingActiveIDs = embeddingItems.filter { isWakeLockStatus($0.status) }.map(\.id)
        let whisperActiveIDs = whisperItems.filter { isWakeLockStatus($0.status) }.map(\.id)
        let activeIDs = Set(modelActiveIDs + datasetActiveIDs + embeddingActiveIDs + whisperActiveIDs)
        let hasActive = !activeIDs.isEmpty
#if canImport(UIKit)
        let isSceneActive = UIApplication.shared.applicationState == .active
#else
        // macOS: the App Nap assertion should hold whenever downloads run, frontmost or not.
        let isSceneActive = true
#endif
        ForegroundDownloadWakeLock.shared.update(hasActiveForegroundDownloads: hasActive, isSceneActive: isSceneActive)
#if os(iOS)
        if #available(iOS 26.0, *) {
            if hasActive {
                continuedProcessingBatchIDs.formUnion(activeIDs)
                ContinuedDownloadCoordinator.shared.downloadsBecameActive(
                    title: continuedDownloadTitle(),
                    userInitiated: userInitiated,
                    controller: self
                )
            } else {
                let failedModelIDs = items.filter { $0.status == .failed }.map(\.id)
                let failedDatasetIDs = datasetItems.filter { $0.status == .failed }.map(\.id)
                let failedEmbeddingIDs = embeddingItems.filter { $0.status == .failed }.map(\.id)
                let failedWhisperIDs = whisperItems.filter { $0.status == .failed }.map(\.id)
                let failedIDs = Set(failedModelIDs + failedDatasetIDs + failedEmbeddingIDs + failedWhisperIDs)
                let batchSucceeded = continuedProcessingBatchIDs.isDisjoint(with: failedIDs)
                ContinuedDownloadCoordinator.shared.downloadsFinished(success: batchSucceeded)
                continuedProcessingBatchIDs.removeAll()
            }
        }
#endif
    }

#if os(iOS)
    private func continuedDownloadTitle() -> String {
        var names: [String] = []
        for item in items where isWakeLockStatus(item.status) {
            names.append(item.detail.id.split(separator: "/").last.map(String.init) ?? item.detail.id)
        }
        for item in datasetItems where isWakeLockStatus(item.status) { names.append(item.detail.displayName ?? item.detail.id) }
        for item in embeddingItems where isWakeLockStatus(item.status) { names.append(item.displayName) }
        for item in whisperItems where isWakeLockStatus(item.status) { names.append(item.displayName) }
        if names.count == 1, let only = names.first, !only.isEmpty { return only }
        return String(localized: "Downloading models")
    }
#endif

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

    }

#endif
