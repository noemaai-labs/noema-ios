import Foundation

#if os(macOS)
import AppKit
#endif

#if canImport(BackgroundTasks) && !os(visionOS) && !os(macOS)
import BackgroundTasks
#endif

#if canImport(UIKit)
import UIKit
#endif

// Thread-safe, monotonic throttler to limit how often we emit progress updates.
enum DownloadProgressExpectationMode: String, Equatable {
    case freshTask
    case freshRecorded
    case resumeFullSize
    case resumeRemainingBytes
    case resumeFallback
    case resumeRecordedOnly
    case resumeNoRecorded
    case unknown
}

struct DownloadProgressNormalizationResult: Equatable {
    let writtenTotal: Int64
    let fullExpected: Int64
    let mode: DownloadProgressExpectationMode
}

struct DownloadByteAccountingSnapshot: Equatable, Sendable {
    let lastChunkBytes: Int64?
    let taskBytesWritten: Int64
    let taskExpectedBytes: Int64?
    let resumeOffset: Int64
    let recordedExpectedBytes: Int64?
    let httpStatusCode: Int?
    let normalizedWrittenTotal: Int64
    let normalizedFullExpected: Int64?
    let normalizationMode: DownloadProgressExpectationMode
}

struct BackgroundDownloadTaskSnapshot: Equatable, Sendable {
    let jobID: String?
    let artifactID: String?
    let destination: URL
    let resumeOffset: Int64
    let bytesReceived: Int64
    let taskExpectedBytes: Int64?
    let recordedExpectedBytes: Int64?
    let writtenTotal: Int64
    let fullExpected: Int64?
    let hasLiveTask: Bool
    let byteAccounting: DownloadByteAccountingSnapshot?
}

/// Pure transport selection policy so OS-availability branches cannot silently
/// route an active app onto the system-paced background session.
enum DownloadTransportPolicy {
    enum Kind: Equatable {
        case foreground
        case background
    }

    /// A running Mac app keeps transfers in-process for predictable throughput.
    /// Window focus is deliberately irrelevant; an App Nap assertion protects
    /// active downloads, and quit-time resume capture provides durability.
    static let macOSActiveProcess: Kind = .foreground

    static func preferred(isAppActive: Bool,
                          supportsContinuedProcessing: Bool,
                          hasContinuedProcessingTask: Bool) -> Kind {
        if isAppActive { return .foreground }
        if supportsContinuedProcessing && hasContinuedProcessingTask { return .foreground }
        return .background
    }
}

final class ProgressThrottler<Key: Hashable> {
    private let minimumInterval: Double
    private let nowSeconds: () -> Double
    private var lastFireSeconds: [Key: Double] = [:]
    private let lock = NSLock()

    init(interval: TimeInterval,
         nowSeconds: @escaping () -> Double = {
             Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
         }) {
        self.minimumInterval = interval
        self.nowSeconds = nowSeconds
    }

    func shouldAllow(key: Key, force: Bool = false) -> Bool {
        let currentSeconds = nowSeconds()
        lock.lock()
        defer { lock.unlock() }

        if force {
            lastFireSeconds[key] = currentSeconds
            return true
        }

        if let last = lastFireSeconds[key], (currentSeconds - last) < minimumInterval {
            return false
        }

        lastFireSeconds[key] = currentSeconds
        return true
    }

    func clear(key: Key) {
        lock.lock()
        lastFireSeconds.removeValue(forKey: key)
        lock.unlock()
    }
}

/// Bridges a non-`Sendable` completion handler through a `URLSession` background
/// callback (which is `@Sendable`) so it can be invoked back on `@MainActor`.
/// Safe because the boxed closure is only ever *called* inside a `@MainActor`
/// task — never on the background callback's thread.
private final class CompletionBox: @unchecked Sendable {
    let value: (() -> Void)?
    init(_ value: (() -> Void)?) { self.value = value }
}

#if canImport(UIKit)
@MainActor
private final class DownloadExpirationGracePeriod {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

@MainActor
private final class DownloadExpirationCompletion {
    private var body: (@MainActor () -> Void)?

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    func finish() {
        let body = body
        self.body = nil
        body?()
    }
}
#endif

/// Manages large downloads that should continue when the app is not frontmost.
/// iOS 26 uses a high-throughput default session under continued-processing
/// protection, with a fixed-identifier background session as the durable fallback.
/// macOS keeps the high-throughput default session while the process is running and
/// captures resume data on quit so the transfer can continue on the next launch.
@MainActor
final class BackgroundDownloadManager: NSObject {
    static let shared = BackgroundDownloadManager()

    private struct TaskRecord: Codable {
        let jobID: String?
        let artifactID: String?
        let destination: URL
        let expectedSize: Int64?
        /// Additive byte offset for manual Range-header resumes: URLSession counts only the
        /// requested segment, so absolute progress is `totalBytesWritten + resumeOffset`.
        /// Must stay nil for resume-data tasks — those already report absolute totals
        /// (adding the offset again double-counts and freezes the visible progress).
        let resumeOffset: Int64?
        let appendsToExistingFile: Bool
        /// Where a resume-data task continued from. Display/bookkeeping only (never added
        /// to byte totals); lets us detect a server that ignored the resume (HTTP 200).
        let resumedAtOffset: Int64?
        /// Whether the task was created while the app was not active (such
        /// background-session tasks are discretionary — the system ignores
        /// isDiscretionary=false for them). Informational only.
        /// Optional so records persisted by older builds still decode.
        var createdInBackground: Bool?

        enum CodingKeys: String, CodingKey {
            case jobID
            case artifactID
            case destination
            case expectedSize
            case resumeOffset
            case appendsToExistingFile
            case resumedAtOffset
            case createdInBackground
        }

        init(jobID: String?,
             artifactID: String?,
             destination: URL,
             expectedSize: Int64?,
             resumeOffset: Int64?,
             appendsToExistingFile: Bool,
             resumedAtOffset: Int64? = nil,
             createdInBackground: Bool? = nil) {
            self.jobID = jobID
            self.artifactID = artifactID
            self.destination = destination
            self.expectedSize = expectedSize
            self.resumeOffset = resumeOffset
            self.appendsToExistingFile = appendsToExistingFile
            self.resumedAtOffset = resumedAtOffset
            self.createdInBackground = createdInBackground
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
            artifactID = try container.decodeIfPresent(String.self, forKey: .artifactID)
            destination = try container.decode(URL.self, forKey: .destination)
            expectedSize = try container.decodeIfPresent(Int64.self, forKey: .expectedSize)
            resumeOffset = try container.decodeIfPresent(Int64.self, forKey: .resumeOffset)
            appendsToExistingFile = try container.decodeIfPresent(Bool.self, forKey: .appendsToExistingFile) ?? false
            resumedAtOffset = try container.decodeIfPresent(Int64.self, forKey: .resumedAtOffset)
            createdInBackground = try container.decodeIfPresent(Bool.self, forKey: .createdInBackground)
        }
    }

    private let sessionIdentifier = "com.noema.background-download"
    #if canImport(BackgroundTasks) && !os(visionOS) && !os(macOS)
    private let maintenanceTaskIdentifier = "com.noema.download.maintenance"
    #endif

    // Background-capable session (keeps downloads running when suspended)
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // Keep the system from deferring downloads unnecessarily
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        // Allow more parallel connections for cases where multiple assets fetch concurrently (e.g., mmproj + weights)
        config.httpMaximumConnectionsPerHost = 8
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        s.sessionDescription = "Noema background downloads"
        NetworkKillSwitch.track(session: s)
        return s
    }()

    // Fast in-process session. On iOS 26 it remains usable in the background only
    // while BGContinuedProcessingTask protection is active.
    private lazy var foregroundSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.httpMaximumConnectionsPerHost = 12
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        s.sessionDescription = "Noema foreground downloads"
        NetworkKillSwitch.track(session: s)
        return s
    }()

    /// Keyed by (session identifier, task identifier) so foreground/background
    /// sessions running concurrently do not trample each other's bookkeeping.
    private struct TaskKey: Hashable {
        let sessionID: String
        let taskID: Int
    }

    // Two updates per second keeps progress/speed readable while preventing parallel
    // model shards from flooding the main actor with dozens of callbacks per second.
    nonisolated(unsafe) private let progressThrottler = ProgressThrottler<TaskKey>(interval: 0.5)

    private var destinations: [TaskKey: URL] = [:]
    private var completions: [TaskKey: (Result<URL, Error>) -> Void] = [:]
    private var progressHandlers: [TaskKey: (Double) -> Void] = [:]
    private var expectedSizes: [TaskKey: Int64] = [:]
    private var progressBytesHandlers: [TaskKey: (Int64, Int64) -> Void] = [:]
    // Additive offsets for Range-header resumes only (segment-relative byte counting).
    private var resumeOffsets: [TaskKey: Int64] = [:]
    // Resume points of resume-data tasks (absolute byte counting). Used to seed initial
    // snapshots and to detect a server restarting the file from zero — never added to totals.
    private var resumedFromOffsets: [TaskKey: Int64] = [:]
    private var loggedProgressModes: [TaskKey: DownloadProgressExpectationMode] = [:]
    // Detailed byte logging performs file and stderr I/O, so keep it far below the
    // already-coalesced UI cadence.
    private var lastBytesLogAt: [TaskKey: Date] = [:]
    private let bytesLogInterval: TimeInterval = 10.0
    private var backgroundCompletionHandler: (() -> Void)?
    // Map destination path → current task key
    private var taskIdByDestination: [String: TaskKey] = [:]
    private var taskRecordByKey: [TaskKey: TaskRecord] = [:]
    private var liveTasks: [TaskKey: URLSessionDownloadTask] = [:]
    private var liveSnapshots: [TaskKey: BackgroundDownloadTaskSnapshot] = [:]
    // Resume data captured when pausing, keyed by destination path
    private var resumeDataStore: [String: Data] = [:]
    private enum SessionKind { case foreground, background }
    private var lastSessionChoice: SessionKind? = nil
    private var lifecycleObservers: [NSObjectProtocol] = []
    // Keys whose task is being intentionally cancelled to hand off to the other
    // URLSession. Their cancellation must NOT be surfaced as a download failure.
    private var migratingKeys: Set<TaskKey> = []
    // Old keys whose migration already finished but whose NSURLErrorCancelled
    // delegate event hasn't been delivered yet (URLSession fires the cancel
    // callback before didCompleteWithError, so the migration continuation runs
    // first). Mapped to the replacement key so cleanup can purge stale entries.
    private var suppressedCancellations: [TaskKey: TaskKey] = [:]
    // Serializes fg⇄bg migration passes: a resign→active bounce queues the second
    // pass behind the first instead of skipping it, so the last lifecycle event
    // always decides which session the tasks end up on.
    private var migrationChain: Task<Void, Never>?
    // macOS startup migration is launched during singleton initialization, then
    // awaited by DownloadController before it reattaches persisted jobs.
    private var restorationTask: Task<Void, Never>?

    private override init() {
        super.init()
        installLifecycleObservers()
        #if canImport(BackgroundTasks) && !os(visionOS) && !os(macOS)
        registerBackgroundTask()
        #endif
        restorePersistedTasks()
    }

    // Build a stable key for tracking tasks across multiple URLSessions.
    nonisolated private func key(for session: URLSession, taskID: Int) -> TaskKey {
        let id = session.configuration.identifier ?? "foreground"
        return TaskKey(sessionID: id, taskID: taskID)
    }

    private func installLifecycleObservers() {
#if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                #if os(iOS)
                await logger.log("[Download][App] willResignActive – evaluating continued-processing protection")
                #else
                await logger.log("[Download][App] willResignActive – handing transfers to the background session")
                #endif
                await self?.handleWillResignActive()
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                await logger.log("[Download][App] didEnterBackground – transfers continue on the selected protected transport")
                await self?.handleEnterBackground()
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { await logger.log("[Download][App] willEnterForeground") }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                #if os(iOS)
                await logger.log("[Download][App] didBecomeActive – restoring foreground-speed transfers")
                #else
                await logger.log("[Download][App] didBecomeActive – pulling transfers onto the foreground session")
                #endif
                await self?.handleBecomeActive()
            }
        })
#endif
#if os(macOS)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { await logger.log("[Download][App] didBecomeActive (macOS)") }
        })
        lifecycleObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { await logger.log("[Download][App] didResignActive (macOS)") }
        })
#endif
    }

    private func logSessionChoice(kind: SessionKind, reason: String) {
        guard lastSessionChoice != kind else { return }
        lastSessionChoice = kind
        let label = (kind == .foreground) ? "foreground" : "background"
        Task { await logger.log("[Download][Session] now using \(label) session (\(reason))") }
    }

    private func resumeDataURL(for record: TaskRecord) -> URL? {
        guard let jobID = record.jobID, let artifactID = record.artifactID else { return nil }
        return DownloadPersistencePaths.resumeDataURL(jobID: jobID, artifactID: artifactID)
    }

    private func loadResumeData(for record: TaskRecord) -> Data? {
        if let cached = resumeDataStore[record.destination.path] {
            return cached
        }
        guard let url = resumeDataURL(for: record),
              let data = try? Data(contentsOf: url) else { return nil }
        resumeDataStore[record.destination.path] = data
        return data
    }

    private func persistResumeData(_ data: Data, for record: TaskRecord) {
        // Resume data from a Range/append task covers only the tail segment; consuming
        // it later as a whole-file resume would replace the staging partial with just
        // that tail. The partial on disk already captures the progress for those tasks.
        guard !record.appendsToExistingFile else { return }
        resumeDataStore[record.destination.path] = data
        guard let url = resumeDataURL(for: record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearResumeData(for record: TaskRecord) {
        resumeDataStore.removeValue(forKey: record.destination.path)
        guard let url = resumeDataURL(for: record) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func register(task: URLSessionDownloadTask, in session: URLSession, record: TaskRecord) -> TaskKey {
        let key = self.key(for: session, taskID: task.taskIdentifier)
        destinations[key] = record.destination
        taskIdByDestination[record.destination.path] = key
        taskRecordByKey[key] = record
        liveTasks[key] = task
        if let expected = record.expectedSize { expectedSizes[key] = expected }
        if let offset = record.resumeOffset, offset > 0 { resumeOffsets[key] = offset }
        if let resumed = record.resumedAtOffset, resumed > 0 { resumedFromOffsets[key] = resumed }
        liveSnapshots[key] = Self.makeTaskSnapshot(
            jobID: record.jobID,
            artifactID: record.artifactID,
            destination: record.destination,
            resumeOffset: record.resumeOffset ?? 0,
            bytesReceived: max(max(0, task.countOfBytesReceived), record.resumedAtOffset ?? 0),
            taskExpected: task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : nil,
            recordedExpected: record.expectedSize,
            hasLiveTask: true
        )
        return key
    }

    private func refreshSessionTasks(session: URLSession, completion: (() -> Void)? = nil) {
        let completionBox = CompletionBox(completion)
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else {
                    completionBox.value?()
                    return
                }
                let sessionID = session.configuration.identifier ?? "foreground"
                self.liveTasks = self.liveTasks.filter { $0.key.sessionID != sessionID }
                self.liveSnapshots = self.liveSnapshots.filter { $0.key.sessionID != sessionID }
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask else { continue }
                    downloadTask.priority = URLSessionTask.highPriority
                    let key = self.key(for: session, taskID: downloadTask.taskIdentifier)
                    self.liveTasks[key] = downloadTask
                    guard let record = self.record(for: downloadTask.taskDescription) else { continue }
                    self.destinations[key] = record.destination
                    self.taskIdByDestination[record.destination.path] = key
                    self.taskRecordByKey[key] = record
                    if let expected = record.expectedSize {
                        self.expectedSizes[key] = expected
                    }
                    if let offset = record.resumeOffset, offset > 0 {
                        self.resumeOffsets[key] = offset
                    }
                    if let resumed = record.resumedAtOffset, resumed > 0 {
                        self.resumedFromOffsets[key] = resumed
                    }
                    self.liveSnapshots[key] = Self.makeTaskSnapshot(
                        jobID: record.jobID,
                        artifactID: record.artifactID,
                        destination: record.destination,
                        resumeOffset: record.resumeOffset ?? 0,
                        bytesReceived: max(max(0, downloadTask.countOfBytesReceived), record.resumedAtOffset ?? 0),
                        taskExpected: downloadTask.countOfBytesExpectedToReceive > 0 ? downloadTask.countOfBytesExpectedToReceive : nil,
                        recordedExpected: record.expectedSize,
                        hasLiveTask: true
                    )
                }
                completionBox.value?()
            }
        }
    }

    private func lookupTask(for destination: URL, completion: @escaping (TaskKey?, URLSessionDownloadTask?) -> Void) {
        if let key = taskIdByDestination[destination.path], let task = liveTasks[key] {
            completion(key, task)
            return
        }
        refreshSessionTasks(session: backgroundSession) { [weak self] in
            guard let self else {
                completion(nil, nil)
                return
            }
            if let key = self.taskIdByDestination[destination.path], let task = self.liveTasks[key] {
                completion(key, task)
                return
            }
#if os(macOS) || canImport(UIKit)
            self.refreshSessionTasks(session: self.foregroundSession) { [weak self] in
                guard let self else {
                    completion(nil, nil)
                    return
                }
                if let key = self.taskIdByDestination[destination.path], let task = self.liveTasks[key] {
                    completion(key, task)
                } else {
                    completion(nil, nil)
                }
            }
#else
                completion(nil, nil)
#endif
        }
    }

    // MARK: - Public API
    /// Start a download that can continue in the background.
    @discardableResult
    func download(from remote: URL,
                  to local: URL,
                  jobID: String? = nil,
                  artifactID: String? = nil,
                  expectedSize: Int64? = nil,
                  progress: ((Double) -> Void)? = nil,
                  progressBytes: ((Int64, Int64) -> Void)? = nil) async throws -> URL {
        let req = URLRequest(url: remote)
        return try await download(
            request: req,
            to: local,
            jobID: jobID,
            artifactID: artifactID,
            expectedSize: expectedSize,
            progress: progress,
            progressBytes: progressBytes
        )
    }

    /// Start a download with a custom request (headers/auth supported).
    @discardableResult
    func download(request: URLRequest,
                  to local: URL,
                  jobID: String? = nil,
                  artifactID: String? = nil,
                  expectedSize: Int64? = nil,
                  progress: ((Double) -> Void)? = nil,
                  progressBytes: ((Int64, Int64) -> Void)? = nil) async throws -> URL {
        // Route Hugging Face URLs through the configured mirror/endpoint. Done here
        // so every task creation, HEAD probe and restart path below uses one host.
        let request = HFEndpoint.rewrite(request)
        guard !NetworkKillSwitch.shouldBlock(request: request) else {
            throw URLError(.notConnectedToInternet)
        }
        let headLength: Int64?
        #if os(iOS)
        // Do not put an awaited probe between the user's foreground action and
        // creation of the transfer. It delays continued-processing startup and,
        // on fallback paths, can make the eventual background-session download
        // discretionary. The GET response supplies the authoritative length.
        headLength = nil
        #else
        // Refine the expected size with a HEAD probe only when we know nothing. A caller
        // that already has a size, or a transfer resuming from stored resume data, gets
        // the authoritative length from the GET response itself (normalizeProgressTotals
        // prefers the task's Content-Length); the extra round-trip — up to 10 s on a bad
        // network — would only delay every start and resume.
        let resumeProbe = TaskRecord(
            jobID: jobID,
            artifactID: artifactID,
            destination: local,
            expectedSize: expectedSize,
            resumeOffset: nil,
            appendsToExistingFile: false
        )
        let needsHeadProbe = (expectedSize ?? 0) <= 0 && loadResumeData(for: resumeProbe) == nil
        headLength = needsHeadProbe ? await remoteContentLength(for: request) : nil
        #endif
        guard !NetworkKillSwitch.shouldBlock(request: request) else {
            throw URLError(.notConnectedToInternet)
        }
        let refinedExpected: Int64? = {
            if let head = headLength, head > 0 { return head }
            return expectedSize
        }()

        return try await withCheckedThrowingContinuation { cont in
            let finish = self.idempotentCompletion { cont.resume(with: $0) }
            // If we have resume data for this destination, prefer resuming
            let session = self.preferredSession()
            let sessionLabel = (session.configuration.identifier == self.sessionIdentifier) ? "background" : "foreground"
            let expectedLabel: String = {
                if let refinedExpected, refinedExpected > 0 {
                    return ByteCountFormatter.string(fromByteCount: refinedExpected, countStyle: .file)
                }
                return "unknown"
            }()
            Task { await logger.log("[Download][Session] start dest=\(local.lastPathComponent) session=\(sessionLabel) expected=\(expectedLabel)") }

            let resumeRecord = TaskRecord(
                jobID: jobID,
                artifactID: artifactID,
                destination: local,
                expectedSize: refinedExpected,
                resumeOffset: nil,
                appendsToExistingFile: false
            )
            // A staging partial on disk supersedes any stored resume blob: the blob may
            // describe only a tail segment or predate the partial, and consuming it would
            // replace the partial with a truncated file. Prefer the Range-from-partial path.
            if self.readExistingPartialSize(at: local) > 0 {
                self.clearResumeData(for: resumeRecord)
            }
            if let resume = self.loadResumeData(for: resumeRecord) {
                let offset = Self.extractResumeOffset(from: resume)
                let task = session.downloadTask(withResumeData: resume)
                task.priority = URLSessionTask.highPriority
                // Resume-data tasks report absolute totals (didWriteData already includes
                // the resumed bytes), so the record carries NO additive resumeOffset —
                // only the non-additive resume point for display and restart detection.
                let record = TaskRecord(
                    jobID: jobID,
                    artifactID: artifactID,
                    destination: local,
                    expectedSize: refinedExpected,
                    resumeOffset: nil,
                    appendsToExistingFile: false,
                    resumedAtOffset: offset > 0 ? offset : nil,
                    createdInBackground: !self.appIsActiveNow()
                )
                if let data = try? JSONEncoder().encode(record) {
                    task.taskDescription = String(data: data, encoding: .utf8)
                }
                let key = self.register(task: task, in: session, record: record)
                if let progress = progress { progressHandlers[key] = progress }
                if let progressBytes = progressBytes { progressBytesHandlers[key] = progressBytes }
                // A long-paused download's resume data usually points at an expired signed
                // CDN URL; the server then answers 4xx. Fall back to the original request
                // (durable URL) instead of surfacing a failure that deletes the row.
                completions[key] = { [weak self] result in
                    if case .failure(let error) = result,
                       Self.httpRejectionStatus(from: error) != nil,
                       let self {
                        Task { @MainActor in
                            await logger.log("[Download][Resume] stored resume data rejected (\(error.localizedDescription)); restarting \(local.lastPathComponent) from the original URL")
                            self.postRestartNotification(jobID: jobID, artifactID: artifactID, destination: local)
                            self.startDownloadTask(
                                request: request,
                                local: local,
                                jobID: jobID,
                                artifactID: artifactID,
                                refinedExpected: refinedExpected,
                                allowRangeResume: false,
                                progress: progress,
                                progressBytes: progressBytes,
                                completion: finish
                            )
                        }
                        return
                    }
                    finish(result)
                }
                self.clearResumeData(for: record)
                task.resume()
                return
            }

            self.startDownloadTask(
                request: request,
                local: local,
                jobID: jobID,
                artifactID: artifactID,
                refinedExpected: refinedExpected,
                allowRangeResume: true,
                progress: progress,
                progressBytes: progressBytes,
                completion: finish
            )
        }
    }

    /// Create and start a download task for `request`, optionally resuming from an on-disk
    /// staging partial via an HTTP Range header. A range request answered with 416 means the
    /// partial no longer matches the remote file — the stale partial is deleted and the
    /// download restarts from scratch (once).
    private func startDownloadTask(request: URLRequest,
                                   local: URL,
                                   jobID: String?,
                                   artifactID: String?,
                                   refinedExpected: Int64?,
                                   allowRangeResume: Bool,
                                   progress: ((Double) -> Void)?,
                                   progressBytes: ((Int64, Int64) -> Void)?,
                                   completion: @escaping (Result<URL, Error>) -> Void) {
        guard !NetworkKillSwitch.shouldBlock(request: request) else {
            completion(.failure(URLError(.notConnectedToInternet)))
            return
        }
        let session = self.preferredSession()
        let existingPartialBytes = allowRangeResume ? self.readExistingPartialSize(at: local) : 0
        if Self.canAdoptCompletedStagingFile(
            existingBytes: existingPartialBytes,
            expectedBytes: refinedExpected
        ) {
            Task { await logger.log("[Download][Resume] adopting complete staging file \(local.lastPathComponent) bytes=\(existingPartialBytes)") }
            progress?(1)
            progressBytes?(existingPartialBytes, existingPartialBytes)
            completion(.success(local))
            return
        }
        let shouldAttemptRangeResume = existingPartialBytes > 0
        var requestToStart = request
        requestToStart.setValue(nil, forHTTPHeaderField: "Range")
        if shouldAttemptRangeResume {
            requestToStart.setValue("bytes=\(existingPartialBytes)-", forHTTPHeaderField: "Range")
        }
        let task = session.downloadTask(with: requestToStart)
        task.priority = URLSessionTask.highPriority
        let record = TaskRecord(
            jobID: jobID,
            artifactID: artifactID,
            destination: local,
            expectedSize: refinedExpected,
            resumeOffset: shouldAttemptRangeResume ? existingPartialBytes : nil,
            appendsToExistingFile: shouldAttemptRangeResume,
            createdInBackground: !appIsActiveNow()
        )
        if let data = try? JSONEncoder().encode(record) {
            task.taskDescription = String(data: data, encoding: .utf8)
        }
        let key = self.register(task: task, in: session, record: record)
        if let progress { progressHandlers[key] = progress }
        if let progressBytes { progressBytesHandlers[key] = progressBytes }
        if shouldAttemptRangeResume {
            completions[key] = { [weak self] result in
                if case .failure(let error) = result,
                   Self.httpRejectionStatus(from: error) == 416,
                   let self {
                    Task { @MainActor in
                        await logger.log("[Download][Resume] range resume rejected (416) for \(local.lastPathComponent); deleting stale partial and restarting")
                        try? FileManager.default.removeItem(at: local)
                        self.postRestartNotification(jobID: jobID, artifactID: artifactID, destination: local)
                        self.startDownloadTask(
                            request: request,
                            local: local,
                            jobID: jobID,
                            artifactID: artifactID,
                            refinedExpected: refinedExpected,
                            allowRangeResume: false,
                            progress: progress,
                            progressBytes: progressBytes,
                            completion: completion
                        )
                    }
                    return
                }
                completion(result)
            }
        } else {
            completions[key] = completion
        }
        task.resume()
    }

    /// A previous process may have finished moving URLSession's temporary file into Noema's
    /// staging location and then exited before owner-specific validation/finalization ran.
    /// Reusing an exact-size staging file lets that validation continue without issuing a
    /// Range request that would receive HTTP 416 and unnecessarily restart from zero.
    nonisolated static func canAdoptCompletedStagingFile(existingBytes: Int64,
                                                         expectedBytes: Int64?) -> Bool {
        guard existingBytes > 0, let expectedBytes, expectedBytes > 0 else { return false }
        return existingBytes == expectedBytes
    }

    /// Marker error for HTTP responses outside 2xx detected at download completion.
    /// Download tasks otherwise treat any response body (403 XML, HTML error pages, …)
    /// as a successful download.
    nonisolated static let httpStatusCodeUserInfoKey = "NoemaHTTPStatusCode"

    nonisolated static func serverRejectionError(statusCode: Int) -> NSError {
        NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorBadServerResponse,
            userInfo: [
                httpStatusCodeUserInfoKey: statusCode,
                NSLocalizedDescriptionKey: "Server returned HTTP \(statusCode)"
            ]
        )
    }

    nonisolated static func httpRejectionStatus(from error: Error) -> Int? {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain, ns.code == NSURLErrorBadServerResponse else { return nil }
        return ns.userInfo[httpStatusCodeUserInfoKey] as? Int
    }

    private func postRestartNotification(jobID: String?, artifactID: String?, destination: URL) {
        var info: [String: Any] = ["destinationURL": destination]
        if let jobID { info["jobID"] = jobID }
        if let artifactID { info["artifactID"] = artifactID }
        NotificationCenter.default.post(name: .backgroundDownloadRestarted, object: nil, userInfo: info)
    }

    /// Called from AppDelegate when the system wakes us for background events.
    func handleEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == sessionIdentifier else { completionHandler(); return }
        _ = backgroundSession // ensure the background session is instantiated so the system can deliver events
        restorePersistedTasks()
        backgroundCompletionHandler = completionHandler
    }

    /// Pause an in‑flight background download targeting the given destination.
    /// Stores resume data so a subsequent `download` call will resume.
    func pause(destination: URL, completion: (() -> Void)? = nil) {
        lookupTask(for: destination) { [weak self] key, task in
            guard let self, let key, let task else {
                completion?()
                return
            }
            let record = self.taskRecordByKey[key]
            let completionBox = CompletionBox(completion)
            task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor in
                    if let self, let data, let record {
                        self.persistResumeData(data, for: record)
                    }
                    completionBox.value?()
                }
            })
        }
    }

    func pause(destination: URL) async {
        await withCheckedContinuation { continuation in
            pause(destination: destination) {
                continuation.resume()
            }
        }
    }

    /// Cancel and discard resume data for a destination.
    func cancel(destination: URL) {
        lookupTask(for: destination) { [weak self] key, task in
            guard let self else { return }
            if let key, let record = self.taskRecordByKey[key] {
                self.clearResumeData(for: record)
            } else {
                self.resumeDataStore.removeValue(forKey: destination.path)
            }
            task?.cancel()
        }
    }

    /// Synchronously capture resume state before the process exits. iOS and visionOS
    /// leave fixed-identifier background tasks with nsurlsessiond; macOS also captures
    /// legacy background tasks so the next launch can restore them onto its fast session.
    /// Blocks the calling (main) thread briefly; the resume-data callbacks land
    /// on the session delegate queue and write straight to disk, never hopping back
    /// to the main actor, so waiting here cannot deadlock.
    func flushForTermination(timeout: TimeInterval = 1.5) {
        guard !liveTasks.isEmpty else { return }
        let group = DispatchGroup()
        for (key, task) in liveTasks {
            #if !os(macOS)
            if key.sessionID == sessionIdentifier { continue }
            #endif
            guard let record = taskRecordByKey[key], !record.appendsToExistingFile,
                  let url = resumeDataURL(for: record) else {
                // Append-mode staging partials are already on disk (a tail-segment blob
                // would corrupt them); unidentified tasks have nowhere to persist to.
                task.cancel()
                continue
            }
            group.enter()
            task.cancel(byProducingResumeData: { data in
                if let data { try? data.write(to: url, options: .atomic) }
                group.leave()
            })
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    func attachObservers(jobID: String?,
                         artifactID: String?,
                         destination: URL,
                         expectedSize: Int64? = nil,
                         progress: ((Double) -> Void)? = nil,
                         progressBytes: ((Int64, Int64) -> Void)? = nil,
                         completion: ((Result<URL, Error>) -> Void)? = nil) {
        lookupTask(for: destination) { [weak self] key, task in
            guard let self, let key else { return }
            let existingRecord = self.taskRecordByKey[key]
            let record = existingRecord ?? TaskRecord(
                jobID: jobID,
                artifactID: artifactID,
                destination: destination,
                expectedSize: expectedSize,
                resumeOffset: nil,
                appendsToExistingFile: false
            )
            if existingRecord == nil, let task {
                self.taskRecordByKey[key] = record
                self.liveTasks[key] = task
            }
            if let expectedSize, expectedSize > 0 {
                self.expectedSizes[key] = expectedSize
            }
            if let progress { self.progressHandlers[key] = progress }
            if let progressBytes { self.progressBytesHandlers[key] = progressBytes }
            if let completion { self.completions[key] = completion }
            if let snapshot = self.liveSnapshots[key] {
                if let fullExpected = snapshot.fullExpected, fullExpected > 0 {
                    let fraction = Double(snapshot.writtenTotal) / Double(fullExpected)
                    progress?(fraction)
                    progressBytes?(snapshot.writtenTotal, fullExpected)
                } else if snapshot.writtenTotal > 0 {
                    progressBytes?(snapshot.writtenTotal, 0)
                }
            }
        }
    }

    func hasLiveTask(for destination: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            lookupTask(for: destination) { _, task in
                continuation.resume(returning: task != nil)
            }
        }
    }

    func snapshot(for destination: URL) async -> BackgroundDownloadTaskSnapshot? {
        await withCheckedContinuation { continuation in
            lookupTask(for: destination) { [weak self] key, _ in
                guard let self, let key else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.liveSnapshots[key])
            }
        }
    }

    func snapshots() async -> [BackgroundDownloadTaskSnapshot] {
        await withCheckedContinuation { continuation in
            refreshSessionTasks(session: backgroundSession) { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
#if os(macOS) || canImport(UIKit)
                self.refreshSessionTasks(session: self.foregroundSession) { [weak self] in
                    continuation.resume(returning: self.map { Array($0.liveSnapshots.values) } ?? [])
                }
#else
                continuation.resume(returning: Array(self.liveSnapshots.values))
#endif
            }
        }
    }

    // MARK: - BGTaskScheduler
    #if canImport(BackgroundTasks) && !os(visionOS) && !os(macOS)
    private func registerBackgroundTask() {
        // Deliver the handler on the main queue to avoid libdispatch queue
        // assertions when the system wakes us on a maintenance queue after
        // long idle periods. Our manager is @MainActor‑isolated, so always hop
        // to the main actor before touching state or URLSession.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: maintenanceTaskIdentifier,
            using: .main
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.handleMaintenance(task: processingTask)
            }
        }
    }

    func scheduleMaintenance() {
        let request = BGProcessingTaskRequest(identifier: maintenanceTaskIdentifier)
        request.requiresNetworkConnectivity = true
        // Stalled/paused downloads should reconcile on battery too, not only while charging.
        request.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // Non-fatal; background tasks are best-effort.
            print("Failed to submit BGProcessingTask: \(error)")
        }
    }

    private func handleMaintenance(task: BGProcessingTask) {
        scheduleMaintenance() // Always reschedule for next time
        refreshSessionTasks(session: backgroundSession) {
            NotificationCenter.default.post(name: .downloadMaintenanceRequested, object: nil)
            task.setTaskCompleted(success: true)
        }
    }
    #else
    func scheduleMaintenance() {
        // BGProcessingTask isn't supported on visionOS or macOS. Downloads
        // still work while the process is active; macOS captures resume data
        // when the app actually quits.
    }
    #endif

    private func restorePersistedTasks() {
        #if os(macOS)
        // Builds before the foreground-throughput policy may have left live tasks
        // owned by nsurlsessiond. Move those tasks once at startup so upgrading does
        // not strand an existing transfer on the system-paced background transport.
        // runMigrationPass refreshes the background session before enumerating it;
        // refresh the foreground session afterward so replacement tasks are the
        // authoritative restored state before DownloadController reattaches observers.
        restorationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runMigrationPass(to: .foreground)
            await self.refreshSessionTasksAsync(session: self.foregroundSession)
        }
        #else
        refreshSessionTasks(session: backgroundSession)
        #if canImport(UIKit)
        refreshSessionTasks(session: foregroundSession)
        #endif
        #endif
    }

    /// Wait until any platform-specific transport restoration is settled before
    /// higher layers inspect tasks and attach their progress/completion handlers.
    func prepareForActiveProcess() async {
        #if os(macOS)
        await restorationTask?.value
        #endif
    }

    private func readExistingPartialSize(at local: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return max(0, size)
    }

    private func appIsActiveNow() -> Bool {
        #if canImport(UIKit)
        return UIApplication.sharedIfAvailable?.applicationState == .active
        #else
        return true
        #endif
    }
}

// MARK: - URLSessionDownloadDelegate
extension BackgroundDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let taskID = downloadTask.taskIdentifier
        let key = self.key(for: session, taskID: taskID)

        // Allow the first callback immediately, throttle to the UI-safe cadence afterward.
        // Always allow the final chunk even if it falls inside the throttle window.
        let isFinalChunk = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard progressThrottler.shouldAllow(key: key, force: isFinalChunk) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let storedOffset = self.resumeOffsets[key] ?? 0
            let offset = statusCode == 200 ? 0 : storedOffset
            // HTTP 200 on a task that was supposed to continue partway means the server
            // ignored/rejected the resume and restarted the file from byte zero. Tell
            // observers so monotonic byte counters reset instead of freezing at the
            // stale larger value while the new transfer catches up.
            if statusCode == 200, storedOffset > 0 || (self.resumedFromOffsets[key] ?? 0) > 0 {
                self.resumeOffsets[key] = nil
                self.resumedFromOffsets[key] = nil
                if let record = self.taskRecordByKey[key] {
                    await logger.log("[Download][Resume] server restarted \(record.destination.lastPathComponent) from byte 0 (HTTP 200 after resume attempt)")
                    self.postRestartNotification(jobID: record.jobID, artifactID: record.artifactID, destination: record.destination)
                }
            }
            let expectedFromTask = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            let recordedExpected = self.expectedSizes[key]
            let normalized = Self.normalizeProgressTotals(
                resumeOffset: offset,
                totalBytesWritten: totalBytesWritten,
                taskExpected: expectedFromTask,
                recordedExpected: recordedExpected
            )
            if let record = self.taskRecordByKey[key] {
                self.liveSnapshots[key] = Self.makeTaskSnapshot(
                    jobID: record.jobID,
                    artifactID: record.artifactID,
                    destination: record.destination,
                    resumeOffset: offset,
                    bytesReceived: max(0, totalBytesWritten),
                    taskExpected: expectedFromTask,
                    recordedExpected: recordedExpected,
                    hasLiveTask: true,
                    lastChunkBytes: max(0, bytesWritten),
                    httpStatusCode: statusCode
                )
            }

            if self.loggedProgressModes[key] != normalized.mode {
                self.loggedProgressModes[key] = normalized.mode
                let destination = self.destinations[key]?.lastPathComponent ?? "unknown"
                let taskLabel = expectedFromTask.map(String.init) ?? "nil"
                let recordedLabel = recordedExpected.map(String.init) ?? "nil"
                await logger.log(
                    "[Download][Progress] dest=\(destination) mode=\(normalized.mode.rawValue) offset=\(offset) taskExpected=\(taskLabel) recordedExpected=\(recordedLabel)"
                )
            }
            let now = Date()
            if isFinalChunk || now.timeIntervalSince(self.lastBytesLogAt[key] ?? .distantPast) >= self.bytesLogInterval {
                self.lastBytesLogAt[key] = now
                await logger.log(
                    "[Download][Bytes] taskID=\(taskID) status=\(statusCode) chunk=\(max(0, bytesWritten)) taskWritten=\(max(0, totalBytesWritten)) normalizedWritten=\(normalized.writtenTotal) normalizedExpected=\(normalized.fullExpected) offset=\(offset) mode=\(normalized.mode.rawValue)"
                )
            }

            if normalized.fullExpected > 0 {
                let fraction = Double(normalized.writtenTotal) / Double(normalized.fullExpected)
                self.progressHandlers[key]?(fraction)
                self.progressBytesHandlers[key]?(normalized.writtenTotal, normalized.fullExpected)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didFinishCollecting metrics: URLSessionTaskMetrics) {
        let taskID = task.taskIdentifier
        let key = self.key(for: session, taskID: taskID)
        let transaction = metrics.transactionMetrics.last
        let protocolName = transaction?.networkProtocolName ?? "unknown"
        let reused = transaction?.isReusedConnection ?? false
        let fetchType = transaction?.resourceFetchType.rawValue ?? 0
        let redirectCount = metrics.redirectCount
        let received = task.countOfBytesReceived
        let expected = task.countOfBytesExpectedToReceive
        Task {
            await logger.log(
                "[Download][Metrics] taskID=\(taskID) session=\(key.sessionID) protocol=\(protocolName) reused=\(reused) fetchType=\(fetchType) redirects=\(redirectCount) countOfBytesReceived=\(received) countOfBytesExpectedToReceive=\(expected)"
            )
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let taskID = downloadTask.taskIdentifier
        let description = downloadTask.taskDescription
        let key = key(for: session, taskID: taskID)
        // Decode the destination synchronously and move the file immediately.
        guard let record = Self.decodeTaskRecordNonisolated(from: description) else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completions[key]?(.failure(URLError(.unknown)))
                self.cleanup(key: key)
            }
            return
        }
        let destination = record.destination
        // Download tasks "succeed" for any HTTP status — a 403 from an expired signed CDN
        // URL (stale resume data) or an HTML error page would otherwise be saved over the
        // staging file, destroying partial data and failing format validation downstream.
        // Reject non-2xx responses here and leave the destination untouched.
        if let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode,
           !(200...299).contains(statusCode) {
            Task { @MainActor [weak self] in
                await logger.log("[Download][Error] dest=\(destination.lastPathComponent) HTTP \(statusCode) — discarding response body")
                self?.seedBookkeepingIfMissing(key: key, record: record)
                await self?.finalizeFailure(key: key, error: Self.serverRejectionError(statusCode: statusCode))
            }
            return
        }
        // Ensure parent exists and move the temp file before returning from delegate
        do {
            let parent = destination.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let shouldAppendRangePayload =
                record.appendsToExistingFile &&
                (downloadTask.response as? HTTPURLResponse)?.statusCode == 206 &&
                FileManager.default.fileExists(atPath: destination.path)
            if shouldAppendRangePayload {
                try Self.appendDownloadedChunk(at: location, to: destination)
                try? FileManager.default.removeItem(at: location)
            } else {
                try FileManager.default.removeItemIfExists(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            }
            Task { @MainActor [weak self] in
                self?.seedBookkeepingIfMissing(key: key, record: record)
                await self?.finalizeSuccess(key: key, destination: destination)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.seedBookkeepingIfMissing(key: key, record: record)
                await self?.finalizeFailure(key: key, error: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        let description = task.taskDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = self.key(for: session, taskID: taskID)
            // The task was cancelled to hand it off to the other URLSession.
            // Don't surface this as a failure; the migration owns the lifecycle.
            if self.migratingKeys.contains(key) { return }
            // Migration already re-created this transfer and persisted its resume
            // data; the old task's cancellation error trails behind. Swallow it or
            // the live replacement gets marked failed.
            if self.suppressedCancellations.removeValue(forKey: key) != nil { return }
            // After a process relaunch the in-memory record is gone but the encoded
            // record still rides in taskDescription — decode it so resume data is
            // persisted and the failure is routed instead of silently dropped.
            let record = self.taskRecordByKey[key] ?? Self.decodeTaskRecordNonisolated(from: description)
            // Transport failures (connection lost, timeouts, …) often carry resume data.
            // Persist it so the retry resumes where the transfer broke instead of
            // restarting from zero.
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let record {
                self.persistResumeData(resumeData, for: record)
            }
            self.seedBookkeepingIfMissing(key: key, record: record)
            await self.finalizeFailure(key: key, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    @MainActor
    private func finalizeSuccess(key: TaskKey, destination: URL) async {
        if let record = taskRecordByKey[key] {
            clearResumeData(for: record)
        }
        if let completion = completions[key] {
            completion(.success(destination))
        } else {
            // No in-memory continuation (likely after app restart). Notify observers so
            // they can reconcile and finalize installation from the completed file.
            let record = taskRecordByKey[key]
            NotificationCenter.default.post(
                name: .backgroundDownloadCompleted,
                object: nil,
                userInfo: [
                    "destinationURL": destination,
                    "taskID": key.taskID,
                    "jobID": record?.jobID as Any,
                    "artifactID": record?.artifactID as Any
                ]
            )
        }
        cleanup(key: key)
    }

    @MainActor
    private func finalizeFailure(key: TaskKey, error: Error) async {
        if let completion = completions[key] {
            completion(.failure(error))
        } else {
            // Surface failure via notification so UI can reflect the error state.
            var info: [String: Any] = [
                "error": error,
                "taskID": key.taskID
            ]
            // Best-effort: include original URL if we can still see the task
            if let task = liveTasks[key], let url = task.originalRequest?.url {
                info["originalURL"] = url
            }
            if let dest = destinations[key] { info["destinationURL"] = dest }
            if let record = taskRecordByKey[key] {
                info["jobID"] = record.jobID
                info["artifactID"] = record.artifactID
            }
            NotificationCenter.default.post(name: .backgroundDownloadCompleted, object: nil, userInfo: info)
        }
        cleanup(key: key)
    }

    /// After a process relaunch delegate events can arrive before the async task
    /// enumeration repopulates bookkeeping; seed it from the record decoded out of
    /// taskDescription so finalize paths can still report jobID/destination and
    /// clear resume data. Never overwrites live entries.
    @MainActor
    private func seedBookkeepingIfMissing(key: TaskKey, record: TaskRecord?) {
        guard taskRecordByKey[key] == nil, let record else { return }
        taskRecordByKey[key] = record
        if taskIdByDestination[record.destination.path] == nil {
            destinations[key] = record.destination
            taskIdByDestination[record.destination.path] = key
        }
    }

    @MainActor
    private func cleanup(key: TaskKey) {
        if let dest = destinations[key] {
            taskIdByDestination[dest.path] = nil
        }
        destinations[key] = nil
        taskRecordByKey[key] = nil
        liveTasks[key] = nil
        progressThrottler.clear(key: key)
        completions[key] = nil
        progressHandlers[key] = nil
        progressBytesHandlers[key] = nil
        expectedSizes[key] = nil
        resumeOffsets[key] = nil
        resumedFromOffsets[key] = nil
        liveSnapshots[key] = nil
        loggedProgressModes[key] = nil
        lastBytesLogAt[key] = nil
        if !suppressedCancellations.isEmpty {
            suppressedCancellations = suppressedCancellations.filter { $0.key != key && $0.value != key }
        }
    }
}

extension BackgroundDownloadManager {
    nonisolated private static func appendDownloadedChunk(at chunkURL: URL, to destination: URL) throws {
        let chunkSize = (try? FileManager.default.attributesOfItem(atPath: chunkURL.path)[.size] as? Int64) ?? 0
        let chunkHandle = try FileHandle(forReadingFrom: chunkURL)
        defer { try? chunkHandle.close() }
        let destinationHandle = try FileHandle(forWritingTo: destination)
        defer { try? destinationHandle.close() }
        let startOffset = try destinationHandle.seekToEnd()
        var finished = false
        while !finished {
            try autoreleasepool {
                guard let data = try chunkHandle.read(upToCount: 1_048_576), !data.isEmpty else {
                    finished = true
                    return
                }
                try destinationHandle.write(contentsOf: data)
            }
        }
        // A short append (disk full mid-write, truncated temp file) must fail the
        // download rather than silently install a corrupt partial as progress.
        let finalOffset = try destinationHandle.offset()
        let expectedOffset = startOffset + UInt64(max(0, chunkSize))
        guard finalOffset == expectedOffset else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteUnknown.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Appended segment size mismatch (expected \(expectedOffset) bytes, have \(finalOffset))"]
            )
        }
    }

    nonisolated static func makeTaskSnapshot(jobID: String?,
                                             artifactID: String?,
                                             destination: URL,
                                             resumeOffset: Int64,
                                             bytesReceived: Int64,
                                             taskExpected: Int64?,
                                             recordedExpected: Int64?,
                                             hasLiveTask: Bool,
                                             lastChunkBytes: Int64? = nil,
                                             httpStatusCode: Int? = nil) -> BackgroundDownloadTaskSnapshot {
        let normalized = normalizeProgressTotals(
            resumeOffset: resumeOffset,
            totalBytesWritten: max(0, bytesReceived),
            taskExpected: taskExpected,
            recordedExpected: recordedExpected
        )
        let normalizedExpected = normalized.fullExpected > 0 ? normalized.fullExpected : nil
        let byteAccounting = DownloadByteAccountingSnapshot(
            lastChunkBytes: lastChunkBytes.map { max(0, $0) },
            taskBytesWritten: max(0, bytesReceived),
            taskExpectedBytes: taskExpected,
            resumeOffset: max(0, resumeOffset),
            recordedExpectedBytes: recordedExpected,
            httpStatusCode: httpStatusCode,
            normalizedWrittenTotal: normalized.writtenTotal,
            normalizedFullExpected: normalizedExpected,
            normalizationMode: normalized.mode
        )
        return BackgroundDownloadTaskSnapshot(
            jobID: jobID,
            artifactID: artifactID,
            destination: destination,
            resumeOffset: max(0, resumeOffset),
            bytesReceived: max(0, bytesReceived),
            taskExpectedBytes: taskExpected,
            recordedExpectedBytes: recordedExpected,
            writtenTotal: normalized.writtenTotal,
            fullExpected: normalizedExpected,
            hasLiveTask: hasLiveTask,
            byteAccounting: byteAccounting
        )
    }

    nonisolated static func normalizeProgressTotals(
        resumeOffset: Int64,
        totalBytesWritten: Int64,
        taskExpected: Int64?,
        recordedExpected: Int64?
    ) -> DownloadProgressNormalizationResult {
        let offset = max(0, resumeOffset)
        let written = max(0, totalBytesWritten)
        let writtenTotal = saturatingAdd(written, offset)
        let expectedFromTask = taskExpected.flatMap { $0 > 0 ? $0 : nil }
        let expectedFromRecord = recordedExpected.flatMap { $0 > 0 ? $0 : nil }

        if offset == 0 {
            if let expectedFromTask {
                return DownloadProgressNormalizationResult(
                    writtenTotal: written,
                    fullExpected: expectedFromTask,
                    mode: .freshTask
                )
            }
            if let expectedFromRecord {
                return DownloadProgressNormalizationResult(
                    writtenTotal: written,
                    fullExpected: expectedFromRecord,
                    mode: .freshRecorded
                )
            }
            return DownloadProgressNormalizationResult(
                writtenTotal: written,
                fullExpected: -1,
                mode: .unknown
            )
        }

        if let expectedFromTask {
            if let expectedFromRecord {
                let tolerance = max(Int64(512 * 1024), expectedFromRecord / 100)
                let difference = max(expectedFromTask, expectedFromRecord) - min(expectedFromTask, expectedFromRecord)
                if difference <= tolerance {
                    return DownloadProgressNormalizationResult(
                        writtenTotal: writtenTotal,
                        fullExpected: expectedFromRecord,
                        mode: .resumeFullSize
                    )
                }

                let remainingExpected = saturatingAdd(offset, expectedFromTask)
                if saturatingAdd(expectedFromTask, tolerance) < expectedFromRecord {
                    return DownloadProgressNormalizationResult(
                        writtenTotal: writtenTotal,
                        fullExpected: remainingExpected,
                        mode: .resumeRemainingBytes
                    )
                }

                return DownloadProgressNormalizationResult(
                    writtenTotal: writtenTotal,
                    fullExpected: max(expectedFromRecord, remainingExpected),
                    mode: .resumeFallback
                )
            }

            return DownloadProgressNormalizationResult(
                writtenTotal: writtenTotal,
                fullExpected: saturatingAdd(offset, expectedFromTask),
                mode: .resumeNoRecorded
            )
        }

        if let expectedFromRecord {
            return DownloadProgressNormalizationResult(
                writtenTotal: writtenTotal,
                fullExpected: expectedFromRecord,
                mode: .resumeRecordedOnly
            )
        }

        return DownloadProgressNormalizationResult(
            writtenTotal: writtenTotal,
            fullExpected: -1,
            mode: .unknown
        )
    }

    nonisolated private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return value }
        return rhs >= 0 ? .max : .min
    }

    /// Best-effort HEAD to learn the true Content-Length before starting a download.
    private func remoteContentLength(for request: URLRequest) async -> Int64? {
        guard !NetworkKillSwitch.shouldBlock(request: request) else { return nil }
        var head = request
        head.httpMethod = "HEAD"
        head.timeoutInterval = 10
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: cfg)
        NetworkKillSwitch.track(session: session)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, resp) = try await session.data(for: head)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let len = http.expectedContentLength
            return len > 0 ? len : nil
        } catch {
            return nil
        }
    }

    @MainActor
    private func record(for taskDescription: String?) -> TaskRecord? {
        guard let desc = taskDescription,
              let data = desc.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskRecord.self, from: data)
    }

    // Nonisolated decoding helper so we can move the temp file synchronously inside the delegate.
    nonisolated private static func decodeTaskRecordNonisolated(from taskDescription: String?) -> TaskRecord? {
        guard let desc = taskDescription, let data = desc.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskRecord.self, from: data)
    }

    /// Choose the session durable transfers run on.
    private func preferredSession() -> URLSession {
        #if os(macOS)
        switch DownloadTransportPolicy.macOSActiveProcess {
        case .foreground:
            logSessionChoice(kind: .foreground, reason: "macOS active process")
            return foregroundSession
        case .background:
            logSessionChoice(kind: .background, reason: "macOS durable transport")
            return backgroundSession
        }
        #elseif os(iOS)
        var supportsContinuedProcessing = false
        var hasContinuedProcessingTask = false
        if #available(iOS 26.0, *) {
            supportsContinuedProcessing = true
            hasContinuedProcessingTask = ContinuedDownloadCoordinator.shared.protectsForegroundTransport
        }
        let decision = DownloadTransportPolicy.preferred(
            isAppActive: appIsActiveNow(),
            supportsContinuedProcessing: supportsContinuedProcessing,
            hasContinuedProcessingTask: hasContinuedProcessingTask
        )
        switch decision {
        case .foreground:
            let reason = hasContinuedProcessingTask ? "continued processing" : "app active"
            logSessionChoice(kind: .foreground, reason: reason)
            return foregroundSession
        case .background:
            logSessionChoice(kind: .background, reason: "durable fallback")
            return backgroundSession
        }
        #else
        // visionOS keeps the foreground-speed optimization and hands the transfer
        // to its background session during the lifecycle transition.
        if appIsActiveNow() {
            logSessionChoice(kind: .foreground, reason: "app active")
            return foregroundSession
        }
        logSessionChoice(kind: .background, reason: "app not active")
        return backgroundSession
        #endif
    }
}

// MARK: - Session Migration (lifecycle fallback and visionOS handoff)
extension BackgroundDownloadManager {
    /// Wrap a completion so a second invocation is a no-op. The underlying
    /// `withCheckedThrowingContinuation` must be resumed exactly once even if
    /// both a migration and a delegate callback race to finish it.
    func idempotentCompletion(_ body: @escaping (Result<URL, Error>) -> Void) -> (Result<URL, Error>) -> Void {
        var done = false
        return { result in
            if done { return }
            done = true
            body(result)
        }
    }

    private func session(for kind: SessionKind) -> URLSession {
        switch kind {
        case .foreground: return foregroundSession
        case .background: return backgroundSession
        }
    }

    private func sessionID(for kind: SessionKind) -> String {
        session(for: kind).configuration.identifier ?? "foreground"
    }

    private func label(for kind: SessionKind) -> String {
        kind == .foreground ? "foreground" : "background"
    }

    private func refreshSessionTasksAsync(session: URLSession) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            refreshSessionTasks(session: session) { cont.resume() }
        }
    }

    /// Move every per-key bookkeeping entry from `oldKey` to `newKey` atomically
    /// (all on the main actor). The stored completion closure travels with the
    /// dictionary value, so the original `async` continuation is preserved.
    private func transferState(from oldKey: TaskKey,
                               to newKey: TaskKey,
                               newTask: URLSessionDownloadTask,
                               newResumeOffset: Int64?) {
        if let dest = destinations[oldKey] {
            destinations[newKey] = dest
            taskIdByDestination[dest.path] = newKey
        }
        destinations[oldKey] = nil

        if let v = completions[oldKey] { completions[newKey] = v }
        completions[oldKey] = nil
        if let v = progressHandlers[oldKey] { progressHandlers[newKey] = v }
        progressHandlers[oldKey] = nil
        if let v = progressBytesHandlers[oldKey] { progressBytesHandlers[newKey] = v }
        progressBytesHandlers[oldKey] = nil
        if let v = expectedSizes[oldKey] { expectedSizes[newKey] = v }
        expectedSizes[oldKey] = nil
        if let v = taskRecordByKey[oldKey] { taskRecordByKey[newKey] = v }
        taskRecordByKey[oldKey] = nil
        if let v = liveSnapshots[oldKey] { liveSnapshots[newKey] = v }
        liveSnapshots[oldKey] = nil
        if let v = loggedProgressModes[oldKey] { loggedProgressModes[newKey] = v }
        loggedProgressModes[oldKey] = nil

        let resolvedOffset = newResumeOffset ?? resumeOffsets[oldKey]
        if let resolvedOffset, resolvedOffset > 0 {
            resumeOffsets[newKey] = resolvedOffset
        } else {
            resumeOffsets[newKey] = nil
        }
        resumeOffsets[oldKey] = nil
        if let v = resumedFromOffsets[oldKey] { resumedFromOffsets[newKey] = v }
        resumedFromOffsets[oldKey] = nil

        liveTasks[newKey] = newTask
        liveTasks[oldKey] = nil
        progressThrottler.clear(key: oldKey)
    }

    private func migrateOneTask(oldKey: TaskKey,
                                task: URLSessionDownloadTask,
                                to target: SessionKind,
                                persist: Bool) async {
        let record = taskRecordByKey[oldKey]
        let originalRequest = task.originalRequest

        // Mark BEFORE cancelling so the cancellation delegate callback knows to
        // ignore this task instead of reporting a spurious failure/pause.
        migratingKeys.insert(oldKey)

        let resumeData: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            task.cancel(byProducingResumeData: { data in cont.resume(returning: data) })
        }

        let targetSession = session(for: target)
        let newTask: URLSessionDownloadTask
        var newResumeOffset: Int64? = nil
        var resumedMarker: Int64? = nil

        if let resumeData {
            newTask = targetSession.downloadTask(withResumeData: resumeData)
            // The handed-off task keeps URLSession's resume semantics: didWriteData totals
            // continue from where the old task stopped. Any additive Range offset carries
            // over from the old key via transferState — installing the extracted resume
            // point as an additive offset here would double-count every progress tick.
            let off = Self.extractResumeOffset(from: resumeData)
            resumedMarker = off > 0 ? off : nil
            // Belt-and-suspenders: also persist to disk so a process kill before
            // the handed-off task finishes can still resume on next launch.
            if persist, let record { persistResumeData(resumeData, for: record) }
        } else if let originalRequest {
            // No resume data (transfer hadn't produced any yet). Restart, re-deriving
            // the Range header from the current on-disk partial when appending.
            var req = originalRequest
            req.setValue(nil, forHTTPHeaderField: "Range")
            if let record, record.appendsToExistingFile {
                let partial = readExistingPartialSize(at: record.destination)
                if partial > 0 {
                    req.setValue("bytes=\(partial)-", forHTTPHeaderField: "Range")
                    newResumeOffset = partial
                }
            }
            newTask = targetSession.downloadTask(with: req)
        } else {
            // Task already finished between enumeration and cancel; nothing to migrate.
            migratingKeys.remove(oldKey)
            return
        }

        newTask.priority = URLSessionTask.highPriority

        if let record, let enc = try? JSONEncoder().encode(record),
           let desc = String(data: enc, encoding: .utf8) {
            newTask.taskDescription = desc
        } else {
            newTask.taskDescription = task.taskDescription
        }

        let newKey = key(for: targetSession, taskID: newTask.taskIdentifier)
        transferState(from: oldKey, to: newKey, newTask: newTask, newResumeOffset: newResumeOffset)
        if let resumedMarker { resumedFromOffsets[newKey] = resumedMarker }
        migratingKeys.remove(oldKey)
        suppressedCancellations[oldKey] = newKey
        newTask.resume()

        let dest = record?.destination.lastPathComponent ?? "unknown"
        await logger.log("[Download][Migrate] dest=\(dest) -> \(label(for: target)) resumeData=\(resumeData != nil) rangeOffset=\(newResumeOffset ?? resumeOffsets[newKey] ?? 0) resumedAt=\(resumedMarker ?? 0)")
    }

    /// Run a whole-session migration pass, queued behind any in-flight pass so
    /// bounced lifecycle events (resign→active) can never interleave or strand
    /// tasks on the wrong session.
    private func runMigrationPass(to target: SessionKind) async {
        let previous = migrationChain
        let pass = Task { @MainActor [weak self] in
            await previous?.value
            await self?.migrateAllTasks(to: target)
        }
        migrationChain = pass
        await pass.value
    }

    /// Put cancellation/expiration cleanup in the same serialization chain as
    /// lifecycle migrations. Once this operation is queued, no older migration
    /// can create a replacement after cleanup pauses the transfer, and any newer
    /// migration must wait until cleanup has finished.
    private func runAfterMigrationPasses(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let previous = migrationChain
        let pass = Task { @MainActor in
            await previous?.value
            await operation()
        }
        migrationChain = pass
        await pass.value
    }

    private func migrateAllTasks(to target: SessionKind) async {
        let source: SessionKind = (target == .foreground) ? .background : .foreground
        await refreshSessionTasksAsync(session: session(for: source))
        let sourceID = sessionID(for: source)
        let keys = liveTasks.compactMap { $0.key.sessionID == sourceID ? $0.key : nil }
        guard !keys.isEmpty else { return }
        var migrated = 0
        for oldKey in keys {
            guard let task = liveTasks[oldKey] else { continue }
            await migrateOneTask(oldKey: oldKey, task: task, to: target, persist: true)
            migrated += 1
        }
        await logger.log("[Download][Migrate] moved \(migrated) transfer(s) to the \(label(for: target)) session")
    }
}

// MARK: - Resume Data Helpers
private extension BackgroundDownloadManager {
    /// Extract the number of bytes that were already received from the URLSession resume data blob.
    /// The resume data format is an opaque plist keyed archive; we defensively try both modern and
    /// legacy keys to maximize compatibility across platforms.
    static func extractResumeOffset(from data: Data) -> Int64 {
        // 1) Attempt to parse as a property list dictionary
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: PropertyListSerialization.ReadOptions(), format: nil) as? [String: Any] {
            if let n = plist["NSURLSessionResumeBytesReceived"] as? NSNumber { return n.int64Value }
            if let n = plist["_NSURLSessionResumeBytesReceived"] as? NSNumber { return n.int64Value }
        }

        // 2) Fallback to keyed unarchiver (older iOS/macOS versions)
        if let dict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSNumber.self, NSString.self, NSData.self], from: data) as? [String: Any] {
            if let n = dict["NSURLSessionResumeBytesReceived"] as? NSNumber { return n.int64Value }
            if let n = dict["_NSURLSessionResumeBytesReceived"] as? NSNumber { return n.int64Value }
        }

        return 0
    }
}

#if canImport(UIKit)
extension BackgroundDownloadManager {
    /// The scheduler may adopt a `.fail` continued-processing request just after
    /// `willResignActive` has already queued the durable fallback. Queue a second,
    /// conditional pass behind that handoff so accepted protection always restores
    /// the high-throughput session instead of leaving the transfer stranded on the
    /// system-paced background session.
    func handleContinuedDownloadProtectionBecameActive() async {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return }
        let previous = migrationChain
        let pass = Task { @MainActor [weak self] in
            await previous?.value
            guard ContinuedDownloadCoordinator.shared.protectsForegroundTransport else { return }
            await self?.migrateAllTasks(to: .foreground)
        }
        migrationChain = pass
        await pass.value
        #endif
    }

    /// App is about to leave the active state (lock, app switcher, control
    /// center). iOS 26 keeps fast default-session transfers in place while an
    /// accepted continued-processing task protects them. Without that protection,
    /// preserve them on the durable session before suspension.
    func handleWillResignActive() async {
        guard !liveTasks.isEmpty else { return }
        #if os(iOS)
        if #available(iOS 26.0, *), ContinuedDownloadCoordinator.shared.protectsForegroundTransport {
            await logger.log("[Download][App] keeping \(liveTasks.count) fast transfer(s) on the default session under continued-processing protection")
            return
        }
        await runMigrationPass(to: .background)
        #else
        await runMigrationPass(to: .background)
        #endif
    }

    /// App reached the background. Protected iOS 26 transfers continue in-process;
    /// fallback and visionOS transfers run on the durable session.
    func handleEnterBackground() async {
        guard !liveTasks.isEmpty else { return }
        await logger.log("[Download][App] \(liveTasks.count) transfer(s) continue while the app is backgrounded")
    }

    /// The app is foreground again, so restore any durable fallback transfer to
    /// the high-throughput default session. A later lifecycle transition will keep
    /// it there only when continued-processing protection is active.
    func handleBecomeActive() async {
        await runMigrationPass(to: .foreground)
    }

    /// A continued-processing task expired or was cancelled. Begin UIKit cleanup
    /// time synchronously before running the caller's cooperative stop/pause work,
    /// then tell BackgroundTasks that cleanup has finished. Continuing the same
    /// operation on a different session would ignore a person's system-level Cancel.
    func handleContinuedDownloadProtectionEnded(
        cleanup: @escaping @MainActor () async -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        #if os(iOS)
        let completionBox = DownloadExpirationCompletion(completion)
        if appIsActiveNow() {
            Task { @MainActor [weak self] in
                if let self {
                    await self.runAfterMigrationPasses(cleanup)
                } else {
                    await cleanup()
                }
                completionBox.finish()
            }
            return
        }
        let application = UIApplication.shared
        let gracePeriod = DownloadExpirationGracePeriod()
        gracePeriod.identifier = application.beginBackgroundTask(withName: "Pause downloads") {
            Task { @MainActor in
                gracePeriod.end()
                completionBox.finish()
            }
        }
        Task { @MainActor [weak self] in
            if let self {
                await self.runAfterMigrationPasses(cleanup)
            } else {
                await cleanup()
            }
            gracePeriod.end()
            completionBox.finish()
        }
        #else
        Task { @MainActor in
            await cleanup()
            completion()
        }
        #endif
    }
}

private extension UIApplication {
    static var sharedIfAvailable: UIApplication? {
        // Avoid accessing UIApplication in app extensions
        guard NSClassFromString("UIApplication") != nil else { return nil }
        return UIApplication.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
    }
}
#endif

// FileManager helper is defined globally in Noema.swift
