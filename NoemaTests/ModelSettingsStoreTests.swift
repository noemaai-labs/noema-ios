import Foundation
import XCTest
@testable import Noema

final class ModelSettingsStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaModelSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        ModelSettingsStore.directoryOverrideForTesting = temporaryDirectory
        ModelSettingsStore.clear()
        UserDefaults.standard.removeObject(forKey: "modelSettings")
    }

    override func tearDown() {
        ModelSettingsStore.clear()
        ModelSettingsStore.directoryOverrideForTesting = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        UserDefaults.standard.removeObject(forKey: "modelSettings")
        super.tearDown()
    }

    func testDurableEntryRoundTripsContextLengthAndCanonicalPath() {
        let model = makeLocalModel(path: "/tmp/noema/tests/context-roundtrip.gguf")
        var settings = ModelSettings.default(for: .gguf)
        settings.contextLength = 8192

        ModelSettingsStore.save(settings: settings, for: model)

        let entries = ModelSettingsStore.loadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.canonicalPath, model.url.path)
        XCTAssertEqual(entries.first?.settings.contextLength, 8192)
    }

    func testDurableEntryRoundTripsSystemPromptSettings() {
        let model = makeLocalModel(path: "/tmp/noema/tests/system-prompt-roundtrip.gguf")
        var settings = ModelSettings.default(for: .gguf)
        settings.systemPromptMode = .override
        settings.systemPromptOverride = "Model-specific instructions."

        ModelSettingsStore.save(settings: settings, for: model)

        let entries = ModelSettingsStore.loadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.settings.systemPromptMode, .override)
        XCTAssertEqual(entries.first?.settings.systemPromptOverride, "Model-specific instructions.")
    }

    func testModelSettingsDecodeDefaultsMissingSystemPromptFields() throws {
        let json = "{}"

        let decoded = try JSONDecoder().decode(ModelSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.systemPromptMode, .inheritGlobal)
        XCTAssertNil(decoded.systemPromptOverride)
    }

    func testLegacySpeculativeDecodingSettingsDecodeAsHelperMode() throws {
        let json = #"{"helperModelID":"draft-model","mode":"max","value":32}"#

        let decoded = try JSONDecoder().decode(
            ModelSettings.SpeculativeDecodingSettings.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.selection, .helperDraftModel)
        XCTAssertEqual(decoded.helperModelID, "draft-model")
        XCTAssertEqual(decoded.mode, .max)
        XCTAssertEqual(decoded.value, 32)
        XCTAssertEqual(decoded.mtpDraftNMax, 2)
    }

    func testMTPModePersistsAndClampsDraftTokenCount() throws {
        var settings = ModelSettings.SpeculativeDecodingSettings()
        settings.selection = .mtp
        settings.mtpDraftNMax = 9

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(
            ModelSettings.SpeculativeDecodingSettings.self,
            from: encoded
        )

        XCTAssertEqual(decoded.selection, .mtp)
        XCTAssertTrue(decoded.mtpEnabled)
        XCTAssertEqual(decoded.mtpDraftNMax, 9)
        XCTAssertEqual(decoded.resolvedMTPDraftNMax, 6)
    }

    func testMTPAutoTuneUsesSeventyPercentAcceptanceThreshold() {
        var settings = ModelSettings.SpeculativeDecodingSettings()
        settings.selection = .mtp
        settings.mtpAutoTune = true
        settings.mtpDraftPMin = 0.2

        XCTAssertEqual(settings.effectiveMTPDraftPMin, 0.7, accuracy: 1e-9)
    }

    func testBlankSystemPromptOverrideNormalizesBackToGlobal() {
        var settings = ModelSettings.default(for: .gguf)
        settings.systemPromptMode = .override
        settings.systemPromptOverride = "   \n"

        let normalized = settings.normalizedSystemPromptSettings()

        XCTAssertEqual(normalized.systemPromptMode, .inheritGlobal)
        XCTAssertNil(normalized.systemPromptOverride)
    }

    func testResolverPrefersExactCanonicalPathWhenQuantLabelChanges() {
        let currentPath = "/tmp/noema/tests/quant-drift.gguf"
        let savedModel = makeLocalModel(quant: "Q4_K_M", path: currentPath)
        var savedSettings = ModelSettings.default(for: .gguf)
        savedSettings.contextLength = 12288
        ModelSettingsStore.save(settings: savedSettings, for: savedModel)

        var legacySettings = ModelSettings.default(for: .gguf)
        legacySettings.contextLength = 4096

        let currentInstalled = makeInstalledModel(
            modelID: savedModel.modelID,
            quantLabel: "Q5_K_M",
            path: currentPath
        )

        let resolved = ModelSettingsStore.resolveLocalSettings(
            installedModels: [currentInstalled],
            legacySettingsByPath: [currentPath: legacySettings]
        )

        XCTAssertEqual(resolved[currentPath]?.contextLength, 12288)
    }

    func testResolverFallsBackToLegacyPathWhenDurableStoreHasNoMatchingEntry() {
        let unrelatedModel = makeLocalModel(
            modelID: "Other/Model",
            quant: "Q4_K_M",
            path: "/tmp/noema/tests/unrelated.gguf"
        )
        var unrelatedSettings = ModelSettings.default(for: .gguf)
        unrelatedSettings.contextLength = 6144
        ModelSettingsStore.save(settings: unrelatedSettings, for: unrelatedModel)

        let currentPath = "/tmp/noema/tests/legacy-fallback.gguf"
        var legacySettings = ModelSettings.default(for: .gguf)
        legacySettings.contextLength = 16384

        let installed = makeInstalledModel(path: currentPath)
        let resolved = ModelSettingsStore.resolveLocalSettings(
            installedModels: [installed],
            legacySettingsByPath: [currentPath: legacySettings]
        )

        XCTAssertEqual(resolved[currentPath]?.contextLength, 16384)
        XCTAssertEqual(
            ModelSettingsStore.loadEntries().first(where: { $0.canonicalPath == currentPath })?.settings.contextLength,
            16384
        )
    }

    func testResolverBackfillsCanonicalPathForLegacyDurableEntryMatchedByModelKey() {
        let model = makeLocalModel(path: "/tmp/noema/tests/backfill-path.gguf")
        var settings = ModelSettings.default(for: .gguf)
        settings.contextLength = 10240

        ModelSettingsStore.save(entries: [
            .init(
                modelID: model.modelID,
                quantLabel: model.quant,
                canonicalPath: nil,
                settings: settings
            )
        ])

        let installed = makeInstalledModel(
            modelID: model.modelID,
            quantLabel: model.quant,
            path: model.url.path
        )
        let resolved = ModelSettingsStore.resolveLocalSettings(
            installedModels: [installed],
            legacySettingsByPath: [:]
        )

        XCTAssertEqual(resolved[model.url.path]?.contextLength, 10240)
        XCTAssertEqual(ModelSettingsStore.loadEntries().first?.canonicalPath, model.url.path)
    }

    func testModelSettingsDecodeToleratesUnknownEnumRawValues() throws {
        // Simulates an older build reading settings written by a newer one: unknown
        // raw values must fall back to defaults instead of failing the whole decode
        // (a throw here used to permanently drop the durable entry).
        let json = #"""
        {
            "contextLength": 32768,
            "kCacheQuant": "Q9_9",
            "vCacheQuant": "SOME_FUTURE_QUANT",
            "tensorOverride": "hologram",
            "speculativeDecoding": {"selection": "warp-drive", "mtpDraftNMax": 4}
        }
        """#

        let decoded = try JSONDecoder().decode(ModelSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.contextLength, 32768)
        XCTAssertEqual(decoded.kCacheQuant, .f16)
        XCTAssertEqual(decoded.vCacheQuant, .f16)
        XCTAssertEqual(decoded.tensorOverride, .none)
        XCTAssertEqual(decoded.speculativeDecoding.selection, .off)
        XCTAssertEqual(decoded.speculativeDecoding.mtpDraftNMax, 4)
    }

    func testLocalPayloadDecodeSeparatesUnrecognizedEntries() throws {
        let payload: [String: Any] = [
            "entries": [
                [
                    "modelID": "Qwen/Qwen3-4B-Instruct",
                    "quantLabel": "Q4_K_M",
                    "canonicalPath": "/tmp/noema/tests/ok.gguf",
                    "settings": ["contextLength": 8192]
                ],
                [
                    "modelID": "Future/Model",
                    "quantLabel": "QX",
                    "settings": 42
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try XCTUnwrap(ModelSettingsPersistenceDecoder.decodeLocalPayload(from: data))

        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries.first?.settings.contextLength, 8192)
        XCTAssertEqual(decoded.unrecognizedRawEntries.count, 1)
        XCTAssertEqual(decoded.unrecognizedRawEntries.first?["modelID"] as? String, "Future/Model")
    }

    func testSavePreservesEntriesFromNewerSchemaAcrossRewrite() throws {
        // A payload containing one entry this build can decode and one it can't.
        let payload: [String: Any] = [
            "entries": [
                [
                    "modelID": "Qwen/Qwen3-4B-Instruct",
                    "quantLabel": "Q4_K_M",
                    "canonicalPath": "/tmp/noema/tests/known.gguf",
                    "settings": ["contextLength": 24576]
                ],
                [
                    "modelID": "Future/Model",
                    "quantLabel": "QX",
                    "canonicalPath": "/tmp/noema/tests/future.bin",
                    "settings": 42
                ]
            ]
        ]
        ModelSettingsStore.replacePayloadForTesting(try JSONSerialization.data(withJSONObject: payload))

        XCTAssertEqual(ModelSettingsStore.loadEntries().count, 1)
        XCTAssertEqual(ModelSettingsStore.unrecognizedRawEntryCountForTesting, 1)

        // Saving an unrelated model rewrites the payload; the undecodable entry must
        // ride along instead of being dropped.
        let other = makeLocalModel(modelID: "Other/Model", path: "/tmp/noema/tests/other.gguf")
        var otherSettings = ModelSettings.default(for: .gguf)
        otherSettings.contextLength = 4096
        ModelSettingsStore.save(settings: otherSettings, for: other)

        let reloaded = ModelSettingsStore.loadEntries()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(ModelSettingsStore.unrecognizedRawEntryCountForTesting, 1)
        XCTAssertTrue(reloaded.contains { $0.settings.contextLength == 24576 })
        XCTAssertTrue(reloaded.contains { $0.modelID == "Other/Model" })
    }

    func testCorruptPayloadDoesNotGetWipedBySave() throws {
        // An unreadable payload (e.g. locked keychain surrogate: corrupt JSON in both
        // stores) must make save() a no-op rather than rebuilding a 1-entry payload.
        ModelSettingsStore.replacePayloadForTesting(Data("not json at all".utf8))

        let model = makeLocalModel(path: "/tmp/noema/tests/wipe-guard.gguf")
        var settings = ModelSettings.default(for: .gguf)
        settings.contextLength = 9999
        ModelSettingsStore.save(settings: settings, for: model)

        // The corrupt payload is still in place, untouched — nothing was overwritten.
        let result = ModelSettingsStore.loadEntriesDetailed()
        XCTAssertFalse(result.storeReadable)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testCanonicalPathMigrationRewritesDurableEntryPath() {
        let oldPath = "/tmp/noema/tests/migrated-old.gguf"
        let newPath = "/tmp/noema/tests/migrated-new.gguf"
        let model = makeLocalModel(path: oldPath)
        var settings = ModelSettings.default(for: .gguf)
        settings.contextLength = 14336
        ModelSettingsStore.save(settings: settings, for: model)

        ModelSettingsStore.migrateCanonicalPaths([(oldPath: oldPath, newPath: newPath)])

        let entries = ModelSettingsStore.loadEntries()
        XCTAssertEqual(entries.first?.canonicalPath, newPath)

        let installed = makeInstalledModel(
            modelID: model.modelID,
            quantLabel: model.quant,
            path: newPath
        )
        let resolved = ModelSettingsStore.resolveLocalSettings(
            installedModels: [installed],
            legacySettingsByPath: [:]
        )

        XCTAssertEqual(resolved[newPath]?.contextLength, 14336)
    }

    private func makeLocalModel(
        modelID: String = "Qwen/Qwen3-4B-Instruct",
        quant: String = "Q4_K_M",
        path: String
    ) -> LocalModel {
        LocalModel(
            modelID: modelID,
            name: "Qwen3-4B-Instruct",
            url: URL(fileURLWithPath: path),
            quant: quant,
            architecture: "qwen3",
            architectureFamily: "qwen",
            format: .gguf,
            sizeGB: 0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )
    }

    private func makeInstalledModel(
        modelID: String = "Qwen/Qwen3-4B-Instruct",
        quantLabel: String = "Q4_K_M",
        path: String
    ) -> InstalledModel {
        InstalledModel(
            modelID: modelID,
            quantLabel: quantLabel,
            url: URL(fileURLWithPath: path),
            format: .gguf,
            sizeBytes: 0,
            lastUsed: nil,
            installDate: Date(),
            checksum: nil,
            isFavourite: false,
            totalLayers: 0
        )
    }
}
