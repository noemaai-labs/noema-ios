// ModelSelectorView.swift
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Represents a locally available language model
struct LocalModel: Identifiable, Hashable {
    // Use a stable identifier to avoid List diffing glitches during refresh
    var id: String { url.path }
    let modelID: String
    let name: String
    /// Path to the model file on disk
    let url: URL
    let quant: String
    var parameterCountLabel: String? = nil
    let architecture: String
    let architectureFamily: String
    let format: ModelFormat
    let sizeGB: Double
    var isMultimodal: Bool
    var isToolCapable: Bool
    /// Whether the model is actually downloaded and available locally
    let isDownloaded: Bool
    let downloadDate: Date
    /// Last time this model was loaded
    var lastUsedDate: Date?
    var isFavourite: Bool = false
    var totalLayers: Int
    var moeInfo: MoEInfo? = nil
    var alias: String? = nil
}

extension LocalModel {
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        if quant.isEmpty {
            return name
        }
        return name
            .replacingOccurrences(of: "-\(quant)", with: "")
            .replacingOccurrences(of: ".\(quant)", with: "")
    }
}

#if canImport(UIKit)
struct ModelSelectorView: View {
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var datasetManager: DatasetManager
    @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @State private var selectedModel: LocalModel?
    @State private var showLoadProgress = false
    @State private var progress: CGFloat = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let loaded = modelManager.loadedModel {
                        HStack {
                            Text(loaded.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(uiColor: .systemGray6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIConstants.extraLargeCornerRadius)
                                        .stroke(Color(uiColor: .systemGray3), lineWidth: 1)
                                )
                                .overlay(alignment: .bottom) {
                                    if showLoadProgress {
                                        GeometryReader { geo in
                                            Rectangle()
                                                .fill(Color.blue)
                                                .frame(width: geo.size.width * progress, height: 2)
                                        }
                                        .frame(height: 2)
                                        .transition(.opacity)
                                        .padding(.horizontal, 4)
                                    }
                                }
                                .cornerRadius(UIConstants.extraLargeCornerRadius)
                            Button(action: {
#if canImport(UIKit) && !os(visionOS)
                                Haptics.impact(.medium)
#endif
                                modelManager.loadedModel = nil
                                Task { await vm.unload() }
                            }) {
                                Image(systemName: "eject")
                            }
                            .buttonStyle(.bordered)
                        }
                        .transition(.opacity)
                    } else {
                        HStack {
                            Text(LocalizedStringKey("No model loaded"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(uiColor: .systemGray6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIConstants.extraLargeCornerRadius)
                                        .stroke(Color(uiColor: .systemGray3), lineWidth: 1)
                                )
                                .cornerRadius(UIConstants.extraLargeCornerRadius)
                        }
                        .transition(.opacity)
                    }

                }
                .padding(.horizontal)
                .animation(.easeInOut, value: modelManager.loadedModel)
                .onChangeCompat(of: vm.loading) { _, loading in
                    if loading {
                        startProgressAnimation()
                    } else {
                        finishProgressAnimation()
                    }
                }
                ModelListView(selectedModel: $selectedModel)
                    .environmentObject(vm)
                    .environmentObject(modelManager)
                    .environmentObject(tabRouter)
                    .environmentObject(datasetManager)
                Picker(LocalizedStringKey("Mode"), selection: $isAdvancedMode) {
                    Text(LocalizedStringKey("Simple")).tag(false)
                    Text(LocalizedStringKey("Advanced")).tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle(LocalizedStringKey("My Models"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert(item: $datasetManager.embedAlert) { info in
            Alert(title: Text(info.message))
        }
    }

    @State private var timer: Timer?

    @MainActor
    private func startProgressAnimation() {
        timer?.invalidate()
        showLoadProgress = true
        progress = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                if progress < 0.9 { progress += 0.02 }
            }
        }
    }

    @MainActor
    private func finishProgressAnimation() {
        timer?.invalidate()
        progress = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.3)) { showLoadProgress = false }
            progress = 0
        }
    }
}

struct ModelListView: View {
    @Binding var selectedModel: LocalModel?
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var datasetManager: DatasetManager

    @State private var sort: SortOption = .recent
    @State private var manualParams = false
    @State private var showInfo = false
    @State private var detailModel: LocalModel?
    @State private var models: [LocalModel] = []
    @State private var loadingModelID: LocalModel.ID?
    @State private var showOffloadWarning = false
    @State private var pendingLoad: (LocalModel, ModelSettings)?
    @AppStorage("hideGGUFOffloadWarning") private var hideGGUFOffloadWarning = false

    enum SortOption: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case size = "Size"
        
        var localizedName: LocalizedStringKey {
            switch self {
            case .recent: return LocalizedStringKey("Recent")
            case .size: return LocalizedStringKey("Size")
            }
        }

        var id: String { rawValue }
    }

    var body: some View {
        List {
            Picker(LocalizedStringKey("Sort"), selection: $sort) {
                ForEach(SortOption.allCases) { option in
                    Text(option.localizedName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            Section(header: Text(LocalizedStringKey("Your Models"))) {
                ForEach(sortedModels, id: \.id) { model in
                    let row = ModelRow(
                        model: model,
                        isLoading: loadingModelID == model.id,
                        settingsAction: { selectedModel = model }
                    ) {
                        if manualParams {
                            selectedModel = model
                        } else {
                            var s = modelManager.settings(for: model)
                            // Default to "all layers" for GGUF if unset
                            if model.format == .gguf && s.gpuLayers == 0 {
                                s.gpuLayers = -1
                            }
                            startLoad(for: model, settings: s)
                        }
                    }
                    row
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedModel = model
                        }
                }
            }
            Section(header: Text(LocalizedStringKey("Your Datasets"))) {
                ForEach(modelManager.downloadedDatasets) { ds in
                    DatasetRow(dataset: ds, indexing: datasetManager.indexingDatasetID == ds.datasetID)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard datasetManager.indexingDatasetID != ds.datasetID, ds.isIndexed else { return }
                            let isActive = modelManager.activeDataset?.datasetID == ds.datasetID
                            vm.setDatasetForActiveSession(isActive ? nil : ds)
                        }
                }
            }

            Section {
                HStack {
                    Toggle(LocalizedStringKey("Manually choose model load parameters"), isOn: $manualParams)
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .onAppear { modelManager.refresh(); models = modelManager.downloadedModels }
        .onReceive(modelManager.$downloadedModels) { models = $0 }
        .alert(LocalizedStringKey("Model Load Parameters"), isPresented: $showInfo) {
            Button(LocalizedStringKey("OK"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("When enabled, you will be asked to choose parameters every time a model loads."))
        }
        .sheet(item: $selectedModel) { model in
            ModelSettingsView(model: model) { settings in
                startLoad(for: model, settings: settings)
            }
            .environmentObject(modelManager)
            .environmentObject(vm)
        }
        .alert(LocalizedStringKey("Load Failed"), isPresented: Binding(get: { vm.loadError != nil }, set: { _ in vm.loadError = nil })) {
            Button(LocalizedStringKey("OK"), role: .cancel) {}
        } message: {
            Text(vm.loadError ?? "")
        }
        .confirmationDialog(
            LocalizedStringKey("Model doesn't support GPU offload"),
            isPresented: $showOffloadWarning,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("Load")) {
                if let (model, settings) = pendingLoad {
                    startLoad(for: model, settings: settings, bypassWarning: true)
                    pendingLoad = nil
                }
            }
            Button(LocalizedStringKey("Don't show again")) {
                hideGGUFOffloadWarning = true
                if let (model, settings) = pendingLoad {
                    startLoad(for: model, settings: settings, bypassWarning: true)
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
    }

    /// Models that are downloaded
    var filteredModels: [LocalModel] {
        return models.filter { model in
            model.isDownloaded
        }
    }

    var sortedModels: [LocalModel] {
        switch sort {
        case .recent:
            return filteredModels.sorted {
                let d0 = $0.lastUsedDate ?? $0.downloadDate
                let d1 = $1.lastUsedDate ?? $1.downloadDate
                return d0 > d1
            }
        case .size:
            return filteredModels.sorted { $0.sizeGB < $1.sizeGB }
        }
    }

    @MainActor
    private func startLoad(for model: LocalModel, settings: ModelSettings, bypassWarning: Bool = false) {
        if model.format == .gguf && !DeviceGPUInfo.supportsGPUOffload && !hideGGUFOffloadWarning && !bypassWarning {
            pendingLoad = (model, settings)
            showOffloadWarning = true
            return
        }
        loadingModelID = model.id
        Task { @MainActor in
            if model.format == .et {
                var effectiveSettings = modelManager.normalizeLocalSettings(settings, for: model)
                effectiveSettings.contextLength = max(1, effectiveSettings.contextLength)
                let success = await vm.load(url: model.url, settings: effectiveSettings, format: .et, forceReload: true)
                if success {
                    modelManager.updateSettings(effectiveSettings, for: model)
                    modelManager.markModelUsed(model)
                    tabRouter.selection = .chat
                } else {
                    modelManager.loadedModel = nil
                }
                loadingModelID = nil
            } else {
                // Unload current model before checking RAM so available memory is accurate
                await vm.unload()
                try? await Task.sleep(nanoseconds: 200_000_000)

                let normalizedSettings = modelManager.normalizeLocalSettings(settings, for: model)
                // RAM safety gate unless bypassed
                let bypass = UserDefaults.standard.bool(forKey: "bypassRAMCheck")
                if !bypass {
                    let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
                    let ctx = Int(normalizedSettings.contextLength)
                    let layerHint: Int? = model.totalLayers > 0 ? model.totalLayers : nil
                    let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: normalizedSettings)
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
                        let locale = LocalizationManager.preferredLocale()
                        vm.loadError = String(localized: "Model likely exceeds memory budget. Lower context or choose a smaller quant.", locale: locale)
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
                            // Prefer a valid non-mmproj GGUF under the directory
                            if let f = InstalledModelsStore.firstGGUF(in: loadURL) {
                                loadURL = f
                            } else {
                                let locale = LocalizationManager.preferredLocale()
                                vm.loadError = String(localized: "Model file missing (.gguf)", locale: locale)
                                modelManager.loadedModel = nil
                                loadingModelID = nil
                                return
                            }
                        } else if loadURL.pathExtension.lowercased() != "gguf" || !InstalledModelsStore.isValidGGUF(at: loadURL) {
                            // Fallback to a valid GGUF next to the provided file path
                            if let f = InstalledModelsStore.firstGGUF(in: loadURL.deletingLastPathComponent()) {
                                loadURL = f
                            } else {
                                let locale = LocalizationManager.preferredLocale()
                                vm.loadError = String(localized: "Model file missing (.gguf)", locale: locale)
                                modelManager.loadedModel = nil
                                loadingModelID = nil
                                return
                            }
                        }
                    } else {
                        // Path no longer exists (e.g., new sandbox). Try to re-discover under canonical base dir.
                        if let alt = InstalledModelsStore.firstGGUF(in: InstalledModelsStore.baseDir(for: .gguf, modelID: model.modelID)) {
                            loadURL = alt
                        } else {
                            let locale = LocalizationManager.preferredLocale()
                            vm.loadError = String(localized: "Model path missing", locale: locale)
                            modelManager.loadedModel = nil
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
                        let locale = LocalizationManager.preferredLocale()
                        vm.loadError = String(localized: "Model path missing", locale: locale)
                        modelManager.loadedModel = nil
                        loadingModelID = nil
                        return
                    }
                }
                case .et:
                    break
                case .ane:
                    break
                case .afm:
                    loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: model.modelID)
                    try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
                case .coreai:
                    loadURL = InstalledModelsStore.baseDir(for: .coreai, modelID: model.modelID)
                    try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
                }

#if DEBUG
                var dbgDir: ObjCBool = false
                let _ = FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &dbgDir)
                print("[ModelListView] load url \(loadURL.path) \(dbgDir.boolValue ? "dir" : "file")")
#endif

                var clamped = normalizedSettings
                clamped.contextLength = max(1, clamped.contextLength)
                if model.format == .gguf {
                    // Only clamp GPU layers when we actually know totalLayers for this model.
                    if model.totalLayers > 0, clamped.gpuLayers >= 0 {
                        clamped.gpuLayers = min(max(0, clamped.gpuLayers), model.totalLayers)
                    }
                }

                let success = await vm.load(url: loadURL,
                                            settings: clamped,
                                            format: model.format)
                if success {
                    // Persist settings used for this successful load
                    modelManager.updateSettings(clamped, for: model)
                    modelManager.markModelUsed(model)
                    tabRouter.selection = .chat
                } else {
                    modelManager.loadedModel = nil
                    // Bubble error to a toast via loadError; UI already observes it
                }
                // Clear pending flag if we survived the load attempt
                UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
                loadingModelID = nil
            }
        }
    }

}
struct ModelDetailView: View {
    let model: LocalModel
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var modelManager: AppModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var showFavouriteLimitAlert = false

    var body: some View {
        List {
            Section(header: Text(model.name)) {
                if model.format != .ane && model.format != .afm {
                    Label(model.architecture, systemImage: "cpu")
                }
                Label(model.format.displayName, systemImage: "doc")
                if let parameterCountLabel = model.parameterCountLabel, !parameterCountLabel.isEmpty {
                    Label(parameterCountLabel, systemImage: "sum")
                }
                if !model.quant.isEmpty && model.format != .ane {
                    Label("Quant: \(model.quant)", systemImage: "dial.max")
                }
                if model.format != .afm {
                    Label(String(format: "Size: %.1f GB", model.sizeGB), systemImage: "externaldrive")
                }
            }
            Section(LocalizedStringKey("Actions")) {
                if model.format != .afm {
                    Button(LocalizedStringKey("Delete")) {
                        showDeleteConfirm = true
                    }
                }

                Button(model.isFavourite ? LocalizedStringKey("Unmark Favorite") : LocalizedStringKey("Mark as Favorite")) {
                    if !modelManager.toggleFavourite(model) {
                        showFavouriteLimitAlert = true
                    }
                }
            }
        }
        .alert(String.localizedStringWithFormat(String(localized: "Delete %@?"), model.name), isPresented: $showDeleteConfirm) {
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                Task {
                    if modelManager.loadedModel?.id == model.id {
                        await vm.unload()
                    }
                    modelManager.delete(model)
                    dismiss()
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) { showDeleteConfirm = false }
        }
        .alert(LocalizedStringKey("Favorite Limit Reached"), isPresented: $showFavouriteLimitAlert) {
            Button(LocalizedStringKey("OK"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("You can only favorite up to three models."))
        }
    }
}

// Close UIKit-only view definitions.
#endif

extension LocalModel {
    static func loadInstalled(store: InstalledModelsStore) -> [LocalModel] {
        let favs = Set(UserDefaults.standard.array(forKey: "favouriteModels") as? [String] ?? [])
        return store.all()
            // Hide CoreAI installs from users below iOS/macOS/visionOS 27, where the
            // runtime can't load them. This is the single source for Stored, every
            // model selector, and App Intents.
            .filter { ModelFormat.isCoreAIRuntimeAvailable || $0.format != .coreai }
            .map { item in
            var layers = item.totalLayers
            if layers == 0 && item.format == .gguf {
                layers = ModelScanner.layerCount(for: item.url, format: .gguf)
                if layers > 0 {
                    store.updateLayers(modelID: item.modelID, quantLabel: item.quantLabel, layers: layers)
                }
            }
            let name: String
            if item.format == .et {
                let baseName = LeapCatalogService.name(for: item.modelID) ?? item.modelID
                name = baseName
            } else if item.format == .afm {
                name = AppleFoundationModelRegistry.modelName
            } else if item.format == .mlx {
                name = Self.friendlyMLXName(for: item.modelID, quantLabel: item.quantLabel)
            } else {
                name = item.modelID.split(separator: "/").last.map(String.init) ?? item.modelID
            }
            let finalURL = item.url
            let architectureLabels = Self.architectureLabels(for: finalURL, format: item.format, modelID: item.modelID)
            return LocalModel(
                modelID: item.modelID,
                name: name,
                url: finalURL,
                quant: item.quantLabel,
                parameterCountLabel: item.parameterCountLabel,
                architecture: architectureLabels.display,
                architectureFamily: architectureLabels.family,
                format: item.format,
                sizeGB: Double(item.sizeBytes) / 1_073_741_824.0,
                isMultimodal: item.isMultimodal,
                isToolCapable: item.isToolCapable,
                isDownloaded: true,
                downloadDate: item.installDate,
                lastUsedDate: item.lastUsed,
                isFavourite: favs.contains(item.url.path),
                totalLayers: layers,
                moeInfo: item.moeInfo,
                alias: item.alias

            )
        }
    }

}

extension LocalModel {
    /// Distinguishes ET artifact source so UI can label ExecuTorch vs GGUF-backed installs.
    var slmSourceFormatLabel: String? {
        guard format == .et else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "bundle" { return "EXECUTORCH" }
        if ext == "gguf" { return "GGUF" }
        let lowerPath = url.path.lowercased()
        if lowerPath.contains(".bundle/") || lowerPath.hasSuffix(".bundle") {
            return "EXECUTORCH"
        }
        return nil
    }
}

private extension LocalModel {
    static func friendlyMLXName(for modelID: String, quantLabel: String) -> String {
        let repo = InstalledModelsStore.normalizedRepoName(for: .mlx, modelID: modelID)
        let humanized = repo
            .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[A-Za-z])(?=[0-9])"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[0-9])(?=[A-Za-z])"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quantLabel.isEmpty else { return humanized }
        return "\(humanized) (\(quantLabel))"
    }
}

extension LocalModel {
    static func architectureLabels(for url: URL, format: ModelFormat, modelID: String) -> (display: String, family: String) {
        let fallbackBase = fallbackArchitectureFamily(for: modelID)
        var display = fallbackBase
        var family = fallbackBase.lowercased()
        var scanSource = "fallback"
        var rawArchitecture: String?

        switch format {
        case .gguf:
            if let info = GGUFMetadata.architectureInfo(at: url) {
                let trimmedArch = info.architecture.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedArch.isEmpty {
                    family = trimmedArch.lowercased()
                    if display.isEmpty { display = trimmedArch }
                }
                if let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    display = name
                } else if !trimmedArch.isEmpty {
                    display = trimmedArch
                }
                scanSource = "gguf-metadata"
                rawArchitecture = trimmedArch.isEmpty ? nil : trimmedArch
            }
        case .mlx:
            if let info = MLXMetadata.architectureInfo(at: url) {
                let trimmedFamily = info.family.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedFamily.isEmpty {
                    family = trimmedFamily.lowercased()
                    if display.isEmpty { display = trimmedFamily }
                }
                if let displayName = info.display?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
                    display = displayName
                }
                scanSource = "mlx-metadata"
                rawArchitecture = trimmedFamily.isEmpty ? nil : trimmedFamily
            }
        case .afm:
            family = "afm"
            display = "Apple Foundation"
            scanSource = "afm-system"
            rawArchitecture = "afm"
        case .coreai:
            family = "coreai"
            display = "Core AI"
            scanSource = "coreai"
            rawArchitecture = "coreai"
        case .et, .ane:
            break
        }

        if family.isEmpty {
            family = fallbackBase.isEmpty ? "unknown" : fallbackBase.lowercased()
        }
        if display.isEmpty {
            display = fallbackBase.isEmpty ? modelID : fallbackBase
        }

        let logKey = "\(url.path)|\(format.rawValue)"
        let message = "[ArchitectureScan] modelID=\(modelID) format=\(format.rawValue) source=\(scanSource) display=\"\(display)\" family=\"\(family)\" raw=\"\(rawArchitecture ?? "<none>")\" path=\(url.lastPathComponent)"
        Task {
            await ArchitectureScanSessionTracker.shared.logOnce(key: logKey, message: message)
        }

        return (display, family)
    }

    private static func fallbackArchitectureFamily(for modelID: String) -> String {
        let trimmed = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matchesArchitectureFamily(of other: LocalModel) -> Bool {
        architectureFamily.caseInsensitiveCompare(other.architectureFamily) == .orderedSame
    }
}

private actor ArchitectureScanSessionTracker {
    static let shared = ArchitectureScanSessionTracker()

    private var loggedKeys: Set<String> = []

    func logOnce(key: String, message: String) async {
        if loggedKeys.insert(key).inserted {
            await logger.log(message)
        }
    }
}

extension Array where Element == LocalModel {
    /// Removes duplicate models based on their file URL while preserving order.
    func removingDuplicateURLs() -> [LocalModel] {
        var seen = Set<URL>()
        var result: [LocalModel] = []
        for m in self {
            if !seen.contains(m.url) {
                seen.insert(m.url)
                result.append(m)
            }
        }
        return result
    }
}

#if canImport(UIKit)
#Preview {
    ModelSelectorView()
}
#endif
