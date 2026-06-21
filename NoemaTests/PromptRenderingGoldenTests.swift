import Foundation
import XCTest
@testable import Noema

final class PromptRenderingGoldenTests: XCTestCase {
    func testPromptBuilderGoldenOutputForSupportedTemplateKinds() {
        let messages = [
            ChatVM.Msg(role: "system", text: "Follow policy."),
            ChatVM.Msg(role: "user", text: "Hello."),
            ChatVM.Msg(role: "assistant", text: "Hi there."),
            ChatVM.Msg(role: "tool", text: #"{"temperature":72}"#),
            ChatVM.Msg(role: "user", text: "Use that result.")
        ]

        let cases: [GoldenCase] = [
            GoldenCase(
                name: "llama3",
                template: "<|begin_of_text|>",
                family: .llama3,
                expectedPrompt: """
                <|begin_of_text|><|start_header_id|>system<|end_header_id|>
                Follow policy.<|eot_id|><|start_header_id|>user<|end_header_id|>
                Hello.<|eot_id|><|start_header_id|>assistant<|end_header_id|>
                Hi there.<|eot_id|><|start_header_id|>user<|end_header_id|>
                Use that result.<|eot_id|><|start_header_id|>user<|end_header_id|>
                Tool Result:
                {"temperature":72}
                <|eot_id|><|start_header_id|>assistant<|end_header_id|>

                """,
                expectedStops: ["<|eot_id|>", "<|end_of_text|>"]
            ),
            GoldenCase(
                name: "inst",
                template: "[INST] <<SYS>>",
                family: .mistral,
                expectedPrompt: """
                <s>[INST] <<SYS>>
                Follow policy.
                <</SYS>>

                Hello. [/INST] Hi there.</s><s>[INST] Use that result.
                Tool Result:
                {"temperature":72}
                 [/INST]
                """,
                expectedStops: ["</s>"]
            ),
            GoldenCase(
                name: "chatml",
                template: "<|im_start|>",
                family: .qwen,
                expectedPrompt: """
                <|im_start|>system
                Follow policy.
                <|im_end|>
                <|im_start|>user
                Hello.
                <|im_end|>
                <|im_start|>assistant
                Hi there.
                <|im_end|>
                <|im_start|>user
                <tool_response>
                {"temperature":72}
                </tool_response><|im_end|>
                <|im_start|>user
                Use that result.
                <|im_end|>
                <|im_start|>assistant

                """,
                expectedStops: ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"]
            ),
            GoldenCase(
                name: "qwen35",
                template: "<tool_call><function=<parameter= enable_thinking <|im_start|>",
                family: .qwen,
                expectedPrompt: """
                <|im_start|>system
                Follow policy.
                <|im_end|>
                <|im_start|>user
                Hello.
                <|im_end|>
                <|im_start|>assistant
                Hi there.
                <|im_end|>
                <|im_start|>user
                <tool_response>
                {"temperature":72}
                </tool_response><|im_end|>
                <|im_start|>user
                Use that result.
                <|im_end|>
                <|im_start|>assistant
                <think>

                """,
                expectedStops: ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"]
            ),
            GoldenCase(
                name: "lfm",
                template: "<|startoftext|><|im_start|>",
                family: .lfm,
                expectedPrompt: """
                <|startoftext|><|im_start|>system
                Follow policy.
                <|im_end|>
                <|im_start|>user
                Hello.
                <|im_end|>
                <|im_start|>assistant
                Hi there.
                <|im_end|>
                <|im_start|>user
                <tool_response>
                {"temperature":72}
                </tool_response><|im_end|>
                <|im_start|>user
                Use that result.
                <|im_end|>
                <|im_start|>assistant

                """,
                expectedStops: ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"]
            ),
            GoldenCase(
                name: "gemma",
                template: "<start_of_turn>",
                family: .gemma,
                expectedPrompt: """
                <bos><start_of_turn>system
                Follow policy.<end_of_turn>
                <start_of_turn>user
                Hello.<end_of_turn>
                <start_of_turn>model
                Hi there.<end_of_turn>
                <start_of_turn>user
                Use that result.
                Tool Result:
                {"temperature":72}
                <end_of_turn>
                <start_of_turn>model

                """,
                expectedStops: ["<end_of_turn>", "<start_of_turn>user"]
            ),
            GoldenCase(
                name: "phi",
                template: "<|system|><|user|><|assistant|>",
                family: .phi,
                expectedPrompt: """
                <|system|>
                Follow policy.
                <|user|>
                Hello.
                <|assistant|>
                Hi there.<|user|>
                Use that result.
                <|user|>
                Tool Result:
                {"temperature":72}
                <|assistant|>

                """,
                expectedStops: ["<|end|>", "<|user|>", "<|system|>", "<|endoftext|>"]
            ),
            GoldenCase(
                name: "internlm",
                template: nil,
                family: .internlm,
                expectedPrompt: """
                <|im_start|>system
                Follow policy.
                <|im_end|>
                <|im_start|>user
                Hello.
                <|im_end|>
                <|im_start|>assistant
                Hi there.
                <|im_end|>
                <|im_start|>user
                <tool_response>
                {"temperature":72}
                </tool_response><|im_end|>
                <|im_start|>user
                Use that result.
                <|im_end|>
                <|im_start|>assistant

                """,
                expectedStops: ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"]
            ),
            GoldenCase(
                name: "deepseek",
                template: "<｜User｜><｜Assistant｜>",
                family: .deepseek,
                expectedPrompt: """
                <｜begin▁of▁sentence｜>Follow policy.<｜User｜>Hello.<｜Assistant｜>Hi there.<｜end▁of▁sentence｜><｜tool▁outputs▁begin｜><｜tool▁output▁begin｜>{"temperature":72}<｜tool▁output▁end｜><｜tool▁outputs▁end｜><｜User｜>Use that result.<｜Assistant｜><think>

                """,
                expectedStops: ["<｜User｜>", "<|User|>", "</s>", "<eos>", "</eos>"]
            ),
            GoldenCase(
                name: "yi",
                template: "<|startoftext|> yi use_default_system_prompt",
                family: .yi,
                expectedPrompt: """
                <|startoftext|><|im_start|>system
                Follow policy.
                <|im_end|>
                <|im_start|>user
                Hello.
                <|im_end|>
                <|im_start|>assistant
                Hi there.
                <|im_end|>
                <|im_start|>user
                <tool_response>
                {"temperature":72}
                </tool_response><|im_end|>
                <|im_start|>user
                Use that result.
                <|im_end|>
                <|im_start|>assistant

                """,
                expectedStops: ["<|im_end|>", "<|im_start|>user", "<|endoftext|>"]
            ),
            GoldenCase(
                name: "alpaca",
                template: "### Instruction",
                family: .other,
                expectedPrompt: """
                ### Instruction:
                Follow policy.
                Use that result.

                Tool Result:
                {"temperature":72}

                ### Response:

                """,
                expectedStops: ["### Instruction:"]
            ),
            GoldenCase(
                name: "vicuna",
                template: "USER: prompt\nASSISTANT:",
                family: .other,
                expectedPrompt: """
                USER: Hello.
                ASSISTANT: Hi there.
                USER: Follow policy.
                Use that result.
                USER: Tool Result:
                {"temperature":72}
                ASSISTANT: 
                """,
                expectedStops: ["USER:"]
            ),
            GoldenCase(
                name: "fallback",
                template: nil,
                family: .other,
                expectedPrompt: """
                System:
                Follow policy.
                User:
                Hello.
                Assistant:
                Hi there.
                User:
                Use that result.
                User:
                Tool Result:
                {"temperature":72}
                Assistant:

                """,
                expectedStops: ["User:"]
            )
        ]

        for testCase in cases {
            let result = PromptBuilder.build(template: testCase.template, family: testCase.family, messages: messages)
            XCTAssertEqual(result.0, testCase.expectedPrompt, testCase.name)
            XCTAssertEqual(result.1, testCase.expectedStops, testCase.name)
            XCTAssertNil(result.2, testCase.name)
        }
    }

    func testPromptTemplateResolutionCoversSupportedMetadataSources() throws {
        let cases: [TemplateSourceCase] = [
            TemplateSourceCase(
                name: "chat_template.jinja",
                expectedSource: .chatTemplateFile,
                write: { dir, template in
                    try template.write(to: dir.appendingPathComponent("chat_template.jinja"), atomically: true, encoding: .utf8)
                }
            ),
            TemplateSourceCase(
                name: "chat_template.txt",
                expectedSource: .chatTemplateFile,
                write: { dir, template in
                    try template.write(to: dir.appendingPathComponent("chat_template.txt"), atomically: true, encoding: .utf8)
                }
            ),
            TemplateSourceCase(
                name: "chat_template.json",
                expectedSource: .chatTemplateFile,
                write: { dir, template in
                    try PromptRenderingGoldenTests.writeJSON(["chat_template": template], to: dir.appendingPathComponent("chat_template.json"))
                }
            ),
            TemplateSourceCase(
                name: "hub gguf metadata",
                expectedSource: .hubMetadata,
                write: { dir, template in
                    try PromptRenderingGoldenTests.writeJSON(["gguf": ["chat_template": template]], to: dir.appendingPathComponent("hub.json"))
                }
            ),
            TemplateSourceCase(
                name: "hub root metadata",
                expectedSource: .hubMetadata,
                write: { dir, template in
                    try PromptRenderingGoldenTests.writeJSON(["chat_template": template], to: dir.appendingPathComponent("hub.json"))
                }
            ),
            TemplateSourceCase(
                name: "hub card metadata",
                expectedSource: .hubMetadata,
                write: { dir, template in
                    try PromptRenderingGoldenTests.writeJSON(["cardData": ["chat_template_jinja": template]], to: dir.appendingPathComponent("hub.json"))
                }
            ),
            TemplateSourceCase(
                name: "tokenizer_config.json",
                expectedSource: .tokenizerConfig,
                write: { dir, template in
                    try PromptRenderingGoldenTests.writeJSON(["chat_template": template], to: dir.appendingPathComponent("tokenizer_config.json"))
                }
            ),
            TemplateSourceCase(
                name: "tokenizer.json",
                expectedSource: .tokenizer,
                write: { dir, template in
                    try PromptRenderingGoldenTests.writeJSON(["chat_template": template], to: dir.appendingPathComponent("tokenizer.json"))
                }
            ),
            TemplateSourceCase(
                name: "config.json",
                expectedSource: .config,
                write: { dir, template in
                    try PromptRenderingGoldenTests.writeJSON(["chat_template": template], to: dir.appendingPathComponent("config.json"))
                }
            )
        ]

        for testCase in cases {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let template = "<|im_start|>\nsource=\(testCase.name)"
            try testCase.write(root, template)

            let resolution = ModelSettings.promptTemplateResolution(
                for: localModel(name: "PlainModel-\(testCase.name)", root: root),
                directory: root
            )
            let rendered = PromptBuilder.build(template: resolution.template, family: .qwen, messages: sampleMessages())

            XCTAssertEqual(resolution.source, testCase.expectedSource, testCase.name)
            XCTAssertEqual(resolution.template, template, testCase.name)
            XCTAssertEqual(rendered.0, chatMLGoldenPrompt(), testCase.name)
        }
    }

    func testCuratedTemplateTakesPrecedenceOverOnDiskMetadataSources() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "### Instruction\nmetadata should lose".write(to: root.appendingPathComponent("chat_template.jinja"), atomically: true, encoding: .utf8)

        let resolution = ModelSettings.promptTemplateResolution(
            for: localModel(name: "Qwen3-0.6B", root: root, architecture: "qwen3", architectureFamily: "qwen"),
            directory: root
        )
        let rendered = PromptBuilder.build(template: resolution.template, family: .qwen, messages: sampleMessages())

        XCTAssertEqual(resolution.source, .curated)
        XCTAssertEqual(resolution.template, ArchitectureTemplates.Templates.qwen3)
        XCTAssertEqual(rendered.0, chatMLGoldenPrompt())
    }

    func testDefaultTemplateSourceFallsBackToFamilyRendering() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolution = ModelSettings.promptTemplateResolution(
            for: localModel(name: "PlainModel", root: root),
            directory: root
        )
        let rendered = PromptBuilder.build(template: resolution.template, family: .llama3, messages: sampleMessages())

        XCTAssertEqual(resolution.source, .defaultTemplate)
        XCTAssertNil(resolution.template)
        XCTAssertEqual(rendered.0, """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>
        Be concise.<|eot_id|><|start_header_id|>user<|end_header_id|>
        Ping?<|eot_id|><|start_header_id|>assistant<|end_header_id|>

        """)
    }

    private struct GoldenCase {
        let name: String
        let template: String?
        let family: ModelKind
        let expectedPrompt: String
        let expectedStops: [String]
    }

    private struct TemplateSourceCase {
        let name: String
        let expectedSource: PromptTemplateSource
        let write: (URL, String) throws -> Void
    }

    private func sampleMessages() -> [ChatVM.Msg] {
        [
            ChatVM.Msg(role: "system", text: "Be concise."),
            ChatVM.Msg(role: "user", text: "Ping?")
        ]
    }

    private func chatMLGoldenPrompt() -> String {
        """
        <|im_start|>system
        Be concise.
        <|im_end|>
        <|im_start|>user
        Ping?
        <|im_end|>
        <|im_start|>assistant

        """
    }

    private func localModel(
        name: String,
        root: URL,
        architecture: String = "unknown",
        architectureFamily: String = "other"
    ) -> LocalModel {
        LocalModel(
            modelID: "fixtures/\(name)",
            name: name,
            url: root.appendingPathComponent("\(name).mlx"),
            quant: "F16",
            architecture: architecture,
            architectureFamily: architectureFamily,
            format: .mlx,
            sizeGB: 1.0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(timeIntervalSince1970: 0),
            totalLayers: 0
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-prompt-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
