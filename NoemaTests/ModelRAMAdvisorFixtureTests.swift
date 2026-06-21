import XCTest
@testable import Noema

final class ModelRAMAdvisorFixtureTests: XCTestCase {
    func testDenseGGUFMetadataFixturesProduceStableWorkingSetBands() throws {
        let llama8B = GGUFMetadataFixture(
            name: "Meta-Llama-3.1-8B-Instruct-Q4_K_M",
            sizeBytes: gib(4.66),
            layerCount: 32,
            contextLength: 8_192,
            budgetBytes: gib(8),
            upperBound: 131_072
        )
        let llama70B = GGUFMetadataFixture(
            name: "Meta-Llama-3.1-70B-Instruct-Q4_K_M",
            sizeBytes: gib(40.5),
            layerCount: 80,
            contextLength: 4_096,
            budgetBytes: gib(16),
            upperBound: 131_072
        )

        let llama8Estimate = estimate(for: llama8B)
        let llama70Estimate = estimate(for: llama70B)

        XCTAssertEqual(gibString(llama8Estimate), "8.86", llama8B.name)
        XCTAssertEqual(gibString(llama70Estimate), "63.08", llama70B.name)
        XCTAssertEqual(maxContext(for: llama8B), 4_639)
        XCTAssertEqual(maxContext(for: llama70B), 512)
    }

    func testDenseGGUFMetadataFixtureExpandsContextWithQuantizedKVCache() throws {
        let llama8B = GGUFMetadataFixture(
            name: "Meta-Llama-3.1-8B-Instruct-Q4_K_M",
            sizeBytes: gib(4.66),
            layerCount: 32,
            contextLength: 8_192,
            budgetBytes: gib(8),
            upperBound: 131_072
        )

        let f16Context = maxContext(for: llama8B, kvCacheEstimate: .init(kCacheQuant: .f16, vCacheQuant: .f16))
        let q4Context = maxContext(for: llama8B, kvCacheEstimate: .init(kCacheQuant: .q4_1, vCacheQuant: .q4_1))

        XCTAssertEqual(f16Context, 4_639)
        XCTAssertEqual(q4Context, 14_846)
        XCTAssertGreaterThan(q4Context, f16Context)
    }

    func testMoEGGUFMetadataFixtureAccountsForActiveExpertCount() throws {
        let mixtralTop2 = GGUFMetadataFixture(
            name: "Mixtral-8x7B-Instruct-v0.1-Q4_K_M top-2",
            sizeBytes: gib(26.4),
            layerCount: 32,
            contextLength: 8_192,
            budgetBytes: gib(32),
            upperBound: 65_536,
            moeInfo: mixtralMoE(activeExperts: 2)
        )
        var mixtralTop8 = mixtralTop2
        mixtralTop8.name = "Mixtral-8x7B-Instruct-v0.1-Q4_K_M top-8"
        mixtralTop8.moeInfo = Self.mixtralMoE(activeExperts: 8)

        let top2Estimate = estimate(for: mixtralTop2)
        let top8Estimate = estimate(for: mixtralTop8)

        XCTAssertEqual(gibString(top2Estimate), "15.51", mixtralTop2.name)
        XCTAssertEqual(gibString(top8Estimate), "43.81", mixtralTop8.name)
        XCTAssertLessThan(top2Estimate, top8Estimate)
        XCTAssertEqual(maxContext(for: mixtralTop2), 42_295)
        XCTAssertEqual(maxContext(for: mixtralTop8), 512)
    }

    func testMoEGGUFMetadataFixtureCanReachUpperBoundWithQuantizedKVWhenWeightsFit() throws {
        let mixtralTop2 = GGUFMetadataFixture(
            name: "Mixtral-8x7B-Instruct-v0.1-Q4_K_M top-2",
            sizeBytes: gib(26.4),
            layerCount: 32,
            contextLength: 8_192,
            budgetBytes: gib(32),
            upperBound: 65_536,
            moeInfo: mixtralMoE(activeExperts: 2)
        )

        let f16Context = maxContext(for: mixtralTop2, kvCacheEstimate: .init(kCacheQuant: .f16, vCacheQuant: .f16))
        let q4Context = maxContext(for: mixtralTop2, kvCacheEstimate: .init(kCacheQuant: .q4_1, vCacheQuant: .q4_1))

        XCTAssertEqual(f16Context, 42_295)
        XCTAssertEqual(q4Context, 65_536)
        XCTAssertGreaterThan(q4Context, f16Context)
    }

    private struct GGUFMetadataFixture {
        var name: String
        var sizeBytes: Int64
        var layerCount: Int
        var contextLength: Int
        var budgetBytes: Int64
        var upperBound: Int
        var moeInfo: MoEInfo? = nil
    }

    private func estimate(
        for fixture: GGUFMetadataFixture,
        kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate = .f16F16
    ) -> Int64 {
        ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: fixture.sizeBytes,
            contextLength: fixture.contextLength,
            layerCount: fixture.layerCount,
            moeInfo: fixture.moeInfo,
            kvCacheEstimate: kvCacheEstimate
        ).estimate
    }

    private func maxContext(
        for fixture: GGUFMetadataFixture,
        kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate = .f16F16
    ) -> Int {
        ModelRAMAdvisor.maxContextUnderBudget(
            format: .gguf,
            sizeBytes: fixture.sizeBytes,
            layerCount: fixture.layerCount,
            moeInfo: fixture.moeInfo,
            upperBound: fixture.upperBound,
            kvCacheEstimate: kvCacheEstimate,
            budgetBytesOverride: fixture.budgetBytes
        ) ?? 0
    }

    private static func mixtralMoE(activeExperts: Int) -> MoEInfo {
        MoEInfo(
            isMoE: true,
            expertCount: 8,
            defaultUsed: activeExperts,
            moeLayerCount: 32,
            totalLayerCount: 32,
            hiddenSize: 4_096,
            feedForwardSize: 14_336,
            vocabSize: 32_000
        )
    }

    private func mixtralMoE(activeExperts: Int) -> MoEInfo {
        Self.mixtralMoE(activeExperts: activeExperts)
    }

    private func gib(_ value: Double) -> Int64 {
        Int64(value * 1_073_741_824.0)
    }

    private func gibString(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824.0)
    }
}
