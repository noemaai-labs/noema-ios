import Foundation
import XCTest
@testable import Noema

final class OverfitLatencyClassifierTests: XCTestCase {

    // MARK: - Golden pin

    /// The production thresholds are a contract with stored canary records:
    /// changing any value silently reclassifies models users already measured,
    /// so every change must be deliberate enough to update this pin.
    func testProductionThresholdsArePinned() {
        let t = OverfitLatencyThresholds.production
        XCTAssertEqual(t.interactiveP50Ms, 150)
        XCTAssertEqual(t.interactiveP95Ms, 350)
        XCTAssertEqual(t.interactiveStallsPer128, 0)
        XCTAssertEqual(t.slowP50Ms, 400)
        XCTAssertEqual(t.slowP95Ms, 1200)
        XCTAssertEqual(t.slowStallsPer128, 2)
        XCTAssertEqual(t.stallFloorMs, 1000)
    }

    // MARK: - summarize

    func testSummarizeEmptyReturnsNil() {
        XCTAssertNil(OverfitLatencyClassifier.summarize(interTokenLatenciesMs: []))
    }

    func testSummarizeComputesInterpolatedPercentiles() throws {
        let sample = try XCTUnwrap(OverfitLatencyClassifier.summarize(
            interTokenLatenciesMs: [50, 10, 30, 20, 40]
        ))
        XCTAssertEqual(sample.p50Ms, 30, accuracy: 1e-9)
        // rank 0.95 * 4 = 3.8 -> 40 * 0.2 + 50 * 0.8
        XCTAssertEqual(sample.p95Ms, 48, accuracy: 1e-9)
        // rank 0.99 * 4 = 3.96 -> 40 * 0.04 + 50 * 0.96
        XCTAssertEqual(sample.p99Ms, 49.6, accuracy: 1e-9)
        XCTAssertEqual(sample.stallsPer128Tokens, 0)
        XCTAssertEqual(sample.tokenCount, 5)
    }

    func testSummarizeCountsOnlyLatenciesStrictlyAboveStallFloor() throws {
        // Exactly at the floor is not a stall; the floor itself is pinned above.
        let atFloor = try XCTUnwrap(OverfitLatencyClassifier.summarize(
            interTokenLatenciesMs: [100, 1000]
        ))
        XCTAssertEqual(atFloor.stallsPer128Tokens, 0)

        let aboveFloor = try XCTUnwrap(OverfitLatencyClassifier.summarize(
            interTokenLatenciesMs: [10, 20, 30, 40, 50, 1500]
        ))
        XCTAssertEqual(aboveFloor.stallsPer128Tokens, 128.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(aboveFloor.p50Ms, 35, accuracy: 1e-9)
    }

    // MARK: - classify boundaries

    private func sample(
        p50: Double,
        p95: Double,
        stallsPer128: Double = 0,
        tokenCount: Int = 128
    ) -> OverfitLatencySample {
        OverfitLatencySample(
            p50Ms: p50,
            p95Ms: p95,
            p99Ms: max(p50, p95),
            stallsPer128Tokens: stallsPer128,
            tokenCount: tokenCount
        )
    }

    func testClassifyInteractiveBoundaryIsInclusive() {
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 150, p95: 350)),
            .pagedInteractive
        )
    }

    func testClassifyJustPastInteractiveFallsToSlow() {
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 150.1, p95: 350)),
            .pagedSlow
        )
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 150, p95: 350.1)),
            .pagedSlow
        )
    }

    func testClassifyAnyStallDisqualifiesInteractive() {
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 10, p95: 20, stallsPer128: 0.5)),
            .pagedSlow
        )
    }

    func testClassifySlowBoundaryIsInclusive() {
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 400, p95: 1200, stallsPer128: 2)),
            .pagedSlow
        )
    }

    func testClassifyBeyondSlowIsOfflineOnly() {
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 400.1, p95: 1200)),
            .offlineOnly
        )
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 400, p95: 1200.1)),
            .offlineOnly
        )
        XCTAssertEqual(
            OverfitLatencyClassifier.classify(sample(p50: 400, p95: 1200, stallsPer128: 2.1)),
            .offlineOnly
        )
    }

    // MARK: - Monotonicity

    /// Uniformly worse latency can never yield a better label.
    func testClassificationIsMonotonicInLatencyScale() {
        func rank(_ classification: OverfitFitClassification) -> Int {
            switch classification {
            case .residentInteractive, .pagedInteractive: return 0
            case .pagedSlow: return 1
            case .offlineOnly, .relayRecommended, .unsupported: return 2
            }
        }
        let base: [Double] = [40, 60, 80, 100, 120, 140, 200, 260]
        var previousRank = Int.min
        for scale in [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0] {
            let scaled = base.map { $0 * scale }
            let sample = OverfitLatencyClassifier.summarize(interTokenLatenciesMs: scaled)!
            let currentRank = rank(OverfitLatencyClassifier.classify(sample))
            XCTAssertGreaterThanOrEqual(
                currentRank, previousRank,
                "scale \(scale) improved the classification"
            )
            previousRank = currentRank
        }
    }
}
