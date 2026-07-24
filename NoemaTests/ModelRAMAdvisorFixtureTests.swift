import XCTest
@testable import Noema

final class ModelRAMAdvisorFixtureTests: XCTestCase {
    // MARK: - Working-set estimates (exact, GQA-aware KV cache)

    func testDenseGGUFMetadataFixturesProduceStableWorkingSetBands() throws {
        // Real attention shapes drive the KV cache now, so fixtures carry them.
        // Llama-3.1-8B: 32 layers, 32 heads, 8 KV heads (GQA 1/4), head dim 128.
        let llama8B = GGUFMetadataFixture(
            name: "Meta-Llama-3.1-8B-Instruct-Q4_K_M",
            sizeBytes: gib(4.66),
            layerCount: 32,
            contextLength: 8_192,
            budgetBytes: gib(8),
            upperBound: 131_072,
            moeInfo: Self.denseArch(layers: 32, heads: 32, kvHeads: 8, headDim: 128, hidden: 4_096)
        )
        // Llama-3.1-70B: 80 layers, 64 heads, 8 KV heads (GQA 1/8), head dim 128.
        let llama70B = GGUFMetadataFixture(
            name: "Meta-Llama-3.1-70B-Instruct-Q4_K_M",
            sizeBytes: gib(40.5),
            layerCount: 80,
            contextLength: 4_096,
            budgetBytes: gib(16),
            upperBound: 131_072,
            moeInfo: Self.denseArch(layers: 80, heads: 64, kvHeads: 8, headDim: 128, hidden: 8_192)
        )

        // Weights and KV are exact inputs; compute buffers add a conservative architecture-
        // dependent term, so assert stable planning bands instead of a byte-exact heuristic.
        XCTAssertTrue(gib(6.2)...gib(6.7) ~= estimate(for: llama8B), llama8B.name)
        XCTAssertTrue(gib(44.0)...gib(46.0) ~= estimate(for: llama70B), llama70B.name)
    }

    func testKVCacheMatchesExactLlamaCppAllocation() throws {
        // 8B/GQA at 8192 tokens with an f16 K and V cache is exactly 1 GiB:
        //   2 caches · 32 layers · 8 kv_heads · 128 head_dim · 2 bytes · 8192 ctx = 1 GiB.
        // Verified by differencing two context lengths so weights/overhead cancel out.
        let arch = Self.denseArch(layers: 32, heads: 32, kvHeads: 8, headDim: 128, hidden: 4_096)
        let size = gib(4.66)
        let at8192 = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf, sizeBytes: size, contextLength: 8_192,
            layerCount: 32, moeInfo: arch, kvCacheEstimate: .f16F16
        ).estimate
        let at4096 = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf, sizeBytes: size, contextLength: 4_096,
            layerCount: 32, moeInfo: arch, kvCacheEstimate: .f16F16
        ).estimate
        // The safety reserve is a fixed, launch-calibrated allocation, so it cancels
        // when contexts are differenced. The delta is the exact KV growth.
        let deltaKV = Double(at8192 - at4096)
        XCTAssertEqual(deltaKV / 1_073_741_824.0, 0.5, accuracy: 0.001)
    }

    func testGroupedQueryAttentionShrinksKVCacheVersusMultiHead() throws {
        let size = gib(4.66)
        let mha = Self.denseArch(layers: 32, heads: 32, kvHeads: 32, headDim: 128, hidden: 4_096)
        let gqa = Self.denseArch(layers: 32, heads: 32, kvHeads: 8, headDim: 128, hidden: 4_096)

        func kv(_ arch: MoEInfo) -> Int64 {
            // Isolate KV by differencing two contexts so weights cancel.
            let hi = ModelRAMAdvisor.estimateAndBudget(format: .gguf, sizeBytes: size, contextLength: 8_192, layerCount: 32, moeInfo: arch, kvCacheEstimate: .f16F16).estimate
            let lo = ModelRAMAdvisor.estimateAndBudget(format: .gguf, sizeBytes: size, contextLength: 4_096, layerCount: 32, moeInfo: arch, kvCacheEstimate: .f16F16).estimate
            return hi - lo
        }
        // 32 KV heads vs 8 KV heads → exactly 4× the cache.
        XCTAssertEqual(Double(kv(mha)) / Double(kv(gqa)), 4.0, accuracy: 0.01)
    }

    func testQuantizedKVCacheExpandsMaxContext() throws {
        let llama8B = GGUFMetadataFixture(
            name: "Meta-Llama-3.1-8B-Instruct-Q4_K_M",
            sizeBytes: gib(4.66),
            layerCount: 32,
            contextLength: 8_192,
            budgetBytes: gib(8),
            upperBound: 131_072,
            moeInfo: Self.denseArch(layers: 32, heads: 32, kvHeads: 8, headDim: 128, hidden: 4_096)
        )

        let f16Context = maxContext(for: llama8B, kvCacheEstimate: .init(kCacheQuant: .f16, vCacheQuant: .f16))
        let q4Context = maxContext(for: llama8B, kvCacheEstimate: .init(kCacheQuant: .q4_1, vCacheQuant: .q4_1))

        // f16 KV is 2 bytes/elem, q4_1 is 0.625. With a fixed measured reserve
        // instead of a whole-model multiplier, more of the 8 GiB budget remains
        // available to the cache.
        XCTAssertTrue(20_000...22_000 ~= f16Context)
        XCTAssertGreaterThan(q4Context, 50_000)
        XCTAssertGreaterThan(q4Context, f16Context)
    }

    // MARK: - MoE weight footprint (all experts are resident)

    func testMoEWeightFootprintIsIndependentOfActiveExpertCount() throws {
        // mmap maps every expert, so resident weights ≈ file size regardless of top-k gating.
        let mixtralTop2 = GGUFMetadataFixture(
            name: "Mixtral-8x7B top-2",
            sizeBytes: gib(26.4),
            layerCount: 32,
            contextLength: 8_192,
            budgetBytes: gib(32),
            upperBound: 65_536,
            moeInfo: Self.mixtralMoE(activeExperts: 2)
        )
        var mixtralTop8 = mixtralTop2
        mixtralTop8.name = "Mixtral-8x7B top-8"
        mixtralTop8.moeInfo = Self.mixtralMoE(activeExperts: 8)

        let top2Estimate = estimate(for: mixtralTop2)
        let top8Estimate = estimate(for: mixtralTop8)

        // Equal estimates: active routing does not change resident expert weights.
        XCTAssertEqual(top2Estimate, top8Estimate)
        XCTAssertTrue(gib(29.0)...gib(30.0) ~= top2Estimate)
    }

    // MARK: - Fallback when attention metadata is missing

    func testFallbackEstimateWithoutAttentionMetadataStaysSane() throws {
        // No moeInfo at all → coarse hidden·gqaRatio heuristic, but still bounded and
        // dominated by the weight term rather than exploding the KV term.
        let (estimate, _) = ModelRAMAdvisor.estimateAndBudget(
            format: .gguf,
            sizeBytes: gib(4.66),
            contextLength: 8_192,
            layerCount: 32,
            moeInfo: nil,
            kvCacheEstimate: .f16F16
        )
        let gb = Double(estimate) / 1_073_741_824.0
        XCTAssertGreaterThan(gb, 4.66)   // at least the weights
        XCTAssertLessThan(gb, 12.0)      // far below the old ~8.9 GiB-and-climbing heuristic blow-up
    }

    // MARK: - Peak runtime allocations

    func testPhysicalBatchSizeChangesGGUFComputeBufferEstimate() {
        var architecture = Self.denseArch(
            layers: 64,
            heads: 40,
            kvHeads: 8,
            headDim: 128,
            hidden: 5_120
        )
        architecture.feedForwardSize = 17_408
        architecture.vocabSize = 248_320

        let large = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: 3_803_452_480,
            contextLength: 4_096,
            layerCount: 64,
            moeInfo: architecture,
            runtimeConfiguration: .init(evaluationBatchSize: 2_048, physicalBatchSize: 1_024)
        )
        let conservative = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: 3_803_452_480,
            contextLength: 4_096,
            layerCount: 64,
            moeInfo: architecture,
            runtimeConfiguration: .init(evaluationBatchSize: 512, physicalBatchSize: 256)
        )

        XCTAssertGreaterThan(large.computeBuffers, conservative.computeBuffers)
        XCTAssertGreaterThan(large.estimate - conservative.estimate, mib(300))
    }

    func testVisionProjectorIsIncludedOnlyWhenConfigured() {
        let projectorBytes = Int64(931_000_000)
        let withoutProjector = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: gib(3.5),
            contextLength: 4_096,
            layerCount: 32
        )
        let withProjector = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: gib(3.5),
            contextLength: 4_096,
            layerCount: 32,
            runtimeConfiguration: .init(projectorFileBytes: projectorBytes)
        )

        XCTAssertEqual(withoutProjector.visionProjector, 0)
        XCTAssertGreaterThan(withProjector.visionProjector, projectorBytes)
        XCTAssertGreaterThan(withProjector.estimate, withoutProjector.estimate)
    }

    func testHybridAttentionChargesKVOnlyToAttentionBlocks() {
        let dense = Self.denseArch(
            layers: 64,
            heads: 40,
            kvHeads: 8,
            headDim: 128,
            hidden: 5_120
        )
        var hybrid = dense
        hybrid.architecture = "qwen35"
        hybrid.attentionLayerCount = 16
        hybrid.recurrentLayerCount = 48
        hybrid.ssmConvKernel = 4
        hybrid.ssmInnerSize = 8_192
        hybrid.ssmStateSize = 128
        hybrid.ssmGroupCount = 8

        func contextGrowth(_ architecture: MoEInfo) -> Int64 {
            let high = ModelRAMAdvisor.estimateAndBudget(
                format: .gguf,
                sizeBytes: 3_803_452_480,
                contextLength: 8_192,
                layerCount: 64,
                moeInfo: architecture
            ).estimate
            let low = ModelRAMAdvisor.estimateAndBudget(
                format: .gguf,
                sizeBytes: 3_803_452_480,
                contextLength: 4_096,
                layerCount: 64,
                moeInfo: architecture
            ).estimate
            return high - low
        }

        XCTAssertEqual(Double(contextGrowth(dense)) / Double(contextGrowth(hybrid)), 4.0, accuracy: 0.01)
        XCTAssertGreaterThan(
            ModelRAMAdvisor.estimateBreakdown(
                format: .gguf,
                sizeBytes: 3_803_452_480,
                contextLength: 4_096,
                layerCount: 64,
                moeInfo: hybrid
            ).recurrentState,
            0
        )
    }

    func testMobilePlanningBudgetUsesLiveIncrementalHeadroom() {
        let budget = ModelRAMAdvisor.mobilePlanningBudgetBytes(
            conservativeBudget: gib(10.5),
            liveAvailable: gib(5),
            currentFootprint: gib(1),
            reserveBytes: gib(0.5)
        )

        XCTAssertEqual(budget, gib(4.5))
    }

    func testAdvisoryWorkingSetAllowsOnlySmallMMapOvercommit() {
        XCTAssertEqual(
            ModelRAMAdvisor.advisoryWorkingSetLimitBytes(
                processLimitBytes: gib(6),
                mappedWorkingSetOvercommitRatio: 1.11
            ),
            Int64(Double(gib(6)) * 1.11)
        )
    }

    func testUltraLowBitMetalReserveIsQuantSpecific() {
        let q1 = ModelRAMAdvisor.RuntimeConfiguration(
            modelPath: "/models/Bonsai-27B-Q1_0.gguf"
        )
        let q3 = ModelRAMAdvisor.RuntimeConfiguration(
            modelPath: "/models/Qwen3.5-9B-Q3_K_M.gguf"
        )

#if os(macOS) || targetEnvironment(macCatalyst)
        XCTAssertEqual(ModelRAMAdvisor.additionalMetalSafetyReserveBytes(runtimeConfiguration: q1), 0)
#else
        XCTAssertEqual(ModelRAMAdvisor.additionalMetalSafetyReserveBytes(runtimeConfiguration: q1), gib(1))
#endif
        XCTAssertEqual(ModelRAMAdvisor.additionalMetalSafetyReserveBytes(runtimeConfiguration: q3), 0)
    }

    func testIncrementalProcessAllocationDoesNotRechargeMMapModelBuffers() {
        let incremental = ModelRAMAdvisor.incrementalProcessAllocationBytes(
            modelBytes: UInt64(gib(4.5)),
            contextBytes: UInt64(mib(320)),
            computeBytes: UInt64(mib(640)),
            projectorBytes: UInt64(mib(768)),
            speculativeBytes: UInt64(mib(96)),
            chargeMappedModelBuffers: false
        )

        XCTAssertEqual(incremental, mib(1_824))
    }

    func testLiveProcessMemoryLimitRequiresACompleteSnapshot() {
        XCTAssertEqual(
            ModelRAMAdvisor.liveProcessMemoryLimitBytes(
                liveAvailable: gib(5),
                currentFootprint: gib(1)
            ),
            gib(6)
        )
        XCTAssertNil(
            ModelRAMAdvisor.liveProcessMemoryLimitBytes(
                liveAvailable: gib(5),
                currentFootprint: nil
            )
        )
    }

    func testMobilePlanningBudgetDoesNotClampLiveHeadroomToDeviceTable() {
        let budget = ModelRAMAdvisor.mobilePlanningBudgetBytes(
            conservativeBudget: gib(6),
            liveAvailable: gib(8),
            currentFootprint: gib(1),
            reserveBytes: gib(0.5)
        )

        XCTAssertEqual(budget, gib(7.5))
    }

    func testMobilePlanningBudgetFallsBackWhenRuntimeHeadroomIsUnavailable() {
        XCTAssertEqual(
            ModelRAMAdvisor.mobilePlanningBudgetBytes(
                conservativeBudget: gib(7),
                liveAvailable: nil,
                currentFootprint: gib(1)
            ),
            gib(6)
        )
    }

    func testMobilePlanningBudgetDoesNotRequireFootprintForLiveHeadroom() {
        XCTAssertEqual(
            ModelRAMAdvisor.mobilePlanningBudgetBytes(
                conservativeBudget: gib(10.5),
                liveAvailable: gib(1),
                currentFootprint: nil
            ),
            gib(1)
        )
    }

    func testTransientReserveUsesMeasuredLaunchSamplesInsteadOfModelMultiplier() throws {
        let suiteName = "ModelRAMAdvisorFixtureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ModelRAMAdvisor.calibratedTransientReserveBytes(defaults: defaults), mib(192))
        ModelRAMAdvisor.recordSuccessfulGGUFLaunch(
            estimatedIncrementalBytes: gib(4),
            baselineFootprintBytes: gib(1),
            peakFootprintBytes: gib(5) + mib(224),
            defaults: defaults
        )

        XCTAssertEqual(ModelRAMAdvisor.calibratedTransientReserveBytes(defaults: defaults), mib(256))
    }

    func testKnownWorkingContextCannotCollapseToTheMinimum() {
        let architecture = Self.denseArch(
            layers: 32,
            heads: 16,
            kvHeads: 4,
            headDim: 256,
            hidden: 4_096
        )
        let context = ModelRAMAdvisor.maxContextUnderBudget(
            format: .gguf,
            sizeBytes: 4_400_000_000,
            layerCount: 32,
            moeInfo: architecture,
            upperBound: 262_144,
            budgetBytesOverride: gib(1),
            knownWorkingContextLength: 20_000
        )

        XCTAssertGreaterThanOrEqual(context ?? 0, 20_000)
    }

    func testExactSizingCurveUsesMeasuredPerTokenSlope() throws {
        let samples = [
            ModelRAMAdvisor.ExactWorkingSetSample(
                contextLength: 4_096,
                bytes: 3_000_000_000
            ),
            ModelRAMAdvisor.ExactWorkingSetSample(
                contextLength: 131_072,
                bytes: 12_000_000_000
            )
        ]

        XCTAssertEqual(
            ModelRAMAdvisor.interpolatedExactWorkingSet(
                contextLength: 4_096,
                samples: samples
            ),
            3_000_000_000
        )
        XCTAssertEqual(
            ModelRAMAdvisor.interpolatedExactWorkingSet(
                contextLength: 131_072,
                samples: samples
            ),
            12_000_000_000
        )

        let midpoint = (4_096 + 131_072) / 2
        XCTAssertEqual(
            ModelRAMAdvisor.interpolatedExactWorkingSet(
                contextLength: midpoint,
                samples: samples
            ),
            7_500_000_000
        )
    }

    func testExactSizingCurveNeverProjectsADecreasingMemorySlope() throws {
        let noisySamples = [
            ModelRAMAdvisor.ExactWorkingSetSample(contextLength: 4_096, bytes: 4_000),
            ModelRAMAdvisor.ExactWorkingSetSample(contextLength: 8_192, bytes: 3_900)
        ]

        XCTAssertEqual(
            ModelRAMAdvisor.interpolatedExactWorkingSet(
                contextLength: 16_384,
                samples: noisySamples
            ),
            4_000
        )
    }

    func testSettingsExactSizingPreservesLargeGGUFAccuracyWithoutSamplingExtremeMTPContext() {
        let standard = ModelRAMAdvisor.RuntimeConfiguration()
        let mtp = ModelRAMAdvisor.RuntimeConfiguration(mtpEnabled: true)

        XCTAssertTrue(ModelRAMAdvisor.permitsSettingsExactSizing(
            contextLength: 18_000,
            runtimeConfiguration: standard
        ))
        XCTAssertFalse(ModelRAMAdvisor.permitsSettingsExactSizing(
            contextLength: 262_144,
            runtimeConfiguration: standard
        ))
        XCTAssertTrue(ModelRAMAdvisor.permitsSettingsExactSizing(
            contextLength: 8_192,
            runtimeConfiguration: mtp
        ))
        XCTAssertFalse(ModelRAMAdvisor.permitsSettingsExactSizing(
            contextLength: 8_193,
            runtimeConfiguration: mtp
        ))

        XCTAssertEqual(
            ModelRAMAdvisor.settingsExactSizingContexts(
                selectedContext: 4_096,
                lowerBound: 512,
                upperBound: 262_144,
                runtimeConfiguration: mtp
            ),
            [4_096, 8_192]
        )
        let bonsaiContexts = ModelRAMAdvisor.settingsExactSizingContexts(
            selectedContext: 4_096,
            lowerBound: 512,
            upperBound: 131_072,
            runtimeConfiguration: standard
        )
        XCTAssertEqual(bonsaiContexts, [4_096, 32_768])
        XCTAssertTrue(bonsaiContexts.max()! >= 18_000)
    }

    // MARK: - Fixtures & helpers

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

    /// Dense transformer architecture descriptor with explicit attention shape.
    private static func denseArch(layers: Int, heads: Int, kvHeads: Int, headDim: Int, hidden: Int) -> MoEInfo {
        MoEInfo(
            isMoE: false,
            expertCount: 0,
            defaultUsed: nil,
            moeLayerCount: nil,
            totalLayerCount: layers,
            hiddenSize: hidden,
            feedForwardSize: nil,
            vocabSize: nil,
            headCount: heads,
            headCountKV: kvHeads,
            keyLength: headDim,
            valueLength: headDim
        )
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
            vocabSize: 32_000,
            headCount: 32,
            headCountKV: 8,
            keyLength: 128,
            valueLength: 128
        )
    }

    private func gib(_ value: Double) -> Int64 {
        Int64(value * 1_073_741_824.0)
    }

    private func mib(_ value: Double) -> Int64 {
        Int64(value * 1_048_576.0)
    }

}
