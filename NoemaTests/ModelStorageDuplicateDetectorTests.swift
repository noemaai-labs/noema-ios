import Foundation
import XCTest
@testable import Noema

final class ModelStorageDuplicateDetectorTests: XCTestCase {
    func testDetectsSameModelQuantFromDifferentRepos() throws {
        let visible = [
            makeLocalModel(
                modelID: "unsloth/Qwen3-1.7B-GGUF",
                name: "Qwen3-1.7B-Q4_K_M.gguf",
                quant: "Q4_K_M",
                sizeGB: 2
            ),
            makeLocalModel(
                modelID: "bartowski/Qwen3-1.7B-GGUF",
                name: "Qwen3-1.7B.Q4_K_M.gguf",
                quant: "Q4_K_M",
                sizeGB: 3
            )
        ]

        let families = ModelStorageDuplicateDetector.families(visibleModels: visible, hiddenModels: [])
        let family = try XCTUnwrap(families.first)

        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(family.totalSizeBytes, 5 * 1_073_741_824)
        XCTAssertTrue(family.id.contains("qwen3 1 7b"))
        XCTAssertTrue(family.id.contains("gguf"))
        XCTAssertTrue(family.id.contains("q4_k_m"))

        let export = family.exportDictionary
        XCTAssertEqual(export["installCount"] as? Int, 2)
        XCTAssertEqual(export["sourceCount"] as? Int, 2)
        XCTAssertEqual(export["quant"] as? String, "Q4_K_M")
        XCTAssertEqual(export["format"] as? String, "GGUF")
        XCTAssertEqual(export["sources"] as? [String], ["bartowski/Qwen3-1.7B-GGUF", "unsloth/Qwen3-1.7B-GGUF"])
    }

    func testDifferentQuantsFromSameRepoAreNotDuplicateFamily() {
        let visible = [
            makeLocalModel(modelID: "unsloth/Qwen3-1.7B-GGUF", name: "Qwen3-1.7B-Q4_K_M.gguf", quant: "Q4_K_M"),
            makeLocalModel(modelID: "unsloth/Qwen3-1.7B-GGUF", name: "Qwen3-1.7B-Q5_K_M.gguf", quant: "Q5_K_M")
        ]

        let families = ModelStorageDuplicateDetector.families(visibleModels: visible, hiddenModels: [])

        XCTAssertTrue(families.isEmpty)
    }

    func testSameRepoSameQuantSingleSourceIsNotDuplicateFamily() {
        let visible = [
            makeLocalModel(modelID: "unsloth/Qwen3-1.7B-GGUF", name: "Qwen3-1.7B-a-Q4_K_M.gguf", quant: "Q4_K_M"),
            makeLocalModel(modelID: "unsloth/Qwen3-1.7B-GGUF", name: "Qwen3-1.7B-b-Q4_K_M.gguf", quant: "Q4_K_M")
        ]

        let families = ModelStorageDuplicateDetector.families(visibleModels: visible, hiddenModels: [])

        XCTAssertTrue(families.isEmpty)
    }

    func testDifferentFormatsAreNotDuplicateFamily() {
        let visible = [
            makeLocalModel(modelID: "unsloth/Qwen3-1.7B-GGUF", name: "Qwen3-1.7B-Q4_K_M.gguf", quant: "Q4_K_M", format: .gguf),
            makeLocalModel(modelID: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3-1.7B-4bit", quant: "Q4_K_M", format: .mlx)
        ]

        let families = ModelStorageDuplicateDetector.families(visibleModels: visible, hiddenModels: [])

        XCTAssertTrue(families.isEmpty)
    }

    private func makeLocalModel(
        modelID: String,
        name: String,
        quant: String,
        format: ModelFormat = .gguf,
        sizeGB: Double = 1
    ) -> LocalModel {
        LocalModel(
            modelID: modelID,
            name: name,
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "-"))
                .appendingPathComponent(name),
            quant: quant,
            architecture: "",
            architectureFamily: "",
            format: format,
            sizeGB: sizeGB,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(timeIntervalSince1970: 1_700_000_000),
            totalLayers: 0
        )
    }
}
