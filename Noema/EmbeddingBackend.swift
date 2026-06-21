// EmbeddingBackend.swift
import Foundation

enum EmbeddingError: Error, LocalizedError {
    case modelMissing
    case notConfigured
    case loadFailed(String)
    case embedFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Embedding model file missing"
        case .notConfigured: return "Embedding backend not loaded"
        case .loadFailed(let s): return "Failed to load embeddings backend: \(s)"
        case .embedFailed: return "Failed to compute embeddings"
        }
    }
}

enum EmbeddingTask: Sendable {
    case generic
    case searchQuery
    case searchDocument
}

struct EmbeddingDocumentInput: Sendable, Equatable {
    let text: String
    let title: String?

    init(text: String, title: String? = nil) {
        self.text = text
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
    }
}

enum EmbeddingWarmUpPhase: Sendable {
    case loadingModel
    case primingFirstPass
}

enum EmbeddingProgressEvent: Sendable {
    case heartbeat(current: Int, total: Int)
    case itemCompleted(completed: Int, total: Int)
}

enum EmbeddingPooling: String, Codable, CaseIterable, Sendable {
    case modelDefault
    case mean
    case cls
    case lastToken

    var nativeRawValue: Int32 {
        switch self {
        case .modelDefault:
            return -1
        case .mean:
            return 1
        case .cls:
            return 2
        case .lastToken:
            return 3
        }
    }
}

protocol EmbeddingsBackend: AnyObject {
    var isReady: Bool { get }
    var dimension: Int { get }

    func load() throws
    func warmUp() throws
    func countTokens(_ text: String) throws -> Int
    func embed(
        _ texts: [String],
        task: EmbeddingTask,
        pooling: EmbeddingPooling,
        normalize: Bool
    ) throws -> [[Float]]
    func embedDocuments(
        _ documents: [EmbeddingDocumentInput],
        pooling: EmbeddingPooling,
        normalize: Bool
    ) throws -> [[Float]]
    /// Unload/free any native resources and stop background work. After this call
    /// the backend should be considered unusable until `load()` is called again.
    func unload()
}
