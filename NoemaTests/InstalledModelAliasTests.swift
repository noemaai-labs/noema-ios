import Foundation
import XCTest
@testable import Noema

final class InstalledModelAliasTests: XCTestCase {
    func testAliasPersistsAndFeedsLocalModelDisplayName() throws {
        let filename = "installed-alias-\(UUID().uuidString).json"
        let store = InstalledModelsStore(filename: filename)
        defer { removeStoreFile(filename) }

        let installed = makeInstalledModel(alias: "Fast tutor")
        store.add(installed)

        let reloaded = InstalledModelsStore(filename: filename)
        let stored = try XCTUnwrap(reloaded.all().first)
        let local = try XCTUnwrap(LocalModel.loadInstalled(store: reloaded).first)

        XCTAssertEqual(stored.alias, "Fast tutor")
        XCTAssertEqual(stored.displayName, "Fast tutor")
        XCTAssertEqual(local.alias, "Fast tutor")
        XCTAssertEqual(local.displayName, "Fast tutor")
        XCTAssertEqual(local.modelID, "example/FastTutor-7B")
        XCTAssertEqual(local.quant, "Q4_K_M")
    }

    func testAliasUpdateTrimsAndClearsWithoutChangingIdentity() throws {
        let filename = "installed-alias-update-\(UUID().uuidString).json"
        let store = InstalledModelsStore(filename: filename)
        defer { removeStoreFile(filename) }

        store.add(makeInstalledModel(alias: nil))
        store.updateAlias(modelID: "example/FastTutor-7B", quantLabel: "Q4_K_M", alias: "  Phone helper  ")

        var stored = try XCTUnwrap(store.all().first)
        XCTAssertEqual(stored.alias, "Phone helper")
        XCTAssertEqual(stored.displayName, "Phone helper")
        XCTAssertEqual(stored.modelID, "example/FastTutor-7B")
        XCTAssertEqual(stored.quantLabel, "Q4_K_M")

        store.updateAlias(modelID: "example/FastTutor-7B", quantLabel: "Q4_K_M", alias: "   ")

        stored = try XCTUnwrap(store.all().first)
        XCTAssertNil(stored.alias)
        XCTAssertEqual(stored.displayName, "example/FastTutor-7B (Q4_K_M)")
    }

    func testLegacyInstalledModelWithoutAliasDecodes() throws {
        let payload: [[String: Any]] = [[
            "id": UUID().uuidString,
            "modelID": "example/Legacy-7B",
            "quantLabel": "Q5_K_M",
            "url": FileManager.default.temporaryDirectory.appendingPathComponent("legacy.gguf").absoluteString,
            "format": "GGUF",
            "sizeBytes": 1024,
            "installDate": 1_700_000_000,
            "checksum": NSNull(),
            "isFavourite": false,
            "totalLayers": 28,
            "isMultimodal": false,
            "isToolCapable": false
        ]]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode([InstalledModel].self, from: data)
        let model = try XCTUnwrap(decoded.first)

        XCTAssertNil(model.alias)
        XCTAssertEqual(model.displayName, "example/Legacy-7B (Q5_K_M)")
    }

    func testConcurrentReadsAndWritesPreserveEveryModel() async {
        let filename = "installed-concurrency-\(UUID().uuidString).json"
        let store = InstalledModelsStore(filename: filename)
        defer { removeStoreFile(filename) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    store.add(
                        InstalledModel(
                            modelID: "example/model-\(index)",
                            quantLabel: "Q4",
                            url: FileManager.default.temporaryDirectory.appendingPathComponent("model-\(index).gguf"),
                            format: .gguf,
                            sizeBytes: Int64(index),
                            lastUsed: nil,
                            installDate: Date(),
                            checksum: nil,
                            isFavourite: false,
                            totalLayers: 0
                        )
                    )
                }
                group.addTask {
                    _ = store.all()
                    _ = store.totalSizeBytes
                    _ = store.isInstalled(id: "example/model-\(index)", quantLabel: "Q4")
                }
            }
        }

        XCTAssertEqual(store.all().count, 40)
    }

    private func makeInstalledModel(alias: String?) -> InstalledModel {
        InstalledModel(
            modelID: "example/FastTutor-7B",
            quantLabel: "Q4_K_M",
            parameterCountLabel: "7B",
            url: FileManager.default.temporaryDirectory.appendingPathComponent("FastTutor-7B-Q4_K_M.gguf"),
            format: .gguf,
            sizeBytes: 4_000_000_000,
            lastUsed: nil,
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            checksum: nil,
            isFavourite: false,
            totalLayers: 32,
            alias: alias
        )
    }

    private func removeStoreFile(_ filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent(filename))
    }
}
