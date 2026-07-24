import XCTest
@testable import Noema

final class AssistantOutputSanitizerTests: XCTestCase {
    func testStripsBareEOTFromNormalVisibleMessageText() {
        let message = ChatVM.Msg(role: "🤖", text: "Finished answer<eot>\n")

        XCTAssertEqual(message.trimmedVisibleAssistantText, "Finished answer")
    }

    func testStripsLlamaFourEOTVariantAndTrailingWhitespace() {
        let cleaned = AssistantOutputSanitizer.strippingTrailingControlMarkers(
            from: "Finished answer<|eot|>\n  "
        )

        XCTAssertEqual(cleaned, "Finished answer")
    }

    func testStripsRepeatedTerminalMarkers() {
        let cleaned = AssistantOutputSanitizer.strippingTrailingControlMarkers(
            from: "Finished answer<eot><|eot|>\n"
        )

        XCTAssertEqual(cleaned, "Finished answer")
    }

    func testPreservesNonTerminalMention() {
        let text = "The <eot> marker ends a generated turn."

        XCTAssertEqual(
            AssistantOutputSanitizer.strippingTrailingControlMarkers(from: text),
            text
        )
    }

    func testLocallyEnforcedStopsIncludeReportedVariantsWithoutDuplicates() {
        let stops = AssistantOutputSanitizer.locallyEnforcedStopSequences(
            including: ["<|eot_id|>"]
        )

        XCTAssertTrue(stops.contains("<eot>"))
        XCTAssertTrue(stops.contains("<|eot|>"))
        XCTAssertEqual(stops.filter { $0 == "<|eot_id|>" }.count, 1)
    }

    func testStripsNestedReasoningFromContinuationReplay() {
        let raw = "<think><think>private chain</think></think>\nVisible answer tail."

        XCTAssertEqual(
            AssistantOutputSanitizer.strippingReasoningBlocks(from: raw),
            "Visible answer tail."
        )
    }

    func testClosesEveryInterruptedReasoningBlockBeforeVisibleResume() {
        let interrupted = "<think><think>unfinished reasoning"
        let closed = AssistantOutputSanitizer.closingUnterminatedReasoningBlocks(in: interrupted)

        XCTAssertTrue(closed.hasSuffix("</think>\n</think>\n\n"))
        XCTAssertEqual(
            AssistantOutputSanitizer.strippingReasoningBlocks(from: closed + "Final answer."),
            "Final answer."
        )
    }
}
