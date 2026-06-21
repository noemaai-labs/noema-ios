import XCTest
@testable import Noema

final class EmbeddingModelCatalogTests: XCTestCase {
    func testCatalogIDsAreUnique() {
        let ids = EmbeddingModelCatalog.records.map(\.id)

        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertNotNil(EmbeddingModelCatalog.record(for: EmbeddingModelCatalog.defaultModelID))
    }

    func testAllCuratedRecordsAreInstallable() throws {
        let nomic = try XCTUnwrap(EmbeddingModelCatalog.record(for: "nomic-ai/nomic-embed-text-v1.5"))
        let qwenSmall = try XCTUnwrap(EmbeddingModelCatalog.record(for: "Qwen/Qwen3-Embedding-0.6B-GGUF"))
        let qwenLarge = try XCTUnwrap(EmbeddingModelCatalog.record(for: "Qwen/Qwen3-Embedding-4B-GGUF"))
        let bge = try XCTUnwrap(EmbeddingModelCatalog.record(for: "ggml-org/bge-m3-Q8_0-GGUF"))
        let e5 = try XCTUnwrap(EmbeddingModelCatalog.record(for: "rodion-m/multilingual-e5-small-gguf"))
        let gemma = try XCTUnwrap(EmbeddingModelCatalog.record(for: "unsloth/embeddinggemma-300m-GGUF"))
        let nomicV2 = try XCTUnwrap(EmbeddingModelCatalog.record(for: "nomic-ai/nomic-embed-text-v2-moe-GGUF"))

        XCTAssertTrue(nomic.isInstallable)
        XCTAssertTrue(qwenSmall.isInstallable)
        XCTAssertTrue(qwenLarge.isInstallable)
        XCTAssertTrue(qwenSmall.isRecommended)
        XCTAssertTrue(bge.isInstallable)
        XCTAssertTrue(e5.isInstallable)
        XCTAssertTrue(gemma.isInstallable)
        XCTAssertTrue(nomicV2.isInstallable)
    }

    func testEveryCatalogRecordIsInstallable() {
        for record in EmbeddingModelCatalog.records {
            XCTAssertEqual(record.catalogState, .installable, "\(record.id) must be installable")
            XCTAssertNil(record.gatingReason, "\(record.id) must not carry a gating reason")
            XCTAssertTrue(record.isInstallable, "\(record.id) must report isInstallable == true")
            let artifact = record.primaryArtifact
            XCTAssertNotNil(artifact, "\(record.id) must expose a primary artifact")
            XCTAssertNotNil(artifact?.downloadURL, "\(record.id) artifact must have a download URL")
            XCTAssertGreaterThan(artifact?.sizeBytes ?? 0, 0, "\(record.id) artifact must declare a non-zero size")
        }
    }

    func testBGEM3UsesCLSPooling() throws {
        let bge = try XCTUnwrap(EmbeddingModelCatalog.record(for: "ggml-org/bge-m3-Q8_0-GGUF"))
        XCTAssertEqual(bge.defaultPooling, .cls, "BGE-M3 dense embeddings must use CLS pooling per its model card")
        XCTAssertEqual(bge.fingerprint.pooling, EmbeddingPooling.cls.rawValue)
    }

    func testQwenEmbeddingRecordsPreservePoolingAndTemplateFields() throws {
        let qwenSmall = try XCTUnwrap(EmbeddingModelCatalog.record(for: "Qwen/Qwen3-Embedding-0.6B-GGUF"))
        let qwenLarge = try XCTUnwrap(EmbeddingModelCatalog.record(for: "Qwen/Qwen3-Embedding-4B-GGUF"))

        for record in [qwenSmall, qwenLarge] {
            XCTAssertEqual(record.defaultPooling, .lastToken)
            XCTAssertEqual(record.runtimeContextTokens, 2_048)
            XCTAssertEqual(record.templates.revision, "qwen3-retrieval-v1")
            XCTAssertEqual(record.fingerprint.pooling, EmbeddingPooling.lastToken.rawValue)
            XCTAssertEqual(record.fingerprint.templateRevision, "qwen3-retrieval-v1")
        }
    }

    func testEmbeddingArtifactPathsUseRecordScopedDirectories() throws {
        let nomic = try XCTUnwrap(EmbeddingModelCatalog.record(for: "nomic-ai/nomic-embed-text-v1.5"))
        let artifact = try XCTUnwrap(nomic.primaryArtifact)

        XCTAssertTrue(
            artifact.directoryURL(recordID: nomic.id).path.hasSuffix("LocalLLMModels/Embeddings/nomic-ai/nomic-embed-text-v1.5")
        )
        XCTAssertTrue(
            artifact.localURL(recordID: nomic.id).path.hasSuffix("LocalLLMModels/Embeddings/nomic-ai/nomic-embed-text-v1.5/nomic-embed-text-v1.5.Q4_K_M.gguf")
        )
    }

    func testTemplatesForCatalogModels() throws {
        let nomic = try XCTUnwrap(EmbeddingModelCatalog.record(for: "nomic-ai/nomic-embed-text-v1.5"))
        let qwen = try XCTUnwrap(EmbeddingModelCatalog.record(for: "Qwen/Qwen3-Embedding-0.6B-GGUF"))
        let e5 = try XCTUnwrap(EmbeddingModelCatalog.record(for: "rodion-m/multilingual-e5-small-gguf"))
        let bge = try XCTUnwrap(EmbeddingModelCatalog.record(for: "ggml-org/bge-m3-Q8_0-GGUF"))
        let gemma = try XCTUnwrap(EmbeddingModelCatalog.record(for: "unsloth/embeddinggemma-300m-GGUF"))
        let nomicV2 = try XCTUnwrap(EmbeddingModelCatalog.record(for: "nomic-ai/nomic-embed-text-v2-moe-GGUF"))

        XCTAssertEqual(nomic.templates.format("neural search", task: .searchQuery), "search_query: neural search")
        XCTAssertEqual(nomic.templates.format("chunk", task: .searchDocument), "search_document: chunk")
        XCTAssertEqual(
            qwen.templates.format("climate policy", task: .searchQuery),
            "Instruct: Given a document query, retrieve the most relevant chunk.\nQuery: climate policy"
        )
        XCTAssertEqual(qwen.templates.format("raw document", task: .searchDocument), "raw document")
        XCTAssertEqual(e5.templates.format("bonjour", task: .searchQuery), "query: bonjour")
        XCTAssertEqual(e5.templates.format("bonjour", task: .searchDocument), "passage: bonjour")
        XCTAssertEqual(bge.templates.format("plain", task: .searchQuery), "plain")
        XCTAssertEqual(gemma.templates.format("body", task: .searchDocument, title: "Doc"), "title: Doc\nbody")
        XCTAssertEqual(nomicV2.templates.format("climate policy", task: .searchQuery), "search_query: climate policy")
        XCTAssertEqual(nomicV2.templates.format("raw document", task: .searchDocument), "search_document: raw document")
    }

    func testFilteredRecordsMatchesDisplayNamePublisherSummaryAndLicense() throws {
        let byDisplayName = EmbeddingModelCatalog.filteredRecords(matching: "BGE-M3")
        XCTAssertEqual(byDisplayName.map(\.id), ["ggml-org/bge-m3-Q8_0-GGUF"])

        let byPublisher = EmbeddingModelCatalog.filteredRecords(matching: "google")
        XCTAssertEqual(byPublisher.map(\.id), ["unsloth/embeddinggemma-300m-GGUF"])

        let bySummary = EmbeddingModelCatalog.filteredRecords(matching: "multilingual retrieval")
        XCTAssertTrue(bySummary.contains { $0.id == "ggml-org/bge-m3-Q8_0-GGUF" })

        let byLicense = EmbeddingModelCatalog.filteredRecords(matching: "gemma terms")
        XCTAssertEqual(byLicense.map(\.id), ["unsloth/embeddinggemma-300m-GGUF"])

        XCTAssertTrue(EmbeddingModelCatalog.filteredRecords(matching: "   ").count == EmbeddingModelCatalog.records.count)
        XCTAssertTrue(EmbeddingModelCatalog.filteredRecords(matching: "does-not-exist").isEmpty)
    }

    func testFingerprintChangesForAllIndexedModelFields() {
        let base = EmbeddingIndexFingerprint(
            modelID: "a",
            artifactID: "artifact-a",
            artifactFilename: "a.gguf",
            dimension: 768,
            pooling: EmbeddingPooling.mean.rawValue,
            normalized: true,
            templateRevision: "v1",
            chunkTokenLimit: 1_200
        )

        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: "b", artifactID: base.artifactID, artifactFilename: base.artifactFilename, dimension: base.dimension, pooling: base.pooling, normalized: base.normalized, templateRevision: base.templateRevision, chunkTokenLimit: base.chunkTokenLimit))
        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: base.modelID, artifactID: "artifact-b", artifactFilename: base.artifactFilename, dimension: base.dimension, pooling: base.pooling, normalized: base.normalized, templateRevision: base.templateRevision, chunkTokenLimit: base.chunkTokenLimit))
        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: base.modelID, artifactID: base.artifactID, artifactFilename: "b.gguf", dimension: base.dimension, pooling: base.pooling, normalized: base.normalized, templateRevision: base.templateRevision, chunkTokenLimit: base.chunkTokenLimit))
        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: base.modelID, artifactID: base.artifactID, artifactFilename: base.artifactFilename, dimension: 1_024, pooling: base.pooling, normalized: base.normalized, templateRevision: base.templateRevision, chunkTokenLimit: base.chunkTokenLimit))
        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: base.modelID, artifactID: base.artifactID, artifactFilename: base.artifactFilename, dimension: base.dimension, pooling: EmbeddingPooling.lastToken.rawValue, normalized: base.normalized, templateRevision: base.templateRevision, chunkTokenLimit: base.chunkTokenLimit))
        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: base.modelID, artifactID: base.artifactID, artifactFilename: base.artifactFilename, dimension: base.dimension, pooling: base.pooling, normalized: false, templateRevision: base.templateRevision, chunkTokenLimit: base.chunkTokenLimit))
        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: base.modelID, artifactID: base.artifactID, artifactFilename: base.artifactFilename, dimension: base.dimension, pooling: base.pooling, normalized: base.normalized, templateRevision: "v2", chunkTokenLimit: base.chunkTokenLimit))
        XCTAssertNotEqual(base, EmbeddingIndexFingerprint(modelID: base.modelID, artifactID: base.artifactID, artifactFilename: base.artifactFilename, dimension: base.dimension, pooling: base.pooling, normalized: base.normalized, templateRevision: base.templateRevision, chunkTokenLimit: 900))
    }

    func testEmbeddingDownloadOwnerDecodesLegacyRepoOnlyPayload() throws {
        let data = Data(#"{"repoID":"nomic-ai/nomic-embed-text-v1.5-GGUF"}"#.utf8)

        let owner = try JSONDecoder().decode(EmbeddingDownloadOwner.self, from: data)

        XCTAssertNil(owner.recordID)
        XCTAssertNil(owner.artifactID)
        XCTAssertEqual(owner.repoID, "nomic-ai/nomic-embed-text-v1.5-GGUF")
        XCTAssertEqual(owner.externalID, "nomic-ai/nomic-embed-text-v1.5-GGUF")
    }

    func testEmbeddingDownloadOwnerEncodesRecordArtifactMetadata() throws {
        let record = try XCTUnwrap(EmbeddingModelCatalog.record(for: "Qwen/Qwen3-Embedding-0.6B-GGUF"))
        let artifact = try XCTUnwrap(record.primaryArtifact)

        let data = try JSONEncoder().encode(EmbeddingDownloadOwner(record: record, artifact: artifact))
        let decoded = try JSONDecoder().decode(EmbeddingDownloadOwner.self, from: data)

        XCTAssertEqual(decoded.recordID, record.id)
        XCTAssertEqual(decoded.artifactID, artifact.id)
        XCTAssertEqual(decoded.repoID, artifact.repoID)
        XCTAssertEqual(decoded.filename, artifact.filename)
        XCTAssertEqual(decoded.externalID, record.id)
    }

    func testSupportInventoryReportsActiveEmbeddingInstallState() throws {
        let record = try XCTUnwrap(EmbeddingModelCatalog.record(for: EmbeddingModelCatalog.defaultModelID))
        EmbeddingModelCatalog.setActiveRecordID(record.id)
        let directory = EmbeddingModelCatalog.directoryURL(for: record.id)
        try? FileManager.default.removeItem(at: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removeObject(forKey: EmbeddingModelCatalog.activeModelIDKey)
        }

        XCTAssertEqual(SupportModelInventory.embeddingItem(embeddingItems: []).state, .missing)

        let fileURL = record.installedURL
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("embedding".utf8).write(to: fileURL)

        let item = SupportModelInventory.embeddingItem(embeddingItems: [])
        XCTAssertEqual(item.titleKey, "Embeddings")
        XCTAssertEqual(item.state, .ready)
    }

    func testSupportInventoryReportsEmbeddingDownloadState() throws {
        let record = try XCTUnwrap(EmbeddingModelCatalog.record(for: EmbeddingModelCatalog.defaultModelID))
        var downloadItem = DownloadController.EmbeddingItem(record: record)
        downloadItem.status = .downloading
        downloadItem.progress = 0.42

        let item = SupportModelInventory.embeddingItem(embeddingItems: [downloadItem])

        XCTAssertEqual(item.state, .downloading)
        XCTAssertEqual(item.progress, 0.42)
    }
}
