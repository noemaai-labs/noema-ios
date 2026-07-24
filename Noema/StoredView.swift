#if os(iOS) || os(visionOS) || os(macOS)
import SwiftUI
import Foundation
import UniformTypeIdentifiers
import PDFKit
import NoemaPackages
#if os(macOS)
import AppKit
#endif

/// Keeps high-frequency support-model progress inside the two-row section instead
/// of invalidating the entire Stored screen.
private struct SupportModelDownloadItems<Content: View>: View {
    @EnvironmentObject private var downloadController: DownloadController
    @ObservedObject private var presentationUpdates = DownloadPresentationUpdates.shared
    @State private var availabilityRevision = 0
    @State private var items: [SupportModelInventoryItem] = []
    let content: ([SupportModelInventoryItem]) -> Content

    init(@ViewBuilder content: @escaping ([SupportModelInventoryItem]) -> Content) {
        self.content = content
    }

    var body: some View {
        content(items)
            .task(id: availabilityRevision) {
                await refreshItems()
            }
            .onReceive(presentationUpdates.objectWillChange) { _ in
                availabilityRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .embeddingModelAvailabilityChanged)) { _ in
                availabilityRevision &+= 1
            }
    }

    private func refreshItems() async {
        let whisperItems = downloadController.whisperItems
        let embeddingItems = downloadController.embeddingItems
#if canImport(TTSKit) && !arch(x86_64)
        let voiceStore = VoiceModelDownloadStore.shared
        let voiceIsDownloading = voiceStore.isDownloading
        let voiceProgress = voiceStore.progress
#endif

        let refreshed = await Task.detached(priority: .utility) {
            var values = [
                SupportModelInventory.speechItem(whisperItems: whisperItems),
                SupportModelInventory.embeddingItem(embeddingItems: embeddingItems)
            ]
#if canImport(TTSKit) && !arch(x86_64)
            values.append(
                SupportModelInventory.voiceItem(
                    installState: VoiceModelCatalog.installState(),
                    isDownloading: voiceIsDownloading,
                    progress: voiceProgress
                )
            )
#endif
            return values
        }.value

        guard !Task.isCancelled else { return }
        items = refreshed
    }
}

struct ModelRow: View {
    let model: LocalModel
    let isLoading: Bool
    var isLoaded: Bool = false
    var settingsAction: (() -> Void)? = nil
    var deleteAction: (() -> Void)? = nil
    /// Stored rows opt in; the iOS selector sheet already renders its own
    /// paged chip below the row, so this defaults off to avoid doubling up.
    var showsPagedFitStatus: Bool = false
    let loadAction: () -> Void
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var modelManager: AppModelManager

    /// Noema Teams: model exists locally but the active policy forbids loading it.
    /// It stays on disk — the user decides whether to keep or delete it.
    private var lockedByPolicy: Bool {
        EnterprisePolicyGate.isActive &&
            (!EnterprisePolicyGate.allowsModel(modelID: model.modelID) ||
             !EnterprisePolicyGate.allowsModelFormat(model.format))
    }

    var body: some View {
        let hidesArchitectureAndMoEChips = model.format == .ane || model.format == .afm
        let hidesStoredSize = model.format == .afm
        let displayName = model.displayName

        let rowContent = HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if lockedByPolicy {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(Text(LocalizedStringKey("Locked by your organization's policy")))
                    }
                    if model.isFavourite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow)
                    }
                    Text(displayName)
                        .font(FontTheme.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.text)
                    
                    if model.isReasoningModel {
                        Image(systemName: "brain")
                            .font(.system(size: 12))
                            .foregroundColor(.purple)
                    }
                    if UIConstants.showMultimodalUI && model.isMultimodal {
                        Image(systemName: "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    if model.isToolCapable {
                        Image(systemName: "hammer")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                }
                
                Text(model.modelID.split(separator: "/").first.map(String.init) ?? model.modelID)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)

                // Minimalist metadata
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(model.format.tagGradient)
                            .frame(width: 6, height: 6)
                        Text(model.format.displayName)
                    }
                    
                    if !model.quant.isEmpty && model.format != .ane {
                        Text("·")
                        Text(QuantExtractor.shortLabel(from: model.quant, format: model.format))
                    }
                    if model.format != .et && !hidesArchitectureAndMoEChips {
                        if !model.architectureFamily.isEmpty {
                            Text("·")
                            Text(model.architectureFamily.uppercased())
                        }
                        if let moeInfo = model.moeInfo {
                            Text("·")
                            Text(moeInfo.isMoE ? "MoE" : "DENSE")
                        }
                    }
                    if model.format == .et {
                        let backend = modelManager.displayETBackend(for: model).displayName
                        Text("·")
                        Text(backend)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.top, 2)

                // Paged verdict + canary lookup are memoized per URL, so list
                // scrolling never stats the disk.
                if showsPagedFitStatus, model.format == .gguf, OverfitPagedInstallCache.isPaged(model.url) {
                    Group {
                        if let classification = OverfitPagedFitCache.classification(forModelAt: model.url) {
                            OverfitClassificationChip(classification: classification)
                        } else {
                            OverfitPagedChip()
                        }
                    }
                    .padding(.top, 2)
                }

                if AppleFoundationModelKind.resolve(modelID: model.modelID) == .privateCloudCompute {
                    Text(ApplePrivateCloudComputeAvailability.status.message)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(
                            ApplePrivateCloudComputeAvailability.status.isAvailableForRequests
                                ? AppTheme.secondaryText
                                : Color.orange
                        )
                }
            }
            Spacer()
            
            VStack(alignment: .trailing, spacing: 6) {
                if !hidesStoredSize {
                    Text(String(format: "%.1f GB", model.sizeGB))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                
                if lockedByPolicy {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                        Text(LocalizedStringKey("Locked"))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else if !isLoaded {
                    #if os(macOS)
                    HStack(spacing: 6) {
                        if let settingsAction {
                            IndustrialIconButton(
                                systemImage: "gearshape",
                                help: LocalizedStringKey("Model settings")
                            ) {
                                settingsAction()
                            }
                            .disabled(isLoading || vm.loading)
                        }
                        macLoadButton
                    }
                    #else
                    loadButton
                    #endif
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text(LocalizedStringKey("Loaded"))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hidesStoredSize ? displayName : String.localizedStringWithFormat(String(localized: "%1$@, size %2$@ GB"), displayName, String(format: "%.1f", model.sizeGB)))

        if let settingsAction, let deleteAction {
            rowContent
                .accessibilityAction(named: Text(LocalizedStringKey("Model Settings")), settingsAction)
                .accessibilityAction(named: Text(LocalizedStringKey("Delete")), deleteAction)
        } else if let settingsAction {
            rowContent
                .accessibilityAction(named: Text(LocalizedStringKey("Model Settings")), settingsAction)
        } else if let deleteAction {
            rowContent
                .accessibilityAction(named: Text(LocalizedStringKey("Delete")), deleteAction)
        } else {
            rowContent
        }
    }
    
    @ViewBuilder
    private var loadButton: some View {
        Button(action: {
            #if canImport(UIKit) && !os(visionOS)
            Haptics.impact(.medium)
            #endif
            loadAction()
        }) {
            if isLoading {
                ProgressView().scaleEffect(0.7)
            } else {
                Text(LocalizedStringKey("Load"))
                    .font(FontTheme.caption.weight(.semibold))
            }
        }
        .buttonStyle(GlassButtonStyle())
        .disabled(isLoading || vm.loading)
    }

#if os(macOS)
    @ViewBuilder
    private var macLoadButton: some View {
        Button(action: loadAction) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 14)
            } else {
                Text(LocalizedStringKey("Load"))
            }
        }
        .buttonStyle(.industrial(.tinted))
        .disabled(isLoading || vm.loading)
    }
#endif
}

private struct StoredOpenRouterModelItem: Identifiable {
    let backend: RemoteBackend
    let model: RemoteModel
    let isInCatalog: Bool

    var id: String {
        "\(backend.id.uuidString)|\(model.id.lowercased())"
    }
}

private struct StoredRemoteBackendDestination: Identifiable, Hashable {
    let id: RemoteBackend.ID
}

private func storedModelsWithPCCBelowAFM(_ models: [LocalModel]) -> [LocalModel] {
    guard let pccIndex = models.firstIndex(where: {
        AppleFoundationModelKind.resolve(modelID: $0.modelID) == .privateCloudCompute
    }) else {
        return models
    }

    var ordered = models
    let pcc = ordered.remove(at: pccIndex)
    guard let afmIndex = ordered.firstIndex(where: {
        AppleFoundationModelKind.resolve(modelID: $0.modelID) == .onDevice
    }) else {
        return models
    }
    ordered.insert(pcc, at: afmIndex + 1)
    return ordered
}

@MainActor
private func storedOpenRouterFavoriteModels(from modelManager: AppModelManager) -> [StoredOpenRouterModelItem] {
    modelManager.remoteBackends
        .filter(\.isOpenRouter)
        .flatMap { backend in
            modelManager.openRouterFavoriteModelIDs(for: backend.id).map { favoriteID in
                let catalogModel = backend.cachedModels.first { model in
                    model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == favoriteID
                }
                return StoredOpenRouterModelItem(
                    backend: backend,
                    model: catalogModel ?? RemoteModel.makeCustom(id: favoriteID),
                    isInCatalog: catalogModel != nil
                )
            }
        }
        .sorted { lhs, rhs in
            let nameOrder = lhs.model.name.localizedCaseInsensitiveCompare(rhs.model.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.backend.name.localizedCaseInsensitiveCompare(rhs.backend.name) == .orderedAscending
        }
}

private struct StoredOpenRouterModelRow: View {
    let item: StoredOpenRouterModelItem
    let isFetching: Bool
    let isOffline: Bool
    let isActivating: Bool
    let isActive: Bool
    let manageAction: () -> Void
    let useAction: () -> Void

    private enum ConnectionState {
        case connected
        case connecting
        case unavailable
        case offline

        var title: LocalizedStringKey {
            switch self {
            case .connected: return LocalizedStringKey("Connected")
            case .connecting: return LocalizedStringKey("Connecting")
            case .unavailable: return LocalizedStringKey("Unavailable")
            case .offline: return LocalizedStringKey("Offline")
            }
        }

        @MainActor
        var color: Color {
            switch self {
            case .connected: return .green
            case .connecting: return .orange
            case .unavailable: return .red
            case .offline: return AppTheme.secondaryText
            }
        }

        var canUse: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    private var connectionState: ConnectionState {
        if isOffline { return .offline }
        if isFetching { return .connecting }
        if !item.isInCatalog { return .unavailable }
        if !EnterprisePolicyGate.remoteInferenceAllowed
            || !EnterprisePolicyGate.allowsRemoteBackend(
                id: item.backend.id,
                endpointType: item.backend.endpointType
            ) {
            return .unavailable
        }
        if let error = item.backend.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return .unavailable
        }
        if item.backend.lastConnectionSummary?.kind == .failure {
            return .unavailable
        }
        return .connected
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)

                    Text(item.model.name)
                        .font(FontTheme.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.text)

                    openRouterBadge
                }

                Text(item.model.id)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(connectionState.color)
                            .frame(width: 6, height: 6)
                        Text(connectionState.title)
                    }
                    .foregroundStyle(connectionState.color)

                    Text("·")
                    Text(item.backend.name)

                    if let contextLength = item.model.maxContextLength, contextLength > 0 {
                        Text("·")
                        Text("\(contextLength.formatted()) ctx")
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
                .lineLimit(1)
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Button(action: manageAction) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.industrial(.quiet))
                .accessibilityLabel(LocalizedStringKey("Manage"))

                if isActive && connectionState.canUse {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text(LocalizedStringKey("Using"))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Button(action: useAction) {
                        if isActivating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(LocalizedStringKey("Use"))
                        }
                    }
                    .buttonStyle(.industrial(.tinted))
                    .disabled(isActivating || !connectionState.canUse)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var openRouterBadge: some View {
        Text(LocalizedStringKey("OpenRouter"))
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct SupportModelRow: View {
    let item: SupportModelInventoryItem

    private var supportModelIcon: String {
        switch item.kind {
        case .speech: return "waveform"
        case .voice: return "waveform.circle"
        case .embedding: return "point.3.connected.trianglepath.dotted"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: supportModelIcon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(LocalizedStringKey(item.titleKey))
                        .font(FontTheme.body.weight(.medium))
                        .foregroundStyle(AppTheme.text)
                    Spacer(minLength: 8)
                    statusBadge
                }

                Text(item.displayName)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.detail)
                    if let sizeBytes = item.sizeBytes {
                        Text("·")
                        Text(formatBytes(sizeBytes))
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.top, 2)

                if item.state == .downloading, let progress = item.progress {
#if os(macOS)
                    IndustrialProgressBar(value: progress)
#else
                    DownloadCapsuleBar(value: progress)
#endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(LocalizedStringKey(item.state.titleKey))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch item.state {
        case .ready: return .green
        case .missing: return AppTheme.secondaryText
        case .downloading: return .accentColor
        case .paused: return .orange
        case .failed, .incomplete: return .red
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#endif

#if os(iOS) || os(visionOS)

struct StoredView: View {
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var datasetManager: DatasetManager
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @EnvironmentObject var downloadController: DownloadController
    @AppStorage("offGrid") private var offGrid = false

    @State private var loadingModelID: LocalModel.ID?
    @State private var selectedModel: LocalModel?
    @State private var selectedDataset: LocalDataset?
    @State private var showOffGridInfo = false
    // Import flow
    @State private var showImporter = false
    @State private var pendingPickedURLs: [URL] = []
    @State private var showNameSheet = false
    @State private var datasetName: String = ""
    @State private var importedDataset: LocalDataset?
    @State private var askStartIndexing = false
    @State private var datasetToIndex: LocalDataset?
    @State private var importNotice: String?
    @State private var showOffloadWarning = false
    @State private var pendingLoad: (LocalModel, ModelSettings)?
    @State private var showRAMSafetyWarning = false
    @State private var pendingRAMSafetyLoad: (LocalModel, ModelSettings)?
    @AppStorage("hideGGUFOffloadWarning") private var hideGGUFOffloadWarning = false
    @State private var showRemoteBackendForm = false
    @State private var selectedBackendDestination: StoredRemoteBackendDestination?
    @State private var activatingOpenRouterModelID: String?
    @State private var modelPendingDeletion: LocalModel?
    @State private var datasetPendingDeletion: LocalDataset?
    @State private var presentedSupportModelKind: SupportModelInventoryItem.Kind?
    @State private var autopilotConfig = AutopilotConfigStore.load()
    @State private var showAutopilotSetup = false
    @State private var showAutopilotSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Use a List (not a ScrollView) so the large "Stored" title collapses into the
                // inline header smoothly. A ScrollView + .navigationTitle re-lays-out the entire
                // content frame on every frame of the collapse, which janks on device; List drives
                // the collapse natively. Each section is rendered as one full-width, separator-less
                // row so the existing visual layout is preserved.
                List {
                    Group {
                        autopilotSection
                        modelsSection
                        supportModelsSection
                        if !modelManager.remoteBackends.isEmpty {
                            remoteBackendsSection
                        }
                        if !modelManager.downloadedDatasets.isEmpty {
                            datasetsSection
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: AppTheme.padding, bottom: 12, trailing: AppTheme.padding))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.windowBackground)
                .guideHighlight(.storedList)
                .navigationDestination(item: $presentedSupportModelKind) { kind in
                    supportModelDestination(for: kind)
                }
                .navigationDestination(item: $selectedBackendDestination) { destination in
                    RemoteBackendDetailView(backendID: destination.id)
                        .environmentObject(modelManager)
                }
                .navigationTitle(LocalizedStringKey("Stored"))
                .task {
                    await modelManager.refreshAsync()
                    modelManager.refreshRemoteBackends(offGrid: offGrid)
                }
                
                // Floating off-grid indicator
                if offGrid {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button(action: { showOffGridInfo = true }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi.slash")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(LocalizedStringKey("Off-Grid"))
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.gradient)
                                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                                )
                            }
                            .padding(.trailing, 20)
                            .padding(.bottom, 20)
                        }
                    }
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: offGrid)
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
            .sheet(isPresented: $showRemoteBackendForm) {
                RemoteBackendFormView { draft in
                    try await modelManager.addRemoteBackend(from: draft)
                }
            }
            .sheet(isPresented: $showAutopilotSetup, onDismiss: {
                autopilotConfig = AutopilotConfigStore.load()
            }) {
                AutopilotSetupView()
                    .environmentObject(modelManager)
            }
            .sheet(isPresented: $showAutopilotSettings, onDismiss: {
                autopilotConfig = AutopilotConfigStore.load()
            }) {
                AutopilotSettingsSheet()
                    .environmentObject(modelManager)
            }
            .alert(item: $datasetManager.embedAlert) { info in
                Alert(title: Text(info.message))
            }
            .alert(LocalizedStringKey("Off-Grid Mode Active"), isPresented: $showOffGridInfo) {
                Button(LocalizedStringKey("OK"), role: .cancel) { }
            } message: {
                Text(LocalizedStringKey("You're in Off-Grid mode. The Explore tab is hidden and all network features are disabled. You can only use downloaded models and datasets."))
            }
            .alert(LocalizedStringKey("Load Failed"), isPresented: Binding(get: { vm.loadError != nil }, set: { _ in vm.loadError = nil })) {
                Button(LocalizedStringKey("OK"), role: .cancel) {}
            } message: {
                Text(vm.loadError ?? "")
            }
            .alert(LocalizedStringKey("RAM Safety Checks"), isPresented: $showRAMSafetyWarning) {
                Button(LocalizedStringKey("Continue"), role: .destructive) {
                    if let (model, settings) = pendingRAMSafetyLoad {
                        pendingRAMSafetyLoad = nil
                        load(
                            model,
                            settings: settings,
                            bypassWarning: true,
                            bypassRAMCheck: true
                        )
                    }
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    pendingRAMSafetyLoad = nil
                }
            } message: {
                Text(LocalizedStringKey("Model likely exceeds memory budget. Lower context size or use a smaller quant/model."))
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
            .alert(
                modelDeleteConfirmationTitle,
                isPresented: Binding(
                    get: { modelPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            modelPendingDeletion = nil
                        }
                    }
                )
            ) {
                Button(LocalizedStringKey("Delete"), role: .destructive) {
                    guard let model = modelPendingDeletion else { return }
                    guard model.format != .afm else {
                        modelPendingDeletion = nil
                        return
                    }
                    modelPendingDeletion = nil
                    Task { @MainActor in
                        if modelManager.loadedModel?.id == model.id {
                            await vm.unload()
                        }
                        modelManager.delete(model)
                    }
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    modelPendingDeletion = nil
                }
            }
            .confirmationDialog(
                Text(LocalizedStringKey("Model doesn't support GPU offload")),
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
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: allowedUTTypes(),
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let accepted = urls.filter { allowedExtensions().contains($0.pathExtension.lowercased()) || TranscriptionMediaSupport.isSupported($0) }
                    guard !accepted.isEmpty else {
                        // Everything picked was unsupported (e.g. CSV/TSV) — tell the
                        // user instead of silently doing nothing.
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
            .confirmationDialog(Text(LocalizedStringKey("Start indexing now?")), isPresented: $askStartIndexing, titleVisibility: .visible) {
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
        .onReceive(walkthrough.$pendingModelSettingsID) { id in
            guard let id else { return }
            if let model = modelManager.downloadedModels.first(where: { $0.modelID == id }) {
                selectedModel = model
            }
            walkthrough.pendingModelSettingsID = nil
        }
        .onReceive(walkthrough.$shouldDismissModelSettings) { shouldDismiss in
            guard shouldDismiss else { return }
            selectedModel = nil
            DispatchQueue.main.async {
                walkthrough.shouldDismissModelSettings = false
            }
        }
        .onChangeCompat(of: offGrid) { _, newValue in
            if !newValue {
                modelManager.refreshRemoteBackends(offGrid: false)
            }
        }
        .onAppear {
            openPendingDatasetDetailIfNeeded()
        }
        .onChangeCompat(of: tabRouter.pendingStoredDatasetID) { _, _ in
            openPendingDatasetDetailIfNeeded()
        }
        .onChangeCompat(of: modelManager.downloadedDatasets) { _, _ in
            openPendingDatasetDetailIfNeeded()
        }
    }

    private func openPendingDatasetDetailIfNeeded() {
        guard let pendingID = tabRouter.pendingStoredDatasetID else { return }
        guard let dataset = modelManager.downloadedDatasets.first(where: { $0.datasetID == pendingID }) else { return }
        tabRouter.pendingStoredDatasetID = nil
        guard selectedDataset?.datasetID != dataset.datasetID else { return }
        selectedDataset = dataset
    }

    private var modelDeleteConfirmationTitle: String {
        guard let model = modelPendingDeletion else { return String(localized: "Delete") }
        return String.localizedStringWithFormat(String(localized: "Delete %@?"), model.name)
    }

    private var datasetDeleteConfirmationTitle: String {
        guard let dataset = datasetPendingDeletion else { return String(localized: "Delete") }
        return String.localizedStringWithFormat(String(localized: "Delete %@?"), dataset.name)
    }

    private var afmHiddenNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Foundation Model is hidden. You can re-enable it in Settings.")
                .font(FontTheme.body)
                .foregroundStyle(AppTheme.text)
            Button {
                tabRouter.dismissAFMHiddenNotice()
                withAnimation(.easeInOut) {
                    tabRouter.selection = .settings
                }
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(AppTheme.cardFill)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private var autopilotConfigured: Bool {
        autopilotConfig.isReadyToArm
    }

    private var autopilotSubtitle: String {
        guard EnterprisePolicyGate.remoteInferenceAllowed || !autopilotConfig.requiresCloudConsent else {
            return String(localized: "Your organization's policy keeps answers on-device.")
        }
        guard autopilotConfigured, let escalation = autopilotConfig.escalationDisplayName else {
            return String(localized: "Set up Autopilot")
        }
        guard vm.modelLoaded, let loaded = modelManager.loadedModel else {
            return String(localized: "Engages when a model loads")
        }
        return "\(loaded.displayName) → \(escalation)"
    }

    private var autopilotToggleBinding: Binding<Bool> {
        Binding(
            get: { modelManager.autoRoutingArmed },
            set: { newValue in
                // Re-read the store at decision time: setup can complete on another
                // surface (Settings, the other visionOS window) while this row's
                // cached snapshot is stale.
                let config = AutopilotConfigStore.load()
                autopilotConfig = config
                if newValue && !config.isReadyToArm {
                    // Arming requires configuration + consent; route through the wizard,
                    // which flips autoRoutingArmed itself once consent is granted.
                    showAutopilotSetup = true
                    return
                }
                #if canImport(UIKit) && !os(visionOS)
                Haptics.impact(.light)
                #endif
                modelManager.autoRoutingArmed = newValue
            }
        )
    }

    @ViewBuilder private var autopilotSection: some View {
        let enterpriseBlocked = !EnterprisePolicyGate.remoteInferenceAllowed
            && autopilotConfig.requiresCloudConsent
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cyan.opacity(modelManager.autoRoutingArmed ? 0.18 : 0.10))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(modelManager.autoRoutingArmed ? Color.cyan : AppTheme.secondaryText)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Autopilot"))
                    .font(FontTheme.body)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.text)
                Text(verbatim: autopilotSubtitle)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            if enterpriseBlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else {
                Toggle(LocalizedStringKey("Autopilot"), isOn: autopilotToggleBinding)
                    .labelsHidden()
                    .tint(.cyan)
                    .accessibilityHint(Text(!autopilotConfigured
                        ? LocalizedStringKey("Set up Autopilot")
                        : (modelManager.autoRoutingArmed
                            ? LocalizedStringKey("Turn off Autopilot")
                            : LocalizedStringKey("Turn on Autopilot"))))
            }
        }
        .padding(16)
        .background(AppTheme.cardFill)
        .cornerRadius(AppTheme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(Color.cyan.opacity(modelManager.autoRoutingArmed ? 0.35 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .visionHoverHighlight(cornerRadius: AppTheme.cornerRadius)
        .onTapGesture {
            // Tap reveals the same Autopilot settings as the Settings tab;
            // the wizard is reached from there (or by flipping the toggle on
            // while unconfigured).
            if !enterpriseBlocked {
                showAutopilotSettings = true
            }
        }
        .opacity(enterpriseBlocked ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.2), value: modelManager.autoRoutingArmed)
        .onAppear { autopilotConfig = AutopilotConfigStore.load() }
        .onChangeCompat(of: modelManager.autoRoutingArmed) { _, _ in
            autopilotConfig = AutopilotConfigStore.load()
        }
    }

    @ViewBuilder private var modelsSection: some View {
        let favoriteOpenRouterModels = storedOpenRouterFavoriteModels(from: modelManager)
        let storedModels = storedModelsWithPCCBelowAFM(modelManager.downloadedModels)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey("Models"))
                    .font(FontTheme.heading)
                    .foregroundStyle(AppTheme.text)
                Spacer()
                Button {
                    showRemoteBackendForm = true
                } label: {
                    Text(LocalizedStringKey("Add remote endpoint"))
                        .font(FontTheme.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(LocalizedStringKey("Add remote endpoint"))
            }

            if tabRouter.isAFMHiddenNoticeVisible {
                afmHiddenNotice
            }

            if modelManager.downloadedModels.isEmpty && favoriteOpenRouterModels.isEmpty {
                VStack(spacing: 16) {
                    Text(LocalizedStringKey("No models yet"))
                        .font(FontTheme.heading)
                        .foregroundStyle(AppTheme.text)
                    Text(LocalizedStringKey("Download a model from Explore or add a remote endpoint to get started."))
                        .font(FontTheme.body)
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        withAnimation(.easeInOut) {
                            tabRouter.selection = .explore
                        }
                    } label: {
                        Label(LocalizedStringKey("Explore Models"), systemImage: "sparkles")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        showRemoteBackendForm = true
                    } label: {
                        Label(LocalizedStringKey("Add remote endpoint"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    if modelManager.downloadedDatasets.isEmpty {
                        Button {
                            showImporter = true
                        } label: {
                            Label(LocalizedStringKey("Import Dataset"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 32)
                .background(AppTheme.cardFill)
                .cornerRadius(AppTheme.cornerRadius)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(storedModels, id: \.id) { model in
                        VStack(spacing: 0) {
                            ModelRow(model: model,
                                    isLoading: loadingModelID == model.id,
                                    isLoaded: vm.modelLoaded && modelManager.loadedModel?.id == model.id,
                                    settingsAction: { selectedModel = model },
                                    deleteAction: model.format == .afm ? nil : { modelPendingDeletion = model },
                                    showsPagedFitStatus: true) {
                                load(model)
                            }
                            .environmentObject(vm)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Always open settings on tap, do not trigger row button's load unintentionally
                                selectedModel = model
                            }
                            .contextMenu {
                                if model.format != .afm {
                                    Button(role: .destructive) {
                                        modelPendingDeletion = model
                                    } label: {
                                        Label(LocalizedStringKey("Delete"), systemImage: "trash")
                                    }
                                }
                            }
                            if model.id != storedModels.last?.id || !favoriteOpenRouterModels.isEmpty {
                                Divider().padding(.leading, 8)
                            }
                        }
                    }

                    ForEach(Array(favoriteOpenRouterModels.enumerated()), id: \.element.id) { index, item in
                        StoredOpenRouterModelRow(
                            item: item,
                            isFetching: modelManager.remoteBackendsFetching.contains(item.backend.id),
                            isOffline: offGrid,
                            isActivating: activatingOpenRouterModelID == item.id,
                            isActive: modelManager.activeRemoteSession?.backendID == item.backend.id
                                && modelManager.activeRemoteSession?.modelID == item.model.id,
                            manageAction: {
                                selectedBackendDestination = StoredRemoteBackendDestination(id: item.backend.id)
                            },
                            useAction: { useOpenRouterFavorite(item) }
                        )
                        .padding(.horizontal, 8)
                        .contextMenu {
                            Button {
                                selectedBackendDestination = StoredRemoteBackendDestination(id: item.backend.id)
                            } label: {
                                Label(LocalizedStringKey("Manage"), systemImage: "gearshape")
                            }
                            Button {
                                modelManager.setOpenRouterFavorite(
                                    false,
                                    backendID: item.backend.id,
                                    modelID: item.model.id
                                )
                            } label: {
                                Label(LocalizedStringKey("Remove Favorite"), systemImage: "star.slash")
                            }
                        }

                        if index < favoriteOpenRouterModels.count - 1 {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }

    private func useOpenRouterFavorite(_ item: StoredOpenRouterModelItem) {
        guard !offGrid, item.isInCatalog else { return }
        activatingOpenRouterModelID = item.id
        Task { @MainActor in
            defer {
                if activatingOpenRouterModelID == item.id {
                    activatingOpenRouterModelID = nil
                }
            }
            do {
                let settings = modelManager.remoteSettings(for: item.backend.id, model: item.model)
                try await vm.activateRemoteSession(backend: item.backend, model: item.model, settings: settings)
                tabRouter.selection = .chat
            } catch {
                vm.loadError = (error as? RemoteBackendError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @ViewBuilder private var supportModelsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedStringKey("Support Models"))
                .font(FontTheme.heading)
                .foregroundStyle(AppTheme.text)

            SupportModelDownloadItems { supportModelItems in
                LazyVStack(spacing: 0) {
                    ForEach(supportModelItems) { item in
                        VStack(spacing: 0) {
                            // This whole section renders as ONE List row, and List
                            // fires every NavigationLink in a row on a single tap.
                            // Borderless buttons get independent hit areas, and the
                            // single optional destination can only push one page.
                            Button {
                                presentedSupportModelKind = item.kind
                            } label: {
                                SupportModelRow(item: item)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)

                            if item.id != supportModelItems.last?.id {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func supportModelDestination(for kind: SupportModelInventoryItem.Kind) -> some View {
        switch kind {
        case .speech:
            WhisperModelsView(engineID: TranscriptionSettings.selectedEngineID.isLocalWhisper ? TranscriptionSettings.selectedEngineID : TranscriptionBackendFactory.preferredLocalWhisperEngineID())
        case .embedding:
            EmbeddingModelsView()
        case .voice:
            VoiceModelCatalogView()
        }
    }

    @ViewBuilder private var remoteBackendsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedStringKey("Remote Backends"))
                .font(FontTheme.heading)
                .foregroundStyle(AppTheme.text)
            
            LazyVStack(spacing: 0) {
                ForEach(modelManager.remoteBackends, id: \.id) { backend in
                    VStack(spacing: 0) {
                        Menu {
                            NavigationLink {
                                RemoteBackendDetailView(backendID: backend.id)
                                    .environmentObject(modelManager)
                            } label: {
                                Label(LocalizedStringKey("Manage"), systemImage: "gearshape")
                            }
                            Button(role: .destructive) {
                                modelManager.deleteRemoteBackend(id: backend.id)
                            } label: {
                                Label(LocalizedStringKey("Delete"), systemImage: "trash")
                            }
                        } label: {
                            RemoteBackendRow(
                                backend: backend,
                                isFetching: modelManager.remoteBackendsFetching.contains(backend.id),
                                isOffline: offGrid,
                                activeSession: modelManager.activeRemoteSession
                            )
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        #endif
                        if backend.id != modelManager.remoteBackends.last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var datasetsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedStringKey("Datasets"))
                .font(FontTheme.heading)
                .foregroundStyle(AppTheme.text)
            
            LazyVStack(spacing: 0) {
                ForEach(modelManager.downloadedDatasets) { ds in
                    VStack(spacing: 0) {
                        Menu {
                            if modelManager.activeDataset?.datasetID == ds.datasetID {
                                Button {
                                    vm.setDatasetForActiveSession(nil)
                                } label: {
                                    Label(LocalizedStringKey("Stop Using"), systemImage: "xmark.circle")
                                }
                            } else {
                                Button {
                                    useDataset(ds)
                                } label: {
                                    Label(LocalizedStringKey("Use"), systemImage: "checkmark.circle")
                                }
                            }
                            Button {
                                selectedDataset = ds
                            } label: {
                                Label(LocalizedStringKey("Manage"), systemImage: "gearshape")
                            }
                            Button(role: .destructive) {
                                requestDatasetDeletion(ds)
                            } label: {
                                Label(LocalizedStringKey("Delete"), systemImage: "trash")
                            }
                        } label: {
                            DatasetRow(
                                dataset: ds,
                                indexing: datasetManager.indexingDatasetID == ds.datasetID,
                                deleteAction: { datasetPendingDeletion = ds }
                            )
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        #endif
                        if ds.id != modelManager.downloadedDatasets.last?.id {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }
        }
        .guideHighlight(.storedDatasets)
    }

    /// Activates a dataset for the current chat session straight from the menu,
    /// so the user doesn't have to open the detail view. If the dataset isn't
    /// indexed yet, fall back to the detail view where it can be prepared.
    private func useDataset(_ ds: LocalDataset) {
        let isReady = !ds.requiresReindex && (ds.isIndexed || DatasetIndexIO.hasValidIndex(at: ds.url))
        if isReady {
            vm.setDatasetForActiveSession(ds)
        } else {
            selectedDataset = ds
        }
    }

    /// Routes a delete request through the confirmation alert. The assignment is
    /// deferred a runloop so the menu finishes dismissing first — otherwise the
    /// menu's dismissal transaction swallows the alert presentation.
    private func requestDatasetDeletion(_ ds: LocalDataset) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            datasetPendingDeletion = ds
        }
    }

    private func load(
        _ model: LocalModel,
        settings: ModelSettings? = nil,
        bypassWarning: Bool = false,
        bypassRAMCheck: Bool = false
    ) {
        let resolvedSettings = settings ?? modelManager.settings(for: model)
        if !bypassWarning {
            AppSoundPlayer.play(.loadPress)
        }
        if model.format == .gguf && !DeviceGPUInfo.supportsGPUOffload && !hideGGUFOffloadWarning && !bypassWarning {
            pendingLoad = (model, resolvedSettings)
            showOffloadWarning = true
            return
        }
        loadingModelID = model.id
        Task { @MainActor in
            let settings = modelManager.normalizeLocalSettings(resolvedSettings, for: model)
            // Unload any current model to get accurate RAM info
            await vm.unload()
            try? await Task.sleep(nanoseconds: 200_000_000)

            // RAM safety gate unless bypassed
            let bypass = bypassRAMCheck || UserDefaults.standard.bool(forKey: "bypassRAMCheck")
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
                    kvCacheEstimate: kvCacheEstimate,
                    runtimeConfiguration: .resolved(from: settings, modelURL: model.url)
                ) {
                    AppSoundPlayer.play(.error)
                    Haptics.error()
                    pendingRAMSafetyLoad = (model, settings)
                    showRAMSafetyWarning = true
                    loadingModelID = nil
                    return
                }
            }
            // Mark pending so if the app crashes during load, we won't autoload on next launch
            UserDefaults.standard.set(true, forKey: "bypassRAMLoadPending")
            var loadURL = model.url
            switch model.format {
            case .gguf:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let f = try? FileManager.default.contentsOfDirectory(at: loadURL, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                            loadURL = f
                        } else if let sub = try? FileManager.default.contentsOfDirectory(at: loadURL, includingPropertiesForKeys: nil).first(where: { url in
                            var d: ObjCBool = false
                            return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue && ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" })) != nil)
                        }), let found = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                            loadURL = found
                        } else {
                            loadingModelID = nil
                            return
                        }
                    } else if loadURL.pathExtension.lowercased() != "gguf" {
                        if let f = try? FileManager.default.contentsOfDirectory(at: loadURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                            loadURL = f
                        }
                    }
                } else {
                    if let alt = InstalledModelsStore.firstGGUF(in: InstalledModelsStore.baseDir(for: .gguf, modelID: model.modelID)) {
                        loadURL = alt
                    } else {
                        loadingModelID = nil
                        return
                    }
                }
            case .mlx:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                    loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                } else {
                    var d: ObjCBool = false
                    let dir = InstalledModelsStore.baseDir(for: .mlx, modelID: model.modelID)
                    if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                        loadURL = dir
                    } else {
                        loadingModelID = nil
                        return
                    }
                }
            case .et:
                break
            case .ane:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                    loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                } else {
                    var d: ObjCBool = false
                    let dir = InstalledModelsStore.baseDir(for: .ane, modelID: model.modelID)
                    if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                        loadURL = dir
                    } else {
                        loadingModelID = nil
                        return
                    }
                }
            case .afm:
                loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: model.modelID)
                try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            case .coreai:
                loadURL = InstalledModelsStore.baseDir(for: .coreai, modelID: model.modelID)
                try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            }
            let success = await vm.load(
                url: loadURL,
                settings: settings,
                format: model.format,
                forceReload: false,
                bypassRAMCheck: bypassRAMCheck
            )
            if success {
                modelManager.updateSettings(settings, for: model)
                modelManager.markModelUsed(model)
                tabRouter.selection = .chat
            } else {
                modelManager.loadedModel = nil
                if vm.lastLoadBlockedByRAMSafety {
                    vm.loadError = nil
                    pendingRAMSafetyLoad = (model, settings)
                    showRAMSafetyWarning = true
                }
            }
            // Clear pending flag if we survived the load attempt
            UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
            loadingModelID = nil
        }
    }

    // MARK: - Import helpers
    private func allowedExtensions() -> Set<String> { DatasetDocumentSupport.acceptedExtensions }
    private func allowedUTTypes() -> [UTType] { DatasetDocumentSupport.allowedUTTypes() }
    private func suggestName(from urls: [URL]) -> String? {
        if let pdfURL = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            if let doc = PDFDocument(url: pdfURL), let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }
        if let u = urls.first {
            return u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        }
        return nil
    }
    private func performImport() async {
        let name = datasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pendingPickedURLs.isEmpty, !name.isEmpty else { return }
        if let ds = await datasetManager.importDocuments(from: pendingPickedURLs, suggestedName: name) {
            importedDataset = ds
            datasetToIndex = ds
            askStartIndexing = true
        }
        pendingPickedURLs.removeAll()
        showNameSheet = false
    }

}

#elseif os(macOS)

import SwiftUI
import Foundation
import UniformTypeIdentifiers
import PDFKit

private enum StoredDatasetModal: Equatable {
    case selected
    case imported
    case namePrompt
}

struct StoredView: View {
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var datasetManager: DatasetManager
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @EnvironmentObject var macModalPresenter: MacModalPresenter
    @EnvironmentObject var downloadController: DownloadController
    @AppStorage("offGrid") private var offGrid = false
    @AppStorage("hideGGUFOffloadWarning") private var hideGGUFOffloadWarning = false

    @State private var loadingModelID: LocalModel.ID?
    @State private var selectedModel: LocalModel?
    @State private var selectedDataset: LocalDataset?
    @State private var importedDataset: LocalDataset?
    @State private var selectedBackendID: RemoteBackend.ID?
    @State private var activatingOpenRouterModelID: String?
    @State private var showOffGridInfo = false
    @State private var showImporter = false
    @State private var pendingPickedURLs: [URL] = []
    @State private var showNameSheet = false
    @State private var datasetName: String = ""
    @State private var datasetToIndex: LocalDataset?
    @State private var askStartIndexing = false
    @State private var importNotice: String?
    @State private var showRemoteBackendForm = false
    @State private var showOffloadWarning = false
    @State private var pendingLoad: (LocalModel, ModelSettings)?
    @State private var showRAMSafetyWarning = false
    @State private var pendingRAMSafetyLoad: (LocalModel, ModelSettings)?
    @State private var activeDatasetModal: StoredDatasetModal?
    @State private var modelPendingDeletion: LocalModel?
    @State private var datasetPendingDeletion: LocalDataset?
    @State private var presentedSupportModelKind: SupportModelInventoryItem.Kind?
    @State private var pagedBuildModel: LocalModel?
    @State private var pagedBuildPhase: PagedPackageBuildPhase = .preparing
    @State private var pagedBuildError: String?
    @State private var pagedBuildPackage: NoemaPagedPackage?
    @State private var pagedBuildIsStored = false
    @State private var pagedBuildTask: Task<Void, Never>?

    var body: some View {
        navigationContent
        .alert(item: $datasetManager.embedAlert) { info in
            Alert(title: Text(info.message))
        }
        .alert(LocalizedStringKey("Off-Grid Mode Active"), isPresented: $showOffGridInfo) {
            Button(LocalizedStringKey("OK"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("You're in Off-Grid mode. The Explore tab is hidden and all network features are disabled. You can only use downloaded models and datasets."))
        }
        .alert(LocalizedStringKey("Load Failed"), isPresented: Binding(get: { vm.loadError != nil }, set: { _ in vm.loadError = nil })) {
            Button(LocalizedStringKey("OK"), role: .cancel) {}
        } message: {
            Text(vm.loadError ?? "")
        }
        .alert(LocalizedStringKey("RAM Safety Checks"), isPresented: $showRAMSafetyWarning) {
            Button(LocalizedStringKey("Continue"), role: .destructive) {
                if let (model, settings) = pendingRAMSafetyLoad {
                    pendingRAMSafetyLoad = nil
                    load(
                        model,
                        settings: settings,
                        bypassWarning: true,
                        bypassRAMCheck: true
                    )
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingRAMSafetyLoad = nil
            }
        } message: {
            Text(LocalizedStringKey("Model likely exceeds memory budget. Lower context size or use a smaller quant/model."))
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
                if modelManager.activeDataset?.datasetID == dataset.datasetID {
                    modelManager.setActiveDataset(nil)
                }
                if activeDatasetModal != nil {
                    activeDatasetModal = nil
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                datasetPendingDeletion = nil
            }
        } message: {
            Text(LocalizedStringKey("This will remove the dataset and its embeddings from this device."))
        }
        .alert(
            modelDeleteConfirmationTitle,
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        modelPendingDeletion = nil
                    }
                }
            )
        ) {
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                guard let model = modelPendingDeletion else { return }
                guard model.format != .afm else {
                    modelPendingDeletion = nil
                    return
                }
                modelPendingDeletion = nil
                if selectedModel?.id == model.id {
                    selectedModel = nil
                }
                Task { @MainActor in
                    if modelManager.loadedModel?.id == model.id {
                        await vm.unload()
                    }
                    modelManager.delete(model)
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                modelPendingDeletion = nil
            }
        }
        .confirmationDialog(
            Text(LocalizedStringKey("Model doesn't support GPU offload")),
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
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: allowedUTTypes(),
            allowsMultipleSelection: true
        ) { result in
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
        .confirmationDialog(Text(LocalizedStringKey("Start indexing now?")), isPresented: $askStartIndexing, titleVisibility: .visible) {
            Button(LocalizedStringKey("Start")) {
                if let ds = datasetToIndex {
                    datasetManager.startIndexing(dataset: ds)
                }
            }
            Button(LocalizedStringKey("Later"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("We'll extract text and prepare embeddings. You can also start later from the dataset details."))
        }
        .onReceive(walkthrough.$pendingModelSettingsID) { id in
            guard let id else { return }
            if let model = modelManager.downloadedModels.first(where: { $0.modelID == id }) {
                selectedModel = model
            }
            walkthrough.pendingModelSettingsID = nil
        }
        .onReceive(walkthrough.$shouldDismissModelSettings) { shouldDismiss in
            guard shouldDismiss else { return }
            selectedModel = nil
            DispatchQueue.main.async {
                walkthrough.shouldDismissModelSettings = false
            }
        }
        .onChange(of: offGrid) { newValue in
            if !newValue {
                modelManager.refreshRemoteBackends(offGrid: false)
            }
        }
        .onChangeCompat(of: showRemoteBackendForm) { _, presenting in
            guard presenting else { return }
            presentRemoteBackendForm()
        }
        .onChangeCompat(of: selectedBackendID) { _, backendID in
            guard let backendID else { return }
            presentRemoteBackendDetail(id: backendID)
        }
        .onChangeCompat(of: selectedDataset) { _, dataset in
            guard let dataset else {
                if activeDatasetModal == .selected {
                    dismissDatasetModal()
                }
                return
            }
            presentDatasetDetail(dataset, context: .selected)
        }
        .onChangeCompat(of: importedDataset) { _, dataset in
            guard let dataset else {
                if activeDatasetModal == .imported {
                    dismissDatasetModal()
                }
                return
            }
            presentDatasetDetail(dataset, context: .imported)
        }
        .onChangeCompat(of: showNameSheet) { _, show in
            if show {
                presentDatasetNamePrompt()
            } else if activeDatasetModal == .namePrompt {
                dismissDatasetModal()
            }
        }
        .onAppear {
            openPendingDatasetDetailIfNeeded()
        }
        .onChangeCompat(of: tabRouter.pendingStoredDatasetID) { _, _ in
            openPendingDatasetDetailIfNeeded()
        }
        .onChangeCompat(of: modelManager.downloadedDatasets) { _, _ in
            openPendingDatasetDetailIfNeeded()
        }
        .sheet(item: $pagedBuildModel, onDismiss: {
            pagedBuildTask?.cancel()
            pagedBuildTask = nil
            pagedBuildPackage = nil
            pagedBuildIsStored = false
        }) { model in
            PagedPackageBuildSheet(
                modelName: model.displayName,
                phase: pagedBuildPhase,
                error: pagedBuildError,
                outputURL: pagedBuildPackage?.directoryURL,
                isInStored: pagedBuildIsStored,
                onAddToStored: addPagedPackageToStored
            ) {
                pagedBuildTask?.cancel()
                pagedBuildTask = nil
                pagedBuildPackage = nil
                pagedBuildIsStored = false
                pagedBuildModel = nil
            }
        }
    }

    private var navigationContent: some View {
        NavigationStack {
            ZStack {
                HStack(spacing: 0) {
                    if let model = selectedModel {
                        modelSettingsPane(for: model)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Divider()
                    }
                    storedList
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedModel != nil)
            }
            .navigationDestination(item: $presentedSupportModelKind) { kind in
                supportModelDestination(for: kind)
            }
        }
    }

    private var settingsPaneWidth: CGFloat { 620 }

    @ViewBuilder
    private func modelSettingsPane(for model: LocalModel) -> some View {
        VStack(spacing: 0) {
            settingsPaneHeader(for: model)
            Divider()
            ModelSettingsView(model: model) { settings in
                load(model, settings: settings)
            }
            // Reset ModelSettingsView's @State when switching models in place.
            .id(model.id)
            .environment(\.macModalDismiss, MacModalDismissAction { selectedModel = nil })
        }
        .frame(width: settingsPaneWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func settingsPaneHeader(for model: LocalModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    ForEach(modelManager.downloadedModels, id: \.id) { candidate in
                        Button {
                            selectedModel = candidate
                        } label: {
                            if candidate.id == model.id {
                                Label(candidate.displayName, systemImage: "checkmark")
                            } else {
                                Text(candidate.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .help(LocalizedStringKey("Switch model"))

                Text(model.format.displayName)
                    .textCase(.uppercase)
                    .industrialStat()
            }
            Spacer()
            IndustrialIconButton(systemImage: "xmark", help: LocalizedStringKey("Close")) {
                selectedModel = nil
            }
            .accessibilityLabel(Text(LocalizedStringKey("Close")))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var storedList: some View {
        ScrollView {
            LazyVStack(spacing: 32) {
                modelsSection
                supportModelsSection
                remoteBackendsSection
                datasetsSection
            }
            .padding(UIConstants.widePadding)
        }
        .background(AppTheme.windowBackground)
        .guideHighlight(.storedList)
        .task {
            // Let the page-switch fade land before hitting the disk —
            // refreshAsync/reloadFromDisk contend with the animation otherwise.
            try? await Task.sleep(nanoseconds: 450_000_000)
            await modelManager.refreshAsync()
            modelManager.refreshRemoteBackends(offGrid: offGrid)
            datasetManager.reloadFromDisk()
        }
    }

    private func openPendingDatasetDetailIfNeeded() {
        guard let pendingID = tabRouter.pendingStoredDatasetID else { return }
        guard let dataset = modelManager.downloadedDatasets.first(where: { $0.datasetID == pendingID }) else { return }
        tabRouter.pendingStoredDatasetID = nil
        guard selectedDataset?.datasetID != dataset.datasetID else { return }
        selectedDataset = dataset
    }

    private var modelDeleteConfirmationTitle: String {
        guard let model = modelPendingDeletion else { return String(localized: "Delete") }
        return String.localizedStringWithFormat(String(localized: "Delete %@?"), model.name)
    }

    private var datasetDeleteConfirmationTitle: String {
        guard let dataset = datasetPendingDeletion else { return String(localized: "Delete") }
        return String.localizedStringWithFormat(String(localized: "Delete %@?"), dataset.name)
    }

    private var afmHiddenNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple Foundation Model is hidden. You can re-enable it in Settings.")
                .font(.system(size: 12.5))
                .foregroundStyle(AppTheme.text)
            Button {
                tabRouter.dismissAFMHiddenNotice()
                withAnimation(.easeInOut) {
                    tabRouter.selection = .settings
                }
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.industrial(.quiet))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var offGridBadge: some View {
        Button {
            showOffGridInfo = true
        } label: {
            IndustrialBadge("Off-Grid", tint: .orange, dot: true)
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey("You're in Off-Grid mode. The Explore tab is hidden and all network features are disabled. You can only use downloaded models and datasets."))
        .accessibilityLabel(Text(LocalizedStringKey("Off-Grid")))
    }

    private func storedEmptyPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder private var modelsSection: some View {
        let favoriteOpenRouterModels = storedOpenRouterFavoriteModels(from: modelManager)
        let storedModels = storedModelsWithPCCBelowAFM(modelManager.downloadedModels)
        let modelCount = storedModels.count + favoriteOpenRouterModels.count
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(
                "Models",
                detail: modelCount == 0 ? nil : "\(modelCount)"
            ) {
                if offGrid {
                    offGridBadge
                }
                Button {
                    showRemoteBackendForm = true
                } label: {
                    Text(LocalizedStringKey("Add remote endpoint"))
                }
                .buttonStyle(.industrial(.quiet))
                .accessibilityLabel(LocalizedStringKey("Add remote endpoint"))
            }

            if tabRouter.isAFMHiddenNoticeVisible {
                afmHiddenNotice
            }

            if modelManager.downloadedModels.isEmpty && favoriteOpenRouterModels.isEmpty {
                storedEmptyPanel {
                    VStack(spacing: 12) {
                        Text(LocalizedStringKey("No models yet"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                        Text(LocalizedStringKey("Download a model from Explore or add a remote endpoint to get started."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            Button {
                                withAnimation(.easeInOut) {
                                    tabRouter.selection = .explore
                                }
                            } label: {
                                Label(LocalizedStringKey("Explore Models"), systemImage: "sparkles")
                                    .symbolRenderingMode(.monochrome)
                            }
                            .buttonStyle(.industrial(.prominent))
                            Button {
                                showRemoteBackendForm = true
                            } label: {
                                Label(LocalizedStringKey("Add remote endpoint"), systemImage: "plus")
                            }
                            .buttonStyle(.industrial(.quiet))
                            if modelManager.downloadedDatasets.isEmpty {
                                Button {
                                    showImporter = true
                                } label: {
                                    Label(LocalizedStringKey("Import Dataset"), systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.industrial(.quiet))
                            }
                        }
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(storedModels.enumerated()), id: \.element.id) { index, model in
                        IndustrialHoverRow(selected: selectedModel?.id == model.id) {
                            ModelRow(
                                model: model,
                                isLoading: loadingModelID == model.id,
                                isLoaded: vm.modelLoaded && modelManager.loadedModel?.id == model.id,
                                settingsAction: { selectedModel = model },
                                deleteAction: model.format == .afm ? nil : { modelPendingDeletion = model },
                                showsPagedFitStatus: true
                            ) {
                                load(model)
                            }
                            .environmentObject(vm)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedModel = model
                        }
                        .contextMenu {
                            Button(LocalizedStringKey("Open Settings")) {
                                selectedModel = model
                            }
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([model.url])
                            } label: {
                                Label(LocalizedStringKey("Reveal in Finder"), systemImage: "folder")
                            }
                            if PagedPackageBuildService.canCreatePackage(for: model) {
                                Button(LocalizedStringKey("Create Paged Package…")) {
                                    startPagedPackageBuild(for: model)
                                }
                                .disabled(pagedBuildTask != nil)
                            }
                            if model.format != .afm {
                                Button(LocalizedStringKey("Delete"), role: .destructive) {
                                    modelPendingDeletion = model
                                }
                            }
                        }

                        if index < storedModels.count - 1 || !favoriteOpenRouterModels.isEmpty {
                            IndustrialHairline().padding(.leading, 10)
                        }
                    }

                    ForEach(Array(favoriteOpenRouterModels.enumerated()), id: \.element.id) { index, item in
                        IndustrialHoverRow {
                            StoredOpenRouterModelRow(
                                item: item,
                                isFetching: modelManager.remoteBackendsFetching.contains(item.backend.id),
                                isOffline: offGrid,
                                isActivating: activatingOpenRouterModelID == item.id,
                                isActive: modelManager.activeRemoteSession?.backendID == item.backend.id
                                    && modelManager.activeRemoteSession?.modelID == item.model.id,
                                manageAction: { selectedBackendID = item.backend.id },
                                useAction: { useOpenRouterFavorite(item) }
                            )
                        }
                        .contextMenu {
                            Button(LocalizedStringKey("Manage")) {
                                selectedBackendID = item.backend.id
                            }
                            Button(LocalizedStringKey("Remove Favorite")) {
                                modelManager.setOpenRouterFavorite(
                                    false,
                                    backendID: item.backend.id,
                                    modelID: item.model.id
                                )
                            }
                        }

                        if index < favoriteOpenRouterModels.count - 1 {
                            IndustrialHairline().padding(.leading, 10)
                        }
                    }
                }
            }
        }
    }

    private func useOpenRouterFavorite(_ item: StoredOpenRouterModelItem) {
        guard !offGrid, item.isInCatalog else { return }
        activatingOpenRouterModelID = item.id
        Task { @MainActor in
            defer {
                if activatingOpenRouterModelID == item.id {
                    activatingOpenRouterModelID = nil
                }
            }
            do {
                let settings = modelManager.remoteSettings(for: item.backend.id, model: item.model)
                try await vm.activateRemoteSession(backend: item.backend, model: item.model, settings: settings)
                tabRouter.selection = .chat
            } catch {
                vm.loadError = (error as? RemoteBackendError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @ViewBuilder private var supportModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader("Support Models")

            SupportModelDownloadItems { supportItems in
                LazyVStack(spacing: 0) {
                    ForEach(Array(supportItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            withAnimation(AppMotion.submenu) {
                                presentedSupportModelKind = item.kind
                            }
                        } label: {
                            IndustrialHoverRow {
                                SupportModelRow(item: item)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < supportItems.count - 1 {
                            IndustrialHairline().padding(.leading, 10)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func supportModelDestination(for kind: SupportModelInventoryItem.Kind) -> some View {
        switch kind {
        case .speech:
            WhisperModelsView(engineID: TranscriptionSettings.selectedEngineID.isLocalWhisper ? TranscriptionSettings.selectedEngineID : TranscriptionBackendFactory.preferredLocalWhisperEngineID())
        case .embedding:
            EmbeddingModelsView()
        case .voice:
            VoiceModelCatalogView()
        }
    }

    @ViewBuilder private var remoteBackendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(
                "Remote Backends",
                detail: modelManager.remoteBackends.isEmpty ? nil : "\(modelManager.remoteBackends.count)"
            )

            if modelManager.remoteBackends.isEmpty {
                storedEmptyPanel {
                    VStack(spacing: 12) {
                        Text(LocalizedStringKey("No remote endpoints configured."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.secondaryText)
                        Button {
                            showRemoteBackendForm = true
                        } label: {
                            Label(LocalizedStringKey("Add Remote Endpoint"), systemImage: "plus")
                        }
                        .buttonStyle(.industrial(.quiet))
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(modelManager.remoteBackends.enumerated()), id: \.element.id) { index, backend in
                        Button {
                            selectedBackendID = backend.id
                        } label: {
                            IndustrialHoverRow {
                                RemoteBackendRow(
                                    backend: backend,
                                    isFetching: modelManager.remoteBackendsFetching.contains(backend.id),
                                    isOffline: offGrid,
                                    activeSession: modelManager.activeRemoteSession
                                )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(LocalizedStringKey("Delete"), role: .destructive) {
                                modelManager.deleteRemoteBackend(id: backend.id)
                            }
                        }

                        if index < modelManager.remoteBackends.count - 1 {
                            IndustrialHairline().padding(.leading, 10)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var datasetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(
                "Datasets",
                detail: modelManager.downloadedDatasets.isEmpty ? nil : "\(modelManager.downloadedDatasets.count)"
            ) {
                Button {
                    showImporter = true
                } label: {
                    Text(LocalizedStringKey("Import Dataset"))
                }
                .buttonStyle(.industrial(.quiet))
            }

            if modelManager.downloadedDatasets.isEmpty {
                storedEmptyPanel {
                    VStack(spacing: 12) {
                        Text(LocalizedStringKey("No datasets yet"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                        Text(LocalizedStringKey("Import PDFs, EPUBs, or text files to build local knowledge bases."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button {
                            showImporter = true
                        } label: {
                            Label(LocalizedStringKey("Import Dataset"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.industrial(.quiet))
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(modelManager.downloadedDatasets.enumerated()), id: \.element.id) { index, ds in
                        IndustrialHoverRow {
                            DatasetRow(
                                dataset: ds,
                                indexing: datasetManager.indexingDatasetID == ds.datasetID,
                                deleteAction: { datasetPendingDeletion = ds }
                            )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedDataset = ds }
                        .contextMenu {
                            Button(LocalizedStringKey("Delete"), role: .destructive) {
                                datasetPendingDeletion = ds
                            }
                        }

                        if index < modelManager.downloadedDatasets.count - 1 {
                            IndustrialHairline().padding(.leading, 10)
                        }
                    }
                }
            }
        }
        .guideHighlight(.storedDatasets)
    }

    private func load(
        _ model: LocalModel,
        settings: ModelSettings? = nil,
        bypassWarning: Bool = false,
        bypassRAMCheck: Bool = false
    ) {
        let resolvedSettings = settings ?? modelManager.settings(for: model)
        if !bypassWarning {
            AppSoundPlayer.play(.loadPress)
        }
        if model.format == .gguf && !DeviceGPUInfo.supportsGPUOffload && !hideGGUFOffloadWarning && !bypassWarning {
            pendingLoad = (model, resolvedSettings)
            showOffloadWarning = true
            return
        }
        loadingModelID = model.id
        Task { @MainActor in
            let settings = resolvedSettings
            await vm.unload()
            try? await Task.sleep(nanoseconds: 200_000_000)

            let bypass = bypassRAMCheck || UserDefaults.standard.bool(forKey: "bypassRAMCheck")
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
                    kvCacheEstimate: kvCacheEstimate,
                    runtimeConfiguration: .resolved(from: settings, modelURL: model.url)
                ) {
                    AppSoundPlayer.play(.error)
                    Haptics.error()
                    pendingRAMSafetyLoad = (model, settings)
                    showRAMSafetyWarning = true
                    loadingModelID = nil
                    return
                }
            }

            UserDefaults.standard.set(true, forKey: "bypassRAMLoadPending")
            var loadURL = model.url
            switch model.format {
            case .gguf:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let f = try? FileManager.default.contentsOfDirectory(at: loadURL, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                            loadURL = f
                        } else if let sub = try? FileManager.default.contentsOfDirectory(at: loadURL, includingPropertiesForKeys: nil).first(where: { url in
                            var d: ObjCBool = false
                            return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue && ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" })) != nil)
                        }), let found = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                            loadURL = found
                        } else {
                            loadingModelID = nil
                            return
                        }
                    } else if loadURL.pathExtension.lowercased() != "gguf" {
                        if let f = try? FileManager.default.contentsOfDirectory(at: loadURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                            loadURL = f
                        }
                    }
                } else {
                    if let alt = InstalledModelsStore.firstGGUF(in: InstalledModelsStore.baseDir(for: .gguf, modelID: model.modelID)) {
                        loadURL = alt
                    } else {
                        loadingModelID = nil
                        return
                    }
                }
            case .mlx:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                    loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                } else {
                    var d: ObjCBool = false
                    let dir = InstalledModelsStore.baseDir(for: .mlx, modelID: model.modelID)
                    if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                        loadURL = dir
                    } else {
                        loadingModelID = nil
                        return
                    }
                }
            case .et:
                break
            case .ane:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                    loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                } else {
                    var d: ObjCBool = false
                    let dir = InstalledModelsStore.baseDir(for: .ane, modelID: model.modelID)
                    if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                        loadURL = dir
                    } else {
                        loadingModelID = nil
                        return
                    }
                }
            case .afm:
                loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: model.modelID)
                try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            case .coreai:
                loadURL = InstalledModelsStore.baseDir(for: .coreai, modelID: model.modelID)
                try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            }

            let success = await vm.load(
                url: loadURL,
                settings: settings,
                format: model.format,
                forceReload: false,
                bypassRAMCheck: bypassRAMCheck
            )
            if success {
                modelManager.markModelUsed(model)
                tabRouter.selection = .chat
            } else {
                modelManager.loadedModel = nil
                if vm.lastLoadBlockedByRAMSafety {
                    vm.loadError = nil
                    pendingRAMSafetyLoad = (model, settings)
                    showRAMSafetyWarning = true
                }
            }
            UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
            loadingModelID = nil
        }
    }

    private func allowedExtensions() -> Set<String> { DatasetDocumentSupport.acceptedExtensions }

    private func allowedUTTypes() -> [UTType] { DatasetDocumentSupport.allowedUTTypes() }

    private func suggestName(from urls: [URL]) -> String? {
        if let pdfURL = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            if let doc = PDFDocument(url: pdfURL), let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }
        if let u = urls.first {
            return u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        }
        return nil
    }

    private func performImport() async {
        let name = datasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pendingPickedURLs.isEmpty, !name.isEmpty else { return }
        if let ds = await datasetManager.importDocuments(from: pendingPickedURLs, suggestedName: name) {
            importedDataset = ds
            datasetToIndex = ds
            askStartIndexing = true
        }
        pendingPickedURLs.removeAll()
        showNameSheet = false
    }

    private func presentDatasetDetail(_ dataset: LocalDataset, context: StoredDatasetModal) {
        activeDatasetModal = context
        macModalPresenter.present(
            title: dataset.name,
            subtitle: dataset.source.isEmpty ? nil : dataset.source,
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 600,
                idealWidth: 660,
                maxWidth: 760,
                minHeight: 560,
                idealHeight: 640,
                maxHeight: 780
            ),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            onDismiss: {
                let currentContext = context
                activeDatasetModal = nil
                switch currentContext {
                case .selected:
                    selectedDataset = nil
                case .imported:
                    importedDataset = nil
                case .namePrompt:
                    showNameSheet = false
                }
            }
        ) {
            LocalDatasetDetailView(dataset: dataset)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(vm)
        }
    }

    private func presentDatasetNamePrompt() {
        activeDatasetModal = .namePrompt
        macModalPresenter.present(
            title: String(localized: "Import Dataset"),
            subtitle: String(localized: "Name your dataset"),
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 360,
                idealWidth: 400,
                maxWidth: 460,
                minHeight: 220,
                idealHeight: 240,
                maxHeight: 320
            ),
            onDismiss: {
                activeDatasetModal = nil
                showNameSheet = false
            }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringKey("Name your dataset"))
                    .font(.system(size: 13, weight: .semibold))
                TextField(LocalizedStringKey("Dataset name"), text: $datasetName)
                    .industrialField()
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                HStack {
                    Button(LocalizedStringKey("Cancel")) { showNameSheet = false }
                        .buttonStyle(.industrial(.quiet))
                    Spacer()
                    Button(LocalizedStringKey("Import")) { Task { await performImport() } }
                        .buttonStyle(.industrial(.prominent))
                        .keyboardShortcut(.defaultAction)
                        .disabled(datasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 320, minHeight: 200)
        }
    }

    private func dismissDatasetModal() {
        guard activeDatasetModal != nil else { return }
        activeDatasetModal = nil
        if macModalPresenter.isPresented {
            macModalPresenter.dismiss()
        }
    }

    private func presentRemoteBackendForm() {
        macModalPresenter.present(
            title: String(localized: "Custom Backend"),
            subtitle: String(localized: "Add a remote inference endpoint"),
            showCloseButton: false,
            dimensions: MacModalDimensions(
                minWidth: 560,
                idealWidth: 620,
                maxWidth: 720,
                minHeight: 560,
                idealHeight: 640,
                maxHeight: 780
            ),
            onDismiss: { showRemoteBackendForm = false }
        ) {
            RemoteBackendFormView { draft in
                try await modelManager.addRemoteBackend(from: draft)
            }
        }
    }

    private func presentRemoteBackendDetail(id backendID: RemoteBackend.ID) {
        macModalPresenter.present(
            title: modelManager.remoteBackend(withID: backendID)?.name,
            subtitle: String(localized: "Connection details"),
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 600,
                idealWidth: 660,
                maxWidth: 760,
                minHeight: 540,
                idealHeight: 620,
                maxHeight: 760
            ),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            onDismiss: { selectedBackendID = nil }
        ) {
            RemoteBackendDetailView(backendID: backendID)
                .environmentObject(modelManager)
                .environmentObject(vm)
                .environmentObject(tabRouter)
        }
    }

    private func startPagedPackageBuild(for model: LocalModel) {
        guard pagedBuildTask == nil else { return }
        pagedBuildPhase = .preparing
        pagedBuildError = nil
        pagedBuildPackage = nil
        pagedBuildIsStored = false
        pagedBuildModel = model
        let source = model.url
        pagedBuildTask = Task { @MainActor in
            do {
                let package = try await PagedPackageBuildService.build(sourceGGUF: source) { phase in
                    Task { @MainActor in
                        pagedBuildPhase = phase
                    }
                }
                pagedBuildPackage = package
                pagedBuildPhase = .finished
            } catch is CancellationError {
                pagedBuildModel = nil
            } catch {
                pagedBuildError = error.localizedDescription
            }
            pagedBuildTask = nil
        }
    }

    private func addPagedPackageToStored() {
        guard !pagedBuildIsStored,
              let package = pagedBuildPackage,
              let sourceModel = pagedBuildModel else {
            return
        }
        let installed = PagedPackageBuildService.installedModel(
            for: package,
            sourceModel: sourceModel
        )
        modelManager.installOrUpdate(installed)
        pagedBuildIsStored = true
    }

}

/// Progress sheet for "Create Paged Package…". Same Stored-dialect anatomy as
/// OverfitCanaryProgressSheet (mono-caps header, 6pt dot, hairlines, step
/// rows, industrial action row); kept local so OverfitStatusViews stays
/// untouched.
private struct PagedPackageBuildSheet: View {
    let modelName: String
    let phase: PagedPackageBuildPhase
    var error: String? = nil
    var outputURL: URL? = nil
    var isInStored = false
    let onAddToStored: () -> Void
    let onDismiss: () -> Void

    private enum StepState {
        case pending
        case active
        case done
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(error == nil ? Color.accentColor : Color.red)
                    .frame(width: 6, height: 6)
                Text(headerTitle)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(error == nil ? Color.primary.opacity(0.6) : Color.red)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.vertical, 7)
            IndustrialHairline()

            HStack(spacing: 8) {
                Text(verbatim: modelName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            IndustrialHairline()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(PagedPackageBuildPhase.allCases, id: \.rawValue) { step in
                    stepRow(step)
                }
            }
            .padding(.vertical, 4)

            if let error {
                IndustrialHairline()
                Text(verbatim: error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
            } else if phase == .finished, let outputURL {
                IndustrialHairline()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Saved to %@"),
                                outputURL.lastPathComponent
                            )
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)

                        Text(verbatim: outputURL.deletingLastPathComponent().path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.5))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(outputURL.path)
                    }
                }
                .padding(.vertical, 10)
            }

            IndustrialHairline()
            HStack(spacing: 8) {
                Spacer()
                if error == nil, phase == .finished, let outputURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    } label: {
                        Label(LocalizedStringKey("Reveal in Finder"), systemImage: "folder")
                    }
                    .buttonStyle(.industrial(.tinted))

                    Button(action: onAddToStored) {
                        Label(
                            LocalizedStringKey(isInStored ? "In Stored" : "Add to Stored"),
                            systemImage: isInStored ? "checkmark" : "plus"
                        )
                    }
                    .buttonStyle(.industrial(isInStored ? .quiet : .prominent))
                    .disabled(isInStored)
                }
                Button(LocalizedStringKey("Done"), action: onDismiss)
                    .buttonStyle(.industrial(.quiet))
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 400)
    }

    private var headerTitle: LocalizedStringKey {
        if error != nil { return "Package build failed" }
        if phase == .finished, outputURL != nil { return "Complete" }
        return "Create Paged Package…"
    }

    private func titleKey(for step: PagedPackageBuildPhase) -> LocalizedStringKey {
        switch step {
        case .preparing: return "Preparing…"
        case .extracting: return "Extracting experts…"
        case .verifying: return "Verifying…"
        case .finishing: return "Finishing…"
        case .finished: return "Complete"
        }
    }

    private func stepRow(_ step: PagedPackageBuildPhase) -> some View {
        let state = state(for: step)
        return HStack(spacing: 10) {
            Group {
                switch state {
                case .pending:
                    Circle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 5, height: 5)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 16, height: 16)
            Text(titleKey(for: step))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(textColor(for: state))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func state(for step: PagedPackageBuildPhase) -> StepState {
        if error != nil {
            if step.rawValue < phase.rawValue { return .done }
            if step == phase { return .failed }
            return .pending
        }
        if phase == .finished { return .done }
        if step.rawValue < phase.rawValue { return .done }
        if step == phase { return .active }
        return .pending
    }

    private func textColor(for state: StepState) -> Color {
        switch state {
        case .pending: return Color.primary.opacity(0.35)
        case .active: return Color.primary.opacity(0.8)
        case .done: return Color.primary.opacity(0.6)
        case .failed: return .red
        }
    }
}

#endif
