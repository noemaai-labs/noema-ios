// ModelSettings.swift
import Foundation
import SwiftUI

enum CacheQuant: String, Codable, CaseIterable, Identifiable {
    case f32 = "F32"
    case f16 = "F16"
    case q8_0 = "Q8_0"
    case q5_0 = "Q5_0"
    case q5_1 = "Q5_1"
    case q4_0 = "Q4_0"
    case q4_1 = "Q4_1"
    case iq4_nl = "IQ4_NL"

    var id: String { rawValue }
}

enum ProcessingUnitConfiguration: String, Codable, CaseIterable, Identifiable {
    case all
    case cpuOnly
    case cpuAndGPU
    case cpuAndNeuralEngine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "All"
        case .cpuOnly:
            return "CPU Only"
        case .cpuAndGPU:
            return "CPU + GPU"
        case .cpuAndNeuralEngine:
            return "CPU + Neural Engine"
        }
    }
}

enum AFMGuardrailsMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case `default`
    case permissiveContentTransformations

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .default:
            return "Standard"
        case .permissiveContentTransformations:
            return "Content Transformation"
        }
    }

    var detailKey: String {
        switch self {
        case .default:
            return "Uses Apple's default AFM guardrails for general chat."
        case .permissiveContentTransformations:
            return "Allows Apple's permissive content-transformation guardrails for rewriting or transforming user-provided content."
        }
    }
}

/// How an Apple Foundation Model request may use Private Cloud Compute (iOS 27+).
enum AFMPrivateCloudComputeMode: String, Codable, CaseIterable, Identifiable, Equatable {
    /// Route every reply through Private Cloud Compute.
    case always
    /// Run on-device, but let the model escalate individual replies to Private Cloud Compute when helpful.
    case smart
    /// Stay fully on-device; never use Private Cloud Compute.
    case off

    var id: String { rawValue }

    /// Short label suitable for a segmented control.
    var titleKey: String {
        switch self {
        case .always:
            return "Always"
        case .smart:
            return "Smart"
        case .off:
            return "Off"
        }
    }

    var detailKey: String {
        switch self {
        case .always:
            return "Every reply runs on Apple's Private Cloud Compute — same privacy guarantees, larger context and deeper reasoning. Falls back to on-device automatically when offline or the daily limit is reached."
        case .smart:
            return "Replies run on-device and hand off mid-answer to Private Cloud Compute only when more capability is needed. The conversation is shared with Apple's secure cloud only when that happens. Requires iOS 27."
        case .off:
            return "Keeps every reply fully on-device. Private Cloud Compute is never used."
        }
    }
}

enum SystemPromptMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case inheritGlobal
    case override
    case excludeGlobal

    var id: String { rawValue }
}

enum PromptTemplateSource: String, Sendable {
    case curated
    case chatTemplateFile = "chat_template"
    case hubMetadata = "hub.json"
    case tokenizerConfig = "tokenizer_config.json"
    case tokenizer = "tokenizer.json"
    case config = "config.json"
    case defaultTemplate = "default"
}

struct LocalModelSettingsResolution: Sendable {
    let settings: ModelSettings
    let promptTemplateSource: PromptTemplateSource
}

private enum ANEModelSettingsCache {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: LocalModelSettingsResolution] = [:]
    }

    private static let storage = Storage()

    static func value(for url: URL) -> LocalModelSettingsResolution? {
        let key = cacheKey(for: url)
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.values[key]
    }

    static func store(_ resolution: LocalModelSettingsResolution, for url: URL) {
        let key = cacheKey(for: url)
        storage.lock.lock()
        storage.values[key] = resolution
        storage.lock.unlock()
    }

    private static func cacheKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

struct ModelSettings: Codable, Equatable {
    var contextLength: Double = 4096
    // -1 means: auto/offload all available layers (default). 0+ means explicit override
    var gpuLayers: Int = -1
    var cpuThreads: Int = 0
    var kvCacheOffload: Bool = true
    var keepInMemory: Bool = true
    var useMmap: Bool = true
    var disableWarmup: Bool = true
    var flashAttention: Bool = false
    var seed: Int?
    var kCacheQuant: CacheQuant = .f16
    var vCacheQuant: CacheQuant = .f16
    /// Optional tokenizer path to override default
    var tokenizerPath: String?
    /// Optional prompt template for chat models
    var promptTemplate: String?
    // Sampling parameters for generation (used by MLX and others)
    var temperature: Double = 0.7
    var repetitionPenalty: Float = 1.1
    var topK: Int = 40
    var topP: Double = 0.95
    var minP: Double = 0.0
    var repeatLastN: Int = 64
    var presencePenalty: Float = 0.0
    var frequencyPenalty: Float = 0.0
    /// Optional stop sequences sourced from repo-provided params files (applied on first use)
    var stopSequences: [String]? = nil
    var speculativeDecoding: SpeculativeDecodingSettings = .init()
    var ropeScaling: RopeScalingSettings? = nil
    var logitBias: [Int: Double] = [:]
    var promptCacheEnabled: Bool = false
    var promptCachePath: String = ""
    var promptCacheAll: Bool = false
    var tensorOverride: TensorOverridePreset = .none
    /// Optional override for the number of experts to use when running MoE models.
    var moeActiveExperts: Int? = nil
    var etBackend: ETBackend = .xnnpack
    /// Optional so older persisted settings decode cleanly; defaults to `.all` at use sites.
    var processingUnitConfiguration: ProcessingUnitConfiguration? = nil
    /// Always pinned to the most permissive guardrails — see
    /// `AFMLLMClient.resolvedGuardrailsMode(from:)`, which ignores any stored value
    /// so new installs *and* anyone updating from a build that persisted `.default`
    /// run with the lax content-transformation guardrails.
    var afmGuardrails: AFMGuardrailsMode = .permissiveContentTransformations
    /// How Apple Foundation Model requests may use Private Cloud Compute (iOS 27+).
    /// `.smart` (the default) keeps inference on-device but allows per-reply escalation;
    /// `.always` routes everything through PCC; `.off` stays fully on-device.
    var afmPrivateCloudComputeMode: AFMPrivateCloudComputeMode = .smart
    var systemPromptMode: SystemPromptMode = .inheritGlobal
    var systemPromptOverride: String? = nil

    /// Default inference thread count. Reserves two cores so the UI, input handling,
    /// SwiftUI layout, and decode callbacks aren't starved while inference runs — on
    /// small models this is usually *smoother* than using every core.
    static var recommendedInferenceThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    /// Hard ceiling for inference threads. Always leaves at least one core free for the
    /// UI, so even an explicit user override (or an old persisted setting) can't fully
    /// starve the main thread.
    static var maxInferenceThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    static func `default`(for format: ModelFormat) -> ModelSettings {
        var s = ModelSettings()
        switch format {
        case .mlx:
            s.gpuLayers = 0
            s.cpuThreads = ModelSettings.recommendedInferenceThreadCount
        case .gguf:
            s.cpuThreads = ModelSettings.recommendedInferenceThreadCount
        case .et:
            s.cpuThreads = ModelSettings.recommendedInferenceThreadCount
            s.etBackend = .xnnpack
        case .ane:
            s.cpuThreads = ModelSettings.recommendedInferenceThreadCount
            s.processingUnitConfiguration = .cpuAndNeuralEngine
        case .afm:
            s.cpuThreads = ModelSettings.recommendedInferenceThreadCount
            s.gpuLayers = 0
        case .coreai:
            s.cpuThreads = ModelSettings.recommendedInferenceThreadCount
            s.gpuLayers = 0
        }
        s.tokenizerPath = nil
        s.promptTemplate = nil
        return s
    }

    /// Creates settings from a model's config.json if present.
    /// Falls back to sensible defaults when the config is missing.
    static func fromConfig(for model: LocalModel) -> ModelSettings {
        resolvedLocalSettings(for: model).settings
    }

    static func resolvedLocalSettings(for model: LocalModel) -> LocalModelSettingsResolution {
        var settings = ModelSettings.default(for: model.format)
        if model.format == .afm {
            settings = settings.normalizedForLocalModel(model)
            return LocalModelSettingsResolution(
                settings: settings,
                promptTemplateSource: .defaultTemplate
            )
        }

        let dir = settingsDirectory(for: model)
        let templateResolution = promptTemplateResolution(for: model, directory: dir)
        settings.promptTemplate = templateResolution.template
        if model.format == .ane {
            settings.tokenizerPath = resolvedTokenizerPath(for: model)
        } else if model.format == .et {
            settings.tokenizerPath = ETModelResolver.tokenizerURL(for: dir)?.path
        }

        if let paramsURL = Self.locateParamsFile(in: dir),
           let data = try? Data(contentsOf: paramsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings.applyParamsJSON(obj)
        }

        settings = settings.normalizedForLocalModel(model)

        return LocalModelSettingsResolution(
            settings: settings,
            promptTemplateSource: templateResolution.source
        )
    }

    static func resolvedANEModelSettings(modelID: String, modelURL: URL) -> LocalModelSettingsResolution {
        let canonicalURL = InstalledModelsStore.canonicalURL(for: modelURL, format: .ane)
        if let cached = ANEModelSettingsCache.value(for: canonicalURL) {
            return cached
        }
        let model = LocalModel(
            modelID: modelID,
            name: canonicalURL.lastPathComponent,
            url: canonicalURL,
            quant: ModelFormat.ane.displayName,
            architecture: "",
            architectureFamily: "",
            format: .ane,
            sizeGB: 0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )
        let resolved = resolvedLocalSettings(for: model)
        ANEModelSettingsCache.store(resolved, for: canonicalURL)
        return resolved
    }

    static func resolvedTokenizerPath(for model: LocalModel) -> String? {
        preferredTokenizerAssetURL(in: settingsDirectory(for: model))?.path
    }
}

extension ModelSettings {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contextLength
        case gpuLayers
        case cpuThreads
        case kvCacheOffload
        case keepInMemory
        case useMmap
        case disableWarmup
        case flashAttention
        case seed
        case kCacheQuant
        case vCacheQuant
        case tokenizerPath
        case promptTemplate
        case temperature
        case repetitionPenalty
        case topK
        case topP
        case minP
        case repeatLastN
        case presencePenalty
        case frequencyPenalty
        case stopSequences
        case speculativeDecoding
        case ropeScaling
        case logitBias
        case promptCacheEnabled
        case promptCachePath
        case promptCacheAll
        case tensorOverride
        case moeActiveExperts
        case etBackend
        case processingUnitConfiguration
        case afmGuardrails
        case afmPrivateCloudComputeMode
        /// Legacy boolean key; migrated to `afmPrivateCloudComputeMode` on decode.
        case afmUsePrivateCloudCompute
        case systemPromptMode
        case systemPromptOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModelSettings()

        self.contextLength = try container.decodeIfPresent(Double.self, forKey: .contextLength) ?? defaults.contextLength
        self.gpuLayers = try container.decodeIfPresent(Int.self, forKey: .gpuLayers) ?? defaults.gpuLayers
        self.cpuThreads = try container.decodeIfPresent(Int.self, forKey: .cpuThreads) ?? defaults.cpuThreads
        self.kvCacheOffload = try container.decodeIfPresent(Bool.self, forKey: .kvCacheOffload) ?? defaults.kvCacheOffload
        self.keepInMemory = try container.decodeIfPresent(Bool.self, forKey: .keepInMemory) ?? defaults.keepInMemory
        self.useMmap = try container.decodeIfPresent(Bool.self, forKey: .useMmap) ?? defaults.useMmap
        self.disableWarmup = try container.decodeIfPresent(Bool.self, forKey: .disableWarmup) ?? defaults.disableWarmup
        self.flashAttention = try container.decodeIfPresent(Bool.self, forKey: .flashAttention) ?? defaults.flashAttention
        self.seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        self.kCacheQuant = try container.decodeIfPresent(CacheQuant.self, forKey: .kCacheQuant) ?? defaults.kCacheQuant
        self.vCacheQuant = try container.decodeIfPresent(CacheQuant.self, forKey: .vCacheQuant) ?? defaults.vCacheQuant
        self.tokenizerPath = try container.decodeIfPresent(String.self, forKey: .tokenizerPath)
        self.promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate)
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        self.repetitionPenalty = try container.decodeIfPresent(Float.self, forKey: .repetitionPenalty) ?? defaults.repetitionPenalty
        self.topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? defaults.topK
        self.topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? defaults.topP
        self.minP = try container.decodeIfPresent(Double.self, forKey: .minP) ?? defaults.minP
        self.repeatLastN = try container.decodeIfPresent(Int.self, forKey: .repeatLastN) ?? defaults.repeatLastN
        self.presencePenalty = try container.decodeIfPresent(Float.self, forKey: .presencePenalty) ?? defaults.presencePenalty
        self.frequencyPenalty = try container.decodeIfPresent(Float.self, forKey: .frequencyPenalty) ?? defaults.frequencyPenalty
        self.stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences)
        self.speculativeDecoding = try container.decodeIfPresent(SpeculativeDecodingSettings.self, forKey: .speculativeDecoding) ?? defaults.speculativeDecoding
        self.ropeScaling = try container.decodeIfPresent(RopeScalingSettings.self, forKey: .ropeScaling)
        self.logitBias = try container.decodeIfPresent([Int: Double].self, forKey: .logitBias) ?? defaults.logitBias
        self.promptCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .promptCacheEnabled) ?? defaults.promptCacheEnabled
        self.promptCachePath = try container.decodeIfPresent(String.self, forKey: .promptCachePath) ?? defaults.promptCachePath
        self.promptCacheAll = try container.decodeIfPresent(Bool.self, forKey: .promptCacheAll) ?? defaults.promptCacheAll
        self.tensorOverride = try container.decodeIfPresent(TensorOverridePreset.self, forKey: .tensorOverride) ?? defaults.tensorOverride
        self.moeActiveExperts = try container.decodeIfPresent(Int.self, forKey: .moeActiveExperts)
        self.etBackend = try container.decodeIfPresent(ETBackend.self, forKey: .etBackend) ?? defaults.etBackend
        self.processingUnitConfiguration = try container.decodeIfPresent(ProcessingUnitConfiguration.self, forKey: .processingUnitConfiguration)
        self.afmGuardrails = try container.decodeIfPresent(AFMGuardrailsMode.self, forKey: .afmGuardrails) ?? defaults.afmGuardrails
        if let pccMode = try container.decodeIfPresent(AFMPrivateCloudComputeMode.self, forKey: .afmPrivateCloudComputeMode) {
            self.afmPrivateCloudComputeMode = pccMode
        } else if let legacyUsePCC = try container.decodeIfPresent(Bool.self, forKey: .afmUsePrivateCloudCompute) {
            // Migrate the old boolean: on → always, off → smart (the prior default behavior).
            self.afmPrivateCloudComputeMode = legacyUsePCC ? .always : .smart
        } else {
            self.afmPrivateCloudComputeMode = defaults.afmPrivateCloudComputeMode
        }
        self.systemPromptMode = try container.decodeIfPresent(SystemPromptMode.self, forKey: .systemPromptMode) ?? defaults.systemPromptMode
        self.systemPromptOverride = try container.decodeIfPresent(String.self, forKey: .systemPromptOverride)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contextLength, forKey: .contextLength)
        try container.encode(gpuLayers, forKey: .gpuLayers)
        try container.encode(cpuThreads, forKey: .cpuThreads)
        try container.encode(kvCacheOffload, forKey: .kvCacheOffload)
        try container.encode(keepInMemory, forKey: .keepInMemory)
        try container.encode(useMmap, forKey: .useMmap)
        try container.encode(disableWarmup, forKey: .disableWarmup)
        try container.encode(flashAttention, forKey: .flashAttention)
        try container.encodeIfPresent(seed, forKey: .seed)
        try container.encode(kCacheQuant, forKey: .kCacheQuant)
        try container.encode(vCacheQuant, forKey: .vCacheQuant)
        try container.encodeIfPresent(tokenizerPath, forKey: .tokenizerPath)
        try container.encodeIfPresent(promptTemplate, forKey: .promptTemplate)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(repetitionPenalty, forKey: .repetitionPenalty)
        try container.encode(topK, forKey: .topK)
        try container.encode(topP, forKey: .topP)
        try container.encode(minP, forKey: .minP)
        try container.encode(repeatLastN, forKey: .repeatLastN)
        try container.encode(presencePenalty, forKey: .presencePenalty)
        try container.encode(frequencyPenalty, forKey: .frequencyPenalty)
        try container.encodeIfPresent(stopSequences, forKey: .stopSequences)
        try container.encode(speculativeDecoding, forKey: .speculativeDecoding)
        try container.encodeIfPresent(ropeScaling, forKey: .ropeScaling)
        try container.encode(logitBias, forKey: .logitBias)
        try container.encode(promptCacheEnabled, forKey: .promptCacheEnabled)
        try container.encode(promptCachePath, forKey: .promptCachePath)
        try container.encode(promptCacheAll, forKey: .promptCacheAll)
        try container.encode(tensorOverride, forKey: .tensorOverride)
        try container.encodeIfPresent(moeActiveExperts, forKey: .moeActiveExperts)
        try container.encode(etBackend, forKey: .etBackend)
        try container.encodeIfPresent(processingUnitConfiguration, forKey: .processingUnitConfiguration)
        try container.encode(afmGuardrails, forKey: .afmGuardrails)
        try container.encode(afmPrivateCloudComputeMode, forKey: .afmPrivateCloudComputeMode)
        try container.encode(systemPromptMode, forKey: .systemPromptMode)
        try container.encodeIfPresent(systemPromptOverride, forKey: .systemPromptOverride)
    }
}

extension ModelSettings {
    var resolvedProcessingUnitConfiguration: ProcessingUnitConfiguration {
        processingUnitConfiguration ?? .all
    }

    func normalizedForLocalModel(_ model: LocalModel) -> ModelSettings {
        var normalized = self
        normalized.contextLength = max(1, normalized.contextLength.rounded())
        if let supportedMaxContextLength = Self.supportedMaxContextLength(for: model) {
            normalized.contextLength = min(normalized.contextLength, Double(supportedMaxContextLength))
        }
        normalized = normalized.normalizedSystemPromptSettings()
        return normalized
    }

    func normalizedSystemPromptSettings() -> ModelSettings {
        var normalized = self
        let trimmedOverride = normalized.systemPromptOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedOverride, !trimmedOverride.isEmpty {
            normalized.systemPromptOverride = trimmedOverride
        } else {
            normalized.systemPromptOverride = nil
            if normalized.systemPromptMode == .override {
                normalized.systemPromptMode = .inheritGlobal
            }
        }
        return normalized
    }

    static func supportedMaxContextLength(for model: LocalModel) -> Int? {
        if let fixedContextLength = fixedContextLength(for: model) {
            return fixedContextLength
        }

        switch model.format {
        case .gguf:
            let canonicalURL = InstalledModelsStore.canonicalURL(for: model.url, format: .gguf)
            return GGUFMetadata.contextLength(at: canonicalURL)
        case .mlx, .et:
            return inferredConfigContextLength(for: model)
        case .coreai:
            return inferredCoreAIContextLength(for: model)
        case .ane, .afm:
            return nil
        }
    }

    static func fixedContextLength(for model: LocalModel) -> Int? {
        switch model.format {
        case .ane:
            return inferredCMLContextLength(for: model)
        case .afm:
            return 4096
        case .gguf, .mlx, .et, .coreai:
            return nil
        }
    }
}

extension ModelSettings {
    static func inferredConfigContextLength(for model: LocalModel) -> Int? {
        let configURL = settingsDirectory(for: model).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let preferredSections = ["text_config", "language_config", "llm_config"]
        for section in preferredSections {
            if let nested = json[section] as? [String: Any],
               let contextLength = contextLengthValue(in: nested) {
                return contextLength
            }
        }

        return contextLengthValue(in: json)
    }

    static func contextLengthValue(in object: [String: Any]) -> Int? {
        let keys = [
            "context_length",
            "max_position_embeddings",
            "max_sequence_length",
            "model_max_length",
            "max_seq_len",
            "n_ctx"
        ]

        for key in keys {
            guard let raw = object[key] else { continue }
            if let number = raw as? NSNumber {
                let value = number.intValue
                if value > 0 { return value }
            }
            if let text = raw as? String,
               let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               value > 0 {
                return value
            }
        }

        return nil
    }

    /// Core AI exports record their context budget in the variant-level
    /// `metadata.json` (`language.max_context_length`).
    static func inferredCoreAIContextLength(for model: LocalModel) -> Int? {
        let root = InstalledModelsStore.canonicalURL(for: model.url, format: .coreai)
        return CoreAILLMClient.exportedMaxContext(resourceRoot: root)
    }

    static func inferredCMLContextLength(for model: LocalModel) -> Int? {
        let candidates = [
            model.name,
            model.url.deletingPathExtension().lastPathComponent,
            model.url.lastPathComponent,
            model.modelID
        ]

        for candidate in candidates {
            if let contextLength = parseContextToken(in: candidate) {
                return contextLength
            }
        }

        return nil
    }

    static func parseContextToken(in text: String) -> Int? {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"ctx(\d+)"#, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let digitsRange = Range(match.range(at: 1), in: text),
              let contextLength = Int(text[digitsRange]),
              contextLength > 0 else {
            return nil
        }

        return contextLength
    }

    struct PromptTemplateResolution {
        let template: String?
        let source: PromptTemplateSource
    }

    /// Finds a params sidecar file (either `params` or `params.json`) in the given directory.
    static func locateParamsFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        for name in ["params.json", "params"] {
            let cand = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: cand.path) { return cand }
        }
        return nil
    }

    static func settingsDirectory(for model: LocalModel) -> URL {
        switch model.format {
        case .gguf, .et:
            return model.url.deletingLastPathComponent()
        case .mlx, .ane, .afm, .coreai:
            return InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
        }
    }

    static func promptTemplateResolution(for model: LocalModel, directory dir: URL) -> PromptTemplateResolution {
        if let curated = ArchitectureTemplates.template(for: model) {
            return PromptTemplateResolution(template: curated, source: .curated)
        }

        let chatTemplateJinjaURL = dir.appendingPathComponent("chat_template.jinja")
        if let template = try? String(contentsOf: chatTemplateJinjaURL, encoding: .utf8),
           !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PromptTemplateResolution(template: template, source: .chatTemplateFile)
        }

        let chatTemplateTextURL = dir.appendingPathComponent("chat_template.txt")
        if let template = try? String(contentsOf: chatTemplateTextURL, encoding: .utf8),
           !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PromptTemplateResolution(template: template, source: .chatTemplateFile)
        }

        let chatTemplateJSONURL = dir.appendingPathComponent("chat_template.json")
        if let template = chatTemplate(from: chatTemplateJSONURL) {
            return PromptTemplateResolution(template: template, source: .chatTemplateFile)
        }

        let hubJSONURL = dir.appendingPathComponent("hub.json")
        if let template = hubChatTemplate(from: hubJSONURL) {
            return PromptTemplateResolution(template: template, source: .hubMetadata)
        }

        let tokenizerConfigURL = dir.appendingPathComponent("tokenizer_config.json")
        if let template = chatTemplate(from: tokenizerConfigURL) {
            return PromptTemplateResolution(template: template, source: .tokenizerConfig)
        }

        if let tokenizerURL = tokenizerJSONURL(in: dir),
           let template = chatTemplate(from: tokenizerURL) {
            return PromptTemplateResolution(template: template, source: .tokenizer)
        }

        let cfgURL = dir.appendingPathComponent("config.json")
        if let template = chatTemplate(from: cfgURL) {
            return PromptTemplateResolution(template: template, source: .config)
        }

        if model.format == .gguf {
            var ggufURL = model.url
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: ggufURL.path, isDirectory: &isDir), isDir.boolValue {
                if let f = try? FileManager.default.contentsOfDirectory(at: ggufURL, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                    ggufURL = f
                }
            }
            if let template = GGUFMetadata.chatTemplate(at: ggufURL) {
                return PromptTemplateResolution(template: template, source: .defaultTemplate)
            }
        }

        return PromptTemplateResolution(template: nil, source: .defaultTemplate)
    }

    static func chatTemplate(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let template = json["chat_template"] as? String,
              !template.isEmpty else {
            return nil
        }
        return template
    }

    static func hubChatTemplate(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let gguf = json["gguf"] as? [String: Any],
           let template = gguf["chat_template"] as? String,
           !template.isEmpty {
            return template
        }
        if let template = json["chat_template"] as? String, !template.isEmpty {
            return template
        }
        if let template = json["chat_template_jinja"] as? String, !template.isEmpty {
            return template
        }
        if let card = json["cardData"] as? [String: Any] {
            if let template = card["chat_template"] as? String, !template.isEmpty {
                return template
            }
            if let template = card["chat_template_jinja"] as? String, !template.isEmpty {
                return template
            }
        }
        return nil
    }

    static func tokenizerJSONURL(in dir: URL) -> URL? {
        firstMatchingFile(in: dir, names: ["tokenizer.json"])
    }

    static func preferredTokenizerAssetURL(in dir: URL) -> URL? {
        firstMatchingFile(
            in: dir,
            names: [
                "tokenizer.json",
                "tokenizer.model",
                "spiece.model",
                "sentencepiece.bpe.model"
            ]
        )
    }

    static func firstMatchingFile(in root: URL, names: [String]) -> URL? {
        let fm = FileManager.default
        let nameSet = Set(names.map { $0.lowercased() })

        func matches(_ file: URL) -> Bool {
            nameSet.contains(file.lastPathComponent.lowercased())
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir), !isDir.boolValue {
            return matches(root) ? root : nil
        }

        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }

        if let direct = files.first(where: { matches($0) }) {
            return direct
        }

        for entry in files {
            var subIsDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &subIsDir), subIsDir.boolValue else {
                continue
            }
            guard let subFiles = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) else {
                continue
            }
            if let subMatch = subFiles.first(where: { matches($0) }) {
                return subMatch
            }
        }

        return nil
    }

    /// Applies sampling defaults from a params JSON object. Unknown fields are ignored.
    mutating func applyParamsJSON(_ obj: [String: Any]) {
        func double(_ key: String) -> Double? {
            if let n = obj[key] as? NSNumber { return n.doubleValue }
            if let s = obj[key] as? String { return Double(s) }
            return nil
        }
        func int(_ key: String) -> Int? {
            if let n = obj[key] as? NSNumber { return n.intValue }
            if let s = obj[key] as? String, let v = Int(s) { return v }
            return nil
        }

        if let t = double("temperature") { temperature = t }
        if let k = int("top_k") { topK = max(1, k) }
        if let p = double("top_p") { topP = max(0.0, min(1.0, p)) }
        if let mp = double("min_p") { minP = max(0.0, min(1.0, mp)) }
        if let rp = double("repeat_penalty") { repetitionPenalty = Float(rp) }
        if let rl = int("repeat_last_n") { repeatLastN = max(0, rl) }
        if let pres = double("presence_penalty") { presencePenalty = Float(pres) }
        if let freq = double("frequency_penalty") { frequencyPenalty = Float(freq) }

        if let stop = obj["stop"] as? [String] {
            stopSequences = stop
        } else if let stopAny = obj["stop"] as? [Any] {
            stopSequences = stopAny.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let stopSingle = obj["stop"] as? String, !stopSingle.isEmpty {
            stopSequences = [stopSingle]
        }
    }
}

extension ModelSettings {
    struct SpeculativeDecodingSettings: Codable, Equatable {
        enum Selection: String, Codable, CaseIterable, Identifiable {
            case off
            case helperDraftModel
            case mtp

            var id: String { rawValue }
            var title: String {
                switch self {
                case .off: return "Off"
                case .helperDraftModel: return "Helper Model"
                case .mtp: return "Multi-Token Prediction"
                }
            }
        }

        enum Mode: String, Codable, CaseIterable, Identifiable {
            case tokens
            case max

            var id: String { rawValue }
            var title: String {
                switch self {
                case .tokens: return "Draft Tokens"
                case .max: return "Draft Window"
                }
            }
        }

        var selection: Selection = .off
        var helperModelID: String? = nil
        var mode: Mode = .tokens
        var value: Int = 64
        var mtpDraftNMax: Int = 2
        var mtpDraftNMin: Int = 0
        var mtpDraftPMin: Double = 0.1

        var hasSelection: Bool {
            switch selection {
            case .off:
                return false
            case .helperDraftModel:
                return helperModelID?.isEmpty == false
            case .mtp:
                return true
            }
        }

        var mtpEnabled: Bool { selection == .mtp }

        var resolvedMTPDraftNMax: Int {
            max(1, min(6, mtpDraftNMax))
        }

        var resolvedMTPDraftNMin: Int {
            max(0, min(resolvedMTPDraftNMax, mtpDraftNMin))
        }

        var resolvedMTPDraftPMin: Double {
            min(1.0, max(0.0, mtpDraftPMin))
        }
    }

    struct RopeScalingSettings: Codable, Equatable {
        var factor: Double = 1.0
        var originalContext: Int = 4096
        var lowFrequency: Double = 1.0
        var highFrequency: Double = 1.0
    }

    enum TensorOverridePreset: String, Codable, CaseIterable, Identifiable {
        case none
        case ffnCPU
        case expertsCPU

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "Default placement"
            case .ffnCPU: return "ffn=CPU (dense models)"
            case .expertsCPU: return "exps=CPU (MoE)"
            }
        }

        var overrideValue: String? {
            switch self {
            case .none: return nil
            case .ffnCPU: return "ffn=CPU"
            case .expertsCPU: return "exps=CPU"
            }
        }

        var requiresWarning: Bool {
            switch self {
            case .none:
                return false
            case .ffnCPU, .expertsCPU:
                return true
            }
        }
    }
}

extension ModelSettings.SpeculativeDecodingSettings {
    private enum CodingKeys: String, CodingKey {
        case selection
        case helperModelID
        case mode
        case value
        case mtpDraftNMax
        case mtpDraftNMin
        case mtpDraftPMin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModelSettings.SpeculativeDecodingSettings()

        self.selection = try container.decodeIfPresent(Selection.self, forKey: .selection) ?? defaults.selection
        self.helperModelID = try container.decodeIfPresent(String.self, forKey: .helperModelID)
        self.mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? defaults.mode
        self.value = try container.decodeIfPresent(Int.self, forKey: .value) ?? defaults.value
        self.mtpDraftNMax = try container.decodeIfPresent(Int.self, forKey: .mtpDraftNMax) ?? defaults.mtpDraftNMax
        self.mtpDraftNMin = try container.decodeIfPresent(Int.self, forKey: .mtpDraftNMin) ?? defaults.mtpDraftNMin
        self.mtpDraftPMin = try container.decodeIfPresent(Double.self, forKey: .mtpDraftPMin) ?? defaults.mtpDraftPMin
        if !container.contains(.selection), helperModelID?.isEmpty == false {
            self.selection = .helperDraftModel
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selection, forKey: .selection)
        try container.encodeIfPresent(helperModelID, forKey: .helperModelID)
        try container.encode(mode, forKey: .mode)
        try container.encode(value, forKey: .value)
        try container.encode(mtpDraftNMax, forKey: .mtpDraftNMax)
        try container.encode(mtpDraftNMin, forKey: .mtpDraftNMin)
        try container.encode(mtpDraftPMin, forKey: .mtpDraftPMin)
    }
}

extension ModelSettings.RopeScalingSettings {
    private enum CodingKeys: String, CodingKey {
        case factor
        case originalContext
        case lowFrequency
        case highFrequency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModelSettings.RopeScalingSettings()

        self.factor = try container.decodeIfPresent(Double.self, forKey: .factor) ?? defaults.factor
        self.originalContext = try container.decodeIfPresent(Int.self, forKey: .originalContext) ?? defaults.originalContext
        self.lowFrequency = try container.decodeIfPresent(Double.self, forKey: .lowFrequency) ?? defaults.lowFrequency
        self.highFrequency = try container.decodeIfPresent(Double.self, forKey: .highFrequency) ?? defaults.highFrequency
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(factor, forKey: .factor)
        try container.encode(originalContext, forKey: .originalContext)
        try container.encode(lowFrequency, forKey: .lowFrequency)
        try container.encode(highFrequency, forKey: .highFrequency)
    }
}
