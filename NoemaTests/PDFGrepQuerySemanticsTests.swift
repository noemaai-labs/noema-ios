import XCTest
@testable import Noema

final class PDFGrepQuerySemanticsTests: XCTestCase {
    func testPlainMultiWordZeroMatchGetsCorrectiveHint() {
        let hint = PDFGrepQuerySemantics.zeroMatchHint(
            query: "hardware GPU computing training used",
            regex: false
        )

        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("one contiguous phrase") == true)
        XCTAssertTrue(hint?.contains("separate grep call") == true)
    }

    func testSingleTermAndRegexQueriesDoNotGetLiteralPhraseHint() {
        XCTAssertNil(PDFGrepQuerySemantics.zeroMatchHint(query: "hardware", regex: false))
        XCTAssertNil(
            PDFGrepQuerySemantics.zeroMatchHint(
                query: "hardware|GPU|accelerator",
                regex: true
            )
        )
    }

    func testSystemGuidanceForbidsKeywordListsInPlainGrep() {
        let guidance = SystemPromptResolver.pdfReadToolGuidance(includeThinkRestriction: false)

        XCTAssertTrue(guidance.contains("one literal contiguous substring"))
        XCTAssertTrue(guidance.contains("Never combine unrelated search terms"))
        XCTAssertTrue(guidance.contains("make a separate `grep` call"))
    }
}
