import XCTest
@testable import Noema

final class ModelStorageCleanupTests: XCTestCase {
    func testDeletingETModelRemovesInstallRootAndSidecars() throws {
        let modelID = "noema-tests/et-\(UUID().uuidString)"
        let root = InstalledModelsStore.baseDir(for: .et, modelID: modelID)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let modelURL = root.appendingPathComponent("model.pte")
        try Data("pte".utf8).write(to: modelURL)
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try Data("repo".utf8).write(to: root.appendingPathComponent("source_repo.txt"))

        let local = makeLocalModel(modelID: modelID, quant: "ET", url: modelURL, format: .et)
        let installed = makeInstalledModel(modelID: modelID, quant: "ET", url: modelURL, format: .et)

        let result = ModelStorageCleanup.deleteModelFiles(for: local, installedModels: [installed])

        XCTAssertTrue(result.didRemoveAnything)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDeletingSharedGGUFQuantPreservesSiblingAndPrunesArtifactsJSON() throws {
        let modelID = "noema-tests/gguf-shared-\(UUID().uuidString)"
        let root = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let targetURL = root.appendingPathComponent("Model-Q4_K_M.gguf")
        let siblingURL = root.appendingPathComponent("Model-Q5_K_M.gguf")
        try Data("GGUF-target".utf8).write(to: targetURL)
        try Data("GGUF-sibling".utf8).write(to: siblingURL)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: targetURL.path + ".download"))
        let artifacts: [String: Any] = [
            "weights": targetURL.lastPathComponent,
            "mmproj": "projector.gguf"
        ]
        let artifactsData = try JSONSerialization.data(withJSONObject: artifacts)
        try artifactsData.write(to: root.appendingPathComponent("artifacts.json"))

        let target = makeLocalModel(modelID: modelID, quant: "Q4_K_M", url: targetURL, format: .gguf)
        let installed = [
            makeInstalledModel(modelID: modelID, quant: "Q4_K_M", url: targetURL, format: .gguf),
            makeInstalledModel(modelID: modelID, quant: "Q5_K_M", url: siblingURL, format: .gguf)
        ]

        _ = ModelStorageCleanup.deleteModelFiles(for: target, installedModels: installed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path + ".download"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
        let remainingData = try Data(contentsOf: root.appendingPathComponent("artifacts.json"))
        let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: remainingData) as? [String: Any])
        XCTAssertNil(remaining["weights"])
        XCTAssertEqual(remaining["mmproj"] as? String, "projector.gguf")
    }

    func testDeletingUnsharedSplitGGUFRemovesAllShardsWithoutArtifactsJSON() throws {
        let modelID = "noema-tests/gguf-split-\(UUID().uuidString)"
        let root = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let shard1 = root.appendingPathComponent("Split-Q4_K_M-00001-of-00002.gguf")
        let shard2 = root.appendingPathComponent("Split-Q4_K_M-00002-of-00002.gguf")
        try Data("GGUF-1".utf8).write(to: shard1)
        try Data("GGUF-2".utf8).write(to: shard2)

        let local = makeLocalModel(modelID: modelID, quant: "Q4_K_M", url: shard1, format: .gguf)
        let installed = makeInstalledModel(modelID: modelID, quant: "Q4_K_M", url: shard1, format: .gguf)

        _ = ModelStorageCleanup.deleteModelFiles(for: local, installedModels: [installed])

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func makeLocalModel(modelID: String, quant: String, url: URL, format: ModelFormat) -> LocalModel {
        LocalModel(
            modelID: modelID,
            name: modelID,
            url: url,
            quant: quant,
            architecture: "",
            architectureFamily: "",
            format: format,
            sizeGB: 0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )
    }

    private func makeInstalledModel(modelID: String, quant: String, url: URL, format: ModelFormat) -> InstalledModel {
        InstalledModel(
            modelID: modelID,
            quantLabel: quant,
            url: url,
            format: format,
            sizeBytes: 1,
            lastUsed: nil,
            installDate: Date(),
            checksum: nil,
            isFavourite: false,
            totalLayers: 0
        )
    }
}
