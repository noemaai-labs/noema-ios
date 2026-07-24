import Foundation
import SwiftUI

@MainActor
final class DatasetManager: ObservableObject {
    static var makeTranscriptionBackend: (TranscriptionEngineID) throws -> any TranscriptionBackend = {
        try TranscriptionBackendFactory.makeBackend(for: $0)
    }

    @Published private(set) var datasets: [LocalDataset] = []
    @AppStorage("selectedDatasetID") private var selectedDatasetID: String = ""
    @AppStorage("embeddedDatasetIDs") private var embeddedDatasetIDsRaw: String = ""
    @Published var indexingDatasetID: String?
    struct AlertItem: Identifiable { let id = UUID(); let message: String }
    enum MediaImportProgressState: Equatable {
        case pending
        case transcribing
        case succeeded
        case failed(String)
    }
    struct MediaImportProgressItem: Identifiable, Equatable {
        let id: UUID
        let filename: String
        var state: MediaImportProgressState

        init(filename: String, state: MediaImportProgressState = .pending) {
            self.id = UUID()
            self.filename = filename
            self.state = state
        }
    }
    @Published var embedAlert: AlertItem?
    @Published var mediaImportProgressItems: [MediaImportProgressItem] = []
    @Published var processingStatus: [String: DatasetProcessingStatus] = [:]
    @AppStorage("indexingDatasetIDPersisted") private var persistedIndexingDatasetID: String = ""

    // MARK: - RAG-upgrade re-embed recommendation
    private static let ragNoticeAckKey = "ragUpgradeAcknowledgedDatasetIDs"
    /// Dataset ids whose "re-embed for the RAG improvements" notice the user has
    /// already seen (the row badge hides once its detail has been opened).
    @Published private(set) var ragNoticeAcknowledgedIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DatasetManager.ragNoticeAckKey) ?? [])

    /// Acknowledgement key is scoped to the current pipeline revision, so a future
    /// revision bump re-surfaces the badge for a dataset the user opened earlier.
    private func ragAckKey(_ id: String) -> String {
        "\(id)#\(DatasetIndexMetadata.currentPipelineRevision)"
    }

    /// Whether to show the small "outdated index" badge on a dataset row.
    func shouldShowRAGUpgradeNotice(for dataset: LocalDataset) -> Bool {
        isRAGIndexOutdated(for: dataset) && !ragNoticeAcknowledgedIDs.contains(ragAckKey(dataset.datasetID))
    }

    /// True when this dataset's index predates the current RAG pipeline (drives
    /// the in-detail re-embed recommendation, independent of acknowledgement).
    /// Managed (Enterprise) datasets are excluded — they are not user-re-embeddable.
    func isRAGIndexOutdated(for dataset: LocalDataset) -> Bool {
        let live = datasets.first(where: { $0.datasetID == dataset.datasetID }) ?? dataset
        return live.isIndexed && live.ragIndexOutdated && live.source != "Enterprise"
    }

    /// Marks the notice seen for a dataset (called when its detail is opened),
    /// which hides the row badge. The in-detail recommendation still shows.
    func acknowledgeRAGUpgradeNotice(for id: String) {
        let key = ragAckKey(id)
        guard !ragNoticeAcknowledgedIDs.contains(key) else { return }
        ragNoticeAcknowledgedIDs.insert(key)
        UserDefaults.standard.set(Array(ragNoticeAcknowledgedIDs), forKey: DatasetManager.ragNoticeAckKey)
    }

    /// Forces a fresh re-embed of an already-indexed dataset so it picks up the
    /// current RAG pipeline. Clears ALL regenerable artifacts (vectors, metadata,
    /// AND extracted/compacted text) so the pipeline genuinely re-extracts with
    /// the improved OCR/de-hyphenation — then runs the full embed (no plug-in
    /// pause; `startEmbeddingForID` re-reads the now-unindexed live entry).
    func reembedForRAGUpgrade(datasetID id: String) {
        guard datasets.contains(where: { $0.datasetID == id }) else { return }
        if let url = datasets.first(where: { $0.datasetID == id })?.url {
            DatasetIndexIO.clearAllIndexArtifacts(at: url)
        }
        Task { await DatasetRetriever.shared.purge(datasetID: id) }
        reloadFromDisk()
        startEmbeddingForID(id)
    }

    /// Download controller used to fetch the embedding model when missing.
    weak var downloadController: DownloadController?
    private var indexingTasks: [String: Task<Void, Never>] = [:]
    private var reloadGeneration: UInt64 = 0
    private var pendingReloadCompletions: [@MainActor () -> Void] = []
    // Throttle and coalesce frequent status updates to avoid UI flicker
    private var lastStatusByID: [String: DatasetProcessingStatus] = [:]
    private var lastStatusUpdateAt: [String: Date] = [:]

    /// Updates the processing status for a dataset with coalescing to minimize UI re-renders.
    /// - Uses a minimum interval between updates and only publishes when values meaningfully change.
    private func updateProcessingStatus(_ status: DatasetProcessingStatus, for id: String) {
        let now = Date()
        let last = lastStatusByID[id]
        let normalizedStatus = Self.normalizedStatusForForwardProgress(previous: last, incoming: status)
        let lastTime = lastStatusUpdateAt[id] ?? .distantPast
        let minInterval: TimeInterval = 0.2 // 5 fps update cadence is sufficient for progress UI

        // Only publish on a stage change or at the time-gated cadence. `processingStatus` is
        // @Published and observed app-wide (MainView/TabView), so each publish triggers a full
        // re-render. The previous `progressDelta >= 0.01` escape hatch bypassed the time cap when
        // chunks embedded faster than 1%/0.2s, storming the UI during fast embedding — drop it so
        // progress updates are strictly capped to `minInterval` (stage changes still fire immediately).
        let stageChanged = last?.stage != normalizedStatus.stage
        let transitionedToCompleted = (last?.stage != .completed) && (normalizedStatus.stage == .completed)
        let timeElapsed = now.timeIntervalSince(lastTime)
        if stageChanged || timeElapsed >= minInterval {
            processingStatus[id] = normalizedStatus
            lastStatusByID[id] = normalizedStatus
            lastStatusUpdateAt[id] = now
            if transitionedToCompleted {
                Haptics.success()
            }
            if normalizedStatus.stage == .failed, normalizedStatus.message == String(localized: "Stopped", locale: LocalizationManager.preferredLocale()) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.processingStatus[id] = nil
                    self?.lastStatusByID[id] = nil
                    self?.lastStatusUpdateAt[id] = nil
                }
            }
        }
    }

    static func normalizedStatusForForwardProgress(
        previous: DatasetProcessingStatus?,
        incoming: DatasetProcessingStatus
    ) -> DatasetProcessingStatus {
        guard let previous, previous.stage == incoming.stage else {
            return incoming
        }
        guard incoming.stage != .completed, incoming.stage != .failed else {
            return incoming
        }
        let clampedProgress = max(previous.progress, incoming.progress)
        guard clampedProgress != incoming.progress else {
            return incoming
        }
        return DatasetProcessingStatus(
            stage: incoming.stage,
            progress: clampedProgress,
            message: incoming.message,
            etaSeconds: incoming.etaSeconds
        )
    }

    init() {
        // Persist dataset selection across launches; only clear when the user disables it.
        reloadFromDisk()
        // If the app was terminated mid-index, don't resume automatically on next launch.
        // Treat termination as the user choosing to embed later from the dataset settings.
        if !persistedIndexingDatasetID.isEmpty {
            Task { await logger.log("[DatasetManager] Clearing persisted indexing ID on launch: \(persistedIndexingDatasetID)") }
            persistedIndexingDatasetID = ""
        }
        NotificationCenter.default.addObserver(
            forName: .enterpriseDatasetsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Pull the Sendable payload out of the (non-Sendable) Notification before
            // hopping into MainActor isolation.
            let downloaded = note.userInfo?["downloadedDatasetIDs"] as? [String] ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadFromDisk()
                // Newly downloaded enterprise datasets enter the same post-download
                // pipeline as any other dataset (indexing/embedding).
                for datasetID in downloaded {
                    self.handleDatasetDownloadCompleted(datasetID: datasetID)
                }
            }
        }
        #if os(iOS) && canImport(ActivityKit)
        // Mirror dataset preparation onto the system Live Activity
        // (lock screen + Dynamic Island).
        DatasetLiveActivityController.shared.bind(to: self)
        #endif
    }

    func bind(downloadController: DownloadController) {
        self.downloadController = downloadController
    }

    /// Reload the dataset list from disk. The scan (directory enumeration plus per-dataset
    /// size and index-state checks) is pure file I/O that previously ran synchronously on the
    /// MainActor, hitching the UI whenever datasets changed or indexing finished. It now runs
    /// on a background task and applies/publishes on the MainActor. Callers that depend on the
    /// publish having happened (e.g. to enqueue indexing afterwards) pass `completion`, which
    /// runs after the publish.
    func reloadFromDisk(completion: (@MainActor () -> Void)? = nil) {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        if let completion {
            pendingReloadCompletions.append(completion)
        }
        let selectedID = selectedDatasetID
        let enterpriseOwnerDir = EnterpriseDatasetStore.ownerDirectoryName
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Self.scanDatasetsOnDisk(selectedDatasetID: selectedID, enterpriseOwnerDir: enterpriseOwnerDir)
            }.value
            guard let self else { return }
            guard generation == self.reloadGeneration else { return }
            self.applyReloadedDatasets(found)
            let completions = self.pendingReloadCompletions
            self.pendingReloadCompletions.removeAll(keepingCapacity: true)
            completions.forEach { $0() }
        }

        // Do not auto-index here; indexing is started explicitly after download
        // or via a user action in dataset settings.
    }

    /// Pure file-I/O scan of the datasets directory. Declared `nonisolated static` so it can
    /// run off the MainActor without touching any actor-isolated state.
    nonisolated private static func scanDatasetsOnDisk(
        selectedDatasetID: String,
        enterpriseOwnerDir: String
    ) -> [LocalDataset] {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        let fm = FileManager.default
        var found: [LocalDataset] = []
        if let owners = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for owner in owners {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: owner.path, isDirectory: &isDir), isDir.boolValue {
                    if let datasets = try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
                        for dir in datasets {
                            var isDir2: ObjCBool = false
                            if fm.fileExists(atPath: dir.path, isDirectory: &isDir2), isDir2.boolValue {
                                let size = (try? directorySize(at: dir)) ?? 0
                                let sizeMB = Double(size) / 1_048_576.0
                                let attrs = try? fm.attributesOfItem(atPath: dir.path)
                                let created = attrs?[.creationDate] as? Date ?? Date()
                                let id = owner.lastPathComponent + "/" + dir.lastPathComponent
                                let hasValidIndex = DatasetIndexIO.hasValidIndex(at: dir)
                                let hasIndexArtifacts = DatasetIndexIO.hasIndexArtifacts(at: dir)
                                let sourceName: String = {
                                    let ownerName = owner.lastPathComponent
                                    if ownerName == "OTL" { return "Open Textbook Library" }
                                    if ownerName == "Imported" { return "Imported" }
                                    if ownerName == "PACK" { return "Knowledge Pack" }
                                    if ownerName == enterpriseOwnerDir { return "Enterprise" }
                                    return "Hugging Face"
                                }()
                                let displayName: String = {
                                    if let title = DatasetTextReader.readString(from: DatasetIndexIO.titleURL(for: dir))?
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                       !title.isEmpty {
                                        return title
                                    }
                                    return dir.lastPathComponent
                                }()
                                found.append(
                                    LocalDataset(
                                        datasetID: id,
                                        name: displayName,
                                        url: dir,
                                        sizeMB: sizeMB,
                                        source: sourceName,
                                        downloadDate: created,
                                        lastUsedDate: nil,
                                        isSelected: selectedDatasetID == id,
                                        isIndexed: hasValidIndex,
                                        requiresReindex: hasIndexArtifacts && !hasValidIndex,
                                        ragIndexOutdated: hasValidIndex && DatasetIndexIO.isPipelineOutdated(at: dir)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
        return found
    }

    /// Background-safe enumeration of indexed, policy-allowed datasets for tool use
    /// (e.g. `noema.rag.search`). Does not require a live MainActor `DatasetManager`
    /// instance: it scans disk and applies the same Enterprise policy filter that
    /// `applyReloadedDatasets` does, so governed Teams datasets are never exposed.
    nonisolated static func indexedDatasetsForTooling() -> [LocalDataset] {
        scanDatasetsOnDisk(selectedDatasetID: "", enterpriseOwnerDir: EnterpriseDatasetStore.ownerDirectoryName)
            .filter { $0.isIndexed && !$0.requiresReindex && EnterprisePolicyGate.allowsDataset(datasetID: $0.datasetID) }
    }

    /// Apply a freshly scanned dataset list on the MainActor: enforce enterprise policy,
    /// compute processing status, and publish.
    private func applyReloadedDatasets(_ scanned: [LocalDataset]) {
        var found = scanned
        // Noema Teams policy: enterprise datasets are only listed for permitted roles;
        // personal datasets are never affected.
        found.removeAll { !EnterprisePolicyGate.allowsDataset(datasetID: $0.datasetID) }
        if !selectedDatasetID.isEmpty,
           selectedDatasetID.hasPrefix("\(EnterpriseDatasetStore.ownerDirectoryName)/"),
           !EnterprisePolicyGate.allowsDataset(datasetID: selectedDatasetID) {
            selectedDatasetID = ""
            UserDefaults.standard.set("", forKey: "selectedDatasetID")
        }
        let embedded = Set(embeddedDatasetIDsRaw.split(separator: ",").map(String.init))
        var computedStatus: [String: DatasetProcessingStatus] = [:]
        for ds in found {
            if let existing = processingStatus[ds.datasetID], existing.stage != .completed {
                computedStatus[ds.datasetID] = existing
            } else if ds.isIndexed {
                if !embedded.contains(ds.datasetID) { markEmbedded(ds.datasetID) }
                computedStatus[ds.datasetID] = DatasetProcessingStatus(
                    stage: .completed,
                    progress: 1.0,
                    message: String(localized: "Ready for use", locale: LocalizationManager.preferredLocale()),
                    etaSeconds: 0
                )
            }
        }
        self.datasets = found
        self.processingStatus = computedStatus
        self.lastStatusByID = computedStatus
        self.scheduleSpotlightDatasetNameIndex()

        if let current = self.indexingDatasetID {
            let stillIndexing = self.datasets.contains { $0.datasetID == current && !$0.isIndexed }
            if !stillIndexing {
                self.indexingDatasetID = nil
                self.persistedIndexingDatasetID = ""
            }
        }
    }

    private func scheduleSpotlightDatasetNameIndex() {
        let records = datasets.map { dataset in
            let trimmedName = dataset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedName.isEmpty ? dataset.datasetID : trimmedName
            return NoemaSpotlightIndexRecord(
                uniqueIdentifier: NoemaSpotlightIndexingService.datasetIdentifier(for: dataset.datasetID),
                title: title,
                contentDescription: String(localized: "Noema Stored dataset"),
                keywords: ["Noema", "dataset", dataset.source]
            )
        }
        NoemaSpotlightIndexingService.shared.scheduleDatasetNameIndex(records: records)
    }

    nonisolated private static func directorySize(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var total: Int64 = 0
        while let next = enumerator?.nextObject() as? URL {
            let values = try next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    func delete(_ ds: LocalDataset) throws {
        cancelProcessingForID(ds.datasetID)
        // Remove on-disk dataset directory first
        try FileManager.default.removeItem(at: ds.url)
        // Purge embeddings cache and vectors file for this dataset
        Task { await DatasetRetriever.shared.purge(datasetID: ds.datasetID) }
        if selectedDatasetID == ds.datasetID { selectedDatasetID = "" }
        var set = Set(embeddedDatasetIDsRaw.split(separator: ",").map(String.init))
        set.remove(ds.datasetID)
        embeddedDatasetIDsRaw = set.joined(separator: ",")
        processingStatus[ds.datasetID] = nil
        reloadFromDisk()
    }

    func cancelProcessingForID(_ id: String) {
        Task { await logger.log("[DatasetManager] Cancelling processing for: \(id)") }
        let hadTask = indexingTasks[id] != nil
        indexingTasks[id]?.cancel()
        indexingTasks[id] = nil
        if indexingDatasetID == id { indexingDatasetID = nil }
        if persistedIndexingDatasetID == id { persistedIndexingDatasetID = "" }
        if !hadTask {
            processingStatus[id] = nil
            lastStatusByID[id] = nil
            lastStatusUpdateAt[id] = nil
        }
        // Keep the last known status so the pipeline can publish a final "Stopped" state.
        // It will be cleared after the final update is processed.
    }

    func select(_ ds: LocalDataset?) {
        if let ds, !EnterprisePolicyGate.allowsDataset(datasetID: ds.datasetID) {
            Task { await logger.log("[DatasetManager] select blocked by enterprise policy: \(ds.datasetID)") }
            return
        }
        let nextID = ds?.datasetID ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectedDatasetID = nextID
            // Reflect dataset active/idle state in UserDefaults keys used by WebToolGate
            let d = UserDefaults.standard
            d.set(nextID, forKey: "selectedDatasetID")
            self.reloadFromDisk()
        }
        // Do not auto-download/embedder or auto-index here; user must trigger manually in UI.
    }

    var selectedDataset: LocalDataset? {
        datasets.first { $0.datasetID == selectedDatasetID }
    }

    func ensureIndexedForID(_ id: String) {
        Task { await logger.log("[DatasetManager] ensureIndexedForID called for: \(id)") }
        if let ds = datasets.first(where: { $0.datasetID == id }) {
            ensureIndexed(ds)
        } else {
            Task { await logger.log("[DatasetManager] ❌ Dataset not found for ID: \(id)") }
        }
    }

    /// Called after a dataset download completes to ensure it appears in Stored immediately and, if desired,
    /// kick off the pre-embedding indexing pipeline.
    func handleDatasetDownloadCompleted(datasetID: String) {
        Task { await logger.log("[DatasetManager] Dataset download completed: \(datasetID)") }
        // Enqueue indexing only after `reloadFromDisk` has published, so the dataset is visible
        // in Stored before the indexing banner appears.
        reloadFromDisk { [weak self] in
            // Give one more turn of the runloop so AppModelManager's `downloadedDatasets` mirror updates too.
            DispatchQueue.main.async { [weak self] in
                self?.ensureIndexedForID(datasetID)
            }
        }
    }
    
    /// Auto-index newly downloaded datasets
    func autoIndexNewDatasets() {
        Task { await logger.log("[DatasetManager] Checking for datasets to auto-index...") }
        for ds in datasets {
            // Skip if the dataset is already finished processing according to our in-memory status, even if the
            // vectors.json file hasn’t been observed on disk yet. This prevents accidentally re-queuing the
            // embedding pipeline due to subtle file-system timing issues.
            let alreadyCompleted = processingStatus[ds.datasetID]?.stage == .completed
            if !ds.isIndexed && !alreadyCompleted && indexingDatasetID != ds.datasetID {
                Task { await logger.log("[DatasetManager] Auto-indexing new dataset: \(ds.datasetID)") }
                ensureIndexed(ds)
                break // Only index one at a time
            }
        }
    }

    private func ensureIndexed(_ ds: LocalDataset) {
        guard !ds.isIndexed else {
            Task { await logger.log("[DatasetManager] ensureIndexed called but dataset already indexed: \(ds.datasetID)") }
            // Clear any stale indexing state so the UI isn't locked out
            if indexingDatasetID == ds.datasetID {
                indexingDatasetID = nil
            }
            if persistedIndexingDatasetID == ds.datasetID {
                persistedIndexingDatasetID = ""
            }
            return
        }
        if indexingTasks[ds.datasetID] != nil { return }

        Task { await logger.log("[DatasetManager] Starting indexing for dataset: \(ds.datasetID)") }
        indexingDatasetID = ds.datasetID
        persistedIndexingDatasetID = ds.datasetID

        let t = Task {
            // No download here; strict on-demand handled by Use Dataset flow
            Task { await logger.log("[DatasetManager] Ensuring embedding model for: \(ds.datasetID)") }
            // Ensure model directory and download model if missing so embedding can proceed
            await EmbeddingModel.shared.ensureModel()
            if !(await EmbeddingModel.shared.isModelAvailable()) {
                await MainActor.run {
                    self.processingStatus[ds.datasetID] = DatasetProcessingStatus(
                        stage: .embedding,
                        progress: 0.0,
                        message: String(localized: "Downloading embedding model…", locale: LocalizationManager.preferredLocale()),
                        etaSeconds: nil
                    )
                }
                let installTask = Task { @MainActor in
                    let installer = EmbedModelInstaller()
                    await installer.installIfNeeded()
                }
                _ = await installTask.value
            }
            
            Task { await logger.log("[DatasetManager] Starting DatasetRetriever.prepare for: \(ds.datasetID)") }
            await DatasetRetriever.shared.prepare(dataset: ds, pauseBeforeEmbedding: true) { status in
                self.updateProcessingStatus(status, for: ds.datasetID)
                // Stream logs to file on each update for transparency
                let pct = Int(status.progress * 100)
                let stage = self.stageName(status.stage)
                let etaStr: String = {
                    if let e = status.etaSeconds, e > 0 { return String(format: "~%dm %02ds", Int(e)/60, Int(e)%60) }
                    return "…"
                }()
                Task { await logger.log("[RAG][UI] \(ds.datasetID) \(stage) \(pct)% ETA \(etaStr) – \(status.message ?? "")") }
            }
            
            await MainActor.run {
                // Keep the banner only while paused at the confirmation gate.
                let status = self.processingStatus[ds.datasetID]
                let stage = status?.stage
                let awaitingEmbeddingConfirmation = (stage == .embedding && (status?.progress ?? 1.0) <= 0.0001)
                if stage == .completed {
                    Task { await logger.log("[DatasetManager] Indexing completed for: \(ds.datasetID)") }
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                    self.reloadFromDisk()
                    // Milestone: dataset embedded successfully (enables RAG). Do not prompt yet;
                    // we’ll prompt after a successful chat turn or other milestone.
                    ReviewPrompter.shared.noteDatasetEmbedded()
                } else if stage == .failed {
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                } else if !awaitingEmbeddingConfirmation {
                    // Defensive cleanup for unexpected terminal states (e.g. cancellation).
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                }
                self.indexingTasks[ds.datasetID] = nil
            }
        }
        indexingTasks[ds.datasetID] = t
    }

    /// Explicit user-triggered embedding: proceed through embedding automatically (no pause gate)
    func startEmbeddingForID(_ id: String) {
        Task { await logger.log("[DatasetManager] startEmbeddingForID called for: \(id)") }
        guard let ds = datasets.first(where: { $0.datasetID == id }) else {
            Task { await logger.log("[DatasetManager] ❌ Dataset not found for ID: \(id)") }
            return
        }
        if ds.isIndexed {
            Task { await logger.log("[DatasetManager] startEmbeddingForID: already indexed: \(ds.datasetID)") }
            return
        }
        if indexingTasks[ds.datasetID] != nil { return }
        indexingDatasetID = ds.datasetID
        persistedIndexingDatasetID = ds.datasetID
        let t = Task {
            // Ensure model present/installed
            await EmbeddingModel.shared.ensureModel()
            if !(await EmbeddingModel.shared.isModelAvailable()) {
                await MainActor.run {
                    self.updateProcessingStatus(
                        DatasetProcessingStatus(
                            stage: .embedding,
                            progress: 0.0,
                            message: String(localized: "Downloading embedding model…", locale: LocalizationManager.preferredLocale()),
                            etaSeconds: nil
                        ),
                        for: ds.datasetID
                    )
                }
                let installer = EmbedModelInstaller()
                // Stream installer progress into the dataset status so the UI reflects download progress
                let progressTask = Task { @MainActor in
                    while !Task.isCancelled {
                        switch installer.state {
                        case .downloading, .verifying, .installing:
                            // Map installer progress directly to the status progress for clear feedback
                            let p = max(0.0, min(1.0, installer.progress))
                            self.updateProcessingStatus(
                                DatasetProcessingStatus(
                                    stage: .embedding,
                                    progress: p,
                                    message: String(localized: "Downloading embedding model…", locale: LocalizationManager.preferredLocale()),
                                    etaSeconds: nil
                                ),
                                for: ds.datasetID
                            )
                        default:
                            break
                        }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
                await installer.installIfNeeded()
                progressTask.cancel()
                // Handle download failure explicitly and stop indexing so the user can retry
                switch installer.state {
                case .failed(let msg):
                    await MainActor.run {
                        self.processingStatus[ds.datasetID] = DatasetProcessingStatus(
                            stage: .failed,
                            progress: 0.0,
                            message: String.localizedStringWithFormat(
                                String(localized: "Failed to download embedding model: %@", locale: LocalizationManager.preferredLocale()),
                                msg
                            ),
                            etaSeconds: nil
                        )
                        self.indexingDatasetID = nil
                        self.persistedIndexingDatasetID = ""
                        self.indexingTasks[ds.datasetID] = nil
                    }
                    return
                default:
                    break
                }
            }

            await DatasetRetriever.shared.prepare(dataset: ds, pauseBeforeEmbedding: false) { status in
                self.updateProcessingStatus(status, for: ds.datasetID)
                let pct = Int(status.progress * 100)
                let stage = self.stageName(status.stage)
                let etaStr: String = {
                    if let e = status.etaSeconds, e > 0 { return String(format: "~%dm %02ds", Int(e)/60, Int(e)%60) }
                    return "…"
                }()
                Task { await logger.log("[RAG][UI] \(ds.datasetID) \(stage) \(pct)% ETA \(etaStr) – \(status.message ?? "")") }
            }

            await MainActor.run {
                let stage = self.processingStatus[ds.datasetID]?.stage
                if stage == .completed {
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                    self.reloadFromDisk()
                } else {
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                }
                self.indexingTasks[ds.datasetID] = nil
            }
        }
        indexingTasks[ds.datasetID] = t
    }

    func rebuildDatasetsNeedingReindex() async {
        reloadFromDisk()
        let staleIDs = datasets.filter(\.requiresReindex).map(\.datasetID)
        guard !staleIDs.isEmpty else { return }

        Task { await logger.log("[DatasetManager] Rebuilding \(staleIDs.count) dataset(s) that need reindexing") }
        for datasetID in staleIDs {
            if Task.isCancelled { break }
            reloadFromDisk()
            guard let dataset = datasets.first(where: { $0.datasetID == datasetID }),
                  dataset.requiresReindex else {
                continue
            }
            if indexingTasks[datasetID] != nil {
                Task { await logger.log("[DatasetManager] Skipping rebuild for \(datasetID) because indexing is already running") }
                continue
            }

            startEmbeddingForID(datasetID)
            while indexingTasks[datasetID] != nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        reloadFromDisk()
    }

    // Public API: background start indexing after a download completes
    /// - Parameter autoEmbed: when true, run straight through embedding to `.completed`
    ///   instead of pausing at the embedding gate awaiting user confirmation. Used by the
    ///   macOS composer attach so an attached PDF is immediately ready for RAG.
    public func startIndexing(dataset: LocalDataset, autoEmbed: Bool = false) {
        if indexingTasks[dataset.datasetID] != nil { return }
        let t = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await logger.log("[DatasetManager] Starting background indexing for downloaded dataset: \(dataset.datasetID)")
            await MainActor.run {
                self.indexingDatasetID = dataset.datasetID
                self.persistedIndexingDatasetID = dataset.datasetID
            }
            // Ensure model folder and download model if missing
            await EmbeddingModel.shared.ensureModel()
            if !(await EmbeddingModel.shared.isModelAvailable()) {
                await MainActor.run {
                    self.processingStatus[dataset.datasetID] = DatasetProcessingStatus(
                        stage: .embedding,
                        progress: 0.0,
                        message: String(localized: "Downloading embedding model…", locale: LocalizationManager.preferredLocale()),
                        etaSeconds: nil
                    )
                }
                let installTask = Task { @MainActor in
                    let installer = EmbedModelInstaller()
                    await installer.installIfNeeded()
                }
                _ = await installTask.value
            }
            await DatasetRetriever.shared.prepare(dataset: dataset, pauseBeforeEmbedding: !autoEmbed) { status in
                self.updateProcessingStatus(status, for: dataset.datasetID)
            }
            await MainActor.run {
                let status = self.processingStatus[dataset.datasetID]
                let stage = status?.stage
                let awaitingEmbeddingConfirmation = (stage == .embedding && (status?.progress ?? 1.0) <= 0.0001)
                if stage == .completed {
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                    self.reloadFromDisk()
                    ReviewPrompter.shared.noteDatasetEmbedded()
                } else if stage == .failed {
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                } else if !awaitingEmbeddingConfirmation {
                    self.indexingDatasetID = nil
                    self.persistedIndexingDatasetID = ""
                }
                self.indexingTasks[dataset.datasetID] = nil
            }
        }
        indexingTasks[dataset.datasetID] = t
    }

    private func stageName(_ s: DatasetProcessingStage) -> String {
        switch s {
        case .extracting:
            return String(localized: "Extracting", locale: LocalizationManager.preferredLocale())
        case .compressing:
            return String(localized: "Compressing", locale: LocalizationManager.preferredLocale())
        case .embedding:
            return String(localized: "Embedding", locale: LocalizationManager.preferredLocale())
        case .completed:
            return String(localized: "Ready", locale: LocalizationManager.preferredLocale())
        case .failed:
            return String(localized: "Failed", locale: LocalizationManager.preferredLocale())
        }
    }
    
    private func markEmbedded(_ id: String) {
        var set = Set(embeddedDatasetIDsRaw.split(separator: ",").map(String.init))
        set.insert(id)
        embeddedDatasetIDsRaw = set.joined(separator: ",")
    }

    // MARK: - Import from Files

    /// Import local documents (PDF/EPUB/TXT) and transcribable media from Files into a new dataset under `Documents/LocalLLMDatasets/Imported/<name>`.
    /// - Returns: The created `LocalDataset` if successful, otherwise nil.
    @discardableResult
    func importDocuments(from urls: [URL], suggestedName: String?) async -> LocalDataset? {
        // Filter allowed extensions
        let allowedExts: Set<String> = ["pdf", "epub", "txt", "md", "json", "jsonl", "csv", "tsv"]
        let picked = urls.filter {
            allowedExts.contains($0.pathExtension.lowercased()) || TranscriptionMediaSupport.isSupported($0)
        }
        guard !picked.isEmpty else { return nil }
        let documentPicked = picked.filter { allowedExts.contains($0.pathExtension.lowercased()) }
        let mediaPicked = picked.filter { TranscriptionMediaSupport.isSupported($0) }

        // Pick a dataset name
        let defaultName: String = {
            if let s = suggestedName, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            // Prefer first PDF/EPUB name; fallback to first file name
            if let u = picked.first(where: { ["pdf", "epub"].contains($0.pathExtension.lowercased()) }) ?? picked.first {
                let base = u.deletingPathExtension().lastPathComponent
                return DatasetManager.humanizeFileName(base)
            }
            return String(localized: "Imported Dataset", locale: LocalizationManager.preferredLocale())
        }()

        // Build destination directory
        let (datasetID, destDir) = DatasetManager.makeImportedDatasetDir(named: defaultName)

        // Copy can be slow (especially with many files / iCloud Drive). Keep it off the main actor
        // so rotations and app switching don't trip watchdog terminations.
        let copiedAny: Bool = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                return false
            }

            var didCopy = false
            var usedRelativePaths = Set<String>()
            for url in documentPicked {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let relativePath = DatasetPathing.uniqueRelativePath(url.lastPathComponent, existing: usedRelativePaths)
                    usedRelativePaths.insert(relativePath)
                    let dest = DatasetPathing.destinationURL(for: relativePath, in: destDir)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: url, to: dest)
                    didCopy = true
                } catch {
                    // Best-effort: continue copying other files
                }
            }

            let titleURL = DatasetIndexIO.titleURL(for: destDir)
            try? defaultName.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)?.write(to: titleURL)
            return didCopy || !mediaPicked.isEmpty
        }.value

        guard copiedAny else {
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: destDir)
            }.value
            return nil
        }

        var didTranscribeMedia = false
        var mediaTranscriptionFailures: [String] = []
        mediaImportProgressItems = mediaPicked.map { MediaImportProgressItem(filename: $0.lastPathComponent) }
        if !mediaPicked.isEmpty {
            let mediaTranscriptDir = destDir.appendingPathComponent("Media Transcripts", isDirectory: true)
            let metadataDir = DatasetIndexIO.transcriptMetadataDirectoryURL(for: destDir)
            try? FileManager.default.createDirectory(at: mediaTranscriptDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
            let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
            let options = TranscriptionSettings.requestOptions(offGrid: offGrid)

            do {
                let backend: any TranscriptionBackend = try Self.makeTranscriptionBackend(TranscriptionSettings.selectedEngineID)
                for mediaURL in mediaPicked {
                    let scoped = mediaURL.startAccessingSecurityScopedResource()
                    defer { if scoped { mediaURL.stopAccessingSecurityScopedResource() } }
                    Self.updateMediaImportProgress(filename: mediaURL.lastPathComponent, state: .transcribing, items: &mediaImportProgressItems)
                    do {
                        let rawArtifact = try await backend.transcribe(
                            mediaURL: mediaURL,
                            originalFilename: mediaURL.lastPathComponent,
                            options: options,
                            onEvent: { _ in }
                        )
                        let artifact = rawArtifact.withProvenance(engineID: TranscriptionSettings.selectedEngineID, options: options)
                        let safeBase = mediaURL.deletingPathExtension().lastPathComponent
                            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
                        let base = safeBase.isEmpty ? artifact.id.uuidString : safeBase
                        let textURL = mediaTranscriptDir.appendingPathComponent(base + ".transcript.txt")
                        let jsonURL = metadataDir.appendingPathComponent(base + ".transcript.json")
                        try artifact.exportText.data(using: .utf8)?.write(to: textURL, options: [.atomic])
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        try encoder.encode(artifact).write(to: jsonURL, options: [.atomic])
                        didTranscribeMedia = true
                        Self.updateMediaImportProgress(filename: mediaURL.lastPathComponent, state: .succeeded, items: &mediaImportProgressItems)
                    } catch {
                        mediaTranscriptionFailures.append(Self.mediaImportFailureLine(filename: mediaURL.lastPathComponent, error: error))
                        Self.updateMediaImportProgress(filename: mediaURL.lastPathComponent, state: .failed(error.localizedDescription), items: &mediaImportProgressItems)
                    }
                }
            } catch {
                for mediaURL in mediaPicked {
                    mediaTranscriptionFailures.append(Self.mediaImportFailureLine(filename: mediaURL.lastPathComponent, error: error))
                    Self.updateMediaImportProgress(filename: mediaURL.lastPathComponent, state: .failed(error.localizedDescription), items: &mediaImportProgressItems)
                }
            }
        }

        guard !documentPicked.isEmpty || didTranscribeMedia else {
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: destDir)
            }.value
            if !mediaTranscriptionFailures.isEmpty {
                embedAlert = AlertItem(message: String.localizedStringWithFormat(
                    String(localized: "Media could not be transcribed: %@"),
                    Self.mediaImportFailureSummary(mediaTranscriptionFailures)
                ))
            }
            return nil
        }

        // Refresh in-memory list and return the created dataset
        reloadFromDisk()
        if !mediaTranscriptionFailures.isEmpty {
            embedAlert = AlertItem(message: String.localizedStringWithFormat(
                String(localized: "Some media could not be transcribed: %@"),
                Self.mediaImportFailureSummary(mediaTranscriptionFailures)
            ))
        }
        if let ds = datasets.first(where: { $0.datasetID == datasetID }) {
            return ds
        }
        let size = (try? Self.directorySize(at: destDir)) ?? 0
        let sizeMB = Double(size) / 1_048_576.0
        let attrs = try? FileManager.default.attributesOfItem(atPath: destDir.path)
        let created = attrs?[.creationDate] as? Date ?? Date()
        return LocalDataset(
            datasetID: datasetID,
            name: defaultName,
            url: destDir,
            sizeMB: sizeMB,
            source: "Imported",
            downloadDate: created,
            lastUsedDate: nil,
            isSelected: selectedDatasetID == datasetID,
            isIndexed: DatasetIndexIO.hasValidIndex(at: destDir),
            requiresReindex: DatasetIndexIO.hasIndexArtifacts(at: destDir) && !DatasetIndexIO.hasValidIndex(at: destDir)
        )
    }

    private static func mediaImportFailureLine(filename: String, error: Error) -> String {
        "\(filename): \(error.localizedDescription)"
    }

    private static func updateMediaImportProgress(filename: String, state: MediaImportProgressState, items: inout [MediaImportProgressItem]) {
        guard let index = items.firstIndex(where: { $0.filename == filename }) else { return }
        items[index].state = state
    }

    private static func mediaImportFailureSummary(_ failures: [String]) -> String {
        var lines = failures.prefix(3).map(\.self)
        if failures.count > lines.count {
            lines.append(String.localizedStringWithFormat(
                String(localized: "%d more media files failed."),
                failures.count - lines.count
            ))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers
    private static func makeImportedDatasetDir(named name: String) -> (String, URL) {
        var base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        base.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        base.appendPathComponent("Imported", isDirectory: true)

        let slug = slugify(name)
        var dir = base.appendingPathComponent(slug, isDirectory: true)
        var finalSlug = slug
        var suffix = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            finalSlug = slug + "-" + String(suffix)
            dir = base.appendingPathComponent(finalSlug, isDirectory: true)
            suffix += 1
        }
        let id = "Imported/" + finalSlug
        return (id, dir)
    }

    private static func slugify(_ s: String) -> String {
        let invalid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
        t = t.components(separatedBy: invalid).joined(separator: "")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if t.isEmpty { t = "dataset" }
        return t.lowercased()
    }

    private static func humanizeFileName(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

#if canImport(UIKit) || os(macOS)
struct DatasetRow: View {
    let dataset: LocalDataset
    let indexing: Bool
    var deleteAction: (() -> Void)? = nil
    @EnvironmentObject var datasetManager: DatasetManager
    @EnvironmentObject var modelManager: AppModelManager
    @Environment(\.locale) private var locale
    #if os(macOS)
    @State private var isHovered = false
    #endif
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 20))
                .foregroundStyle(AppTheme.secondaryText)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(dataset.name)
                        .font(FontTheme.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.text)
                    if datasetManager.shouldShowRAGUpgradeNotice(for: dataset) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(Text(LocalizedStringKey("Re-embedding recommended")))
                    }
                }

                HStack(spacing: 6) {
                    if dataset.source == "Enterprise" {
                        // Governed company dataset: distinct badge instead of a plain source label.
                        HStack(spacing: 4) {
                            Image(systemName: "building.2.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(LocalizedStringKey("Company"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.13), in: Capsule())
                    } else {
                        Text(dataset.source)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.top, 2)
            }
            Spacer()
            statusView
        }
        .padding(.vertical, 8)
        #if os(macOS)
        .overlay(alignment: .topTrailing) {
            if isHovered, let deleteAction {
                Button(action: deleteAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Delete dataset")
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    @ViewBuilder
    private var statusView: some View {
        let status = datasetManager.processingStatus[dataset.datasetID]
        let isProcessing = indexing || (status != nil && status?.stage != .completed)
        VStack(alignment: .trailing, spacing: 4) {
            Text(localizedFileSizeString(bytes: Int64(dataset.sizeMB * 1_048_576.0), locale: locale))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText)
            
            if isProcessing, let s = status {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color.gray.opacity(0.3), lineWidth: 3).frame(width: 14, height: 14)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0, min(1, s.progress))))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 14, height: 14)
                    }
                    Text("\(Int(s.progress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                
                Text(stageLabel(s.stage))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText)
                if let m = s.message, !m.isEmpty {
                    Text(m)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)
                }
            } else if modelManager.activeDataset?.datasetID == dataset.datasetID {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                    Text("Active")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private func stageLabel(_ s: DatasetProcessingStage) -> String {
        switch s {
        case .extracting:
            return String(localized: "Extracting", locale: locale)
        case .compressing:
            return String(localized: "Compressing", locale: locale)
        case .embedding:
            return String(localized: "Embedding", locale: locale)
        case .completed:
            return String(localized: "Ready", locale: locale)
        case .failed:
            return String(localized: "Failed", locale: locale)
        }
    }
}
#endif
