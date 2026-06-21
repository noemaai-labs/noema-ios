import XCTest
@testable import Noema

final class ImagePromptBudgetEstimatorTests: XCTestCase {
    func testEstimatesPromptTokensAndBytesForMultipleImages() {
        let estimate = ImagePromptBudgetEstimator.estimate(
            imageCount: 3,
            totalFileBytes: 1_500_000,
            usablePromptTokens: 8_000
        )

        XCTAssertEqual(estimate.imageCount, 3)
        XCTAssertEqual(estimate.estimatedPromptTokens, 1_728)
        XCTAssertEqual(estimate.totalFileBytes, 1_500_000)
        XCTAssertEqual(estimate.status, .comfortable)
    }

    func testMarksImageBudgetTightAtThirtyFivePercent() {
        let estimate = ImagePromptBudgetEstimator.estimate(
            imageCount: 5,
            totalFileBytes: 2_000_000,
            usablePromptTokens: 8_000
        )

        XCTAssertEqual(estimate.estimatedPromptTokens, 2_880)
        XCTAssertEqual(estimate.status, .tight)
    }

    func testMarksImageBudgetOverWhenImagesExceedPromptBudget() {
        let estimate = ImagePromptBudgetEstimator.estimate(
            imageCount: 5,
            totalFileBytes: 2_000_000,
            usablePromptTokens: 2_000
        )

        XCTAssertEqual(estimate.status, .overBudget)
        XCTAssertEqual(estimate.fractionOfPromptBudget, 1)
    }

    func testClampsNegativeInputs() {
        let estimate = ImagePromptBudgetEstimator.estimate(
            imageCount: -2,
            totalFileBytes: -10,
            usablePromptTokens: -1
        )

        XCTAssertEqual(estimate.imageCount, 0)
        XCTAssertEqual(estimate.estimatedPromptTokens, 0)
        XCTAssertEqual(estimate.totalFileBytes, 0)
        XCTAssertEqual(estimate.usablePromptTokens, 0)
        XCTAssertEqual(estimate.status, .comfortable)
    }
}
