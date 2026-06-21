// ModelSettingsView.swift
import SwiftUI
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
    var detailKey: LocalizedStringKey {
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
    var id: UUID = UUID()
    var name: String
    var contextLength: Double
    var cpuThreads: Int
    var keepInMemory: Bool
    var kvCacheOffload: Bool
    var flashAttention: Bool
    var kCacheQuant: CacheQuant
    var vCacheQuant: CacheQuant
    var promptCacheEnabled: Bool
    var gpuLayers: Int

    /// Captures the runtime-relevant fields from a live `ModelSettings`.
    init(name: String, settings: ModelSettings) {
        self.id = UUID()
        self.name = name
        self.contextLength = settings.contextLength
        self.cpuThreads = settings.cpuThreads
        self.keepInMemory = settings.keepInMemory
        self.kvCacheOffload = settings.kvCacheOffload
        self.flashAttention = settings.flashAttention
        self.kCacheQuant = settings.kCacheQuant
        self.vCacheQuant = settings.vCacheQuant
        self.promptCacheEnabled = settings.promptCacheEnabled
        self.gpuLayers = settings.gpuLayers
    }
}

enum ModelSettingsSectionID: String, Codable, CaseIterable, Sendable {
    case overview
    case provenance
    case chatTemplatePreview
    case formatSpecific
    case sampling
    case speculativeDecoding
    case benchmark
    case maintenance
    case files
}

struct ModelSettingsSectionSnapshot: Codable, Equatable, Identifiable, Sendable {
    enum Platform: String, Codable, Sendable {
        case iOSForm
        case macOS
    }

    let id: ModelSettingsSectionID
    let title: String

    static func sections(
        for format: ModelFormat,
        isAdvancedMode: Bool,
        platform: Platform
    ) -> [ModelSettingsSectionSnapshot] {
        var sections: [ModelSettingsSectionSnapshot] = [
            .init(id: .overview, title: format.displayName)
        ]

        if platform == .iOSForm {
            sections.append(.init(id: .chatTemplatePreview, title: "Chat Template Preview"))
        }

        sections.append(.init(id: .formatSpecific, title: format == .gguf ? "GGUF" : format.displayName))

        if isAdvancedMode {
            sections.append(.init(id: .sampling, title: "Sampling"))
            if format == .gguf {
                sections.append(.init(id: .speculativeDecoding, title: "Speculative Decoding"))
            }
        }

        sections.append(.init(id: .benchmark, title: "Benchmark"))
        sections.append(.init(id: .maintenance, title: "Maintenance"))

        if format == .gguf {
            sections.append(.init(id: .files, title: "Files"))
        }

        sections.append(.init(id: .provenance, title: "Provenance"))

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
    let sizeBytes: Int64
    let layerCount: Int?
    let moeInfo: MoEInfo?
    let supportedMaxContextLength: Int?
    let kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate
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
    }

    @State private var draft: Double = 0
    @State private var isEditing = false

    private var draftFingerprint: String {
        guard let d = draftEstimateInput else { return "none" }
        return "\(d.format.rawValue)|\(d.sizeBytes)|\(d.layerCount ?? -1)"
    }

    // Cached RAM estimate. The math is cheap, but it allocates two
    // ByteCountFormatters per evaluation, and the view body can re-render for
    // many reasons (scroll re-realization, observed-object churn). Compute it
    // only when the inputs that affect it actually change.
    private struct RAMEstimate: Equatable {
        var estimate: Int64 = 0
        var budget: Int64? = nil
        var maxCtx: Int? = nil
        var estStr: String = "--"
        var budStr: String = "--"
        /// Target + draft model working set, when a helper draft model is set.
        var combined: Int64? = nil
        var combinedStr: String = "--"
    }
    @State private var ram = RAMEstimate()

    private var isSliderFormat: Bool {
        format == .gguf || format == .mlx || format == .et || format == .coreai
    }

    private var displayValue: Double {
        isEditing ? draft : contextLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(format == .afm ? "Fixed Context Length" : "Context Length")
                    .font(FontTheme.subheadline)
                    .foregroundStyle(AppTheme.text)
                if isSliderFormat {
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
                } else {
                    HStack {
                        Text("\(Int(contextLength)) tokens")
                            .monospacedDigit()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }

            if format == .ane {
                Text("Derived from model title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if format == .afm {
                Text("Apple Foundation Models only support a 4096-token context in Noema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Int(displayValue)) tokens")
            }

            ramEstimateRows()

            if isSliderFormat && displayValue > 8192 {
                Text("High context lengths use more memory")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .onAppear { recomputeRAM() }
        .onChange(of: Int(displayValue)) { _ in recomputeRAM() }
        .onChange(of: kvCacheEstimate) { _ in recomputeRAM() }
        .onChange(of: layerCount) { _ in recomputeRAM() }
        .onChange(of: draftFingerprint) { _ in recomputeRAM() }
    }

    private func recomputeRAM() {
        let ctx = Int(displayValue)
        let (estimate, budget) = ModelRAMAdvisor.estimateAndBudget(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: ctx,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate
        )
        let maxCtx = ModelRAMAdvisor.maxContextUnderBudget(
            format: format,
            sizeBytes: sizeBytes,
            layerCount: layerCount,
            moeInfo: moeInfo,
            upperBound: supportedMaxContextLength,
            kvCacheEstimate: kvCacheEstimate
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
                kvCacheEstimate: kvCacheEstimate
            )
            let total = estimate + draftEstimate
            combined = total
            combinedStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
        }
        ram = RAMEstimate(
            estimate: estimate,
            budget: budget,
            maxCtx: maxCtx,
            estStr: ByteCountFormatter.string(fromByteCount: estimate, countStyle: .memory),
            budStr: budget.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "--",
            combined: combined,
            combinedStr: combinedStr
        )
    }

    @ViewBuilder
    private func ramEstimateRows() -> some View {
        let locale = LocalizationManager.preferredLocale()
        // When a helper draft model is configured, the fit assessment must judge
        // the combined working set (target + draft), not the target alone.
        let estimate = ram.combined ?? ram.estimate
        let budget = ram.budget
        let maxCtx = ram.maxCtx
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: ramFitIcon(estimate: estimate, budget: budget))
                    .foregroundColor(ramFitColor(estimate: estimate, budget: budget))
                Text(LocalizedStringKey(ramFitTitle(estimate: estimate, budget: budget)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ramFitColor(estimate: estimate, budget: budget))
            }
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundColor(.secondary)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Estimated working set: %@ · Budget: %@", locale: locale),
                        ram.estStr,
                        ram.budStr
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if ram.combined != nil {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundColor(.secondary)
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "With draft model: %@ combined", locale: locale),
                            ram.combinedStr
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let maxCtx {
                HStack(spacing: 8) {
                    Image(systemName: "gauge")
                        .foregroundColor(.secondary)
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Max recommended context on this device: ~%@ tokens", locale: locale),
                            "\(maxCtx)"
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let budget, estimate > budget, let maxCtx {
                Button {
                    let safe = Double(max(512, maxCtx))
                    contextLength = safe
                    draft = safe
                    isEditing = false
                } label: {
                    Label(LocalizedStringKey("Use Safe Context"), systemImage: "dial.low")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    private func ramFitTitle(estimate: Int64, budget: Int64?) -> String {
        guard let budget, budget > 0 else { return "No device budget available" }
        let ratio = Double(estimate) / Double(budget)
        if ratio > 1.0 { return "Likely over memory budget" }
        if ratio >= 0.85 { return "Borderline context" }
        return "Comfortable context"
    }

    private func ramFitIcon(estimate: Int64, budget: Int64?) -> String {
        guard let budget, budget > 0 else { return "questionmark.circle" }
        let ratio = Double(estimate) / Double(budget)
        if ratio > 1.0 { return "exclamationmark.triangle.fill" }
        if ratio >= 0.85 { return "gauge.medium" }
        return "checkmark.circle.fill"
    }

    private func ramFitColor(estimate: Int64, budget: Int64?) -> Color {
        guard let budget, budget > 0 else { return .secondary }
        let ratio = Double(estimate) / Double(budget)
        if ratio > 1.0 { return .orange }
        if ratio >= 0.85 { return .yellow }
        return .green
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
    @State private var settings = ModelSettings()
    @State private var layerCount: Int = 0
    @State private var scanning = false
    @State private var showKInfo = false
    @State private var showVInfo = false
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
    @State private var isArgmaxANEMLLModel = false
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
        settingsContainer
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
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(action: {
#if canImport(UIKit) && !os(visionOS)
                        Haptics.impact(.light)
#endif
                        // Save only; do not load. Close sheet.
                        persistModelAliasIfNeeded()
                        modelManager.updateSettings(settings, for: model)
                        vm.syncActiveLocalModelPromptSettingsIfNeeded(model: model, settings: settings)
                        close()
                    }) {
                        Text("Save")
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .disabled(benchmarking)

                    Button(action: {
#if canImport(UIKit) && !os(visionOS)
                        Haptics.impact(.medium)
#endif
                        // Persist settings and trigger load
                        persistModelAliasIfNeeded()
                        modelManager.updateSettings(settings, for: model)
                        vm.syncActiveLocalModelPromptSettingsIfNeeded(model: model, settings: settings)
                        loadAction(settings)
                        close()
                    }) {
                        if vm.loading { ProgressView() } else { Text("Load") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(vm.loading || benchmarking)
                }
            }
        #endif
            .onAppear {
                usingDefaultGPULayers = modelManager.modelSettings[model.url.path] == nil
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
                // Baseline for the runtime preset "Custom" detection: the loaded
                // settings are the starting point; later hand-edits drift from it.
                appliedRuntimeFingerprint = runtimeConfigFingerprint
            }
            .onReceive(modelManager.$downloadedModels) { models in
                if let current = models.first(where: { $0.id == model.id }) {
                    isFavourite = current.isFavourite
                    updateMoESettingsIfNeeded(with: current.moeInfo)
                }
            }
            .task(id: resolvedModel.url.path) {
                await refreshArgmaxCapability(for: resolvedModel)
                await refreshModelUpdateStatus()
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
            .onChange(of: settings.moeActiveExperts) { _ in recomputeBenchmarkFitsRAM() }
            .onChange(of: settings.gpuLayers) { _ in usingDefaultGPULayers = false }
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

#if os(macOS)
private struct MacSettingsBlock<Content: View>: View {
    let title: String?
    let format: ModelFormat?
    let iconName: String?
    let content: Content

    init(title: String? = nil, format: ModelFormat? = nil, iconName: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.format = format
        self.iconName = iconName
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if title != nil || format != nil || iconName != nil {
                HStack(spacing: 12) {
                    if let format {
                        ModelFormatTagView(format: format)
                    } else if let iconName {
                        Image(systemName: iconName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    if let title {
                        Text(title)
                            .font(FontTheme.heading(size: 20))
                            .foregroundStyle(AppTheme.text)
                    }

                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .controlSize(.large)
    }
}

private struct ModelFormatTagView: View {
    let format: ModelFormat

    var body: some View {
        Text(format.displayName)
            .font(FontTheme.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(format.tagGradient)
            .clipShape(Capsule())
            .foregroundStyle(.white)
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}

#endif

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

    @ViewBuilder
    private var settingsContainer: some View {
#if os(macOS)
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 24) {
                        MacSettingsBlock(title: "General", format: model.format, iconName: "square.grid.2x2") {
                            VStack(alignment: .leading, spacing: 12) {
                                modelAliasContent
                                favoriteToggle
                            }
                        }

                        if model.format == .afm, AFMLLMClient.supportsPrivateCloudCompute {
                            MacSettingsBlock(title: "Private Cloud Compute", iconName: "lock.icloud") {
                                afmSettingsContent
                            }
                        }

                        MacSettingsBlock {
                            contextLengthControl
                        }

                        if model.format != .afm {
                            MacSettingsBlock {
                                runtimePresetContent
                            }
                        }

                        MacSettingsBlock {
                            systemPromptSettingsContent
                        }

                        if model.format == .gguf {
                            MacSettingsBlock(title: "GGUF", iconName: "circle.hexagongrid") {
                                ggufSettingsContent
                            }
                        } else if model.format != .afm {
                            // AFM settings (Private Cloud Compute) are surfaced near the top instead.
                            MacSettingsBlock(title: model.format.displayName, iconName: "slider.horizontal.2.square") {
                                if model.format == .et {
                                    etSettingsContent
                                } else if model.format == .ane {
                                    aneSettingsContent
                                } else {
                                    mlxSettingsContent
                                }
                            }
                        }

                        if isAdvancedMode {
                            MacSettingsBlock(title: "Sampling", iconName: "slider.horizontal.3") {
                                samplingSectionContent
                            }
#if os(macOS)
                            if supportsSpeculativeDecoding {
                                MacSettingsBlock(title: "Speculative Decoding", iconName: "sparkles") {
                                    speculativeDecodingContent
                                }
                            }
#endif
                        }

                        MacSettingsBlock(title: "Benchmark", iconName: "speedometer") {
                            benchmarkSectionContent
                        }

                        MacSettingsBlock(title: "Maintenance", iconName: "arrow.clockwise") {
                            resetActionsContent
                        }

                        if model.format == .gguf {
                            MacSettingsBlock(title: "Files", iconName: "externaldrive") {
                                filesSectionContent
                            }
                        }

                        MacSettingsBlock(title: "Provenance", iconName: "info.circle") {
                            provenanceSectionContent
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            // Inline action bar to avoid window toolbar on macOS
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        close()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.plain)
                    .disabled(benchmarking)

                    Spacer()

                    Button(action: {
                        modelManager.updateSettings(settings, for: model)
                        vm.syncActiveLocalModelPromptSettingsIfNeeded(model: model, settings: settings)
                        close()
                    }) {
                        Text("Save")
                            .foregroundColor(.primary)
                            .opacity(0.75)
                    }
                    .buttonStyle(.plain)
                    .disabled(benchmarking)

                    Button(action: {
                        modelManager.updateSettings(settings, for: model)
                        vm.syncActiveLocalModelPromptSettingsIfNeeded(model: model, settings: settings)
                        loadAction(settings)
                        close()
                    }) {
                        if vm.loading { ProgressView() } else { Text("Load") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(vm.loading || benchmarking)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
#else
        Form {
            settingsSections
        }
#endif
    }

    @ViewBuilder
    private var settingsSections: some View {
        ForEach(ModelSettingsSectionSnapshot.sections(for: model.format, isAdvancedMode: isAdvancedMode, platform: .iOSForm)) { section in
            switch section.id {
            case .overview:
                Section(header: Text(model.format.displayName)) {
                    modelAliasContent
                    favoriteToggle
                }
                if model.format == .afm, AFMLLMClient.supportsPrivateCloudCompute {
                    Section(header: Text(LocalizedStringKey("Private Cloud Compute"))) {
                        afmSettingsContent
                    }
                }
                Section {
                    contextLengthControl
                }
                if model.format != .afm {
                    Section {
                        runtimePresetContent
                    }
                }
                Section {
                    systemPromptSettingsContent
                }
            case .provenance:
                provenanceSection
            case .chatTemplatePreview:
                chatTemplatePreviewSection
            case .formatSpecific:
                if model.format == .gguf {
                    ggufSettings
                } else if model.format != .afm {
                    // AFM settings (Private Cloud Compute) are surfaced near the top instead.
                    nonGGUFSettings
                }
            case .sampling:
                samplingSection
            case .speculativeDecoding:
                speculativeDecodingSection
            case .benchmark:
                benchmarkSection
            case .maintenance:
                Section {
                    resetActionsContent
                }
            case .files:
                filesSection
            }
        }
    }

    // The context control owns a local draft value so dragging the
    // slider re-renders only itself, not this whole (very large) view.
    private var contextLengthControl: some View {
        ContextLengthControl(
            contextLength: $settings.contextLength,
            range: contextLengthSliderRange,
            format: model.format,
            sizeBytes: Int64(model.sizeGB * 1_073_741_824.0),
            layerCount: layerCount > 0 ? layerCount : nil,
            moeInfo: effectiveMoEInfo,
            supportedMaxContextLength: supportedMaxContextLength,
            kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings),
            draftEstimateInput: resolvedDraftEstimateInput,
            attachWalkthroughHighlight: walkthrough.isActive
        )
    }

    /// The configured helper draft model resolved to its memory-estimate inputs,
    /// so the context control can show a combined (target + draft) RAM estimate.
    private var resolvedDraftEstimateInput: ContextLengthControl.DraftEstimateInput? {
        guard settings.speculativeDecoding.selection == .helperDraftModel,
              let id = settings.speculativeDecoding.helperModelID,
              let draft = modelManager.downloadedModels.first(where: { $0.id == id }) else { return nil }
        return ContextLengthControl.DraftEstimateInput(
            format: draft.format,
            sizeBytes: Int64(draft.sizeGB * 1_073_741_824.0),
            layerCount: draft.totalLayers > 0 ? draft.totalLayers : nil,
            moeInfo: draft.moeInfo
        )
    }

    private var favoriteToggle: some View {
        Toggle("Favorite Model", isOn: Binding(
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
        ))
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
                .buttonStyle(.bordered)
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
        Section(LocalizedStringKey("Provenance")) {
            provenanceSectionContent
        }
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
                .buttonStyle(.bordered)
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
        Section(LocalizedStringKey("Chat Template Preview")) {
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
            Text(LocalizedStringKey("System Prompt"))
                .font(FontTheme.subheadline)
                .foregroundStyle(AppTheme.text)

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
                Text(LocalizedStringKey("Runtime Presets"))
                    .font(FontTheme.subheadline)
                    .foregroundStyle(AppTheme.text)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(runtimePresets) { preset in
                        let isActive = selectedCustomPresetID == nil && !runtimeConfigIsCustom && selectedRuntimePreset == preset
                        Button {
#if canImport(UIKit) && !os(visionOS)
                            Haptics.impact(.light)
#endif
                            selectedCustomPresetID = nil
                            selectedRuntimePreset = preset
                            applyRuntimePreset(preset)
                        } label: {
                            presetCard(
                                systemImage: preset.systemImage,
                                title: Text(preset.titleKey),
                                subtitle: Text(preset.subtitleKey),
                                isActive: isActive
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }

                    ForEach(customRuntimePresets) { preset in
                        let isActive = selectedCustomPresetID == preset.id && !runtimeConfigIsCustom
                        Button {
#if canImport(UIKit) && !os(visionOS)
                            Haptics.impact(.light)
#endif
                            applyCustomPreset(preset)
                        } label: {
                            presetCard(
                                systemImage: "bookmark.fill",
                                title: Text(verbatim: preset.name),
                                subtitle: Text(LocalizedStringKey("Saved preset")),
                                isActive: isActive
                            )
                        }
                        .buttonStyle(.plain)
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

                Button {
#if canImport(UIKit) && !os(visionOS)
                    Haptics.impact(.light)
#endif
                    newPresetName = ""
                    showingSavePresetAlert = true
                } label: {
                    Label(LocalizedStringKey("Save current settings as a preset"), systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

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

    /// Shared card chrome for both built-in and user-saved preset buttons.
    @ViewBuilder
    private func presetCard(systemImage: String, title: Text, subtitle: Text, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : AppTheme.text)
            title
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            subtitle
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.14) : AppTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.45) : AppTheme.cardStroke, lineWidth: 1)
        )
    }

    /// True once the live runtime fingerprint drifts from the snapshot taken when
    /// a preset was applied — i.e. the user hand-tuned an individual control.
    private var runtimeConfigIsCustom: Bool {
        !appliedRuntimeFingerprint.isEmpty && runtimeConfigFingerprint != appliedRuntimeFingerprint
    }

    /// Hashable signature of the runtime-relevant settings the presets control.
    private var runtimeConfigFingerprint: String {
        "\(Int(settings.contextLength))|\(settings.kCacheQuant.rawValue)|\(settings.vCacheQuant.rawValue)|\(settings.flashAttention)|\(settings.keepInMemory)|\(settings.kvCacheOffload)|\(settings.cpuThreads)|\(settings.promptCacheEnabled)"
    }

    /// The user-saved preset currently selected, if any.
    private var activeCustomPreset: CustomRuntimePreset? {
        guard let id = selectedCustomPresetID else { return nil }
        return customRuntimePresets.first { $0.id == id }
    }

    /// Compact line beneath the preset grid describing what the active preset
    /// changes, or a "Custom" state once the user hand-tunes a control. Keeps the
    /// runtime behaviour explained without cluttering each preset card.
    @ViewBuilder
    private var runtimePresetSummary: some View {
        let summaryIcon: String = {
            if runtimeConfigIsCustom { return "slider.horizontal.3" }
            if activeCustomPreset != nil { return "bookmark.fill" }
            return selectedRuntimePreset.systemImage
        }()
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: summaryIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if runtimeConfigIsCustom {
                    Text(LocalizedStringKey("Custom"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(LocalizedStringKey("Manual settings that don't match a preset. Tap a preset above to start from a known baseline."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let custom = activeCustomPreset {
                    Text(verbatim: custom.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(LocalizedStringKey("Your saved preset. Long-press it above to delete."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(selectedRuntimePreset.titleKey)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(selectedRuntimePreset.detailKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .animation(.easeInOut(duration: 0.2), value: runtimeConfigIsCustom)
    }

    private var runtimePresets: [ModelRuntimePreset] {
        ModelRuntimePreset.allCases.filter { preset in
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
        } else {
            Button("Delete Model", role: .destructive) {
#if canImport(UIKit) && !os(visionOS)
                Haptics.impact(.medium)
#endif
                showDeleteConfirm = true
            }
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        Section("Files") {
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

    @ViewBuilder
    private var ggufSettings: some View {
        Section("GGUF") {
            ggufSettingsContent
        }
    }

    @ViewBuilder
    private var ggufSettingsContent: some View {
        Toggle("Keep Model In Memory", isOn: $settings.keepInMemory)
        if scanning {
            VStack(alignment: .leading) { ProgressView() }
        } else if DeviceGPUInfo.supportsGPUOffload {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("GPU Offload Layers"))
                        .font(FontTheme.subheadline)
                        .foregroundStyle(AppTheme.text)
                    Slider(
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
                        in: 0...Double(layerCount + 1),
                        step: 1
                    )
                }
                let offloadValue = settings.gpuLayers < 0 ? String(localized: "All") : "\(settings.gpuLayers)"
                let layerCountLabel = "\(layerCount)"
                Text(String.localizedStringWithFormat(
                    String(localized: "GPU Offload Layers: %@/%@"),
                    offloadValue,
                    layerCountLabel
                ))
                    .font(.footnote.monospacedDigit())
            }
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
            Stepper(
                String.localizedStringWithFormat(String(localized: "CPU Threads: %@"), "\(settings.cpuThreads)"),
                value: $settings.cpuThreads,
                in: 1...ModelSettings.maxInferenceThreadCount
            )
            if DeviceGPUInfo.supportsGPUOffload {
                Toggle("Offload KV Cache to GPU", isOn: $settings.kvCacheOffload)
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

            Toggle("Flash Attention", isOn: $settings.flashAttention)

            if settings.flashAttention {
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
            }
        }
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Experts Per Token")
                            .font(.subheadline.weight(.semibold))
                        Slider(
                            value: Binding<Double>(
                                get: { Double(resolvedActiveExperts(for: info)) },
                                set: { newValue in
                                    let resolved = min(max(1, Int(newValue.rounded())), totalExperts)
                                    settings.moeActiveExperts = resolved
                                }
                            ),
                            in: 1...Double(totalExperts),
                            step: 1
                        )
                    }
                }
                Text("Active experts per token: \(currentValue) of \(totalExperts)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    @ViewBuilder
    private var samplingSection: some View {
        Section(LocalizedStringKey("Sampling")) {
            samplingSectionContent
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("Temperature"))
                        .font(.subheadline.weight(.semibold))
                    Slider(value: $settings.temperature, in: 0...2, step: 0.05)
                }
                Text(String(format: "%.2f", settings.temperature))
                    .font(.footnote.monospacedDigit())
                Text(LocalizedStringKey("Top-k, top-p, and repetition penalties are not available for ET runtime in this build."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("Temperature"))
                        .font(.subheadline.weight(.semibold))
                    Slider(value: $settings.temperature, in: 0...2, step: 0.05)
                }
                HStack {
                    Text(String(format: "%.2f", settings.temperature))
                        .font(.footnote.monospacedDigit())
                    Spacer()
                    Text(LocalizedStringKey("Low = focused. High = varied."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("Top-p"))
                        .font(.subheadline.weight(.semibold))
                    Slider(value: $settings.topP, in: 0...1, step: 0.01)
                }
                Text(String(format: "%.2f", settings.topP))
                    .font(.footnote.monospacedDigit())
            }

            Stepper(value: $settings.topK, in: 1...2048, step: 1) {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Top-k: %@"),
                        NumberFormatter.localizedString(from: NSNumber(value: settings.topK), number: .decimal)
                    )
                )
            }

#if os(macOS)
            if supportsMinP {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("Min-p"))
                            .font(.subheadline.weight(.semibold))
                        Slider(value: $settings.minP, in: 0...1, step: 0.01)
                    }
                    Text(String(format: "%.2f", settings.minP))
                        .font(.footnote.monospacedDigit())
                }
            }

            VStack(alignment: .leading, spacing: 12) {
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
#endif
        }
    }

    @ViewBuilder
    private var speculativeDecodingSection: some View {
        Section("Speculative Decoding") {
            speculativeDecodingContent
        }
    }

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
        }

        if settings.speculativeDecoding.selection == .mtp {
            Stepper(value: $settings.speculativeDecoding.mtpDraftNMax, in: 1...6, step: 1) {
                Text(String.localizedStringWithFormat(String(localized: "MTP draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMax)"))
            }
            Stepper(value: $settings.speculativeDecoding.mtpDraftNMin, in: 0...6, step: 1) {
                Text(String.localizedStringWithFormat(String(localized: "MTP min draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMin)"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(String.localizedStringWithFormat(String(localized: "MTP draft probability floor: %@"), String(format: "%.2f", settings.speculativeDecoding.resolvedMTPDraftPMin)))
                Slider(value: $settings.speculativeDecoding.mtpDraftPMin, in: 0.0...1.0, step: 0.05)
                Text("Lower values let the MTP head draft more tokens before bailing (more speculation, lower per-token acceptance). 0.75 is the conservative llama.cpp default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Install another model with the same architecture and equal or smaller size to enable speculative decoding.")
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
                    Text("Draft window: \(settings.speculativeDecoding.value)")
                }
            }

            switch settings.speculativeDecoding.mode {
            case .tokens:
                Text("Draft tokens — the helper model proposes this many tokens in one batch. The target model then verifies them in a single pass and keeps the leading run it agrees with before the helper drafts the next batch. Higher values speculate further ahead but waste more work when a guess is rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .max:
                Text("Draft window — the furthest the helper model may run ahead of the target. The two models work in parallel up to this many tokens, so a larger window allows more overlap but discards more work when the target rejects a draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        MtpLocator.hasMtpFile(alongside: resolvedModel.url) || GGUFMetadata.hasMTP(at: resolvedModel.url)
    }

    private var speculativeDraftCandidates: [LocalModel] {
        let base = resolvedModel
        return modelManager.downloadedModels.filter { candidate in
            guard candidate.id != base.id else { return false }
            guard candidate.matchesArchitectureFamily(of: base) else { return false }
            let baseSize = base.sizeGB
            let candidateSize = candidate.sizeGB
            if baseSize > 0, candidateSize > 0, candidateSize - baseSize > 0.01 {
                return false
            }
            return true
        }
    }

    @ViewBuilder
    private var nonGGUFSettings: some View {
        Section(model.format.displayName) {
            if model.format == .et {
                etSettingsContent
            } else if model.format == .ane {
                aneSettingsContent
            } else {
                // AFM is handled separately (Private Cloud Compute, shown near the top).
                mlxSettingsContent
            }
        }
    }

    @ViewBuilder
    private var mlxSettingsContent: some View {
        Text("GPU off-load is not supported for this model.")
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
    private var afmSettingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey("Choose how this model uses Apple's Private Cloud Compute."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(LocalizedStringKey("Private Cloud Compute"), selection: $settings.afmPrivateCloudComputeMode) {
                ForEach(AFMPrivateCloudComputeMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(LocalizedStringKey("Private Cloud Compute"))

            Text(LocalizedStringKey(settings.afmPrivateCloudComputeMode.detailKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var benchmarkSection: some View {
        Section("Benchmark") {
            benchmarkSectionContent
        }
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
                    runBenchmark()
                } label: {
                    HStack {
                        Image(systemName: "speedometer")
                        Text(benchmarking ? "Benchmarking…" : "Run Benchmark")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(benchmarking || ramGuardActive)

                if ramGuardActive {
                    Text("This configuration exceeds the current RAM safety guard, so benchmarking is disabled.")
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
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
        case .mlx, .et, .ane, .afm, .coreai:
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

            // Hide optimization details entirely for MLX benchmarks.
            if format != .mlx {
                VStack(alignment: .leading, spacing: 8) {
                    optimizationSection
                }
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
        switch preset {
        case .batterySaver:
            settings.cpuThreads = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
            settings.keepInMemory = false
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            settings.flashAttention = false
            // Flexible: don't hard-cap small models on roomy devices at 4K.
            settings.contextLength = Double(presetContext(upTo: batterySaverContextTarget(), preferSafe: true))
            if model.format == .gguf {
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
        "\(Int(preset.contextLength))|\(preset.kCacheQuant.rawValue)|\(preset.vCacheQuant.rawValue)|\(preset.flashAttention)|\(preset.keepInMemory)|\(preset.kvCacheOffload)|\(preset.cpuThreads)|\(preset.promptCacheEnabled)"
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
        settings.cpuThreads = preset.cpuThreads
        settings.keepInMemory = preset.keepInMemory
        settings.kvCacheOffload = preset.kvCacheOffload
        settings.promptCacheEnabled = preset.promptCacheEnabled
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
                kvCacheEstimate: estimate
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
            kvCacheEstimate: estimate
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
            kvCacheEstimate: kvCacheEstimate
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
            kvCacheEstimate: kvCacheEstimate
        )
    }

    func runBenchmark() {
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
                    vm: vm
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
