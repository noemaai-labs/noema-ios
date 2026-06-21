import Combine
import Foundation
import XCTest
@testable import Noema

final class ToolCallStreamingTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let trackedKeys = [
        "pythonEnabled",
        "pythonArmed",
        "webSearchEnabled",
        "webSearchArmed",
        "offGrid",
        "currentModelSupportsFunctionCalling",
        "currentModelFormat",
        "currentModelIsRemote",
        "selectedDatasetID",
        "indexingDatasetIDPersisted"
    ]
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        savedDefaults = trackedKeys.reduce(into: [:]) { result, key in
            result[key] = defaults.object(forKey: key)
        }
        defaults.set(true, forKey: "pythonEnabled")
        defaults.set(true, forKey: "pythonArmed")
        defaults.set(true, forKey: "webSearchEnabled")
        defaults.set(true, forKey: "webSearchArmed")
        defaults.set(false, forKey: "offGrid")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
        defaults.set(ModelFormat.gguf.rawValue, forKey: "currentModelFormat")
        defaults.set(false, forKey: "currentModelIsRemote")
        defaults.set("", forKey: "selectedDatasetID")
        defaults.set("", forKey: "indexingDatasetIDPersisted")
    }

    override func tearDown() {
        for key in trackedKeys {
            if let value = savedDefaults[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedDefaults.removeAll()
        super.tearDown()
    }

    @MainActor
    func testResolvedVisiblePostToolFinalTextPreservesExistingVisibleTextAfterToolTurn() {
        let vm = makeChatVM(userText: "Who is the president of Romania")
        let completedWebCall = ChatVM.Msg.ToolCall(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: ["query": AnyCodable("Who is the president of Romania as of March 2026")],
            phase: .completed,
            result: "[]"
        )
        let streamedVisibleText = "<think>First thought</think>\(noemaToolAnchorToken)<think>Second thought</think>\nFinal answer"
        vm.streamMsgs[1].toolCalls = [completedWebCall]
        vm.streamMsgs[1].text = streamedVisibleText

        let resolved = vm.resolvedVisiblePostToolFinalText(
            existingVisibleText: vm.streamMsgs[1].text,
            fallbackText: "replacement text that should not win",
            toolCalls: vm.streamMsgs[1].toolCalls
        )

        vm.streamMsgs[1].text = resolved
        vm.streamMsgs[1].postToolWaiting = false

        XCTAssertEqual(vm.streamMsgs[1].text, streamedVisibleText)
        XCTAssertTrue(vm.streamMsgs[1].text.contains("<think>Second thought</think>"))
        XCTAssertTrue(vm.streamMsgs[1].text.contains("Final answer"))
    }

    @MainActor
    func testResolvedVisiblePostToolFinalTextFallsBackWhenVisibleTextIsEmpty() {
        let vm = makeChatVM(userText: "Who is the president of Romania")
        let completedWebCall = ChatVM.Msg.ToolCall(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: ["query": AnyCodable("Who is the president of Romania as of March 2026")],
            phase: .completed,
            result: "[]"
        )
        let finalizedText = "<think>First thought</think>\(noemaToolAnchorToken)<think>Second thought</think>\nFinal answer"
        vm.streamMsgs[1].toolCalls = [completedWebCall]
        vm.streamMsgs[1].text = ""

        let resolved = vm.resolvedVisiblePostToolFinalText(
            existingVisibleText: vm.streamMsgs[1].text,
            fallbackText: finalizedText,
            toolCalls: vm.streamMsgs[1].toolCalls
        )

        XCTAssertEqual(resolved, finalizedText)
        XCTAssertTrue(resolved.contains("<think>Second thought</think>"))
        XCTAssertTrue(resolved.contains("Final answer"))
    }

    @MainActor
    func testPartialPythonToolTokenCreatesRequestingCardWithoutExecution() async throws {
        let vm = makeChatVM(userText: "Calculate 2 + 2")

        let handled = await interceptToolCallIfPresent(
            #"TOOL_CALL: {"tool":"noema.python.execute","tool_call_id":"py-1","args":{},"request_status":"requesting"}"#,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNil(handled)
        let call = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)
        XCTAssertEqual(call.toolName, "noema.python.execute")
        XCTAssertEqual(call.phase, .requesting)
        XCTAssertEqual(call.externalToolCallID, "py-1")
        XCTAssertTrue(call.requestParams.isEmpty)
        XCTAssertNil(call.result)
        XCTAssertNil(call.error)
    }

    @MainActor
    func testReadyPythonToolTokenUpgradesSameCardAndExecutes() async throws {
        let vm = makeChatVM(userText: "Calculate 2 + 2")

        _ = await interceptToolCallIfPresent(
            #"TOOL_CALL: {"tool":"noema.python.execute","tool_call_id":"py-1","args":{},"request_status":"requesting"}"#,
            messageIndex: 1,
            chatVM: vm
        )
        let pendingCall = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)

        let handled = await interceptToolCallIfPresent(
            #"TOOL_CALL: {"tool":"noema.python.execute","tool_call_id":"py-1","args":{"code":"print(2 + 2)"},"request_status":"ready"}"#,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNotNil(handled)
        let completedCall = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)
        XCTAssertEqual(completedCall.id, pendingCall.id)
        XCTAssertEqual(completedCall.externalToolCallID, "py-1")
        XCTAssertEqual(completedCall.phase, .completed)
        XCTAssertEqual(completedCall.requestParams["code"]?.value as? String, "print(2 + 2)")
        XCTAssertNotNil(completedCall.result)
        XCTAssertNil(completedCall.error)
    }

    @MainActor
    func testStreamedPythonToolCallPreservesRepeatedDigitsInArguments() async throws {
        let vm = makeChatVM(userText: "Calculate 11 squared")
        var merger = StreamChunkMerger(mode: .delta)
        var buffer = ""

        merger.append(#"<tool_call>{"name":"noema.python.execute","arguments":{"code":"print("#, to: &buffer)
        merger.append("1", to: &buffer)
        merger.append("1", to: &buffer)
        merger.append(#" * 11)"}}</tool_call>"#, to: &buffer)

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm
        )

        let call = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)
        XCTAssertNotNil(result?.token)
        XCTAssertEqual(call.toolName, "noema.python.execute")
        XCTAssertEqual(call.phase, .completed)
        XCTAssertEqual(call.requestParams["code"]?.value as? String, "print(11 * 11)")
        XCTAssertEqual(call.result?.trimmingCharacters(in: .whitespacesAndNewlines), "121")
    }

    @MainActor
    func testReadyPythonToolTokenPreservesRepeatedDigitsInCode() async throws {
        let vm = makeChatVM(userText: "Calculate 11 squared")

        let handled = await interceptToolCallIfPresent(
            #"TOOL_CALL: {"tool":"noema.python.execute","tool_call_id":"py-11","args":{"code":"print(11 * 11)"},"request_status":"ready"}"#,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNotNil(handled)
        let completedCall = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)
        XCTAssertEqual(completedCall.externalToolCallID, "py-11")
        XCTAssertEqual(completedCall.requestParams["code"]?.value as? String, "print(11 * 11)")
        XCTAssertEqual(completedCall.result?.trimmingCharacters(in: .whitespacesAndNewlines), "121")
    }

    @MainActor
    func testToolCallSimulatorMatrixExecutesSupportedPythonPayloadShapes() async throws {
        enum Scanner {
            case prefixed
            case embedded
        }

        struct Scenario {
            let name: String
            let payload: String
            let scanner: Scanner
            let expectedCode: String
            let expectedOutput: String
        }

        let scenarios = [
            Scenario(
                name: "openai-ready",
                payload: #"TOOL_CALL: {"tool":"noema.python.execute","tool_call_id":"sim-openai","args":{"code":"print(6 * 7)"},"request_status":"ready"}"#,
                scanner: .prefixed,
                expectedCode: "print(6 * 7)",
                expectedOutput: "42"
            ),
            Scenario(
                name: "xml-mlx",
                payload: #"<tool_call>{"name":"noema.python.execute","arguments":{"code":"print(7 * 7)"}}</tool_call>"#,
                scanner: .embedded,
                expectedCode: "print(7 * 7)",
                expectedOutput: "49"
            ),
            Scenario(
                name: "arguments-json-string",
                payload: #"TOOL_CALL: {"tool":"noema.python.execute","tool_call_id":"sim-string-args","args":"{\"code\":\"print(9 * 9)\"}","request_status":"ready"}"#,
                scanner: .prefixed,
                expectedCode: "print(9 * 9)",
                expectedOutput: "81"
            )
        ]

        for scenario in scenarios {
            let vm = makeChatVM(userText: "Run \(scenario.name)")
            let didHandle: Bool
            switch scenario.scanner {
            case .prefixed:
                didHandle = await interceptToolCallIfPresent(
                    scenario.payload,
                    messageIndex: 1,
                    chatVM: vm
                ) != nil
            case .embedded:
                didHandle = await interceptEmbeddedToolCallIfPresent(
                    in: scenario.payload,
                    messageIndex: 1,
                    chatVM: vm
                ) != nil
            }

            XCTAssertTrue(didHandle, scenario.name)
            let completedCall = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement, scenario.name)
            XCTAssertEqual(completedCall.toolName, "noema.python.execute", scenario.name)
            XCTAssertEqual(completedCall.phase, .completed, scenario.name)
            XCTAssertEqual(completedCall.requestParams["code"]?.value as? String, scenario.expectedCode, scenario.name)
            XCTAssertEqual(
                ToolCallViewSupport.parsePythonResult(from: completedCall.result ?? "")?.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                scenario.expectedOutput,
                scenario.name
            )
        }
    }

    @MainActor
    func testRequestingWebToolTokenCreatesImmediatePendingCard() async throws {
        let vm = makeChatVM(userText: "Latest AI news")

        let handled = await interceptToolCallIfPresent(
            #"TOOL_CALL: {"tool":"noema.web.retrieve","tool_call_id":"web-1","args":{},"request_status":"requesting"}"#,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNil(handled)
        let call = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)
        XCTAssertEqual(call.toolName, "noema.web.retrieve")
        XCTAssertEqual(call.phase, .requesting)
        XCTAssertEqual(call.externalToolCallID, "web-1")
    }

    @MainActor
    func testFailedToolTokenResolvesPendingCardWithoutExecution() async throws {
        let vm = makeChatVM(userText: "Latest AI news")

        _ = await interceptToolCallIfPresent(
            #"TOOL_CALL: {"tool":"noema.web.retrieve","tool_call_id":"web-2","args":{},"request_status":"requesting"}"#,
            messageIndex: 1,
            chatVM: vm
        )
        let pendingCall = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)

        let handled = await interceptToolCallIfPresent(
            #"TOOL_CALL: {"tool":"noema.web.retrieve","tool_call_id":"web-2","args":{},"request_status":"failed","error":"Timed out"}"#,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNil(handled)
        let failedCall = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)
        XCTAssertEqual(failedCall.id, pendingCall.id)
        XCTAssertEqual(failedCall.phase, .failed)
        XCTAssertEqual(failedCall.error, "Timed out")
        XCTAssertNil(failedCall.result)
    }

    @MainActor
    func testPartialEmbeddedToolCallCreatesSinglePlaceholderCard() async throws {
        let vm = makeChatVM(userText: "Latest AI news")
        let partial = #"<tool_call>{"name":"noema.web.retrieve","arguments":{"query":"latest ai news""#

        let first = await interceptEmbeddedToolCallIfPresent(
            in: partial,
            messageIndex: 1,
            chatVM: vm
        )
        let second = await interceptEmbeddedToolCallIfPresent(
            in: partial + #","count":5"#,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.count, 1)
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.first?.phase, .requesting)
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.first?.toolName, "noema.web.retrieve")
    }

    @MainActor
    func testScrubOnlyEmbeddedToolCallRemovesVisibleXMLWithoutDispatch() async throws {
        let vm = makeChatVM(userText: "Latest AI news")
        let buffer = #"Before answer <tool_call>{"name":"noema.web.retrieve","arguments":{"query":"latest ai news","count":3}}</tool_call>"#

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm,
            handlingMode: .scrubOnly
        )

        XCTAssertNotNil(result)
        XCTAssertNil(result?.token)
        XCTAssertEqual(result?.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines), "Before answer")
        XCTAssertTrue(vm.streamMsgs[1].toolCalls?.isEmpty ?? true)
    }

    @MainActor
    func testScrubOnlyBareJSONToolCallRemovesVisibleArtifactWithoutDispatch() async throws {
        let vm = makeChatVM(userText: "Latest AI news")
        let buffer = #"Answer draft {"name":"noema.web.retrieve","arguments":{"query":"latest ai news","count":3}}"#

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm,
            handlingMode: .scrubOnly
        )

        XCTAssertNotNil(result)
        XCTAssertNil(result?.token)
        XCTAssertEqual(result?.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines), "Answer draft")
        XCTAssertTrue(vm.streamMsgs[1].toolCalls?.isEmpty ?? true)
    }

    @MainActor
    func testEmbeddedXMLToolCallPreservesAnchorBetweenThoughtBlocks() async throws {
        let vm = makeChatVM(userText: "Calculate 2 + 2")
        let buffer = #"<think>First thought</think><tool_call>{"name":"noema.python.execute","arguments":{"code":"print(2 + 2)"}}</tool_call><think>Second thought</think>"#

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNotNil(result?.token)
        XCTAssertEqual(
            result?.cleanedText,
            "<think>First thought</think>\(noemaToolAnchorToken)<think>Second thought</think>"
        )
    }

    @MainActor
    func testEmbeddedBareJSONToolCallPreservesAnchorBetweenThoughtBlocks() async throws {
        let vm = makeChatVM(userText: "Calculate 2 + 2")
        let buffer = #"<think>First thought</think>{"name":"noema.python.execute","arguments":{"code":"print(2 + 2)"}}<think>Second thought</think>"#

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNotNil(result?.token)
        XCTAssertEqual(
            result?.cleanedText,
            "<think>First thought</think>\(noemaToolAnchorToken)<think>Second thought</think>"
        )
    }

    @MainActor
    func testScrubOnlyEmbeddedToolCallBetweenThoughtBlocksDoesNotInsertAnchor() async throws {
        let vm = makeChatVM(userText: "Calculate 2 + 2")
        let buffer = #"<think>First thought</think><tool_call>{"name":"noema.python.execute","arguments":{"code":"print(2 + 2)"}}</tool_call><think>Second thought</think>"#

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm,
            handlingMode: .scrubOnly
        )

        XCTAssertNotNil(result)
        XCTAssertNil(result?.token)
        XCTAssertEqual(
            result?.cleanedText,
            "<think>First thought</think><think>Second thought</think>"
        )
        XCTAssertFalse(result?.cleanedText.contains(noemaToolAnchorToken) ?? true)
    }

    func testLegacyMissingToolFallbackPlacesToolBeforeSecondThought() {
        var kinds: [MessageView.MissingToolFallbackKind] = [.think, .think]
        let insertIndex = MessageView.insertIndexForMissingToolEntries(in: kinds)
        kinds.insert(.tool, at: insertIndex)

        XCTAssertEqual(kinds, [.think, .tool, .think])
    }

    @MainActor
    func testPostToolContinuationNudgePrefersAnsweringFromPythonResult() {
        let vm = ChatVM()

        let nudge = vm.postToolContinuationNudge(
            toolName: "noema.python.execute",
            originalQuestion: "Do 2+2 with the python tool"
        )

        XCTAssertTrue(nudge.contains("Use the latest tool result to answer the user's original question directly."))
        XCTAssertTrue(nudge.contains("The Python result is authoritative for the computation that was run."))
        XCTAssertTrue(nudge.contains("Only call another tool if the current result is empty, malformed, or clearly insufficient."))
        XCTAssertTrue(nudge.contains("Original question: Do 2+2 with the python tool"))
    }

    @MainActor
    func testAssistantLoadingStateUsesPromptProcessingEvenWhenOnlyToolAnchorAndToolCardArePresent() {
        let toolCall = ChatVM.Msg.ToolCall(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: ["query": AnyCodable("latest ai news")],
            phase: .completed,
            result: "[]"
        )
        var msg = ChatVM.Msg(
            role: "🤖",
            text: noemaToolAnchorToken,
            timestamp: Date(),
            streaming: true,
            promptProcessing: .init(progress: 0.66)
        )
        msg.toolCalls = [toolCall]
        msg.usedWebSearch = true

        XCTAssertEqual(msg.trimmedVisibleAssistantText, "")
        XCTAssertFalse(msg.hasVisibleAssistantText)
        XCTAssertTrue(msg.shouldShowPromptProcessingCard)
        XCTAssertFalse(msg.shouldShowGenericLoadingIndicator)
    }

    @MainActor
    func testPromptProcessingProgressAdvancesWhileCompletedToolMetadataExists() {
        let vm = makeChatVM(userText: "Latest AI news")
        let toolCall = ChatVM.Msg.ToolCall(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: ["query": AnyCodable("latest ai news")],
            phase: .completed,
            result: "[]"
        )
        vm.streamMsgs[1].text = noemaToolAnchorToken
        vm.streamMsgs[1].toolCalls = [toolCall]
        vm.streamMsgs[1].usedWebSearch = true
        vm.streamMsgs[1].promptProcessing = .init(progress: 0)

        vm.updatePromptProcessingProgress(0.66, messageIndex: 1)

        XCTAssertNotNil(vm.streamMsgs[1].promptProcessing)
        XCTAssertEqual(vm.streamMsgs[1].promptProcessing?.progress ?? -1, 0.66, accuracy: 0.0001)
    }

    @MainActor
    func testPromptProcessingProgressPublishesMessageUpdate() {
        let vm = makeChatVM(userText: "Latest AI news")
        vm.streamMsgs[1].streaming = true
        vm.streamMsgs[1].promptProcessing = .init(progress: 0)

        let expectation = expectation(description: "prompt progress publishes")
        var cancellable: AnyCancellable?
        cancellable = vm.objectWillChange.sink {
            expectation.fulfill()
        }

        vm.updatePromptProcessingProgress(0.66, messageIndex: 1)

        wait(for: [expectation], timeout: 0.2)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(vm.streamMsgs[1].promptProcessing?.progress ?? -1, 0.66, accuracy: 0.0001)
    }

    @MainActor
    func testStartPromptProcessingResetsProgressToZeroForFollowupGGUFTurn() {
        let vm = makeChatVM(userText: "Latest AI news")
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/qwen.gguf"),
            loadedFormat: .gguf
        )
        vm.streamMsgs[1].promptProcessing = .init(progress: 0.99)

        vm.startPromptProcessing(for: 1)

        XCTAssertEqual(vm.streamMsgs[1].promptProcessing?.progress, 0)
    }

    @MainActor
    func testClearPromptProcessingRemovesProgressOnFirstFollowupToken() {
        let vm = makeChatVM(userText: "Latest AI news")
        vm.streamMsgs[1].promptProcessing = .init(progress: 0.99)

        vm.clearPromptProcessing(for: 1)

        XCTAssertNil(vm.streamMsgs[1].promptProcessing)
    }

    func testPromptProcessingInsertionIndexPlacesCardAfterLastTool() {
        let kinds: [MessageView.MissingToolFallbackKind] = [.think, .tool, .text]

        let index = MessageView.insertIndexForPromptProcessingEntry(in: kinds)

        XCTAssertEqual(index, 2)
    }

    func testDanglingPlaceholderToolCallDetectionMatchesEmptyRequestingCardOnly() {
        let placeholder = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: [:],
            phase: .requesting
        )
        let realInFlight = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: [:],
            phase: .requesting,
            externalToolCallID: "py-2"
        )
        let completed = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: ["code": AnyCodable("print(2 + 2)")],
            phase: .completed,
            result: #"{"stdout":"4"}"#
        )

        XCTAssertTrue(isDanglingPlaceholderToolCall(placeholder))
        XCTAssertFalse(isDanglingPlaceholderToolCall(realInFlight))
        XCTAssertFalse(isDanglingPlaceholderToolCall(completed))
    }

    @MainActor
    func testScrubOnlyToolOnlyXMLCompletionStaysEmptyWithoutFallbackText() async throws {
        let vm = makeChatVM(userText: "Latest AI news")
        let buffer = #"<tool_call>{"name":"noema.web.retrieve","arguments":{"query":"latest ai news","count":3}}</tool_call>"#

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm,
            handlingMode: .scrubOnly
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cleanedText, "")
        XCTAssertFalse(result?.cleanedText.contains("interrupted before completion") ?? true)
    }

    @MainActor
    func testScrubOnlyToolOnlyJSONCompletionStaysEmptyWithoutFallbackText() async throws {
        let vm = makeChatVM(userText: "Do 2+2 with the python tool")
        let buffer = #"{"name":"noema.python.execute","arguments":{"code":"print(2 + 2)"}}"#

        let result = await interceptEmbeddedToolCallIfPresent(
            in: buffer,
            messageIndex: 1,
            chatVM: vm,
            handlingMode: .scrubOnly
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cleanedText, "")
        XCTAssertFalse(result?.cleanedText.contains("interrupted before completion") ?? true)
    }

    @MainActor
    func testPruneDanglingPlaceholderRemovesEmptySecondPythonCard() async throws {
        let vm = makeChatVM(userText: "Do 2+2 with the python tool")
        let completed = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: ["code": AnyCodable("print(2 + 2)")],
            phase: .completed,
            result: #"{"stdout":"4"}"#
        )
        let placeholder = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: [:],
            phase: .requesting
        )
        vm.streamMsgs[1].text = "<think>First</think>\(noemaToolAnchorToken)<think>Second</think>\(noemaToolAnchorToken)"
        vm.streamMsgs[1].toolCalls = [completed, placeholder]

        let cleaned = await pruneDanglingPlaceholderToolCalls(messageIndex: 1, chatVM: vm)

        XCTAssertEqual(cleaned, "<think>First</think>\(noemaToolAnchorToken)<think>Second</think>")
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.count, 1)
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.first?.phase, .completed)
        XCTAssertEqual(vm.streamMsgs[1].text, "<think>First</think>\(noemaToolAnchorToken)<think>Second</think>")
    }

    @MainActor
    func testPruneDanglingPlaceholderDoesNotRemoveTrackedInFlightToolCall() async throws {
        let vm = makeChatVM(userText: "Do 2+2 with the python tool")
        let inFlight = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: [:],
            phase: .requesting,
            externalToolCallID: "py-2"
        )
        vm.streamMsgs[1].text = "Answer\(noemaToolAnchorToken)"
        vm.streamMsgs[1].toolCalls = [inFlight]

        let cleaned = await pruneDanglingPlaceholderToolCalls(messageIndex: 1, chatVM: vm)

        XCTAssertEqual(cleaned, "Answer\(noemaToolAnchorToken)")
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.count, 1)
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.first?.externalToolCallID, "py-2")
    }

    @MainActor
    func testPruneDanglingPlaceholderDoesNotRemoveCompletedOrFailedToolCards() async throws {
        let vm = makeChatVM(userText: "Use tools")
        let completed = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: ["code": AnyCodable("print(2 + 2)")],
            phase: .completed,
            result: #"{"stdout":"4"}"#
        )
        let failed = ChatVM.Msg.ToolCall(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: ["query": AnyCodable("latest ai news")],
            phase: .failed,
            error: "Timed out"
        )
        vm.streamMsgs[1].text = "Answer\(noemaToolAnchorToken)\(noemaToolAnchorToken)"
        vm.streamMsgs[1].toolCalls = [completed, failed]

        let cleaned = await pruneDanglingPlaceholderToolCalls(messageIndex: 1, chatVM: vm)

        XCTAssertEqual(cleaned, "Answer\(noemaToolAnchorToken)\(noemaToolAnchorToken)")
        XCTAssertEqual(vm.streamMsgs[1].toolCalls?.map(\.phase), [.completed, .failed])
    }

    func testToolCallBackwardCompatibilityInfersPhase() throws {
        struct LegacyToolCall: Codable {
            let id: UUID
            let toolName: String
            let displayName: String
            let iconName: String
            let requestParams: [String: AnyCodable]
            let result: String?
            let error: String?
            let timestamp: Date
        }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let timestamp = Date()

        let completedData = try encoder.encode(
            LegacyToolCall(
                id: UUID(),
                toolName: "noema.python.execute",
                displayName: "Python",
                iconName: "chevron.left.forwardslash.chevron.right",
                requestParams: [:],
                result: "{\"stdout\":\"4\"}",
                error: nil,
                timestamp: timestamp
            )
        )
        let failedData = try encoder.encode(
            LegacyToolCall(
                id: UUID(),
                toolName: "noema.web.retrieve",
                displayName: "Web Search",
                iconName: "globe",
                requestParams: [:],
                result: nil,
                error: "Timed out",
                timestamp: timestamp
            )
        )
        let executingData = try encoder.encode(
            LegacyToolCall(
                id: UUID(),
                toolName: "noema.python.execute",
                displayName: "Python",
                iconName: "chevron.left.forwardslash.chevron.right",
                requestParams: [:],
                result: nil,
                error: nil,
                timestamp: timestamp
            )
        )

        XCTAssertEqual(try decoder.decode(ChatVM.Msg.ToolCall.self, from: completedData).phase, .completed)
        XCTAssertEqual(try decoder.decode(ChatVM.Msg.ToolCall.self, from: failedData).phase, .failed)
        XCTAssertEqual(try decoder.decode(ChatVM.Msg.ToolCall.self, from: executingData).phase, .executing)
    }

    func testToolCallViewSupportDefaultResultDisplayModeUsesFormattedOnlyForParseablePythonAndWebResults() {
        let pythonResult = #"{"stdout":"4\n","stderr":"","exitCode":0,"executionTimeMs":12,"error":null,"timedOut":false}"#
        let webResult = #"[{"title":"Example","url":"https://example.com","snippet":"Summary"}]"#

        XCTAssertEqual(
            ToolCallViewSupport.defaultResultDisplayMode(
                toolName: "noema.python.execute",
                result: pythonResult
            ),
            .formatted
        )
        XCTAssertEqual(
            ToolCallViewSupport.defaultResultDisplayMode(
                toolName: "noema.web.retrieve",
                result: webResult
            ),
            .formatted
        )
        XCTAssertEqual(
            ToolCallViewSupport.defaultResultDisplayMode(
                toolName: "noema.python.execute",
                result: "not json"
            ),
            .raw
        )
        XCTAssertEqual(
            ToolCallViewSupport.defaultResultDisplayMode(
                toolName: "noema.code.analyze",
                result: webResult
            ),
            .raw
        )
        XCTAssertEqual(
            ToolCallViewSupport.defaultResultDisplayMode(
                toolName: "noema.web.retrieve",
                result: nil
            ),
            .raw
        )
    }

    func testToolCallViewSupportCompletionSweepStaysDisabledForCompletedWebAndPythonCalls() {
        XCTAssertFalse(
            ToolCallViewSupport.shouldAnimateCompletionSweep(
                toolName: "noema.web.retrieve",
                phase: .completed
            )
        )
        XCTAssertFalse(
            ToolCallViewSupport.shouldAnimateCompletionSweep(
                toolName: "noema.python.execute",
                phase: .completed
            )
        )
        XCTAssertTrue(
            ToolCallViewSupport.shouldAnimateCompletionSweep(
                toolName: "noema.code.analyze",
                phase: .completed
            )
        )
        XCTAssertFalse(
            ToolCallViewSupport.shouldAnimateCompletionSweep(
                toolName: "noema.code.analyze",
                phase: .requesting
            )
        )
    }

    func testToolCallViewSupportParameterSummaryTruncationIsDeterministic() {
        let params: [String: AnyCodable] = [
            "alpha": AnyCodable(String(repeating: "a", count: 80)),
            "beta": AnyCodable("short"),
            "gamma": AnyCodable("ignored")
        ]

        let entries = ToolCallViewSupport.parameterSummaryEntries(from: params)

        XCTAssertEqual(
            entries,
            [
                .init(key: "alpha", value: String(repeating: "a", count: 50)),
                .init(key: "beta", value: "short")
            ]
        )
        XCTAssertEqual(ToolCallViewSupport.remainingParameterCount(from: params), 1)
    }

    @MainActor
    private func makeChatVM(userText: String) -> ChatVM {
        let vm = ChatVM()
        vm.streamMsgs = [
            ChatVM.Msg(role: "🧑‍💻", text: userText, timestamp: Date()),
            ChatVM.Msg(role: "🤖", text: "", timestamp: Date(), streaming: true)
        ]
        return vm
    }
}

private extension Array {
    var onlyElement: Element? {
        count == 1 ? first : nil
    }
}
