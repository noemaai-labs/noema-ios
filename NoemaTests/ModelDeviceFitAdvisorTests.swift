import XCTest
@testable import Noema

final class ModelDeviceFitAdvisorTests: XCTestCase {
    func testUsesBenchmarkWhenAvailable() {
        let result = benchmarkResult(generationRate: 28, timeToFirstToken: 0.7)

        let assessment = ModelDeviceFitAdvisor.assess(
            format: .gguf,
            sizeBytes: 80_000_000_000,
            benchmark: result
        )

        XCTAssertEqual(assessment.source, .benchmark)
        XCTAssertEqual(assessment.status, .works)
        XCTAssertEqual(assessment.generationRate, 28)
        XCTAssertNil(assessment.estimatedBytes)
    }

    func testSlowBenchmarkIsMarkedUnlikely() {
        let result = benchmarkResult(generationRate: 1.2, timeToFirstToken: 18)

        let assessment = ModelDeviceFitAdvisor.assess(
            format: .gguf,
            sizeBytes: 1_000_000_000,
            benchmark: result
        )

        XCTAssertEqual(assessment.source, .benchmark)
        XCTAssertEqual(assessment.status, .unlikely)
    }

    func testFallsBackToDeviceEstimateWithoutBenchmark() {
        let assessment = ModelDeviceFitAdvisor.assess(
            format: .gguf,
            sizeBytes: 1_000_000_000,
            benchmark: nil
        )

        XCTAssertEqual(assessment.source, .estimate)
        XCTAssertNotNil(assessment.estimatedBytes)
    }

    private func benchmarkResult(generationRate: Double, timeToFirstToken: TimeInterval) -> ModelBenchmarkResult {
        ModelBenchmarkResult(
            format: .gguf,
            settings: ModelSettings(),
            kvCacheOffloadActive: true,
            promptTokens: 64,
            promptRate: 120,
            generationTokens: 128,
            generationRate: generationRate,
            totalDuration: 5,
            timeToFirstToken: timeToFirstToken,
            peakMemoryBytes: 4_000_000_000,
            memoryDeltaBytes: 512_000_000,
            outputPreview: "Benchmark preview",
            completedAt: Date(timeIntervalSince1970: 1_780_000_000),
            speculativeTimings: nil
        )
    }
}
