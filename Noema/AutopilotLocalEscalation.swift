#if os(macOS)
import Foundation
import NoemaPackages

@MainActor
final class AutopilotLocalEscalationRuntime: ObservableObject {
    static let shared = AutopilotLocalEscalationRuntime()

    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var client: AnyLLMClient?
    private(set) var loadedSelection: AutopilotLocalEscalationSelection?
    private var loadTask: Task<AnyLLMClient?, Never>?
    private var teardownTask: Task<Void, Never>?
    private var teardownGeneration = 0
    /// Monotonic token: a resolve→load→install sequence is only allowed to
    /// mutate `client`/`loadTask` if it is still the newest one. Bumped on
    /// every new load and every unload so a stale awaiter can never
    /// clobber a newer load or install an outdated client.
    private var loadGeneration = 0
    private var installedLoadGeneration: Int?
    /// While a handed-off turn is streaming on `client`, defer teardown so
    /// disarming Autopilot (or re-saving a different selection) can't cancel
    /// the answer mid-stream — matching cloud-escalation semantics.
    private var activeTurnToken: UUID?
    private var pendingUnload = false
    /// Covers the whole resident ChatVM replacement, not only its preflight.
    /// This prevents an awaited prewarm from reclaiming the GGUF bridge between
    /// the stronger-model teardown and the resident model's actual load.
    private var residentLoadInProgress = false
    private weak var pendingPrewarmManager: AppModelManager?

    private init() {}

    /// The formats the runtime can host next to the resident chat model.
    static func supportsFormat(_ format: ModelFormat) -> Bool {
        AutopilotLocalEscalationPolicy.supports(format)
    }

    static func resolveModel(for selection: AutopilotLocalEscalationSelection,
                             in downloaded: [LocalModel]) -> LocalModel? {
        if let match = downloaded.first(where: {
            $0.modelID == selection.modelID
                && $0.quant == selection.quant
                && $0.format == selection.format
                && $0.isDownloaded
        }) {
            return match
        }
        let selectedPath = canonicalPath(selection.urlPath)
        return downloaded.first(where: {
            $0.format == selection.format
                && canonicalPath($0.url.path) == selectedPath
                && $0.isDownloaded
        })
    }

    /// Fire-and-forget warm-up on arm/config change; safe to call repeatedly.
    /// Also re-evaluates fit: if a newly loaded chat model no longer fits
    /// alongside the escalation model (or IS the escalation model), tear down.
    func prewarmIfNeeded(manager: AppModelManager) {
        guard !residentLoadInProgress else {
            pendingPrewarmManager = manager
            return
        }
        let config = AutopilotConfigStore.load()
        guard config.enabled,
              config.escalationTarget == .localModel,
              let selection = config.localEscalation else {
            unload()
            return
        }
        // A resident escalation client may have become unfit because the chat
        // model changed. For GGUF, also verify that the global bridge still
        // points at this exact model; resident-client rebuilds reset the bridge.
        if loadedSelection == selection, client != nil {
            if let model = Self.resolveModel(for: selection, in: manager.downloadedModels),
               stillFits(model: model, selection: selection, manager: manager),
               isClientRuntimeReady(for: model) {
                return
            }
            Task { _ = await ensureReady(manager: manager) }
            return
        }
        if loadedSelection == selection, loadTask != nil {
            Task { _ = await ensureReady(manager: manager) }
            return
        }
        Task { _ = await ensureReady(manager: manager) }
    }

    /// True when `model` (the escalation target) still fits in RAM alongside
    /// the currently-resident chat model, and is not itself the chat model.
    private func stillFits(model: LocalModel,
                           selection: AutopilotLocalEscalationSelection,
                           manager: AppModelManager) -> Bool {
        if model.url.path == manager.loadedModel?.url.path { return false }
        guard EnterprisePolicyGate.allowsModelFormat(model.format),
              EnterprisePolicyGate.allowsModel(modelID: model.modelID) else { return false }
        guard AutopilotLocalEscalationPolicy.canCoexist(
            escalationFormat: model.format,
            residentFormat: manager.loadedModel?.format
        ) else { return false }
        var escSettings = manager.settings(for: model)
        escSettings.contextLength = Double(max(512, selection.contextLength))
        let escPlan = AutopilotDualLoadAdvisor.plan(for: model, settings: escSettings)
        let residentPlan = manager.loadedModel.map {
            AutopilotDualLoadAdvisor.plan(for: $0, settings: manager.settings(for: $0))
        }
        return AutopilotDualLoadAdvisor.assess(resident: residentPlan, escalation: escPlan).fits
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func isClientRuntimeReady(for model: LocalModel) -> Bool {
        guard let client else { return false }
        guard model.format == .gguf else { return true }
        return client.isCurrentRuntime() == true
    }

    /// Detaches runtime state immediately, then serializes any in-progress load
    /// and client teardown. Awaiting the returned task is required before a
    /// resident GGUF load can take ownership of the process-global bridge.
    @discardableResult
    private func scheduleUnload() -> Task<Void, Never> {
        loadGeneration += 1
        teardownGeneration += 1
        let teardownID = teardownGeneration
        let priorTeardown = teardownTask
        let pendingLoad = loadTask
        let loadedClient = client

        loadTask?.cancel()
        loadTask = nil
        installedLoadGeneration = nil
        client = nil
        loadedSelection = nil
        state = .idle

        let task = Task {
            await priorTeardown?.value
            let partiallyLoadedClient = await pendingLoad?.value
            await loadedClient?.unloadAndWait()
            await partiallyLoadedClient?.unloadAndWait()
        }
        teardownTask = task
        Task { [weak self] in
            await task.value
            guard let self, self.teardownGeneration == teardownID else { return }
            self.teardownTask = nil
        }
        return task
    }

    /// Starts a transaction spanning the resident ChatVM's entire replacement.
    /// The chat loader resets the global bridge before every resident load, so
    /// a stronger GGUF must be fully released and prevented from re-prewarming
    /// until the new resident client has finished loading.
    func beginResidentModelLoad(manager: AppModelManager?) async -> Bool {
        guard !residentLoadInProgress else { return false }
        residentLoadInProgress = true
        pendingPrewarmManager = manager
        if let teardownTask {
            await teardownTask.value
        }
        if loadedSelection?.format == .gguf {
            guard activeTurnToken == nil else {
                residentLoadInProgress = false
                pendingPrewarmManager = nil
                return false
            }
            await scheduleUnload().value
        }
        return true
    }

    /// Completes the resident-load transaction and replays a prewarm request
    /// that arrived while the bridge was reserved for ChatVM.
    func endResidentModelLoad() {
        guard residentLoadInProgress else { return }
        residentLoadInProgress = false
        let manager = pendingPrewarmManager
        pendingPrewarmManager = nil
        if let manager {
            prewarmIfNeeded(manager: manager)
        }
    }

    /// Returns a ready client for the configured local escalation model,
    /// loading it on demand. Nil when unconfigured, unresolvable, doesn't fit
    /// in RAM, or the load fails — callers fall back to the resident model.
    func ensureReady(manager: AppModelManager) async -> AnyLLMClient? {
        guard !residentLoadInProgress else {
            pendingPrewarmManager = manager
            return nil
        }
        if let teardownTask {
            await teardownTask.value
        }
        guard !residentLoadInProgress else {
            pendingPrewarmManager = manager
            return nil
        }
        let config = AutopilotConfigStore.load()
        guard config.escalationTarget == .localModel,
              let selection = config.localEscalation else {
            unload()
            return nil
        }

        // Selection changed while an old model was resident.
        if loadedSelection != nil, loadedSelection != selection {
            guard activeTurnToken == nil else {
                pendingUnload = true
                return nil
            }
            await scheduleUnload().value
        }

        guard let model = Self.resolveModel(for: selection, in: manager.downloadedModels),
              Self.supportsFormat(model.format) else {
            return await failAndRetire(
                String(
                    localized: "The stronger model is no longer installed.",
                    locale: LocalizationManager.preferredLocale()
                )
            )
        }
        guard EnterprisePolicyGate.allowsModelFormat(model.format),
              EnterprisePolicyGate.allowsModel(modelID: model.modelID) else {
            return await failAndRetire(
                String(
                    localized: "Blocked by your organization's policy.",
                    locale: LocalizationManager.preferredLocale()
                )
            )
        }
        guard AutopilotLocalEscalationPolicy.canCoexist(
            escalationFormat: model.format,
            residentFormat: manager.loadedModel?.format
        ) else {
            return await failAndRetire(
                String(
                    localized: "A GGUF stronger model can't stay loaded with a GGUF chat model.",
                    locale: LocalizationManager.preferredLocale()
                )
            )
        }
        // Never load the same model twice; and honor the dual-load RAM gate at
        // arm/prewarm/on-demand time, not just at wizard-selection time (the
        // resident chat model may have changed since the user picked).
        guard model.url.path != manager.loadedModel?.url.path else {
            return await failAndRetire(
                String(
                    localized: "The stronger model is already loaded as your chat model.",
                    locale: LocalizationManager.preferredLocale()
                )
            )
        }
        var settings = manager.settings(for: model)
        settings.contextLength = Double(max(512, selection.contextLength))
        guard stillFits(model: model, selection: selection, manager: manager) else {
            return await failAndRetire(
                String(
                    localized: "Not enough memory to keep both models loaded.",
                    locale: LocalizationManager.preferredLocale()
                )
            )
        }

        if let client, loadedSelection == selection, isClientRuntimeReady(for: model) {
            return client
        }
        if let loadTask, loadedSelection == selection {
            let gen = loadGeneration
            let loaded = await loadTask.value
            return await installLoadedClient(
                loaded,
                generation: gen,
                selection: selection,
                model: model,
                manager: manager
            )
        }
        // The selected client exists but its runtime was replaced/reset.
        if client != nil || loadTask != nil || loadedSelection != nil {
            guard activeTurnToken == nil else {
                pendingUnload = true
                return nil
            }
            await scheduleUnload().value
        }
        guard !residentLoadInProgress else {
            pendingPrewarmManager = manager
            return nil
        }

        loadGeneration += 1
        let gen = loadGeneration
        loadedSelection = selection
        state = .loading
        let task = Task<AnyLLMClient?, Never> { () -> AnyLLMClient? in
            do {
                let loaded: AnyLLMClient
                switch model.format {
                case .mlx:
                    if MLXBridge.isVLMModel(at: model.url) {
                        loaded = try await MLXBridge.makeVLMClient(url: model.url, settings: settings)
                    } else {
                        loaded = try await MLXBridge.makeTextClient(url: model.url, settings: settings)
                    }
                case .gguf:
                    // A non-GGUF resident does not use the loopback. Refuse to
                    // replace any unexpected owner rather than silently sending
                    // the hand-off to the wrong model.
                    let bridgeReservation = await NoemaLlamaClient.reserveLoopbackBridge()
                    defer { bridgeReservation.release() }
                    guard bridgeReservation.isActive else {
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                    guard LlamaServerBridge.port() <= 0 else {
                        throw NSError(
                            domain: "Noema.AutopilotLocalEscalation",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "The GGUF runtime is already in use.",
                                    locale: LocalizationManager.preferredLocale()
                                )
                            ]
                        )
                    }
                    let mmproj = ProjectorLocator.projectorPath(alongside: model.url)
                    let (configuration, overfitPlan) = GGUFServerConfigurationResolver.resolveWithPlan(
                        modelURL: model.url,
                        settings: settings,
                        mmprojPath: mmproj,
                        contextShiftEnabled: ContextOverflowStrategy.from(
                            UserDefaults.standard.string(forKey: "contextOverflowStrategy") ?? ""
                        ) != .stopAtLimit,
                        downloadedModels: manager.downloadedModels
                    )
                    if case .refused(let reason) = overfitPlan {
                        throw NSError(
                            domain: "Noema",
                            code: 2004,
                            userInfo: [NSLocalizedDescriptionKey: OverfitPlanResolver.refusalMessage(reason)]
                        )
                    }
                    let parameter = LlamaParameter(
                        options: LlamaOptions(),
                        contextLength: max(512, selection.contextLength),
                        threadCount: settings.cpuThreads,
                        mmproj: mmproj,
                        preferContextOverEnvironment: true,
                        forceFreshLoopback: false,
                        serverConfiguration: configuration
                    )
                    loaded = AnyLLMClient(
                        try await NoemaLlamaClient.llama(
                            url: model.url,
                            parameter: parameter,
                            bridgeReservation: bridgeReservation
                        )
                    )
                default:
                    return nil
                }
                return loaded
            } catch {
                await logger.log("[Autopilot][LocalEscalation] load failed: \(error.localizedDescription)")
                return nil
            }
        }
        loadTask = task
        let loaded = await task.value
        return await installLoadedClient(
            loaded,
            generation: gen,
            selection: selection,
            model: model,
            manager: manager
        )
    }

    /// Atomically returns the current client and reserves it for one handed-off
    /// turn. Revalidation after `ensureReady` closes the actor-reentrancy window
    /// where a resident load or another turn could take ownership while loading.
    func acquireTurn(manager: AppModelManager) async -> (
        client: AnyLLMClient,
        token: UUID,
        selection: AutopilotLocalEscalationSelection
    )? {
        guard activeTurnToken == nil, !residentLoadInProgress else { return nil }
        _ = await ensureReady(manager: manager)
        guard activeTurnToken == nil,
              !residentLoadInProgress,
              let client,
              let loadedSelection else { return nil }
        let config = AutopilotConfigStore.load()
        guard config.escalationTarget == .localModel,
              config.localEscalation == loadedSelection,
              let model = Self.resolveModel(
                  for: loadedSelection,
                  in: manager.downloadedModels
              ),
              EnterprisePolicyGate.allowsModelFormat(model.format),
              EnterprisePolicyGate.allowsModel(modelID: model.modelID),
              isClientRuntimeReady(for: model) else {
            unload()
            return nil
        }
        let token = UUID()
        activeTurnToken = token
        return (client, token, loadedSelection)
    }

    /// Clears only the matching turn guard; a stale completion can never release
    /// a newer handed-off turn.
    func endTurn(token: UUID) {
        guard activeTurnToken == token else { return }
        activeTurnToken = nil
        if pendingUnload {
            pendingUnload = false
            unload()
        }
    }

    func unload() {
        // Defer teardown while a handed-off answer is still streaming.
        if activeTurnToken != nil {
            pendingUnload = true
            return
        }
        scheduleUnload()
    }

    private func failAndRetire(_ message: String) async -> AnyLLMClient? {
        if activeTurnToken != nil {
            pendingUnload = true
        } else if client != nil || loadTask != nil || loadedSelection != nil {
            await scheduleUnload().value
        }
        state = .failed(message)
        return nil
    }

    /// Installs a completed coalesced load exactly once. Every waiter re-enters
    /// through this method, so none can return a client that a newer teardown or
    /// resident-load reservation has already invalidated.
    private func installLoadedClient(
        _ loaded: AnyLLMClient?,
        generation: Int,
        selection: AutopilotLocalEscalationSelection,
        model: LocalModel,
        manager: AppModelManager
    ) async -> AnyLLMClient? {
        guard generation == loadGeneration,
              loadedSelection == selection,
              !residentLoadInProgress else { return nil }
        if installedLoadGeneration == generation {
            return client
        }

        loadTask = nil
        installedLoadGeneration = generation
        guard let loaded else {
            state = .failed(
                String(
                    localized: "The stronger model failed to load.",
                    locale: LocalizationManager.preferredLocale()
                )
            )
            loadedSelection = nil
            return nil
        }

        let stillAllowed = EnterprisePolicyGate.allowsModelFormat(model.format)
            && EnterprisePolicyGate.allowsModel(modelID: model.modelID)
        let stillCompatible = AutopilotLocalEscalationPolicy.canCoexist(
            escalationFormat: model.format,
            residentFormat: manager.loadedModel?.format
        ) && stillFits(model: model, selection: selection, manager: manager)
        guard stillAllowed, stillCompatible else {
            loadedSelection = nil
            state = .failed(
                String(
                    localized: stillAllowed
                        ? "Not enough memory to keep both models loaded."
                        : "Blocked by your organization's policy.",
                    locale: LocalizationManager.preferredLocale()
                )
            )
            await loaded.unloadAndWait()
            return nil
        }

        client = loaded
        state = .ready
        Task {
            await logger.log(
                "[Autopilot][LocalEscalation] ready model=\(model.name) format=\(model.format.rawValue) ctx=\(selection.contextLength)"
            )
        }
        return loaded
    }
}
#endif
