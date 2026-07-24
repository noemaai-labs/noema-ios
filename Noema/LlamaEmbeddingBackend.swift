import Foundation

final class LlamaEmbeddingBackend: EmbeddingsBackend {
    private enum EmbeddingPayload {
        case text(String)
        case document(EmbeddingDocumentInput)

        var text: String {
            switch self {
            case .text(let text):
                return text
            case .document(let document):
                return document.text
            }
        }

        var title: String? {
            switch self {
            case .text:
                return nil
            case .document(let document):
                return document.title
            }
        }
    }

    private let modelPath: String
    private let record: EmbeddingModelRecord
    private var embedder: LlamaEmbedder?
    private var didPrimeFirstEmbeddingPass = false
    private var flatOutputScratch: [Float] = []
    private(set) var dimension: Int = 0
    var isReady: Bool { (embedder?.isReady() ?? false) && dimension > 0 }

    static func maxFormattedCharacters(for record: EmbeddingModelRecord) -> Int {
        max(32_768, record.runtimeContextTokens * 16)
    }

    init(modelPath: String, record: EmbeddingModelRecord = EmbeddingModelCatalog.activeRecord()) {
        self.modelPath = modelPath
        self.record = record
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: modelPath) else { throw EmbeddingError.modelMissing }

        // Reasonable defaults for iOS
        let pathMsg = "[Embed] load_model path=\(modelPath)"
        Task.detached(priority: .utility) { await logger.log(pathMsg) }
        // Reserve cores for the main/render thread so embedding does not starve the UI.
        // Mirrors the chat-generation policy (ModelSettings.recommendedInferenceThreadCount =
        // activeProcessorCount - 2); previously this grabbed every core, which caused UI jank
        // during dataset indexing / RAG embedding even though the work is off the main thread.
        let threadCount = ModelSettings.recommendedInferenceThreadCount
        Task.detached(priority: .utility) { await logger.log("[Embed] Using \(threadCount) threads") }

        let desiredGpuLayers: Int32 = {
#if canImport(Metal)
            return 1_000_000 // Request full offload when GPU is available
#else
            return 0
#endif
        }()

        let threads32 = Int32(threadCount)
        var loadedWithGPU = false
        var resolvedEmbedder: LlamaEmbedder?

#if canImport(Metal)
        if DeviceGPUInfo.supportsGPUOffload && desiredGpuLayers > 0 {
            Task.detached(priority: .utility) { await logger.log("[Embed] Attempting GPU offload with nGpuLayers=\(desiredGpuLayers)") }
            let gpuEmbedder = LlamaEmbedder(
                modelPath: modelPath,
                threads: threads32,
                nGpuLayers: desiredGpuLayers,
                contextLength: Int32(record.runtimeContextTokens),
                poolingType: record.defaultPooling.nativeRawValue
            )

            if gpuEmbedder.isReady() {
                resolvedEmbedder = gpuEmbedder
                loadedWithGPU = true
            } else {
                Task.detached(priority: .utility) { await logger.log("[Embed] ⚠️ GPU offload failed, falling back to CPU") }
                gpuEmbedder.unload()
            }
        }
#endif

        if resolvedEmbedder == nil {
            let cpuEmbedder = LlamaEmbedder(
                modelPath: modelPath,
                threads: threads32,
                nGpuLayers: 0,
                contextLength: Int32(record.runtimeContextTokens),
                poolingType: record.defaultPooling.nativeRawValue
            )

            guard cpuEmbedder.isReady() else {
                Task.detached(priority: .utility) { await logger.log("[Embed] ❌ Failed to load embedder on CPU") }
                throw EmbeddingError.loadFailed("embedder init failed on CPU")
            }

            resolvedEmbedder = cpuEmbedder
        }

        guard let resolvedEmbedder else {
            throw EmbeddingError.loadFailed("embedder init unresolved")
        }

        embedder = resolvedEmbedder
        didPrimeFirstEmbeddingPass = false
        dimension = Int(resolvedEmbedder.dimension())
        let dim = dimension
        Task.detached(priority: .utility) {
            let backend = loadedWithGPU ? "GPU" : "CPU"
            await logger.log("[Embed] ✅ Model loaded successfully (\(backend)), dim=\(dim), threads=\(threadCount)")
        }
    }

    func warmUp() throws {
        guard let embedder else { throw EmbeddingError.notConfigured }
        let dim = Int(embedder.dimension())
        guard dim > 0 else {
            throw EmbeddingError.loadFailed("invalid embedding dim during warmup")
        }
        if didPrimeFirstEmbeddingPass {
            let msg = "[Embed] warmup completed, model ready dim=\(dim)"
            Task.detached(priority: .utility) { await logger.log(msg) }
            return
        }

        let targetTokens = max(32, min(DatasetChunkingPolicy.maxTokensPerChunk, max(32, record.runtimeContextTokens - 8)))
        let defaultPooling = record.defaultPooling
        let normalizeSetting = record.normalize
        let probe = try makePrimeProbe(task: .searchDocument, targetTokens: targetTokens)
        let startedAt = Date()
        Task.detached(priority: .utility) {
            await logger.log("[Embed] prime.start targetTokens=\(targetTokens) actualTokens=\(probe.formattedTokenCount) pooling=\(defaultPooling) normalize=\(normalizeSetting)")
        }
        let heartbeatTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await logger.log("[Embed] prime.heartbeat targetTokens=\(targetTokens) actualTokens=\(probe.formattedTokenCount)")
            }
        }
        defer { heartbeatTask.cancel() }
        _ = try embed([probe.text], task: .searchDocument, pooling: defaultPooling, normalize: normalizeSetting)
        didPrimeFirstEmbeddingPass = true
        Task.detached(priority: .utility) {
            let dt = Date().timeIntervalSince(startedAt)
            await logger.log("[Embed] prime.done dt=\(String(format: "%.2f", dt))s actualTokens=\(probe.formattedTokenCount)")
        }
        let msg = "[Embed] warmup completed, model ready dim=\(dim)"
        Task.detached(priority: .utility) { await logger.log(msg) }
    }

    func countTokens(_ text: String) throws -> Int {
        guard let embedder else { throw EmbeddingError.notConfigured }
        return Int(embedder.countTokens(text))
    }

    func embed(_ texts: [String], task: EmbeddingTask, pooling: EmbeddingPooling, normalize: Bool) throws -> [[Float]] {
        try embedInternal(texts.map(EmbeddingPayload.text), task: task, pooling: pooling, normalize: normalize, onEvent: nil)
    }

    func embedDocuments(
        _ documents: [EmbeddingDocumentInput],
        pooling: EmbeddingPooling,
        normalize: Bool
    ) throws -> [[Float]] {
        try embedInternal(documents.map(EmbeddingPayload.document), task: .searchDocument, pooling: pooling, normalize: normalize, onEvent: nil)
    }

    private func embedInternal(
        _ payloads: [EmbeddingPayload],
        task: EmbeddingTask,
        pooling: EmbeddingPooling,
        normalize: Bool,
        onEvent: (@Sendable (EmbeddingProgressEvent) -> Void)?
    ) throws -> [[Float]] {
        guard let embedder else { 
            Task.detached(priority: .utility) { await logger.log("[Embed] ❌ embed() called but model/context not configured") }
            throw EmbeddingError.notConfigured 
        }
        if payloads.isEmpty { return [] }
        
        let dim = Int(embedder.dimension())
        guard dim > 0 else {
            Task.detached(priority: .utility) { await logger.log("[Embed] ❌ Invalid dimension: \(dim)") }
            throw EmbeddingError.embedFailed
        }
        
        let recordID = record.id
        Task.detached(priority: .utility) { await logger.log("[Embed] Starting embedding for \(payloads.count) text(s), dim=\(dim), model=\(recordID)") }
        // Adjust batch size heuristics (controlled by caller). Here we log the type of task.
        switch task {
        case .searchDocument: Task.detached(priority: .utility) { await logger.log("[Embed] task=searchDocument pooling=\(pooling) normalize=\(normalize)") }
        case .searchQuery: Task.detached(priority: .utility) { await logger.log("[Embed] task=searchQuery pooling=\(pooling) normalize=\(normalize)") }
        case .generic: Task.detached(priority: .utility) { await logger.log("[Embed] task=generic pooling=\(pooling) normalize=\(normalize)") }
        }
        
        let formatted = try payloads.enumerated().map { index, payload -> String in
            let text = record.templates.format(payload.text, task: task, title: payload.title)
            let maxCharacters = LlamaEmbeddingBackend.maxFormattedCharacters(for: record)
            guard !text.isEmpty && text.count < maxCharacters else {
                Task.detached(priority: .utility) {
                    await logger.log("[Embed] ❌ Invalid text length at \(index): \(text.count)")
                }
                throw EmbeddingError.embedFailed
            }
            return text
        }

        var results: [[Float]] = []
        results.reserveCapacity(payloads.count)
        let nativeBatchCapacity = 8
        for groupStart in stride(from: 0, to: formatted.count, by: nativeBatchCapacity) {
            try Task.checkCancellation()
            let groupEnd = min(formatted.count, groupStart + nativeBatchCapacity)
            let group = Array(formatted[groupStart..<groupEnd])
            let requiredFloats = group.count * dim
            if flatOutputScratch.count < requiredFloats {
                flatOutputScratch = Array(repeating: 0, count: requiredFloats)
            }
            let heartbeat = makeHeartbeatTask(
                current: groupStart + 1,
                total: payloads.count,
                onEvent: onEvent
            )
            let ok = flatOutputScratch.withUnsafeMutableBufferPointer { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                return embedder.embedTexts(group, intoBuffer: base, rowStride: Int32(dim))
            }
            heartbeat.cancel()
            guard ok else {
                Task.detached(priority: .utility) {
                    await logger.log("[Embed] ❌ Native batch failed at item \(groupStart)")
                }
                throw EmbeddingError.embedFailed
            }

            for row in 0..<group.count {
                let start = row * dim
                var vector = Array(flatOutputScratch[start..<(start + dim)])
                if normalize {
                    let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
                    if magnitude > 0 {
                        for index in vector.indices { vector[index] /= magnitude }
                    }
                }
                results.append(vector)
                let completed = groupStart + row + 1
                onEvent?(.itemCompleted(completed: completed, total: payloads.count))
            }
            if payloads.count > 1 {
                let completed = groupEnd
                let total = payloads.count
                Task.detached(priority: .utility) {
                    await logger.log("[Embed] Progress: \(completed)/\(total)")
                }
            }
        }
        
        Task.detached(priority: .utility) { await logger.log("[Embed] ✅ Successfully embedded \(results.count) text(s) [pooling=\(pooling.rawValue)]") }
        return results
    }

    /// Embeds texts and invokes a callback after each item is produced.
    /// - Parameters:
    ///   - texts: Input texts to embed
    ///   - task: Embedding task flavor
    ///   - pooling: Pooling behavior requested by the active model record
    ///   - normalize: Whether to L2-normalize vectors
    ///   - onItem: Callback receiving (completedCount, totalCount)
    /// - Returns: Array of vectors, one per input text
    func embedWithProgress(
        _ texts: [String],
        task: EmbeddingTask,
        pooling: EmbeddingPooling,
        normalize: Bool,
        onEvent: @escaping @Sendable (EmbeddingProgressEvent) -> Void
    ) throws -> [[Float]] {
        try embedInternal(texts.map(EmbeddingPayload.text), task: task, pooling: pooling, normalize: normalize, onEvent: onEvent)
    }

    func embedDocumentsWithProgress(
        _ documents: [EmbeddingDocumentInput],
        pooling: EmbeddingPooling,
        normalize: Bool,
        onEvent: @escaping @Sendable (EmbeddingProgressEvent) -> Void
    ) throws -> [[Float]] {
        try embedInternal(documents.map(EmbeddingPayload.document), task: .searchDocument, pooling: pooling, normalize: normalize, onEvent: onEvent)
    }

    deinit {
        embedder?.unload()
    }

    func unload() {
        embedder?.unload()
        embedder = nil
        didPrimeFirstEmbeddingPass = false
        flatOutputScratch.removeAll(keepingCapacity: false)
        dimension = 0
        Task.detached(priority: .utility) { await logger.log("[Embed] Backend unloaded and freed from memory") }
    }

    private func makePrimeProbe(task: EmbeddingTask, targetTokens: Int) throws -> (text: String, formattedTokenCount: Int) {
        let maxCharacters = LlamaEmbeddingBackend.maxFormattedCharacters(for: record)
        let seed = "warmup "
        let titleSeed = task == .searchDocument ? "Warmup Document" : nil
        // embed() validates the *formatted* string (with any template prefix
        // applied) against maxCharacters, so cap the probe accordingly. The
        // overhead must be measured with a non-empty sentinel because some
        // templates (e.g. EmbeddingGemma's `"title: \n{{text}}"`) collapse to
        // a shorter string when {{text}} is empty and trailing whitespace is
        // trimmed — computing overhead from `format("")` would under-count
        // the bytes added to real inputs and push the formatted probe just
        // past the limit.
        let sentinel = "x"
        let withSentinel = record.templates.format(sentinel, task: task, title: titleSeed)
        let withEmpty = record.templates.format("", task: task, title: titleSeed)
        let templateOverhead = max(withSentinel.count - sentinel.count, withEmpty.count)
        let probeBudget = max(1, maxCharacters - templateOverhead - 1)
        let source = String(
            String(repeating: seed, count: max(32, targetTokens)).prefix(probeBudget)
        )
        var lowerBound = 1
        var upperBound = source.count
        var probe = "warmup"
        var formattedTokenCount = try countTokens(
            record.templates.format(probe, task: task, title: titleSeed)
        )

        // Token density varies substantially by tokenizer. Find the longest
        // probe that stays within the requested token budget instead of using
        // targetTokens as a repetition count (which produced 2,401 tokens for
        // a 1,200-token Qwen3 warm-up and made every warm-up fail).
        while lowerBound <= upperBound {
            let candidateLength = lowerBound + (upperBound - lowerBound) / 2
            let candidate = String(source.prefix(candidateLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateTokenCount = try countTokens(
                record.templates.format(candidate, task: task, title: titleSeed)
            )
            if candidateTokenCount <= targetTokens {
                probe = candidate
                formattedTokenCount = candidateTokenCount
                lowerBound = candidateLength + 1
            } else {
                upperBound = candidateLength - 1
            }
        }
        return (probe, formattedTokenCount)
    }

    private func makeHeartbeatTask(
        current: Int,
        total: Int,
        onEvent: (@Sendable (EmbeddingProgressEvent) -> Void)?
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await logger.log("[Embed] Heartbeat current=\(current)/\(total)")
                onEvent?(.heartbeat(current: current, total: total))
            }
        }
    }
}
