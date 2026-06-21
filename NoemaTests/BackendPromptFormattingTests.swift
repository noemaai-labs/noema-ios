import Foundation
import XCTest
@testable import Noema
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif

/// Covers the prompt plumbing fixed in the backend audit: ExecuTorch per-turn
/// templating (previously hardcoded ChatML or none at all) and the MLX
/// structured-chat/sampling-parameter mapping (previously "role: content"
/// joins and unwired sampling sliders).
final class BackendPromptFormattingTests: XCTestCase {
    // MARK: - ETTurnFormatter

    func testChatMLFirstTurnCarriesSystemPromptOnce() {
        let formatter = ETTurnFormatter(kind: .chatml)
        let first = formatter.renderTurn(
            userText: "Hello",
            systemPrompt: "Be brief.",
            isFirstTurn: true
        )

        XCTAssertEqual(first, "<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n")

        let continuation = formatter.renderTurn(
            userText: "And again",
            systemPrompt: "Be brief.",
            isFirstTurn: false
        )
        XCTAssertFalse(continuation.contains("Be brief."), "system prompt must not be re-sent into a persistent KV cache")
        XCTAssertEqual(continuation, "<|im_start|>user\nAnd again<|im_end|>\n<|im_start|>assistant\n")
    }

    func testLlama3TurnUsesHeaderTokensAndBOSOnlyOnFirstTurn() {
        let formatter = ETTurnFormatter(kind: .llama3)
        let first = formatter.renderTurn(userText: "Hi", systemPrompt: "Stay safe.", isFirstTurn: true)

        XCTAssertTrue(first.hasPrefix("<|begin_of_text|>"))
        XCTAssertTrue(first.contains("<|start_header_id|>system<|end_header_id|>\n\nStay safe.<|eot_id|>"))
        XCTAssertTrue(first.hasSuffix("<|start_header_id|>assistant<|end_header_id|>\n\n"))
        XCTAssertFalse(first.contains("<|im_start|>"), "llama3 models must not receive ChatML tokens")

        let continuation = formatter.renderTurn(userText: "More", systemPrompt: "Stay safe.", isFirstTurn: false)
        XCTAssertFalse(continuation.contains("<|begin_of_text|>"))
        XCTAssertFalse(continuation.contains("Stay safe."))
    }

    func testGemmaTurnFoldsSystemIntoUserBlock() {
        let formatter = ETTurnFormatter(kind: .gemmaTurn)
        let first = formatter.renderTurn(userText: "Hi", systemPrompt: "Be kind.", isFirstTurn: true)

        XCTAssertEqual(first, "<bos><start_of_turn>user\nBe kind.\n\nHi<end_of_turn>\n<start_of_turn>model\n")
    }

    func testToolResultIsRenderedBeforeUserTurn() {
        let formatter = ETTurnFormatter(kind: .chatml)
        let turn = formatter.renderTurn(
            userText: "Summarize the results",
            systemPrompt: nil,
            isFirstTurn: false,
            toolResult: #"{"temperature":72}"#
        )

        XCTAssertEqual(
            turn,
            "<|im_start|>user\n<tool_response>\n{\"temperature\":72}\n</tool_response><|im_end|>\n<|im_start|>user\nSummarize the results<|im_end|>\n<|im_start|>assistant\n"
        )
    }

    func testNoTemplateKindStillAvoidsRoleColonJoin() {
        let formatter = ETTurnFormatter(kind: .none)
        let turn = formatter.renderTurn(userText: "Hello", systemPrompt: "Sys", isFirstTurn: true)

        XCTAssertEqual(turn, "System:\nSys\n\nUser:\nHello\nAssistant:\n")
        XCTAssertFalse(turn.contains("user: "), "the legacy 'role: content' join must not reappear")
    }

    func testFormatterDetectsFamilyFromTemplateAndModelName() {
        XCTAssertEqual(ETTurnFormatter(template: "<|begin_of_text|>...", modelNameHint: "whatever.pte").kind, .llama3)
        XCTAssertEqual(ETTurnFormatter(template: nil, modelNameHint: "llama3_2-1B_et.pte").kind, .llama3)
        XCTAssertEqual(ETTurnFormatter(template: nil, modelNameHint: "qwen2_5-1_5b.pte").kind, .chatml)
        XCTAssertEqual(ETTurnFormatter(template: nil, modelNameHint: "gemma-2b.pte").kind, .gemmaTurn)
    }

    // MARK: - MLX chat-turn mapping

    func testMLXChatTurnsMapRolesAndFoldToolResults() {
        let messages = [
            ChatMessage(role: "system", content: "Policy"),
            ChatMessage(role: "user", content: "Question"),
            ChatMessage(role: "assistant", content: "Answer"),
            ChatMessage(role: "tool", content: "{\"ok\":true}"),
            ChatMessage(role: "🧑‍💻", content: "Emoji user")
        ]

        let turns = MLXBridge.chatTurns(from: messages)

        XCTAssertEqual(turns.map(\.role), [.system, .user, .assistant, .user, .user])
        XCTAssertEqual(turns[3].content, "Tool result:\n{\"ok\":true}")
        XCTAssertEqual(turns[4].content, "Emoji user")
        XCTAssertFalse(turns.contains { $0.content.hasPrefix("user: ") })
    }

    // MARK: - MLX sampling parameters

    #if canImport(MLXLMCommon)
    func testGenerateParametersMapSamplingSettings() {
        var settings = ModelSettings()
        settings.temperature = 0.4
        settings.topP = 0.9
        settings.topK = 50
        settings.minP = 0.05
        settings.repetitionPenalty = 1.2
        settings.repeatLastN = 128

        let parameters = MLXBridge.generateParameters(settings: settings, maxOutputTokens: 256)

        XCTAssertEqual(parameters.temperature, 0.4, accuracy: 1e-6)
        XCTAssertEqual(parameters.topP, 0.9, accuracy: 1e-6)
        XCTAssertEqual(parameters.topK, 50)
        XCTAssertEqual(parameters.minP, 0.05, accuracy: 1e-6)
        XCTAssertEqual(parameters.repetitionPenalty, 1.2)
        XCTAssertEqual(parameters.repetitionContextSize, 128)
        XCTAssertEqual(parameters.maxTokens, 256)
    }

    func testGenerateParametersDisableNeutralPenalties() {
        var settings = ModelSettings()
        settings.repetitionPenalty = 1.0
        settings.presencePenalty = 0
        settings.frequencyPenalty = 0

        let parameters = MLXBridge.generateParameters(settings: settings, maxOutputTokens: nil)

        XCTAssertNil(parameters.repetitionPenalty, "a 1.0 penalty is a no-op and should not pay the processor cost")
        XCTAssertNil(parameters.presencePenalty)
        XCTAssertNil(parameters.frequencyPenalty)
        XCTAssertNil(parameters.maxTokens)
    }
    #endif
}
