import SwiftUI

@MainActor
struct ModelAutoTunerSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openAutoTuner: () -> Void

    private var snapshot: ModelAutoTunerSnapshot {
        ModelAutoTunerSnapshot(models: modelManager.downloadedModels, modelManager: modelManager, objective: .balanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(snapshot.tunableCount > 0 ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Auto-Tuner"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openAutoTuner) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Auto-Tuner"))
            }

            HStack(spacing: 8) {
                ModelAutoTunerCapsule(title: LocalizedStringKey("Tunable"), value: "\(snapshot.tunableCount)")
                ModelAutoTunerCapsule(title: LocalizedStringKey("Safe Plans"), value: "\(snapshot.safePlansCount)")
                ModelAutoTunerCapsule(title: LocalizedStringKey("Benchmarked"), value: "\(snapshot.benchmarkedCount)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openAutoTuner)
    }

    private var summaryLine: String {
        if snapshot.models.isEmpty {
            return String(localized: "Install local models to generate runtime tuning plans.")
        }
        if snapshot.safePlansCount == snapshot.tunableCount {
            return String(localized: "Every tunable model has a safe runtime plan.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%d models need review before applying runtime plans."),
            snapshot.reviewCount
        )
    }
}

@MainActor
struct ModelAutoTunerView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var objective: ModelAutoTuneObjective = .balanced
    @State private var appliedNotice: String?

    private var snapshot: ModelAutoTunerSnapshot {
        ModelAutoTunerSnapshot(models: modelManager.downloadedModels, modelManager: modelManager, objective: objective)
    }

    var body: some View {
        Form {
            if modelManager.downloadedModels.isEmpty {
                Section(LocalizedStringKey("Auto-Tuner")) {
                    Label(LocalizedStringKey("No local models installed"), systemImage: "tray")
                    Text(LocalizedStringKey("Install local models to generate runtime tuning plans."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                objectiveSection
                overviewSection
                plansSection
                bulkActionsSection
            }
        }
        .navigationTitle(LocalizedStringKey("Auto-Tuner"))
    }

    private var objectiveSection: some View {
        Section(LocalizedStringKey("Tuning Objective")) {
            Picker(LocalizedStringKey("Tuning Objective"), selection: $objective) {
                ForEach(ModelAutoTuneObjective.allCases) { option in
                    Text(option.titleKey).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(objective.descriptionKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var overviewSection: some View {
        Section(LocalizedStringKey("Auto-Tune Overview")) {
            ModelAutoTunerValueRow(title: LocalizedStringKey("Installed Models"), value: "\(snapshot.models.count)")
            ModelAutoTunerValueRow(title: LocalizedStringKey("Tunable Models"), value: "\(snapshot.tunableCount)")
            ModelAutoTunerValueRow(title: LocalizedStringKey("Safe Runtime Plans"), value: "\(snapshot.safePlansCount)")
            ModelAutoTunerValueRow(title: LocalizedStringKey("Need Review"), value: "\(snapshot.reviewCount)")
            ModelAutoTunerValueRow(title: LocalizedStringKey("Measured Results"), value: "\(snapshot.benchmarkedCount)")
        }
    }

    private var plansSection: some View {
        Section(LocalizedStringKey("Runtime Plans")) {
            ForEach(snapshot.plans) { plan in
                ModelAutoTunePlanRow(plan: plan) {
                    apply(plan)
                }
            }
        }
    }

    private var bulkActionsSection: some View {
        Section(LocalizedStringKey("Bulk Actions")) {
            Button {
                applySafePlans()
            } label: {
                Label(LocalizedStringKey("Apply Safe Runtime Plans"), systemImage: "checkmark.seal")
            }
            .disabled(snapshot.safeApplicablePlans.isEmpty)

            if let appliedNotice {
                Text(verbatim: appliedNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(LocalizedStringKey("Auto-Tuner changes saved model settings only. It does not load or unload models. Run benchmarks afterward to replace estimates with measured data."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func apply(_ plan: ModelAutoTunePlan) {
        modelManager.updateSettings(plan.recommendedSettings, for: plan.model)
        appliedNotice = String.localizedStringWithFormat(
            String(localized: "Applied runtime plan for %@."),
            plan.model.name
        )
    }

    private func applySafePlans() {
        let plans = snapshot.safeApplicablePlans
        for plan in plans {
            modelManager.updateSettings(plan.recommendedSettings, for: plan.model)
        }
        appliedNotice = String.localizedStringWithFormat(
            String(localized: "Applied %d safe runtime plans."),
            plans.count
        )
    }
}

private enum ModelAutoTuneObjective: String, CaseIterable, Identifiable {
    case balanced
    case battery
    case speed
    case context

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .balanced: return "Balanced"
        case .battery: return "Battery"
        case .speed: return "Speed"
        case .context: return "Context"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .balanced:
            return "Balanced tuning favors stable memory use with enough context for everyday chat."
        case .battery:
            return "Battery tuning lowers threads, context, and warm residency for cooler runs."
        case .speed:
            return "Speed tuning favors GPU offload, warm loads, Flash Attention, and low first-token latency."
        case .context:
            return "Context tuning maximizes safe context while using compact KV cache settings for GGUF models."
        }
    }
}

@MainActor
private struct ModelAutoTunerSnapshot {
    let models: [LocalModel]
    let plans: [ModelAutoTunePlan]

    init(models: [LocalModel], modelManager: AppModelManager, objective: ModelAutoTuneObjective) {
        self.models = models.sorted { $0.name < $1.name }
        self.plans = self.models.compactMap { model in
            ModelAutoTunePlan.make(model: model, modelManager: modelManager, objective: objective)
        }
    }

    var tunableCount: Int { plans.count }
    var safePlansCount: Int { plans.filter(\.fitsBudget).count }
    var reviewCount: Int { max(0, tunableCount - safePlansCount) }
    var benchmarkedCount: Int { plans.filter { $0.benchmarkResult != nil }.count }

    var safeApplicablePlans: [ModelAutoTunePlan] {
        plans.filter { $0.fitsBudget && $0.hasChanges }
    }
}

@MainActor
private struct ModelAutoTunePlan: Identifiable {
    let model: LocalModel
    let currentSettings: ModelSettings
    let recommendedSettings: ModelSettings
    let estimateBytes: Int64
    let budgetBytes: Int64?
    let safeContext: Int?
    let objective: ModelAutoTuneObjective
    let benchmarkResult: ModelBenchmarkResult?

    var id: String { model.id }
    var hasChanges: Bool { currentSettings != recommendedSettings }

    var fitsBudget: Bool {
        guard let budgetBytes else { return true }
        return estimateBytes <= budgetBytes
    }

    var statusColor: Color {
        fitsBudget ? .green : .orange
    }

    var statusIcon: String {
        fitsBudget ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    var statusText: String {
        if fitsBudget { return String(localized: "Safe to apply") }
        return String(localized: "Review memory budget")
    }

    var benchmarkText: String {
        guard let benchmarkResult else {
            return String(localized: "No benchmark yet")
        }
        return String.localizedStringWithFormat(
            String(localized: "%.1f tok/s measured"),
            benchmarkResult.generationRate
        )
    }

    var detailText: String {
        let context = NumberFormatter.localizedString(from: NSNumber(value: Int(recommendedSettings.contextLength)), number: .decimal)
        let estimate = ByteCountFormatter.string(fromByteCount: estimateBytes, countStyle: .memory)
        let budget = budgetBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? String(localized: "No budget")
        return String.localizedStringWithFormat(
            String(localized: "Context %@ · Estimate %@ · Budget %@"),
            context,
            estimate,
            budget
        )
    }

    static func make(model: LocalModel, modelManager: AppModelManager, objective: ModelAutoTuneObjective) -> ModelAutoTunePlan? {
        guard model.format != .ane && model.format != .afm else { return nil }
        let current = modelManager.displaySettings(for: model)
        let recommended = recommendedSettings(for: model, current: current, objective: objective)
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        let layerHint = layerCount(for: model)
        let kvEstimate = model.format == .gguf ? ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: recommended) : .f16F16
        let estimate = ModelRAMAdvisor.estimateAndBudget(
            format: model.format,
            sizeBytes: sizeBytes,
            contextLength: Int(recommended.contextLength),
            layerCount: layerHint,
            moeInfo: model.moeInfo,
            kvCacheEstimate: kvEstimate
        )
        let safe = ModelRAMAdvisor.maxContextUnderBudget(
            format: model.format,
            sizeBytes: sizeBytes,
            layerCount: layerHint,
            moeInfo: model.moeInfo,
            upperBound: supportedContextUpperBound(for: model),
            kvCacheEstimate: kvEstimate
        )
        return ModelAutoTunePlan(
            model: model,
            currentSettings: current,
            recommendedSettings: recommended,
            estimateBytes: estimate.estimate,
            budgetBytes: estimate.budget,
            safeContext: safe,
            objective: objective,
            benchmarkResult: ModelBenchmarkResultStore.result(for: model)?.result
        )
    }

    private static func recommendedSettings(for model: LocalModel, current: ModelSettings, objective: ModelAutoTuneObjective) -> ModelSettings {
        var settings = current
        let activeThreads = ProcessInfo.processInfo.activeProcessorCount
        let safe = safeContext(for: model, settings: settings)
        let cap = supportedContextUpperBound(for: model)

        switch objective {
        case .balanced:
            settings.contextLength = Double(contextTarget(requested: 8_192, safe: safe, cap: cap))
            settings.cpuThreads = activeThreads
            settings.keepInMemory = true
            settings.disableWarmup = false
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            applyGGUFAcceleration(to: &settings, quantizedKV: false)
        case .battery:
            settings.contextLength = Double(contextTarget(requested: 4_096, safe: safe, cap: cap))
            settings.cpuThreads = max(1, activeThreads / 2)
            settings.keepInMemory = false
            settings.disableWarmup = true
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            if model.format == .gguf {
                settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
                settings.flashAttention = false
                settings.kCacheQuant = .q8_0
                settings.vCacheQuant = .q8_0
            }
        case .speed:
            settings.contextLength = Double(contextTarget(requested: 8_192, safe: safe, cap: cap))
            settings.cpuThreads = activeThreads
            settings.keepInMemory = true
            settings.disableWarmup = false
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            applyGGUFAcceleration(to: &settings, quantizedKV: false)
            if model.format == .gguf {
                settings.flashAttention = true
            }
        case .context:
            if model.format == .gguf {
                settings.flashAttention = true
                settings.kCacheQuant = .q8_0
                settings.vCacheQuant = .q8_0
            }
            let contextSafe = safeContext(for: model, settings: settings)
            settings.contextLength = Double(contextTarget(requested: min(cap, 65_536), safe: contextSafe, cap: cap))
            settings.cpuThreads = activeThreads
            settings.keepInMemory = true
            settings.disableWarmup = false
            settings.kvCacheOffload = DeviceGPUInfo.supportsGPUOffload
            applyGGUFAcceleration(to: &settings, quantizedKV: true)
        }

        if model.format != .gguf {
            settings.gpuLayers = 0
            settings.kvCacheOffload = false
            settings.flashAttention = false
        }

        return settings.normalizedForLocalModel(model)
    }

    private static func applyGGUFAcceleration(to settings: inout ModelSettings, quantizedKV: Bool) {
        settings.gpuLayers = DeviceGPUInfo.supportsGPUOffload ? -1 : 0
        guard quantizedKV else {
            settings.kCacheQuant = .f16
            settings.vCacheQuant = .f16
            return
        }
        settings.kCacheQuant = .q8_0
        settings.vCacheQuant = .q8_0
    }

    private static func contextTarget(requested: Int, safe: Int?, cap: Int) -> Int {
        let upper = max(512, cap)
        let requested = max(512, min(requested, upper))
        guard let safe else { return requested }
        return max(512, min(requested, safe, upper))
    }

    private static func safeContext(for model: LocalModel, settings: ModelSettings) -> Int? {
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        return ModelRAMAdvisor.maxContextUnderBudget(
            format: model.format,
            sizeBytes: sizeBytes,
            layerCount: layerCount(for: model),
            moeInfo: model.moeInfo,
            upperBound: supportedContextUpperBound(for: model),
            kvCacheEstimate: model.format == .gguf ? .resolved(from: settings) : .f16F16
        )
    }

    private static func supportedContextUpperBound(for model: LocalModel) -> Int {
        switch model.format {
        case .gguf:
            return GGUFMetadata.contextLength(at: model.url) ?? 131_072
        case .mlx:
            return 65_536
        case .et:
            return 8_192
        case .ane, .afm, .coreai:
            return 4_096
        }
    }

    private static func layerCount(for model: LocalModel) -> Int? {
        if model.totalLayers > 0 { return model.totalLayers }
        if model.format == .gguf { return GGUFMetadata.layerCount(at: model.url) }
        return nil
    }
}

@MainActor
private struct ModelAutoTunePlanRow: View {
    let plan: ModelAutoTunePlan
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: plan.statusIcon)
                    .foregroundStyle(plan.statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: plan.model.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(verbatim: "\(plan.model.format.displayName) · \(plan.model.quant)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: plan.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(plan.statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Text(verbatim: plan.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                smallMetric(LocalizedStringKey("Threads"), "\(plan.recommendedSettings.cpuThreads)")
                smallMetric(LocalizedStringKey("GPU"), gpuValue)
                smallMetric(LocalizedStringKey("Benchmark"), plan.benchmarkText)
            }

            Button {
                apply()
            } label: {
                Label(LocalizedStringKey("Apply Runtime Plan"), systemImage: "slider.horizontal.3")
            }
            .disabled(!plan.fitsBudget || !plan.hasChanges)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var gpuValue: String {
        if plan.model.format != .gguf { return String(localized: "Off") }
        if plan.recommendedSettings.gpuLayers < 0 { return String(localized: "Auto") }
        if plan.recommendedSettings.gpuLayers == 0 { return String(localized: "CPU") }
        return "\(plan.recommendedSettings.gpuLayers)"
    }

    private func smallMetric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ModelAutoTunerCapsule: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct ModelAutoTunerValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
