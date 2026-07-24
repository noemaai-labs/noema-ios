import SwiftUI
import Foundation
import RelayKit
import Combine
import ImageIO
#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
import CoreSpotlight
import UniformTypeIdentifiers
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
import NoemaPackages
#if canImport(MLX)
import MLX
#endif

#if canImport(UIKit) || os(macOS)
@MainActor final class AppModelManager: ObservableObject {
    // Thread-safe store (internally synchronized) is safe to access off the main actor.
    private nonisolated let store: InstalledModelsStore
    @Published var downloadedModels: [LocalModel] = []
    @Published var hiddenModels: [LocalModel] = []
    @Published var loadedModel: LocalModel?
    /// Autopilot armed state; persists via AutopilotConfigStore. Active only
    /// while a local model is also loaded.
    @Published var autoRoutingArmed: Bool = AutopilotConfigStore.load().enabled {
        didSet {
            guard oldValue != autoRoutingArmed else { return }
            var config = AutopilotConfigStore.load()
            config.enabled = autoRoutingArmed
            AutopilotConfigStore.save(config)
            AutopilotAFMBrain.syncWarmState(
                armed: autoRoutingArmed,
                cancelInFlight: !autoRoutingArmed
            )
            if autoRoutingArmed {
                Task { await AutopilotRouter.shared.resetDegradation() }
            }
#if os(macOS)
            // Keep the local escalation model resident only while armed.
            if autoRoutingArmed {
                AutopilotLocalEscalationRuntime.shared.prewarmIfNeeded(manager: self)
            } else {
                AutopilotLocalEscalationRuntime.shared.unload()
            }
#endif
        }
    }
    @Published var lastUsedModel: LocalModel?
    @Published var modelSettings: [String: ModelSettings] = [:]
    @Published var downloadedDatasets: [LocalDataset] = []
    @Published var remoteBackends: [RemoteBackend] = []
    @Published var remoteBackendsFetching: Set<RemoteBackend.ID> = []
    @Published var activeRemoteSession: ActiveRemoteSession?
    @Published var activeLMStudioRemoteDownloadTargetID: RemoteBackend.ID?
    @Published var activeDataset: LocalDataset?
    @Published var loadingModelName: String?
    private var favouritePaths: [String] = []
    private static let favouriteLimit = 3
    fileprivate var datasetManager: DatasetManager?
    private var cancellables: Set<AnyCancellable> = []
    var activeRelayLANRefreshes: Set<RemoteBackend.ID> = []
    var relayLANRefreshTimestamps: [RemoteBackend.ID: Date] = [:]
    // Track one-time early LAN health probes per backend so we don't spam.
    var lanInitialProbePerformed: Set<RemoteBackend.ID> = []
    private static let remoteModelSettingsStorageKey = "remoteModelSettings.v1"
    private static let openRouterFavoriteModelsStorageKey = "openRouterFavoriteModels.v1"
    private var remoteModelSettingsByKey: [String: ModelSettings] = [:]
    @Published private var openRouterFavoriteModelKeys: Set<String> = []
    /// Snapshot of the durable per-model settings entries, rebuilt at init and on
    /// every model-list refresh. Consulted when the path-keyed `modelSettings` map
    /// misses (model URL drifted across a migration/re-install), so reads return the
    /// user's saved settings instead of defaults — and the post-load write-backs in
    /// the load paths can never replace a saved entry with defaults.
    private var durableSettingsByPath: [String: ModelSettings] = [:]
    private var durableSettingsByModelKey: [String: ModelSettings] = [:]

    init(store: InstalledModelsStore = InstalledModelsStore()) {
        self.store = store
        store.migratePaths()
        store.migrateShardedGGUFEntries()
        store.rehomeIfMissing()
        Self.syncBuiltInAppleModels(in: store, availableKinds: AppleFoundationModelRegistry.availableKinds)
        if let fav = UserDefaults.standard.array(forKey: "favouriteModels") as? [String] {
            favouritePaths = Array(fav.prefix(Self.favouriteLimit))
            if favouritePaths.count != fav.count {
                UserDefaults.standard.set(favouritePaths, forKey: "favouriteModels")
            }
        }
        var installed = LocalModel.loadInstalled(store: store)
            .removingDuplicateURLs()
        let partitionedInstalled = partitionHiddenModels(installed)
        pruneFavouritePaths(against: partitionedInstalled.visible)
        installed = installed.map { model in
            var m = model
            m.isFavourite = favouritePaths.contains(m.url.path)
            return m
        }
        let partitionedFavorites = partitionHiddenModels(installed)
        downloadedModels = partitionedFavorites.visible
        hiddenModels = partitionedFavorites.hidden
        invalidateLocalGGUFMoeInfoIfNeeded()
        hydrateMoEInfoFromCache()
        updateLastUsedModel()
        // Merge durable and legacy path-based settings into the in-memory path-keyed map.
        let legacyModelSettings: [String: ModelSettings] = {
            guard let data = UserDefaults.standard.data(forKey: "modelSettings"),
                  let decoded = try? JSONDecoder().decode([String: ModelSettings].self, from: data) else {
                return [:]
            }
            return decoded
        }()
        modelSettings = ModelSettingsStore.resolveLocalSettings(
            installedModels: store.all(),
            legacySettingsByPath: legacyModelSettings
        )
        rebuildDurableSettingsCache(entries: ModelSettingsStore.loadEntries())
        remoteBackends = RemoteBackendsStore.load()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = UserDefaults.standard.data(forKey: Self.remoteModelSettingsStorageKey),
           let decoded = ModelSettingsPersistenceDecoder.decodeRemoteSettingsMap(from: data) {
            remoteModelSettingsByKey = decoded.map
            if decoded.droppedInvalidEntries {
                persistRemoteSettings()
            }
        }
        if let favorites = UserDefaults.standard.array(forKey: Self.openRouterFavoriteModelsStorageKey) as? [String] {
            openRouterFavoriteModelKeys = Set(favorites)
        }
        scanLayersIfNeeded()
        scanMoEInfoIfNeeded()
    }

    nonisolated private static func syncBuiltInAppleModels(
        in store: InstalledModelsStore,
        availableKinds: [AppleFoundationModelKind]
    ) {
        let fm = FileManager.default
        let availableSet = Set(availableKinds)

        for kind in AppleFoundationModelKind.allCases {
            let modelID = kind.modelID
            let quantLabel = kind.quantLabel
            guard availableSet.contains(kind) else {
                store.remove(modelID: modelID, quantLabel: quantLabel)
                continue
            }

            let base = InstalledModelsStore.baseDir(for: .afm, modelID: modelID)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let canonical = InstalledModelsStore.canonicalURL(for: base, format: .afm)

            let existing = store.all().filter { $0.modelID == modelID && $0.quantLabel == quantLabel }
            if existing.count > 1 {
                store.remove(modelID: modelID, quantLabel: quantLabel)
            }
            let existingModel = existing.count == 1 ? existing.first : nil

            let installed = InstalledModel(
                id: existingModel?.id ?? UUID(),
                modelID: modelID,
                quantLabel: quantLabel,
                parameterCountLabel: kind.parameterCountLabel,
                url: canonical,
                format: .afm,
                sizeBytes: 0,
                lastUsed: existingModel?.lastUsed,
                installDate: existingModel?.installDate ?? Date(),
                checksum: existingModel?.checksum,
                isFavourite: existingModel?.isFavourite ?? false,
                totalLayers: 0,
                isMultimodal: kind.supportsVision,
                isToolCapable: true,
                moeInfo: nil,
                etBackend: nil
            )
            store.upsert(installed)
        }
    }

    var activeLMStudioRemoteDownloadTargetBackend: RemoteBackend? {
        guard let targetID = activeLMStudioRemoteDownloadTargetID,
              let backend = remoteBackends.first(where: { $0.id == targetID }),
              backend.endpointType == .lmStudio else {
            return nil
        }
        return backend
    }

    func remoteSettingsKey(backendID: RemoteBackend.ID, modelID: String) -> String {
        let normalizedModelID = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(backendID.uuidString)|\(normalizedModelID)"
    }

    func clampedRemoteSettings(_ settings: ModelSettings, maxContextLength: Int?) -> ModelSettings {
        func quantize(_ value: Double, step: Double) -> Double {
            guard step > 0 else { return value }
            return (value / step).rounded() * step
        }

        var clamped = settings
        clamped.contextLength = max(1, clamped.contextLength.rounded())
        if let maxContextLength, maxContextLength > 0 {
            clamped.contextLength = min(clamped.contextLength, Double(maxContextLength))
        }
        clamped.topP = quantize(max(0, min(1, clamped.topP)), step: 0.01)
        clamped.topK = max(1, clamped.topK)
        clamped.minP = quantize(max(0, min(1, clamped.minP)), step: 0.01)
        clamped.temperature = quantize(max(0, min(2, clamped.temperature)), step: 0.01)
        let repeatPenalty = Double(max(0.1, min(3.0, clamped.repetitionPenalty)))
        clamped.repetitionPenalty = Float(quantize(repeatPenalty, step: 0.01))
        return clamped.normalizedSystemPromptSettings()
    }

    func remoteSettings(for backendID: RemoteBackend.ID, model: RemoteModel) -> ModelSettings {
        let key = remoteSettingsKey(backendID: backendID, modelID: model.id)
        if let existing = remoteModelSettingsByKey[key] {
            let clamped = clampedRemoteSettings(existing, maxContextLength: model.maxContextLength)
            if clamped != existing {
                remoteModelSettingsByKey[key] = clamped
                persistRemoteSettings()
            }
            return clamped
        }
        let defaults = ModelSettings.default(for: model.compatibilityFormat ?? .gguf)
        return clampedRemoteSettings(defaults, maxContextLength: model.maxContextLength)
    }

    func hasSavedRemoteSettings(for backendID: RemoteBackend.ID, modelID: String) -> Bool {
        remoteModelSettingsByKey[remoteSettingsKey(backendID: backendID, modelID: modelID)] != nil
    }

    func saveRemoteSettings(_ settings: ModelSettings, for backendID: RemoteBackend.ID, model: RemoteModel) {
        let key = remoteSettingsKey(backendID: backendID, modelID: model.id)
        remoteModelSettingsByKey[key] = clampedRemoteSettings(settings, maxContextLength: model.maxContextLength)
        persistRemoteSettings()
    }

    func clearRemoteSettings(for backendID: RemoteBackend.ID) {
        let prefix = "\(backendID.uuidString)|"
        let previousCount = remoteModelSettingsByKey.count
        remoteModelSettingsByKey = remoteModelSettingsByKey.filter { !$0.key.hasPrefix(prefix) }
        if remoteModelSettingsByKey.count != previousCount {
            persistRemoteSettings()
        }
    }

    private func persistRemoteSettings() {
        guard let data = try? JSONEncoder().encode(remoteModelSettingsByKey) else { return }
        UserDefaults.standard.set(data, forKey: Self.remoteModelSettingsStorageKey)
    }

    func isOpenRouterFavorite(backendID: RemoteBackend.ID, modelID: String) -> Bool {
        openRouterFavoriteModelKeys.contains(remoteSettingsKey(backendID: backendID, modelID: modelID))
    }

    @discardableResult
    func setOpenRouterFavorite(_ isFavorite: Bool, backendID: RemoteBackend.ID, modelID: String) -> Bool {
        let key = remoteSettingsKey(backendID: backendID, modelID: modelID)
        let changed: Bool
        if isFavorite {
            changed = openRouterFavoriteModelKeys.insert(key).inserted
        } else {
            changed = openRouterFavoriteModelKeys.remove(key) != nil
        }
        if changed {
            persistOpenRouterFavorites()
        }
        return changed
    }

    @discardableResult
    func toggleOpenRouterFavorite(backendID: RemoteBackend.ID, modelID: String) -> Bool {
        let newValue = !isOpenRouterFavorite(backendID: backendID, modelID: modelID)
        _ = setOpenRouterFavorite(newValue, backendID: backendID, modelID: modelID)
        return newValue
    }

    func openRouterFavoriteModelIDs(for backendID: RemoteBackend.ID) -> Set<String> {
        let prefix = "\(backendID.uuidString)|"
        return Set(
            openRouterFavoriteModelKeys.compactMap { key in
                guard key.hasPrefix(prefix) else { return nil }
                return String(key.dropFirst(prefix.count))
            }
        )
    }

    func clearOpenRouterFavorites(for backendID: RemoteBackend.ID) {
        let prefix = "\(backendID.uuidString)|"
        let filtered = openRouterFavoriteModelKeys.filter { !$0.hasPrefix(prefix) }
        guard filtered.count != openRouterFavoriteModelKeys.count else { return }
        openRouterFavoriteModelKeys = filtered
        persistOpenRouterFavorites()
    }

    private func persistOpenRouterFavorites() {
        UserDefaults.standard.set(Array(openRouterFavoriteModelKeys).sorted(), forKey: Self.openRouterFavoriteModelsStorageKey)
    }

    func refresh() {
        refreshGeneration &+= 1
        store.reload()
        store.migratePaths()
        store.migrateShardedGGUFEntries()
        store.rehomeIfMissing()
        Self.syncBuiltInAppleModels(in: store, availableKinds: AppleFoundationModelRegistry.availableKinds)
        var installed = LocalModel.loadInstalled(store: store)
            .removingDuplicateURLs()
        let partitionedInstalled = partitionHiddenModels(installed)
        pruneFavouritePaths(against: partitionedInstalled.visible)
        installed = installed.map { model in
            var m = model
            m.isFavourite = favouritePaths.contains(m.url.path)
            return m
        }
        let partitionedFavorites = partitionHiddenModels(installed)
        downloadedModels = partitionedFavorites.visible
        hiddenModels = partitionedFavorites.hidden
        rehydrateDurableSettings(entries: ModelSettingsStore.loadEntries())
        invalidateLocalGGUFMoeInfoIfNeeded()
        hydrateMoEInfoFromCache()
        updateLastUsedModel()
        scanLayersIfNeeded()
        scanMoEInfoIfNeeded()
        scanCapabilitiesIfNeeded()
        datasetManager?.reloadFromDisk()
    }

    // MARK: - Async Refresh (Performance Optimized)

    private var lastRefreshTime: Date = .distantPast
    private var refreshGeneration: UInt = 0
    private static let refreshDebounceInterval: TimeInterval = 0.3

    /// Async version of refresh that moves heavy I/O off the main thread.
    /// Includes debouncing to prevent redundant refreshes when rapidly switching tabs.
    func refreshAsync() async {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) > Self.refreshDebounceInterval else { return }
        lastRefreshTime = now
        refreshGeneration &+= 1
        let generation = refreshGeneration

        // Capture store reference for use in detached task
        let store = self.store
        let currentFavouritePaths = self.favouritePaths
        let availableAppleModelKinds = AppleFoundationModelRegistry.availableKinds

        // Perform heavy I/O operations off the main actor
        let (installed, durableEntries) = await Task.detached(priority: .userInitiated) {
            store.reload()
            store.migratePaths()
            store.migrateShardedGGUFEntries()
            store.rehomeIfMissing()
            Self.syncBuiltInAppleModels(in: store, availableKinds: availableAppleModelKinds)
            var models = LocalModel.loadInstalled(store: store)
                .removingDuplicateURLs()
            models = models.map { model in
                var m = model
                m.isFavourite = currentFavouritePaths.contains(m.url.path)
                return m
            }
            return (models, ModelSettingsStore.loadEntries())
        }.value

        guard generation == refreshGeneration else { return }
        let partitionedInstalled = partitionHiddenModels(installed)
        pruneFavouritePaths(against: partitionedInstalled.visible)
        let refreshedInstalled = installed.map { model in
            var refreshed = model
            refreshed.isFavourite = favouritePaths.contains(model.url.path)
            return refreshed
        }
        let partitionedFavorites = partitionHiddenModels(refreshedInstalled)
        downloadedModels = partitionedFavorites.visible
        hiddenModels = partitionedFavorites.hidden
        rehydrateDurableSettings(entries: durableEntries)
        hydrateMoEInfoFromCache()
        updateLastUsedModel()

        // These already use Task.detached internally
        scanLayersIfNeeded()
        scanMoEInfoIfNeeded()
        scanCapabilitiesIfNeeded()
    }

    private func updateLastUsedModel() {
        lastUsedModel = downloadedModels
            .filter { $0.lastUsedDate != nil }
            .sorted { $0.lastUsedDate! > $1.lastUsedDate! }
            .first
    }

    private func partitionHiddenModels(_ models: [LocalModel]) -> (visible: [LocalModel], hidden: [LocalModel]) {
        let hiddenKeys = HiddenModelsStore.load()
        let partitioned = models.reduce(into: (visible: [LocalModel](), hidden: [LocalModel]())) { partialResult, model in
            let key = HiddenModelsStore.key(modelID: model.modelID, quantLabel: model.quant)
            if hiddenKeys.contains(key) {
                partialResult.hidden.append(model)
            } else {
                partialResult.visible.append(model)
            }
        }
        return partitioned
    }

    func isHidden(_ model: LocalModel) -> Bool {
        HiddenModelsStore.isHidden(modelID: model.modelID, quantLabel: model.quant)
    }

    func hide(_ model: LocalModel) {
        HiddenModelsStore.hide(modelID: model.modelID, quantLabel: model.quant)
        refresh()
    }

    func unhide(modelID: String, quantLabel: String) {
        HiddenModelsStore.unhide(modelID: modelID, quantLabel: quantLabel)
        refresh()
    }

    /// Set the given model as recently used and mark it as loaded.
    func markModelUsed(_ model: LocalModel) {
        var m = model
        let lastUsedDate = Date()
        m.lastUsedDate = lastUsedDate
        store.updateLastUsed(modelID: m.modelID, quantLabel: m.quant, date: lastUsedDate)
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx] = m
        } else {
            downloadedModels.append(m)
        }
        loadedModel = m
        lastUsedModel = m
        if autoRoutingArmed {
            AutopilotAFMBrain.syncWarmState(armed: true)
        }
#if os(macOS)
        // Autopilot rides on the loaded chat model; make sure its stronger
        // local escalation model is warm too (no-op unless configured+armed).
        if autoRoutingArmed {
            AutopilotLocalEscalationRuntime.shared.prewarmIfNeeded(manager: self)
        }
#endif
    }

    func setCapabilities(modelID: String, quant: String, isMultimodal: Bool, isToolCapable: Bool) {
        store.updateCapabilities(modelID: modelID, quantLabel: quant, isMultimodal: isMultimodal, isToolCapable: isToolCapable)
        refresh()
    }

    func bind(datasetManager: DatasetManager) {
        guard self.datasetManager !== datasetManager else { return }
        self.datasetManager = datasetManager
        datasetManager.$datasets
            .receive(on: RunLoop.main)
            .sink { [weak self] ds in
                // Publish changes on the next runloop to avoid nested view-update warnings
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.downloadedDatasets = ds
                    let selectedID = UserDefaults.standard.string(forKey: "selectedDatasetID") ?? ""
                    if selectedID.isEmpty {
                        self.activeDataset = nil
                        return
                    }

                    if let selected = ds.first(where: { $0.datasetID == selectedID }) {
                        // Keep the active dataset object fresh (e.g., when indexing flips isIndexed).
                        self.activeDataset = selected
                    } else {
                        // Selected dataset no longer exists on disk.
                        self.activeDataset = nil
                        UserDefaults.standard.set("", forKey: "selectedDatasetID")
                    }
                }
            }
            .store(in: &cancellables)
    }

    func setActiveDataset(_ ds: LocalDataset?) {
        datasetManager?.select(ds)
        // Defer publishing selection to avoid modifying state during view updates
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeDataset = ds
            let id = ds?.datasetID ?? ""
            UserDefaults.standard.set(id, forKey: "selectedDatasetID")
        }
    }

    /// Adds a newly installed model to the store and refreshes the list.
    func install(_ model: InstalledModel) {
        store.add(model)
        refresh()
    }

    /// Registers a derived/rebuilt artifact without creating duplicate rows
    /// when the same model identity has already been installed.
    func installOrUpdate(_ model: InstalledModel) {
        store.upsert(model)
        refresh()
    }

    func installedModel(matching model: LocalModel) -> InstalledModel? {
        store.all().first { installed in
            installed.modelID == model.modelID
            && installed.quantLabel == model.quant
            && InstalledModelsStore.canonicalURL(for: installed.url, format: installed.format).path == InstalledModelsStore.canonicalURL(for: model.url, format: model.format).path
        } ?? store.all().first { installed in
            installed.modelID == model.modelID
            && installed.quantLabel == model.quant
            && installed.format == model.format
        }
    }

    func delete(_ model: LocalModel) {
        if model.format == .afm {
            return
        }
        let canonicalURL = InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
#if canImport(CoreML) && (os(iOS) || os(visionOS))
        if model.format == .ane {
            try? ANEModelResolver.removeCompiledCache(for: model.url)
        }
#endif
        let installedBeforeDelete = store.all()
        _ = ModelStorageCleanup.deleteModelFiles(for: model, installedModels: installedBeforeDelete)
        store.remove(modelID: model.modelID, quantLabel: model.quant)
        // Keep the durable settings entry: it's a few hundred bytes, and it means a
        // re-download of the same model+quant comes back with the user's context
        // length and sampling instead of resetting to defaults.
        modelSettings.removeValue(forKey: canonicalURL.path)
        modelSettings.removeValue(forKey: model.url.path)
        HiddenModelsStore.unhide(modelID: model.modelID, quantLabel: model.quant)
        ModelStorageCleanup.clearPassExtractionSelectionIfNeeded(deletedModel: model)
        Task {
            await MoEDetectionStore.shared.remove(modelID: model.modelID, quantLabel: model.quant)
        }
        refresh()
        if loadedModel?.id == model.id { loadedModel = nil }
        if lastUsedModel?.id == model.id { lastUsedModel = nil }
        StartupPreferencesStore.clearLocalPath(model.url.path)
        StartupPreferencesStore.clearLocalPath(canonicalURL.path)
    }

    private func rebuildDurableSettingsCache(entries: [ModelSettingsStore.Entry]) {
        var byPath: [String: ModelSettings] = [:]
        var byModelKey: [String: ModelSettings] = [:]
        for entry in entries {
            if let path = entry.canonicalPath, !path.isEmpty {
                byPath[path] = entry.settings
            }
            byModelKey[entry.modelID + "|" + entry.quantLabel] = entry.settings
        }
        durableSettingsByPath = byPath
        durableSettingsByModelKey = byModelKey
    }

    /// The user's saved settings for this model from the durable store, matched the
    /// same way `ModelSettingsStore.resolveLocalSettings` does: exact path first,
    /// then the (modelID, quant) identity that survives path changes.
    private func durableSettings(for model: LocalModel) -> ModelSettings? {
        if let byPath = durableSettingsByPath[model.url.path] {
            return byPath
        }
        if let byModelKey = durableSettingsByModelKey[model.modelID + "|" + model.quant] {
            return byModelKey
        }
        let canonicalPath = InstalledModelsStore.canonicalURL(for: model.url, format: model.format).path
        return durableSettingsByPath[canonicalPath]
    }

    /// True when a durable settings entry was ever saved for this model (any install
    /// of it). The in-memory map doesn't count — it also caches derived defaults.
    func hasUserSavedSettings(for model: LocalModel) -> Bool {
        durableSettings(for: model) != nil
    }

    /// Store migrations and re-installs can change model URLs after init, but the
    /// `modelSettings` map is keyed by path. After every list rebuild, refresh the
    /// durable snapshot and seed map entries for any current model URL that lost its
    /// key — otherwise reads fall back to defaults and the post-load write-back
    /// replaces the saved entry with them.
    private func rehydrateDurableSettings(entries: [ModelSettingsStore.Entry]) {
        rebuildDurableSettingsCache(entries: entries)
        var additions: [String: ModelSettings] = [:]
        for model in downloadedModels + hiddenModels {
            let path = model.url.path
            guard modelSettings[path] == nil, additions[path] == nil else { continue }
            if let durable = durableSettings(for: model) {
                additions[path] = durable
            }
        }
        guard !additions.isEmpty else { return }
        modelSettings.merge(additions) { current, _ in current }
    }

    private func resolvedSettings(for model: LocalModel,
                                  persistIfMissing: Bool,
                                  deferPublishedWrites: Bool = false) -> ModelSettings {
        if var existing = modelSettings[model.url.path] {
            let stored = existing
            existing = normalizeLocalSettings(existing, for: model)
            var shouldPersistNormalized = existing != stored
            if model.format == .ane,
               (existing.tokenizerPath ?? "").isEmpty,
               let tokenizerPath = ModelSettings.resolvedTokenizerPath(for: model) {
                existing.tokenizerPath = tokenizerPath
                shouldPersistNormalized = true
            }
            if persistIfMissing && shouldPersistNormalized {
                if deferPublishedWrites {
                    scheduleSettingsPersistence(existing, for: model)
                } else {
                    updateSettings(existing, for: model)
                }
            }
            return existing
        }
        // Path-keyed miss: adopt the durable entry before assuming a fresh model,
        // so a drifted URL can't surface (and later persist) defaults.
        if let durable = durableSettings(for: model) {
            let adopted = normalizeLocalSettings(durable, for: model)
            if persistIfMissing && !deferPublishedWrites {
                modelSettings[model.url.path] = adopted
            } else {
                scheduleSettingsCaching(adopted, for: model)
            }
            return adopted
        }
        var s = ModelSettings.fromConfig(for: model)
        // Default to sentinel (-1) meaning "all layers" for GGUF unless already set elsewhere.
        if model.format == .gguf && s.gpuLayers == 0 {
            s.gpuLayers = -1
        }
        // MTP-export GGUFs get speculative decoding on by default: the runtime
        // auto-tuner adapts the draft length to the device and backs off on its
        // own, so a fresh model benefits without a trip to Model Settings.
        if model.format == .gguf,
           s.speculativeDecoding.selection == .off,
           MtpLocator.hasMtpFileCached(alongside: model.url) || GGUFMetadata.hasMTP(at: model.url) {
            s.speculativeDecoding.selection = .mtp
            s.speculativeDecoding.mtpAutoTune = true
        }
        if model.format == .et {
            let storedBackend = store
                .all()
                .first(where: { $0.modelID == model.modelID && $0.quantLabel == model.quant })?
                .etBackend
            s.etBackend = ETBackendDetector.effectiveBackend(userSelected: storedBackend ?? s.etBackend, detected: nil)
        }
        s = normalizeLocalSettings(s, for: model)
        if persistIfMissing {
            if deferPublishedWrites {
                scheduleSettingsCaching(s, for: model)
            } else {
                modelSettings[model.url.path] = s
            }
        }
        return s
    }

    private func scheduleSettingsCaching(_ settings: ModelSettings, for model: LocalModel) {
        let path = model.url.path
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.modelSettings[path] == nil else { return }
            self.modelSettings[path] = settings
        }
    }

    private func scheduleSettingsPersistence(_ settings: ModelSettings, for model: LocalModel) {
        let expected = modelSettings[model.url.path]
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Compare-and-swap: persist this normalization only while the entry is
            // untouched. If a user save (or anything else) landed in between, writing
            // the older snapshot would silently revert it.
            let latest = self.modelSettings[model.url.path]
            guard latest == expected else { return }
            guard latest.map({ self.normalizeLocalSettings($0, for: model) }) == settings,
                  latest != settings else { return }
            self.updateSettings(settings, for: model)
        }
    }

    func settings(for model: LocalModel) -> ModelSettings {
        resolvedSettings(for: model, persistIfMissing: true, deferPublishedWrites: true)
    }

    func displaySettings(for model: LocalModel) -> ModelSettings {
        resolvedSettings(for: model, persistIfMissing: false)
    }

    /// Stored rows only need the ET backend label. Resolve it from already-loaded
    /// state instead of constructing full model settings (which may read tokenizer
    /// and config files during the screen's first render).
    func displayETBackend(for model: LocalModel) -> ETBackend {
        if let settings = modelSettings[model.url.path] ?? durableSettings(for: model) {
            return settings.etBackend
        }
        let storedBackend = store
            .all()
            .first(where: { $0.modelID == model.modelID && $0.quantLabel == model.quant })?
            .etBackend
        return ETBackendDetector.effectiveBackend(
            userSelected: storedBackend ?? ModelSettings.default(for: .et).etBackend,
            detected: nil
        )
    }

    func normalizeLocalSettings(_ settings: ModelSettings, for model: LocalModel) -> ModelSettings {
        settings.normalizedForLocalModel(model)
    }

    func updateSettings(_ settings: ModelSettings, for model: LocalModel) {
        let normalized = normalizeLocalSettings(settings, for: model)
        modelSettings[model.url.path] = normalized
        // Persist to legacy store for backwards compatibility
        if let data = try? JSONEncoder().encode(modelSettings) {
            UserDefaults.standard.set(data, forKey: "modelSettings")
        }
        // Persist to durable store using the current canonical model path.
        ModelSettingsStore.save(settings: normalized, for: model)
        let canonicalPath = InstalledModelsStore.canonicalURL(for: model.url, format: model.format).path
        durableSettingsByPath[canonicalPath] = normalized
        durableSettingsByPath[model.url.path] = normalized
        durableSettingsByModelKey[model.modelID + "|" + model.quant] = normalized
        if model.format == .et {
            store.updateETBackend(modelID: model.modelID, quantLabel: model.quant, backend: normalized.etBackend)
        }
    }

    func updateAlias(_ alias: String?, for model: LocalModel) {
        store.updateAlias(modelID: model.modelID, quantLabel: model.quant, alias: alias)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlias = trimmed?.isEmpty == false ? trimmed : nil

        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx].alias = normalizedAlias
        }
        if let idx = hiddenModels.firstIndex(where: { $0.id == model.id }) {
            hiddenModels[idx].alias = normalizedAlias
        }
        if loadedModel?.id == model.id {
            loadedModel?.alias = normalizedAlias
        }
        if lastUsedModel?.id == model.id {
            lastUsedModel?.alias = normalizedAlias
        }
    }

    var favouriteCount: Int { favouritePaths.count }
    var favouriteCapacity: Int { Self.favouriteLimit }

    private func persistFavourites() {
        if favouritePaths.count > Self.favouriteLimit {
            favouritePaths = Array(favouritePaths.prefix(Self.favouriteLimit))
        }
        UserDefaults.standard.set(favouritePaths, forKey: "favouriteModels")
    }

    @discardableResult
    private func pruneFavouritePaths(against models: [LocalModel]) -> Bool {
        let validPaths = Set(models.map { $0.url.path })
        let filtered = favouritePaths.filter { validPaths.contains($0) }
        guard filtered != favouritePaths else { return false }
        favouritePaths = filtered
        persistFavourites()
        return true
    }

    func canFavourite(_ model: LocalModel) -> Bool {
        _ = pruneFavouritePaths(against: downloadedModels)
        return favouritePaths.contains(model.url.path) || favouritePaths.count < Self.favouriteLimit
    }

    @discardableResult
    func setFavourite(_ model: LocalModel, isFavourite desired: Bool) -> Bool {
        _ = pruneFavouritePaths(against: downloadedModels)
        let path = model.url.path
        if desired {
            if !favouritePaths.contains(path) {
                guard favouritePaths.count < Self.favouriteLimit else { return false }
                favouritePaths.append(path)
            }
        } else {
            favouritePaths.removeAll { $0 == path }
        }
        persistFavourites()

        let updatedValue = favouritePaths.contains(path)
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            var models = downloadedModels
            models[idx].isFavourite = updatedValue
            downloadedModels = models
        }
        store.updateFavorite(modelID: model.modelID, quantLabel: model.quant, fav: updatedValue)
        return true
    }

    @discardableResult
    func toggleFavourite(_ model: LocalModel) -> Bool {
        _ = pruneFavouritePaths(against: downloadedModels)
        let shouldFavourite = !favouritePaths.contains(model.url.path)
        if shouldFavourite && favouritePaths.count >= Self.favouriteLimit {
            return false
        }
        return setFavourite(model, isFavourite: shouldFavourite)
    }

    func favouriteModels(limit: Int = AppModelManager.favouriteLimit) -> [LocalModel] {
        let favourites = downloadedModels
            .filter { favouritePaths.contains($0.url.path) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastUsedDate ?? lhs.downloadDate
                let rhsDate = rhs.lastUsedDate ?? rhs.downloadDate
                return lhsDate > rhsDate
            }
        return limit > 0 ? Array(favourites.prefix(limit)) : favourites
    }

    func recentModels(limit: Int = 3, excludingIDs: Set<String> = []) -> [LocalModel] {
        let recents = downloadedModels
            .filter { $0.lastUsedDate != nil }
            .filter { !excludingIDs.contains($0.id) }
            .sorted { ($0.lastUsedDate ?? Date.distantPast) > ($1.lastUsedDate ?? Date.distantPast) }
        return limit > 0 ? Array(recents.prefix(limit)) : recents
    }

    private func scanLayersIfNeeded() {
        let pending = downloadedModels.filter { $0.totalLayers == 0 }
        guard !pending.isEmpty else { return }
        let models = pending
        Task.detached(priority: .utility) { [weak self] in
            for model in models {
                let count = ModelScanner.layerCount(for: model.url, format: model.format)
                await self?.applyLayerCount(count, to: model)
                // Stagger to avoid startup spikes
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func scanMoEInfoIfNeeded() {
        let pending = downloadedModels.filter { model in
            switch model.format {
            case .gguf:
                guard let info = model.moeInfo else { return true }
                // Re-scan when the attention shape is absent: it drives exact KV-cache
                // sizing and was added after some models had their metadata cached.
                if info.headCountKV == nil { return true }
                // Architecture and hybrid/recurrent state fields were added later. Re-scan
                // older cached descriptors so Qwen3.5/3.6 does not charge KV to all blocks.
                if info.architecture == nil { return true }
                if let architecture = info.architecture,
                   ["qwen35", "qwen35moe"].contains(architecture),
                   (info.attentionLayerCount == nil || info.recurrentLayerCount == nil ||
                    info.ssmConvKernel == nil || info.ssmInnerSize == nil ||
                    info.ssmStateSize == nil || info.ssmGroupCount == nil) {
                    return true
                }
                if info.isMoE {
                    return info.moeLayerCount == nil || info.totalLayerCount == nil || info.hiddenSize == nil || info.feedForwardSize == nil || info.vocabSize == nil
                }
                return info.totalLayerCount == nil
            case .mlx:
                guard let info = model.moeInfo else { return true }
                if info.isMoE {
                    return info.expertCount <= 1
                }
                if info.totalLayerCount == nil, info.moeLayerCount == 0 {
                    return true
                }
                return false
            case .et, .ane, .afm, .coreai:
                return false
            }
        }
        guard !pending.isEmpty else { return }
        let models = pending
        Task.detached(priority: .utility) { [weak self] in
            print("[MoEDetect] queued \(models.count) models for metadata scan")
            for model in models {
                let descriptor = "\(model.name) (\(model.quant)) [\(model.format.displayName)]"
                print("[MoEDetect] ▶︎ scanning \(descriptor)")
                let info = ModelScanner.moeInfo(for: model.url, format: model.format)
                let resolvedInfo: MoEInfo
                if let info {
                    let label = info.isMoE ? "MoE" : "Dense"
                    let moeLayers = info.moeLayerCount.map(String.init) ?? "n/a"
                    let totalLayers = info.totalLayerCount.map(String.init) ?? "n/a"
                    print("[MoEDetect] ✓ \(descriptor) result=\(label) experts=\(info.expertCount) moeLayers=\(moeLayers) totalLayers=\(totalLayers)")
                    resolvedInfo = info
                } else {
                    print("[MoEDetect] ⚠︎ \(descriptor) scan failed; defaulting to Dense metadata")
                    resolvedInfo = .denseFallback
                }
                guard let self else {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    continue
                }
                await self.applyMoEInfo(resolvedInfo, to: model)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func scanCapabilitiesIfNeeded() {
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
        // Prepare a list of models that still need capability detection
        let candidates: [(id: String, quant: String, format: ModelFormat, url: URL)] = downloadedModels.compactMap { model in
            // Skip if we already have capability info
            if model.isMultimodal || model.isToolCapable { return nil }
            if let installed = store.all().first(where: { $0.modelID == model.modelID && $0.quantLabel == model.quant }),
               (installed.isMultimodal || installed.isToolCapable) { return nil }
            return (model.modelID, model.quant, model.format, model.url)
        }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for (modelID, quant, format, localURL) in candidates {
                // Only use pipeline tag for multimodality
                var isVision = false
                var toolCap = false

                switch format {
                case .gguf, .mlx:
                    let meta = await HuggingFaceMetadataCache.fetchAndCache(repoId: modelID, token: token)
                    isVision = meta?.isVision ?? false
                    if !isVision {
                        // Fallback to on-disk heuristics for missing/incorrect tags
                        let ggufDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
                        if let gguf = InstalledModelsStore.firstGGUF(in: ggufDir) {
                            isVision = ChatVM.guessLlamaVisionModel(from: gguf)
                        } else {
                            let mlxDir = InstalledModelsStore.baseDir(for: .mlx, modelID: modelID)
                            isVision = MLXBridge.isVLMModel(at: mlxDir)
                        }
                    }
                    toolCap = await ToolCapabilityDetector.isToolCapable(repoId: modelID, token: token)
                    if toolCap == false {
                        // Local fallback: prefer GGUF file or MLX directory
                        let ggufDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
                        if let gguf = InstalledModelsStore.firstGGUF(in: ggufDir) {
                            toolCap = ToolCapabilityDetector.isToolCapableLocal(url: gguf, format: .gguf)
                        } else {
                            let mlxDir = InstalledModelsStore.baseDir(for: .mlx, modelID: modelID)
                            toolCap = ToolCapabilityDetector.isToolCapableLocal(url: mlxDir, format: .mlx)
                        }
                    }
                case .et:
                    isVision = ETModelResolver.isVisionIdentifier(modelID) || ETModelResolver.isLikelyVisionModel(at: localURL)
                    toolCap = true
                case .ane:
                    isVision = false
                    let aneDir = InstalledModelsStore.baseDir(for: .ane, modelID: modelID)
                    toolCap = ToolCapabilityDetector.isToolCapableLocal(url: aneDir, format: .ane)
                case .afm:
                    isVision = AppleFoundationModelKind.resolve(modelID: modelID)?.supportsVision ?? false
                    toolCap = true
                case .coreai:
                    isVision = false
                    let coreaiDir = InstalledModelsStore.baseDir(for: .coreai, modelID: modelID)
                    toolCap = ToolCapabilityDetector.isToolCapableLocal(url: coreaiDir, format: .coreai)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.store.updateCapabilities(modelID: modelID, quantLabel: quant, isMultimodal: isVision, isToolCapable: toolCap)
                    // Update in-memory list in place to avoid full refresh loops
                    if let idx = self.downloadedModels.firstIndex(where: { $0.modelID == modelID && $0.quant == quant }) {
                        self.downloadedModels[idx].isMultimodal = isVision
                        self.downloadedModels[idx].isToolCapable = toolCap
                    }
                }
                // Stagger requests
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func applyLayerCount(_ count: Int, to model: LocalModel) {
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx].totalLayers = count
            store.updateLayers(modelID: model.modelID, quantLabel: model.quant, layers: count)
        }
    }

    private func hydrateMoEInfoFromCache() {
        Task { [weak self] in
            let cache = await MoEDetectionStore.shared.all()
            guard !cache.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                var updated = self.downloadedModels
                var mutated = false
                for idx in updated.indices {
                    if updated[idx].moeInfo == nil && !updated[idx].modelID.hasPrefix("local/") {
                        let key = MoEDetectionStore.key(modelID: updated[idx].modelID, quantLabel: updated[idx].quant)
                        if let cachedInfo = cache[key] {
                            updated[idx].moeInfo = cachedInfo
                            self.store.updateMoEInfo(modelID: updated[idx].modelID, quantLabel: updated[idx].quant, info: cachedInfo)
                            mutated = true
                        }
                    }
                }
                if mutated {
                    self.downloadedModels = updated
                }
            }
        }
    }

    private static let moeDetectorVersionKey = "moeDetectorVersion"
    private static let currentMoEDetectorVersion = 2

    /// Imported models (`local/*`) historically used less-complete GGUF metadata keys/tensors, leading to
    /// dense misclassification. When our detector improves, clear cached results for local GGUF models once
    /// so they get re-scanned with the updated heuristics.
    private func invalidateLocalGGUFMoeInfoIfNeeded() {
        let storedVersion = UserDefaults.standard.integer(forKey: Self.moeDetectorVersionKey)
        guard storedVersion < Self.currentMoEDetectorVersion else { return }
        let localGGUFModels = downloadedModels.filter { $0.format == .gguf && $0.modelID.hasPrefix("local/") }
        guard !localGGUFModels.isEmpty else {
            UserDefaults.standard.set(Self.currentMoEDetectorVersion, forKey: Self.moeDetectorVersionKey)
            return
        }

        var updated = downloadedModels
        var mutated = false
        for idx in updated.indices {
            let model = updated[idx]
            guard model.format == .gguf, model.modelID.hasPrefix("local/") else { continue }
            if updated[idx].moeInfo != nil {
                updated[idx].moeInfo = nil
                store.updateMoEInfo(modelID: model.modelID, quantLabel: model.quant, info: nil)
                mutated = true
            }
        }
        if mutated {
            downloadedModels = updated
        }

        Task.detached(priority: .utility) {
            for model in localGGUFModels {
                await MoEDetectionStore.shared.remove(modelID: model.modelID, quantLabel: model.quant)
            }
        }
        UserDefaults.standard.set(Self.currentMoEDetectorVersion, forKey: Self.moeDetectorVersionKey)
    }

    @MainActor
    private func applyMoEInfo(_ info: MoEInfo, to model: LocalModel) async {
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx].moeInfo = info
        }
        store.updateMoEInfo(modelID: model.modelID, quantLabel: model.quant, info: info)
        await MoEDetectionStore.shared.update(info: info, modelID: model.modelID, quantLabel: model.quant)
    }
}

extension AppModelManager: ModelLoadingManaging {}
#endif
