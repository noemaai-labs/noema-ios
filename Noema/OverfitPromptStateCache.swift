import Foundation
import NoemaPackages

final class OverfitPromptStateCache: @unchecked Sendable {
    static let shared = OverfitPromptStateCache()

    static let environmentKey = "NOEMA_PAGED_SLOT_SAVE_DIR"
    static let fileExtension = "noemaslot"
    static let checkpointFileExtension = "noemackpt"
    /// Bump whenever the native slot/sidecar contract or identity inputs
    /// change incompatibly. This makes older files cold misses rather than
    /// asking native restore to interpret stale state.
    static let identityVersion = 2
    /// LRU cap for the whole cache directory. KV state files scale with
    /// context and model size (hundreds of MiB each on Mac-class models).
    static let maxTotalBytes: Int64 = 4 << 30

    private let lock = NSLock()
    /// Filename for the session prepared by the last prepareForPagedLaunch;
    /// nil while no paged session is active or preparation failed.
    private var pendingFilename: String?
    /// Loopback port bound by restoreIfAvailable; save only fires for
    /// completions on this exact server instance.
    private var activePort: Int32 = 0
    private var saveInFlight = false
    private var saveRequested = false
    private var restoreAwaitingReuseCheck = false
    private var sessionGeneration: UInt64 = 0

    private init() {}

    // MARK: - Launch preparation (synchronous, pre-server-start)

    /// Creates the cache directory, exports it via the env var the native
    /// bridge reads at argv-build time, and derives this session's filename.
    /// Must run before LlamaServerBridge.start for the paged launch.
    func prepareForPagedLaunch(
        packageDirectory: URL,
        configuration: LlamaServerBridge.StartConfiguration,
        systemPromptText: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        pendingFilename = nil
        activePort = 0
        sessionGeneration &+= 1
        saveInFlight = false
        saveRequested = false
        restoreAwaitingReuseCheck = false
        do {
            let directory = try Self.cacheDirectoryCreatingIfNeeded()
            setenv(Self.environmentKey, directory.path, 1)
            let fingerprint = try Self.packageFingerprint(packageDirectory: packageDirectory)
            // The filename covers every launch input that can change token
            // serialization, KV layout, recurrent/SWA snapshots, or draft
            // state. A mismatch becomes a cold miss rather than a corrupt or
            // silently ineffective restore.
            let identity = Self.cacheIdentity(
                packageFingerprint: fingerprint,
                configuration: configuration,
                systemPromptText: systemPromptText
            )
            let digest = PagedSHA256.hexDigest(of: Data(identity.utf8))
            pendingFilename = digest + "." + Self.fileExtension
            Self.pruneLRU(directory: directory, protecting: pendingFilename)
        } catch {
            // Without a directory the env var must not leak a stale value
            // into this boot: the bridge validates existence, but a valid
            // older directory would enable endpoints nobody will call.
            unsetenv(Self.environmentKey)
            Task { await logger.log("[OverfitSlotCache] prepare failed: \(error.localizedDescription)") }
        }
    }

    // Synchronous so the lock never straddles a suspension point.
    private func takePendingFilename(activePort port: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        self.activePort = port
        return pendingFilename
    }

    private func markRestoreAwaitingReuseCheck(filename: String, port: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if pendingFilename == filename, activePort == port {
            restoreAwaitingReuseCheck = true
        }
    }

    private func takeQueuedSave(filename: String, port: Int32, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sessionGeneration == generation, pendingFilename == filename, activePort == port else {
            return false
        }
        guard saveRequested else {
            saveInFlight = false
            return false
        }
        saveRequested = false
        return true
    }

    private func finishSuccessfulSave(
        filename: String, port: Int32, generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sessionGeneration == generation, pendingFilename == filename, activePort == port else {
            return false
        }
        let shouldRepeat = saveRequested
        if !shouldRepeat { saveInFlight = false }
        return shouldRepeat
    }

    private func finishFailedSave(filename: String, port: Int32, generation: UInt64) {
        lock.lock()
        if sessionGeneration == generation, pendingFilename == filename, activePort == port {
            saveInFlight = false
            saveRequested = false
        }
        lock.unlock()
    }

    // MARK: - Restore (post-ready, pre-first-request)

    /// Restores this session's state file into slot 0 if one exists. Runs
    /// after the paged server reports ready and before the first user
    /// request. Fail-open: any error logs and leaves the slot cold.
    func restoreIfAvailable(port: Int32) async {
        let filename = takePendingFilename(activePort: port)
        guard let filename, port > 0 else { return }
        guard let directory = try? Self.cacheDirectoryCreatingIfNeeded() else { return }
        let fileURL = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Task { await logger.log("[OverfitSlotCache] no saved state for this identity — cold prefill") }
            return
        }
        do {
            let response = try await Self.slotAction(port: port, action: "restore", filename: filename)
            let restored = (response["n_restored"] as? NSNumber)?.intValue ?? 0
            let read = (response["n_read"] as? NSNumber)?.int64Value ?? 0
            guard restored > 0, read > 0 else {
                throw NSError(domain: "OverfitSlotCache", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "restore returned n_restored=\(restored) n_read=\(read)",
                ])
            }
            // Freshen for LRU so live identities outlast abandoned ones.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: fileURL.path)
            let checkpointURL = Self.checkpointURL(for: fileURL)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: checkpointURL.path)
            markRestoreAwaitingReuseCheck(filename: filename, port: port)
            Task { await logger.log("[OverfitSlotCache] restored n_tokens=\(restored) bytes=\(read) file=\(filename)") }
        } catch {
            // Native restore clears partially loaded state. Remove this pair
            // so an incompatible legacy/corrupt entry is not retried at every
            // launch; the next successful completion writes a fresh pair.
            Self.removeCacheEntry(filename: filename, directory: directory)
            Task { await logger.log("[OverfitSlotCache] restore failed (cold prefill): \(error.localizedDescription)") }
        }
    }

    // MARK: - Save (after successful paged completions)

    /// Called by the loopback client after every successful paged completion;
    /// coalesces overlapping requests while always persisting the newest idle
    /// slot. The server defers a save until the slot is idle, so a follow-up
    /// turn can safely arrive while an earlier save request is outstanding.
    func noteSuccessfulPagedCompletion(port: Int32, promptCacheTokens: Int?) {
        lock.lock()
        guard let filename = pendingFilename, port > 0, port == activePort else {
            lock.unlock()
            return
        }

        var ineffectiveRestore = false
        if restoreAwaitingReuseCheck, let promptCacheTokens {
            ineffectiveRestore = promptCacheTokens == 0
            restoreAwaitingReuseCheck = false
        }
        saveRequested = true
        guard !saveInFlight else {
            lock.unlock()
            if ineffectiveRestore {
                Task { await logger.log("[OverfitSlotCache] restored state reused 0 prompt tokens; replacing it with the current slot") }
            }
            return
        }
        saveInFlight = true
        let generation = sessionGeneration
        lock.unlock()

        if ineffectiveRestore {
            Task { await logger.log("[OverfitSlotCache] restored state reused 0 prompt tokens; replacing it with the current slot") }
        }
        Task.detached(priority: .utility) {
            await self.drainSaveRequests(
                filename: filename, port: port, generation: generation)
        }
    }

    private func drainSaveRequests(
        filename: String, port: Int32, generation: UInt64
    ) async {
        while true {
            guard takeQueuedSave(
                filename: filename, port: port, generation: generation) else { return }

            do {
                let response = try await Self.slotAction(port: port, action: "save", filename: filename)
                let saved = (response["n_saved"] as? NSNumber)?.intValue ?? 0
                let written = (response["n_written"] as? NSNumber)?.int64Value ?? 0
                guard saved > 0, written > 0 else {
                    throw NSError(domain: "OverfitSlotCache", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "save returned n_saved=\(saved) n_written=\(written)",
                    ])
                }
                await logger.log("[OverfitSlotCache] saved n_tokens=\(saved) bytes=\(written) file=\(filename)")
                if let directory = try? Self.cacheDirectoryCreatingIfNeeded() {
                    Self.pruneLRU(directory: directory, protecting: filename)
                }
            } catch {
                finishFailedSave(filename: filename, port: port, generation: generation)
                await logger.log("[OverfitSlotCache] save failed: \(error.localizedDescription)")
                return
            }

            let shouldRepeat = finishSuccessfulSave(
                filename: filename, port: port, generation: generation)
            if !shouldRepeat { return }
        }
    }

    // MARK: - Storage

    static func cacheDirectoryCreatingIfNeeded() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("OverfitSlotCache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func packageFingerprint(packageDirectory: URL) throws -> String {
        // Decode only the manifest's fingerprint field: the full manifest
        // (per-expert records) is bulky and already validated at load time.
        struct FingerprintOnly: Decodable { let fingerprint: String }
        let manifestURL = packageDirectory
            .appendingPathComponent(NoemaPagedPackageManifest.manifestFileName)
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(FingerprintOnly.self, from: data).fingerprint
    }

    private static func cacheIdentity(
        packageFingerprint: String,
        configuration: LlamaServerBridge.StartConfiguration,
        systemPromptText: String
    ) -> String {
        let templateIdentity: String = {
            guard let path = configuration.chatTemplateFile, !path.isEmpty else { return "none" }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return PagedSHA256.hexDigest(of: data)
            }
            return "unreadable:\(URL(fileURLWithPath: path).lastPathComponent)"
        }()
        let draftIdentity: String = {
            guard let path = configuration.mtpPath, !path.isEmpty else { return "none" }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(URL(fileURLWithPath: path).standardized.path)|\(size)|\(modified)"
        }()
        func optional<T>(_ value: T?) -> String { value.map(String.init(describing:)) ?? "nil" }

        let components = [
            "identity-version=\(identityVersion)",
            "native-contract=\(OverfitEnvironmentIdentity.nativeContractVersion)",
            "package=\(packageFingerprint)",
            "system=\(systemPromptText)",
            "template=\(templateIdentity)",
            "jinja=\(configuration.useJinja)",
            "reasoning=\(optional(configuration.reasoningBudget))",
            "context=\(configuration.contextSize)",
            "context-shift=\(configuration.contextShift)",
            "kv-offload=\(configuration.kvOffload)",
            "kv-unified=\(configuration.unifiedKVCache)",
            "flash-attention=\(configuration.flashAttention)",
            "cache-k=\(configuration.cacheTypeK)",
            "cache-v=\(configuration.cacheTypeV)",
            "parallel=\(configuration.parallelSlots)",
            "gpu-layers=\(configuration.gpuLayers)",
            "tensor-override=\(optional(configuration.tensorOverride))",
            "yarn-scale=\(optional(configuration.yarnScale))",
            "yarn-original=\(optional(configuration.yarnOriginalContext))",
            "yarn-beta-fast=\(optional(configuration.yarnBetaFast))",
            "yarn-beta-slow=\(optional(configuration.yarnBetaSlow))",
            "ctx-checkpoints=\(configuration.ctxCheckpoints)",
            "spec-type=\(optional(configuration.speculativeType))",
            "spec-draft=\(draftIdentity)",
            "spec-max=\(optional(configuration.specDraftNMax))",
            "spec-min=\(optional(configuration.specDraftNMin))",
            "spec-pmin=\(optional(configuration.specDraftPMin))",
            "spec-dynamic=\(configuration.specDynamic)",
            "paged-mode=\(configuration.pagedMode.rawValue)",
        ]
        // Length-prefix each value so even user-controlled prompt text cannot
        // create an ambiguous concatenation.
        return components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func checkpointURL(for slotURL: URL) -> URL {
        slotURL.appendingPathExtension(checkpointFileExtension)
    }

    private static func removeCacheEntry(filename: String, directory: URL) {
        let slotURL = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: slotURL)
        try? FileManager.default.removeItem(at: checkpointURL(for: slotURL))
    }

    /// Deletes least-recently-touched slot + checkpoint pairs until the
    /// directory total is at or below maxTotalBytes. The active session's
    /// pair is never deleted.
    static func pruneLRU(directory: URL, protecting protectedFilename: String?) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let slotNames = Set(entries.filter { $0.pathExtension == fileExtension }
            .map(\.lastPathComponent))
        // A crash can leave a native temporary or an orphaned checkpoint.
        // Neither is independently restorable, so do not let it evade LRU
        // accounting forever.
        for url in entries {
            let name = url.lastPathComponent
            if name.hasSuffix(".\(checkpointFileExtension).tmp") ||
                (name.hasSuffix(".\(checkpointFileExtension)") &&
                 !slotNames.contains(String(name.dropLast(checkpointFileExtension.count + 1)))) {
                try? fm.removeItem(at: url)
            }
        }

        var files: [(url: URL, checkpointURL: URL, size: Int64, modified: Date)] = []
        for url in entries where url.pathExtension == fileExtension {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let checkpoint = checkpointURL(for: url)
            let checkpointValues = try? checkpoint.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            files.append((
                url: url,
                checkpointURL: checkpoint,
                size: Int64(values?.fileSize ?? 0) + Int64(checkpointValues?.fileSize ?? 0),
                modified: max(
                    values?.contentModificationDate ?? .distantPast,
                    checkpointValues?.contentModificationDate ?? .distantPast
                )
            ))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxTotalBytes else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            if total <= maxTotalBytes { break }
            if let protectedFilename, file.url.lastPathComponent == protectedFilename { continue }
            try? fm.removeItem(at: file.url)
            try? fm.removeItem(at: file.checkpointURL)
            total -= file.size
        }
    }

    // MARK: - HTTP (same lightweight loopback style as the canary service)

    private static func slotAction(
        port: Int32, action: String, filename: String
    ) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/slots/0?action=\(action)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Multi-GiB state files stream from/to disk; generous but bounded.
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: ["filename": filename])
        let session = makeLoopbackSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw NSError(domain: "OverfitSlotCache", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "slot \(action) HTTP \(status): \(String(data: data, encoding: .utf8) ?? "<binary>")",
            ])
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func makeLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        return session
    }
}
