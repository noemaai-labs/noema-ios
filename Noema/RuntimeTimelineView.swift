import SwiftUI
import NoemaPackages

struct RuntimeTimelineSummaryContent: View {
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    @ObservedObject var datasetManager: DatasetManager
    let openTimeline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Runtime Timeline"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openTimeline) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Runtime Timeline"))
            }

            HStack(spacing: 8) {
                RuntimeTimelinePill(title: LocalizedStringKey("Loopback"), value: loopbackPill)
                RuntimeTimelinePill(title: LocalizedStringKey("Tools"), value: flag(chatVM.supportsToolsFlag))
                RuntimeTimelinePill(title: LocalizedStringKey("RAG"), value: ragPill)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openTimeline)
    }

    private var summaryLine: String {
        if let remote = modelManager.activeRemoteSession {
            return String.localizedStringWithFormat(String(localized: "Remote: %@"), remote.modelName)
        }
        if chatVM.loading || chatVM.stillLoading || LlamaServerBridge.isLoading() {
            let progress = Int((LlamaServerBridge.loadProgress() * 100).rounded())
            return String.localizedStringWithFormat(String(localized: "Loading %d%%"), progress)
        }
        if let model = activeLocalModel {
            return "\(model.name) · \(model.format.displayName)"
        }
        return String(localized: "No local model loaded")
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var loopbackPill: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else { return String(localized: "Off") }
        return LlamaServerBridge.isLoading() ? String(localized: "Loading") : String(localized: "Ready")
    }

    private var ragPill: String {
        (modelManager.activeDataset ?? datasetManager.selectedDataset) == nil
            ? String(localized: "Off")
            : String(localized: "On")
    }

    private func flag(_ value: Bool) -> String {
        value ? String(localized: "On") : String(localized: "Off")
    }
}

struct RuntimeTimelineView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @State private var checkedAt = Date()
    @State private var latestResponse: LoopbackResponseDiagnostics?
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Runtime Timeline")) {
                ForEach(timelineEvents) { event in
                    RuntimeTimelineEventRow(event: event)
                }
            }

            Section(LocalizedStringKey("Live Runtime")) {
                RuntimeTimelineValueRow(title: LocalizedStringKey("Loaded Model"), value: loadedModelValue)
                RuntimeTimelineValueRow(title: LocalizedStringKey("Backend"), value: backendValue)
                RuntimeTimelineValueRow(title: LocalizedStringKey("Loopback Server"), value: loopbackValue)
                RuntimeTimelineValueRow(title: LocalizedStringKey("Last Response"), value: lastResponseValue)
                RuntimeTimelineValueRow(title: LocalizedStringKey("Last Checked"), value: checkedAt.formatted(date: .omitted, time: .standard))
                Button {
                    refresh()
                } label: {
                    Label(LocalizedStringKey("Refresh Timeline"), systemImage: "arrow.clockwise")
                }
            }

            Section(LocalizedStringKey("Timeline Export")) {
                Button {
                    generateExport()
                } label: {
                    Label(LocalizedStringKey("Generate Timeline JSON"), systemImage: "doc.badge.gearshape")
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share Timeline JSON"), systemImage: "square.and.arrow.up")
                    }
                    RuntimeTimelineValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                }

                if let exportError {
                    RuntimeTimelineValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Runtime Timeline"))
        .task { await refreshLatestResponse() }
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var activeSettings: ModelSettings? {
        chatVM.loadedModelSettings ?? activeLocalModel.map { modelManager.settings(for: $0) }
    }

    private var timelineEvents: [RuntimeTimelineEvent] {
        var events: [RuntimeTimelineEvent] = []

        if let remote = modelManager.activeRemoteSession {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Remote Session"),
                detail: "\(remote.backendName) · \(remote.modelName) · \(remote.transport.label)",
                systemImage: "network",
                tint: .blue,
                state: String(localized: "Active")
            ))
        } else if let model = activeLocalModel {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Model Selected"),
                detail: "\(model.name) · \(model.format.displayName) · \(model.url.lastPathComponent)",
                systemImage: "shippingbox",
                tint: .blue,
                state: chatVM.loadedModelURL == nil ? String(localized: "Stored") : String(localized: "Loaded")
            ))
        } else {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Model Selected"),
                detail: String(localized: "No local model loaded"),
                systemImage: "shippingbox",
                tint: .secondary,
                state: String(localized: "Idle")
            ))
        }

        if let settings = activeSettings {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Load Configuration"),
                detail: loadConfigurationDetail(settings),
                systemImage: "slider.horizontal.3",
                tint: .accentColor,
                state: String(localized: "Prepared")
            ))
        }

        let port = Int(LlamaServerBridge.port())
        if port > 0 {
            let state = LlamaServerBridge.isLoading() ? String(localized: "Loading") : String(localized: "Ready")
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Loopback Launch"),
                detail: loopbackValue,
                systemImage: "server.rack",
                tint: LlamaServerBridge.isLoading() ? .orange : .green,
                state: state
            ))
        }

        if let options = LlamaServerBridge.lastStartOptions() {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Bridge Arguments"),
                detail: startOptionsDetail(options),
                systemImage: "terminal",
                tint: .secondary,
                state: String.localizedStringWithFormat(String(localized: "%d args"), options.argv.count)
            ))
        }

        if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Readiness Probe"),
                detail: diagnostics.message,
                systemImage: diagnostics.httpReady ? "checkmark.seal.fill" : "exclamationmark.triangle",
                tint: diagnostics.httpReady ? .green : .orange,
                state: String.localizedStringWithFormat(String(localized: "%d ms"), diagnostics.elapsedMs)
            ))
        }

        if let settings = activeSettings {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Prompt Cache"),
                detail: promptCacheDetail(settings),
                systemImage: settings.promptCacheEnabled ? "externaldrive.fill" : "externaldrive",
                tint: settings.promptCacheEnabled ? .green : .secondary,
                state: settings.promptCacheEnabled ? String(localized: "Enabled") : String(localized: "Off")
            ))
        }

        if let latestResponse {
            let timings = latestResponse.timings
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Prompt Processing"),
                detail: promptProcessingDetail(timings),
                systemImage: "text.line.first.and.arrowtriangle.forward",
                tint: .purple,
                state: latestResponse.requestMode
            ))
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Generation Stream"),
                detail: generationDetail(latestResponse),
                systemImage: latestResponse.streaming ? "dot.radiowaves.forward" : "text.bubble",
                tint: .green,
                state: latestResponse.finishReason ?? String(localized: "Complete")
            ))
            if let speculation = speculationDetail(timings) {
                events.append(RuntimeTimelineEvent(
                    title: String(localized: "Speculation"),
                    detail: speculation,
                    systemImage: "bolt.fill",
                    tint: .orange,
                    state: String(localized: "Measured")
                ))
            }
        }

        events.append(RuntimeTimelineEvent(
            title: String(localized: "Tools And Retrieval"),
            detail: toolsRetrievalDetail,
            systemImage: "wrench.and.screwdriver",
            tint: chatVM.supportsToolsFlag ? .green : .secondary,
            state: String(localized: "Available")
        ))

        if let dataset = modelManager.activeDataset ?? datasetManager.selectedDataset {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Dataset Context"),
                detail: "\(dataset.name) · \(dataset.isIndexed ? String(localized: "Indexed") : String(localized: "Not indexed"))",
                systemImage: "books.vertical",
                tint: dataset.isIndexed ? .green : .orange,
                state: String(localized: "RAG")
            ))
        }

        if let error = chatVM.loadError, !error.isEmpty {
            events.append(RuntimeTimelineEvent(
                title: String(localized: "Load Error"),
                detail: error,
                systemImage: "xmark.octagon",
                tint: .red,
                state: String(localized: "Needs attention")
            ))
        }

        return events
    }

    private var backendValue: String {
        if let remote = modelManager.activeRemoteSession {
            return String.localizedStringWithFormat(String(localized: "Remote: %@"), remote.backendName)
        }
        guard let format = chatVM.loadedModelFormat ?? activeLocalModel?.format else {
            return String(localized: "No local model loaded")
        }
        switch format {
        case .gguf: return String(localized: "Local llama.cpp loopback")
        case .mlx: return String(localized: "Local MLX")
        case .et: return String(localized: "Local ExecuTorch")
        case .ane: return String(localized: "Local CML")
        case .afm: return String(localized: "Apple Foundation Models")
        case .coreai: return String(localized: "Local Core AI")
        }
    }

    private var loadedModelValue: String {
        if let remote = modelManager.activeRemoteSession {
            return remote.modelName
        }
        if let model = activeLocalModel {
            return model.name
        }
        return String(localized: "No local model loaded")
    }

    private var loopbackValue: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else { return String(localized: "Not running") }
        if LlamaServerBridge.isLoading() {
            let progress = Int((LlamaServerBridge.loadProgress() * 100).rounded())
            return String.localizedStringWithFormat(String(localized: "Port %d, loading %d%%"), port, progress)
        }
        return String.localizedStringWithFormat(String(localized: "Port %d, ready"), port)
    }

    private var lastResponseValue: String {
        guard let latestResponse else {
            return String(localized: "No response recorded")
        }
        return latestResponse.completedAt.formatted(date: .abbreviated, time: .standard)
    }

    private var toolsRetrievalDetail: String {
        let tools = chatVM.supportsToolsFlag ? String(localized: "Tools enabled") : String(localized: "Tools off")
        let images = chatVM.supportsImageInput ? String(localized: "Images enabled") : String(localized: "Images off")
        let retrieval = (modelManager.activeDataset ?? datasetManager.selectedDataset) == nil
            ? String(localized: "Retrieval off")
            : String(localized: "Retrieval enabled")
        return "\(tools) · \(images) · \(retrieval)"
    }

    private func refresh() {
        checkedAt = Date()
        exportError = nil
        Task { await refreshLatestResponse() }
    }

    @MainActor
    private func refreshLatestResponse() async {
        latestResponse = await LoopbackRuntimeDiagnostics.shared.latestResponseSnapshot()
        checkedAt = Date()
    }

    private func loadConfigurationDetail(_ settings: ModelSettings) -> String {
        let context = NumberFormatter.localizedString(from: NSNumber(value: Int(settings.contextLength)), number: .decimal)
        let gpu = settings.gpuLayers == 0 ? String(localized: "CPU") : String.localizedStringWithFormat(String(localized: "%d GPU layers"), settings.gpuLayers)
        let kv = settings.kvCacheOffload ? String(localized: "KV offload on") : String(localized: "KV offload off")
        let flash = settings.flashAttention ? String(localized: "Flash Attention on") : String(localized: "Flash Attention off")
        return "\(String(localized: "Context")) \(context) · \(gpu) · \(kv) · \(flash)"
    }

    private func startOptionsDetail(_ options: LlamaServerBridge.StartOptions) -> String {
        var parts = [
            URL(fileURLWithPath: options.ggufPath).lastPathComponent,
            String.localizedStringWithFormat(String(localized: "Port %d"), options.port)
        ]
        if !options.mmprojPath.isEmpty {
            parts.append(URL(fileURLWithPath: options.mmprojPath).lastPathComponent)
        }
        if !options.speculativeType.isEmpty {
            parts.append(options.speculativeType)
        }
        if !options.mtpPath.isEmpty {
            parts.append(URL(fileURLWithPath: options.mtpPath).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    private func promptCacheDetail(_ settings: ModelSettings) -> String {
        guard settings.promptCacheEnabled else { return String(localized: "Prompt cache disabled") }
        let path = settings.promptCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return String(localized: "Prompt cache enabled without a file path") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func promptProcessingDetail(_ timings: LoopbackSpeculativeTimings?) -> String {
        guard let timings else {
            return String(localized: "No timing metadata")
        }
        let tokens = timings.promptN.map { String.localizedStringWithFormat(String(localized: "%d prompt tokens"), $0) } ?? String(localized: "Unknown prompt tokens")
        let rate = timings.promptPerSecond.map { String.localizedStringWithFormat(String(localized: "%.1f tok/s"), $0) } ?? String(localized: "Unknown rate")
        return "\(tokens) · \(rate)"
    }

    private func generationDetail(_ response: LoopbackResponseDiagnostics) -> String {
        let timings = response.timings
        let tokens = timings?.predictedN.map { String.localizedStringWithFormat(String(localized: "%d output tokens"), $0) } ?? String.localizedStringWithFormat(String(localized: "%d output characters"), response.outputCharacters)
        let rate = timings?.predictedPerSecond.map { String.localizedStringWithFormat(String(localized: "%.1f tok/s"), $0) } ?? response.endpoint
        return "\(tokens) · \(rate)"
    }

    private func speculationDetail(_ timings: LoopbackSpeculativeTimings?) -> String? {
        guard let timings, let draft = timings.draftN, draft > 0 else { return nil }
        let accepted = timings.draftNAccepted ?? 0
        let percent = (timings.acceptanceRate ?? 0) * 100
        return String.localizedStringWithFormat(String(localized: "%d drafted, %d accepted, %.0f%% acceptance"), draft, accepted, percent)
    }

    private func generateExport() {
        do {
            let data = try JSONSerialization.data(withJSONObject: exportPayload(), options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-runtime-timeline-\(Self.fileTimestamp()).json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func exportPayload() -> [String: Any] {
        [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "checkedAt": ISO8601DateFormatter().string(from: checkedAt),
            "loadedModel": loadedModelValue,
            "backend": backendValue,
            "loopback": loopbackValue,
            "lastResponse": lastResponseValue,
            "events": timelineEvents.map(\.exportDictionary)
        ]
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct RuntimeTimelinePill: View {
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

private struct RuntimeTimelineEvent: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let state: String

    var exportDictionary: [String: Any] {
        [
            "title": title,
            "detail": detail,
            "state": state,
            "systemImage": systemImage
        ]
    }
}

private struct RuntimeTimelineEventRow: View {
    let event: RuntimeTimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(event.tint)
                .frame(width: 28, height: 28)
                .background(event.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: event.title)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 6)
                    Text(verbatim: event.state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(verbatim: event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RuntimeTimelineValueRow: View {
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
