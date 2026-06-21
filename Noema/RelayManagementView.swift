import SwiftUI
import Combine
import RelayKit

#if os(macOS)
import AppKit
import CloudKit
import CryptoKit

private actor RelayManagementWorker {
    struct CatalogPublishSnapshot: Sendable {
        let status: RelayHostStatus
        let changedBy: String
        let deviceName: String
        let activeModelID: String?
        let activeContext: Int?
        let capabilities: [String: String]
        let models: [RelayCatalogModelDraft]
        let endpoints: [RelayCatalogEndpointDraft]
    }

    func publishCatalog(_ snapshot: CatalogPublishSnapshot) async throws -> (version: Int, status: RelayHostStatus) {
        try Task.checkCancellation()

        let publisher = RelayCatalogPublisher.shared

        _ = try await publisher.updateHostState(status: snapshot.status,
                                                activeModelID: snapshot.activeModelID,
                                                tokensPerSecond: nil,
                                                context: snapshot.activeContext,
                                                changedBy: snapshot.changedBy)

        try Task.checkCancellation()

        let version = try await publisher.updateCatalog(deviceName: snapshot.deviceName,
                                                        capabilities: snapshot.capabilities,
                                                        status: snapshot.status,
                                                        models: snapshot.models,
                                                        endpoints: snapshot.endpoints)
        return (version, snapshot.status)
    }
}

struct RelayWarmupHealth: Sendable {
    let names: [String]
    let offlineModelIDs: Set<String>

    static let empty = RelayWarmupHealth(names: [], offlineModelIDs: [])
}

struct RelayLifecycleDependencies: Sendable {
    var ensureLocalNetworkPermission: @Sendable () async -> Void
    var makeHTTPServer: @Sendable (RelayServerEngine, RelayServerConfiguration) -> any RelayHTTPServing
    var performHealthCheck: @Sendable (RelayManagementViewModel, UUID) async throws -> RelayWarmupHealth
    var startCloudKitProcessing: @Sendable (InferenceProvider) async -> Void
    var stopCloudKitProcessing: @Sendable () -> Void

    static func live() -> RelayLifecycleDependencies {
        RelayLifecycleDependencies(
            ensureLocalNetworkPermission: {
                await LocalNetworkPermissionRequester.shared.ensurePrompt()
            },
            makeHTTPServer: { engine, configuration in
                RelayHTTPServer(engine: engine, configuration: configuration)
            },
            performHealthCheck: { viewModel, runID in
                await viewModel.checkExposedEndpointsHealth(for: runID)
            },
            startCloudKitProcessing: { provider in
                let containerID = RelayConfiguration.containerIdentifier
                CloudKitRelay.shared.configure(containerIdentifier: containerID, provider: provider)
                await CloudKitRelay.shared.startServerProcessing()
            },
            stopCloudKitProcessing: {
                CloudKitRelay.shared.stopServerProcessing()
            }
        )
    }
}

@MainActor
final class RelayManagementViewModel: ObservableObject {
    @MainActor static let shared = RelayManagementViewModel()

    enum ServerState: Equatable {
        case stopped
        case starting
        case running
        case error(String)
    }

    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var statusMessage: String = String(
        localized: "Relay stopped",
        locale: LocalizationManager.preferredLocale()
    )
    @Published private(set) var serverConfiguration = RelayServerConfiguration.load()
    @Published private(set) var httpServerState: RelayHTTPServer.State?
    @Published private(set) var lanReachableAddress: String?
    @Published private(set) var isLANServerStarting = false
    @Published private(set) var bluetoothState: RelayBluetoothAdvertiser.State = .idle
    @Published private(set) var payload: RelayBluetoothPayload?
    @Published private(set) var lastActivity: Date?
    @Published private(set) var catalogVersion: Int = 0
    @Published private(set) var cloudKitAccountStatus: CKAccountStatus?
    @Published private(set) var cloudKitAccountError: String?
    @Published private(set) var isCheckingCloudKitAccount = false
    @Published private(set) var lastCatalogUpdate: Date?
    @Published private(set) var lastPublishedHostStatus: RelayHostStatus = .idle
    @Published private(set) var connectedClients: [RelayServerEngine.ConnectedClient] = []
    @Published private(set) var loadedModels: [RelayServerEngine.ModelSnapshot] = []
    @Published private(set) var loadingModelIDs: Set<String> = []
    private var relaySnapshots: [RelayServerEngine.ModelSnapshot] = []
    private var appLoadedDescriptorID: String?
    var relayHasLocalOwnership: Bool {
        relaySnapshots.contains { $0.isLoaded && $0.descriptor.isLocal }
    }
    @Published fileprivate var availableModels: [RelayModelDescriptor] = []
    @Published fileprivate var catalogEntries: [RelayCatalogEntry] = [] {
        didSet {
            let entries = catalogEntries
            Task { await serverEngine.updateCatalogEntries(entries) }
            guard hasFinishedInitialLoad else { return }
            persistCatalogEntries()
            refreshPayload()
            scheduleCatalogUpdate()
        }
    }
    @Published var activeModelID: String? {
        didSet {
            guard activeModelID != oldValue else { return }
            guard hasFinishedInitialLoad else { return }
            persistActiveModelID()
            Task { await serverEngine.updateActiveModel(activeModelID) }
            refreshPayload()
            scheduleCatalogUpdate()
        }
    }
    @Published var ejectsModelOnDisconnect: Bool = false {
        didSet {
            guard hasFinishedInitialLoad else { return }
            persistEjectPreference()
            scheduleCatalogUpdate()
        }
    }

    private let advertiser = RelayBluetoothAdvertiser()
    private let catalogPublisher = RelayCatalogPublisher.shared
    private let worker = RelayManagementWorker()
    private let catalogUpdateDebounceNanoseconds: UInt64 = 250_000_000
    private let hostDeviceID = RelayConfiguration.hostDeviceIdentifier
    private let dependencies: RelayLifecycleDependencies
    private var startupTask: Task<Void, Never>?
    private var startupWarmupTask: Task<Void, Never>?
    private var serverTask: Task<Void, Never>?
    private var httpServer: (any RelayHTTPServing)?
    private var commandListenerTask: Task<Void, Never>?
    private var catalogUpdateTask: Task<Void, Never>?
    private var loadedModelsMonitorTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var modelManagerCancellables: Set<AnyCancellable> = []
    private var relayIdentifier = UUID()
    private var hasFinishedInitialLoad = false
    fileprivate var hadPendingCommandWhileStopped = false
    private var statusAnimation: Animation? {
        .easeInOut(duration: 0.25)
    }
    private weak var modelManager: AppModelManager?
    private weak var chatVM: ChatVM?
    private let serverEngine = RelayServerEngine()
    private var lastKnownLANAddress: String?
    private var activeRunID = UUID()

    private static let catalogEntriesKey = "relay.catalog.entries"
    private static let activeModelKey = "relay.activeModelID"
    private static let ejectsOnDisconnectKey = "relay.ejectsOnDisconnect"

    convenience init() {
        self.init(dependencies: .live())
    }

    init(dependencies: RelayLifecycleDependencies) {
        self.dependencies = dependencies
        advertiser.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.bluetoothState = state
            }
            .store(in: &cancellables)

        advertiser.$lastPayload
            .receive(on: DispatchQueue.main)
            .sink { [weak self] payload in
                self?.payload = payload
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshCloudKitAccountStatus() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .relayWillLoadLocalModel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleRelayWillLoadLocalModel()
            }
            .store(in: &cancellables)

        loadCatalogState()

        Task { [weak self] in
            await self?.configureCatalogPublisher()
        }

        Task { [weak self] in
            await self?.refreshCloudKitAccountStatus()
        }

        Task { [weak self] in
            guard let self else { return }
            await self.serverEngine.updateConfiguration(self.serverConfiguration)
        }

        commandListenerTask = Task.detached(priority: .utility) { [weak self, hostDeviceID, catalogPublisher] in
            guard let viewModel = self else { return }
            await relayCommandLoop(viewModel: viewModel,
                                   hostDeviceID: hostDeviceID,
                                   catalogPublisher: catalogPublisher)
        }

#if os(macOS)
        RelayControlCenter.shared.register(self)

        $serverState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                RelayControlCenter.shared.refresh(from: self)
            }
            .store(in: &cancellables)

        $statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                RelayControlCenter.shared.refresh(from: self)
            }
            .store(in: &cancellables)

        $lanReachableAddress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                RelayControlCenter.shared.refresh(from: self)
            }
            .store(in: &cancellables)

        $isLANServerStarting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                RelayControlCenter.shared.refresh(from: self)
            }
            .store(in: &cancellables)

        $lastActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                RelayControlCenter.shared.refresh(from: self)
            }
            .store(in: &cancellables)
#endif
    }

    private func beginLifecycleRun() -> UUID {
        let runID = UUID()
        activeRunID = runID
        return runID
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        activeRunID == runID
    }

    // MARK: - Public model load/unload helpers

    func isModelLoaded(_ descriptorID: String) -> Bool {
        loadedModels.first(where: { $0.descriptor.id == descriptorID })?.isLoaded == true
    }

    func loadModel(_ descriptorID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run { self.loadingModelIDs.insert(descriptorID) }
                try await self.serverEngine.ensureModelLoaded(descriptorID, origin: .manual)
                await self.refreshLoadedModelsSnapshot()
                await MainActor.run {
                    self.loadingModelIDs.remove(descriptorID)
                    self.setStatusMessage(
                        String(
                            localized: "Loaded model ready",
                            locale: LocalizationManager.preferredLocale()
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.loadingModelIDs.remove(descriptorID)
                    self.setStatusMessage(
                        String(
                            localized: "Failed to load model",
                            locale: LocalizationManager.preferredLocale()
                        )
                    )
                }
            }
        }
    }

    func unloadModel(_ descriptorID: String) {
        Task { [weak self] in
            guard let self else { return }
            let shouldUnloadAppModel = await MainActor.run { self.appLoadedDescriptorID == descriptorID }
            if shouldUnloadAppModel {
                if let chatVM = await MainActor.run(body: { self.chatVM as ChatVM? }) {
                    await chatVM.unload()
                }
                await MainActor.run {
                    self.modelManager?.loadedModel = nil
                    self.appLoadedDescriptorID = nil
                    self.recomputeLoadedModels()
                }
            }
            await self.serverEngine.unloadModel(descriptorID, reason: "manual unload")
            await self.refreshLoadedModelsSnapshot()
        }
    }

    @MainActor deinit {
#if os(macOS)
        RelayControlCenter.shared.unregister(self)
#endif
        startupTask?.cancel()
        startupWarmupTask?.cancel()
        serverTask?.cancel()
        commandListenerTask?.cancel()
    }

    func bind(modelManager: AppModelManager, chatVM: ChatVM) {
        if self.modelManager === modelManager, self.chatVM === chatVM { return }
        self.modelManager = modelManager
        self.chatVM = chatVM
        modelManagerCancellables.removeAll()

        Publishers.CombineLatest3(
            modelManager.$downloadedModels,
            modelManager.$remoteBackends,
            modelManager.$loadedModel
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locals, remotes, loaded in
                self?.refreshModels(localModels: locals, remoteBackends: remotes, appLoadedModel: loaded)
            }
            .store(in: &modelManagerCancellables)

        refreshModels(localModels: modelManager.downloadedModels,
                      remoteBackends: modelManager.remoteBackends,
                      appLoadedModel: modelManager.loadedModel)
    }

    private func configureCatalogPublisher() async {
        await catalogPublisher.configure(containerIdentifier: RelayConfiguration.containerIdentifier,
                                          hostDeviceID: hostDeviceID)
        await catalogPublisher.ensureCommandSubscription()
        hasFinishedInitialLoad = true
        Task { await serverEngine.updateDescriptors(availableModels) }
        Task { await serverEngine.updateActiveModel(activeModelID) }
        refreshPayload()
        scheduleCatalogUpdate()
    }

    private func refreshCloudKitAccountStatus() async {
        isCheckingCloudKitAccount = true
        cloudKitAccountError = nil

        let containerID = RelayConfiguration.containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerID.isEmpty else {
            cloudKitAccountStatus = nil
            cloudKitAccountError = String(
                localized: "Set the CloudKit container identifier in RelayConfiguration.swift to enable syncing.",
                locale: LocalizationManager.preferredLocale()
            )
            isCheckingCloudKitAccount = false
            return
        }

        let container = CKContainer(identifier: containerID)
        do {
            let status = try await container.accountStatus()
            cloudKitAccountStatus = status
            cloudKitAccountError = nil
        } catch {
            cloudKitAccountStatus = nil
            cloudKitAccountError = error.localizedDescription
        }

        isCheckingCloudKitAccount = false
    }

    private func loadCatalogState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.catalogEntriesKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([RelayCatalogEntry].self, from: data) {
                catalogEntries = decoded
            } else {
                catalogEntries = []
            }
        } else {
            catalogEntries = []
        }
        if defaults.object(forKey: Self.ejectsOnDisconnectKey) != nil {
            ejectsModelOnDisconnect = defaults.bool(forKey: Self.ejectsOnDisconnectKey)
        } else {
            ejectsModelOnDisconnect = false
        }
        if let activeID = defaults.string(forKey: Self.activeModelKey), !activeID.isEmpty {
            activeModelID = activeID
        } else {
            activeModelID = nil
        }
    }

    private func refreshModels(localModels: [LocalModel],
                               remoteBackends: [RemoteBackend],
                               appLoadedModel: LocalModel?) {
        let descriptors = buildDescriptors(localModels: localModels, remoteBackends: remoteBackends)
        availableModels = descriptors

        Task { await serverEngine.updateDescriptors(descriptors) }

        mergeCatalogEntries(with: descriptors)
        appLoadedDescriptorID = descriptorID(for: appLoadedModel, in: descriptors)
        recomputeLoadedModels()

        if let activeID = activeModelID, !descriptors.contains(where: { $0.id == activeID }) {
            activeModelID = descriptors.first(where: { descriptor in
                catalogEntries.first(where: { $0.modelID == descriptor.id })?.exposed == true
            })?.id ?? descriptors.first?.id
        }

        Task { await serverEngine.updateActiveModel(activeModelID) }
        Task { await refreshLoadedModelsSnapshot() }
        refreshPayload()
    }

    private func descriptorID(for model: LocalModel?, in descriptors: [RelayModelDescriptor]) -> String? {
        guard let model else { return nil }
        return descriptors.first(where: { descriptor in
            guard case .local(let local) = descriptor.kind else { return false }
            if local.modelID == model.modelID && local.quant == model.quant {
                return true
            }
            return local.url == model.url
        })?.id
    }

    private func recomputeLoadedModels() {
        var relayByID: [String: RelayServerEngine.ModelSnapshot] = [:]
        for snapshot in relaySnapshots {
            relayByID[snapshot.descriptor.id] = snapshot
        }

        loadedModels = availableModels.map { descriptor in
            var snapshot = relayByID[descriptor.id] ?? RelayServerEngine.ModelSnapshot(
                id: descriptor.identifier,
                displayName: descriptor.displayName,
                ownedBy: descriptor.provider.displayName,
                created: catalogEntries.first(where: { $0.modelID == descriptor.id })?.lastChecked ?? Date(),
                isLoaded: false,
                contextLength: descriptor.context,
                quant: descriptor.quant,
                sizeBytes: descriptor.sizeBytes,
                provider: descriptor.provider,
                descriptor: descriptor
            )
            snapshot.id = descriptor.identifier
            snapshot.displayName = descriptor.displayName
            snapshot.ownedBy = descriptor.provider.displayName
            snapshot.contextLength = descriptor.context
            snapshot.quant = descriptor.quant
            snapshot.sizeBytes = descriptor.sizeBytes
            snapshot.provider = descriptor.provider
            snapshot.descriptor = descriptor
            snapshot.isLoaded = snapshot.isLoaded || (appLoadedDescriptorID == descriptor.id)
            return snapshot
        }
    }

    private func handleRelayWillLoadLocalModel() {
        Task { [weak self] in
            guard let self else { return }
            let shouldPreempt = await MainActor.run { () -> Bool in
                guard let manager = self.modelManager,
                      let chatVM = self.chatVM else { return false }
                if manager.loadedModel != nil { return true }
                return chatVM.modelLoaded && chatVM.loadedModelURL != nil
            }
            guard shouldPreempt else { return }

            if let chatVM = await MainActor.run(body: { self.chatVM as ChatVM? }) {
                await chatVM.unload()
            }

            await MainActor.run {
                self.modelManager?.loadedModel = nil
                self.appLoadedDescriptorID = nil
                self.recomputeLoadedModels()
            }
        }
    }

    func applySettings(_ settings: ModelSettings, forRelayModelID id: String) async {
        guard let manager = modelManager,
              let descriptor = availableModels.first(where: { $0.id == id }) else { return }
        guard case .local(let model) = descriptor.kind else { return }
        manager.updateSettings(settings, for: model)
        refreshModels(localModels: manager.downloadedModels,
                      remoteBackends: manager.remoteBackends,
                      appLoadedModel: manager.loadedModel)
        scheduleCatalogUpdate()
        await serverEngine.updateDescriptors(availableModels)
        await serverEngine.unloadModel(id, reason: "model settings updated")
        if case .running = serverState {
            do {
                // Reload as a JIT load; do not pin here because this path is a policy-driven reload
                try await serverEngine.ensureModelLoaded(id, origin: .jit)
            } catch {
                RelayLog.record(category: "RelayManagement",
                                message: "Failed to reload \(descriptor.displayName) after settings update: \(error.localizedDescription)")
            }
        }
        await refreshLoadedModelsSnapshot()
    }

    func updateServerConfiguration(restartHTTP: Bool = false, _ transform: (inout RelayServerConfiguration) -> Void) {
        var config = serverConfiguration
        transform(&config)
        guard config != serverConfiguration else { return }
        serverConfiguration = config
        serverConfiguration.saving()
        Task { await serverEngine.updateConfiguration(config) }
        if let httpServer {
            Task {
                try? await httpServer.updateConfiguration(config, restart: restartHTTP)
                await refreshHTTPServerState()
            }
        }
        refreshPayload()
        scheduleCatalogUpdate()
    }

    @MainActor
    private func refreshHTTPServerState(for runID: UUID? = nil) async {
        if let runID, !isCurrentRun(runID) { return }
        guard let httpServer else {
            httpServerState = nil
            lanReachableAddress = nil
            refreshPayload()
            return
        }
        let state = await httpServer.currentState()
        var adjusted = state
        if (adjusted.port ?? 0) == 0 {
            adjusted.port = serverConfiguration.port == 0 ? 12345 : serverConfiguration.port
        }
        if let lan = adjusted.reachableLANAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           lan.isEmpty || lan.hasSuffix(":0") {
            if let port = adjusted.port,
               port != 0,
               let recomputed = RelayHTTPServer.primaryLANAddress(bindHost: serverConfiguration.bindHost, port: port) {
                adjusted.reachableLANAddress = recomputed
            } else {
                adjusted.reachableLANAddress = nil
            }
        }
        httpServerState = adjusted
        lanReachableAddress = adjusted.reachableLANAddress
        refreshPayload()
        scheduleCatalogUpdate()
    }

    func setServerPort(_ value: UInt16) {
        updateServerConfiguration(restartHTTP: true) { config in
            config.port = value
        }
    }

    func toggleServeOnLocalNetwork(_ value: Bool) {
        updateServerConfiguration(restartHTTP: true) { config in
            config.serveOnLocalNetwork = value
        }
    }

    func toggleCORS(_ value: Bool) {
        updateServerConfiguration { config in
            config.enableCORS = value
        }
    }

    func updateAllowedOrigins(from text: String) {
        let origins = text.split(whereSeparator: { $0.isNewline || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        updateServerConfiguration { config in
            config.allowedOrigins = origins
        }
    }

    func regenerateAPIToken() {
        updateServerConfiguration(restartHTTP: true) { config in
            config.regenerateToken()
        }
    }

    func toggleJustInTimeLoading(_ value: Bool) {
        updateServerConfiguration { config in
            config.justInTimeLoading = value
        }
    }

    func toggleAutoUnloadJIT(_ value: Bool) {
        updateServerConfiguration { config in
            config.autoUnloadJIT = value
        }
    }

    func setIdleTTLMinutes(_ minutes: Int) {
        updateServerConfiguration { config in
            config.maxIdleTTLMinutes = max(1, minutes)
        }
    }

    func toggleKeepLastJITModel(_ value: Bool) {
        updateServerConfiguration { config in
            config.onlyKeepLastJITModel = value
        }
    }

    func toggleRequestLogging(_ value: Bool) {
        updateServerConfiguration { config in
            config.requestLoggingEnabled = value
        }
    }

    private func buildDescriptors(localModels: [LocalModel], remoteBackends: [RemoteBackend]) -> [RelayModelDescriptor] {
        var descriptors: [RelayModelDescriptor] = []

        for model in localModels where model.isDownloaded {
            descriptors.append(makeDescriptor(for: model))
        }

        for backend in remoteBackends {
            for remote in backend.cachedModels {
                descriptors.append(makeDescriptor(for: backend, remoteModel: remote))
            }
        }

        descriptors.sort { lhs, rhs in
            let lhsLocal = lhs.isLocal
            let rhsLocal = rhs.isLocal
            if lhsLocal != rhsLocal {
                return lhsLocal && !rhsLocal
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return descriptors
    }

    private func makeDescriptor(for model: LocalModel) -> RelayModelDescriptor {
        let origin = RelayModelOrigin.local(modelID: model.modelID, quant: model.quant)
        let originID = originIdentifier(for: origin)
        let modelID = stableModelID(for: originID)
        let settings = modelManager?.settings(for: model)
        let tags = tags(for: model)
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)

        return RelayModelDescriptor(
            id: modelID,
            origin: origin,
            kind: .local(model),
            displayName: "\(model.name) (\(model.quant))",
            provider: .local,
            endpointID: nil,
            identifier: model.modelID,
            context: settings.map { Int($0.contextLength) },
            quant: model.quant,
            sizeBytes: sizeBytes,
            tags: tags,
            settings: settings
        )
    }

    private func makeDescriptor(for backend: RemoteBackend, remoteModel: RemoteModel) -> RelayModelDescriptor {
        let origin = RelayModelOrigin.remote(backendID: backend.id, modelID: remoteModel.id)
        let originID = originIdentifier(for: origin)
        let modelID = stableModelID(for: originID)
        let provider = providerKind(for: backend)
        let endpointID = endpointIdentifier(for: backend)
        let tags = remoteModel.families ?? []

        return RelayModelDescriptor(
            id: modelID,
            origin: origin,
            kind: .remote(backend, remoteModel),
            displayName: "\(remoteModel.name) — \(backend.name)",
            provider: provider,
            endpointID: endpointID,
            identifier: remoteModel.id,
            context: remoteModel.maxContextLength,
            quant: remoteModel.quantization,
            sizeBytes: remoteModel.fileSizeBytes.map(Int64.init),
            tags: tags,
            settings: nil
        )
    }

    private func tags(for model: LocalModel) -> [String] {
        var tags: [String] = []
        if !model.architectureFamily.isEmpty {
            tags.append(model.architectureFamily)
        }
        if !model.quant.isEmpty { tags.append(model.quant) }
        if model.isMultimodal { tags.append("multimodal") }
        if model.isToolCapable { tags.append("tools") }
        return tags
    }

    private func providerKind(for backend: RemoteBackend) -> RelayProviderKind {
        switch backend.endpointType {
        case .ollama:
            return .ollama
        case .lmStudio:
            return .lmstudio
        default:
            return .http
        }
    }

    private func endpointKind(for backend: RemoteBackend) -> RelayEndpointKind {
        switch backend.endpointType {
        case .ollama:
            return .ollama
        case .lmStudio:
            return .lmstudio
        default:
            return .openAICompatible
        }
    }

    private func originIdentifier(for origin: RelayModelOrigin) -> String {
        switch origin {
        case .local(let modelID, let quant):
            return "local|\(modelID)|\(quant)"
        case .remote(let backendID, let modelID):
            return "remote|\(backendID.uuidString.lowercased())|\(modelID)"
        }
    }

    private func stableModelID(for originIdentifier: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "[^a-z0-9]+", options: [.caseInsensitive])
        let lower = originIdentifier.lowercased()
        let range = NSRange(location: 0, length: lower.utf16.count)
        let normalized = pattern.stringByReplacingMatches(in: lower, options: [], range: range, withTemplate: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let hash = SHA256.hash(data: Data(originIdentifier.utf8))
        let shortHash = hash.map { String(format: "%02x", $0) }.joined().prefix(12)
        if normalized.isEmpty {
            return "model-\(shortHash)"
        }
        return "\(normalized)-\(shortHash)"
    }

    private func endpointIdentifier(for backend: RemoteBackend) -> String {
        "endpoint-\(backend.id.uuidString.lowercased())"
    }

    private func mergeCatalogEntries(with descriptors: [RelayModelDescriptor]) {
        var existing = Dictionary(uniqueKeysWithValues: catalogEntries.map { ($0.originIdentifier, $0) })
        var merged: [RelayCatalogEntry] = []

        for descriptor in descriptors {
            let originID = originIdentifier(for: descriptor.origin)
            let modelID = descriptor.id
            if var entry = existing.removeValue(forKey: originID) {
                entry.modelID = modelID
                entry.displayName = descriptor.displayName
                entry.providerRaw = descriptor.provider.rawValue
                entry.endpointID = descriptor.endpointID
                entry.identifier = descriptor.identifier
                entry.context = descriptor.context
                entry.quant = descriptor.quant
                entry.sizeBytes = descriptor.sizeBytes
                entry.tags = descriptor.tags
                if entry.health == .missing {
                    entry.health = .available
                }
                merged.append(entry)
            } else {
                let entry = RelayCatalogEntry(
                    modelID: modelID,
                    originIdentifier: originID,
                    displayName: descriptor.displayName,
                    provider: descriptor.provider,
                    endpointID: descriptor.endpointID,
                    identifier: descriptor.identifier,
                    context: descriptor.context,
                    quant: descriptor.quant,
                    sizeBytes: descriptor.sizeBytes,
                    tags: descriptor.tags,
                    exposed: true
                )
                merged.append(entry)
            }
        }

        for (_, var orphan) in existing {
            orphan.health = .missing
            orphan.exposed = false
            merged.append(orphan)
        }

        merged.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        catalogEntries = merged
    }

    private func persistCatalogEntries() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(catalogEntries) {
            UserDefaults.standard.set(data, forKey: Self.catalogEntriesKey)
        }
    }

    private func persistActiveModelID() {
        let defaults = UserDefaults.standard
        if let id = activeModelID {
            defaults.set(id, forKey: Self.activeModelKey)
        } else {
            defaults.removeObject(forKey: Self.activeModelKey)
        }
    }

    private func persistEjectPreference() {
        UserDefaults.standard.set(ejectsModelOnDisconnect, forKey: Self.ejectsOnDisconnectKey)
    }

    private func hostStatusForCurrentServerState() -> RelayHostStatus {
        switch serverState {
        case .stopped:
            return .idle
        case .starting:
            return .loading
        case .running:
            return .running
        case .error:
            return .error
        }
    }

    private func scheduleCatalogUpdate(statusOverride: RelayHostStatus? = nil, changedBy: String = "mac") {
        guard hasFinishedInitialLoad else { return }
        catalogUpdateTask?.cancel()
        let status = statusOverride ?? hostStatusForCurrentServerState()

        guard let snapshot = makeCatalogSnapshot(status: status, changedBy: changedBy) else { return }

        let debounce = catalogUpdateDebounceNanoseconds
        let worker = self.worker

        catalogUpdateTask = Task(priority: .utility) { [snapshot, debounce, worker] in
            do {
                if debounce > 0 {
                    try await Task.sleep(nanoseconds: debounce)
                }
                try Task.checkCancellation()

                let result = try await worker.publishCatalog(snapshot)
                await MainActor.run { [weak self] in
                    self?.applyCatalogPublishResult(version: result.version, status: result.status)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    RelayLog.record(category: "RelayManagement",
                                    message: "Catalog publish failed: \(error.localizedDescription)",
                                    suppressConsole: true)
                }
            }
        }
    }

    private func makeCatalogSnapshot(status: RelayHostStatus, changedBy: String) -> RelayManagementWorker.CatalogPublishSnapshot? {
        let entries = catalogEntries
        let filteredEntries = entries.filter { $0.health != .error }
        let drafts = filteredEntries.map { entry in
            RelayCatalogModelDraft(
                modelID: entry.modelID,
                displayName: entry.displayName,
                provider: entry.provider,
                endpointID: entry.endpointID,
                identifier: entry.identifier,
                context: entry.context,
                quant: entry.quant,
                sizeBytes: entry.sizeBytes,
                tags: entry.tags,
                exposed: entry.exposed,
                health: entry.health,
                lastChecked: entry.lastChecked
            )
        }

        let endpoints = buildEndpointDrafts(entries: entries)
        let activeEntry = filteredEntries.first(where: { $0.modelID == activeModelID })
        let capabilities = makeCapabilities()

        if let lanSample = capabilities["lanURL"] {
            RelayLog.record(category: "RelayManagement",
                            message: "Publishing LAN metadata → lanURL=\(lanSample)",
                            style: .lanTransition)
        } else {
            RelayLog.record(category: "RelayManagement",
                            message: "Publishing LAN metadata without lanURL",
                            style: .lanTransition)
        }

        let fallbackDeviceName = String(
            localized: "This Mac",
            locale: LocalizationManager.preferredLocale()
        )
        return RelayManagementWorker.CatalogPublishSnapshot(
            status: status,
            changedBy: changedBy,
            deviceName: Host.current().localizedName ?? fallbackDeviceName,
            activeModelID: activeEntry?.modelID,
            activeContext: activeEntry?.context,
            capabilities: capabilities,
            models: drafts,
            endpoints: endpoints
        )
    }

    private func applyCatalogPublishResult(version: Int, status: RelayHostStatus) {
        lastPublishedHostStatus = status
        catalogVersion = version
        lastCatalogUpdate = Date()
    }

    private func buildEndpointDrafts(entries: [RelayCatalogEntry]) -> [RelayCatalogEndpointDraft] {
        var map: [String: (backend: RemoteBackend, exposed: Bool)] = [:]
        for descriptor in availableModels {
            guard case .remote(let backend, _) = descriptor.kind,
                  let endpointID = descriptor.endpointID else { continue }
            let isExposed = entries.contains { $0.endpointID == endpointID && $0.exposed }
            if let existing = map[endpointID] {
                map[endpointID] = (existing.backend, existing.exposed || isExposed)
            } else {
                map[endpointID] = (backend, isExposed)
            }
        }

        return map.map { endpointID, value in
            let backend = modelManager?.remoteBackend(withID: value.backend.id) ?? value.backend
            let summary = backend.lastConnectionSummary
            let endpointHealth: RelayEndpointHealth
            if let summary {
                endpointHealth = summary.kind == .success ? .up : .down
            } else {
                endpointHealth = value.exposed ? .down : .up
            }

            return RelayCatalogEndpointDraft(
                endpointID: endpointID,
                kind: endpointKind(for: backend),
                baseURL: backend.baseURLString,
                authConfigured: backend.hasAuth,
                health: endpointHealth,
                exposed: value.exposed
            )
        }
    }

    private func makeCapabilities() -> [String: String] {
        var capabilities: [String: String] = [:]
        let ramInfo = DeviceRAMInfo.current()
        capabilities["model"] = ramInfo.modelName
        capabilities["ram"] = ramInfo.ram
        capabilities["platform"] = "macOS"
        capabilities["gpu"] = DeviceGPUInfo.supportsGPUOffload ? "metal" : "cpu"
        capabilities["ejectsOnDisconnect"] = ejectsModelOnDisconnect ? "true" : "false"
        if serverConfiguration.serveOnLocalNetwork,
           let lan = lanReachableAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lan.isEmpty {
            capabilities["lanURL"] = lan
        }
        if !serverConfiguration.apiToken.isEmpty {
            capabilities["apiToken"] = serverConfiguration.apiToken
        }
        if let activeID = activeModelID,
           let descriptor = availableModels.first(where: { $0.id == activeID }) {
            capabilities["activeModel"] = descriptor.displayName
            capabilities["activeProvider"] = descriptor.provider.rawValue
        }
        return capabilities
    }

    private func recordName(for entry: RelayCatalogEntry) -> String {
        "model-\(entry.modelID)"
    }

    private func ensureEntryExposed(modelID: String) {
        guard let index = catalogEntries.firstIndex(where: { $0.modelID == modelID }) else { return }
        if catalogEntries[index].exposed { return }
        var updated = catalogEntries
        updated[index].exposed = true
        catalogEntries = updated
    }

    func setExposureForAllAvailable(_ exposed: Bool) {
        guard !availableModels.isEmpty else { return }
        let allowed = Set(availableModels.map(\.id))

        var updated = catalogEntries
        var changed = false

        for index in updated.indices {
            guard allowed.contains(updated[index].modelID) else { continue }
            if updated[index].exposed != exposed {
                updated[index].exposed = exposed
                changed = true
            }
        }

        if changed {
            catalogEntries = updated
        }
    }

    fileprivate func handle(command: RelayCommandRecord) async {
        let verb = command.verb.uppercased()
        guard verb == "POST" else {
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 400,
                                                 result: nil,
                                                 errorMessage: "Unsupported command")
            return
        }

        switch command.path {
        case "/models/activate":
            await handleActivationCommand(command)
        case "/models/deactivate":
            await handleDeactivationCommand(command)
        case "/catalog/refresh":
            await handleCatalogRefreshCommand(command)
        case "/network/refresh":
            await handleNetworkRefreshCommand(command)
        default:
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 400,
                                                 result: nil,
                                                 errorMessage: "Unsupported command")
        }
    }

    private func handleCatalogRefreshCommand(_ command: RelayCommandRecord) async {
        setStatusMessage(
            String(
                localized: "Refreshing relay catalog…",
                locale: LocalizationManager.preferredLocale()
            )
        )
        let loadingTask = beginCatalogUpdate(status: .loading)
        await loadingTask?.value

        do {
            try await refreshRelaySources()
            await Task.yield()
            let publishTask = beginCatalogUpdate(status: hostStatusForCurrentServerState())
            await publishTask?.value
            try await catalogPublisher.complete(commandID: command.recordID,
                                                state: .succeeded,
                                                statusCode: 200,
                                                result: nil,
                                                errorMessage: nil)
            hadPendingCommandWhileStopped = false
            lastActivity = Date()
            setStatusMessage(
                String(
                    localized: "Relay catalog refreshed",
                    locale: LocalizationManager.preferredLocale()
                )
            )
        } catch {
            let message: String
            if let relayError = error as? RelayError, case .notConfigured = relayError {
                message = "Relay manager is not configured. Open the Relay tab on the Mac to finish setup."
            } else {
                message = error.localizedDescription
            }
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalMessage = trimmedMessage.isEmpty ? "Unknown error." : trimmedMessage
            let revertTask = beginCatalogUpdate(status: hostStatusForCurrentServerState())
            await revertTask?.value
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 500,
                                                 result: nil,
                                                 errorMessage: finalMessage)
            hadPendingCommandWhileStopped = false
            lastActivity = Date()
            setStatusMessage(
                String.localizedStringWithFormat(
                    String(
                        localized: "Failed to refresh catalog: %@",
                        locale: LocalizationManager.preferredLocale()
                    ),
                    finalMessage
                )
            )
            RelayLog.record(category: "RelayManagement",
                            message: "CloudKit: catalog refresh failed (\(finalMessage))",
                            suppressConsole: true)
        }
    }

    private func handleNetworkRefreshCommand(_ command: RelayCommandRecord) async {
        RelayLog.record(category: "RelayManagement",
                        message: "Processing LAN refresh request from iOS…",
                        style: .lanTransition)
        let originalStatus = statusMessage
        setStatusMessage(
            String(
                localized: "Updating LAN status…",
                locale: LocalizationManager.preferredLocale()
            )
        )
        await refreshHTTPServerState()
        ensureLANReachableAddressFallback()
        refreshPayload()
        let status = hostStatusForCurrentServerState()
        let lanSummary = "serveOnLAN=\(serverConfiguration.serveOnLocalNetwork) lanAddress=\(lanReachableAddress ?? lastKnownLANAddress ?? "nil") status=\(status)"
        RelayLog.record(category: "RelayManagement",
                        message: "LAN status payload prepared → \(lanSummary)",
                        style: .lanTransition)
        // Publish synchronously so Device.capabilities (lanURL) are persisted
        // before iOS fetches the snapshot.
        if let snapshot = makeCatalogSnapshot(status: status, changedBy: "ios") {
            do {
                let result = try await worker.publishCatalog(snapshot)
                applyCatalogPublishResult(version: result.version, status: result.status)
            } catch {
                RelayLog.record(category: "RelayManagement",
                                message: "LAN status publish failed: \(error.localizedDescription)",
                                style: .lanTransition)
            }
        }
        let lanURLRaw = lanReachableAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lanURLClean = (lanURLRaw?.hasSuffix(":0") == true) ? nil : lanURLRaw
        let interface: RelayLANInterface? = lanURLClean?.isEmpty == false ? .ethernet : nil
        let payload = RelayLANStatusPayload(
            lanURL: lanURLClean?.isEmpty == false ? lanURLClean : nil,
            wifiSSID: nil,
            serveOnLAN: serverConfiguration.serveOnLocalNetwork,
            hostStatus: status,
            updatedAt: Date(),
            interface: interface
        )
        let payloadData: Data?
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            payloadData = try encoder.encode(payload)
            RelayLog.record(category: "RelayManagement",
                            message: "LAN payload encoded → lanURL=\(payload.lanURL ?? "nil") serveOnLAN=\(payload.serveOnLAN)",
                            style: .lanTransition)
        } catch {
            RelayLog.record(category: "RelayManagement",
                            message: "Failed to encode LAN payload: \(error.localizedDescription)",
                            style: .lanTransition)
            payloadData = nil
        }
        do {
            try await catalogPublisher.complete(commandID: command.recordID,
                                                state: .succeeded,
                                                statusCode: 200,
                                                result: payloadData,
                                                errorMessage: nil)
            lastActivity = Date()
            setStatusMessage(originalStatus)
            RelayLog.record(category: "RelayManagement",
                            message: "LAN status shared with iOS",
                            style: .lanTransition)
        } catch {
            setStatusMessage(
                String(
                    localized: "Failed to update LAN status",
                    locale: LocalizationManager.preferredLocale()
                )
            )
            RelayLog.record(category: "RelayManagement",
                            message: "LAN refresh command failed: \(error.localizedDescription)",
                            style: .lanTransition)
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 500,
                                                 result: nil,
                                                 errorMessage: error.localizedDescription)
        }
    }

    private func ensureLANReachableAddressFallback() {
        guard serverConfiguration.serveOnLocalNetwork else { return }
        if let current = lanReachableAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty,
           !current.hasSuffix(":0") { return }
        if lanReachableAddress?.hasSuffix(":0") == true {
            lanReachableAddress = nil
        }
        let configuredPort = serverConfiguration.port == 0 ? 12345 : serverConfiguration.port
        let port = httpServerState?.port.flatMap { $0 == 0 ? nil : $0 } ?? configuredPort
        guard port != 0 else { return }
        let fallback = RelayHTTPServer.primaryLANAddress(bindHost: serverConfiguration.bindHost, port: port)
        if let fallback {
            lanReachableAddress = fallback
            lastKnownLANAddress = fallback
            RelayLog.record(category: "RelayManagement",
                            message: "LAN fallback address resolved ⇒ \(fallback)",
                            style: .lanTransition)
        } else {
            RelayLog.record(category: "RelayManagement",
                            message: "LAN fallback probe returned no address (port \(port)).",
                            style: .lanTransition)
        }
    }

    private func beginCatalogUpdate(status: RelayHostStatus) -> Task<Void, Never>? {
        scheduleCatalogUpdate(statusOverride: status, changedBy: "ios")
        return catalogUpdateTask
    }

    // Remote model fetch runs off the main actor; only the manager mutation is on main.
    nonisolated private func refreshRelaySources() async throws {
        let manager: AppModelManager? = await MainActor.run { self.modelManager }
        guard let manager else {
            throw RelayError.notConfigured
        }
        
        // Identify targets
        let targets: [RemoteBackend] = await MainActor.run {
            manager.remoteBackends.filter { !$0.endpointType.isRelay }
        }
        guard !targets.isEmpty else { return }
        
        // Fetch in parallel (detached)
        let results = await fetchAllRemoteModels(backends: targets)
        
        // Update manager on main actor
        await MainActor.run {
            for (backendID, result) in results {
                switch result {
                case .success(let fetchResult):
                    manager.updateRemoteBackend(
                        backendID: backendID,
                        with: fetchResult.models,
                        error: nil,
                        summary: .success(statusCode: fetchResult.statusCode, reason: fetchResult.reason),
                        relayEjectsOnDisconnect: fetchResult.relayEjectsOnDisconnect,
                        relayHostStatus: fetchResult.relayHostStatus,
                        relayLANURL: .some(fetchResult.relayLANURL),
                        relayWiFiSSID: .some(fetchResult.relayWiFiSSID),
                        relayAPIToken: .some(fetchResult.relayAPIToken),
                        relayLANInterface: .some(fetchResult.relayLANInterface)
                    )
                case .failure(let error):
                    let summary = RemoteBackend.ConnectionSummary.failure(message: error.localizedDescription)
                    manager.updateRemoteBackend(
                        backendID: backendID,
                        with: nil,
                        error: error.localizedDescription,
                        summary: summary
                    )
                }
            }
        }
    }

    private func handleActivationCommand(_ command: RelayCommandRecord) async {
        guard let body = command.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let modelRef = json["modelRef"] as? String else {
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 422,
                                                 result: nil,
                                                 errorMessage: "Missing model reference")
            return
        }

        let normalizedID = modelRef.hasPrefix("model-") ? String(modelRef.dropFirst("model-".count)) : modelRef

        guard let entry = catalogEntries.first(where: { $0.modelID == normalizedID || recordName(for: $0) == modelRef }) else {
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 404,
                                                 result: nil,
                                                 errorMessage: "Model not found")
            return
        }

        RelayLog.record(category: "RelayManagement",
                        message: "CloudKit: iOS requested activation of \(entry.displayName)",
                        suppressConsole: true)
        await MainActor.run {
            let locale = LocalizationManager.preferredLocale()
            setStatusMessage(
                String.localizedStringWithFormat(
                    String(localized: "Activating %@…", locale: locale),
                    entry.displayName
                )
            )
            ensureEntryExposed(modelID: entry.modelID)
            if activeModelID != entry.modelID {
                activeModelID = entry.modelID
            }
        }

        scheduleCatalogUpdate(statusOverride: .loading, changedBy: "ios")

        do {
            _ = try await catalogPublisher.updateHostState(status: .loading,
                                                           activeModelID: entry.modelID,
                                                           tokensPerSecond: nil,
                                                           context: entry.context,
                                                           changedBy: "ios")
            scheduleCatalogUpdate(statusOverride: .running, changedBy: "ios")
            try await catalogPublisher.complete(commandID: command.recordID,
                                                state: .succeeded,
                                                statusCode: 200,
                                                result: nil,
                                                errorMessage: nil)
            await MainActor.run {
                hadPendingCommandWhileStopped = false
                let locale = LocalizationManager.preferredLocale()
                setStatusMessage(
                    String.localizedStringWithFormat(
                        String(localized: "Relay switched to %@", locale: locale),
                        entry.displayName
                    )
                )
                lastActivity = Date()
            }
            RelayLog.record(category: "RelayManagement",
                            message: "CloudKit: activation for \(entry.displayName) completed",
                            suppressConsole: true)
        } catch {
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 500,
                                                 result: nil,
                                                 errorMessage: error.localizedDescription)
            await MainActor.run {
                hadPendingCommandWhileStopped = false
                let locale = LocalizationManager.preferredLocale()
                setStatusMessage(
                    String.localizedStringWithFormat(
                        String(localized: "Failed to activate %@", locale: locale),
                        entry.displayName
                    )
                )
            }
            RelayLog.record(category: "RelayManagement",
                            message: "CloudKit: activation for \(entry.displayName) failed: \(error.localizedDescription)",
                            suppressConsole: true)
        }
    }

    private func handleDeactivationCommand(_ command: RelayCommandRecord) async {
        guard let body = command.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let modelRef = json["modelRef"] as? String else {
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 422,
                                                 result: nil,
                                                 errorMessage: "Missing model reference")
            return
        }

        let normalizedID = modelRef.hasPrefix("model-") ? String(modelRef.dropFirst("model-".count)) : modelRef
        let ensure = (json["ensure"] as? String)?.lowercased()
        let shouldUnload = ensure == nil || ensure == "unloaded"

        guard let entry = catalogEntries.first(where: { $0.modelID == normalizedID || recordName(for: $0) == modelRef }) else {
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 404,
                                                 result: nil,
                                                 errorMessage: "Model not found")
            return
        }

        scheduleCatalogUpdate(statusOverride: .idle, changedBy: "ios")
        do {
            _ = try await catalogPublisher.updateHostState(status: .idle,
                                                           activeModelID: nil,
                                                           tokensPerSecond: nil,
                                                           context: nil,
                                                           changedBy: "ios")
            if shouldUnload {
                await serverEngine.unloadModel(entry.modelID, reason: "deactivate command")
                await refreshLoadedModelsSnapshot()
            }
            try await catalogPublisher.complete(commandID: command.recordID,
                                                state: .succeeded,
                                                statusCode: 200,
                                                result: nil,
                                                errorMessage: nil)
            await MainActor.run {
                hadPendingCommandWhileStopped = false
                activeModelID = nil
                let locale = LocalizationManager.preferredLocale()
                setStatusMessage(
                    String.localizedStringWithFormat(
                        String(localized: "Relay idle after ejecting %@", locale: locale),
                        entry.displayName
                    )
                )
                lastActivity = Date()
            }
        } catch {
            try? await catalogPublisher.complete(commandID: command.recordID,
                                                 state: .failed,
                                                 statusCode: 500,
                                                 result: nil,
                                                 errorMessage: error.localizedDescription)
            await MainActor.run {
                let locale = LocalizationManager.preferredLocale()
                setStatusMessage(
                    String.localizedStringWithFormat(
                        String(localized: "Failed to eject %@", locale: locale),
                        entry.displayName
                    )
                )
            }
        }
    }

    func start() {
        guard serverState != .starting,
              serverState != .running,
              startupTask == nil,
              serverTask == nil else { return }
        startLoadedModelsMonitor()
        let runID = beginLifecycleRun()
        setStatusMessage(
            String(
                localized: "Starting relay…",
                locale: LocalizationManager.preferredLocale()
            )
        )
        withAnimation(statusAnimation) {
            serverState = .starting
        }
        isLANServerStarting = true

        startupTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentRun(runID) else { return }
                    self.startupTask = nil
                }
            }
            await self.performStartSequence(for: runID)
        }
    }

    // Runs the relay start-up away from the main actor; UI updates are bridged via MainActor.run.
    private func performStartSequence(for runID: UUID) async {
        await dependencies.ensureLocalNetworkPermission()
        guard !Task.isCancelled else { return }
        let isCurrent = await MainActor.run { self.isCurrentRun(runID) }
        guard isCurrent else { return }

        let configuration = await MainActor.run { self.serverConfiguration }
        let engine = await MainActor.run { self.serverEngine }
        var server = await MainActor.run { self.httpServer }
        if server == nil {
            server = dependencies.makeHTTPServer(engine, configuration)
        }

        await MainActor.run {
            guard self.isCurrentRun(runID) else { return }
            self.httpServer = server
            self.isLANServerStarting = true
        }

        do {
            try await server?.start()
            await refreshHTTPServerState(for: runID)
            guard !Task.isCancelled else { return }
            let isStillCurrent = await MainActor.run { self.isCurrentRun(runID) }
            guard isStillCurrent else { return }
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.isLANServerStarting = false
                self.relayIdentifier = UUID()
                self.refreshPayload()
                self.setStatusMessage(
                    String(
                        localized: "Listening for conversations… Checking sources…",
                        locale: LocalizationManager.preferredLocale()
                    )
                )
                withAnimation(self.statusAnimation) {
                    self.serverState = .running
                }
                self.lastActivity = Date()
                self.scheduleCatalogUpdate(statusOverride: .running)
            }
        } catch {
            await MainActor.run {
                guard self.isCurrentRun(runID) else { return }
                self.isLANServerStarting = false
                self.httpServer = nil
                self.serverState = .error("LAN server failed: \(error.localizedDescription)")
                self.setStatusMessage(
                    String(
                        localized: "Failed to start LAN server",
                        locale: LocalizationManager.preferredLocale()
                    )
                )
            }
            return
        }

        await refreshConnectedClientsSnapshot(for: runID)
        let isStillCurrent = await MainActor.run { self.isCurrentRun(runID) }
        guard isStillCurrent else { return }

        let loopTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let active = await MainActor.run { self.activeModelID }
            await self.serverEngine.updateActiveModel(active)
            await self.runRelayLoopDetached(for: runID)
        }
        await MainActor.run {
            guard self.isCurrentRun(runID) else {
                loopTask.cancel()
                return
            }
            self.serverTask = loopTask
        }

        await MainActor.run {
            guard self.isCurrentRun(runID) else { return }
            self.launchStartupWarmup(for: runID)
        }
    }

    // Collects remote health on a background executor; only state mutations run on the main actor.
    nonisolated func checkExposedEndpointsHealth(for runID: UUID? = nil) async -> RelayWarmupHealth {
        let manager: AppModelManager? = await MainActor.run { self.modelManager }
        guard let manager else {
            return .empty
        }

        let descriptors: [RelayModelDescriptor] = await MainActor.run { self.availableModels }
        var backendIDs: Set<RemoteBackend.ID> = []
        for descriptor in descriptors {
            if case .remote(let backend, _) = descriptor.kind {
                backendIDs.insert(backend.id)
            }
        }

        guard !backendIDs.isEmpty else { return .empty }

        let backendsToCheck: [RemoteBackend] = await MainActor.run {
            manager.remoteBackends.filter { backendIDs.contains($0.id) }
        }
        let results = await fetchAllRemoteModels(backends: backendsToCheck)

        // Apply backend updates on the main actor to keep state in sync with the UI.
        await MainActor.run {
            guard runID == nil || self.isCurrentRun(runID!) else { return }
            for (backendID, result) in results {
                switch result {
                case .success(let fetchResult):
                    manager.updateRemoteBackend(
                        backendID: backendID,
                        with: fetchResult.models,
                        error: nil,
                        summary: .success(statusCode: fetchResult.statusCode, reason: fetchResult.reason),
                        relayEjectsOnDisconnect: fetchResult.relayEjectsOnDisconnect,
                        relayHostStatus: fetchResult.relayHostStatus,
                        relayLANURL: .some(fetchResult.relayLANURL),
                        relayWiFiSSID: .some(fetchResult.relayWiFiSSID),
                        relayAPIToken: .some(fetchResult.relayAPIToken),
                        relayLANInterface: .some(fetchResult.relayLANInterface)
                    )
                case .failure(let error):
                    let summary = RemoteBackend.ConnectionSummary.failure(message: error.localizedDescription)
                    manager.updateRemoteBackend(
                        backendID: backendID,
                        with: nil,
                        error: error.localizedDescription,
                        summary: summary
                    )
                }
            }
        }

        return await MainActor.run {
            guard runID == nil || self.isCurrentRun(runID!) else {
                return .empty
            }
            var offlineBackends: [RemoteBackend.ID: Bool] = [:]
            var offlineNames: [String] = []
            var offlineModelIDs: Set<String> = []

            for backendID in backendIDs {
                guard let refreshed = manager.remoteBackend(withID: backendID) else {
                    offlineBackends[backendID] = true
                    continue
                }
                let isOffline = refreshed.lastConnectionSummary.map { $0.kind != .success } ?? true
                offlineBackends[backendID] = isOffline
                if isOffline && !offlineNames.contains(refreshed.name) {
                    offlineNames.append(refreshed.name)
                }
            }

            let now = Date()
            var updatedEntries = self.catalogEntries
            for index in updatedEntries.indices {
                guard let descriptor = descriptors.first(where: { $0.id == updatedEntries[index].modelID }) else { continue }
                guard case .remote(let backend, _) = descriptor.kind else { continue }
                let isOffline = offlineBackends[backend.id] ?? false
                updatedEntries[index].health = isOffline ? .error : .available
                updatedEntries[index].lastChecked = now
                if isOffline {
                    offlineModelIDs.insert(updatedEntries[index].modelID)
                }
            }
            self.catalogEntries = updatedEntries

            offlineNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            for descriptor in descriptors {
                guard case .remote(let backend, _) = descriptor.kind else { continue }
                if offlineBackends[backend.id] ?? false {
                    offlineModelIDs.insert(descriptor.id)
                }
            }

            return RelayWarmupHealth(names: offlineNames, offlineModelIDs: offlineModelIDs)
        }
    }
    
    nonisolated private func fetchAllRemoteModels(backends: [RemoteBackend]) async -> [RemoteBackend.ID: Result<RemoteBackendAPI.FetchModelsResult, Error>] {
        await withTaskGroup(of: (RemoteBackend.ID, Result<RemoteBackendAPI.FetchModelsResult, Error>).self) { group in
            for backend in backends {
                group.addTask {
                    do {
                        let result = try await RemoteBackendAPI.fetchModels(for: backend)
                        return (backend.id, .success(result))
                    } catch {
                        return (backend.id, .failure(error))
                    }
                }
            }
            
            var results: [RemoteBackend.ID: Result<RemoteBackendAPI.FetchModelsResult, Error>] = [:]
            for await (id, result) in group {
                results[id] = result
            }
            return results
        }
    }

    private func ensureActiveModelAvailable(excluding offlineModelIDs: Set<String>) {
        if let activeID = activeModelID, !offlineModelIDs.contains(activeID) {
            return
        }

        if let nextExposed = catalogEntries.first(where: { $0.exposed && !offlineModelIDs.contains($0.modelID) }) {
            activeModelID = nextExposed.modelID
            return
        }

        if let nextAvailable = availableModels.first(where: { !offlineModelIDs.contains($0.id) }) {
            activeModelID = nextAvailable.id
        } else {
            activeModelID = nil
        }
    }

    func stop() {
        activeRunID = UUID()
        startupTask?.cancel()
        startupWarmupTask?.cancel()
        serverTask?.cancel()
        startupTask = nil
        startupWarmupTask = nil
        serverTask = nil
        let httpServer = httpServer
        self.httpServer = nil
        httpServerState = nil
        lanReachableAddress = nil
        lastKnownLANAddress = nil
        isLANServerStarting = false
        payload = nil
        advertiser.stopAdvertising()
        stopLoadedModelsMonitor()
        dependencies.stopCloudKitProcessing()
        withAnimation(statusAnimation) {
            serverState = .stopped
        }
        hadPendingCommandWhileStopped = false
        setStatusMessage(
            String(
                localized: "Relay stopped",
                locale: LocalizationManager.preferredLocale()
            )
        )
        relaySnapshots = []
        recomputeLoadedModels()
        connectedClients = []
        scheduleCatalogUpdate(statusOverride: .idle)
        if let httpServer {
            Task { await httpServer.stop() }
        }
        Task { await serverEngine.unloadAllClients() }
    }

    func restartRelay() {
        stop()
        start()
    }

    private func refreshPayload() {
        let title = catalogEntries.first(where: { $0.modelID == activeModelID })?.displayName ?? "No model selected"
        if let current = lanReachableAddress, !current.isEmpty {
            lastKnownLANAddress = current
        }
        var lanCandidate = serverConfiguration.serveOnLocalNetwork ? (lanReachableAddress ?? lastKnownLANAddress) : nil
        if let candidate = lanCandidate, candidate.hasSuffix(":0") {
            lanCandidate = nil
        }
        let fallbackDeviceName = String(
            localized: "This Mac",
            locale: LocalizationManager.preferredLocale()
        )
        let payload = RelayBluetoothPayload(
            id: relayIdentifier,
            containerID: RelayConfiguration.containerIdentifier,
            deviceName: Host.current().localizedName ?? fallbackDeviceName,
            provider: title,
            hostDeviceID: hostDeviceID,
            lanURL: lanCandidate,
            apiToken: serverConfiguration.apiToken,
            wifiSSID: nil,
            updatedAt: Date()
        )
        if payload != self.payload,
           let lanURL = lanCandidate {
            RelayLog.record(category: "RelayServer",
                            message: "LAN ready ⇒ \(lanURL)",
                            style: .lanTransition)
        }
        if serverState == .running || serverState == .starting {
            advertiser.startAdvertising(payload: payload)
        } else {
            advertiser.stopAdvertising()
        }
        self.payload = payload
    }

    /// Sync loaded model snapshots from server engine on-demand.
    nonisolated func refreshLoadedModelsSnapshot() async {
        let snapshots = await serverEngine.modelSnapshots()
        await MainActor.run {
            self.relaySnapshots = snapshots
            self.recomputeLoadedModels()
        }
    }

    private func startLoadedModelsMonitor() {
        loadedModelsMonitorTask?.cancel()
        loadedModelsMonitorTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var lastSignature: [String]? = nil
            while !Task.isCancelled {
                let snapshots = await self.serverEngine.modelSnapshots()
                // Only hop to the main actor (and invalidate SwiftUI) when
                // something the UI cares about actually changed. Otherwise this
                // 1 Hz poll re-rendered the whole Relay view every second.
                let signature = snapshots.map {
                    "\($0.id)|\($0.isLoaded)|\($0.contextLength ?? -1)|\($0.displayName)"
                }
                if signature != lastSignature {
                    lastSignature = signature
                    await MainActor.run {
                        self.relaySnapshots = snapshots
                        self.recomputeLoadedModels()
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s poll
            }
        }
    }

    private func stopLoadedModelsMonitor() {
        loadedModelsMonitorTask?.cancel()
        loadedModelsMonitorTask = nil
    }

    nonisolated func refreshConnectedClientsSnapshot(for runID: UUID? = nil) async {
        let snapshot = await serverEngine.connectedClientsSnapshot()
        await MainActor.run {
            guard runID == nil || self.isCurrentRun(runID!) else { return }
            self.connectedClients = snapshot
        }
    }

    private func launchStartupWarmup(for runID: UUID) {
        startupWarmupTask?.cancel()
        startupWarmupTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentRun(runID) else { return }
                    self.startupWarmupTask = nil
                }
            }

            do {
                let health = try await self.dependencies.performHealthCheck(self, runID)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.isCurrentRun(runID) else { return }
                    self.ensureActiveModelAvailable(excluding: health.offlineModelIDs)
                    if health.names.isEmpty {
                        self.setStatusMessage(
                            String(
                                localized: "Listening for conversations…",
                                locale: LocalizationManager.preferredLocale()
                            )
                        )
                    } else {
                        let list = health.names.joined(separator: ", ")
                        self.setStatusMessage(
                            String.localizedStringWithFormat(
                                String(
                                    localized: "Listening for conversations… Offline: %@",
                                    locale: LocalizationManager.preferredLocale()
                                ),
                                list
                            )
                        )
                    }
                }
            } catch is CancellationError {
                RelayLog.record(category: "RelayManagement",
                                message: "Relay warmup cancelled",
                                suppressConsole: true)
            } catch {
                RelayLog.record(category: "RelayManagement",
                                message: "Relay warmup failed: \(error.localizedDescription)",
                                suppressConsole: true)
                await MainActor.run {
                    guard self.isCurrentRun(runID), self.serverState == .running else { return }
                    self.setStatusMessage(
                        String(
                            localized: "Listening for conversations…",
                            locale: LocalizationManager.preferredLocale()
                        )
                    )
                }
            }
        }
    }

    private func runRelayLoopDetached(for runID: UUID) async {
        let inferenceProvider = await MainActor.run { makeProvider() }
        guard !Task.isCancelled else { return }
        let isStillCurrent = await MainActor.run { self.isCurrentRun(runID) }
        guard isStillCurrent else { return }
        await dependencies.startCloudKitProcessing(inferenceProvider)

        // Keep the task alive with a very light heartbeat so cancellation works.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000) // 5-minute heartbeat
        }
    }

    fileprivate func setStatusMessage(_ message: String) {
        withAnimation(statusAnimation) {
            statusMessage = message
        }
        RelayLog.record(category: "RelayManagement", message: message, suppressConsole: true)
    }

    private func makeProvider() -> InferenceProvider {
        RelayDynamicProvider(service: serverEngine)
    }
}

// MARK: - Background CloudKit command loop (macOS relay)

private func relayCommandLoop(viewModel: RelayManagementViewModel,
                              hostDeviceID: String,
                              catalogPublisher: RelayCatalogPublisher) async {
    while !Task.isCancelled {
        do {
            // Fetch queued CloudKit commands on a background executor.
            let commands = try await catalogPublisher.fetchQueuedCommands(limit: 10)
            if commands.isEmpty {
                await MainActor.run {
                    if viewModel.hadPendingCommandWhileStopped && viewModel.serverState == .stopped {
                        viewModel.hadPendingCommandWhileStopped = false
                        viewModel.setStatusMessage(
                            String(
                                localized: "Relay stopped",
                                locale: LocalizationManager.preferredLocale()
                            )
                        )
                    }
                }
            } else {
                RelayLog.record(category: "RelayManagement",
                                message: "CloudKit: received \(commands.count) queued command(s) from iOS",
                                suppressConsole: true)
                let shouldProcess: Bool = await MainActor.run {
                    if viewModel.serverState == .stopped && !viewModel.hadPendingCommandWhileStopped {
                        viewModel.hadPendingCommandWhileStopped = true
                        viewModel.setStatusMessage(
                            String(
                                localized: "iOS requested a relay switch. Start the relay to respond.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        )
                    }
                    return viewModel.serverState == .running || viewModel.serverState == .starting
                }
                guard shouldProcess else {
                    // Back off when not running.
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                    continue
                }
                for command in commands {
                    if Task.isCancelled { return }
                    if let claimed = try await catalogPublisher.claim(command: command, leaseOwner: hostDeviceID) {
                        RelayLog.record(category: "RelayManagement",
                                        message: "CloudKit: claimed command \(command.recordID.recordName) path=\(command.path)",
                                        suppressConsole: true)
                        // Hand the claimed command back to the main-actor view model
                        // to update UI and trigger any follow-up work.
                        await MainActor.run {
                            Task { await viewModel.handle(command: claimed) }
                        }
                    }
                }
            }
        } catch {
            // Ignore transient CloudKit errors and retry.
        }
        let delay: UInt64 = await MainActor.run {
            (viewModel.serverState == .running || viewModel.serverState == .starting)
            ? 1_000_000_000
            : 5_000_000_000
        }
        try? await Task.sleep(nanoseconds: delay)
    }
}

private struct RelayDynamicProvider: InferenceProvider {
    let service: RelayServerEngine

    func generateReply(for envelope: RelayEnvelope) async throws -> String {
        try await service.generateReply(for: envelope)
    }

    func generateReplyStreaming(
        for envelope: RelayEnvelope,
        onPartial: @Sendable @escaping (String) async -> Void
    ) async throws -> String {
        try await service.streamReply(for: envelope) { partial in
            Task { await onPartial(partial) }
        }
    }
}

@MainActor
struct RelayManagementView: View {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var walkthrough: GuidedWalkthroughManager
    @ObservedObject private var viewModel = RelayManagementViewModel.shared
    @State private var portText = ""
    @State private var idleTTLText = ""
    @State private var serverSettingsExpanded = true
    @State private var settingsSheetContext: LoadedModelContext?
    // Removed Cloud Relay worker/log overrides to simplify settings.

    var body: some View {
        VStack(spacing: 0) {
            RelayChromeBar(
                state: viewModel.serverState,
                statusMessage: viewModel.statusMessage,
                onRestart: { viewModel.restartRelay() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    industrialPane { serverOverviewSection }
                    industrialPane { connectionsAndModelsSection }
                    settingsAndBluetoothRow
                    industrialPane { sourcesSection }
                    industrialPane { cloudKitSection }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(AppTheme.windowBackground.ignoresSafeArea())
        .task { viewModel.bind(modelManager: modelManager, chatVM: chatVM) }
        .task { await viewModel.refreshConnectedClientsSnapshot() }
        .onAppear { syncConfigurationFields() }
        .onChange(of: viewModel.serverState) { _ in
            Task { await viewModel.refreshConnectedClientsSnapshot() }
        }
        .onChange(of: viewModel.serverConfiguration) { _ in syncConfigurationFields() }
        .sheet(item: $settingsSheetContext) { context in
            ModelSettingsView(model: context.model) { settings in
                Task {
                    await viewModel.applySettings(settings, forRelayModelID: context.descriptorID)
                }
            }
            .environmentObject(modelManager)
            .environmentObject(chatVM)
            .environmentObject(walkthrough)
        }
    }

    private var isRelayConsoleActive: Bool {
        switch viewModel.serverState {
        case .starting, .running:
            return true
        case .stopped, .error:
            return false
        }
    }

    @ViewBuilder
    private func industrialPane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.secondary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
    }

    // Place Server Settings and Bluetooth panels side-by-side on wide screens
    private var settingsAndBluetoothRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                industrialPane { serverSettingsSection }
                    .frame(maxWidth: .infinity, alignment: .leading)
                industrialPane { bluetoothSection }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                industrialPane { serverSettingsSection }
                industrialPane { bluetoothSection }
            }
        }
    }

    private var serverOverviewSection: some View {
        let ramInfo = DeviceRAMInfo.current()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                serverOverviewPrimary
                    .frame(maxWidth: .infinity, alignment: .leading)
                RelayRAMUsageView(info: ramInfo)
                    .frame(width: 230)
            }
            VStack(alignment: .leading, spacing: 20) {
                serverOverviewPrimary
                RelayRAMUsageView(info: ramInfo)
            }
        }
    }

    private var serverOverviewPrimary: some View {
        VStack(alignment: .leading, spacing: 20) {
            serverOverviewHeader
            serverOverviewDetails
        }
    }

    private var serverOverviewHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            RelayGlyph()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("NOEMA SERVER"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.text)
                Text(viewModel.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText)
                if viewModel.isLANServerStarting {
                    Label(LocalizedStringKey("Bringing LAN server online…"), systemImage: "clock.arrow.2.circlepath")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppTheme.tertiaryText)
                } else if let activity = viewModel.lastActivity {
                    Label(String.localizedStringWithFormat(String(localized: "Last activity %@"), activity.formatted(date: .numeric, time: .shortened)), systemImage: "clock.arrow.circlepath")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppTheme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
            Toggle(isOn: serverRunningBinding) {
                Text(viewModel.serverState == .running ? String(localized: "RUNNING") : String(localized: "STOPPED"))
                    .font(.system(.caption, design: .monospaced, weight: .bold))
            }
            .toggleStyle(ModernToggleStyle())
            .disabled(viewModel.serverState == .starting || viewModel.isLANServerStarting)
        }
    }

    private var serverOverviewDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey("IP"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(lanAddressDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Button {
                    copyToPasteboard(lanAddressDisplay)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy local URL"))
                .disabled(viewModel.lanReachableAddress == nil)
            }
            
            Divider()
                .padding(.vertical, 2)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("CONNECTION MODES"))
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(AppTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(LocalizedStringKey("CloudKit Relay"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppTheme.text)
                        } icon: {
                            Image(systemName: "icloud")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                        Label {
                            Text(LocalizedStringKey("Local LAN (OpenAI)"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppTheme.text)
                        } icon: {
                            Image(systemName: "wifi.router")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("ENDPOINTS"))
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(AppTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(LocalizedStringKey("v1/chat, v1/models"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppTheme.text)
                        } icon: {
                            Image(systemName: "chevron.left.slash.chevron.right")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }

    private var connectionsAndModelsSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                connectedDevicesSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                loadedModelsSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(spacing: 24) {
                connectedDevicesSection
                loadedModelsSection
            }
        }
    }

    private var connectedDevicesSection: some View {
        MacSection(LocalizedStringKey("Last Seen Devices")) {
            if viewModel.connectedClients.isEmpty {
                Text(LocalizedStringKey("No recent devices. We'll list clients the next time they talk to this relay."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(viewModel.connectedClients.enumerated()), id: \.element.id) { index, client in
                        connectedDeviceRow(for: client)
                        if index < viewModel.connectedClients.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var loadedModelsSection: some View {
        MacSection(LocalizedStringKey("Loaded Models")) {
            let loaded = viewModel.loadedModels.filter { $0.isLoaded }
            if loaded.isEmpty {
                Text(LocalizedStringKey("No models loaded right now. We'll spin one up when a request arrives."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(loaded, id: \.descriptor.id) { snapshot in
                        loadedModelRow(for: snapshot)
                        if snapshot.descriptor.id != loaded.last?.descriptor.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private struct LoadedModelContext: Identifiable, Equatable {
        let descriptorID: String
        let model: LocalModel

        var id: String { descriptorID }
    }

    private struct MacSection<Content: View>: View {
        let title: LocalizedStringKey
        let content: Content

        init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.bold)
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.secondaryText)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func connectedDeviceRow(for client: RelayServerEngine.ConnectedClient) -> some View {
        let descriptor = connectedDeviceDescriptor(for: client)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: descriptor.icon)
                .font(.caption)
                .foregroundStyle(descriptor.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(AppTheme.text)
                if let detail = descriptor.detail {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Text(descriptor.lastSeen)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
        }
    }

    private func connectedDeviceDescriptor(for client: RelayServerEngine.ConnectedClient) -> (title: String, detail: String?, lastSeen: String, icon: String, tint: Color) {
        let title = client.name.isEmpty ? client.clientIdentifier : client.name
        let transportLabel: String
        let icon: String
        let tint: Color
        let locale = LocalizationManager.preferredLocale()
        switch client.transport {
        case .lan:
            if let ssid = client.ssid, !ssid.isEmpty {
                transportLabel = String.localizedStringWithFormat(
                    String(localized: "LAN · %@", locale: locale),
                    ssid
                )
            } else {
                transportLabel = String(localized: "LAN", locale: locale)
            }
            icon = "wifi.router"
            tint = .green
        case .cloud:
            transportLabel = String(localized: "Cloud Relay", locale: locale)
            icon = "icloud"
            tint = .teal
        }

        var detailParts: [String] = [transportLabel]
        if client.transport == .lan, let address = client.address, !address.isEmpty {
            detailParts.append(address)
        }
        if client.transport == .cloud, let ssid = client.ssid, !ssid.isEmpty {
            detailParts.append(
                String.localizedStringWithFormat(
                    String(localized: "Client Wi-Fi: %@", locale: locale),
                    ssid
                )
            )
        }
        if let platform = client.platform, !platform.isEmpty {
            detailParts.append(platform)
        } else if let model = client.model, !model.isEmpty {
            detailParts.append(model)
        }
        let detail = detailParts.isEmpty ? nil : detailParts.joined(separator: " • ")
        let lastSeen = String.localizedStringWithFormat(
            String(localized: "Last seen %@", locale: locale),
            Self.relativeFormatter.localizedString(for: client.lastSeen, relativeTo: Date())
        )
        return (title, detail, lastSeen, icon, tint)
    }

    @ViewBuilder
    private func loadedModelRow(for snapshot: RelayServerEngine.ModelSnapshot) -> some View {
        let isActive = viewModel.activeModelID == snapshot.descriptor.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.displayName)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(AppTheme.text)
                if isActive {
                    Text(LocalizedStringKey("ACTIVE"))
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                if case .local = snapshot.descriptor.kind {
                    HStack(spacing: 8) {
                        Button(String(localized: "Settings")) { presentModelSettings(for: snapshot) }
                            .buttonStyle(GlassButtonStyle())
                            .controlSize(.small)
                        Button(String(localized: "Unload")) { viewModel.unloadModel(snapshot.descriptor.id) }
                            .buttonStyle(GlassButtonStyle())
                            .controlSize(.small)
                    }
                }
            }
            HStack(spacing: 8) {
                metadataLabel(snapshot.provider.displayName, systemImage: "antenna.radiowaves.left.and.right")
                if let quant = snapshot.quant, !quant.isEmpty {
                    metadataLabel(quant, systemImage: "cube")
                }
                if let context = snapshot.contextLength {
                    metadataLabel(String.localizedStringWithFormat(String(localized: "%d ctx"), context), systemImage: "text.alignleft")
                }
                if let size = snapshot.sizeBytes {
                    metadataLabel(ByteCountFormatter.string(fromByteCount: size, countStyle: .memory), systemImage: "externaldrive")
                }
                Spacer(minLength: 0)
                Text(String.localizedStringWithFormat(String(localized: "Refreshed %@"), Self.relativeFormatter.localizedString(for: snapshot.created, relativeTo: Date())))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(AppTheme.tertiaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func metadataLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
    }

    private func presentModelSettings(for snapshot: RelayServerEngine.ModelSnapshot) {
        guard case .local(let model) = snapshot.descriptor.kind else { return }
        settingsSheetContext = LoadedModelContext(descriptorID: snapshot.descriptor.id, model: model)
    }

    private var serverSettingsSection: some View {
        let config = viewModel.serverConfiguration
        return DisclosureGroup(isExpanded: $serverSettingsExpanded) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    settingsLabel(LocalizedStringKey("PORT"))
                    HStack(spacing: 8) {
                        TextField(String(localized: "Port"), text: $portText)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .onSubmit { applyPortText() }
                        Button(String(localized: "Apply")) { applyPortText() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }

                GridRow {
                    settingsLabel(LocalizedStringKey("LAN SERVE"))
                    Toggle("", isOn: Binding(
                        get: { config.serveOnLocalNetwork },
                        set: { viewModel.toggleServeOnLocalNetwork($0) }
                    ))
                    .toggleStyle(ModernToggleStyle())
                    .labelsHidden()
                }

                GridRow {
                    settingsLabel(LocalizedStringKey("JIT LOAD"))
                    Toggle("", isOn: Binding(
                        get: { config.justInTimeLoading },
                        set: { viewModel.toggleJustInTimeLoading($0) }
                    ))
                    .toggleStyle(ModernToggleStyle())
                    .labelsHidden()
                }

                GridRow {
                    settingsLabel(LocalizedStringKey("AUTO UNLOAD"))
                    Toggle("", isOn: Binding(
                        get: { config.autoUnloadJIT },
                        set: { viewModel.toggleAutoUnloadJIT($0) }
                    ))
                    .toggleStyle(ModernToggleStyle())
                    .labelsHidden()
                }

                GridRow {
                    settingsLabel(LocalizedStringKey("IDLE TTL"))
                    HStack(spacing: 8) {
                        TextField(String(localized: "Mins"), text: $idleTTLText)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .onSubmit { applyIdleTTLText() }
                        Button(String(localized: "Apply")) { applyIdleTTLText() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }

                GridRow {
                    settingsLabel(LocalizedStringKey("KEEP LAST"))
                    Toggle("", isOn: Binding(
                        get: { config.onlyKeepLastJITModel },
                        set: { viewModel.toggleKeepLastJITModel($0) }
                    ))
                    .toggleStyle(ModernToggleStyle())
                    .labelsHidden()
                }

                GridRow {
                    settingsLabel(LocalizedStringKey("REQ LOGGING"))
                    Toggle("", isOn: Binding(
                        get: { config.requestLoggingEnabled },
                        set: { viewModel.toggleRequestLogging($0) }
                    ))
                    .toggleStyle(ModernToggleStyle())
                    .labelsHidden()
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.caption)
                Text(LocalizedStringKey("SERVER SETTINGS"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.text)
            }
        }
        .tint(Color.accentColor)
    }

    private func settingsLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(AppTheme.secondaryText)
    }

    private var serverRunningBinding: Binding<Bool> {
        Binding(
            get: {
                if case .running = viewModel.serverState { return true }
                return false
            },
            set: { isOn in
                if isOn {
                    viewModel.start()
                } else {
                    viewModel.stop()
                }
            }
        )
    }

    private var lanAddressDisplay: String {
        if let lan = viewModel.lanReachableAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lan.isEmpty,
           !lan.hasSuffix(":0") {
            return lan
        }
        if viewModel.serverConfiguration.serveOnLocalNetwork {
            return String(
                localized: "LAN address not detected",
                locale: LocalizationManager.preferredLocale()
            )
        }
        let fallbackPort = viewModel.serverConfiguration.port == 0 ? 12345 : viewModel.serverConfiguration.port
        return "http://127.0.0.1:\(fallbackPort)"
    }

    private func applyPortText() {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = UInt16(trimmed), value > 0 {
            viewModel.setServerPort(value)
        }
        portText = String(viewModel.serverConfiguration.port)
    }

    private func applyIdleTTLText() {
        let trimmed = idleTTLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(trimmed), value > 0 {
            viewModel.setIdleTTLMinutes(value)
        }
        idleTTLText = String(viewModel.serverConfiguration.maxIdleTTLMinutes)
    }

    private func copyToPasteboard(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringKey("RELAY SOURCES"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.text)
                Spacer()
                exposureBulkControls
            }
            if viewModel.availableModels.isEmpty {
                Text(LocalizedStringKey("No models available. Add downloads or remote connections in Stored to configure the relay."))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(viewModel.availableModels.enumerated()), id: \.element.id) { index, descriptor in
                        modelRow(for: descriptor)
                        if index < viewModel.availableModels.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            Divider()

            Toggle(LocalizedStringKey("Eject button unloads relay model"), isOn: $viewModel.ejectsModelOnDisconnect)
                .toggleStyle(ModernToggleStyle())
                .font(.system(.caption, design: .monospaced))
        }
    }

    @ViewBuilder
    private func modelRow(for descriptor: RelayModelDescriptor) -> some View {
        let isActive = viewModel.activeModelID == descriptor.id
        let entryIndex = viewModel.catalogEntries.firstIndex { $0.modelID == descriptor.id }
        let entry = entryIndex.flatMap { viewModel.catalogEntries[$0] }
        let isUnavailable = entry?.health == .error
        let isLoaded = viewModel.isModelLoaded(descriptor.id)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                providerBadge(for: descriptor.provider)
                Text(descriptor.displayName)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(AppTheme.text)
                if isActive {
                    Text(LocalizedStringKey("ACTIVE"))
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                if let entryIndex = entryIndex {
                    Text(LocalizedStringKey("EXPOSE"))
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                    Toggle("", isOn: $viewModel.catalogEntries[entryIndex].exposed)
                        .labelsHidden()
                        .toggleStyle(ModernToggleStyle())
                        .disabled(isUnavailable)
                }
            }

            HStack(alignment: .center, spacing: 8) {
                Text(modelSubtitle(for: descriptor))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText)
                if let entry {
                    Text("•")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.tertiaryText)
                    Text(exposureSummary(for: descriptor, entry: entry))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                if !isUnavailable {
                    if isLoaded {
                        Button(LocalizedStringKey("Unload")) { viewModel.unloadModel(descriptor.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    } else {
                        if viewModel.loadingModelIDs.contains(descriptor.id) {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(LocalizedStringKey("Loading…"))
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            Button(LocalizedStringKey("Load")) { viewModel.loadModel(descriptor.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                }
            }
            if let entry, entry.health == .missing {
                Text(LocalizedStringKey("Source unavailable. Check storage or network settings."))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.red)
            }
            if isUnavailable {
                Text(LocalizedStringKey("Remote endpoint is offline. This model can't be found at this time."))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
        .opacity(isUnavailable ? 0.45 : 1)
    }

    private var exposureBulkControls: some View {
        let allSelected = viewModel.availableModels.allSatisfy { descriptor in
            viewModel.catalogEntries.first(where: { $0.modelID == descriptor.id })?.exposed == true
        }

        return HStack {
            Button {
                viewModel.setExposureForAllAvailable(!allSelected)
            } label: {
                Text(allSelected ? LocalizedStringKey("Clear All") : LocalizedStringKey("Select All"))
            }
            .buttonStyle(.bordered)
            .help(
                String(
                    localized: allSelected
                        ? "Hide every relay source from paired devices"
                        : "Expose every relay source to paired devices",
                    locale: LocalizationManager.preferredLocale()
                )
            )

            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func providerBadge(for provider: RelayProviderKind) -> some View {
        let symbol: String
        switch provider {
        case .local:
            symbol = "internaldrive"
        case .ollama:
            symbol = "cube.fill"
        case .lmstudio:
            symbol = "macmini.fill"
        case .http:
            symbol = "network"
        }
        return Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .frame(width: 16)
    }

    private func modelSubtitle(for descriptor: RelayModelDescriptor) -> String {
        var components: [String] = [descriptor.provider.displayName]
        if descriptor.isLocal {
            if let quant = descriptor.quant, !quant.isEmpty {
                components.append(quant)
            }
            if let context = descriptor.context, context > 0 {
                components.append("\(context) ctx")
            }
        } else if let backend = descriptor.backend {
            components.append(backend.name)
            let host = backend.displayBaseHost
            if !host.isEmpty {
                components.append(host)
            }
        }
        return components.joined(separator: " • ")
    }

    private func exposureSummary(for descriptor: RelayModelDescriptor, entry: RelayCatalogEntry) -> String {
        var pieces: [String] = []
        let locale = LocalizationManager.preferredLocale()
        if descriptor.provider == .local {
            if let size = descriptor.sizeBytes {
                pieces.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        } else if let backend = descriptor.backend {
            pieces.append(backend.endpointType.displayName)
            let auth = backend.hasAuth
                ? String(localized: "auth", locale: locale)
                : String(localized: "no auth", locale: locale)
            pieces.append(auth)
        }
        pieces.append(
            entry.exposed
                ? String(localized: "exposed", locale: locale)
                : String(localized: "hidden", locale: locale)
        )
        if entry.health == .error {
            pieces.append(String(localized: "unavailable", locale: locale))
        }
        return pieces.joined(separator: " • ")
    }

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(Color.blue)
                Text(LocalizedStringKey("BLUETOOTH PAIRING"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.text)
            }
            HStack(alignment: .center, spacing: 12) {
                AnimatedBluetoothBadge(state: viewModel.bluetoothState)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bluetoothStatusTitle)
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(AppTheme.text)
                    bluetoothStatusDetail
                }
            }
            if let payload = viewModel.payload {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text(LocalizedStringKey("DEVICE"))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(payload.deviceName)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppTheme.text)
                    }
                    GridRow {
                        Text(LocalizedStringKey("RELAY ID"))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(payload.id.uuidString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppTheme.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
                .animation(.easeInOut(duration: 0.35), value: payload.id)
            }
        }
    }

    private var bluetoothStatusTitle: String {
        switch viewModel.bluetoothState {
        case .idle:
            return String(
                localized: "Bluetooth ready to advertise",
                locale: LocalizationManager.preferredLocale()
            )
        case .poweringOn:
            return String(
                localized: "Warming up Bluetooth radio…",
                locale: LocalizationManager.preferredLocale()
            )
        case .advertising:
            return String(
                localized: "Broadcasting relay details",
                locale: LocalizationManager.preferredLocale()
            )
        case .error(let message):
            return message
        }
    }

    @ViewBuilder
    private var bluetoothStatusDetail: some View {
        switch viewModel.bluetoothState {
        case .idle:
            Text(LocalizedStringKey("Start the relay to automatically share the latest payload with nearby devices."))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        case .poweringOn:
            Text(LocalizedStringKey("Enabling Bluetooth…"))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        case .advertising:
            Text(LocalizedStringKey("Sharing relay payload with nearby devices…"))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        case .error(let message):
            Text(message)
                .font(FontTheme.caption)
                .foregroundColor(.red)
        }
    }

    private var cloudKitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: cloudKitStatusSymbol)
                    .font(.caption)
                    .foregroundStyle(cloudKitStatusColor)
                Text(LocalizedStringKey("CLOUDKIT RELAY"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.text)
                Spacer()
                if shouldShowCloudKitProgress {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text(LocalizedStringKey("STATUS"))
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(cloudKitStatusTitle)
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(cloudKitStatusColor)
                }
                
                if let detail = cloudKitPrimaryDetail {
                    GridRow {
                        Text(LocalizedStringKey("INFO"))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(cloudKitPrimaryDetailColor)
                    }
                }
                
                if viewModel.catalogVersion > 0 {
                    GridRow {
                        Text(LocalizedStringKey("CATALOG"))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text("v\(viewModel.catalogVersion)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppTheme.text)
                    }
                }
                if let lastSync = cloudKitLastSyncText {
                    GridRow {
                        Text(LocalizedStringKey("LAST SYNC"))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(lastSync)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppTheme.text)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func syncConfigurationFields() {
        let config = viewModel.serverConfiguration
        portText = String(config.port)
        idleTTLText = String(config.maxIdleTTLMinutes)
    }

    private var cloudKitStatusTitle: String {
        if viewModel.isCheckingCloudKitAccount {
            return String(
                localized: "Checking iCloud availability…",
                locale: LocalizationManager.preferredLocale()
            )
        }
        if viewModel.cloudKitAccountError != nil {
            return String(
                localized: "CloudKit unavailable",
                locale: LocalizationManager.preferredLocale()
            )
        }
        guard let status = viewModel.cloudKitAccountStatus else {
            return String(
                localized: "CloudKit unavailable",
                locale: LocalizationManager.preferredLocale()
            )
        }
        switch status {
        case .available:
            return String(
                localized: "Connected to iCloud",
                locale: LocalizationManager.preferredLocale()
            )
        case .noAccount:
            return String(
                localized: "Sign in to iCloud to enable the relay",
                locale: LocalizationManager.preferredLocale()
            )
        case .restricted:
            return String(
                localized: "iCloud access is restricted",
                locale: LocalizationManager.preferredLocale()
            )
        case .couldNotDetermine:
            return String(
                localized: "Unable to determine iCloud status",
                locale: LocalizationManager.preferredLocale()
            )
        @unknown default:
            return String(
                localized: "CloudKit status unknown",
                locale: LocalizationManager.preferredLocale()
            )
        }
    }

    private var cloudKitStatusSymbol: String {
        if viewModel.isCheckingCloudKitAccount {
            return "clock.arrow.2.circlepath"
        }
        if viewModel.cloudKitAccountError != nil {
            return "exclamationmark.triangle.fill"
        }
        switch viewModel.cloudKitAccountStatus {
        case .available?:
            return "icloud"
        case .noAccount?:
            return "icloud.slash"
        case .restricted?:
            return "lock.icloud"
        case .couldNotDetermine?:
            return "questionmark.circle"
        default:
            return "icloud.slash"
        }
    }

    private var cloudKitStatusColor: Color {
        if viewModel.isCheckingCloudKitAccount {
            return .accentColor
        }
        if viewModel.cloudKitAccountError != nil {
            return .red
        }
        switch viewModel.cloudKitAccountStatus {
        case .available?:
            return .green
        case .noAccount?, .restricted?, .couldNotDetermine?:
            return .orange
        default:
            return .red
        }
    }

    private var cloudKitPrimaryDetail: String? {
        if viewModel.isCheckingCloudKitAccount {
            let id = RelayConfiguration.containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                return String(
                    localized: "Set a CloudKit container identifier in RelayConfiguration.swift to publish the catalog.",
                    locale: LocalizationManager.preferredLocale()
                )
            }
            return String.localizedStringWithFormat(
                String(
                    localized: "Verifying access to %@…",
                    locale: LocalizationManager.preferredLocale()
                ),
                id
            )
        }
        if let error = viewModel.cloudKitAccountError {
            return error
        }
        guard let status = viewModel.cloudKitAccountStatus else { return nil }
        switch status {
        case .noAccount:
            return String(
                localized: "Open System Settings → Apple ID and sign in with the same account as your iPhone or iPad.",
                locale: LocalizationManager.preferredLocale()
            )
        case .restricted:
            return String(
                localized: "Screen Time or device management restrictions may be blocking iCloud access.",
                locale: LocalizationManager.preferredLocale()
            )
        case .couldNotDetermine:
            return String(
                localized: "Check your internet connection and try again.",
                locale: LocalizationManager.preferredLocale()
            )
        default:
            return nil
        }
    }

    private var cloudKitPrimaryDetailColor: Color {
        if viewModel.cloudKitAccountError != nil {
            return .red
        }
        if viewModel.isCheckingCloudKitAccount {
            return .secondary
        }
        guard let status = viewModel.cloudKitAccountStatus else { return .secondary }
        switch status {
        case .noAccount, .restricted, .couldNotDetermine:
            return .orange
        default:
            return .secondary
        }
    }

    private var shouldShowCloudKitProgress: Bool {
        viewModel.cloudKitAccountError == nil &&
        viewModel.cloudKitAccountStatus == .some(.available) &&
        viewModel.lastPublishedHostStatus == .loading
    }

    private var cloudKitSubstatus: String? {
        guard viewModel.cloudKitAccountError == nil,
              viewModel.cloudKitAccountStatus == .some(.available) else { return nil }
        switch viewModel.lastPublishedHostStatus {
        case .loading:
            if viewModel.catalogVersion == 0 {
                return String(
                    localized: "Relay catalog is still syncing. Initial publishes typically finish within about 30 seconds after you start the relay.",
                    locale: LocalizationManager.preferredLocale()
                )
            }
            return String(
                localized: "Publishing catalog updates to CloudKit…",
                locale: LocalizationManager.preferredLocale()
            )
        case .running:
            return catalogVersionDescription
                ?? String(
                    localized: "Catalog is live and ready for paired devices.",
                    locale: LocalizationManager.preferredLocale()
                )
        case .idle:
            if let description = catalogVersionDescription {
                return description
            }
            return viewModel.serverState == .stopped
                ? String(
                    localized: "Start the relay to resume CloudKit updates.",
                    locale: LocalizationManager.preferredLocale()
                )
                : String(
                    localized: "Waiting for the first catalog publish from this Mac.",
                    locale: LocalizationManager.preferredLocale()
                )
        case .error:
            return String(
                localized: "CloudKit reported an error while publishing the catalog. Restart the relay to retry.",
                locale: LocalizationManager.preferredLocale()
            )
        }
    }

    private var catalogVersionDescription: String? {
        guard viewModel.catalogVersion > 0 else { return nil }
        if let updated = viewModel.lastCatalogUpdate {
            let relative = Self.relativeFormatter.localizedString(for: updated, relativeTo: Date())
            return String.localizedStringWithFormat(
                String(
                    localized: "Catalog version %@ synced %@.",
                    locale: LocalizationManager.preferredLocale()
                ),
                "\(viewModel.catalogVersion)",
                relative
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "Catalog version %@ is ready.",
                locale: LocalizationManager.preferredLocale()
            ),
            "\(viewModel.catalogVersion)"
        )
    }

private var cloudKitLastSyncText: String? {
        guard viewModel.catalogVersion > 0,
              let updated = viewModel.lastCatalogUpdate else { return nil }
        return updated.formatted(date: .numeric, time: .shortened)
    }

}

@_silgen_name("app_memory_footprint")
private func c_app_memory_footprint() -> UInt

private struct RelayChromeBar: View {
    let state: RelayManagementViewModel.ServerState
    let statusMessage: String
    var onRestart: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Noema Relay"))
                    .font(FontTheme.heading)
                    .foregroundStyle(AppTheme.text)
                Text(statusMessage)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            RelayStateBadge(state: state)

            Button(action: onRestart) {
                Label(LocalizedStringKey("Restart"), systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(GlassButtonStyle())
            .controlSize(.small)
            .disabled(!state.canRestartRelay)
            .help(LocalizedStringKey("Restart Relay"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .glassifyIfAvailable(in: Rectangle())
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}

private struct RelayStateBadge: View {
    let state: RelayManagementViewModel.ServerState

    var body: some View {
        let badge = state.badgeInfo
        Label(badge.title, systemImage: badge.icon)
            .font(FontTheme.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                badge.tint.opacity(0.15),
                in: Capsule(style: .continuous)
            )
            .foregroundStyle(badge.tint)
    }
}

private extension RelayManagementViewModel.ServerState {
    var badgeInfo: (icon: String, title: String, tint: Color) {
        let locale = LocalizationManager.preferredLocale()
        switch self {
        case .running:
            return (
                "checkmark.circle.fill",
                String(localized: "Running", locale: locale),
                .green
            )
        case .starting:
            return (
                "clock.arrow.circlepath",
                String(localized: "Starting", locale: locale),
                .orange
            )
        case .stopped:
            return (
                "pause.circle.fill",
                String(localized: "Stopped", locale: locale),
                Color.secondary
            )
        case .error:
            return (
                "exclamationmark.triangle.fill",
                String(localized: "Error", locale: locale),
                .red
            )
        }
    }

    var canRestartRelay: Bool {
        if case .running = self { return true }
        return false
    }
}

fileprivate struct RelayRAMUsageView: View {
    let info: DeviceRAMInfo
    @State private var usageBytes: Int64 = 0
    @State private var timer: Timer?
    private let updateInterval: TimeInterval = 5.0
    private let minChangeBytes: Int64 = 5 * 1_048_576 // 5 MB jitter threshold
    @Environment(\.locale) private var locale

    private var budgetBytes: Int64? {
        info.conservativeLimitBytes()
    }

    private var progress: Double {
        guard let cap = budgetBytes, cap > 0 else { return 0 }
        return min(1.0, Double(usageBytes) / Double(cap))
    }

    private var color: Color {
        switch progress {
        case 0..<0.7: return .green
        case 0.7..<0.9: return .orange
        default: return .red
        }
    }

    private var usageText: String {
        ByteCountFormatter.string(fromByteCount: usageBytes, countStyle: .memory)
    }

    private var capText: String {
        guard let cap = budgetBytes else { return "--" }
        return ByteCountFormatter.string(fromByteCount: cap, countStyle: .memory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 10)
                        .frame(width: 64, height: 64)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 64, height: 64)
                    Text("\(Int(progress * 100))%")
                        .font(FontTheme.caption)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.text)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("App Memory Usage (estimated)"))
                        .font(FontTheme.body)
                        .foregroundStyle(AppTheme.text)
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%@ of %@ budget", locale: locale),
                            usageText,
                            capText
                        )
                    )
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .onAppear(perform: start)
        .onDisappear(perform: stop)
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { @MainActor in refresh() }
        }
#endif
        .accessibilityElement(children: .contain)
    }

    private func start() {
        Task { @MainActor in refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let bytes = Int64(c_app_memory_footprint())
        // Skip tiny changes to reduce UI churn.
        guard usageBytes == 0 || abs(bytes - usageBytes) >= minChangeBytes else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            usageBytes = max(0, bytes)
        }
    }
}

private struct AnimatedBluetoothBadge: View {
    let state: RelayBluetoothAdvertiser.State
    @State private var ripple = false

    private var shouldAnimate: Bool {
        switch state {
        case .advertising, .poweringOn:
            return true
        case .idle, .error:
            return false
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(shouldAnimate ? 0.4 : 0.2), lineWidth: 1.5)
                .scaleEffect(ripple ? 1.6 : 1.0)
                .opacity(shouldAnimate ? (ripple ? 0.0 : 0.5) : 0)
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay {
                    Image(systemName: "wave.3.right")
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .foregroundStyle(Color.accentColor)
                }
        }
        .onAppear(perform: restartAnimation)
        .onChange(of: state) { _ in restartAnimation() }
        .animation(
            shouldAnimate
                ? .easeOut(duration: 1.8).repeatForever(autoreverses: false)
                : nil,
            value: ripple
        )
    }

    private func restartAnimation() {
        if shouldAnimate {
            ripple = false
            DispatchQueue.main.async {
                ripple = true
            }
        } else {
            ripple = false
        }
    }
}

private struct RelayGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            Image(systemName: "bolt.horizontal.fill")
                .resizable()
                .scaledToFit()
                .padding(10)
                .foregroundStyle(Color.accentColor)
        }
    }
}

#endif
