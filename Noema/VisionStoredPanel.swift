#if os(visionOS)
import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct VisionStoredPanel: View {
    @EnvironmentObject private var vm: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var walkthrough: GuidedWalkthroughManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @AppStorage("offGrid") private var offGrid = false
    @AppStorage("hideGGUFOffloadWarning") private var hideGGUFOffloadWarning = false

    @State private var loadingModelID: LocalModel.ID?
    @State private var selectedModel: LocalModel?
    @State private var selectedDataset: LocalDataset?
    @State private var selectedRemoteID: IdentifiableBackendID?
    @State private var showRemoteBackendForm = false
    @State private var showImporter = false
    @State private var importNotice: String?
    @State private var pendingPickedURLs: [URL] = []
    @State private var showNameSheet = false
    @State private var datasetName: String = ""
    @State private var importedDataset: LocalDataset?
    @State private var askStartIndexing = false
    @State private var datasetToIndex: LocalDataset?
    @State private var showOffloadWarning = false
    @State private var pendingLoad: (LocalModel, ModelSettings)?
    @State private var datasetPendingDeletion: LocalDataset?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    modelsSection
                    if !modelManager.remoteBackends.isEmpty {
                        remoteSection
                    }
                    if !modelManager.downloadedDatasets.isEmpty {
                        datasetsSection
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onAppear {
            modelManager.refresh()
            modelManager.refreshRemoteBackends(offGrid: offGrid)
        }
        .onChangeCompat(of: offGrid) { _, newValue in
            if !newValue {
                modelManager.refreshRemoteBackends(offGrid: false)
            }
        }
        .sheet(item: $selectedModel) { model in
            ModelSettingsView(model: model) { settings in
                load(model, settings: settings)
            }
            .environmentObject(modelManager)
            .environmentObject(vm)
            .environmentObject(walkthrough)
        }
        .sheet(item: $selectedDataset) { ds in
            LocalDatasetDetailView(dataset: ds)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(vm)
        }
        .sheet(item: $importedDataset) { ds in
            LocalDatasetDetailView(dataset: ds)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(vm)
        }
        .sheet(item: $selectedRemoteID) { backendID in
            NavigationStack {
                RemoteBackendDetailView(backendID: backendID.id)
                    .environmentObject(modelManager)
                    .environmentObject(vm)
                    .environmentObject(tabRouter)
            }
        }
        .sheet(isPresented: $showRemoteBackendForm) {
            RemoteBackendFormView { draft in
                try await modelManager.addRemoteBackend(from: draft)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: allowedUTTypes(),
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let accepted = urls.filter { allowedExtensions().contains($0.pathExtension.lowercased()) || TranscriptionMediaSupport.isSupported($0) }
                guard !accepted.isEmpty else {
                    // Everything picked was unsupported (e.g. CSV/TSV) — tell the user
                    // instead of silently doing nothing.
                    importNotice = DatasetDocumentSupport.skippedMessage(for: urls)
                    return
                }
                pendingPickedURLs = accepted
                datasetName = suggestName(from: accepted) ?? String(localized: "Imported Dataset")
                showNameSheet = true
            case .failure:
                break
            }
        }
        .datasetImportNotice($importNotice)
        .sheet(isPresented: $showNameSheet) {
            DatasetImportNamePromptView(
                datasetName: $datasetName,
                onCancel: { showNameSheet = false },
                onImport: { await performImport() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(item: $datasetManager.embedAlert) { info in
            Alert(title: Text(info.message))
        }
        .confirmationDialog(
            String(localized: "Model doesn't support GPU offload"),
            isPresented: $showOffloadWarning,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("Load")) {
                if let (model, settings) = pendingLoad {
                    load(model, settings: settings, bypassWarning: true)
                    pendingLoad = nil
                }
            }
            Button(LocalizedStringKey("Don't show again")) {
                hideGGUFOffloadWarning = true
                if let (model, settings) = pendingLoad {
                    load(model, settings: settings, bypassWarning: true)
                    pendingLoad = nil
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingLoad = nil
            }
        } message: {
            if DeviceGPUInfo.supportsGPUOffload {
                Text(LocalizedStringKey("This model doesn't support GPU offload and generation speed will be significantly slower. Consider switching to an MLX model."))
            } else {
                Text(LocalizedStringKey("This model doesn't support GPU offload and generation speed will be significantly slower. Fastest option on this device: use an ET model."))
            }
        }
        .alert(
            datasetDeleteConfirmationTitle,
            isPresented: Binding(
                get: { datasetPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        datasetPendingDeletion = nil
                    }
                }
            )
        ) {
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                guard let dataset = datasetPendingDeletion else { return }
                datasetPendingDeletion = nil
                try? datasetManager.delete(dataset)
                if selectedDataset?.datasetID == dataset.datasetID {
                    selectedDataset = nil
                }
                if importedDataset?.datasetID == dataset.datasetID {
                    importedDataset = nil
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                datasetPendingDeletion = nil
            }
        } message: {
            Text(LocalizedStringKey("This will remove the dataset and its embeddings from this device."))
        }
        .confirmationDialog(LocalizedStringKey("Start indexing now?"), isPresented: $askStartIndexing, titleVisibility: .visible) {
            Button(LocalizedStringKey("Start")) {
                if let ds = datasetToIndex {
                    datasetManager.startIndexing(dataset: ds)
                }
            }
            Button(LocalizedStringKey("Later"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("We'll extract text and prepare embeddings. You can also start later from the dataset details."))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library")
                    .font(.title2.weight(.semibold))
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    showRemoteBackendForm = true
                } label: {
                    Label("Add Remote", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Add remote endpoint")

                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Import Dataset")
            }
        }
    }

    private var summaryText: String {
        let models = modelManager.downloadedModels.count
        let datasets = modelManager.downloadedDatasets.count
        let remotes = modelManager.remoteBackends.count
        return "\(models) models • \(datasets) datasets • \(remotes) remotes"
    }

    private var afmHiddenNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Foundation Model is hidden. You can re-enable it in Settings.")
                .font(.body)
                .foregroundStyle(.primary)
            Button {
                tabRouter.dismissAFMHiddenNotice()
                tabRouter.selection = .settings
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var modelsSection: some View {
        sectionContainer {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Models")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
        } content: {
            if tabRouter.isAFMHiddenNoticeVisible {
                afmHiddenNotice
            }
            if modelManager.downloadedModels.isEmpty {
                emptyLibraryPrompt
            } else {
                VStack(spacing: 12) {
                    ForEach(modelManager.downloadedModels, id: \.id) { model in
                        modelCard(for: model)
                            .contextMenu {
                                Button("Open Settings") {
                                    selectedModel = model
                                }
                                if model.format != .afm {
                                    Button("Delete", role: .destructive) {
                                        Task { @MainActor in
                                            if modelManager.loadedModel?.id == model.id {
                                                await vm.unload()
                                            }
                                            modelManager.delete(model)
                                        }
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    private var remoteSection: some View {
        sectionContainer {
            HStack(alignment: .firstTextBaseline) {
                Text("Remote Backends")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
        } content: {
            if modelManager.remoteBackends.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No remote endpoints configured yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        showRemoteBackendForm = true
                    } label: {
                        Label("Add Remote Endpoint", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(modelManager.remoteBackends, id: \.id) { backend in
                        remoteCard(for: backend)
                            .contextMenu {
                                Button("Open Details") {
                                    selectedRemoteID = IdentifiableBackendID(id: backend.id)
                                }
                                Button("Delete", role: .destructive) {
                                    modelManager.deleteRemoteBackend(id: backend.id)
                                }
                            }
                    }
                }
            }
        }
    }

    private var datasetsSection: some View {
        sectionContainer {
            HStack(alignment: .firstTextBaseline) {
                Text("Datasets")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
        } content: {
            if modelManager.downloadedDatasets.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No datasets imported yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Dataset", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(modelManager.downloadedDatasets) { dataset in
                        datasetCard(for: dataset)
                            .contextMenu {
                                Button("Open Details") {
                                    selectedDataset = dataset
                                }
                                Button("Delete", role: .destructive) {
                                    datasetPendingDeletion = dataset
                                }
                            }
                    }
                }
            }
        }
    }

    private var datasetDeleteConfirmationTitle: String {
        guard let dataset = datasetPendingDeletion else { return String(localized: "Delete") }
        return String.localizedStringWithFormat(String(localized: "Delete %@?"), dataset.name)
    }

    @ViewBuilder
    private func sectionContainer<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header()
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(sectionBorderColor, lineWidth: 1)
        )
    }

    private var emptyLibraryPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No models yet")
                .font(.subheadline.weight(.semibold))
            Text("Download a model from Explore or add a remote endpoint to get started.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut) {
                        tabRouter.selection = .explore
                    }
                } label: {
                    Label("Explore", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showRemoteBackendForm = true
                } label: {
                    Label("Remote", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func modelCard(for model: LocalModel) -> some View {
        let isActive = modelManager.loadedModel?.id == model.id
        let isLoading = loadingModelID == model.id

        let displayName = formattedDisplayName(for: model)
        let vendor = model.modelID.split(separator: "/").first.map(String.init) ?? model.modelID
        let chips = modelChips(for: model)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if model.isFavourite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if model.isReasoningModel {
                            Image(systemName: "brain")
                                .foregroundStyle(.purple)
                        }
                        if UIConstants.showMultimodalUI && model.isMultimodal {
                            Image(systemName: "eye")
                        }
                        if model.isToolCapable {
                            Image(systemName: "hammer")
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(vendor)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    WrappingChipLayout() {
                        ForEach(chips) { chip in
                            chipView(chip)
                        }
                    }
                }
                Spacer()
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                } else if isLoading {
                    ProgressView()
                }
            }

            HStack(spacing: 18) {
                Button {
                    if isActive {
                        Task { await vm.unload() }
                    } else {
                        load(model)
                    }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .frame(width: 48, height: 48)
                                .padding(6)
                                .background(Circle().fill(Color.accentColor.opacity(0.35)))
                        } else {
                            IconCircle(
                                systemImage: isActive ? "eject" : "play.fill",
                                foreground: .white,
                                background: isActive ? .orange : .accentColor
                            )
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel(isActive ? "Unload model" : "Load model")

                Button {
                    selectedModel = model
                } label: {
                    IconCircle(
                        systemImage: "slider.horizontal.3",
                        foreground: .primary,
                        background: Color.secondary.opacity(0.15)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Model settings")

                if model.format != .afm {
                    Button(role: .destructive) {
                        Task { @MainActor in
                            if modelManager.loadedModel?.id == model.id {
                                await vm.unload()
                            }
                            modelManager.delete(model)
                        }
                    } label: {
                        IconCircle(
                            systemImage: "trash",
                            foreground: .red,
                            background: Color.red.opacity(0.15)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete model")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
    }

    private func remoteCard(for backend: RemoteBackend) -> some View {
        Button {
            selectedRemoteID = IdentifiableBackendID(id: backend.id)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(backend.name)
                        .font(.subheadline.weight(.semibold))
                    Text(backend.baseURLString.isEmpty ? backend.endpointType.displayName : backend.baseURLString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if offGrid {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.orange)
                } else if modelManager.remoteBackendsFetching.contains(backend.id) {
                    ProgressView()
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(cardBorderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func datasetCard(for dataset: LocalDataset) -> some View {
        Button {
            selectedDataset = dataset
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dataset.name)
                        .font(.subheadline.weight(.semibold))
                    Text(datasetSizeLabel(for: dataset))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if datasetManager.indexingDatasetID == dataset.datasetID {
                    ProgressView()
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(cardBorderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func datasetSizeLabel(for dataset: LocalDataset) -> String {
        localizedFileSizeString(bytes: Int64(dataset.sizeMB * 1_048_576.0), locale: locale)
    }

    private func formattedDisplayName(for model: LocalModel) -> String {
        guard !model.quant.isEmpty else { return model.name }
        return model.name
            .replacingOccurrences(of: "-\(model.quant)", with: "")
            .replacingOccurrences(of: ".\(model.quant)", with: "")
    }

    private func modelChips(for model: LocalModel) -> [ModelChip] {
        var chips: [ModelChip] = []
        let hidesArchitectureAndMoEChips = model.format == .et || model.format == .ane || model.format == .afm

        if !model.quant.isEmpty && model.format != .ane {
            let quantLabel = QuantExtractor.shortLabel(from: model.quant, format: model.format)
            chips.append(
                ModelChip(
                    text: quantLabel,
                    background: .fill(Color.accentColor.opacity(0.2)),
                    foreground: .accentColor
                )
            )
        }
        if let source = model.slmSourceFormatLabel {
            chips.append(
                ModelChip(
                    text: source,
                    background: .fill(Color.secondary.opacity(0.15)),
                    foreground: .secondary
                )
            )
        }
        chips.append(
            ModelChip(
                text: model.format.displayName,
                background: .gradient(model.format.tagGradient),
                foreground: .white
            )
        )
        if !hidesArchitectureAndMoEChips {
            if !model.architectureFamily.isEmpty {
                chips.append(
                    ModelChip(
                        text: model.architectureFamily.uppercased(),
                        background: .fill(Color.secondary.opacity(0.15)),
                        foreground: .secondary
                    )
                )
            }
            if let moeInfo = model.moeInfo {
                let isMoE = moeInfo.isMoE
                let tint = isMoE ? Color.orange : Color.secondary
                chips.append(
                    ModelChip(
                        text: isMoE ? "MoE" : "Dense",
                        background: .fill(tint.opacity(0.2)),
                        foreground: tint
                    )
                )
            } else {
                chips.append(
                    ModelChip(
                        text: "Checking…",
                        background: .stroke(Color.secondary.opacity(0.3)),
                        foreground: .secondary
                    )
                )
            }
        }
        return chips
    }

    @ViewBuilder
    private func chipView(_ chip: ModelChip) -> some View {
        Text(chip.text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                switch chip.background {
                case .fill(let color):
                    Capsule().fill(color)
                case .gradient(let gradient):
                    Capsule().fill(gradient)
                case .stroke(let color):
                    Capsule().stroke(color, lineWidth: 1)
                }
            }
            .foregroundStyle(chip.foreground)
    }

    private struct ModelChip: Identifiable {
        enum Background {
            case fill(Color)
            case gradient(LinearGradient)
            case stroke(Color)
        }

        let id = UUID()
        let text: String
        let background: Background
        let foreground: Color
    }

    private struct IconCircle: View {
        let systemImage: String
        let foreground: Color
        let background: Color
        var size: CGFloat = 56

        var body: some View {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(foreground)
                .background(
                    Circle()
                        .fill(background)
                        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
                )
                .contentShape(Circle())
        }
    }

    private struct WrappingChipLayout: Layout {
        var horizontalSpacing: CGFloat = 8
        var verticalSpacing: CGFloat = 8

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard !subviews.isEmpty else { return .zero }

            let maxWidth = proposal.width ?? .infinity

            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var rowHeight: CGFloat = 0
            var usedWidth: CGFloat = 0

            let widthProposal: CGFloat? = maxWidth.isFinite ? maxWidth : nil

            for (index, subview) in subviews.enumerated() {
                let size = subview.sizeThatFits(
                    ProposedViewSize(width: widthProposal, height: nil)
                )
                if currentX > 0 && currentX + size.width > maxWidth {
                    currentX = 0
                    currentY += rowHeight + verticalSpacing
                    rowHeight = 0
                }

                rowHeight = max(rowHeight, size.height)
                currentX += size.width
                usedWidth = max(usedWidth, currentX)

                if index != subviews.count - 1 {
                    currentX += horizontalSpacing
                }
            }

            return CGSize(
                width: min(usedWidth, maxWidth),
                height: currentY + rowHeight
            )
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard !subviews.isEmpty else { return }

            var x = bounds.minX
            var y = bounds.minY
            var rowHeight: CGFloat = 0

            let widthProposal: CGFloat? = bounds.width.isFinite ? bounds.width : nil

            for (index, subview) in subviews.enumerated() {
                let size = subview.sizeThatFits(
                    ProposedViewSize(width: widthProposal, height: nil)
                )
                if x > bounds.minX && x + size.width > bounds.maxX {
                    x = bounds.minX
                    y += rowHeight + verticalSpacing
                    rowHeight = 0
                }

                subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width
                rowHeight = max(rowHeight, size.height)

                if index != subviews.count - 1 {
                    x += horizontalSpacing
                }
            }
        }
    }

    private var sectionBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var cardBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private func allowedUTTypes() -> [UTType] { DatasetDocumentSupport.allowedUTTypes() }

    private func allowedExtensions() -> Set<String> { DatasetDocumentSupport.acceptedExtensions }

    private func suggestName(from urls: [URL]) -> String? {
        guard let first = urls.first else { return nil }
        let base = first.deletingPathExtension().lastPathComponent
        return base.isEmpty ? nil : base
    }

    private func performImport() async {
        showNameSheet = false
        let name = datasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dataset = await datasetManager.importDocuments(from: pendingPickedURLs, suggestedName: name)
        if let dataset {
            importedDataset = dataset
            pendingPickedURLs = []
            datasetName = ""
            datasetToIndex = dataset
            askStartIndexing = true
        }
    }

    private struct IdentifiableBackendID: Identifiable {
        let id: RemoteBackend.ID
    }

    private func load(_ model: LocalModel, settings: ModelSettings? = nil, bypassWarning: Bool = false) {
        let resolvedSettings = settings ?? modelManager.settings(for: model)
        if model.format == .gguf && !DeviceGPUInfo.supportsGPUOffload && !hideGGUFOffloadWarning && !bypassWarning {
            pendingLoad = (model, resolvedSettings)
            showOffloadWarning = true
            return
        }
        loadingModelID = model.id
        Task { @MainActor in
            let settings = modelManager.normalizeLocalSettings(resolvedSettings, for: model)
            await vm.unload()
            try? await Task.sleep(nanoseconds: 200_000_000)

            let bypass = UserDefaults.standard.bool(forKey: "bypassRAMCheck")
            if !bypass {
                let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
                let ctx = Int(settings.contextLength)
                let layerHint: Int? = model.totalLayers > 0 ? model.totalLayers : nil
                let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
                if !ModelRAMAdvisor.fitsInRAM(
                    format: model.format,
                    sizeBytes: sizeBytes,
                    contextLength: ctx,
                    layerCount: layerHint,
                    moeInfo: model.moeInfo,
                    kvCacheEstimate: kvCacheEstimate
                ) {
                    AppSoundPlayer.play(.error)
                    Haptics.error()
                    vm.loadError = "Model likely exceeds memory budget. Lower context size or use a smaller quant/model."
                    loadingModelID = nil
                    return
                }
            }

            UserDefaults.standard.set(true, forKey: "bypassRAMLoadPending")
            var loadURL = model.url
            switch model.format {
            case .gguf:
                loadURL = resolveGGUFURL(from: loadURL, model: model)
                if loadURL == model.url && !FileManager.default.fileExists(atPath: loadURL.path) {
                    loadingModelID = nil
                    return
                }
            case .mlx:
                loadURL = resolveMLXURL(from: loadURL, model: model)
            case .et, .ane:
                break
            case .afm:
                loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: model.modelID)
                try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            case .coreai:
                loadURL = InstalledModelsStore.baseDir(for: .coreai, modelID: model.modelID)
                try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            }

            let success = await vm.load(url: loadURL, settings: settings, format: model.format)
            if success {
                modelManager.updateSettings(settings, for: model)
                modelManager.markModelUsed(model)
            } else {
                modelManager.loadedModel = nil
            }
            loadingModelID = nil
            UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
        }
    }

    private func resolveGGUFURL(from url: URL, model: LocalModel) -> URL {
        var loadURL = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
            if isDir.boolValue {
                if let file = try? FileManager.default.contentsOfDirectory(at: loadURL, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                    loadURL = file
                }
            } else if loadURL.pathExtension.lowercased() != "gguf" {
                if let alt = try? FileManager.default.contentsOfDirectory(at: loadURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                    loadURL = alt
                }
            }
        } else {
            if let alt = InstalledModelsStore.firstGGUF(in: InstalledModelsStore.baseDir(for: .gguf, modelID: model.modelID)) {
                loadURL = alt
            }
        }
        return loadURL
    }

    private func resolveMLXURL(from url: URL, model: LocalModel) -> URL {
        var loadURL = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                loadURL = loadURL.deletingLastPathComponent()
            }
        } else {
            loadURL = InstalledModelsStore.baseDir(for: .mlx, modelID: model.modelID)
        }
        return loadURL
    }
}
#endif
