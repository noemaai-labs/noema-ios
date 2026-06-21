import XCTest
@testable import Noema

final class GGUFImportSupportTests: XCTestCase {
    func testCollectImportableFilesRecursesIntoNestedDirectories() throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("snapshots/123", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let weight = nested.appendingPathComponent("model-Q4_K_M.gguf")
        let projector = nested.appendingPathComponent("vision-projector.mmproj")
        let ignored = nested.appendingPathComponent("README.md")
        FileManager.default.createFile(atPath: weight.path, contents: Data())
        FileManager.default.createFile(atPath: projector.path, contents: Data())
        FileManager.default.createFile(atPath: ignored.path, contents: Data())

        let files = GGUFImportSupport.collectImportableFiles(from: [root])

        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(["model-Q4_K_M.gguf", "vision-projector.mmproj"]))
    }

    func testProjectorDetectionHandlesMmprojExtensionAndKeywords() {
        XCTAssertTrue(GGUFImportSupport.isProjector(URL(fileURLWithPath: "/tmp/projector.mmproj")))
        XCTAssertTrue(GGUFImportSupport.isProjector(URL(fileURLWithPath: "/tmp/mmproj-q8.gguf")))
        XCTAssertFalse(GGUFImportSupport.isProjector(URL(fileURLWithPath: "/tmp/model-q4_k_m.gguf")))
    }

    func testMTPDetectionHandlesDraftSidecarsWithoutTreatingThemAsWeights() {
        let mtp = URL(fileURLWithPath: "/tmp/qwen3-mtp-f16.gguf")
        let draft = URL(fileURLWithPath: "/tmp/qwen3-draft.gguf")
        let nextn = URL(fileURLWithPath: "/tmp/qwen3-nextn.gguf")
        let main = URL(fileURLWithPath: "/tmp/qwen3-q4_k_m.gguf")
        let projector = URL(fileURLWithPath: "/tmp/qwen3-mtp-mmproj.gguf")

        XCTAssertTrue(GGUFImportSupport.isMTP(mtp))
        XCTAssertTrue(GGUFImportSupport.isMTP(draft))
        XCTAssertTrue(GGUFImportSupport.isMTP(nextn))
        XCTAssertFalse(GGUFImportSupport.isMTP(main))
        XCTAssertFalse(GGUFImportSupport.isMTP(projector))
        XCTAssertFalse(GGUFImportSupport.isWeightFile(mtp))
        XCTAssertTrue(GGUFImportSupport.isWeightFile(main))
    }

    func testModelImportPlansIncludeHintedProjectorAndSidecars() throws {
        let root = try makeTemporaryDirectory()
        let weight = root.appendingPathComponent("Next2.5-Q4_K_M.gguf")
        let preferredProjector = root.appendingPathComponent("next2.5-projector.mmproj")
        let otherProjector = root.appendingPathComponent("other-model-projector.mmproj")
        let preferredMTP = root.appendingPathComponent("next2.5-mtp-f16.gguf")
        let otherMTP = root.appendingPathComponent("other-draft.gguf")
        let tokenizerConfig = root.appendingPathComponent("tokenizer_config.json")
        let chatTemplate = root.appendingPathComponent("chat_template.jinja")
        let config = root.appendingPathComponent("config.json")
        let artifacts = root.appendingPathComponent("artifacts.json")

        FileManager.default.createFile(atPath: weight.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: preferredProjector.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: otherProjector.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: preferredMTP.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: otherMTP.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: tokenizerConfig.path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: chatTemplate.path, contents: Data("{{ enable_thinking }}".utf8))
        FileManager.default.createFile(atPath: config.path, contents: Data("{}".utf8))
        try JSONSerialization.data(
            withJSONObject: [
                "mmproj": preferredProjector.lastPathComponent,
                "mtp": preferredMTP.lastPathComponent
            ],
            options: []
        )
            .write(to: artifacts)

        let plans = GGUFImportSupport.modelImportPlans(from: [root])

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.projector?.lastPathComponent, preferredProjector.lastPathComponent)
        XCTAssertEqual(plans.first?.mtp?.lastPathComponent, preferredMTP.lastPathComponent)
        XCTAssertEqual(
            Set(plans.first?.sidecars.map(\.lastPathComponent) ?? []),
            Set(["tokenizer_config.json", "chat_template.jinja", "config.json"])
        )
    }

    func testModelImportPlansExpandSiblingShardsForDirectFileSelection() throws {
        let root = try makeTemporaryDirectory()
        let part1 = root.appendingPathComponent("Next2.5-Q4_K_M-00001-of-00002.gguf")
        let part2 = root.appendingPathComponent("Next2.5-Q4_K_M-00002-of-00002.gguf")
        FileManager.default.createFile(atPath: part1.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: part2.path, contents: Data("GGUF".utf8))

        let plans = GGUFImportSupport.modelImportPlans(from: [part1])

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.primaryWeight.lastPathComponent, part1.lastPathComponent)
        XCTAssertEqual(plans.first?.weightFiles.map(\.lastPathComponent), [part1.lastPathComponent, part2.lastPathComponent])
    }

    func testWriteArtifactsJSONPersistsShardAndProjectorMetadata() throws {
        let root = try makeTemporaryDirectory()
        let primary = root.appendingPathComponent("Next2.5-Q4_K_M-00001-of-00002.gguf")
        let shard = root.appendingPathComponent("Next2.5-Q4_K_M-00002-of-00002.gguf")
        let projector = root.appendingPathComponent("next2.5-projector.mmproj")
        let mtp = root.appendingPathComponent("next2.5-mtp-f16.gguf")
        FileManager.default.createFile(atPath: primary.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: shard.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: projector.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: mtp.path, contents: Data("GGUF".utf8))

        let artifactsURL = GGUFImportSupport.writeArtifactsJSON(
            in: root,
            weightFiles: [primary, shard],
            projector: projector,
            mtp: mtp
        )

        let data = try Data(contentsOf: artifactsURL)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["weights"] as? String, primary.lastPathComponent)
        XCTAssertEqual(payload["weightShards"] as? [String], [primary.lastPathComponent, shard.lastPathComponent])
        XCTAssertEqual(payload["mmproj"] as? String, projector.lastPathComponent)
        XCTAssertEqual(payload["mmprojChecked"] as? Bool, true)
        XCTAssertEqual(payload["mtp"] as? String, mtp.lastPathComponent)
        XCTAssertEqual(payload["mtpChecked"] as? Bool, true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
