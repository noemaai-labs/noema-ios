import XCTest
@testable import Noema

final class GenerationPowerPolicyTests: XCTestCase {
    func testNominalEnvironmentLeavesSettingsUnchanged() {
        var settings = ModelSettings.default(for: .gguf)
        settings.cpuThreads = min(4, ModelSettings.maxInferenceThreadCount)
        settings.contextLength = 8192
        settings.keepInMemory = true

        let decision = GenerationPowerPolicy.adjustedSettings(
            settings,
            format: .gguf,
            environment: .init(
                thermalState: .nominal,
                lowPowerMode: false,
                activeProcessorCount: 8
            )
        )

        XCTAssertFalse(decision.adapted)
        XCTAssertEqual(decision.settings.cpuThreads, settings.cpuThreads)
        XCTAssertEqual(decision.settings.contextLength, settings.contextLength)
        XCTAssertTrue(decision.settings.keepInMemory)
    }

    func testLowPowerModeReducesThreadsAndCapsContext() {
        var settings = ModelSettings.default(for: .gguf)
        settings.cpuThreads = ModelSettings.maxInferenceThreadCount
        settings.contextLength = 16_384
        settings.keepInMemory = true

        let activeProcessors = max(8, ModelSettings.maxInferenceThreadCount)
        let decision = GenerationPowerPolicy.adjustedSettings(
            settings,
            format: .gguf,
            environment: .init(
                thermalState: .nominal,
                lowPowerMode: true,
                activeProcessorCount: activeProcessors
            )
        )

        XCTAssertTrue(decision.adapted)
        XCTAssertEqual(decision.reasons, [.lowPowerMode])
        XCTAssertEqual(decision.settings.cpuThreads, min(ModelSettings.maxInferenceThreadCount, activeProcessors / 2))
        XCTAssertEqual(Int(decision.settings.contextLength), 4096)
        XCTAssertFalse(decision.settings.keepInMemory)
    }

    func testCriticalThermalStateUsesStrongerLimits() {
        var settings = ModelSettings.default(for: .mlx)
        settings.cpuThreads = ModelSettings.maxInferenceThreadCount
        settings.contextLength = 16_384
        settings.keepInMemory = true
        settings.disableWarmup = false

        let activeProcessors = max(9, ModelSettings.maxInferenceThreadCount)
        let decision = GenerationPowerPolicy.adjustedSettings(
            settings,
            format: .mlx,
            environment: .init(
                thermalState: .critical,
                lowPowerMode: false,
                activeProcessorCount: activeProcessors
            )
        )

        XCTAssertTrue(decision.adapted)
        XCTAssertEqual(decision.reasons, [.criticalThermal])
        XCTAssertEqual(decision.settings.cpuThreads, min(ModelSettings.maxInferenceThreadCount, activeProcessors / 3))
        XCTAssertEqual(Int(decision.settings.contextLength), 2048)
        XCTAssertFalse(decision.settings.keepInMemory)
        XCTAssertTrue(decision.settings.disableWarmup)
    }

    func testNonConfigurableFormatsAreNotAdapted() {
        var settings = ModelSettings.default(for: .afm)
        settings.cpuThreads = 1
        settings.contextLength = 4096

        let decision = GenerationPowerPolicy.adjustedSettings(
            settings,
            format: .afm,
            environment: .init(
                thermalState: .critical,
                lowPowerMode: true,
                activeProcessorCount: 8
            )
        )

        XCTAssertFalse(decision.adapted)
        XCTAssertEqual(decision.settings, settings)
        XCTAssertTrue(decision.reasons.isEmpty)
    }
}
