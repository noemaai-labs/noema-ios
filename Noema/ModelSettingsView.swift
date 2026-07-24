import SwiftUI
import NoemaPackages
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

private enum ModelRuntimePreset: String, CaseIterable, Identifiable {
    case batterySaver
    case balanced
    case maxSpeed
    case maxContext
    case maxContextAggressive
    case visionHeavy
    case toolHeavy

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .batterySaver: return "Battery Saver"
        case .balanced: return "Balanced"
        case .maxSpeed: return "Max Speed"
        case .maxContext: return "Max Context"
        case .maxContextAggressive: return "Max Context (Aggressive)"
        case .visionHeavy: return "Vision Heavy"
        case .toolHeavy: return "Tool Heavy"
        }
    }

    var subtitleKey: LocalizedStringKey {
        switch self {
        case .batterySaver: return "Lower memory"
        case .balanced: return "Everyday chat"
        case .maxSpeed: return "Fast first tokens"
        case .maxContext: return "Long documents"
        case .maxContextAggressive: return "Longest context"
        case .visionHeavy: return "Images and OCR"
        case .toolHeavy: return "Tools and RAG"
        }
    }

    var systemImage: String {
        switch self {
        case .batterySaver: return "battery.75"
        case .balanced: return "gauge.medium"
        case .maxSpeed: return "bolt.fill"
        case .maxContext: return "rectangle.expand.vertical"
        case .maxContextAggressive: return "flame.fill"
        case .visionHeavy: return "photo.on.rectangle.angled"
        case .toolHeavy: return "wrench.and.screwdriver"
        }
    }

    /// One-line summary of what the preset actually changes, surfaced beneath the
    /// preset grid so the runtime behaviour is explained without cluttering each card.
    func detailKey(for format: ModelFormat) -> LocalizedStringKey {
        if format == .mlx {
            switch self {
            case .batterySaver:
                return "4-bit KV cache and smaller prefill batches reduce memory use."
            case .balanced:
                return "8-bit KV cache, prompt reuse, and standard prefill batches."
            case .maxSpeed:
                return "Full-precision KV cache and larger prefill batches prioritize throughput."
            case .maxContext:
                return "4-bit KV cache stretches the longest supported context."
            case .maxContextAggressive, .visionHeavy, .toolHeavy:
                return "MLX runtime preset"
            }
        }
        switch self {
        case .batterySaver:
            return "Scales context to your device — about 4K, or up to 8K for small models with memory to spare — with fewer CPU threads and a compact q8_0 KV cache. Lowest memory and power use."
        case .balanced:
            return "Around 8K context with full GPU offload and an f16 KV cache. The everyday default."
        case .maxSpeed:
            return "Around 8K context with flash attention and a q8_0 KV cache for the fastest token generation with minimal memory."
        case .maxContext:
            return "Stretches context to the largest the device allows, keeping a full-precision KV cache and only switching to a compact q8_0 cache when needed to fit. Stops once the model's full context fits."
        case .maxContextAggressive:
            return "Pushes context to the absolute maximum the device can hold: enables flash attention and a heavily quantized KV cache (Q4 keys, IQ4_NL values) when required. Slower, but fits the longest documents."
        case .visionHeavy:
            return "Around 12K context with flash attention, tuned for image and OCR workloads."
        case .toolHeavy:
            return "Around 16K context with flash attention and prompt caching, tuned for tools and RAG."
        }
    }
}

/// A user-saved runtime preset: a named snapshot of the runtime knobs the preset
/// grid controls. Stored globally (JSON in UserDefaults) so it can be applied to
/// any model, and clamped to what each model/device can actually fit on apply.
struct CustomRuntimePreset: Codable, Identifiable, Equatable {
    static let promptCacheDefaultsVersion = 1

    var id: UUID = UUID()
    var name: String
    var contextLength: Double
    var cpuThreads: Int
    var keepInMemory: Bool
    var kvCacheOffload: Bool
    var unifiedKVCache: Bool
    var flashAttention: Bool
    var kCacheQuant: CacheQuant
    var vCacheQuant: CacheQuant
    var promptCacheEnabled: Bool
    var gpuLayers: Int
    var mlxPromptCacheEnabled: Bool
    var mlxKVCacheQuantization: MLXKVCacheQuantization
    var mlxKVCacheGroupSize: Int
    var mlxKVCacheQuantizationStart: Int
    var mlxKVCacheLimit: Int
    var mlxPrefillStepSize: Int

    /// Captures the runtime-relevant fields from a live `ModelSettings`.
    init(name: String, settings: ModelSettings) {
        self.id = UUID()
        self.name = name
        self.contextLength = settings.contextLength
        self.cpuThreads = settings.cpuThreads
        self.keepInMemory = settings.keepInMemory
        self.kvCacheOffload = settings.kvCacheOffload
        self.unifiedKVCache = settings.unifiedKVCache
        self.flashAttention = settings.flashAttention
        self.kCacheQuant = settings.kCacheQuant
        self.vCacheQuant = settings.vCacheQuant
        self.promptCacheEnabled = settings.promptCacheEnabled
        self.gpuLayers = settings.gpuLayers
        self.mlxPromptCacheEnabled = settings.mlxPromptCacheEnabled
        self.mlxKVCacheQuantization = settings.mlxKVCacheQuantization
        self.mlxKVCacheGroupSize = settings.mlxKVCacheGroupSize
        self.mlxKVCacheQuantizationStart = settings.mlxKVCacheQuantizationStart
        self.mlxKVCacheLimit = settings.mlxKVCacheLimit
        self.mlxPrefillStepSize = settings.mlxPrefillStepSize
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, contextLength, cpuThreads, keepInMemory, kvCacheOffload, unifiedKVCache
        case flashAttention, kCacheQuant, vCacheQuant, promptCacheEnabled, promptCacheDefaultsVersion, gpuLayers
        case mlxPromptCacheEnabled, mlxKVCacheQuantization, mlxKVCacheGroupSize
        case mlxKVCacheQuantizationStart, mlxKVCacheLimit, mlxPrefillStepSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModelSettings()
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        contextLength = (try? container.decodeIfPresent(Double.self, forKey: .contextLength)) ?? defaults.contextLength
        cpuThreads = (try? container.decodeIfPresent(Int.self, forKey: .cpuThreads)) ?? defaults.cpuThreads
        keepInMemory = (try? container.decodeIfPresent(Bool.self, forKey: .keepInMemory)) ?? defaults.keepInMemory
        kvCacheOffload = (try? container.decodeIfPresent(Bool.self, forKey: .kvCacheOffload)) ?? defaults.kvCacheOffload
        unifiedKVCache = (try? container.decodeIfPresent(Bool.self, forKey: .unifiedKVCache)) ?? defaults.unifiedKVCache
        flashAttention = (try? container.decodeIfPresent(Bool.self, forKey: .flashAttention)) ?? defaults.flashAttention
        kCacheQuant = (try? container.decodeIfPresent(CacheQuant.self, forKey: .kCacheQuant)) ?? defaults.kCacheQuant
        vCacheQuant = (try? container.decodeIfPresent(CacheQuant.self, forKey: .vCacheQuant)) ?? defaults.vCacheQuant
        let decodedPromptCacheEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .promptCacheEnabled)) ?? defaults.promptCacheEnabled
        let promptCacheDefaultsVersion = (try? container.decodeIfPresent(Int.self, forKey: .promptCacheDefaultsVersion)) ?? 0
        promptCacheEnabled = promptCacheDefaultsVersion < Self.promptCacheDefaultsVersion
            ? true
            : decodedPromptCacheEnabled
        gpuLayers = (try? container.decodeIfPresent(Int.self, forKey: .gpuLayers)) ?? defaults.gpuLayers
        mlxPromptCacheEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .mlxPromptCacheEnabled)) ?? defaults.mlxPromptCacheEnabled
        mlxKVCacheQuantization = (try? container.decodeIfPresent(MLXKVCacheQuantization.self, forKey: .mlxKVCacheQuantization)) ?? defaults.mlxKVCacheQuantization
        mlxKVCacheGroupSize = (try? container.decodeIfPresent(Int.self, forKey: .mlxKVCacheGroupSize)) ?? defaults.mlxKVCacheGroupSize
        mlxKVCacheQuantizationStart = (try? container.decodeIfPresent(Int.self, forKey: .mlxKVCacheQuantizationStart)) ?? defaults.mlxKVCacheQuantizationStart
        mlxKVCacheLimit = (try? container.decodeIfPresent(Int.self, forKey: .mlxKVCacheLimit)) ?? defaults.mlxKVCacheLimit
        mlxPrefillStepSize = (try? container.decodeIfPresent(Int.self, forKey: .mlxPrefillStepSize)) ?? defaults.mlxPrefillStepSize
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(contextLength, forKey: .contextLength)
        try container.encode(cpuThreads, forKey: .cpuThreads)
        try container.encode(keepInMemory, forKey: .keepInMemory)
        try container.encode(kvCacheOffload, forKey: .kvCacheOffload)
        try container.encode(unifiedKVCache, forKey: .unifiedKVCache)
        try container.encode(flashAttention, forKey: .flashAttention)
        try container.encode(kCacheQuant, forKey: .kCacheQuant)
        try container.encode(vCacheQuant, forKey: .vCacheQuant)
        try container.encode(promptCacheEnabled, forKey: .promptCacheEnabled)
        try container.encode(Self.promptCacheDefaultsVersion, forKey: .promptCacheDefaultsVersion)
        try container.encode(gpuLayers, forKey: .gpuLayers)
        try container.encode(mlxPromptCacheEnabled, forKey: .mlxPromptCacheEnabled)
        try container.encode(mlxKVCacheQuantization, forKey: .mlxKVCacheQuantization)
        try container.encode(mlxKVCacheGroupSize, forKey: .mlxKVCacheGroupSize)
        try container.encode(mlxKVCacheQuantizationStart, forKey: .mlxKVCacheQuantizationStart)
        try container.encode(mlxKVCacheLimit, forKey: .mlxKVCacheLimit)
        try container.encode(mlxPrefillStepSize, forKey: .mlxPrefillStepSize)
    }
}

enum ModelSettingsSectionID: String, Codable, CaseIterable, Sendable {
    case essentials
    case performance
    case behavior
    case advanced
    case details

    var systemImage: String {
        switch self {
        case .essentials: return "dial.medium"
        case .performance: return "bolt"
        case .behavior: return "brain"
        case .advanced: return "slider.horizontal.3"
        case .details: return "info.circle"
        }
    }
}

struct ModelSettingsSectionSnapshot: Codable, Equatable, Identifiable, Sendable {
    enum Platform: String, Codable, Sendable {
        case iOSForm
        case macOS
    }

    let id: ModelSettingsSectionID
    let title: String

    static func sections(
        for _: ModelFormat,
        isAdvancedMode: Bool,
        platform _: Platform
    ) -> [ModelSettingsSectionSnapshot] {
        // Every device uses the same mental model. Platform-specific layout
        // changes navigation and density, not the order or ownership of controls.
        var sections: [ModelSettingsSectionSnapshot] = [
            .init(id: .essentials, title: "Essentials"),
            .init(id: .performance, title: "Performance"),
            .init(id: .behavior, title: "Behavior")
        ]

        if isAdvancedMode {
            sections.append(.init(id: .advanced, title: "Advanced"))
        }

        sections.append(.init(id: .details, title: "Model Details"))

        return sections
    }
}

private struct TemplateSourceCandidate: Identifiable {
    let id: String
    let title: String
    let detail: String
    let kind: String
    let status: LocalizedStringKey
    let statusColor: Color
    let snippet: String
}

private struct TemplateSourceDiffRow: View {
    let candidate: TemplateSourceCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: candidate.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Kind: %@"),
                            candidate.kind
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(candidate.status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(candidate.statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(candidate.statusColor.opacity(0.12), in: Capsule())
            }

            Text(verbatim: candidate.snippet)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
        .background(AppTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}

/// Isolated context-length control. It keeps a local `draft` while the slider is
/// being dragged and only writes back to the parent's `contextLength` when the
/// drag ends — so dragging re-renders just this small view instead of the entire
/// (very large) `ModelSettingsView`. The RAM estimate still updates live off the
/// local draft (cheap arithmetic).
private struct ContextLengthControl: View {
    @Binding var contextLength: Double
    let range: ClosedRange<Double>
    let format: ModelFormat
    let fixedContextLength: Int?
    let showsRAMEstimate: Bool
    let sizeBytes: Int64
    let layerCount: Int?
    let moeInfo: MoEInfo?
    let supportedMaxContextLength: Int?
    let kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate
    let runtimeConfiguration: ModelRAMAdvisor.RuntimeConfiguration
    /// Context already loaded successfully with these same memory-affecting settings.
    let knownWorkingContextLength: Int?
    /// Paged (Noema Overfit) installs must size through the paged native
    /// contract so bank/staging accounting reaches the estimate; nil for
    /// resident models. Resolved by the parent via
    /// GGUFServerConfigurationResolver.resolveWithPlan.
    var pagedServerConfiguration: LlamaServerBridge.StartConfiguration? = nil
    /// When a helper draft model is configured, its working set is added on top of
    /// the target model's so the estimate reflects what both models need loaded
    /// together (weights + KV cache, at the same context length and cache quant).
    var draftEstimateInput: DraftEstimateInput? = nil
    /// Only attach the guided-walkthrough anchor preference when the walkthrough is
    /// actually presenting; otherwise the preference machinery makes scrolling janky.
    var attachWalkthroughHighlight: Bool = false

    struct DraftEstimateInput {
        let format: ModelFormat
        let sizeBytes: Int64
        let layerCount: Int?
        let moeInfo: MoEInfo?
        let runtimeConfiguration: ModelRAMAdvisor.RuntimeConfiguration
    }

    @State private var draft: Double = 0
    @State private var isEditing = false

    private var draftFingerprint: String {
        guard let d = draftEstimateInput else { return "none" }
        return "\(d.format.rawValue)|\(d.sizeBytes)|\(d.layerCount ?? -1)|\(d.runtimeConfiguration.evaluationBatchSize)|\(d.runtimeConfiguration.physicalBatchSize)|\(d.runtimeConfiguration.flashAttention)|\(d.runtimeConfiguration.projectorFileBytes)"
    }

    /// Every input the RAM estimate depends on, bundled so a single `onChange` drives the
    /// recompute. `kvCacheEstimate` is included so the estimate refreshes when the KV-cache
    /// quant settles in after the sheet opens.
    private struct RAMInputs: Equatable {
        var ctx: Int
        var kv: ModelRAMAdvisor.GGUFKVCacheEstimate
        var layers: Int
        var draft: String
        var size: Int64
        var runtime: ModelRAMAdvisor.RuntimeConfiguration
        var knownWorkingContext: Int
    }
    private var ramInputsFingerprint: RAMInputs {
        RAMInputs(ctx: Int(displayValue),
                  kv: kvCacheEstimate,
                  layers: layerCount ?? -1,
                  draft: draftFingerprint,
                  size: sizeBytes,
                  runtime: runtimeConfiguration,
                  knownWorkingContext: knownWorkingContextLength ?? 0)
    }

    /// Inputs that define one llama.cpp allocation curve. Context is deliberately excluded:
    /// changing only the slider position must not restart curve calibration.
    private struct ExactProfileInputs: Equatable {
        var kv: ModelRAMAdvisor.GGUFKVCacheEstimate
        var runtime: ModelRAMAdvisor.RuntimeConfiguration
        var paged: LlamaServerBridge.StartConfiguration?
        var lowerContext: Int
        var upperContext: Int
        var isApplicable: Bool
    }

    private var exactProfileFingerprint: ExactProfileInputs {
        ExactProfileInputs(
            kv: kvCacheEstimate,
            runtime: runtimeConfiguration,
            paged: pagedServerConfiguration,
            lowerContext: Int(range.lowerBound),
            upperContext: Int(range.upperBound),
            isApplicable: format == .gguf
                && runtimeConfiguration.modelPath != nil
                && draftEstimateInput == nil
        )
    }

    /// Exact verification follows the committed binding, not the rapidly changing local draft.
    /// Cached exact samples are used when available; otherwise live updates stay arithmetic-only.
    private struct ExactAssessmentInputs: Equatable {
        var profile: ExactProfileInputs
        var contextLength: Int
    }

    private var exactAssessmentFingerprint: ExactAssessmentInputs {
        ExactAssessmentInputs(
            profile: exactProfileFingerprint,
            contextLength: Int(contextLength)
        )
    }

    // Cached RAM estimate. The math is cheap, but it allocates two
    // ByteCountFormatters per evaluation, and the view body can re-render for
    // many reasons (scroll re-realization, observed-object churn). Compute it
    // only when the inputs that affect it actually change.
    private struct RAMEstimate: Equatable {
        var estimate: Int64 = 0
        var budget: Int64? = nil
        var workingSet: Int64 = 0
        var nominalWorkingSetLimit: Int64? = nil
        var advisoryWorkingSetLimit: Int64? = nil
        var maxCtx: Int? = nil
        var workingSetStr: String = "--"
        var workingSetLimitStr: String = "--"
        /// Target + draft model working set, when a helper draft model is set.
        var combined: Int64? = nil
        var combinedStr: String = "--"
    }
    @State private var ram = RAMEstimate()

    private enum ExactFitState: Equatable {
        case notApplicable
        case calculating
        case fits
        case doesNotFit
        case unavailable
    }
    @State private var exactFitState: ExactFitState = .notApplicable
    @State private var exactCurveCalibrating = false

    private struct ExactSizingAnchor: Equatable {
        let contextLength: Int
        let kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate
        let runtimeConfiguration: ModelRAMAdvisor.RuntimeConfiguration
    }
    @State private var exactSizingAnchor: ExactSizingAnchor?

    private var matchingExactAnchorContextLength: Int? {
        guard let exactSizingAnchor,
              exactSizingAnchor.kvCacheEstimate == kvCacheEstimate,
              exactSizingAnchor.runtimeConfiguration == runtimeConfiguration else { return nil }
        return exactSizingAnchor.contextLength
    }

    private var isSliderFormat: Bool {
        format == .gguf || format == .mlx || format == .et || format == .coreai
    }

    private var displayValue: Double {
        if let fixedContextLength {
            return Double(fixedContextLength)
        }
        return isEditing ? draft : contextLength
    }

    /// Keep the trailing token count from resizing the slider as it crosses digit boundaries.
    private var contextValueColumnWidth: CGFloat {
        let characters = max(5, String(max(0, Int(range.upperBound))).count)
        return max(48, CGFloat(characters) * 7.25)
    }

    private var afmContextDescription: String {
        let locale = LocalizationManager.preferredLocale()
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: Int(displayValue)))
            ?? String(Int(displayValue))
        return String.localizedStringWithFormat(
            String(localized: "Current context window: %@ tokens.", locale: locale),
            count
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(format == .afm ? "Fixed Context Length" : "Context Length")
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .padding(.bottom, 7)
                IndustrialHairline()
            }

            if isSliderFormat {
                HStack(spacing: 10) {
#if os(macOS)
                    // Stepped sliders draw tick marks on macOS; quantize in the
                    // binding instead so the rail stays clean.
                    Slider(
                        value: Binding(
                            get: { isEditing ? draft : contextLength },
                            set: { draft = ($0 / 256).rounded() * 256 }
                        ),
                        in: range,
                        onEditingChanged: { editing in
                            if editing {
                                draft = contextLength
                                isEditing = true
                            } else {
                                contextLength = draft
                                isEditing = false
                            }
                        }
                    )
                    .controlSize(.small)
                    .guideHighlightIfActive(attachWalkthroughHighlight, .modelSettingsContext)
#else
                    Slider(
                        value: Binding(
                            get: { isEditing ? draft : contextLength },
                            set: { draft = $0 }
                        ),
                        in: range,
                        step: 256,
                        onEditingChanged: { editing in
                            if editing {
                                draft = contextLength
                                isEditing = true
                            } else {
                                contextLength = draft
                                isEditing = false
                            }
                        }
                    )
                    .guideHighlightIfActive(attachWalkthroughHighlight, .modelSettingsContext)
#endif

                    Text(verbatim: "\(Int(displayValue))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: contextValueColumnWidth, alignment: .trailing)
                }
            } else {
                HStack {
                    Text("\(Int(displayValue)) tokens")
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            if format == .ane {
                Text("Derived from model title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if format == .afm {
                Text(verbatim: afmContextDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showsRAMEstimate {
                ramEstimateRows()
            }

            if isSliderFormat && displayValue > 8192 {
                Text("High context lengths use more memory")
                    .font(.caption)
                    .foregroundColor(pressureColor(for: currentPressureBand))
            }
        }
        // One trigger over all inputs, computed on appear (`initial: true`) and on any
        // change. Crucially this includes `kvCacheEstimate`: the per-model settings (KV
        // quant, flash attention) load a frame *after* the sheet first appears, flipping
        // it from the default f16/f16. Keying recompute on the combined fingerprint makes
        // the estimate refresh then — previously it stayed on the default cache cost until
        // the slider was nudged.
        .onChange(of: ramInputsFingerprint, initial: true) { _, _ in recomputeRAM() }
        .task(id: exactProfileFingerprint) {
            await warmExactGGUFSizingCurve(for: exactProfileFingerprint)
        }
        .task(id: exactAssessmentFingerprint) {
            await refreshExactGGUFFit(for: exactAssessmentFingerprint)
        }
    }

    private func warmExactGGUFSizingCurve(for profile: ExactProfileInputs) async {
        guard profile.isApplicable else {
            exactCurveCalibrating = false
            return
        }

        // Stored per-model settings settle one frame after presentation. Debounce before
        // entering the non-cancellable native sizing call so the superseded default profile
        // cannot queue an additional GGUF/context construction pass.
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, profile == exactProfileFingerprint else { return }

        exactCurveCalibrating = true
        let contexts = ModelRAMAdvisor.settingsExactSizingContexts(
            selectedContext: Int(contextLength),
            lowerBound: profile.lowerContext,
            upperBound: profile.upperContext,
            runtimeConfiguration: profile.runtime
        )
        for context in contexts {
            // A paged configuration carries its own (cap-clamped) context, so
            // every calibration point sizes the shape the launch will use.
            _ = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
                contextLength: context,
                kvCacheEstimate: profile.kv,
                runtimeConfiguration: profile.runtime,
                serverConfiguration: profile.paged
            )
            guard !Task.isCancelled, profile == exactProfileFingerprint else { return }
        }

        exactCurveCalibrating = false
        // The bounded exact samples now serve live slider movement through interpolation or
        // extrapolation. No GGUF scan or graph setup occurs on individual slider ticks.
        recomputeRAM()
    }

    private func refreshExactGGUFFit(for inputs: ExactAssessmentInputs) async {
        guard inputs.profile.isApplicable else {
            exactFitState = .notApplicable
            exactSizingAnchor = nil
            return
        }
        // Paged launches clamp context at the plan cap, so the effective sized
        // context is the configuration's, not the slider's.
        let sizedContext = inputs.profile.paged.map { Int($0.contextSize) } ?? inputs.contextLength
        guard ModelRAMAdvisor.permitsSettingsExactSizing(
            contextLength: sizedContext,
            runtimeConfiguration: inputs.profile.runtime
        ) else {
            // The bounded exact curve still feeds the estimate. The launch path performs the
            // authoritative point check for contexts outside the settings-safe window.
            exactFitState = .unavailable
            exactSizingAnchor = nil
            recomputeRAM()
            return
        }

        exactFitState = .calculating
        do {
            // Avoid starting a metadata/graph sizing pass for every intermediate slider tick.
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        let assessedContext = sizedContext
        let assessment = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
            contextLength: assessedContext,
            kvCacheEstimate: inputs.profile.kv,
            runtimeConfiguration: inputs.profile.runtime,
            serverConfiguration: inputs.profile.paged
        )
        guard !Task.isCancelled, inputs == exactAssessmentFingerprint else { return }

        switch assessment.status {
        case .fits:
            exactFitState = .fits
            exactSizingAnchor = ExactSizingAnchor(
                contextLength: assessedContext,
                kvCacheEstimate: inputs.profile.kv,
                runtimeConfiguration: inputs.profile.runtime
            )
        case .doesNotFit:
            exactFitState = .doesNotFit
            exactSizingAnchor = ExactSizingAnchor(
                contextLength: assessedContext,
                kvCacheEstimate: inputs.profile.kv,
                runtimeConfiguration: inputs.profile.runtime
            )
        case .unavailable:
            exactFitState = .unavailable
        }
        // The sizing pass populated the exact cache. Recompute the hard launch allocation and
        // the separate total-working-set pressure recommendation from that breakdown.
        recomputeRAM(exactAnchorContextLength: assessedContext)
    }

    private func recomputeRAM(exactAnchorContextLength: Int? = nil) {
        let ctx = Int(displayValue)
        let exactAnchorContextLength = exactAnchorContextLength
            ?? matchingExactAnchorContextLength
        let (estimate, budget) = ModelRAMAdvisor.estimateAndBudget(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: ctx,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration,
            knownWorkingContextLength: knownWorkingContextLength
        )
        let nominalWorkingSetLimit = ModelRAMAdvisor.currentMemoryBudgetSnapshot().bytes
        let advisoryWorkingSetLimit = ModelRAMAdvisor.advisoryWorkingSetLimitBytes(
            processLimitBytes: nominalWorkingSetLimit,
            runtimeConfiguration: runtimeConfiguration
        )
        let maxCtx = ModelRAMAdvisor.maxContextUnderAdvisoryWorkingSet(
            format: format,
            sizeBytes: sizeBytes,
            layerCount: layerCount,
            moeInfo: moeInfo,
            upperBound: supportedMaxContextLength,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration,
            processLimitBytes: nominalWorkingSetLimit,
            exactAnchorContextLength: exactAnchorContextLength,
            knownWorkingContextLength: knownWorkingContextLength
        )
        var workingSet = ModelRAMAdvisor.advisoryWorkingSetEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: ctx,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration,
            exactAnchorContextLength: exactAnchorContextLength
        )
        var combined: Int64? = nil
        var combinedStr = "--"
        if let draft = draftEstimateInput {
            let (draftEstimate, _) = ModelRAMAdvisor.estimateAndBudget(
                format: draft.format,
                sizeBytes: draft.sizeBytes,
                contextLength: ctx,
                layerCount: draft.layerCount,
                moeInfo: draft.moeInfo,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: draft.runtimeConfiguration
            )
            let total = estimate + draftEstimate
            combined = total
            combinedStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
            workingSet = ModelRAMAdvisor.saturatedAdding(
                workingSet,
                ModelRAMAdvisor.estimateBreakdown(
                    format: draft.format,
                    sizeBytes: draft.sizeBytes,
                    contextLength: ctx,
                    layerCount: draft.layerCount,
                    moeInfo: draft.moeInfo,
                    kvCacheEstimate: kvCacheEstimate,
                    runtimeConfiguration: draft.runtimeConfiguration
                ).estimate
            )
        }
        ram = RAMEstimate(
            estimate: estimate,
            budget: budget,
            workingSet: workingSet,
            nominalWorkingSetLimit: nominalWorkingSetLimit,
            advisoryWorkingSetLimit: advisoryWorkingSetLimit,
            maxCtx: maxCtx,
            workingSetStr: ByteCountFormatter.string(fromByteCount: workingSet, countStyle: .memory),
            workingSetLimitStr: advisoryWorkingSetLimit.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory)
            } ?? "--",
            combined: combined,
            combinedStr: combinedStr
        )
    }

    @ViewBuilder
    private func ramEstimateRows() -> some View {
        let locale = LocalizationManager.preferredLocale()
        // When a helper draft model is configured, the fit assessment must judge
        // the combined working set (target + draft), not the target alone.
        let maxCtx = ram.maxCtx
        let exactFitConfirmed = exactFitState == .fits
        let pressureBand = currentPressureBand
        let isChecking = exactCurveCalibrating || exactFitState == .calculating
        let displayedWorkingSet = exactCurveCalibrating ? "--" : ram.workingSetStr
        VStack(alignment: .leading, spacing: 5) {
            if let pressureLimit = ram.advisoryWorkingSetLimit, pressureLimit > 0 {
                IndustrialProgressBar(
                    value: min(1, Double(ram.workingSet) / Double(pressureLimit)),
                    tint: pressureColor(for: pressureBand)
                )
                .accessibilityLabel(Text(LocalizedStringKey(pressureTitle(for: pressureBand))))
                .padding(.bottom, 2)
            }
            Text(
                String.localizedStringWithFormat(
                    String(localized: "Estimated RAM allocation: %@ · Limit: %@", locale: locale),
                    displayedWorkingSet,
                    ram.workingSetLimitStr
                )
            )
            .industrialStat()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
            if ram.combined != nil {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "With draft model: %@ combined", locale: locale),
                        ram.combinedStr
                    )
                )
                .industrialStat()
            }
            if isChecking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                }
                .industrialStat()
            } else if exactFitConfirmed {
                Label(
                    LocalizedStringKey(pressureTitle(for: pressureBand)),
                    systemImage: pressureBand == .comfortable
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                    .foregroundStyle(pressureColor(for: pressureBand))
                    .industrialStat()
            } else if exactFitState == .doesNotFit {
                Label(
                    LocalizedStringKey(pressureTitle(for: .overRecommended)),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .foregroundStyle(pressureColor(for: .overRecommended))
                    .industrialStat()
            }
            if let maxCtx {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Max recommended context on this device: ~%@ tokens", locale: locale),
                        "\(maxCtx)"
                    )
                )
                .industrialStat()
            }
            if let maxCtx,
               (Int(displayValue) > maxCtx || exactFitState == .doesNotFit) {
                Button {
                    let safe = Double(max(512, maxCtx))
                    contextLength = safe
                    draft = safe
                    isEditing = false
                } label: {
                    Label(LocalizedStringKey("Use Safe Context"), systemImage: "dial.low")
                }
                .buttonStyle(.industrial(.tinted))
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(.top, 2)
    }

    private enum RAMPressureBand: Equatable {
        case comfortable
        case borderline
        case overRecommended
    }

    private var currentPressureBand: RAMPressureBand {
        guard let nominal = ram.nominalWorkingSetLimit, nominal > 0,
              let advisory = ram.advisoryWorkingSetLimit, advisory > 0 else {
            return .borderline
        }
        if ram.workingSet > advisory || exactFitState == .doesNotFit {
            return .overRecommended
        }
        if exactCurveCalibrating
            || exactFitState == .calculating
            || exactFitState == .unavailable {
            return .borderline
        }
        if ram.workingSet >= Int64(Double(nominal) * 0.85) {
            return .borderline
        }
        return .comfortable
    }

    private func pressureTitle(for band: RAMPressureBand) -> String {
        switch band {
        case .comfortable: return "Fits in RAM (estimated)"
        case .borderline: return "Borderline context"
        case .overRecommended: return "Likely over memory budget"
        }
    }

    private func pressureColor(for band: RAMPressureBand) -> Color {
        switch band {
        case .comfortable: return .green
        case .borderline: return .yellow
        case .overRecommended: return .orange
        }
    }
}

struct ModelSettingsView: View {
    let model: LocalModel
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @AppStorage("huggingFaceToken") private var huggingFaceToken = ""
    // Global llama.cpp chat-template behavior: keep prior-turn reasoning in context.
    // Default ON. Read by NoemaLlamaClient as chat_template_kwargs.preserve_thinking.
    @AppStorage("preserveThinking") private var preserveThinking = true
    @State private var settings = ModelSettings()
    @State private var layerCount: Int = 0
    @State private var scanning = false
    @State private var showKInfo = false
    @State private var showVInfo = false
    @State private var showVisionProjectorInfo = false
    @State private var showUnifiedKVCacheInfo = false
    @State private var showMLXKVCacheInfo = false
    @State private var showDeleteConfirm = false
    @State private var usingDefaultGPULayers = false
    @State private var isFavourite = false
    @State private var showFavouriteLimitAlert = false
    @State private var cachedBenchmarkFitsRAM: Bool = true
    @State private var benchmarking = false
    @State private var benchmarkResult: ModelBenchmarkResult?
    @State private var benchmarkError: String?
    @State private var benchmarkTask: Task<Void, Never>? = nil
    @State private var benchmarkTaskID: UUID? = nil
    @State private var showBenchmarkRAMSafetyWarning = false
    @State private var benchmarkProgress: Double = 0
    @State private var benchmarkProgressDetail: String = String(localized: "Benchmark running…")
    @State private var selectedRuntimePreset: ModelRuntimePreset = .balanced
    /// When a user-saved preset is the active selection, its id; nil when a
    /// built-in preset (or a hand-tuned "Custom" config) is active.
    @State private var selectedCustomPresetID: UUID? = nil
    @State private var showingSavePresetAlert = false
    @State private var newPresetName = ""
    /// Persisted list of user-saved runtime presets, encoded as JSON. Global
    /// (not per-model) so a saved preset can be applied to any model.
    @AppStorage("customRuntimePresets") private var customRuntimePresetsData = ""
    /// Snapshot of the runtime fingerprint taken when a preset is applied or the
    /// model's settings are first loaded. When the live fingerprint drifts from
    /// this, the user has hand-tuned a control and the section shows "Custom".
    @State private var appliedRuntimeFingerprint = ""
    @State private var showTemplateSourceDiff = false
    @State private var modelAlias = ""
    @State private var modelUpdateResult: ModelUpdateCheckResult?
    @State private var modelUpdateChecking = false
    @State private var modelUpdateError: String?
    /// The full settings tree performs several metadata-dependent calculations.
    /// Keep it unmounted until cold file work has completed away from the main actor.
    @State private var initialStateLoaded = false
    @State private var selectedSettingsSection: ModelSettingsSectionID = .essentials
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @Environment(\.macModalDismiss) private var macModalDismiss
#endif
    let loadAction: (ModelSettings) -> Void
    // File status (GGUF)
    @State private var weightsFilePath: String? = nil
    @State private var mmprojFilePath: String? = nil
    @State private var mmprojChecked: Bool = false
    @State private var filesStatusLoaded: Bool = false
    @State private var supportedMaxContextLength: Int? = nil
    /// Paged (Noema Overfit) sizing configuration for this install, refreshed
    /// when memory-affecting settings change; nil for resident installs. The
    /// RAM estimate must size the paged native contract (resident + bank +
    /// staging), not resident.gguf as an ordinary small GGUF.
    @State private var pagedSizingConfiguration: LlamaServerBridge.StartConfiguration? = nil
    @State private var isArgmaxANEMLLModel = false
    /// Disk-backed projector discovery must never run while SwiftUI is building the
    /// settings view. A cold GGUF header read can otherwise stall the row-tap
    /// presentation for about a second.
    @State private var discoveredVisionProjectorSupport = false
    /// Whether this model's runtime can act on the reasoning toggle. Gates the
    /// Reasoning control so it never appears as a dead switch. Resolved off-main on appear.
    @State private var supportsReasoning = false
    // Cached chat-template preview. Rendering the template (Jinja) and reading
    // the on-disk template sources is expensive, and none of it depends on the
    // context-length slider — so cache it and refresh only when the template or
    // system-prompt inputs actually change (not on every slider step).
    @State private var cachedTemplatePreview: (prompt: String, stops: [String]) = ("", [])
    @State private var cachedTemplateKindLabel: String = ""
    @State private var cachedTemplateSourceCandidates: [TemplateSourceCandidate] = []

    private var availableKCacheQuants: [CacheQuant] {
        CacheQuant.allCases.filter { $0 != .iq4_nl }
    }

    private var supportsMinP: Bool { model.format == .gguf }
    private var supportsPresencePenalty: Bool { model.format == .gguf }
    private var supportsFrequencyPenalty: Bool { model.format == .gguf }
    private var supportsSpeculativeDecoding: Bool { model.format == .gguf }

    private var supportsVisionProjectorLoading: Bool {
        resolvedModel.format == .gguf
            && (resolvedModel.isMultimodal || discoveredVisionProjectorSupport)
    }

    private var resolvedModel: LocalModel {
        modelManager.downloadedModels.first(where: { $0.id == model.id }) ?? model
    }

    private var resolvedMoEInfo: MoEInfo? {
        resolvedModel.moeInfo
    }

    private var allowsMoEExpertSelection: Bool {
        switch model.format {
        case .mlx:
            return false
        case .afm:
            return false
        default:
            return true
        }
    }

    private var effectiveMoEInfo: MoEInfo? {
        guard var info = resolvedMoEInfo else { return nil }
        guard info.isMoE else { return info }
        guard allowsMoEExpertSelection else { return info }
        // Preserve the true expert pool size for sizing calculations but
        // carry the user's active-expert choice through `defaultUsed` so
        // RAM estimates scale upward when more experts are selected.
        info.defaultUsed = resolvedActiveExperts(for: info)
        return info
    }

    private var contextLengthSliderUpperBound: Int {
        max(512, supportedMaxContextLength ?? 262_144)
    }

    private var contextLengthSliderRange: ClosedRange<Double> {
        512...Double(contextLengthSliderUpperBound)
    }

    private func fallbackActiveExperts(for info: MoEInfo) -> Int {
        let total = max(1, info.expertCount)
        if let recommended = info.defaultUsed, recommended > 0 {
            let sanitized = min(max(1, recommended), total)
            if sanitized < total { return sanitized }
        }
        guard total > 1 else { return 1 }
        let half = max(1, Int((Double(total) * 0.5).rounded(.toNearestOrAwayFromZero)))
        if half < total { return half }
        return max(1, total - 1)
    }

    private func resolvedActiveExperts(for info: MoEInfo) -> Int {
        let total = max(1, info.expertCount)
        let fallback = fallbackActiveExperts(for: info)
        let selected = settings.moeActiveExperts ?? fallback
        return min(max(1, selected), total)
    }

    private func refreshArgmaxCapability(for model: LocalModel) async {
        guard model.format == .ane else {
            isArgmaxANEMLLModel = false
            return
        }

        let modelURL = model.url
        let isArgmax = await Task.detached(priority: .utility) {
            ANEMLLCapabilityLookup.argmaxInModel(modelURL: modelURL)
        }.value

        guard !Task.isCancelled, model.id == resolvedModel.id else { return }
        isArgmaxANEMLLModel = isArgmax
    }

    private func refreshVisionProjectorSupport(for model: LocalModel) async {
        guard model.format == .gguf, !model.isMultimodal else {
            discoveredVisionProjectorSupport = false
            return
        }

        discoveredVisionProjectorSupport = false
        let url = model.url
        let supported = await Task.detached(priority: .utility) {
            ProjectorLocator.projectorPath(alongside: url) != nil
                || GGUFMetadata.hasMultimodalProjector(at: url)
        }.value
        guard !Task.isCancelled, model.id == resolvedModel.id else { return }
        discoveredVisionProjectorSupport = supported
    }

    private func refreshReasoningCapability(for model: LocalModel) async {
        let url = model.url
        let format = model.format
        let capable = await Task.detached(priority: .utility) {
            ReasoningCapabilityDetector.isReasoningCapableLocal(url: url, format: format)
        }.value
        guard !Task.isCancelled, model.id == resolvedModel.id else { return }
        supportsReasoning = capable
    }

    private func prepareInitialState(for model: LocalModel) async {
        initialStateLoaded = false
        let wasUsingDefaultGPULayers = modelManager.modelSettings[model.url.path] == nil
        let hasSavedSettings = modelManager.hasUserSavedSettings(for: model)
        let shouldPrepareDefaults = wasUsingDefaultGPULayers
            && !hasSavedSettings
            && model.format != .et
        let shouldResolveMTP = shouldPrepareDefaults
            || hasSavedSettings
            || isAdvancedMode
            || modelManager.modelSettings[model.url.path]?.speculativeDecoding.mtpEnabled == true

        let preparedDefaults = await Task.detached(priority: .userInitiated) {
            if model.format == .gguf {
                // These accessors are memoized and used by settings normalization
                // or the initial form. Populate only the needed entries here so the
                // first render is cache-only without delaying it on unrelated scans.
                _ = GGUFMetadata.contextLength(at: model.url)
                _ = GGUFMetadata.chatTemplate(at: model.url)
                _ = ProjectorLocator.projectorPath(alongside: model.url)
                if shouldResolveMTP {
                    _ = GGUFMetadata.hasMTP(at: model.url)
                }
            }

            guard shouldPrepareDefaults else { return nil as ModelSettings? }
            var prepared = ModelSettings.fromConfig(for: model)
            if model.format == .gguf {
                if prepared.gpuLayers == 0 {
                    prepared.gpuLayers = -1
                }
                if prepared.speculativeDecoding.selection == .off,
                   MtpLocator.hasMtpFileCached(alongside: model.url)
                    || GGUFMetadata.hasMTP(at: model.url) {
                    prepared.speculativeDecoding.selection = .mtp
                    prepared.speculativeDecoding.mtpAutoTune = true
                }
            }
            return prepared.normalizedForLocalModel(model)
        }.value

        guard !Task.isCancelled, model.id == resolvedModel.id else { return }
        if let preparedDefaults,
           modelManager.modelSettings[model.url.path] == nil,
           !modelManager.hasUserSavedSettings(for: model) {
            // This is the same in-memory caching performed by settings(for:), but
            // the disk-backed construction above happened off the main actor.
            modelManager.modelSettings[model.url.path] = preparedDefaults
        }

        usingDefaultGPULayers = wasUsingDefaultGPULayers
        modelAlias = resolvedModel.alias ?? ""
        settings = modelManager.settings(for: model)
        supportedMaxContextLength = ModelSettings.supportedMaxContextLength(for: model)
        if settings.kCacheQuant == .iq4_nl {
            settings.kCacheQuant = .f16
        }
        if let current = modelManager.downloadedModels.first(where: { $0.id == model.id }) {
            isFavourite = current.isFavourite
        } else {
            isFavourite = model.isFavourite
        }
        layerCount = model.totalLayers
        if layerCount == 0 {
            scanning = true
            Task.detached {
                let count = ModelScanner.layerCount(for: model.url, format: model.format)
                await MainActor.run {
                    guard model.id == resolvedModel.id else { return }
                    if count > 0 {
                        layerCount = count
                    }
                    scanning = false
                    updateGPULayers()
                }
            }
        } else {
            updateGPULayers()
        }
        updateMoESettingsIfNeeded(with: resolvedMoEInfo)
        refreshFileStatuses()
        recomputeBenchmarkFitsRAM()
        refreshTemplatePreview()
        appliedRuntimeFingerprint = runtimeConfigFingerprint
        initialStateLoaded = true
    }

    private func updateMoESettingsIfNeeded(with info: MoEInfo?) {
        guard let info else { return }
        if let total = info.totalLayerCount, total > 0 {
            if layerCount <= 0 || layerCount < total {
                layerCount = total
            }
        }
        if !info.isMoE {
            if settings.moeActiveExperts != nil {
                settings.moeActiveExperts = nil
            }
            return
        }
        if !allowsMoEExpertSelection {
            if settings.moeActiveExperts != nil {
                settings.moeActiveExperts = nil
            }
            return
        }
        let resolved = resolvedActiveExperts(for: info)
        if settings.moeActiveExperts != resolved {
            settings.moeActiveExperts = resolved
        }
    }

    var body: some View {
        NavigationStack {
            mainContent
        }
    }

    private var mainContent: some View {
        Group {
            if initialStateLoaded {
                settingsContainer
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
            // Only collect highlight anchors / mount the overlay while the walkthrough is
            // running. When idle this avoids per-frame preference propagation that
            // otherwise makes scrolling (e.g. with the context slider visible) janky.
            .modifier(WalkthroughHighlightOverlay(isActive: walkthrough.isActive, walkthrough: walkthrough))
#if canImport(UIKit) && !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
#endif
            .interactiveDismissDisabled(benchmarking)
            .navigationTitle(resolvedModel.displayName)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        close()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(benchmarking)
                }
            }
        #endif
            .onReceive(modelManager.$downloadedModels) { models in
                if let current = models.first(where: { $0.id == model.id }) {
                    isFavourite = current.isFavourite
                    updateMoESettingsIfNeeded(with: current.moeInfo)
                }
            }
            .task(id: resolvedModel.url.path) {
                await prepareInitialState(for: resolvedModel)
                guard !Task.isCancelled else { return }
                await refreshVisionProjectorSupport(for: resolvedModel)
                await refreshArgmaxCapability(for: resolvedModel)
                await refreshReasoningCapability(for: resolvedModel)
                await refreshModelUpdateStatus()
            }
            .task(id: pagedSizingFingerprint) {
                refreshPagedSizingConfiguration()
            }
            .onDisappear {
                benchmarkTask?.cancel()
                benchmarkTask = nil
                benchmarkTaskID = nil
                benchmarking = false
            }
            .onChange(of: layerCount) { _ in updateGPULayers(); recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.contextLength) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.kCacheQuant) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.vCacheQuant) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.flashAttention) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.unifiedKVCache) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.mlxKVCacheQuantization) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.mlxKVCacheLimit) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.moeActiveExperts) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.gpuLayers) { _ in usingDefaultGPULayers = false }
            .onChange(of: isAdvancedMode) { enabled in
                if !enabled, selectedSettingsSection == .advanced {
                    selectedSettingsSection = .details
                }
            }
            .onChange(of: settings.promptTemplate) { _ in
                refreshTemplatePreview()
                refreshTemplateSources()
            }
            .onChange(of: settings.systemPromptMode) { _ in refreshTemplatePreview() }
            .onChange(of: settings.systemPromptOverride) { _ in refreshTemplatePreview() }
            .onChange(of: showTemplateSourceDiff) { expanded in
                if expanded { refreshTemplateSources() }
            }
            .alert("K Cache Quantization", isPresented: $showKInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Quantize the runtime key cache to save memory. Experimental.")
            }
            .alert("Favorite Limit Reached", isPresented: $showFavouriteLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can only favorite up to three models.")
            }
            .alert("V Cache Quantization", isPresented: $showVInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Quantize the runtime value cache to save memory when Flash Attention is enabled. Experimental.")
            }
            .alert("MLX KV Cache", isPresented: $showMLXKVCacheInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Quantization reduces KV-cache memory with some compute and quality cost. A sliding limit bounds memory by overwriting older entries except the first four tokens.")
            }
            .alert(LocalizedStringKey("RAM Safety Checks"), isPresented: $showBenchmarkRAMSafetyWarning) {
                Button(LocalizedStringKey("Continue"), role: .destructive) {
                    runBenchmark(bypassRAMCheck: true)
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {}
            } message: {
                Text(LocalizedStringKey("Model likely exceeds memory budget. Lower context size or use a smaller quant/model."))
            }
            .alert(
                String.localizedStringWithFormat(String(localized: "Delete %@?"), resolvedModel.displayName),
                isPresented: $showDeleteConfirm
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        if modelManager.loadedModel?.id == model.id {
                            await vm.unload()
                        }
                        modelManager.delete(model)
                        close()
                    }
                }
                Button("Cancel", role: .cancel) { showDeleteConfirm = false }
            }
    }

private struct ModelProvenanceValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var isPath: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(isPath ? .caption2.monospaced() : .caption)
                .foregroundStyle(AppTheme.text)
                .textSelection(.enabled)
                .lineLimit(isPath ? 3 : 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MinimalSettingsGroup<Content: View>: View {
    let id: ModelSettingsSectionID
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.text)
                    Spacer(minLength: 8)
                }
                .padding(.bottom, 9)
                IndustrialHairline()
            }

            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(id)
    }
}

private struct ModelSettingsSectionNavigation: View {
    let modelName: String
    let modelDetail: String
    let sections: [ModelSettingsSectionSnapshot]
    let selected: ModelSettingsSectionID
    let select: (ModelSettingsSectionID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: modelName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(verbatim: modelDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)

            VStack(spacing: 3) {
                ForEach(sections) { section in
                    Button {
                        select(section.id)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: section.id.systemImage)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 16)
                                .foregroundStyle(selected == section.id ? Color.accentColor : Color.secondary)
                            Text(LocalizedStringKey(section.title))
                                .font(.system(size: 13, weight: selected == section.id ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected == section.id ? Color.primary.opacity(0.07) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 24)
        .frame(width: 202)
        .background(AppTheme.sidebarBackground)
    }
}

    @ViewBuilder
    private var settingsContainer: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                HStack(spacing: 0) {
                    if geometry.size.width >= 760 {
                        ModelSettingsSectionNavigation(
                            modelName: resolvedModel.displayName,
                            modelDetail: modelNavigationDetail,
                            sections: settingsSectionSnapshots,
                            selected: selectedSettingsSection
                        ) { section in
                            selectedSettingsSection = section
                            withAnimation(.easeInOut(duration: 0.24)) {
                                scrollProxy.scrollTo(section, anchor: .top)
                            }
                        }
                        Divider()
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 34) {
                            modelIdentityHeader
                            settingsSections
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, geometry.size.width < 520 ? 20 : 32)
                        .padding(.top, geometry.size.width < 520 ? 24 : 32)
                        .padding(.bottom, 36)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        settingsActionBar
                    }
                }
                .background(AppTheme.windowBackground)
            }
        }
    }

    private var settingsSectionSnapshots: [ModelSettingsSectionSnapshot] {
#if os(macOS)
        let platform: ModelSettingsSectionSnapshot.Platform = .macOS
#else
        let platform: ModelSettingsSectionSnapshot.Platform = .iOSForm
#endif
        return ModelSettingsSectionSnapshot.sections(
            for: model.format,
            isAdvancedMode: isAdvancedMode,
            platform: platform
        )
    }

    private var modelNavigationDetail: String {
        let quant = provenanceSnapshot.quantLabel
        return quant.isEmpty ? model.format.displayName : "\(model.format.displayName) · \(quant)"
    }

    @ViewBuilder
    private var settingsSections: some View {
        ForEach(settingsSectionSnapshots) { section in
            switch section.id {
            case .essentials:
                MinimalSettingsGroup(id: section.id, title: LocalizedStringKey(section.title)) {
                    contextLengthControl
                    if model.format != .afm {
                        runtimePresetContent
                    }
                }

            case .performance:
                MinimalSettingsGroup(id: section.id, title: LocalizedStringKey(section.title)) {
                    performanceSettingsContent
                }

            case .behavior:
                MinimalSettingsGroup(id: section.id, title: LocalizedStringKey(section.title)) {
                    behaviorSettingsContent
                }

            case .advanced:
                MinimalSettingsGroup(id: section.id, title: LocalizedStringKey(section.title)) {
                    advancedSettingsContent
                }

            case .details:
                MinimalSettingsGroup(id: section.id, title: LocalizedStringKey(section.title)) {
                    modelDetailsContent
                }
            }
        }
    }

    private var modelIdentityHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey("Local Model"))
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text(verbatim: resolvedModel.displayName)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(AppTheme.text)
                    .lineLimit(2)
                Text(verbatim: modelIdentityDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
            favoriteButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelIdentityDetail: String {
        let snapshot = provenanceSnapshot
        let size = ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file)
        var parts = [model.format.displayName]
        if !snapshot.quantLabel.isEmpty { parts.append(snapshot.quantLabel) }
        parts.append(size)
        if snapshot.isMultimodal { parts.append(String(localized: "Vision")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var performanceSettingsContent: some View {
        if AppleFoundationModelKind.resolve(modelID: model.modelID) == .privateCloudCompute {
            privateCloudSettingsContent
        } else if model.format == .gguf {
            ggufSettingsContent
        } else if model.format == .et {
            etSettingsContent
        } else if model.format == .ane {
            aneSettingsContent
        } else if model.format == .afm {
            Text(LocalizedStringKey("This format manages runtime optimizations automatically."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            mlxSettingsContent
        }
    }

    @ViewBuilder
    private var behaviorSettingsContent: some View {
        systemPromptSettingsContent
        if model.format == .gguf {
            ggufBehaviorSettingsContent
        }
        if supportsReasoning {
            reasoningSettingsContent
        }
    }

    private var samplingHeadline: String {
        String(format: "temp %.2f · top-p %.2f · top-k %d", settings.temperature, settings.topP, settings.topK)
    }

    @ViewBuilder
    private var advancedSettingsContent: some View {
        IndustrialDisclosureRow("Sampling", headline: samplingHeadline) {
            samplingSectionContent
        }
        if supportsSpeculativeDecoding {
            IndustrialDisclosureRow(
                "Speculative Decoding",
                headline: settings.speculativeDecoding.selection.title
            ) {
                speculativeDecodingContent
            }
        }
    }

    @ViewBuilder
    private var modelDetailsContent: some View {
        IndustrialDisclosureRow("Model Alias", headline: modelAliasSummary) {
            modelAliasContent
            favoriteToggle
        }
        chatTemplatePreviewSection
        benchmarkSection
        if model.format == .gguf {
            filesSection
        }
        provenanceSection
        IndustrialDisclosureRow("Maintenance") {
            resetActionsContent
        }
    }

    private var modelAliasSummary: String {
        modelAliasNormalized(resolvedModel.alias) ?? String(localized: "No alias")
    }

    private var settingsActionBar: some View {
        HStack(spacing: 9) {
#if os(macOS)
            Button {
                close()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(.industrial(.quiet))
            .disabled(benchmarking)
#endif

            Spacer(minLength: 12)

            Button(action: saveAndClose) {
                Text("Save")
            }
            .buttonStyle(.industrial(.quiet))
            .disabled(benchmarking || !initialStateLoaded)

            Button(action: loadAndClose) {
                if vm.loading { ProgressView() } else { Text("Load") }
            }
            .buttonStyle(.industrial(.prominent))
            .keyboardShortcut(.defaultAction)
            .disabled(vm.loading || benchmarking || !initialStateLoaded)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            IndustrialHairline()
        }
    }

    // The context control owns a local draft value so dragging the
    // slider re-renders only itself, not this whole (very large) view.
    private var contextLengthControl: some View {
        ContextLengthControl(
            contextLength: $settings.contextLength,
            range: contextLengthSliderRange,
            format: model.format,
            fixedContextLength: ModelSettings.fixedContextLength(for: model),
            showsRAMEstimate: AppleFoundationModelKind.resolve(modelID: model.modelID) != .privateCloudCompute,
            sizeBytes: Int64(model.sizeGB * 1_073_741_824.0),
            layerCount: layerCount > 0 ? layerCount : nil,
            moeInfo: effectiveMoEInfo,
            supportedMaxContextLength: supportedMaxContextLength,
            kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings),
            // Paged installs estimate against the paged runtime shape (single
            // slot, one-token micro-batch, capped context), matching what the
            // launch actually starts.
            runtimeConfiguration: pagedSizingConfiguration.map { .resolved(from: $0) }
                ?? .resolved(from: settings, modelURL: model.url),
            knownWorkingContextLength: knownWorkingContextLength,
            pagedServerConfiguration: pagedSizingConfiguration,
            attachWalkthroughHighlight: walkthrough.isActive
        )
    }

    /// Memory-affecting inputs of the paged sizing configuration. Kept narrow
    /// so sampling/template edits don't re-run the plan resolver, which decodes
    /// the (multi-MB) package manifest.
    private struct PagedSizingInputs: Equatable {
        var path: String
        var contextLength: Int
        var kCache: CacheQuant
        var vCache: CacheQuant
        var flashAttention: Bool
        var gpuLayers: Int
        var evaluationBatch: Int
        var kvOffload: Bool
        var unifiedKVCache: Bool
        var threads: Int
        var overfitMode: ModelSettings.OverfitMode
    }

    private var pagedSizingFingerprint: PagedSizingInputs {
        PagedSizingInputs(
            path: model.url.path,
            contextLength: Int(settings.contextLength),
            kCache: settings.kCacheQuant,
            vCache: settings.vCacheQuant,
            flashAttention: settings.flashAttention,
            gpuLayers: settings.gpuLayers,
            evaluationBatch: settings.resolvedEvaluationBatchSize,
            kvOffload: settings.kvCacheOffload,
            unifiedKVCache: settings.unifiedKVCache,
            threads: settings.cpuThreads,
            overfitMode: settings.overfitMode
        )
    }

    @MainActor
    private func refreshPagedSizingConfiguration() {
        guard model.format == .gguf, OverfitPagedInstallCache.isPaged(model.url) else {
            if pagedSizingConfiguration != nil { pagedSizingConfiguration = nil }
            return
        }
        // Context shift is server behavior, not a memory-sizing input.
        let (configuration, plan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: model.url,
            settings: settings,
            mmprojPath: nil,
            contextShiftEnabled: true,
            purpose: .chat
        )
        pagedSizingConfiguration = plan.isPaged ? configuration : nil
    }

    /// Use the active runtime as an empirical lower bound only while the settings that affect
    /// memory still match. Moving the context slider is allowed; changing batch/KV/projector
    /// settings invalidates the proof until the model is loaded again.
    private var knownWorkingContextLength: Int? {
        guard let loadedURL = vm.loadedModelURL,
              let loaded = vm.loadedModelSettings,
              settings.speculativeDecoding.selection != .helperDraftModel else { return nil }
        let currentRuntime = ModelRAMAdvisor.RuntimeConfiguration.resolved(from: settings, modelURL: model.url)
        let loadedRuntime = ModelRAMAdvisor.RuntimeConfiguration.resolved(from: loaded, modelURL: loadedURL)
        // Catalog entries may point at an installation directory while ChatVM retains the
        // resolved GGUF file. Compare the resolved runtime paths instead of LocalModel IDs,
        // which can differ even though both values identify the same loaded model.
        guard currentRuntime.modelPath == loadedRuntime.modelPath,
              currentRuntime == loadedRuntime,
              ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
                == ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: loaded) else { return nil }
        return max(512, Int(loaded.contextLength))
    }

    private var favoriteBinding: Binding<Bool> {
        Binding(
            get: { isFavourite },
            set: { newValue in
                if newValue {
                    if modelManager.setFavourite(model, isFavourite: true) {
                        isFavourite = true
                    } else {
                        isFavourite = false
                        showFavouriteLimitAlert = true
                    }
                } else {
                    _ = modelManager.setFavourite(model, isFavourite: false)
                    isFavourite = false
                }
            }
        )
    }

    private var favoriteToggle: some View {
        Toggle("Favorite Model", isOn: favoriteBinding)
    }

    private var favoriteButton: some View {
        Button {
            favoriteBinding.wrappedValue.toggle()
        } label: {
            Image(systemName: isFavourite ? "star.fill" : "star")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFavourite ? Color.orange : Color.secondary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(isFavourite ? Color.orange.opacity(0.10) : Color.primary.opacity(0.04))
                )
                .overlay(
                    Circle()
                        .stroke(isFavourite ? Color.orange.opacity(0.35) : AppTheme.cardStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey("Favorite Model"))
        .accessibilityValue(isFavourite ? Text("On") : Text("Off"))
    }

    @ViewBuilder
    private var modelAliasContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Model Alias", text: $modelAlias)
                .platformAutocapitalization(.words)
                .disableAutocorrection(true)
                .onSubmit { persistModelAliasIfNeeded() }

            HStack(spacing: 12) {
                Button("Apply Alias") {
                    persistModelAliasIfNeeded()
                }
                .buttonStyle(.industrial(.quiet))
                .disabled(!modelAliasHasChanges)

                if modelAliasNormalized(resolvedModel.alias) != nil || modelAliasNormalized(modelAlias) != nil {
                    Button("Clear Alias") {
                        modelAlias = ""
                        persistModelAliasIfNeeded()
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(FontTheme.caption)
        }
    }

    private var modelAliasHasChanges: Bool {
        modelAliasNormalized(modelAlias) != modelAliasNormalized(resolvedModel.alias)
    }

    private func persistModelAliasIfNeeded() {
        guard modelAliasHasChanges else { return }
        modelManager.updateAlias(modelAlias, for: model)
    }

    private func modelAliasNormalized(_ alias: String?) -> String? {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private var provenanceSnapshot: ModelProvenanceSnapshot {
        ModelProvenanceSnapshot(
            model: resolvedModel,
            installed: modelManager.installedModel(matching: resolvedModel)
        )
    }

    @ViewBuilder
    private var provenanceSection: some View {
        IndustrialDisclosureRow("Provenance", headline: provenanceHeadline) {
            provenanceSectionContent
        }
    }

    private var provenanceHeadline: String {
        let snapshot = provenanceSnapshot
        let size = ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file)
        return snapshot.quantLabel.isEmpty ? size : "\(snapshot.quantLabel) · \(size)"
    }

    @ViewBuilder
    private var provenanceSectionContent: some View {
        let snapshot = provenanceSnapshot
        VStack(alignment: .leading, spacing: 10) {
            ModelProvenanceValueRow(title: "Model ID", value: snapshot.modelID)
            ModelProvenanceValueRow(title: "Alias", value: snapshot.alias ?? String(localized: "No alias"))
            ModelProvenanceValueRow(title: "Format", value: snapshot.formatRawValue)
            ModelProvenanceValueRow(title: "Quantization", value: snapshot.quantLabel.isEmpty ? String(localized: "Unknown") : snapshot.quantLabel)
            if let parameterCountLabel = snapshot.parameterCountLabel {
                ModelProvenanceValueRow(title: "Parameters", value: parameterCountLabel)
            }
            ModelProvenanceValueRow(
                title: "Disk Use",
                value: ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file)
            )
            ModelProvenanceValueRow(title: "Installed", value: snapshot.installDate.formatted(date: .abbreviated, time: .shortened))
            ModelProvenanceValueRow(title: "Last Used", value: snapshot.lastUsedDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Never loaded"))
            ModelProvenanceValueRow(title: "Checksum", value: snapshot.checksum ?? String(localized: "No checksum"))
            modelUpdateStatusContent
            ModelProvenanceValueRow(title: "Local Path", value: snapshot.localPath, isPath: true)
            ModelProvenanceValueRow(title: "Install Root", value: snapshot.installRootPath, isPath: true)
            ModelProvenanceValueRow(title: "Capabilities", value: provenanceCapabilities(snapshot))
            ModelProvenanceValueRow(title: "Layers", value: snapshot.totalLayers > 0 ? "\(snapshot.totalLayers)" : String(localized: "Unknown"))
            if snapshot.isMoE == true {
                ModelProvenanceValueRow(title: "MoE", value: provenanceMoESummary(snapshot))
            }
        }
    }

    @ViewBuilder
    private var modelUpdateStatusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if modelUpdateChecking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(LocalizedStringKey("Checking for model updates..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let modelUpdateResult {
                ModelProvenanceValueRow(title: "Update Status", value: modelUpdateSummary(modelUpdateResult))
            } else if let modelUpdateError {
                ModelProvenanceValueRow(
                    title: "Update Status",
                    value: String.localizedStringWithFormat(String(localized: "Update check failed: %@"), modelUpdateError)
                )
            } else {
                ModelProvenanceValueRow(title: "Update Status", value: String(localized: "Unable to compare"))
            }

            if resolvedModel.format != .afm {
                Button {
                    Task { await refreshModelUpdateStatus(force: true) }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.industrial(.quiet))
                .font(.caption)
                .disabled(modelUpdateChecking)
            }
        }
    }

    private func refreshModelUpdateStatus(force: Bool = false) async {
        guard resolvedModel.format != .afm, !resolvedModel.modelID.isEmpty else {
            modelUpdateResult = ModelUpdateCheckResult(state: .unableToCompare, differences: [], remoteQuant: nil)
            modelUpdateError = nil
            return
        }
        if !force, modelUpdateResult != nil || modelUpdateChecking {
            return
        }
        guard let installed = modelManager.installedModel(matching: resolvedModel) else {
            modelUpdateResult = ModelUpdateCheckResult(state: .unableToCompare, differences: [], remoteQuant: nil)
            modelUpdateError = nil
            return
        }

        modelUpdateChecking = true
        modelUpdateError = nil
        defer { modelUpdateChecking = false }

        do {
            let token = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = try await HuggingFaceRegistry(token: token.isEmpty ? nil : token).details(for: installed.modelID)
            guard !Task.isCancelled else { return }
            modelUpdateResult = ModelUpdateChecker.compare(installed: ModelProvenanceSnapshot(installed: installed), against: details)
        } catch {
            guard !Task.isCancelled else { return }
            modelUpdateResult = nil
            modelUpdateError = error.localizedDescription
        }
    }

    private func modelUpdateSummary(_ result: ModelUpdateCheckResult) -> String {
        switch result.state {
        case .current:
            return String(localized: "Current")
        case .missingRemoteQuant:
            return String(localized: "Installed quant no longer listed")
        case .unableToCompare:
            return String(localized: "Unable to compare")
        case .updateAvailable:
            let details = result.differences.map(modelUpdateDifferenceLabel).joined(separator: " · ")
            if details.isEmpty {
                return String(localized: "Update available")
            }
            return "\(String(localized: "Update available")): \(details)"
        }
    }

    private func modelUpdateDifferenceLabel(_ difference: ModelUpdateCheckResult.Difference) -> String {
        switch difference {
        case .checksum:
            return String(localized: "Checksum changed")
        case .size:
            return String(localized: "Size changed")
        case .primaryFile:
            return String(localized: "Primary file changed")
        case .partCount:
            return String(localized: "File parts changed")
        }
    }

    private func provenanceCapabilities(_ snapshot: ModelProvenanceSnapshot) -> String {
        var capabilities: [String] = []
        if snapshot.isMultimodal {
            capabilities.append(String(localized: "Multimodal"))
        }
        if snapshot.isToolCapable {
            capabilities.append(String(localized: "Tool Capable"))
        }
        if snapshot.isFavourite {
            capabilities.append(String(localized: "Favorite"))
        }
        return capabilities.isEmpty ? String(localized: "None") : capabilities.joined(separator: " · ")
    }

    private func provenanceMoESummary(_ snapshot: ModelProvenanceSnapshot) -> String {
        var parts: [String] = []
        if let expertCount = snapshot.expertCount, expertCount > 0 {
            parts.append(String.localizedStringWithFormat(String(localized: "%d experts"), expertCount))
        }
        if let defaultExperts = snapshot.defaultExperts, defaultExperts > 0 {
            parts.append(String.localizedStringWithFormat(String(localized: "%d active"), defaultExperts))
        }
        if let moeLayerCount = snapshot.moeLayerCount, moeLayerCount > 0 {
            parts.append(String.localizedStringWithFormat(String(localized: "%d MoE layers"), moeLayerCount))
        }
        return parts.isEmpty ? String(localized: "Detected") : parts.joined(separator: " · ")
    }

    private var chatTemplatePreviewSection: some View {
        IndustrialDisclosureRow(
            "Chat Template Preview",
            headline: templateStopTokens.isEmpty
                ? cachedTemplateKindLabel
                : "\(cachedTemplateKindLabel) · \(templateStopTokens.count)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("Rendered Prompt"))
                            .font(FontTheme.subheadline)
                            .foregroundStyle(AppTheme.text)
                        Text(templatePreviewSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: cachedTemplateKindLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(verbatim: renderedTemplatePreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 132, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                )

                if !templateStopTokens.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("Stop Tokens"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(templateStopTokens, id: \.self) { token in
                                Text(verbatim: token)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.10), in: Capsule())
                            }
                        }
                    }
                } else {
                    Text(LocalizedStringKey("No explicit stop tokens detected for this template."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup(isExpanded: $showTemplateSourceDiff) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(cachedTemplateSourceCandidates) { candidate in
                            TemplateSourceDiffRow(candidate: candidate)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label(LocalizedStringKey("Template Source Diff"), systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private var systemPromptSettingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                HStack {
                    Text(LocalizedStringKey("System Prompt"))
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 7)
                IndustrialHairline()
            }

            Picker(LocalizedStringKey("System Prompt"), selection: $settings.systemPromptMode) {
                Text(LocalizedStringKey("Use Global Default")).tag(SystemPromptMode.inheritGlobal)
                Text(LocalizedStringKey("Use Model Prompt")).tag(SystemPromptMode.override)
                Text(LocalizedStringKey("Exclude Global Default")).tag(SystemPromptMode.excludeGlobal)
            }
            .labelsHidden()

            if settings.systemPromptMode == .override {
                TextEditor(text: systemPromptOverrideBinding)
                    .font(FontTheme.body)
                    .frame(minHeight: 140)
#if os(iOS)
                    .scrollContentBackground(.hidden)
#endif
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.cardFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 1)
                    )
            }

            Text(systemPromptModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemPromptOverrideBinding: Binding<String> {
        Binding(
            get: { settings.systemPromptOverride ?? "" },
            set: { settings.systemPromptOverride = $0 }
        )
    }

    private var systemPromptModeDescription: LocalizedStringKey {
        switch settings.systemPromptMode {
        case .inheritGlobal:
            return LocalizedStringKey("Uses the default system prompt from Settings for this model.")
        case .override:
            return LocalizedStringKey("Use a model-specific prompt instead of the shared Settings prompt.")
        case .excludeGlobal:
            return LocalizedStringKey("Skip the editable Settings prompt for this model while keeping Noema's built-in system guidance.")
        }
    }

    private var templateFamily: ModelKind {
        ModelKind.detect(id: "\(model.modelID) \(model.name) \(model.architectureFamily) \(model.architecture)")
    }

    private var templateKindLabel: String {
        String(describing: PromptBuilder.detect(template: settings.promptTemplate, family: templateFamily))
    }

    /// Recompute the Jinja-rendered preview + detected template kind. Cheap to
    /// store, but the render itself is expensive — only call when the template or
    /// system-prompt inputs change, never on context-length changes.
    private func refreshTemplatePreview() {
        cachedTemplatePreview = templatePreviewResult
        cachedTemplateKindLabel = templateKindLabel
    }

    /// Recompute the on-disk template-source candidates (reads several files).
    /// Depends on the active template + model, not the system prompt.
    private func refreshTemplateSources() {
        cachedTemplateSourceCandidates = templateSourceCandidates
    }

    private var templatePreviewSummary: LocalizedStringKey {
        if settings.promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return LocalizedStringKey("Using the model's configured chat template.")
        }
        return LocalizedStringKey("Using Noema's detected default template for this model family.")
    }

    private var templatePreviewResult: (prompt: String, stops: [String]) {
        let system: String = {
            switch settings.systemPromptMode {
            case .override:
                return settings.systemPromptOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (settings.systemPromptOverride ?? "")
                    : String(localized: "You are Noema, a private offline assistant.")
            case .excludeGlobal:
                return ""
            case .inheritGlobal:
                return String(localized: "You are Noema, a private offline assistant.")
            }
        }()
        let sampleMessages: [ChatVM.Msg] = [
            ChatVM.Msg(role: "system", text: system),
            ChatVM.Msg(role: "user", text: String(localized: "Summarize this note in two concise bullets.")),
            ChatVM.Msg(role: "assistant", text: String(localized: "- Key fact: Noema keeps private data local.\n- Next step: cite the active dataset when possible.")),
            ChatVM.Msg(role: "user", text: String(localized: "Now answer with citations if available."))
        ]
        let result = PromptBuilder.build(template: settings.promptTemplate, family: templateFamily, messages: sampleMessages)
        return (result.0, result.1)
    }

    private var renderedTemplatePreview: String {
        let prompt = cachedTemplatePreview.prompt
        guard !prompt.isEmpty else {
            return String(localized: "No preview could be generated for this template.")
        }
        let maxCharacters = 3_000
        guard prompt.count > maxCharacters else { return prompt }
        let prefix = prompt.prefix(maxCharacters)
        return String(prefix) + "\n\n" + String(localized: "Preview truncated.")
    }

    private var templateStopTokens: [String] {
        cachedTemplatePreview.stops
    }

    private var templateSourceCandidates: [TemplateSourceCandidate] {
        let activeTemplate = settings.promptTemplate
        let activeNormalized = normalizedTemplate(activeTemplate)
        var candidates: [TemplateSourceCandidate] = []
        let dir = templateSettingsDirectory

        func add(title: String, detail: String, template: String?) {
            let normalized = normalizedTemplate(template)
            let kind = String(describing: PromptBuilder.detect(template: template, family: templateFamily))
            let status: LocalizedStringKey
            if normalized == activeNormalized {
                status = "Active"
            } else if kind == templateKindLabel {
                status = "Same kind"
            } else {
                status = "Different kind"
            }
            candidates.append(
                TemplateSourceCandidate(
                    id: "\(title)-\(detail)-\(normalized.hashValue)",
                    title: title,
                    detail: detail,
                    kind: kind,
                    status: status,
                    statusColor: normalized == activeNormalized ? .green : (kind == templateKindLabel ? .orange : .secondary),
                    snippet: templateSnippet(template)
                )
            )
        }

        if let curated = ArchitectureTemplates.template(for: model) {
            add(title: String(localized: "Curated"), detail: "ArchitectureTemplates", template: curated)
        }

        let jinja = dir.appendingPathComponent("chat_template.jinja")
        if let template = try? String(contentsOf: jinja, encoding: .utf8),
           !template.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            add(title: "chat_template.jinja", detail: jinja.lastPathComponent, template: template)
        }

        let text = dir.appendingPathComponent("chat_template.txt")
        if let template = try? String(contentsOf: text, encoding: .utf8),
           !template.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            add(title: "chat_template.txt", detail: text.lastPathComponent, template: template)
        }

        let chatTemplateJSON = dir.appendingPathComponent("chat_template.json")
        if let template = chatTemplate(from: chatTemplateJSON) {
            add(title: "chat_template.json", detail: chatTemplateJSON.lastPathComponent, template: template)
        }

        let hubJSON = dir.appendingPathComponent("hub.json")
        if let template = hubChatTemplate(from: hubJSON) {
            add(title: "hub.json", detail: hubJSON.lastPathComponent, template: template)
        }

        let tokenizerConfig = dir.appendingPathComponent("tokenizer_config.json")
        if let template = chatTemplate(from: tokenizerConfig) {
            add(title: "tokenizer_config.json", detail: tokenizerConfig.lastPathComponent, template: template)
        }

        if let tokenizerURL = tokenizerJSONURL(in: dir),
           let template = chatTemplate(from: tokenizerURL) {
            add(title: "tokenizer.json", detail: tokenizerURL.lastPathComponent, template: template)
        }

        let config = dir.appendingPathComponent("config.json")
        if let template = chatTemplate(from: config) {
            add(title: "config.json", detail: config.lastPathComponent, template: template)
        }

        if model.format == .gguf,
           let template = GGUFMetadata.chatTemplate(at: model.url) {
            add(title: "GGUF metadata", detail: model.url.lastPathComponent, template: template)
        }

        add(title: String(localized: "Family Default"), detail: String(describing: templateFamily), template: nil)

        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(candidate.title)-\(candidate.snippet)"
            return seen.insert(key).inserted
        }
    }

    private var templateSettingsDirectory: URL {
        switch model.format {
        case .gguf, .et:
            return model.url.deletingLastPathComponent()
        case .mlx, .ane, .afm, .coreai:
            return InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
        }
    }

    private func chatTemplate(from url: URL) -> String? {
        guard let json = jsonDictionary(from: url),
              let template = json["chat_template"] as? String,
              !template.isEmpty else {
            return nil
        }
        return template
    }

    private func hubChatTemplate(from url: URL) -> String? {
        guard let json = jsonDictionary(from: url) else {
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

    private func tokenizerJSONURL(in dir: URL) -> URL? {
        let url = dir.appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func jsonDictionary(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func normalizedTemplate(_ template: String?) -> String {
        (template ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func templateSnippet(_ template: String?) -> String {
        let normalized = normalizedTemplate(template)
        guard !normalized.isEmpty else {
            return String(localized: "No explicit template; PromptBuilder will use the detected model family.")
        }
        let singleLine = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        let maxCharacters = 220
        guard singleLine.count > maxCharacters else { return singleLine }
        return String(singleLine.prefix(maxCharacters)) + "…"
    }

    @ViewBuilder
    private var runtimePresetContent: some View {
        if model.format != .afm {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey("Runtime Presets"))
                            .textCase(.uppercase)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
#if canImport(UIKit) && !os(visionOS)
                            Haptics.impact(.light)
#endif
                            newPresetName = ""
                            showingSavePresetAlert = true
                        } label: {
                            Label(LocalizedStringKey("Save Preset"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.industrial(.quiet))
                        .controlSize(.small)
                        .accessibilityLabel(LocalizedStringKey("Save current settings as a preset"))
                    }
                    .padding(.bottom, 7)
                    IndustrialHairline()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(primaryRuntimePresets) { preset in
                        let isActive = selectedCustomPresetID == nil && !runtimeConfigIsCustom && selectedRuntimePreset == preset
                        Button {
#if canImport(UIKit) && !os(visionOS)
                            Haptics.impact(.light)
#endif
                            selectedCustomPresetID = nil
                            selectedRuntimePreset = preset
                            applyRuntimePreset(preset)
                        } label: {
                            presetChip(title: Text(preset.titleKey), isActive: isActive)
                        }
                        .buttonStyle(.plain)
                        .help(preset.detailKey(for: model.format))
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }

                    if !additionalRuntimePresets.isEmpty {
                        let isAdditionalPresetActive = selectedCustomPresetID == nil
                            && !runtimeConfigIsCustom
                            && additionalRuntimePresets.contains(selectedRuntimePreset)
                        Menu {
                            ForEach(additionalRuntimePresets) { preset in
                                let isActive = selectedCustomPresetID == nil
                                    && !runtimeConfigIsCustom
                                    && selectedRuntimePreset == preset
                                Button {
                                    selectedCustomPresetID = nil
                                    selectedRuntimePreset = preset
                                    applyRuntimePreset(preset)
                                } label: {
                                    Label(preset.titleKey, systemImage: isActive ? "checkmark" : preset.systemImage)
                                }
                            }
                        } label: {
                            presetChip(title: Text("More"), isActive: isAdditionalPresetActive)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(customRuntimePresets) { preset in
                        let isActive = selectedCustomPresetID == preset.id && !runtimeConfigIsCustom
                        Button {
#if canImport(UIKit) && !os(visionOS)
                            Haptics.impact(.light)
#endif
                            applyCustomPreset(preset)
                        } label: {
                            presetChip(title: Text(verbatim: preset.name), isActive: isActive)
                        }
                        .buttonStyle(.plain)
                        .help(LocalizedStringKey("Your saved preset. Long-press it above to delete."))
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteCustomPreset(preset)
                            } label: {
                                Label(LocalizedStringKey("Delete Preset"), systemImage: "trash")
                            }
                        }
                    }
                }

                runtimePresetSummary
            }
            .alert(LocalizedStringKey("Save Preset"), isPresented: $showingSavePresetAlert) {
                TextField(LocalizedStringKey("Preset name"), text: $newPresetName)
                Button(LocalizedStringKey("Save")) {
                    saveCurrentSettingsAsPreset(named: newPresetName)
                    newPresetName = ""
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    newPresetName = ""
                }
            } message: {
                Text(LocalizedStringKey("Name this preset to reuse these runtime settings on any model later."))
            }
        }
    }

    /// Shared chip chrome for both built-in and user-saved preset buttons.
    @ViewBuilder
    private func presetChip(title: Text, isActive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        title
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.3)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, presetChipVerticalPadding)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.65))
            .background(shape.fill(isActive ? Color.accentColor.opacity(0.16) : .clear))
            .overlay(shape.stroke(isActive ? Color.clear : Color.primary.opacity(0.15), lineWidth: 1))
            .contentShape(shape)
    }

#if os(macOS)
    private var presetChipVerticalPadding: CGFloat { 5 }
#else
    private var presetChipVerticalPadding: CGFloat { 9 }
#endif

    /// One mono line of the resolved runtime config — doubles as the "did I
    /// hand-tune this?" indicator next to the active preset badge.
    private var runtimeConfigStatLine: String {
        var parts: [String] = ["CTX \(Int(settings.contextLength))"]
        if model.format == .gguf {
            parts.append("KV \(settings.kCacheQuant.rawValue.uppercased())")
            if settings.flashAttention { parts.append("FLASH") }
            parts.append("THREADS \(settings.cpuThreads)")
        } else if model.format == .mlx {
            parts.append("KV \(settings.mlxKVCacheQuantization.shortLabel)")
            parts.append("PREFILL \(settings.mlxPrefillStepSize)")
            if settings.mlxPromptCacheEnabled { parts.append("REUSE") }
        }
        return parts.joined(separator: " · ")
    }

    /// True once the live runtime fingerprint drifts from the snapshot taken when
    /// a preset was applied — i.e. the user hand-tuned an individual control.
    private var runtimeConfigIsCustom: Bool {
        !appliedRuntimeFingerprint.isEmpty && runtimeConfigFingerprint != appliedRuntimeFingerprint
    }

    /// Hashable signature of the runtime-relevant settings the presets control.
    private var runtimeConfigFingerprint: String {
        if model.format == .mlx {
            return "\(Int(settings.contextLength))|\(settings.mlxPromptCacheEnabled)|\(settings.mlxKVCacheQuantization.rawValue)|\(settings.mlxKVCacheGroupSize)|\(settings.mlxKVCacheQuantizationStart)|\(settings.mlxKVCacheLimit)|\(settings.mlxPrefillStepSize)"
        }
        return "\(Int(settings.contextLength))|\(settings.kCacheQuant.rawValue)|\(settings.vCacheQuant.rawValue)|\(settings.flashAttention)|\(settings.keepInMemory)|\(settings.kvCacheOffload)|\(settings.unifiedKVCache)|\(settings.cpuThreads)|\(settings.promptCacheEnabled)"
    }

    /// The user-saved preset currently selected, if any.
    private var activeCustomPreset: CustomRuntimePreset? {
        guard let id = selectedCustomPresetID else { return nil }
        return customRuntimePresets.first { $0.id == id }
    }

    /// Mono stat line of the resolved config plus the active-preset badge —
    /// flips to a "Custom" badge once the user hand-tunes a control. The full
    /// preset descriptions live in each chip's tooltip.
    @ViewBuilder
    private var runtimePresetSummary: some View {
        HStack(spacing: 8) {
            Text(verbatim: runtimeConfigStatLine)
                .industrialStat()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if runtimeConfigIsCustom {
                IndustrialBadge("Custom", tint: .orange)
                    .help(LocalizedStringKey("Manual settings that don't match a preset. Tap a preset above to start from a known baseline."))
            } else if let custom = activeCustomPreset {
                IndustrialBadge(verbatim: custom.name, tint: .accentColor)
            } else {
                IndustrialBadge(selectedRuntimePreset.titleKey, tint: .accentColor)
                    .help(selectedRuntimePreset.detailKey(for: model.format))
            }
        }
        .padding(.top, 2)
        .animation(.easeInOut(duration: 0.2), value: runtimeConfigIsCustom)
    }

    private var runtimePresets: [ModelRuntimePreset] {
        if model.format == .mlx {
            return [.batterySaver, .balanced, .maxSpeed, .maxContext]
        }
        return ModelRuntimePreset.allCases.filter { preset in
            switch preset {
            case .visionHeavy:
                return model.isMultimodal || model.format == .gguf
            case .maxSpeed, .maxContext, .maxContextAggressive:
                return model.format != .ane
            default:
                return true
            }
        }
    }

    private var primaryRuntimePresets: [ModelRuntimePreset] {
        let primary: [ModelRuntimePreset] = [.batterySaver, .balanced, .maxSpeed, .maxContext]
        return runtimePresets.filter(primary.contains)
    }

    private var additionalRuntimePresets: [ModelRuntimePreset] {
        runtimePresets.filter { !primaryRuntimePresets.contains($0) }
    }

    @ViewBuilder
    private var resetActionsContent: some View {
        Button("Reset to Default Settings") {
#if canImport(UIKit) && !os(visionOS)
            Haptics.impact(.light)
#endif
            settings = ModelSettings.default(for: model.format)
            settings = settings.normalizedForLocalModel(model)
            if model.format == .gguf { settings.gpuLayers = -1 }
            updateMoESettingsIfNeeded(with: resolvedMoEInfo)
        }
        .buttonStyle(.industrial(.quiet))
        .disabled(vm.loading)

        if model.format == .afm {
            Button("Hide Model", role: .destructive) {
#if canImport(UIKit) && !os(visionOS)
                Haptics.impact(.medium)
#endif
                modelManager.updateSettings(settings, for: model)
                modelManager.hide(model)
                tabRouter.showAFMHiddenNotice()
                close()
            }
            .buttonStyle(.industrial(.destructive))
        } else {
            Button("Delete Model", role: .destructive) {
#if canImport(UIKit) && !os(visionOS)
                Haptics.impact(.medium)
#endif
                showDeleteConfirm = true
            }
            .buttonStyle(.industrial(.destructive))
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        IndustrialDisclosureRow("Files") {
            filesSectionContent
        }
    }

    @ViewBuilder
    private var filesSectionContent: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: (weightsFilePath != nil) ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle((weightsFilePath != nil) ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Weights")
                Text(weightsFilePath ?? String(localized: "Not found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        HStack(alignment: .top, spacing: 8) {
            let projectorIcon: String = {
                if mmprojFilePath != nil { return "checkmark.circle.fill" }
                return mmprojChecked ? "xmark.circle" : "questionmark.circle"
            }()
            let projectorColor: Color = {
                if mmprojFilePath != nil { return .green }
                return mmprojChecked ? .orange : .secondary
            }()
            Image(systemName: projectorIcon)
                .foregroundStyle(projectorColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Projector (mmproj)")
                Text(
                    mmprojFilePath ?? (mmprojChecked
                                       ? String(localized: "Not provided by repository")
                                       : String(localized: "Unknown (not checked yet)"))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        if model.isMultimodal {
            VStack(alignment: .leading, spacing: 4) {
                if let mmprojFilePath {
                    Label {
                        Text("Projector downloaded automatically from Hugging Face. Keep this file alongside the weights so vision remains available.")
                    } icon: {
                        Image(systemName: "wand.and.rays")
                            .foregroundStyle(Color.visionAccent)
                    }
                } else if mmprojChecked {
                    Label {
                        Text("Noema could not find a projector in the repository. If the model advertises vision, ensure the mmproj file is present in the same folder as the weights.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label {
                        Text("Vision models require a companion projector (.mmproj). Noema will fetch it automatically the next time you download this model.")
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    // The reasoning preference lives in ModelSettings, so it follows the same
    // draft-then-Save/Load flow as every other control here — edits only persist when
    // the user taps Save or Load. The context bar edits the same value but writes through
    // immediately. Only shown when `supportsReasoning`.
    @ViewBuilder
    private var reasoningSettingsContent: some View {
        Toggle("Reasoning", isOn: $settings.reasoningEnabled)
            .help("Let the model think through the problem before answering. Turn it off for faster, more direct replies.")
        Text("Let the model think through the problem before answering. Turn it off for faster, more direct replies.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var ggufBehaviorSettingsContent: some View {
        if supportsVisionProjectorLoading {
            HStack(spacing: 8) {
                Toggle("Load Vision Projector", isOn: $settings.loadVisionProjector)
                Button {
                    showVisionProjectorInfo = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Vision Projector Loading")
            }
            .alert("Vision Projector Loading", isPresented: $showVisionProjectorInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Loads the companion mmproj so this model can accept images. Turn it off to reduce memory use. Image attachments stay unavailable until the model is loaded again with this setting enabled.")
            }
        }
        Toggle("Preserve Thinking", isOn: $preserveThinking)
            .help("Keeps the model's earlier reasoning in context on later turns so it can build on its own prior thinking. Improves multi-step and follow-up answers, at the cost of a little more context per turn.")
    }

    @ViewBuilder
    private var ggufSettingsContent: some View {
        #if os(macOS)
        Toggle("Keep Model In Memory", isOn: $settings.keepInMemory)
        #endif
        Toggle("Prompt Cache", isOn: $settings.promptCacheEnabled)
        if scanning {
            VStack(alignment: .leading) { ProgressView() }
        } else if DeviceGPUInfo.supportsGPUOffload {
            let offloadValue = settings.gpuLayers < 0 ? String(localized: "All") : "\(settings.gpuLayers)"
            IndustrialSliderRow(
                label: "GPU Offload Layers",
                value: Binding(get: {
                    Double(settings.gpuLayers < 0 ? (layerCount + 1) : settings.gpuLayers)
                }, set: { newVal in
                    let v = Int(newVal)
                    if v >= layerCount + 1 {
                        settings.gpuLayers = -1
                    } else {
                        settings.gpuLayers = max(0, min(layerCount, v))
                    }
                }),
                range: 0...Double(layerCount + 1),
                step: 1,
                display: "\(offloadValue)/\(layerCount)"
            )
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(LocalizedStringKey("This device doesn't support GPU offload."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsWarningBackground()
        }
        if let moeInfo = resolvedMoEInfo {
            moeSettings(for: moeInfo)
        }
        if isAdvancedMode {
            IndustrialDisclosureRow("Advanced", headline: advancedRuntimeHeadline) {
                Stepper(
                    String.localizedStringWithFormat(String(localized: "CPU Threads: %@"), "\(settings.cpuThreads)"),
                    value: $settings.cpuThreads,
                    in: 1...ModelSettings.maxInferenceThreadCount
                )
                Stepper(
                    value: Binding(
                        get: { settings.evaluationBatchSize },
                        set: { newValue in
                            settings.evaluationBatchSize = newValue
                            settings.physicalBatchSize = min(settings.physicalBatchSize, newValue)
                        }
                    ),
                    in: ModelSettings.minimumBatchSize...ModelSettings.maximumBatchSize,
                    step: 32
                ) {
                    HStack {
                        Text("Evaluation Batch Size")
                        Spacer()
                        Text(verbatim: "\(settings.evaluationBatchSize)")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(
                    value: $settings.physicalBatchSize,
                    in: ModelSettings.minimumBatchSize...max(ModelSettings.minimumBatchSize, settings.evaluationBatchSize),
                    step: 32
                ) {
                    HStack {
                        Text("Physical Batch Size")
                        Spacer()
                        Text(verbatim: "\(settings.physicalBatchSize)")
                            .foregroundStyle(.secondary)
                    }
                }
                if DeviceGPUInfo.supportsGPUOffload {
                    Toggle("Offload KV Cache to GPU", isOn: $settings.kvCacheOffload)
                }
                HStack(spacing: 8) {
                    Toggle("Unified KV Cache", isOn: $settings.unifiedKVCache)
                    Button {
                        showUnifiedKVCacheInfo = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Unified KV Cache")
                }
                .alert("Unified KV Cache", isPresented: $showUnifiedKVCacheInfo) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Shares one KV buffer across server slots. Active requests can use otherwise-idle context capacity, and freed slot space becomes reusable, which can improve memory use and throughput with parallel clients. The tradeoff is less predictable per-slot capacity: long requests compete for the same context pool and can cause more cache eviction. With Noema's usual single chat slot, the difference is typically small.")
                }
                Toggle("Use mmap()", isOn: $settings.useMmap)
                Toggle("Skip llama.cpp Warmup", isOn: $settings.disableWarmup)
                    .help("Skips llama.cpp's empty-run warmup. Model load finishes sooner, but the first request may take longer.")
                HStack {
                    Text("Seed")
                    TextField("Random", text: Binding(
                        get: { settings.seed.map(String.init) ?? "" },
                        set: { newVal in
                            let digits = newVal.filter { $0.isNumber }
                            if let val = Int(digits) { settings.seed = val } else { settings.seed = nil }
                        }
                    ))
                    .platformKeyboardType(.numberPad)
                }

                #if os(iOS)
                HStack(spacing: 8) {
                    HStack {
                        Text("K Cache Quant")
                        Button {
                            showKInfo = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("K Cache Quantization")
                    }
                    Spacer(minLength: 8)
                    Picker("K Cache Quant", selection: $settings.kCacheQuant) {
                        ForEach(availableKCacheQuants) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .help("Quantize the runtime key cache to save memory. Experimental.")
                #else
                Picker(selection: $settings.kCacheQuant) {
                    ForEach(availableKCacheQuants) { q in
                        Text(q.rawValue).tag(q)
                    }
                } label: {
                    HStack {
                        Text("K Cache Quant")
                        Button {
                            showKInfo = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .pickerStyle(.menu)
                .help("Quantize the runtime key cache to save memory. Experimental.")
                #endif

                Toggle("Flash Attention", isOn: $settings.flashAttention)

                if settings.flashAttention {
                    #if os(iOS)
                    HStack(spacing: 8) {
                        HStack {
                            Text("V Cache Quant")
                            Button {
                                showVInfo = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("V Cache Quantization")
                        }
                        Spacer(minLength: 8)
                        Picker("V Cache Quant", selection: $settings.vCacheQuant) {
                            ForEach(CacheQuant.allCases) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .help("Quantize the runtime value cache to save memory when Flash Attention is enabled. Experimental.")
                    #else
                    Picker(selection: $settings.vCacheQuant) {
                        ForEach(CacheQuant.allCases) { q in
                            Text(q.rawValue).tag(q)
                        }
                    } label: {
                        HStack {
                            Text("V Cache Quant")
                            Button {
                                showVInfo = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Quantize the runtime value cache to save memory when Flash Attention is enabled. Experimental.")
                    #endif
                }
            }
        }
    }

    private var advancedRuntimeHeadline: String {
        var parts = ["\(settings.cpuThreads) threads", "kv \(settings.kCacheQuant.rawValue)"]
        if settings.flashAttention { parts.append("flash") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func moeSettings(for info: MoEInfo) -> some View {
        if info.isMoE {
            let totalExperts = max(1, info.expertCount)
            let recommendedValue = info.defaultUsed.map { max(1, min(totalExperts, $0)) }
            let fallbackRecommendation = fallbackActiveExperts(for: info)
            let fallbackLabel = fallbackRecommendation == 1
            ? String(localized: "1 expert")
            : String.localizedStringWithFormat(String(localized: "%@ experts"), "\(fallbackRecommendation)")
            let currentValue: Int = {
                if allowsMoEExpertSelection {
                    return resolvedActiveExperts(for: info)
                }
                if let recommendedValue { return recommendedValue }
                return fallbackRecommendation
            }()
            VStack(alignment: .leading, spacing: 8) {
                if let moeLayers = info.moeLayerCount, let totalLayers = info.totalLayerCount {
                    Text("MoE layers: \(moeLayers) / \(totalLayers)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if totalExperts > 1, allowsMoEExpertSelection {
                    IndustrialSliderRow(
                        label: "Experts Per Token",
                        value: Binding<Double>(
                            get: { Double(resolvedActiveExperts(for: info)) },
                            set: { newValue in
                                let resolved = min(max(1, Int(newValue.rounded())), totalExperts)
                                settings.moeActiveExperts = resolved
                            }
                        ),
                        range: 1...Double(totalExperts),
                        display: "\(currentValue)/\(totalExperts)"
                    )
                } else {
                    Text("Active experts per token: \(currentValue) of \(totalExperts)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if totalExperts > 1 {
                    if allowsMoEExpertSelection {
                        Text("Selecting more experts keeps additional expert weights resident in RAM and increases memory usage.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("MLX currently manages expert routing automatically; manual selection is not supported.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Only one expert is available for this model; the active expert count is fixed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let recommendedValue {
                    let recommendedLabel = recommendedValue == 1
                    ? String(localized: "1 expert")
                    : String.localizedStringWithFormat(String(localized: "%@ experts"), "\(recommendedValue)")
                    Text("Vendor recommendation: \(recommendedLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if allowsMoEExpertSelection, currentValue > recommendedValue {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Text("Using more than \(recommendedLabel) significantly increases RAM usage.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Default selection (~\(fallbackLabel)) balances RAM usage against model quality.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        if model.format == .gguf, OverfitPagedInstallCache.isPaged(model.url) {
            OverfitSettingsBlock(model: resolvedModel, settings: $settings, isAdvancedMode: isAdvancedMode)
        }
    }

    @ViewBuilder
    private var samplingSectionContent: some View {
        if isArgmaxANEMLLModel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(LocalizedStringKey("Sampling unavailable for Argmax models"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if model.format == .et {
            VStack(alignment: .leading, spacing: 12) {
                IndustrialSliderRow(
                    label: "Temperature",
                    value: $settings.temperature,
                    range: 0...2,
                    step: 0.05,
                    display: String(format: "%.2f", settings.temperature)
                )
                Text(LocalizedStringKey("Top-k, top-p, and repetition penalties are not available for ET runtime in this build."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24)], alignment: .leading, spacing: 6) {
                IndustrialSliderRow(
                    label: "Temperature",
                    value: $settings.temperature,
                    range: 0...2,
                    step: 0.05,
                    display: String(format: "%.2f", settings.temperature)
                )
                .help(LocalizedStringKey("Low = focused. High = varied."))

                IndustrialSliderRow(
                    label: "Top-p",
                    value: $settings.topP,
                    range: 0...1,
                    step: 0.01,
                    display: String(format: "%.2f", settings.topP)
                )

                IndustrialStepperRow(
                    label: "Top-k",
                    display: NumberFormatter.localizedString(from: NSNumber(value: settings.topK), number: .decimal),
                    value: $settings.topK,
                    range: 1...2048
                )

#if os(macOS)
                if supportsMinP {
                    IndustrialSliderRow(
                        label: "Min-p",
                        value: $settings.minP,
                        range: 0...1,
                        step: 0.01,
                        display: String(format: "%.2f", settings.minP)
                    )
                }
#endif
            }

#if os(macOS)
            IndustrialDisclosureRow("Advanced", headline: repetitionControlsHeadline) {
                Stepper(
                    value: Binding(
                        get: { Double(settings.repetitionPenalty) },
                        set: { settings.repetitionPenalty = Float($0) }
                    ),
                    in: 0.8...2.0,
                    step: 0.05
                ) {
                    let formatted = String(format: "%.2f", Double(settings.repetitionPenalty))
                    Text(String.localizedStringWithFormat(String(localized: "Repetition penalty: %@"), formatted))
                }
                Stepper(value: $settings.repeatLastN, in: 0...4096, step: 16) {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Repeat last N tokens: %@"),
                            NumberFormatter.localizedString(from: NSNumber(value: settings.repeatLastN), number: .decimal)
                        )
                    )
                }
                if supportsPresencePenalty {
                    Stepper(
                        value: Binding(
                            get: { Double(settings.presencePenalty) },
                            set: { settings.presencePenalty = Float($0) }
                        ),
                        in: -2.0...2.0,
                        step: 0.1
                    ) {
                        let formatted = String(format: "%.1f", Double(settings.presencePenalty))
                        Text(String.localizedStringWithFormat(String(localized: "Presence penalty: %@"), formatted))
                    }
                }
                if supportsFrequencyPenalty {
                    Stepper(
                        value: Binding(
                            get: { Double(settings.frequencyPenalty) },
                            set: { settings.frequencyPenalty = Float($0) }
                        ),
                        in: -2.0...2.0,
                        step: 0.1
                    ) {
                        let formatted = String(format: "%.1f", Double(settings.frequencyPenalty))
                        Text(String.localizedStringWithFormat(String(localized: "Frequency penalty: %@"), formatted))
                    }
                }
                Text(LocalizedStringKey("Smooth loops and repeated phrases by tuning repetition controls."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
#endif
        }
    }

#if os(macOS)
    private var repetitionControlsHeadline: String {
        String(format: "penalty %.2f · last %d", Double(settings.repetitionPenalty), settings.repeatLastN)
    }
#endif

    @ViewBuilder
    private var speculativeDecodingContent: some View {
        Text("Speed up generation with a helper model or Multi-Token Prediction.")
            .font(.caption)
            .foregroundStyle(.secondary)

        let options = speculativeDraftCandidates

        Picker("Speculative Mode", selection: speculativeSelectionBinding) {
            ForEach(ModelSettings.SpeculativeDecodingSettings.Selection.allCases) { selection in
                Text(selection.title).tag(selection)
                    .disabled(selection == .mtp && !modelHasMTPSupport)
            }
        }
        .pickerStyle(.segmented)
        .onAppear { enforceSpeculativeSelectionAvailability() }
        .onChange(of: modelHasMTPSupport) { _ in enforceSpeculativeSelectionAvailability() }

        if !modelHasMTPSupport {
            mtpUnavailableNotice
        } else if settings.speculativeDecoding.selection == .off {
            mtpAvailableNotice
        }

        if settings.speculativeDecoding.selection == .mtp {
            Toggle(isOn: $settings.speculativeDecoding.mtpAutoTune) {
                Text("Auto-tune draft length")
            }
            if settings.speculativeDecoding.mtpAutoTune {
                Text(String.localizedStringWithFormat(
                    String(localized: "Noema drafts up to %@ tokens on this device and adapts the length while generating. Speculation pauses automatically when drafts stop being accepted."),
                    "\(SpeculativeAutoTune.deviceDraftCap)"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Stepper(value: $settings.speculativeDecoding.mtpDraftNMax, in: 1...6, step: 1) {
                    Text(String.localizedStringWithFormat(String(localized: "MTP draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMax)"))
                }
                Stepper(value: $settings.speculativeDecoding.mtpDraftNMin, in: 0...6, step: 1) {
                    Text(String.localizedStringWithFormat(String(localized: "MTP min draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMin)"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(String.localizedStringWithFormat(String(localized: "MTP draft probability floor: %@"), String(format: "%.2f", settings.speculativeDecoding.resolvedMTPDraftPMin)))
                    IndustrialSliderRow(value: $settings.speculativeDecoding.mtpDraftPMin, range: 0.0...1.0, step: 0.05)
                    Text("MTP confidence is measured before top-k filtering. Set the probability floor to 0 to disable it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if settings.speculativeDecoding.selection == .helperDraftModel {
        Picker("Helper Model", selection: Binding(
            get: { settings.speculativeDecoding.helperModelID },
            set: { settings.speculativeDecoding.helperModelID = $0 }
        )) {
            Text("None").tag(String?.none)
            ForEach(options, id: \.id) { candidate in
                Text(candidate.name).tag(String?.some(candidate.id))
            }
        }

        if settings.speculativeDecoding.helperModelID == nil {
            if options.isEmpty {
                Text("Install another model from the same model family with equal or smaller size to enable speculative decoding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Draft strategy", selection: $settings.speculativeDecoding.mode) {
                ForEach(ModelSettings.SpeculativeDecodingSettings.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $settings.speculativeDecoding.value, in: 1...2048, step: 1) {
                switch settings.speculativeDecoding.mode {
                case .tokens:
                    Text("Draft tokens: \(settings.speculativeDecoding.value)")
                case .max:
                    Text(String.localizedStringWithFormat(
                        String(localized: "Adaptive draft limit: %@"),
                        "\(settings.speculativeDecoding.value)"
                    ))
                }
            }

            switch settings.speculativeDecoding.mode {
            case .tokens:
                Text("Draft tokens — the helper model proposes this many tokens in one batch. The target model then verifies them in a single pass and keeps the leading run it agrees with before the helper drafts the next batch. Higher values speculate further ahead but waste more work when a guess is rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .max:
                EmptyView()
            }
        }
        }
    }

    private var speculativeSelectionBinding: Binding<ModelSettings.SpeculativeDecodingSettings.Selection> {
        Binding(
            get: {
                if settings.speculativeDecoding.selection == .mtp, !modelHasMTPSupport {
                    return .off
                }
                return settings.speculativeDecoding.selection
            },
            set: { selection in
                settings.speculativeDecoding.selection = (selection == .mtp && !modelHasMTPSupport) ? .off : selection
            }
        )
    }

    @ViewBuilder
    private var mtpAvailableNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("This model supports Multi-Token Prediction. Turn it on for faster generation with identical output.")
            } icon: {
                Image(systemName: "bolt.fill")
            }
            .font(.caption)
            .foregroundStyle(.green)
            Button {
                settings.speculativeDecoding.selection = .mtp
                settings.speculativeDecoding.mtpAutoTune = true
            } label: {
                Text("Enable MTP")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var mtpUnavailableNotice: some View {
        Label {
            Text("MTP is unavailable for this model. Choose another GGUF with an MTP head or bundled MTP weights. Helper-model speculative decoding is still available.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func enforceSpeculativeSelectionAvailability() {
        if settings.speculativeDecoding.selection == .mtp, !modelHasMTPSupport {
            settings.speculativeDecoding.selection = .off
        }
    }

    private var modelHasMTPSupport: Bool {
        MtpLocator.hasMtpFileCached(alongside: resolvedModel.url) || GGUFMetadata.hasMTP(at: resolvedModel.url)
    }

    private var speculativeDraftCandidates: [LocalModel] {
        let base = resolvedModel
        return modelManager.downloadedModels.filter { candidate in
            guard candidate.id != base.id else { return false }
            guard candidate.format == .gguf else { return false }
            guard candidate.matchesArchitectureFamily(of: base) else { return false }
            // A paged install cannot load resident as the draft; ChatVM rejects
            // it at launch, so the picker must not offer it.
            guard !OverfitPagedInstallCache.isPaged(candidate.url) else { return false }
            let baseSize = base.sizeGB
            let candidateSize = candidate.sizeGB
            if baseSize > 0, candidateSize > 0, candidateSize - baseSize > 0.01 {
                return false
            }
            return true
        }
    }

    @ViewBuilder
    private var mlxSettingsContent: some View {
        Toggle("Reuse Prompt Cache", isOn: $settings.mlxPromptCacheEnabled)
            .help("Reuse the shared prompt prefix between turns to reduce time to first token.")
        Picker(selection: $settings.mlxKVCacheQuantization) {
            ForEach(MLXKVCacheQuantization.allCases) { quantization in
                Text(LocalizedStringKey(quantization.titleKey)).tag(quantization)
            }
        } label: {
            HStack {
                Text("KV Cache Precision")
                Button {
                    showMLXKVCacheInfo = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .pickerStyle(.menu)
        if let moeInfo = resolvedMoEInfo {
            moeSettings(for: moeInfo)
        }
        if isAdvancedMode {
            IndustrialDisclosureRow("Advanced", headline: mlxAdvancedRuntimeHeadline) {
                if settings.mlxKVCacheQuantization != .fullPrecision {
                    Picker("Quantization Group Size", selection: $settings.mlxKVCacheGroupSize) {
                        ForEach(ModelSettings.mlxKVCacheGroupSizes, id: \.self) { size in
                            Text(verbatim: "\(size)").tag(size)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(
                        value: $settings.mlxKVCacheQuantizationStart,
                        in: 0...max(0, Int(settings.contextLength)),
                        step: 256
                    ) {
                        HStack {
                            Text("Quantization Start")
                            Spacer()
                            Text(verbatim: "\(settings.mlxKVCacheQuantizationStart)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle("Sliding KV Cache", isOn: Binding(
                    get: { settings.mlxKVCacheLimit > 0 },
                    set: { enabled in
                        settings.mlxKVCacheLimit = enabled
                            ? min(max(128, Int(settings.contextLength)), 4096)
                            : 0
                    }
                ))
                if settings.mlxKVCacheLimit > 0 {
                    Stepper(
                        value: $settings.mlxKVCacheLimit,
                        in: 128...max(128, Int(settings.contextLength)),
                        step: 128
                    ) {
                        HStack {
                            Text("KV Cache Limit")
                            Spacer()
                            Text(verbatim: "\(settings.mlxKVCacheLimit)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Prefill Batch Size", selection: $settings.mlxPrefillStepSize) {
                    ForEach(ModelSettings.mlxPrefillStepSizes, id: \.self) { size in
                        Text(verbatim: "\(size)").tag(size)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Seed")
                    TextField("Random", text: Binding(
                        get: { settings.seed.map(String.init) ?? "" },
                        set: { newVal in
                            let digits = newVal.filter { $0.isNumber }
                            if let val = Int(digits) { settings.seed = val } else { settings.seed = nil }
                        }
                    ))
                    .platformKeyboardType(.numberPad)
                }
                TextField("Tokenizer Path (tokenizer.json)", text: Binding(
                    get: { settings.tokenizerPath ?? "" },
                    set: { settings.tokenizerPath = $0.isEmpty ? nil : $0 }
                ))
                .platformAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption)
            }
        }
    }

    private var mlxAdvancedRuntimeHeadline: String {
        let window = settings.mlxKVCacheLimit > 0 ? " · window \(settings.mlxKVCacheLimit)" : ""
        return "prefill \(settings.mlxPrefillStepSize)\(window)"
    }

    @ViewBuilder
    private var etSettingsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ExecuTorch backend selection is automatic in this build. The runtime uses the delegates embedded in the model program.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if let moeInfo = resolvedMoEInfo {
            moeSettings(for: moeInfo)
        }

        if isAdvancedMode {
            HStack {
                Text("Seed")
                TextField("Random", text: Binding(
                    get: { settings.seed.map(String.init) ?? "" },
                    set: { newVal in
                        let digits = newVal.filter { $0.isNumber }
                        if let val = Int(digits) { settings.seed = val } else { settings.seed = nil }
                    }
                ))
                .platformKeyboardType(.numberPad)
            }
            TextField("Tokenizer Path (tokenizer.json)", text: Binding(
                get: { settings.tokenizerPath ?? "" },
                set: { settings.tokenizerPath = $0.isEmpty ? nil : $0 }
            ))
            .platformAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.caption)
        }
    }

    @ViewBuilder
    private var aneSettingsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select which Apple processing units Core ML can use for this model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(
                "Processing Unit Configuration",
                selection: Binding(
                    get: { settings.resolvedProcessingUnitConfiguration },
                    set: { settings.processingUnitConfiguration = $0 }
                )
            ) {
                ForEach(ProcessingUnitConfiguration.allCases) { config in
                    Text(config.displayName).tag(config)
                }
            }
            .pickerStyle(.menu)
        }

        if isAdvancedMode {
            TextField("Tokenizer Path (tokenizer.json)", text: Binding(
                get: { settings.tokenizerPath ?? "" },
                set: { settings.tokenizerPath = $0.isEmpty ? nil : $0 }
            ))
            .platformAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.caption)
        }
    }

    @ViewBuilder
    private var privateCloudSettingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(ApplePrivateCloudComputeAvailability.status.isAvailableForRequests ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(ApplePrivateCloudComputeAvailability.status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(LocalizedStringKey("Private Cloud Compute requests use Apple's privacy-preserving servers and require a network connection."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(LocalizedStringKey("Reasoning Level"), selection: $settings.pccReasoningLevel) {
                ForEach(PCCReasoningLevel.allCases) { level in
                    Text(LocalizedStringKey(level.titleKey)).tag(level)
                }
            }
            .pickerStyle(.menu)

            Text(LocalizedStringKey(settings.pccReasoningLevel.detailKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch ApplePrivateCloudComputeAvailability.status {
            case .approachingLimit, .limitReached:
                if ApplePrivateCloudComputeAvailability.canShowQuotaOptions {
                    Button(LocalizedStringKey("View Usage Options")) {
                        ApplePrivateCloudComputeAvailability.showQuotaOptions()
                    }
                    .buttonStyle(.borderless)
                }
            case .available, .unavailable:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var benchmarkSection: some View {
        IndustrialDisclosureRow("Benchmark", headline: benchmarkHeadline, dotColor: benchmarkResult != nil ? .accentColor : nil, initiallyExpanded: benchmarking) {
            benchmarkSectionContent
        }
    }

    private var benchmarkHeadline: String? {
        guard let result = benchmarkResult else { return nil }
        return String(format: "%.1f tok/s · %@", result.generationRate, result.completedAt.formatted(date: .abbreviated, time: .omitted))
    }

    @ViewBuilder
    private var benchmarkSectionContent: some View {
        if model.format == .ane {
            Text("Benchmarking is not available for this model format.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Measure real-world generation speed for this configuration. A short scripted prompt will run locally and report timing and memory usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let fitsRAM = cachedBenchmarkFitsRAM
                let ramGuardActive = !fitsRAM && !benchmarking
                Button {
                    if ramGuardActive {
                        showBenchmarkRAMSafetyWarning = true
                    } else {
                        runBenchmark()
                    }
                } label: {
                    HStack {
                        Image(systemName: "speedometer")
                        Text(benchmarking ? "Benchmarking…" : "Run Benchmark")
                    }
                    .industrialCTAWidth()
                }
                .buttonStyle(.industrial(.prominent))
                .disabled(benchmarking)

                if ramGuardActive {
                    Text("Model likely exceeds memory budget. Lower context size or use a smaller quant/model.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if benchmarking {
                    VStack(alignment: .leading, spacing: 8) {
                        if vm.loadingProgressTracker.isLoading {
                            ProgressView(value: vm.loadingProgressTracker.progress, total: 1) {
                                Text("Preparing benchmark…")
                            }
                            .progressViewStyle(.linear)

                            HStack {
                                Spacer()
                                ModelLoadingProgressView(tracker: vm.loadingProgressTracker)
                                    .padding(.top, 2)
                                Spacer()
                            }

                            if model.format == .gguf {
                                Text("Compiling Metal kernels for GGUF models can take up to a minute on first load.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Benchmark running…")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ProgressView(value: benchmarkProgress, total: 1)
                                .progressViewStyle(.linear)

                            Text(benchmarkProgressDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .cancel) {
                        cancelBenchmark()
                    } label: {
                        HStack {
                            Image(systemName: "stop.circle")
                            Text("Cancel Benchmark")
                        }
                        .industrialCTAWidth()
                    }
                    .buttonStyle(.industrial(.destructive))
                    .tint(.red)
                }

                if let result = benchmarkResult {
                    BenchmarkSummaryCard(result: result)
                }

                if let error = benchmarkError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct BenchmarkSummaryCard: View {
    let result: ModelBenchmarkResult

    private var settings: ModelSettings { result.settings }
    private var format: ModelFormat { result.format }

    private struct OptimizationDescriptor: Identifiable {
        let id: String
        let title: String
        let value: String
        let icon: String
        let isActive: Bool
    }

    private var promptRateText: String {
        result.promptRate > 0 ? String.localizedStringWithFormat(String(localized: "%.1f tok/s"), result.promptRate) : "--"
    }

    private var generationRateText: String {
        result.generationRate > 0 ? String.localizedStringWithFormat(String(localized: "%.1f tok/s"), result.generationRate) : "--"
    }

    private var totalTimeText: String {
        String.localizedStringWithFormat(String(localized: "%.1fs"), result.totalDuration)
    }

    private var timeToFirstText: String {
        String.localizedStringWithFormat(String(localized: "%.2fs"), result.timeToFirstToken)
    }

    private var memoryValueText: String {
        ByteCountFormatter.string(fromByteCount: result.peakMemoryBytes, countStyle: .memory)
    }

    private var memoryDeltaText: String? {
        guard result.memoryDeltaBytes > 0 else { return nil }
        let delta = ByteCountFormatter.string(fromByteCount: result.memoryDeltaBytes, countStyle: .memory)
        return "+\(delta)"
    }

    private var draftAcceptanceText: String? {
        guard
            let timings = result.speculativeTimings,
            let draftN = timings.draftN,
            draftN > 0
        else { return nil }
        let accepted = timings.draftNAccepted ?? 0
        return "\(accepted)/\(draftN)"
    }

    private var draftAcceptanceDetailText: String? {
        guard let rate = result.speculativeTimings?.acceptanceRate else { return nil }
        return String.localizedStringWithFormat(String(localized: "%.1f%% accepted"), rate * 100)
    }

    private var optimizationBadges: [OptimizationDescriptor] {
        switch format {
        case .gguf:
            let onText = String(localized: "On")
            let offText = String(localized: "Off")
            let gpuText = String(localized: "GPU")
            let cpuText = String(localized: "CPU")
            var badges: [OptimizationDescriptor] = []
            badges.append(OptimizationDescriptor(id: "flash", title: String(localized: "Flash Attention"), value: settings.flashAttention ? onText : offText, icon: "bolt.fill", isActive: settings.flashAttention))
            badges.append(OptimizationDescriptor(id: "kcache", title: String(localized: "K Cache"), value: settings.kCacheQuant.rawValue, icon: "memorychip", isActive: settings.kCacheQuant != .f16))
            if settings.flashAttention {
                badges.append(OptimizationDescriptor(id: "vcache", title: String(localized: "V Cache"), value: settings.vCacheQuant.rawValue, icon: "waveform.path.ecg", isActive: settings.vCacheQuant != .f16))
            }
            badges.append(OptimizationDescriptor(id: "kvoffload", title: String(localized: "KV Offload"), value: result.kvCacheOffloadActive ? gpuText : cpuText, icon: "externaldrive.connected.to.line.below", isActive: result.kvCacheOffloadActive))
            let mtpValue: String
            if settings.speculativeDecoding.mtpEnabled {
                if let acceptance = result.speculativeTimings?.acceptanceRate {
                    mtpValue = String.localizedStringWithFormat(String(localized: "On · %.0f%%"), acceptance * 100)
                } else {
                    mtpValue = String.localizedStringWithFormat(String(localized: "On · n=%d"), settings.speculativeDecoding.resolvedMTPDraftNMax)
                }
            } else {
                mtpValue = offText
            }
            badges.append(OptimizationDescriptor(id: "mtp", title: String(localized: "MTP"), value: mtpValue, icon: "forward.end.fill", isActive: settings.speculativeDecoding.mtpEnabled))
            return badges
        case .mlx:
            let onText = String(localized: "On")
            let offText = String(localized: "Off")
            var badges: [OptimizationDescriptor] = [
                OptimizationDescriptor(
                    id: "mlx-kv",
                    title: String(localized: "KV Cache Precision"),
                    value: String(localized: String.LocalizationValue(settings.mlxKVCacheQuantization.titleKey)),
                    icon: "memorychip",
                    isActive: settings.mlxKVCacheQuantization != .fullPrecision
                ),
                OptimizationDescriptor(
                    id: "mlx-prompt-reuse",
                    title: String(localized: "Reuse Prompt Cache"),
                    value: settings.mlxPromptCacheEnabled ? onText : offText,
                    icon: "arrow.triangle.2.circlepath",
                    isActive: settings.mlxPromptCacheEnabled
                ),
                OptimizationDescriptor(
                    id: "mlx-prefill",
                    title: String(localized: "Prefill Batch Size"),
                    value: "\(settings.mlxPrefillStepSize)",
                    icon: "square.stack.3d.up",
                    isActive: settings.mlxPrefillStepSize != 512
                )
            ]
            if settings.mlxKVCacheLimit > 0 {
                badges.append(OptimizationDescriptor(
                    id: "mlx-window",
                    title: String(localized: "Sliding KV Cache"),
                    value: "\(settings.mlxKVCacheLimit)",
                    icon: "rectangle.compress.vertical",
                    isActive: true
                ))
            }
            return badges
        case .et, .ane, .afm, .coreai:
            return []
        }
    }

    @ViewBuilder
    private var optimizationSection: some View {
        Text(String(localized: "Optimizations in use"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        if optimizationBadges.isEmpty {
            Text((format == .et || format == .afm)
                 ? String(localized: "This format manages runtime optimizations automatically.")
                 : String(localized: "This format doesn't expose tunable runtime optimizations."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(optimizationBadges) { badge in
                        OptimizationBadge(
                            title: badge.title,
                            value: badge.value,
                            icon: badge.icon,
                            isActive: badge.isActive
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latest benchmark")
                        .font(.headline)
                    Text(result.completedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                optimizationSection
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    MetricTile(title: String(localized: "Token processing"), value: promptRateText)
                    MetricTile(title: String(localized: "Token generation"), value: generationRateText)
                }
                GridRow {
                    MetricTile(title: String(localized: "Total time"), value: totalTimeText)
                    MetricTile(title: String(localized: "First token"), value: timeToFirstText)
                }
                GridRow {
                    MetricTile(title: String(localized: "Peak memory"), value: memoryValueText, detail: memoryDeltaText)
                    MetricTile(title: String(localized: "Output tokens"), value: "\(result.generationTokens)")
                }
                if let draftAcceptanceText {
                    GridRow {
                        MetricTile(title: String(localized: "Draft acceptance"), value: draftAcceptanceText, detail: draftAcceptanceDetailText)
                        MetricTile(title: String(localized: "Draft generated"), value: "\(result.speculativeTimings?.draftN ?? 0)")
                    }
                }
            }

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct OptimizationBadge: View {
    let title: String
    let value: String
    let icon: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                Text(value)
                    .font(.caption2.weight(.semibold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12))
        )
        .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.7))
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String?

    init(title: String, value: String, detail: String? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Conditionally mounts the guided-walkthrough highlight overlay (and the
/// `overlayPreferenceValue` anchor collection it depends on) only while the walkthrough is
/// active, so idle scrolling does no preference-propagation work.
private struct WalkthroughHighlightOverlay: ViewModifier {
    let isActive: Bool
    let walkthrough: GuidedWalkthroughManager

    func body(content: Content) -> some View {
        if isActive {
            content.overlayPreferenceValue(GuidedHighlightPreferenceKey.self) { anchors in
                ModelSettingsWalkthroughOverlay(anchors: anchors)
                    .environmentObject(walkthrough)
            }
        } else {
            content
        }
    }
}

private struct ModelSettingsWalkthroughOverlay: View {
    @EnvironmentObject private var manager: GuidedWalkthroughManager
    var anchors: [GuidedWalkthroughManager.HighlightID: Anchor<CGRect>]
    private let allowedSteps: Set<GuidedWalkthroughManager.Step> = [.modelSettingsIntro, .modelSettingsContext]
    private let padding: CGFloat = 16
    @State private var highlightRect: CGRect = .zero
    @State private var highlightVisible = false
    @State private var pulse = false
    @State private var cardPlacement: CardPlacement = .bottom

    var body: some View {
        GeometryReader { proxy in
            overlay(in: proxy)
        }
    }

    @ViewBuilder
    private func overlay(in proxy: GeometryProxy) -> some View {
        if manager.isActive, allowedSteps.contains(manager.step) {
            let targetRect = currentHighlight(in: proxy)
            let instruction = manager.instruction(for: manager.step)
            let allowsInteraction = interactionAllowed(for: manager.step)

            ZStack {
                if highlightVisible {
                    dimmedLayer(for: highlightRect, allowsInteraction: allowsInteraction)
                    spotlightLayer(for: highlightRect)
                    haloLayer(for: highlightRect)
                } else {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .allowsHitTesting(!allowsInteraction)
                }

                VStack {
                    if cardPlacement == .top {
                        VStack(spacing: 12) {
                            instructionCard(for: instruction)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            HStack {
                                Spacer()
                                endGuideButton()
                                    .transition(.opacity)
                            }
                            .padding(.trailing, 8)
                        }
                        .padding(.horizontal, 24)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        VStack(spacing: 12) {
                            HStack {
                                Spacer()
                                endGuideButton()
                                    .transition(.opacity)
                            }
                            .padding(.trailing, 8)
                            instructionCard(for: instruction)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 4)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                    }
                }
                .allowsHitTesting(true)
            }
            .transition(.opacity)
            .overlay(
                Color.clear
                    .onAppear {
                        startPulse()
                        updateHighlight(to: targetRect, in: proxy)
                    }
                    .onChange(of: targetRect) { updateHighlight(to: $0, in: proxy) }
                    .onChange(of: manager.step) { _ in updateHighlight(to: currentHighlight(in: proxy), in: proxy) }
            )
        } else {
            EmptyView()
        }
    }

    private func currentHighlight(in proxy: GeometryProxy) -> CGRect? {
        guard let id = manager.highlightID(for: manager.step),
              let anchor = anchors[id] else { return nil }
        var rect = proxy[anchor]
        rect = rect.insetBy(dx: -padding, dy: -padding)
        rect.origin.x = max(0, rect.origin.x)
        rect.origin.y = max(0, rect.origin.y)
        rect.size.width = min(proxy.size.width - rect.origin.x, rect.width)
        rect.size.height = min(proxy.size.height - rect.origin.y, rect.height)
        return rect
    }

    private func instructionCard(for instruction: (title: String, message: String, primary: String, secondary: String?)) -> some View {
        VStack(spacing: 16) {
            Text(instruction.title)
                .font(.system(size: 19, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(instruction.message)
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.85))
                .multilineTextAlignment(.center)
            Button(instruction.primary) {
                manager.performPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(22)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(0.2), radius: 18, x: 0, y: 12)
        .animation(.easeInOut(duration: 0.3), value: manager.step)
    }

    private func dimmedLayer(for rect: CGRect, allowsInteraction: Bool) -> some View {
        let radius = highlightCornerRadius(for: rect)
        return Canvas { context, size in
            let full = Path(CGRect(origin: .zero, size: size))
            context.fill(full, with: .color(Color.black.opacity(0.52)))

            let cutout = Path(roundedRect: CGRect(x: rect.minX,
                                                  y: rect.minY,
                                                  width: rect.width,
                                                  height: rect.height),
                              cornerRadius: radius)
            context.drawLayer { inner in
                inner.blendMode = .destinationOut
                inner.fill(cutout, with: .color(.black))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!allowsInteraction)
    }

    private func haloLayer(for rect: CGRect) -> some View {
        let radius = highlightCornerRadius(for: rect)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(
                LinearGradient(colors: [Color.white.opacity(0.9), Color.accentColor.opacity(0.5)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                lineWidth: 3
            )
            .frame(width: rect.width + padding * 1.2, height: rect.height + padding * 1.2)
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 16)
            .shadow(color: Color.white.opacity(0.25), radius: 10)
            .scaleEffect(pulse ? 1.03 : 0.97)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
            .allowsHitTesting(false)
    }

    private func spotlightLayer(for rect: CGRect) -> some View {
        let innerWidth = max(1, rect.width - padding * 0.9)
        let innerHeight = max(1, rect.height - padding * 0.9)
        let radius = max(10, highlightCornerRadius(for: rect) - 6)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [
                    Color.white.opacity(0.6),
                    Color.white.opacity(0.18)
                ],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                lineWidth: 2
            )
            .shadow(color: Color.white.opacity(0.24), radius: 8)
            .frame(width: innerWidth, height: innerHeight)
            .position(x: rect.midX, y: rect.midY)
            .blendMode(.screen)
            .compositingGroup()
            .allowsHitTesting(false)
    }

    private func highlightCornerRadius(for rect: CGRect) -> CGFloat {
        let minSide = max(1, min(rect.width, rect.height))
        if minSide < 64 { return minSide / 2 }
        return max(14, min(minSide / 3.5, 28))
    }

    private func updateHighlight(to rect: CGRect?, in proxy: GeometryProxy) {
        guard let rect else {
            if highlightVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    highlightVisible = false
                }
            }
            return
        }
        let availableAbove = rect.minY
        let availableBelow = proxy.size.height - rect.maxY
        let newPlacement: CardPlacement = availableAbove > availableBelow ? .top : .bottom

        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            highlightRect = rect
            highlightVisible = true
            cardPlacement = newPlacement
        }
    }

    private func endGuideButton() -> some View {
        Button("End Guide") {
            manager.finish()
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.white.opacity(0.85))
        .foregroundStyle(.white)
    }

    private func interactionAllowed(for step: GuidedWalkthroughManager.Step) -> Bool {
        switch step {
        case .modelSettingsContext:
            return true
        default:
            return false
        }
    }

    private func startPulse() {
        guard !pulse else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse.toggle()
        }
    }

    private enum CardPlacement {
        case top, bottom
    }
}

private extension ModelSettingsView {
    func applyRuntimePreset(_ preset: ModelRuntimePreset) {
        if model.format == .mlx {
            settings.mlxKVCacheGroupSize = 64
            settings.mlxKVCacheQuantizationStart = 0
            // Presets never silently discard old attention state. The sliding
            // window remains an explicit advanced choice.
            settings.mlxKVCacheLimit = 0

            switch preset {
            case .batterySaver:
                settings.mlxPromptCacheEnabled = false
                settings.mlxKVCacheQuantization = .fourBit
                settings.mlxPrefillStepSize = 256
                settings.contextLength = Double(presetContext(upTo: batterySaverContextTarget(), preferSafe: true))
            case .balanced:
                settings.mlxPromptCacheEnabled = true
                settings.mlxKVCacheQuantization = .eightBit
                settings.mlxPrefillStepSize = 512
                settings.contextLength = Double(presetContext(upTo: 8192, preferSafe: true))
            case .maxSpeed:
                settings.mlxPromptCacheEnabled = true
                settings.mlxKVCacheQuantization = .fullPrecision
#if os(macOS)
                settings.mlxPrefillStepSize = 1024
#else
                settings.mlxPrefillStepSize = 512
#endif
                settings.contextLength = Double(presetContext(upTo: 8192, preferSafe: true))
            case .maxContext:
                settings.mlxPromptCacheEnabled = true
                settings.mlxKVCacheQuantization = .fourBit
                settings.mlxPrefillStepSize = 256
                settings.contextLength = Double(
                    presetContext(upTo: supportedMaxContextLength ?? 65_536, preferSafe: true)
                )
            case .maxContextAggressive, .visionHeavy, .toolHeavy:
                break
            }

            settings = settings.normalizedForLocalModel(model)
            settings.gpuLayers = 0
            updateMoESettingsIfNeeded(with: resolvedMoEInfo)
            recomputeBenchmarkFitsRAM()
            appliedRuntimeFingerprint = runtimeConfigFingerprint
            return
        }

        switch preset {
        case .batterySaver:
            settings.cpuThreads = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
            settings.keepInMemory = false
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            settings.flashAttention = false
            // Flexible: don't hard-cap small models on roomy devices at 4K.
            settings.contextLength = Double(presetContext(upTo: batterySaverContextTarget(), preferSafe: true))
            if model.format == .gguf {
                settings.promptCacheEnabled = false
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                settings.kCacheQuant = .q8_0
                settings.vCacheQuant = .q8_0
            }
        case .balanced:
            settings.contextLength = Double(presetContext(upTo: 8192, preferSafe: true))
            settings.cpuThreads = ModelSettings.maxInferenceThreadCount
            settings.keepInMemory = true
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            if model.format == .gguf {
                settings.promptCacheEnabled = true
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                settings.flashAttention = false
                settings.kCacheQuant = .f16
                settings.vCacheQuant = .f16
            }
        case .maxSpeed:
            settings.contextLength = Double(presetContext(upTo: 8192, preferSafe: true))
            settings.cpuThreads = ModelSettings.maxInferenceThreadCount
            settings.keepInMemory = true
            settings.disableWarmup = false
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            if model.format == .gguf {
                settings.promptCacheEnabled = true
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                settings.flashAttention = true
                // Keep K/V cache at F16 for raw speed: quantizing the cache saves
                // memory but adds (de)quantization overhead on every attention step,
                // which slows token generation. Max Speed prioritizes throughput.
                settings.kCacheQuant = .f16
                settings.vCacheQuant = .f16
            }
        case .maxContext:
            settings.cpuThreads = ModelSettings.maxInferenceThreadCount
            settings.keepInMemory = true
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            if model.format == .gguf {
                settings.promptCacheEnabled = false
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                // Climb only as far as needed: full-precision KV first, escalate to
                // a compact q8_0 cache + flash attention if the model's full context
                // doesn't otherwise fit. Stop at the least optimization that fits.
                let resolved = resolveContextLadder(
                    target: supportedMaxContextLength ?? 65_536,
                    ladder: [
                        KVCachePlan(kQuant: .f16, vQuant: .f16, flashAttention: false),
                        KVCachePlan(kQuant: .q8_0, vQuant: .q8_0, flashAttention: true)
                    ]
                )
                settings.contextLength = Double(resolved.context)
                settings.flashAttention = resolved.plan.flashAttention
                settings.kCacheQuant = resolved.plan.kQuant
                settings.vCacheQuant = resolved.plan.vQuant
            } else {
                settings.contextLength = Double(presetContext(upTo: supportedMaxContextLength ?? 65_536, preferSafe: true))
            }
        case .maxContextAggressive:
            settings.cpuThreads = ModelSettings.maxInferenceThreadCount
            settings.keepInMemory = true
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            if model.format == .gguf {
                settings.promptCacheEnabled = false
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                // Same escalation, but willing to go all the way to a heavily
                // quantized KV cache (Q4 keys, IQ4_NL values) + flash attention to
                // squeeze the longest possible context — yet still stops early if a
                // lighter config already fits the model's full context.
                let resolved = resolveContextLadder(
                    target: supportedMaxContextLength ?? 131_072,
                    ladder: [
                        KVCachePlan(kQuant: .f16, vQuant: .f16, flashAttention: false),
                        KVCachePlan(kQuant: .q8_0, vQuant: .q8_0, flashAttention: true),
                        KVCachePlan(kQuant: .q4_1, vQuant: .iq4_nl, flashAttention: true),
                        KVCachePlan(kQuant: .q4_0, vQuant: .iq4_nl, flashAttention: true)
                    ]
                )
                settings.contextLength = Double(resolved.context)
                settings.flashAttention = resolved.plan.flashAttention
                settings.kCacheQuant = resolved.plan.kQuant
                settings.vCacheQuant = resolved.plan.vQuant
            } else {
                settings.contextLength = Double(presetContext(upTo: supportedMaxContextLength ?? 131_072, preferSafe: true))
            }
        case .visionHeavy:
            settings.contextLength = Double(presetContext(upTo: 12_288, preferSafe: true))
            settings.cpuThreads = ModelSettings.maxInferenceThreadCount
            settings.keepInMemory = true
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            if model.format == .gguf {
                settings.promptCacheEnabled = false
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                settings.flashAttention = true
                settings.kCacheQuant = .f16
                settings.vCacheQuant = .f16
            }
        case .toolHeavy:
            settings.contextLength = Double(presetContext(upTo: 16_384, preferSafe: true))
            settings.cpuThreads = ModelSettings.maxInferenceThreadCount
            settings.keepInMemory = true
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            if model.format == .gguf {
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                settings.flashAttention = true
                settings.kCacheQuant = .f16
                settings.vCacheQuant = .f16
                settings.promptCacheEnabled = true
                if settings.promptCachePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settings.promptCachePath = defaultPromptCachePath()
                }
                settings.promptCacheAll = false
            }
        }

        settings = settings.normalizedForLocalModel(model)
        if model.format != .gguf {
            settings.gpuLayers = 0
        }
        updateMoESettingsIfNeeded(with: resolvedMoEInfo)
        recomputeBenchmarkFitsRAM()
        // Re-baseline so the section reads as the chosen preset (not "Custom")
        // until the user next hand-edits a control.
        appliedRuntimeFingerprint = runtimeConfigFingerprint
    }

    // MARK: - Custom (user-saved) runtime presets

    var customRuntimePresets: [CustomRuntimePreset] {
        guard let data = customRuntimePresetsData.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([CustomRuntimePreset].self, from: data)) ?? []
    }

    func persistCustomPresets(_ presets: [CustomRuntimePreset]) {
        guard let data = try? JSONEncoder().encode(presets),
              let json = String(data: data, encoding: .utf8) else { return }
        customRuntimePresetsData = json
    }

    /// Runtime fingerprint of a saved preset, in the same shape as
    /// `runtimeConfigFingerprint`, so an active saved preset can be highlighted.
    func fingerprint(for preset: CustomRuntimePreset) -> String {
        if model.format == .mlx {
            return "\(Int(preset.contextLength))|\(preset.mlxPromptCacheEnabled)|\(preset.mlxKVCacheQuantization.rawValue)|\(preset.mlxKVCacheGroupSize)|\(preset.mlxKVCacheQuantizationStart)|\(preset.mlxKVCacheLimit)|\(preset.mlxPrefillStepSize)"
        }
        return "\(Int(preset.contextLength))|\(preset.kCacheQuant.rawValue)|\(preset.vCacheQuant.rawValue)|\(preset.flashAttention)|\(preset.keepInMemory)|\(preset.kvCacheOffload)|\(preset.unifiedKVCache)|\(preset.cpuThreads)|\(preset.promptCacheEnabled)"
    }

    func saveCurrentSettingsAsPreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var presets = customRuntimePresets
        let preset = CustomRuntimePreset(name: name, settings: settings)
        // Replace a same-named preset (case-insensitive) instead of duplicating.
        if let idx = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            var replacement = preset
            replacement.id = presets[idx].id
            presets[idx] = replacement
            selectedCustomPresetID = replacement.id
        } else {
            presets.append(preset)
            selectedCustomPresetID = preset.id
        }
        persistCustomPresets(presets)
        appliedRuntimeFingerprint = runtimeConfigFingerprint
    }

    func deleteCustomPreset(_ preset: CustomRuntimePreset) {
        var presets = customRuntimePresets
        presets.removeAll { $0.id == preset.id }
        persistCustomPresets(presets)
        if selectedCustomPresetID == preset.id {
            selectedCustomPresetID = nil
        }
    }

    func applyCustomPreset(_ preset: CustomRuntimePreset) {
        if model.format == .mlx {
            settings.mlxPromptCacheEnabled = preset.mlxPromptCacheEnabled
            settings.mlxKVCacheQuantization = preset.mlxKVCacheQuantization
            settings.mlxKVCacheGroupSize = preset.mlxKVCacheGroupSize
            settings.mlxKVCacheQuantizationStart = preset.mlxKVCacheQuantizationStart
            settings.mlxKVCacheLimit = preset.mlxKVCacheLimit
            settings.mlxPrefillStepSize = preset.mlxPrefillStepSize
        } else {
            settings.cpuThreads = preset.cpuThreads
            settings.keepInMemory = preset.keepInMemory
            settings.kvCacheOffload = preset.kvCacheOffload
            settings.unifiedKVCache = preset.unifiedKVCache
            settings.promptCacheEnabled = preset.promptCacheEnabled
        }
        if model.format == .gguf {
            settings.flashAttention = preset.flashAttention
            settings.kCacheQuant = preset.kCacheQuant
            settings.vCacheQuant = preset.vCacheQuant
            settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? preset.gpuLayers : 0
            if preset.promptCacheEnabled,
               settings.promptCachePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.promptCachePath = defaultPromptCachePath()
            }
        }
        // Clamp the saved context to what this model + device can actually fit.
        settings.contextLength = Double(presetContext(upTo: Int(preset.contextLength), preferSafe: true))

        settings = settings.normalizedForLocalModel(model)
        if model.format != .gguf {
            settings.gpuLayers = 0
        }
        updateMoESettingsIfNeeded(with: resolvedMoEInfo)
        recomputeBenchmarkFitsRAM()
        selectedCustomPresetID = preset.id
        appliedRuntimeFingerprint = runtimeConfigFingerprint
    }

    func defaultPromptCachePath() -> String {
        let base = model.url.deletingLastPathComponent()
        let name = model.url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return base.appendingPathComponent("\(name).prompt-cache").path
    }

    /// One rung on the KV-cache optimization ladder a context-maximizing preset
    /// can climb. Lighter rungs come first; quantized values only take effect when
    /// `flashAttention` is on, mirroring how the runtime applies LLAMA_V_QUANT.
    struct KVCachePlan {
        let kQuant: CacheQuant
        let vQuant: CacheQuant
        let flashAttention: Bool
    }

    /// Walks an ordered ladder of KV-cache configurations (lightest optimization
    /// first) and returns the first rung whose largest fittable context already
    /// reaches `target`, together with the context to use. When no rung fits the
    /// full target, returns the heaviest rung and the largest context it can fit.
    /// This lets context-maximizing presets stop at the least optimization that
    /// already fits, and only escalate (flash attention, quantized KV) when the
    /// device is genuinely tight.
    func resolveContextLadder(target requestedTarget: Int,
                              ladder: [KVCachePlan]) -> (context: Int, plan: KVCachePlan) {
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        let layerHint: Int? = layerCount > 0 ? layerCount : nil
        let upper = supportedMaxContextLength
        let clampedTarget = max(512, min(requestedTarget, supportedMaxContextLength ?? requestedTarget))
        let defaultPlan = KVCachePlan(kQuant: .f16, vQuant: .f16, flashAttention: false)
        var fallback: (context: Int, plan: KVCachePlan) = (clampedTarget, ladder.last ?? defaultPlan)

        for plan in ladder {
            // V-cache quantization only applies with flash attention, so a non-flash
            // rung effectively keeps f16 values for the memory estimate.
            let estimate = ModelRAMAdvisor.GGUFKVCacheEstimate(
                kCacheQuant: plan.kQuant,
                vCacheQuant: plan.flashAttention ? plan.vQuant : .f16
            )
            let fittable = ModelRAMAdvisor.maxContextUnderBudget(
                format: model.format,
                sizeBytes: sizeBytes,
                layerCount: layerHint,
                moeInfo: effectiveMoEInfo,
                upperBound: upper,
                kvCacheEstimate: estimate,
                runtimeConfiguration: .resolved(from: settings, modelURL: model.url),
                knownWorkingContextLength: knownWorkingContextLength
            ) ?? clampedTarget
            let achievable = max(512, min(clampedTarget, fittable))
            fallback = (achievable, plan)
            if achievable >= clampedTarget {
                return (achievable, plan)
            }
        }
        return fallback
    }

    /// Battery Saver keeps context modest to save power, but small models on
    /// devices with memory headroom don't need to be capped at 4K — bump the
    /// ceiling to 8K when the device can comfortably afford it. The result is
    /// still passed through `presetContext` so it's clamped to what actually fits.
    func batterySaverContextTarget() -> Int {
        let base = 4096
        let generous = 8192
        let isSmallModel = model.sizeGB <= 2.0
        guard isSmallModel else { return base }
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        let layerHint: Int? = layerCount > 0 ? layerCount : nil
        // Battery Saver runs flash attention off, so values stay f16 regardless of
        // the q8_0 V setting — estimate accordingly.
        let estimate = ModelRAMAdvisor.GGUFKVCacheEstimate(kCacheQuant: .q8_0, vCacheQuant: .f16)
        let fittable = ModelRAMAdvisor.maxContextUnderBudget(
            format: model.format,
            sizeBytes: sizeBytes,
            layerCount: layerHint,
            moeInfo: effectiveMoEInfo,
            upperBound: supportedMaxContextLength,
            kvCacheEstimate: estimate,
            runtimeConfiguration: .resolved(from: settings, modelURL: model.url),
            knownWorkingContextLength: knownWorkingContextLength
        ) ?? base
        return fittable >= generous ? generous : base
    }

    func presetContext(upTo requested: Int, preferSafe: Bool) -> Int {
        let upperBound = supportedMaxContextLength ?? requested
        let requestedBound = max(512, min(requested, upperBound))
        guard preferSafe else { return requestedBound }

        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
        guard let safe = ModelRAMAdvisor.maxContextUnderBudget(
            format: model.format,
            sizeBytes: sizeBytes,
            layerCount: (layerCount > 0 ? layerCount : nil),
            moeInfo: effectiveMoEInfo,
            upperBound: upperBound,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: .resolved(from: settings, modelURL: model.url),
            knownWorkingContextLength: knownWorkingContextLength
        ) else {
            return requestedBound
        }

        return max(512, min(requestedBound, safe))
    }

    func recomputeBenchmarkFitsRAM() {
        guard model.format != .ane else { cachedBenchmarkFitsRAM = false; return }
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        let context = Int(settings.contextLength)
        let layerHint: Int? = layerCount > 0 ? layerCount : nil
        let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
        cachedBenchmarkFitsRAM = ModelRAMAdvisor.fitsInRAM(
            format: model.format,
            sizeBytes: sizeBytes,
            contextLength: context,
            layerCount: layerHint,
            moeInfo: effectiveMoEInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: .resolved(from: settings, modelURL: model.url)
        )
    }

    func runBenchmark(bypassRAMCheck: Bool = false) {
        guard !benchmarking, model.format != .ane else { return }
#if canImport(UIKit) && !os(visionOS)
        Haptics.impact(.light)
#endif
        let currentSettings = settings
        benchmarkError = nil
        benchmarking = true
        benchmarkProgress = 0
        benchmarkProgressDetail = String(localized: "Benchmark running…")

        let taskID = UUID()
        benchmarkTaskID = taskID
        let task = Task { [model, vm] in
            do {
                let result = try await ModelBenchmarkService.run(
                    model: model,
                    settings: currentSettings,
                    vm: vm,
                    bypassRAMCheck: bypassRAMCheck
                ) { update in
                    benchmarkProgress = update.fraction
                    benchmarkProgressDetail = update.detail
                }
                try Task.checkCancellation()
                await MainActor.run {
                    if benchmarkTaskID == taskID {
                        benchmarkResult = result
                        ModelBenchmarkResultStore.save(result: result, for: model)
                        benchmarkError = nil
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if benchmarkTaskID == taskID {
                        benchmarkError = nil
                    }
                }
            } catch ModelBenchmarkError.ramSafetyBlocked {
                await MainActor.run {
                    if benchmarkTaskID == taskID {
                        if bypassRAMCheck {
                            benchmarkError = ModelBenchmarkError.ramSafetyBlocked.localizedDescription
                        } else {
                            vm.loadError = nil
                            benchmarkError = nil
                            showBenchmarkRAMSafetyWarning = true
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if benchmarkTaskID == taskID {
                        benchmarkError = error.localizedDescription
                        benchmarkResult = nil
                    }
                }
            }

            await MainActor.run {
                if benchmarkTaskID == taskID {
                    benchmarking = false
                    benchmarkTask = nil
                    benchmarkTaskID = nil
                }
            }
        }
        benchmarkTask = task
    }

    func cancelBenchmark() {
        guard benchmarking || benchmarkTask != nil else { return }
#if canImport(UIKit) && !os(visionOS)
        Haptics.impact(.light)
#endif
        benchmarkTask?.cancel()
        benchmarkTask = nil
        benchmarkTaskID = nil
        benchmarking = false
        vm.loadingProgressTracker.completeLoading()
        benchmarkProgress = 0
        benchmarkProgressDetail = String(localized: "Benchmark running…")
    }

    private func saveAndClose() {
#if canImport(UIKit) && !os(visionOS)
        Haptics.impact(.light)
#endif
        persistModelAliasIfNeeded()
        modelManager.updateSettings(settings, for: model)
        vm.syncActiveLocalModelPromptSettingsIfNeeded(model: model, settings: settings)
        close()
    }

    private func loadAndClose() {
#if canImport(UIKit) && !os(visionOS)
        Haptics.impact(.medium)
#endif
        persistModelAliasIfNeeded()
        modelManager.updateSettings(settings, for: model)
        vm.syncActiveLocalModelPromptSettingsIfNeeded(model: model, settings: settings)
        loadAction(settings)
        close()
    }

    func close() {
#if os(macOS)
        macModalDismiss()
#else
        dismiss()
#endif
    }

    func updateGPULayers() {
        if !DeviceGPUInfo.supportsGPUOffload {
            settings.gpuLayers = 0
            settings.kvCacheOffload = false
            return
        }
        if model.format == .gguf {
            if layerCount > 0 {
                // Preserve sentinel (-1) meaning all layers
                if settings.gpuLayers >= 0 && settings.gpuLayers > layerCount {
                    settings.gpuLayers = layerCount
                }
                if usingDefaultGPULayers && settings.gpuLayers == 0 {
                    // Default to all layers when unset
                    settings.gpuLayers = -1
                }
            }
        } else {
            settings.gpuLayers = 0
        }
    }
    
    func refreshFileStatuses() {
        guard model.format == .gguf else { return }
        let dir = model.url.deletingLastPathComponent()
        let artifactsURL = dir.appendingPathComponent("artifacts.json")
        var weightsName: String? = nil
        var projector: Any? = nil
        var checked = false
        if let data = try? Data(contentsOf: artifactsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            weightsName = obj["weights"] as? String
            projector = obj["mmproj"]
            checked = (obj["mmprojChecked"] as? Bool) ?? false
        }
        // Resolve weights path
        var resolvedWeights: String? = nil
        if let w = weightsName {
            let p = dir.appendingPathComponent(w).path
            if FileManager.default.fileExists(atPath: p) { resolvedWeights = p }
        } else {
            let p = model.url.path
            if FileManager.default.fileExists(atPath: p) { resolvedWeights = p }
        }
        // Resolve projector path
        var resolvedProj: String? = nil
        if let s = projector as? String {
            let p = dir.appendingPathComponent(s).path
            if FileManager.default.fileExists(atPath: p) { resolvedProj = p }
        }
        weightsFilePath = resolvedWeights
        mmprojFilePath = resolvedProj
        mmprojChecked = checked
        filesStatusLoaded = true
    }
}

#if os(macOS)
private extension View {
    func settingsWarningBackground() -> some View {
        self
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.yellow.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            )
    }
}
#else
private extension View {
    func settingsWarningBackground() -> some View {
        self.listRowBackground(Color.yellow.opacity(0.1))
    }
}
#endif

/// Overfit (paged experts) controls for a `.noema-paged` GGUF install: mode
/// picker, canary status, and the canary launcher. Package + stored-canary
/// state loads off-main because manifest reads touch disk.
private struct OverfitSettingsBlock: View {
    let model: LocalModel
    @Binding var settings: ModelSettings
    let isAdvancedMode: Bool
    @Environment(\.locale) private var locale

    @State private var package: NoemaPagedPackage?
    @State private var packageDirectory: URL?
    @State private var canaryRecord: OverfitCanaryRecord?
    @State private var showCanarySheet = false
    @State private var canaryPhase: OverfitCanaryPhase = .validating
    @State private var canaryError: String?
    @State private var canaryTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overfit (Paged Experts)")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(Color.primary.opacity(0.6))
                .lineLimit(1)
            modePicker
            Text("Streams expert weights from storage on demand. Speed depends on this device's storage.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let canaryRecord {
                HStack(spacing: 8) {
                    OverfitClassificationChip(classification: canaryRecord.classification)
                    Text(verbatim: canarySummary(for: canaryRecord))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Button("Run Canary Test") { runCanary() }
                .buttonStyle(.industrial)
                .disabled(package == nil || showCanarySheet)
        }
        .padding(.top, 4)
        .task(id: model.url) { await loadPackageState() }
        .sheet(isPresented: $showCanarySheet) {
            OverfitCanaryProgressSheet(phase: canaryPhase, error: canaryError) {
                canaryTask?.cancel()
                canaryTask = nil
                showCanarySheet = false
            }
        }
    }

    /// `.forceExperimental` stays selectable outside advanced mode only while
    /// it is the current value, so the control never shows an impossible state.
    private var showsForceMode: Bool {
        isAdvancedMode || settings.overfitMode == .forceExperimental
    }

    @ViewBuilder
    private var modePicker: some View {
#if os(macOS)
        HStack(spacing: 6) {
            modeButton("Off", mode: .off)
            modeButton("Automatic", mode: .automatic)
            if showsForceMode {
                modeButton("Force (Experimental)", mode: .forceExperimental)
            }
        }
#else
        Picker("Overfit (Paged Experts)", selection: $settings.overfitMode) {
            Text("Off").tag(ModelSettings.OverfitMode.off)
            Text("Automatic").tag(ModelSettings.OverfitMode.automatic)
            if showsForceMode {
                Text("Force (Experimental)").tag(ModelSettings.OverfitMode.forceExperimental)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
#endif
    }

#if os(macOS)
    private func modeButton(_ title: LocalizedStringKey, mode: ModelSettings.OverfitMode) -> some View {
        Button(title) { settings.overfitMode = mode }
            .buttonStyle(.industrial(settings.overfitMode == mode ? .tinted : .quiet))
    }
#endif

    private func canarySummary(for record: OverfitCanaryRecord) -> String {
        let measured = String.localizedStringWithFormat(
            String(localized: "Measured %@ tok/s · %@ MB/s", locale: locale),
            String(format: "%.1f", record.generationRate),
            String(format: "%.0f", record.storageAlignedReadMBps)
        )
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        let relative = formatter.localizedString(for: record.completedAt, relativeTo: Date())
        return "\(measured) · \(relative)"
    }

    private func loadPackageState() async {
        let modelURL = model.url
        let loaded: (URL, NoemaPagedPackage, OverfitCanaryRecord?)? = await Task.detached(priority: .utility) {
            guard let directory = PagedPackageLocator.enclosingPackage(for: modelURL),
                  let package = try? NoemaPagedPackage.load(at: directory) else {
                return nil
            }
            let record = OverfitCanaryStore.shared.record(
                fingerprint: package.manifest.fingerprint,
                device: OverfitEnvironmentIdentity.deviceModelIdentifier,
                volume: OverfitEnvironmentIdentity.volumeIdentifier(for: directory),
                contractVersion: OverfitEnvironmentIdentity.nativeContractVersion,
                appBuild: OverfitEnvironmentIdentity.appBuild
            )
            return (directory, package, record)
        }.value
        guard let loaded else { return }
        packageDirectory = loaded.0
        package = loaded.1
        canaryRecord = loaded.2
    }

    private func runCanary() {
        guard let package else { return }
        canaryError = nil
        canaryPhase = .validating
        showCanarySheet = true
        let modelURL = model.url
        let runSettings = settings
        canaryTask = Task { @MainActor in
            do {
                _ = try await OverfitCanaryService.run(
                    package: package,
                    modelURL: modelURL,
                    settings: runSettings,
                    progress: { phase in
                        Task { @MainActor in canaryPhase = phase }
                    }
                )
                canaryPhase = .finished
                await loadPackageState()
            } catch is CancellationError {
                showCanarySheet = false
            } catch {
                canaryError = error.localizedDescription
            }
            canaryTask = nil
        }
    }
}
