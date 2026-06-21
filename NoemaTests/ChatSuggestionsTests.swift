import XCTest
@testable import Noema

final class ChatSuggestionsTests: XCTestCase {
    func testDatasetSuggestionsUseDatasetName() {
        let suggestions = ChatSuggestions.nextThree(datasetName: "Biology Notes")

        XCTAssertEqual(suggestions.count, 3)
        XCTAssertTrue(suggestions.allSatisfy { $0.contains("Biology Notes") })
        XCTAssertTrue(suggestions.contains("Summarize Biology Notes with citations."))
    }

    func testDatasetSuggestionsTrimLongNamesForMobileOverlay() {
        let longName = String(repeating: "A", count: 80)
        let suggestions = ChatSuggestions.nextThree(datasetName: longName)

        XCTAssertTrue(suggestions.allSatisfy { !$0.contains(longName) })
        XCTAssertTrue(suggestions.allSatisfy { $0.contains("...") })
    }

    func testBlankDatasetNameFallsBackToGenericSuggestions() {
        let suggestions = ChatSuggestions.nextThree(datasetName: "   ")

        XCTAssertEqual(suggestions.count, 3)
        XCTAssertFalse(suggestions.contains { $0.contains("  ") })
    }
}
