import SwiftUI
import NoemaPackages

struct RuntimeDiagnosticsSummaryContent: View {
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    @ObservedObject var datasetManager: DatasetManager
    let openDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: chatVM.canAcceptChatInput ? "checkmark.circle.fill" : "pause.circle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(chatVM.canAcceptChatInput ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Runtime Diagnostics"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openDiagnostics) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Runtime Diagnostics"))
            }

            HStack(spacing: 8) {
                CapsuleMetric(title: LocalizedStringKey("Tools"), value: flag(chatVM.supportsToolsFlag))
                CapsuleMetric(title: LocalizedStringKey("Images"), value: flag(chatVM.supportsImageInput))
                CapsuleMetric(title: LocalizedStringKey("RAG"), value: ragValue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openDiagnostics)
    }

    private var summaryLine: String {
        if let remote = modelManager.activeRemoteSession {
            return String.localizedStringWithFormat(
                String(localized: "Remote: %@"),
                remote.modelName
            )
        }
        if let model = activeLocalModel {
            return "\(model.name) · \(model.format.displayName)"
        }
        if chatVM.loading || chatVM.stillLoading {
            return String(localized: "Loading")
        }
        return String(localized: "No local model loaded")
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var ragValue: String {
        (modelManager.activeDataset ?? datasetManager.selectedDataset) == nil
            ? String(localized: "Disabled")
            : String(localized: "Enabled")
    }

    private func flag(_ value: Bool) -> String {
        value ? String(localized: "Enabled") : String(localized: "Disabled")
    }
}

private struct CapsuleMetric: View {
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

struct RuntimeDiagnosticsView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @State private var checkedAt = Date()
    @State private var diagnosticsExportURL: URL?
    @State private var diagnosticsExportError: String?
    @State private var developerBundleURL: URL?
    @State private var developerBundleError: String?
    @State private var promptCacheActionMessage: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Runtime Readiness")) {
                DiagnosticStatusRow(
                    title: LocalizedStringKey("Chat Input"),
                    value: chatInputValue,
                    systemImage: chatVM.canAcceptChatInput ? "checkmark.circle.fill" : "pause.circle",
                    tint: chatVM.canAcceptChatInput ? .green : .orange
                )
                DiagnosticValueRow(title: LocalizedStringKey("Backend"), value: backendValue)
                DiagnosticValueRow(title: LocalizedStringKey("Current Model"), value: modelValue)
                DiagnosticValueRow(title: LocalizedStringKey("Format"), value: formatValue)
                if let error = chatVM.loadError, !error.isEmpty {
                    DiagnosticValueRow(title: LocalizedStringKey("Load Error"), value: error)
                }
            }

            Section(LocalizedStringKey("Local Runtime")) {
                DiagnosticValueRow(title: LocalizedStringKey("Context Length"), value: contextValue)
                DiagnosticValueRow(title: LocalizedStringKey("Power Adaptation"), value: powerAdaptationValue)
                DiagnosticValueRow(title: LocalizedStringKey("Working Set"), value: workingSetValue)
                DiagnosticValueRow(title: LocalizedStringKey("Loopback Server"), value: loopbackValue)
                DiagnosticValueRow(title: LocalizedStringKey("Prompt Cache"), value: promptCacheValue)
                DiagnosticValueRow(title: LocalizedStringKey("Last Unload Verification"), value: unloadVerificationValue)
                DiagnosticValueRow(title: LocalizedStringKey("MTP"), value: mtpValue)
                DiagnosticValueRow(title: LocalizedStringKey("Last Start"), value: lastResponseValue)
            }

            Section(LocalizedStringKey("Live Memory Pressure")) {
                LiveMemoryPressureMeter(
                    modelEstimateBytes: activeLocalModelEstimate,
                    modelAlreadyLoaded: chatVM.loadedModelURL != nil || modelManager.loadedModel != nil
                )
                DiagnosticValueRow(title: LocalizedStringKey("Thermal Stage"), value: thermalStageValue)
            }

            Section(LocalizedStringKey("Prompt Cache Manager")) {
                DiagnosticValueRow(title: LocalizedStringKey("Cache File"), value: promptCacheFileValue)
                DiagnosticValueRow(title: LocalizedStringKey("Cache Size"), value: promptCacheSizeValue)
                Button(role: .destructive) {
                    clearPromptCache()
                } label: {
                    Label(LocalizedStringKey("Clear Prompt Cache"), systemImage: "trash")
                }
                .disabled(promptCacheURL == nil)

                if let promptCacheActionMessage {
                    Text(verbatim: promptCacheActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("MTP Validation")) {
                DiagnosticStatusRow(
                    title: LocalizedStringKey("Model Supports MTP"),
                    value: mtpSupportValue,
                    systemImage: mtpIsSupported ? "checkmark.seal.fill" : "xmark.seal",
                    tint: mtpIsSupported ? .green : .secondary
                )
                DiagnosticStatusRow(
                    title: LocalizedStringKey("MTP Setting"),
                    value: mtpSettingValue,
                    systemImage: mtpSettingEnabled ? "switch.2" : "switch.2",
                    tint: mtpSettingEnabled ? .green : .secondary
                )
                DiagnosticStatusRow(
                    title: LocalizedStringKey("Start Options"),
                    value: mtpStartOptionsValue,
                    systemImage: mtpStartOptionsActive ? "bolt.fill" : "bolt.slash",
                    tint: mtpStartOptionsActive ? .green : .secondary
                )
                DiagnosticValueRow(title: LocalizedStringKey("Draft Tokens"), value: mtpDraftTokenValue)
                DiagnosticValueRow(title: LocalizedStringKey("Draft Source"), value: mtpDraftSourceValue)
            }

            Section(LocalizedStringKey("Capabilities")) {
                DiagnosticStatusRow(
                    title: LocalizedStringKey("Images"),
                    value: flag(chatVM.supportsImageInput),
                    systemImage: chatVM.supportsImageInput ? "photo.on.rectangle.angled" : "photo",
                    tint: chatVM.supportsImageInput ? .green : .secondary
                )
                DiagnosticStatusRow(
                    title: LocalizedStringKey("Tool Calling"),
                    value: flag(chatVM.supportsToolsFlag),
                    systemImage: chatVM.supportsToolsFlag ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver",
                    tint: chatVM.supportsToolsFlag ? .green : .secondary
                )
                DiagnosticValueRow(title: LocalizedStringKey("Retrieval"), value: retrievalValue)
                DiagnosticValueRow(title: LocalizedStringKey("Embedding Model"), value: embeddingValue)
            }

            Section(LocalizedStringKey("Privacy")) {
                DiagnosticStatusRow(
                    title: LocalizedStringKey("Off-Grid"),
                    value: flag(NetworkKillSwitch.isEnabled),
                    systemImage: NetworkKillSwitch.isEnabled ? "wifi.slash" : "wifi",
                    tint: NetworkKillSwitch.isEnabled ? .green : .secondary
                )
                DiagnosticValueRow(title: LocalizedStringKey("Remote Session"), value: remoteSessionValue)
            }

            Section {
                Button {
                    checkedAt = Date()
                } label: {
                    Label(LocalizedStringKey("Run Checks"), systemImage: "stethoscope")
                }
                DiagnosticValueRow(title: LocalizedStringKey("Last Checked"), value: checkedAt.formatted(date: .omitted, time: .standard))
            }

            Section(LocalizedStringKey("Diagnostics Export")) {
                Button {
                    generateDiagnosticsExport()
                } label: {
                    Label(LocalizedStringKey("Generate Load Receipt"), systemImage: "doc.badge.gearshape")
                }

                if let url = diagnosticsExportURL {
                    ShareLink(item: url) {
                        Label(LocalizedStringKey("Share Diagnostics JSON"), systemImage: "square.and.arrow.up")
                    }
                    DiagnosticValueRow(title: LocalizedStringKey("Receipt File"), value: url.lastPathComponent)
                }

                if let error = diagnosticsExportError {
                    DiagnosticValueRow(title: LocalizedStringKey("Export Error"), value: error)
                }

                Button {
                    generateDeveloperBundle()
                } label: {
                    Label(LocalizedStringKey("Generate Developer Bundle"), systemImage: "archivebox")
                }

                if let url = developerBundleURL {
                    ShareLink(item: url) {
                        Label(LocalizedStringKey("Share Developer Bundle"), systemImage: "square.and.arrow.up")
                    }
                    DiagnosticValueRow(title: LocalizedStringKey("Developer Bundle File"), value: url.lastPathComponent)
                }

                if let error = developerBundleError {
                    DiagnosticValueRow(title: LocalizedStringKey("Developer Bundle Error"), value: error)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Runtime Diagnostics"))
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        if let loaded = modelManager.loadedModel {
            return loaded
        }
        return nil
    }

    private var activeSettings: ModelSettings? {
        chatVM.loadedModelSettings ?? activeLocalModel.map { modelManager.settings(for: $0) }
    }

    private var chatInputValue: String {
        if chatVM.canAcceptChatInput {
            return String(localized: "Ready")
        }
        if chatVM.loading || chatVM.stillLoading {
            return String(localized: "Loading")
        }
        return String(localized: "Disabled")
    }

    private var backendValue: String {
        if let remote = modelManager.activeRemoteSession {
            return String.localizedStringWithFormat(
                String(localized: "Remote: %@"),
                remote.backendName
            )
        }
        guard let format = chatVM.loadedModelFormat ?? activeLocalModel?.format else {
            return String(localized: "No local model loaded")
        }
        switch format {
        case .gguf:
            return String(localized: "Local llama.cpp loopback")
        case .mlx:
            return String(localized: "Local MLX")
        case .et:
            return String(localized: "Local ExecuTorch")
        case .ane:
            return String(localized: "Local CML")
        case .afm:
            return String(localized: "Apple Foundation Models")
        case .coreai:
            return String(localized: "Local Core AI")
        }
    }

    private var modelValue: String {
        if let remote = modelManager.activeRemoteSession {
            return remote.modelName
        }
        if let model = activeLocalModel {
            return model.name
        }
        if let url = chatVM.loadedModelURL {
            return url.lastPathComponent
        }
        return String(localized: "No local model loaded")
    }

    private var formatValue: String {
        if let format = chatVM.loadedModelFormat ?? activeLocalModel?.format {
            return format.displayName
        }
        return String(localized: "Unavailable")
    }

    private var contextValue: String {
        guard let settings = chatVM.loadedModelSettings else {
            return String(localized: "Unavailable")
        }
        return NumberFormatter.localizedString(from: NSNumber(value: Int(settings.contextLength)), number: .decimal)
    }

    private var workingSetValue: String {
        guard let model = activeLocalModel else {
            return String(localized: "Unavailable")
        }
        let settings = activeSettings ?? modelManager.settings(for: model)
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
        let estimateText = memoryString(estimate.estimate)
        let budgetText = estimate.budget.map(memoryString) ?? "--"
        let fits = estimate.budget.map { estimate.estimate <= $0 } ?? true
        let status = fits ? String(localized: "Fits") : String(localized: "Over Budget")
        return "\(status) · \(estimateText) / \(budgetText)"
    }

    private var powerAdaptationValue: String {
        guard let decision = chatVM.lastGenerationPowerPolicy else {
            return String(localized: "No adaptation")
        }
        guard decision.adapted else {
            return String(localized: "No adaptation")
        }
        let reasonText = decision.reasons
            .map { reason in String(localized: String.LocalizationValue(reason.localizedTitleKey)) }
            .joined(separator: ", ")
        return String.localizedStringWithFormat(
            String(localized: "%@ - threads %@ to %@ - context %@ to %@"),
            reasonText,
            "\(decision.originalThreadCount)",
            "\(decision.appliedThreadCount)",
            "\(decision.originalContextLength)",
            "\(decision.appliedContextLength)"
        )
    }

    private var unloadVerificationValue: String {
        guard let result = chatVM.lastUnloadVerification else {
            return String(localized: "Not checked")
        }
        let status = String(localized: String.LocalizationValue(result.status.titleKey))
        let released = ByteCountFormatter.string(fromByteCount: result.releasedBytes, countStyle: .memory)
        return String.localizedStringWithFormat(
            String(localized: "%@ · %@ released"),
            status,
            released
        )
    }

    private var activeLocalModelEstimate: Int64? {
        guard let model = activeLocalModel else {
            return nil
        }
        let settings = activeSettings ?? modelManager.settings(for: model)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: model.url.path)[.size]) as? Int64 else {
            return nil
        }
        return ModelRAMAdvisor.estimateAndBudget(
            format: model.format,
            sizeBytes: size,
            contextLength: Int(settings.contextLength),
            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
            moeInfo: model.moeInfo,
            kvCacheEstimate: model.format == .gguf ? .resolved(from: settings) : .f16F16
        ).estimate
    }

    private var thermalStageValue: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return String(localized: "Nominal")
        case .fair:
            return String(localized: "Fair")
        case .serious:
            return String(localized: "Serious")
        case .critical:
            return String(localized: "Critical")
        @unknown default:
            return String(localized: "Unknown")
        }
    }

    private var loopbackValue: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else {
            return String(localized: "Not running")
        }
        if LlamaServerBridge.isLoading() {
            let progress = Int((LlamaServerBridge.loadProgress() * 100).rounded())
            return String.localizedStringWithFormat(
                String(localized: "Port %d, loading %d%%"),
                port,
                progress
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "Port %d, ready"),
            port
        )
    }

    private var promptCacheValue: String {
        guard let settings = activeSettings else {
            return String(localized: "Unavailable")
        }
        guard settings.promptCacheEnabled else {
            return String(localized: "Disabled")
        }
        let path = settings.promptCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return String(localized: "Enabled")
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var promptCacheURL: URL? {
        guard let settings = activeSettings, settings.promptCacheEnabled else {
            return nil
        }
        let path = settings.promptCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private var promptCacheFileValue: String {
        guard let url = promptCacheURL else {
            return String(localized: "No explicit cache file")
        }
        return url.lastPathComponent
    }

    private var promptCacheSizeValue: String {
        guard let url = promptCacheURL else {
            return String(localized: "Unavailable")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return String(localized: "Not created yet")
        }
        let bytes = directorySize(at: url) ?? fileSize(at: url)
        guard let bytes else {
            return String(localized: "Unavailable")
        }
        return memoryString(bytes)
    }

    private var mtpValue: String {
        guard let settings = activeSettings else {
            return String(localized: "Unavailable")
        }
        guard settings.speculativeDecoding.mtpEnabled else {
            return String(localized: "Disabled")
        }
        return String.localizedStringWithFormat(
            String(localized: "Enabled, %d draft tokens"),
            settings.speculativeDecoding.resolvedMTPDraftNMax
        )
    }

    private var lastResponseValue: String {
        guard let options = LlamaServerBridge.lastStartOptions() else {
            return String(localized: "Unavailable")
        }
        let spec = options.speculativeType.isEmpty ? String(localized: "None") : options.speculativeType
        return String.localizedStringWithFormat(
            String(localized: "Speculation: %@"),
            spec
        )
    }

    private var retrievalValue: String {
        if let dataset = modelManager.activeDataset ?? datasetManager.selectedDataset {
            return dataset.name
        }
        return String(localized: "No active dataset")
    }

    private var embeddingValue: String {
        FileManager.default.fileExists(atPath: EmbeddingModel.modelURL.path)
            ? String(localized: "Installed")
            : String(localized: "Missing")
    }

    private var remoteSessionValue: String {
        guard let remote = modelManager.activeRemoteSession else {
            return String(localized: "Local only")
        }
        return "\(remote.endpointType.displayName) · \(remote.transport.label)"
    }

    private var mtpIsSupported: Bool {
        guard let model = activeLocalModel, model.format == .gguf else { return false }
        return MtpLocator.hasMtpFile(alongside: model.url) || GGUFMetadata.hasMTP(at: model.url)
    }

    private var mtpSettingEnabled: Bool {
        activeSettings?.speculativeDecoding.mtpEnabled == true
    }

    private var mtpStartOptionsActive: Bool {
        guard let options = LlamaServerBridge.lastStartOptions() else { return false }
        return options.speculativeType == "draft-mtp"
    }

    private var mtpSupportValue: String {
        guard let model = activeLocalModel else {
            return String(localized: "No local model loaded")
        }
        guard model.format == .gguf else {
            return String(localized: "GGUF only")
        }
        let sidecar = MtpLocator.mtpPath(alongside: model.url) != nil
        let embedded = GGUFMetadata.hasMTP(at: model.url)
        if sidecar && embedded {
            return String(localized: "Sidecar and embedded head")
        }
        if sidecar {
            return String(localized: "Sidecar")
        }
        if embedded {
            return String(localized: "Embedded Head")
        }
        return String(localized: "Missing")
    }

    private var mtpSettingValue: String {
        guard activeSettings != nil else {
            return String(localized: "Unavailable")
        }
        return mtpSettingEnabled ? String(localized: "Enabled") : String(localized: "Disabled")
    }

    private var mtpStartOptionsValue: String {
        guard let options = LlamaServerBridge.lastStartOptions() else {
            return String(localized: "Unavailable")
        }
        guard !options.speculativeType.isEmpty else {
            return String(localized: "Inactive")
        }
        return options.speculativeType
    }

    private var mtpDraftTokenValue: String {
        if let options = LlamaServerBridge.lastStartOptions(),
           let draft = options.specDraftNMax {
            return NumberFormatter.localizedString(from: NSNumber(value: draft), number: .decimal)
        }
        guard let settings = activeSettings else {
            return String(localized: "Unavailable")
        }
        return NumberFormatter.localizedString(
            from: NSNumber(value: settings.speculativeDecoding.resolvedMTPDraftNMax),
            number: .decimal
        )
    }

    private var mtpDraftSourceValue: String {
        guard let model = activeLocalModel, model.format == .gguf else {
            return String(localized: "Unavailable")
        }
        if let path = MtpLocator.mtpPath(alongside: model.url) {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if GGUFMetadata.hasMTP(at: model.url) {
            return String(localized: "Embedded Head")
        }
        return String(localized: "Missing")
    }

    private func flag(_ enabled: Bool) -> String {
        enabled ? String(localized: "Enabled") : String(localized: "Disabled")
    }

    private func memoryString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func generateDiagnosticsExport() {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: diagnosticsPayload(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("noema-runtime-diagnostics-\(Self.fileTimestamp()).json")
            try data.write(to: url, options: [.atomic])
            diagnosticsExportURL = url
            diagnosticsExportError = nil
            checkedAt = Date()
        } catch {
            diagnosticsExportError = error.localizedDescription
        }
    }

    private func generateDeveloperBundle() {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: developerBundlePayload(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("noema-developer-diagnostics-\(Self.fileTimestamp()).json")
            try data.write(to: url, options: [.atomic])
            developerBundleURL = url
            developerBundleError = nil
            checkedAt = Date()
        } catch {
            developerBundleError = error.localizedDescription
        }
    }

    private func diagnosticsPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "chatInput": chatInputValue,
            "backend": backendValue,
            "currentModel": modelValue,
            "format": formatValue,
            "contextLength": contextValue,
            "powerAdaptation": powerAdaptationValue,
            "workingSet": workingSetValue,
            "loopbackServer": loopbackValue,
            "promptCache": promptCacheValue,
            "promptCacheFile": promptCacheFileValue,
            "promptCacheSize": promptCacheSizeValue,
            "mtp": mtpValue,
            "capabilities": [
                "images": chatVM.supportsImageInput,
                "tools": chatVM.supportsToolsFlag,
                "retrieval": retrievalValue
            ],
            "privacy": [
                "offGrid": NetworkKillSwitch.isEnabled,
                "remoteSession": remoteSessionValue
            ],
            "embeddingModel": embeddingValue
        ]

        if let error = chatVM.loadError, !error.isEmpty {
            payload["loadError"] = error
        }

        if let model = activeLocalModel {
            payload["localModel"] = [
                "name": model.name,
                "modelID": model.modelID,
                "quant": model.quant,
                "format": model.format.displayName,
                "file": model.url.lastPathComponent,
                "isMultimodal": model.isMultimodal,
                "isToolCapable": model.isToolCapable,
                "totalLayers": model.totalLayers
            ]
        }

        if let settings = activeSettings {
            payload["modelSettings"] = [
                "contextLength": settings.contextLength,
                "gpuLayers": settings.gpuLayers,
                "cpuThreads": settings.cpuThreads,
                "flashAttention": settings.flashAttention,
                "useMMap": settings.useMmap,
                "kvCacheOffload": settings.kvCacheOffload,
                "promptCacheEnabled": settings.promptCacheEnabled,
                "promptCacheAll": settings.promptCacheAll,
                "mtpEnabled": settings.speculativeDecoding.mtpEnabled,
                "mtpDraftTokens": settings.speculativeDecoding.resolvedMTPDraftNMax
            ]
        }

        payload["mtpValidation"] = [
            "supported": mtpIsSupported,
            "support": mtpSupportValue,
            "settingEnabled": mtpSettingEnabled,
            "startOptionsActive": mtpStartOptionsActive,
            "startOptions": mtpStartOptionsValue,
            "draftTokens": mtpDraftTokenValue,
            "draftSource": mtpDraftSourceValue
        ]

        if let options = LlamaServerBridge.lastStartOptions() {
            payload["llamaStartOptions"] = [
                "port": options.port,
                "ggufFile": URL(fileURLWithPath: options.ggufPath).lastPathComponent,
                "projectorFile": options.mmprojPath.isEmpty ? "" : URL(fileURLWithPath: options.mmprojPath).lastPathComponent,
                "mtpFile": options.mtpPath.isEmpty ? "" : URL(fileURLWithPath: options.mtpPath).lastPathComponent,
                "speculativeType": options.speculativeType,
                "specDraftNMax": jsonValue(options.specDraftNMax),
                "specDraftNMin": jsonValue(options.specDraftNMin),
                "specDraftPMin": jsonValue(options.specDraftPMin),
                "argv": options.argv
            ]
        }

        if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
            payload["llamaStartDiagnostics"] = [
                "code": diagnostics.code,
                "message": diagnostics.message,
                "lastHTTPStatus": jsonValue(diagnostics.lastHTTPStatus),
                "elapsedMs": diagnostics.elapsedMs,
                "progress": diagnostics.progress,
                "httpReady": diagnostics.httpReady
            ]
        }

        if let remote = modelManager.activeRemoteSession {
            payload["remote"] = [
                "backend": remote.backendName,
                "model": remote.modelName,
                "endpointType": remote.endpointType.displayName,
                "transport": remote.transport.label
            ]
        }

        if let dataset = modelManager.activeDataset ?? datasetManager.selectedDataset {
            payload["dataset"] = [
                "name": dataset.name,
                "source": dataset.source,
                "isIndexed": dataset.isIndexed,
                "requiresReindex": dataset.requiresReindex
            ]
        }

        return payload
    }

    private func developerBundlePayload() -> [String: Any] {
        var payload = diagnosticsPayload()
        payload["bundleKind"] = "developer-diagnostics"
        payload["privacyNote"] = String(localized: "This export includes redacted recent logs and excludes chat transcripts and document contents.")
        payload["device"] = devicePayload()
        payload["installedModels"] = modelManager.downloadedModels.map(modelMetadataPayload(_:))
        payload["benchmarks"] = benchmarkPayloads()
        payload["runtimeReceipts"] = runtimeReceiptPayload()
        payload["recentLogs"] = DiagnosticLogRedactor.recentLogPayload(from: Logger.shared.logFileURL)
        return payload
    }

    private func devicePayload() -> [String: Any] {
        let ram = DeviceRAMInfo.current()
        return [
            "modelIdentifier": ram.modelIdentifier,
            "modelName": ram.modelName,
            "ram": ram.ram,
            "conservativeLimitBytes": jsonValue(ram.conservativeLimitBytes()),
            "thermalState": thermalStageValue,
            "gpuOffloadSupported": DeviceGPUInfo.supportsGPUOffload
        ]
    }

    private func modelMetadataPayload(_ model: LocalModel) -> [String: Any] {
        let settingsResolution = ModelSettings.resolvedLocalSettings(for: model)
        let settings = settingsResolution.settings
        let projectorPath = model.format == .gguf ? ProjectorLocator.projectorPath(alongside: model.url) : nil
        let mtpPath = model.format == .gguf ? MtpLocator.mtpPath(alongside: model.url) : nil
        let embeddedMTP = model.format == .gguf && GGUFMetadata.hasMTP(at: model.url)
        let mergedProjector = model.format == .gguf && GGUFMetadata.hasMultimodalProjector(at: model.url)
        let tokenizerPath = ModelSettings.resolvedTokenizerPath(for: model)
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: model.url.path)[.size]) as? NSNumber)?.int64Value
        return [
            "name": model.name,
            "modelID": model.modelID,
            "format": model.format.displayName,
            "quant": model.quant,
            "file": model.url.lastPathComponent,
            "fileSizeBytes": jsonValue(fileSize),
            "isMultimodal": model.isMultimodal,
            "isToolCapable": model.isToolCapable,
            "isFavourite": model.isFavourite,
            "totalLayers": model.totalLayers,
            "architecture": model.architecture,
            "architectureFamily": model.architectureFamily,
            "downloadDate": ISO8601DateFormatter().string(from: model.downloadDate),
            "lastUsedDate": model.lastUsedDate.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "dependencies": [
                "tokenizer": tokenizerPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                "promptTemplateSource": settingsResolution.promptTemplateSource.rawValue,
                "hasPromptTemplate": settings.promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "projector": projectorPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                "mergedProjector": mergedProjector,
                "mtp": mtpPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                "embeddedMTP": embeddedMTP
            ],
            "settings": [
                "contextLength": settings.contextLength,
                "gpuLayers": settings.gpuLayers,
                "cpuThreads": settings.cpuThreads,
                "flashAttention": settings.flashAttention,
                "useMMap": settings.useMmap,
                "kvCacheOffload": settings.kvCacheOffload,
                "promptCacheEnabled": settings.promptCacheEnabled,
                "mtpEnabled": settings.speculativeDecoding.mtpEnabled,
                "mtpDraftTokens": settings.speculativeDecoding.resolvedMTPDraftNMax
            ]
        ]
    }

    private func benchmarkPayloads() -> [[String: Any]] {
        ModelBenchmarkResultStore.loadAll()
            .values
            .sorted { lhs, rhs in
                lhs.result.completedAt > rhs.result.completedAt
            }
            .map { record in
                let result = record.result
                return [
                    "modelID": record.modelID,
                    "modelName": record.modelName,
                    "modelFile": URL(fileURLWithPath: record.modelPath).lastPathComponent,
                    "quant": record.quant,
                    "sizeGB": record.sizeGB,
                    "format": result.format.displayName,
                    "completedAt": ISO8601DateFormatter().string(from: result.completedAt),
                    "promptTokens": result.promptTokens,
                    "promptRate": result.promptRate,
                    "generationTokens": result.generationTokens,
                    "generationRate": result.generationRate,
                    "totalDuration": result.totalDuration,
                    "timeToFirstToken": result.timeToFirstToken,
                    "peakMemoryBytes": result.peakMemoryBytes,
                    "memoryDeltaBytes": result.memoryDeltaBytes,
                    "kvCacheOffloadActive": result.kvCacheOffloadActive,
                    "speculativeTimings": speculativePayload(result.speculativeTimings)
                ]
            }
    }

    private func speculativePayload(_ timings: LoopbackSpeculativeTimings?) -> Any {
        guard let timings else { return NSNull() }
        return [
            "draftTokensGenerated": jsonValue(timings.draftN),
            "draftTokensAccepted": jsonValue(timings.draftNAccepted),
            "acceptanceRate": jsonValue(timings.acceptanceRate),
            "promptMs": jsonValue(timings.promptMS),
            "predictedMs": jsonValue(timings.predictedMS)
        ]
    }

    private func runtimeReceiptPayload() -> [String: Any] {
        var receipt: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "backend": backendValue,
            "currentModel": modelValue,
            "format": formatValue,
            "loopbackServer": loopbackValue,
            "powerAdaptation": powerAdaptationValue,
            "workingSet": workingSetValue
        ]
        if let options = LlamaServerBridge.lastStartOptions() {
            receipt["llamaStartOptions"] = [
                "port": options.port,
                "ggufFile": URL(fileURLWithPath: options.ggufPath).lastPathComponent,
                "projectorFile": options.mmprojPath.isEmpty ? "" : URL(fileURLWithPath: options.mmprojPath).lastPathComponent,
                "mtpFile": options.mtpPath.isEmpty ? "" : URL(fileURLWithPath: options.mtpPath).lastPathComponent,
                "speculativeType": options.speculativeType,
                "argv": options.argv
            ]
        }
        if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
            receipt["llamaStartDiagnostics"] = [
                "code": diagnostics.code,
                "message": diagnostics.message,
                "lastHTTPStatus": jsonValue(diagnostics.lastHTTPStatus),
                "elapsedMs": diagnostics.elapsedMs,
                "progress": diagnostics.progress,
                "httpReady": diagnostics.httpReady
            ]
        }
        return receipt
    }

    private func jsonValue<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    private func clearPromptCache() {
        guard let url = promptCacheURL else {
            promptCacheActionMessage = String(localized: "No prompt cache file is configured.")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                promptCacheActionMessage = String(localized: "Prompt cache cleared.")
            } else {
                promptCacheActionMessage = String(localized: "Prompt cache has not been created yet.")
            }
            checkedAt = Date()
        } catch {
            promptCacheActionMessage = error.localizedDescription
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
    }

    private func directorySize(at url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct DiagnosticValueRow: View {
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

private struct DiagnosticStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}
