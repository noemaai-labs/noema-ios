import Foundation
import XCTest
#if canImport(CoreML)
import CoreML
#endif
import Generation
@testable import Noema

final class CMLSupportTests: XCTestCase {
    func testModelFormatCompatibilityDecodesLegacyAndCMLValues() throws {
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(ModelFormat.self, from: Data(#""ANE""#.utf8)), .ane)
        XCTAssertEqual(try decoder.decode(ModelFormat.self, from: Data(#""APPLE""#.utf8)), .ane)
        XCTAssertEqual(try decoder.decode(ModelFormat.self, from: Data(#""CML""#.utf8)), .ane)
        XCTAssertEqual(ModelFormat.ane.displayName, "CML")
    }

    func testANEModelSettingsLoadsPromptTemplateFromModelRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let template = "<|im_start|>system\nYou are Qwen3<|im_end|>\n"
        let payload: [String: Any] = ["chat_template": template]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: root.appendingPathComponent("tokenizer_config.json"))

        let model = LocalModel(
            modelID: "Qwen/Qwen3-0.6B",
            name: "Qwen3-0.6B",
            url: root,
            quant: "CML",
            architecture: "qwen3",
            architectureFamily: "qwen",
            format: .ane,
            sizeGB: 0.6,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )

        let settings = ModelSettings.fromConfig(for: model)
        XCTAssertEqual(settings.promptTemplate, template)
    }

    func testArchitectureTemplatesApplyToQwen3ANE() {
        let model = LocalModel(
            modelID: "Qwen/Qwen3-0.6B",
            name: "Qwen3-0.6B",
            url: URL(fileURLWithPath: "/tmp/Qwen3-0.6B"),
            quant: "CML",
            architecture: "qwen3",
            architectureFamily: "qwen",
            format: .ane,
            sizeGB: 0.6,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )

        XCTAssertEqual(ArchitectureTemplates.template(for: model), ArchitectureTemplates.Templates.qwen3)
    }

    func testANEModelSettingsDefaultToNeuralEngine() {
        let settings = ModelSettings.default(for: .ane)
        XCTAssertEqual(settings.processingUnitConfiguration, .cpuAndNeuralEngine)
    }

    func testCMLFixedContextParsesCtxTokenFromModelTitle() {
        let model = LocalModel(
            modelID: "anemll/sample-model",
            name: "Qwen3-CTX8192",
            url: URL(fileURLWithPath: "/tmp/Qwen3-CTX8192.mlmodelc"),
            quant: "CML",
            architecture: "qwen3",
            architectureFamily: "qwen",
            format: .ane,
            sizeGB: 1.0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )

        XCTAssertEqual(ModelSettings.fixedContextLength(for: model), 8192)
        XCTAssertEqual(ModelSettings(contextLength: 2048).normalizedForLocalModel(model).contextLength, 8192)
    }

    func testCMLFixedContextNormalizationPreservesExistingValueWithoutCtxToken() {
        let model = LocalModel(
            modelID: "anemll/sample-model",
            name: "Qwen3",
            url: URL(fileURLWithPath: "/tmp/Qwen3.mlmodelc"),
            quant: "CML",
            architecture: "qwen3",
            architectureFamily: "qwen",
            format: .ane,
            sizeGB: 1.0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )

        let settings = ModelSettings(contextLength: 3072)
        XCTAssertNil(ModelSettings.fixedContextLength(for: model))
        XCTAssertEqual(settings.normalizedForLocalModel(model).contextLength, 3072)
    }

    #if canImport(CoreML) && (os(iOS) || os(visionOS))
    @available(iOS 18.0, visionOS 2.0, *)
    func testPlainCMLPromptDoesNotPrependSystemText() {
        let resolved = CoreMLLLMClient.resolvedPromptText(
            for: .plain("<|im_start|>system\nkeep me<|im_end|>\n<|im_start|>user\nHi<|im_end|>"),
            systemPrompt: "You are Noema"
        )

        XCTAssertEqual(resolved, "<|im_start|>system\nkeep me<|im_end|>\n<|im_start|>user\nHi<|im_end|>")
        XCTAssertFalse(resolved.hasPrefix("System: You are Noema"))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testMessageBasedCMLPromptAddsSystemTextOnlyOnce() {
        let resolved = CoreMLLLMClient.resolvedPromptText(
            for: LLMInput(.messages([ChatMessage(role: "user", content: "Hi")])),
            systemPrompt: "You are Noema"
        )

        XCTAssertTrue(resolved.hasPrefix("System: You are Noema"))
        XCTAssertEqual(resolved.components(separatedBy: "You are Noema").count - 1, 1)

        let explicitSystem = CoreMLLLMClient.resolvedPromptText(
            for: LLMInput(.messages([
                ChatMessage(role: "system", content: "You are Noema"),
                ChatMessage(role: "user", content: "Hi")
            ])),
            systemPrompt: "You are Noema"
        )

        XCTAssertEqual(explicitSystem.components(separatedBy: "You are Noema").count - 1, 1)
        XCTAssertFalse(explicitSystem.hasPrefix("System: You are Noema\n\nSystem: You are Noema"))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testSharedCMLGenerationEngineStreamsOnlyGeneratedSuffix() async throws {
        var partials: [String] = []

        let output = try await CoreMLGenerationEngine.generate(
            promptTokens: [101, 102],
            config: GenerationConfig(maxNewTokens: 4),
            bosTokenId: nil,
            eosTokenId: 9,
            decode: { tokens in
                tokens.map {
                    switch $0 {
                    case 101: return "PROMPT"
                    case 102: return " INPUT"
                    case 4: return "A"
                    case 5: return "B"
                    default: return "?"
                    }
                }.joined()
            },
            resetState: {},
            predictor: { tokens, _ in
                let count = await tokens.shapedArray(of: Int32.self).scalars.count
                switch count {
                case 2:
                    return Self.makeScores(bestToken: 4)
                case 3:
                    return Self.makeScores(bestToken: 5)
                default:
                    return Self.makeScores(bestToken: 9)
                }
            },
            onPartialText: { partials.append($0) }
        )

        XCTAssertEqual(partials, ["A", "AB"])
        XCTAssertEqual(output, "AB")
        XCTAssertFalse(partials.contains(where: { $0.contains("PROMPT") }))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testSharedCMLGenerationEnginePropagatesCancellation() async {
        await XCTAssertThrowsErrorAsync(
            try await CoreMLGenerationEngine.generate(
                promptTokens: [101],
                config: GenerationConfig(maxNewTokens: 2),
                bosTokenId: nil,
                eosTokenId: 9,
                decode: { _ in "" },
                resetState: {},
                predictor: { _, _ in
                    throw CancellationError()
                },
                onPartialText: { _ in }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testSharedCMLGenerationEnginePropagatesPredictionErrors() async {
        let expected = NSError(domain: "NoemaTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "prediction failed"])

        await XCTAssertThrowsErrorAsync(
            try await CoreMLGenerationEngine.generate(
                promptTokens: [101],
                config: GenerationConfig(maxNewTokens: 2),
                bosTokenId: nil,
                eosTokenId: 9,
                decode: { _ in "" },
                resetState: {},
                predictor: { _, _ in
                    throw expected
                },
                onPartialText: { _ in }
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, expected.domain)
            XCTAssertEqual(nsError.code, expected.code)
        }
    }

    func testPromptMetadataSummaryRedactsPromptAndSystemContent() {
        let promptSummary = ChatVM.promptMetadataSummary(
            prompt: "very secret prompt body",
            stops: ["<stop>"],
            format: .ane,
            kind: .qwen,
            hasTemplate: true
        )
        let systemSummary = ChatVM.systemPromptMetadataSummary("very secret system body")

        XCTAssertFalse(promptSummary.contains("very secret prompt body"))
        XCTAssertFalse(systemSummary.contains("very secret system body"))
        XCTAssertTrue(promptSummary.contains("len="))
        XCTAssertTrue(promptSummary.contains("hash="))
        XCTAssertTrue(systemSummary.contains("len="))
        XCTAssertTrue(systemSummary.contains("hash="))
    }

    func testCancelledAssistantPlaceholderIsRemovedWhenEmpty() {
        let messages: [ChatVM.Msg] = [
            .init(role: "🧑‍💻", text: "Hi"),
            .init(role: "🤖", text: "", streaming: true)
        ]

        let cleaned = ChatVM.removingCancelledAssistantPlaceholder(from: messages)
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.last?.role, "🧑‍💻")
    }

    func testCancelledAssistantPlaceholderIsKeptWhenPartialTextExists() {
        let messages: [ChatVM.Msg] = [
            .init(role: "🧑‍💻", text: "Hi"),
            .init(role: "🤖", text: "Hello", streaming: true)
        ]

        let cleaned = ChatVM.removingCancelledAssistantPlaceholder(from: messages)
        XCTAssertEqual(cleaned, messages)
    }

    @MainActor
    func testHasActiveChatModelIsFalseWithoutLoadedState() {
        let (manager, filename) = makeIsolatedModelManager()
        defer { removeInstalledStore(named: filename) }

        let vm = ChatVM()
        vm.modelManager = manager
        vm.setLoadedStateForTesting(modelLoaded: false, loadedURL: nil, loadedFormat: nil)

        XCTAssertFalse(vm.hasActiveChatModel)
    }

    @MainActor
    func testHasActiveChatModelUsesLoadedModelFromManager() {
        let (manager, filename) = makeIsolatedModelManager()
        defer { removeInstalledStore(named: filename) }

        let vm = ChatVM()
        vm.modelManager = manager
        vm.setLoadedStateForTesting(modelLoaded: false, loadedURL: nil, loadedFormat: nil)
        manager.loadedModel = makeTestLocalModel()

        XCTAssertTrue(vm.hasActiveChatModel)
    }

    @MainActor
    func testHasActiveChatModelUsesActiveRemoteSession() {
        let (manager, filename) = makeIsolatedModelManager()
        defer { removeInstalledStore(named: filename) }

        let vm = ChatVM()
        vm.modelManager = manager
        vm.setLoadedStateForTesting(modelLoaded: false, loadedURL: nil, loadedFormat: nil)
        manager.activeRemoteSession = ActiveRemoteSession(
            backendID: UUID(),
            backendName: "Test Backend",
            modelID: "test/model",
            modelName: "Test Model",
            endpointType: .openAI,
            transport: .direct,
            streamingEnabled: true
        )

        XCTAssertTrue(vm.hasActiveChatModel)
    }

    @MainActor
    func testHasActiveChatModelUsesLoadedURLFallback() {
        let (manager, filename) = makeIsolatedModelManager()
        defer { removeInstalledStore(named: filename) }

        let vm = ChatVM()
        vm.modelManager = manager
        vm.setLoadedStateForTesting(
            modelLoaded: false,
            loadedURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).gguf"),
            loadedFormat: nil
        )

        XCTAssertTrue(vm.hasActiveChatModel)
    }

    @MainActor
    func testHasActiveChatModelUsesLoadedFormatFallback() {
        let (manager, filename) = makeIsolatedModelManager()
        defer { removeInstalledStore(named: filename) }

        let vm = ChatVM()
        vm.modelManager = manager
        vm.setLoadedStateForTesting(modelLoaded: false, loadedURL: nil, loadedFormat: .gguf)

        XCTAssertTrue(vm.hasActiveChatModel)
    }

    @MainActor
    func testHasActiveChatModelReturnsFalseAfterClearingAllSources() {
        let (manager, filename) = makeIsolatedModelManager()
        defer { removeInstalledStore(named: filename) }

        let vm = ChatVM()
        vm.modelManager = manager
        manager.loadedModel = makeTestLocalModel()
        manager.activeRemoteSession = ActiveRemoteSession(
            backendID: UUID(),
            backendName: "Test Backend",
            modelID: "test/model",
            modelName: "Test Model",
            endpointType: .openAI,
            transport: .direct,
            streamingEnabled: true
        )
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).gguf"),
            loadedFormat: .gguf
        )

        manager.loadedModel = nil
        manager.activeRemoteSession = nil
        vm.setLoadedStateForTesting(modelLoaded: false, loadedURL: nil, loadedFormat: nil)

        XCTAssertFalse(vm.hasActiveChatModel)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testMetadataClassificationDetectsStatefulCausalLayout() throws {
        let metadata = CoreMLArtifactMetadata(
            inputSchema: [
                CoreMLArtifactFeature(name: "input_ids", dataType: "Int32"),
                CoreMLArtifactFeature(name: "causal_mask", dataType: "Float16")
            ],
            outputSchema: [
                CoreMLArtifactFeature(name: "logits", dataType: "Float16")
            ],
            stateSchema: [
                CoreMLArtifactFeature(name: "key_cache", dataType: "Float16"),
                CoreMLArtifactFeature(name: "value_cache", dataType: "Float16")
            ],
            generatedClassName: "Qwen3_0_6B"
        )

        XCTAssertEqual(ANEModelResolver.classify(metadata: metadata), .statefulCausalLM)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testMetadataClassificationRoutesExactTransformersNamesToTransformersRuntime() throws {
        let stateless = CoreMLArtifactMetadata(
            inputSchema: [CoreMLArtifactFeature(name: "inputIds", dataType: "Int32")],
            outputSchema: [CoreMLArtifactFeature(name: "logits", dataType: "Float16")]
        )
        XCTAssertEqual(ANEModelResolver.classify(metadata: stateless), .transformersLanguageModel)

        // camelCase stateful with the exact swift-transformers names stays on
        // that runtime (it supports keyCache/valueCache MLState natively).
        let stateful = CoreMLArtifactMetadata(
            inputSchema: [
                CoreMLArtifactFeature(name: "inputIds", dataType: "Int32"),
                CoreMLArtifactFeature(name: "causalMask", dataType: "Float16")
            ],
            outputSchema: [CoreMLArtifactFeature(name: "logits", dataType: "Float16")],
            stateSchema: [
                CoreMLArtifactFeature(name: "keyCache", dataType: "Float16"),
                CoreMLArtifactFeature(name: "valueCache", dataType: "Float16")
            ]
        )
        XCTAssertEqual(ANEModelResolver.classify(metadata: stateful), .transformersLanguageModel)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testMetadataClassificationDoesNotCrashRouteStatefulModelsWithoutInputIds() throws {
        // keyCache/valueCache states but no exact "inputIds" input: routing this
        // to swift-transformers would force-unwrap-crash. It must resolve to
        // Noema's own stateful runtime via role aliases instead.
        let metadata = CoreMLArtifactMetadata(
            inputSchema: [
                CoreMLArtifactFeature(name: "tokens", dataType: "Int32"),
                CoreMLArtifactFeature(name: "attention_mask", dataType: "Float16")
            ],
            outputSchema: [CoreMLArtifactFeature(name: "output_logits", dataType: "Float16")],
            stateSchema: [
                CoreMLArtifactFeature(name: "keyCache", dataType: "Float16"),
                CoreMLArtifactFeature(name: "valueCache", dataType: "Float16")
            ]
        )

        XCTAssertEqual(ANEModelResolver.classify(metadata: metadata), .statefulCausalLM)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testMetadataClassificationResolvesAliasAndAutoNamedFeatures() throws {
        // coremltools auto-named logits output plus snake-case KV states.
        let metadata = CoreMLArtifactMetadata(
            inputSchema: [
                CoreMLArtifactFeature(name: "input_ids", dataType: "Int32"),
                CoreMLArtifactFeature(name: "causal_mask", dataType: "Float16")
            ],
            outputSchema: [CoreMLArtifactFeature(name: "var_546", dataType: "Float16")],
            stateSchema: [
                CoreMLArtifactFeature(name: "key_cache", dataType: "Float16"),
                CoreMLArtifactFeature(name: "value_cache", dataType: "Float16")
            ]
        )

        XCTAssertEqual(ANEModelResolver.classify(metadata: metadata), .statefulCausalLM)

        let roles = CoreMLRoleResolver.resolve(metadata: metadata)
        XCTAssertEqual(roles.tokenInput, "input_ids")
        XCTAssertEqual(roles.maskInput, "causal_mask")
        XCTAssertEqual(roles.logitsOutput, "var_546")
        XCTAssertEqual(roles.keyCacheState, "key_cache")
        XCTAssertEqual(roles.valueCacheState, "value_cache")
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testMetadataClassificationRejectsAmbiguousLayouts() throws {
        // Two integer inputs and no recognizable names: token role is ambiguous.
        let metadata = CoreMLArtifactMetadata(
            inputSchema: [
                CoreMLArtifactFeature(name: "alpha", dataType: "Int32"),
                CoreMLArtifactFeature(name: "beta", dataType: "Int32")
            ],
            outputSchema: [CoreMLArtifactFeature(name: "logits", dataType: "Float16")],
            stateSchema: [
                CoreMLArtifactFeature(name: "key_cache", dataType: "Float16"),
                CoreMLArtifactFeature(name: "value_cache", dataType: "Float16")
            ]
        )

        XCTAssertEqual(ANEModelResolver.classify(metadata: metadata), .unknown)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractAcceptsFixedSingleTokenInputWithMaskWidthContext() throws {
        let contract = try makeValidStatefulCMLContract(
            inputDimensions: [.fixed(1), .fixed(1)],
            maskDimensions: [.fixed(1), .fixed(1), .fixed(1), .fixed(2048)]
        )

        XCTAssertEqual(contract.contextLength, 2048)
        XCTAssertEqual(contract.effectivePromptTokenLimit, 2047)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractDerivesContextLengthFromKeyCacheWhenMaskless() throws {
        let contract = try makeValidStatefulCMLContract(
            includeMask: false,
            inputDimensions: [.fixed(1), .fixed(1)],
            keyCacheState: StatefulCMLStateSpec(
                name: "key_cache",
                dataType: .float16,
                bufferShape: [1, 8, 4096, 64]
            )
        )

        XCTAssertEqual(contract.contextLength, 4096)
        XCTAssertNil(contract.causalMask)
        XCTAssertNil(contract.maskLayout)
        XCTAssertTrue(contract.summary.contains("causal_mask=<none>"))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractPrefersMetadataContextLength() throws {
        let contract = try makeValidStatefulCMLContract(
            includeMask: false,
            inputDimensions: [.fixed(1), .fixed(1)],
            metadata: CoreMLArtifactMetadata(
                generatedClassName: "Qwen3_0_6B",
                userDefinedMetadata: ["context_length": "1024"]
            )
        )

        XCTAssertEqual(contract.contextLength, 1024)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractRejectsFixedMultiTokenChunkInput() throws {
        XCTAssertThrowsError(
            try makeValidStatefulCMLContract(inputDimensions: [.fixed(1), .fixed(64)])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("fixed prompt-chunk length"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractRejectsFixedSingleTokenInputWithoutContextSource() throws {
        XCTAssertThrowsError(
            try makeValidStatefulCMLContract(
                includeMask: false,
                inputDimensions: [.fixed(1), .fixed(1)]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Could not determine the context length"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractAcceptsValidSnakeCaseSchema() throws {
        let contract = try makeValidStatefulCMLContract(contextLength: 2048)

        XCTAssertEqual(contract.contextLength, 2048)
        XCTAssertEqual(contract.effectivePromptTokenLimit, 2047)
        XCTAssertEqual(contract.effectiveSequenceTokenLimit, 2048)
        XCTAssertEqual(contract.inputIDs.rank, 2)
        XCTAssertEqual(contract.logits.rank, 3)
        XCTAssertTrue(contract.summary.contains("context=2048"))
        XCTAssertTrue(contract.summary.contains("prefillMode=compat-single-query"))
        XCTAssertTrue(contract.summary.contains("maskWidthFormula=tokens"))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractRejectsMissingKVStates() {
        XCTAssertThrowsError(try makeValidStatefulCMLContract(hasKeyCache: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("key_cache"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractRejectsNonIntegerInputIDs() {
        XCTAssertThrowsError(try makeValidStatefulCMLContract(inputDataType: .float16)) { error in
            XCTAssertTrue(error.localizedDescription.contains("input_ids"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractRejectsNonRankThreeLogits() {
        let invalidLogits = [
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(32000)
        ]

        XCTAssertThrowsError(try makeValidStatefulCMLContract(logitsDimensions: invalidLogits)) { error in
            XCTAssertTrue(error.localizedDescription.contains("logits"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractDerivesContextLengthFromSequenceDimension() throws {
        let contract = try makeValidStatefulCMLContract(contextLength: 4096)

        XCTAssertEqual(contract.inputIDs.minSequenceLength, 1)
        XCTAssertEqual(contract.inputIDs.maxSequenceLength, 4096)
        XCTAssertEqual(contract.contextLength, 4096)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLMaskBuilderAvoidsTriangularPrefillShape() throws {
        let contract = try makeValidStatefulCMLContract(contextLength: 2048)
        let tokenCount = 32
        let mask = try contract.makeCausalMask(
            logicalWidth: contract.maskWidth(for: tokenCount),
            logicalQueryLength: contract.maskQueryLength(isPrefill: true)
        )
        let shape = mask.shape.map(\.intValue)

        XCTAssertEqual(shape, [1, 1, 1, 32])
        XCTAssertNotEqual(shape, [1, 1, 32, 32])
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLMaskBuilderUsesSingleTokenWidthForFirstPrefillStep() throws {
        let contract = try makeValidStatefulCMLContract(contextLength: 2048)
        let mask = try contract.makeCausalMask(
            logicalWidth: contract.maskWidth(for: 1),
            logicalQueryLength: contract.maskQueryLength(isPrefill: true)
        )

        XCTAssertEqual(contract.maskWidth(for: 1), 1)
        XCTAssertEqual(mask.shape.map(\.intValue), [1, 1, 1, 1])
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLMaskBuilderUsesFixedWidthWhenRequired() throws {
        let fixedWidthMask = [
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(2048)
        ]
        let contract = try makeValidStatefulCMLContract(
            contextLength: 2048,
            maskDimensions: fixedWidthMask
        )
        let mask = try contract.makeCausalMask(
            logicalWidth: contract.maskWidth(for: 32),
            logicalQueryLength: contract.maskQueryLength(isPrefill: true)
        )

        XCTAssertEqual(mask.shape.map(\.intValue), [1, 1, 1, 2048])
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLMaskBuilderMasksPaddedFuturePositionsForFixedWidthLayouts() throws {
        let fixedWidthMask = [
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(8)
        ]
        let contract = try makeValidStatefulCMLContract(
            contextLength: 8,
            maskDimensions: fixedWidthMask
        )
        let mask = try contract.makeCausalMask(logicalWidth: 3, logicalQueryLength: 1)
        let scalars = MLShapedArray<Float16>(mask).scalars

        XCTAssertEqual(Array(scalars.prefix(3)), [Float16.zero, .zero, .zero])
        XCTAssertEqual(Array(scalars.suffix(5)), Array(repeating: -Float16.greatestFiniteMagnitude, count: 5))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractRejectsPromptsBeyondValidatedContextLength() throws {
        let contract = try makeValidStatefulCMLContract(contextLength: 64)

        XCTAssertThrowsError(try contract.validateTokenCount(64)) { error in
            XCTAssertTrue(error.localizedDescription.contains("effective prompt limit 63"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLContractAllowsDynamicLogitsShape() throws {
        let contract = try makeValidStatefulCMLContract(
            contextLength: 2048,
            logitsDimensions: []
        )

        XCTAssertFalse(contract.logits.hasKnownShape)
        XCTAssertTrue(contract.summary.contains("logits=Float16[dynamic]"))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLMaskBuilderAllowsDynamicQueryAxis() throws {
        let dynamicQueryMask = [
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension.fixed(1),
            StatefulCMLDimension(minValue: 1, maxValue: 2048),
            StatefulCMLDimension(minValue: 1, maxValue: 2048)
        ]
        let contract = try makeValidStatefulCMLContract(
            contextLength: 2048,
            maskDimensions: dynamicQueryMask
        )

        let prefillMask = try contract.makeCausalMask(
            logicalWidth: contract.maskWidth(for: 32),
            logicalQueryLength: contract.maskQueryLength(isPrefill: true)
        )
        let extendMask = try contract.makeCausalMask(
            logicalWidth: contract.maskWidth(for: 33),
            logicalQueryLength: contract.maskQueryLength(isPrefill: false)
        )

        XCTAssertEqual(prefillMask.shape.map(\.intValue), [1, 1, 1, 32])
        XCTAssertEqual(extendMask.shape.map(\.intValue), [1, 1, 1, 33])
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLDimensionFromRangeUsesUpperBoundInsteadOfRangeLength() {
        let dimension = StatefulCMLTensorSpec.dimension(from: NSRange(location: 4, length: 9))

        XCTAssertEqual(dimension.minValue, 4)
        XCTAssertEqual(dimension.maxValue, 12)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolverPrefersSourceArtifactsOverCompiledBundles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let compiled = root.appendingPathComponent("Model.mlmodelc", isDirectory: true)
        let package = root.appendingPathComponent("Model.mlpackage", isDirectory: true)
        let model = root.appendingPathComponent("Model.mlmodel")

        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: model.path, contents: Data())

        XCTAssertEqual(ANEModelResolver.preferredCoreMLArtifact(in: root), package)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolverOnlyRecompilesWhenSourceIsNewer() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Model.mlpackage", isDirectory: true)
        let compiled = ANEModelResolver.cachedCompiledModelURL(for: source, modelRoot: root)

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(120)

        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: compiled.path)
        XCTAssertFalse(ANEModelResolver.needsRecompile(source: source, cachedCompiledURL: compiled))

        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: compiled.path)
        XCTAssertTrue(ANEModelResolver.needsRecompile(source: source, cachedCompiledURL: compiled))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testCompiledCachePathLivesOutsideModelRootAndIsExcludedFromBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Model.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let cached = ANEModelResolver.cachedCompiledModelURL(for: source, modelRoot: root)
        let cacheDirectory = cached.deletingLastPathComponent()
        let resourceValues = try cacheDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])

        XCTAssertFalse(cached.path.hasPrefix(root.path + "/"))
        XCTAssertTrue(cached.path.contains("/Library/Caches/Noema/CoreMLCompiled/"))
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolvedANEModelSettingsUsesLocalTokenizerTemplateAndReportsSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ANEModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let template = "<|im_start|>system\nYou are local tokenizer config<|im_end|>\n"
        let payload: [String: Any] = ["chat_template": template]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: root.appendingPathComponent("tokenizer_config.json"))
        try "{}".write(to: root.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let resolution = ModelSettings.resolvedANEModelSettings(
            modelID: "Example/ANEModel",
            modelURL: root
        )

        XCTAssertEqual(resolution.promptTemplateSource, .tokenizerConfig)
        XCTAssertEqual(resolution.settings.promptTemplate, template)
        XCTAssertEqual(
            resolution.settings.tokenizerPath,
            root.appendingPathComponent("tokenizer.json").path
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolvedANEModelSettingsPrefersTokenizerTemplateOverConfigTemplate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ANEModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configTemplate = "<|im_start|>system\nconfig template<|im_end|>\n"
        let tokenizerTemplate = "<|im_start|>system\ntokenizer template<|im_end|>\n"

        let configData = try JSONSerialization.data(withJSONObject: ["chat_template": configTemplate])
        try configData.write(to: root.appendingPathComponent("config.json"))

        let tokenizerData = try JSONSerialization.data(withJSONObject: ["chat_template": tokenizerTemplate])
        try tokenizerData.write(to: root.appendingPathComponent("tokenizer_config.json"))

        let resolution = ModelSettings.resolvedANEModelSettings(
            modelID: "Example/ANEModel",
            modelURL: root
        )

        XCTAssertEqual(resolution.promptTemplateSource, .tokenizerConfig)
        XCTAssertEqual(resolution.settings.promptTemplate, tokenizerTemplate)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testAutomaticCMLLoadStrategyAttemptsAllThenFallsBack() {
        var settings = ModelSettings.default(for: .ane)
        settings.processingUnitConfiguration = nil
        let inheritedDefault = CoreMLLLMClient.loadStrategy(for: settings, flavor: .statefulCausalLM)
        XCTAssertEqual(inheritedDefault.computeUnits, [.all, .cpuAndGPU, .cpuOnly])
        XCTAssertTrue(inheritedDefault.isAutomatic)
        XCTAssertNil(inheritedDefault.requestedConfiguration)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testExplicitAllCMLLoadStrategyRemainsExplicit() {
        var settings = ModelSettings.default(for: .ane)
        settings.processingUnitConfiguration = .all
        let explicitAll = CoreMLLLMClient.loadStrategy(for: settings, flavor: .statefulCausalLM)

        XCTAssertEqual(explicitAll.computeUnits, [.all, .cpuAndGPU, .cpuOnly])
        XCTAssertFalse(explicitAll.isAutomatic)
        XCTAssertEqual(explicitAll.requestedConfiguration, .all)
        XCTAssertNil(explicitAll.restrictionReason)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testStatefulCMLNeuralEngineSelectionFallsBackWhenPlanBuildFails() {
        var settings = ModelSettings.default(for: .ane)
        settings.processingUnitConfiguration = .cpuAndNeuralEngine
        let strategy = CoreMLLLMClient.loadStrategy(for: settings, flavor: .statefulCausalLM)

        XCTAssertEqual(strategy.computeUnits, [.cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly])
        XCTAssertFalse(strategy.isAutomatic)
        XCTAssertEqual(strategy.requestedConfiguration, .cpuAndNeuralEngine)
        XCTAssertEqual(
            strategy.restrictionReason,
            "note=CPU + Neural Engine is attempted first, but stateful CML models may fall back to CPU + GPU or CPU Only if Core ML cannot build an ANE execution plan."
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testTransformersCMLNeuralEngineSelectionRemainsExplicit() {
        var settings = ModelSettings.default(for: .ane)
        settings.processingUnitConfiguration = .cpuAndNeuralEngine
        let strategy = CoreMLLLMClient.loadStrategy(for: settings, flavor: .transformersLanguageModel)

        XCTAssertEqual(strategy.computeUnits, [.cpuAndNeuralEngine])
        XCTAssertFalse(strategy.isAutomatic)
        XCTAssertEqual(strategy.requestedConfiguration, .cpuAndNeuralEngine)
        XCTAssertNil(strategy.restrictionReason)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLAutomaticLoadStrategyFallsBackWhenANEPlanBuildFails() {
        var settings = ModelSettings.default(for: .ane)
        settings.processingUnitConfiguration = nil
        let strategy = CoreMLLLMClient.loadStrategy(for: settings, flavor: .anemllPipeline)

        XCTAssertEqual(strategy.computeUnits, [.cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly])
        XCTAssertTrue(strategy.isAutomatic)
        XCTAssertNil(strategy.requestedConfiguration)
        XCTAssertEqual(
            strategy.restrictionReason,
            "note=ANEMLL pipelines prefer CPU + Neural Engine, but fall back to CPU + GPU or CPU Only if Core ML cannot build an ANE execution plan."
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLExplicitComputeSelectionFallbacksOnlyWhenNeeded() {
        var settings = ModelSettings.default(for: .ane)
        settings.processingUnitConfiguration = .all
        let explicitAll = CoreMLLLMClient.loadStrategy(for: settings, flavor: .anemllPipeline)
        XCTAssertEqual(explicitAll.computeUnits, [.all, .cpuAndGPU, .cpuOnly])
        XCTAssertFalse(explicitAll.isAutomatic)
        XCTAssertEqual(explicitAll.requestedConfiguration, .all)
        XCTAssertNil(explicitAll.restrictionReason)

        settings.processingUnitConfiguration = .cpuAndGPU
        let explicitGPU = CoreMLLLMClient.loadStrategy(for: settings, flavor: .anemllPipeline)
        XCTAssertEqual(explicitGPU.computeUnits, [.cpuAndGPU])
        XCTAssertFalse(explicitGPU.isAutomatic)
        XCTAssertEqual(explicitGPU.requestedConfiguration, .cpuAndGPU)
        XCTAssertNil(explicitGPU.restrictionReason)

        settings.processingUnitConfiguration = .cpuOnly
        let explicitCPU = CoreMLLLMClient.loadStrategy(for: settings, flavor: .anemllPipeline)
        XCTAssertEqual(explicitCPU.computeUnits, [.cpuOnly])
        XCTAssertFalse(explicitCPU.isAutomatic)
        XCTAssertEqual(explicitCPU.requestedConfiguration, .cpuOnly)
        XCTAssertNil(explicitCPU.restrictionReason)

        settings.processingUnitConfiguration = .cpuAndNeuralEngine
        let explicitANE = CoreMLLLMClient.loadStrategy(for: settings, flavor: .anemllPipeline)
        XCTAssertEqual(
            explicitANE.computeUnits,
            [.cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly]
        )
        XCTAssertFalse(explicitANE.isAutomatic)
        XCTAssertEqual(explicitANE.requestedConfiguration, .cpuAndNeuralEngine)
        XCTAssertEqual(
            explicitANE.restrictionReason,
            "note=CPU + Neural Engine is attempted first, but ANEMLL pipelines may fall back to CPU + GPU or CPU Only if Core ML cannot build an ANE execution plan."
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testNestedCompiledBundlePathCanonicalizesToCMLRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appendingPathComponent("qwen_embeddings.mlmodelc", isDirectory: true)
        let analytics = bundle.appendingPathComponent("analytics", isDirectory: true)
        try FileManager.default.createDirectory(at: analytics, withIntermediateDirectories: true)

        let fixed = InstalledModelsStore.canonicalURL(for: analytics, format: .ane)
        XCTAssertEqual(fixed, root)
        XCTAssertEqual(ANEModelResolver.modelRoot(from: analytics), root)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolverDetectsANEMLLPipelineFromMetaManifest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        model_info:
          parameters:
            context_length: 2048
            state_length: 4096
            batch_size: 64
            num_chunks: 2
            sliding_window: 512
            update_mask_prefill: true
            prefill_dynamic_slice: false
            vocab_size: 151936
            lm_head_chunk_sizes: [75968, 75968]
            argmax_in_model: false
            embeddings: qwen_embeddings.mlmodelc
            lm_head: qwen_lm_head_lut6.mlmodelc
            ffn: qwen_FFN_PF_lut6_chunk_01of02.mlmodelc
            recommended_sampling:
              do_sample: true
              temperature: 0.6
              top_p: 0.95
              top_k: 20
        """.write(to: root.appendingPathComponent("meta.yaml"), atomically: true, encoding: .utf8)

        try "{}".write(to: root.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let embeddings = root.appendingPathComponent("qwen_embeddings.mlmodelc", isDirectory: true)
        let embeddingsAnalytics = embeddings.appendingPathComponent("analytics", isDirectory: true)
        let lmHead = root.appendingPathComponent("qwen_lm_head_lut6.mlmodelc", isDirectory: true)
        let chunk1 = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_01of02.mlmodelc", isDirectory: true)
        let chunk2 = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_02of02.mlmodelc", isDirectory: true)

        try FileManager.default.createDirectory(at: embeddingsAnalytics, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lmHead, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunk1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunk2, withIntermediateDirectories: true)

        let resolved = try ANEModelResolver.resolve(modelURL: embeddingsAnalytics)
        XCTAssertEqual(resolved.modelRoot, root)
        XCTAssertEqual(resolved.flavor, .anemllPipeline)
        XCTAssertEqual(resolved.anemllPipeline?.contextLength, 2048)
        XCTAssertEqual(resolved.anemllPipeline?.stateLength, 4096)
        XCTAssertEqual(resolved.anemllPipeline?.batchSize, 64)
        XCTAssertEqual(resolved.anemllPipeline?.slidingWindow, 512)
        XCTAssertEqual(resolved.anemllPipeline?.updateMaskPrefill, true)
        XCTAssertEqual(resolved.anemllPipeline?.prefillDynamicSlice, false)
        XCTAssertEqual(resolved.anemllPipeline?.vocabSize, 151936)
        XCTAssertEqual(resolved.anemllPipeline?.lmHeadChunkSizes, [75968, 75968])
        XCTAssertEqual(resolved.anemllPipeline?.argmaxInModel, false)
        XCTAssertEqual(resolved.anemllPipeline?.recommendedSampling?.doSample, true)
        XCTAssertEqual(resolved.anemllPipeline?.recommendedSampling?.temperature, 0.6)
        XCTAssertEqual(resolved.anemllPipeline?.recommendedSampling?.topP, 0.95)
        XCTAssertEqual(resolved.anemllPipeline?.recommendedSampling?.topK, 20)
        XCTAssertEqual(resolved.anemllPipeline?.ffnChunkURLs.count, 2)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolverPrefersCompiledANEMLLComponentOverPackageManifestPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        model_info:
          parameters:
            context_length: 2048
            batch_size: 64
            num_chunks: 1
            embeddings: qwen_embeddings.mlpackage
            lm_head: qwen_lm_head_lut6.mlpackage
            ffn: qwen_FFN_PF_lut6_chunk_01of01.mlpackage
        """.write(to: root.appendingPathComponent("meta.yaml"), atomically: true, encoding: .utf8)

        try "{}".write(to: root.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let embeddingsCompiled = root.appendingPathComponent("qwen_embeddings.mlmodelc", isDirectory: true)
        let embeddingsPackage = root.appendingPathComponent("qwen_embeddings.mlpackage", isDirectory: true)
        let lmHeadCompiled = root.appendingPathComponent("qwen_lm_head_lut6.mlmodelc", isDirectory: true)
        let lmHeadPackage = root.appendingPathComponent("qwen_lm_head_lut6.mlpackage", isDirectory: true)
        let chunkCompiled = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_01of01.mlmodelc", isDirectory: true)
        let chunkPackage = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_01of01.mlpackage", isDirectory: true)

        try FileManager.default.createDirectory(at: embeddingsCompiled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: embeddingsPackage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lmHeadCompiled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lmHeadPackage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunkCompiled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunkPackage, withIntermediateDirectories: true)

        let resolved = try ANEModelResolver.resolve(modelURL: root)
        XCTAssertEqual(resolved.anemllPipeline?.embeddingsURL, embeddingsCompiled)
        XCTAssertEqual(resolved.anemllPipeline?.lmHeadURL, lmHeadCompiled)
        XCTAssertEqual(resolved.anemllPipeline?.ffnChunkURLs, [chunkCompiled])
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolverFindsANEMLLTokenizerInImmediateChildDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        model_info:
          parameters:
            context_length: 2048
            batch_size: 64
            num_chunks: 1
            embeddings: qwen_embeddings.mlmodelc
            lm_head: qwen_lm_head_lut6.mlmodelc
            ffn: qwen_FFN_PF_lut6_chunk_01of01.mlmodelc
        """.write(to: root.appendingPathComponent("meta.yaml"), atomically: true, encoding: .utf8)

        let tokenizerDir = root.appendingPathComponent("tokenizer", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizerDir, withIntermediateDirectories: true)
        try "{}".write(to: tokenizerDir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let embeddings = root.appendingPathComponent("qwen_embeddings.mlmodelc", isDirectory: true)
        let lmHead = root.appendingPathComponent("qwen_lm_head_lut6.mlmodelc", isDirectory: true)
        let chunk = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_01of01.mlmodelc", isDirectory: true)

        try FileManager.default.createDirectory(at: embeddings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lmHead, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunk, withIntermediateDirectories: true)

        let resolved = try ANEModelResolver.resolve(modelURL: root)
        XCTAssertEqual(resolved.flavor, .anemllPipeline)
        XCTAssertEqual(resolved.tokenizerDirectory, tokenizerDir)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testResolverInfersANEMLLPipelineWithoutManifest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try "{}".write(to: root.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let embeddings = root.appendingPathComponent("qwen_embeddings.mlmodelc", isDirectory: true)
        let lmHead = root.appendingPathComponent("qwen_lm_head_lut6.mlmodelc", isDirectory: true)
        let chunk1 = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_01of02.mlmodelc", isDirectory: true)
        let chunk2 = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_02of02.mlmodelc", isDirectory: true)

        try FileManager.default.createDirectory(at: embeddings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lmHead, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunk1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunk2, withIntermediateDirectories: true)

        try writeMetadata([
            CoreMLArtifactMetadata(
                inputSchema: [CoreMLArtifactFeature(name: "input_ids", dataType: "Int32")],
                outputSchema: [CoreMLArtifactFeature(name: "hidden_states", dataType: "Float16")],
                stateSchema: [],
                generatedClassName: "qwen_embeddings",
                userDefinedMetadata: ["com.anemll.context_length": "2048"]
            )
        ], to: embeddings.appendingPathComponent("metadata.json"))

        try writeMetadata([
            CoreMLArtifactMetadata(
                inputSchema: [CoreMLArtifactFeature(name: "hidden_states", dataType: "Float16")],
                outputSchema: [CoreMLArtifactFeature(name: "logits1", dataType: "Float16")],
                stateSchema: [],
                generatedClassName: "qwen_lm_head_lut6",
                userDefinedMetadata: ["com.anemll.context_length": "2048"]
            )
        ], to: lmHead.appendingPathComponent("metadata.json"))

        try writeMetadata([
            CoreMLArtifactMetadata(
                inputSchema: [
                    CoreMLArtifactFeature(name: "hidden_states", dataType: "Float16"),
                    CoreMLArtifactFeature(name: "position_ids", dataType: "Int32"),
                    CoreMLArtifactFeature(name: "causal_mask", dataType: "Float16"),
                    CoreMLArtifactFeature(name: "current_pos", dataType: "Int32")
                ],
                outputSchema: [CoreMLArtifactFeature(name: "output_hidden_states", dataType: "Float16")],
                stateSchema: [CoreMLArtifactFeature(name: "model_model_kv_cache_0", dataType: "Float16")],
                generatedClassName: "qwen_FFN_PF_lut6_chunk_01of02",
                userDefinedMetadata: [
                    "com.anemll.context_length": "2048",
                    "com.anemll.batch_size": "64",
                    "com.anemll.num_chunks": "2",
                    "com.anemll.chunk_no": "1"
                ]
            )
        ], to: chunk1.appendingPathComponent("metadata.json"))

        try writeMetadata([
            CoreMLArtifactMetadata(
                inputSchema: [
                    CoreMLArtifactFeature(name: "hidden_states", dataType: "Float16"),
                    CoreMLArtifactFeature(name: "position_ids", dataType: "Int32"),
                    CoreMLArtifactFeature(name: "causal_mask", dataType: "Float16"),
                    CoreMLArtifactFeature(name: "current_pos", dataType: "Int32")
                ],
                outputSchema: [CoreMLArtifactFeature(name: "output_hidden_states", dataType: "Float16")],
                stateSchema: [CoreMLArtifactFeature(name: "model_model_kv_cache_0", dataType: "Float16")],
                generatedClassName: "qwen_FFN_PF_lut6_chunk_02of02",
                userDefinedMetadata: [
                    "com.anemll.context_length": "2048",
                    "com.anemll.batch_size": "64",
                    "com.anemll.num_chunks": "2",
                    "com.anemll.chunk_no": "2"
                ]
            )
        ], to: chunk2.appendingPathComponent("metadata.json"))

        let resolved = try ANEModelResolver.resolve(modelURL: embeddings)
        XCTAssertEqual(resolved.flavor, .anemllPipeline)
        XCTAssertEqual(resolved.sourceModelURL, root)
        XCTAssertEqual(resolved.anemllPipeline?.contextLength, 2048)
        XCTAssertEqual(resolved.anemllPipeline?.batchSize, 64)
        XCTAssertEqual(resolved.anemllPipeline?.ffnChunkURLs.count, 2)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testValidateDownloadedANEMLLInstallRequiresCompiledBundlesAndWeights() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        model_info:
          parameters:
            context_length: 2048
            batch_size: 64
            num_chunks: 1
            embeddings: qwen_embeddings.mlmodelc
            lm_head: qwen_lm_head_lut6.mlmodelc
            ffn: qwen_FFN_PF_lut6_chunk_01of01.mlmodelc
        """.write(to: root.appendingPathComponent("meta.yaml"), atomically: true, encoding: .utf8)

        try "{}".write(to: root.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let embeddings = root.appendingPathComponent("qwen_embeddings.mlmodelc", isDirectory: true)
        let lmHead = root.appendingPathComponent("qwen_lm_head_lut6.mlmodelc", isDirectory: true)
        let chunk = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_01of01.mlmodelc", isDirectory: true)

        try createCompiledBundleSkeleton(at: embeddings, includeWeights: true)
        try createCompiledBundleSkeleton(at: lmHead, includeWeights: true)
        try createCompiledBundleSkeleton(at: chunk, includeWeights: false)

        XCTAssertThrowsError(try ANEModelResolver.validateDownloadedANEMLLInstall(in: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("weights"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testValidateDownloadedANEMLLInstallAllowsCompiledBundlesWithoutModelMIL() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        model_info:
          parameters:
            context_length: 2048
            batch_size: 64
            num_chunks: 1
            embeddings: qwen_embeddings.mlmodelc
            lm_head: qwen_lm_head_lut6.mlmodelc
            ffn: qwen_FFN_PF_lut6_chunk_01of01.mlmodelc
        """.write(to: root.appendingPathComponent("meta.yaml"), atomically: true, encoding: .utf8)

        try "{}".write(to: root.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let embeddings = root.appendingPathComponent("qwen_embeddings.mlmodelc", isDirectory: true)
        let lmHead = root.appendingPathComponent("qwen_lm_head_lut6.mlmodelc", isDirectory: true)
        let chunk = root.appendingPathComponent("qwen_FFN_PF_lut6_chunk_01of01.mlmodelc", isDirectory: true)

        try createCompiledBundleSkeleton(at: embeddings, includeWeights: true, includeModelMIL: false)
        try createCompiledBundleSkeleton(at: lmHead, includeWeights: true, includeModelMIL: false)
        try createCompiledBundleSkeleton(at: chunk, includeWeights: true, includeModelMIL: false)

        let pipeline = try ANEModelResolver.validateDownloadedANEMLLInstall(in: root)
        XCTAssertEqual(pipeline.ffnChunkURLs, [chunk])
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLPrefillPlanUsesUpdateMaskStrategyForPartialBatches() {
        XCTAssertEqual(
            ANEMLLPrefillStrategy.paddedBatchesWithUpdateMask.makePlan(tokenCount: 53, batchSize: 64),
            ANEMLLPrefillPlan(
                strategy: .paddedBatchesWithUpdateMask,
                fullBatchTokenCount: 53,
                remainderTokenCount: 0,
                needsFinalTokenInfer: false
            )
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLPrefillPlanUsesInferRemainderForShortPrompt() {
        XCTAssertEqual(
            ANEMLLPrefillStrategy.fullBatchesWithInferRemainder.makePlan(tokenCount: 53, batchSize: 64),
            ANEMLLPrefillPlan(
                strategy: .fullBatchesWithInferRemainder,
                fullBatchTokenCount: 0,
                remainderTokenCount: 53,
                needsFinalTokenInfer: false
            )
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLPrefillPlanUsesInferRemainderForNonMultiplePrompt() {
        XCTAssertEqual(
            ANEMLLPrefillStrategy.fullBatchesWithInferRemainder.makePlan(tokenCount: 70, batchSize: 64),
            ANEMLLPrefillPlan(
                strategy: .fullBatchesWithInferRemainder,
                fullBatchTokenCount: 64,
                remainderTokenCount: 6,
                needsFinalTokenInfer: false
            )
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLPrefillPlanUsesPrefillOutputForExactBatchMultiple() {
        XCTAssertEqual(
            ANEMLLPrefillStrategy.fullBatchesWithInferRemainder.makePlan(tokenCount: 128, batchSize: 64),
            ANEMLLPrefillPlan(
                strategy: .fullBatchesWithInferRemainder,
                fullBatchTokenCount: 128,
                remainderTokenCount: 0,
                needsFinalTokenInfer: false
            )
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLPrefillPlanInferOnlyProcessesAllTokensAsRemainder() {
        XCTAssertEqual(
            ANEMLLPrefillStrategy.inferOnly.makePlan(tokenCount: 200, batchSize: 64),
            ANEMLLPrefillPlan(
                strategy: .inferOnly,
                fullBatchTokenCount: 0,
                remainderTokenCount: 200,
                needsFinalTokenInfer: false
            )
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLAllowedSequenceLengthsRejectUnsupportedEnumeratedLength() {
        let allowed = ANEMLLAllowedSequenceLengths.fromEnumeratedShapes(
            [[1, 1], [1, 64]],
            axis: 1
        )

        XCTAssertEqual(allowed, .enumerated([1, 64]))
        XCTAssertTrue(allowed.supports(1))
        XCTAssertTrue(allowed.supports(64))
        XCTAssertFalse(allowed.supports(53))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLFunctionLoadPlannerSkipsRotateWhenSlidingWindowIsAbsent() throws {
        XCTAssertEqual(
            try ANEMLLFunctionLoadPlanner.requiredFunctions(
                availableFunctions: ["infer", "prefill"],
                requiresRotation: false
            ),
            ["infer", "prefill"]
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLChunkLoadPlannerUsesNamedFunctionsWhenAvailable() throws {
        XCTAssertEqual(
            try ANEMLLChunkLoadPlanner.resolve(
                availableFunctions: ["prefill", "infer"],
                requiresRotation: false,
                artifactName: "chunk_01.mlmodelc"
            ),
            .multiFunction(["infer", "prefill"])
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLChunkLoadPlannerFallsBackToSingleModelWithoutNamedFunctions() throws {
        XCTAssertEqual(
            try ANEMLLChunkLoadPlanner.resolve(
                availableFunctions: ["main"],
                requiresRotation: false,
                artifactName: "chunk_01.mlmodelc"
            ),
            .singleModel
        )
        XCTAssertEqual(
            try ANEMLLChunkLoadPlanner.resolve(
                availableFunctions: nil,
                requiresRotation: false,
                artifactName: "chunk_01.mlmodelc"
            ),
            .singleModel
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLChunkLoadPlannerRejectsSlidingWindowSingleModelChunks() {
        XCTAssertThrowsError(
            try ANEMLLChunkLoadPlanner.resolve(
                availableFunctions: ["main"],
                requiresRotation: true,
                artifactName: "chunk_01.mlmodelc"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("sliding-window"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testFunctionNameUnsupportedErrorDetection() {
        let matchingError = NSError(
            domain: "com.apple.CoreML",
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "`MLModelConfiguration`'s `.functionName` property must be `nil` unless the model type is ML Program."
            ]
        )
        XCTAssertTrue(ANEMLLLoadErrorClassifier.isFunctionNameUnsupported(matchingError))

        let wrappedError = NSError(
            domain: "Noema.CoreML",
            code: -6,
            userInfo: [
                NSUnderlyingErrorKey: matchingError,
                NSLocalizedDescriptionKey:
                    "Failed to load ANEMLL artifact `chunk_01.mlmodelc` function=infer " +
                    "computeUnits=CPU + GPU. underlyingError=`MLModelConfiguration`'s `.functionName` " +
                    "property must be `nil` unless the model type is ML Program."
            ]
        )
        XCTAssertTrue(ANEMLLLoadErrorClassifier.isFunctionNameUnsupported(wrappedError))

        let unrelatedError = NSError(
            domain: "com.apple.CoreML",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Model compilation failed."]
        )
        XCTAssertFalse(ANEMLLLoadErrorClassifier.isFunctionNameUnsupported(unrelatedError))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLLoadDiagnosticSummaryReportsPrefillStrategyCapabilities() throws {
        let pipeline = ANEMLLPipelineDescriptor(
            metaURL: URL(fileURLWithPath: "/tmp/meta.yaml"),
            embeddingsURL: URL(fileURLWithPath: "/tmp/embeddings.mlmodelc"),
            lmHeadURL: URL(fileURLWithPath: "/tmp/lm_head.mlmodelc"),
            ffnChunkURLs: [URL(fileURLWithPath: "/tmp/chunk_01.mlmodelc")],
            contextLength: 2048,
            stateLength: 2048,
            batchSize: 64,
            slidingWindow: nil,
            updateMaskPrefill: false,
            prefillDynamicSlice: true,
            vocabSize: nil,
            lmHeadChunkSizes: nil,
            argmaxInModel: false,
            recommendedSampling: nil
        )

        let summary = ANEMLLLoadDiagnosticSummary.make(
            modelFormat: "mlprogram",
            artifactType: "mlmodelc-direct",
            computeUnits: "CPU + Neural Engine",
            pipeline: pipeline,
            prefillStrategy: .fullBatchesWithInferRemainder,
            supportsUpdateMask: false,
            embedInputLengths: "1,64",
            functions: "chunk1=infer,prefill"
        )

        XCTAssertTrue(summary.contains("prefillStrategy=full-batches+infer-remainder"))
        XCTAssertTrue(summary.contains("manifestPrefillDynamicSlice=true"))
        XCTAssertTrue(summary.contains("supportsUpdateMask=false"))
        XCTAssertTrue(summary.contains("embedInputLengths=1,64"))
        XCTAssertFalse(summary.contains("prefillMode="))
        XCTAssertFalse(summary.contains("finalInfer=true"))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLLoadDiagnosticSummaryReportsArgmaxMode() throws {
        let pipeline = makeANEMLLPipeline(
            vocabSize: 16,
            lmHeadChunkSizes: [5, 5, 6],
            argmaxInModel: true
        )

        let summary = ANEMLLLoadDiagnosticSummary.make(
            modelFormat: "mlprogram",
            artifactType: "mlmodelc-direct",
            computeUnits: "CPU + Neural Engine",
            pipeline: pipeline,
            prefillStrategy: .fullBatchesWithInferRemainder,
            supportsUpdateMask: false,
            embedInputLengths: "1,64",
            functions: "chunk1=infer,prefill"
        )

        XCTAssertTrue(summary.contains("argmaxInModel=true"))
        XCTAssertTrue(summary.contains("lmHeadMode=argmax"))
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLSamplingResolverUsesRecommendedSamplingForDefaultANEControls() {
        let settings = ModelSettings.default(for: .ane)
        let pipeline = ANEMLLPipelineDescriptor(
            metaURL: URL(fileURLWithPath: "/tmp/meta.yaml"),
            embeddingsURL: URL(fileURLWithPath: "/tmp/embeddings.mlmodelc"),
            lmHeadURL: URL(fileURLWithPath: "/tmp/lm_head.mlmodelc"),
            ffnChunkURLs: [URL(fileURLWithPath: "/tmp/chunk_01.mlmodelc")],
            contextLength: 2048,
            stateLength: 2048,
            batchSize: 64,
            slidingWindow: nil,
            updateMaskPrefill: false,
            prefillDynamicSlice: false,
            vocabSize: nil,
            lmHeadChunkSizes: nil,
            argmaxInModel: false,
            recommendedSampling: ANEMLLRecommendedSampling(
                doSample: true,
                temperature: 0.6,
                topP: 0.9,
                topK: 0
            )
        )

        let resolved = ANEMLLSamplingConfigResolver.resolve(settings: settings, pipeline: pipeline)
        XCTAssertTrue(resolved.doSample)
        XCTAssertEqual(resolved.temperature, 0.6, accuracy: 0.0001)
        XCTAssertEqual(resolved.topP, 0.9, accuracy: 0.0001)
        XCTAssertEqual(resolved.topK, 0)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLSamplingResolverRespectsExplicitUserOverrides() {
        var settings = ModelSettings.default(for: .ane)
        settings.temperature = 0.2
        settings.topP = 0.8
        settings.topK = 12

        let pipeline = ANEMLLPipelineDescriptor(
            metaURL: URL(fileURLWithPath: "/tmp/meta.yaml"),
            embeddingsURL: URL(fileURLWithPath: "/tmp/embeddings.mlmodelc"),
            lmHeadURL: URL(fileURLWithPath: "/tmp/lm_head.mlmodelc"),
            ffnChunkURLs: [URL(fileURLWithPath: "/tmp/chunk_01.mlmodelc")],
            contextLength: 2048,
            stateLength: 2048,
            batchSize: 64,
            slidingWindow: nil,
            updateMaskPrefill: false,
            prefillDynamicSlice: false,
            vocabSize: nil,
            lmHeadChunkSizes: nil,
            argmaxInModel: false,
            recommendedSampling: ANEMLLRecommendedSampling(
                doSample: true,
                temperature: 0.6,
                topP: 0.9,
                topK: 0
            )
        )

        let resolved = ANEMLLSamplingConfigResolver.resolve(settings: settings, pipeline: pipeline)
        XCTAssertTrue(resolved.doSample)
        XCTAssertEqual(resolved.temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(resolved.topP, 0.8, accuracy: 0.0001)
        XCTAssertEqual(resolved.topK, 12)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLSamplingResolverDisablesSamplingForArgmaxPipelines() {
        var settings = ModelSettings.default(for: .ane)
        settings.temperature = 0.9
        settings.topP = 0.7
        settings.topK = 32

        let pipeline = makeANEMLLPipeline(
            vocabSize: 32,
            lmHeadChunkSizes: [8, 8, 8, 8],
            argmaxInModel: true
        )

        let resolved = ANEMLLSamplingConfigResolver.resolve(settings: settings, pipeline: pipeline)
        XCTAssertFalse(resolved.doSample)
        XCTAssertEqual(resolved.temperature, 0)
        XCTAssertEqual(resolved.topP, 1, accuracy: 0.0001)
        XCTAssertEqual(resolved.topK, 0)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLArgmaxOutputResolverUsesChunkSizeMetadata() throws {
        let pipeline = makeANEMLLPipeline(
            vocabSize: 12,
            lmHeadChunkSizes: [3, 5, 4],
            argmaxInModel: true
        )
        let indexArray = try makeInt32Array([1, 4, 2])
        let valueArray = try makeFloat32Array([0.2, 0.9, 0.1])

        let token = try ANEMLLArgmaxOutputResolver.selectToken(
            indexArray: indexArray,
            valueArray: valueArray,
            pipeline: pipeline
        )

        XCTAssertEqual(token, 7)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLArgmaxOutputResolverFallsBackToVocabSize() throws {
        let pipeline = makeANEMLLPipeline(
            vocabSize: 10,
            lmHeadChunkSizes: nil,
            argmaxInModel: true
        )
        let indexArray = try makeInt32Array([2, 0, 1, 1])
        let valueArray = try makeFloat32Array([0.1, 0.2, 0.3, 0.95])

        let token = try ANEMLLArgmaxOutputResolver.selectToken(
            indexArray: indexArray,
            valueArray: valueArray,
            pipeline: pipeline
        )

        XCTAssertEqual(token, 9)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLArgmaxOutputResolverRequiresChunkMetadataOrVocabSize() throws {
        let pipeline = makeANEMLLPipeline(
            vocabSize: nil,
            lmHeadChunkSizes: nil,
            argmaxInModel: true
        )
        let indexArray = try makeInt32Array([0, 1])
        let valueArray = try makeFloat32Array([0.1, 0.9])

        XCTAssertThrowsError(
            try ANEMLLArgmaxOutputResolver.selectToken(
                indexArray: indexArray,
                valueArray: valueArray,
                pipeline: pipeline
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("lm_head_chunk_sizes"))
            XCTAssertTrue(error.localizedDescription.contains("vocab_size"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLHiddenStateShapeResolverPrefersNonTrivialInputWidth() {
        XCTAssertEqual(
            ANEMLLHiddenStateShapeResolver.resolve(
                inputShape: [1, 64, 2048],
                embeddingShape: [1, 64, 2048],
                outputShape: [1, 64, 1]
            ),
            [1, 64, 2048]
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    func testANEMLLHiddenStateShapeResolverFallsBackToEmbeddingWidth() {
        XCTAssertEqual(
            ANEMLLHiddenStateShapeResolver.resolve(
                inputShape: [],
                embeddingShape: [1, 1, 2048],
                outputShape: [1, 1, 1]
            ),
            [1, 1, 2048]
        )
    }

    func testANEQuantIncludesManifestInDownloadParts() {
        let files = [
            RepoFile(path: "meta.yaml", size: 512, sha256: nil),
            RepoFile(path: "qwen_embeddings.mlmodelc/metadata.json", size: 128, sha256: nil),
            RepoFile(path: "qwen_embeddings.mlmodelc/model.mil", size: 128, sha256: nil),
            RepoFile(path: "qwen_lm_head_lut6.mlmodelc/metadata.json", size: 128, sha256: nil),
            RepoFile(path: "qwen_lm_head_lut6.mlmodelc/model.mil", size: 128, sha256: nil),
            RepoFile(path: "qwen_FFN_PF_lut6_chunk_01of02.mlmodelc/metadata.json", size: 128, sha256: nil),
            RepoFile(path: "qwen_FFN_PF_lut6_chunk_01of02.mlmodelc/model.mil", size: 128, sha256: nil),
            RepoFile(path: "tokenizer.json", size: 128, sha256: nil)
        ]

        let quant = QuantExtractor.extract(from: files, repoID: "anemll/anemll-Qwen-Qwen3-1.7B-ctx2048_0.3.5")
            .first(where: { $0.format == .ane })

        XCTAssertNotNil(quant)
        XCTAssertTrue(quant?.allDownloadParts.contains(where: { $0.path == "meta.yaml" }) == true)
    }
    #endif

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeIsolatedModelManager() -> (AppModelManager, String) {
        let filename = "installed-\(UUID().uuidString).json"
        return (AppModelManager(store: InstalledModelsStore(filename: filename)), filename)
    }

    private func removeInstalledStore(named filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent(filename))
    }

    private func makeTestLocalModel() -> LocalModel {
        LocalModel(
            modelID: "test/model",
            name: "Test Model",
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).gguf"),
            quant: "Q4_K_M",
            architecture: "llama",
            architectureFamily: "llama",
            format: .gguf,
            sizeGB: 1.0,
            isMultimodal: false,
            isToolCapable: true,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )
    }

    private func writeMetadata(_ metadata: [CoreMLArtifactMetadata], to url: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url)
    }

    private func createCompiledBundleSkeleton(
        at url: URL,
        includeWeights: Bool,
        includeModelMIL: Bool = true
    ) throws {
        let weightsDir = url.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        try "[]".write(to: url.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        if includeModelMIL {
            try "mil".write(to: url.appendingPathComponent("model.mil"), atomically: true, encoding: .utf8)
        }
        if includeWeights {
            try Data([1]).write(to: weightsDir.appendingPathComponent("weight.bin"))
        }
    }

    @available(iOS 18.0, visionOS 2.0, *)
    private static func makeScores(bestToken: Int, vocabSize: Int = 16) -> MLTensor {
        var scalars = [Float](repeating: -1000, count: vocabSize)
        if scalars.indices.contains(bestToken) {
            scalars[bestToken] = 1000
        }
        let shaped = MLShapedArray<Float>(scalars: scalars, shape: [1, 1, vocabSize])
        return MLTensor(shaped)
    }

    @available(iOS 18.0, visionOS 2.0, *)
    private func makeANEMLLPipeline(
        vocabSize: Int?,
        lmHeadChunkSizes: [Int]?,
        argmaxInModel: Bool
    ) -> ANEMLLPipelineDescriptor {
        ANEMLLPipelineDescriptor(
            metaURL: URL(fileURLWithPath: "/tmp/meta.yaml"),
            embeddingsURL: URL(fileURLWithPath: "/tmp/embeddings.mlmodelc"),
            lmHeadURL: URL(fileURLWithPath: "/tmp/lm_head.mlmodelc"),
            ffnChunkURLs: [URL(fileURLWithPath: "/tmp/chunk_01.mlmodelc")],
            contextLength: 2048,
            stateLength: 2048,
            batchSize: 64,
            slidingWindow: nil,
            updateMaskPrefill: false,
            prefillDynamicSlice: false,
            vocabSize: vocabSize,
            lmHeadChunkSizes: lmHeadChunkSizes,
            argmaxInModel: argmaxInModel,
            recommendedSampling: nil
        )
    }

    @available(iOS 18.0, visionOS 2.0, *)
    private func makeInt32Array(_ values: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [NSNumber(value: values.count)],
            dataType: .int32
        )
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: value)
        }
        return array
    }

    @available(iOS 18.0, visionOS 2.0, *)
    private func makeFloat32Array(_ values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [NSNumber(value: values.count)],
            dataType: .float32
        )
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: value)
        }
        return array
    }

    @available(iOS 18.0, visionOS 2.0, *)
    private func makeValidStatefulCMLContract(
        contextLength: Int = 2048,
        inputDataType: MLMultiArrayDataType = .int32,
        maskDataType: MLMultiArrayDataType = .float16,
        logitsDataType: MLMultiArrayDataType = .float16,
        hasKeyCache: Bool = true,
        hasValueCache: Bool = true,
        includeMask: Bool = true,
        inputDimensions: [StatefulCMLDimension]? = nil,
        maskDimensions: [StatefulCMLDimension]? = nil,
        logitsDimensions: [StatefulCMLDimension]? = nil,
        keyCacheState: StatefulCMLStateSpec? = nil,
        metadata: CoreMLArtifactMetadata? = nil
    ) throws -> StatefulCMLContract {
        let inputIDs = StatefulCMLTensorSpec(
            name: "input_ids",
            dataType: inputDataType,
            dimensions: inputDimensions ?? [
                .fixed(1),
                StatefulCMLDimension(minValue: 1, maxValue: contextLength)
            ]
        )
        let causalMask: StatefulCMLTensorSpec? = includeMask
            ? StatefulCMLTensorSpec(
                name: "causal_mask",
                dataType: maskDataType,
                dimensions: maskDimensions ?? [
                    .fixed(1),
                    .fixed(1),
                    .fixed(1),
                    StatefulCMLDimension(minValue: 1, maxValue: contextLength)
                ]
            )
            : nil
        let logits = StatefulCMLTensorSpec(
            name: "logits",
            dataType: logitsDataType,
            dimensions: logitsDimensions ?? [
                .fixed(1),
                StatefulCMLDimension(minValue: 1, maxValue: contextLength),
                .fixed(32000)
            ]
        )

        return try StatefulCMLContract(
            inputIDs: inputIDs,
            causalMask: causalMask,
            logits: logits,
            hasKeyCache: hasKeyCache,
            hasValueCache: hasValueCache,
            keyCacheState: keyCacheState,
            metadata: metadata ?? CoreMLArtifactMetadata(
                generatedClassName: "Qwen3_0_6B"
            )
        )
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure @escaping () async throws -> T,
        _ errorHandler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error to be thrown")
        } catch {
            errorHandler(error)
        }
    }
}

final class RemoteBackendOpenRouterTests: XCTestCase {
    private let remoteSettingsStorageKey = "remoteModelSettings.v1"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: remoteSettingsStorageKey)
        super.tearDown()
    }

    func testOpenRouterEndpointDefaults() {
        XCTAssertEqual(RemoteBackend.EndpointType.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(RemoteBackend.EndpointType.openRouter.defaultChatPath, "/api/v1/chat/completions")
        XCTAssertEqual(RemoteBackend.EndpointType.openRouter.defaultModelsPath, "/api/v1/models/user")
        XCTAssertTrue(RemoteBackend.EndpointType.remoteEndpointOptions.contains(.openRouter))
        XCTAssertTrue(RemoteBackend.EndpointType.openRouter.isOpenRouter)
    }

    func testOpenRouterModelsDecodeAndMap() throws {
        let json = """
        {
          "data": [
            {
              "id": "openai/gpt-5.2",
              "canonical_slug": "openai/gpt-5.2",
              "name": "GPT-5.2",
              "description": "Flagship multimodal model with tool calling.",
              "pricing": {
                "prompt": "0.000002",
                "completion": "0.000008",
                "request": "0.01",
                "image": "0.000004"
              },
              "context_length": 200000,
              "architecture": {
                "modality": "text",
                "tokenizer": "gpt",
                "instruct_type": "chatml"
              },
              "top_provider": {
                "context_length": 200000,
                "max_completion_tokens": 16384,
                "is_moderated": true,
                "provider_name": "OpenAI"
              },
              "per_request_limits": {
                "prompt_tokens": 120000,
                "completion_tokens": 16384
              },
              "supported_parameters": ["temperature", "top_p", "tools", "structured_outputs", "reasoning"],
              "default_parameters": {
                "temperature": 0.3,
                "top_p": 0.9,
                "top_k": 50,
                "repetition_penalty": 1.05
              },
              "expiration_date": "2027-12-31"
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.data.count, 1)
        let model = RemoteModel.make(from: decoded.data[0])
        XCTAssertEqual(model.id, "openai/gpt-5.2")
        XCTAssertEqual(model.name, "GPT-5.2")
        XCTAssertEqual(model.author, "OpenAI")
        XCTAssertEqual(model.publisher, "OpenAI")
        XCTAssertEqual(model.maxContextLength, 200000)
        XCTAssertEqual(model.type, "openrouter")
        XCTAssertEqual(model.promptPricePerMillion, 2.0)
        XCTAssertEqual(model.completionPricePerMillion, 8.0)
        XCTAssertEqual(model.requestPrice, 0.01)
        XCTAssertEqual(model.imagePricePerMillion, 4.0)
        XCTAssertTrue(model.supportsTools)
        XCTAssertTrue(model.supportsStructuredOutputs)
        XCTAssertTrue(model.supportsReasoning)
        XCTAssertEqual(model.defaultTemperature, 0.3)
        XCTAssertEqual(model.defaultTopP, 0.9)
        XCTAssertEqual(model.defaultTopK, 50)
        XCTAssertEqual(model.defaultRepetitionPenalty, 1.05)
        XCTAssertEqual(model.maxCompletionTokens, 16384)
        XCTAssertTrue(model.isModerated == true)
        XCTAssertEqual(model.expirationDateRaw, "2027-12-31")
    }

    func testOpenRouterKeyResponseDecodes() throws {
        let json = """
        {
          "data": {
            "label": "Noema Test Key",
            "limit": 25,
            "usage": 1.5,
            "usage_daily": 0.2,
            "usage_weekly": 0.6,
            "usage_monthly": 1.5,
            "byok_usage": 0,
            "byok_usage_daily": 0,
            "byok_usage_weekly": 0,
            "byok_usage_monthly": 0,
            "is_free_tier": false,
            "is_management_key": false,
            "is_provisioning_key": false,
            "limit_remaining": 23.5,
            "limit_reset": "monthly",
            "include_byok_in_limit": false,
            "expires_at": "2027-01-01T00:00:00Z"
          }
        }
        """

        let decoded = try JSONDecoder().decode(OpenRouterKeyResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.data.label, "Noema Test Key")
        XCTAssertEqual(decoded.data.limitRemaining, 23.5)
        XCTAssertFalse(decoded.data.isFreeTier)
        XCTAssertEqual(decoded.data.expiresAt, "2027-01-01T00:00:00Z")
    }

    @MainActor
    func testRemoteSettingsNormalizeBlankSystemPromptOverride() {
        let filename = "installed-\(UUID().uuidString).json"
        defer {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(filename))
        }

        let manager = AppModelManager(store: InstalledModelsStore(filename: filename))
        let backendID = UUID()
        let model = RemoteModel(
            id: "openrouter/test-model",
            name: "Test Model",
            author: "OpenRouter",
            compatibilityType: "gguf",
            maxContextLength: 8192
        )

        var settings = ModelSettings.default(for: .gguf)
        settings.systemPromptMode = .override
        settings.systemPromptOverride = "   \n"

        manager.saveRemoteSettings(settings, for: backendID, model: model)
        let resolved = manager.remoteSettings(for: backendID, model: model)

        XCTAssertEqual(resolved.systemPromptMode, .inheritGlobal)
        XCTAssertNil(resolved.systemPromptOverride)
    }

    func testOpenRouterCredentialsUseKeychainBackedAuthorizationHeader() throws {
        let backendID = UUID()
        defer { try? RemoteBackendCredentialStore.removeOpenRouterAPIKey(for: backendID) }

        try RemoteBackendCredentialStore.setOpenRouterAPIKey("test-openrouter-key", for: backendID)
        let backend = RemoteBackend(
            id: backendID,
            name: "OpenRouter",
            baseURLString: RemoteBackend.openRouterDefaultBaseURL.absoluteString,
            chatPath: RemoteBackend.EndpointType.openRouter.defaultChatPath,
            modelsPath: RemoteBackend.EndpointType.openRouter.defaultModelsPath,
            endpointType: .openRouter
        )

        XCTAssertEqual(try backend.resolvedAuthorizationHeader(), "Bearer test-openrouter-key")
        XCTAssertTrue(backend.hasAuth)

        XCTAssertTrue(try RemoteBackendCredentialStore.removeOpenRouterAPIKey(for: backendID))
        XCTAssertNil(try backend.resolvedAuthorizationHeader())
    }

    func testOpenRouterChatRequestIncludesHeadersAndParameters() async throws {
        let backendID = UUID()
        defer { try? RemoteBackendCredentialStore.removeOpenRouterAPIKey(for: backendID) }
        try RemoteBackendCredentialStore.setOpenRouterAPIKey("test-openrouter-key", for: backendID)

        let backend = RemoteBackend(
            id: backendID,
            name: "OpenRouter",
            baseURLString: RemoteBackend.openRouterDefaultBaseURL.absoluteString,
            chatPath: RemoteBackend.EndpointType.openRouter.defaultChatPath,
            modelsPath: RemoteBackend.EndpointType.openRouter.defaultModelsPath,
            endpointType: .openRouter
        )

        let service = RemoteChatService(backend: backend, modelID: "openai/gpt-5.2", toolSpecs: [])
        await service.updateOptions(
            stops: ["STOP"],
            temperature: 0.7,
            contextLength: nil,
            topP: 0.8,
            topK: 40,
            minP: 0.1,
            repeatPenalty: 1.1,
            includeTools: false
        )

        let request = try await service.buildChatRequestForTesting(prompt: "Hello")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openrouter-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://noemaai.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"), "NoemaAI")

        let bodyObject = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyObject) as? [String: Any])
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
        XCTAssertEqual(json["top_p"] as? Double, 0.8)
        XCTAssertEqual(json["top_k"] as? Int, 40)
        XCTAssertEqual(json["min_p"] as? Double, 0.1)
        XCTAssertEqual(json["repetition_penalty"] as? Double, 1.1)
        XCTAssertEqual(json["stop"] as? [String], ["STOP"])
    }

    func testOpenRouterStreamingErrorDecodesToRemoteChatError() throws {
        let payload = """
        {
          "id": "cmpl_test",
          "object": "chat.completion.chunk",
          "error": {
            "code": 429,
            "message": "Rate limit exceeded"
          },
          "choices": [
            {
              "index": 0,
              "delta": { "content": "" },
              "finish_reason": "error"
            }
          ]
        }
        """

        let error = try XCTUnwrap(RemoteChatService.openRouterStreamError(from: Data(payload.utf8)))
        switch error {
        case .httpError(let code, let body):
            XCTAssertEqual(code, 429)
            XCTAssertEqual(body, "Rate limit exceeded")
        default:
            XCTFail("Expected httpError")
        }
    }

    func testOpenRouterModelSearchAndFilterHelpers() {
        let model = RemoteModel(
            id: "anthropic/claude-sonnet-4",
            name: "Claude Sonnet 4",
            author: "Anthropic",
            publisher: "Anthropic",
            architecture: "claude · vision",
            maxContextLength: 200000,
            isCustom: false,
            supportedParameters: ["tools", "structured_outputs", "reasoning"],
            promptPricePerMillion: 3.0,
            completionPricePerMillion: 15.0,
            isModerated: true,
            descriptionText: "Multimodal reasoning model"
        )

        XCTAssertTrue(model.matchesOpenRouterSearch("claude"))
        XCTAssertTrue(model.matchesOpenRouterSearch("anthropic reasoning"))
        XCTAssertTrue(model.matchesOpenRouterSearch("structured outputs"))
        XCTAssertTrue(model.matchesOpenRouterFilter(.tools))
        XCTAssertTrue(model.matchesOpenRouterFilter(.structuredOutputs))
        XCTAssertTrue(model.matchesOpenRouterFilter(.reasoning))
        XCTAssertTrue(model.matchesOpenRouterFilter(.vision))
        XCTAssertTrue(model.matchesOpenRouterFilter(.moderated))
        XCTAssertTrue(model.matchesOpenRouterFilter(.hasPricing))
        XCTAssertTrue(model.matchesOpenRouterSupportedParameter("tools"))
        XCTAssertFalse(model.matchesOpenRouterSupportedParameter("top_k"))
    }

    func testOpenRouterDefaultSettingsApplyModelDefaults() throws {
        let model = RemoteModel(
            id: "openai/gpt-5.2",
            name: "GPT-5.2",
            author: "OpenAI",
            isCustom: false,
            defaultTemperature: 0.2,
            defaultTopP: 0.85,
            defaultTopK: 60,
            defaultRepetitionPenalty: 1.15
        )
        let defaults = try XCTUnwrap(model.openRouterDefaultSettings())
        XCTAssertEqual(defaults.temperature, 0.2)
        XCTAssertEqual(defaults.topP, 0.85)
        XCTAssertEqual(defaults.topK, 60)
        XCTAssertEqual(defaults.repetitionPenalty, 1.15)
    }

    @MainActor
    func testOpenRouterFavoritesPersistPerBackend() throws {
        let filename = "installed-\(UUID().uuidString).json"
        let manager = AppModelManager(store: InstalledModelsStore(filename: filename))
        let backendA = UUID()
        let backendB = UUID()
        let modelID = "openai/gpt-5.2"
        defer {
            manager.clearOpenRouterFavorites(for: backendA)
            manager.clearOpenRouterFavorites(for: backendB)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(filename))
        }

        XCTAssertFalse(manager.isOpenRouterFavorite(backendID: backendA, modelID: modelID))
        XCTAssertTrue(manager.toggleOpenRouterFavorite(backendID: backendA, modelID: modelID))
        XCTAssertTrue(manager.isOpenRouterFavorite(backendID: backendA, modelID: modelID))
        XCTAssertFalse(manager.isOpenRouterFavorite(backendID: backendB, modelID: modelID))
        XCTAssertEqual(manager.openRouterFavoriteModelIDs(for: backendA), Set([modelID.lowercased()]))

        XCTAssertFalse(manager.toggleOpenRouterFavorite(backendID: backendA, modelID: modelID))
        XCTAssertFalse(manager.isOpenRouterFavorite(backendID: backendA, modelID: modelID))
    }

    func testModelSettingsRoundTripPreservesAllFields() throws {
        let settings = fullyPopulatedModelSettings()

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ModelSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    func testModelSettingsMigrationFixtureCoversEveryPersistedKey() throws {
        let object = try settingsJSONObject(fullyPopulatedModelSettings())
        let encodedKeys = Set(object.keys)
        let persistedKeys = Set(ModelSettings.CodingKeys.allCases.map(\.rawValue))

        XCTAssertEqual(encodedKeys, persistedKeys)
    }

    func testModelSettingsDecodeToleratesEveryMissingPersistedKey() throws {
        let fullObject = try settingsJSONObject(fullyPopulatedModelSettings())
        let defaultObject = try settingsJSONObject(ModelSettings())

        for key in ModelSettings.CodingKeys.allCases {
            var legacyObject = fullObject
            legacyObject.removeValue(forKey: key.rawValue)

            let data = try JSONSerialization.data(withJSONObject: legacyObject)
            let decoded = try JSONDecoder().decode(ModelSettings.self, from: data)
            let decodedObject = try settingsJSONObject(decoded)

            var expectedObject = fullObject
            if let defaultValue = defaultObject[key.rawValue] {
                expectedObject[key.rawValue] = defaultValue
            } else {
                expectedObject.removeValue(forKey: key.rawValue)
            }

            XCTAssertTrue(
                NSDictionary(dictionary: decodedObject).isEqual(to: expectedObject),
                "Missing \(key.rawValue) should decode with the current default while preserving every other persisted setting"
            )
        }
    }

    func testModelSettingsLegacyDecodeAppliesDefaultsForMissingKeys() throws {
        let legacyObject: [String: Any] = [
            "contextLength": 2048,
            "gpuLayers": 8,
            "cpuThreads": 4,
            "temperature": 0.55,
            "topK": 51,
            "topP": 0.91
        ]

        let data = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(ModelSettings.self, from: data)

        XCTAssertEqual(decoded.contextLength, 2048)
        XCTAssertEqual(decoded.gpuLayers, 8)
        XCTAssertEqual(decoded.cpuThreads, 4)
        XCTAssertEqual(decoded.temperature, 0.55)
        XCTAssertEqual(decoded.topK, 51)
        XCTAssertEqual(decoded.topP, 0.91)
        XCTAssertTrue(decoded.disableWarmup)
        XCTAssertEqual(decoded.speculativeDecoding, .init())
        XCTAssertFalse(decoded.promptCacheEnabled)
        XCTAssertEqual(decoded.tensorOverride, .none)
        XCTAssertEqual(decoded.etBackend, .xnnpack)
        XCTAssertEqual(decoded.afmGuardrails, .permissiveContentTransformations)
    }

    func testModelSettingsExplicitWarmupValueOverridesDefault() throws {
        let disabledData = try JSONSerialization.data(withJSONObject: ["disableWarmup": false])
        let enabledData = try JSONSerialization.data(withJSONObject: ["disableWarmup": true])

        let warmupEnabled = try JSONDecoder().decode(ModelSettings.self, from: disabledData)
        let warmupDisabled = try JSONDecoder().decode(ModelSettings.self, from: enabledData)

        XCTAssertFalse(warmupEnabled.disableWarmup)
        XCTAssertTrue(warmupDisabled.disableWarmup)
    }

    func testLossyLocalModelSettingsPayloadRecoveryKeepsValidEntries() throws {
        var validSettings = ModelSettings()
        validSettings.disableWarmup = false
        validSettings.topK = 77

        let validEntry: [String: Any] = [
            "modelID": "model-a",
            "quantLabel": "Q4_K_M",
            "settings": try settingsJSONObject(validSettings)
        ]
        let invalidEntry: [String: Any] = [
            "modelID": "model-b",
            "quantLabel": "Q8_0",
            "settings": "not-an-object"
        ]
        let payload: [String: Any] = [
            "entries": [validEntry, invalidEntry, "garbage"]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try XCTUnwrap(ModelSettingsPersistenceDecoder.decodeLocalPayload(from: data))
        let entry = try XCTUnwrap(decoded.entries.first { entry in
            entry.modelID == "model-a" && entry.quantLabel == "Q4_K_M"
        })

        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertTrue(decoded.droppedInvalidEntries)
        XCTAssertEqual(entry.settings.topK, 77)
        XCTAssertEqual(entry.settings.disableWarmup, false)
    }

    func testLossyRemoteModelSettingsRecoveryKeepsValidEntries() throws {
        var validSettings = ModelSettings()
        validSettings.disableWarmup = false
        validSettings.temperature = 0.21

        let payload: [String: Any] = [
            "backend-a|model-a": try settingsJSONObject(validSettings),
            "backend-a|model-b": "broken"
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try XCTUnwrap(ModelSettingsPersistenceDecoder.decodeRemoteSettingsMap(from: data))

        XCTAssertEqual(decoded.map.count, 1)
        XCTAssertTrue(decoded.droppedInvalidEntries)
        XCTAssertEqual(decoded.map["backend-a|model-a"]?.temperature, 0.21)
        XCTAssertEqual(decoded.map["backend-a|model-a"]?.disableWarmup, false)
    }

    func testModelSettingsDefaultToSkipWarmupForAllFormats() {
        XCTAssertTrue(ModelSettings.default(for: .gguf).disableWarmup)
        XCTAssertTrue(ModelSettings.default(for: .mlx).disableWarmup)
        XCTAssertTrue(ModelSettings.default(for: .et).disableWarmup)
        XCTAssertTrue(ModelSettings.default(for: .ane).disableWarmup)
        XCTAssertTrue(ModelSettings.default(for: .afm).disableWarmup)
    }

    private func fullyPopulatedModelSettings() -> ModelSettings {
        var settings = ModelSettings()
        settings.contextLength = 8192
        settings.gpuLayers = 24
        settings.cpuThreads = 6
        settings.kvCacheOffload = false
        settings.keepInMemory = false
        settings.useMmap = false
        settings.disableWarmup = false
        settings.flashAttention = true
        settings.seed = 1234
        settings.kCacheQuant = .q8_0
        settings.vCacheQuant = .q5_1
        settings.tokenizerPath = "/tmp/tokenizer.json"
        settings.promptTemplate = "<|im_start|>user"
        settings.temperature = 0.33
        settings.repetitionPenalty = 1.23
        settings.topK = 73
        settings.topP = 0.88
        settings.minP = 0.12
        settings.repeatLastN = 96
        settings.presencePenalty = 0.4
        settings.frequencyPenalty = 0.2
        settings.stopSequences = ["</s>", "<|eot_id|>"]
        settings.speculativeDecoding = .init(helperModelID: "helper-model", mode: .max, value: 96)
        settings.ropeScaling = .init(factor: 2.0, originalContext: 4096, lowFrequency: 0.75, highFrequency: 1.25)
        settings.logitBias = [1: -0.5, 42: 1.0]
        settings.promptCacheEnabled = true
        settings.promptCachePath = "/tmp/prompt-cache.bin"
        settings.promptCacheAll = true
        settings.tensorOverride = .expertsCPU
        settings.moeActiveExperts = 7
        settings.etBackend = .mps
        settings.processingUnitConfiguration = .cpuAndGPU
        settings.afmGuardrails = .default
        settings.systemPromptMode = .override
        settings.systemPromptOverride = "You are concise."
        return settings
    }

    private func settingsJSONObject(_ settings: ModelSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
