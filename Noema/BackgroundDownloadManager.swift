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

private final class ProgressThrottler<Key: Hashable> {
    private let minimumInterval: Double
    private var lastFireSeconds: [Key: Double] = [:]
    private let lock = NSLock()

    init(interval: TimeInterval) {
        self.minimumInterval = interval
    }

    func shouldAllow(key: Key, force: Bool = false) -> Bool {
        let nowSeconds = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        lock.lock()
        defer { lock.unlock() }

        if force {
            lastFireSeconds[key] = nowSeconds
            return true
        }

        if let last = lastFireSeconds[key], (nowSeconds - last) < minimumInterval {
            return false
        }

        lastFireSeconds[key] = nowSeconds
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

/// Manages large downloads that should continue while the app is suspended or terminated.
/// Uses a background URLSession with a fixed identifier and exposes a simple async API.
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

        enum CodingKeys: String, CodingKey {
            case jobID
            case artifactID
            case destination
            case expectedSize
            case resumeOffset
            case appendsToExistingFile
            case resumedAtOffset
        }

        init(jobID: String?,
             artifactID: String?,
             destination: URL,
             expectedSize: Int64?,
             resumeOffset: Int64?,
             appendsToExistingFile: Bool,
             resumedAtOffset: Int64? = nil) {
            self.jobID = jobID
            self.artifactID = artifactID
            self.destination = destination
            self.expectedSize = expectedSize
            self.resumeOffset = resumeOffset
            self.appendsToExistingFile = appendsToExistingFile
            self.resumedAtOffset = resumedAtOffset
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
        #if os(iOS) || os(tvOS) || os(watchOS)
        if #available(iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
            config.multipathServiceType = .handover
        }
        #endif
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        s.sessionDescription = "Noema background downloads"
        NetworkKillSwitch.track(session: s)
        return s
    }()

    // Fast foreground session used while the app is active; noticeably improves throughput
    private lazy var foregroundSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.httpShouldUsePipelining = true
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

    // Throttle progress events to ~10 Hz per download to avoid flooding the main actor.
    nonisolated(unsafe) private let progressThrottler = ProgressThrottler<TaskKey>(interval: 0.1)

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
    // Per-task byte logging is throttled hard: at 10 Hz per task the log lines
    // (string interpolation + file write + stderr flush) measurably drag the app.
    private var lastBytesLogAt: [TaskKey: Date] = [:]
    private let bytesLogInterval: TimeInterval = 2.0
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
    private var isMigrating = false
    private var pendingMigration: (from: SessionKind, to: SessionKind, reason: String)? = nil

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
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                await logger.log("[Download][App] didEnterBackground – migrating active transfers to background URLSession")
                await self?.handleEnterBackground()
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { await logger.log("[Download][App] willEnterForeground") }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                await logger.log("[Download][App] didBecomeActive – migrating durable transfers to foreground URLSession")
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
        var req = URLRequest(url: remote)
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
        // Try to refine the expected size with a HEAD request; this fixes UI lag when registry
        // metadata overestimates the real file size. We only do this for the initial call
        // (resume path below already has a persisted expectedSize).
        let headLength = await remoteContentLength(for: request)
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
            if let resume = self.loadResumeData(for: resumeRecord) {
                let offset = Self.extractResumeOffset(from: resume)
                let task = session.downloadTask(withResumeData: resume)
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
                    resumedAtOffset: offset > 0 ? offset : nil
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
        let session = self.preferredSession()
        let existingPartialBytes = allowRangeResume ? self.readExistingPartialSize(at: local) : 0
        let shouldAttemptRangeResume = existingPartialBytes > 0
        var requestToStart = request
        requestToStart.setValue(nil, forHTTPHeaderField: "Range")
        if shouldAttemptRangeResume {
            requestToStart.setValue("bytes=\(existingPartialBytes)-", forHTTPHeaderField: "Range")
        }
        let task = session.downloadTask(with: requestToStart)
        let record = TaskRecord(
            jobID: jobID,
            artifactID: artifactID,
            destination: local,
            expectedSize: refinedExpected,
            resumeOffset: shouldAttemptRangeResume ? existingPartialBytes : nil,
            appendsToExistingFile: shouldAttemptRangeResume
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
        request.requiresExternalPower = true
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
        // still work while the scene is active thanks to the background
        // URLSession.
    }
    #endif

    private func restorePersistedTasks() {
        refreshSessionTasks(session: backgroundSession)
        #if os(macOS) || canImport(UIKit)
        refreshSessionTasks(session: foregroundSession)
        #endif
    }

    private func readExistingPartialSize(at local: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return max(0, size)
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

        // Allow the first callback immediately, throttle to 10 Hz afterward.
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
                await self?.finalizeSuccess(key: key, destination: destination)
            }
        } catch {
            Task { @MainActor [weak self] in
                await self?.finalizeFailure(key: key, error: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = self.key(for: session, taskID: taskID)
            // The task was cancelled to hand it off to the other URLSession.
            // Don't surface this as a failure; the migration owns the lifecycle.
            if self.migratingKeys.contains(key) { return }
            // Transport failures (connection lost, timeouts, …) often carry resume data.
            // Persist it so the retry resumes where the transfer broke instead of
            // restarting from zero.
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let record = self.taskRecordByKey[key] {
                self.persistResumeData(resumeData, for: record)
            }
            self.completions[key]?(.failure(error))
            self.cleanup(key: key)
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
    }
}

extension BackgroundDownloadManager {
    nonisolated private static func appendDownloadedChunk(at chunkURL: URL, to destination: URL) throws {
        let chunkHandle = try FileHandle(forReadingFrom: chunkURL)
        defer { try? chunkHandle.close() }
        let destinationHandle = try FileHandle(forWritingTo: destination)
        defer { try? destinationHandle.close() }
        try destinationHandle.seekToEnd()
        while autoreleasepool(invoking: {
            let data = try? chunkHandle.read(upToCount: 1_048_576) ?? Data()
            guard let data, !data.isEmpty else { return false }
            try? destinationHandle.write(contentsOf: data)
            return true
        }) {}
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
        let writtenTotal = totalBytesWritten + offset
        let expectedFromTask = taskExpected.flatMap { $0 > 0 ? $0 : nil }
        let expectedFromRecord = recordedExpected.flatMap { $0 > 0 ? $0 : nil }

        if offset == 0 {
            if let expectedFromTask {
                return DownloadProgressNormalizationResult(
                    writtenTotal: totalBytesWritten,
                    fullExpected: expectedFromTask,
                    mode: .freshTask
                )
            }
            if let expectedFromRecord {
                return DownloadProgressNormalizationResult(
                    writtenTotal: totalBytesWritten,
                    fullExpected: expectedFromRecord,
                    mode: .freshRecorded
                )
            }
            return DownloadProgressNormalizationResult(
                writtenTotal: totalBytesWritten,
                fullExpected: -1,
                mode: .unknown
            )
        }

        if let expectedFromTask {
            if let expectedFromRecord {
                let tolerance = max(Int64(512 * 1024), expectedFromRecord / 100)
                if abs(expectedFromTask - expectedFromRecord) <= tolerance {
                    return DownloadProgressNormalizationResult(
                        writtenTotal: writtenTotal,
                        fullExpected: expectedFromRecord,
                        mode: .resumeFullSize
                    )
                }

                let remainingExpected = offset + expectedFromTask
                if expectedFromTask + tolerance < expectedFromRecord {
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
                fullExpected: offset + expectedFromTask,
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

    /// Best-effort HEAD to learn the true Content-Length before starting a download.
    private func remoteContentLength(for request: URLRequest) async -> Int64? {
        var head = request
        head.httpMethod = "HEAD"
        head.timeoutInterval = 10
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: cfg)
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

    /// Choose the best session for the current app state: prefer a fast foreground session while
    /// the app is active, fall back to the background-capable session otherwise.
    private func preferredSession() -> URLSession {
        #if os(macOS)
        // macOS: use a foreground session so downloads start immediately and are visible in Xcode.
        // Background URLSessions on macOS can be deferred or require additional background modes.
        logSessionChoice(kind: .foreground, reason: "macOS")
        return foregroundSession
        #elseif canImport(UIKit)
        // iOS/iPadOS: while the app is active, use the fast default URLSession so
        // throughput and progress callbacks aren't throttled/coalesced by nsurlsessiond.
        // When the app is not active, use the background-capable session so the
        // transfer survives suspend/lock. Lifecycle observers migrate in-flight
        // tasks between the two sessions so both states work seamlessly.
        let state = UIApplication.sharedIfAvailable?.applicationState
        let stateLabel: String = {
            switch state {
            case .some(.active): return "active"
            case .some(.background): return "background"
            case .some(.inactive): return "inactive"
            default: return "unknown"
            }
        }()
        if state == .active {
            logSessionChoice(kind: .foreground, reason: "active iOS transfer appState=\(stateLabel)")
            return foregroundSession
        }
        logSessionChoice(kind: .background, reason: "durable iOS transfer appState=\(stateLabel)")
        return backgroundSession
        #else
        logSessionChoice(kind: .background, reason: "platform default")
        return backgroundSession
        #endif
    }
}

// MARK: - Session Migration (iOS foreground ⇄ background handoff)
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
        newTask.resume()

        let dest = record?.destination.lastPathComponent ?? "unknown"
        await logger.log("[Download][Migrate] dest=\(dest) -> \(label(for: target)) resumeData=\(resumeData != nil) rangeOffset=\(newResumeOffset ?? resumeOffsets[newKey] ?? 0) resumedAt=\(resumedMarker ?? 0)")
    }

    /// Hand off all in-flight tasks from one session to the other, preserving
    /// progress and the awaiting continuation. Re-entrant safe: a request that
    /// arrives mid-migration is coalesced and run afterward.
    private func migrateTasks(from source: SessionKind, to target: SessionKind, reason: String) async {
        if isMigrating {
            pendingMigration = (source, target, reason)
            return
        }
        isMigrating = true
        defer { isMigrating = false }

        var work: (from: SessionKind, to: SessionKind, reason: String)? = (source, target, reason)
        while let job = work {
            work = nil
            let srcSession = session(for: job.from)
            await refreshSessionTasksAsync(session: srcSession)
            let srcID = sessionID(for: job.from)
            let keys = liveTasks.compactMap { $0.key.sessionID == srcID ? $0.key : nil }
            if !keys.isEmpty {
                await logger.log("[Download][Migrate] start count=\(keys.count) \(label(for: job.from))->\(label(for: job.to)) reason=\(job.reason)")
            }
            for oldKey in keys {
                guard let task = liveTasks[oldKey] else { continue }
                await migrateOneTask(oldKey: oldKey, task: task, to: job.to, persist: job.to == .background)
            }
            if let pending = pendingMigration {
                pendingMigration = nil
                work = pending
            }
        }
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
    /// App is suspending: move fast (default-session) transfers onto the
    /// background-capable session so they survive lock/suspend. Hold a
    /// background-task assertion so the async resume-data callbacks finish
    /// before the process is suspended.
    func handleEnterBackground() async {
        guard !liveTasks.isEmpty else { return }
        let app = UIApplication.sharedIfAvailable
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        var ended = false
        func endBG() {
            guard !ended else { return }
            ended = true
            if bgTask != .invalid {
                app?.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        bgTask = app?.beginBackgroundTask(withName: "noema.download.migrate") {
            Task { @MainActor in
                await logger.log("[Download][Migrate] background-task assertion expired before handoff completed")
                endBG()
            }
        } ?? .invalid
        await migrateTasks(from: .foreground, to: .background, reason: "didEnterBackground")
        endBG()
    }

    /// App is active again: move durable (background-session) transfers back
    /// onto the fast default session for full throughput and live progress.
    func handleBecomeActive() async {
        guard !liveTasks.isEmpty else { return }
        await migrateTasks(from: .background, to: .foreground, reason: "didBecomeActive")
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
