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

    func testMTPDetectionDoesNotTreatGenericDraftModelsAsMTP() {
        let mtp = URL(fileURLWithPath: "/tmp/qwen3-mtp-f16.gguf")
        let draft = URL(fileURLWithPath: "/tmp/qwen3-draft.gguf")
        let nextn = URL(fileURLWithPath: "/tmp/qwen3-nextn.gguf")
        let main = URL(fileURLWithPath: "/tmp/qwen3-q4_k_m.gguf")
        let projector = URL(fileURLWithPath: "/tmp/qwen3-mtp-mmproj.gguf")

        XCTAssertTrue(GGUFImportSupport.isMTP(mtp))
        XCTAssertFalse(GGUFImportSupport.isMTP(draft))
        XCTAssertTrue(GGUFImportSupport.isMTP(nextn))
        XCTAssertFalse(GGUFImportSupport.isMTP(main))
        XCTAssertFalse(GGUFImportSupport.isMTP(projector))
        XCTAssertFalse(GGUFImportSupport.isWeightFile(mtp))
        XCTAssertTrue(GGUFImportSupport.isWeightFile(draft))
        XCTAssertTrue(GGUFImportSupport.isWeightFile(main))
    }

    func testModelImportPlansIncludeHintedProjectorAndSidecars() throws {
        let root = try makeTemporaryDirectory()
        let weight = root.appendingPathComponent("Next2.5-Q4_K_M.gguf")
        let preferredProjector = root.appendingPathComponent("next2.5-projector.mmproj")
        let otherProjector = root.appendingPathComponent("other-model-projector.mmproj")
        let preferredMTP = root.appendingPathComponent("next2.5-mtp-f16.gguf")
        let otherMTP = root.appendingPathComponent("other-mtp.gguf")
        let tokenizerConfig = root.appendingPathComponent("tokenizer_config.json")
        let chatTemplate = root.appendingPathComponent("chat_template.jinja")
        let config = root.appendingPathComponent("config.json")
        let artifacts = root.appendingPathComponent("artifacts.json")

        try writeMTPFixture(to: weight, tensors: [])
        FileManager.default.createFile(atPath: preferredProjector.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: otherProjector.path, contents: Data("GGUF".utf8))
        try writeMTPFixture(
            to: preferredMTP,
            tensors: [
                "blk.35.nextn.eh_proj.weight",
                "blk.35.nextn.enorm.weight",
                "blk.35.nextn.hnorm.weight"
            ]
        )
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

    func testMtpLocatorRejectsArtifactsPathOutsideModelDirectory() throws {
        let root = try makeTemporaryDirectory()
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let target = modelDirectory.appendingPathComponent("qwen-target.gguf")
        let outside = root.appendingPathComponent("qwen-mtp.gguf")
        try writeMTPFixture(to: target, tensors: [])
        try writeMTPFixture(
            to: outside,
            tensors: [
                "blk.35.nextn.eh_proj.weight",
                "blk.35.nextn.enorm.weight",
                "blk.35.nextn.hnorm.weight"
            ]
        )
        let artifacts = try JSONSerialization.data(withJSONObject: ["mtp": "../qwen-mtp.gguf"])
        try artifacts.write(to: modelDirectory.appendingPathComponent("artifacts.json"))

        XCTAssertNil(MtpLocator.mtpPath(alongside: target))
    }

    func testMtpLocatorRejectsAmbiguousValidatedSidecars() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("qwen-target.gguf")
        try writeMTPFixture(to: target, tensors: [])
        let tensors = [
            "blk.35.nextn.eh_proj.weight",
            "blk.35.nextn.enorm.weight",
            "blk.35.nextn.hnorm.weight"
        ]
        try writeMTPFixture(to: root.appendingPathComponent("qwen-mtp-a.gguf"), tensors: tensors)
        try writeMTPFixture(to: root.appendingPathComponent("qwen-mtp-b.gguf"), tensors: tensors)

        XCTAssertNil(MtpLocator.mtpPath(alongside: target))
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

    private func writeMTPFixture(to url: URL, tensors: [String]) throws {
        var data = Data("GGUF".utf8)
        append(UInt32(3), to: &data)
        append(UInt64(tensors.count), to: &data)
        append(UInt64(5), to: &data)

        appendString("general.architecture", to: &data)
        append(UInt32(8), to: &data)
        appendString("qwen35", to: &data)

        for (key, value) in [
            ("qwen35.nextn_predict_layers", UInt32(1)),
            ("qwen35.embedding_length", UInt32(2_048)),
            ("qwen35.vocab_size", UInt32(3))
        ] {
            appendString(key, to: &data)
            append(UInt32(4), to: &data)
            append(value, to: &data)
        }

        appendString("tokenizer.ggml.tokens", to: &data)
        append(UInt32(9), to: &data)
        append(UInt32(8), to: &data)
        append(UInt64(3), to: &data)
        for token in ["a", "b", "c"] {
            appendString(token, to: &data)
        }

        for tensor in tensors {
            appendString(tensor, to: &data)
            append(UInt32(1), to: &data)
            append(UInt64(1), to: &data)
            append(UInt32(0), to: &data)
            append(UInt64(0), to: &data)
        }
        try data.write(to: url)
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }
}
