import XCTest
@testable import Noema

final class ManualModelRegistryTests: XCTestCase {
    func testCuratedIncludesBonsai8BAsFeaturedCard() async throws {
        let registry = ManualModelRegistry()
        let curated = try await registry.curated()

        guard let bonsaiIndex = curated.firstIndex(where: { $0.id == "prism-ml/Bonsai-8B-gguf" }) else {
            XCTFail("Bonsai 8b should be included in the curated registry")
            return
        }

        XCTAssertEqual(curated[bonsaiIndex].displayName, "Bonsai 8b")
        XCTAssertLessThan(bonsaiIndex, 6, "Bonsai 8b should stay in the featured card group")
    }

    func testMLXInferenceDoesNotPromoteGGUFOnlyLMStudioRecords() {
        let formats = HuggingFaceRegistry.inferFormats(
            tags: ["gguf", "text-generation"],
            id: "lmstudio-community/example-model-GGUF"
        )

        XCTAssertTrue(formats.contains(.gguf))
        XCTAssertFalse(formats.contains(.mlx))
    }

    func testMLXModeIncludesOnlyRecordsWithMLXFormat() {
        let ggufRecord = ModelRecord(
            id: "lmstudio-community/example-model-GGUF",
            displayName: "Example",
            publisher: "lmstudio-community",
            summary: nil,
            hasInstallableQuant: true,
            formats: [.gguf],
            installed: false,
            tags: ["gguf"],
            pipeline_tag: "text-generation"
        )
        let mlxRecord = ModelRecord(
            id: "mlx-community/example-model-4bit",
            displayName: "Example",
            publisher: "mlx-community",
            summary: nil,
            hasInstallableQuant: true,
            formats: [.mlx],
            installed: false,
            tags: nil,
            pipeline_tag: "text-generation"
        )

        XCTAssertFalse(ExploreSearchMode.mlx.includes(ggufRecord))
        XCTAssertTrue(ExploreSearchMode.mlx.includes(mlxRecord))
    }
}
