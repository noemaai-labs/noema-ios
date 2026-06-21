import Foundation

enum DownloadPersistencePaths {
    static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        ensureDirectory(base)
        return base
    }

    static var queueFileURL: URL {
        baseDirectory.appendingPathComponent("queue.json")
    }

    static var resumeDataDirectory: URL {
        let url = baseDirectory.appendingPathComponent("resume-data", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    static func resumeDataURL(jobID: String, artifactID: String) -> URL {
        resumeDataDirectory.appendingPathComponent("\(jobID)-\(artifactID).resume")
    }

    private static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum DownloadJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case scheduled
    case preparing
    case downloading
    case paused
    case waitingForConnectivity
    case retrying
    case verifying
    case finalizing
    case completed
    case failed
    case cancelled
}

enum DownloadArtifactState: String, Codable, CaseIterable, Sendable {
    case queued
    case preparing
    case downloading
    case paused
    case waitingForConnectivity
    case retrying
    case verifying
    case finalizing
    case completed
    case failed
    case cancelled
}

enum DownloadArtifactRole: String, Codable, CaseIterable, Sendable {
    case mainWeights
    case weightShard
    case projector
    case importanceMatrix
    case mtp
    case modelSidecar
    case leapBundle
    case leapManifest
    case leapManifestAsset
    case datasetFile
    case embeddingModel
    case whisperModel
}

struct ModelDownloadOwner: Codable, Hashable, Sendable {
    let detail: ModelDetails
    let quant: QuantInfo
}

struct LeapDownloadOwner: Codable, Hashable, Sendable {
    let entry: LeapCatalogEntry
}

struct DatasetDownloadOwner: Codable, Hashable, Sendable {
    let detail: DatasetDetails
}

struct EmbeddingDownloadOwner: Hashable, Sendable {
    let recordID: String?
    let artifactID: String?
    let repoID: String
    let filename: String?

    init(repoID: String) {
        self.recordID = nil
        self.artifactID = nil
        self.repoID = repoID
        self.filename = nil
    }

    init(record: EmbeddingModelRecord, artifact: EmbeddingModelArtifact) {
        self.recordID = record.id
        self.artifactID = artifact.id
        self.repoID = artifact.repoID
        self.filename = artifact.filename
    }
}

extension EmbeddingDownloadOwner: Codable {
    private enum CodingKeys: String, CodingKey {
        case recordID
        case artifactID
        case repoID
        case filename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try container.decodeIfPresent(String.self, forKey: .recordID)
        artifactID = try container.decodeIfPresent(String.self, forKey: .artifactID)
        repoID = try container.decode(String.self, forKey: .repoID)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(recordID, forKey: .recordID)
        try container.encodeIfPresent(artifactID, forKey: .artifactID)
        try container.encode(repoID, forKey: .repoID)
        try container.encodeIfPresent(filename, forKey: .filename)
    }

    var externalID: String {
        recordID ?? repoID
    }
}

struct WhisperDownloadOwner: Codable, Hashable, Sendable {
    let recordID: String
    let artifactID: String
    let runtimeRawValue: String
    let repoID: String
    let resourcePath: String

    init(record: WhisperModelRecord, artifact: WhisperArtifact) {
        self.recordID = record.id
        self.artifactID = artifact.id
        self.runtimeRawValue = artifact.runtime.rawValue
        self.repoID = artifact.repoID
        self.resourcePath = artifact.resourcePath
    }

    var runtime: WhisperRuntimeFormat {
        WhisperRuntimeFormat(rawValue: runtimeRawValue) ?? .ggml
    }

    var externalID: String {
        "whisper:\(runtimeRawValue):\(recordID)"
    }
}

enum DownloadOwner: Hashable, Sendable {
    case model(ModelDownloadOwner)
    case leap(LeapDownloadOwner)
    case dataset(DatasetDownloadOwner)
    case embedding(EmbeddingDownloadOwner)
    case whisper(WhisperDownloadOwner)
}

extension DownloadOwner: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case model
        case leap
        case dataset
        case embedding
        case whisper
    }

    private enum Kind: String, Codable {
        case model
        case leap
        case dataset
        case embedding
        case whisper
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .model:
            self = .model(try container.decode(ModelDownloadOwner.self, forKey: .model))
        case .leap:
            self = .leap(try container.decode(LeapDownloadOwner.self, forKey: .leap))
        case .dataset:
            self = .dataset(try container.decode(DatasetDownloadOwner.self, forKey: .dataset))
        case .embedding:
            self = .embedding(try container.decode(EmbeddingDownloadOwner.self, forKey: .embedding))
        case .whisper:
            self = .whisper(try container.decode(WhisperDownloadOwner.self, forKey: .whisper))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .model(let owner):
            try container.encode(Kind.model, forKey: .kind)
            try container.encode(owner, forKey: .model)
        case .leap(let owner):
            try container.encode(Kind.leap, forKey: .kind)
            try container.encode(owner, forKey: .leap)
        case .dataset(let owner):
            try container.encode(Kind.dataset, forKey: .kind)
            try container.encode(owner, forKey: .dataset)
        case .embedding(let owner):
            try container.encode(Kind.embedding, forKey: .kind)
            try container.encode(owner, forKey: .embedding)
        case .whisper(let owner):
            try container.encode(Kind.whisper, forKey: .kind)
            try container.encode(owner, forKey: .whisper)
        }
    }
}

extension DownloadOwner {
    var externalID: String {
        switch self {
        case .model(let owner):
            return "\(owner.detail.id)-\(owner.quant.label)"
        case .leap(let owner):
            return owner.entry.slug
        case .dataset(let owner):
            return owner.detail.id
        case .embedding(let owner):
            return owner.externalID
        case .whisper(let owner):
            return owner.externalID
        }
    }
}

struct DownloadArtifact: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var role: DownloadArtifactRole
    var remoteURL: URL?
    var stagingURL: URL
    var finalURL: URL
    var expectedBytes: Int64?
    var downloadedBytes: Int64
    var checksum: String?
    var state: DownloadArtifactState
    var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorDescription: String?
    var manualPause: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case remoteURL
        case stagingURL
        case finalURL
        case destinationURL
        case expectedBytes
        case downloadedBytes
        case checksum
        case state
        case retryCount
        case nextRetryAt
        case lastErrorDescription
        case manualPause
    }

    init(id: String,
         role: DownloadArtifactRole,
         remoteURL: URL?,
         stagingURL: URL,
         finalURL: URL,
         expectedBytes: Int64?,
         downloadedBytes: Int64,
         checksum: String?,
         state: DownloadArtifactState,
         retryCount: Int,
         nextRetryAt: Date?,
         lastErrorDescription: String?,
         manualPause: Bool) {
        self.id = id
        self.role = role
        self.remoteURL = remoteURL
        self.stagingURL = stagingURL
        self.finalURL = finalURL
        self.expectedBytes = expectedBytes
        self.downloadedBytes = downloadedBytes
        self.checksum = checksum
        self.state = state
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastErrorDescription = lastErrorDescription
        self.manualPause = manualPause
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(DownloadArtifactRole.self, forKey: .role)
        remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
        let legacyDestination = try container.decodeIfPresent(URL.self, forKey: .destinationURL)
        let decodedStaging = try container.decodeIfPresent(URL.self, forKey: .stagingURL)
        let decodedFinal = try container.decodeIfPresent(URL.self, forKey: .finalURL)
        if let decodedStaging {
            stagingURL = decodedStaging
        } else if let legacyDestination {
            stagingURL = legacyDestination
        } else {
            throw DecodingError.keyNotFound(CodingKeys.stagingURL, .init(codingPath: decoder.codingPath, debugDescription: "Missing staging URL"))
        }
        if let decodedFinal {
            finalURL = decodedFinal
        } else if let legacyDestination {
            finalURL = Self.legacyFinalURL(from: legacyDestination)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.finalURL, .init(codingPath: decoder.codingPath, debugDescription: "Missing final URL"))
        }
        expectedBytes = try container.decodeIfPresent(Int64.self, forKey: .expectedBytes)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
        state = try container.decode(DownloadArtifactState.self, forKey: .state)
        retryCount = try container.decode(Int.self, forKey: .retryCount)
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        lastErrorDescription = try container.decodeIfPresent(String.self, forKey: .lastErrorDescription)
        manualPause = try container.decode(Bool.self, forKey: .manualPause)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
        try container.encode(stagingURL, forKey: .stagingURL)
        try container.encode(finalURL, forKey: .finalURL)
        try container.encodeIfPresent(expectedBytes, forKey: .expectedBytes)
        try container.encode(downloadedBytes, forKey: .downloadedBytes)
        try container.encodeIfPresent(checksum, forKey: .checksum)
        try container.encode(state, forKey: .state)
        try container.encode(retryCount, forKey: .retryCount)
        try container.encodeIfPresent(nextRetryAt, forKey: .nextRetryAt)
        try container.encodeIfPresent(lastErrorDescription, forKey: .lastErrorDescription)
        try container.encode(manualPause, forKey: .manualPause)
    }

    var destinationURL: URL { stagingURL }

    private static func legacyFinalURL(from url: URL) -> URL {
        guard url.pathExtension.lowercased() == "download" else { return url }
        return url.deletingPathExtension()
    }

    var canPause: Bool {
        switch state {
        case .queued, .preparing, .downloading, .waitingForConnectivity, .retrying, .verifying, .finalizing:
            return true
        case .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var canResume: Bool {
        state == .paused || state == .waitingForConnectivity || state == .retrying || state == .failed
    }
}

struct DownloadJob: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let owner: DownloadOwner
    var state: DownloadJobState
    var artifacts: [DownloadArtifact]
    var createdAt: Date
    var updatedAt: Date
    var lastErrorDescription: String?
    var manualPause: Bool

    var externalID: String { owner.externalID }

    var totalExpectedBytes: Int64 {
        artifacts.reduce(into: Int64(0)) { partial, artifact in
            partial += max(artifact.expectedBytes ?? 0, artifact.downloadedBytes)
        }
    }

    var totalDownloadedBytes: Int64 {
        artifacts.reduce(into: Int64(0)) { $0 += max(0, $1.downloadedBytes) }
    }

    var progress: Double {
        let total = totalExpectedBytes
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(totalDownloadedBytes) / Double(total)))
    }

    var canPause: Bool {
        if state == .scheduled { return false }
        if manualPause { return false }
        return artifacts.contains(where: \.canPause)
    }

    var canResume: Bool {
        if state == .scheduled { return true }
        return manualPause || artifacts.contains(where: \.canResume)
    }
}

extension DownloadJobState {
    var autoResumeEligible: Bool {
        switch self {
        case .downloading, .waitingForConnectivity, .retrying, .verifying, .finalizing:
            return true
        case .queued, .scheduled, .preparing, .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var statusLabelKey: String {
        switch self {
        case .queued:
            return "Download Status Queued"
        case .scheduled:
            return "Download Status Scheduled"
        case .preparing:
            return "Download Status Preparing"
        case .downloading:
            return "Download Status Downloading"
        case .paused:
            return "Download Status Paused"
        case .waitingForConnectivity:
            return "Download Status Waiting"
        case .retrying:
            return "Download Status Retrying"
        case .verifying:
            return "Download Status Verifying"
        case .finalizing:
            return "Download Status Finalizing"
        case .completed:
            return "Download Status Completed"
        case .failed:
            return "Download Status Failed"
        case .cancelled:
            return "Download Status Cancelled"
        }
    }
}

actor DownloadEngine {
    static let shared = DownloadEngine()

    private var jobs: [String: DownloadJob] = [:]
    private var bootstrapped = false
    private let fm = FileManager.default
    private var lastProgressPersistenceAt: [String: Date] = [:]
    private let progressPersistenceInterval: TimeInterval = 0.8

    init() {
        jobs = Self.loadPersistedJobs()
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        loadQueue()
        await migrateRecoveredJobsIfNeeded()
        await notifyChanged()
    }

    func snapshots() -> [DownloadJob] {
        jobs.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func job(forExternalID externalID: String) -> DownloadJob? {
        jobs.values.first(where: { $0.externalID == externalID })
    }

    func job(id: String) -> DownloadJob? {
        jobs[id]
    }

    func job(matching destination: URL) -> DownloadJob? {
        jobs.values.first(where: { job in
            job.artifacts.contains(where: {
                $0.stagingURL.path == destination.path || $0.finalURL.path == destination.path
            })
        })
    }

    func activeArtifacts(forExternalID externalID: String) -> [DownloadArtifact] {
        job(forExternalID: externalID)?.artifacts.filter {
            $0.state != .completed && $0.state != .cancelled && $0.state != .failed
        } ?? []
    }

    func upsertJob(owner: DownloadOwner,
                   artifacts: [DownloadArtifact],
                   state: DownloadJobState) async -> DownloadJob {
        let now = Date()
        let jobID: String
        if let existing = job(forExternalID: owner.externalID) {
            jobID = existing.id
        } else {
            jobID = UUID().uuidString
        }
        let job = DownloadJob(
            id: jobID,
            owner: owner,
            state: state,
            artifacts: mergeArtifacts(existing: jobs[jobID]?.artifacts ?? [], incoming: artifacts),
            createdAt: jobs[jobID]?.createdAt ?? now,
            updatedAt: now,
            lastErrorDescription: jobs[jobID]?.lastErrorDescription,
            manualPause: jobs[jobID]?.manualPause ?? false
        )
        jobs[jobID] = job
        persistQueue()
        await notifyChanged()
        return job
    }

    func updateJobState(externalID: String,
                        state: DownloadJobState,
                        manualPause: Bool? = nil,
                        errorMessage: String? = nil) async {
        guard var job = job(forExternalID: externalID) else { return }
        // A cancelled job is awaiting removal; late pause/fail events from torn-down
        // transfers must not revive it.
        if job.state == .cancelled && state != .cancelled { return }
        job.state = state
        if let manualPause { job.manualPause = manualPause }
        if let errorMessage { job.lastErrorDescription = errorMessage }
        job.updatedAt = Date()
        jobs[job.id] = job
        persistQueue()
        await notifyChanged()
    }

    func upsertArtifacts(externalID: String, artifacts incoming: [DownloadArtifact]) async {
        guard var job = job(forExternalID: externalID), !incoming.isEmpty else { return }
        if job.state == .cancelled { return }
        job.artifacts = mergeArtifacts(existing: job.artifacts, incoming: incoming)
        job.updatedAt = Date()
        recalculateJobState(&job, preferredState: nil)
        jobs[job.id] = job
        persistQueue()
        await notifyChanged()
    }

    func updateArtifactState(externalID: String,
                             artifactID: String,
                             state: DownloadArtifactState,
                             downloadedBytes: Int64? = nil,
                             expectedBytes: Int64? = nil,
                             retryCount: Int? = nil,
                             nextRetryAt: Date? = nil,
                             errorMessage: String? = nil,
                             manualPause: Bool? = nil) async {
        guard var job = job(forExternalID: externalID),
              let index = job.artifacts.firstIndex(where: { $0.id == artifactID }) else { return }
        if job.state == .cancelled && state != .cancelled { return }
        if let downloadedBytes { job.artifacts[index].downloadedBytes = max(0, downloadedBytes) }
        if let expectedBytes, expectedBytes > 0 { job.artifacts[index].expectedBytes = expectedBytes }
        if let retryCount { job.artifacts[index].retryCount = retryCount }
        if let nextRetryAt { job.artifacts[index].nextRetryAt = nextRetryAt }
        if let errorMessage { job.artifacts[index].lastErrorDescription = errorMessage }
        if let manualPause { job.artifacts[index].manualPause = manualPause }
        job.artifacts[index].state = state
        job.updatedAt = Date()
        recalculateJobState(&job, preferredState: nil)
        jobs[job.id] = job
        persistQueue()
        await notifyChanged()
    }

    func updateArtifactProgress(externalID: String,
                                artifactID: String,
                                written: Int64,
                                expected: Int64?) async {
        await updateArtifactProgressInternal(
            externalID: externalID,
            artifactID: artifactID,
            written: written,
            expected: expected,
            persistNow: true,
            notify: true
        )
    }

    func markArtifactCompleted(externalID: String,
                               artifactID: String,
                               finalBytes: Int64? = nil) async {
        guard var job = job(forExternalID: externalID),
              let index = job.artifacts.firstIndex(where: { $0.id == artifactID }) else { return }
        if job.state == .cancelled { return }
        if let finalBytes {
            job.artifacts[index].downloadedBytes = max(job.artifacts[index].downloadedBytes, finalBytes)
            job.artifacts[index].expectedBytes = max(job.artifacts[index].expectedBytes ?? 0, finalBytes)
        }
        job.artifacts[index].state = .completed
        job.artifacts[index].lastErrorDescription = nil
        job.artifacts[index].manualPause = false
        job.artifacts[index].nextRetryAt = nil
        job.updatedAt = Date()
        recalculateJobState(&job, preferredState: nil)
        jobs[job.id] = job
        persistQueue()
        await notifyChanged()
    }

    /// Resets an artifact's byte count downward after a transfer verifiably restarted from
    /// scratch (the server rejected or ignored a resume). Progress updates are otherwise
    /// monotonic, so without this the stale larger count freezes the visible progress
    /// until the new transfer catches up.
    func resetArtifactProgress(jobID: String, artifactID: String, downloadedBytes: Int64 = 0) async {
        guard var job = jobs[jobID],
              let index = job.artifacts.firstIndex(where: { $0.id == artifactID }) else { return }
        if job.state == .cancelled { return }
        if job.artifacts[index].state == .completed { return }
        job.artifacts[index].downloadedBytes = max(0, downloadedBytes)
        job.updatedAt = Date()
        jobs[job.id] = job
        persistQueue()
        await notifyChanged()
    }

    func markCancelled(externalID: String) async {
        guard var job = job(forExternalID: externalID) else { return }
        job.state = .cancelled
        job.manualPause = false
        job.updatedAt = Date()
        for index in job.artifacts.indices {
            job.artifacts[index].state = .cancelled
            job.artifacts[index].manualPause = false
            try? fm.removeItem(at: DownloadPersistencePaths.resumeDataURL(jobID: job.id, artifactID: job.artifacts[index].id))
        }
        jobs[job.id] = job
        persistQueue()
        await notifyChanged()
    }

    func removeJob(externalID: String) async {
        guard let job = job(forExternalID: externalID) else { return }
        for artifact in job.artifacts {
            try? fm.removeItem(at: DownloadPersistencePaths.resumeDataURL(jobID: job.id, artifactID: artifact.id))
        }
        jobs.removeValue(forKey: job.id)
        persistQueue()
        await notifyChanged()
    }

    /// Removes the job only while it is still marked cancelled. A restart of the same
    /// download re-upserts the job with a fresh state; teardown must not delete that.
    func removeJobIfCancelled(externalID: String) async {
        guard let job = job(forExternalID: externalID), job.state == .cancelled else { return }
        await removeJob(externalID: externalID)
    }

    func autoResumableJobs() -> [DownloadJob] {
        jobs.values
            .filter { !$0.manualPause && $0.state.autoResumeEligible }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func scheduledJobs() -> [DownloadJob] {
        jobs.values
            .filter { $0.state == .scheduled }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    private func mergeArtifacts(existing: [DownloadArtifact], incoming: [DownloadArtifact]) -> [DownloadArtifact] {
        var mergedByID: [String: DownloadArtifact] = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for artifact in incoming {
            if var existing = mergedByID[artifact.id] {
                existing.remoteURL = artifact.remoteURL ?? existing.remoteURL
                existing.expectedBytes = artifact.expectedBytes ?? existing.expectedBytes
                existing.checksum = artifact.checksum ?? existing.checksum
                existing.stagingURL = artifact.stagingURL
                existing.finalURL = artifact.finalURL
                existing.role = artifact.role
                mergedByID[artifact.id] = existing
            } else {
                mergedByID[artifact.id] = artifact
            }
        }
        return mergedByID.values.sorted { $0.id < $1.id }
    }

    private func persistQueue() {
        let queueURL = DownloadPersistencePaths.queueFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let ordered = snapshots()
        if let data = try? encoder.encode(ordered) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }

    private func loadQueue() {
        jobs = Self.loadPersistedJobs()
    }

    private func recalculateJobState(_ job: inout DownloadJob, preferredState: DownloadJobState?) {
        if let preferredState {
            job.state = preferredState
            return
        }
        if job.artifacts.allSatisfy({ $0.state == .completed }) {
            job.state = .finalizing
            return
        }
        if job.manualPause || job.artifacts.contains(where: { $0.state == .paused }) {
            // Scheduled jobs pause their live transfers; keep them visibly scheduled.
            if job.state != .scheduled {
                job.state = .paused
            }
            return
        }
        if job.artifacts.contains(where: { $0.state == .failed }) {
            job.state = .failed
            return
        }
        if job.artifacts.contains(where: { $0.state == .retrying }) {
            job.state = .retrying
            return
        }
        if job.artifacts.contains(where: { $0.state == .waitingForConnectivity }) {
            job.state = .waitingForConnectivity
            return
        }
        if job.artifacts.contains(where: { $0.state == .verifying }) {
            job.state = .verifying
            return
        }
        if job.artifacts.contains(where: { $0.state == .preparing }) {
            job.state = .preparing
            return
        }
        if job.artifacts.contains(where: { $0.state == .downloading }) {
            job.state = .downloading
            return
        }
        if job.artifacts.contains(where: { $0.state == .queued }) {
            job.state = .queued
            return
        }
    }

    private func notifyChanged() async {
        let snapshots = snapshots()
        await logger.log("[DownloadEngine] jobs=\(snapshots.count)")
        NotificationCenter.default.post(name: .downloadEngineDidChange, object: nil)
    }

    private func shouldPersistProgress(for externalID: String, artifactID: String, force: Bool) -> Bool {
        if force { return true }
        let key = "\(externalID)::\(artifactID)"
        let now = Date()
        if let last = lastProgressPersistenceAt[key],
           now.timeIntervalSince(last) < progressPersistenceInterval {
            return false
        }
        lastProgressPersistenceAt[key] = now
        return true
    }

    private func updateArtifactProgressInternal(externalID: String,
                                                artifactID: String,
                                                written: Int64,
                                                expected: Int64?,
                                                persistNow: Bool,
                                                notify: Bool) async {
        guard var job = job(forExternalID: externalID),
              let index = job.artifacts.firstIndex(where: { $0.id == artifactID }) else { return }
        if job.state == .cancelled { return }
        job.artifacts[index].downloadedBytes = max(job.artifacts[index].downloadedBytes, written)
        if let expected, expected > 0 {
            job.artifacts[index].expectedBytes = max(job.artifacts[index].expectedBytes ?? 0, expected)
        }
        // Trailing bytes from a transfer that is being paused must not undo the user's
        // pause (or a scheduled hold): record the progress but keep the held state.
        let holdState = job.manualPause || job.state == .scheduled
        if !holdState {
            if job.artifacts[index].state != .completed {
                job.artifacts[index].state = .downloading
            }
        }
        job.updatedAt = Date()
        if !holdState {
            recalculateJobState(&job, preferredState: .downloading)
        }
        jobs[job.id] = job
        if persistNow {
            persistQueue()
            if notify {
                await notifyChanged()
            }
        }
    }

    func updateArtifactProgressLive(externalID: String,
                                    artifactID: String,
                                    written: Int64,
                                    expected: Int64?,
                                    forcePersistence: Bool = false) async {
        let persistNow = shouldPersistProgress(for: externalID, artifactID: artifactID, force: forcePersistence)
        await updateArtifactProgressInternal(
            externalID: externalID,
            artifactID: artifactID,
            written: written,
            expected: expected,
            persistNow: persistNow,
            notify: false
        )
    }

    private func migrateRecoveredJobsIfNeeded() async {
        let key = "download-engine-orphan-migration-v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        for record in EmbeddingModelCatalog.records where record.isInstallable {
            guard let embeddingArtifact = record.primaryArtifact else { continue }
            let stagedURL = embeddingArtifact.localURL(recordID: record.id).appendingPathExtension("download")
            guard fm.fileExists(atPath: stagedURL.path),
                  job(forExternalID: record.id) == nil,
                  job(forExternalID: embeddingArtifact.repoID) == nil else {
                continue
            }

            let existingBytes = downloadEngineFileSize(at: stagedURL)
            let recoveredArtifact = DownloadArtifact(
                id: "embedding",
                role: .embeddingModel,
                remoteURL: embeddingArtifact.downloadURL,
                stagingURL: stagedURL,
                finalURL: embeddingArtifact.localURL(recordID: record.id),
                expectedBytes: existingBytes,
                downloadedBytes: existingBytes ?? 0,
                checksum: nil,
                state: .paused,
                retryCount: 0,
                nextRetryAt: nil,
                lastErrorDescription: nil,
                manualPause: true
            )
            _ = await upsertJob(
                owner: .embedding(EmbeddingDownloadOwner(record: record, artifact: embeddingArtifact)),
                artifacts: [recoveredArtifact],
                state: .paused
            )
            await logger.log("[DownloadEngine] recovered orphan embedding partial for \(record.id)")
        }
    }

    private nonisolated static func loadPersistedJobs() -> [String: DownloadJob] {
        let queueURL = DownloadPersistencePaths.queueFileURL
        guard let data = try? Data(contentsOf: queueURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([DownloadJob].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }
}

private func downloadEngineFileSize(at url: URL) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int64 else {
        return nil
    }
    return size
}
