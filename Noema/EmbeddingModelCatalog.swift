import Foundation

enum EmbeddingRuntimeFormat: String, Codable, CaseIterable, Sendable {
    case gguf
    case coreML
    case transformers
}

enum EmbeddingCatalogState: String, Codable, Sendable {
    case installable
    case gated
    case unsupported
}

struct EmbeddingTemplateSet: Codable, Equatable, Sendable {
    let revision: String
    let generic: String
    let query: String
    let document: String

    func format(_ text: String, task: EmbeddingTask, title: String? = nil) -> String {
        let template: String
        switch task {
        case .generic:
            template = generic
        case .searchQuery:
            template = query
        case .searchDocument:
            template = document
        }

        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return template
            .replacingOccurrences(of: "{{text}}", with: text)
            .replacingOccurrences(of: "{{title}}", with: resolvedTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EmbeddingModelArtifact: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let repoID: String
    let filename: String
    let quantization: String
    let runtime: EmbeddingRuntimeFormat
    let sizeBytes: Int64
    let downloadURL: URL?

    func directoryURL(recordID: String) -> URL {
        EmbeddingModelCatalog.directoryURL(for: recordID)
    }

    func localURL(recordID: String) -> URL {
        directoryURL(recordID: recordID).appendingPathComponent(filename)
    }
}

struct EmbeddingModelRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let publisher: String
    let summary: String
    let sizeTier: String
    let licenseLabel: String
    let catalogState: EmbeddingCatalogState
    let gatingReason: String?
    let isRecommended: Bool
    let dimension: Int
    let maxInputTokens: Int
    let runtimeContextTokens: Int
    let defaultPooling: EmbeddingPooling
    let normalize: Bool
    let templates: EmbeddingTemplateSet
    let artifacts: [EmbeddingModelArtifact]

    var primaryArtifact: EmbeddingModelArtifact? {
        artifacts.first
    }

    var isInstallable: Bool {
        catalogState == .installable && primaryArtifact?.downloadURL != nil
    }

    var installedURL: URL {
        guard let artifact = primaryArtifact else {
            return EmbeddingModelCatalog.directoryURL(for: id)
        }
        return artifact.localURL(recordID: id)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    var fingerprint: EmbeddingIndexFingerprint {
        EmbeddingIndexFingerprint(
            modelID: id,
            artifactID: primaryArtifact?.id ?? "none",
            artifactFilename: primaryArtifact?.filename ?? "",
            dimension: dimension,
            pooling: defaultPooling.rawValue,
            normalized: normalize,
            templateRevision: templates.revision,
            chunkTokenLimit: DatasetChunkingPolicy.maxTokensPerChunk
        )
    }
}

struct EmbeddingIndexFingerprint: Codable, Equatable, Sendable {
    let modelID: String
    let artifactID: String
    let artifactFilename: String
    let dimension: Int
    let pooling: String
    let normalized: Bool
    let templateRevision: String
    let chunkTokenLimit: Int
}

enum DatasetChunkingPolicy {
    static let maxTokensPerChunk = 1_200
}

enum EmbeddingModelCatalog {
    static let activeModelIDKey = "activeEmbeddingModelID"
    static let defaultModelID = "Qwen/Qwen3-Embedding-0.6B-GGUF"

    static let legacyIDAliases: [String: String] = [
        "milimyname/multilingual-e5-small-Q8_0-GGUF": "rodion-m/multilingual-e5-small-gguf",
        "cstr/multilingual-e5-small-GGUF": "rodion-m/multilingual-e5-small-gguf",
        "lm-kit/bge-m3-gguf": "ggml-org/bge-m3-Q8_0-GGUF",
        "djuna/jina-embeddings-v2-base-multilingual-GGUF": "nomic-ai/nomic-embed-text-v2-moe-GGUF"
    ]

    static var baseDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMModels/Embeddings", isDirectory: true)
    }

    static func directoryURL(for recordID: String) -> URL {
        var url = baseDirectory
        for component in recordID.split(separator: "/").map(String.init) {
            url.appendPathComponent(component, isDirectory: true)
        }
        return url
    }

    static func record(for id: String) -> EmbeddingModelRecord? {
        if let direct = records.first(where: { $0.id == id }) {
            return direct
        }
        if let aliased = legacyIDAliases[id] {
            return records.first { $0.id == aliased }
        }
        return nil
    }

    static func record(matchingDownloadIdentifier identifier: String) -> EmbeddingModelRecord? {
        records.first { record in
            record.id == identifier ||
                record.primaryArtifact?.repoID == identifier ||
                record.primaryArtifact?.id == identifier
        }
    }

    static func activeRecord() -> EmbeddingModelRecord {
        let stored = UserDefaults.standard.string(forKey: activeModelIDKey)
        if let stored, let record = record(for: stored) {
            if record.id != stored {
                UserDefaults.standard.set(record.id, forKey: activeModelIDKey)
            }
            return record
        }
        return record(for: defaultModelID) ?? records[0]
    }

    static func setActiveRecordID(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeModelIDKey)
    }

    static func currentIndexFingerprint() -> EmbeddingIndexFingerprint {
        activeRecord().fingerprint
    }

    static func filteredRecords(matching rawQuery: String) -> [EmbeddingModelRecord] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }

        return records.filter { record in
            [
                record.displayName,
                record.publisher,
                record.summary,
                record.licenseLabel,
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    static let records: [EmbeddingModelRecord] = [
        EmbeddingModelRecord(
            id: "nomic-ai/nomic-embed-text-v1.5",
            displayName: "Nomic Embed Text v1.5",
            publisher: "Nomic AI",
            summary: "Compatibility default for local dataset search.",
            sizeTier: "Small",
            licenseLabel: "Apache 2.0",
            catalogState: .installable,
            gatingReason: nil,
            isRecommended: false,
            dimension: 768,
            maxInputTokens: 2_048,
            runtimeContextTokens: 2_048,
            defaultPooling: .mean,
            normalize: true,
            templates: EmbeddingTemplateSet(
                revision: "nomic-v1",
                generic: "{{text}}",
                query: "search_query: {{text}}",
                document: "search_document: {{text}}"
            ),
            artifacts: [
                EmbeddingModelArtifact(
                    id: "nomic-v1.5-q4-k-m",
                    repoID: "nomic-ai/nomic-embed-text-v1.5-GGUF",
                    filename: "nomic-embed-text-v1.5.Q4_K_M.gguf",
                    quantization: "Q4_K_M",
                    runtime: .gguf,
                    sizeBytes: 335_544_320,
                    downloadURL: URL(string: "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf?download=1")
                )
            ]
        ),
        EmbeddingModelRecord(
            id: "Qwen/Qwen3-Embedding-0.6B-GGUF",
            displayName: "Qwen3 Embedding 0.6B",
            publisher: "Qwen",
            summary: "Recommended multilingual embedding model for most devices.",
            sizeTier: "Medium",
            licenseLabel: "Apache 2.0",
            catalogState: .installable,
            gatingReason: nil,
            isRecommended: true,
            dimension: 1_024,
            maxInputTokens: 32_768,
            runtimeContextTokens: 2_048,
            defaultPooling: .lastToken,
            normalize: true,
            templates: EmbeddingTemplateSet(
                revision: "qwen3-retrieval-v1",
                generic: "{{text}}",
                query: "Instruct: Given a document query, retrieve the most relevant chunk.\nQuery: {{text}}",
                document: "{{text}}"
            ),
            artifacts: [
                EmbeddingModelArtifact(
                    id: "qwen3-embedding-0.6b-q8-0",
                    repoID: "Qwen/Qwen3-Embedding-0.6B-GGUF",
                    filename: "Qwen3-Embedding-0.6B-Q8_0.gguf",
                    quantization: "Q8_0",
                    runtime: .gguf,
                    sizeBytes: 639_000_000,
                    downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf?download=1")
                )
            ]
        ),
        EmbeddingModelRecord(
            id: "Qwen/Qwen3-Embedding-4B-GGUF",
            displayName: "Qwen3 Embedding 4B",
            publisher: "Qwen",
            summary: "Higher-quality multilingual retrieval for Macs and high-RAM devices.",
            sizeTier: "Large",
            licenseLabel: "Apache 2.0",
            catalogState: .installable,
            gatingReason: nil,
            isRecommended: false,
            dimension: 2_560,
            maxInputTokens: 32_768,
            runtimeContextTokens: 2_048,
            defaultPooling: .lastToken,
            normalize: true,
            templates: EmbeddingTemplateSet(
                revision: "qwen3-retrieval-v1",
                generic: "{{text}}",
                query: "Instruct: Given a document query, retrieve the most relevant chunk.\nQuery: {{text}}",
                document: "{{text}}"
            ),
            artifacts: [
                EmbeddingModelArtifact(
                    id: "qwen3-embedding-4b-q4-k-m",
                    repoID: "Qwen/Qwen3-Embedding-4B-GGUF",
                    filename: "Qwen3-Embedding-4B-Q4_K_M.gguf",
                    quantization: "Q4_K_M",
                    runtime: .gguf,
                    sizeBytes: 2_500_000_000,
                    downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF/resolve/main/Qwen3-Embedding-4B-Q4_K_M.gguf?download=1")
                )
            ]
        ),
        EmbeddingModelRecord(
            id: "ggml-org/bge-m3-Q8_0-GGUF",
            displayName: "BGE-M3",
            publisher: "BAAI",
            summary: "Multilingual retrieval specialist with CLS-pooled dense embeddings and long-context support.",
            sizeTier: "Medium",
            licenseLabel: "MIT",
            catalogState: .installable,
            gatingReason: nil,
            isRecommended: false,
            dimension: 1_024,
            maxInputTokens: 8_192,
            runtimeContextTokens: 2_048,
            defaultPooling: .cls,
            normalize: true,
            templates: EmbeddingTemplateSet(
                revision: "bge-m3-v1",
                generic: "{{text}}",
                query: "{{text}}",
                document: "{{text}}"
            ),
            artifacts: [
                EmbeddingModelArtifact(
                    id: "bge-m3-q8-0",
                    repoID: "ggml-org/bge-m3-Q8_0-GGUF",
                    filename: "bge-m3-q8_0.gguf",
                    quantization: "Q8_0",
                    runtime: .gguf,
                    sizeBytes: 600_000_000,
                    downloadURL: URL(string: "https://huggingface.co/ggml-org/bge-m3-Q8_0-GGUF/resolve/main/bge-m3-q8_0.gguf?download=1")
                )
            ]
        ),
        EmbeddingModelRecord(
            id: "rodion-m/multilingual-e5-small-gguf",
            displayName: "Multilingual E5 Small",
            publisher: "intfloat",
            summary: "Compact multilingual encoder with query/passage prefixes and mean-pooled embeddings.",
            sizeTier: "Small",
            licenseLabel: "MIT",
            catalogState: .installable,
            gatingReason: nil,
            isRecommended: false,
            dimension: 384,
            maxInputTokens: 512,
            runtimeContextTokens: 512,
            defaultPooling: .mean,
            normalize: true,
            templates: EmbeddingTemplateSet(
                revision: "e5-v1",
                generic: "query: {{text}}",
                query: "query: {{text}}",
                document: "passage: {{text}}"
            ),
            artifacts: [
                EmbeddingModelArtifact(
                    id: "multilingual-e5-small-fp32",
                    repoID: "rodion-m/multilingual-e5-small-gguf",
                    filename: "multilingual-e5-small-fp32.gguf",
                    quantization: "F32",
                    runtime: .gguf,
                    sizeBytes: 476_369_248,
                    downloadURL: URL(string: "https://huggingface.co/rodion-m/multilingual-e5-small-gguf/resolve/main/multilingual-e5-small-fp32.gguf?download=1")
                )
            ]
        ),
        EmbeddingModelRecord(
            id: "unsloth/embeddinggemma-300m-GGUF",
            displayName: "EmbeddingGemma 300m",
            publisher: "Google",
            summary: "On-device-focused embedding model distributed under Google's Gemma Terms of Use.",
            sizeTier: "Small",
            licenseLabel: "Gemma terms",
            catalogState: .installable,
            gatingReason: nil,
            isRecommended: false,
            dimension: 768,
            maxInputTokens: 2_048,
            runtimeContextTokens: 2_048,
            defaultPooling: .lastToken,
            normalize: true,
            templates: EmbeddingTemplateSet(
                revision: "embeddinggemma-v1",
                generic: "task: search result | query: {{text}}",
                query: "task: search result | query: {{text}}",
                document: "title: {{title}}\n{{text}}"
            ),
            artifacts: [
                EmbeddingModelArtifact(
                    id: "embeddinggemma-300m-q8-0",
                    repoID: "unsloth/embeddinggemma-300m-GGUF",
                    filename: "embeddinggemma-300M-Q8_0.gguf",
                    quantization: "Q8_0",
                    runtime: .gguf,
                    sizeBytes: 325_000_000,
                    downloadURL: URL(string: "https://huggingface.co/unsloth/embeddinggemma-300m-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf?download=1")
                )
            ]
        ),
        EmbeddingModelRecord(
            id: "nomic-ai/nomic-embed-text-v2-moe-GGUF",
            displayName: "Nomic Embed Text v2 MoE",
            publisher: "Nomic AI",
            summary: "Official multilingual MoE encoder (100+ languages) with mean-pooled retrieval embeddings.",
            sizeTier: "Medium",
            licenseLabel: "Apache 2.0",
            catalogState: .installable,
            gatingReason: nil,
            isRecommended: false,
            dimension: 768,
            maxInputTokens: 512,
            runtimeContextTokens: 512,
            defaultPooling: .mean,
            normalize: true,
            templates: EmbeddingTemplateSet(
                revision: "nomic-v2-moe-v1",
                generic: "{{text}}",
                query: "search_query: {{text}}",
                document: "search_document: {{text}}"
            ),
            artifacts: [
                EmbeddingModelArtifact(
                    id: "nomic-embed-text-v2-moe-q4-k-m",
                    repoID: "nomic-ai/nomic-embed-text-v2-moe-GGUF",
                    filename: "nomic-embed-text-v2-moe.Q4_K_M.gguf",
                    quantization: "Q4_K_M",
                    runtime: .gguf,
                    sizeBytes: 300_000_000,
                    downloadURL: URL(string: "https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe-GGUF/resolve/main/nomic-embed-text-v2-moe.Q4_K_M.gguf?download=1")
                )
            ]
        ),
    ]
}
