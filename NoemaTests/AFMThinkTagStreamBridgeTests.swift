import XCTest
@testable import Noema

final class AFMThinkTagStreamBridgeTests: XCTestCase {
    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        var value: String {
            get { lock.lock(); defer { lock.unlock() }; return text }
            set { lock.lock(); defer { lock.unlock() }; text = newValue }
        }

        func append(_ delta: String) {
            lock.lock()
            defer { lock.unlock() }
            text += delta
        }
    }

    private func makeBridge(reasoning: TextBox, output: TextBox) -> AFMThinkTagStreamBridge {
        AFMThinkTagStreamBridge(
            readLatestReasoning: {
                let text = reasoning.value
                return AFMReasoningTranscriptSnapshot(
                    text: text,
                    entryCount: text.isEmpty ? 0 : 1,
                    segmentCount: text.isEmpty ? 0 : 1,
                    signedEntryCount: 0
                )
            },
            reasoningStatusText: "PCC reasoning enabled.",
            emit: { output.append($0) }
        )
    }

    func testBeginReasoningPublishesLiveStatusBeforeContent() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.beginReasoning()

        XCTAssertEqual(output.value, "<think>PCC reasoning enabled.")

        bridge.emitContent("The answer")
        XCTAssertEqual(output.value, "<think>PCC reasoning enabled.")

        bridge.emitContent(" is 42.")
        XCTAssertEqual(
            output.value,
            "<think>PCC reasoning enabled.</think>\n\nThe answer is 42."
        )
    }

    func testReadableReasoningCanAppendToAlreadyVisibleStatusRow() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.beginReasoning()
        bridge.emitContent("Answer.")
        reasoning.value = "Readable transcript reasoning."
        bridge.syncReasoning()

        XCTAssertEqual(
            output.value,
            "<think>PCC reasoning enabled.\n\nReadable transcript reasoning.</think>\n\nAnswer."
        )
    }

    func testReasoningStreamsBeforeContentInsideThinkTags() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        reasoning.value = "Step 1."
        bridge.syncReasoning()
        reasoning.value = "Step 1. Step 2."
        bridge.syncReasoning()
        bridge.emitContent("The answer")
        bridge.emitContent(" is 42.")
        bridge.finish()

        XCTAssertEqual(output.value, "<think>Step 1. Step 2.</think>\n\nThe answer is 42.")
    }

    func testNoReasoningEmitsPlainContentWithoutTags() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.syncReasoning()
        bridge.emitContent("Plain answer.")
        XCTAssertEqual(output.value, "")
        bridge.finish()

        XCTAssertEqual(output.value, "Plain answer.")
    }

    func testSecondReasoningFreeContentChunkReleasesBufferedFirstChunk() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.emitContent("Plain ")
        XCTAssertEqual(output.value, "")

        bridge.emitContent("answer.")

        XCTAssertEqual(output.value, "Plain answer.")
    }

    func testReasoningThatAppearsAfterFirstContentStillPrecedesAnswer() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.emitContent("Answer.")
        XCTAssertEqual(output.value, "")

        reasoning.value = "Delayed transcript reasoning."
        bridge.syncReasoning()

        XCTAssertEqual(
            output.value,
            "<think>Delayed transcript reasoning.</think>\n\nAnswer."
        )
    }

    func testReportedReasoningTokensKeepMultipleContentChunksBuffered() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.noteReasoningTokens(12)
        XCTAssertEqual(output.value, "<think>PCC reasoning enabled.")
        bridge.emitContent("The answer")
        bridge.emitContent(" is 42.")
        XCTAssertEqual(
            output.value,
            "<think>PCC reasoning enabled.</think>\n\nThe answer is 42."
        )
        XCTAssertEqual(bridge.reportedReasoningTokens, 12)

        reasoning.value = "Compute carefully."
        bridge.syncReasoning()

        XCTAssertEqual(
            output.value,
            "<think>PCC reasoning enabled.</think>\n\nThe answer is 42."
        )
    }

    func testMissingReasoningTextDoesNotLoseBufferedAnswerAtFinish() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.noteReasoningTokens(8)
        XCTAssertEqual(output.value, "<think>PCC reasoning enabled.")
        bridge.emitContent("Fallback answer.")
        bridge.finish()

        XCTAssertEqual(
            output.value,
            "<think>PCC reasoning enabled.</think>\n\nFallback answer."
        )
    }

    func testSignedReasoningEntryWithoutReadableSegmentsShowsTruthfulReasoningRow() {
        let output = TextBox()
        let bridge = AFMThinkTagStreamBridge(
            readLatestReasoning: {
                AFMReasoningTranscriptSnapshot(
                    text: "",
                    entryCount: 1,
                    segmentCount: 0,
                    signedEntryCount: 1
                )
            },
            reasoningStatusText: "PCC reasoning enabled.",
            emit: { output.append($0) }
        )

        bridge.emitContent("Answer.")
        XCTAssertEqual(output.value, "<think>PCC reasoning enabled.")
        bridge.finish()

        XCTAssertEqual(
            output.value,
            "<think>PCC reasoning enabled.</think>\n\nAnswer."
        )
        XCTAssertEqual(bridge.observedReasoningEntries, 1)
        XCTAssertEqual(bridge.observedReasoningSegments, 0)
        XCTAssertEqual(bridge.observedSignedReasoningEntries, 1)
    }

    func testReasoningOnlyStreamClosesThinkBlockOnFinish() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        reasoning.value = "Thinking hard."
        bridge.syncReasoning()
        bridge.finish()
        bridge.finish()

        XCTAssertEqual(output.value, "<think>Thinking hard.</think>")
    }

    func testFirstContentDrainsUnpolledReasoning() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        // Reasoning finished between two polls; content arrives before the
        // poller ever saw it.
        reasoning.value = "Missed by the poller."
        bridge.emitContent("Answer.")
        bridge.finish()

        XCTAssertEqual(output.value, "<think>Missed by the poller.</think>\n\nAnswer.")
    }

    func testLateReasoningIsIgnoredOnceContentStarted() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        reasoning.value = "Before."
        bridge.syncReasoning()
        bridge.emitContent("Answer.")
        reasoning.value = "Before. After — must not reopen."
        bridge.syncReasoning()
        bridge.finish()

        XCTAssertEqual(output.value, "<think>Before.</think>\n\nAnswer.")
    }

    func testEmptyStreamEmitsNothing() {
        let reasoning = TextBox()
        let output = TextBox()
        let bridge = makeBridge(reasoning: reasoning, output: output)

        bridge.syncReasoning()
        bridge.finish()

        XCTAssertEqual(output.value, "")
    }
}
