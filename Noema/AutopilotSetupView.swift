import SwiftUI

enum AutopilotSetupMode: String, Equatable, Identifiable, Sendable {
    case full
    case router
    case strongerModel

    var id: String { rawValue }
}

struct AutopilotSetupView: View {
    @EnvironmentObject var modelManager: AppModelManager
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int {
        case system = 0
        case router = 1
        case cloud = 2
        case consent = 3
    }

    private enum PriceFilter: CaseIterable {
        case all
        case free
        case paid

        var title: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .free: return "Free"
            case .paid: return "Paid"
            }
        }
    }

    private let mode: AutopilotSetupMode
    @State private var step: Step
    @State private var system: AutopilotSystem = .router
    @State private var routerKind: RouterBrainKind = .remote
    @State private var escalationTarget: AutopilotEscalationTarget = .remote
    /// True once the user explicitly picks system / target in this wizard run.
    /// Off-Grid/enterprise coerces the shown values to the local combination for
    /// display, but a save must NOT persist that coercion over a saved config
    /// the user never touched.
    @State private var userPickedSystem = false
    @State private var userPickedTarget = false
    @State private var localEscalation: AutopilotLocalEscalationSelection?
    @State private var routerSelection: StartupPreferences.RemoteSelection?
    @State private var escalationSelection: StartupPreferences.RemoteSelection?
    @State private var expandedBackendID: RemoteBackend.ID?
    @State private var modelSearchText = ""
    @State private var priceFilter: PriceFilter = .all
    @State private var openRouterKey = ""
    @State private var isConnectingOpenRouter = false
    @State private var openRouterConnectError: String?
    @State private var connectOpenRouterExpanded = false

    private enum RouterTestPhase: Equatable {
        case idle
        case testing
        case success(latencyMs: Int)
        case failure(message: String)
    }

    @State private var routerTestPhase: RouterTestPhase = .idle
    @State private var routerTestGeneration = 0
    @State private var routerTestTask: Task<Void, Never>?
    @State private var routerTestWatchdogTask: Task<Void, Never>?

    init(mode: AutopilotSetupMode = .full) {
        let config = AutopilotConfigStore.load()
        self.mode = mode
        switch mode {
        case .full:
            _step = State(initialValue: .system)
        case .router:
            _step = State(initialValue: .router)
        case .strongerModel:
            _step = State(initialValue: .cloud)
        }
        _system = State(initialValue: config.system)
        _routerKind = State(initialValue: config.routerKind)
        _escalationTarget = State(
            initialValue: config.escalationTarget == .localModel && !Self.localEscalationSupported
                ? .remote
                : config.escalationTarget
        )
        _localEscalation = State(initialValue: config.localEscalation)
        _routerSelection = State(initialValue: config.routerSelection)
        _escalationSelection = State(initialValue: config.escalationSelection)
        _expandedBackendID = State(initialValue: mode == .strongerModel
            ? config.escalationSelection?.backendID
            : config.routerSelection?.backendID)
    }

    /// A second resident local model is macOS-only (RAM headroom + MLX dual-load).
    static var localEscalationSupported: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
#if os(macOS)
        macContainer
            .onDisappear(perform: cancelRouterTest)
#else
        touchContainer
            .onDisappear(perform: cancelRouterTest)
#endif
    }

    // MARK: - Shared state

    private var offGridBlocked: Bool {
        UserDefaults.standard.bool(forKey: "offGrid")
    }

    private var enterpriseBlocked: Bool {
        !EnterprisePolicyGate.remoteInferenceAllowed
    }

    /// Off-Grid / enterprise policy forbids the cloud paths (router brain +
    /// remote escalation). On macOS the fully-local phone-a-friend combination
    /// remains available, so the wizard opens with the cloud choices disabled
    /// instead of blocking outright.
    private var remotePathsBlocked: Bool {
        offGridBlocked || enterpriseBlocked
    }

    private var isFocusedEdit: Bool { mode != .full }

    private func enforceRemoteRestrictions() {
        guard remotePathsBlocked, Self.localEscalationSupported else { return }
        if !(system == .router && routerKind == .appleFoundationModel) {
            system = .phoneAFriend
        }
        escalationTarget = .localModel
    }

    private var smartRouterDetail: LocalizedStringKey {
        switch routerKind {
        case .appleFoundationModel:
            return "Autopilot reads each message privately on this device with Apple Intelligence to decide where it runs. Nothing is sent anywhere for routing."
        case .privateCloudCompute:
            return "Apple Private Cloud Compute reads each message privately and decides whether the on-device or stronger model should answer."
        case .remote:
            return "A small cloud router reads each message before the answer starts and picks on-device or the stronger model. Per-message control, works with any local model."
        }
    }

    private var loadedModelToolWarningNeeded: Bool {
        guard system == .phoneAFriend else { return false }
        guard let loaded = modelManager.loadedModel else { return false }
        return !loaded.isToolCapable
    }

    private var eligibleBackends: [RemoteBackend] {
        modelManager.remoteBackends.filter { !$0.isCloudRelay }
    }

    private struct ModelChoice: Identifiable {
        let id: String
        let name: String
        var maxContextLength: Int? = nil
        var promptPricePerMillion: Double? = nil
        var completionPricePerMillion: Double? = nil
        var hasPricing = false
        var isFree = false
    }

    private func modelChoices(for backend: RemoteBackend) -> [ModelChoice] {
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var ranked: [(choice: ModelChoice, rank: Int)] = []
        for model in backend.cachedModels {
            guard seen.insert(model.id).inserted else { continue }
            let rank = model.openRouterSearchRank(for: query)
            guard query.isEmpty || rank <= 5 else { continue }
            let choice = ModelChoice(
                id: model.id,
                name: model.name.isEmpty ? model.id : model.name,
                maxContextLength: model.maxContextLength,
                promptPricePerMillion: model.promptPricePerMillion,
                completionPricePerMillion: model.completionPricePerMillion,
                hasPricing: model.hasOpenRouterPricing,
                isFree: model.isOpenRouterFreeModel
            )
            ranked.append((choice, rank))
        }
        for raw in backend.customModelIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            guard query.isEmpty || id.range(of: query, options: .caseInsensitive) != nil else { continue }
            ranked.append((ModelChoice(id: id, name: id), 1))
        }
        if !query.isEmpty {
            ranked.sort {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.choice.name.localizedCaseInsensitiveCompare($1.choice.name) == .orderedAscending
            }
        }
        var choices = ranked.map(\.choice)
        switch priceFilter {
        case .all:
            break
        case .free:
            choices = choices.filter { $0.isFree }
        case .paid:
            choices = choices.filter { $0.hasPricing && !$0.isFree }
        }
        return choices
    }

    private func hasAnyModelChoices(_ backend: RemoteBackend) -> Bool {
        if !backend.cachedModels.isEmpty { return true }
        return backend.customModelIDs.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func backendHasPricingData(_ backend: RemoteBackend) -> Bool {
        backend.cachedModels.contains { $0.hasOpenRouterPricing }
    }

    private func choiceMetadata(_ choice: ModelChoice) -> String? {
        var parts: [String] = []
        if let context = choice.maxContextLength, context > 0 {
            parts.append("\(context.formatted(.number.grouping(.automatic))) ctx")
        }
        if choice.isFree {
            parts.append("free")
        } else if choice.hasPricing {
            var pricing: [String] = []
            if let prompt = choice.promptPricePerMillion {
                pricing.append("$\(Self.priceString(prompt))/M in")
            }
            if let completion = choice.completionPricePerMillion {
                pricing.append("$\(Self.priceString(completion))/M out")
            }
            if !pricing.isEmpty {
                parts.append(pricing.joined(separator: " · "))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func priceString(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private func resetModelFilters() {
        modelSearchText = ""
        priceFilter = .all
    }

    private func toggleExpanded(_ backend: RemoteBackend) {
        if expandedBackendID == backend.id {
            expandedBackendID = nil
        } else {
            expandedBackendID = backend.id
            resetModelFilters()
        }
    }

    private var stepSelection: StartupPreferences.RemoteSelection? {
        step == .router ? routerSelection : escalationSelection
    }

    private func isSelected(_ backend: RemoteBackend, _ choice: ModelChoice) -> Bool {
        if step == .router, routerKind != .remote { return false }
        if step == .cloud, escalationTarget != .remote { return false }
        return stepSelection?.backendID == backend.id && stepSelection?.modelID == choice.id
    }

    private func select(_ backend: RemoteBackend, _ choice: ModelChoice) {
        let selection = StartupPreferences.RemoteSelection(
            backendID: backend.id,
            backendName: backend.name,
            modelID: choice.id,
            modelName: choice.name
        )
        if step == .router {
            let changed = routerKind != .remote
                || routerSelection?.backendID != selection.backendID
                || routerSelection?.modelID != selection.modelID
            routerKind = .remote
            routerSelection = selection
            if changed {
                resetRouterTest()
            }
            autoRunRouterTestIfFree()
        } else {
            escalationTarget = .remote
            userPickedTarget = true
            escalationSelection = selection
        }
    }

    // MARK: - Router connection test

    private var afmUnavailableMessage: String? {
        AutopilotAFMBrain.unavailableMessage
    }

    private var pccUnavailableMessage: String? {
        AutopilotPCCBrain.unavailableMessage
    }

    private func selectAFMRouter() {
        guard AutopilotAFMBrain.isAvailableNow else { return }
        if routerKind != .appleFoundationModel {
            routerKind = .appleFoundationModel
            resetRouterTest()
        }
        if remotePathsBlocked, Self.localEscalationSupported {
            escalationTarget = .localModel
            userPickedTarget = true
        }
        // Selection is an early, high-confidence signal that a manual test or
        // real send is likely. Do not auto-run inference here.
        AutopilotAFMBrain.prewarmForLikelyUse()
    }

    private func selectPCCRouter() {
        guard AutopilotPCCBrain.isSelectable else { return }
        if routerKind != .privateCloudCompute {
            routerKind = .privateCloudCompute
            resetRouterTest()
        }
    }

    private func selectPCCEscalation() {
        guard AutopilotPCCBrain.isSelectable else { return }
        escalationTarget = .privateCloudCompute
        userPickedTarget = true
    }

    private var selectedRouterBackend: RemoteBackend? {
        guard let id = routerSelection?.backendID else { return nil }
        return modelManager.remoteBackends.first { $0.id == id }
    }

    private var selectedRouterModel: RemoteModel? {
        guard let selection = routerSelection else { return nil }
        if let cached = selectedRouterBackend?.cachedModels.first(where: { $0.id == selection.modelID }) {
            return cached
        }
        return RemoteModel(id: selection.modelID, name: selection.modelName, author: "")
    }

    private var routerTestModelIsPaid: Bool {
        guard routerKind == .remote, let model = selectedRouterModel else { return false }
        return model.hasOpenRouterPricing && !model.isOpenRouterFreeModel
    }

    private func resetRouterTest() {
        routerTestTask?.cancel()
        routerTestTask = nil
        routerTestWatchdogTask?.cancel()
        routerTestWatchdogTask = nil
        routerTestGeneration += 1
        routerTestPhase = .idle
    }

    private func cancelRouterTest() {
        routerTestTask?.cancel()
        routerTestTask = nil
        routerTestWatchdogTask?.cancel()
        routerTestWatchdogTask = nil
        routerTestGeneration += 1
        // A provisional AFM selection may have prewarmed a session. Reconcile
        // with the persisted configuration when the sheet closes.
        AutopilotAFMBrain.syncWarmState()
    }

    private func autoRunRouterTestIfFree() {
        guard routerTestPhase == .idle else { return }
        // AFM tests are always explicit: an automatic test can consume the
        // prewarm window intended for the user's first real message.
        guard routerKind == .remote else { return }
        guard routerSelection != nil, !routerTestModelIsPaid else { return }
        startRouterTest()
    }

    private func startRouterTest() {
        if routerKind == .appleFoundationModel {
            routerTestTask?.cancel()
            routerTestWatchdogTask?.cancel()
            routerTestWatchdogTask = nil
            routerTestGeneration += 1
            let generation = routerTestGeneration
            routerTestPhase = .testing
            routerTestTask = Task { @MainActor in
                let result = await AutopilotAFMBrain.runConnectionTest()
                guard generation == routerTestGeneration else { return }
                routerTestTask = nil
                switch result {
                case .success(let decision):
                    routerTestPhase = .success(latencyMs: decision.latencyMs)
                case .failure(let error):
                    routerTestPhase = .failure(message: error.localizedDescription)
                }
            }
            return
        }
        if routerKind == .privateCloudCompute {
            routerTestTask?.cancel()
            routerTestWatchdogTask?.cancel()
            routerTestWatchdogTask = nil
            routerTestGeneration += 1
            let generation = routerTestGeneration
            routerTestPhase = .testing
            routerTestTask = Task { @MainActor in
                let result = await AutopilotPCCBrain.runConnectionTest()
                guard generation == routerTestGeneration else { return }
                routerTestTask = nil
                switch result {
                case .success(let decision):
                    routerTestPhase = .success(latencyMs: decision.latencyMs)
                case .failure(let error):
                    routerTestPhase = .failure(message: error.localizedDescription)
                }
            }
            return
        }
        guard let backend = selectedRouterBackend, let model = selectedRouterModel else { return }
        routerTestTask?.cancel()
        routerTestWatchdogTask?.cancel()
        routerTestWatchdogTask = nil
        routerTestGeneration += 1
        let generation = routerTestGeneration
        routerTestPhase = .testing
        routerTestTask = Task { @MainActor in
            let result = await AutopilotBrainClient.runConnectionTest(backend: backend, model: model)
            guard generation == routerTestGeneration else { return }
            routerTestTask = nil
            switch result {
            case .success(let decision):
                routerTestPhase = .success(latencyMs: decision.latencyMs)
            case .failure(let error):
                routerTestPhase = .failure(message: error.localizedDescription)
            }
        }
    }

    private static func routerTestSeconds(_ latencyMs: Int) -> String {
        String(format: "%.1f", Double(latencyMs) / 1000.0)
    }

    private var visibleSteps: [Step] {
        system == .router ? [.system, .router, .cloud, .consent] : [.system, .cloud, .consent]
    }

    private var stepNumber: Int {
        (visibleSteps.firstIndex(of: step) ?? 0) + 1
    }

    private var stepCount: Int {
        visibleSteps.count
    }

    private var stepTitle: LocalizedStringKey {
        switch step {
        case .system: return "System"
        case .router: return "Router"
        case .cloud:
            if escalationTarget != .remote { return "Stronger Model" }
            return "Cloud Model"
        case .consent: return "Before Autopilot begins"
        }
    }

    private var stepCaption: LocalizedStringKey? {
        switch step {
        case .system: return "Choose how Autopilot decides when the stronger model steps in."
        case .router: return "Choose the small model that reads each message and decides where it runs."
        case .cloud:
            if Self.localEscalationSupported {
                return "Choose the model Autopilot escalates to — in the cloud, or a stronger model kept loaded on this Mac."
            }
            return "Choose the one model Autopilot may escalate to."
        case .consent: return nil
        }
    }

    private var continueEnabled: Bool {
        switch step {
        case .system: return true
        case .router: return routerKind != .remote || routerSelection != nil
        case .cloud:
            return escalationConfiguredInWizard
        case .consent: return true
        }
    }

    private func advance() {
        switch step {
        case .system:
            step = system == .router ? .router : .cloud
            expandedBackendID = escalationSelection?.backendID ?? routerSelection?.backendID
            resetModelFilters()
        case .router:
            step = .cloud
            expandedBackendID = escalationSelection?.backendID ?? routerSelection?.backendID
            resetModelFilters()
        case .cloud:
            step = .consent
        case .consent:
            break
        }
    }

    private func goBack() {
        switch step {
        case .system:
            break
        case .router:
            step = .system
        case .cloud:
            if system == .router {
                step = .router
                expandedBackendID = routerSelection?.backendID
                resetModelFilters()
            } else {
                step = .system
            }
        case .consent:
            step = .cloud
        }
    }

    // MARK: - Local escalation model (macOS)

    /// Installed models eligible to be the resident stronger model. MLX is
    /// instance-scoped. GGUF uses the compiled loopback server and can coexist
    /// with a non-GGUF chat model; the pair policy disables GGUF + GGUF.
    private var installedLocalEscalationCandidates: [LocalModel] {
        modelManager.downloadedModels
            .filter { $0.isDownloaded && AutopilotLocalEscalationPolicy.supports($0.format) }
            .filter { $0.url.path != modelManager.loadedModel?.url.path }
    }

    private var localEscalationCandidates: [LocalModel] {
        installedLocalEscalationCandidates
            .filter {
                EnterprisePolicyGate.allowsModelFormat($0.format)
                    && EnterprisePolicyGate.allowsModel(modelID: $0.modelID)
            }
            .sorted { $0.sizeGB > $1.sizeGB }
    }

    private var localEscalationCandidatesBlockedByPolicy: Bool {
        !installedLocalEscalationCandidates.isEmpty && localEscalationCandidates.isEmpty
    }

    /// The small model the estimate pairs against: the loaded one, else the
    /// most recently used one.
    private var residentReferenceModel: LocalModel? {
        modelManager.loadedModel ?? modelManager.lastUsedModel
    }

    private func dualFitAssessment(for candidate: LocalModel) -> AutopilotDualLoadAdvisor.Assessment {
        let escalationPlan = AutopilotDualLoadAdvisor.plan(
            for: candidate,
            settings: modelManager.settings(for: candidate)
        )
        let residentPlan = residentReferenceModel.map {
            AutopilotDualLoadAdvisor.plan(for: $0, settings: modelManager.settings(for: $0))
        }
        return AutopilotDualLoadAdvisor.assess(resident: residentPlan, escalation: escalationPlan)
    }

    private func localCandidateCanCoexist(_ candidate: LocalModel) -> Bool {
        AutopilotLocalEscalationPolicy.canCoexist(
            escalationFormat: candidate.format,
            residentFormat: residentReferenceModel?.format
        )
    }

    private func localCandidateIsSelectable(_ candidate: LocalModel) -> Bool {
        localCandidateCanCoexist(candidate) && dualFitAssessment(for: candidate).fits
    }

    private var localEscalationSelectionIsValid: Bool {
        guard let selection = localEscalation,
              let candidate = localEscalationCandidates.first(where: {
                  $0.modelID == selection.modelID
                      && $0.quant == selection.quant
                      && $0.format == selection.format
              }) else { return false }
        return localCandidateIsSelectable(candidate)
    }

    private func isLocalSelected(_ candidate: LocalModel) -> Bool {
        localEscalation?.modelID == candidate.modelID
            && localEscalation?.quant == candidate.quant
            && localEscalation?.format == candidate.format
    }

    private func selectLocal(_ candidate: LocalModel) {
        guard localCandidateIsSelectable(candidate) else { return }
        localEscalation = AutopilotLocalEscalationSelection(
            modelID: candidate.modelID,
            name: candidate.name,
            quant: candidate.quant,
            format: candidate.format,
            urlPath: candidate.url.path,
            contextLength: max(512, Int(modelManager.settings(for: candidate).contextLength))
        )
    }

    private static func memoryString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func dualFitDetail(_ assessment: AutopilotDualLoadAdvisor.Assessment) -> String {
        guard let budget = assessment.budgetBytes else {
            return Self.memoryString(assessment.combinedBytes)
        }
        return "\(Self.memoryString(assessment.combinedBytes)) / \(Self.memoryString(budget))"
    }

    // MARK: - OpenRouter quick connect

    private var trimmedOpenRouterKey: String {
        openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectButtonDisabled: Bool {
        isConnectingOpenRouter || trimmedOpenRouterKey.isEmpty
    }

    private func connectOpenRouter() {
        guard !isConnectingOpenRouter else { return }
        let key = trimmedOpenRouterKey
        isConnectingOpenRouter = true
        openRouterConnectError = nil
        Task { @MainActor in
            do {
                _ = try await RemoteBackendAPI.verifyOpenRouterAPIKey(key)
                var draft = RemoteBackendDraft()
                draft.name = "OpenRouter"
                draft.baseURL = "https://openrouter.ai"
                draft.endpointType = .openRouter
                draft.chatPath = RemoteBackend.EndpointType.openRouter.defaultChatPath
                draft.modelsPath = RemoteBackend.EndpointType.openRouter.defaultModelsPath
                draft.openRouterAPIKey = key
                try await modelManager.addRemoteBackend(from: draft)
                let added = modelManager.remoteBackends.first {
                    $0.endpointType == .openRouter
                        && $0.name.caseInsensitiveCompare("OpenRouter") == .orderedSame
                } ?? modelManager.remoteBackends.first { $0.endpointType == .openRouter }
                if let added {
                    resetModelFilters()
                    expandedBackendID = added.id
                }
                openRouterKey = ""
                connectOpenRouterExpanded = false
            } catch {
                openRouterConnectError = error.localizedDescription
            }
            isConnectingOpenRouter = false
        }
    }

    private var routerBackendName: String {
        routerSelection?.backendName ?? ""
    }

    private var escalationModelName: String {
        escalationTarget == .privateCloudCompute
            ? AppleFoundationModelKind.privateCloudCompute.modelName
            : (escalationSelection?.modelName ?? "")
    }

    private var consentedRouterHost: String? {
        guard let id = routerSelection?.backendID,
              let backend = modelManager.remoteBackends.first(where: { $0.id == id }) else { return nil }
        return URL(string: backend.baseURLString)?.host
    }

    private var escalationConfiguredInWizard: Bool {
        switch escalationTarget {
        case .localModel:
            return localEscalationSelectionIsValid
        case .privateCloudCompute:
            return AutopilotPCCBrain.isSelectable
        case .remote:
            return escalationSelection != nil
        }
    }

    private func applyWizardSelections(to config: inout AutopilotConfig) {
        // Under a policy block the shown system/target were coerced to the
        // local combination for display only (enforceRemoteRestrictions). If
        // the user never explicitly chose them, preserve the saved config's
        // values so "Not Now"/save on an untouched wizard is a no-op for them.
        if !remotePathsBlocked || userPickedSystem {
            config.system = system
        }
        if !remotePathsBlocked || userPickedTarget {
            config.escalationTarget = escalationTarget
        }
        config.routerKind = routerKind
        config.routerSelection = routerSelection
        config.escalationSelection = escalationSelection
        if config.escalationTarget == .localModel {
            config.localEscalation = localEscalation ?? config.localEscalation
        }
    }

    private func turnOnAutopilot() {
        if system == .router {
            guard routerKind != .remote || routerSelection != nil else { return }
        }
        guard escalationConfiguredInWizard else { return }
        var config = AutopilotConfigStore.load()
        applyWizardSelections(to: &config)
        // Stamp cloud consent ONLY for configurations that actually send
        // content to the cloud. Any fully-local setup must leave hasConsent ==
        // false so a later switch to a cloud path re-prompts.
        if config.requiresCloudConsent {
            config.consentAcceptedAt = Date()
            config.consentedRouterHost = config.system == .router && config.routerKind == .remote
                ? consentedRouterHost
                : nil
        } else {
            config.consentAcceptedAt = nil
            config.consentedRouterHost = nil
        }
        config.enabled = true
        AutopilotConfigStore.save(config)
        AutopilotAFMBrain.syncWarmState(armed: true)
        modelManager.autoRoutingArmed = true
        // A new router brain deserves a clean slate: without this, failure
        // cool-down latched by the previous brain keeps bypassing the new one.
        Task { await AutopilotRouter.shared.resetDegradation() }
        #if os(macOS)
        AutopilotLocalEscalationRuntime.shared.prewarmIfNeeded(manager: modelManager)
        #endif
        dismiss()
    }

    private func saveSelectionsOnly() {
        var config = AutopilotConfigStore.load()
        applyWizardSelections(to: &config)
        AutopilotConfigStore.save(config)
        AutopilotAFMBrain.syncWarmState(armed: config.enabled)
        Task { await AutopilotRouter.shared.resetDegradation() }
        #if os(macOS)
        AutopilotLocalEscalationRuntime.shared.prewarmIfNeeded(manager: modelManager)
        #endif
        dismiss()
    }

    private func saveFocusedSelection() {
        var config = AutopilotConfigStore.load()
        switch mode {
        case .full:
            return
        case .router:
            guard routerKind != .remote || routerSelection != nil else { return }
            config.routerKind = routerKind
            config.routerSelection = routerSelection
        case .strongerModel:
            guard escalationConfiguredInWizard else { return }
            config.escalationTarget = escalationTarget
            config.escalationSelection = escalationSelection
            if escalationTarget == .localModel {
                config.localEscalation = localEscalation
            }
        }

        // Choosing and saving a cloud-backed option here is the focused
        // equivalent of accepting the onboarding disclosure. Fully-local
        // combinations carry no cloud consent state.
        if config.requiresCloudConsent {
            if config.consentAcceptedAt == nil {
                config.consentAcceptedAt = Date()
            }
            config.consentedRouterHost = config.system == .router && config.routerKind == .remote
                ? consentedRouterHost
                : nil
        } else {
            config.consentAcceptedAt = nil
            config.consentedRouterHost = nil
        }

        AutopilotConfigStore.save(config)
        if modelManager.autoRoutingArmed && !config.isReadyToArm {
            modelManager.autoRoutingArmed = false
        }
        AutopilotAFMBrain.syncWarmState(armed: modelManager.autoRoutingArmed)
        Task { await AutopilotRouter.shared.resetDegradation() }
        #if os(macOS)
        AutopilotLocalEscalationRuntime.shared.prewarmIfNeeded(manager: modelManager)
        #endif
        dismiss()
    }

    private var localEscalationName: String {
        localEscalation?.name ?? ""
    }

    @ViewBuilder
    private var consentParagraphs: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch (system, escalationTarget) {
            case (.router, _):
                if routerKind == .appleFoundationModel {
                    Text("Autopilot reads each message privately on this device with Apple Intelligence to decide where it runs. Nothing is sent anywhere for routing.")
                } else if routerKind == .privateCloudCompute {
                    Text("Autopilot sends each message to Apple Private Cloud Compute so Apple's privacy-preserving server model can decide where the answer should run.")
                } else {
                    Text("Autopilot sends every message you write to your router endpoint (\(routerBackendName)) so it can decide where the answer should run. Most answers stay on this device.")
                }
                if escalationTarget == .localModel {
                    Text("When the router escalates, the answer is produced by \(localEscalationName) — a stronger model that stays on this Mac. Your conversation never goes to an answer model in the cloud.")
                } else if escalationTarget == .privateCloudCompute {
                    Text("When the router escalates, your message and recent conversation are sent to Apple Private Cloud Compute for the answer.")
                } else {
                    Text("When the router escalates, your message and recent conversation are sent to \(escalationModelName).")
                }
                Text("If you're offline, nothing is sent — Noema answers on-device and says so.")
            case (.phoneAFriend, .remote):
                Text("Your on-device model answers everything itself. When a request is clearly beyond it, it can hand the conversation to \(escalationModelName) — only then are your message and recent conversation sent to the cloud.")
                Text("Nothing is sent before a hand-off, and there is no separate router reading your messages.")
                Text("If you're offline, nothing is sent — Noema answers on-device and says so.")
            case (.phoneAFriend, .localModel):
                Text("Your on-device model answers everything itself. When a request is clearly beyond it, it hands the conversation to \(localEscalationName) — a stronger model that stays loaded on this Mac.")
                Text("Everything runs on this device. No message, router call, or hand-off ever touches the network.")
                Text("Keeping both models loaded uses more memory; Noema checked that they fit together on this Mac.")
            case (.phoneAFriend, .privateCloudCompute):
                Text("Your on-device model answers everything itself. When a request is clearly beyond it, it can hand the conversation to Apple Private Cloud Compute — only then are your message and recent conversation sent to Apple's privacy-preserving servers.")
                Text("Nothing is sent before a hand-off, and there is no separate router reading your messages.")
                Text("If you're offline, nothing is sent — Noema answers on-device and says so.")
            }
            Text("Every answer carries a receipt showing where it ran and why. You can change the system or turn Autopilot off any time in Settings.")
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.primary.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

#if !os(macOS)

    // MARK: - iOS / visionOS

    private var touchContainer: some View {
        VStack(spacing: 0) {
            if offGridBlocked {
                touchBlocked(icon: "airplane", tint: .secondary,
                             message: "Off‑Grid mode is on. Autopilot needs the network to route messages.")
            } else if enterpriseBlocked {
                touchBlocked(icon: "lock.fill", tint: .orange,
                             message: "Your organization's policy doesn't allow cloud routing.")
            } else {
                touchHeader
                touchStepContent
                Divider()
                touchFooter
            }
        }
    }

    private func touchBlocked(icon: String, tint: Color, message: LocalizedStringKey) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(tint)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var touchHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isFocusedEdit {
                Text("Step \(stepNumber) of \(stepCount)")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.secondary)
            }
            Text(stepTitle)
                .font(.title2.weight(.bold))
            if let stepCaption {
                Text(stepCaption)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var touchStepContent: some View {
        switch step {
        case .system:
            touchSystemList
        case .router, .cloud:
            touchPickerList
        case .consent:
            ScrollView {
                consentParagraphs
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
        }
    }

    private var touchSystemList: some View {
        List {
            Section {
                touchSystemChoiceRow(
                    .router,
                    title: "Smart Router",
                    icon: "arrow.triangle.branch",
                    detail: smartRouterDetail
                )
                touchSystemChoiceRow(
                    .phoneAFriend,
                    title: "Phone a Friend",
                    icon: "phone.arrow.up.right",
                    detail: "No router. Your on-device model answers everything and calls for the stronger model only when a request is beyond it. Needs a tool-capable local model."
                )
            } footer: {
                if loadedModelToolWarningNeeded {
                    Text("The loaded model (\(modelManager.loadedModel?.name ?? "")) can't call tools, so it won't be able to phone a friend. Load a tool-capable model to use this system.")
                        .foregroundStyle(Color.orange)
                }
            }
        }
    }

    private func touchSystemChoiceRow(_ choice: AutopilotSystem, title: LocalizedStringKey, icon: String, detail: LocalizedStringKey) -> some View {
        Button {
            system = choice
            userPickedSystem = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color.cyan)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(Color.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if system == choice {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var touchPickerList: some View {
        List {
            if step == .router, AutopilotAFMBrain.isSelectable {
                Section {
                    Button {
                        selectAFMRouter()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "apple.intelligence")
                                .foregroundStyle(AutopilotAFMBrain.isAvailableNow ? Color.accentColor : Color.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Intelligence")
                                    .foregroundStyle(Color.primary)
                                Text("Routes on-device. Nothing is sent anywhere to decide.")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let afmUnavailableMessage {
                                    Text(verbatim: afmUnavailableMessage)
                                        .font(.caption)
                                        .foregroundStyle(Color.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if routerKind == .appleFoundationModel {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!AutopilotAFMBrain.isAvailableNow)

                    if routerKind == .appleFoundationModel {
                        touchRouterTestRow
                    }
                } header: {
                    Text("Apple Intelligence (on-device)")
                }
            }
            if AutopilotPCCBrain.isSelectable {
                Section {
                    Button {
                        if step == .router {
                            selectPCCRouter()
                        } else {
                            selectPCCEscalation()
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.icloud")
                                .foregroundStyle(AutopilotPCCBrain.isAvailableNow ? Color.accentColor : Color.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Private Cloud Compute")
                                    .foregroundStyle(Color.primary)
                                Text(
                                    step == .router
                                        ? "Privacy-preserving cloud routing with Apple's smarter model."
                                        : "Apple's smarter privacy-preserving model with 32K context and extended reasoning."
                                )
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                if let pccUnavailableMessage {
                                    Text(verbatim: pccUnavailableMessage)
                                        .font(.caption)
                                        .foregroundStyle(Color.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if (step == .router && routerKind == .privateCloudCompute)
                                || (step == .cloud && escalationTarget == .privateCloudCompute) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if step == .router, routerKind == .privateCloudCompute {
                        touchRouterTestRow
                    }
                } header: {
                    Text("Apple Private Cloud Compute")
                }
            }
            if eligibleBackends.isEmpty {
                Section {
                    Text("No remote endpoints are set up yet. Connect OpenRouter below to get started, or add an endpoint in the Stored tab.")
                        .foregroundStyle(Color.secondary)
                }
                touchConnectOpenRouterSection(prominent: true)
            } else {
                ForEach(eligibleBackends) { backend in
                    Section {
                        Button {
                            toggleExpanded(backend)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: backend.endpointType.symbolName)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: backend.name)
                                        .foregroundStyle(Color.primary)
                                    Text(verbatim: backend.endpointType.displayName)
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                Image(systemName: expandedBackendID == backend.id ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if expandedBackendID == backend.id {
                            let hasModels = hasAnyModelChoices(backend)
                            if hasModels {
                                touchModelSearchField
                                if backendHasPricingData(backend) {
                                    touchPriceFilterChips
                                }
                            }
                            let choices = modelChoices(for: backend)
                            if choices.isEmpty {
                                if hasModels {
                                    Text("No models match your search.")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.secondary)
                                } else {
                                    Text("No models available from this endpoint.")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                            ForEach(choices) { choice in
                                Button {
                                    select(backend, choice)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: choice.name)
                                                .foregroundStyle(Color.primary)
                                            if let metadata = choiceMetadata(choice) {
                                                Text(verbatim: metadata)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(Color.secondary)
                                            }
                                        }
                                        Spacer()
                                        if isSelected(backend, choice) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if step == .router && isSelected(backend, choice) {
                                    touchRouterTestRow
                                }
                            }
                        }
                    }
                }
                if step == .router {
                    Section {
                    } footer: {
                        Text("Cheap and fast is right here — the router only ever answers with a verdict.")
                    }
                }
                touchConnectOpenRouterSection(prominent: false)
            }
        }
    }

    @ViewBuilder
    private var touchRouterTestRow: some View {
        Group {
            switch routerTestPhase {
            case .idle:
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        startRouterTest()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.horizontal.circle")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            Text("Test router")
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if routerTestModelIsPaid {
                        Text("Sends one tiny test request (a fraction of a cent).")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 36)
                    }
                }
            case .testing:
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24)
                    Text("Testing router…")
                        .foregroundStyle(Color.secondary)
                }
            case .success(let latencyMs):
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                        .frame(width: 24)
                    Text("Router responded in \(Self.routerTestSeconds(latencyMs))s")
                        .foregroundStyle(Color.secondary)
                }
            case .failure(let message):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                            .frame(width: 24)
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        startRouterTest()
                    } label: {
                        Text("Try Again")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 36)
                }
            }
        }
        .onAppear { autoRunRouterTestIfFree() }
    }

    private var touchModelSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            TextField("Search models", text: $modelSearchText)
                .platformAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !modelSearchText.isEmpty {
                Button {
                    modelSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
    }

    private var touchPriceFilterChips: some View {
        HStack(spacing: 8) {
            ForEach(PriceFilter.allCases, id: \.self) { filter in
                let selected = priceFilter == filter
                Button {
                    priceFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func touchConnectOpenRouterSection(prominent: Bool) -> some View {
        Section {
            if prominent || connectOpenRouterExpanded {
                SecureField("OpenRouter API key", text: $openRouterKey)
                    .platformAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Link("Create OpenRouter API Key", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.subheadline)
                if let openRouterConnectError {
                    Text(verbatim: openRouterConnectError)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                }
                Button {
                    connectOpenRouter()
                } label: {
                    HStack(spacing: 8) {
                        if isConnectingOpenRouter {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting…")
                        } else {
                            Text("Connect")
                        }
                    }
                }
                .disabled(connectButtonDisabled)
            } else {
                Button {
                    connectOpenRouterExpanded = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        Text("Connect OpenRouter…")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            if prominent {
                Text("Connect OpenRouter")
            }
        } footer: {
            if prominent || connectOpenRouterExpanded {
                Text("One OpenRouter key unlocks hundreds of cloud models. Your key is stored securely on this device.")
            }
        }
    }

    private var touchFooter: some View {
        HStack(spacing: 12) {
            if isFocusedEdit {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    saveFocusedSelection()
                } label: {
                    Text("Save")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!continueEnabled)
            } else if step == .consent {
                Button {
                    goBack()
                } label: {
                    Text("Back")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    saveSelectionsOnly()
                } label: {
                    Text("Not Now")
                }
                .buttonStyle(.bordered)
                Button {
                    turnOnAutopilot()
                } label: {
                    Text("Turn On Autopilot")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
                Spacer()
                if step != .system {
                    Button {
                        goBack()
                    } label: {
                        Text("Back")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    advance()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!continueEnabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

#else

    // MARK: - macOS

    private var macContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Off-Grid / enterprise policy only forbids the cloud paths; the
            // fully local phone-a-friend combination stays available on macOS,
            // so the wizard opens with the cloud choices disabled instead.
            macHeader
            ScrollView {
                macStepContent
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            IndustrialHairline()
            macFooter
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .background(AppTheme.windowBackground)
        .onAppear { enforceRemoteRestrictions() }
    }

    private var macHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isFocusedEdit {
                Text("Step \(stepNumber) of \(stepCount)")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            Text(stepTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.text)
            if let stepCaption {
                Text(stepCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var macStepContent: some View {
        switch step {
        case .system:
            macSystemColumn
        case .router:
            macPickerColumn
        case .cloud:
            macEscalationColumn
        case .consent:
            consentParagraphs
        }
    }

    private var macSystemColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            macSystemChoiceCard(
                .router,
                title: "Smart Router",
                icon: "arrow.triangle.branch",
                detail: smartRouterDetail,
                disabled: remotePathsBlocked && !AutopilotAFMBrain.isSelectable
            )
            macSystemChoiceCard(
                .phoneAFriend,
                title: "Phone a Friend",
                icon: "phone.arrow.up.right",
                detail: "No router. Your on-device model answers everything and calls for the stronger model only when a request is beyond it. Needs a tool-capable local model.",
                disabled: false
            )
            if remotePathsBlocked {
                Text(offGridBlocked
                     ? "Off‑Grid mode is on: cloud routing is unavailable, but a stronger model on this Mac still works."
                     : "Your organization's policy doesn't allow cloud routing, but a stronger model on this Mac still works.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loadedModelToolWarningNeeded {
                Text("The loaded model (\(modelManager.loadedModel?.name ?? "")) can't call tools, so it won't be able to phone a friend. Load a tool-capable model to use this system.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func macSystemChoiceCard(_ choice: AutopilotSystem, title: LocalizedStringKey, icon: String, detail: LocalizedStringKey, disabled: Bool) -> some View {
        Button {
            guard !disabled else { return }
            system = choice
            userPickedSystem = true
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(disabled ? Color.primary.opacity(0.25) : Color.cyan)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(disabled ? 0.35 : 0.85))
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(disabled ? 0.25 : 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if system == choice {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(system == choice ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var macEscalationColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            macEscalationTargetChips
            if escalationTarget == .localModel {
                macLocalEscalationList
            } else if escalationTarget == .privateCloudCompute {
                macPCCCard(forRouter: false)
            } else {
                macPickerColumn
            }
        }
    }

    private var macEscalationTargetChips: some View {
        HStack(spacing: 6) {
            macEscalationTargetChip(.remote, title: "CLOUD", disabled: remotePathsBlocked)
            macEscalationTargetChip(.privateCloudCompute, title: "PRIVATE CLOUD", disabled: remotePathsBlocked || !AutopilotPCCBrain.isSelectable)
            macEscalationTargetChip(.localModel, title: "ON THIS MAC", disabled: false)
            Spacer()
        }
    }

    private func macEscalationTargetChip(_ target: AutopilotEscalationTarget, title: LocalizedStringKey, disabled: Bool) -> some View {
        let selected = escalationTarget == target
        return Button {
            guard !disabled else { return }
            escalationTarget = target
            userPickedTarget = true
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(disabled ? Color.primary.opacity(0.25) : (selected ? Color.accentColor : Color.primary.opacity(0.55)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var macLocalEscalationList: some View {
        let candidates = localEscalationCandidates
        if candidates.isEmpty {
            let emptyMessage: LocalizedStringKey = localEscalationCandidatesBlockedByPolicy
                ? "Blocked by your organization's policy."
                : "No eligible MLX or GGUF models are installed. Download one from Explore, then come back."
            Text(emptyMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if let reference = residentReferenceModel {
                Text("Estimated together with \(reference.name), the model Autopilot rides on. Models that don't fit in memory alongside it can't be selected.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Load a chat model first for an exact estimate — the check below assumes only the stronger model.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if residentReferenceModel?.format == .gguf,
               candidates.contains(where: { $0.format == .gguf }) {
                Text("A GGUF stronger model needs a non-GGUF chat model. Noema keeps one GGUF inference slot so prompt and document caches are reused across turns.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { IndustrialHairline() }
                    macLocalEscalationRow(candidate)
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func macLocalEscalationRow(_ candidate: LocalModel) -> some View {
        let assessment = dualFitAssessment(for: candidate)
        let canCoexist = localCandidateCanCoexist(candidate)
        let selectable = assessment.fits && canCoexist
        return Button {
            selectLocal(candidate)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: candidate.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(selectable ? 0.8 : 0.35))
                        .lineLimit(1)
                    Text(verbatim: "\(candidate.format.rawValue.uppercased()) · \(candidate.quant) · \(dualFitDetail(assessment))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(selectable ? 0.45 : 0.3))
                        .lineLimit(1)
                }
                Spacer()
                if selectable {
                    if isLocalSelected(candidate) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                } else if !canCoexist {
                    Text("ONE GGUF")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.orange.opacity(0.8))
                } else {
                    Text("TOO BIG")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }

    @ViewBuilder
    private var macPickerColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if step == .router, AutopilotAFMBrain.isSelectable {
                macAFMRouterCard
            }
            if step == .router, AutopilotPCCBrain.isSelectable {
                macPCCCard(forRouter: true)
            }
            if step == .router, remotePathsBlocked {
                Text(offGridBlocked
                     ? "Off‑Grid mode is on: cloud routing is unavailable, but a stronger model on this Mac still works."
                     : "Your organization's policy doesn't allow cloud routing, but a stronger model on this Mac still works.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            } else if eligibleBackends.isEmpty {
                Text("No remote endpoints are set up yet. Connect OpenRouter below to get started, or add an endpoint in the Stored tab.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                macConnectOpenRouterCard(prominent: true)
            } else {
                ForEach(eligibleBackends) { backend in
                    macBackendCard(backend)
                }
                macConnectOpenRouterCard(prominent: false)
                if step == .router {
                    Text("Cheap and fast is right here — the router only ever answers with a verdict.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var macAFMRouterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selectAFMRouter()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "apple.intelligence")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AutopilotAFMBrain.isAvailableNow ? Color.cyan : Color.primary.opacity(0.25))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Intelligence")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(AutopilotAFMBrain.isAvailableNow ? 0.85 : 0.4))
                        Text("Routes on-device. Nothing is sent anywhere to decide.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                        if let afmUnavailableMessage {
                            Text(verbatim: afmUnavailableMessage)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if routerKind == .appleFoundationModel {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!AutopilotAFMBrain.isAvailableNow)

            if routerKind == .appleFoundationModel {
                IndustrialHairline()
                macRouterTestRow
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(routerKind == .appleFoundationModel ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func macPCCCard(forRouter: Bool) -> some View {
        let selected = forRouter
            ? routerKind == .privateCloudCompute
            : escalationTarget == .privateCloudCompute
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if forRouter {
                    selectPCCRouter()
                } else {
                    selectPCCEscalation()
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.icloud")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AutopilotPCCBrain.isAvailableNow ? Color.cyan : Color.primary.opacity(0.35))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Private Cloud Compute")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.85))
                        Text(
                            forRouter
                                ? "Privacy-preserving cloud routing with Apple's smarter model."
                                : "32K context · vision · extended reasoning · daily usage limit"
                        )
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        if let pccUnavailableMessage {
                            Text(verbatim: pccUnavailableMessage)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(remotePathsBlocked || !AutopilotPCCBrain.isSelectable)

            if forRouter, routerKind == .privateCloudCompute {
                IndustrialHairline()
                macRouterTestRow
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func macBackendCard(_ backend: RemoteBackend) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpanded(backend)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: backend.endpointType.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: backend.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.85))
                        Text(verbatim: backend.endpointType.displayName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                    Spacer()
                    Image(systemName: expandedBackendID == backend.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedBackendID == backend.id {
                let hasModels = hasAnyModelChoices(backend)
                if hasModels {
                    IndustrialHairline()
                    VStack(alignment: .leading, spacing: 8) {
                        macModelSearchField
                        if backendHasPricingData(backend) {
                            macPriceFilterChips
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                let choices = modelChoices(for: backend)
                if choices.isEmpty {
                    IndustrialHairline()
                    Group {
                        if hasModels {
                            Text("No models match your search.")
                        } else {
                            Text("No models available from this endpoint.")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                ForEach(choices) { choice in
                    IndustrialHairline()
                    Button {
                        select(backend, choice)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: choice.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.primary.opacity(0.8))
                                    .lineLimit(1)
                                if let metadata = choiceMetadata(choice) {
                                    Text(verbatim: metadata)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.primary.opacity(0.45))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if isSelected(backend, choice) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if step == .router && isSelected(backend, choice) {
                        IndustrialHairline()
                        macRouterTestRow
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var macRouterTestRow: some View {
        Group {
            switch routerTestPhase {
            case .idle:
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        startRouterTest()
                    } label: {
                        Text("Test router")
                    }
                    .buttonStyle(.industrial(.quiet))
                    if routerTestModelIsPaid {
                        Text("Sends one tiny test request (a fraction of a cent).")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .testing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Testing router…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
            case .success(let latencyMs):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green)
                    Text("Router responded in \(Self.routerTestSeconds(latencyMs))s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
            case .failure(let message):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.orange)
                        Text(verbatim: message)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        startRouterTest()
                    } label: {
                        Text("Try Again")
                    }
                    .buttonStyle(.industrial(.quiet))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { autoRunRouterTestIfFree() }
    }

    private var macModelSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.45))
            TextField("Search models", text: $modelSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
            if !modelSearchText.isEmpty {
                Button {
                    modelSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var macPriceFilterChips: some View {
        HStack(spacing: 6) {
            ForEach(PriceFilter.allCases, id: \.self) { filter in
                let selected = priceFilter == filter
                Button {
                    priceFilter = filter
                } label: {
                    Text(filter.title)
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.55))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func macConnectOpenRouterCard(prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if prominent {
                HStack(spacing: 10) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .frame(width: 18)
                    Text("Connect OpenRouter")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.85))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            } else {
                Button {
                    connectOpenRouterExpanded.toggle()
                    openRouterConnectError = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .frame(width: 18)
                        Text("Connect OpenRouter…")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.85))
                        Spacer()
                        Image(systemName: connectOpenRouterExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if prominent || connectOpenRouterExpanded {
                IndustrialHairline()
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("OpenRouter API key", text: $openRouterKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Link("Create OpenRouter API Key", destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.system(size: 11))
                    Text("One OpenRouter key unlocks hundreds of cloud models. Your key is stored securely on this device.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                    if let openRouterConnectError {
                        Text(verbatim: openRouterConnectError)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button {
                            connectOpenRouter()
                        } label: {
                            HStack(spacing: 6) {
                                if isConnectingOpenRouter {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Connecting…")
                                } else {
                                    Text("Connect")
                                }
                            }
                        }
                        .buttonStyle(.industrial(.prominent))
                        .disabled(connectButtonDisabled)
                    }
                }
                .padding(12)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var macFooter: some View {
        HStack(spacing: 8) {
            if isFocusedEdit {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.industrial(.quiet))
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    saveFocusedSelection()
                } label: {
                    Text("Save")
                }
                .buttonStyle(.industrial(.prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(!continueEnabled)
            } else if step == .consent {
                Button {
                    goBack()
                } label: {
                    Text("Back")
                }
                .buttonStyle(.industrial(.quiet))
                Spacer()
                Button {
                    saveSelectionsOnly()
                } label: {
                    Text("Not Now")
                }
                .buttonStyle(.industrial(.quiet))
                Button {
                    turnOnAutopilot()
                } label: {
                    Text("Turn On Autopilot")
                }
                .buttonStyle(.industrial(.prominent))
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.industrial(.quiet))
                .keyboardShortcut(.cancelAction)
                Spacer()
                if step != .system {
                    Button {
                        goBack()
                    } label: {
                        Text("Back")
                    }
                    .buttonStyle(.industrial(.quiet))
                }
                Button {
                    advance()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(.industrial(.prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(!continueEnabled)
            }
        }
        .padding(.top, 12)
    }

#endif
}
