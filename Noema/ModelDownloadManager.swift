// ModelDownloadManager.swift
import Foundation
import CryptoKit

enum DownloadEvent {
    case started(Int64?)
    case progress(Double, Int64, Int64, Double)
    case verifying
    case finished(InstalledModel)
    case failed(Error)
    case cancelled
    case paused(Double)
    case networkError(Error, Double) // Network error with current progress
}

// MARK: - Safetensors Validation Helpers

/// Checks if a file is a Git LFS pointer instead of actual content.
/// LFS pointers are small text files starting with "version https://git-lfs.github.com/spec/v1"
func isGitLFSPointer(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }

    // LFS pointers are typically <200 bytes
    guard let data = try? handle.read(upToCount: 200) else { return false }
    guard let text = String(data: data, encoding: .utf8) else { return false }

    return text.hasPrefix("version https://git-lfs.github.com/spec/v1")
}

/// Validates that a safetensors file has a valid header.
/// Safetensors format: first 8 bytes are header length (u64 little endian), followed by JSON header.
/// Returns true if valid, false if corrupted/incomplete.
func isValidSafetensorsFile(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }

    // Read first 8 bytes for header length
    guard let headerLengthData = try? handle.read(upToCount: 8), headerLengthData.count == 8 else {
        return false
    }

    // Parse as little-endian u64
    let headerLength = headerLengthData.withUnsafeBytes { $0.load(as: UInt64.self) }

    // Sanity check: header should be reasonable size (< 100MB)
    if headerLength > 100_000_000 {
        return false
    }

    // Try to read and parse the JSON header
    guard let headerData = try? handle.read(upToCount: Int(headerLength)) else {
        return false
    }

    // Verify it's valid JSON
    guard let _ = try? JSONSerialization.jsonObject(with: headerData) else {
        return false
    }

    return true
}

/// Returns the file size in bytes, or nil if file doesn't exist
func fileSize(at url: URL) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int64 else {
        return nil
    }
    return size
}

private actor MultipartDownloadProgressTracker {
    private let totalExpected: Int64
    private let minSampleInterval: TimeInterval = 0.4
    private var bytesByArtifact: [String: Int64] = [:]
    private var speedByArtifact: [String: Double] = [:]
    private var lastSampleTimeByArtifact: [String: Date] = [:]
    private var lastSampleBytesByArtifact: [String: Int64] = [:]

    init(totalExpected: Int64) {
        self.totalExpected = totalExpected
    }

    func updateBytes(_ written: Int64, for artifactID: String) -> (Double, Int64, Int64, Double) {
        let clampedWritten = max(bytesByArtifact[artifactID] ?? 0, written)
        bytesByArtifact[artifactID] = clampedWritten

        let now = Date()
        if let t0 = lastSampleTimeByArtifact[artifactID],
           let b0 = lastSampleBytesByArtifact[artifactID] {
            let dt = now.timeIntervalSince(t0)
            if dt >= minSampleInterval {
                let delta = max(0, clampedWritten - b0)
                speedByArtifact[artifactID] = dt > 0 ? Double(delta) / dt : 0
                lastSampleTimeByArtifact[artifactID] = now
                lastSampleBytesByArtifact[artifactID] = clampedWritten
            }
        } else {
            lastSampleTimeByArtifact[artifactID] = now
            lastSampleBytesByArtifact[artifactID] = clampedWritten
            speedByArtifact[artifactID] = 0
        }

        return snapshot()
    }

    func markCompleted(_ bytes: Int64, for artifactID: String) -> (Double, Int64, Int64, Double) {
        let clampedBytes = max(bytesByArtifact[artifactID] ?? 0, bytes)
        bytesByArtifact[artifactID] = clampedBytes
        speedByArtifact[artifactID] = 0
        lastSampleTimeByArtifact[artifactID] = Date()
        lastSampleBytesByArtifact[artifactID] = clampedBytes
        return snapshot()
    }

    private func snapshot() -> (Double, Int64, Int64, Double) {
        let totalWritten = max(0, bytesByArtifact.values.reduce(0, +))
        let fraction = min(max(Double(totalWritten) / Double(max(totalExpected, 1)), 0), 1)
        let totalSpeed = speedByArtifact.values.reduce(0, +)
        return (fraction, totalWritten, totalExpected, totalSpeed)
    }
}

actor ModelDownloadManager {
    nonisolated static let multipartDownloadConcurrencyLimit = 4
    typealias RepositoryFileFetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    nonisolated(unsafe) static var repositoryFileFetcherOverride: RepositoryFileFetcher?

    nonisolated static func canonicalProgressSnapshot(written: Int64,
                                                       reportedExpected: Int64,
                                                       fallbackExpected: Int64) -> (downloadedBytes: Int64, expectedBytes: Int64?, progress: Double) {
        let downloadedBytes = max(0, written)
        let expected = max(reportedExpected, fallbackExpected, downloadedBytes)
        let expectedBytes = expected > 0 ? expected : nil
        let progress = expected > 0 ? min(1, max(0, Double(downloadedBytes) / Double(expected))) : 0
        return (downloadedBytes, expectedBytes, progress)
    }

    private var active: [String: Task<Void, Never>] = [:]
    private var dataTasks: [String: URLSessionDataTask] = [:]
    // Track all temp destinations for an active model so pause/cancel can fan out across multipart jobs.
    private var tmpByKey: [String: Set<URL>] = [:]
    private var verbose: Bool { UserDefaults.standard.bool(forKey: "verboseLogging") }

    nonisolated static func runBoundedConcurrency<T: Sendable>(
        limit: Int,
        count: Int,
        operation: @escaping @Sendable (Int) async throws -> T
    ) async throws -> [T] {
        guard count > 0 else { return [] }
        let boundedLimit = Swift.max(1, limit)

        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var nextIndex = 0
            let initialCount = Swift.min(count, boundedLimit)
            for _ in 0..<initialCount {
                let currentIndex = nextIndex
                nextIndex += 1
                group.addTask {
                    (currentIndex, try await operation(currentIndex))
                }
            }

            var results = Array<T?>(repeating: nil, count: count)
            while let (index, value) = try await group.next() {
                results[index] = value
                if nextIndex < count {
                    let currentIndex = nextIndex
                    nextIndex += 1
                    group.addTask {
                        (currentIndex, try await operation(currentIndex))
                    }
                }
            }

            return results.enumerated().map { offset, element in
                guard let element else {
                    fatalError("Missing bounded concurrency result at index \(offset)")
                }
                return element
            }
        }
    }

    private func registerDataTask(_ task: URLSessionDataTask, for key: String) {
        dataTasks[key] = task
    }

    private func clearDataTask(for key: String, cancel: Bool = false) {
        if cancel { dataTasks[key]?.cancel() }
        dataTasks[key] = nil
    }

    private func setTempDestinations(_ destinations: Set<URL>, for key: String) {
        if destinations.isEmpty {
            tmpByKey[key] = nil
        } else {
            tmpByKey[key] = destinations
        }
    }

    private func clearTempDestinations(for key: String) {
        tmpByKey[key] = nil
    }

    private func tempDestinations(for key: String) -> [URL] {
        Array(tmpByKey[key] ?? [])
    }

    private func stagedDestinations(for quant: QuantInfo, in dir: URL) -> Set<URL> {
        Set(quant.allRelativeDownloadPaths.map { relativePath in
            dir.appendingPathComponent(relativePath + ".download")
        })
    }

    // MARK: - Public controls
    func pause(modelID: String, quantLabel: String) async {
        let key = "\(modelID)-\(quantLabel)"
        let destinations = tempDestinations(for: key)
        // Prefer pausing the background task so resume data is preserved.
        if !destinations.isEmpty {
            for destination in destinations {
                await BackgroundDownloadManager.shared.pause(destination: destination)
            }
        } else {
            // Legacy: cancel any foreground data task
            clearDataTask(for: key, cancel: true)
        }
    }

    nonisolated private func isValidGGUFMagic(at url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let magic = try? fh.read(upToCount: 4)
        return magic == Data("GGUF".utf8)
    }

    nonisolated private func sha256Hex(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? fh.read(upToCount: 1_048_576) ?? Data()
            if let c = chunk, !c.isEmpty {
                hasher.update(data: c)
                return true
            }
            return false
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func sha256Matches(fileURL: URL, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let computed = sha256Hex(of: fileURL) else { return false }
        return computed.lowercased() == expected.lowercased()
    }

    nonisolated private func updateWeightsArtifacts(in dir: URL, weights: String, weightShards: [String]? = nil) {
        do {
            let artifactsURL = dir.appendingPathComponent("artifacts.json")
            var obj: [String: Any] = [:]
            if let data = try? Data(contentsOf: artifactsURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj = parsed
            }
            obj["weights"] = weights
            if let weightShards, !weightShards.isEmpty {
                obj["weightShards"] = weightShards
            } else {
                obj.removeValue(forKey: "weightShards")
            }
            if obj["mmproj"] == nil { obj["mmproj"] = NSNull() }
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            try? out.write(to: artifactsURL)
        } catch {}
    }

    nonisolated private func relativePath(for part: QuantInfo.DownloadPart) -> String {
        QuantInfo.relativeDownloadPath(path: part.path, fallbackURL: part.downloadURL)
    }

    nonisolated private func primaryRelativePath(for quant: QuantInfo) -> String {
        quant.primaryDownloadRelativePath
    }

    nonisolated private func shardArtifactID(for relativePath: String) -> String {
        "shard:\(relativePath)"
    }

    nonisolated private func ensureParentDirectory(for fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    nonisolated private func scheduleCoreMLPrecompileIfNeeded(root: URL) {
#if canImport(CoreML) && (os(iOS) || os(visionOS))
        guard #available(iOS 18.0, visionOS 2.0, *) else { return }
        if InstalledModelsStore.firstANEArtifact(in: root)?.pathExtension.lowercased() == "mlmodelc" {
            return
        }
        Task.detached(priority: .utility) {
            _ = try? ANEModelResolver.precompilePreferredArtifact(in: root)
        }
#endif
    }

    nonisolated private func verifyANEMLLInstallIfNeeded(root: URL, modelID: String, sourceRepoID: String? = nil) throws {
#if canImport(CoreML) && (os(iOS) || os(visionOS))
        guard #available(iOS 18.0, visionOS 2.0, *) else { return }
        // Curated entries keep their catalog id (e.g. an unsloth GGUF repo) while the
        // CoreML artifacts come from an anemll repo, so check the source repo too.
        let isANEMLL = modelID.lowercased().hasPrefix("anemll/")
            || (sourceRepoID?.lowercased().hasPrefix("anemll/") ?? false)
        guard isANEMLL else { return }
        let metaURL = root.appendingPathComponent("meta.yaml")
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return }
        _ = try ANEModelResolver.validateDownloadedANEMLLInstall(in: root)
#endif
    }

    private func downloadMultipartGGUF(
        quant: QuantInfo,
        key: String,
        jobID: String?,
        dir: URL,
        continuation: AsyncStream<DownloadEvent>.Continuation
    ) async throws -> (final: URL, installedSizeBytes: Int64) {
        let parts = quant.allDownloadParts
        guard parts.count > 1 else {
            throw URLError(.badURL)
        }

        let totalExpected = max(1, max(quant.sizeBytes, parts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }))
        let progressState = MultipartDownloadProgressTracker(totalExpected: totalExpected)
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await Self.runBoundedConcurrency(
                limit: Self.multipartDownloadConcurrencyLimit,
                count: parts.count
            ) { index in
                let part = parts[index]
                let shardPath = self.relativePath(for: part)
                let artifactID = self.shardArtifactID(for: shardPath)
                let finalURL = dir.appendingPathComponent(shardPath)
                let tmpURL = dir.appendingPathComponent(shardPath + ".download")
                let fm = FileManager.default

                self.ensureParentDirectory(for: finalURL)

                if fm.fileExists(atPath: finalURL.path) {
                    if self.isValidGGUFMagic(at: finalURL), self.sha256Matches(fileURL: finalURL, expected: part.sha256) {
                        let existingSize = fileSize(at: finalURL) ?? max(part.sizeBytes, 0)
                        await DownloadEngine.shared.markArtifactCompleted(
                            externalID: key,
                            artifactID: artifactID,
                            finalBytes: existingSize
                        )
                        let snap = await progressState.markCompleted(existingSize, for: artifactID)
                        continuation.yield(.progress(snap.0, snap.1, snap.2, snap.3))
                        return existingSize
                    }
                    try? fm.removeItem(at: finalURL)
                }

                await DownloadEngine.shared.updateArtifactState(
                    externalID: key,
                    artifactID: artifactID,
                    state: .downloading,
                    manualPause: false
                )

                var request = URLRequest(url: part.downloadURL)
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                request.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
                if let token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                _ = try await BackgroundDownloadManager.shared.download(
                    request: request,
                    to: tmpURL,
                    jobID: jobID,
                    artifactID: artifactID,
                    expectedSize: part.sizeBytes > 0 ? part.sizeBytes : nil,
                    progress: nil,
                    progressBytes: { written, _ in
                        Task {
                            await DownloadEngine.shared.updateArtifactProgressLive(
                                externalID: key,
                                artifactID: artifactID,
                                written: written,
                                expected: part.sizeBytes > 0 ? part.sizeBytes : nil
                            )
                            let snap = await progressState.updateBytes(written, for: artifactID)
                            continuation.yield(.progress(snap.0, snap.1, snap.2, snap.3))
                        }
                    }
                )

                guard self.isValidGGUFMagic(at: tmpURL) else {
                    throw URLError(.cannotParseResponse)
                }
                guard self.sha256Matches(fileURL: tmpURL, expected: part.sha256) else {
                    throw URLError(.cannotParseResponse)
                }

                try? fm.removeItem(at: finalURL)
                try fm.moveItem(at: tmpURL, to: finalURL)

                let finalSize = fileSize(at: finalURL) ?? max(part.sizeBytes, 0)
                await DownloadEngine.shared.markArtifactCompleted(
                    externalID: key,
                    artifactID: artifactID,
                    finalBytes: finalSize
                )
                let snap = await progressState.markCompleted(finalSize, for: artifactID)
                continuation.yield(.progress(snap.0, snap.1, snap.2, snap.3))
                return finalSize
            }
        } catch {
            let destinations = tempDestinations(for: key)
            if !destinations.isEmpty {
                Task { @MainActor in
                    for destination in destinations {
                        BackgroundDownloadManager.shared.cancel(destination: destination)
                    }
                }
            }
            throw error
        }

        await DownloadEngine.shared.updateJobState(externalID: key, state: .verifying, manualPause: false)
        continuation.yield(.verifying)

        let shardNames = parts.map { relativePath(for: $0) }
        let primaryName = primaryRelativePath(for: quant)
        let primaryURL = dir.appendingPathComponent(primaryName)
        updateWeightsArtifacts(in: dir, weights: primaryName, weightShards: shardNames)

        let onDiskTotal = shardNames.reduce(into: Int64(0)) { sum, name in
            let url = dir.appendingPathComponent(name)
            sum += fileSize(at: url) ?? 0
        }

        return (primaryURL, onDiskTotal > 0 ? onDiskTotal : quant.sizeBytes)
    }

    private func downloadMultipartAssets(
        quant: QuantInfo,
        key: String,
        jobID: String?,
        dir: URL,
        continuation: AsyncStream<DownloadEvent>.Continuation
    ) async throws -> (final: URL, installedSizeBytes: Int64) {
        let parts = quant.allDownloadParts
        guard !parts.isEmpty else {
            throw URLError(.badURL)
        }

        let totalExpected = max(1, max(quant.sizeBytes, parts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }))
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let progressState = MultipartDownloadProgressTracker(totalExpected: totalExpected)

        do {
            _ = try await Self.runBoundedConcurrency(
                limit: Self.multipartDownloadConcurrencyLimit,
                count: parts.count
            ) { index in
                let part = parts[index]
                let relative = self.relativePath(for: part)
                let artifactID = self.shardArtifactID(for: relative)
                let finalURL = dir.appendingPathComponent(relative)
                let tmpURL = dir.appendingPathComponent(relative + ".download")
                let fm = FileManager.default

                self.ensureParentDirectory(for: finalURL)

                if fm.fileExists(atPath: finalURL.path), self.sha256Matches(fileURL: finalURL, expected: part.sha256) {
                    let existingSize = fileSize(at: finalURL) ?? max(part.sizeBytes, 0)
                    let sizeMatches = part.sizeBytes <= 0 || existingSize == part.sizeBytes
                    if sizeMatches {
                        await DownloadEngine.shared.markArtifactCompleted(
                            externalID: key,
                            artifactID: artifactID,
                            finalBytes: existingSize
                        )
                        let snap = await progressState.markCompleted(existingSize, for: artifactID)
                        continuation.yield(.progress(snap.0, snap.1, snap.2, snap.3))
                        return existingSize
                    }
                }
                try? fm.removeItem(at: finalURL)

                await DownloadEngine.shared.updateArtifactState(
                    externalID: key,
                    artifactID: artifactID,
                    state: .downloading,
                    manualPause: false
                )

                var request = URLRequest(url: part.downloadURL)
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                request.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
                if let token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                _ = try await BackgroundDownloadManager.shared.download(
                    request: request,
                    to: tmpURL,
                    jobID: jobID,
                    artifactID: artifactID,
                    expectedSize: part.sizeBytes > 0 ? part.sizeBytes : nil,
                    progress: nil,
                    progressBytes: { written, _ in
                        Task {
                            await DownloadEngine.shared.updateArtifactProgressLive(
                                externalID: key,
                                artifactID: artifactID,
                                written: written,
                                expected: part.sizeBytes > 0 ? part.sizeBytes : nil
                            )
                            let snap = await progressState.updateBytes(written, for: artifactID)
                            continuation.yield(.progress(snap.0, snap.1, snap.2, snap.3))
                        }
                    }
                )

                guard self.sha256Matches(fileURL: tmpURL, expected: part.sha256) else {
                    throw URLError(.cannotParseResponse)
                }

                try? fm.removeItem(at: finalURL)
                try fm.moveItem(at: tmpURL, to: finalURL)

                let finalSize = fileSize(at: finalURL) ?? max(part.sizeBytes, 0)
                await DownloadEngine.shared.markArtifactCompleted(
                    externalID: key,
                    artifactID: artifactID,
                    finalBytes: finalSize
                )
                let snap = await progressState.markCompleted(finalSize, for: artifactID)
                continuation.yield(.progress(snap.0, snap.1, snap.2, snap.3))
                return finalSize
            }
        } catch {
            let destinations = tempDestinations(for: key)
            if !destinations.isEmpty {
                Task { @MainActor in
                    for destination in destinations {
                        BackgroundDownloadManager.shared.cancel(destination: destination)
                    }
                }
            }
            throw error
        }

        await DownloadEngine.shared.updateJobState(externalID: key, state: .verifying, manualPause: false)
        continuation.yield(.verifying)

        let shardNames = parts.map { relativePath(for: $0) }
        let primaryName = primaryRelativePath(for: quant)
        let primaryURL = dir.appendingPathComponent(primaryName)
        updateWeightsArtifacts(in: dir, weights: primaryName, weightShards: shardNames)

        let onDiskTotal = shardNames.reduce(into: Int64(0)) { sum, relPath in
            let fileURL = dir.appendingPathComponent(relPath)
            sum += fileSize(at: fileURL) ?? 0
        }

        return (primaryURL, onDiskTotal > 0 ? onDiskTotal : quant.sizeBytes)
    }

    /// Curated catalog entries can carry a CoreML or Core AI quant whose URL is just the
    /// Hugging Face repo root (no file parts) — that happens when the catalog's own repo
    /// resolution was skipped or failed at browse time. A repo root is not downloadable,
    /// so resolve the real artifact list (model containers + tokenizer sidecars) the same
    /// way Explore search does. A label match picks the intended variant when the repo
    /// publishes several bundles. Returns the original quant when no resolution is needed
    /// or possible.
    func resolveANEQuantIfNeeded(_ quant: QuantInfo, modelID: String) async -> QuantInfo {
        guard quant.format == .ane || quant.format == .coreai,
              quant.downloadParts?.isEmpty ?? true else { return quant }
        let repoID = huggingFaceRepoID(from: quant.downloadURL) ?? modelID
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let registry = HuggingFaceRegistry(token: (token?.isEmpty == false) ? token : nil)
        guard let details = try? await registry.details(for: repoID) else { return quant }
        let candidates = details.quants.filter { $0.format == quant.format && !($0.downloadParts?.isEmpty ?? true) }
        guard let resolved = candidates.first(where: { $0.label.caseInsensitiveCompare(quant.label) == .orderedSame }) ?? candidates.first else {
            return quant
        }
        return quant.copying(
            sizeBytes: resolved.sizeBytes,
            downloadURL: resolved.downloadURL,
            sha256: resolved.sha256,
            configURL: resolved.configURL ?? quant.configURL,
            downloadParts: resolved.downloadParts
        )
    }

    private func isHuggingFaceRepoRootURL(_ url: URL) -> Bool {
        guard huggingFaceRepoID(from: url) != nil else { return false }
        return url.path.split(separator: "/").filter { !$0.isEmpty }.count <= 2
    }

    func download(_ quant: QuantInfo, for modelID: String, jobID: String? = nil) -> AsyncStream<DownloadEvent> {
        AsyncStream { continuation in
            let key = "\(modelID)-\(quant.label)"
            if let existing = active[key] {
                existing.cancel()
            }

            let task = Task {
                let quant = await self.resolveANEQuantIfNeeded(quant, modelID: modelID)
                let dir = InstalledModelsStore.baseDir(for: quant.format, modelID: modelID)
                let authToken = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	                // Persist the canonical repo id for later recovery of assets
	                let repoFile = dir.appendingPathComponent("repo.txt")
	                try? modelID.data(using: .utf8)?.write(to: repoFile)
                    if let sourceRepoID = huggingFaceRepoID(from: quant.downloadURL) {
                        ETModelResolver.writeSourceRepoID(sourceRepoID, into: dir)
                    }
	                self.setTempDestinations(self.stagedDestinations(for: quant, in: dir), for: key)
                let primaryRelativePath = primaryRelativePath(for: quant)
                let tmp = dir.appendingPathComponent(primaryRelativePath + ".download")
                ensureParentDirectory(for: tmp)

                let announcedExpected: Int64 = {
                    if quant.isMultipart {
                        let summed = quant.allDownloadParts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }
                        return max(quant.sizeBytes, summed)
                    }
                    return quant.sizeBytes
                }()
                continuation.yield(.started(announcedExpected))

                // Track progress via an actor to satisfy Sendable rules for the progress handler
                // Throttle instantaneous speed calculation to avoid unrealistically large spikes
                // from very small time deltas between delegate callbacks.
                actor ProgressState {
                    // Always track last observed bytes so snapshot() can report progress immediately
                    private var lastBytes: Int64 = 0
                    private(set) var latestSpeed: Double = 0
                    private let expected: Int64

                    // Throttled speed sampling state
                    private var lastSpeedSampleTime: Date? = nil
                    private var lastSpeedSampleBytes: Int64? = nil
                    private let minSampleInterval: TimeInterval = 0.5

                    init(expected: Int64) { self.expected = expected }

                    // Update with the absolute total bytes written so far.
                    // Returns the latest throttled instantaneous speed (bytes/sec).
                    func updateBytes(_ written: Int64) -> Double {
                        lastBytes = written
                        let now = Date()
                        guard let t0 = lastSpeedSampleTime, let b0 = lastSpeedSampleBytes else {
                            lastSpeedSampleTime = now
                            lastSpeedSampleBytes = written
                            latestSpeed = 0
                            return latestSpeed
                        }
                        let dt = now.timeIntervalSince(t0)
                        // Only refresh speed when enough time has elapsed to get a stable estimate
                        guard dt >= minSampleInterval else { return latestSpeed }
                        let bytesDelta = written - b0
                        let speed = dt > 0 ? Double(bytesDelta) / dt : 0
                        latestSpeed = max(0, speed)
                        lastSpeedSampleTime = now
                        lastSpeedSampleBytes = written
                        return latestSpeed
                    }
                    func estimatedBytes(forProgress p: Double) -> Int64 {
                        if expected > 0 { return Int64(Double(expected) * p) }
                        return lastBytes
                    }
                    func snapshotSpeed() -> Double { latestSpeed }
                    func snapshot() -> Double {
                        guard expected > 0 else { return 0 }
                        return Double(lastBytes) / Double(expected)
                    }
                }
                // Background download → tmp path. We compute speeds locally using expected size.
                let expected = quant.sizeBytes
                let progressState = ProgressState(expected: expected)
                // Track the best-known expected total in a tiny actor to satisfy @Sendable rules
                actor ExpectedState {
                    private let initial: Int64
                    private var runtime: Int64
                    init(initial: Int64) { self.initial = initial; self.runtime = initial }
                    func update(_ v: Int64) { if v > 0 { runtime = v } }
                    func total() -> Int64 { return runtime > 0 ? runtime : initial }
                }
                let expectedState = ExpectedState(initial: expected)
                // Track actual bytes written as reported by URLSession delegate to avoid deriving
                // from fraction (which can be throttled/rounded by the OS)
                actor TransferState {
                    private var written: Int64 = 0
                    private var expected: Int64 = -1
                    func update(w: Int64, e: Int64) { written = w; if e > 0 { expected = e } }
                    func snapshot() -> (Int64, Int64) { (written, expected) }
                }
                let transferState = TransferState()
                var final = dir.appendingPathComponent(primaryRelativePath)
                var installedSizeBytes = quant.sizeBytes
                var currentArtifactID: String? = quant.isMultipart ? nil : "main"
                do {
                    // A CoreML or Core AI quant still pointing at a bare repo root could
                    // not be resolved into file parts; downloading it would save an HTML
                    // page as the model. Fail (retryably — resolution is usually blocked
                    // by a transient API error) instead of installing garbage.
                    if quant.format == .ane || quant.format == .coreai,
                       quant.downloadParts?.isEmpty ?? true,
                       self.isHuggingFaceRepoRootURL(quant.downloadURL) {
                        throw URLError(.badServerResponse)
                    }
                    // Local-catalog CoreAI entries use a `coreai://` sentinel URL —
                    // they're export recipes, not downloadable artifacts.
                    if quant.format == .coreai, quant.downloadURL.scheme?.lowercased() == "coreai" {
                        throw URLError(.unsupportedURL)
                    }
                    if quant.isMultipart {
                        if verbose { print("DOWNLOAD_START \(Date().timeIntervalSince1970)") }
                        let multipart: (final: URL, installedSizeBytes: Int64)
                        if quant.format == .gguf {
                            multipart = try await self.downloadMultipartGGUF(
                                quant: quant,
                                key: key,
                                jobID: jobID,
                                dir: dir,
                                continuation: continuation
                            )
                        } else {
                            multipart = try await self.downloadMultipartAssets(
                                quant: quant,
                                key: key,
                                jobID: jobID,
                                dir: dir,
                                continuation: continuation
                            )
                        }
                        if verbose { print("DOWNLOAD_END \(Date().timeIntervalSince1970)") }
                        final = multipart.final
                        installedSizeBytes = multipart.installedSizeBytes
                    } else {
                    var req = URLRequest(url: quant.downloadURL)
                    req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
                    if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    await DownloadEngine.shared.updateArtifactState(
                        externalID: key,
                        artifactID: "main",
                        state: .downloading,
                        manualPause: false
                    )
                    if verbose { print("DOWNLOAD_START \(Date().timeIntervalSince1970)") }
                    let progressHandler: @Sendable (Double) -> Void = { p in
                        Task {
                            let (w, e) = await transferState.snapshot()
                            let total = (e > 0) ? e : await expectedState.total()
                            let s = await progressState.snapshotSpeed()
                            continuation.yield(.progress(p, w, total, s))
                        }
                    }
                    let _ = try await BackgroundDownloadManager.shared.download(
                        request: req,
                        to: tmp,
                        jobID: jobID,
                        artifactID: "main",
                        expectedSize: expected,
                        progress: progressHandler,
                        progressBytes: { written, reportedExpected in
                            if reportedExpected > 0 {
                                Task { await expectedState.update(reportedExpected) }
                            }
                            Task { await transferState.update(w: written, e: reportedExpected) }
                            Task {
                                await DownloadEngine.shared.updateArtifactProgressLive(
                                    externalID: key,
                                    artifactID: "main",
                                    written: written,
                                    expected: reportedExpected > 0 ? reportedExpected : expected
                                )
                                _ = await progressState.updateBytes(written)
                            }
                        })
                    if verbose { print("DOWNLOAD_END \(Date().timeIntervalSince1970)") }

                    let total = await expectedState.total()
                    continuation.yield(.progress(1, Int64(total), total, 0))
                    await DownloadEngine.shared.updateJobState(externalID: key, state: .verifying, manualPause: false)
                    continuation.yield(.verifying)

                    // Validate GGUF magic to avoid saving HTML or Git LFS pointers as model files
                    if quant.format == .gguf {
                        do {
                            // If the server served HTML (e.g., rate limit page), bail out
                            // Basic sniff: ensure file begins with GGUF magic
                            let readHandle = try FileHandle(forReadingFrom: tmp)
                            defer { try? readHandle.close() }
                            let magic = try readHandle.read(upToCount: 4) ?? Data()
                            if magic != Data("GGUF".utf8) {
                                throw URLError(.cannotParseResponse)
                            }
                        } catch {
                            throw URLError(.cannotParseResponse)
                        }
                    }

                    if let sha = quant.sha256 {
                        // Compute sha256 over the completed tmp file
                        if let fh = try? FileHandle(forReadingFrom: tmp) {
                            var hasher = SHA256()
                            while autoreleasepool(invoking: {
                                let chunk = try? fh.read(upToCount: 1_048_576) ?? Data()
                                if let c = chunk, !c.isEmpty { hasher.update(data: c); return true }
                                return false
                            }) {}
                            try? fh.close()
                            let computed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                            if computed.lowercased() != sha.lowercased() { throw URLError(.cannotParseResponse) }
                        }
                    }

                    final = dir.appendingPathComponent(primaryRelativePath)
                    ensureParentDirectory(for: final)
                    try? FileManager.default.removeItem(at: final)
                    try FileManager.default.moveItem(at: tmp, to: final)
                    installedSizeBytes = fileSize(at: final) ?? quant.sizeBytes
                    await DownloadEngine.shared.markArtifactCompleted(
                        externalID: key,
                        artifactID: "main",
                        finalBytes: installedSizeBytes
                    )
                    // Persist artifact pointers for later recovery
                    updateWeightsArtifacts(in: dir, weights: primaryRelativePath)
                    }
                    await DownloadEngine.shared.updateJobState(externalID: key, state: .finalizing, manualPause: false)
                    // Fetch and cache hub metadata (pipeline_tag, gguf.chat_template, etc.)
                    if let meta = await HuggingFaceMetadataCache.fetchAndCache(repoId: modelID, token: UserDefaults.standard.string(forKey: "huggingFaceToken")) {
                        HuggingFaceMetadataCache.saveToModelDir(meta: meta, modelID: modelID, format: quant.format)
                    }
                    if let cfgURL = quant.configURL {
                        do {
                            var req = URLRequest(url: cfgURL)
                            req.setValue("application/json", forHTTPHeaderField: "Accept")
                            if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                            }
                            if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                            NetworkKillSwitch.track(session: URLSession.shared)
                            let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                                // Basic JSON validation to avoid saving HTML error pages
                                if (try? JSONSerialization.jsonObject(with: data)) != nil {
                                    let dest = dir.appendingPathComponent("config.json")
                                    do {
                                        try data.write(to: dest)
                                        await self.markDownloadedModelSidecar(externalID: key, relativePath: "config.json", finalURL: dest, remoteURL: cfgURL, finalBytes: Int64(data.count))
                                    } catch {
                                        // ignore config download failures
                                    }
                                }
                            }
                    } catch {
                        // ignore config download failures
                    }
                }

                    // Best-effort: fetch repo-provided sampling hints (params/params.json) to seed default settings.
                    do {
                        let repoID = huggingFaceRepoID(from: quant.downloadURL) ?? modelID
                        try await downloadParamsFile(repoID: repoID, into: dir, token: authToken, externalID: key)
                    } catch {
                        // optional sidecar; ignore failures
                    }

	                    if quant.format == .et {
	                        let repoID = huggingFaceRepoID(from: quant.downloadURL) ?? modelID
                            ETModelResolver.writeSourceRepoID(repoID, into: dir)
	                        try await downloadETTokenizerArtifacts(repoID: repoID, into: dir, token: authToken, required: true, externalID: key)
                            let artifacts = try ETModelResolver.resolveLoadArtifacts(for: dir)
                            final = artifacts.pteURL
	                    }

                    // CoreML installs need tokenizer assets (and anemll's meta.yaml) next to
                    // the compiled containers. Multipart repo downloads normally include them;
                    // backfill anything missing and fail here — with a clear error — when no
                    // tokenizer could be obtained, instead of surfacing it at load time.
                    if quant.format == .ane {
                        let repoID = huggingFaceRepoID(from: quant.downloadURL) ?? modelID
                        try await downloadANESidecarArtifacts(repoID: repoID, into: dir, token: authToken, externalID: key)
                    }

                    // Core AI installs need a tokenizer near the .aimodel bundle.
                    // Hugging Face variants sometimes publish only the compiled graph;
                    // backfill from the repo (or its referenced source repo) and fail
                    // with a clear error when none can be obtained.
                    if quant.format == .coreai {
                        let repoID = huggingFaceRepoID(from: quant.downloadURL) ?? modelID
                        let variantRoot = InstalledModelsStore.canonicalURL(for: final, format: .coreai)
                        try await downloadCoreAITokenizerArtifacts(repoID: repoID, variantRoot: variantRoot, token: authToken, externalID: key)
                    }

                    // Ensure MLX tokenizer assets exist alongside weights so the client can load.
                    if quant.format == .mlx {
                        // MLX quants may come from a repo different from the modelID (e.g. curated mirrors).
                        // Resolve the actual Hugging Face repo from the quant URL so we fetch tokenizers
                        // and sidecar files from the correct location.
                        let repoID = huggingFaceRepoID(from: quant.downloadURL) ?? modelID
                        let tokenizerDest = dir.appendingPathComponent("tokenizer.json")
                        if !FileManager.default.fileExists(atPath: tokenizerDest.path) {
                            // Prefer resolve endpoint (works with LFS), then fall back to raw
                            do {
                                let resolveURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/tokenizer.json?download=1")!
                                var req = URLRequest(url: resolveURL)
                                req.setValue("application/json", forHTTPHeaderField: "Accept")
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                    try? data.write(to: tokenizerDest)
                                }
                            } catch {
                                // try raw as fallback
                                do {
                                    let rawURL = URL(string: "https://huggingface.co/\(repoID)/raw/main/tokenizer.json")!
                                    var req = URLRequest(url: rawURL)
                                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                                    if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                    }
                                    if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                    NetworkKillSwitch.track(session: URLSession.shared)
                                    let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                    if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                        try? data.write(to: tokenizerDest)
                                    }
                                } catch {
                                    // Some repos may use alternative tokenizers (e.g. tokenizer.model).
                                    // We ignore failures here; the loader will surface any remaining issues.
                                }
                            }
                        }
                        // Fallback: sentencepiece model
                        if !FileManager.default.fileExists(atPath: tokenizerDest.path) {
                            let spmCandidates = ["tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]
                            for name in spmCandidates {
                                let dest = dir.appendingPathComponent(name)
                                if FileManager.default.fileExists(atPath: dest.path) { break }
                                // Try resolve first, then raw
                                do {
                                    let rURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(name)?download=1")!
                                    var req = URLRequest(url: rURL)
                                    req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                                    if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                    }
                                    if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                    NetworkKillSwitch.track(session: URLSession.shared)
                                    let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                    if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                        try? data.write(to: dest)
                                        break
                                    }
                                } catch {}
                                do {
                                    let url = URL(string: "https://huggingface.co/\(repoID)/raw/main/\(name)")!
                                    var req = URLRequest(url: url)
                                    req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                                    if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                    }
                                    if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                    NetworkKillSwitch.track(session: URLSession.shared)
                                    let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                    if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                        try? data.write(to: dest)
                                        break
                                    }
                                } catch {
                                    // try next candidate
                                }
                            }
                        }

                        // Best-effort: fetch common tokenizer side files if present
                        for side in ["tokenizer_config.json", "special_tokens_map.json", "vocab.txt", "merges.txt"] {
                            let dest = dir.appendingPathComponent(side)
                            if FileManager.default.fileExists(atPath: dest.path) { continue }
                            // Prefer resolve first (handles LFS), then raw
                            do {
                                let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(side)?download=1")!
                                var req = URLRequest(url: url)
                                if side.hasSuffix(".json") {
                                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                                } else {
                                    req.setValue("text/plain", forHTTPHeaderField: "Accept")
                                }
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                                    try? data.write(to: dest)
                                    continue
                                }
                            } catch {}
                            do {
                                let url = URL(string: "https://huggingface.co/\(repoID)/raw/main/\(side)")!
                                var req = URLRequest(url: url)
                                if side.hasSuffix(".json") {
                                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                                } else {
                                    req.setValue("text/plain", forHTTPHeaderField: "Accept")
                                }
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                                    try? data.write(to: dest)
                                }
                            } catch {
                                // optional; ignore
                            }
                        }

                        // Best-effort: fetch chat templates (needed by MLX tokenizer/init)
                        // Many HF repos (e.g., Qwen3-VL) ship chat_template.jinja / chat_template.json separately.
                        // If missing locally, MLX will raise "tokenizer does not have a chat template".
                        for tmpl in ["chat_template.json", "chat_template.jinja"] {
                            let dest = dir.appendingPathComponent(tmpl)
                            if FileManager.default.fileExists(atPath: dest.path) { continue }
                            // Prefer resolve (supports LFS), then raw
                            do {
                                let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(tmpl)?download=1")!
                                var req = URLRequest(url: url)
                                if tmpl.hasSuffix(".json") {
                                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                                } else {
                                    req.setValue("text/plain", forHTTPHeaderField: "Accept")
                                }
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                    try? data.write(to: dest)
                                    continue
                                }
                            } catch {}
                            do {
                                let raw = URL(string: "https://huggingface.co/\(repoID)/raw/main/\(tmpl)")!
                                var req = URLRequest(url: raw)
                                if tmpl.hasSuffix(".json") {
                                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                                } else {
                                    req.setValue("text/plain", forHTTPHeaderField: "Accept")
                                }
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                    try? data.write(to: dest)
                                }
                            } catch {
                                // optional; ignore
                            }
                        }

                        // Download safetensors model weights
                        // Strategy: Try single model.safetensors first, then fall back to sharded files
                        let singleSafetensorsDest = dir.appendingPathComponent("model.safetensors")
                        var needsShardedDownload = true

                        // First, try downloading the single model.safetensors file
                        if !FileManager.default.fileExists(atPath: singleSafetensorsDest.path) ||
                           isGitLFSPointer(at: singleSafetensorsDest) ||
                           !isValidSafetensorsFile(at: singleSafetensorsDest) {

                            print("[ModelDownloadManager] Attempting to download single model.safetensors...")
                            do {
                                let singleURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/model.safetensors?download=1")!
                                var sreq = URLRequest(url: singleURL)
                                sreq.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    sreq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }

                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)

                                let (tmpFile, resp) = try await URLSession.shared.download(for: HFEndpoint.rewrite(sreq))

                                if let httpResp = resp as? HTTPURLResponse, (200..<300).contains(httpResp.statusCode) {
                                    // Validate before moving
                                    if isGitLFSPointer(at: tmpFile) {
                                        print("[ModelDownloadManager] Downloaded model.safetensors is LFS pointer - will try sharded")
                                        try? FileManager.default.removeItem(at: tmpFile)
                                    } else if !isValidSafetensorsFile(at: tmpFile) {
                                        let size = fileSize(at: tmpFile) ?? 0
                                        print("[ModelDownloadManager] Downloaded model.safetensors has invalid header (size: \(size)) - will try sharded")
                                        try? FileManager.default.removeItem(at: tmpFile)
                                    } else {
                                        // Valid single file - move to destination
                                        try? FileManager.default.removeItem(at: singleSafetensorsDest) // Remove any invalid existing file
                                        try FileManager.default.moveItem(at: tmpFile, to: singleSafetensorsDest)
                                        let finalSize = fileSize(at: singleSafetensorsDest) ?? 0
                                        print("[ModelDownloadManager] Successfully downloaded model.safetensors (\(finalSize / 1_000_000) MB)")
                                        needsShardedDownload = false
                                    }
                                } else if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 404 {
                                    print("[ModelDownloadManager] model.safetensors not found (404) - will try sharded files")
                                    try? FileManager.default.removeItem(at: tmpFile)
                                } else {
                                    print("[ModelDownloadManager] Failed to download model.safetensors - will try sharded")
                                    try? FileManager.default.removeItem(at: tmpFile)
                                }
                            } catch {
                                print("[ModelDownloadManager] Error downloading model.safetensors: \(error) - will try sharded")
                            }
                        } else {
                            print("[ModelDownloadManager] Valid model.safetensors already exists - skipping download")
                            needsShardedDownload = false
                        }

                        // If single file download failed/not available, try sharded download via index
                        if needsShardedDownload {
                            do {
                                let indexURL = URL(string: "https://huggingface.co/\(repoID)/raw/main/model.safetensors.index.json")!
                                var req = URLRequest(url: indexURL)
                                req.setValue("application/json", forHTTPHeaderField: "Accept")
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                                    // Persist the index file
                                    let idxDest = dir.appendingPathComponent("model.safetensors.index.json")
                                    try? data.write(to: idxDest)

                                    // Parse shard list from weight_map values
                                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       let weightMap = obj["weight_map"] as? [String: String] {
                                        let shardNames = Array(Set(weightMap.values)).sorted()
                                        print("[ModelDownloadManager] Found \(shardNames.count) safetensors shards in index")

                                        var anyShardFailed = false
                                        for name in shardNames {
                                            let shardDest = dir.appendingPathComponent(name)

                                            // Check if file exists and is valid
                                            if FileManager.default.fileExists(atPath: shardDest.path) {
                                                if isGitLFSPointer(at: shardDest) {
                                                    print("[ModelDownloadManager] \(name) is LFS pointer - re-downloading")
                                                    try? FileManager.default.removeItem(at: shardDest)
                                                } else if !isValidSafetensorsFile(at: shardDest) {
                                                    let size = fileSize(at: shardDest) ?? 0
                                                    print("[ModelDownloadManager] \(name) invalid (size: \(size)) - re-downloading")
                                                    try? FileManager.default.removeItem(at: shardDest)
                                                } else {
                                                    print("[ModelDownloadManager] \(name) already valid - skipping")
                                                    continue
                                                }
                                            }

                                            // Download the shard
                                            print("[ModelDownloadManager] Downloading shard: \(name)")
                                            do {
                                                let shardURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(name)?download=1")!
                                                var sreq = URLRequest(url: shardURL)
                                                sreq.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                                    sreq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                                }

                                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                                NetworkKillSwitch.track(session: URLSession.shared)

                                                let (tmpShard, shardResp) = try await URLSession.shared.download(for: HFEndpoint.rewrite(sreq))

                                                if let httpResp = shardResp as? HTTPURLResponse {
                                                    guard (200..<300).contains(httpResp.statusCode) else {
                                                        print("[ModelDownloadManager] Shard \(name): HTTP \(httpResp.statusCode)")
                                                        anyShardFailed = true
                                                        try? FileManager.default.removeItem(at: tmpShard)
                                                        continue
                                                    }
                                                }

                                                // Validate downloaded file
                                                if isGitLFSPointer(at: tmpShard) {
                                                    print("[ModelDownloadManager] ERROR: \(name) is LFS pointer")
                                                    try? FileManager.default.removeItem(at: tmpShard)
                                                    anyShardFailed = true
                                                    continue
                                                }

                                                if !isValidSafetensorsFile(at: tmpShard) {
                                                    let size = fileSize(at: tmpShard) ?? 0
                                                    print("[ModelDownloadManager] ERROR: \(name) invalid header (size: \(size))")
                                                    try? FileManager.default.removeItem(at: tmpShard)
                                                    anyShardFailed = true
                                                    continue
                                                }

                                                try FileManager.default.moveItem(at: tmpShard, to: shardDest)
                                                let finalSize = fileSize(at: shardDest) ?? 0
                                                print("[ModelDownloadManager] Downloaded \(name) (\(finalSize / 1_000_000) MB)")

                                            } catch {
                                                print("[ModelDownloadManager] Failed shard \(name): \(error)")
                                                anyShardFailed = true
                                            }
                                        }

                                        // If any shards failed to download, the index might be stale
                                        // Try the single file as final fallback
                                        if anyShardFailed && !FileManager.default.fileExists(atPath: singleSafetensorsDest.path) {
                                            print("[ModelDownloadManager] Some shards failed - index may be outdated. Model weights may be incomplete.")
                                        }
                                    }
                                }
                            } catch {
                                print("[ModelDownloadManager] No safetensors index or failed to fetch: \(error)")
                            }
                        }

                        // Also fetch the index file if we downloaded a single file (for compatibility)
                        if !needsShardedDownload {
                            let idxDest = dir.appendingPathComponent("model.safetensors.index.json")
                            if !FileManager.default.fileExists(atPath: idxDest.path) {
                                do {
                                    let indexURL = URL(string: "https://huggingface.co/\(repoID)/raw/main/model.safetensors.index.json")!
                                    var req = URLRequest(url: indexURL)
                                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                                    if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                    }
                                    let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                    if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                                        try? data.write(to: idxDest)
                                        print("[ModelDownloadManager] Also downloaded model.safetensors.index.json")
                                    }
                                } catch {
                                    // Index is optional for single-file models
                                }
                            }
                        }

                        // Attempt to fetch common VLM processor/projector configs used by MLX VLM models (e.g., SmolVLM)
                        let vlmSidecars: [String] = [
                            "image_processor.json",
                            "processor_config.json",
                            "preprocessor_config.json",
                            "vision_config.json",
                            "open_clip_config.json",
                            "siglip_config.json",
                            "projector.json"
                        ]
                        for side in vlmSidecars {
                            let dest = dir.appendingPathComponent(side)
                            if FileManager.default.fileExists(atPath: dest.path) { continue }
                            // Prefer resolve endpoint; fall back to raw
                            do {
                                let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(side)?download=1")!
                                var req = URLRequest(url: url)
                                req.setValue("application/json", forHTTPHeaderField: "Accept")
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                    try? data.write(to: dest)
                                    continue
                                }
                            } catch {}
                            do {
                                let raw = URL(string: "https://huggingface.co/\(repoID)/raw/main/\(side)")!
                                var req = URLRequest(url: raw)
                                req.setValue("application/json", forHTTPHeaderField: "Accept")
                                if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
                                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                }
                                if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
                                NetworkKillSwitch.track(session: URLSession.shared)
                                let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 0 {
                                    try? data.write(to: dest)
                                }
                            } catch {
                                // optional
                            }
                        }
                    }

                    // Success - file has been downloaded and moved to final location
                    clearDataTask(for: key, cancel: false)

                    let layers = ModelScanner.layerCount(for: final, format: quant.format)
                    let canonical = InstalledModelsStore.canonicalURL(for: final, format: quant.format)
                    if quant.format == .ane {
                        try self.verifyANEMLLInstallIfNeeded(
                            root: canonical,
                            modelID: modelID,
                            sourceRepoID: huggingFaceRepoID(from: quant.downloadURL)
                        )
                    }
                    if quant.format == .ane {
                        self.scheduleCoreMLPrecompileIfNeeded(root: canonical)
                    }
                    
                    // Detect capabilities: rely on projector presence for GGUF models
                    let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
                    let authToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
                    var meta = await HuggingFaceMetadataCache.fetchAndCache(repoId: modelID, token: authToken)
                    var isVision = false
                    switch quant.format {
                    case .gguf:
                        if let meta, meta.hasProjectorFile {
                            isVision = true
                        } else {
                            isVision = ProjectorLocator.hasProjectorFile(alongside: canonical)
                            if !isVision, meta == nil {
                                isVision = await VisionModelDetector.isVisionModel(repoId: modelID, token: (authToken?.isEmpty ?? true) ? nil : authToken)
                                if let refreshed = HuggingFaceMetadataCache.cached(repoId: modelID) {
                                    meta = refreshed
                                }
                            }
                        }
                    case .mlx:
                        isVision = MLXBridge.isVLMModel(at: canonical)
                    case .et:
                        // Use Leap heuristics: prefer quantization slug check; fall back to bundle scan
                        let slug = final.deletingPathExtension().lastPathComponent
                        isVision = LeapCatalogService.isVisionQuantizationSlug(slug) || LeapCatalogService.bundleLikelyVision(at: canonical)
                    case .ane:
                        isVision = false
                    case .afm:
                        isVision = false
                    case .coreai:
                        isVision = false
                    }
                    // Tool capability: prefer hub/template/token hints; fallback to local scan of installed files
                    var isToolCapable = quant.format == .afm ? false : await ToolCapabilityDetector.isToolCapable(repoId: modelID, token: authToken)
                    if isToolCapable == false {
                        isToolCapable = ToolCapabilityDetector.isToolCapableLocal(url: canonical, format: quant.format)
                    }

                    let moeInfo: MoEInfo?
                    switch quant.format {
                    case .gguf, .mlx:
                        let detectedInfo = ModelScanner.moeInfo(for: canonical, format: quant.format)
                        if let detectedInfo {
                            let label = detectedInfo.isMoE ? "MoE" : "Dense"
                            let moeLayers = detectedInfo.moeLayerCount.map(String.init) ?? "n/a"
                            let totalLayers = detectedInfo.totalLayerCount.map(String.init) ?? "n/a"
                            print("[MoEDetect] post-download \(modelID) (\(quant.label)) [\(quant.format.displayName)] → \(label) experts=\(detectedInfo.expertCount) moeLayers=\(moeLayers) totalLayers=\(totalLayers)")
                            moeInfo = detectedInfo
                        } else {
                            print("[MoEDetect] post-download \(modelID) (\(quant.label)) [\(quant.format.displayName)] scan failed; defaulting to Dense metadata")
                            moeInfo = .denseFallback
                        }
                        if let info = moeInfo {
                            await MoEDetectionStore.shared.update(info: info, modelID: modelID, quantLabel: quant.label)
                        }
                    case .et, .ane, .afm, .coreai:
                        moeInfo = nil
                    }

                    let installed = InstalledModel(modelID: modelID,
                                                   quantLabel: quant.label,
                                                   url: canonical,
                                                   format: quant.format,
                                                   sizeBytes: installedSizeBytes,
                                                   lastUsed: nil,
                                                   installDate: Date(),
                                                   checksum: quant.sha256,
                                                   isFavourite: false,
                                                   totalLayers: layers,
                                                   isMultimodal: isVision,
                                                   isToolCapable: isToolCapable,
                                                   moeInfo: moeInfo,
                                                   etBackend: quant.format == .et
                                                       ? ETBackendDetector.effectiveBackend(
                                                           userSelected: nil,
                                                           detected: ETBackendDetector.detect(tags: [], modelName: "\(modelID) \(quant.label)")
                                                       )
                                                       : nil)
                    self.clearTempDestinations(for: key)
                    continuation.yield(.finished(installed))
                } catch is CancellationError {
                    // Full cancel
                    for destination in self.tempDestinations(for: key) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                    self.clearTempDestinations(for: key)
                    continuation.yield(.cancelled)
                } catch {
                    let ns = error as NSError
                    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                        let (written, reportedExpected) = await transferState.snapshot()
                        let fallbackExpected = await expectedState.total()
                        let snapshot = Self.canonicalProgressSnapshot(
                            written: written,
                            reportedExpected: reportedExpected,
                            fallbackExpected: fallbackExpected
                        )
                        if let currentArtifactID {
                            await DownloadEngine.shared.updateArtifactState(
                                externalID: key,
                                artifactID: currentArtifactID,
                                state: .paused,
                                downloadedBytes: snapshot.downloadedBytes,
                                expectedBytes: snapshot.expectedBytes,
                                manualPause: true
                            )
                        }
                        continuation.yield(.paused(snapshot.progress))
                    } else if self.isNetworkError(error) {
                        let (written, reportedExpected) = await transferState.snapshot()
                        let fallbackExpected = await expectedState.total()
                        let snapshot = Self.canonicalProgressSnapshot(
                            written: written,
                            reportedExpected: reportedExpected,
                            fallbackExpected: fallbackExpected
                        )
                        if let currentArtifactID {
                            await DownloadEngine.shared.updateArtifactState(
                                externalID: key,
                                artifactID: currentArtifactID,
                                state: .retrying,
                                downloadedBytes: snapshot.downloadedBytes,
                                expectedBytes: snapshot.expectedBytes,
                                retryCount: 1,
                                nextRetryAt: Date().addingTimeInterval(2),
                                errorMessage: error.localizedDescription,
                                manualPause: false
                            )
                        }
                        continuation.yield(.networkError(error, snapshot.progress))
                    } else {
                        if let currentArtifactID {
                            await DownloadEngine.shared.updateArtifactState(
                                externalID: key,
                                artifactID: currentArtifactID,
                                state: .failed,
                                errorMessage: error.localizedDescription,
                                manualPause: false
                            )
                        }
                        continuation.yield(.failed(error))
                    }
                }
                continuation.finish()
            }

            active[key] = task
            continuation.onTermination = { [self] termination in
                guard case .cancelled = termination else { return }
                Task { await self.cancel(modelID: modelID, quantLabel: quant.label) }
            }
        }
    }

    func cancel(modelID: String, quantLabel: String) {
        let key = "\(modelID)-\(quantLabel)"
        active[key]?.cancel()
        active[key] = nil
        let destinations = tempDestinations(for: key)
        clearTempDestinations(for: key)
        if !destinations.isEmpty {
            // Hop to main without making this method async
            Task { @MainActor in
                for destination in destinations {
                    BackgroundDownloadManager.shared.cancel(destination: destination)
                }
            }
        } else {
            clearDataTask(for: key, cancel: true)
        }
    }

    private func isGitLFSPointerData(_ data: Data) -> Bool {
        if data.count > 4096 { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        return lower.contains("git-lfs") || lower.contains("oid sha256:")
    }

    @discardableResult
    private func downloadRepoFileIfMissing(
        repoID: String,
        fileName: String,
        into dir: URL,
        accept: String,
        token: String?,
        rejectLFSPointer: Bool = false,
        externalID: String? = nil
    ) async -> Bool {
        let dest = dir.appendingPathComponent(fileName)
        let isTokenizerCandidate = ETModelResolver.tokenizerFileNames.contains(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            if isTokenizerCandidate, ETModelResolver.invalidTokenizerReason(at: dest) != nil {
                try? FileManager.default.removeItem(at: dest)
            } else {
                return true
            }
        }
        if NetworkKillSwitch.isEnabled { return false }

        let escaped = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let endpoints = [
            "https://huggingface.co/\(repoID)/resolve/main/\(escaped)?download=1",
            "https://huggingface.co/\(repoID)/raw/main/\(escaped)"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                var req = URLRequest(url: url)
                req.setValue(accept, forHTTPHeaderField: "Accept")
                if let token, !token.isEmpty {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let data: Data
                let resp: URLResponse
                if let fetcher = Self.repositoryFileFetcherOverride {
                    (data, resp) = try await fetcher(req)
                } else {
                    NetworkKillSwitch.track(session: URLSession.shared)
                    (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                }
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                    continue
                }
                if rejectLFSPointer && isGitLFSPointerData(data) {
                    continue
                }
                do {
                    try data.write(to: dest)
                } catch {
                    continue
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    await markDownloadedModelSidecar(externalID: externalID, relativePath: fileName, finalURL: dest, remoteURL: url, finalBytes: Int64(data.count))
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

#if DEBUG
    func fetchETTokenizerArtifactsForTesting(repoID: String, into dir: URL, required: Bool) async throws -> Bool {
        try await downloadETTokenizerArtifacts(repoID: repoID, into: dir, token: nil, required: required)
    }
#endif

    private static let aneTokenizerFileNames = ["tokenizer.json", "tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]

    private func downloadANESidecarArtifacts(repoID: String, into dir: URL, token: String?, externalID: String? = nil) async throws {
        _ = await downloadRepoFileIfMissing(
            repoID: repoID,
            fileName: "meta.yaml",
            into: dir,
            accept: "text/plain",
            token: token,
            externalID: externalID
        )

        _ = await downloadRepoFileIfMissing(
            repoID: repoID,
            fileName: "tokenizer.json",
            into: dir,
            accept: "application/json",
            token: token,
            rejectLFSPointer: true,
            externalID: externalID
        )
        if !Self.installContainsANETokenizer(at: dir) {
            for name in ["tokenizer.model", "spiece.model", "sentencepiece.bpe.model"] {
                _ = await downloadRepoFileIfMissing(
                    repoID: repoID,
                    fileName: name,
                    into: dir,
                    accept: "application/octet-stream",
                    token: token,
                    externalID: externalID
                )
                if Self.installContainsANETokenizer(at: dir) { break }
            }
        }

        let sidecars = [
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "vocab.json",
            "vocab.txt",
            "merges.txt",
            "config.json",
            "generation_config.json",
            "chat_template.json",
            "chat_template.jinja"
        ]
        for file in sidecars {
            let accept: String
            if file.hasSuffix(".json") {
                accept = "application/json"
            } else if file.hasSuffix(".txt") || file.hasSuffix(".jinja") {
                accept = "text/plain"
            } else {
                accept = "application/octet-stream"
            }
            _ = await downloadRepoFileIfMissing(
                repoID: repoID,
                fileName: file,
                into: dir,
                accept: accept,
                token: token,
                externalID: externalID
            )
        }

        guard Self.installContainsANETokenizer(at: dir) else {
            throw NSError(
                domain: "Noema.ANEDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The CoreML model from \(repoID) has no tokenizer files (tokenizer.json or tokenizer.model). The model cannot run without one."]
            )
        }
    }

    /// The CoreML client loads tokenizers from the install root or a (non-container)
    /// subdirectory; mirror that search when deciding whether a tokenizer is present.
    nonisolated private static func installContainsANETokenizer(at root: URL) -> Bool {
        let fm = FileManager.default
        func directoryHasTokenizer(_ url: URL) -> Bool {
            let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return contents.contains { aneTokenizerFileNames.contains($0.lastPathComponent.lowercased()) }
        }
        if directoryHasTokenizer(root) { return true }
        let subdirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { url in
                let ext = url.pathExtension.lowercased()
                guard ext != "mlmodelc", ext != "mlpackage" else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        return subdirs.contains(where: directoryHasTokenizer)
    }

    /// Core AI variants on Hugging Face often ship without tokenizer files next to
    /// the `.aimodel` bundle (the bundle holds only the compiled graph). Backfill
    /// `tokenizer.json` (+ companions) into the variant root, trying the model repo
    /// first, then the tokenizer repo referenced by the variant's `metadata.json`
    /// (`language.tokenizer`), then the Hub card's `base_model`.
    private func downloadCoreAITokenizerArtifacts(repoID: String, variantRoot: URL, token: String?, externalID: String? = nil) async throws {
        if Self.coreAITokenizerURL(under: variantRoot) != nil { return }

        var sourceRepos: [String] = [repoID]
        if let referenced = Self.coreAIReferencedTokenizerRepo(under: variantRoot), !sourceRepos.contains(referenced) {
            sourceRepos.append(referenced)
        }
        if let base = await Self.fetchBaseModelRepoID(for: repoID, token: token), !sourceRepos.contains(base) {
            sourceRepos.append(base)
        }

        let sidecars = [
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "vocab.json",
            "merges.txt",
            "generation_config.json",
            "chat_template.json",
            "chat_template.jinja"
        ]
        for repo in sourceRepos {
            _ = await downloadRepoFileIfMissing(
                repoID: repo,
                fileName: "tokenizer.json",
                into: variantRoot,
                accept: "application/json",
                token: token,
                rejectLFSPointer: true,
                externalID: externalID
            )
            guard Self.coreAITokenizerURL(under: variantRoot) != nil else { continue }
            for file in sidecars {
                let accept = file.hasSuffix(".json") ? "application/json" : "text/plain"
                _ = await downloadRepoFileIfMissing(
                    repoID: repo,
                    fileName: file,
                    into: variantRoot,
                    accept: accept,
                    token: token,
                    externalID: externalID
                )
            }
            return
        }

        throw NSError(
            domain: "Noema.CoreAIDownload",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The Core AI model from \(repoID) has no tokenizer.json, and none could be fetched from its source repo. The model cannot run without one."]
        )
    }

    /// Mirrors CoreAIModelResolver's tokenizer search: the variant root, then its
    /// `tokenizer/` subfolder.
    nonisolated private static func coreAITokenizerURL(under root: URL) -> URL? {
        let fm = FileManager.default
        for dir in [root, root.appendingPathComponent("tokenizer", isDirectory: true)] {
            for name in ["tokenizer.json", "tokenizer.model"] {
                let candidate = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    nonisolated private static func coreAIReferencedTokenizerRepo(under root: URL) -> String? {
        let url = root.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let language = json["language"] as? [String: Any],
              let tokenizer = language["tokenizer"] as? String,
              tokenizer.contains("/") else { return nil }
        return tokenizer
    }

    private static func fetchBaseModelRepoID(for repoID: String, token: String?) async -> String? {
        guard !NetworkKillSwitch.isEnabled else { return nil }
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)?cardData=true") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        NetworkKillSwitch.track(session: URLSession.shared)
        guard let (data, resp) = try? await URLSession.shared.data(for: HFEndpoint.rewrite(req)),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let card = json["cardData"] as? [String: Any] else { return nil }
        if let base = card["base_model"] as? String, base.contains("/") { return base }
        if let bases = card["base_model"] as? [String], let base = bases.first(where: { $0.contains("/") }) {
            return base
        }
        return nil
    }

    @discardableResult
    private func downloadETTokenizerArtifacts(repoID: String, into dir: URL, token: String?, required: Bool = false, externalID: String? = nil) async throws -> Bool {
        ETModelResolver.writeSourceRepoID(repoID, into: dir)

        _ = await downloadRepoFileIfMissing(
            repoID: repoID,
            fileName: "tokenizer.json",
            into: dir,
            accept: "application/json",
            token: token,
            rejectLFSPointer: true,
            externalID: externalID
        )

        if ETModelResolver.tokenizerURL(for: dir) == nil {
            let fallbackTokenizers = ["tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]
            for name in fallbackTokenizers {
                _ = await downloadRepoFileIfMissing(
                    repoID: repoID,
                    fileName: name,
                    into: dir,
                    accept: "application/octet-stream",
                    token: token,
                    externalID: externalID
                )
                if ETModelResolver.tokenizerURL(for: dir) != nil {
                    break
                }
            }
        }

        let sidecars = [
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "vocab.json",
            "vocab.txt",
            "merges.txt"
        ]
        for file in sidecars {
            let accept: String
            if file.hasSuffix(".json") {
                accept = "application/json"
            } else if file.hasSuffix(".txt") {
                accept = "text/plain"
            } else {
                accept = "application/octet-stream"
            }
            _ = await downloadRepoFileIfMissing(
                repoID: repoID,
                fileName: file,
                into: dir,
                accept: accept,
                token: token,
                externalID: externalID
            )
        }

        do {
            _ = try ETModelResolver.resolveLoadArtifacts(for: dir)
            return true
        } catch {
            if required { throw error }
            return false
        }
    }

    func repairETArtifacts(modelID: String, modelURL: URL, sourceRepoID: String? = nil) async throws {
        let dir = ETModelResolver.modelDirectory(for: modelURL)
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var repos: [String] = []
        if let sourceRepoID, !sourceRepoID.isEmpty {
            repos.append(sourceRepoID)
        }
        if let source = ETModelResolver.sourceRepoID(in: dir), !source.isEmpty {
            if !repos.contains(source) { repos.append(source) }
        }
        if !modelID.isEmpty, !repos.contains(modelID) {
            repos.append(modelID)
        }

        guard !repos.isEmpty else {
            _ = try ETModelResolver.resolveLoadArtifacts(for: dir)
            return
        }

        var lastError: Error?
        for repo in repos {
            do {
                if try await downloadETTokenizerArtifacts(repoID: repo, into: dir, token: token, required: false) {
                    _ = try ETModelResolver.resolveLoadArtifacts(for: dir)
                    return
                }
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        _ = try ETModelResolver.resolveLoadArtifacts(for: dir)
    }
    
    nonisolated private func isNetworkError(_ error: Error) -> Bool {
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
            return true
        }

        // HTTP 5xx server errors and rate limiting should also be retryable
        if let status = BackgroundDownloadManager.httpRejectionStatus(from: error) {
            return status >= 500 || status == 429
        }
        if let httpError = error as? URLError,
           let response = httpError.userInfo["NSHTTPURLResponse"] as? HTTPURLResponse {
            return response.statusCode >= 500
        }

        return false
    }

    // Extract the owner/repo path from a Hugging Face URL.
    private func huggingFaceRepoID(from url: URL) -> String? {
        guard let host = url.host, host.contains("huggingface.co") else { return nil }
        var parts = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        // Skip common API/CDN prefixes like `/repos` or `/api/models`
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

    nonisolated static func modelSidecarArtifactID(relativePath: String) -> String {
        "sidecar:\(relativePath)"
    }

    private func markDownloadedModelSidecar(externalID: String?,
                                            relativePath: String,
                                            finalURL: URL,
                                            remoteURL: URL?,
                                            finalBytes: Int64? = nil) async {
        guard let externalID, !externalID.isEmpty else { return }
        let bytes = finalBytes ?? fileSize(at: finalURL) ?? 0
        let artifact = DownloadArtifact(
            id: Self.modelSidecarArtifactID(relativePath: relativePath),
            role: .modelSidecar,
            remoteURL: remoteURL,
            stagingURL: finalURL.appendingPathExtension("download"),
            finalURL: finalURL,
            expectedBytes: bytes > 0 ? bytes : nil,
            downloadedBytes: bytes,
            checksum: nil,
            state: .completed,
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorDescription: nil,
            manualPause: false
        )
        await DownloadEngine.shared.upsertArtifacts(externalID: externalID, artifacts: [artifact])
        await DownloadEngine.shared.markArtifactCompleted(
            externalID: externalID,
            artifactID: artifact.id,
            finalBytes: bytes > 0 ? bytes : nil
        )
    }

    /// Best-effort download of a repo's params / params.json sidecar to seed default sampling settings.
    private func downloadParamsFile(repoID: String, into dir: URL, token: String?, externalID: String? = nil) async throws {
        let fm = FileManager.default
        let existing = ["params", "params.json"].first(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) })
        if existing != nil { return }
        // Respect offline/kill switch
        if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }

        let candidates = ["params", "params.json"]
        let endpointTemplates = [
            "https://huggingface.co/%@/resolve/main/%@?download=1",
            "https://huggingface.co/%@/raw/main/%@"
        ]

        for name in candidates {
            for tmpl in endpointTemplates {
                guard let url = URL(string: String(format: tmpl, repoID, name)) else { continue }
                var req = URLRequest(url: url)
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                if let token, !token.isEmpty {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                NetworkKillSwitch.track(session: URLSession.shared)
                do {
                    let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
                    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { continue }
                    // Basic sniff to ensure it's JSON
                    guard (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
                    let dest = dir.appendingPathComponent(name)
                    try data.write(to: dest)
                    await markDownloadedModelSidecar(externalID: externalID, relativePath: name, finalURL: dest, remoteURL: url, finalBytes: Int64(data.count))
                    return
                } catch {
                    // try next candidate/endpoint
                    continue
                }
            }
        }
    }
}
