import XCTest
@testable import Noema

@MainActor
final class DatasetManagerProgressTests: XCTestCase {
    func testNormalizedStatusForForwardProgressClampsRegressionWithinSameStage() {
        let previous = DatasetProcessingStatus(
            stage: .embedding,
            progress: 0.10,
            message: "Warming up embedding model…",
            etaSeconds: nil
        )
        let incoming = DatasetProcessingStatus(
            stage: .embedding,
            progress: 0.06,
            message: "Priming first embedding pass…",
            etaSeconds: nil
        )

        let normalized = DatasetManager.normalizedStatusForForwardProgress(previous: previous, incoming: incoming)

        XCTAssertEqual(normalized.stage, .embedding)
        XCTAssertEqual(normalized.progress, 0.10, accuracy: 0.0001)
        XCTAssertEqual(normalized.message, "Priming first embedding pass…")
    }

    func testNormalizedStatusForForwardProgressAllowsStageTransitionsToResetProgress() {
        let previous = DatasetProcessingStatus(
            stage: .embedding,
            progress: 0.55,
            message: "Embedding",
            etaSeconds: 40
        )
        let incoming = DatasetProcessingStatus(
            stage: .completed,
            progress: 1.0,
            message: "Ready for use",
            etaSeconds: 0
        )

        let normalized = DatasetManager.normalizedStatusForForwardProgress(previous: previous, incoming: incoming)

        XCTAssertEqual(normalized.stage, .completed)
        XCTAssertEqual(normalized.progress, 1.0, accuracy: 0.0001)
        XCTAssertEqual(normalized.message, "Ready for use")
    }

    func testNormalizedStatusForForwardProgressLeavesForwardMovementUntouched() {
        let previous = DatasetProcessingStatus(
            stage: .embedding,
            progress: 0.55,
            message: "Embedding",
            etaSeconds: 40
        )
        let incoming = DatasetProcessingStatus(
            stage: .embedding,
            progress: 0.62,
            message: "Embedding",
            etaSeconds: 35
        )

        let normalized = DatasetManager.normalizedStatusForForwardProgress(previous: previous, incoming: incoming)

        XCTAssertEqual(normalized.stage, .embedding)
        XCTAssertEqual(normalized.progress, 0.62, accuracy: 0.0001)
        XCTAssertEqual(normalized.etaSeconds ?? -1, 35, accuracy: 0.0001)
    }
}
