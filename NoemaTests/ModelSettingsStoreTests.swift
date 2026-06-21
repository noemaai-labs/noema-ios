import Foundation
import XCTest
@testable import Noema

final class ModelSettingsStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ModelSettingsStore.clear()
        UserDefaults.standard.removeObject(forKey: "modelSettings")
    }

    override func tearDown() {
        ModelSettingsStore.clear()
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
