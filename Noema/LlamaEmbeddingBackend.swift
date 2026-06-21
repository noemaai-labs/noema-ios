// LlamaEmbeddingBackend.swift
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
        let threadCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
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
        
        var results: [[Float]] = []
        results.reserveCapacity(payloads.count)
        
        for (index, payload) in payloads.enumerated() {
            if Task.isCancelled { break }
            do {
                let s = record.templates.format(payload.text, task: task, title: payload.title)

                // Validate input text. The cap is a safety rail against
                // pathological inputs; actual tokenization clamps to the
                // model context inside LlamaEmbedder. Character counts
                // over-approximate tokens for multilingual (CJK/Thai/Arabic)
                // text, so use a generous multiplier instead of 4× context.
                let maxCharacters = LlamaEmbeddingBackend.maxFormattedCharacters(for: record)
                guard !s.isEmpty && s.count < maxCharacters else {
                    Task.detached(priority: .utility) { await logger.log("[Embed] ❌ Invalid text length: \(s.count)") }
                    throw EmbeddingError.embedFailed
                }
                
                var vec = Array(repeating: Float(0), count: Int(dim))
                let current = index + 1
                let total = payloads.count
                let heartbeatTask = makeHeartbeatTask(current: current, total: total, onEvent: onEvent)
                let ok = vec.withUnsafeMutableBufferPointer { buf -> Bool in
                    guard let base = buf.baseAddress else { return false }
                    // Return the model-configured pooled sequence embedding for this text.
                    return embedder.embedText(s, intoBuffer: base, length: Int32(dim))
                }
                heartbeatTask.cancel()
                if !ok {
                    Task.detached(priority: .utility) { await logger.log("[Embed] ❌ Embedding failed for text \(index)") }
                    throw EmbeddingError.embedFailed
                }
                
                if normalize {
                    let n = sqrt(vec.reduce(0) { $0 + $1 * $1 })
                    if n > 0 { for i in 0..<vec.count { vec[i] /= Float(n) } }
                }
                results.append(vec)
                
                // Log progress for longer sequences
                if payloads.count > 1 {
                    Task.detached(priority: .utility) { await logger.log("[Embed] Progress: \(current)/\(total)") }
                }
                onEvent?(.itemCompleted(completed: current, total: total))
                
            } catch {
                Task.detached(priority: .utility) { await logger.log("[Embed] ❌ Exception during embedding text \(index): \(error.localizedDescription)") }
                throw error
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
        var repetitions = max(32, targetTokens)
        var probe = String(repeating: seed, count: repetitions).trimmingCharacters(in: .whitespacesAndNewlines)
        if probe.count > probeBudget {
            probe = String(probe.prefix(probeBudget))
        }
        var formattedTokenCount = try countTokens(record.templates.format(probe, task: task, title: titleSeed))
        while formattedTokenCount < targetTokens && probe.count < (probeBudget - seed.count) {
            repetitions += max(16, targetTokens / 4)
            let candidate = String(repeating: seed, count: repetitions).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count > probeBudget { break }
            probe = candidate
            formattedTokenCount = try countTokens(record.templates.format(probe, task: task, title: titleSeed))
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
