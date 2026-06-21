import XCTest
@testable import Noema

final class ConflictingSourceDetectorTests: XCTestCase {
    func testDetectsNumericConflictsAcrossSources() {
        let conflicts = ConflictingSourceDetector.detect(in: [
            SourceSnippet(id: "a", sourceName: "Guide A", text: "The context length is 4096 tokens."),
            SourceSnippet(id: "b", sourceName: "Guide B", text: "Context length is 8192 tokens.")
        ])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].kind, .numeric)
        XCTAssertEqual(conflicts[0].claimKey, "context length")
        XCTAssertEqual(conflicts[0].uniqueValues, ["4096 tokens", "8192 tokens"])
        XCTAssertEqual(conflicts[0].sourceNames, ["Guide A", "Guide B"])
    }

    func testDetectsStateConflictsAcrossSources() {
        let conflicts = ConflictingSourceDetector.detect(in: [
            SourceSnippet(id: "a", sourceName: "Spec A", text: "Noema supports image input."),
            SourceSnippet(id: "b", sourceName: "Spec B", text: "Noema does not support image input.")
        ])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].kind, .state)
        XCTAssertEqual(conflicts[0].claimKey, "noema supports image input")
        XCTAssertEqual(conflicts[0].uniqueValues, ["no", "yes"])
    }

    func testIgnoresMatchingClaims() {
        let conflicts = ConflictingSourceDetector.detect(in: [
            SourceSnippet(id: "a", sourceName: "Guide A", text: "The context length is 4096 tokens."),
            SourceSnippet(id: "b", sourceName: "Guide B", text: "Context length is 4096 tokens.")
        ])

        XCTAssertTrue(conflicts.isEmpty)
    }

    func testRequiresMoreThanOneSource() {
        let conflicts = ConflictingSourceDetector.detect(in: [
            SourceSnippet(id: "a", sourceName: "Guide A", text: "The context length is 4096 tokens. Context length is 8192 tokens.")
        ])

        XCTAssertTrue(conflicts.isEmpty)
    }
}
