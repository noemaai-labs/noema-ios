import SwiftUI
import NoemaPackages

struct ModelLoadReceiptSummaryContent: View {
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    let openReceipt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: receiptAvailable ? "doc.text.magnifyingglass" : "doc.text")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(receiptAvailable ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Load Receipt"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openReceipt) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Load Receipt"))
            }

            HStack(spacing: 8) {
                LoadReceiptPill(title: LocalizedStringKey("Model"), value: modelPillValue)
                LoadReceiptPill(title: LocalizedStringKey("Template"), value: templatePillValue)
                LoadReceiptPill(title: LocalizedStringKey("Ready"), value: readinessPillValue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openReceipt)
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var receiptAvailable: Bool {
        activeLocalModel != nil || LlamaServerBridge.lastStartOptions() != nil || modelManager.activeRemoteSession != nil
    }

    private var summaryLine: String {
        if let model = activeLocalModel {
            return String.localizedStringWithFormat(String(localized: "%@ load settings and bridge arguments"), model.name)
        }
        if let remote = modelManager.activeRemoteSession {
            return String.localizedStringWithFormat(String(localized: "%@ remote session receipt"), remote.modelName)
        }
        if LlamaServerBridge.lastStartOptions() != nil {
            return String(localized: "Last loopback start options are available")
        }
        return String(localized: "No model load has been recorded")
    }

    private var modelPillValue: String {
        if activeLocalModel != nil { return String(localized: "Loaded") }
        if modelManager.activeRemoteSession != nil { return String(localized: "Remote") }
        return String(localized: "None")
    }

    private var templatePillValue: String {
        chatVM.promptTemplateSourceLabel.isEmpty ? String(localized: "Default") : chatVM.promptTemplateSourceLabel
    }

    private var readinessPillValue: String {
        if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
            return diagnostics.httpReady ? String(localized: "Ready") : String(localized: "Failed")
        }
        return chatVM.hasActiveChatModel ? String(localized: "Active") : String(localized: "Unknown")
    }
}

struct ModelLoadReceiptView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var checkedAt = Date()
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Receipt Summary")) {
                LoadReceiptStatusRow(
                    title: LocalizedStringKey("Runtime"),
                    value: runtimeValue,
                    systemImage: runtimeIcon,
                    tint: runtimeTint
                )
                LoadReceiptValueRow(title: LocalizedStringKey("Loaded Model"), value: loadedModelValue)
                LoadReceiptValueRow(title: LocalizedStringKey("Backend"), value: backendValue)
                LoadReceiptValueRow(title: LocalizedStringKey("Prompt Template"), value: promptTemplateValue)
                LoadReceiptValueRow(title: LocalizedStringKey("Readiness"), value: readinessValue)
                LoadReceiptValueRow(title: LocalizedStringKey("Generated"), value: checkedAt.formatted(date: .abbreviated, time: .standard))
            }

            if let model = activeLocalModel {
                Section(LocalizedStringKey("Local Model")) {
                    LoadReceiptValueRow(title: LocalizedStringKey("Model ID"), value: model.modelID)
                    LoadReceiptValueRow(title: LocalizedStringKey("Format"), value: model.format.displayName)
                    LoadReceiptValueRow(title: LocalizedStringKey("Quantization"), value: model.quant.isEmpty ? String(localized: "Unknown") : model.quant)
                    LoadReceiptValueRow(title: LocalizedStringKey("Architecture"), value: model.architecture.isEmpty ? String(localized: "Unknown") : model.architecture)
                    LoadReceiptValueRow(title: LocalizedStringKey("Size"), value: ByteCountFormatter.string(fromByteCount: modelSizeBytes(model), countStyle: .file))
                    LoadReceiptValueRow(title: LocalizedStringKey("File"), value: model.url.lastPathComponent)
                    LoadReceiptValueRow(title: LocalizedStringKey("Path"), value: model.url.path)
                }
            }

            if let settings = activeSettings {
                Section(LocalizedStringKey("Runtime Settings")) {
                    LoadReceiptValueRow(title: LocalizedStringKey("Context"), value: String.localizedStringWithFormat(String(localized: "%d tokens"), Int(settings.contextLength)))
                    LoadReceiptValueRow(title: LocalizedStringKey("GPU Layers"), value: gpuLayersValue(settings.gpuLayers))
                    LoadReceiptValueRow(title: LocalizedStringKey("CPU Threads"), value: settings.cpuThreads == 0 ? String(localized: "Auto") : "\(settings.cpuThreads)")
                    LoadReceiptValueRow(title: LocalizedStringKey("KV Offload"), value: settings.kvCacheOffload ? String(localized: "On") : String(localized: "Off"))
                    LoadReceiptValueRow(title: LocalizedStringKey("KV Quantization"), value: "\(settings.kCacheQuant.rawValue) / \(settings.vCacheQuant.rawValue)")
                    LoadReceiptValueRow(title: LocalizedStringKey("Flash Attention"), value: settings.flashAttention ? String(localized: "On") : String(localized: "Off"))
                    LoadReceiptValueRow(title: LocalizedStringKey("Memory Map"), value: settings.useMmap ? String(localized: "On") : String(localized: "Off"))
                    LoadReceiptValueRow(title: LocalizedStringKey("Warmup"), value: settings.disableWarmup ? String(localized: "Skipped") : String(localized: "Enabled"))
                    LoadReceiptValueRow(title: LocalizedStringKey("Prompt Cache"), value: promptCacheValue(settings))
                    LoadReceiptValueRow(title: LocalizedStringKey("Speculation"), value: speculationValue(settings))
                }

                Section(LocalizedStringKey("Memory Estimate")) {
                    LoadReceiptValueRow(title: LocalizedStringKey("Estimated Working Set"), value: workingSetValue(settings))
                    LoadReceiptValueRow(title: LocalizedStringKey("RAM Budget"), value: ramBudgetValue(settings))
                    LoadReceiptValueRow(title: LocalizedStringKey("Fit Status"), value: fitStatusValue(settings))
                }
            }

            Section(LocalizedStringKey("Loopback Start")) {
                if let options = LlamaServerBridge.lastStartOptions() {
                    LoadReceiptValueRow(title: LocalizedStringKey("Loopback Port"), value: "\(options.port)")
                    LoadReceiptValueRow(title: LocalizedStringKey("GGUF File"), value: URL(fileURLWithPath: options.ggufPath).lastPathComponent)
                    LoadReceiptValueRow(title: LocalizedStringKey("Projector File"), value: options.mmprojPath.isEmpty ? String(localized: "None") : URL(fileURLWithPath: options.mmprojPath).lastPathComponent)
                    LoadReceiptValueRow(title: LocalizedStringKey("MTP File"), value: options.mtpPath.isEmpty ? String(localized: "None") : URL(fileURLWithPath: options.mtpPath).lastPathComponent)
                    LoadReceiptValueRow(title: LocalizedStringKey("Speculative Type"), value: options.speculativeType.isEmpty ? String(localized: "Off") : options.speculativeType)
                    LoadReceiptValueRow(title: LocalizedStringKey("Draft Tokens"), value: options.specDraftNMax.map(String.init) ?? String(localized: "None"))
                    LoadReceiptValueRow(title: LocalizedStringKey("Server Arguments"), value: options.argv.joined(separator: " "))
                } else {
                    Text(LocalizedStringKey("No loopback start options recorded"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Start Diagnostics")) {
                if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
                    LoadReceiptValueRow(title: LocalizedStringKey("Code"), value: diagnostics.code)
                    LoadReceiptValueRow(title: LocalizedStringKey("Message"), value: diagnostics.message)
                    LoadReceiptValueRow(title: LocalizedStringKey("HTTP Ready"), value: diagnostics.httpReady ? String(localized: "Ready") : String(localized: "Failed"))
                    LoadReceiptValueRow(title: LocalizedStringKey("Last HTTP Status"), value: diagnostics.lastHTTPStatus.map(String.init) ?? "--")
                    LoadReceiptValueRow(title: LocalizedStringKey("Elapsed"), value: String.localizedStringWithFormat(String(localized: "%d ms"), diagnostics.elapsedMs))
                } else {
                    Text(LocalizedStringKey("No start diagnostics recorded"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Receipt Export")) {
                Button {
                    generateExport()
                } label: {
                    Label(LocalizedStringKey("Generate Receipt JSON"), systemImage: "doc.badge.gearshape")
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share Receipt JSON"), systemImage: "square.and.arrow.up")
                    }
                    LoadReceiptValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                }

                if let exportError {
                    LoadReceiptValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Load Receipt"))
        .onAppear { checkedAt = Date() }
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var activeSettings: ModelSettings? {
        if let loaded = chatVM.loadedModelSettings {
            return loaded
        }
        return activeLocalModel.map { modelManager.displaySettings(for: $0) }
    }

    private var runtimeValue: String {
        if modelManager.activeRemoteSession != nil { return String(localized: "Remote") }
        if activeLocalModel != nil { return String(localized: "Local") }
        if LlamaServerBridge.lastStartOptions() != nil { return String(localized: "Recorded") }
        return String(localized: "Unavailable")
    }

    private var runtimeIcon: String {
        switch runtimeValue {
        case String(localized: "Local"):
            return "desktopcomputer"
        case String(localized: "Remote"):
            return "network"
        case String(localized: "Recorded"):
            return "clock.arrow.circlepath"
        default:
            return "questionmark.circle"
        }
    }

    private var runtimeTint: Color {
        runtimeValue == String(localized: "Unavailable") ? .secondary : .accentColor
    }

    private var loadedModelValue: String {
        if let model = activeLocalModel { return model.name }
        if let remote = modelManager.activeRemoteSession { return remote.modelName }
        if let options = LlamaServerBridge.lastStartOptions() { return URL(fileURLWithPath: options.ggufPath).lastPathComponent }
        return String(localized: "No model loaded")
    }

    private var backendValue: String {
        if let remote = modelManager.activeRemoteSession {
            return "\(remote.backendName) · \(remote.endpointType.displayName) · \(remote.transport.label)"
        }
        if let summary = chatVM.inferenceBackendSummary, !summary.isEmpty {
            return summary
        }
        if let format = chatVM.loadedModelFormat ?? activeLocalModel?.format {
            return format.displayName
        }
        return String(localized: "Unknown")
    }

    private var promptTemplateValue: String {
        chatVM.promptTemplateSourceLabel.isEmpty ? String(localized: "Default") : chatVM.promptTemplateSourceLabel
    }

    private var readinessValue: String {
        if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
            let status = diagnostics.httpReady ? String(localized: "Ready") : String(localized: "Failed")
            return "\(status) · \(diagnostics.code)"
        }
        return chatVM.hasActiveChatModel ? String(localized: "Active") : String(localized: "Unknown")
    }

    private func modelSizeBytes(_ model: LocalModel) -> Int64 {
        if let size = (try? FileManager.default.attributesOfItem(atPath: model.url.path)[.size]) as? Int64 {
            return size
        }
        return Int64(model.sizeGB * 1_000_000_000)
    }

    private func gpuLayersValue(_ layers: Int) -> String {
        if layers < 0 { return String(localized: "Auto") }
        if layers == 0 { return String(localized: "CPU") }
        return String.localizedStringWithFormat(String(localized: "%d GPU layers"), layers)
    }

    private func promptCacheValue(_ settings: ModelSettings) -> String {
        guard settings.promptCacheEnabled else { return String(localized: "Off") }
        let path = settings.promptCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = settings.promptCacheAll ? String(localized: "All prompts") : String(localized: "System prompts")
        guard !path.isEmpty else { return mode }
        return "\(mode) · \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    private func speculationValue(_ settings: ModelSettings) -> String {
        switch settings.speculativeDecoding.selection {
        case .off:
            return String(localized: "Off")
        case .mtp:
            return String.localizedStringWithFormat(String(localized: "MTP · %d draft tokens"), settings.speculativeDecoding.resolvedMTPDraftNMax)
        case .helperDraftModel:
            return String(localized: "Helper model")
        }
    }

    private func memoryEstimate(for settings: ModelSettings) -> (estimate: Int64, budget: Int64?)? {
        guard let model = activeLocalModel else { return nil }
        return ModelRAMAdvisor.estimateAndBudget(
            format: model.format,
            sizeBytes: modelSizeBytes(model),
            contextLength: Int(settings.contextLength),
            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
            moeInfo: model.moeInfo,
            kvCacheEstimate: model.format == .gguf ? .resolved(from: settings) : .f16F16
        )
    }

    private func workingSetValue(_ settings: ModelSettings) -> String {
        guard let estimate = memoryEstimate(for: settings) else { return String(localized: "Unavailable") }
        return ByteCountFormatter.string(fromByteCount: estimate.estimate, countStyle: .memory)
    }

    private func ramBudgetValue(_ settings: ModelSettings) -> String {
        guard let budget = memoryEstimate(for: settings)?.budget else { return String(localized: "Unavailable") }
        return ByteCountFormatter.string(fromByteCount: budget, countStyle: .memory)
    }

    private func fitStatusValue(_ settings: ModelSettings) -> String {
        guard let estimate = memoryEstimate(for: settings), let budget = estimate.budget else {
            return String(localized: "Unknown")
        }
        return estimate.estimate <= budget ? String(localized: "Fits budget") : String(localized: "Exceeds budget")
    }

    private func generateExport() {
        do {
            let data = try JSONSerialization.data(withJSONObject: exportPayload(), options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-load-receipt-\(Self.fileTimestamp()).json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func exportPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "checkedAt": ISO8601DateFormatter().string(from: checkedAt),
            "runtime": runtimeValue,
            "loadedModel": loadedModelValue,
            "backend": backendValue,
            "promptTemplate": promptTemplateValue,
            "readiness": readinessValue
        ]

        if let model = activeLocalModel {
            payload["localModel"] = [
                "name": model.name,
                "modelID": model.modelID,
                "format": model.format.displayName,
                "quant": model.quant,
                "architecture": model.architecture,
                "sizeBytes": modelSizeBytes(model),
                "file": model.url.lastPathComponent,
                "path": model.url.path
            ]
        }

        if let settings = activeSettings {
            payload["settings"] = [
                "contextLength": Int(settings.contextLength),
                "gpuLayers": settings.gpuLayers,
                "cpuThreads": settings.cpuThreads,
                "kvCacheOffload": settings.kvCacheOffload,
                "kCacheQuant": settings.kCacheQuant.rawValue,
                "vCacheQuant": settings.vCacheQuant.rawValue,
                "flashAttention": settings.flashAttention,
                "useMmap": settings.useMmap,
                "disableWarmup": settings.disableWarmup,
                "promptCacheEnabled": settings.promptCacheEnabled,
                "promptCachePath": settings.promptCachePath,
                "promptCacheAll": settings.promptCacheAll,
                "speculation": settings.speculativeDecoding.selection.rawValue,
                "mtpDraftNMax": settings.speculativeDecoding.resolvedMTPDraftNMax
            ]
            if let estimate = memoryEstimate(for: settings) {
                let fitsBudget = estimate.budget.map { estimate.estimate <= $0 } ?? false
                payload["memoryEstimate"] = [
                    "estimateBytes": estimate.estimate,
                    "budgetBytes": estimate.budget ?? 0,
                    "fitsBudget": fitsBudget
                ]
            }
        }

        if let options = LlamaServerBridge.lastStartOptions() {
            payload["loopbackStart"] = [
                "port": options.port,
                "ggufPath": options.ggufPath,
                "mmprojPath": options.mmprojPath,
                "mtpPath": options.mtpPath,
                "speculativeType": options.speculativeType,
                "specDraftNMax": options.specDraftNMax ?? 0,
                "specDraftNMin": options.specDraftNMin ?? 0,
                "specDraftPMin": options.specDraftPMin ?? 0.0,
                "argv": options.argv
            ]
        }

        if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
            payload["startDiagnostics"] = [
                "code": diagnostics.code,
                "message": diagnostics.message,
                "lastHTTPStatus": diagnostics.lastHTTPStatus ?? 0,
                "elapsedMs": diagnostics.elapsedMs,
                "progress": diagnostics.progress,
                "httpReady": diagnostics.httpReady
            ]
        }

        return payload
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct LoadReceiptPill: View {
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

private struct LoadReceiptStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct LoadReceiptValueRow: View {
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
