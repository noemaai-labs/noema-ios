import SwiftUI
import NoemaPackages

struct LoopbackRemediationSummaryContent: View {
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    let openRemediation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: hasIssue ? "wrench.adjustable.fill" : "wrench.adjustable")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(hasIssue ? Color.orange : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Runtime Fixes"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openRemediation) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Runtime Fixes"))
            }

            HStack(spacing: 8) {
                RuntimeFixPill(title: LocalizedStringKey("Issue"), value: hasIssue ? String(localized: "Yes") : String(localized: "No"))
                RuntimeFixPill(title: LocalizedStringKey("Model"), value: activeLocalModel == nil ? String(localized: "None") : String(localized: "Loaded"))
                RuntimeFixPill(title: LocalizedStringKey("Fixes"), value: "\(fixCount)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openRemediation)
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var hasIssue: Bool {
        chatVM.loadError?.isEmpty == false || LlamaServerBridge.lastStartDiagnostics()?.httpReady == false
    }

    private var fixCount: Int {
        guard let model = activeLocalModel else { return 0 }
        return LoopbackRemediationPlanner.plan(
            model: model,
            settings: modelManager.displaySettings(for: model),
            loadError: chatVM.loadError,
            diagnostics: LlamaServerBridge.lastStartDiagnostics()
        ).actions.count
    }

    private var summaryLine: String {
        if hasIssue {
            return String(localized: "Review safe setting changes for the last loopback failure")
        }
        if activeLocalModel == nil {
            return String(localized: "Load a local model to see recovery options")
        }
        return String(localized: "Prepare lower-risk settings before the next load")
    }
}

struct LoopbackRemediationView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var applyMessage: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Failure Snapshot")) {
                RuntimeFixValueRow(title: LocalizedStringKey("Current Model"), value: activeModel?.name ?? String(localized: "No local model loaded"))
                RuntimeFixValueRow(title: LocalizedStringKey("Load Error"), value: loadErrorValue)
                RuntimeFixValueRow(title: LocalizedStringKey("Start Diagnostic"), value: startDiagnosticValue)
                RuntimeFixValueRow(title: LocalizedStringKey("Current Context"), value: currentContextValue)
                RuntimeFixValueRow(title: LocalizedStringKey("Estimated Working Set"), value: workingSetValue)
            }

            Section(LocalizedStringKey("Recommended Fixes")) {
                if remediationPlan.actions.isEmpty {
                    Text(LocalizedStringKey("No automatic fixes are available for the current state."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remediationPlan.actions) { action in
                        RuntimeFixActionRow(action: action) {
                            apply(action)
                        }
                    }
                }

                if let applyMessage {
                    Text(verbatim: applyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Manual Checklist")) {
                ForEach(remediationPlan.checklist) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .foregroundStyle(item.tint)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Runtime Fixes"))
    }

    private var activeModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var activeSettings: ModelSettings? {
        activeModel.map { modelManager.displaySettings(for: $0) }
    }

    private var remediationPlan: LoopbackRemediationPlan {
        guard let model = activeModel, let settings = activeSettings else {
            return LoopbackRemediationPlan(actions: [], checklist: [
                RuntimeFixChecklistItem(title: LocalizedStringKey("Load or select a local model first."), systemImage: "shippingbox", tint: .secondary)
            ])
        }
        return LoopbackRemediationPlanner.plan(
            model: model,
            settings: settings,
            loadError: chatVM.loadError,
            diagnostics: LlamaServerBridge.lastStartDiagnostics()
        )
    }

    private var loadErrorValue: String {
        guard let error = chatVM.loadError, !error.isEmpty else {
            return String(localized: "No load error recorded")
        }
        return error
    }

    private var startDiagnosticValue: String {
        guard let diagnostics = LlamaServerBridge.lastStartDiagnostics() else {
            return String(localized: "No start diagnostics recorded")
        }
        return "\(diagnostics.code) · \(diagnostics.message)"
    }

    private var currentContextValue: String {
        guard let settings = activeSettings else { return "--" }
        return String.localizedStringWithFormat(String(localized: "%d tokens"), Int(settings.contextLength))
    }

    private var workingSetValue: String {
        guard let model = activeModel, let settings = activeSettings else {
            return String(localized: "Unavailable")
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: model.url.path)[.size]) as? Int64 else {
            return String(localized: "Unavailable")
        }
        let estimate = ModelRAMAdvisor.estimateAndBudget(
            format: model.format,
            sizeBytes: size,
            contextLength: Int(settings.contextLength),
            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
            moeInfo: model.moeInfo,
            kvCacheEstimate: model.format == .gguf ? .resolved(from: settings) : .f16F16
        )
        let budget = estimate.budget.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "--"
        return "\(ByteCountFormatter.string(fromByteCount: estimate.estimate, countStyle: .memory)) / \(budget)"
    }

    private func apply(_ action: RuntimeFixAction) {
        guard let model = activeModel else { return }
        var settings = modelManager.displaySettings(for: model)
        action.apply(&settings)
        modelManager.updateSettings(settings, for: model)
        applyMessage = String.localizedStringWithFormat(String(localized: "Applied: %@"), action.titleText)
    }
}

private struct LoopbackRemediationPlan {
    let actions: [RuntimeFixAction]
    let checklist: [RuntimeFixChecklistItem]
}

private enum LoopbackRemediationPlanner {
    static func plan(
        model: LocalModel,
        settings: ModelSettings,
        loadError: String?,
        diagnostics: LlamaServerBridge.StartDiagnostics?
    ) -> LoopbackRemediationPlan {
        var actions: [RuntimeFixAction] = []
        var checklist: [RuntimeFixChecklistItem] = []
        let lowercasedError = (loadError ?? diagnostics?.message ?? "").lowercased()
        let probablyMemory = lowercasedError.contains("memory") ||
            lowercasedError.contains("alloc") ||
            lowercasedError.contains("oom") ||
            lowercasedError.contains("failed to load")

        if let safeContext = safeContext(for: model, settings: settings),
           safeContext < Int(settings.contextLength) {
            actions.append(RuntimeFixAction(
                title: LocalizedStringKey("Use Safe Context"),
                titleText: String(localized: "Use Safe Context"),
                detail: String.localizedStringWithFormat(String(localized: "Set context to %d tokens."), safeContext),
                systemImage: "arrow.down.forward.circle",
                tint: .green,
                apply: { $0.contextLength = Double(max(512, safeContext)) }
            ))
        }

        if settings.contextLength > 1024 {
            let reduced = max(512, Int(settings.contextLength / 2.0))
            actions.append(RuntimeFixAction(
                title: LocalizedStringKey("Halve Context"),
                titleText: String(localized: "Halve Context"),
                detail: String.localizedStringWithFormat(String(localized: "Reduce context to %d tokens for the next load."), reduced),
                systemImage: "rectangle.compress.vertical",
                tint: .orange,
                apply: { $0.contextLength = Double(reduced) }
            ))
        }

        if settings.flashAttention {
            actions.append(RuntimeFixAction(
                title: LocalizedStringKey("Disable Flash Attention"),
                titleText: String(localized: "Disable Flash Attention"),
                detail: String(localized: "Use the safer attention path for the next load."),
                systemImage: "bolt.slash",
                tint: .orange,
                apply: { $0.flashAttention = false }
            ))
        }

        if settings.kvCacheOffload {
            actions.append(RuntimeFixAction(
                title: LocalizedStringKey("Disable KV Offload"),
                titleText: String(localized: "Disable KV Offload"),
                detail: String(localized: "Keep KV cache on CPU if GPU memory is unstable."),
                systemImage: "externaldrive.badge.xmark",
                tint: .orange,
                apply: { $0.kvCacheOffload = false }
            ))
        }

        if settings.kCacheQuant != .f16 || settings.vCacheQuant != .f16 {
            actions.append(RuntimeFixAction(
                title: LocalizedStringKey("Reset KV Quantization"),
                titleText: String(localized: "Reset KV Quantization"),
                detail: String(localized: "Return K/V cache quantization to F16."),
                systemImage: "arrow.counterclockwise.circle",
                tint: .blue,
                apply: {
                    $0.kCacheQuant = .f16
                    $0.vCacheQuant = .f16
                }
            ))
        }

        if probablyMemory {
            checklist.append(RuntimeFixChecklistItem(
                title: LocalizedStringKey("Memory pressure detected; apply a smaller context before retrying."),
                systemImage: "memorychip",
                tint: .orange
            ))
        }
        checklist.append(RuntimeFixChecklistItem(
            title: LocalizedStringKey("After applying a fix, unload and load the model again."),
            systemImage: "arrow.triangle.2.circlepath",
            tint: .secondary
        ))
        checklist.append(RuntimeFixChecklistItem(
            title: LocalizedStringKey("If health still fails, open Loopback Health and export diagnostics."),
            systemImage: "server.rack",
            tint: .secondary
        ))

        return LoopbackRemediationPlan(actions: actions, checklist: checklist)
    }

    private static func safeContext(for model: LocalModel, settings: ModelSettings) -> Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: model.url.path)[.size]) as? Int64 else {
            return nil
        }
        return ModelRAMAdvisor.maxContextUnderBudget(
            format: model.format,
            sizeBytes: size,
            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
            moeInfo: model.moeInfo,
            upperBound: GGUFMetadata.contextLength(at: model.url),
            kvCacheEstimate: model.format == .gguf ? .resolved(from: settings) : .f16F16
        )
    }
}

private struct RuntimeFixAction: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let titleText: String
    let detail: String
    let systemImage: String
    let tint: Color
    let apply: (inout ModelSettings) -> Void
}

private struct RuntimeFixChecklistItem: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
}

private struct RuntimeFixPill: View {
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
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct RuntimeFixActionRow: View {
    let action: RuntimeFixAction
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(action.title, systemImage: action.systemImage)
                .font(.headline)
                .foregroundStyle(action.tint)
            Text(verbatim: action.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: apply) {
                Label(LocalizedStringKey("Apply Fix"), systemImage: "checkmark.circle")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RuntimeFixValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
