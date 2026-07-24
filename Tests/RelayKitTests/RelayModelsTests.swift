import Foundation
import XCTest
@testable import RelayKit

final class RelayModelsTests: XCTestCase {
    func testVisibleTextRemovesCompleteReasoningBlocksCaseInsensitively() {
        let text = "<THINK>private reasoning</THINK>\nVisible answer"
        XCTAssertEqual(RelayMessage.visibleText(from: text), "Visible answer")
    }

    func testVisibleTextHidesUnfinishedStreamingReasoning() {
        XCTAssertEqual(RelayMessage.visibleText(from: "Visible prefix\n<Think>private partial"), "Visible prefix")
        XCTAssertEqual(RelayMessage.visibleText(from: "<think>private partial"), "")
    }

    func testVisibleTextLeavesOrdinaryResponsesUnchanged() {
        XCTAssertEqual(RelayMessage.visibleText(from: "  ordinary response  "), "ordinary response")
    }

    func testStreamingPartialPreservesInboundSuffixAndReplacesOlderPartial() {
        let conversationID = UUID()
        let originalUser = RelayMessage(
            conversationID: conversationID,
            role: "user",
            text: "First question"
        )
        let base = RelayEnvelope(
            conversationID: conversationID,
            messages: [originalUser],
            needsResponse: true,
            parameters: ["temperature": "0.5"]
        )
        let priorPartial = RelayMessage(
            conversationID: conversationID,
            role: "assistant",
            text: "Old partial",
            fullText: "Old partial"
        )
        let newUser = RelayMessage(
            conversationID: conversationID,
            role: "user",
            text: "Follow-up"
        )
        let latest = RelayEnvelope(
            conversationID: conversationID,
            messages: [originalUser, priorPartial, newUser],
            needsResponse: true,
            parameters: ["temperature": "0.8"]
        )

        let merged = RelayEnvelope.streamingPartial(
            base: base,
            latest: latest,
            partial: "<think>private</think>Visible partial",
            timestamp: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(merged.messages.count, 3)
        XCTAssertEqual(merged.messages[0].id, originalUser.id)
        XCTAssertEqual(merged.messages[1].role, "assistant")
        XCTAssertEqual(merged.messages[1].text, "Visible partial")
        XCTAssertEqual(merged.messages[1].fullText, "<think>private</think>Visible partial")
        XCTAssertEqual(merged.messages[2].id, newUser.id)
        XCTAssertFalse(merged.messages.contains { $0.id == priorPartial.id })
        XCTAssertEqual(merged.parameters["temperature"], "0.8")
        XCTAssertEqual(merged.status, .processing)
        XCTAssertTrue(merged.needsResponse)
    }
}
