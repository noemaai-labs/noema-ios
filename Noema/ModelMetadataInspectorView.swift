import SwiftUI

struct ModelMetadataInspectorSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openInspector: () -> Void

    private struct Summary: Equatable {
        var gguf = 0
        var vision = 0
        var mtp = 0
    }
    @State private var summary = Summary()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Model Metadata"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openInspector) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Model Metadata"))
            }

            HStack(spacing: 8) {
                MetadataCapsuleMetric(title: LocalizedStringKey("GGUF"), value: "\(summary.gguf)")
                MetadataCapsuleMetric(title: LocalizedStringKey("Vision"), value: "\(summary.vision)")
                MetadataCapsuleMetric(title: LocalizedStringKey("MTP"), value: "\(summary.mtp)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openInspector)
        .task(id: modelSignature) { await refresh() }
    }

    private var modelSignature: String {
        modelManager.downloadedModels
            .filter { $0.format == .gguf }
            .map(\.url.path)
            .joined(separator: "|")
    }

    // Warm the (uncached, disk-bound) GGUF metadata reads off the main thread,
    // then tally the counts from cache so scrolling never blocks on disk.
    @MainActor
    private func refresh() async {
        let gguf = modelManager.downloadedModels.filter { $0.format == .gguf }
        let urls = gguf.map(\.url)
        await Task.detached(priority: .utility) {
            for url in urls { GGUFMetadata.prewarm(at: url) }
        }.value
        guard !Task.isCancelled else { return }
        var result = Summary()
        result.gguf = gguf.count
        result.vision = gguf.filter { model in
            model.isMultimodal ||
            ProjectorLocator.projectorPath(alongside: model.url) != nil ||
            GGUFMetadata.hasMultimodalProjector(at: model.url)
        }.count
        result.mtp = gguf.filter { model in
            MtpLocator.hasMtpFile(alongside: model.url) ||
            GGUFMetadata.hasMTP(at: model.url)
        }.count
        summary = result
    }

    private var summaryLine: String {
        guard summary.gguf > 0 else {
            return String(localized: "No GGUF models installed")
        }

        let format = String(localized: "%d GGUF models installed")
        return String.localizedStringWithFormat(format, summary.gguf)
    }
}

struct ModelMetadataInspectorView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var selectedModelPath: String = ""
    @State private var exportURL: URL?
    @State private var exportError: String?

    private var availableModels: [LocalModel] {
        modelManager.downloadedModels.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var selectedModel: LocalModel? {
        if let model = availableModels.first(where: { $0.url.path == selectedModelPath }) {
            return model
        }
        return availableModels.first
    }

    var body: some View {
        platformContent
            .onAppear(perform: ensureSelection)
            .onReceive(modelManager.$downloadedModels) { _ in ensureSelection() }
    }

    private var platformContent: some View {
#if os(macOS)
        // The iOS Form renders badly inside the Mac settings sheet (clipped
        // labels, wrong insets, stock buttons), and that sheet already supplies
        // the title + close, so macOS gets the industrial card layout with no
        // navigationTitle.
        macBody
#else
        formBody
            .navigationTitle(LocalizedStringKey("Model Metadata"))
#endif
    }

    private var formBody: some View {
        Form {
            if availableModels.isEmpty {
                Section(LocalizedStringKey("Model Metadata")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(LocalizedStringKey("No local models installed"), systemImage: "tray")
                            .font(.headline)
                        Text(LocalizedStringKey("Install a local model to inspect architecture, context, tokenizer, vision, MoE, and MTP metadata."))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section(LocalizedStringKey("Model")) {
                    Picker(LocalizedStringKey("Inspect Model"), selection: selectedPathBinding) {
                        ForEach(availableModels, id: \.id) { model in
                            Text(verbatim: modelLabel(model)).tag(model.url.path)
                        }
                    }
                    MetadataValueRow(title: LocalizedStringKey("Format"), value: selectedModel?.format.displayName ?? String(localized: "Unknown"))
                    MetadataValueRow(title: LocalizedStringKey("File"), value: selectedModel?.url.lastPathComponent ?? String(localized: "Unknown"))
                }

                if let model = selectedModel {
                    if model.format == .gguf {
                        ggufSections(for: model)
                    } else {
                        Section(LocalizedStringKey("Metadata Inspector")) {
                            MetadataStatusRow(
                                title: LocalizedStringKey("Detailed Header Scan"),
                                value: String(localized: "GGUF only"),
                                systemImage: "info.circle",
                                tint: .secondary
                            )
                            MetadataValueRow(title: LocalizedStringKey("Architecture"), value: model.architecture.isEmpty ? String(localized: "Unknown") : model.architecture)
                            MetadataValueRow(title: LocalizedStringKey("Tokenizer"), value: ModelSettings.resolvedTokenizerPath(for: model).map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Managed by backend"))
                        }
                    }

                    exportSection(for: model)
                }
            }
        }
    }

#if os(macOS)
    // MARK: - macOS industrial layout

    private var macBody: some View {
        MacSettingsPage {
            if availableModels.isEmpty {
                MacSettingsCard(LocalizedStringKey("Model Metadata")) {
                    MacSettingsNoteRow(LocalizedStringKey("No local models installed"), divider: false)
                    MacSettingsNoteRow(LocalizedStringKey("Install a local model to inspect architecture, context, tokenizer, vision, MoE, and MTP metadata."))
                }
            } else {
                MacSettingsCard(LocalizedStringKey("Model")) {
                    MacSettingsControlRow(LocalizedStringKey("Inspect Model"), divider: false) {
                        Picker(LocalizedStringKey("Inspect Model"), selection: selectedPathBinding) {
                            ForEach(availableModels, id: \.id) { model in
                                Text(verbatim: modelLabel(model)).tag(model.url.path)
                            }
                        }
                        .labelsHidden()
                    }
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Format"), value: selectedModel?.format.displayName ?? String(localized: "Unknown"))
                    MacSettingsKeyValueRow(title: LocalizedStringKey("File"), value: selectedModel?.url.lastPathComponent ?? String(localized: "Unknown"))
                }

                if let model = selectedModel {
                    if model.format == .gguf {
                        macGGUFSections(for: model)
                    } else {
                        macNonGGUFSection(for: model)
                    }
                    macExportSection(for: model)
                }
            }
        }
    }

    @ViewBuilder
    private func macNonGGUFSection(for model: LocalModel) -> some View {
        MacSettingsCard(LocalizedStringKey("Metadata Inspector")) {
            MacSettingsStatusRow(
                title: LocalizedStringKey("Detailed Header Scan"),
                value: String(localized: "GGUF only"),
                systemImage: "info.circle",
                tint: .secondary,
                divider: false
            )
            MacSettingsKeyValueRow(title: LocalizedStringKey("Architecture"), value: model.architecture.isEmpty ? String(localized: "Unknown") : model.architecture)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Tokenizer"), value: ModelSettings.resolvedTokenizerPath(for: model).map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Managed by backend"))
        }
    }

    @ViewBuilder
    private func macExportSection(for model: LocalModel) -> some View {
        MacSettingsCard(LocalizedStringKey("Metadata Export")) {
            MacSettingsActionRow(divider: false) {
                Button {
                    generateMetadataExport(for: model)
                } label: {
                    Label(LocalizedStringKey("Generate Metadata JSON"), systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(.industrial(.prominent))

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share Metadata JSON"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.industrial(.quiet))
                }
            }

            if let exportURL {
                MacSettingsKeyValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
            }
            if let exportError {
                MacSettingsKeyValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
            }
        }
    }

    @ViewBuilder
    private func macGGUFSections(for model: LocalModel) -> some View {
        let snapshot = ModelMetadataInspectorSnapshot(model: model)

        MacSettingsCard(LocalizedStringKey("Architecture")) {
            MacSettingsKeyValueRow(title: LocalizedStringKey("Display Name"), value: snapshot.displayName, divider: false)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Architecture"), value: snapshot.architecture)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Layers"), value: snapshot.layers)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Training Context"), value: snapshot.trainingContext)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Size"), value: snapshot.size)
        }

        MacSettingsCard(LocalizedStringKey("Tokenizer & Template")) {
            MacSettingsKeyValueRow(title: LocalizedStringKey("Tokenizer"), value: snapshot.tokenizer, divider: false)
            MacSettingsStatusRow(
                title: LocalizedStringKey("Chat Template"),
                value: snapshot.chatTemplateStatus,
                systemImage: snapshot.hasChatTemplate ? "checkmark.circle.fill" : "xmark.circle",
                tint: snapshot.hasChatTemplate ? .green : .secondary
            )
            if let preview = snapshot.chatTemplatePreview {
                MacMetadataTemplatePreviewRow(preview: preview)
            }
        }

        MacSettingsCard(LocalizedStringKey("Capabilities")) {
            MacSettingsStatusRow(
                title: LocalizedStringKey("Vision Projector"),
                value: snapshot.projector,
                systemImage: snapshot.hasProjector ? "photo.on.rectangle.angled" : "photo",
                tint: snapshot.hasProjector ? .green : .secondary,
                divider: false
            )
            MacSettingsStatusRow(
                title: LocalizedStringKey("Tool Hints"),
                value: snapshot.toolHints,
                systemImage: snapshot.hasToolHints ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver",
                tint: snapshot.hasToolHints ? .green : .secondary
            )
            MacSettingsStatusRow(
                title: LocalizedStringKey("MTP Support"),
                value: snapshot.mtp,
                systemImage: snapshot.hasMTP ? "bolt.fill" : "bolt.slash",
                tint: snapshot.hasMTP ? .green : .secondary
            )
        }

        // Only Mixture-of-Experts models carry expert routing metadata; dense models
        // would just show a wall of "Unknown"/"None", so hide the card entirely.
        if snapshot.isMoE {
            MacSettingsCard(LocalizedStringKey("MoE")) {
                MacSettingsStatusRow(
                    title: LocalizedStringKey("MoE Model"),
                    value: snapshot.moeStatus,
                    systemImage: "square.grid.3x3.fill",
                    tint: .green,
                    divider: false
                )
                MacSettingsKeyValueRow(title: LocalizedStringKey("Experts"), value: snapshot.experts)
                MacSettingsKeyValueRow(title: LocalizedStringKey("MoE Layers"), value: snapshot.moeLayers)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Hidden Size"), value: snapshot.hiddenSize)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Feed Forward Size"), value: snapshot.feedForwardSize)
            }
        }

        MacSettingsCard(LocalizedStringKey("Sidecars")) {
            MacSettingsKeyValueRow(title: LocalizedStringKey("Weights"), value: model.url.lastPathComponent, divider: false)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Projector"), value: snapshot.projectorFile)
            MacSettingsKeyValueRow(title: LocalizedStringKey("MTP Draft Model"), value: snapshot.mtpFile)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Install Folder"), value: model.url.deletingLastPathComponent().lastPathComponent)
        }
    }
#endif

    private var selectedPathBinding: Binding<String> {
        Binding(
            get: {
                if selectedModelPath.isEmpty {
                    return availableModels.first?.url.path ?? ""
                }
                return selectedModelPath
            },
            set: { selectedModelPath = $0 }
        )
    }

    private func ensureSelection() {
        guard !availableModels.isEmpty else {
            selectedModelPath = ""
            return
        }
        if selectedModelPath.isEmpty || !availableModels.contains(where: { $0.url.path == selectedModelPath }) {
            selectedModelPath = modelManager.loadedModel?.url.path ?? availableModels.first?.url.path ?? ""
        }
    }

    private func modelLabel(_ model: LocalModel) -> String {
        let suffix = model.quant.isEmpty ? model.format.displayName : "\(model.quant) · \(model.format.displayName)"
        return "\(model.name) (\(suffix))"
    }

    @ViewBuilder
    private func exportSection(for model: LocalModel) -> some View {
        Section(LocalizedStringKey("Metadata Export")) {
            Button {
                generateMetadataExport(for: model)
            } label: {
                Label(LocalizedStringKey("Generate Metadata JSON"), systemImage: "doc.badge.gearshape")
            }

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(LocalizedStringKey("Share Metadata JSON"), systemImage: "square.and.arrow.up")
                }
                MetadataValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
            }

            if let exportError {
                MetadataValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
            }
        }
    }

    private func generateMetadataExport(for model: LocalModel) {
        do {
            let snapshot = ModelMetadataInspectorSnapshot(model: model)
            let payload = ModelMetadataExportPayload(model: model, snapshot: snapshot).dictionary
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let fileName = "noema-model-metadata-\(Self.sanitizedFileToken(model.name)).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private static func sanitizedFileToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "model" : collapsed
    }

    @ViewBuilder
    private func ggufSections(for model: LocalModel) -> some View {
        let snapshot = ModelMetadataInspectorSnapshot(model: model)

        Section(LocalizedStringKey("Architecture")) {
            MetadataValueRow(title: LocalizedStringKey("Display Name"), value: snapshot.displayName)
            MetadataValueRow(title: LocalizedStringKey("Architecture"), value: snapshot.architecture)
            MetadataValueRow(title: LocalizedStringKey("Layers"), value: snapshot.layers)
            MetadataValueRow(title: LocalizedStringKey("Training Context"), value: snapshot.trainingContext)
            MetadataValueRow(title: LocalizedStringKey("Size"), value: snapshot.size)
        }

        Section(LocalizedStringKey("Tokenizer & Template")) {
            MetadataValueRow(title: LocalizedStringKey("Tokenizer"), value: snapshot.tokenizer)
            MetadataStatusRow(
                title: LocalizedStringKey("Chat Template"),
                value: snapshot.chatTemplateStatus,
                systemImage: snapshot.hasChatTemplate ? "checkmark.circle.fill" : "xmark.circle",
                tint: snapshot.hasChatTemplate ? .green : .secondary
            )
            if let preview = snapshot.chatTemplatePreview {
                Text(verbatim: preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        Section(LocalizedStringKey("Capabilities")) {
            MetadataStatusRow(
                title: LocalizedStringKey("Vision Projector"),
                value: snapshot.projector,
                systemImage: snapshot.hasProjector ? "photo.on.rectangle.angled" : "photo",
                tint: snapshot.hasProjector ? .green : .secondary
            )
            MetadataStatusRow(
                title: LocalizedStringKey("Tool Hints"),
                value: snapshot.toolHints,
                systemImage: snapshot.hasToolHints ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver",
                tint: snapshot.hasToolHints ? .green : .secondary
            )
            MetadataStatusRow(
                title: LocalizedStringKey("MTP Support"),
                value: snapshot.mtp,
                systemImage: snapshot.hasMTP ? "bolt.fill" : "bolt.slash",
                tint: snapshot.hasMTP ? .green : .secondary
            )
        }

        // Only Mixture-of-Experts models carry expert routing metadata; dense models
        // would just show a wall of "Unknown"/"None", so hide the section entirely.
        if snapshot.isMoE {
            Section(LocalizedStringKey("MoE")) {
                MetadataStatusRow(
                    title: LocalizedStringKey("MoE Model"),
                    value: snapshot.moeStatus,
                    systemImage: "square.grid.3x3.fill",
                    tint: .green
                )
                MetadataValueRow(title: LocalizedStringKey("Experts"), value: snapshot.experts)
                MetadataValueRow(title: LocalizedStringKey("MoE Layers"), value: snapshot.moeLayers)
                MetadataValueRow(title: LocalizedStringKey("Hidden Size"), value: snapshot.hiddenSize)
                MetadataValueRow(title: LocalizedStringKey("Feed Forward Size"), value: snapshot.feedForwardSize)
            }
        }

        Section(LocalizedStringKey("Sidecars")) {
            MetadataValueRow(title: LocalizedStringKey("Weights"), value: model.url.lastPathComponent)
            MetadataValueRow(title: LocalizedStringKey("Projector"), value: snapshot.projectorFile)
            MetadataValueRow(title: LocalizedStringKey("MTP Draft Model"), value: snapshot.mtpFile)
            MetadataValueRow(title: LocalizedStringKey("Install Folder"), value: model.url.deletingLastPathComponent().lastPathComponent)
        }
    }
}

#if os(macOS)
/// Full-width monospace chat-template preview inside the Tokenizer card. The
/// text is a dynamic GGUF template excerpt, so it stays verbatim rather than a
/// localizable note row.
private struct MacMetadataTemplatePreviewRow: View {
    let preview: String

    var body: some View {
        MacSettingsRowContainer {
            Text(verbatim: preview)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.45))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif

private struct MetadataCapsuleMetric: View {
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

private struct MetadataValueRow: View {
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

private struct MetadataStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct ModelMetadataInspectorSnapshot {
    let displayName: String
    let architecture: String
    let layers: String
    let trainingContext: String
    let size: String
    let tokenizer: String
    let hasChatTemplate: Bool
    let chatTemplateStatus: String
    let chatTemplatePreview: String?
    let hasProjector: Bool
    let projector: String
    let hasToolHints: Bool
    let toolHints: String
    let hasMTP: Bool
    let mtp: String
    let isMoE: Bool
    let moeStatus: String
    let experts: String
    let moeLayers: String
    let hiddenSize: String
    let feedForwardSize: String
    let projectorFile: String
    let mtpFile: String

    init(model: LocalModel) {
        // model.url can point at an install directory for some layouts; resolve the
        // actual .gguf file so the GGUF KV reads (layers/context/MoE) don't silently
        // come back empty.
        let ggufURL = Self.resolvedGGUFURL(for: model)
        let info = GGUFMetadata.architectureInfo(at: ggufURL)
        let moeInfo = model.moeInfo ?? GGUFMetadata.moeInfo(at: ggufURL)
        // Prefer the layer count detected at discovery; fall back to a fresh GGUF read
        // and finally to the MoE descriptor's total-layer count so a real value is shown.
        let layerCount = model.totalLayers > 0
            ? model.totalLayers
            : (GGUFMetadata.layerCount(at: ggufURL) ?? moeInfo?.totalLayerCount ?? 0)
        let context = GGUFMetadata.contextLength(at: ggufURL)
        // Use the same authoritative resolver the runtime uses (curated → sidecar
        // chat_template → hub.json → tokenizer_config → tokenizer.json → config.json →
        // embedded GGUF) instead of only the embedded GGUF template, so models whose
        // template lives in a sidecar no longer read as "Missing".
        let template = ModelSettings.promptTemplateResolution(
            for: model,
            directory: ModelSettings.settingsDirectory(for: model)
        ).template
        let projectorPath = ProjectorLocator.projectorPath(alongside: model.url)
        let mergedProjector = GGUFMetadata.hasMultimodalProjector(at: model.url)
        let mtpPath = MtpLocator.mtpPath(alongside: model.url)
        let embeddedMTP = GGUFMetadata.hasMTP(at: model.url)
        let tools = model.isToolCapable || GGUFMetadata.suggestsTools(at: model.url)

        displayName = info?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? model.name
        architecture = info?.architecture.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? model.architecture.nilIfEmpty
            ?? String(localized: "Unknown")
        layers = layerCount > 0 ? "\(layerCount)" : String(localized: "Unknown")
        trainingContext = context.map { String.localizedStringWithFormat(String(localized: "%@ tokens"), "\($0)") } ?? String(localized: "Unknown")
        size = ByteCountFormatter.string(fromByteCount: Int64(model.sizeGB * 1_073_741_824.0), countStyle: .file)
        tokenizer = String(localized: "Embedded in GGUF")
        hasChatTemplate = template?.isEmpty == false
        chatTemplateStatus = hasChatTemplate ? String(localized: "Present") : String(localized: "Missing")
        chatTemplatePreview = template.map { Self.preview($0) }
        hasProjector = projectorPath != nil || mergedProjector || model.isMultimodal
        if let projectorPath {
            projector = URL(fileURLWithPath: projectorPath).lastPathComponent
        } else if mergedProjector {
            projector = String(localized: "Merged in GGUF")
        } else if model.isMultimodal {
            projector = String(localized: "Marked multimodal")
        } else {
            projector = String(localized: "Missing")
        }
        hasToolHints = tools
        toolHints = tools ? String(localized: "Detected") : String(localized: "Not detected")
        hasMTP = mtpPath != nil || embeddedMTP
        if let mtpPath {
            mtp = URL(fileURLWithPath: mtpPath).lastPathComponent
        } else if embeddedMTP {
            mtp = String(localized: "Embedded MTP head")
        } else {
            mtp = String(localized: "Missing")
        }
        isMoE = moeInfo?.isMoE == true
        moeStatus = isMoE ? String(localized: "Detected") : String(localized: "Dense")
        experts = moeInfo?.expertCount.nonzeroString ?? String(localized: "Unknown")
        moeLayers = Self.layerFraction(moeInfo?.moeLayerCount, moeInfo?.totalLayerCount)
        hiddenSize = moeInfo?.hiddenSize?.nonzeroString ?? String(localized: "Unknown")
        feedForwardSize = moeInfo?.feedForwardSize?.nonzeroString ?? String(localized: "Unknown")
        projectorFile = projectorPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "None")
        mtpFile = mtpPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "None")
    }

    /// Resolves the concrete `.gguf` file for a model whose URL may point at a
    /// containing directory, so the metadata reads target real bytes.
    private static func resolvedGGUFURL(for model: LocalModel) -> URL {
        var url = model.url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if let gguf = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                url = gguf
            }
        }
        return url
    }

    private static func preview(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 600 else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: 600)
        return String(collapsed[..<end]) + "..."
    }

    private static func layerFraction(_ moeLayers: Int?, _ totalLayers: Int?) -> String {
        guard let moeLayers, moeLayers > 0 else { return String(localized: "None") }
        if let totalLayers, totalLayers > 0 {
            return "\(moeLayers) / \(totalLayers)"
        }
        return "\(moeLayers)"
    }
}

private struct ModelMetadataExportPayload {
    let dictionary: [String: Any]

    init(model: LocalModel, snapshot: ModelMetadataInspectorSnapshot) {
        dictionary = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "model": [
                "id": model.modelID,
                "name": model.name,
                "format": model.format.rawValue,
                "quant": model.quant,
                "parameterCount": model.parameterCountLabel ?? "",
                "file": model.url.lastPathComponent,
                "installFolder": model.url.deletingLastPathComponent().lastPathComponent,
                "size": snapshot.size,
                "isMultimodal": model.isMultimodal,
                "isToolCapable": model.isToolCapable
            ],
            "architecture": [
                "displayName": snapshot.displayName,
                "architecture": snapshot.architecture,
                "layers": snapshot.layers,
                "trainingContext": snapshot.trainingContext
            ],
            "tokenizer": [
                "source": snapshot.tokenizer,
                "chatTemplate": snapshot.chatTemplateStatus
            ],
            "capabilities": [
                "visionProjector": snapshot.projector,
                "toolHints": snapshot.toolHints,
                "mtp": snapshot.mtp
            ],
            "moe": [
                "status": snapshot.moeStatus,
                "experts": snapshot.experts,
                "layers": snapshot.moeLayers,
                "hiddenSize": snapshot.hiddenSize,
                "feedForwardSize": snapshot.feedForwardSize
            ],
            "sidecars": [
                "projector": snapshot.projectorFile,
                "mtpDraftModel": snapshot.mtpFile
            ]
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Int {
    var nonzeroString: String? {
        self > 0 ? "\(self)" : nil
    }
}
