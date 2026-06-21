// DatasetRetriever.swift
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

enum DatasetRetrievalMode: String, CaseIterable, Identifiable {
    case focused
    case balanced
    case broad

    var id: String { rawValue }

    static let defaultValue: DatasetRetrievalMode = .balanced

    static func from(_ rawValue: String) -> DatasetRetrievalMode {
        DatasetRetrievalMode(rawValue: rawValue) ?? defaultValue
    }

    /// The similarity floor this mode applies on top of the user's base
    /// threshold. Focused keeps it strict; Balanced and Broad progressively
    /// loosen it for higher recall. This is the single source of truth shared
    /// by the retriever and the Settings UI so the "effective threshold" shown
    /// to the user always matches actual retrieval behavior.
    func effectiveThreshold(base: Float) -> Float {
        let clamped = min(max(base, 0), 1)
        switch self {
        case .focused: return clamped
        case .balanced: return max(0, clamped - 0.10)
        case .broad: return max(0, clamped - 0.20)
        }
    }
}

/// Handles building and querying simple embedding indexes for datasets.
actor DatasetRetriever {
    static let shared = DatasetRetriever()

    private let indexingDatasetIDPersistedKey = "indexingDatasetIDPersisted"
    private let supportedExtensions = DatasetFileSupport.supportedExtensions

    private struct Chunk: Codable {
        let text: String
        let vector: [Float]
        let source: String?
    }

    private struct DiscoveredFile {
        let url: URL
        let relativePath: String
        let ext: String
    }

    private actor WarmUpPhaseState {
        private var phase: EmbeddingWarmUpPhase = .loadingModel

        func set(_ phase: EmbeddingWarmUpPhase) {
            self.phase = phase
        }

        func snapshot() -> EmbeddingWarmUpPhase {
            phase
        }
    }

    private var cache: [String: [Chunk]] = [:]

    /// Drops any in-memory chunk cache. Safe to call on memory pressure; on-disk vectors remain.
    func clearCache() {
        cache.removeAll(keepingCapacity: false)
    }

    static func titleForEmbedding(source: String?, datasetTitle: String?) -> String? {
        if let sourceTitle = normalizedEmbeddingTitle(fromSourceMarker: source) {
            return sourceTitle
        }
        return normalizedEmbeddingTitle(datasetTitle)
    }

    private static func normalizedEmbeddingTitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedEmbeddingTitle(fromSourceMarker source: String?) -> String? {
        guard let source = normalizedEmbeddingTitle(source) else { return nil }
        let lastPath = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
        let cleaned = lastPath
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Purges any in-memory and on-disk embeddings for a dataset ID
    func purge(datasetID: String) {
        cache[datasetID] = nil
        var base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        base.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        for comp in datasetID.split(separator: "/").map(String.init) {
            base.appendPathComponent(comp, isDirectory: true)
        }
        DatasetIndexIO.clearReadyIndex(at: base)
    }

    private func loadPersistedChunksIfValid(for dataset: LocalDataset) -> [Chunk]? {
        guard DatasetIndexIO.hasValidIndex(at: dataset.url) else { return nil }
        let file = DatasetIndexIO.vectorsURL(for: dataset.url)
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([Chunk].self, from: data),
              !decoded.isEmpty else {
            return nil
        }
        // Indexes built before a filename became internal (e.g. the enterprise
        // governance manifest) can still carry its chunks; drop them on load.
        let chunks = decoded.filter { chunk in
            guard let source = chunk.source else { return true }
            return !DatasetStorage.isInternalRelativePath(source)
        }
        return chunks.isEmpty ? nil : chunks
    }

    private func persist(_ chunks: [Chunk], for dataset: LocalDataset) {
        guard !chunks.isEmpty,
              let data = try? JSONEncoder().encode(chunks) else {
            return
        }
        try? data.write(to: DatasetIndexIO.vectorsURL(for: dataset.url), options: .atomic)
        var report = DatasetIndexIO.loadReport(from: dataset.url) ?? .empty
        report.failureReason = nil
        DatasetIndexIO.writeReport(report, to: dataset.url)
        DatasetIndexIO.writeMetadata(DatasetIndexMetadata(chunkCount: chunks.count), to: dataset.url)
    }

    private func recordFailure(for dataset: LocalDataset, reason: String) {
        cache[dataset.datasetID] = nil
        DatasetIndexIO.clearReadyIndex(at: dataset.url)
        var report = DatasetIndexIO.loadReport(from: dataset.url) ?? .empty
        report.failureReason = reason
        DatasetIndexIO.writeReport(report, to: dataset.url)
    }

    private func validateChunks(_ chunks: [Chunk], for dataset: LocalDataset) throws -> [Chunk] {
        guard !chunks.isEmpty else {
            let reason = String(localized: "No retrievable text found in imported files", locale: LocalizationManager.preferredLocale())
            recordFailure(for: dataset, reason: reason)
            throw NoemaError.chunkingFailed(reason: reason)
        }
        return chunks
    }

    private func supportedFiles(in dataset: LocalDataset) -> [DiscoveredFile] {
        let fm = FileManager.default
        var discovered: [DiscoveredFile] = []
        if let enumerator = fm.enumerator(at: dataset.url, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let url = enumerator.nextObject() as? URL {
                let relativePath = DatasetPathing.relativePath(for: url, under: dataset.url)
                if DatasetStorage.isInternalRelativePath(relativePath) { continue }
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile != true {
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }
                discovered.append(
                    DiscoveredFile(
                        url: url,
                        relativePath: relativePath,
                        ext: ext
                    )
                )
            }
        }
        return discovered.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private func embedPreparedText(
        _ text: String,
        for dataset: LocalDataset,
        progress: (@MainActor @Sendable (DatasetProcessingStatus) -> Void)? = nil
    ) async throws -> [Chunk] {
        let result = try await embedFromText(
            text,
            datasetID: dataset.datasetID,
            datasetTitle: embeddingDatasetTitle(for: dataset)
        ) { frac, phase in
            if let progress {
                Task { @MainActor in
                    progress(DatasetProcessingStatus(stage: .embedding, progress: frac, message: phase, etaSeconds: nil))
                }
            }
        }
        let validated = try validateChunks(result, for: dataset)
        cache[dataset.datasetID] = validated
        persist(validated, for: dataset)
        return validated
    }

    /// Returns the cached chunks for a dataset, computing them if needed.
    private func chunks(
        for dataset: LocalDataset,
        progress: (@MainActor @Sendable (DatasetProcessingStatus) -> Void)? = nil
    ) async throws -> [Chunk] {
        if dataset.requiresReindex {
            Task { await logger.log("[RAG] Refusing to use stale index for dataset: \(dataset.datasetID)") }
            throw NoemaError.vectorDatabaseCorrupted(dataset: dataset.datasetID)
        }
        if let cached = cache[dataset.datasetID] { return cached }
        if let decoded = loadPersistedChunksIfValid(for: dataset) {
            cache[dataset.datasetID] = decoded
            return decoded
        }

        Task { await logger.log("[RAG] Creating embeddings for dataset on-demand: \(dataset.datasetID)") }

        let compactURL = DatasetIndexIO.compactURL(for: dataset.url)
        if let compactText = DatasetTextReader.readString(from: compactURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !compactText.isEmpty {
            return try await embedPreparedText(compactText, for: dataset, progress: progress)
        }

        let extractedURL = DatasetIndexIO.extractedURL(for: dataset.url)
        if !FileManager.default.fileExists(atPath: extractedURL.path) &&
            !FileManager.default.fileExists(atPath: compactURL.path) {
            Task { await logger.log("[RAG] No extracted text found, extracting from dataset files: \(dataset.datasetID)") }
            await prepare(dataset: dataset, progress: progress)
        }

        if let decoded = loadPersistedChunksIfValid(for: dataset) {
            cache[dataset.datasetID] = decoded
            return decoded
        }

        if let compactText = DatasetTextReader.readString(from: compactURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !compactText.isEmpty {
            return try await embedPreparedText(compactText, for: dataset, progress: progress)
        }
        if let extractedText = DatasetTextReader.readString(from: extractedURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !extractedText.isEmpty {
            return try await embedPreparedText(extractedText, for: dataset, progress: progress)
        }

        let fallbackText = await fetchAllContent(for: dataset).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackText.isEmpty else {
            let reason = "No retrievable text found in imported files"
            recordFailure(for: dataset, reason: reason)
            throw NoemaError.chunkingFailed(reason: reason)
        }
        return try await embedPreparedText(fallbackText, for: dataset, progress: progress)
    }

    /// Precomputes text extraction and compression for the dataset, and optionally proceeds to embeddings.
    /// When `pauseBeforeEmbedding` is true, this function will stop after compression and emit an `.embedding`
    /// status with 0% progress, leaving it to the caller to trigger the embedding step via `embedPrepared`.
    func prepare(
        dataset: LocalDataset,
        pauseBeforeEmbedding: Bool = false,
        progress: (@MainActor @Sendable (DatasetProcessingStatus) -> Void)? = nil
    ) async {
        // Persist indexing flag so tool gate can disable web search while indexing runs
        setIndexingDatasetIDPersisted(dataset.datasetID)
        defer {
            // Always clear the indexing flag, including when we pause awaiting user confirmation.
            setIndexingDatasetIDPersisted("")
        }
        // Only extract and compress text during indexing - no embedding model loading
        Task { await logger.log("[RAG] prepare.start dataset=\(dataset.datasetID)") }
        let dir = dataset.url
        let extractedURL = DatasetIndexIO.extractedURL(for: dir)
        let compactURL = DatasetIndexIO.compactURL(for: dir)

        if DatasetIndexIO.hasValidIndex(at: dir) {
            Task { await logger.log("[RAG] vectors.exist path=\(DatasetStorage.vectorsFilename) - indexing complete") }
            if let progress {
                await progress(
                    DatasetProcessingStatus(
                        stage: .completed,
                        progress: 1.0,
                        message: String(localized: "Ready for use", locale: LocalizationManager.preferredLocale()),
                        etaSeconds: 0
                    )
                )
            }
            return
        }

        if DatasetIndexIO.hasIndexArtifacts(at: dir) {
            DatasetIndexIO.clearReadyIndex(at: dir)
            cache[dataset.datasetID] = nil
        }

        do {
            if !FileManager.default.fileExists(atPath: compactURL.path) {
                Task { await logger.log("[RAG] extract.begin") }
                if let progress {
                    await progress(
                        DatasetProcessingStatus(
                            stage: .extracting,
                            progress: 0.0,
                            message: String(localized: "Extracting text from files (images ignored)", locale: LocalizationManager.preferredLocale()),
                            etaSeconds: nil
                        )
                    )
                }
                let t0 = Date()
                let report = try await extractPlainText(from: dataset, writingTo: extractedURL) { frac in
                    Task { @MainActor in
                        let dt = Date().timeIntervalSince(t0)
                        let eta = frac > 0 ? dt * (1.0 / frac - 1.0) : nil
                        progress?(
                            DatasetProcessingStatus(
                                stage: .extracting,
                                progress: frac,
                                message: String(localized: "Extracting text from files (images ignored)", locale: LocalizationManager.preferredLocale()),
                                etaSeconds: eta
                            )
                        )
                    }
                }
                DatasetIndexIO.writeReport(report, to: dir)
                let extractedBytes = (try? FileManager.default.attributesOfItem(atPath: extractedURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                Task { await logger.log("[RAG] extract.done size=\(extractedBytes)B dt=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s") }

                if let progress {
                    await progress(
                        DatasetProcessingStatus(
                            stage: .compressing,
                            progress: 0.0,
                            message: String(localized: "Normalizing whitespace and merging paragraphs", locale: LocalizationManager.preferredLocale()),
                            etaSeconds: nil
                        )
                    )
                }
                let c0 = Date()
                try compactText(from: extractedURL, writingTo: compactURL) { frac in
                    Task { @MainActor in
                        let dt = Date().timeIntervalSince(c0)
                        let eta = frac > 0 ? dt * (1.0 / frac - 1.0) : nil
                        progress?(
                            DatasetProcessingStatus(
                                stage: .compressing,
                                progress: frac,
                                message: String(localized: "Normalizing whitespace and merging paragraphs", locale: LocalizationManager.preferredLocale()),
                                etaSeconds: eta
                            )
                        )
                    }
                }
                let compactBytes = (try? FileManager.default.attributesOfItem(atPath: compactURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                Task { await logger.log("[RAG] compress.done size=\(compactBytes)B dt=\(String(format: "%.2f", Date().timeIntervalSince(c0)))s") }
            }

            let preparedText = [
                DatasetTextReader.readString(from: compactURL),
                DatasetTextReader.readString(from: extractedURL)
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            if preparedText.isEmpty {
                let reason = String(localized: "No retrievable text found in imported files", locale: LocalizationManager.preferredLocale())
                recordFailure(for: dataset, reason: reason)
                if let progress {
                    await progress(DatasetProcessingStatus(stage: .failed, progress: 0.0, message: reason, etaSeconds: nil))
                }
                return
            }

            // If caller asked to pause, emit an embedding gate status; otherwise continue to embeddings.
            if pauseBeforeEmbedding {
                if let progress {
                    await progress(
                        DatasetProcessingStatus(
                            stage: .embedding,
                            progress: 0.0,
                            message: String(localized: "Ready to compute embeddings. Tap Confirm to start. For best performance, plug in your device.", locale: LocalizationManager.preferredLocale()),
                            etaSeconds: nil
                        )
                    )
                }
                Task { await logger.log("[RAG] prepare.paused - awaiting user confirmation for embeddings") }
                return
            } else {
                // Proceed to embedding immediately so indexing completes in one go
                try await embedPrepared(dataset: dataset, progress: progress)
            }
        } catch {
            Task { await logger.log("[RAG] ❌ prepare.failed error=\(error.localizedDescription)") }
            if !(error is CancellationError) {
                recordFailure(for: dataset, reason: error.localizedDescription)
            }
            if let progress {
                if error is CancellationError {
                    await progress(
                        DatasetProcessingStatus(
                            stage: .failed,
                            progress: 0.0,
                            message: String(localized: "Stopped", locale: LocalizationManager.preferredLocale()),
                            etaSeconds: nil
                        )
                    )
                } else {
                    await progress(DatasetProcessingStatus(stage: .failed, progress: 0.0, message: error.localizedDescription, etaSeconds: nil))
                }
            }
        }
    }

    private func setIndexingDatasetIDPersisted(_ value: String) {
        let key = indexingDatasetIDPersistedKey
        if Thread.isMainThread {
            UserDefaults.standard.set(value, forKey: key)
            return
        }

        DispatchQueue.main.sync {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// Performs the embedding step assuming extraction and compression have completed.
    /// Writes vectors to disk and reports progress via the provided closure.
    func embedPrepared(
        dataset: LocalDataset,
        progress: (@MainActor @Sendable (DatasetProcessingStatus) -> Void)? = nil
    ) async throws {
        let dir = dataset.url
        let extractedURL = DatasetIndexIO.extractedURL(for: dir)
        let compactURL = DatasetIndexIO.compactURL(for: dir)

        // Initial warmup phase so the user sees progress while the embedding model loads kernels.
        let warmUpFraction = 0.1
        let loadWarmUpFraction = 0.05
        if let progress {
            await progress(
                DatasetProcessingStatus(
                    stage: .embedding,
                    progress: 0.0,
                    message: String(localized: "Warming up embedding model…", locale: LocalizationManager.preferredLocale()),
                    etaSeconds: nil
                )
            )
        }
        let phaseState = WarmUpPhaseState()
        let warmupTicker = Task.detached(priority: .utility) { [progress] in
            var publishedProgress: Double = 0.0
            while !Task.isCancelled {
                let phase = await phaseState.snapshot()
                let target: Double
                let message: String
                switch phase {
                case .loadingModel:
                    target = loadWarmUpFraction
                    message = String(localized: "Warming up embedding model…", locale: LocalizationManager.preferredLocale())
                case .primingFirstPass:
                    target = warmUpFraction
                    message = String(localized: "Priming first embedding pass…", locale: LocalizationManager.preferredLocale())
                }

                if publishedProgress < target {
                    publishedProgress = min(target, publishedProgress + 0.005)
                    if let progress {
                        await MainActor.run {
                            progress(
                                DatasetProcessingStatus(
                                    stage: .embedding,
                                    progress: publishedProgress,
                                    message: message,
                                    etaSeconds: nil
                                )
                            )
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await EmbeddingModel.shared.warmUp { phase in
            Task {
                await phaseState.set(phase)
            }
        }
        warmupTicker.cancel()
        _ = await warmupTicker.result
        if Task.isCancelled { throw CancellationError() }

        let text: String
        if let s = DatasetTextReader.readString(from: compactURL) {
            text = s
        } else if let s = DatasetTextReader.readString(from: extractedURL) {
            text = s
        } else {
            text = await fetchAllContent(for: dataset)
        }
        if let progress {
            await progress(
                DatasetProcessingStatus(
                    stage: .embedding,
                    progress: warmUpFraction,
                    message: String(localized: "Preparing chunks", locale: LocalizationManager.preferredLocale()),
                    etaSeconds: nil
                )
            )
        }
        let textToEmbed = text
        if Task.isCancelled { throw CancellationError() }
        let startTime = Date()
        let finalChunks = try await embedFromText(
            textToEmbed,
            datasetID: dataset.datasetID,
            datasetTitle: embeddingDatasetTitle(for: dataset)
        ) { frac, phase in
            Task { @MainActor in
                // Rough ETA estimate using elapsed time and progress slope
                let elapsed = Date().timeIntervalSince(startTime)
                let eta: Double? = (frac > 0.01) ? max(0, elapsed * (1.0 / frac - 1.0)) : nil
                let adjusted = warmUpFraction + frac * (1 - warmUpFraction)
                progress?(DatasetProcessingStatus(stage: .embedding, progress: adjusted, message: phase, etaSeconds: eta))
            }
        }
        if Task.isCancelled { throw CancellationError() }
        let validated = try validateChunks(finalChunks, for: dataset)
        cache[dataset.datasetID] = validated
        persist(validated, for: dataset)
        if Task.isCancelled { throw CancellationError() }
        Task { await logger.log("[RAG] embedPrepared.done - embeddings complete") }
        // After finishing embeddings, if no other part of the app needs the
        // embedder, unload it to free CPU/RAM. We only unload when there are
        // zero active operations to avoid races with concurrent embeddings.
        Task.detached {
            // small delay to allow any immediate follow-up operations to start
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await EmbeddingModel.shared.activeOperationsCount == 0 {
                await EmbeddingModel.shared.unload()
            }
        }
        if Task.isCancelled { throw CancellationError() }
        if let progress {
            await progress(
                DatasetProcessingStatus(
                    stage: .completed,
                    progress: 1.0,
                    message: String(localized: "Ready for use", locale: LocalizationManager.preferredLocale()),
                    etaSeconds: 0
                )
            )
        }
    }

    // MARK: - Pipeline helpers

    private func extractPlainText(
        from dataset: LocalDataset,
        writingTo outputURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> DatasetIndexReport {
        let fm = FileManager.default
        let files = supportedFiles(in: dataset)
        let pdfs = files.filter { $0.ext == "pdf" }
        let epubs = files.filter { $0.ext == "epub" }
        let textFiles = files.filter { $0.ext != "pdf" && $0.ext != "epub" }

        _ = fm.createFile(atPath: outputURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outputURL)
        defer { out.closeFile() }

        func write(_ string: String) throws {
            guard let data = string.data(using: .utf8) else { return }
            out.write(data)
        }

        func writeProcessedFile(relativePath: String, text: String) throws {
            try write(DatasetSourceMarkers.marker(forRelativePath: relativePath) + "\n")
            try write(text)
            try write("\n\n")
        }

        var report = DatasetIndexReport.empty
        let totalUnits = max(files.count, 1)
        var completedUnits = 0

        func advanceProgress() {
            completedUnits += 1
            onProgress(min(0.95, Double(completedUnits) / Double(totalUnits)))
        }

        #if canImport(PDFKit)
        for file in pdfs {
            if Task.isCancelled { throw CancellationError() }
            guard let doc = PDFKit.PDFDocument(url: file.url) else {
                report.skippedFiles.append(file.relativePath)
                advanceProgress()
                continue
            }

            var parts: [String] = []
            for pageIndex in 0..<doc.pageCount {
                if Task.isCancelled { throw CancellationError() }
                if let page = doc.page(at: pageIndex),
                   let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    parts.append(text)
                }
            }
            let text = parts.joined(separator: "\n")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.emptyFiles.append(file.relativePath)
            } else {
                try writeProcessedFile(relativePath: file.relativePath, text: text)
                report.processedFiles.append(file.relativePath)
            }
            advanceProgress()
        }
        #else
        for file in pdfs {
            if Task.isCancelled { throw CancellationError() }
            report.skippedFiles.append(file.relativePath)
            advanceProgress()
        }
        #endif

        for file in epubs {
            if Task.isCancelled { throw CancellationError() }
            let extracted = EPUBTextExtractor.extractText(from: file.url)
            let text = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                report.emptyFiles.append(file.relativePath)
            } else {
                try writeProcessedFile(relativePath: file.relativePath, text: text)
                report.processedFiles.append(file.relativePath)
            }
            advanceProgress()
        }

        for file in textFiles {
            if Task.isCancelled { throw CancellationError() }
            guard let raw = DatasetTextReader.readString(from: file.url) else {
                report.skippedFiles.append(file.relativePath)
                advanceProgress()
                continue
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                report.emptyFiles.append(file.relativePath)
            } else {
                try writeProcessedFile(relativePath: file.relativePath, text: raw)
                report.processedFiles.append(file.relativePath)
            }
            advanceProgress()
        }

        if Task.isCancelled { throw CancellationError() }
        onProgress(1.0)
        return report
    }

    private func compactText(from inputURL: URL, writingTo outputURL: URL, onProgress: (Double) -> Void) throws {
        let fm = FileManager.default
        let totalBytes: Int64 = (try? fm.attributesOfItem(atPath: inputURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        // Truncate/create output file
        _ = fm.createFile(atPath: outputURL.path, contents: nil)

        let input = try FileHandle(forReadingFrom: inputURL)
        defer { input.closeFile() }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { output.closeFile() }

        func writeLine(_ s: String) throws {
            guard let data = (s + "\n").data(using: .utf8) else { return }
            output.write(data)
        }

        func normalizeInlineWhitespace(_ s: String) -> String {
            var out = ""
            out.reserveCapacity(s.count)
            var previousWasSpace = false
            for scalar in s.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if !previousWasSpace {
                        out.append(" ")
                        previousWasSpace = true
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                    previousWasSpace = false
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        let chunkSize = 64 * 1024
        var bytesRead: Int64 = 0
        var lastBlank = false
        var lastProgressBytes: Int64 = 0

        func handleLine(_ raw: String) throws {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !lastBlank {
                    try writeLine("")
                    lastBlank = true
                }
                return
            }
            let normalized = normalizeInlineWhitespace(trimmed)
            try writeLine(normalized)
            lastBlank = false
        }

        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk = input.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
                try handleLine(line)
            }

            // Progress: based on bytes consumed.
            if totalBytes > 0, bytesRead - lastProgressBytes >= 512 * 1024 {
                lastProgressBytes = bytesRead
                onProgress(min(0.99, Double(bytesRead) / Double(totalBytes)))
            }
        }

        if !buffer.isEmpty {
            let line = String(data: buffer, encoding: .utf8) ?? String(decoding: buffer, as: UTF8.self)
            try handleLine(line)
        }

        onProgress(1.0)
    }

    private func embedFromText(
        _ text: String,
        datasetID: String? = nil,
        datasetTitle: String? = nil,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [Chunk] {
        // Chunk by token cap without embedding per chunk; batch-embed at the end.
        var chunkTexts: [String] = []
        var chunkSources: [String?] = []
        var chunkTitles: [String?] = []
        var buffer = ""
        var currentSource: String? = nil
        // Stale extracted/compact text can still carry sections for files that
        // are now internal (e.g. the enterprise governance manifest); those
        // sections must never be embedded.
        var skippingInternalSource = false

        func parseSourceMarker(_ line: String) -> String? {
            DatasetSourceMarkers.sourcePath(fromLine: line)
        }
        let lines = text.components(separatedBy: .newlines)
        let total = max(lines.count, 1)
        var lastProgressEmit = Date(timeIntervalSince1970: 0)
        let maxTokensPerChunk = DatasetChunkingPolicy.maxTokensPerChunk
        Task.detached { await logger.log("[RAG] Using maxTokensPerChunk=\(maxTokensPerChunk) for chunking") }

        func splitLongText(_ s: String, maxChars: Int) -> [String] {
            var out: [String] = []
            var remaining = s
            while !remaining.isEmpty {
                if remaining.count <= maxChars { out.append(remaining); break }
                // Try to split on the last sentence boundary or space before the limit
                let idx = remaining.index(remaining.startIndex, offsetBy: maxChars)
                var splitIndex = remaining[..<idx].lastIndex(of: "\n")
                    ?? remaining[..<idx].lastIndex(of: ".")
                    ?? remaining[..<idx].lastIndex(of: " ")
                if splitIndex == nil { splitIndex = idx }
                let part = String(remaining[..<splitIndex!]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { out.append(part) }
                remaining = String(remaining[splitIndex!..<remaining.endIndex])
                remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return out
        }

        func flushBuffer() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let chunkTitle = DatasetRetriever.titleForEmbedding(source: currentSource, datasetTitle: datasetTitle)
                // Ensure we don't emit chunks that exceed the embedder's character limit
                let maxCharsPerChunk = 8000
                if trimmed.count <= maxCharsPerChunk {
                    chunkTexts.append(trimmed)
                    chunkSources.append(currentSource)
                    chunkTitles.append(chunkTitle)
                } else {
                    let parts = splitLongText(trimmed, maxChars: maxCharsPerChunk)
                    for p in parts {
                        chunkTexts.append(p)
                        chunkSources.append(currentSource)
                        chunkTitles.append(chunkTitle)
                    }
                }
            }
            buffer = ""
        }

        for (idx, line) in lines.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = parseSourceMarker(t) {
                flushBuffer()
                currentSource = marker
                skippingInternalSource = DatasetStorage.isInternalRelativePath(marker)
                continue
            }
            if skippingInternalSource { continue }
            if t.isEmpty {
                flushBuffer()
            } else {
                let prospective = buffer.isEmpty ? t : buffer + " " + t
                let tok = await EmbeddingModel.shared.countTokens(prospective)
                if tok > maxTokensPerChunk {
                    flushBuffer()
                    buffer = t
                } else {
                    buffer = prospective
                }
            }
            if idx % 50 == 0 {
                let now = Date()
                let frac = Double(idx + 1) / Double(total)
                onProgress(frac * 0.5, String(localized: "Preparing chunks", locale: LocalizationManager.preferredLocale())) // first half for chunking
                if now.timeIntervalSince(lastProgressEmit) > 1.0 {
                    lastProgressEmit = now
                    Task { await logger.log(String(format: "[RAG] embed.chunk %.0f%%", frac * 100)) }
                }
            }
        }
        flushBuffer()
        // Token-safety pass: ensure no chunk exceeds token cap; split by tokens when needed
        let tokenSafetyChunksCount = chunkTexts.count
        let tokenSafetyMaxTokens = maxTokensPerChunk
        Task.detached { await logger.log("[RAG] token_safety_pass start chunks=\(tokenSafetyChunksCount) maxTokens=\(tokenSafetyMaxTokens)") }
        func splitLongByTokens(_ s: String, maxTokens: Int) async -> [String] {
            var remaining = s.trimmingCharacters(in: .whitespacesAndNewlines)
            var out: [String] = []
            while !remaining.isEmpty {
                let totalTokens = await EmbeddingModel.shared.countTokens(remaining)
                if totalTokens <= maxTokens { out.append(remaining); break }
                // Binary-search for largest prefix within token limit
                var low = 0
                var high = remaining.count
                var best = 0
                while low < high {
                    let mid = (low + high) / 2
                    let idx = remaining.index(remaining.startIndex, offsetBy: mid)
                    let prefix = String(remaining[..<idx])
                    let t = await EmbeddingModel.shared.countTokens(prefix)
                    if t <= maxTokens { best = mid; low = mid + 1 } else { high = mid }
                }
                if best == 0 {
                    // Fallback to char-based split
                    let parts = splitLongText(remaining, maxChars: 4000)
                    if parts.isEmpty { break }
                    out.append(parts[0])
                    remaining = parts.dropFirst().joined(separator: " ")
                    continue
                }
                let splitIdx = remaining.index(remaining.startIndex, offsetBy: best)
                let part = String(remaining[..<splitIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { out.append(part) }
                remaining = String(remaining[splitIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return out
        }

        var tokenSafeTexts: [String] = []
        var tokenSafeSources: [String?] = []
        var tokenSafeTitles: [String?] = []
        for i in chunkTexts.indices {
            if Task.isCancelled { throw CancellationError() }
            let c = chunkTexts[i]
            let source = chunkSources.indices.contains(i) ? chunkSources[i] : nil
            let title = chunkTitles.indices.contains(i) ? chunkTitles[i] : nil
            let tok = await EmbeddingModel.shared.countTokens(c)
            if tok <= maxTokensPerChunk {
                tokenSafeTexts.append(c)
                tokenSafeSources.append(source)
                tokenSafeTitles.append(title)
            } else {
                Task.detached { await logger.log("[RAG] Chunk too large (\(tok) tokens), splitting by tokens") }
                let parts = await splitLongByTokens(c, maxTokens: maxTokensPerChunk)
                for p in parts {
                    tokenSafeTexts.append(p)
                    tokenSafeSources.append(source)
                    tokenSafeTitles.append(title)
                    Task.detached {
                        let tcount = await EmbeddingModel.shared.countTokens(p)
                        await logger.log("[RAG] Added split part chars=\(p.count) tokens=\(tcount)")
                    }
                }
            }
        }
        chunkTexts = tokenSafeTexts
        chunkSources = tokenSafeSources
        chunkTitles = tokenSafeTitles
        // Ensure we show an immediate hand-off to embedding phase at 50%
        let initialEmbeddingMessage: String = {
            guard !chunkTexts.isEmpty else {
                return String(localized: "Embedding", locale: LocalizationManager.preferredLocale())
            }
            return String.localizedStringWithFormat(
                String(localized: "Embedding chunk %d of %d…", locale: LocalizationManager.preferredLocale()),
                1,
                chunkTexts.count
            )
        }()
        onProgress(0.50, initialEmbeddingMessage)

        // Batch embed the prepared chunks, streaming per-item progress to UI
        var batched: [Chunk] = []
        if !chunkTexts.isEmpty {
            let batchSize = 8
            var produced = 0
            let totalCount = chunkTexts.count
            for i in stride(from: 0, to: chunkTexts.count, by: batchSize) {
                if Task.isCancelled { throw CancellationError() }
                let j = min(i + batchSize, chunkTexts.count)
                let sliceTexts = Array(chunkTexts[i..<j])
                let sliceTitles: [String?]
                let sliceSources: [String?]
                if chunkSources.count >= j {
                    sliceSources = Array(chunkSources[i..<j])
                } else if chunkSources.count > i {
                    sliceSources = Array(chunkSources[i...])
                } else {
                    sliceSources = []
                }
                if chunkTitles.count >= j {
                    sliceTitles = Array(chunkTitles[i..<j])
                } else if chunkTitles.count > i {
                    sliceTitles = Array(chunkTitles[i...])
                } else {
                    sliceTitles = []
                }
                let sliceDocuments = sliceTexts.enumerated().map { idx, value in
                    EmbeddingDocumentInput(
                        text: value,
                        title: sliceTitles.indices.contains(idx) ? sliceTitles[idx] : nil
                    )
                }
                // Stream progress within the batch so UI updates at each item completion
                let baseProduced = produced
                let embedSlice: () async -> [[Float]] = {
                    await EmbeddingModel.shared.embedDocumentsWithProgress(sliceDocuments) { event in
                        switch event {
                        case .heartbeat(let current, _):
                            let overallCurrent = min(totalCount, baseProduced + current)
                            let frac = Double(baseProduced) / Double(totalCount)
                            onProgress(
                                0.5 + frac * 0.5,
                                String.localizedStringWithFormat(
                                    String(localized: "Embedding chunk %d of %d…", locale: LocalizationManager.preferredLocale()),
                                    overallCurrent,
                                    totalCount
                                )
                            )
                        case .itemCompleted(let done, _):
                            let overallDone = baseProduced + done
                            let frac = Double(overallDone) / Double(totalCount)
                            onProgress(0.5 + frac * 0.5, String(localized: "Embedding", locale: LocalizationManager.preferredLocale()))
                        }
                    }
                }

                // iOS rejects Metal work while the app is backgrounded (screen
                // locked / app switched), and an interrupted command buffer
                // poisons the backend. Pause at this boundary, recover the
                // backend, and retry the same batch instead of silently
                // dropping its chunks.
                var failedAttempts = 0
                var vecs: [[Float]] = []
                while true {
                    if Task.isCancelled { throw CancellationError() }
                    if EmbeddingForegroundGate.shared.isBackgrounded {
                        let frac = Double(baseProduced) / Double(totalCount)
                        onProgress(
                            0.5 + frac * 0.5,
                            String(localized: "Paused — return to Noema to continue", locale: LocalizationManager.preferredLocale())
                        )
                        Task { await logger.log("[RAG] embed paused in background at chunk \(baseProduced)/\(totalCount)") }
                        try await EmbeddingForegroundGate.shared.waitUntilForeground()
                        await EmbeddingModel.shared.recoverAfterInterruption()
                        onProgress(
                            0.5 + frac * 0.5,
                            String.localizedStringWithFormat(
                                String(localized: "Embedding chunk %d of %d…", locale: LocalizationManager.preferredLocale()),
                                min(totalCount, baseProduced + 1),
                                totalCount
                            )
                        )
                        Task { await logger.log("[RAG] embed resumed after foreground + backend recovery") }
                    }
                    vecs = await embedSlice()
                    let succeeded = vecs.count == sliceTexts.count && !vecs.contains(where: { $0.isEmpty })
                    if succeeded { break }
                    if EmbeddingForegroundGate.shared.isBackgrounded {
                        // Interrupted by backgrounding: loop back to pause and retry.
                        continue
                    }
                    failedAttempts += 1
                    if failedAttempts >= 2 { break }
                    // The backend may still be poisoned from an earlier
                    // interruption; rebuild it once before giving up.
                    await EmbeddingModel.shared.recoverAfterInterruption()
                }
                if vecs.count == sliceTexts.count {
                    for idx in 0..<sliceTexts.count {
                        let t = sliceTexts[idx]
                        let source = sliceSources.indices.contains(idx) ? sliceSources[idx] : nil
                        let v = vecs[idx]
                        if !v.isEmpty && v.allSatisfy({ $0.isFinite && !$0.isNaN }) {
                            batched.append(Chunk(text: t, vector: v, source: source))
                        } else {
                            Task { await logger.log("[RAG] ⚠️ Skipping invalid/empty vector for a batch item") }
                            let ds = datasetID ?? "<unknown>"
                            Task { await writeEmbeddingFailureBackup(dataset: ds, source: source, text: t, reason: "invalid_batch_vector") }
                        }
                    }
                } else {
                    // Fallback per-item if batch failed or mismatched
                    for idx in 0..<sliceTexts.count {
                        let t = sliceTexts[idx]
                        let source = sliceSources.indices.contains(idx) ? sliceSources[idx] : nil
                        let document = EmbeddingDocumentInput(
                            text: t,
                            title: sliceTitles.indices.contains(idx) ? sliceTitles[idx] : nil
                        )
                        let v = await EmbeddingModel.shared.embedDocument(document)
                        if !v.isEmpty && v.allSatisfy({ $0.isFinite && !$0.isNaN }) {
                            batched.append(Chunk(text: t, vector: v, source: source))
                        } else {
                            let ds = datasetID ?? "<unknown>"
                            Task { await writeEmbeddingFailureBackup(dataset: ds, source: source, text: t, reason: "fallback_failed") }
                        }
                    }
                }
                produced += (j - i)
                let frac = Double(produced) / Double(totalCount)
                onProgress(0.5 + frac * 0.5, String(localized: "Embedding", locale: LocalizationManager.preferredLocale()))
                Task { await logger.log(String(format: "[RAG] embed.progress %.0f%%", (0.5 + frac * 0.5) * 100)) }
            }
        }
        onProgress(1.0, String(localized: "Embedding complete", locale: LocalizationManager.preferredLocale()))
        return batched
    }

    private func embeddingDatasetTitle(for dataset: LocalDataset) -> String? {
        if let stored = DatasetTextReader.readString(from: DatasetIndexIO.titleURL(for: dataset.url)),
           let normalized = DatasetRetriever.titleForEmbedding(source: nil, datasetTitle: stored) {
            return normalized
        }
        return DatasetRetriever.titleForEmbedding(source: nil, datasetTitle: dataset.name)
    }

    /// Write a compact backup of a failed chunk embedding to disk for inspection.
    private func writeEmbeddingFailureBackup(dataset: String, source: String?, text: String, reason: String) async {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var dir = docs.appendingPathComponent("EmbeddingFailures", isDirectory: true)
        dir.appendPathComponent(dataset, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let ts = formatter.string(from: Date())
        let safeReason = reason.replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
        let filename = "fail_\(ts)_\(safeReason).txt"
        let fileURL = dir.appendingPathComponent(filename)
        let cap = 16_000
        let trimmed = String(text.prefix(cap))
        var content = "reason: \(reason)\nsource: \(source ?? "<unknown>")\ndataset: \(dataset)\n\n"
        content += trimmed
        do {
            try content.data(using: .utf8)?.write(to: fileURL)
            await logger.log("[RAG] Wrote embedding failure backup: \(fileURL.path)")
        } catch {
            await logger.log("[RAG] ⚠️ Failed to write embedding backup: \(error.localizedDescription)")
        }
    }

    private func preparedText(for dataset: LocalDataset) -> String? {
        let candidates = [
            DatasetIndexIO.compactURL(for: dataset.url),
            DatasetIndexIO.extractedURL(for: dataset.url),
        ]
        for url in candidates {
            guard let str = DatasetTextReader.readString(from: url) else { continue }
            // Strip sections for internal files (e.g. the enterprise governance
            // manifest) that older artifacts may still contain.
            let sanitized = DatasetSourceMarkers.strippingInternalSections(from: str)
            if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return sanitized
            }
        }

        return nil
    }

    private func lexicalScore(queryTokens: Set<String>, text: String) -> Float {
        if queryTokens.isEmpty { return 0 }
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        if words.isEmpty { return 0 }

        var hits = 0
        var seen = Set<String>()
        for word in words {
            let token = String(word)
            seen.insert(token)
            if queryTokens.contains(token) {
                hits += 1
            }
        }

        let jaccard = Float(hits) / Float(max(seen.count + queryTokens.count - hits, 1))
        let lengthBonus = min(Float(text.count) / 500.0, 1.0)
        return jaccard * 0.9 + lengthBonus * 0.1
    }

    private func queryTokens(for query: String) -> Set<String> {
        Set(
            query.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }

    private func expandedQuery(_ query: String, mode: DatasetRetrievalMode) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode != .focused else { return trimmed }

        let stopWords: Set<String> = [
            "about", "after", "also", "and", "are", "can", "could", "does", "for", "from",
            "has", "have", "how", "into", "its", "more", "not", "that", "the", "their",
            "there", "this", "was", "what", "when", "where", "which", "who", "why", "with",
            "would", "your"
        ]
        let keywords = trimmed.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        var seenKeywords = Set<String>()
        let uniqueKeywords = keywords.filter { seenKeywords.insert($0).inserted }
        let cappedKeywords = Array(uniqueKeywords.prefix(mode == .broad ? 16 : 10))
        guard !cappedKeywords.isEmpty else { return trimmed }

        let keywordLine = cappedKeywords.joined(separator: ", ")
        switch mode {
        case .focused:
            return trimmed
        case .balanced:
            return "\(trimmed)\n\nKeywords: \(keywordLine)"
        case .broad:
            return "\(trimmed)\n\nKeywords and related mentions: \(keywordLine)"
        }
    }

    private func retrievalParameters(maxChunks: Int, minScore: Float, mode: DatasetRetrievalMode) -> (candidateLimit: Int, threshold: Float) {
        let threshold = mode.effectiveThreshold(base: minScore)
        switch mode {
        case .focused, .balanced:
            // Precision-leaning: tight candidate pool capped at the requested
            // chunk count, using the mode's effective floor.
            return (maxChunks, threshold)
        case .broad:
            // Highest recall: widen the candidate pool for more source diversity.
            return (min(maxChunks + 3, 12), threshold)
        }
    }

    private func rankedChunks(
        for query: String,
        chunks: [Chunk],
        maxChunks: Int,
        minScore: Float,
        mode: DatasetRetrievalMode
    ) async -> [DatasetRetrievalCandidate<Chunk>] {
        guard maxChunks > 0, !chunks.isEmpty else { return [] }

        let trimmedQuery = expandedQuery(query, mode: mode)
        guard !trimmedQuery.isEmpty else { return [] }
        let parameters = retrievalParameters(maxChunks: maxChunks, minScore: minScore, mode: mode)

        let embedReady = await EmbeddingModel.shared.isReady()
        var candidates: [DatasetRetrievalCandidate<Chunk>] = []

        if embedReady {
            let qVec = await EmbeddingModel.shared.embedQuery(trimmedQuery)
            if !qVec.isEmpty && qVec.allSatisfy({ $0.isFinite && !$0.isNaN }) {
                candidates.reserveCapacity(chunks.count)
                for chunk in chunks {
                    guard !chunk.vector.isEmpty,
                          chunk.vector.allSatisfy({ $0.isFinite && !$0.isNaN }) else {
                        continue
                    }
                    let similarity = cosineSimilarity(chunk.vector, qVec)
                    if similarity.isFinite && !similarity.isNaN {
                        candidates.append(
                            DatasetRetrievalCandidate(
                                score: similarity,
                                source: chunk.source,
                                payload: chunk
                            )
                        )
                    }
                }
            } else {
                Task { await logger.log("[RAG] ❌ Invalid query embedding, using lexical fallback") }
            }
        }

        if candidates.isEmpty {
            let tokens = queryTokens(for: trimmedQuery)
            candidates = chunks.compactMap { chunk in
                let score = lexicalScore(queryTokens: tokens, text: chunk.text)
                if score <= 0 {
                    return nil
                }
                return DatasetRetrievalCandidate(score: score, source: chunk.source, payload: chunk)
            }
        }

        if candidates.isEmpty, let first = chunks.first {
            return [DatasetRetrievalCandidate(score: 0, source: first.source, payload: first)]
        }

        let selected = DatasetRetrievalRanker.select(
            candidates,
            maxChunks: parameters.candidateLimit,
            minScore: parameters.threshold
        )
        return Array(selected.prefix(maxChunks))
    }

    /// Estimates how many tokens the full dataset would occupy when inserted
    /// into the prompt. Uses the embedding model's tokenizer for counting.
    func estimateTokens(in dataset: LocalDataset) async -> Int {
        if let prepared = preparedText(for: dataset)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prepared.isEmpty {
            return await EmbeddingModel.shared.countTokens(prepared)
        }

        var total = 0
        for file in supportedFiles(in: dataset) {
            if Task.isCancelled { return total }
#if canImport(PDFKit)
                if file.ext == "pdf" {
                    if let doc = PDFKit.PDFDocument(url: file.url) {
                        var combined = ""
                        for i in 0..<doc.pageCount {
                            if let page = doc.page(at: i), let text = page.string {
                                combined += text + "\n"
                            }
                        }
                        total += await EmbeddingModel.shared.countTokens(combined)
                    }
                } else if file.ext == "epub" {
                    let text = EPUBTextExtractor.extractText(from: file.url)
                    total += await EmbeddingModel.shared.countTokens(text)
                } else if let str = DatasetTextReader.readString(from: file.url) {
                    total += await EmbeddingModel.shared.countTokens(str)
                }
#else
                if file.ext == "epub" {
                    let text = EPUBTextExtractor.extractText(from: file.url)
                    total += await EmbeddingModel.shared.countTokens(text)
                } else if let str = DatasetTextReader.readString(from: file.url) {
                    total += await EmbeddingModel.shared.countTokens(str)
                }
#endif
        }
        return total
    }

    /// Reads and concatenates all eligible files within the dataset without
    /// performing any embedding or tokenization.
    func fetchAllContent(for dataset: LocalDataset) -> String {
        if let prepared = preparedText(for: dataset) {
            return prepared
        }

        var parts: [String] = []
        for file in supportedFiles(in: dataset) {
            if Task.isCancelled { break }
#if canImport(PDFKit)
            if file.ext == "pdf" {
                if let doc = PDFKit.PDFDocument(url: file.url) {
                    var combined = ""
                    for i in 0..<doc.pageCount {
                        if let page = doc.page(at: i), let text = page.string {
                            combined += text + "\n"
                        }
                    }
                    let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        parts.append("<<<FILE: \(file.relativePath)>>>\n\(combined)")
                    }
                }
            } else if file.ext == "epub" {
                let text = EPUBTextExtractor.extractText(from: file.url).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append("<<<FILE: \(file.relativePath)>>>\n\(text)")
                }
            } else if let str = DatasetTextReader.readString(from: file.url) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append("<<<FILE: \(file.relativePath)>>>\n\(str)")
                }
            }
#else
            if file.ext == "epub" {
                let text = EPUBTextExtractor.extractText(from: file.url).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append("<<<FILE: \(file.relativePath)>>>\n\(text)")
                }
            } else if let str = DatasetTextReader.readString(from: file.url) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append("<<<FILE: \(file.relativePath)>>>\n\(str)")
                }
            }
#endif
        }
        return parts.joined(separator: "\n\n")
    }

    /// Fetches the most relevant chunks for the provided query text from the
    /// active dataset and returns them joined with blank lines. Chunks are only
    /// returned if their similarity meets the provided threshold.
    /// Returns a concatenated context for prompting
    /// Use `fetchContextDetailed` to display per-chunk citations in UI.
    func fetchContext(
        for query: String,
        dataset: LocalDataset,
        maxChunks: Int = 3,
        minScore: Float = 0.2,
        mode: DatasetRetrievalMode = .defaultValue,
        progress: (@MainActor @Sendable (DatasetProcessingStatus) -> Void)? = nil
    ) async -> String {
        Task { await logger.log("[RAG] retrieve.begin queryLen=\(query.count) mode=\(mode.rawValue) dataset=\(dataset.datasetID)") }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            Task { await logger.log("[RAG] Empty query provided") }
            return ""
        }

        if Task.isCancelled { return "" }
        let chunks = (try? await chunks(for: dataset, progress: progress)) ?? []
        if Task.isCancelled || chunks.isEmpty {
            Task { await logger.log("[RAG] No chunks available for dataset: \(dataset.datasetID)") }
            return ""
        }

        let ranked = await rankedChunks(for: trimmedQuery, chunks: chunks, maxChunks: maxChunks, minScore: minScore, mode: mode)
        let selectedTexts = ranked.map(\.payload.text)
        guard !selectedTexts.isEmpty else { Task { await logger.log("[RAG] retrieve.none") }; return "" }
        // Token-aware clamping for safety: cap total retrieved tokens; avoid per-chunk character truncation.
        // Allocate a generous token budget here; upstream prompt builder will enforce final budget.
        let maxTotalTokens = 12000
        var out: [String] = []
        var assembled = ""
        for text in selectedTexts {
            let candidate = assembled.isEmpty ? text : assembled + "\n\n" + text
            let tok = await EmbeddingModel.shared.countTokens(candidate)
            if tok > maxTotalTokens { break }
            out.append(text)
            assembled = candidate
        }
        let result = out.joined(separator: "\n\n")
        let resultTokens = await EmbeddingModel.shared.countTokens(result)
        Task { await logger.log("[RAG] retrieve.done picked=\(out.count) totalTokens=\(resultTokens) chars=\(result.count)") }
        return result
    }

    /// Detailed retrieval suitable for citation UI
    func fetchContextDetailed(
        for query: String,
        dataset: LocalDataset,
        maxChunks: Int = 3,
        minScore: Float = 0.2,
        mode: DatasetRetrievalMode = .defaultValue,
        progress: (@MainActor @Sendable (DatasetProcessingStatus) -> Void)? = nil
    ) async -> [(text: String, source: String?, score: Float?)] {
        Task { await logger.log("[RAG] retrieveDetailed.begin queryLen=\(query.count) mode=\(mode.rawValue) dataset=\(dataset.datasetID)") }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        if Task.isCancelled { return [] }
        let chunks = (try? await chunks(for: dataset, progress: progress)) ?? []
        if Task.isCancelled || chunks.isEmpty { return [] }

        let ranked = await rankedChunks(for: trimmedQuery, chunks: chunks, maxChunks: maxChunks, minScore: minScore, mode: mode)
        // Do not character-trim individual chunks; keep full text and let token-aware injector handle final limits.
        var results: [(String, String?, Float?)] = []
        for chunk in ranked {
            results.append((chunk.payload.text, chunk.payload.source, chunk.score))
        }
        Task { await logger.log("[RAG] retrieveDetailed.done picked=\(results.count)") }
        return results
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let length = min(a.count, b.count)
        if length == 0 { return 0 }
        
        // Validate input vectors
        guard a.allSatisfy({ $0.isFinite }) && b.allSatisfy({ $0.isFinite }) else {
            return 0 // Return 0 similarity for invalid vectors
        }
        
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<length {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        // Ensure we don't divide by zero and result is valid
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        
        let similarity = dot / denominator
        return similarity.isFinite ? similarity : 0
    }
    
}
