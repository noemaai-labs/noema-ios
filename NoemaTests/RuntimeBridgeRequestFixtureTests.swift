import Foundation
import XCTest
import NoemaPackages
@testable import Noema

final class RuntimeBridgeRequestFixtureTests: XCTestCase {
    func testSpeculativeTimingsDecodeRollbackAndPerPositionTelemetry() throws {
        let raw = Data(#"""
        {
          "draft_n": 5,
          "draft_n_accepted": 3,
          "draft_rollback_ms": 1.25,
          "draft_accepted_per_position": [3, 2, 1]
        }
        """#.utf8)
        let timings = try JSONDecoder().decode(LoopbackSpeculativeTimings.self, from: raw)
        XCTAssertEqual(timings.draftRollbackMS, 1.25)
        XCTAssertEqual(timings.draftAcceptedPerPosition, [3, 2, 1])
    }

    @MainActor
    func testChatAppliesCurrentLoadedSamplingSettingsToNextLocalRequest() {
        var settings = ModelSettings.default(for: .mlx)
        settings.seed = 73
        settings.temperature = 0.35
        settings.topK = 24
        settings.topP = 0.82
        settings.minP = 0.04
        settings.repetitionPenalty = 1.18
        settings.repeatLastN = 96
        settings.presencePenalty = 0.3
        settings.frequencyPenalty = 0.2
        settings.logitBias = [42: -2]
        settings.promptCacheEnabled = true

        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/live-mlx"),
            loadedFormat: .mlx,
            loadedSettings: settings
        )

        let input = vm.applyingLoadedReasoningPreference(
            to: LLMInput.plain(
                "Hello",
                generationOptions: LLMGenerationOptions(
                    temperature: 0.1,
                    logitBias: [42: 1],
                    promptCache: false
                )
            )
        )
        let options = input.generationOptions

        XCTAssertEqual(options.temperature, 0.1, "explicit request overrides must win")
        XCTAssertEqual(options.seed, 73)
        XCTAssertEqual(options.topK, 24)
        XCTAssertEqual(options.topP, 0.82)
        XCTAssertEqual(options.minP, 0.04)
        XCTAssertEqual(options.repeatPenalty ?? -1, 1.18, accuracy: 1e-6)
        XCTAssertEqual(options.repeatLastN, 96)
        XCTAssertEqual(options.presencePenalty ?? -1, 0.3, accuracy: 1e-6)
        XCTAssertEqual(options.frequencyPenalty ?? -1, 0.2, accuracy: 1e-6)
        XCTAssertEqual(options.logitBias, [42: 1], "explicit request overrides must win")
        XCTAssertEqual(options.promptCache, false, "explicit request overrides must win")
    }

    @MainActor
    func testLiveSidebarSamplingSyncUpdatesOnlyLoadedSamplingFields() {
        let url = URL(fileURLWithPath: "/tmp/live-mlx")
        var loaded = ModelSettings.default(for: .mlx)
        loaded.contextLength = 2_048
        loaded.temperature = 0.7

        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: url,
            loadedFormat: .mlx,
            loadedSettings: loaded
        )
        let model = LocalModel(
            modelID: "fixture/live-mlx",
            name: "live-mlx",
            url: url,
            quant: "MLX",
            architecture: "",
            architectureFamily: "",
            format: .mlx,
            sizeGB: 0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )
        var edited = loaded
        edited.contextLength = 8_192
        edited.temperature = 1.25
        edited.topK = 12

        vm.syncActiveLocalModelSamplingSettingsIfNeeded(model: model, settings: edited)

        XCTAssertEqual(vm.loadedModelSettings?.contextLength, 2_048)
        XCTAssertEqual(vm.loadedModelSettings?.temperature, 1.25)
        XCTAssertEqual(vm.loadedModelSettings?.topK, 12)
    }

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

    func testRequestScopedSamplingOverridesAreIncludedInBody() throws {
        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Relay-Q4_K_M.gguf"))
        let input = LLMInput(
            .messages([ChatMessage(role: "user", content: "Hello")]),
            generationOptions: LLMGenerationOptions(
                maxOutputTokens: 32,
                seed: 42,
                temperature: 0.25,
                topK: 20,
                topP: 0.8,
                minP: 0.05,
                repeatPenalty: 1.15,
                repeatLastN: 128,
                presencePenalty: 0.2,
                frequencyPenalty: 0.1,
                logitBias: [15043: 1, 7: -100],
                promptCache: false
            )
        )

        let body = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: true).body

        XCTAssertEqual(body["seed"] as? Int, 42)
        XCTAssertEqual(body["temperature"] as? Double, 0.25)
        XCTAssertEqual(body["top_k"] as? Int, 20)
        XCTAssertEqual(body["top_p"] as? Double, 0.8)
        XCTAssertEqual(body["min_p"] as? Double, 0.05)
        XCTAssertEqual(body["repeat_penalty"] as? Double, 1.15)
        XCTAssertEqual(body["repeat_last_n"] as? Int, 128)
        XCTAssertEqual(body["presence_penalty"] as? Double, 0.2)
        XCTAssertEqual(body["frequency_penalty"] as? Double, 0.1)
        XCTAssertEqual(body["logit_bias"] as? [String: Double], ["15043": 1, "7": -100])
        XCTAssertEqual(body["cache_prompt"] as? Bool, false)
        XCTAssertEqual(body["n_predict"] as? Int, 32)
        XCTAssertEqual(body["max_tokens"] as? Int, 32)
    }

    func testPagedLaunchAlwaysRequestsSlotPromptReuse() throws {
        // Paged (Overfit) launches disable the checkpoint prompt cache in the
        // StartConfiguration (cacheRamMiB 0 / ctxCheckpoints 0), and the
        // options seed mirrors settings.promptCacheEnabled — false under
        // several presets. Per-request cache_prompt governs the separate,
        // free single-slot KV prefix reuse; without it every paged turn
        // re-prefills the whole transcript (minutes of TTFT on an overfit
        // model). The client must therefore pin cache_prompt=true for paged
        // launches, overriding the settings-derived option.
        let pagedConfiguration = LlamaServerBridge.StartConfiguration(
            ggufPath: "/tmp/Overfit-MoE-Q4_K_M.gguf",
            contextSize: 4096,
            threads: 2,
            threadsBatch: 2,
            batchSize: 512,
            ubatchSize: 1,
            parallelSlots: 1,
            cacheRamMiB: 0,
            ctxCheckpoints: 0,
            pagedMode: .streamed,
            pagedManifestPath: "/tmp/Overfit-MoE.noema-paged/manifest.json"
        )
        let client = NoemaLlamaClient(
            url: URL(fileURLWithPath: "/tmp/Overfit-MoE-Q4_K_M.gguf"),
            serverConfiguration: pagedConfiguration
        )
        let input = LLMInput(
            .messages([ChatMessage(role: "user", content: "Hello")]),
            generationOptions: LLMGenerationOptions(promptCache: false)
        )

        let body = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: true).body
        XCTAssertEqual(body["cache_prompt"] as? Bool, true,
                       "paged launches must request slot-KV prefix reuse regardless of the checkpoint-cache setting")

        let plainBody = client.buildLoopbackRequestPlan(
            for: LLMInput.plain("Hello", generationOptions: LLMGenerationOptions(promptCache: false)),
            forceNonStreaming: true
        ).body
        XCTAssertEqual(plainBody["cache_prompt"] as? Bool, true)
    }

    func testPagedAuxiliaryRequestDoesNotReuseConversationSlot() throws {
        let pagedConfiguration = LlamaServerBridge.StartConfiguration(
            ggufPath: "/tmp/Overfit-MoE-Q4_K_M.gguf",
            contextSize: 4096,
            threads: 2,
            threadsBatch: 2,
            batchSize: 512,
            ubatchSize: 1,
            parallelSlots: 1,
            cacheRamMiB: 0,
            ctxCheckpoints: 0,
            pagedMode: .streamed,
            pagedManifestPath: "/tmp/Overfit-MoE.noema-paged/manifest.json"
        )
        let client = NoemaLlamaClient(
            url: URL(fileURLWithPath: "/tmp/Overfit-MoE-Q4_K_M.gguf"),
            serverConfiguration: pagedConfiguration
        )
        let input = LLMInput(
            .messages([ChatMessage(role: "user", content: "Summarize older turns")]),
            generationOptions: LLMGenerationOptions(
                promptCache: true,
                requestPurpose: .auxiliary
            )
        )

        let body = client.buildLoopbackRequestPlan(for: input, forceNonStreaming: true).body

        XCTAssertEqual(body["cache_prompt"] as? Bool, false,
                       "an auxiliary recap must not reuse or publish the paged chat prefix as its own cache state")
    }

    func testPagedInstallPinsSlotPromptReuseWithoutServerConfiguration() throws {
        // The main chat path was measured sending cache_prompt=false against a
        // live paged server: the pin must not depend on this client instance
        // carrying a StartConfiguration copy. With serverConfiguration nil the
        // client falls back to the install shape itself (an enclosing
        // .noema-paged package with a manifest) and still pins slot reuse.
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-fixture-\(UUID().uuidString).noema-paged")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        try Data("{}".utf8).write(
            to: package.appendingPathComponent(NoemaPagedPackageManifest.manifestFileName))
        let modelURL = package.appendingPathComponent("resident.gguf")

        let client = NoemaLlamaClient(url: modelURL)
        let body = client.buildLoopbackRequestPlan(
            for: LLMInput(
                .messages([ChatMessage(role: "user", content: "Hello")]),
                generationOptions: LLMGenerationOptions(promptCache: false)
            ),
            forceNonStreaming: true
        ).body

        XCTAssertEqual(body["cache_prompt"] as? Bool, true,
                       "a paged install must pin cache_prompt=true even when the client has no StartConfiguration")
    }

    func testToolsPayloadIsDeterministicAcrossIdenticalRequestBuilds() throws {
        // The server parses request JSON as nlohmann::ordered_json, so both the
        // tools ARRAY order and every object's KEY order flow byte-for-byte
        // into the Jinja-rendered prompt. Any drift between two builds of the
        // same request breaks the slot-KV common prefix right at the tools
        // section — the measured 304 s turn-2 re-prefill. Two identical
        // requests must therefore serialize byte-identically, with the tools
        // name-sorted regardless of the caller-supplied order.
        func makeSpec(_ name: String) -> ToolSpec {
            ToolSpec(
                name: name,
                description: "Fixture tool \(name)",
                parameters: .init(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "What to look up"),
                        "count": .init(type: "integer", description: "How many results",
                                       maximum: 5, minimum: 1),
                    ],
                    required: ["query"]
                )
            )
        }
        let specs = [makeSpec("noema.web.retrieve"),
                     makeSpec("noema.math.calculate"),
                     makeSpec("noema.python.execute")]

        let client = NoemaLlamaClient(url: URL(fileURLWithPath: "/tmp/Tools-Q4_K_M.gguf"))
        func canonicalBody(toolOrder: [ToolSpec]) throws -> (names: [String], bytes: Data) {
            let body = client.buildLoopbackRequestPlan(
                for: LLMInput(
                    .messages([ChatMessage(role: "user", content: "Hello")]),
                    generationOptions: LLMGenerationOptions(tools: toolOrder)
                ),
                forceNonStreaming: true
            ).body
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            // Same serialization the client puts on the wire (.sortedKeys).
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return (names, bytes)
        }

        let first = try canonicalBody(toolOrder: specs.reversed())
        let second = try canonicalBody(toolOrder: specs.shuffled())

        XCTAssertEqual(first.names,
                       ["noema.math.calculate", "noema.python.execute", "noema.web.retrieve"],
                       "tools must be name-sorted on the wire, not registry/caller order")
        XCTAssertEqual(first.bytes, second.bytes,
                       "two identical-history requests must produce byte-identical bodies")
    }

    func testLoopbackOutputCaptureModes() {
        var none = LoopbackOutputCapture(policy: .none)
        none.append("abc")
        XCTAssertEqual(none.result, LoopbackGenerationResult(text: nil, characterCount: 0))

        var count = LoopbackOutputCapture(policy: .characterCount)
        count.append("abc")
        count.append("🙂")
        XCTAssertEqual(count.result, LoopbackGenerationResult(text: nil, characterCount: 4))

        var full = LoopbackOutputCapture(policy: .fullText)
        full.append("abc")
        full.append("🙂")
        XCTAssertEqual(full.result, LoopbackGenerationResult(text: "abc🙂", characterCount: 4))
    }

    func testStartConfigurationNormalizesInvalidOptionalValues() {
        let configuration = LlamaServerBridge.StartConfiguration(
            ggufPath: "/tmp/model.gguf",
            contextSize: 0,
            threads: 0,
            threadsBatch: 0,
            batchSize: 0,
            ubatchSize: 99,
            unifiedKVCache: true,
            parallelSlots: 0,
            moeExpertCount: 0,
            yarnScale: .nan,
            yarnOriginalContext: 0,
            yarnBetaFast: -.infinity,
            yarnBetaSlow: -1
        )

        XCTAssertEqual(configuration.contextSize, 1)
        XCTAssertEqual(configuration.threads, 1)
        XCTAssertEqual(configuration.threadsBatch, 1)
        XCTAssertEqual(configuration.batchSize, 1)
        XCTAssertEqual(configuration.ubatchSize, 1)
        XCTAssertEqual(configuration.parallelSlots, 1)
        XCTAssertNil(configuration.moeExpertCount)
        XCTAssertNil(configuration.yarnScale)
        XCTAssertNil(configuration.yarnOriginalContext)
        XCTAssertNil(configuration.yarnBetaFast)
        XCTAssertNil(configuration.yarnBetaSlow)
        XCTAssertTrue(configuration.unifiedKVCache)
    }

    @MainActor
    func testUnifiedKVCachePersistsAndMapsToTypedServerConfiguration() throws {
        var settings = ModelSettings.default(for: .gguf)
        settings.unifiedKVCache = true
        let decoded = try JSONDecoder().decode(
            ModelSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decoded.unifiedKVCache)

        let configuration = GGUFServerConfigurationResolver.resolve(
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            settings: decoded,
            mmprojPath: nil,
            contextShiftEnabled: true
        )
        XCTAssertTrue(configuration.unifiedKVCache)
    }

    @MainActor
    func testUnifiedKVCacheDefaultsOnAcrossSettingsRuntimeAndSizing() throws {
        let settings = ModelSettings.default(for: .gguf)
        XCTAssertTrue(settings.unifiedKVCache)

        let legacySettings = try JSONDecoder().decode(
            ModelSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(legacySettings.unifiedKVCache)

        let explicitOptOut = try JSONDecoder().decode(
            ModelSettings.self,
            from: Data(#"{"unifiedKVCache":false}"#.utf8)
        )
        XCTAssertFalse(explicitOptOut.unifiedKVCache)

        let configuration = TemplateDrivenModelSupport.loopbackStartConfiguration(
            ggufPath: "/tmp/model.gguf",
            mmprojPath: nil
        )
        XCTAssertTrue(configuration.unifiedKVCache)
        XCTAssertTrue(
            ModelRAMAdvisor.RuntimeConfiguration.resolved(from: configuration).unifiedKVCache
        )
    }

    func testPromptCacheOffDisablesBothServerCaches() {
        let configuration = TemplateDrivenModelSupport.loopbackStartConfiguration(
            modelID: "google/gemma-4-31B-it",
            ggufPath: "/tmp/gemma-4.gguf",
            mmprojPath: nil,
            promptCacheEnabled: false
        )

        XCTAssertEqual(configuration.cacheRamMiB, 0)
        XCTAssertEqual(configuration.ctxCheckpoints, 0)
    }

    func testLegacyRopeFrequencyFieldsDecodeIntoYaRNBetaFields() throws {
        let data = Data("""
        {
          "factor": 2.0,
          "originalContext": 4096,
          "lowFrequency": 32.0,
          "highFrequency": 1.0
        }
        """.utf8)
        let rope = try JSONDecoder().decode(ModelSettings.RopeScalingSettings.self, from: data)

        XCTAssertEqual(rope.betaFast, 32)
        XCTAssertEqual(rope.betaSlow, 1)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rope)) as? [String: Any])
        XCTAssertEqual(encoded["betaFast"] as? Double, 32)
        XCTAssertEqual(encoded["betaSlow"] as? Double, 1)
        XCTAssertNil(encoded["lowFrequency"])
        XCTAssertNil(encoded["highFrequency"])
    }

    func testLegacyPromptCacheFileFieldsDecodeButAreNoLongerPersisted() throws {
        var settings = ModelSettings()
        settings.promptCacheEnabled = true
        settings.promptCachePath = "/tmp/legacy-cache.bin"
        settings.promptCacheAll = true

        let encodedData = try JSONEncoder().encode(settings)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        XCTAssertEqual(encoded["promptCacheEnabled"] as? Bool, true)
        XCTAssertNil(encoded["promptCachePath"])
        XCTAssertNil(encoded["promptCacheAll"])

        var legacy = encoded
        legacy["promptCachePath"] = "/tmp/legacy-cache.bin"
        legacy["promptCacheAll"] = true
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(ModelSettings.self, from: legacyData)
        XCTAssertEqual(decoded.promptCachePath, "/tmp/legacy-cache.bin")
        XCTAssertTrue(decoded.promptCacheAll)
    }

    func testBoundedLoopbackStreamPreservesOneHundredThousandChunks() async throws {
        let stats = BoundedStreamStats()
        let pair = AsyncThrowingStream<String, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(BoundedLoopbackStreamEmitter.capacity)
        )
        let producer = Task {
            do {
                for index in 0..<100_000 {
                    try await BoundedLoopbackStreamEmitter.yield(String(index), to: pair.continuation)
                    await stats.didProduce()
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }

        var expected = 0
        for try await chunk in pair.stream {
            XCTAssertEqual(chunk, String(expected))
            expected += 1
            await stats.didConsume()
            if expected.isMultiple(of: 64) {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        await producer.value

        XCTAssertEqual(expected, 100_000)
        let maximumLead = await stats.maximumLead()
        XCTAssertLessThanOrEqual(maximumLead, BoundedLoopbackStreamEmitter.capacity + 1)
    }

    func testBoundedLoopbackEmitterUnblocksAfterTermination() async {
        let pair = AsyncThrowingStream<String, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(BoundedLoopbackStreamEmitter.capacity)
        )
        pair.continuation.finish()
        do {
            try await BoundedLoopbackStreamEmitter.yield("late", to: pair.continuation)
            XCTFail("terminated streams must reject producer output")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
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
          "speculative" : false,
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

private actor BoundedStreamStats {
    private var produced = 0
    private var consumed = 0
    private var maxLead = 0

    func didProduce() {
        produced += 1
        maxLead = max(maxLead, produced - consumed)
    }

    func didConsume() {
        consumed += 1
    }

    func maximumLead() -> Int { maxLead }
}
