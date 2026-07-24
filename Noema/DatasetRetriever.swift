import Foundation

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

        var generatedExtractedText = false
        var generatedCompactText = false
        var preparationCompleted = false
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
                generatedExtractedText = true
                let report = try await extractPlainText(from: dataset, writingTo: extractedURL) { frac in
                    if let progress {
                        let dt = Date().timeIntervalSince(t0)
                        let eta = frac > 0 ? dt * (1.0 / frac - 1.0) : nil
                        await progress(
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
                generatedCompactText = true
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
                if generatedExtractedText { try? FileManager.default.removeItem(at: extractedURL) }
                if generatedCompactText { try? FileManager.default.removeItem(at: compactURL) }
                let reason = String(localized: "No retrievable text found in imported files", locale: LocalizationManager.preferredLocale())
                recordFailure(for: dataset, reason: reason)
                if let progress {
                    await progress(DatasetProcessingStatus(stage: .failed, progress: 0.0, message: reason, etaSeconds: nil))
                }
                return
            }
            preparationCompleted = true

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
            if !preparationCompleted {
                if generatedExtractedText { try? FileManager.default.removeItem(at: extractedURL) }
                if generatedCompactText { try? FileManager.default.removeItem(at: compactURL) }
            }
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
        // UserDefaults is thread-safe, so write directly. Previously this hopped to the main
        // thread via DispatchQueue.main.sync, which blocks this actor (and risks a hang) while
        // the main thread is busy — pointless for a plain defaults write.
        UserDefaults.standard.set(value, forKey: indexingDatasetIDPersistedKey)
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
        onProgress: @escaping @Sendable (Double) async -> Void
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

        #if canImport(PDFKit)
        for file in pdfs {
            if Task.isCancelled { throw CancellationError() }
            let progressBeforeFile = Double(completedUnits) / Double(totalUnits)
            let progressForFile = 1.0 / Double(totalUnits)
            guard let text = try await Self.extractPDFDocumentText(
                from: file.url,
                onPageProgress: { completedPages, pageCount in
                    guard pageCount > 0 else { return }
                    let pageFraction = Double(completedPages) / Double(pageCount)
                    await onProgress(min(0.95, progressBeforeFile + progressForFile * pageFraction))
                }
            ) else {
                report.skippedFiles.append(file.relativePath)
                completedUnits += 1
                await onProgress(min(0.95, Double(completedUnits) / Double(totalUnits)))
                continue
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.emptyFiles.append(file.relativePath)
            } else {
                try writeProcessedFile(relativePath: file.relativePath, text: text)
                report.processedFiles.append(file.relativePath)
            }
            completedUnits += 1
            await onProgress(min(0.95, Double(completedUnits) / Double(totalUnits)))
        }
        #else
        for file in pdfs {
            if Task.isCancelled { throw CancellationError() }
            report.skippedFiles.append(file.relativePath)
            completedUnits += 1
            await onProgress(min(0.95, Double(completedUnits) / Double(totalUnits)))
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
            completedUnits += 1
            await onProgress(min(0.95, Double(completedUnits) / Double(totalUnits)))
        }

        for file in textFiles {
            if Task.isCancelled { throw CancellationError() }
            guard let raw = DatasetTextReader.readString(from: file.url) else {
                report.skippedFiles.append(file.relativePath)
                completedUnits += 1
                await onProgress(min(0.95, Double(completedUnits) / Double(totalUnits)))
                continue
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                report.emptyFiles.append(file.relativePath)
            } else {
                try writeProcessedFile(relativePath: file.relativePath, text: raw)
                report.processedFiles.append(file.relativePath)
            }
            completedUnits += 1
            await onProgress(min(0.95, Double(completedUnits) / Double(totalUnits)))
        }

        if Task.isCancelled { throw CancellationError() }
        await onProgress(1.0)
        return report
    }

    #if canImport(PDFKit)
    /// Runs synchronous PDFKit/Vision work outside this actor. Cancellation of
    /// indexing is forwarded to the worker and checked between PDF pages.
    private nonisolated static func extractPDFDocumentText(
        from url: URL,
        onPageProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> String? {
        let (updates, continuation) = AsyncStream<(Int, Int)>.makeStream()
        let worker = Task.detached(priority: .utility) {
            defer { continuation.finish() }
            return try PDFTextExtractor.documentText(
                from: url,
                ocrEmptyPages: true,
                onPageProgress: { completed, total in
                    continuation.yield((completed, total))
                }
            )
        }
        return try await withTaskCancellationHandler {
            for await (completed, total) in updates {
                if Task.isCancelled { throw CancellationError() }
                await onPageProgress(completed, total)
            }
            return try await worker.value
        } onCancel: {
            worker.cancel()
            continuation.finish()
        }
    }
    #endif

    /// High-confidence prefixes that form genuine hyphenated compounds. When a
    /// line-wrap hyphen follows one of these the hyphen is preserved rather than
    /// removed, so "anti-inflammatory" doesn't collapse to "antiinflammatory".
    private static let dehyphenationCompoundPrefixes: Set<String> = [
        "self", "non", "anti", "multi", "semi"
    ]

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
        // Holds the previous non-blank line so we can de-hyphenate a wrap
        // ("infor-\nmation" → "information") before committing it.
        var pendingLine: String? = nil

        func flushPending() throws {
            if let p = pendingLine {
                try writeLine(p)
                pendingLine = nil
            }
        }

        func handleLine(_ raw: String) throws {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try flushPending()
                if !lastBlank {
                    try writeLine("")
                    lastBlank = true
                }
                return
            }
            let normalized = normalizeInlineWhitespace(trimmed)
            lastBlank = false
            if let prev = pendingLine {
                // Previous line ends with letter + hyphen and this line starts
                // lowercase: either a wrapped word ("infor-\nmation") or a genuine
                // hyphenated compound that happened to wrap ("anti-\ninflammatory").
                if prev.count >= 2,
                   prev.hasSuffix("-"),
                   prev[prev.index(prev.endIndex, offsetBy: -2)].isLetter,
                   let firstChar = normalized.first, firstChar.isLowercase {
                    let stem = String(prev.dropLast())  // without the trailing hyphen
                    let lastWord = (stem.split { $0 == " " || $0 == "\t" }.last).map { String($0).lowercased() } ?? ""
                    if Self.dehyphenationCompoundPrefixes.contains(lastWord) {
                        // Real compound — keep the hyphen ("anti-inflammatory").
                        pendingLine = prev + normalized
                    } else {
                        // Line-wrap hyphenation — drop the hyphen ("information").
                        pendingLine = stem + normalized
                    }
                    return
                }
                try writeLine(prev)
            }
            pendingLine = normalized
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
        try flushPending()

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
        // Running token estimate for `buffer`, accumulated per line so we never
        // re-tokenize the whole growing buffer (the old code was O(L^2) per file).
        var bufferTokens = 0
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
                    let parts = Self.splitLongTextForEmbedding(trimmed, maxChars: maxCharsPerChunk)
                    for p in parts {
                        chunkTexts.append(p)
                        chunkSources.append(currentSource)
                        chunkTitles.append(chunkTitle)
                    }
                }
            }
            buffer = ""
            bufferTokens = 0
        }

        var consecutiveBlanks = 0
        for (idx, line) in lines.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = parseSourceMarker(t) {
                flushBuffer()
                consecutiveBlanks = 0
                currentSource = marker
                skippingInternalSource = DatasetStorage.isInternalRelativePath(marker)
                continue
            }
            if skippingInternalSource { continue }
            if t.isEmpty {
                // Only a strong boundary (a real paragraph/section break — two or
                // more consecutive blank lines) forces a flush. A single blank
                // line, which PDFKit emits constantly around visual line, column
                // and figure seams, is a soft separator so passages stay whole
                // instead of fragmenting into one-line chunks.
                consecutiveBlanks += 1
                if consecutiveBlanks >= 2 {
                    flushBuffer()
                }
            } else {
                consecutiveBlanks = 0
                // Tokenize only the new line and keep a running total, instead of
                // re-tokenizing the whole buffer every line. The 8000-char cap in
                // flushBuffer is the hard backstop if the running estimate drifts.
                let lineTokens = await EmbeddingModel.shared.countTokens(t)
                if !buffer.isEmpty && bufferTokens + lineTokens > maxTokensPerChunk {
                    flushBuffer()
                    buffer = t
                    bufferTokens = lineTokens
                } else {
                    buffer = buffer.isEmpty ? t : buffer + " " + t
                    bufferTokens += lineTokens
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
                    let parts = Self.splitLongTextForEmbedding(remaining, maxChars: 4000)
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

    nonisolated static func splitLongTextForEmbedding(_ text: String, maxChars: Int) -> [String] {
        guard maxChars > 0 else { return [] }
        var output: [String] = []
        var remaining = text
        while !remaining.isEmpty {
            if remaining.count <= maxChars {
                output.append(remaining)
                break
            }
            let limit = remaining.index(remaining.startIndex, offsetBy: maxChars)
            let candidate = remaining[..<limit].lastIndex(of: "\n")
                ?? remaining[..<limit].lastIndex(of: ".")
                ?? remaining[..<limit].lastIndex(of: " ")
            // A delimiter at startIndex would emit an empty part and leave the
            // remainder unchanged (notably for long strings beginning with a period).
            let splitIndex = candidate == remaining.startIndex ? limit : (candidate ?? limit)
            let part = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { output.append(part) }
            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
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

        // No query term appears in this chunk — it is not a lexical match. Return
        // 0 so the length bonus alone can never manufacture a spurious score. This
        // matters for garbled corpora (e.g. char-spaced OCR), where every chunk
        // tokenizes to single characters that match no multi-character query
        // token: without this guard every long chunk scored exactly
        // lengthBonus * 0.1 = 0.10 and the title page got injected as "relevant".
        if hits == 0 { return 0 }

        let jaccard = Float(hits) / Float(max(seen.count + queryTokens.count - hits, 1))
        let lengthBonus = min(Float(text.count) / 500.0, 1.0)
        return jaccard * 0.9 + lengthBonus * 0.1
    }

    private func queryTokens(for query: String) -> Set<String> {
        var tokens = Set<String>()
        // Keep runs of letters/digits together with internal "-" and "." so codes
        // like "m8-1.25", "e-204" or "fm21-76" survive as one token instead of
        // being shredded into sub-3-char fragments that the old filter dropped.
        let pieces = query.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "." }
        for piece in pieces {
            let s = String(piece).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
            guard !s.isEmpty else { continue }
            let hasDigit = s.contains { $0.isNumber }
            // Alphabetic words need >=3 chars; anything with a digit (part numbers,
            // statutes, codes) is kept regardless of length.
            if hasDigit || s.count >= 3 { tokens.insert(s) }
            // Also index sub-parts of a compound code so "m8" matches "m8 bolt".
            if hasDigit, s.contains("-") || s.contains(".") {
                for sub in s.split(whereSeparator: { $0 == "-" || $0 == "." }) {
                    let t = String(sub)
                    if !t.isEmpty, t.contains(where: { $0.isNumber }) || t.count >= 3 {
                        tokens.insert(t)
                    }
                }
            }
        }
        return tokens
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

        // Distinctive query terms used to nudge dense scores toward chunks that
        // contain an exact term (part numbers, statutes, defined terms). Must
        // contain a letter — pure-numeric tokens like "204" substring-match
        // unrelated figures (e.g. "1204") and are dropped to avoid false hits.
        let boostTokens = Array(
            queryTokens(for: query)
                .filter { $0.contains(where: { $0.isLetter }) && $0.count >= 3 }
                .prefix(6)
        )

        // Best UN-BOOSTED cosine seen; the abstain decision keys off this so the
        // keyword boost can re-order candidates but can never promote an
        // off-topic chunk past the relevance floor.
        var maxRawSimilarity: Float = -1
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
                        maxRawSimilarity = max(maxRawSimilarity, similarity)
                        var score = similarity
                        if !boostTokens.isEmpty {
                            // Tokenize the chunk the SAME way as the query (keeping
                            // internal "-"/"." so codes like "e-204" / "m8-1.25" stay
                            // a single token) and match on set membership: "204" can't
                            // hit inside "1204", yet "e-204" still matches "e-204".
                            let words = Set(
                                chunk.text.lowercased()
                                    .split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "." }
                                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-.")) }
                            )
                            let present = boostTokens.reduce(0) { $0 + (words.contains($1) ? 1 : 0) }
                            if present > 0 {
                                score += 0.08 * (Float(present) / Float(boostTokens.count))
                            }
                        }
                        candidates.append(
                            DatasetRetrievalCandidate(
                                score: score,
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

        // True when the candidate pool came from dense (cosine) scoring, so the
        // raw-cosine abstain below applies on the right scale.
        let usedDense = !candidates.isEmpty

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

        if candidates.isEmpty {
            // Nothing matched at all — abstain rather than forcing an irrelevant
            // chunk into context, which invites grounded-looking hallucination.
            return []
        }

        // Abstain ONLY when even the best raw (un-boosted) match is clearly
        // off-topic. Above the floor we hand back the ranker's normal selection,
        // preserving its graceful best-scoring fallback for weak-but-present matches.
        if usedDense {
            let floor = Self.abstainFloor()
            if maxRawSimilarity < floor {
                let best = maxRawSimilarity
                Task { await logger.log(String(format: "[RAG] abstain — best cosine %.3f < floor %.3f", best, floor)) }
                return []
            }
        }

        let selected = DatasetRetrievalRanker.select(
            candidates,
            maxChunks: parameters.candidateLimit,
            minScore: parameters.threshold
        )
        return Array(selected.prefix(maxChunks))
    }

    /// Raw-cosine relevance floor below which even the best match is treated as
    /// off-topic and dense retrieval abstains. Deliberately conservative so it
    /// only fires on genuine misses (it must not suppress legitimate weak matches
    /// on lower-baseline models). Per-model overrides go here as real thresholds
    /// are calibrated from abstain telemetry.
    nonisolated static func abstainFloor() -> Float {
        switch EmbeddingModelCatalog.activeRecord().id {
        // Qwen3-Embedding is instruction-tuned: genuine matches sit well above
        // ~0.3, while a degenerate corpus (e.g. garbled OCR whose chunks tokenize
        // to near-identical vectors) collapses every cosine to ~0.10 — just over
        // the old 0.08 default, so junk was injected instead of abstaining.
        // Floor at 0.12 to reject the collapse while staying far below any real
        // match. Conservative; tune up from abstain telemetry if needed.
        case "Qwen/Qwen3-Embedding-0.6B-GGUF",
             "Qwen/Qwen3-Embedding-4B-GGUF":
            return 0.12
        default: return 0.08
        }
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
                    if let combined = try? await Self.extractPDFDocumentText(from: file.url) {
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
    func fetchAllContent(for dataset: LocalDataset) async -> String {
        if let prepared = preparedText(for: dataset) {
            return prepared
        }

        var parts: [String] = []
        for file in supportedFiles(in: dataset) {
            if Task.isCancelled { break }
#if canImport(PDFKit)
            if file.ext == "pdf" {
                if let combined = try? await Self.extractPDFDocumentText(from: file.url) {
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
