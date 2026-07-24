import Foundation

actor EmbeddingModel {
    static let shared = EmbeddingModel()
    
    // llama backend
    private var backend: EmbeddingsBackend?
    private var loadedRecordID: String?
    private(set) var warmedUp = false
    private var isLoading = false
    // Track active embedding operations that should keep the backend alive
    private var activeOperations: Int = 0

    /// Public read accessor for active operation count. Accessing this is async because
    /// the value is actor-isolated; callers should `await EmbeddingModel.shared.activeOperationsCount`.
    var activeOperationsCount: Int {
        return activeOperations
    }

    // Compatibility accessors for existing call sites. They now resolve to the active record.
    static var modelDir: URL {
        let record = EmbeddingModelCatalog.activeRecord()
        return record.primaryArtifact?.directoryURL(recordID: record.id) ?? EmbeddingModelCatalog.directoryURL(for: record.id)
    }
    static var modelFilename: String { EmbeddingModelCatalog.activeRecord().primaryArtifact?.filename ?? "" }
    static var modelURL: URL { EmbeddingModelCatalog.activeRecord().installedURL }

    private init() {}

    // Cheap prep only – no network
    func ensureModel() async { try? FileManager.default.createDirectory(at: Self.modelDir, withIntermediateDirectories: true) }

    func activeRecord() -> EmbeddingModelRecord {
        EmbeddingModelCatalog.activeRecord()
    }

    func activeFingerprint() -> EmbeddingIndexFingerprint {
        EmbeddingModelCatalog.currentIndexFingerprint()
    }

    func isModelInstalled(recordID: String) -> Bool {
        guard let record = EmbeddingModelCatalog.record(for: recordID) else { return false }
        return record.isInstalled
    }

    func setActiveModel(recordID: String) async throws {
        guard let record = EmbeddingModelCatalog.record(for: recordID) else {
            throw EmbeddingError.modelMissing
        }
        guard record.isInstallable, record.isInstalled else {
            throw EmbeddingError.modelMissing
        }
        if EmbeddingModelCatalog.activeRecord().id != record.id {
            unload()
            await DatasetRetriever.shared.clearCache()
            EmbeddingModelCatalog.setActiveRecordID(record.id)
            NotificationCenter.default.post(
                name: .embeddingModelAvailabilityChanged,
                object: nil,
                userInfo: ["available": true, "recordID": record.id]
            )
        }
    }

    func load() throws {
        let record = EmbeddingModelCatalog.activeRecord()
        let modelURL = record.installedURL
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            Task { await logger.log("[EmbedModel] ❌ Model file not found at: \(modelURL.path)") }
            throw EmbeddingError.modelMissing 
        }
        
        // Ensure we don't already have a backend loaded
        if backend != nil {
            Task { await logger.log("[EmbedModel] ⚠️ Backend already loaded, unloading first") }
            backend = nil
            warmedUp = false
        }
        
        let b = LlamaEmbeddingBackend(modelPath: modelURL.path, record: record)
        do {
            try b.load()
            backend = b
            loadedRecordID = record.id
            warmedUp = false
            Task { await logger.log("[EmbedModel] ✅ Backend loaded successfully") }
        } catch {
            backend = nil
            loadedRecordID = nil
            warmedUp = false
            Task { await logger.log("[EmbedModel] ❌ Failed to load backend: \(error.localizedDescription)") }
            throw error
        }
    }

    func unload() {
        if let b = backend {
            Task.detached { await logger.log("[EmbedModel] Unloading embedding backend") }
            b.unload()
            backend = nil
            loadedRecordID = nil
            warmedUp = false
        }
    }

    /// Recreates the native backend after a Metal failure. GPU work denied
    /// while the app was backgrounded leaves the llama.cpp Metal backend in a
    /// sticky error state ("recreate the backend to recover"), so a plain
    /// retry can never succeed until the backend is rebuilt.
    func recoverAfterInterruption() async {
        Task.detached { await logger.log("[EmbedModel] Recreating embedding backend after interruption") }
        unload()
        do {
            try load()
        } catch {
            Task.detached { await logger.log("[EmbedModel] ❌ Recovery reload failed: \(error.localizedDescription)") }
            return
        }
        await warmUp()
    }

    func warmUp() async {
        await warmUp(onPhaseChange: nil)
    }

    func warmUp(onPhaseChange: (@Sendable (EmbeddingWarmUpPhase) -> Void)? = nil) async {
        let record = EmbeddingModelCatalog.activeRecord()
        if warmedUp, backend != nil, loadedRecordID == record.id {
            return
        }
        if backend == nil || loadedRecordID != record.id {
            onPhaseChange?(.loadingModel)
            if FileManager.default.fileExists(atPath: record.installedURL.path) {
                do { try load() } catch { warmedUp = false; return }
            } else { warmedUp = false; return }
        }
        do {
            onPhaseChange?(.primingFirstPass)
            try backend?.warmUp()
            warmedUp = backend?.isReady ?? false
        } catch {
            Task { await logger.log("[Embed] ❌ warmUp failed: \(error.localizedDescription)") }
            warmedUp = false
        }
    }

    func isReady() -> Bool { warmedUp }

    func isModelAvailable() -> Bool { FileManager.default.fileExists(atPath: Self.modelURL.path) }

    func countTokens(_ text: String) async -> Int {
        do { if backend == nil || loadedRecordID != EmbeddingModelCatalog.activeRecord().id { try load() }; return try backend?.countTokens(text) ?? text.split{ $0.isWhitespace }.count }
        catch { return text.split{ $0.isWhitespace }.count }
    }

    func embed(_ text: String) async -> [Float] {
        let record = EmbeddingModelCatalog.activeRecord()
        do { if backend == nil || loadedRecordID != record.id { try load() }; return try backend?.embed([text], task: .generic, pooling: record.defaultPooling, normalize: record.normalize).first ?? [] }
        catch { return [] }
    }

    // Preferred specialized variants for better retrieval quality with models like nomic-embed-text-v2
    func embedDocuments(_ texts: [String]) async -> [[Float]] {
        await embedDocuments(texts.map { EmbeddingDocumentInput(text: $0) })
    }

    // Preferred specialized variants for better retrieval quality with models like nomic-embed-text-v2
    func embedDocuments(_ documents: [EmbeddingDocumentInput]) async -> [[Float]] {
        guard !documents.isEmpty else {
            Task.detached { await logger.log("[EmbedModel] embedDocuments called with empty array") }
            return []
        }
        let texts = documents.map(\.text)
        let hasDocumentTitles = documents.contains { ($0.title?.isEmpty == false) }
        do {
            // Ensure backend is loaded; serialize load using isLoading flag to prevent racing callers
            let record = EmbeddingModelCatalog.activeRecord()
            if backend == nil || loadedRecordID != record.id {
                if isLoading {
                    // Wait briefly for an in-flight load to complete
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if backend == nil {
                    isLoading = true
                    Task.detached { await logger.log("[EmbedModel] Loading embedding backend for batch document embedding") }
                    defer { isLoading = false }
                    try load()
                }
            }
            guard let backend = backend else {
                Task.detached { await logger.log("[EmbedModel] embedDocuments: backend missing after load attempt") }
                return []
            }
            if !warmedUp {
                // Attempt a warmUp once
                await warmUp()
            }
            guard backend.isReady else {
                Task.detached { await logger.log("[EmbedModel] embedDocuments: backend not ready") }
                return []
            }
            // Mark active operation while embedding so callers can coordinate unloads
            activeOperations += 1
            defer { activeOperations = max(0, activeOperations - 1) }

            // Try specialized task first.
            do {
                return try backend.embedDocuments(documents, pooling: record.defaultPooling, normalize: record.normalize)
            } catch {
                let fallbackTask: EmbeddingTask = hasDocumentTitles ? .searchDocument : .generic
                Task.detached {
                    await logger.log("[EmbedModel] embedDocuments: searchDocument failed, falling back to \(fallbackTask) – \(error.localizedDescription)")
                }
                return try backend.embed(texts, task: fallbackTask, pooling: record.defaultPooling, normalize: record.normalize)
            }
        } catch {
            Task.detached { await logger.log("[EmbedModel] embedDocuments failed: \(error.localizedDescription)") }
            return []
        }
    }

    /// Batching with progress callback so UI can update continuously even if user navigates away
    func embedDocumentsWithProgress(_ texts: [String], onEvent: @escaping @Sendable (EmbeddingProgressEvent) -> Void) async -> [[Float]] {
        await embedDocumentsWithProgress(texts.map { EmbeddingDocumentInput(text: $0) }, onEvent: onEvent)
    }

    /// Batching with progress callback so UI can update continuously even if user navigates away
    func embedDocumentsWithProgress(_ documents: [EmbeddingDocumentInput], onEvent: @escaping @Sendable (EmbeddingProgressEvent) -> Void) async -> [[Float]] {
        guard !documents.isEmpty else { return [] }
        do {
            let record = EmbeddingModelCatalog.activeRecord()
            if backend == nil || loadedRecordID != record.id { try load() }
            guard let backend = backend as? LlamaEmbeddingBackend else {
                // If backend is not our llama backend, fall back to regular embedding
                return await embedDocuments(documents)
            }
            if !warmedUp { await warmUp() }
            guard backend.isReady else { return [] }
            // Keep track of an active embedding operation while this method runs
            activeOperations += 1
            defer { activeOperations = max(0, activeOperations - 1) }

            return try backend.embedDocumentsWithProgress(documents, pooling: record.defaultPooling, normalize: record.normalize, onEvent: onEvent)
        } catch {
            Task.detached { await logger.log("[EmbedModel] embedDocumentsWithProgress failed: \(error.localizedDescription)") }
            return []
        }
    }

    func embedDocumentsWithProgress(_ texts: [String], onProgress: @escaping @Sendable (Int, Int) -> Void) async -> [[Float]] {
        await embedDocumentsWithProgress(texts.map { EmbeddingDocumentInput(text: $0) }) { event in
            if case .itemCompleted(let done, let total) = event {
                Task { await logger.log("[Embed] Progress: \(done)/\(total)") }
                onProgress(done, total)
            }
        }
    }

    func embedDocument(_ text: String) async -> [Float] {
        await embedDocument(EmbeddingDocumentInput(text: text))
    }

    func embedDocument(_ document: EmbeddingDocumentInput) async -> [Float] {
        // Guard against invalid input
        guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Task.detached { await logger.log("[EmbedModel] embedDocument called with empty text") }
            return []
        }

        let results = await embedDocuments([document])
        if let first = results.first, !first.isEmpty {
            Task.detached { await logger.log("[EmbedModel] embedDocument: success, embedding dim=\(first.count)") }
            return first
        }
        return []

    }

    func embedQuery(_ text: String) async -> [Float] {
        // Guard against invalid input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Task.detached { await logger.log("[EmbedModel] embedQuery called with empty text") }
            return []
        }
        
        do { 
            let record = EmbeddingModelCatalog.activeRecord()
            if backend == nil || loadedRecordID != record.id {
                if isLoading {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if backend == nil {
                    isLoading = true
                    Task.detached { await logger.log("[EmbedModel] Loading embedding backend for query embedding") }
                    defer { isLoading = false }
                    try load()
                }
            }
            guard let backend = backend else {
                Task.detached { await logger.log("[EmbedModel] embedQuery: backend missing after load attempt") }
                return []
            }
            if !warmedUp { await warmUp() }
            guard backend.isReady else {
                Task.detached { await logger.log("[EmbedModel] embedQuery: backend not ready") }
                return []
            }
            let result = try backend.embed([text], task: .searchQuery, pooling: record.defaultPooling, normalize: record.normalize).first ?? []
            Task.detached { await logger.log("[EmbedModel] embedQuery: success, embedding dim=\(result.count)") }
            return result
        } catch { 
            Task.detached { await logger.log("[EmbedModel] embedQuery failed: \(error.localizedDescription)") }
            // Do not reset backend here; simply report failure
            return [] 
        }
    }
}
