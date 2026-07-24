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

/// KV-cache precision supported by mlx-swift-lm's `GenerateParameters`.
/// This is intentionally separate from llama.cpp's K/V cache formats: MLX
/// quantizes the combined cache with affine 2, 3, 4, 5, 6, or 8-bit storage.
/// MLX does not provide a 7-bit quantization kernel.
enum MLXKVCacheQuantization: String, Codable, CaseIterable, Identifiable {
    case fullPrecision
    case eightBit
    case sixBit
    case fiveBit
    case fourBit
    case threeBit
    case twoBit

    var id: String { rawValue }

    var bits: Int? {
        switch self {
        case .fullPrecision: return nil
        case .eightBit: return 8
        case .sixBit: return 6
        case .fiveBit: return 5
        case .fourBit: return 4
        case .threeBit: return 3
        case .twoBit: return 2
        }
    }

    var titleKey: String {
        switch self {
        case .fullPrecision: return "Full Precision"
        case .eightBit: return "8-bit"
        case .sixBit: return "6-bit"
        case .fiveBit: return "5-bit"
        case .fourBit: return "4-bit"
        case .threeBit: return "3-bit"
        case .twoBit: return "2-bit"
        }
    }

    var shortLabel: String {
        switch self {
        case .fullPrecision: return "FP"
        case .eightBit: return "8-BIT"
        case .sixBit: return "6-BIT"
        case .fiveBit: return "5-BIT"
        case .fourBit: return "4-BIT"
        case .threeBit: return "3-BIT"
        case .twoBit: return "2-BIT"
        }
    }
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

enum PCCReasoningLevel: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case off
    case light
    case moderate
    case deep

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .deep: return "Deep"
        }
    }

    var detailKey: String {
        switch self {
        case .off:
            return "Answers without extended reasoning for the lowest latency."
        case .light:
            return "Uses a small reasoning budget for quick analysis."
        case .moderate:
            return "Balances response time with deeper analysis. Apple recommends starting here."
        case .deep:
            return "Spends more time reasoning through complex, multi-step requests and uses more of the context window."
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
        defer { storage.lock.unlock() }
        storage.values[key] = resolution
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
    /// Logical maximum number of prompt tokens submitted to llama.cpp per decode.
    var evaluationBatchSize: Int = ModelSettings.defaultEvaluationBatchSize
    /// Physical micro-batch used by llama.cpp while processing a logical batch.
    var physicalBatchSize: Int = ModelSettings.defaultPhysicalBatchSize
    /// Whether llama.cpp should discover and load a companion vision projector.
    /// Defaults to true so settings saved by older app versions keep their behavior.
    var loadVisionProjector: Bool = true
    var kvCacheOffload: Bool = true
    /// Share one llama.cpp KV allocation across server slots instead of
    /// statically partitioning the context between them.
    var unifiedKVCache: Bool = true
    var keepInMemory: Bool = true
    var useMmap: Bool = true
    var disableWarmup: Bool = true
    var flashAttention: Bool = true
    var seed: Int?
    var kCacheQuant: CacheQuant = .f16
    var vCacheQuant: CacheQuant = .f16
    /// Optional tokenizer path to override default
    var tokenizerPath: String?
    /// Optional prompt template for chat models
    var promptTemplate: String?
    // Sampling parameters for generation (used by MLX and others)
    var temperature: Double = 0.7
    var repetitionPenalty: Float = 1.0
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
    /// Reuse matching GGUF prompt prefixes by default. The cache is bounded by the
    /// loopback server configuration, and paged/low-memory modes can still disable it.
    var promptCacheEnabled: Bool = true
    var promptCachePath: String = ""
    var promptCacheAll: Bool = false
    /// Reuse the in-memory MLX KV cache across turns with a shared prompt prefix.
    var mlxPromptCacheEnabled: Bool = true
    /// MLX KV-cache precision. Full precision matches the upstream default.
    var mlxKVCacheQuantization: MLXKVCacheQuantization = .fullPrecision
    /// Quantization group size passed to mlx-swift-lm.
    var mlxKVCacheGroupSize: Int = 64
    /// Number of cached tokens to keep full precision before MLX quantizes the cache.
    var mlxKVCacheQuantizationStart: Int = 0
    /// Maximum rotating KV-cache length. Zero keeps the full cache.
    var mlxKVCacheLimit: Int = 0
    /// Prompt prefill chunk size used by mlx-swift-lm.
    var mlxPrefillStepSize: Int = 512
    var tensorOverride: TensorOverridePreset = .none
    var overfitMode: OverfitMode = .automatic
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
    /// Extended reasoning used only by the explicit Apple Private Cloud Compute model.
    var pccReasoningLevel: PCCReasoningLevel = .moderate
    var systemPromptMode: SystemPromptMode = .inheritGlobal
    var systemPromptOverride: String? = nil
    /// Whether the model is allowed to reason (emit a `<think>` block) before answering.
    /// Per-request via `LLMGenerationOptions.reasoningEnabled`; a no-op for models whose
    /// chat template doesn't honor it (see `ReasoningCapabilityDetector`). Default ON —
    /// reasoning-capable models think by default.
    var reasoningEnabled: Bool = true

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

    static let minimumBatchSize = 32
    static let maximumBatchSize = 8192
    /// Conservative GGUF prompt-processing defaults. Larger batches remain available
    /// in Model Settings for models and devices with enough compute-buffer headroom.
    static let defaultEvaluationBatchSize = 512
    static let defaultPhysicalBatchSize = 256
    /// Version stamped into persisted settings so the one release that used much larger
    /// implicit defaults can be migrated without rewriting deliberate future overrides.
    static let batchSizingDefaultsVersion = 1
    private static let legacyDefaultEvaluationBatchSize = 2048
    private static let legacyDefaultPhysicalBatchSizes: Set<Int> = [512, 1024, 2048]
    /// Version stamped into persisted settings after changing GGUF prompt reuse to
    /// default-on. A missing version identifies an older saved `false`, including a
    /// hand-tuned Custom configuration, that should adopt the new default once.
    static let promptCacheDefaultsVersion = 1
    /// Version stamped into persisted settings after disabling Noema's legacy
    /// blanket repetition penalty. A missing version plus the old implicit 1.1
    /// value identifies settings that should adopt the new neutral default once.
    static let repetitionPenaltyDefaultsVersion = 1
    private static let legacyDefaultRepetitionPenalty: Float = 1.1

    static func `default`(for format: ModelFormat) -> ModelSettings {
        var s = ModelSettings()
        switch format {
        case .mlx:
            s.gpuLayers = 0
            s.cpuThreads = ModelSettings.recommendedInferenceThreadCount
            s.mlxPromptCacheEnabled = true
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
        case evaluationBatchSize
        case physicalBatchSize
        case batchSizingDefaultsVersion
        case loadVisionProjector
        case kvCacheOffload
        case unifiedKVCache
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
        case repetitionPenaltyDefaultsVersion
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
        case promptCacheDefaultsVersion
        case promptCachePath
        case promptCacheAll
        case mlxPromptCacheEnabled
        case mlxKVCacheQuantization
        case mlxKVCacheGroupSize
        case mlxKVCacheQuantizationStart
        case mlxKVCacheLimit
        case mlxPrefillStepSize
        case tensorOverride
        case overfitMode
        case moeActiveExperts
        case etBackend
        case processingUnitConfiguration
        case afmGuardrails
        case pccReasoningLevel
        case systemPromptMode
        case systemPromptOverride
        case reasoningEnabled
    }

    /// Decoding never throws on individual fields: any value this build can't read
    /// (unknown enum raw value or changed type written by a newer version) falls back
    /// to its default instead of failing the whole payload. A thrown decode here used
    /// to make the durable store drop the entire entry — i.e. running an older build
    /// once permanently erased settings saved by a newer one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModelSettings()

        self.contextLength = (try? container.decodeIfPresent(Double.self, forKey: .contextLength)) ?? defaults.contextLength
        self.gpuLayers = (try? container.decodeIfPresent(Int.self, forKey: .gpuLayers)) ?? defaults.gpuLayers
        self.cpuThreads = (try? container.decodeIfPresent(Int.self, forKey: .cpuThreads)) ?? defaults.cpuThreads
        let decodedEvaluationBatchSize = (try? container.decodeIfPresent(Int.self, forKey: .evaluationBatchSize)) ?? defaults.evaluationBatchSize
        let decodedPhysicalBatchSize = (try? container.decodeIfPresent(Int.self, forKey: .physicalBatchSize)) ?? defaults.physicalBatchSize
        let batchSizingDefaultsVersion = (try? container.decodeIfPresent(Int.self, forKey: .batchSizingDefaultsVersion)) ?? 0
        if batchSizingDefaultsVersion < Self.batchSizingDefaultsVersion,
           decodedEvaluationBatchSize == Self.legacyDefaultEvaluationBatchSize,
           Self.legacyDefaultPhysicalBatchSizes.contains(decodedPhysicalBatchSize) {
            self.evaluationBatchSize = defaults.evaluationBatchSize
            self.physicalBatchSize = defaults.physicalBatchSize
        } else {
            self.evaluationBatchSize = decodedEvaluationBatchSize
            self.physicalBatchSize = decodedPhysicalBatchSize
        }
        self.loadVisionProjector = (try? container.decodeIfPresent(Bool.self, forKey: .loadVisionProjector)) ?? defaults.loadVisionProjector
        self.kvCacheOffload = (try? container.decodeIfPresent(Bool.self, forKey: .kvCacheOffload)) ?? defaults.kvCacheOffload
        self.unifiedKVCache = (try? container.decodeIfPresent(Bool.self, forKey: .unifiedKVCache)) ?? defaults.unifiedKVCache
        self.keepInMemory = (try? container.decodeIfPresent(Bool.self, forKey: .keepInMemory)) ?? defaults.keepInMemory
        self.useMmap = (try? container.decodeIfPresent(Bool.self, forKey: .useMmap)) ?? defaults.useMmap
        self.disableWarmup = (try? container.decodeIfPresent(Bool.self, forKey: .disableWarmup)) ?? defaults.disableWarmup
        self.flashAttention = (try? container.decodeIfPresent(Bool.self, forKey: .flashAttention)) ?? defaults.flashAttention
        self.seed = (try? container.decodeIfPresent(Int.self, forKey: .seed)) ?? nil
        self.kCacheQuant = (try? container.decodeIfPresent(CacheQuant.self, forKey: .kCacheQuant)) ?? defaults.kCacheQuant
        self.vCacheQuant = (try? container.decodeIfPresent(CacheQuant.self, forKey: .vCacheQuant)) ?? defaults.vCacheQuant
        self.tokenizerPath = (try? container.decodeIfPresent(String.self, forKey: .tokenizerPath)) ?? nil
        self.promptTemplate = (try? container.decodeIfPresent(String.self, forKey: .promptTemplate)) ?? nil
        self.temperature = (try? container.decodeIfPresent(Double.self, forKey: .temperature)) ?? defaults.temperature
        let decodedRepetitionPenalty = (try? container.decodeIfPresent(Float.self, forKey: .repetitionPenalty)) ?? defaults.repetitionPenalty
        let repetitionPenaltyDefaultsVersion = (try? container.decodeIfPresent(Int.self, forKey: .repetitionPenaltyDefaultsVersion)) ?? 0
        self.repetitionPenalty = repetitionPenaltyDefaultsVersion < Self.repetitionPenaltyDefaultsVersion
            && decodedRepetitionPenalty == Self.legacyDefaultRepetitionPenalty
            ? defaults.repetitionPenalty
            : decodedRepetitionPenalty
        self.topK = (try? container.decodeIfPresent(Int.self, forKey: .topK)) ?? defaults.topK
        self.topP = (try? container.decodeIfPresent(Double.self, forKey: .topP)) ?? defaults.topP
        self.minP = (try? container.decodeIfPresent(Double.self, forKey: .minP)) ?? defaults.minP
        self.repeatLastN = (try? container.decodeIfPresent(Int.self, forKey: .repeatLastN)) ?? defaults.repeatLastN
        self.presencePenalty = (try? container.decodeIfPresent(Float.self, forKey: .presencePenalty)) ?? defaults.presencePenalty
        self.frequencyPenalty = (try? container.decodeIfPresent(Float.self, forKey: .frequencyPenalty)) ?? defaults.frequencyPenalty
        self.stopSequences = (try? container.decodeIfPresent([String].self, forKey: .stopSequences)) ?? nil
        self.speculativeDecoding = (try? container.decodeIfPresent(SpeculativeDecodingSettings.self, forKey: .speculativeDecoding)) ?? defaults.speculativeDecoding
        self.ropeScaling = (try? container.decodeIfPresent(RopeScalingSettings.self, forKey: .ropeScaling)) ?? nil
        self.logitBias = (try? container.decodeIfPresent([Int: Double].self, forKey: .logitBias)) ?? defaults.logitBias
        let decodedPromptCacheEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .promptCacheEnabled)) ?? defaults.promptCacheEnabled
        let promptCacheDefaultsVersion = (try? container.decodeIfPresent(Int.self, forKey: .promptCacheDefaultsVersion)) ?? 0
        self.promptCacheEnabled = promptCacheDefaultsVersion < Self.promptCacheDefaultsVersion
            ? true
            : decodedPromptCacheEnabled
        self.promptCachePath = (try? container.decodeIfPresent(String.self, forKey: .promptCachePath)) ?? defaults.promptCachePath
        self.promptCacheAll = (try? container.decodeIfPresent(Bool.self, forKey: .promptCacheAll)) ?? defaults.promptCacheAll
        self.mlxPromptCacheEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .mlxPromptCacheEnabled)) ?? defaults.mlxPromptCacheEnabled
        self.mlxKVCacheQuantization = (try? container.decodeIfPresent(MLXKVCacheQuantization.self, forKey: .mlxKVCacheQuantization)) ?? defaults.mlxKVCacheQuantization
        self.mlxKVCacheGroupSize = (try? container.decodeIfPresent(Int.self, forKey: .mlxKVCacheGroupSize)) ?? defaults.mlxKVCacheGroupSize
        self.mlxKVCacheQuantizationStart = (try? container.decodeIfPresent(Int.self, forKey: .mlxKVCacheQuantizationStart)) ?? defaults.mlxKVCacheQuantizationStart
        self.mlxKVCacheLimit = (try? container.decodeIfPresent(Int.self, forKey: .mlxKVCacheLimit)) ?? defaults.mlxKVCacheLimit
        self.mlxPrefillStepSize = (try? container.decodeIfPresent(Int.self, forKey: .mlxPrefillStepSize)) ?? defaults.mlxPrefillStepSize
        self.tensorOverride = (try? container.decodeIfPresent(TensorOverridePreset.self, forKey: .tensorOverride)) ?? defaults.tensorOverride
        self.overfitMode = (try? container.decodeIfPresent(OverfitMode.self, forKey: .overfitMode)) ?? defaults.overfitMode
        self.moeActiveExperts = (try? container.decodeIfPresent(Int.self, forKey: .moeActiveExperts)) ?? nil
        self.etBackend = (try? container.decodeIfPresent(ETBackend.self, forKey: .etBackend)) ?? defaults.etBackend
        self.processingUnitConfiguration = (try? container.decodeIfPresent(ProcessingUnitConfiguration.self, forKey: .processingUnitConfiguration)) ?? nil
        self.afmGuardrails = (try? container.decodeIfPresent(AFMGuardrailsMode.self, forKey: .afmGuardrails)) ?? defaults.afmGuardrails
        self.pccReasoningLevel = (try? container.decodeIfPresent(PCCReasoningLevel.self, forKey: .pccReasoningLevel)) ?? defaults.pccReasoningLevel
        self.systemPromptMode = (try? container.decodeIfPresent(SystemPromptMode.self, forKey: .systemPromptMode)) ?? defaults.systemPromptMode
        self.systemPromptOverride = (try? container.decodeIfPresent(String.self, forKey: .systemPromptOverride)) ?? nil
        self.reasoningEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .reasoningEnabled)) ?? defaults.reasoningEnabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contextLength, forKey: .contextLength)
        try container.encode(gpuLayers, forKey: .gpuLayers)
        try container.encode(cpuThreads, forKey: .cpuThreads)
        try container.encode(evaluationBatchSize, forKey: .evaluationBatchSize)
        try container.encode(physicalBatchSize, forKey: .physicalBatchSize)
        try container.encode(Self.batchSizingDefaultsVersion, forKey: .batchSizingDefaultsVersion)
        try container.encode(loadVisionProjector, forKey: .loadVisionProjector)
        try container.encode(kvCacheOffload, forKey: .kvCacheOffload)
        try container.encode(unifiedKVCache, forKey: .unifiedKVCache)
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
        try container.encode(Self.repetitionPenaltyDefaultsVersion, forKey: .repetitionPenaltyDefaultsVersion)
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
        try container.encode(Self.promptCacheDefaultsVersion, forKey: .promptCacheDefaultsVersion)
        try container.encode(mlxPromptCacheEnabled, forKey: .mlxPromptCacheEnabled)
        try container.encode(mlxKVCacheQuantization, forKey: .mlxKVCacheQuantization)
        try container.encode(mlxKVCacheGroupSize, forKey: .mlxKVCacheGroupSize)
        try container.encode(mlxKVCacheQuantizationStart, forKey: .mlxKVCacheQuantizationStart)
        try container.encode(mlxKVCacheLimit, forKey: .mlxKVCacheLimit)
        try container.encode(mlxPrefillStepSize, forKey: .mlxPrefillStepSize)
        try container.encode(tensorOverride, forKey: .tensorOverride)
        try container.encode(overfitMode, forKey: .overfitMode)
        try container.encodeIfPresent(moeActiveExperts, forKey: .moeActiveExperts)
        try container.encode(etBackend, forKey: .etBackend)
        try container.encodeIfPresent(processingUnitConfiguration, forKey: .processingUnitConfiguration)
        try container.encode(afmGuardrails, forKey: .afmGuardrails)
        try container.encode(pccReasoningLevel, forKey: .pccReasoningLevel)
        try container.encode(systemPromptMode, forKey: .systemPromptMode)
        try container.encodeIfPresent(systemPromptOverride, forKey: .systemPromptOverride)
        try container.encode(reasoningEnabled, forKey: .reasoningEnabled)
    }
}

extension ModelSettings {
    /// Copies only request-time sampling controls, leaving load-time/runtime
    /// fields (context, compute units, prompt template, and so on) untouched.
    /// This is used by Chat's live sampling sidebar so moving a control cannot
    /// accidentally undo a power-policy adjustment or another settings edit.
    mutating func applySamplingSettings(from source: ModelSettings) {
        seed = source.seed
        temperature = source.temperature
        repetitionPenalty = source.repetitionPenalty
        topK = source.topK
        topP = source.topP
        minP = source.minP
        repeatLastN = source.repeatLastN
        presencePenalty = source.presencePenalty
        frequencyPenalty = source.frequencyPenalty
    }

    var resolvedProcessingUnitConfiguration: ProcessingUnitConfiguration {
        processingUnitConfiguration ?? .all
    }

    var resolvedEvaluationBatchSize: Int {
        min(max(Self.minimumBatchSize, evaluationBatchSize), Self.maximumBatchSize)
    }

    var resolvedPhysicalBatchSize: Int {
        min(
            resolvedEvaluationBatchSize,
            min(max(Self.minimumBatchSize, physicalBatchSize), Self.maximumBatchSize)
        )
    }

    static let mlxKVCacheGroupSizes = [32, 64, 128]
    static let mlxPrefillStepSizes = [128, 256, 512, 1024, 2048]

    var resolvedMLXKVCacheGroupSize: Int {
        Self.mlxKVCacheGroupSizes.min(by: {
            abs(Double($0) - Double(mlxKVCacheGroupSize))
                < abs(Double($1) - Double(mlxKVCacheGroupSize))
        }) ?? 64
    }

    var resolvedMLXKVCacheQuantizationStart: Int {
        let context = contextLength.isFinite
            ? Int(max(0, min(contextLength, Double(Int.max))))
            : 0
        return min(max(0, mlxKVCacheQuantizationStart), context)
    }

    var resolvedMLXKVCacheLimit: Int? {
        mlxKVCacheLimit > 0 ? max(128, mlxKVCacheLimit) : nil
    }

    var resolvedMLXPrefillStepSize: Int {
        Self.mlxPrefillStepSizes.min(by: {
            abs(Double($0) - Double(mlxPrefillStepSize))
                < abs(Double($1) - Double(mlxPrefillStepSize))
        }) ?? 512
    }

    func normalizedForLocalModel(_ model: LocalModel) -> ModelSettings {
        var normalized = self
        normalized.contextLength = max(1, normalized.contextLength.rounded())
        if let supportedMaxContextLength = Self.supportedMaxContextLength(for: model) {
            normalized.contextLength = min(normalized.contextLength, Double(supportedMaxContextLength))
        }
        normalized.evaluationBatchSize = normalized.resolvedEvaluationBatchSize
        normalized.physicalBatchSize = normalized.resolvedPhysicalBatchSize
        normalized.mlxKVCacheGroupSize = normalized.resolvedMLXKVCacheGroupSize
        normalized.mlxKVCacheQuantizationStart = normalized.resolvedMLXKVCacheQuantizationStart
        normalized.mlxKVCacheLimit = normalized.resolvedMLXKVCacheLimit ?? 0
        normalized.mlxPrefillStepSize = normalized.resolvedMLXPrefillStepSize
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
            let modelLimit = GGUFMetadata.contextLength(at: canonicalURL)
            guard PagedPackageLocator.isPagedInstall(canonicalURL) else {
                return modelLimit
            }
            return min(modelLimit ?? Int.max, OverfitPlanResolver.pagedContextCapTokens)
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
            let kind = AppleFoundationModelKind.resolve(modelID: model.modelID)
            return kind == .privateCloudCompute
                ? AppleFoundationModelKind.privateCloudContextLimit
                : AFMLLMClient.onDeviceContextLimit()
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
                case .max: return "Adaptive Draft Limit"
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
        var mtpAutoTune: Bool = true

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

        var mtpAutoTuneActive: Bool { mtpEnabled && mtpAutoTune }

        var effectiveMTPDraftNMax: Int {
            mtpAutoTuneActive ? SpeculativeAutoTune.deviceDraftCap : resolvedMTPDraftNMax
        }

        var effectiveMTPDraftNMin: Int {
            mtpAutoTuneActive ? 0 : resolvedMTPDraftNMin
        }

        var effectiveMTPDraftPMin: Double {
            mtpAutoTuneActive ? SpeculativeAutoTune.pMin : resolvedMTPDraftPMin
        }
    }

    struct RopeScalingSettings: Codable, Equatable {
        var factor: Double = 1.0
        var originalContext: Int = 4096
        var betaFast: Double = 1.0
        var betaSlow: Double = 1.0

        // Source compatibility for older callers; persistence now uses the
        // accurately named YaRN beta fields.
        var lowFrequency: Double {
            get { betaFast }
            set { betaFast = newValue }
        }
        var highFrequency: Double {
            get { betaSlow }
            set { betaSlow = newValue }
        }

        private enum CodingKeys: String, CodingKey {
            case factor, originalContext, betaFast, betaSlow, lowFrequency, highFrequency
        }

        init(factor: Double = 1.0, originalContext: Int = 4096,
             betaFast: Double = 1.0, betaSlow: Double = 1.0) {
            self.factor = factor
            self.originalContext = originalContext
            self.betaFast = betaFast
            self.betaSlow = betaSlow
        }

        init(factor: Double, originalContext: Int,
             lowFrequency: Double, highFrequency: Double) {
            self.init(
                factor: factor,
                originalContext: originalContext,
                betaFast: lowFrequency,
                betaSlow: highFrequency
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            factor = try container.decodeIfPresent(Double.self, forKey: .factor) ?? 1.0
            originalContext = try container.decodeIfPresent(Int.self, forKey: .originalContext) ?? 4096
            betaFast = try container.decodeIfPresent(Double.self, forKey: .betaFast)
                ?? container.decodeIfPresent(Double.self, forKey: .lowFrequency)
                ?? 1.0
            betaSlow = try container.decodeIfPresent(Double.self, forKey: .betaSlow)
                ?? container.decodeIfPresent(Double.self, forKey: .highFrequency)
                ?? 1.0
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(factor, forKey: .factor)
            try container.encode(originalContext, forKey: .originalContext)
            try container.encode(betaFast, forKey: .betaFast)
            try container.encode(betaSlow, forKey: .betaSlow)
        }
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

    /// Noema Overfit (paged experts) policy for GGUF installs.
    /// `.automatic` runs paged packages paged and everything else resident;
    /// `.off` refuses paged installs; `.forceExperimental` additionally
    /// bypasses performance classification (never integrity checks).
    enum OverfitMode: String, Codable, CaseIterable, Identifiable {
        case off
        case automatic
        case forceExperimental

        var id: String { rawValue }
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
        case mtpAutoTune
    }

    /// Field-tolerant like `ModelSettings.init(from:)`: unknown raw values (e.g. a
    /// selection written by a newer build) default instead of throwing, so the parent
    /// entry survives version skew.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModelSettings.SpeculativeDecodingSettings()

        self.selection = (try? container.decodeIfPresent(Selection.self, forKey: .selection)) ?? defaults.selection
        self.helperModelID = (try? container.decodeIfPresent(String.self, forKey: .helperModelID)) ?? nil
        self.mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)) ?? defaults.mode
        self.value = (try? container.decodeIfPresent(Int.self, forKey: .value)) ?? defaults.value
        self.mtpDraftNMax = (try? container.decodeIfPresent(Int.self, forKey: .mtpDraftNMax)) ?? defaults.mtpDraftNMax
        self.mtpDraftNMin = (try? container.decodeIfPresent(Int.self, forKey: .mtpDraftNMin)) ?? defaults.mtpDraftNMin
        self.mtpDraftPMin = (try? container.decodeIfPresent(Double.self, forKey: .mtpDraftPMin)) ?? defaults.mtpDraftPMin
        self.mtpAutoTune = (try? container.decodeIfPresent(Bool.self, forKey: .mtpAutoTune)) ?? defaults.mtpAutoTune
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
        try container.encode(mtpAutoTune, forKey: .mtpAutoTune)
    }
}
