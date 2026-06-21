// LeapBundleDownloader.swift
import Foundation
import CryptoKit

/// Downloader for ET bundles using the Hugging Face models API.
///
/// It discovers bundle filenames via `https://huggingface.co/api/models/LiquidAI/LeapBundles`
/// and downloads using the `resolve/main/<filename>?download=1` endpoint with
/// support for resume, Hugging Face tokens, and progress updates.
final class LeapBundleDownloader: NSObject, @unchecked Sendable {

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed(URL)
        case failed(String)
    }

    static let shared = LeapBundleDownloader()

    private let queue = DispatchQueue(label: "noema.leap.downloader")
    private var continuations: [String: AsyncStream<DownloadEvent>.Continuation] = [:] // keyed by quantization slug
    private var dataTasks: [String: URLSessionDataTask] = [:] // keyed by quantization slug
    private var progressMap: [String: Double] = [:] // keyed by quantization slug
    private var bgDestinations: [String: [URL]] = [:] // keyed by slug, used to cancel BackgroundDownloadManager tasks
    private var pausedSlugs: Set<String> = []

    private override init() { super.init() }

    // Network error classifier for retry/backoff decisions
    private func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let codes: Set<Int> = [
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
        if nsError.domain == NSURLErrorDomain && codes.contains(nsError.code) { return true }
        if let http = nsError.userInfo["NSHTTPURLResponse"] as? HTTPURLResponse, http.statusCode >= 500 { return true }
        return false
    }

    /// Async status using local file presence or in-memory progress.
    func statusAsync(for entry: LeapCatalogEntry) async -> State {
        let slug = entry.slug
        if let installedURL = installedURLIfPresent(for: entry) {
            return .installed(installedURL)
        }
        // If there is an active download, report progress
        var currentProgress: Double?
        queue.sync { currentProgress = progressMap[slug] }
        if let p = currentProgress { return .downloading(p) }

        // If there's a temp file for bundled artifacts, estimate progress from size/expected
        if entry.artifactKind == .bundle {
            let base = InstalledModelsStore.baseDir(for: .et, modelID: slug)
            let tmp = base.appendingPathComponent(slug + ".bundle.download")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path),
               let sz = attrs[.size] as? Int64, entry.sizeBytes > 0 {
                let p = max(0, min(1, Double(sz) / Double(entry.sizeBytes)))
                return .downloading(p)
            }
        }
        return .notInstalled
    }

    /// Legacy sync status kept for compatibility; returns .notInstalled.
    func status(for entry: LeapCatalogEntry) -> State { .notInstalled }

    /// Cancel a specific active download.
    func cancel(slug: String) {
        queue.sync {
            pausedSlugs.remove(slug)
            dataTasks[slug]?.cancel()
            dataTasks[slug] = nil
            if let destinations = bgDestinations.removeValue(forKey: slug) {
                for destination in destinations {
                    Task { @MainActor in
                        BackgroundDownloadManager.shared.cancel(destination: destination)
                    }
                }
            }
            if let cont = continuations.removeValue(forKey: slug) {
                cont.yield(.cancelled)
                cont.finish()
            }
            progressMap.removeValue(forKey: slug)
        }
    }

    func pause(slug: String) {
        queue.sync {
            pausedSlugs.insert(slug)
            dataTasks[slug]?.cancel()
            dataTasks[slug] = nil
            if let destinations = bgDestinations[slug] {
                for destination in destinations {
                    Task { @MainActor in
                        BackgroundDownloadManager.shared.pause(destination: destination)
                    }
                }
            }
            let progress = progressMap[slug] ?? 0
            if let cont = continuations.removeValue(forKey: slug) {
                cont.yield(.paused(progress))
                cont.finish()
            }
        }
    }

    /// Cancel all active downloads.
    func cancelAll() {
        queue.sync {
            pausedSlugs.removeAll()
            for (_, task) in dataTasks { task.cancel() }
            dataTasks.removeAll()
            let allDestinations = bgDestinations.values.flatMap { $0 }
            bgDestinations.removeAll()
            for destination in allDestinations {
                Task { @MainActor in
                    BackgroundDownloadManager.shared.cancel(destination: destination)
                }
            }
            for (_, cont) in continuations { cont.yield(.cancelled); cont.finish() }
            continuations.removeAll()
            progressMap.removeAll()
        }
    }

    /// Download a ET bundle via Hugging Face API and emit DownloadEvent updates.
    func download(_ entry: LeapCatalogEntry, jobID: String? = nil) -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let slug = entry.slug

        queue.sync {
            pausedSlugs.remove(slug)
            continuations[slug] = continuation
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                switch entry.artifactKind {
                case .bundle:
                    try await self.downloadBundleArtifact(entry, jobID: jobID, continuation: continuation)
                case .manifest:
                    try await self.downloadManifestArtifact(entry, requestedJobID: jobID, continuation: continuation)
                }
            } catch {
                let pausedByUser = self.queue.sync { self.pausedSlugs.contains(slug) }
                if pausedByUser {
                    let p = self.queue.sync { self.progressMap[slug] } ?? 0
                    continuation.yield(.paused(p))
                } else if self.isNetworkError(error) {
                    let p = queue.sync { progressMap[slug] } ?? 0
                    continuation.yield(.networkError(error, p))
                } else {
                    continuation.yield(.failed(error))
                }
                continuation.finish()
                queue.sync {
                    pausedSlugs.remove(slug)
                    continuations.removeValue(forKey: slug)
                    dataTasks[slug]?.cancel()
                    dataTasks[slug] = nil
                    bgDestinations.removeValue(forKey: slug)
                    progressMap.removeValue(forKey: slug)
                }
                return
            }

            continuation.finish()
            queue.sync {
                pausedSlugs.remove(slug)
                continuations.removeValue(forKey: slug)
                progressMap.removeValue(forKey: slug)
                bgDestinations.removeValue(forKey: slug)
            }
        }

        continuation.onTermination = { [weak self] term in
            guard let self else { return }
            if case .cancelled = term {
                self.cancel(slug: slug)
            }
        }

        return stream
    }

    private struct ManifestDocument: Decodable {
        let schema_version: String?
        let inference_type: String?
        let load_time_parameters: [String: String]?
    }

    private final class DataFileDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        var hasher: SHA256?
        var expected: Int64
        var bytes: Int64 = 0
        var lastBytes: Int64
        var lastTime: Date
        var lastProgress: Double = 0
        let report: @Sendable (Double, Int64, Double) -> Void

        init(handle: FileHandle, expected: Int64, sha: Bool, start: Date, report: @escaping @Sendable (Double, Int64, Double) -> Void) {
            self.handle = handle
            self.expected = expected
            self.report = report
            self.lastTime = start
            self.lastBytes = 0
            if sha { self.hasher = SHA256() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if expected <= 0 { expected = response.expectedContentLength }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            try? handle.write(contentsOf: data)
            hasher?.update(data: data)
            bytes += Int64(data.count)

            let now = Date()
            let prog = expected > 0 ? Double(bytes) / Double(expected) : 0
            if prog - lastProgress >= 0.01 || now.timeIntervalSince(lastTime) >= 0.3 {
                let speed = Double(bytes - lastBytes) / max(0.001, now.timeIntervalSince(lastTime))
                lastBytes = bytes
                lastTime = now
                lastProgress = prog
                report(prog, bytes, speed)
            }
        }

        private var cont: CheckedContinuation<Void, Error>?
        func wait() async throws { try await withCheckedThrowingContinuation { self.cont = $0 } }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            if let e = error { cont?.resume(throwing: e) } else { cont?.resume() }
        }

        func finalizeHash() -> String? {
            guard let h = hasher else { return nil }
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private func installedURLIfPresent(for entry: LeapCatalogEntry) -> URL? {
        let base = InstalledModelsStore.baseDir(for: .et, modelID: entry.modelID)
        switch entry.artifactKind {
        case .bundle:
            let finalURL = base.appendingPathComponent(entry.slug + ".bundle")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: finalURL.path, isDirectory: &isDir), !isDir.boolValue {
                return finalURL
            }
            return nil
        case .manifest:
            let dir = base.appendingPathComponent(entry.slug, isDirectory: true)
            return firstPrimaryGGUF(in: dir)
        }
    }

    private func firstPrimaryGGUF(in directory: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.first(where: { file in
            let lower = file.lastPathComponent.lowercased()
            guard lower.hasSuffix(".gguf") else { return false }
            if lower.contains("mmproj") || lower.contains("projector") { return false }
            if lower.contains("vocoder") || lower.contains("decoder") || lower.contains("tokenizer") { return false }
            return true
        })
    }

    private func leapResolveURL(for remotePath: String) -> URL {
        let escaped = remotePath
            .split(separator: "/")
            .map { component -> String in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
            }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/LiquidAI/LeapBundles/resolve/main/\(escaped)?download=1")!
    }

    private func readFileSize(_ url: URL) -> Int64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            return size
        }
        return 0
    }

    private func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1_048_576) ?? Data()
            if let chunk, !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            }
            return false
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func withAuthHeaders(_ request: inout URLRequest, token: String?) {
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let t = token, !t.isEmpty {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
    }

    private func registerBackgroundDestination(_ destination: URL, for slug: String) {
        queue.sync {
            var list = bgDestinations[slug] ?? []
            if !list.contains(destination) { list.append(destination) }
            bgDestinations[slug] = list
        }
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

    private func downloadBundleArtifact(_ entry: LeapCatalogEntry,
                                        jobID: String?,
                                        continuation: AsyncStream<DownloadEvent>.Continuation) async throws {
        let slug = entry.slug
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
        let base = InstalledModelsStore.baseDir(for: .et, modelID: entry.modelID)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let finalURL = base.appendingPathComponent(slug + ".bundle")
        let stagingURL = finalURL.appendingPathExtension("download")

        if let installedURL = installedURLIfPresent(for: entry) {
            let installedBytes = max(entry.sizeBytes, readFileSize(installedURL))
            await DownloadEngine.shared.markArtifactCompleted(
                externalID: slug,
                artifactID: "bundle",
                finalBytes: installedBytes
            )
            let installed = InstalledModel(
                modelID: entry.modelID,
                quantLabel: entry.quantization,
                url: installedURL,
                format: .et,
                sizeBytes: installedBytes,
                lastUsed: nil,
                installDate: Date(),
                checksum: entry.sha256,
                isFavourite: false,
                totalLayers: 0,
                isMultimodal: entry.isVision,
                isToolCapable: true,
                moeInfo: nil
            )
            continuation.yield(.finished(installed))
            return
        }

        continuation.yield(.started(entry.sizeBytes > 0 ? entry.sizeBytes : nil))
        let expectedBytes: Int64 = entry.sizeBytes > 0 ? entry.sizeBytes : 0
        let resolveURL = leapResolveURL(for: entry.remotePath.isEmpty ? (slug + ".bundle") : entry.remotePath)
        var request = URLRequest(url: resolveURL)
        withAuthHeaders(&request, token: token)
        registerBackgroundDestination(stagingURL, for: slug)
        await DownloadEngine.shared.updateArtifactState(
            externalID: slug,
            artifactID: "bundle",
            state: .downloading,
            manualPause: false
        )

        var lastBytes: Int64 = 0
        var lastTime = Date()
        try await BackgroundDownloadManager.shared.download(
            request: request,
            to: stagingURL,
            jobID: jobID,
            artifactID: "bundle",
            expectedSize: expectedBytes > 0 ? expectedBytes : nil,
            progress: nil,
            progressBytes: { written, expected in
                let now = Date()
                let dt = max(0.001, now.timeIntervalSince(lastTime))
                let speed = Double(max(0, written - lastBytes)) / dt
                lastTime = now
                lastBytes = written
                let total = max(expected, expectedBytes, written, 1)
                    let progress = min(1, max(0, Double(written) / Double(total)))
                    self.queue.sync { self.progressMap[slug] = progress }
                    continuation.yield(.progress(progress, written, total, speed))
                    Task {
                        await DownloadEngine.shared.updateArtifactProgressLive(
                            externalID: slug,
                            artifactID: "bundle",
                            written: written,
                            expected: total
                        )
                }
            }
        )
        try finalizeStagedDownload(from: stagingURL, to: finalURL)

        let actualBytes = readFileSize(finalURL)
        continuation.yield(.progress(1, max(1, actualBytes), max(1, max(actualBytes, expectedBytes)), 0))
        continuation.yield(.verifying)

        if let sha = entry.sha256,
           let computed = sha256Hex(of: finalURL),
           sha.lowercased() != computed.lowercased() {
            throw URLError(.cannotParseResponse)
        }
        await DownloadEngine.shared.markArtifactCompleted(
            externalID: slug,
            artifactID: "bundle",
            finalBytes: actualBytes
        )
        let fileSize = actualBytes

        let installed = InstalledModel(
            modelID: entry.modelID,
            quantLabel: entry.quantization,
            url: finalURL,
            format: .et,
            sizeBytes: fileSize > 0 ? fileSize : max(actualBytes, expectedBytes),
            lastUsed: nil,
            installDate: Date(),
            checksum: entry.sha256,
            isFavourite: false,
            totalLayers: 0,
            isMultimodal: entry.isVision,
            isToolCapable: true,
            moeInfo: nil
        )
        continuation.yield(.finished(installed))
    }

    @MainActor
    private func downloadManifestArtifact(_ entry: LeapCatalogEntry,
                                          requestedJobID: String?,
                                          continuation: AsyncStream<DownloadEvent>.Continuation) async throws {
        let slug = entry.slug
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = InstalledModelsStore.baseDir(for: .et, modelID: entry.modelID)
        let installDir = base.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        if let installedURL = installedURLIfPresent(for: entry) {
            let installed = InstalledModel(
                modelID: entry.modelID,
                quantLabel: entry.quantization,
                url: installedURL,
                format: .et,
                sizeBytes: max(entry.sizeBytes, readFileSize(installedURL)),
                lastUsed: nil,
                installDate: Date(),
                checksum: nil,
                isFavourite: false,
                totalLayers: 0,
                isMultimodal: entry.isVision,
                isToolCapable: true,
                moeInfo: nil
            )
            continuation.yield(.finished(installed))
            return
        }

        continuation.yield(.started(nil))

        // 1) Fetch manifest.
        var manifestReq = URLRequest(url: leapResolveURL(for: entry.remotePath))
        withAuthHeaders(&manifestReq, token: token)
        let (manifestData, manifestResp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(manifestReq))
        if let http = manifestResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let manifest = try JSONDecoder().decode(ManifestDocument.self, from: manifestData)
        let manifestLocalURL = installDir.appendingPathComponent(entry.quantization + ".json")
        try? manifestData.write(to: manifestLocalURL, options: .atomic)
        await DownloadEngine.shared.markArtifactCompleted(
            externalID: slug,
            artifactID: "manifest",
            finalBytes: readFileSize(manifestLocalURL)
        )

        guard let loadParams = manifest.load_time_parameters, !loadParams.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        var files: [(name: String, key: String, url: URL, destination: URL)] = []
        for (key, value) in loadParams {
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            let filename = url.lastPathComponent.isEmpty ? key : url.lastPathComponent
            let destination = installDir.appendingPathComponent(filename)
            files.append((filename, key, url, destination))
        }
        var seenDestinations = Set<String>()
        files = files.filter { seenDestinations.insert($0.destination.path).inserted }
        guard !files.isEmpty else { throw URLError(.cannotParseResponse) }

        let manifestArtifacts = files.map { file in
            DownloadArtifact(
                id: "leap:\(file.destination.lastPathComponent)",
                role: .leapManifestAsset,
                remoteURL: file.url,
                stagingURL: file.destination.appendingPathExtension("download"),
                finalURL: file.destination,
                expectedBytes: nil,
                downloadedBytes: 0,
                checksum: nil,
                state: .queued,
                retryCount: 0,
                nextRetryAt: nil,
                lastErrorDescription: nil,
                manualPause: false
            )
        }
        let job = await DownloadEngine.shared.upsertJob(
            owner: .leap(LeapDownloadOwner(entry: entry)),
            artifacts: [
                DownloadArtifact(
                    id: "manifest",
                    role: .leapManifest,
                    remoteURL: leapResolveURL(for: entry.remotePath),
                    stagingURL: manifestLocalURL,
                    finalURL: manifestLocalURL,
                    expectedBytes: readFileSize(manifestLocalURL),
                    downloadedBytes: readFileSize(manifestLocalURL),
                    checksum: nil,
                    state: .completed,
                    retryCount: 0,
                    nextRetryAt: nil,
                    lastErrorDescription: nil,
                    manualPause: false
                )
            ] + manifestArtifacts,
            state: .downloading
        )
        let activeJobID = requestedJobID ?? job.id

        // Identify primary model file from manifest key, fallback to first non-projector gguf.
        let primary = files.first(where: { $0.key.caseInsensitiveCompare("model") == .orderedSame })
            ?? files.first(where: { $0.key.lowercased().contains("model") })
            ?? files.first(where: { $0.url.lastPathComponent.lowercased().hasSuffix(".gguf") && !$0.url.lastPathComponent.lowercased().contains("mmproj") })
            ?? files.first
        guard let primary else { throw URLError(.cannotParseResponse) }

        queue.sync {
            bgDestinations[slug] = files.map(\.destination)
        }

        var expectedByIndex = Array(repeating: Int64(0), count: files.count)
        var writtenByIndex = Array(repeating: Int64(0), count: files.count)
        var lastAggregateBytes: Int64 = 0
        var lastSampleTime = Date()

        for (idx, file) in files.enumerated() {
            let existingBytes = readFileSize(file.destination)
            let artifactID = "leap:\(file.destination.lastPathComponent)"
            if existingBytes > 0 {
                writtenByIndex[idx] = existingBytes
                expectedByIndex[idx] = max(expectedByIndex[idx], existingBytes)
                await DownloadEngine.shared.markArtifactCompleted(
                    externalID: slug,
                    artifactID: artifactID,
                    finalBytes: existingBytes
                )
                continue
            }

            var req = URLRequest(url: file.url)
            withAuthHeaders(&req, token: token)
            let stagedDestination = file.destination.appendingPathExtension("download")
            registerBackgroundDestination(stagedDestination, for: slug)
            await DownloadEngine.shared.updateArtifactState(
                externalID: slug,
                artifactID: artifactID,
                state: .downloading,
                manualPause: false
            )

            _ = try await BackgroundDownloadManager.shared.download(
                request: req,
                to: stagedDestination,
                jobID: activeJobID,
                artifactID: artifactID,
                expectedSize: nil,
                progress: nil,
                progressBytes: { written, expected in
                    writtenByIndex[idx] = written
                    if expected > 0 { expectedByIndex[idx] = expected }

                    let aggregateWritten = writtenByIndex.reduce(0, +)
                    var aggregateExpected = zip(expectedByIndex, writtenByIndex).reduce(Int64(0)) { acc, pair in
                        let (exp, wr) = pair
                        return acc + max(exp, wr)
                    }
                    if aggregateExpected <= 0 { aggregateExpected = max(1, aggregateWritten) }

                    let now = Date()
                    let dt = max(0.001, now.timeIntervalSince(lastSampleTime))
                    let speed = Double(max(0, aggregateWritten - lastAggregateBytes)) / dt
                    lastAggregateBytes = aggregateWritten
                    lastSampleTime = now

                    let progress = min(1, max(0, Double(aggregateWritten) / Double(aggregateExpected)))
                    self.queue.sync { self.progressMap[slug] = progress }
                    continuation.yield(.progress(progress, aggregateWritten, aggregateExpected, speed))
                    Task {
                        await DownloadEngine.shared.updateArtifactProgressLive(
                            externalID: slug,
                            artifactID: artifactID,
                            written: written,
                            expected: expected > 0 ? expected : nil
                        )
                    }
                }
            )
            try finalizeStagedDownload(from: stagedDestination, to: file.destination)
            await DownloadEngine.shared.markArtifactCompleted(
                externalID: slug,
                artifactID: artifactID,
                finalBytes: readFileSize(file.destination)
            )
        }

        let finalModelURL = primary.destination
        let finalSize = readFileSize(finalModelURL)
        continuation.yield(.progress(1, max(1, finalSize), max(1, finalSize), 0))
        continuation.yield(.verifying)

        let installed = InstalledModel(
            modelID: entry.modelID,
            quantLabel: entry.quantization,
            url: finalModelURL,
            format: .et,
            sizeBytes: finalSize,
            lastUsed: nil,
            installDate: Date(),
            checksum: nil,
            isFavourite: false,
            totalLayers: 0,
            isMultimodal: entry.isVision || files.contains(where: { $0.key.lowercased().contains("projector") }),
            isToolCapable: true,
            moeInfo: nil
        )
        continuation.yield(.finished(installed))
    }

    /// Normalizes ET bundle URLs that may point to inner files rather than the bundle root
    /// and updates persisted selections when needed. This is a best-effort no-op when paths
    /// are already canonical.
    static func sanitizeBundleIfNeeded(at url: URL) {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL

        // If the provided URL is inside a "*.bundle" directory, prefer the bundle root.
        func bundleRoot(for url: URL) -> URL? {
            let parent = url.deletingLastPathComponent()
            if parent.pathExtension.lowercased() == "bundle" { return parent }
            return nil
        }

        // Compute preferred target
        let preferred: URL
        if let root = bundleRoot(for: fixed) {
            preferred = root
        } else if fixed.pathExtension.lowercased() == "bundle" {
            preferred = fixed
        } else {
            preferred = fixed
        }

        // If the path changed and the old selection matches startup preferences, update it.
        if preferred != fixed {
            StartupPreferencesStore.updateLocalPath(from: fixed.path, to: preferred.path)
        }

        // If the preferred is a bundle but exists as a file while a directory with the same
        // name exists, prefer the directory by updating defaults.
        if preferred.pathExtension.lowercased() == "bundle" {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: preferred.path, isDirectory: &isDir)
            if exists && !isDir.boolValue {
                // Check if a directory with the same name already exists (edge case after migrations)
                // Nothing actionable without moving files; keep this as a no-op to avoid data loss.
                return
            }
        }
    }
}
