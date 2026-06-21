// NoemaAppIntentDriver.swift
//
// Bridges App Intents (Siri / Shortcuts / Spotlight) to the live app object
// graph. Each platform's App entry binds its root objects here at launch;
// intents resolve through the driver and fail with a friendly error when the
// app has not finished launching yet.

import Foundation
import SwiftUI

@MainActor
final class AppIntentDriver {
    static let shared = AppIntentDriver()

    private(set) weak var chatVM: ChatVM?
    private(set) weak var modelManager: AppModelManager?
    private(set) weak var datasetManager: DatasetManager?
    private(set) weak var tabRouter: TabRouter?
    private(set) weak var downloadController: DownloadController?

    private init() {}

    func bind(chatVM: ChatVM,
              modelManager: AppModelManager,
              datasetManager: DatasetManager,
              tabRouter: TabRouter,
              downloadController: DownloadController) {
        self.chatVM = chatVM
        self.modelManager = modelManager
        self.datasetManager = datasetManager
        self.tabRouter = tabRouter
        self.downloadController = downloadController
        NoemaEntityIndexer.scheduleDonation()
    }

    var isBound: Bool { chatVM != nil && modelManager != nil }

    /// Siri can start an intent while the SwiftUI graph is still being built
    /// on a cold launch; give binding a moment before giving up.
    func waitUntilBound(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isBound && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isBound
    }

    // MARK: - Catalog access (works without a bound graph where possible)

    /// Installed models, preferring the live manager and falling back to the
    /// on-disk store so entity queries also work right after process launch.
    func installedModels() -> [LocalModel] {
        if let modelManager {
            return modelManager.downloadedModels + modelManager.hiddenModels
        }
        return LocalModel.loadInstalled(store: InstalledModelsStore())
    }

    func downloadedDatasets() -> [LocalDataset] {
        if let datasetManager, !datasetManager.datasets.isEmpty {
            return datasetManager.datasets
        }
        return Self.scanDatasetsOnDisk()
    }

    /// Minimal mirror of `DatasetManager.reloadFromDisk()` for use before the
    /// app graph is bound (entity queries from Siri/Spotlight).
    nonisolated static func scanDatasetsOnDisk() -> [LocalDataset] {
        let fm = FileManager.default
        var url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        var found: [LocalDataset] = []
        guard let owners = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return []
        }
        for owner in owners {
            var ownerIsDir: ObjCBool = false
            guard fm.fileExists(atPath: owner.path, isDirectory: &ownerIsDir), ownerIsDir.boolValue,
                  let dirs = try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
                continue
            }
            for dir in dirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let id = owner.lastPathComponent + "/" + dir.lastPathComponent
                let attrs = try? fm.attributesOfItem(atPath: dir.path)
                let created = attrs?[.creationDate] as? Date ?? Date()
                let title = DatasetTextReader.readString(from: DatasetIndexIO.titleURL(for: dir))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceName: String = {
                    let ownerName = owner.lastPathComponent
                    if ownerName == "OTL" { return "Open Textbook Library" }
                    if ownerName == "Imported" { return "Imported" }
                    if ownerName == EnterpriseDatasetStore.ownerDirectoryName { return "Enterprise" }
                    return "Hugging Face"
                }()
                found.append(LocalDataset(
                    datasetID: id,
                    name: (title?.isEmpty == false ? title! : dir.lastPathComponent),
                    url: dir,
                    sizeMB: 0,
                    source: sourceName,
                    downloadDate: created,
                    lastUsedDate: nil,
                    isSelected: false,
                    isIndexed: DatasetIndexIO.hasValidIndex(at: dir),
                    requiresReindex: false
                ))
            }
        }
        found.removeAll { !EnterprisePolicyGate.allowsDataset(datasetID: $0.datasetID) }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Actions

    /// Loads an installed model by its stable identifier (file path).
    /// Mirrors `StartupLoader.attemptLocal`.
    func loadModel(withID id: String) async throws -> LocalModel {
        guard let chatVM, let modelManager else { throw NoemaIntentError.appNotReady }
        guard let model = installedModels().first(where: { $0.id == id }) else {
            throw NoemaIntentError.modelNotFound
        }
        if modelManager.loadedModel?.id == model.id, chatVM.modelLoaded {
            return model
        }
        let settings = modelManager.settings(for: model)
        await chatVM.unload()
        let success = await chatVM.load(url: model.url, settings: settings, format: model.format)
        if success {
            modelManager.updateSettings(settings, for: model)
            modelManager.markModelUsed(model)
            NoemaEntityIndexer.scheduleDonation()
            return model
        }
        modelManager.loadedModel = nil
        throw NoemaIntentError.loadFailed(chatVM.loadError ?? String(localized: "The model could not be loaded."))
    }

    func unloadModel() async throws {
        guard let chatVM, let modelManager else { throw NoemaIntentError.appNotReady }
        modelManager.loadedModel = nil
        await chatVM.unload()
    }

    /// Makes sure some model is ready for chat, trying the user's startup
    /// preferences first and the most recently used local model second.
    func ensureModelLoaded() async throws -> String {
        guard let chatVM, let modelManager else { throw NoemaIntentError.appNotReady }
        if chatVM.modelLoaded {
            return modelManager.loadedModel?.displayName ?? String(localized: "the loaded model")
        }
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        await StartupLoader.performStartupLoad(chatVM: chatVM, modelManager: modelManager, offGrid: offGrid)
        if chatVM.modelLoaded {
            return modelManager.loadedModel?.displayName ?? String(localized: "the loaded model")
        }
        if let lastUsed = modelManager.lastUsedModel ?? modelManager.downloadedModels.first(where: { $0.isDownloaded }) {
            let model = try await loadModel(withID: lastUsed.id)
            return model.displayName
        }
        throw NoemaIntentError.noModelAvailable
    }

    func startNewChat() throws {
        guard let chatVM else { throw NoemaIntentError.appNotReady }
        tabRouter?.selection = .chat
        chatVM.startNewSession()
    }

    /// Starts a new chat and sends `prompt`. Generation streams in the app UI;
    /// this returns as soon as the message is on its way.
    func ask(_ prompt: String, inNewChat: Bool) async throws {
        guard let chatVM else { throw NoemaIntentError.appNotReady }
        tabRouter?.selection = .chat
        if inNewChat {
            chatVM.startNewSession()
        }
        Task { await chatVM.sendMessage(prompt) }
    }

    func selectDataset(withID id: String?) throws -> LocalDataset? {
        guard let datasetManager else { throw NoemaIntentError.appNotReady }
        guard let id else {
            datasetManager.select(nil)
            return nil
        }
        guard let dataset = downloadedDatasets().first(where: { $0.datasetID == id }) else {
            throw NoemaIntentError.datasetNotFound
        }
        datasetManager.select(dataset)
        return dataset
    }

    func openDatasetDetail(withID id: String) throws {
        guard let tabRouter else { throw NoemaIntentError.appNotReady }
        tabRouter.selection = .stored
        tabRouter.pendingStoredDatasetID = id
    }

    func open(page: NoemaAppPage) throws {
        guard let tabRouter else { throw NoemaIntentError.appNotReady }
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        switch page {
        case .chat:
            tabRouter.selection = .chat
        case .stored:
            tabRouter.selection = .stored
        case .exploreModels, .exploreDatasets:
            guard !offGrid else { throw NoemaIntentError.offGridBlocked }
            tabRouter.pendingExploreSection = (page == .exploreModels) ? .models : .datasets
            tabRouter.selection = .explore
        case .settings:
            tabRouter.selection = .settings
        case .downloads:
            downloadController?.showPopup = true
        }
    }

    func searchExplore(query: String, scope: NoemaExploreScope) throws {
        guard let tabRouter else { throw NoemaIntentError.appNotReady }
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        guard !offGrid else { throw NoemaIntentError.offGridBlocked }
        tabRouter.pendingExploreSection = (scope == .datasets) ? .datasets : .models
        tabRouter.pendingExploreSearch = query
        tabRouter.selection = .explore
    }

    /// Returns the resulting state.
    func setOffGrid(_ mode: NoemaOffGridMode) -> Bool {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: "offGrid") as? Bool ?? false
        let next: Bool
        switch mode {
        case .on: next = true
        case .off: next = false
        case .toggle: next = !current
        }
        defaults.set(next, forKey: "offGrid")
        NetworkKillSwitch.setEnabled(next)
        // The Explore tab disappears in off-grid mode; don't leave the
        // selection pointing at a tab that no longer exists.
        if next, let tabRouter, tabRouter.selection == .explore {
            tabRouter.selection = .chat
        }
        return next
    }
}
