import Foundation
import XCTest
@testable import Noema

final class LocalModelContextLimitTests: XCTestCase {
    func testSupportedMaxContextLengthReadsGGUFMetadataAbove32K() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let ggufURL = root.appendingPathComponent("model.gguf")
        try writeMinimalGGUF(to: ggufURL, contextLength: 131_072)

        let model = makeLocalModel(format: .gguf, url: ggufURL)
        XCTAssertEqual(ModelSettings.supportedMaxContextLength(for: model), 131_072)
    }

    func testPagedGGUFContextLimitUsesPlatformLaunchCap() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let packageURL = temporaryRoot.appendingPathComponent("model.noema-paged", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let ggufURL = packageURL.appendingPathComponent("resident.gguf")
        try writeMinimalGGUF(to: ggufURL, contextLength: 131_072)
        try Data("{}".utf8).write(to: packageURL.appendingPathComponent("manifest.json"))

        let model = makeLocalModel(format: .gguf, url: ggufURL)
        XCTAssertEqual(
            ModelSettings.supportedMaxContextLength(for: model),
            OverfitPlanResolver.pagedContextCapTokens
        )

        let settings = ModelSettings(contextLength: 131_072)
        XCTAssertEqual(
            settings.normalizedForLocalModel(model).contextLength,
            Double(OverfitPlanResolver.pagedContextCapTokens)
        )
    }

    func testSupportedMaxContextLengthReadsNestedMLXConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeConfig(
            [
                "text_config": [
                    "max_position_embeddings": 200_000
                ]
            ],
            to: root.appendingPathComponent("config.json")
        )

        let model = makeLocalModel(format: .mlx, url: root)
        XCTAssertEqual(ModelSettings.supportedMaxContextLength(for: model), 200_000)
    }

    func testSupportedMaxContextLengthReadsETConfigFromRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pteURL = root.appendingPathComponent("model.pte")
        try Data().write(to: pteURL)
        try writeConfig(
            [
                "model_max_length": 65_536
            ],
            to: root.appendingPathComponent("config.json")
        )

        let model = makeLocalModel(format: .et, url: pteURL)
        XCTAssertEqual(ModelSettings.supportedMaxContextLength(for: model), 65_536)
    }

    func testNormalizedForLocalModelClampsContextToDetectedModelMax() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeConfig(
            [
                "text_config": [
                    "max_position_embeddings": 200_000
                ]
            ],
            to: root.appendingPathComponent("config.json")
        )

        let model = makeLocalModel(format: .mlx, url: root)
        let settings = ModelSettings(contextLength: 250_000)

        XCTAssertEqual(settings.normalizedForLocalModel(model).contextLength, 200_000)
    }

    func testNormalizedForLocalModelLeavesUnknownModelMaxUnchanged() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeLocalModel(format: .mlx, url: root)
        let settings = ModelSettings(contextLength: 250_000)

        XCTAssertEqual(settings.normalizedForLocalModel(model).contextLength, 250_000)
    }

    func testGGUFEstimateDropsAsKCacheQuantizationGetsSmaller() {
        let contextLength = 32_768
        let sizeBytes = gib(2)
        let layerCount = 32

        let f16Estimate = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: nil,
            kvCacheEstimate: .init(kCacheQuant: .f16, vCacheQuant: .f16)
        ).estimate
        let q8Estimate = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: nil,
            kvCacheEstimate: .init(kCacheQuant: .q8_0, vCacheQuant: .f16)
        ).estimate
        let q4Estimate = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: nil,
            kvCacheEstimate: .init(kCacheQuant: .q4_1, vCacheQuant: .f16)
        ).estimate

        XCTAssertGreaterThan(f16Estimate, q8Estimate)
        XCTAssertGreaterThan(q8Estimate, q4Estimate)
    }

    func testMLXEstimateDropsAcrossEverySupportedKVCacheBitWidth() {
        let quantizations: [MLXKVCacheQuantization] = [
            .fullPrecision, .eightBit, .sixBit, .fiveBit, .fourBit, .threeBit, .twoBit
        ]
        let estimates = quantizations.map { quantization in
            var settings = ModelSettings.default(for: .mlx)
            settings.mlxKVCacheQuantization = quantization
            return ModelRAMAdvisor.estimateAndBudget(
                format: .mlx,
                sizeBytes: gib(2),
                contextLength: 32_768,
                layerCount: 32,
                moeInfo: nil,
                kvCacheEstimate: .resolved(from: settings)
            ).estimate
        }

        for pair in zip(estimates, estimates.dropFirst()) {
            XCTAssertGreaterThan(pair.0, pair.1)
        }
    }

    func testGGUFVCacheQuantOnlyChangesEstimateWhenFlashAttentionIsEnabled() {
        let sizeBytes = gib(2)
        let contextLength = 24_576
        let layerCount = 32

        var settings = ModelSettings.default(for: .gguf)
        settings.kCacheQuant = .q8_0
        settings.vCacheQuant = .q4_1
        settings.flashAttention = false

        let noFlashEstimate = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: nil,
            kvCacheEstimate: .resolved(from: settings)
        ).estimate

        settings.vCacheQuant = .f16

        let noFlashReferenceEstimate = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: nil,
            kvCacheEstimate: .resolved(from: settings)
        ).estimate

        XCTAssertEqual(noFlashEstimate, noFlashReferenceEstimate)

        settings.flashAttention = true

        let flashF16Estimate = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: nil,
            kvCacheEstimate: .resolved(from: settings)
        ).estimate

        settings.vCacheQuant = .q4_1

        let flashQuantizedEstimate = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: nil,
            kvCacheEstimate: .resolved(from: settings)
        ).estimate

        XCTAssertLessThan(flashQuantizedEstimate, flashF16Estimate)
    }

    func testMaxContextUnderBudgetGrowsWhenGGUFKVCacheUsesSmallerQuant() throws {
        let budget = gib(2) + mib(512)
        let sizeBytes = gib(1)
        let layerCount = 32

        let f16Context = try XCTUnwrap(
            ModelRAMAdvisor.maxContextUnderBudget(
                format: .gguf,
                sizeBytes: sizeBytes,
                layerCount: layerCount,
                moeInfo: nil,
                upperBound: 65_536,
                kvCacheEstimate: .init(kCacheQuant: .f16, vCacheQuant: .f16),
                budgetBytesOverride: budget
            )
        )
        let q4Context = try XCTUnwrap(
            ModelRAMAdvisor.maxContextUnderBudget(
                format: .gguf,
                sizeBytes: sizeBytes,
                layerCount: layerCount,
                moeInfo: nil,
                upperBound: 65_536,
                kvCacheEstimate: .init(kCacheQuant: .q4_1, vCacheQuant: .f16),
                budgetBytesOverride: budget
            )
        )

        XCTAssertGreaterThan(q4Context, f16Context)
    }

    func testMaxContextUnderBudgetHonorsUpperBound() throws {
        let maxContext = try XCTUnwrap(
            ModelRAMAdvisor.maxContextUnderBudget(
                format: .gguf,
                sizeBytes: 1,
                layerCount: 1,
                moeInfo: nil,
                upperBound: 2_048,
                budgetBytesOverride: gib(8)
            )
        )

        XCTAssertEqual(maxContext, 2_048)
    }

    func testPromptBudgetForLongContextUsesConfiguredContextMinusReserve() {
        let budget = ChatVM.promptBudget(for: 190_000)

        XCTAssertEqual(budget.configuredContextTokens, 190_000)
        XCTAssertEqual(budget.reservedResponseTokens, 4_096)
        XCTAssertEqual(budget.usablePromptTokens, 185_904)
    }
}

private extension LocalModelContextLimitTests {
    func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func makeLocalModel(format: ModelFormat, url: URL) -> LocalModel {
        LocalModel(
            modelID: "local/\(UUID().uuidString)",
            name: url.deletingPathExtension().lastPathComponent,
            url: url,
            quant: format.displayName,
            architecture: "",
            architectureFamily: "",
            format: format,
            sizeGB: 1.0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )
    }

    func writeConfig(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }

    func writeMinimalGGUF(to url: URL, contextLength: UInt32) throws {
        var data = Data()
        data.append(Data("GGUF".utf8))
        append(UInt32(3), to: &data)
        append(UInt64(0), to: &data)
        append(UInt64(1), to: &data)

        let key = Data("llama.n_ctx_train".utf8)
        append(UInt64(key.count), to: &data)
        data.append(key)
        append(UInt32(4), to: &data)
        append(contextLength, to: &data)

        try data.write(to: url)
    }

    func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    func gib(_ value: Int64) -> Int64 {
        value * 1_073_741_824
    }

    func mib(_ value: Int64) -> Int64 {
        value * 1_048_576
    }
}
