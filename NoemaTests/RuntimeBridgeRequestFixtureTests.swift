import Foundation
import XCTest
@testable import Noema

final class RuntimeBridgeRequestFixtureTests: XCTestCase {
    func testPlainCompletionRequestBodyFixture() throws {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/TinyLlama-Q4_K_M.gguf"))
        let input = LLMInput.plain(
            "Write one haiku.",
            generationOptions: LLMGenerationOptions(maxOutputTokens: 64)
        )

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: true)

        XCTAssertEqual(plan.endpoint, "/completion")
        XCTAssertEqual(plan.requestMode, "completion")
        XCTAssertEqual(try canonicalJSONObject(plan.body), """
        {
          "max_tokens" : 64,
          "n_predict" : 64,
          "prompt" : "Write one haiku.",
          "return_progress" : true,
          "stream" : false
        }
        """)
    }

    func testChatCompletionRequestBodyFixture() throws {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Mistral-7B-Instruct-Q4_K_M.gguf"))
        let input = LLMInput(.messages([
            ChatMessage(role: "system", content: "Be terse."),
            ChatMessage(role: "user", content: "Hello"),
            ChatMessage(role: "assistant", content: "Hi."),
            ChatMessage(role: "user", content: "Summarize this.")
        ]))

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: false)

        XCTAssertEqual(plan.endpoint, "/v1/chat/completions")
        XCTAssertEqual(plan.requestMode, "chat_completions")
        XCTAssertEqual(try canonicalJSONObject(plan.body), """
        {
          "messages" : [
            {
              "content" : "Be terse.",
              "role" : "system"
            },
            {
              "content" : "Hello",
              "role" : "user"
            },
            {
              "content" : "Hi.",
              "role" : "assistant"
            },
            {
              "content" : "Summarize this.",
              "role" : "user"
            }
          ],
          "model" : "Mistral-7B-Instruct-Q4_K_M.gguf",
          "n_predict" : -1,
          "return_progress" : true,
          "stream" : true,
          "stream_options" : {
            "include_usage" : true
          }
        }
        """)
    }

    func testMultimodalRequestBodyFixture() throws {
        let root = try makeTemporaryDirectory()
        let image = root.appendingPathComponent("fixture.png")
        try Data("image-bytes".utf8).write(to: image)

        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Llava-Q4_K_M.gguf"))
        let input = LLMInput.multimodal(
            text: "Describe the attachment.",
            imagePaths: [image.path]
        )

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: true)

        XCTAssertEqual(plan.endpoint, "/v1/chat/completions")
        XCTAssertEqual(plan.imagePaths, [image.path])
        XCTAssertEqual(try canonicalJSONObject(plan.body), """
        {
          "messages" : [
            {
              "content" : [
                {
                  "text" : "Describe the attachment.",
                  "type" : "text"
                },
                {
                  "image_url" : {
                    "url" : "data:image/png;base64,aW1hZ2UtYnl0ZXM="
                  },
                  "type" : "image_url"
                }
              ],
              "role" : "user"
            }
          ],
          "model" : "Llava-Q4_K_M.gguf",
          "n_predict" : -1,
          "return_progress" : true,
          "stream" : false
        }
        """)
    }

    func testReasoningStructuredOutputAndTokenOptionsRequestBodyFixture() throws {
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

        let client = NoemaLlamaClient(url: weight)
        let input = LLMInput(
            .messages([ChatMessage(role: "user", content: "Return JSON.")]),
            generationOptions: LLMGenerationOptions(
                reasoningEnabled: false,
                maxOutputTokens: 256,
                thinkingBudgetTokens: 0,
                responseFormat: .jsonSchema(
                    name: "answer",
                    schema: [
                        "type": AnyCodable("object"),
                        "required": AnyCodable(["answer"])
                    ]
                )
            )
        )

        let plan = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: false)

        XCTAssertEqual(plan.endpoint, "/v1/chat/completions")
        XCTAssertEqual(plan.requestMode, "chat_completions")
        XCTAssertEqual(try canonicalJSONObject(plan.body), """
        {
          "add_generation_prompt" : true,
          "chat_template_kwargs" : {
            "enable_thinking" : false
          },
          "max_tokens" : 256,
          "messages" : [
            {
              "content" : "Return JSON.",
              "role" : "user"
            }
          ],
          "model" : "Next2.5-Q4_K_M.gguf",
          "n_predict" : 256,
          "response_format" : {
            "json_schema" : {
              "name" : "answer",
              "schema" : {
                "required" : [
                  "answer"
                ],
                "type" : "object"
              },
              "strict" : true
            },
            "type" : "json_schema"
          },
          "return_progress" : true,
          "stream" : true,
          "stream_options" : {
            "include_usage" : true
          },
          "thinking_budget_tokens" : 0
        }
        """)
        XCTAssertNil(plan.body["reasoning_format"])
    }

    private func canonicalJSONObject(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\\/", with: "/")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeBridgeRequestFixtureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
