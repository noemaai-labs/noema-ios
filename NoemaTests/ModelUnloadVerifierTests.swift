import XCTest
@testable import Noema

final class ModelUnloadVerifierTests: XCTestCase {
    func testRecoveredWhenFootprintDropsPastThreshold() {
        let result = ModelUnloadVerifier.evaluate(
            before: snapshot(footprint: 1_000_000_000),
            after: snapshot(footprint: 900_000_000)
        )

        XCTAssertEqual(result.status, .recovered)
        XCTAssertEqual(result.releasedBytes, 100_000_000)
        XCTAssertEqual(result.beforeFootprintBytes, 1_000_000_000)
        XCTAssertEqual(result.afterFootprintBytes, 900_000_000)
    }

    func testUnchangedWhenFootprintDropIsSmall() {
        let result = ModelUnloadVerifier.evaluate(
            before: snapshot(footprint: 1_000_000_000),
            after: snapshot(footprint: 990_000_000)
        )

        XCTAssertEqual(result.status, .unchanged)
        XCTAssertEqual(result.releasedBytes, 10_000_000)
    }

    func testIncreasedWhenFootprintGrows() {
        let result = ModelUnloadVerifier.evaluate(
            before: snapshot(footprint: 1_000_000_000),
            after: snapshot(footprint: 1_050_000_000)
        )

        XCTAssertEqual(result.status, .increased)
        XCTAssertEqual(result.releasedBytes, 0)
    }

    func testUnavailableWhenFootprintCannotBeSampled() {
        let missingBefore = ModelUnloadVerifier.evaluate(
            before: snapshot(footprint: 0),
            after: snapshot(footprint: 900_000_000)
        )
        let missingAfter = ModelUnloadVerifier.evaluate(
            before: snapshot(footprint: 1_000_000_000),
            after: snapshot(footprint: 0)
        )

        XCTAssertEqual(missingBefore.status, .unavailable)
        XCTAssertEqual(missingAfter.status, .unavailable)
    }

    private func snapshot(footprint: Int64) -> LiveMemoryPressureSnapshot {
        LiveMemoryPressureSnapshot(
            footprintBytes: footprint,
            availableBytes: 2_000_000_000,
            budgetBytes: 3_000_000_000,
            thermalState: .nominal,
            sampledAt: Date()
        )
    }
}
