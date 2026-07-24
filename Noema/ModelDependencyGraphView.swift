import SwiftUI

struct ModelDependencyGraphSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openGraph: () -> Void

    private var snapshots: [ModelDependencySnapshot] {
        ModelDependencySnapshot.snapshots(for: modelManager.downloadedModels)
    }

    private var missingCount: Int {
        snapshots.reduce(0) { total, snapshot in
            total + snapshot.items.filter { $0.state == .missing }.count
        }
    }

    private var readyCount: Int {
        snapshots.filter { $0.isReady }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: missingCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(missingCount == 0 ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Model Dependencies"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(summaryText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openGraph) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Model Dependencies"))
            }

            HStack(spacing: 8) {
                ModelDependencyPill(title: LocalizedStringKey("Models"), value: "\(snapshots.count)")
                ModelDependencyPill(title: LocalizedStringKey("Ready"), value: "\(readyCount)")
                ModelDependencyPill(title: LocalizedStringKey("Missing"), value: "\(missingCount)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openGraph)
    }

    private var summaryText: String {
        guard !snapshots.isEmpty else {
            return String(localized: "No local models installed.")
        }
        if missingCount == 0 {
            return String(localized: "Weights, tokenizers, templates, projectors, and draft heads are mapped.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%d missing runtime dependencies"),
            missingCount
        )
    }
}

struct ModelDependencyGraphView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var downloadController: DownloadController
    @State private var searchText = ""
    @State private var isRepairing = false
    @State private var repairResults: [ModelDependencyRepairResult] = []
    @State private var maintenanceSummary: String?

    private var snapshots: [ModelDependencySnapshot] {
        ModelDependencySnapshot.snapshots(for: modelManager.downloadedModels)
    }

    private var filteredSnapshots: [ModelDependencySnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshots }
        return snapshots.filter { snapshot in
            let haystack = "\(snapshot.model.name) \(snapshot.model.modelID) \(snapshot.model.quant) \(snapshot.model.format.displayName) \(snapshot.items.map(\.title).joined(separator: " "))"
                .localizedCaseInsensitiveContains(query)
            return haystack
        }
    }

    private var missingCount: Int {
        snapshots.reduce(0) { total, snapshot in
            total + snapshot.items.filter { $0.state == .missing }.count
        }
    }

    private var warningCount: Int {
        snapshots.reduce(0) { total, snapshot in
            total + snapshot.items.filter { $0.state == .warning }.count
        }
    }

    private var repairCandidateCount: Int {
        snapshots.filter(\.needsRepair).count
    }

    var body: some View {
#if os(macOS)
        // The iOS Form renders badly inside the Mac settings sheet (clipped
        // labels, wrong insets, stock buttons), so macOS gets the shared
        // industrial card layout. The sheet already supplies the title + close.
        macBody
#else
        formBody
            .navigationTitle(LocalizedStringKey("Model Dependencies"))
#endif
    }

    private var formBody: some View {
        Form {
            Section(LocalizedStringKey("Dependency Graph")) {
                HStack(spacing: 8) {
                    ModelDependencyPill(title: LocalizedStringKey("Models"), value: "\(snapshots.count)")
                    ModelDependencyPill(title: LocalizedStringKey("Missing"), value: "\(missingCount)")
                    ModelDependencyPill(title: LocalizedStringKey("Ready"), value: "\(snapshots.filter(\.isReady).count)")
                }

                TextField(LocalizedStringKey("Search models"), text: $searchText)
                    .platformAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section(LocalizedStringKey("Repair Queue")) {
                Button {
                    Task { await repairAllModels() }
                } label: {
                    Label(
                        isRepairing ? LocalizedStringKey("Repairing Models...") : LocalizedStringKey("Repair All Models"),
                        systemImage: isRepairing ? "arrow.triangle.2.circlepath" : "wrench.and.screwdriver"
                    )
                }
                .disabled(isRepairing || snapshots.isEmpty)

                Text(LocalizedStringKey("Runs path rehoming, stale partial download cleanup, and queues downloads for resolvable missing artifacts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ModelDependencyPill(title: LocalizedStringKey("Candidates"), value: "\(repairCandidateCount)")
                    ModelDependencyPill(title: LocalizedStringKey("Warnings"), value: "\(warningCount)")
                }

                if let maintenanceSummary {
                    Label(maintenanceSummary, systemImage: "checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !repairResults.isEmpty {
                    ForEach(repairResults) { result in
                        ModelDependencyRepairResultRow(result: result)
                    }
                }
            }

            if snapshots.isEmpty {
                Section {
                    ContentUnavailableView(
                        LocalizedStringKey("No local models installed."),
                        systemImage: "square.stack.3d.down.right"
                    )
                }
            } else if filteredSnapshots.isEmpty {
                Section {
                    ContentUnavailableView(
                        LocalizedStringKey("No matching models"),
                        systemImage: "magnifyingglass"
                    )
                }
            } else {
                Section(LocalizedStringKey("Installed Model Dependencies")) {
                    ForEach(filteredSnapshots) { snapshot in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(snapshot.items) { item in
                                    ModelDependencyRow(item: item)
                                }
                            }
                            .padding(.vertical, 8)
                        } label: {
                            ModelDependencyModelLabel(snapshot: snapshot)
                        }
                    }
                }
            }
        }
    }

#if os(macOS)
    private var macBody: some View {
        MacSettingsPage {
            MacSettingsCard(LocalizedStringKey("Dependency Graph")) {
                MacSettingsKeyValueRow(title: LocalizedStringKey("Models"), value: "\(snapshots.count)", divider: false)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Missing"), value: "\(missingCount)")
                MacSettingsKeyValueRow(title: LocalizedStringKey("Ready"), value: "\(snapshots.filter(\.isReady).count)")
                MacSettingsControlRow(LocalizedStringKey("Search models")) {
                    TextField(LocalizedStringKey("Search models"), text: $searchText)
                        .labelsHidden()
                        .platformAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .industrialField(width: 200)
                }
            }

            MacSettingsCard(LocalizedStringKey("Repair Queue")) {
                MacSettingsActionRow(divider: false) {
                    Button {
                        Task { await repairAllModels() }
                    } label: {
                        Label(
                            isRepairing ? LocalizedStringKey("Repairing Models...") : LocalizedStringKey("Repair All Models"),
                            systemImage: isRepairing ? "arrow.triangle.2.circlepath" : "wrench.and.screwdriver"
                        )
                    }
                    .buttonStyle(.industrial(.prominent))
                    .disabled(isRepairing || snapshots.isEmpty)
                }

                MacSettingsNoteRow(LocalizedStringKey("Runs path rehoming, stale partial download cleanup, and queues downloads for resolvable missing artifacts."))

                MacSettingsKeyValueRow(title: LocalizedStringKey("Candidates"), value: "\(repairCandidateCount)")
                MacSettingsKeyValueRow(title: LocalizedStringKey("Warnings"), value: "\(warningCount)")

                if let maintenanceSummary {
                    MacSettingsRowContainer {
                        HStack(spacing: 8) {
                            Image(systemName: "checklist")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.4))
                            Text(verbatim: maintenanceSummary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }

                ForEach(repairResults) { result in
                    MacSettingsRowContainer {
                        ModelDependencyRepairResultRow(result: result)
                    }
                }
            }

            if snapshots.isEmpty {
                MacSettingsCard(LocalizedStringKey("Installed Model Dependencies")) {
                    MacSettingsNoteRow(LocalizedStringKey("No local models installed."), divider: false)
                }
            } else if filteredSnapshots.isEmpty {
                MacSettingsCard(LocalizedStringKey("Installed Model Dependencies")) {
                    MacSettingsNoteRow(LocalizedStringKey("No matching models"), divider: false)
                }
            } else {
                MacSettingsCard(LocalizedStringKey("Installed Model Dependencies")) {
                    ForEach(Array(filteredSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        MacDependencyDisclosure(snapshot: snapshot, divider: index != 0)
                    }
                }
            }
        }
    }
#endif

    @MainActor
    private func repairAllModels() async {
        isRepairing = true
        repairResults = []
        maintenanceSummary = nil

        modelManager.refresh()
        let maintenance = await downloadController.runDownloadMaintenance(manual: true, force: true)
        modelManager.refresh()
        maintenanceSummary = String.localizedStringWithFormat(
            String(localized: "Maintenance repaired %d artifacts, completed %d installs, removed %d stale files."),
            maintenance.repairedArtifacts,
            maintenance.repairedCompletions,
            maintenance.removedOrphanFiles + maintenance.removedResumeData + maintenance.removedJobs
        )

        let candidates = ModelDependencySnapshot
            .snapshots(for: modelManager.downloadedModels)
            .filter(\.needsRepair)

        guard !candidates.isEmpty else {
            repairResults = [
                ModelDependencyRepairResult(
                    modelName: String(localized: "All Models"),
                    detail: String(localized: "No missing dependencies after maintenance."),
                    state: .ready
                )
            ]
            isRepairing = false
            return
        }

        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
        let registry = HuggingFaceRegistry(token: token)
        var updatedResults: [ModelDependencyRepairResult] = []

        for snapshot in candidates {
            let result = await repair(snapshot: snapshot, registry: registry)
            updatedResults.append(result)
            repairResults = updatedResults
        }

        modelManager.refresh()
        isRepairing = false
    }

    @MainActor
    private func repair(snapshot: ModelDependencySnapshot, registry: HuggingFaceRegistry) async -> ModelDependencyRepairResult {
        let model = snapshot.model
        guard !model.modelID.hasPrefix("local/") else {
            return ModelDependencyRepairResult(
                modelName: model.name,
                detail: String(localized: "Manual import; add missing files next to the model weights."),
                state: .skipped
            )
        }

        guard model.format != .afm else {
            return ModelDependencyRepairResult(
                modelName: model.name,
                detail: String(localized: "System-managed model; no repair needed."),
                state: .ready
            )
        }

        do {
            let details = try await registry.details(for: model.modelID)
            guard let quant = matchingQuant(for: model, in: details.quants) else {
                return ModelDependencyRepairResult(
                    modelName: model.name,
                    detail: String(localized: "No matching quant found in the model registry."),
                    state: .skipped
                )
            }

            downloadController.start(detail: details, quant: quant)
            return ModelDependencyRepairResult(
                modelName: model.name,
                detail: String.localizedStringWithFormat(
                    String(localized: "Queued repair download for %d runtime issues."),
                    snapshot.issueCount
                ),
                state: .queued
            )
        } catch {
            return ModelDependencyRepairResult(
                modelName: model.name,
                detail: String.localizedStringWithFormat(
                    String(localized: "Could not read model registry: %@"),
                    error.localizedDescription
                ),
                state: .failed
            )
        }
    }

    private func matchingQuant(for model: LocalModel, in quants: [QuantInfo]) -> QuantInfo? {
        quants.first { quant in
            guard quant.format == model.format else { return false }
            return quant.label.compare(model.quant, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        } ?? quants.first { quant in
            guard quant.format == model.format else { return false }
            let localName = model.url.lastPathComponent
            return quant.primaryDownloadRelativePath.caseInsensitiveCompare(localName) == .orderedSame ||
                quant.downloadURL.lastPathComponent.caseInsensitiveCompare(localName) == .orderedSame
        }
    }
}

private struct ModelDependencySnapshot: Identifiable {
    let id: String
    let model: LocalModel
    let items: [ModelDependencyItem]

    var isReady: Bool {
        !items.contains { $0.state == .missing }
    }

    var needsRepair: Bool {
        items.contains { $0.state == .missing || $0.state == .warning }
    }

    var issueCount: Int {
        items.filter { $0.state == .missing || $0.state == .warning }.count
    }

    static func snapshots(for models: [LocalModel]) -> [Self] {
        models
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(Self.init(model:))
    }

    init(model: LocalModel) {
        self.id = model.id
        self.model = model
        self.items = Self.items(for: model)
    }

    private static func items(for model: LocalModel) -> [ModelDependencyItem] {
        let directory = dependencyDirectory(for: model)
        let fm = FileManager.default
        let settingsResolution = ModelSettings.resolvedLocalSettings(for: model)
        let tokenizerPath = ModelSettings.resolvedTokenizerPath(for: model)
        let configURL = directory.appendingPathComponent("config.json")
        let artifactsURL = directory.appendingPathComponent("artifacts.json")
        let projectorPath = model.format == .gguf ? ProjectorLocator.projectorPath(alongside: model.url) : nil
        let mergedProjector = model.format == .gguf && GGUFMetadata.hasMultimodalProjector(at: model.url)
        let wantsVision = model.isMultimodal || projectorPath != nil || mergedProjector
        let mtpPath = model.format == .gguf ? MtpLocator.mtpPath(alongside: model.url) : nil
        let embeddedMTP = model.format == .gguf && GGUFMetadata.hasMTP(at: model.url)

        var items: [ModelDependencyItem] = []

        items.append(
            ModelDependencyItem(
                title: String(localized: "Weights"),
                detail: model.url.lastPathComponent,
                state: fm.fileExists(atPath: model.url.path) ? .ready : .missing,
                systemImage: "shippingbox"
            )
        )

        let tokenizerDetail: String
        let tokenizerState: ModelDependencyState
        if model.format == .afm {
            tokenizerDetail = String(localized: "Managed by Apple Foundation Models")
            tokenizerState = .optional
        } else if let tokenizerPath,
                  fm.fileExists(atPath: tokenizerPath) {
            tokenizerDetail = URL(fileURLWithPath: tokenizerPath).lastPathComponent
            tokenizerState = .ready
        } else if let tokenizerURL = firstExisting(
            in: directory,
            names: ["tokenizer.json", "tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]
        ) {
            tokenizerDetail = tokenizerURL.lastPathComponent
            tokenizerState = .ready
        } else if model.format == .gguf {
            tokenizerDetail = String(localized: "Built into GGUF or backend")
            tokenizerState = .optional
        } else {
            tokenizerDetail = String(localized: "Missing")
            tokenizerState = .missing
        }
        items.append(ModelDependencyItem(title: String(localized: "Tokenizer"), detail: tokenizerDetail, state: tokenizerState, systemImage: "textformat.abc"))

        if fm.fileExists(atPath: configURL.path) {
            items.append(ModelDependencyItem(title: String(localized: "Configuration"), detail: configURL.lastPathComponent, state: .ready, systemImage: "gearshape"))
        } else {
            let state: ModelDependencyState = model.format == .gguf || model.format == .afm ? .optional : .warning
            items.append(ModelDependencyItem(title: String(localized: "Configuration"), detail: String(localized: "Missing"), state: state, systemImage: "gearshape"))
        }

        if settingsResolution.settings.promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            items.append(
                ModelDependencyItem(
                    title: String(localized: "Chat Template"),
                    detail: settingsResolution.promptTemplateSource.rawValue,
                    state: .ready,
                    systemImage: "text.bubble"
                )
            )
        } else {
            items.append(ModelDependencyItem(title: String(localized: "Chat Template"), detail: String(localized: "Family default"), state: .optional, systemImage: "text.bubble"))
        }

        if wantsVision {
            if let projectorPath {
                items.append(ModelDependencyItem(title: String(localized: "Projector"), detail: URL(fileURLWithPath: projectorPath).lastPathComponent, state: .ready, systemImage: "photo.on.rectangle.angled"))
            } else if mergedProjector {
                items.append(ModelDependencyItem(title: String(localized: "Projector"), detail: String(localized: "Merged in GGUF"), state: .ready, systemImage: "photo.on.rectangle.angled"))
            } else {
                items.append(ModelDependencyItem(title: String(localized: "Projector"), detail: String(localized: "Missing"), state: .missing, systemImage: "photo.on.rectangle.angled"))
            }
        } else {
            items.append(ModelDependencyItem(title: String(localized: "Projector"), detail: String(localized: "Text-only"), state: .optional, systemImage: "photo"))
        }

        if let mtpPath {
            items.append(ModelDependencyItem(title: String(localized: "MTP Draft Head"), detail: URL(fileURLWithPath: mtpPath).lastPathComponent, state: .ready, systemImage: "bolt.badge.clock"))
        } else if embeddedMTP {
            items.append(ModelDependencyItem(title: String(localized: "MTP Draft Head"), detail: String(localized: "Embedded in GGUF"), state: .ready, systemImage: "bolt.badge.clock"))
        } else {
            items.append(ModelDependencyItem(title: String(localized: "MTP Draft Head"), detail: String(localized: "Not installed"), state: .optional, systemImage: "bolt.badge.clock"))
        }

        items.append(
            ModelDependencyItem(
                title: String(localized: "Artifacts Manifest"),
                detail: fm.fileExists(atPath: artifactsURL.path) ? artifactsURL.lastPathComponent : String(localized: "Not installed"),
                state: fm.fileExists(atPath: artifactsURL.path) ? .ready : .optional,
                systemImage: "doc.badge.gearshape"
            )
        )

        return items
    }

    private static func dependencyDirectory(for model: LocalModel) -> URL {
        switch model.format {
        case .gguf, .et:
            return model.url.deletingLastPathComponent()
        case .mlx, .ane, .afm, .coreai:
            return InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
        }
    }

    private static func firstExisting(in directory: URL, names: [String]) -> URL? {
        for name in names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

private struct ModelDependencyItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let state: ModelDependencyState
    let systemImage: String
}

private struct ModelDependencyRepairResult: Identifiable {
    let id = UUID()
    let modelName: String
    let detail: String
    let state: ModelDependencyRepairState
}

private enum ModelDependencyRepairState {
    case queued
    case skipped
    case failed
    case ready

    var title: LocalizedStringKey {
        switch self {
        case .queued: return "Queued"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        case .ready: return "Ready"
        }
    }

    var tint: Color {
        switch self {
        case .queued: return .blue
        case .skipped: return .secondary
        case .failed: return .red
        case .ready: return .green
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "arrow.down.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.circle.fill"
        }
    }
}

private enum ModelDependencyState {
    case ready
    case missing
    case optional
    case warning

    var title: LocalizedStringKey {
        switch self {
        case .ready: return "Ready"
        case .missing: return "Missing"
        case .optional: return "Optional"
        case .warning: return "Warning"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .missing: return .red
        case .optional: return .secondary
        case .warning: return .orange
        }
    }
}

private struct ModelDependencyRepairResultRow: View {
    let result: ModelDependencyRepairResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.state.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(result.state.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: result.modelName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: result.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(result.state.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(result.state.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(result.state.tint.opacity(0.12), in: Capsule())
        }
    }
}

private struct ModelDependencyModelLabel: View {
    let snapshot: ModelDependencySnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(snapshot.isReady ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: snapshot.model.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: "\(snapshot.model.format.displayName) · \(snapshot.model.quant)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ModelDependencyRow: View {
    let item: ModelDependencyItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.state.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(verbatim: item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Text(item.state.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.state.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(item.state.tint.opacity(0.12), in: Capsule())
        }
    }
}

private struct ModelDependencyPill: View {
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

#if os(macOS)
/// The Form's per-model `DisclosureGroup` rebuilt in the industrial dialect:
/// the existing status label as a tappable header over the model's item rows.
private struct MacDependencyDisclosure: View {
    let snapshot: ModelDependencySnapshot
    var divider: Bool = true

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ModelDependencyModelLabel(snapshot: snapshot)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.items) { item in
                        ModelDependencyRow(item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
    }
}
#endif
