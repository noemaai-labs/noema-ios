import Foundation
import XCTest
import NoemaPackages
@testable import Noema
#if canImport(UIKit)
import UIKit
#endif

final class Qwen35LoopbackTests: XCTestCase {
    @MainActor
    func testSanitizedHistoryRemovesTrailingStreamingEmptyAssistantPlaceholder() {
        let vm = ChatVM()
        let history: [ChatVM.Msg] = [
            .init(role: "system", text: "sys", timestamp: Date()),
            .init(role: "🧑‍💻", text: "hello", timestamp: Date()),
            .init(role: "🤖", text: "   ", timestamp: Date(), streaming: true),
        ]

        let sanitized = vm.sanitizedHistoryForTemplateDrivenLoopback(history)

        XCTAssertEqual(sanitized.count, 2)
        XCTAssertEqual(sanitized.last?.role, "🧑‍💻")
    }

    @MainActor
    func testSanitizedHistoryPreservesNonEmptyAssistantMessage() {
        let vm = ChatVM()
        let history: [ChatVM.Msg] = [
            .init(role: "system", text: "sys", timestamp: Date()),
            .init(role: "🧑‍💻", text: "hello", timestamp: Date()),
            .init(role: "🤖", text: "answer", timestamp: Date(), streaming: true),
        ]

        let sanitized = vm.sanitizedHistoryForTemplateDrivenLoopback(history)

        XCTAssertEqual(sanitized, history)
    }

    @MainActor
    func testSanitizedHistoryPreservesNonStreamingEmptyAssistantMessage() {
        let vm = ChatVM()
        let history: [ChatVM.Msg] = [
            .init(role: "system", text: "sys", timestamp: Date()),
            .init(role: "🧑‍💻", text: "hello", timestamp: Date()),
            .init(role: "assistant", text: "", timestamp: Date(), streaming: false),
        ]

        let sanitized = vm.sanitizedHistoryForTemplateDrivenLoopback(history)

        XCTAssertEqual(sanitized, history)
    }

    @MainActor
    func testSanitizedHistoryLeavesUserTerminatedHistoryUnchanged() {
        let vm = ChatVM()
        let history: [ChatVM.Msg] = [
            .init(role: "system", text: "sys", timestamp: Date()),
            .init(role: "🧑‍💻", text: "hello", timestamp: Date()),
        ]

        let sanitized = vm.sanitizedHistoryForTemplateDrivenLoopback(history)

        XCTAssertEqual(sanitized, history)
    }

    @MainActor
    func testStructuredLoopbackInputDropsLiveAssistantPlaceholder() {
        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"),
            loadedFormat: .gguf
        )

        let history: [ChatVM.Msg] = [
            .init(role: "system", text: "sys", timestamp: Date()),
            .init(role: "🧑‍💻", text: "hello", timestamp: Date()),
            .init(role: "🤖", text: "", timestamp: Date(), streaming: true),
        ]

        guard let input = vm.structuredLoopbackInput(for: history),
              case .messages(let messages) = input.content else {
            return XCTFail("Expected structured loopback messages")
        }

        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertEqual(messages.last?.content, "hello")
    }

    @MainActor
    func testStructuredLoopbackInputKeepsFrozenFullDocumentSystemPrefix() throws {
        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"),
            loadedFormat: .gguf
        )
        let history: [ChatVM.Msg] = [
            .init(role: "user", text: "What does this method do?", timestamp: Date())
        ]

        let input = try XCTUnwrap(vm.structuredLoopbackInput(
            for: history,
            retrievedContext: "FULL DOCUMENT SENTINEL",
            fullDocumentPlacement: true,
            systemPromptOverride: "FROZEN SYSTEM SENTINEL"
        ))
        guard case .messages(let messages) = input.content else {
            return XCTFail("Expected structured loopback messages")
        }
        let system = try XCTUnwrap(messages.first(where: { $0.role == "system" }))

        XCTAssertTrue(system.content.contains("FULL DOCUMENT SENTINEL"))
        XCTAssertTrue(system.content.contains("FROZEN SYSTEM SENTINEL"))
        let documentIndex = try XCTUnwrap(system.content.range(of: "FULL DOCUMENT SENTINEL")?.lowerBound)
        let systemIndex = try XCTUnwrap(system.content.range(of: "FROZEN SYSTEM SENTINEL")?.lowerBound)
        XCTAssertLessThan(documentIndex, systemIndex)
    }

    @MainActor
    func testPlainToolContinuationPromptRetainsFullDocumentAndFrozenSystemPrompt() {
        let vm = ChatVM()
        let history: [ChatVM.Msg] = [
            .init(role: "user", text: "Question", timestamp: Date()),
            .init(role: "assistant", text: "", timestamp: Date()),
            .init(role: "tool", text: #"{"result":"value"}"#, timestamp: Date())
        ]

        let prompt = vm.plainToolContinuationPrompt(
            history: history,
            retrievedContext: "FULL DOCUMENT SENTINEL",
            fullDocumentPlacement: true,
            systemPromptOverride: "FROZEN SYSTEM SENTINEL"
        )

        XCTAssertTrue(prompt.contains("FULL DOCUMENT SENTINEL"))
        XCTAssertTrue(prompt.contains("FROZEN SYSTEM SENTINEL"))
        XCTAssertTrue(prompt.contains(#"{"result":"value"}"#))
    }

    @MainActor
    func testPlainToolContinuationPromptRetainsQuerySpecificRAGContext() {
        let vm = ChatVM()
        let history: [ChatVM.Msg] = [
            .init(role: "user", text: "Question", timestamp: Date()),
            .init(role: "tool", text: "Tool output", timestamp: Date())
        ]

        let prompt = vm.plainToolContinuationPrompt(
            history: history,
            retrievedContext: "RAG CONTEXT SENTINEL",
            fullDocumentPlacement: false,
            systemPromptOverride: "FROZEN SYSTEM SENTINEL"
        )

        XCTAssertTrue(prompt.contains("RAG CONTEXT SENTINEL"))
        XCTAssertTrue(prompt.contains("FROZEN SYSTEM SENTINEL"))
    }

    @MainActor
    func testToolContinuationHistoryCopiesLiveAssistantToolMetadata() throws {
        let vm = ChatVM()
        let toolCall = ChatVM.Msg.ToolCall(
            toolName: "dataset.grep",
            displayName: "Read",
            iconName: "doc.text.magnifyingglass",
            requestParams: ["query": AnyCodable("method")],
            phase: .completed,
            externalToolCallID: "call-dataset-1",
            result: #"{"matches":[]}"#
        )
        let history: [ChatVM.Msg] = [
            .init(role: "user", text: "Question", timestamp: Date()),
            .init(role: "assistant", text: "", timestamp: Date(), streaming: true)
        ]

        let continuation = vm.historyForToolContinuation(
            from: history,
            assistantIndex: 1,
            assistantText: "Calling the document tool",
            assistantToolCalls: [toolCall],
            toolResult: #"{"matches":[]}"#
        )

        XCTAssertEqual(continuation[1].text, "Calling the document tool")
        XCTAssertEqual(continuation[1].toolCalls?.first?.externalToolCallID, "call-dataset-1")
        XCTAssertEqual(continuation.last?.role, "tool")
        XCTAssertEqual(continuation.last?.text, #"{"matches":[]}"#)
    }

    @MainActor
    func testEscalationMessagesPreserveNativeToolCallAndResultRoles() throws {
        let vm = ChatVM()
        let toolCall = ChatVM.Msg.ToolCall(
            toolName: "noema.pdf.read",
            displayName: "Read",
            iconName: "doc.text.magnifyingglass",
            requestParams: [
                "action": AnyCodable("grep"),
                "query": AnyCodable("hardware")
            ],
            phase: .completed,
            externalToolCallID: "pdf-call-1",
            result: #"{"matches":[{"page":6}]}"#
        )
        var assistant = ChatVM.Msg(
            role: "assistant",
            text: "<think>Search the PDF.</think>\(noemaToolAnchorToken)",
            timestamp: Date()
        )
        assistant.toolCalls = [toolCall]
        let history: [ChatVM.Msg] = [
            .init(role: "user", text: "Find the training hardware", timestamp: Date()),
            assistant,
            .init(role: "tool", text: #"{"matches":[{"page":6}]}"#, timestamp: Date())
        ]

        let messages = vm.escalationChatMessages(
            history: history,
            systemPrompt: "System"
        )

        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "tool"])
        XCTAssertFalse(messages[2].content.contains(noemaToolAnchorToken))
        XCTAssertEqual(messages[2].toolCalls?.first?.id, "pdf-call-1")
        XCTAssertEqual(messages[2].toolCalls?.first?.function.name, "noema.pdf.read")
        XCTAssertEqual(messages[3].toolCallId, "pdf-call-1")
        XCTAssertFalse(messages.contains { $0.content.contains("Give the final answer now") })
    }

    @MainActor
    func testStreamingContinuationDoesNotStopAfterTwoToolResults() async {
        let probe = SequencedToolContinuationProbe(
            outputs: [
                [#"TOOL_RESULT: {"step":1}"#],
                [#"TOOL_RESULT: {"step":2}"#],
                [#"TOOL_RESULT: {"step":3}"#],
                ["Final answer after three tool results."]
            ]
        )
        let client = AnyLLMClient(textStream: { input in
            let chunks = await probe.nextOutput(for: input)
            return AsyncThrowingStream<String, Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        })
        let vm = ChatVM()
        vm.msgs = [.init(role: "system", text: "test")]
        vm.setClientForTesting(
            client,
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/unlimited-tool-continuation.gguf"),
            loadedFormat: .gguf
        )

        await vm.sendMessage("Research this with as many tool calls as needed")
        for _ in 0..<2_000 {
            if await probe.invocationCount() >= 4,
               vm.msgs.last?.streaming == false {
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 4)
        XCTAssertTrue(vm.msgs.last?.text.contains("Final answer after three tool results.") == true)
        XCTAssertFalse(vm.msgs.last?.streaming ?? true)
    }

    func testTemplateDrivenLoopbackRequestPlanAddsGenerationPrompt() {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"))
        let input = LLMInput(
            .messages([ChatMessage(role: "user", content: "hello")]),
            generationOptions: LLMGenerationOptions(promptCache: true)
        )

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: false)

        XCTAssertEqual(plan.endpoint, "/v1/chat/completions")
        XCTAssertEqual(plan.requestMode, "chat_completions")
        XCTAssertEqual(plan.body["add_generation_prompt"] as? Bool, true)
        XCTAssertEqual(plan.body["cache_prompt"] as? Bool, true)
        XCTAssertEqual(plan.body["reasoning_format"] as? String, "deepseek")
        let kwargs = plan.body["chat_template_kwargs"] as? [String: Bool]
        XCTAssertEqual(kwargs?["enable_thinking"], true)
    }

    func testPlainLoopbackRequestPlanHonorsRequestPromptCache() {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/model.gguf"))

        let plan = client.buildLoopbackRequestPlan(
            for: LLMInput(.plain("hello"), generationOptions: LLMGenerationOptions(promptCache: true)),
            forceNonStreaming: false
        )

        XCTAssertEqual(plan.endpoint, "/completion")
        XCTAssertEqual(plan.body["cache_prompt"] as? Bool, true)
    }

    func testAliasModelUsesMetadataBackedQwen35Profile() throws {
        let root = try makeTemporaryDirectory()
        let weight = root.appendingPathComponent("Next2.5-Q4_K_M.gguf")
        let template = root.appendingPathComponent("chat_template.jinja")
        FileManager.default.createFile(atPath: weight.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(
            atPath: template.path,
            contents: Data(
                """
                <|im_start|>assistant
                {% if enable_thinking %}<think>{% endif %}
                <tool_call><function=name><parameter=name>
                """.utf8
            )
        )

        XCTAssertTrue(TemplateDrivenModelSupport.isQwen35(modelURL: weight))
        XCTAssertEqual(TemplateDrivenModelSupport.templateLabel(modelURL: weight), "qwen3.5-override")
        let configuration = TemplateDrivenModelSupport.loopbackStartConfiguration(
            modelURL: weight,
            ggufPath: weight.path,
            mmprojPath: nil
        )
        XCTAssertTrue(configuration.useJinja)
        XCTAssertEqual(configuration.reasoningBudget, -1)
        XCTAssertNotNil(configuration.chatTemplateFile)
    }

    func testLoopbackStartConfigurationIncludesMTPDraftOptions() throws {
        let root = try makeTemporaryDirectory()
        let weight = root.appendingPathComponent("Next2.5-Q4_K_M.gguf")
        let mtp = root.appendingPathComponent("Next2.5-mtp-f16.gguf")
        FileManager.default.createFile(atPath: weight.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(atPath: mtp.path, contents: Data("GGUF".utf8))

        let configuration = TemplateDrivenModelSupport.loopbackStartConfiguration(
            modelURL: weight,
            ggufPath: weight.path,
            mmprojPath: nil,
            mtpPath: mtp.path,
            speculativeType: "draft-mtp",
            specDraftNMax: 2
        )

        XCTAssertEqual(configuration.mtpPath, mtp.path)
        XCTAssertEqual(configuration.speculativeType, "draft-mtp")
        XCTAssertEqual(configuration.specDraftNMax, 2)
    }

    func testStructuredMultimodalRequestPlanPreservesHistoryAndQwenFlags() throws {
        let root = try makeTemporaryDirectory()
        let weight = root.appendingPathComponent("Next2.5-Q4_K_M.gguf")
        let template = root.appendingPathComponent("chat_template.jinja")
        let image = root.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: weight.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(
            atPath: template.path,
            contents: Data(
                """
                <|im_start|>assistant
                {% if enable_thinking %}<think>{% endif %}
                <tool_call><function=name><parameter=name>
                """.utf8
            )
        )
        FileManager.default.createFile(atPath: image.path, contents: Data("not-a-real-image".utf8))

        let client = NoemaLlamaClient(url: weight)
        let input = LLMInput.multimodal(
            messages: [
                ChatMessage(role: "system", content: "sys"),
                ChatMessage(role: "user", content: "Describe this image")
            ],
            imagePaths: [image.path]
        )

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: false)
        let messages = try XCTUnwrap(plan.body["messages"] as? [[String: Any]])
        let userPayload = try XCTUnwrap(messages.last)
        let content = try XCTUnwrap(userPayload["content"] as? [[String: Any]])
        let imagePayload = try XCTUnwrap(content.last?["image_url"] as? [String: String])

        XCTAssertEqual(plan.body["add_generation_prompt"] as? Bool, true)
        XCTAssertEqual(plan.body["speculative"] as? Bool, false)
        XCTAssertEqual(plan.body["reasoning_format"] as? String, "deepseek")
        XCTAssertEqual((plan.body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "sys")
        XCTAssertEqual(userPayload["role"] as? String, "user")
        XCTAssertEqual(content.first?["text"] as? String, "Describe this image")
        XCTAssertTrue(imagePayload["url"]?.hasPrefix("data:image/") == true)
    }

    func testStructuredExtractionRequestDisablesQwenThinkingAndConstrainsJSON() throws {
        let root = try makeTemporaryDirectory()
        let weight = root.appendingPathComponent("Next2.5-Q4_K_M.gguf")
        let template = root.appendingPathComponent("chat_template.jinja")
        let image = root.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: weight.path, contents: Data("GGUF".utf8))
        FileManager.default.createFile(
            atPath: template.path,
            contents: Data(
                """
                <|im_start|>assistant
                {% if enable_thinking %}<think>{% endif %}
                <tool_call><function=name><parameter=name>
                """.utf8
            )
        )
        FileManager.default.createFile(atPath: image.path, contents: Data("not-a-real-image".utf8))

        let client = NoemaLlamaClient(url: weight)
        let input = LLMInput.multimodal(
            text: "Return pass JSON",
            imagePaths: [image.path],
            generationOptions: LLMGenerationOptions(
                reasoningEnabled: false,
                maxOutputTokens: 1024,
                thinkingBudgetTokens: 256,
                responseFormat: .jsonSchema(name: "pass_extraction", schema: ["type": AnyCodable("object")])
            )
        )

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: false)
        let messages = try XCTUnwrap(plan.body["messages"] as? [[String: Any]])
        let userPayload = try XCTUnwrap(messages.last)
        let content = try XCTUnwrap(userPayload["content"] as? [[String: Any]])
        let responseFormat = try XCTUnwrap(plan.body["response_format"] as? [String: Any])
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])

        XCTAssertEqual(plan.body["add_generation_prompt"] as? Bool, true)
        XCTAssertEqual(plan.body["speculative"] as? Bool, false)
        XCTAssertNil(plan.body["reasoning_format"])
        XCTAssertEqual((plan.body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual(plan.body["n_predict"] as? Int, 1024)
        XCTAssertEqual(plan.body["max_tokens"] as? Int, 1024)
        XCTAssertEqual(plan.body["thinking_budget_tokens"] as? Int, 256)
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        XCTAssertEqual(jsonSchema["name"] as? String, "pass_extraction")
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(content.first?["text"] as? String, "Return pass JSON")
        XCTAssertNotNil(content.last?["image_url"] as? [String: String])
    }

    @MainActor
    func testLoopbackChatMessagesPreserveToolCallsAndToolMessageIDs() throws {
        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"),
            loadedFormat: .gguf
        )

        let toolCall = ChatVM.Msg.ToolCall(
            toolName: "noema.python.execute",
            displayName: "Python",
            iconName: "chevron.left.forwardslash.chevron.right",
            requestParams: ["code": AnyCodable("print(2 + 2)")],
            phase: .completed,
            externalToolCallID: "call-1",
            result: #"{"stdout":"4"}"#
        )
        var assistant = ChatVM.Msg(
            role: "🤖",
            text: "<think>Using Python</think>\(noemaToolAnchorToken)",
            timestamp: Date()
        )
        assistant.toolCalls = [toolCall]

        let history: [ChatVM.Msg] = [
            .init(role: "system", text: "sys", timestamp: Date()),
            .init(role: "🧑‍💻", text: "Do 2+2", timestamp: Date()),
            assistant,
            .init(role: "tool", text: #"{"stdout":"4"}"#, timestamp: Date())
        ]

        let messages = try XCTUnwrap(vm.loopbackChatMessages(from: history))
        let assistantMessage = try XCTUnwrap(messages.first(where: { $0.role == "assistant" && ($0.toolCalls?.isEmpty == false) }))
        let toolMessage = try XCTUnwrap(messages.first(where: { $0.role == "tool" }))

        XCTAssertEqual(assistantMessage.toolCalls?.first?.id, "call-1")
        XCTAssertEqual(assistantMessage.toolCalls?.first?.function.name, "noema.python.execute")
        XCTAssertEqual(assistantMessage.toolCalls?.first?.function.arguments, #"{"code":"print(2 + 2)"}"#)
        XCTAssertEqual(toolMessage.toolCallId, "call-1")
        XCTAssertFalse(assistantMessage.content.contains(noemaToolAnchorToken))
        XCTAssertTrue(assistantMessage.content.contains("<think>Using Python</think>"))
    }

    func testLoopbackRequestPlanSerializesToolCallsAndNullAssistantContent() throws {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"))
        let input = LLMInput(.messages([
            ChatMessage(role: "user", content: "Do 2+2"),
            ChatMessage(
                role: "assistant",
                content: "",
                toolCalls: [
                    ToolCall(
                        id: "call-1",
                        name: "noema.python.execute",
                        arguments: #"{"code":"print(2 + 2)"}"#
                    )
                ]
            ),
            ChatMessage(role: "tool", content: #"{"stdout":"4"}"#, toolCallId: "call-1")
        ]))

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: false)
        let messages = try XCTUnwrap(plan.body["messages"] as? [[String: Any]])
        let assistantPayload = try XCTUnwrap(messages.first(where: { ($0["role"] as? String) == "assistant" }))
        let toolPayload = try XCTUnwrap(messages.first(where: { ($0["role"] as? String) == "tool" }))
        let toolCalls = try XCTUnwrap(assistantPayload["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])

        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call-1")
        XCTAssertEqual(function["name"] as? String, "noema.python.execute")
        XCTAssertEqual(function["arguments"] as? String, #"{"code":"print(2 + 2)"}"#)
        XCTAssertTrue(assistantPayload["content"] is NSNull)
        XCTAssertEqual(toolPayload["tool_call_id"] as? String, "call-1")
    }

    func testLoopbackRequestPlanPreservesAssistantThoughtTextAlongsideToolCalls() throws {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"))
        let thought = "<think>Using Python to verify the arithmetic.</think>"
        let input = LLMInput(.messages([
            ChatMessage(
                role: "assistant",
                content: thought,
                toolCalls: [
                    ToolCall(
                        id: "call-1",
                        name: "noema.python.execute",
                        arguments: #"{"code":"print(2 + 2)"}"#
                    )
                ]
            )
        ]))

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: false)
        let messages = try XCTUnwrap(plan.body["messages"] as? [[String: Any]])
        let assistantPayload = try XCTUnwrap(messages.first)

        XCTAssertEqual(assistantPayload["content"] as? String, thought)
        XCTAssertEqual((assistantPayload["tool_calls"] as? [[String: Any]])?.count, 1)
    }

    @MainActor
    func testStrictFinalAnswerTextKeepsVisibleTextBeforeToolAnchor() {
        let vm = ChatVM()
        var message = ChatVM.Msg(
            role: "🤖",
            text: "Visible answer\(noemaToolAnchorToken)",
            timestamp: Date()
        )
        message.toolCalls = [
            .init(
                toolName: "noema.web.retrieve",
                displayName: "Web Search",
                iconName: "globe",
                requestParams: [:],
                phase: .completed,
                result: "[]"
            )
        ]

        XCTAssertEqual(vm.strictFinalAnswerText(for: message), "Visible answer")
    }

    @MainActor
    func testStrictFinalAnswerTextIgnoresScrubbedToolArtifacts() {
        let vm = ChatVM()
        var message = ChatVM.Msg(
            role: "🤖",
            text: "Visible answer",
            timestamp: Date()
        )
        message.toolCalls = [
            .init(
                toolName: "noema.web.retrieve",
                displayName: "Web Search",
                iconName: "globe",
                requestParams: [:],
                phase: .completed,
                result: "[]"
            )
        ]

        XCTAssertEqual(vm.strictFinalAnswerText(for: message), "Visible answer")
    }

    @MainActor
    func testToolOnlyAssistantMessageKeepsEmptyScrubbedContentWithoutFallbackText() throws {
        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"),
            loadedFormat: .gguf
        )

        let toolCall = ChatVM.Msg.ToolCall(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: ["query": AnyCodable("latest ai news")],
            phase: .completed,
            result: "[]"
        )
        var assistant = ChatVM.Msg(
            role: "🤖",
            text: noemaToolAnchorToken,
            timestamp: Date()
        )
        assistant.toolCalls = [toolCall]

        XCTAssertNil(vm.strictFinalAnswerText(for: assistant))
        XCTAssertNil(vm.finalAnswerText(for: assistant))

        let messages = try XCTUnwrap(vm.loopbackChatMessages(from: [assistant]))
        let assistantMessage = try XCTUnwrap(messages.first(where: { $0.role == "assistant" }))

        XCTAssertEqual(assistantMessage.content, "")
        XCTAssertEqual(assistantMessage.toolCalls?.count, 1)
        XCTAssertFalse(assistantMessage.content.contains("interrupted before completion"))
    }

    @MainActor
    func testResolvedVisiblePostToolFinalTextPreservesExistingVisibleText() {
        let vm = ChatVM()
        let visibleText = "<think>First</think>\(noemaToolAnchorToken)<think>Second</think>\nFinal answer"
        vm.streamMsgs = [
            ChatVM.Msg(role: "🧑‍💻", text: "Who is the president of Romania", timestamp: Date()),
            ChatVM.Msg(role: "🤖", text: visibleText, timestamp: Date(), streaming: true)
        ]

        let resolved = vm.resolvedVisiblePostToolFinalText(
            existingVisibleText: vm.streamMsgs[1].text,
            fallbackText: "replacement text that should not win",
            toolCalls: vm.streamMsgs[1].toolCalls
        )
        vm.streamMsgs[1].text = resolved
        vm.streamMsgs[1].streaming = false

        XCTAssertEqual(vm.streamMsgs[1].text, visibleText)
        XCTAssertFalse(vm.streamMsgs[1].streaming)
    }

    func testGenerationCoordinatorAllowsFutureUnloadsAfterConcurrentWaiters() async {
        let coordinator = GenerationCoordinator()

        await coordinator.acquireGeneration()

        let firstUnload = Task { await coordinator.beginUnloadAcquiring() }
        await Task.yield()
        let secondUnload = Task { await coordinator.beginUnloadAcquiring() }
        await Task.yield()

        await coordinator.releaseGeneration()

        let firstDidUnload = await firstUnload.value
        XCTAssertTrue(firstDidUnload)
        await coordinator.endUnload()
        let secondDidUnload = await secondUnload.value
        XCTAssertFalse(secondDidUnload)

        await coordinator.acquireGeneration()
        let thirdUnload = Task { await coordinator.beginUnloadAcquiring() }
        await Task.yield()
        await coordinator.releaseGeneration()

        let thirdDidUnload = await thirdUnload.value
        XCTAssertTrue(thirdDidUnload)
        await coordinator.endUnload()
    }

    @MainActor
    func testManualUnloadDetachesClientStateBeforeAwaitedTeardownCompletes() async {
        let probe = AsyncUnloadProbe()
        let vm = ChatVM()
        let client = AnyLLMClient(
            textStream: { _ in
                AsyncThrowingStream<String, Error> { continuation in
                    continuation.finish()
                }
            },
            unloadAsync: {
                await probe.waitForRelease()
            }
        )

        vm.setClientForTesting(
            client,
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/manual-unload.gguf"),
            loadedFormat: .gguf
        )

        let unloadTask = Task {
            await vm.unload()
        }

        await probe.waitUntilInvoked()

        XCTAssertFalse(vm.modelLoaded)
        XCTAssertNil(vm.loadedModelURL)
        XCTAssertNil(vm.loadedModelFormat)
        let invocationCountBeforeResume = await probe.invocationCount()
        XCTAssertEqual(invocationCountBeforeResume, 1)

        await probe.resume()
        await unloadTask.value

        let invocationCountAfterResume = await probe.invocationCount()
        XCTAssertEqual(invocationCountAfterResume, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

#if canImport(UIKit)
    func testAttachmentNormalizerClampsOversizedImageData() throws {
        let input = try XCTUnwrap(Self.makeJPEG(width: 4200, height: 2800))
        let normalized = try XCTUnwrap(AttachmentImageNormalizer.normalizeAttachmentData(input))

        XCTAssertLessThanOrEqual(max(normalized.pixelWidth, normalized.pixelHeight), AttachmentImageNormalizer.maxLongEdgePixels)
        XCTAssertTrue(normalized.wasClamped)
        let expectedRatio = 4200.0 / 2800.0
        let actualRatio = Double(normalized.pixelWidth) / Double(normalized.pixelHeight)
        XCTAssertEqual(actualRatio, expectedRatio, accuracy: 0.02)
    }

    @MainActor
    func testSavePendingImageDataNormalizesOversizedPhotoPickerData() async throws {
        let vm = ChatVM()
        let priorURLs = Set(vm.pendingImageURLs)
        let input = try XCTUnwrap(Self.makeJPEG(width: 4032, height: 3024))

        await vm.savePendingImageData(input)

        let newURL = try XCTUnwrap(vm.pendingImageURLs.last(where: { !priorURLs.contains($0) }))
        defer { try? FileManager.default.removeItem(at: newURL) }

        let metadata = try XCTUnwrap(AttachmentImageNormalizer.metadata(forFileAt: newURL))
        XCTAssertLessThanOrEqual(max(metadata.pixelWidth, metadata.pixelHeight), AttachmentImageNormalizer.maxLongEdgePixels)
    }

    func testLoopbackImagePayloadClampsOversizedStoredAttachment() throws {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Qwen3.5-4B-Q4_K_M.gguf"))
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("noema-loopback-\(UUID().uuidString).jpg")
        let data = try XCTUnwrap(Self.makeJPEG(width: 5000, height: 1800))
        try data.write(to: tempURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let payload = client.loopbackImagePayload(for: tempURL.path)

        XCTAssertEqual(payload.mime, "image/jpeg")
        XCTAssertLessThanOrEqual(max(payload.pixelWidth, payload.pixelHeight), AttachmentImageNormalizer.maxLongEdgePixels)
        XCTAssertTrue(payload.wasClamped)
    }

    private static func makeJPEG(width: Int, height: Int) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill()
            context.fill(CGRect(x: width / 8, y: height / 8, width: width / 3, height: height / 3))
        }
        return image.jpegData(compressionQuality: 0.95)
    }
#endif
}

private actor AsyncUnloadProbe {
    private var count = 0
    private var invocationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        count += 1

        let waiters = invocationWaiters
        invocationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilInvoked() async {
        if count > 0 { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(continuation)
        }
    }

    func invocationCount() -> Int {
        count
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SequencedToolContinuationProbe {
    private let outputs: [[String]]
    private var inputs: [LLMInput] = []

    init(outputs: [[String]]) {
        self.outputs = outputs
    }

    func nextOutput(for input: LLMInput) -> [String] {
        inputs.append(input)
        let index = inputs.count - 1
        return outputs.indices.contains(index) ? outputs[index] : []
    }

    func invocationCount() -> Int {
        inputs.count
    }
}
