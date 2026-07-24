import Foundation

/// Comprehensive error types for Noema application
enum NoemaError: Error, LocalizedError {
    case modelNotFound(path: String)
    case modelLoadFailed(format: ModelFormat, reason: String)
    case unsupportedModelFormat(ModelFormat)
    case insufficientMemory(required: Int, available: Int)

    case backendNotAvailable(String)
    case backendInitializationFailed(String)
    case contextCreationFailed(reason: String)

    case generationFailed(reason: String)
    case tokenizationFailed(text: String)
    case streamingError(String)

    case embeddingModelMissing
    case embeddingFailed(reason: String)
    case invalidEmbeddingDimension(expected: Int, actual: Int)

    case datasetNotFound(id: String)
    case chunkingFailed(reason: String)
    case retrievalFailed(reason: String)
    case vectorDatabaseCorrupted(dataset: String)

    case downloadFailed(url: String, reason: String)
    case networkUnavailable
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model file not found at: \(path)"
        case .modelLoadFailed(let format, let reason):
            return "Failed to load \(format) model: \(reason)"
        case .unsupportedModelFormat(let format):
            return "Model format '\(format)' is not supported in this build"
        case .insufficientMemory(let required, let available):
            return "Insufficient memory: \(required)MB required, \(available)MB available"
            
        case .backendNotAvailable(let backend):
            return "\(backend) backend is not available in this build"
        case .backendInitializationFailed(let reason):
            return "Backend initialization failed: \(reason)"
        case .contextCreationFailed(let reason):
            return "Failed to create context: \(reason)"
            
        case .generationFailed(let reason):
            return "Text generation failed: \(reason)"
        case .tokenizationFailed(let text):
            return "Failed to tokenize text: \(String(text.prefix(50)))..."
        case .streamingError(let reason):
            return "Streaming error: \(reason)"
            
        case .embeddingModelMissing:
            return "Embedding model not found. Please download the required model."
        case .embeddingFailed(let reason):
            return "Embedding generation failed: \(reason)"
        case .invalidEmbeddingDimension(let expected, let actual):
            return "Invalid embedding dimension: expected \(expected), got \(actual)"
            
        case .datasetNotFound(let id):
            return "Dataset not found: \(id)"
        case .chunkingFailed(let reason):
            return "Failed to chunk document: \(reason)"
        case .retrievalFailed(let reason):
            return "Failed to retrieve context: \(reason)"
        case .vectorDatabaseCorrupted(let dataset):
            return "Vector database corrupted for dataset: \(dataset)"
            
        case .downloadFailed(let url, let reason):
            return "Download failed for \(url): \(reason)"
        case .networkUnavailable:
            return "Network connection unavailable"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .modelNotFound:
            return "Please download the model from the Models tab."
        case .modelLoadFailed:
            return "Try redownloading the model or selecting a different one."
        case .unsupportedModelFormat:
            return "This model format requires a different build configuration."
        case .insufficientMemory:
            return "Close other applications or try a smaller model."
            
        case .backendNotAvailable:
            return "Install the required dependencies or use a different model format."
        case .backendInitializationFailed, .contextCreationFailed:
            return "Restart the app and try again."
            
        case .generationFailed, .tokenizationFailed, .streamingError:
            return "Check the model compatibility and try again."
            
        case .embeddingModelMissing:
            return "Download the embedding model from Settings."
        case .embeddingFailed:
            return "Check the embedding model installation and try again."
        case .invalidEmbeddingDimension:
            return "The embedding model may be incompatible. Try reinstalling."
            
        case .datasetNotFound:
            return "Re-import the dataset or select a different one."
        case .chunkingFailed, .retrievalFailed:
            return "Check the dataset format and try again."
        case .vectorDatabaseCorrupted:
            return "Rebuild the vector index for this dataset."
            
        case .downloadFailed:
            return "Check your internet connection and try again."
        case .networkUnavailable:
            return "Connect to the internet and retry."
        }
    }
}

/// Extension for converting existing errors to NoemaError
extension NoemaError {
    static func from(_ error: Error, context: String = "") -> NoemaError {
        if let noemaError = error as? NoemaError {
            return noemaError
        }
        
        let nsError = error as NSError
        let description = nsError.localizedDescription
        
        // Try to categorize based on error domain and code
        switch nsError.domain {
        case "Noema":
            if description.contains("backend") || description.contains("Backend") {
                return .backendInitializationFailed(description)
            } else if description.contains("model") || description.contains("Model") {
                return .modelLoadFailed(format: .gguf, reason: description)
            }
        case NSURLErrorDomain:
            return .downloadFailed(url: context, reason: description)
        default:
            break
        }

        return .generationFailed(reason: description)
    }
}