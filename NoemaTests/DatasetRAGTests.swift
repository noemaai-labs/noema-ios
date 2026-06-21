import XCTest
@testable import Noema

final class DatasetRAGTests: XCTestCase {
    private struct StoredVectorFixture: Codable {
        let text: String
        let vector: [Float]
        let source: String?
    }

    func testUniqueRelativePathAddsSuffixForDuplicateBasenames() {
        let first = DatasetPathing.uniqueRelativePath("chapter.txt", existing: [])
        let second = DatasetPathing.uniqueRelativePath("chapter.txt", existing: [first])
        let third = DatasetPathing.uniqueRelativePath("chapter.txt", existing: [first, second])

        XCTAssertEqual(first, "chapter.txt")
        XCTAssertEqual(second, "chapter (2).txt")
        XCTAssertEqual(third, "chapter (3).txt")
    }

    func testDownloadControllerDatasetHelpersPreserveNestedRelativePaths() {
        let first = DownloadController.datasetDestinationURL(for: "owner/book", relativePath: "a/chapter.txt")
        let second = DownloadController.datasetDestinationURL(for: "owner/book", relativePath: "b/chapter.txt")

        XCTAssertTrue(first.path.hasSuffix("/LocalLLMDatasets/owner/book/a/chapter.txt"))
        XCTAssertTrue(second.path.hasSuffix("/LocalLLMDatasets/owner/book/b/chapter.txt"))
        XCTAssertNotEqual(first, second)

        let firstArtifact = DownloadController.datasetArtifactID(relativePath: "a/chapter.txt")
        let secondArtifact = DownloadController.datasetArtifactID(relativePath: "b/chapter.txt")
        XCTAssertNotEqual(firstArtifact, secondArtifact)
    }

    func testRetrievalRankerDiversifiesSourcesBeforeRepeats() {
        let candidates = [
            DatasetRetrievalCandidate(score: 0.95, source: "a/ch1.txt", payload: "a1"),
            DatasetRetrievalCandidate(score: 0.94, source: "a/ch1.txt", payload: "a2"),
            DatasetRetrievalCandidate(score: 0.93, source: "b/ch2.txt", payload: "b1"),
            DatasetRetrievalCandidate(score: 0.92, source: "c/ch3.txt", payload: "c1"),
        ]

        let selected = DatasetRetrievalRanker.select(candidates, maxChunks: 3, minScore: 0.5)

        XCTAssertEqual(selected.map(\.payload), ["a1", "b1", "c1"])
    }

    func testEnterpriseManifestIsInternalRelativePath() {
        XCTAssertTrue(DatasetStorage.isInternalRelativePath(DatasetStorage.enterpriseManifestFilename))
        XCTAssertTrue(DatasetStorage.isInternalRelativePath("./" + DatasetStorage.enterpriseManifestFilename))
        XCTAssertFalse(DatasetStorage.isInternalRelativePath("handbook.pdf"))
        XCTAssertFalse(DatasetStorage.isInternalRelativePath("nested/" + DatasetStorage.enterpriseManifestFilename))
    }

    func testStrippingInternalSectionsRemovesEnterpriseManifestSection() {
        let text = """
        <<<FILE: handbook.txt>>>
        Vacation policy: 25 days.

        <<<FILE: \(DatasetStorage.enterpriseManifestFilename)>>>
        {"tenantID":"tenant-1","allowedRoleIDs":["admin"]}

        <<<FILE: onboarding.txt>>>
        Welcome to the company.
        """

        let stripped = DatasetSourceMarkers.strippingInternalSections(from: text)

        XCTAssertTrue(stripped.contains("Vacation policy: 25 days."))
        XCTAssertTrue(stripped.contains("Welcome to the company."))
        XCTAssertTrue(stripped.contains("<<<FILE: handbook.txt>>>"))
        XCTAssertFalse(stripped.contains(DatasetStorage.enterpriseManifestFilename))
        XCTAssertFalse(stripped.contains("tenant-1"))
        XCTAssertFalse(stripped.contains("allowedRoleIDs"))
    }

    func testStrippingInternalSectionsLeavesMarkerlessTextUntouched() {
        let text = "Plain dataset text with no markers."
        XCTAssertEqual(DatasetSourceMarkers.strippingInternalSections(from: text), text)
    }

    func testSourceMarkerRoundTrip() {
        let marker = DatasetSourceMarkers.marker(forRelativePath: "docs/guide.md")
        XCTAssertEqual(marker, "<<<FILE: docs/guide.md>>>")
        XCTAssertEqual(DatasetSourceMarkers.sourcePath(fromLine: marker), "docs/guide.md")
        XCTAssertNil(DatasetSourceMarkers.sourcePath(fromLine: "regular line"))
        XCTAssertNil(DatasetSourceMarkers.sourcePath(fromLine: "<<<FILE: >>>"))
    }

    func testDatasetTextReaderDecodesLatin1AndWindows1252() {
        let data = Data([0x63, 0x61, 0x66, 0xE9])

        XCTAssertEqual(DatasetTextReader.string(from: data), "café")
    }

    func testEmbeddingTitlePrefersSourceMarkerOverDatasetTitle() {
        let title = DatasetRetriever.titleForEmbedding(
            source: "chapters/unit-1_intro.pdf",
            datasetTitle: "Fallback Dataset"
        )

        XCTAssertEqual(title, "unit 1 intro")
    }

    func testEmbeddingTitleFallsBackToDatasetTitleWhenSourceMissing() {
        let title = DatasetRetriever.titleForEmbedding(source: nil, datasetTitle: "Course Reader")

        XCTAssertEqual(title, "Course Reader")
    }

    func testEmbeddingTitleReturnsNilWhenNoSourceOrDatasetTitleExists() {
        XCTAssertNil(DatasetRetriever.titleForEmbedding(source: nil, datasetTitle: "   "))
    }

    func testDatasetIndexIORequiresMetadataAndPositiveChunkCount() throws {
        let dir = try makeTempDirectory(prefix: "dataset-index-")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeVectors(to: dir, dimension: EmbeddingModelCatalog.currentIndexFingerprint().dimension)

        XCTAssertFalse(DatasetIndexIO.hasValidIndex(at: dir))

        DatasetIndexIO.writeMetadata(DatasetIndexMetadata(chunkCount: 0), to: dir)
        XCTAssertFalse(DatasetIndexIO.hasValidIndex(at: dir))

        DatasetIndexIO.writeMetadata(DatasetIndexMetadata(chunkCount: 2), to: dir)
        XCTAssertTrue(DatasetIndexIO.hasValidIndex(at: dir))
    }

    func testDatasetIndexIOMarksLegacySchemaV2MetadataStaleWithoutDeletingArtifacts() throws {
        let dir = try makeTempDirectory(prefix: "dataset-index-legacy-")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeVectors(to: dir, dimension: EmbeddingModelCatalog.currentIndexFingerprint().dimension)
        let legacyMetadata = """
        {
          "schemaVersion": 2,
          "sourceLabelMode": "relativePath",
          "chunkCount": 1,
          "createdAt": 0
        }
        """
        try Data(legacyMetadata.utf8).write(to: DatasetIndexIO.metadataURL(for: dir))

        XCTAssertTrue(DatasetIndexIO.hasIndexArtifacts(at: dir))
        XCTAssertFalse(DatasetIndexIO.hasValidIndex(at: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DatasetIndexIO.vectorsURL(for: dir).path))
    }

    func testDatasetIndexIORejectsVectorDimensionMismatch() throws {
        let dir = try makeTempDirectory(prefix: "dataset-index-dim-")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fingerprint = EmbeddingModelCatalog.currentIndexFingerprint()
        try writeVectors(to: dir, dimension: fingerprint.dimension + 1)
        DatasetIndexIO.writeMetadata(DatasetIndexMetadata(chunkCount: 1, embeddingFingerprint: fingerprint), to: dir)

        XCTAssertFalse(DatasetIndexIO.hasValidIndex(at: dir))
        XCTAssertEqual(DatasetIndexIO.firstVectorDimension(at: dir), fingerprint.dimension + 1)
    }

    func testDatasetFileSupportTotalsIncludeAllSupportedFormats() {
        let files = [
            DatasetFile(id: "1", name: "book.epub", sizeBytes: 10, downloadURL: URL(string: "https://example.com/book")!),
            DatasetFile(id: "2", name: "chapter.txt", sizeBytes: 20, downloadURL: URL(string: "https://example.com/chapter")!),
            DatasetFile(id: "3", name: "notes.json", sizeBytes: 30, downloadURL: URL(string: "https://example.com/notes")!),
            DatasetFile(id: "4", name: "table.csv", sizeBytes: 40, downloadURL: URL(string: "https://example.com/table")!),
            DatasetFile(id: "5", name: "cover.jpg", sizeBytes: 50, downloadURL: URL(string: "https://example.com/cover.jpg")!),
        ]

        XCTAssertEqual(DatasetFileSupport.totalSupportedSize(files: files), 100)
    }

    func testRAGPackingReturnsAllRequestedChunksWhenBudgetAllows() async {
        let chunks: [(text: String, source: String?, score: Float?)] = [
            (String(repeating: "A", count: 40), "a.txt", nil),
            (String(repeating: "B", count: 40), "b.txt", nil),
            (String(repeating: "C", count: 40), "c.txt", nil),
        ]

        let packed = await ChatVM.packRAGContext(
            chunks: chunks,
            requestedMaxChunks: 3,
            usablePromptTokens: 1_024,
            promptTokenCounter: { $0.count },
            promptBuilder: { $0 }
        )

        XCTAssertEqual(packed.retrievedChunkCount, 3)
        XCTAssertEqual(packed.injectedChunkCount, 3)
        XCTAssertEqual(packed.trimmedChunkCount, 0)
        XCTAssertFalse(packed.partialChunkInjected)
        XCTAssertEqual(packed.injectedCitations.count, 3)
        XCTAssertTrue(packed.injectedContext.contains("[1] (a.txt)"))
        XCTAssertTrue(packed.injectedContext.contains("[2] (b.txt)"))
        XCTAssertTrue(packed.injectedContext.contains("[3] (c.txt)"))
    }

    func testRAGPackingReducesToTwoChunksWhenBudgetOnlyFitsTwo() async {
        let chunks: [(text: String, source: String?, score: Float?)] = [
            (String(repeating: "A", count: 90), "a.txt", nil),
            (String(repeating: "B", count: 90), "b.txt", nil),
            (String(repeating: "C", count: 90), "c.txt", nil),
            (String(repeating: "D", count: 90), "d.txt", nil),
            (String(repeating: "E", count: 90), "e.txt", nil),
        ]

        let packed = await ChatVM.packRAGContext(
            chunks: chunks,
            requestedMaxChunks: 5,
            usablePromptTokens: 256,
            promptTokenCounter: { $0.count },
            promptBuilder: { $0 }
        )

        XCTAssertEqual(packed.contextBudgetTokens, 256)
        XCTAssertEqual(packed.retrievedChunkCount, 5)
        XCTAssertEqual(packed.injectedChunkCount, 2)
        XCTAssertEqual(packed.trimmedChunkCount, 3)
        XCTAssertFalse(packed.partialChunkInjected)
        XCTAssertEqual(packed.injectedCitations.count, packed.injectedChunkCount)
        XCTAssertTrue(packed.injectedContext.contains("[1] (a.txt)"))
        XCTAssertTrue(packed.injectedContext.contains("[2] (b.txt)"))
        XCTAssertFalse(packed.injectedContext.contains("[3] (c.txt)"))
    }

    func testRAGPackingFallsBackToPartialTopChunkWhenNothingFitsWhole() async {
        let original = String(repeating: "A", count: 500)
        let packed = await ChatVM.packRAGContext(
            chunks: [(text: original, source: "a.txt", score: nil)],
            requestedMaxChunks: 1,
            usablePromptTokens: 256,
            promptTokenCounter: { $0.count },
            promptBuilder: { $0 }
        )

        XCTAssertEqual(packed.retrievedChunkCount, 1)
        XCTAssertEqual(packed.injectedChunkCount, 1)
        XCTAssertTrue(packed.partialChunkInjected)
        XCTAssertEqual(packed.injectedCitations.count, packed.injectedChunkCount)
        XCTAssertLessThan(packed.injectedCitations[0].text.count, original.count)
        XCTAssertTrue(packed.injectedContext.contains("[1] (a.txt)"))
    }

    func testRAGInjectionInfoRoundTripsThroughCodable() throws {
        let info = ChatVM.Msg.RAGInjectionInfo(
            datasetName: "Handbook",
            stage: .injected,
            method: .rag,
            requestedMaxChunks: 5,
            retrievedChunkCount: 4,
            injectedChunkCount: 2,
            trimmedChunkCount: 2,
            partialChunkInjected: false,
            fullContentEstimateTokens: 1800,
            configuredContextTokens: 4_096,
            reservedResponseTokens: 512,
            contextBudgetTokens: 900,
            injectedContextTokens: 420,
            decisionReason: "2 of 4 chunks fit."
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ChatVM.Msg.RAGInjectionInfo.self, from: data)

        XCTAssertEqual(decoded, info)
    }

    func testFullContentMessageRoundTripsWithoutPreviewCitations() throws {
        let info = ChatVM.Msg.RAGInjectionInfo(
            datasetName: "Manual",
            stage: .injected,
            method: .fullContent,
            requestedMaxChunks: 5,
            retrievedChunkCount: 0,
            injectedChunkCount: 0,
            trimmedChunkCount: 0,
            partialChunkInjected: false,
            fullContentEstimateTokens: 1200,
            configuredContextTokens: 4_096,
            reservedResponseTokens: 512,
            contextBudgetTokens: 900,
            injectedContextTokens: 850,
            decisionReason: "Using the full document."
        )
        var msg = ChatVM.Msg(role: "🤖", text: "Answer")
        msg.retrievedContext = "Full document text"
        msg.citations = []
        msg.ragInjectionInfo = info

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: data)

        XCTAssertEqual(decoded.ragInjectionInfo?.method, .fullContent)
        XCTAssertEqual(decoded.citations ?? [], [])
        XCTAssertEqual(decoded.retrievedContext, "Full document text")
    }

    func testRAGPackingUsesFullPromptBudgetInsteadOfFixedEightyPercentWindow() async {
        let chunk = String(repeating: "A", count: 12_000)
        let packed = await ChatVM.packRAGContext(
            chunks: [
                (text: chunk, source: "a.txt", score: nil),
                (text: chunk, source: "b.txt", score: nil),
                (text: chunk, source: "c.txt", score: nil),
            ],
            requestedMaxChunks: 3,
            usablePromptTokens: ChatVM.promptBudget(for: 50_000).usablePromptTokens,
            promptTokenCounter: { $0.count },
            promptBuilder: { context in
                String(repeating: "P", count: 6_000) + context
            }
        )

        XCTAssertEqual(packed.injectedChunkCount, 3)
        XCTAssertEqual(packed.trimmedChunkCount, 0)
    }

    func testFullContextInjectionAllowsFitThatOldSixtyPercentThresholdWouldReject() async {
        let decision = await ChatVM.evaluateFullContextInjection(
            fullContext: String(repeating: "D", count: 7_000),
            contextLimit: 10_000,
            promptBuilder: { context in
                String(repeating: "P", count: 1_000) + context
            },
            promptTokenCounter: { $0.count }
        )

        XCTAssertEqual(decision.budget.usablePromptTokens, 9_488)
        XCTAssertEqual(decision.fullContextTokens, 7_000)
        XCTAssertEqual(decision.promptTokens, 8_000)
        XCTAssertTrue(decision.fits)
    }

    func testFullContextInjectionStaysUsableUntilPromptGrowthForcesRAG() async {
        let contextLimit = 10_000.0
        let fullContext = String(repeating: "D", count: 7_000)

        let firstTurn = await ChatVM.evaluateFullContextInjection(
            fullContext: fullContext,
            contextLimit: contextLimit,
            promptBuilder: { context in
                String(repeating: "P", count: 1_000) + context
            },
            promptTokenCounter: { $0.count }
        )
        let laterTurn = await ChatVM.evaluateFullContextInjection(
            fullContext: fullContext,
            contextLimit: contextLimit,
            promptBuilder: { context in
                String(repeating: "P", count: 3_000) + context
            },
            promptTokenCounter: { $0.count }
        )

        XCTAssertTrue(firstTurn.fits)
        XCTAssertFalse(laterTurn.fits)
    }

    func testLegacyRAGInjectionInfoDefaultsNewBudgetFields() throws {
        let json = """
        {
          "datasetName":"Handbook",
          "stage":"injected",
          "method":"rag",
          "requestedMaxChunks":5,
          "retrievedChunkCount":4,
          "injectedChunkCount":2,
          "trimmedChunkCount":2,
          "partialChunkInjected":false,
          "fullContentEstimateTokens":1800,
          "contextBudgetTokens":900,
          "injectedContextTokens":420,
          "decisionReason":"2 of 4 chunks fit."
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChatVM.Msg.RAGInjectionInfo.self, from: json)

        XCTAssertEqual(decoded.configuredContextTokens, 900)
        XCTAssertEqual(decoded.reservedResponseTokens, 0)
        XCTAssertEqual(decoded.contextBudgetTokens, 900)
    }

    @MainActor
    func testReloadFromDiskMarksLegacyIndexForRebuild() async throws {
        let datasetID = "Imported/legacy-index-\(UUID().uuidString)"
        let datasetURL = documentsDirectory()
            .appendingPathComponent("LocalLLMDatasets", isDirectory: true)
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(datasetID.replacingOccurrences(of: "Imported/", with: ""), isDirectory: true)
        try FileManager.default.createDirectory(at: datasetURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: datasetURL) }

        try Data("[]".utf8).write(to: DatasetIndexIO.vectorsURL(for: datasetURL))
        try Data("Legacy Dataset".utf8).write(to: DatasetIndexIO.titleURL(for: datasetURL))

        let manager = DatasetManager()
        manager.reloadFromDisk()
        try await Task.sleep(nanoseconds: 100_000_000)

        let dataset = try XCTUnwrap(manager.datasets.first(where: { $0.datasetID == datasetID }))
        XCTAssertFalse(dataset.isIndexed)
        XCTAssertTrue(dataset.requiresReindex)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeVectors(to dir: URL, dimension: Int) throws {
        let fixture = StoredVectorFixture(
            text: "fixture",
            vector: Array(repeating: Float(0.1), count: dimension),
            source: "fixture.txt"
        )
        let data = try JSONEncoder().encode([fixture])
        try data.write(to: DatasetIndexIO.vectorsURL(for: dir))
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
