import Foundation
#if canImport(CoreAI)
import CoreAI
#endif
#if canImport(CoreAI) && canImport(CoreAILanguageModels)
import CoreAILanguageModels
import Tokenizers
#endif

/// Wraps a non-Sendable value for capture in a @Sendable task closure when the
/// surrounding type already serializes access (single generation at a time).
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

enum CoreAILLMClientError: LocalizedError {
    case unsupportedOS
    case frameworkUnavailable
    case generationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return String(localized: "Core AI models require iOS 27 / macOS 27 or later.")
        case .frameworkUnavailable:
            return String(localized: "The Core AI framework is unavailable in this build (requires Xcode 27+).")
        case .generationUnavailable(let detail):
            return detail
        }
    }
}

/// Sampling configuration derived from the model's `ModelSettings`.
struct CoreAISamplingParams: Sendable {
    var temperature: Float
    var topK: Int
    var topP: Float
    var seed: UInt64?

    static let greedy = CoreAISamplingParams(temperature: 0, topK: 0, topP: 1, seed: nil)

    init(temperature: Float, topK: Int, topP: Float, seed: UInt64?) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.seed = seed
    }

    init(settings: ModelSettings) {
        self.temperature = Float(settings.temperature)
        self.topK = settings.topK
        self.topP = Float(settings.topP)
        self.seed = settings.seed.map { UInt64(bitPattern: Int64($0)) }
    }
}

/// Runs a downloaded or side-loaded Core AI `.aimodel` language model on-device.
///
/// Gated behind `canImport(CoreAI)` + iOS/macOS 27 availability. On older
/// toolchains the Core AI module is absent, so only the fallback path compiles
/// and `load()` throws a clear, actionable error.
final class CoreAILLMClient: @unchecked Sendable {
    private let resolved: CoreAIResolvedModel
    private let settings: ModelSettings
    private var tokenizer: CoreAITokenizer?
    private var systemPrompt: String?

    #if canImport(CoreAI)
    private var loadedModel: Any?       // AIModel (iOS 27+)
    private var loadedFunction: Any?    // InferenceFunction (iOS 27+)
    private var loadedDescriptor: Any?  // InferenceFunctionDescriptor (iOS 27+)
    // Chunked-prefill companion graph (host-cache exports): consumes the prompt
    // in fixed-size token blocks, states handed to the decode graph afterwards.
    private var loadedPrefillModel: Any?       // AIModel (iOS 27+)
    private var loadedPrefillFunction: Any?    // InferenceFunction (iOS 27+)
    private var loadedPrefillDescriptor: Any?  // InferenceFunctionDescriptor (iOS 27+)
    // Session-long decoder (per-token paths). Its in-place KV/SSM state and
    // its fed-token log persist across requests, so the normal chat case —
    // the resent history plus one new message — prefills only the unseen
    // suffix instead of the whole transcript, and the device never has to
    // re-specialize a new state shape mid-session.
    private var activeDecoder: Any?            // CoreAIDecoder (iOS 27+)
    private var activeDecoderBusy = false
    #endif
    #if canImport(CoreAI) && canImport(CoreAILanguageModels)
    // Apple's coreai-models engine stack (pipelined GPU runtime): async encode,
    // on-GPU sampling, device-resident KV — the fast path when the bundle has
    // the LanguageBundle layout. Falls back to the per-token decoder otherwise.
    private var loadedEngine: Any?           // any InferenceEngine (iOS 27+)
    private var loadedEngineTokenizer: Any?  // any Tokenizers.Tokenizer (iOS 27+)
    private var engineEOSTokenIDs: Set<Int32> = []
    #endif

    /// On-device context budget. The export's own limit (variant `metadata.json`,
    /// `language.max_context_length`) caps the user-selected context length; KV
    /// cache is allocated for this many tokens.
    private let maxContextTokens: Int

    init(resolved: CoreAIResolvedModel, settings: ModelSettings = .default(for: .coreai)) {
        self.resolved = resolved
        self.settings = settings
        let requested = max(512, Int(settings.contextLength))
        if let exported = Self.exportedMaxContext(resourceRoot: resolved.resourceRoot) {
            self.maxContextTokens = min(requested, exported)
        } else {
            self.maxContextTokens = requested
        }
    }

    /// Reads `language.max_context_length` from the variant-level `metadata.json`
    /// written by Apple's Core AI export tooling, when present.
    static func exportedMaxContext(resourceRoot: URL) -> Int? {
        let url = resourceRoot.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let language = json["language"] as? [String: Any] else {
            return nil
        }
        if let value = language["max_context_length"] as? Int, value > 0 { return value }
        if let value = (language["max_context_length"] as? NSNumber)?.intValue, value > 0 { return value }
        return nil
    }

    func syncSystemPrompt(_ prompt: String?) async {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        systemPrompt = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func load() async throws {
        // Tokenizer load is OS-independent (pure Foundation) so it validates the
        // side-loaded folder even on builds without the Core AI runtime.
        if let tokenizerURL = resolved.tokenizerURL {
            tokenizer = try CoreAITokenizer(contentsOf: tokenizerURL)
        }

        #if canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            #if canImport(CoreAI) && canImport(CoreAILanguageModels)
            synthesizeLanguageBundleLayoutIfNeeded()
            #endif
            try await loadCoreAIModel()
            return
        }
        throw CoreAILLMClientError.unsupportedOS
        #else
        throw CoreAILLMClientError.frameworkUnavailable
        #endif
    }

    func unload() {
        #if canImport(CoreAI)
        loadedFunction = nil
        loadedModel = nil
        loadedPrefillFunction = nil
        loadedPrefillDescriptor = nil
        loadedPrefillModel = nil
        activeDecoder = nil
        activeDecoderBusy = false
        #endif
        #if canImport(CoreAI) && canImport(CoreAILanguageModels)
        loadedEngine = nil
        loadedEngineTokenizer = nil
        engineEOSTokenIDs = []
        #endif
        tokenizer = nil
    }

    /// Streams generated text token by token. `onPromptProgress` reports
    /// prefill progress in [0, 1] — chiefly useful for static-query exports
    /// (gpu-pipelined / host-cache monoliths) that consume the prompt one
    /// token per forward pass before the first token can stream.
    func textStream(
        from input: LLMInput,
        onPromptProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        let prompt = renderedPrompt(for: input)

        #if canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            #if canImport(CoreAI) && canImport(CoreAILanguageModels)
            if loadedEngine != nil {
                return try engineTextStream(from: input)
            }
            #endif
            return try coreAITextStream(
                prompt: prompt,
                options: input.generationOptions,
                onPromptProgress: onPromptProgress
            )
        }
        throw CoreAILLMClientError.unsupportedOS
        #else
        _ = prompt
        throw CoreAILLMClientError.frameworkUnavailable
        #endif
    }

    // MARK: - Prompt rendering

    private func renderedPrompt(for input: LLMInput) -> String {
        let reasoningEnabled = input.generationOptions.reasoningEnabled
        let body: String
        switch input.content {
        case .plain(let text):
            body = text
        case .messages(let messages):
            return chatTemplate(messages: messages, reasoningEnabled: reasoningEnabled)
        case .multimodal(let text, _):
            body = text
        case .multimodalMessages(let messages, _):
            return chatTemplate(messages: messages, reasoningEnabled: reasoningEnabled)
        }
        let user = ChatMessage(role: "user", content: body)
        return chatTemplate(messages: [user], reasoningEnabled: reasoningEnabled)
    }

    /// Minimal chat wrapper. When the tokenizer exposes Qwen-style markers we use
    /// them; otherwise we fall back to a plain role-prefixed transcript. Full
    /// per-model Jinja templating is a follow-up (needs the LanguageModels runtime).
    private func chatTemplate(messages: [ChatMessage], reasoningEnabled: Bool? = nil) -> String {
        let usesIMStart = tokenizer?.hasToken("<|im_start|>") == true
        var lines: [String] = []
        // Structured history from ChatVM already carries the resolved system
        // prompt (incl. tool guidance); only fall back to the synced copy when
        // the caller didn't provide one.
        let historyHasSystem = messages.contains { $0.role.lowercased() == "system" }
        if let systemPrompt, !historyHasSystem {
            lines.append(wrap(role: "system", content: systemPrompt, imStart: usesIMStart))
        }
        for message in messages {
            lines.append(wrap(role: message.role, content: message.content, imStart: usesIMStart))
        }
        if usesIMStart {
            lines.append("<|im_start|>assistant\n")
            // Qwen-style thinking models open a `<think>` block by default;
            // when reasoning is off, prime an empty block (the official
            // no-think rendering) so the visible answer starts immediately.
            if reasoningEnabled == false, tokenizer?.hasToken("<think>") == true {
                lines.append("<think>\n\n</think>\n\n")
            }
        } else {
            lines.append("assistant: ")
        }
        return lines.joined(separator: usesIMStart ? "" : "\n")
    }

    private func wrap(role: String, content: String, imStart: Bool) -> String {
        if imStart {
            if role.lowercased() == "tool" {
                // ChatML transcripts carry tool results as a user turn wrapping
                // <tool_response> (Qwen convention); a bare `tool` role header
                // is unseen at training time.
                return "<|im_start|>user\n<tool_response>\n\(content)\n</tool_response><|im_end|>\n"
            }
            return "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        return "\(role): \(content)"
    }

    /// Chunk schedule for prompt processing through the decode graph. Static
    /// graphs are fixed at their exported query length. Dynamic-query graphs
    /// accept any length, but every NEW input shape triggers a device
    /// re-specialization — so feed a fixed bucket, then power-of-two remainder
    /// chunks: a handful of shapes total, each compiled once and reused across
    /// prompts, instead of one fresh compile per prompt length.
    private static func prefillChunkSize(remaining: Int, perStep: Int) -> Int {
        guard remaining > 0 else { return 1 }
        guard perStep == Int.max else { return min(max(1, perStep), remaining) }
        let bucket = 32
        if remaining >= bucket { return bucket }
        var size = 1
        while size * 2 <= remaining { size *= 2 }
        return size
    }

    // MARK: - Core AI runtime (iOS 27+)

    #if canImport(CoreAI)
    /// Compute-unit preference derived from the bundle's repo folder, following
    /// the published Core AI export conventions (coreai-model-zoo): `ios-ane/`
    /// bundles are the dynamic graphs proven on the Neural Engine; `ios-gpu/`
    /// static monoliths use fp32 SSM intermediates + custom Metal kernels and
    /// fail ANE specialization ("ANE cannot handle intermediate tensor type
    /// fp32"); `gpu-pipelined/` and `macos/` are GPU graphs. Exact path-component
    /// matches only — substring checks mis-fire on names like "gated-deltanet".
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static func specializationOptions(for modelURL: URL) -> SpecializationOptions {
        let components = Set(modelURL.pathComponents.map { $0.lowercased() })
        if components.contains("ios-ane") {
            #if os(macOS)
            var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
            #else
            // Only pin the ANE when this device actually exposes it to Core AI.
            let preferred: ComputeUnitKind = ComputeUnitKind.availableKinds.contains(.neuralEngine) ? .neuralEngine : .gpu
            var options = SpecializationOptions(preferredComputeUnitKind: preferred)
            #endif
            options.expectFrequentReshapes = true  // dynamic sequence dimension
            return options
        }
        if components.contains("macos") || components.contains("gpu-pipelined") {
            var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
            options.expectFrequentReshapes = true
            return options
        }
        if components.contains("ios-gpu") {
            var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
            options.expectFrequentReshapes = false  // fully static shapes
            return options
        }
        return .default
    }

    /// Documented load flow (Core AI "Managing model specialization and
    /// caching"): check `AIModelCache.default`, otherwise
    /// `AIModel(contentsOf:options:)` — which specializes **and** stores the
    /// result in the default cache automatically. On failure, clear the
    /// possibly-stale/evicted cache entry and retry once; if the preferred
    /// compute unit still can't be specialized for this model on this device,
    /// fall back to `.default` options (compiler picks the units).
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private static func loadSpecializedModel(url: URL, options: SpecializationOptions) async throws -> AIModel {
        if let cached = try? AIModelCache.default.model(for: url, options: options) {
            print("[CoreAI] Specialization cache hit.")
            return cached
        }
        do {
            print("[CoreAI] Specializing model (preferred compute unit: \(String(describing: options.preferredComputeUnitKind)))…")
            return try await AIModel(contentsOf: url, options: options)
        } catch {
            // Clear every cached variant of this model: each SpecializationOptions
            // change leaves its own multi-GB entry behind, and stale/evicted
            // entries are the documented way loads get wedged under storage
            // pressure.
            print("[CoreAI] Specialization failed (\(error)); clearing cached entries for this model and retrying once.")
            try? AIModelCache.default.deleteEntries(for: url)
            do {
                return try await AIModel(contentsOf: url, options: options)
            } catch {
                guard options != .default else { throw error }
                print("[CoreAI] Retry failed (\(error)); falling back to default specialization options.")
                if let cached = try? AIModelCache.default.model(for: url, options: .default) {
                    return cached
                }
                return try await AIModel(contentsOf: url, options: .default)
            }
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func loadCoreAIModel() async throws {
        print("[CoreAI] Loading model bundle: \(resolved.modelURL.path)")
        // Cheap validity pre-flight (no specialization) so a truncated or
        // corrupted download fails with an actionable message instead of a
        // bare AIModelError from the specializer.
        guard AIModelAsset.isValid(at: resolved.modelURL) else {
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "The Core AI model bundle is invalid or incomplete. Delete the model and download it again.")
            )
        }
        #if canImport(CoreAI) && canImport(CoreAILanguageModels)
        // Prefer Apple's pipelined engine runtime (async encode, on-GPU
        // sampling, device-resident KV) whenever the bundle can be opened as a
        // LanguageBundle; the hand-rolled per-token decoder stays as fallback.
        if Self.engineEligible(resourceRoot: resolved.resourceRoot, modelPath: resolved.modelURL.path) {
            do {
                try await loadEngine()
                return
            } catch {
                print("[CoreAI] Engine runtime unavailable for this bundle (\(error)); using the per-token decoder.")
            }
        }
        #endif
        let options = Self.specializationOptions(for: resolved.modelURL)
        // First load specializes (a heavy one-time device compile, cached by
        // content hash); warm loads are near-instant. Logged so a slow first
        // run isn't mistaken for slow prefill.
        let loadStart = Date()
        let model = try await Self.loadSpecializedModel(url: resolved.modelURL, options: options)
        print(String(
            format: "[CoreAI] Model ready in %.2fs; functions: %@",
            Date().timeIntervalSince(loadStart),
            model.functionNames.joined(separator: ",")
        ))
        loadedModel = model

        let functionName = model.functionNames.first ?? "main"
        guard let descriptor = model.functionDescriptor(for: functionName) else {
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "Core AI model has no function named '\(functionName)'.")
            )
        }
        let function: InferenceFunction?
        do {
            function = try model.loadFunction(named: functionName)
        } catch {
            print("[CoreAI] loadFunction('\(functionName)') failed: \(error)")
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "Core AI couldn't load inference function '\(functionName)': \(error.localizedDescription)")
            )
        }
        guard let function else {
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "Core AI inference function '\(functionName)' failed to load.")
            )
        }
        print("[CoreAI] Function '\(functionName)' loaded.")
        print("[CoreAI] Descriptor: \(Self.descriptorSummary(descriptor))")
        loadedFunction = function
        loadedDescriptor = descriptor

        await loadPrefillCompanionIfPresent(decodeDescriptor: descriptor, options: options)
        await prewarmCoreAIModel(function: function, descriptor: descriptor)
    }

    /// Loads the chunked-prefill companion graph next to a host-cache decode
    /// bundle. The companion is the fast prefill path: the q=1 decode graph
    /// consumes one prompt token per forward pass, while the companion takes
    /// fixed-size blocks (16/32 tokens per dispatch) with the same state
    /// contract and hands the states to the decode graph for generation.
    /// Failure is non-fatal — prefill degrades to one token per pass.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func loadPrefillCompanionIfPresent(
        decodeDescriptor: InferenceFunctionDescriptor,
        options: SpecializationOptions
    ) async {
        guard let prefillURL = resolved.prefillModelURL else { return }
        // Only host-cache exports publish companions Noema can drive; the
        // stateful contract has no documented cross-bundle state handoff.
        guard CoreAIDecoder.hostCacheCapacity(in: decodeDescriptor) != nil else { return }
        guard AIModelAsset.isValid(at: prefillURL) else {
            print("[CoreAI] Prefill companion at \(prefillURL.lastPathComponent) is invalid; using q=1 prefill.")
            return
        }
        do {
            let model = try await Self.loadSpecializedModel(url: prefillURL, options: options)
            let functionName = model.functionNames.first ?? "main"
            guard let descriptor = model.functionDescriptor(for: functionName),
                  let function = try model.loadFunction(named: functionName) else {
                print("[CoreAI] Prefill companion has no loadable '\(functionName)' function; using q=1 prefill.")
                return
            }
            loadedPrefillModel = model
            loadedPrefillFunction = function
            loadedPrefillDescriptor = descriptor
            print("[CoreAI] Prefill companion loaded: \(prefillURL.lastPathComponent)")
        } catch {
            print("[CoreAI] Prefill companion failed to load (\(error)); using q=1 prefill.")
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func prewarmCoreAIModel(function: InferenceFunction, descriptor: InferenceFunctionDescriptor) async {
        guard CoreAIDecoder.hostCacheCapacity(in: descriptor) == nil else {
            print("[CoreAI] Skipping prewarm for host-cache graph; it would allocate the static KV cache.")
            return
        }
        guard let warmupID = tokenizer?.encode("hi").first else {
            print("[CoreAI] Skipping prewarm; tokenizer produced no warmup token.")
            return
        }

        let start = Date()
        do {
            // Build the decoder real requests will reuse — full context window,
            // so the session runs ONE state shape, specialized here at load
            // time instead of on the first message — warm it with one step,
            // then rewind it in place.
            let decoder = try CoreAIDecoder(
                function: function,
                descriptor: descriptor,
                maxContext: maxContextTokens,
                sampling: CoreAISamplingParams(settings: settings)
            )
            _ = try await decoder.step(newTokens: [Int32(warmupID)])
            decoder.reset()
            activeDecoder = decoder
            print(String(
                format: "[CoreAI] prewarm: 1 token in %.2fs (context=%d, decoder retained for the session)",
                Date().timeIntervalSince(start),
                maxContextTokens
            ))
        } catch {
            // Prewarm is an optimization only. Some exports reject tiny state
            // allocations even though the normal request path can still run.
            print("[CoreAI] Prewarm skipped after failure: \(error)")
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private static func descriptorSummary(_ descriptor: InferenceFunctionDescriptor) -> String {
        let states = descriptor.stateNames.isEmpty ? "none" : descriptor.stateNames.joined(separator: ",")
        return "inputs=[\(descriptor.inputNames.joined(separator: ","))] outputs=[\(descriptor.outputNames.joined(separator: ","))] states=[\(states)]"
    }

    // MARK: - Apple coreai-models engine runtime (vendored, External/coreai-models)

    #if canImport(CoreAI) && canImport(CoreAILanguageModels)
    /// Bare bundles (`ios-ane/`, `macos/` — a lone `.aimodel` with no variant
    /// metadata) can still ride the engine once the LanguageBundle layout is
    /// synthesized next to them: a `metadata.json` mirroring the export
    /// tooling's schema plus a `tokenizer/` folder populated from the
    /// backfilled tokenizer artifacts. No-op when either already exists or the
    /// folder holds more than one bundle.
    func synthesizeLanguageBundleLayoutIfNeeded() {
        let fm = FileManager.default
        let root = resolved.resourceRoot
        let metadataURL = root.appendingPathComponent("metadata.json")

        let bundles = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { ["aimodel", "aimodelc"].contains($0.pathExtension.lowercased()) } ?? []
        guard bundles.count == 1, let bundleURL = bundles.first else { return }

        if !fm.fileExists(atPath: metadataURL.path) {
            let name = bundleURL.deletingPathExtension().lastPathComponent
            let metadata: [String: Any] = [
                "metadata_version": "0.2",
                "kind": "llm",
                "name": name,
                "assets": ["main": bundleURL.lastPathComponent],
                "language": [
                    "tokenizer": Self.exportedTokenizerID(resourceRoot: root) ?? "",
                    "vocab_size": tokenizer?.vocabularySize ?? 0,
                    "max_context_length": maxContextTokens,
                    "embedded_tokenizer": true,
                    "function_map": ["main": ["main"]],
                ] as [String: Any],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: metadataURL)
                print("[CoreAI] Synthesized LanguageBundle metadata.json for \(name).")
            }
        }

        let tokenizerDir = root.appendingPathComponent("tokenizer", isDirectory: true)
        if !fm.fileExists(atPath: tokenizerDir.path), let tokenizerURL = resolved.tokenizerURL {
            try? fm.createDirectory(at: tokenizerDir, withIntermediateDirectories: true)
            let sourceDir = tokenizerURL.deletingLastPathComponent()
            for fileName in ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "chat_template.jinja", "added_tokens.json", "vocab.json", "merges.txt"] {
                let source = sourceDir.appendingPathComponent(fileName)
                guard fm.fileExists(atPath: source.path) else { continue }
                try? fm.copyItem(at: source, to: tokenizerDir.appendingPathComponent(fileName))
            }
        }
    }

    /// `language.tokenizer` hint (HF repo id of the base tokenizer) from any
    /// metadata the download backfilled, when present.
    private static func exportedTokenizerID(resourceRoot: URL) -> String? {
        let url = resourceRoot.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let language = json["language"] as? [String: Any] else { return nil }
        return language["tokenizer"] as? String
    }

    /// The engine needs the LanguageBundle layout (variant-level metadata.json).
    /// On iOS, `ios-ane` bundles stay on the per-token decoder: their k-means
    /// int8 LUTs are slow on the GPU delegate the pipelined engine would pick,
    /// while the Neural Engine path is the export's proven configuration.
    static func engineEligible(resourceRoot: URL, modelPath: String) -> Bool {
        let metadata = resourceRoot.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return false }
        #if !os(macOS)
        if modelPath.lowercased().contains("ios-ane") { return false }
        #endif
        return true
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func loadEngine() async throws {
        let bundle = try LanguageBundle(at: resolved.resourceRoot)
        let modelURL = try bundle.requireModelURL(for: ModelBundle.ComponentKey.main)
        let config = ModelConfig(
            name: bundle.name,
            tokenizer: bundle.tokenizer,
            vocabSize: bundle.vocabSize,
            maxContextLength: bundle.maxContextLength,
            serializedModel: [bundle.modelAssetPath],
            function: bundle.language.functionMap?.name(for: "main") ?? "main"
        )
        let configData = try JSONEncoder().encode(config)

        // S=1 decode-only exports (the published `gpu-pipelined` bundles) can't
        // take block prefill — partially-written SSM conv/rec states poison the
        // recurrence — so route prefill through pipelined S=1 steps.
        if resolved.modelURL.path.lowercased().contains("pipelined") {
            setenv("COREAI_CHUNK_THRESHOLD", "1", 1)
        }

        print("[CoreAI] Creating inference engine (structure-detected variant)…")
        let engine = try await EngineFactory.createEngine(
            config: configData,
            modelURL: modelURL,
            options: EngineOptions(variant: nil, kvCacheStrategy: .auto)
        )
        print("[CoreAI] Engine variant: \(type(of: engine))")
        // No warmup(): S=1 graphs reject the default warmup shape; the first
        // generate call compiles the kernels instead.

        let tok = try await bundle.loadTokenizer()
        var eos: Set<Int32> = []
        if let id = tok.eosTokenId { eos.insert(Int32(id)) }
        if let local = tokenizer {
            for id in local.eosTokenIDs { eos.insert(Int32(id)) }
        }

        loadedEngine = engine
        loadedEngineTokenizer = tok
        engineEOSTokenIDs = eos
        print("[CoreAI] Engine ready: \(bundle.name), ctx=\(bundle.maxContextLength), vocab=\(bundle.vocabSize)")
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func engineTextStream(from input: LLMInput) throws -> AsyncThrowingStream<String, Error> {
        guard let engine = loadedEngine as? any InferenceEngine,
              let tok = loadedEngineTokenizer as? any Tokenizer else {
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "Core AI engine is not loaded.")
            )
        }

        var messages: [[String: String]] = []
        switch input.content {
        case .plain(let text), .multimodal(let text, _):
            messages.append(["role": "user", "content": text])
        case .messages(let history), .multimodalMessages(let history, _):
            messages.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] })
        }
        // Structured history from ChatVM already carries the resolved system
        // prompt; only fall back to the synced copy when the caller didn't
        // provide one.
        if let systemPrompt, !messages.contains(where: { $0["role"]?.lowercased() == "system" }) {
            messages.insert(["role": "system", "content": systemPrompt], at: 0)
        }

        // The bundle's own chat template (Jinja, via swift-transformers) — exact
        // per-model formatting instead of the minimal ChatML fallback.
        var promptIDs: [Int32]
        if let templated = try? tok.applyChatTemplate(messages: messages) {
            promptIDs = templated.map { Int32($0) }
        } else {
            promptIDs = tok.encode(text: renderedPrompt(for: input)).map { Int32($0) }
        }
        if input.generationOptions.reasoningEnabled == false {
            promptIDs += tok.encode(text: "<think>\n\n</think>\n\n").map { Int32($0) }
        }

        let temperature = Double(settings.temperature)
        let sampling: SamplingConfiguration = temperature <= 0.01
            ? .greedy
            : SamplingConfiguration(
                temperature: temperature,
                topK: settings.topK > 0 ? settings.topK : nil,
                topP: settings.topP > 0 && settings.topP < 1 ? Double(settings.topP) : nil
            )
        // Always finite: the engine generates to maxTokens on its own schedule,
        // and EOS termination happens on our side — an unbounded run would hold
        // the engine for the rest of the context window.
        let inferenceOptions = InferenceOptions(
            maxTokens: input.generationOptions.maxOutputTokens ?? 1024,
            includeLogits: false
        )

        let eosIDs = engineEOSTokenIDs
        let engineBox = UnsafeSendableBox(value: engine)
        let tokBox = UnsafeSendableBox(value: tok)
        let ids = promptIDs

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let engine = engineBox.value
                    let tok = tokBox.value
                    // Noema resends the full history each turn; reset so the
                    // engine's retained KV doesn't double the context. Cross-
                    // turn KV reuse is NOT possible on this engine: the
                    // pipelined GPU loop overshoots the consumer's EOS break by
                    // its pipeline depth (extra tokens land in device-resident
                    // KV and the SSM states, which can't be rolled back), so
                    // the exact fed sequence is unknowable. TTFT here is
                    // inherently historyTokens / decodeRate (S=1 graph).
                    try await engine.reset()
                    let start = Date()
                    let stream = try engine.generate(
                        with: ids,
                        samplingConfiguration: sampling,
                        inferenceOptions: inferenceOptions
                    )
                    var accumIDs: [Int] = []
                    var emitted = ""
                    var firstTokenAt: Date?
                    for try await output in stream {
                        try Task.checkCancellation()
                        if firstTokenAt == nil {
                            firstTokenAt = Date()
                            print(String(
                                format: "[CoreAI][engine] prefill: %d tokens in %.2fs",
                                ids.count, firstTokenAt!.timeIntervalSince(start)
                            ))
                        }
                        if eosIDs.contains(output.tokenId) { break }
                        accumIDs.append(Int(output.tokenId))
                        let full = tok.decode(tokens: accumIDs)
                        if full.count > emitted.count {
                            continuation.yield(String(full.dropFirst(emitted.count)))
                            emitted = full
                        }
                    }
                    let decodeSeconds = Date().timeIntervalSince(firstTokenAt ?? start)
                    print(String(
                        format: "[CoreAI][engine] done: %d tokens in %.2fs (%.1f tok/s)",
                        accumIDs.count, decodeSeconds,
                        decodeSeconds > 0 ? Double(accumIDs.count) / decodeSeconds : 0
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func coreAITextStream(
        prompt: String,
        options: LLMGenerationOptions,
        onPromptProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let tokenizer else {
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "This Core AI model folder is missing a tokenizer.json required for text generation.")
            )
        }
        guard let function = loadedFunction as? InferenceFunction,
              let descriptor = loadedDescriptor as? InferenceFunctionDescriptor else {
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "Core AI inference function failed to load.")
            )
        }

        let tokenizationStart = Date()
        let promptIDs = tokenizer.encode(prompt).map { Int32($0) }
        let tokenizationSeconds = Date().timeIntervalSince(tokenizationStart)
        let hostCacheCapacity = CoreAIDecoder.hostCacheCapacity(in: descriptor)
        // The decoder may cap the window below the user setting (host-cache
        // graphs have a static KV capacity baked into the export).
        let contextWindow = min(maxContextTokens, hostCacheCapacity ?? maxContextTokens)
        guard promptIDs.count < contextWindow else {
            throw CoreAILLMClientError.generationUnavailable(
                String(localized: "The prompt (\(promptIDs.count) tokens) doesn't fit this Core AI model's context window (\(contextWindow) tokens). Start a new chat or shorten the message.")
            )
        }
        let budget = max(0, contextWindow - promptIDs.count)
        let maxNewTokens = min(options.maxOutputTokens ?? 512, budget)

        let decoderStart = Date()
        // One decoder serves the whole session. When the new prompt extends
        // the already-fed token sequence (resent history + a new message),
        // prefill skips straight to the unseen suffix; otherwise the instance
        // is rewound in place, keeping its buffers and the state shapes the
        // device has already specialized. A fresh decoder per request would
        // re-prefill the entire transcript one token per pass on static-query
        // exports — TTFT growing with every message.
        var reusedTokenCount = 0
        let decoder: CoreAIDecoder
        let ownsActiveDecoder: Bool
        if !activeDecoderBusy, let cached = activeDecoder as? CoreAIDecoder,
           cached.maxContext == contextWindow {
            if !cached.fedTokens.isEmpty,
               promptIDs.count > cached.fedTokens.count,
               promptIDs.starts(with: cached.fedTokens) {
                reusedTokenCount = cached.fedTokens.count
            } else {
                cached.reset()
            }
            decoder = cached
            ownsActiveDecoder = true
        } else {
            decoder = try CoreAIDecoder(
                function: function,
                descriptor: descriptor,
                maxContext: contextWindow,
                sampling: CoreAISamplingParams(settings: settings),
                prefillFunction: loadedPrefillFunction as? InferenceFunction,
                prefillDescriptor: loadedPrefillDescriptor as? InferenceFunctionDescriptor
            )
            // Don't displace a decoder another request is still driving.
            ownsActiveDecoder = !activeDecoderBusy
            if ownsActiveDecoder { activeDecoder = decoder }
        }
        if ownsActiveDecoder { activeDecoderBusy = true }
        let decoderInitSeconds = Date().timeIntervalSince(decoderStart)
        if decoder.isGreedyOnly {
            print("[CoreAI] This export argmaxes in-graph (head_pv/head_pi); decoding greedily — temperature/top-k/top-p don't apply.")
        }
        print(String(
            format: "[CoreAI] request: bundle=%@ prompt=%d reused=%d context=%d maxNew=%d hostCache=%@ prefill=%@ tokenization=%.3fs decoderInit=%.3fs",
            resolved.modelURL.lastPathComponent,
            promptIDs.count,
            reusedTokenCount,
            decoder.maxContext,
            maxNewTokens,
            hostCacheCapacity == nil ? "no" : "yes",
            decoder.prefillBlockSize.map { "q\($0) blocks" } ?? "per-step",
            tokenizationSeconds,
            decoderInitSeconds
        ))

        let reusedTokens = reusedTokenCount
        let ownsDecoder = ownsActiveDecoder
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { if ownsDecoder { self.activeDecoderBusy = false } }
                do {
                    guard !promptIDs.isEmpty else { continuation.finish(); return }

                    // Prefill. The chunked-prefill companion consumes the prompt
                    // in FULL q-token blocks (one weight pass per block instead
                    // of per token) over prompt[0..M-2]; the last prompt token
                    // and any remainder go through the decode graph, which also
                    // samples the first generated token. Without a companion,
                    // static graphs run at their exported query length (q=1 for
                    // host-cache monoliths — the slow path that must honor Stop)
                    // and dynamic graphs take fixed buckets.
                    let prefillStart = Date()
                    let blockSize = decoder.prefillBlockSize
                    var nextID = 0
                    var offset = reusedTokens
                    if reusedTokens > 0 {
                        print("[CoreAI] cache hit: \(reusedTokens) tokens already in state; prefilling \(promptIDs.count - reusedTokens) new")
                    }
                    onPromptProgress?(Double(offset) / Double(promptIDs.count))
                    if let blockSize {
                        while promptIDs.count - 1 - offset >= blockSize {
                            try Task.checkCancellation()
                            try await decoder.prefillBlock(
                                newTokens: Array(promptIDs[offset..<offset + blockSize])
                            )
                            offset += blockSize
                            onPromptProgress?(Double(offset) / Double(promptIDs.count))
                        }
                    }
                    while offset < promptIDs.count {
                        try Task.checkCancellation()
                        let chunk = Self.prefillChunkSize(
                            remaining: promptIDs.count - offset,
                            perStep: decoder.maxInputTokensPerStep
                        )
                        let end = offset + chunk
                        nextID = try await decoder.step(newTokens: Array(promptIDs[offset..<end]))
                        offset = end
                        onPromptProgress?(Double(offset) / Double(promptIDs.count))
                    }
                    let decodeStart = Date()
                    let prefillSeconds = decodeStart.timeIntervalSince(prefillStart)
                    let prefillMode: String
                    if let blockSize {
                        prefillMode = "q\(blockSize) blocks + q=1 remainder"
                    } else if decoder.maxInputTokensPerStep == 1 {
                        prefillMode = "1 token/pass"
                    } else {
                        prefillMode = "chunked"
                    }
                    let prefilled = promptIDs.count - reusedTokens
                    print(String(
                        format: "[CoreAI] prefill: %d new tokens (%d cached) in %.2fs = %.1f tok/s (%@)",
                        prefilled,
                        reusedTokens,
                        prefillSeconds,
                        prefillSeconds > 0 ? Double(prefilled) / prefillSeconds : 0,
                        prefillMode
                    ))

                    var generated = 0
                    var generatedIDs: [Int] = []
                    var emittedText = ""

                    while generated < maxNewTokens {
                        if Task.isCancelled { break }
                        if tokenizer.eosTokenIDs.contains(nextID) {
                            if generated == 0 {
                                print("[CoreAI] first sampled token is EOS (id \(nextID)) — empty response. Check the chat template / prompt rendering.")
                            }
                            break
                        }

                        generatedIDs.append(nextID)
                        generated += 1

                        // Decode the full generated suffix and emit only the delta so
                        // multi-byte tokens render correctly.
                        let full = tokenizer.decode(generatedIDs)
                        if full.count > emittedText.count {
                            continuation.yield(String(full.dropFirst(emittedText.count)))
                            emittedText = full
                        }
                        if generated == 8 {
                            let head = String(full.prefix(60)).replacingOccurrences(of: "\n", with: "\\n")
                            print("[CoreAI] first tokens: \"\(head)\"")
                        }

                        // Decode step: feed only the new token; the states hold the past.
                        nextID = try await decoder.step(newTokens: [Int32(nextID)])
                    }
                    let decodeSeconds = Date().timeIntervalSince(decodeStart)
                    let preview = String(emittedText.suffix(80)).replacingOccurrences(of: "\n", with: "\\n")
                    print(String(
                        format: "[CoreAI] done: %d tokens in %.2fs (%.1f tok/s), emitted %d chars, tail: \"%@\"",
                        generated, decodeSeconds,
                        decodeSeconds > 0 ? Double(generated) / decodeSeconds : 0,
                        emittedText.count, preview
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Stop generating when the consumer cancels or stops iterating;
            // the loop checks Task.isCancelled between decode steps.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}

#if canImport(CoreAI)

// MARK: - fp16 host storage

// `Float16` is the Swift stdlib half type, but it is marked
// `@available(macOS, unavailable)` / `@available(macCatalyst, unavailable)` on
// the **x86_64** Apple slices (the half type isn't in that C ABI). The arm64
// macOS slice — the one that actually runs Core AI on Apple Silicon — has it.
// Core AI's fp16 tensors still need 16-bit host-side storage on every slice the
// universal binary compiles, so on the x86_64 fallback we hold the raw
// IEEE-754 binary16 *bits* in `UInt16` and reinterpret the NDArray buffers as
// `UInt16` (a byte-for-byte view of the same fp16 storage). The K/V and SSM
// carries are pure bit shuffles that never inspect values; only the additive
// mask (writes constants) and the logits / argmax reads convert via
// `CoreAIHalfCodec`. Wherever `Float16` exists the alias *is* `Float16` and the
// codec is the identity-cheap stdlib initializer, so the real targets are
// byte-identical to before.
#if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
typealias CoreAIHalf = UInt16

enum CoreAIHalfCodec {
    /// IEEE-754 binary16 bits → Float32 (magic-multiply renormalization that
    /// handles subnormals / Inf / NaN). Fabian Giesen's `half_to_float`.
    /// Verified bit-exact against native `Float16` over all 65 536 patterns.
    @inline(__always) static func float(_ half: CoreAIHalf) -> Float {
        let h = UInt32(half)
        let magic = Float(bitPattern: 0x7780_0000)       // (254-15) << 23  == 2^112
        let wasInfNan = Float(bitPattern: 0x4780_0000)   // (127+16) << 23
        var out = Float(bitPattern: (h & 0x7fff) << 13)
        out *= magic
        var bits = out.bitPattern
        if out >= wasInfNan { bits |= 0x7F80_0000 }      // 255 << 23 (all-ones exponent)
        bits |= (h & 0x8000) << 16
        return Float(bitPattern: bits)
    }

    /// Float32 → IEEE-754 binary16 bits, round-to-nearest-even. Fabian Giesen's
    /// `float_to_half_fast3_rtne`. Verified bit-exact against native `Float16`.
    @inline(__always) static func half(_ value: Float) -> CoreAIHalf {
        let f32infty: UInt32 = 0x7F80_0000               // 255 << 23
        let f16max: UInt32 = 0x4780_0000                 // (127+16) << 23
        let denormMagic = Float(bitPattern: 0x3F00_0000) // ((127-15)+(23-10)+1) << 23 == 0.5
        let signMask: UInt32 = 0x8000_0000
        var f = value.bitPattern
        let sign = f & signMask
        f ^= sign
        let out: UInt32
        if f >= f16max {
            out = (f > f32infty) ? 0x7e00 : 0x7c00       // NaN → qNaN, Inf → Inf
        } else if f < 0x3880_0000 {                      // 113 << 23: subnormal / zero
            let renorm = Float(bitPattern: f) + denormMagic
            out = renorm.bitPattern &- denormMagic.bitPattern
        } else {
            let mantOdd = (f >> 13) & 1                   // round to nearest even
            f &+= 0xC800_0FFF                             // ((-112) << 23) &+ 0xfff: exp rebias + round
            f &+= mantOdd
            out = f >> 13
        }
        return UInt16(truncatingIfNeeded: out) | UInt16(truncatingIfNeeded: sign >> 16)
    }
}
#else
typealias CoreAIHalf = Float16

enum CoreAIHalfCodec {
    @inline(__always) static func float(_ half: CoreAIHalf) -> Float { Float(half) }
    @inline(__always) static func half(_ value: Float) -> CoreAIHalf { Float16(value) }
}
#endif

/// Decoder for a Core AI language model. Two export contracts are supported:
///
/// **Stateful** (as used by `apple/coreai-models`): 2 inputs (`input_ids` Int32,
/// `position_ids` Int32), 1 output (`logits`, float16/float32), and N Core AI
/// states updated in place across steps — classic attention exports carry 2 (KV
/// cache); hybrid-SSM exports (e.g. Qwen3.5's gated-deltanet) add conv/recurrent
/// states. All states are allocated once with dynamic dimensions resolved to
/// `maxContext` and passed back each step.
///
/// **Host-cache** (the "hc" static monoliths from coreai-model-zoo, e.g. the
/// `ios-gpu/` bundles of `mlboydaisuke/qwen3.5-0.8B-CoreAI`): the caches ride as
/// plain I/O (`causal_mask`/`past_k`/`past_v` [+ `conv_state`/`rec_state`] in,
/// `k_cur`/`v_cur` [+ `conv_cur`/`rec_cur`] out) because the ANE compiler
/// rejects in-graph indexed KV writes. The host writes each step's K/V column
/// back at `position` and threads the SSM states. Fused-kernel exports replace
/// logits with two-level GPU argmax partials (`head_pv`/`head_pi`) — greedy-only.
///
/// Sampling honors temperature / top-k / top-p when logits are available,
/// falling back to greedy argmax.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
final class CoreAIDecoder: @unchecked Sendable {
    private let function: InferenceFunction
    private let inputIdsName: String
    private let positionIdsName: String
    private let logitsName: String?
    private let inputIdsDescriptor: NDArrayDescriptor
    private let positionIdsDescriptor: NDArrayDescriptor
    private let logitsDescriptor: NDArrayDescriptor?
    private let logitsScalarType: NDArray.ScalarType?
    private let vocabSize: Int
    /// Effective context window: the requested budget, additionally capped by a
    /// host-cache graph's static KV capacity.
    let maxContext: Int
    private let sampling: CoreAISamplingParams
    private var rng: SplitMix64
    /// Non-nil when the graph follows the host-cache contract.
    private let hostCache: HostCacheRuntime?
    /// Non-nil when a chunked-prefill companion graph is loaded alongside a
    /// host-cache decode graph — the fast prefill path.
    private let prefillRuntime: PrefillRuntime?
    /// Tiny NDArray parked in `stateArrays` slots while a step runs so the
    /// working copy is the unique owner of the state buffer — otherwise the
    /// runtime's in-place state update copy-on-writes the entire KV/SSM cache
    /// (tens of MB) every step.
    private let statePlaceholder: NDArray

    /// True when the export's head argmaxes in-graph: temperature/top-k/top-p
    /// can't apply, decoding is always greedy.
    var isGreedyOnly: Bool { hostCache?.argmaxHead == true }

    /// Largest token batch a single forward pass accepts. Dynamic exports
    /// (negative sequence dimension) take any length; static decode graphs are
    /// fixed at their exported query length (usually 1).
    let maxInputTokensPerStep: Int

    /// Token block size of the chunked-prefill companion graph, when loaded.
    /// The prompt should be fed in FULL blocks of this size via
    /// `prefillBlock(newTokens:)` — the remainder (and the last prompt token)
    /// go through `step(newTokens:)` on the decode graph.
    var prefillBlockSize: Int? { prefillRuntime?.blockSize }

    private let stateNames: [String]
    private var stateArrays: [NDArray]
    private var processedTokenCount = 0

    /// Every token fed through the graph, in order (prompt + generated tokens
    /// that seeded subsequent steps). The KV/SSM state is exactly the state
    /// after this sequence — a new request whose prompt extends it can skip
    /// straight to the unseen suffix instead of re-prefilling the whole
    /// history ("states are mutated in place across calls — reuse the same
    /// buffers to persist KV/SSM state").
    private(set) var fedTokens: [Int32] = []

    static func hostCacheCapacity(in descriptor: InferenceFunctionDescriptor) -> Int? {
        guard Set(descriptor.inputNames).isSuperset(of: HostCacheRuntime.requiredInputs),
              case .ndArray(let pastK) = descriptor.inputDescriptor(of: "past_k"),
              pastK.shape.count == 5,
              pastK.shape[3] > 0 else {
            return nil
        }
        return pastK.shape[3]
    }

    init(
        function: InferenceFunction,
        descriptor: InferenceFunctionDescriptor,
        maxContext: Int,
        sampling: CoreAISamplingParams = .greedy,
        prefillFunction: InferenceFunction? = nil,
        prefillDescriptor: InferenceFunctionDescriptor? = nil
    ) throws {
        self.function = function
        self.sampling = sampling
        self.rng = SplitMix64(seed: sampling.seed ?? UInt64.random(in: UInt64.min...UInt64.max))

        // Host-cache contract: caches as plain I/O, detected by input names.
        if Set(descriptor.inputNames).isSuperset(of: HostCacheRuntime.requiredInputs) {
            let runtime = try HostCacheRuntime(descriptor: descriptor)
            self.hostCache = runtime
            if let prefillFunction, let prefillDescriptor {
                self.prefillRuntime = PrefillRuntime(
                    function: prefillFunction,
                    descriptor: prefillDescriptor,
                    decode: runtime
                )
            } else {
                self.prefillRuntime = nil
            }
            self.inputIdsName = HostCacheRuntime.inputIdsName
            self.positionIdsName = HostCacheRuntime.positionIdsName
            self.inputIdsDescriptor = runtime.idsDescriptor
            self.positionIdsDescriptor = runtime.posDescriptor
            self.logitsName = runtime.logitsName
            self.logitsDescriptor = runtime.logitsDescriptor
            self.logitsScalarType = runtime.logitsDescriptor?.scalarType
            self.vocabSize = runtime.vocabSize
            self.maxInputTokensPerStep = 1
            self.maxContext = min(maxContext, runtime.capacity)
            self.stateNames = []
            self.stateArrays = []
            self.statePlaceholder = NDArray(descriptor: runtime.idsDescriptor)
            return
        }

        self.hostCache = nil
        self.prefillRuntime = nil
        self.maxContext = maxContext

        guard descriptor.inputNames.count == 2 else {
            throw CoreAILLMClientError.generationUnavailable(
                "Core AI model exposes inputs [\(descriptor.inputNames.joined(separator: ", "))]; Noema supports the stateful contract (input_ids, position_ids) and the host-cache contract (input_ids, position_ids, causal_mask, past_k, past_v [, conv_state, rec_state])."
            )
        }
        guard let firstOutput = descriptor.outputNames.first else {
            throw CoreAILLMClientError.generationUnavailable("Core AI model exposes no outputs.")
        }

        let inputIdsName = descriptor.inputNames[0]
        let positionIdsName = descriptor.inputNames[1]
        self.inputIdsName = inputIdsName
        self.positionIdsName = positionIdsName
        self.logitsName = firstOutput

        guard case .ndArray(let inDesc) = descriptor.inputDescriptor(of: inputIdsName) else {
            throw CoreAILLMClientError.generationUnavailable("Core AI input '\(inputIdsName)' is not an NDArray.")
        }
        guard case .ndArray(let posDesc) = descriptor.inputDescriptor(of: positionIdsName) else {
            throw CoreAILLMClientError.generationUnavailable("Core AI input '\(positionIdsName)' is not an NDArray.")
        }
        guard case .ndArray(let logDesc) = descriptor.outputDescriptor(of: firstOutput) else {
            throw CoreAILLMClientError.generationUnavailable("Core AI output '\(firstOutput)' is not an NDArray.")
        }

        self.inputIdsDescriptor = inDesc
        self.positionIdsDescriptor = posDesc
        self.logitsDescriptor = logDesc
        self.logitsScalarType = logDesc.scalarType
        self.statePlaceholder = NDArray(descriptor: inDesc.resolvingDynamicDimensions([1, 1]))
        if let seqDim = inDesc.shape.last, seqDim > 0 {
            self.maxInputTokensPerStep = seqDim
        } else {
            self.maxInputTokensPerStep = Int.max
        }

        guard let vocab = logDesc.shape.last, vocab > 0 else {
            throw CoreAILLMClientError.generationUnavailable("Core AI logits have an unresolved vocabulary dimension.")
        }
        // A tiny last dimension means the export samples in-graph (argmax head)
        // rather than returning logits; sampling from it would silently emit
        // garbage tokens.
        guard vocab >= 256 else {
            throw CoreAILLMClientError.generationUnavailable(
                "Core AI output '\(firstOutput)' has last dimension \(vocab) — this export returns sampled token ids instead of logits, which Noema's stateful path can't decode."
            )
        }
        self.vocabSize = vocab

        // Allocate every state for the full context window, resolving dynamic
        // sequence dimensions (negative entries) to `maxContext`. Fixed-shape
        // states (e.g. SSM conv/recurrent states) come through unchanged.
        var names: [String] = []
        var arrays: [NDArray] = []
        names.reserveCapacity(descriptor.stateNames.count)
        arrays.reserveCapacity(descriptor.stateNames.count)
        for name in descriptor.stateNames {
            guard case .ndArray(let stateDesc) = descriptor.stateDescriptor(of: name) else {
                throw CoreAILLMClientError.generationUnavailable("Core AI state '\(name)' descriptor is unavailable.")
            }
            let resolved = stateDesc.resolvingDynamicDimensions(stateDesc.shape.map { $0 < 0 ? maxContext : $0 })
            var array = NDArray(descriptor: resolved)
            Self.zero(&array, scalarType: resolved.scalarType)
            names.append(name)
            arrays.append(array)
        }
        self.stateNames = names
        self.stateArrays = arrays
    }

    /// Runs one forward pass over `newTokens` and returns the sampled next-token id.
    func step(newTokens: [Int32]) async throws -> Int {
        let batchSize = newTokens.count
        guard batchSize > 0 else {
            throw CoreAILLMClientError.generationUnavailable("Core AI decode step received no tokens.")
        }
        let totalPositions = processedTokenCount + batchSize
        guard totalPositions <= maxContext else {
            throw CoreAILLMClientError.generationUnavailable("Core AI context window (\(maxContext)) exceeded.")
        }

        if let hostCache {
            guard batchSize == 1 else {
                throw CoreAILLMClientError.generationUnavailable(
                    "Core AI host-cache decode accepts 1 token per step; got \(batchSize)."
                )
            }
            let next = try await hostCacheStep(hostCache, token: newTokens[0], position: processedTokenCount)
            processedTokenCount = totalPositions
            fedTokens.append(contentsOf: newTokens)
            return next
        }

        guard let logitsName, let logitsDescriptor else {
            throw CoreAILLMClientError.generationUnavailable("Core AI logits output is unavailable.")
        }

        // input_ids: [1, batchSize] = the new tokens.
        var inputIds = NDArray(descriptor: inputIdsDescriptor.resolvingDynamicDimensions([1, batchSize]))
        Self.fillInt32(&inputIds, newTokens)

        // position_ids semantics differ between exports: dynamic graphs take all
        // absolute positions 0..<totalPositions; static graphs take only the new
        // tokens' positions. Pick by the resolved tensor's capacity.
        let resolvedPos = positionIdsDescriptor.resolvingDynamicDimensions([1, totalPositions])
        let posCapacity = resolvedPos.shape.reduce(1, *)
        var positionIds = NDArray(descriptor: resolvedPos)
        if posCapacity == totalPositions {
            Self.fillInt32(&positionIds, (0..<totalPositions).map { Int32($0) })
        } else if posCapacity == batchSize {
            Self.fillInt32(&positionIds, (processedTokenCount..<totalPositions).map { Int32($0) })
        } else {
            throw CoreAILLMClientError.generationUnavailable(
                "Core AI position_ids shape \(resolvedPos.shape) doesn't match \(batchSize) new tokens (\(totalPositions) total)."
            )
        }

        // logits: [1, batchSize, vocab].
        var logits = NDArray(descriptor: logitsDescriptor.resolvingDynamicDimensions([1, batchSize, vocabSize]))

        try await runStep(inputIds: inputIds, positionIds: positionIds, logits: &logits, logitsName: logitsName)

        processedTokenCount = totalPositions
        fedTokens.append(contentsOf: newTokens)
        return sampleLastToken(logits, batchSize: batchSize)
    }

    /// Rewinds the decoder to an empty sequence in place: states re-zeroed,
    /// counters cleared. Reusing the instance keeps the allocated buffers and
    /// — critically — the graph shapes the device already specialized for, so
    /// a fresh conversation doesn't pay a re-compile.
    func reset() {
        for index in stateArrays.indices {
            Self.zero(&stateArrays[index], scalarType: stateArrays[index].scalarType)
        }
        if let hc = hostCache {
            hc.hostK.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            hc.hostV.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            if let convDescriptor = hc.convDescriptor, let recDescriptor = hc.recDescriptor {
                var conv = NDArray(descriptor: convDescriptor)
                Self.zero(&conv, scalarType: convDescriptor.scalarType)
                var rec = NDArray(descriptor: recDescriptor)
                Self.zero(&rec, scalarType: recDescriptor.scalarType)
                hc.convState = conv
                hc.recState = rec
            }
        }
        if let runtime = prefillRuntime {
            runtime.convCarry.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            runtime.recCarry.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            runtime.pendingHandoff = false
        }
        processedTokenCount = 0
        fedTokens = []
    }

    /// One forward pass of the chunked-prefill companion graph over a FULL
    /// block of `prefillBlockSize` prompt tokens (one weight pass per block
    /// instead of per token). Returns no sample — the last prompt token must
    /// go through `step(newTokens:)` so the decode graph produces the first
    /// generated token. Mirrors the reference runner (coreai-model-zoo
    /// QwenChatFast/FastEngine.swift): K/V columns scattered back at the block
    /// positions, conv/rec carried host-side at block rate, handed to the
    /// decode graph once before its first step.
    func prefillBlock(newTokens: [Int32]) async throws {
        guard let hc = hostCache, let runtime = prefillRuntime else {
            throw CoreAILLMClientError.generationUnavailable(
                "Core AI block prefill requires a host-cache graph with a loaded prefill companion."
            )
        }
        let q = runtime.blockSize
        guard newTokens.count == q else {
            throw CoreAILLMClientError.generationUnavailable(
                "Core AI prefill block takes exactly \(q) tokens; got \(newTokens.count)."
            )
        }
        let position = processedTokenCount
        guard position + q <= maxContext else {
            throw CoreAILLMClientError.generationUnavailable("Core AI context window (\(maxContext)) exceeded.")
        }

        var ids = NDArray(descriptor: runtime.idsDescriptor)
        Self.fillInt32(&ids, newTokens)
        var positionIds = NDArray(descriptor: runtime.posDescriptor)
        Self.fillInt32(&positionIds, (position..<position + q).map { Int32($0) })
        var mask = NDArray(descriptor: runtime.maskDescriptor)
        Self.fillFloat16(&mask, Self.prefillMask(position: position, blockSize: q, capacity: hc.capacity))
        var pastK = NDArray(descriptor: runtime.pastKDescriptor)
        Self.fillFloat16(&pastK, hc.hostK)
        var pastV = NDArray(descriptor: runtime.pastVDescriptor)
        Self.fillFloat16(&pastV, hc.hostV)

        var inputs: [String: NDArray] = [
            HostCacheRuntime.inputIdsName: ids,
            HostCacheRuntime.positionIdsName: positionIds,
            "causal_mask": mask,
            "past_k": pastK,
            "past_v": pastV
        ]
        if let convDescriptor = runtime.convDescriptor, let recDescriptor = runtime.recDescriptor {
            // The decode graph owns the live conv/rec states between requests;
            // the carries are only authoritative mid-block-run (pendingHandoff).
            // On a reused session the recurrence has advanced through decode
            // steps since the last block — re-sync or the blocks would resume
            // from a stale recurrence.
            if !runtime.pendingHandoff, let conv = hc.convState, let rec = hc.recState {
                runtime.convCarry = Self.readScalars(conv, as: CoreAIHalf.self)
                runtime.recCarry = Self.readScalars(rec, as: CoreAIHalf.self)
            }
            var conv = NDArray(descriptor: convDescriptor)
            Self.fillFloat16(&conv, runtime.convCarry)
            var rec = NDArray(descriptor: recDescriptor)
            Self.fillFloat16(&rec, runtime.recCarry)
            inputs["conv_state"] = conv
            inputs["rec_state"] = rec
        }

        var outputs = try await runtime.function.run(inputs: inputs)

        if let kCur = outputs.remove("k_cur")?.ndArray,
           let vCur = outputs.remove("v_cur")?.ndArray {
            Self.writeColumns(
                into: &hc.hostK, block: Self.readScalars(kCur, as: CoreAIHalf.self),
                layers: hc.layers, kvHeads: hc.kvHeads, capacity: hc.capacity,
                headDim: hc.headDim, position: position, columns: q
            )
            Self.writeColumns(
                into: &hc.hostV, block: Self.readScalars(vCur, as: CoreAIHalf.self),
                layers: hc.layers, kvHeads: hc.kvHeads, capacity: hc.capacity,
                headDim: hc.headDim, position: position, columns: q
            )
        }
        if runtime.convDescriptor != nil {
            if let conv = outputs.remove("conv_cur")?.ndArray {
                runtime.convCarry = Self.readScalars(conv, as: CoreAIHalf.self)
            }
            if let rec = outputs.remove("rec_cur")?.ndArray {
                runtime.recCarry = Self.readScalars(rec, as: CoreAIHalf.self)
            }
            runtime.pendingHandoff = true
        }
        processedTokenCount = position + q
        fedTokens.append(contentsOf: newTokens)
    }

    /// One forward pass of a host-cache graph: fill the static inputs from the
    /// host caches, run, write the returned K/V column back at `position`,
    /// thread the SSM states, and pick the next token.
    private func hostCacheStep(_ hc: HostCacheRuntime, token: Int32, position: Int) async throws -> Int {
        // Block prefill ran: seed the decode graph's SSM states from the
        // companion's final carry before the first decode step.
        if let runtime = prefillRuntime, runtime.pendingHandoff,
           let convDescriptor = hc.convDescriptor, let recDescriptor = hc.recDescriptor {
            var conv = NDArray(descriptor: convDescriptor)
            Self.fillFloat16(&conv, runtime.convCarry)
            var rec = NDArray(descriptor: recDescriptor)
            Self.fillFloat16(&rec, runtime.recCarry)
            hc.convState = conv
            hc.recState = rec
            runtime.pendingHandoff = false
        }
        var ids = NDArray(descriptor: hc.idsDescriptor)
        Self.fillInt32(&ids, [token])
        var positionIds = NDArray(descriptor: hc.posDescriptor)
        Self.fillInt32(&positionIds, [Int32(position)])
        var mask = NDArray(descriptor: hc.maskDescriptor)
        Self.fillFloat16(&mask, Self.causalMask(position: position, width: hc.maskWidth))
        var pastK = NDArray(descriptor: hc.pastKDescriptor)
        Self.fillFloat16(&pastK, hc.hostK)
        var pastV = NDArray(descriptor: hc.pastVDescriptor)
        Self.fillFloat16(&pastV, hc.hostV)

        var inputs: [String: NDArray] = [
            HostCacheRuntime.inputIdsName: ids,
            HostCacheRuntime.positionIdsName: positionIds,
            "causal_mask": mask,
            "past_k": pastK,
            "past_v": pastV
        ]
        if hc.hasConvRec, let conv = hc.convState, let rec = hc.recState {
            inputs["conv_state"] = conv
            inputs["rec_state"] = rec
        }

        var outputs = try await function.run(inputs: inputs)

        if let kCur = outputs.remove("k_cur")?.ndArray,
           let vCur = outputs.remove("v_cur")?.ndArray {
            Self.writeColumn(
                into: &hc.hostK, column: Self.readScalars(kCur, as: CoreAIHalf.self),
                layers: hc.layers, kvHeads: hc.kvHeads, capacity: hc.capacity,
                headDim: hc.headDim, position: position
            )
            Self.writeColumn(
                into: &hc.hostV, column: Self.readScalars(vCur, as: CoreAIHalf.self),
                layers: hc.layers, kvHeads: hc.kvHeads, capacity: hc.capacity,
                headDim: hc.headDim, position: position
            )
        }
        if hc.hasConvRec {
            if let conv = outputs.remove("conv_cur")?.ndArray { hc.convState = conv }
            if let rec = outputs.remove("rec_cur")?.ndArray { hc.recState = rec }
        }

        if hc.argmaxHead {
            guard let values = outputs.remove("head_pv")?.ndArray,
                  let indices = outputs.remove("head_pi")?.ndArray,
                  let next = Self.reduceArgmaxPartials(values: values, indices: indices) else {
                throw CoreAILLMClientError.generationUnavailable("Core AI argmax head returned no usable partials.")
            }
            return next
        }
        guard let logitsName = hc.logitsName,
              let logits = outputs.remove(logitsName)?.ndArray else {
            throw CoreAILLMClientError.generationUnavailable("Core AI host-cache graph returned no logits.")
        }
        return sampleLastToken(logits, batchSize: 1)
    }

    private func runStep(inputIds: NDArray, positionIds: NDArray, logits: inout NDArray, logitsName: String) async throws {
        // `run` accepts a plain [String: NDArray]; InferenceFunction.Inputs is the
        // borrowing zero-copy path and InferenceValue only wraps pixel buffers.
        let inputs: [String: NDArray] = [
            inputIdsName: inputIds,
            positionIdsName: positionIds
        ]

        switch stateArrays.count {
        case 0:
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, outputViews: consume outputViews)
        case 1:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
        case 2:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var state1 = stateArrays[1]
            stateArrays[1] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            states.insert(&state1, for: stateNames[1])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
            stateArrays[1] = state1
        case 3:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var state1 = stateArrays[1]
            stateArrays[1] = statePlaceholder
            var state2 = stateArrays[2]
            stateArrays[2] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            states.insert(&state1, for: stateNames[1])
            states.insert(&state2, for: stateNames[2])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
            stateArrays[1] = state1
            stateArrays[2] = state2
        case 4:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var state1 = stateArrays[1]
            stateArrays[1] = statePlaceholder
            var state2 = stateArrays[2]
            stateArrays[2] = statePlaceholder
            var state3 = stateArrays[3]
            stateArrays[3] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            states.insert(&state1, for: stateNames[1])
            states.insert(&state2, for: stateNames[2])
            states.insert(&state3, for: stateNames[3])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
            stateArrays[1] = state1
            stateArrays[2] = state2
            stateArrays[3] = state3
        case 5:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var state1 = stateArrays[1]
            stateArrays[1] = statePlaceholder
            var state2 = stateArrays[2]
            stateArrays[2] = statePlaceholder
            var state3 = stateArrays[3]
            stateArrays[3] = statePlaceholder
            var state4 = stateArrays[4]
            stateArrays[4] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            states.insert(&state1, for: stateNames[1])
            states.insert(&state2, for: stateNames[2])
            states.insert(&state3, for: stateNames[3])
            states.insert(&state4, for: stateNames[4])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
            stateArrays[1] = state1
            stateArrays[2] = state2
            stateArrays[3] = state3
            stateArrays[4] = state4
        case 6:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var state1 = stateArrays[1]
            stateArrays[1] = statePlaceholder
            var state2 = stateArrays[2]
            stateArrays[2] = statePlaceholder
            var state3 = stateArrays[3]
            stateArrays[3] = statePlaceholder
            var state4 = stateArrays[4]
            stateArrays[4] = statePlaceholder
            var state5 = stateArrays[5]
            stateArrays[5] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            states.insert(&state1, for: stateNames[1])
            states.insert(&state2, for: stateNames[2])
            states.insert(&state3, for: stateNames[3])
            states.insert(&state4, for: stateNames[4])
            states.insert(&state5, for: stateNames[5])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
            stateArrays[1] = state1
            stateArrays[2] = state2
            stateArrays[3] = state3
            stateArrays[4] = state4
            stateArrays[5] = state5
        case 7:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var state1 = stateArrays[1]
            stateArrays[1] = statePlaceholder
            var state2 = stateArrays[2]
            stateArrays[2] = statePlaceholder
            var state3 = stateArrays[3]
            stateArrays[3] = statePlaceholder
            var state4 = stateArrays[4]
            stateArrays[4] = statePlaceholder
            var state5 = stateArrays[5]
            stateArrays[5] = statePlaceholder
            var state6 = stateArrays[6]
            stateArrays[6] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            states.insert(&state1, for: stateNames[1])
            states.insert(&state2, for: stateNames[2])
            states.insert(&state3, for: stateNames[3])
            states.insert(&state4, for: stateNames[4])
            states.insert(&state5, for: stateNames[5])
            states.insert(&state6, for: stateNames[6])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
            stateArrays[1] = state1
            stateArrays[2] = state2
            stateArrays[3] = state3
            stateArrays[4] = state4
            stateArrays[5] = state5
            stateArrays[6] = state6
        case 8:
            var state0 = stateArrays[0]
            stateArrays[0] = statePlaceholder
            var state1 = stateArrays[1]
            stateArrays[1] = statePlaceholder
            var state2 = stateArrays[2]
            stateArrays[2] = statePlaceholder
            var state3 = stateArrays[3]
            stateArrays[3] = statePlaceholder
            var state4 = stateArrays[4]
            stateArrays[4] = statePlaceholder
            var state5 = stateArrays[5]
            stateArrays[5] = statePlaceholder
            var state6 = stateArrays[6]
            stateArrays[6] = statePlaceholder
            var state7 = stateArrays[7]
            stateArrays[7] = statePlaceholder
            var states = InferenceFunction.MutableViews()
            states.insert(&state0, for: stateNames[0])
            states.insert(&state1, for: stateNames[1])
            states.insert(&state2, for: stateNames[2])
            states.insert(&state3, for: stateNames[3])
            states.insert(&state4, for: stateNames[4])
            states.insert(&state5, for: stateNames[5])
            states.insert(&state6, for: stateNames[6])
            states.insert(&state7, for: stateNames[7])
            var outputViews = InferenceFunction.MutableViews()
            outputViews.insert(&logits, for: logitsName)
            _ = try await function.run(inputs: inputs, states: consume states, outputViews: consume outputViews)
            stateArrays[0] = state0
            stateArrays[1] = state1
            stateArrays[2] = state2
            stateArrays[3] = state3
            stateArrays[4] = state4
            stateArrays[5] = state5
            stateArrays[6] = state6
            stateArrays[7] = state7
        default:
            throw CoreAILLMClientError.generationUnavailable(
                "Core AI model has \(stateArrays.count) states; Noema currently supports up to 8 state tensors."
            )
        }
    }

    // MARK: - Host-cache contract

    /// Graph facts + host-side cache storage for the host-cache contract.
    ///
    /// `past_k`/`past_v` are static `[layers, 1, kvHeads, capacity, headDim]`
    /// tensors the host fills each step; the graph returns the current token's
    /// `k_cur`/`v_cur` column (`[layers, 1, kvHeads, 1, headDim]`) which the
    /// host scatters back at the step's position. SSM exports additionally
    /// thread `conv_state`/`rec_state` → `conv_cur`/`rec_cur` (the output
    /// NDArray is fed straight back as the next step's input — zero copy).
    final class HostCacheRuntime {
        static let inputIdsName = "input_ids"
        static let positionIdsName = "position_ids"
        static let requiredInputs: Set<String> = [
            inputIdsName, positionIdsName, "causal_mask", "past_k", "past_v"
        ]

        let idsDescriptor: NDArrayDescriptor
        let posDescriptor: NDArrayDescriptor
        let maskDescriptor: NDArrayDescriptor
        let pastKDescriptor: NDArrayDescriptor
        let pastVDescriptor: NDArrayDescriptor
        let hasConvRec: Bool
        let layers: Int
        let kvHeads: Int
        /// Static KV capacity (the export's context window).
        let capacity: Int
        let headDim: Int
        let maskWidth: Int
        /// Fused-kernel exports argmax in-graph and return `head_pv`/`head_pi`
        /// partials instead of logits.
        let argmaxHead: Bool
        let logitsName: String?
        let logitsDescriptor: NDArrayDescriptor?
        let vocabSize: Int
        let convDescriptor: NDArrayDescriptor?
        let recDescriptor: NDArrayDescriptor?

        var hostK: [CoreAIHalf]
        var hostV: [CoreAIHalf]
        var convState: NDArray?
        var recState: NDArray?

        init(descriptor: InferenceFunctionDescriptor) throws {
            func input(_ name: String) throws -> NDArrayDescriptor {
                guard case .ndArray(let d) = descriptor.inputDescriptor(of: name) else {
                    throw CoreAILLMClientError.generationUnavailable(
                        "Core AI input '\(name)' is missing or not an NDArray."
                    )
                }
                return d
            }

            let ids = try input(Self.inputIdsName)
            guard ids.shape.allSatisfy({ $0 > 0 }), ids.shape.reduce(1, *) == 1 else {
                throw CoreAILLMClientError.generationUnavailable(
                    "Core AI host-cache graph takes input_ids \(ids.shape); Noema drives the single-token (q=1) decode graph — chunked-prefill companion graphs aren't standalone chat models."
                )
            }
            let pastK = try input("past_k")
            guard pastK.shape.count == 5, pastK.shape.allSatisfy({ $0 > 0 }) else {
                throw CoreAILLMClientError.generationUnavailable(
                    "Core AI past_k shape \(pastK.shape) isn't the expected static [layers, 1, kvHeads, capacity, headDim]."
                )
            }
            let mask = try input("causal_mask")
            idsDescriptor = ids
            posDescriptor = try input(Self.positionIdsName)
            maskDescriptor = mask
            pastKDescriptor = pastK
            pastVDescriptor = try input("past_v")
            layers = pastK.shape[0]
            kvHeads = pastK.shape[2]
            capacity = pastK.shape[3]
            headDim = pastK.shape[4]
            guard let width = mask.shape.last, width == capacity + 1 else {
                throw CoreAILLMClientError.generationUnavailable(
                    "Core AI causal_mask shape \(mask.shape) doesn't match the KV capacity \(capacity) (expected last dimension \(capacity + 1))."
                )
            }
            maskWidth = width

            let inputNames = Set(descriptor.inputNames)
            hasConvRec = inputNames.contains("conv_state") && inputNames.contains("rec_state")

            let outputNames = Set(descriptor.outputNames)
            guard outputNames.contains("k_cur"), outputNames.contains("v_cur") else {
                throw CoreAILLMClientError.generationUnavailable(
                    "Core AI host-cache graph doesn't return k_cur/v_cur for the host KV write-back."
                )
            }
            if outputNames.contains("head_pv"), outputNames.contains("head_pi") {
                argmaxHead = true
                logitsName = nil
                logitsDescriptor = nil
                vocabSize = 0
            } else if outputNames.contains("logits"),
                      case .ndArray(let logits) = descriptor.outputDescriptor(of: "logits"),
                      let vocab = logits.shape.last, vocab > 0 {
                argmaxHead = false
                logitsName = "logits"
                logitsDescriptor = logits
                vocabSize = vocab
            } else {
                throw CoreAILLMClientError.generationUnavailable(
                    "Core AI host-cache graph outputs [\(descriptor.outputNames.joined(separator: ", "))] — expected 'logits' or 'head_pv'/'head_pi'."
                )
            }

            let kvCount = pastK.shape.reduce(1, *)
            hostK = [CoreAIHalf](repeating: 0, count: kvCount)
            hostV = [CoreAIHalf](repeating: 0, count: kvCount)
            if hasConvRec {
                let conv = try input("conv_state")
                let rec = try input("rec_state")
                convDescriptor = conv
                recDescriptor = rec
                var convArray = NDArray(descriptor: conv)
                CoreAIDecoder.zero(&convArray, scalarType: conv.scalarType)
                var recArray = NDArray(descriptor: rec)
                CoreAIDecoder.zero(&recArray, scalarType: rec.scalarType)
                convState = convArray
                recState = recArray
            } else {
                convDescriptor = nil
                recDescriptor = nil
            }
        }
    }

    /// Chunked-prefill companion graph facts + block-rate SSM state carry.
    ///
    /// The companion consumes the prompt in fixed `blockSize`-token dispatches:
    /// `input_ids [1, q]`, `position_ids [1, q]` (absolute), block causal mask
    /// `[1, 1, q, capacity + q]`, the same `past_k`/`past_v` host caches as the
    /// decode graph, and `conv_state`/`rec_state` carried between blocks as
    /// fp16 host arrays. Outputs `k_cur`/`v_cur` (`[layers, 1, kvHeads, q,
    /// headDim]`) are scattered into the host caches; the final conv/rec carry
    /// is handed to the decode graph before the first decode step. Only FULL
    /// blocks are ever fed: the SSM recurrence can't be partially written back,
    /// so padding would poison it — the remainder runs through the q=1 decode
    /// graph.
    final class PrefillRuntime {
        let function: InferenceFunction
        let blockSize: Int
        let idsDescriptor: NDArrayDescriptor
        let posDescriptor: NDArrayDescriptor
        let maskDescriptor: NDArrayDescriptor
        let pastKDescriptor: NDArrayDescriptor
        let pastVDescriptor: NDArrayDescriptor
        let convDescriptor: NDArrayDescriptor?
        let recDescriptor: NDArrayDescriptor?
        /// Per-row mask width: `capacity + blockSize`.
        let maskWidth: Int

        /// fp16 conv/rec carry between blocks (zero = fresh recurrence). After
        /// the last block these seed the decode graph's state inputs.
        var convCarry: [CoreAIHalf] = []
        var recCarry: [CoreAIHalf] = []
        /// Set once any block has run, so the decode path knows to seed its
        /// conv/rec states from the carries before its first step.
        var pendingHandoff = false

        init?(function: InferenceFunction, descriptor: InferenceFunctionDescriptor, decode: HostCacheRuntime) {
            func input(_ name: String) -> NDArrayDescriptor? {
                guard case .ndArray(let d) = descriptor.inputDescriptor(of: name) else { return nil }
                return d
            }
            guard Set(descriptor.inputNames).isSuperset(of: HostCacheRuntime.requiredInputs),
                  let ids = input(HostCacheRuntime.inputIdsName),
                  let pos = input(HostCacheRuntime.positionIdsName),
                  let mask = input("causal_mask"),
                  let pastK = input("past_k"),
                  let pastV = input("past_v") else {
                print("[CoreAI] Prefill companion doesn't follow the host-cache contract; using q=1 prefill.")
                return nil
            }
            // Block size from the static query shape [1, q], q > 1.
            guard ids.shape.allSatisfy({ $0 > 0 }), let q = ids.shape.last, q > 1,
                  ids.shape.reduce(1, *) == q else {
                print("[CoreAI] Prefill companion input_ids \(ids.shape) isn't a [1, q>1] block; using q=1 prefill.")
                return nil
            }
            // Same state contract as the decode graph.
            guard pastK.shape == decode.pastKDescriptor.shape else {
                print("[CoreAI] Prefill companion past_k \(pastK.shape) doesn't match the decode graph \(decode.pastKDescriptor.shape); using q=1 prefill.")
                return nil
            }
            guard let width = mask.shape.last, width == decode.capacity + q else {
                print("[CoreAI] Prefill companion causal_mask \(mask.shape) doesn't match capacity \(decode.capacity) + q \(q); using q=1 prefill.")
                return nil
            }
            let outputs = Set(descriptor.outputNames)
            guard outputs.contains("k_cur"), outputs.contains("v_cur") else {
                print("[CoreAI] Prefill companion returns no k_cur/v_cur; using q=1 prefill.")
                return nil
            }
            let inputs = Set(descriptor.inputNames)
            let hasConvRec = inputs.contains("conv_state") && inputs.contains("rec_state")
            guard hasConvRec == decode.hasConvRec else {
                print("[CoreAI] Prefill companion SSM states don't match the decode graph; using q=1 prefill.")
                return nil
            }
            if hasConvRec {
                guard outputs.contains("conv_cur"), outputs.contains("rec_cur"),
                      let conv = input("conv_state"), let rec = input("rec_state") else {
                    print("[CoreAI] Prefill companion doesn't thread conv/rec states; using q=1 prefill.")
                    return nil
                }
                convDescriptor = conv
                recDescriptor = rec
                convCarry = [CoreAIHalf](repeating: 0, count: conv.shape.reduce(1, *))
                recCarry = [CoreAIHalf](repeating: 0, count: rec.shape.reduce(1, *))
            } else {
                convDescriptor = nil
                recDescriptor = nil
            }
            self.function = function
            self.blockSize = q
            self.idsDescriptor = ids
            self.posDescriptor = pos
            self.maskDescriptor = mask
            self.pastKDescriptor = pastK
            self.pastVDescriptor = pastV
            self.maskWidth = width
        }
    }

    // MARK: - Sampling

    private func sampleLastToken(_ logits: NDArray, batchSize: Int) -> Int {
        let row: [Float]
        switch logitsScalarType {
        case .float16:
            row = Self.lastTokenRowHalf(logits, batchSize: batchSize, vocab: vocabSize)
        default:
            row = Self.lastTokenRow(logits, as: Float.self, batchSize: batchSize, vocab: vocabSize)
        }
        // Greedy when the temperature is effectively zero.
        guard sampling.temperature > 0.01 else {
            return Self.argmax(row)
        }
        return sample(row: row)
    }

    /// Temperature → top-k → top-p (nucleus) → categorical draw.
    private func sample(row: [Float]) -> Int {
        let invTemp = 1 / max(sampling.temperature, 0.01)
        // Top-k selection happens on raw logits (temperature scaling is
        // monotonic) so the whole vocabulary never needs sorting.
        var candidates: [(id: Int, logit: Float)]
        if sampling.topK > 0, row.count > sampling.topK {
            candidates = Self.topCandidates(row, count: sampling.topK)
        } else {
            candidates = row.indices.map { ($0, row[$0]) }
        }
        candidates.sort { $0.logit > $1.logit }
        for index in candidates.indices {
            candidates[index].logit *= invTemp
        }

        // Softmax over the surviving candidates.
        let maxLogit = candidates.first?.logit ?? 0
        var probs = candidates.map { expf($0.logit - maxLogit) }
        var total = probs.reduce(0, +)
        guard total > 0 else { return candidates.first?.id ?? Self.argmax(row) }

        if sampling.topP > 0, sampling.topP < 1 {
            var cumulative: Float = 0
            var cutoff = probs.count
            for (index, p) in probs.enumerated() {
                cumulative += p / total
                if cumulative >= sampling.topP {
                    cutoff = index + 1
                    break
                }
            }
            probs.removeLast(probs.count - cutoff)
            candidates.removeLast(candidates.count - cutoff)
            total = probs.reduce(0, +)
        }

        var draw = Float(rng.nextUniform()) * total
        for (index, p) in probs.enumerated() {
            draw -= p
            if draw <= 0 { return candidates[index].id }
        }
        return candidates.last?.id ?? Self.argmax(row)
    }

    /// Top-`count` (id, logit) pairs via a size-k min-heap — O(V·log k) over the
    /// ~250k-entry vocabulary instead of a full sort per token.
    private static func topCandidates(_ row: [Float], count: Int) -> [(id: Int, logit: Float)] {
        var heap: [(id: Int, logit: Float)] = []
        heap.reserveCapacity(count)
        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < heap.count, heap[left].logit < heap[smallest].logit { smallest = left }
                if right < heap.count, heap[right].logit < heap[smallest].logit { smallest = right }
                if smallest == parent { return }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }
        for id in row.indices {
            let logit = row[id]
            if heap.count < count {
                heap.append((id, logit))
                if heap.count == count {
                    for index in stride(from: count / 2 - 1, through: 0, by: -1) { siftDown(index) }
                }
            } else if logit > heap[0].logit {
                heap[0] = (id, logit)
                siftDown(0)
            }
        }
        return heap
    }

    private static func argmax(_ row: [Float]) -> Int {
        var best = 0
        var bestValue = -Float.greatestFiniteMagnitude
        for (index, value) in row.enumerated() where value > bestValue {
            bestValue = value
            best = index
        }
        return best
    }

    // MARK: - NDArray helpers

    private static func lastTokenRow<T: BinaryFloatingPoint & BitwiseCopyable>(
        _ logits: NDArray, as type: T.Type, batchSize: Int, vocab: Int
    ) -> [Float] {
        var row = [Float](repeating: 0, count: vocab)
        logits.view(as: T.self).withUnsafePointer { ptr, _, strides in
            // Final position's row within the [1, batchSize, vocab] logits tensor.
            let rowBase = (batchSize - 1) * strides[1]
            let vocabStride = strides[2]
            for v in 0..<vocab {
                row[v] = Float(ptr[rowBase + v * vocabStride])
            }
        }
        return row
    }

    /// fp16 specialization of `lastTokenRow`: `Float16` isn't a usable Swift
    /// type on the x86_64 Apple slices, so the half logits are read through
    /// `CoreAIHalf` (native `Float16` where it exists, raw binary16 bits in
    /// `UInt16` otherwise) and converted to Float via `CoreAIHalfCodec`.
    private static func lastTokenRowHalf(_ logits: NDArray, batchSize: Int, vocab: Int) -> [Float] {
        var row = [Float](repeating: 0, count: vocab)
        logits.view(as: CoreAIHalf.self).withUnsafePointer { ptr, _, strides in
            // Final position's row within the [1, batchSize, vocab] logits tensor.
            let rowBase = (batchSize - 1) * strides[1]
            let vocabStride = strides[2]
            for v in 0..<vocab {
                row[v] = CoreAIHalfCodec.float(ptr[rowBase + v * vocabStride])
            }
        }
        return row
    }

    private static func fillInt32(_ array: inout NDArray, _ values: [Int32]) {
        var view = array.mutableView(as: Int32.self)
        view.withUnsafeMutablePointer { ptr, _, _ in
            values.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { ptr.update(from: base, count: src.count) }
            }
        }
    }

    // Bulk memcpy — the host-cache loop streams the full KV cache (tens of MB)
    // into the inputs every step, so an element-wise copy dominates the step
    // time (~260 ms host vs ~40 ms inference observed in Instruments).
    private static func fillFloat16(_ array: inout NDArray, _ values: [CoreAIHalf]) {
        var view = array.mutableView(as: CoreAIHalf.self)
        view.withUnsafeMutablePointer { ptr, _, _ in
            values.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { ptr.update(from: base, count: src.count) }
            }
        }
    }

    /// Reads a contiguous NDArray into a Swift array. Core AI run outputs and
    /// the host-cache tensors are row-major contiguous.
    private static func readScalars<T: BitwiseCopyable>(_ array: NDArray, as type: T.Type) -> [T] {
        let count = array.shape.reduce(1, *)
        guard count > 0 else { return [] }
        return array.view(as: T.self).withUnsafePointer { ptr, _, _ in
            Array(UnsafeBufferPointer(start: ptr, count: count))
        }
    }

    /// Additive q=1 causal mask `[1, 1, 1, width]` where `width = capacity + 1`:
    /// past columns `< position` and the current-token column (last index) are
    /// 0, everything else is a large negative (exports use −1e4, not −inf — the
    /// ANE softmax mishandles IEEE −inf).
    private static func causalMask(position: Int, width: Int) -> [CoreAIHalf] {
        var mask = [CoreAIHalf](repeating: CoreAIHalfCodec.half(-1.0e4), count: width)
        for column in 0..<min(position, width - 1) {
            mask[column] = 0
        }
        mask[width - 1] = 0
        return mask
    }

    /// Additive block mask `[1, 1, q, capacity + q]` for the chunked-prefill
    /// companion: past columns `< position` are visible to ALL rows; the
    /// current block's column `t` (at index `capacity + t`) is visible to rows
    /// `i >= t`; everything else is the large negative.
    private static func prefillMask(position: Int, blockSize: Int, capacity: Int) -> [CoreAIHalf] {
        let width = capacity + blockSize
        var mask = [CoreAIHalf](repeating: CoreAIHalfCodec.half(-1.0e4), count: blockSize * width)
        for row in 0..<blockSize {
            let base = row * width
            for column in 0..<position {
                mask[base + column] = 0
            }
            for t in 0...row {
                mask[base + capacity + t] = 0
            }
        }
        return mask
    }

    /// Scatters a prefill block's K/V (`[layers, 1, kvHeads, q, headDim]`) into
    /// the host cache (`[layers, 1, kvHeads, capacity, headDim]`) at sequence
    /// columns `position..<position+columns`.
    private static func writeColumns(
        into cache: inout [CoreAIHalf], block: [CoreAIHalf],
        layers: Int, kvHeads: Int, capacity: Int, headDim: Int, position: Int, columns: Int
    ) {
        guard block.count == layers * kvHeads * columns * headDim,
              position + columns <= capacity else { return }
        for layer in 0..<layers {
            for head in 0..<kvHeads {
                for column in 0..<columns {
                    let dst = ((layer * kvHeads + head) * capacity + position + column) * headDim
                    let src = ((layer * kvHeads + head) * columns + column) * headDim
                    for element in 0..<headDim {
                        cache[dst + element] = block[src + element]
                    }
                }
            }
        }
    }

    /// Scatters a step's K/V column (`[layers, 1, kvHeads, 1, headDim]`) into
    /// the host cache (`[layers, 1, kvHeads, capacity, headDim]`) at sequence
    /// column `position`.
    private static func writeColumn(
        into cache: inout [CoreAIHalf], column: [CoreAIHalf],
        layers: Int, kvHeads: Int, capacity: Int, headDim: Int, position: Int
    ) {
        guard column.count == layers * kvHeads * headDim, position < capacity else { return }
        for layer in 0..<layers {
            for head in 0..<kvHeads {
                let dst = ((layer * kvHeads + head) * capacity + position) * headDim
                let src = (layer * kvHeads + head) * headDim
                for element in 0..<headDim {
                    cache[dst + element] = column[src + element]
                }
            }
        }
    }

    /// Reduces a two-level GPU argmax head's per-threadgroup partials
    /// (`head_pv` max values, `head_pi` global indices) to the greedy token:
    /// `token = pi[argmax(pv)]`. Strict `>` keeps the lowest index on ties,
    /// matching `torch.argmax`.
    private static func reduceArgmaxPartials(values: NDArray, indices: NDArray) -> Int? {
        let partialValues: [Float]
        switch values.scalarType {
        case .float32:
            partialValues = readScalars(values, as: Float.self)
        default:
            partialValues = readScalars(values, as: CoreAIHalf.self).map(CoreAIHalfCodec.float)
        }
        let partialIndices = readScalars(indices, as: Int32.self)
        guard !partialValues.isEmpty, partialValues.count == partialIndices.count else { return nil }
        var best = 0
        var bestValue = partialValues[0]
        for j in 1..<partialValues.count where partialValues[j] > bestValue {
            bestValue = partialValues[j]
            best = j
        }
        return Int(partialIndices[best])
    }

    private static func zero(_ array: inout NDArray, scalarType: NDArray.ScalarType) {
        let count = array.shape.reduce(1, *)
        switch scalarType {
        case .float32:
            var view = array.mutableView(as: Float.self)
            view.withUnsafeMutablePointer { ptr, _, _ in
                ptr.update(repeating: 0, count: count)
            }
        default:
            // float16 KV caches and other 16-bit states.
            var view = array.mutableView(as: CoreAIHalf.self)
            view.withUnsafeMutablePointer { ptr, _, _ in
                ptr.update(repeating: 0, count: count)
            }
        }
    }
}

/// Deterministic, seedable RNG for reproducible sampling when a seed is set.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1).
    mutating func nextUniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
#endif
