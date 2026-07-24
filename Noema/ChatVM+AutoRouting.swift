import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AutoRoutingStage: Equatable {
    case none
    case deciding
}

#if canImport(UIKit) || os(macOS)

/// Everything one escalated turn needs; discarded when the turn ends.
/// `service`/`backend` are nil when the escalation target is a second local
/// model (macOS) — the client then wraps a resident MLX container or GGUF
/// loopback owned by `AutopilotLocalEscalationRuntime`, not a remote session.
struct TurnEscalation {
    let service: RemoteChatService?
    let client: AnyLLMClient
    let backend: RemoteBackend?
    let modelID: String
    let modelName: String
    let model: RemoteModel?
    let decision: AutoRouteDecision
    let remoteKind: ModelKind
    let settings: ModelSettings
    let hasExplicitRemoteSettings: Bool
    var isLocalTarget: Bool = false
    var isPrivateCloudComputeTarget: Bool = false
    var localTurnToken: UUID? = nil

    var isVisionCapable: Bool {
        isPrivateCloudComputeTarget || model?.isVisionModel == true
    }
}

struct AutoRoutingOutcome {
    var decision: AutoRouteDecision
    var escalation: TurnEscalation?
    var escalationBackendName: String?
    var escalationModelName: String?
    var routerPromptTokens: Int?
    var routerCompletionTokens: Int?
}

extension ChatVM {
    var isAutoRoutingActive: Bool {
        modelManager?.autoRoutingArmed == true && modelLoaded && modelManager?.loadedModel != nil
            && modelManager?.activeRemoteSession == nil
            && activeAppleFoundationModelKind != .privateCloudCompute
    }

    /// Runs the routing pipeline for one turn. Returns nil when Autopilot is
    /// not active for this turn (plain local send).
    func routeCurrentTurnIfNeeded(userMessage: String,
                                  history: [Msg],
                                  imageCount: Int,
                                  documentCount: Int,
                                  documentAccess: DocumentAccessContext = .none) async -> AutoRoutingOutcome? {
        guard !Task.isCancelled else { return nil }
        guard isAutoRoutingActive, let manager = modelManager, let localModel = manager.loadedModel else {
            return nil
        }
        let config = AutopilotConfigStore.load()
        guard config.isReadyToArm else { return nil }
        // Phone-a-friend turns have no pre-turn router: the local model itself
        // asks for the handoff mid-stream (see runPhoneAFriendHandoff).
        guard config.system == .router else { return nil }

        let escalationIsLocal = config.escalationTarget == .localModel
        let escalationUsesPCC = config.escalationTarget == .privateCloudCompute
        let routerBackend = config.routerSelection.flatMap { manager.remoteBackend(withID: $0.backendID) }
        let routerModel: RemoteModel? = config.routerSelection.flatMap { sel in
            routerBackend?.cachedModels.first(where: { $0.id == sel.modelID })
                ?? RemoteModel(id: sel.modelID, name: sel.modelName, author: "")
        }
        let escalationBackend = config.escalationSelection.flatMap { manager.remoteBackend(withID: $0.backendID) }
        let escalationModel: RemoteModel? = config.escalationSelection.flatMap { sel in
            escalationBackend?.cachedModels.first(where: { $0.id == sel.modelID })
                ?? RemoteModel(id: sel.modelID, name: sel.modelName, author: "")
        }
        let usableEscalationBackend = (escalationBackend?.isCloudRelay == false) ? escalationBackend : nil

        let gates = PolicyGates(
            offGrid: UserDefaults.standard.bool(forKey: "offGrid") || EnterprisePolicyGate.requiresOffGrid,
            offline: !NetworkReachability.shared.isOnline,
            killSwitch: NetworkKillSwitch.isEnabled,
            enterpriseRemoteAllowed: EnterprisePolicyGate.remoteInferenceAllowed,
            enterpriseAllowsRouterBackend: config.routerKind == .privateCloudCompute
                ? EnterprisePolicyGate.remoteInferenceAllowed
                : (routerBackend.map {
                    EnterprisePolicyGate.allowsRemoteBackend(id: $0.id, endpointType: $0.endpointType)
                } ?? false),
            enterpriseAllowsEscalationBackend: escalationUsesPCC
                ? EnterprisePolicyGate.remoteInferenceAllowed
                : (usableEscalationBackend.map {
                    EnterprisePolicyGate.allowsRemoteBackend(id: $0.id, endpointType: $0.endpointType)
                } ?? false),
            escalationIsLocal: escalationIsLocal
        )

        let inputs = buildAutoRouteInputs(
            userMessage: userMessage,
            history: history,
            localModel: localModel,
            escalationModel: escalationModel,
            escalationSelection: config.escalationSelection,
            localEscalation: escalationIsLocal ? config.localEscalation : nil,
            privateCloudEscalation: escalationUsesPCC,
            imageCount: imageCount,
            documentCount: documentCount,
            documentAccess: documentAccess
        )

        var decision: AutoRouteDecision
        var routerPromptTokens: Int?
        var routerCompletionTokens: Int?
        if let forced = pendingForcedRoute {
            pendingForcedRoute = nil
            var d = AutoRouteDecision.forced(forced, reasonKey: AutopilotReasonKey.userOverride)
            d.reason = AutopilotReasonKey.localized(AutopilotReasonKey.userOverride)
            decision = d
        } else {
            let targets = AutopilotResolvedTargets(
                routerBackend: routerBackend,
                routerModel: routerModel,
                escalationBackend: usableEscalationBackend,
                escalationModel: escalationModel,
                localEscalation: escalationIsLocal ? config.localEscalation : nil
            )
            let result = await AutopilotRouter.shared.decide(inputs, config: config, targets: targets, gates: gates)
            guard !Task.isCancelled else { return nil }
            decision = result.decision
            routerPromptTokens = result.routerPromptTokens
            routerCompletionTokens = result.routerCompletionTokens
            AutopilotLedger.shared.recordRouterSpend(
                promptTokens: result.routerPromptTokens,
                completionTokens: result.routerCompletionTokens,
                promptPricePerMillion: routerModel?.promptPricePerMillion,
                completionPricePerMillion: routerModel?.completionPricePerMillion
            )
        }

        var outcome = AutoRoutingOutcome(
            decision: decision,
            escalation: nil,
            escalationBackendName: escalationIsLocal || escalationUsesPCC
                ? nil
                : config.escalationSelection?.backendName,
            escalationModelName: escalationIsLocal
                ? config.localEscalation?.name
                : (escalationUsesPCC
                    ? AppleFoundationModelKind.privateCloudCompute.modelName
                    : config.escalationSelection?.modelName),
            routerPromptTokens: routerPromptTokens,
            routerCompletionTokens: routerCompletionTokens
        )

        if decision.target == .cloud, escalationIsLocal {
            guard !Task.isCancelled else { return nil }
            if let escalation = await prepareLocalTurnEscalation(decision: decision) {
                guard !Task.isCancelled else {
                    releaseLocalEscalationTurn(escalation)
                    return nil
                }
                outcome.escalation = escalation
            } else {
                outcome.decision.target = .local
                outcome.decision.reasonKey = AutopilotReasonKey.noEscalationTarget
                outcome.decision.reason = AutopilotReasonKey.localized(AutopilotReasonKey.noEscalationTarget)
            }
        } else if decision.target == .cloud, escalationUsesPCC {
            guard !Task.isCancelled else { return nil }
            if let escalation = await preparePrivateCloudTurnEscalation(decision: decision) {
                outcome.escalation = escalation
            } else {
                outcome.decision.target = .local
                outcome.decision.reasonKey = AutopilotReasonKey.noEscalationTarget
                outcome.decision.reason = AutopilotReasonKey.localized(AutopilotReasonKey.noEscalationTarget)
            }
        } else if decision.target == .cloud,
           let backend = usableEscalationBackend,
           let selection = config.escalationSelection {
            guard !Task.isCancelled else { return nil }
            if let escalation = await prepareTurnEscalation(
                backend: backend,
                modelID: selection.modelID,
                modelName: selection.modelName,
                model: escalationModel,
                decision: decision
            ) {
                guard !Task.isCancelled else { return nil }
                outcome.escalation = escalation
                outcome.escalationBackendName = backend.name
            } else {
                outcome.decision.target = .local
                outcome.decision.reasonKey = AutopilotReasonKey.noEscalationTarget
                outcome.decision.reason = AutopilotReasonKey.localized(AutopilotReasonKey.noEscalationTarget)
            }
        }
        return outcome
    }

    func prepareTurnEscalation(backend: RemoteBackend,
                               modelID: String,
                               modelName: String,
                               model: RemoteModel?,
                               decision: AutoRouteDecision) async -> TurnEscalation? {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty, backend.chatEndpointURL != nil else { return nil }

        let settings: ModelSettings = {
            if let manager = modelManager, let model {
                return manager.remoteSettings(for: backend.id, model: model)
            }
            return ModelSettings.default(for: .gguf)
        }()
        let hasExplicit = modelManager?.hasSavedRemoteSettings(for: backend.id, modelID: trimmedModelID) == true

        // The stronger model must never see the phone-a-friend tool — it IS
        // the friend, and advertising it would let escalations recurse.
        let specs = PhoneAFriendGate.strippingHandoff(from: await fetchEnabledToolSpecs())
        let service = RemoteChatService(backend: backend, modelID: trimmedModelID, toolSpecs: specs)
        await service.updateConversationID(activeSessionID)
        await service.updateRelayContainerID(nil)
        await service.updateToolSpecs(specs)

        let client = AnyLLMClient(
            textStream: { input in await service.stream(for: input) },
            cancel: { Task { await service.cancelActiveStream() } }
        )

        return TurnEscalation(
            service: service,
            client: client,
            backend: backend,
            modelID: trimmedModelID,
            modelName: modelName,
            model: model,
            decision: decision,
            remoteKind: ModelKind.detect(id: trimmedModelID),
            settings: settings,
            hasExplicitRemoteSettings: hasExplicit
        )
    }

    func preparePrivateCloudTurnEscalation(decision: AutoRouteDecision) async -> TurnEscalation? {
        guard ApplePrivateCloudComputeAvailability.isAvailableNow else { return nil }
        let modelID = AppleFoundationModelKind.privateCloudCompute.modelID
        let storedModel = modelManager?.downloadedModels.first { $0.modelID == modelID }
        var settings: ModelSettings
        if let storedModel, let modelManager {
            settings = modelManager.settings(for: storedModel)
        } else {
            settings = ModelSettings.default(for: .afm)
        }
        settings.contextLength = Double(AppleFoundationModelKind.privateCloudContextLimit)
        let client = AFMLLMClient(
            modelKind: .privateCloudCompute,
            guardrailsMode: AFMLLMClient.resolvedGuardrailsMode(from: settings),
            pccReasoningLevel: settings.pccReasoningLevel
        )
        do {
            try await client.load()
        } catch {
            return nil
        }
        return TurnEscalation(
            service: nil,
            client: AnyLLMClient(
                textStream: { input in
                    try await client.textStream(from: input)
                },
                cancel: { client.cancelActive() },
                unload: { client.unload() },
                syncSystemPrompt: { prompt in
                    await client.syncSystemPrompt(prompt)
                }
            ),
            backend: nil,
            modelID: modelID,
            modelName: AppleFoundationModelKind.privateCloudCompute.modelName,
            model: nil,
            decision: decision,
            remoteKind: ModelKind.detect(id: modelID),
            settings: settings,
            hasExplicitRemoteSettings: storedModel != nil,
            isPrivateCloudComputeTarget: true
        )
    }

    /// Escalation onto the second resident local model (macOS). The client is
    /// owned by `AutopilotLocalEscalationRuntime` and survives across turns —
    /// only the TurnEscalation wrapper is per-turn.
    func prepareLocalTurnEscalation(decision: AutoRouteDecision) async -> TurnEscalation? {
        #if os(macOS)
        guard let manager = modelManager else { return nil }
        let acquisitionRunID = activeRunIDForAutopilot
        let config = AutopilotConfigStore.load()
        guard config.escalationTarget == .localModel,
              config.localEscalation != nil else { return nil }
        guard let acquired = await AutopilotLocalEscalationRuntime.shared.acquireTurn(manager: manager) else {
            return nil
        }
        guard !Task.isCancelled, acquisitionRunID == activeRunIDForAutopilot else {
            AutopilotLocalEscalationRuntime.shared.endTurn(token: acquired.token)
            return nil
        }
        let selection = acquired.selection
        let resolvedModel = AutopilotLocalEscalationRuntime.resolveModel(
            for: selection,
            in: manager.downloadedModels
        )
        var settings = resolvedModel.map { manager.settings(for: $0) }
            ?? ModelSettings.default(for: selection.format)
        settings.contextLength = Double(max(512, selection.contextLength))
        return TurnEscalation(
            service: nil,
            client: acquired.client,
            backend: nil,
            modelID: selection.modelID,
            modelName: selection.name,
            model: nil,
            decision: decision,
            remoteKind: ModelKind.detect(id: selection.name),
            settings: settings,
            hasExplicitRemoteSettings: false,
            isLocalTarget: true,
            localTurnToken: acquired.token
        )
        #else
        return nil
        #endif
    }

    /// Prepares the escalation for a phone-a-friend handoff (either target).
    /// Policy gates are re-checked here because the tool call happens well
    /// after advertisement — offGrid/kill-switch may have flipped since.
    func preparePhoneAFriendEscalation(reason: String) async -> TurnEscalation? {
        let config = AutopilotConfigStore.load()
        guard config.enabled, config.system == .phoneAFriend, config.isReadyToArm else { return nil }

        var decision = AutoRouteDecision(
            target: .cloud,
            confidence: 1.0,
            reason: reason.isEmpty ? AutopilotReasonKey.localized(AutopilotReasonKey.phoneAFriend) : reason,
            reasonKey: AutopilotReasonKey.phoneAFriend,
            category: nil,
            estDifficulty: 4,
            latencyMs: 0,
            decidedBy: .phoneAFriend
        )
        if !reason.isEmpty {
            // Keep the model's own justification visible in the receipt while
            // the localized key still drives fallback wording.
            decision.reason = reason
        }

        // "Pause cloud escalation" withholds the hand-off in both targets.
        guard !config.pauseCloudEscalation else { return nil }

        switch config.escalationTarget {
        case .localModel:
            return await prepareLocalTurnEscalation(decision: decision)
        case .privateCloudCompute:
            if activeSessionRetrievalDataset != nil && !config.allowCloudForRAGTurns {
                return nil
            }
            return await preparePrivateCloudTurnEscalation(decision: decision)
        case .remote:
            // Knowledge-base chats must not reach a cloud model unless the user
            // opted in — mirror the router's ragPrivacy gate.
            if activeSessionRetrievalDataset != nil && !config.allowCloudForRAGTurns {
                return nil
            }
            guard !UserDefaults.standard.bool(forKey: "offGrid"),
                  !EnterprisePolicyGate.requiresOffGrid,
                  NetworkReachability.shared.isOnline,
                  !NetworkKillSwitch.isEnabled,
                  EnterprisePolicyGate.remoteInferenceAllowed,
                  let manager = modelManager,
                  let selection = config.escalationSelection,
                  let backend = manager.remoteBackend(withID: selection.backendID),
                  backend.isCloudRelay == false,
                  EnterprisePolicyGate.allowsRemoteBackend(id: backend.id, endpointType: backend.endpointType) else {
                return nil
            }
            let model = backend.cachedModels.first(where: { $0.id == selection.modelID })
                ?? RemoteModel(id: selection.modelID, name: selection.modelName, author: "")
            return await prepareTurnEscalation(
                backend: backend,
                modelID: selection.modelID,
                modelName: selection.modelName,
                model: model,
                decision: decision
            )
        }
    }

    /// Escalated prompts must not carry the local model's chat-template markup:
    /// the remote endpoint applies its own template server-side, so the prompt
    /// is built template-free with the remote model's family, exactly like a
    /// full remote session (which sets promptTemplate = nil on activation).
    func buildPromptForEscalatedTurn(kind: ModelKind, history: [Msg], systemPromptOverride: String? = nil) -> (String, [String], Int?) {
        let savedTemplate = promptTemplate
        let savedKind = currentKind
        promptTemplate = nil
        currentKind = kind
        defer {
            promptTemplate = savedTemplate
            currentKind = savedKind
        }
        return buildPrompt(kind: kind, history: history, systemPromptOverride: systemPromptOverride)
    }

    private func buildAutoRouteInputs(userMessage: String,
                                      history: [Msg],
                                      localModel: LocalModel,
                                      escalationModel: RemoteModel?,
                                      escalationSelection: StartupPreferences.RemoteSelection?,
                                      localEscalation: AutopilotLocalEscalationSelection? = nil,
                                      privateCloudEscalation: Bool = false,
                                      imageCount: Int,
                                      documentCount: Int,
                                      documentAccess: DocumentAccessContext = .none) -> AutoRouteInputs {
        let priorAssistant = history.filter { $0.role == "🤖" }
        let priorLocal = priorAssistant.filter { $0.route?.answerTarget == .local }.count
        let priorCloud = priorAssistant.filter { $0.route?.answerTarget == .cloud }.count
        // The route that produced the newest visible answer; a cloud verdict
        // that fell back pre-first-token was answered locally.
        let lastRoute: AutoRouteTarget? = priorAssistant.reversed().lazy
            .compactMap { msg -> AutoRouteTarget? in
                guard let record = msg.route else { return nil }
                return record.answerTarget
            }
            .first
        let previousUser = history.filter { $0.role == "🧑‍💻" }.dropLast().last?.text

        // EWMA over the most recent local-turn speeds so the router brain sees
        // the RESIDENT model's measured throughput. Exclude escalated turns:
        // remote turns (usedRemoteBackend) and local-escalation turns (a
        // different, stronger resident model, route == .cloud) both ran on
        // something other than the model the router rides on. Pre-first-token
        // fallbacks kept (they ran on the resident model → fellBackToLocal).
        var speed: Double?
        for msg in priorAssistant.suffix(10) where msg.usedRemoteBackend != true {
            if let record = msg.route, record.target == .cloud, !record.fellBackToLocal { continue }
            guard let tps = msg.perf?.avgTokPerSec, tps > 0 else { continue }
            speed = speed.map { $0 * 0.7 + tps * 0.3 } ?? tps
        }

        let moeSummary: String? = localModel.moeInfo.flatMap { moe in
            guard moe.isMoE, moe.expertCount > 0 else { return nil }
            if let used = moe.defaultUsed, used > 0 {
                return "\(used) of \(moe.expertCount) experts active per token"
            }
            return "\(moe.expertCount) experts"
        }
        let card = LocalModelCard(
            name: localModel.name,
            format: localModel.format,
            sizeGB: localModel.sizeGB,
            quant: localModel.quant,
            parameterLabel: Self.routerParameterLabel(for: localModel),
            contextLength: Int(contextLimit),
            isToolCapable: localModel.isToolCapable,
            isMultimodal: localModel.isMultimodal,
            moeSummary: moeSummary,
            recentAvgTokPerSec: speed
        )
        let cloudCard: EscalationModelCard
        if let localEscalation {
            // Image turns remain on the resident model.
            cloudCard = EscalationModelCard(
                name: localEscalation.name,
                contextLength: localEscalation.contextLength,
                promptPricePerMillion: nil,
                completionPricePerMillion: nil,
                isVisionCapable: false
            )
        } else if privateCloudEscalation {
            cloudCard = EscalationModelCard(
                name: AppleFoundationModelKind.privateCloudCompute.modelName,
                contextLength: AppleFoundationModelKind.privateCloudContextLimit,
                promptPricePerMillion: nil,
                completionPricePerMillion: nil,
                isVisionCapable: true
            )
        } else {
            cloudCard = EscalationModelCard(
                name: escalationModel?.name ?? escalationSelection?.modelName ?? "",
                contextLength: escalationModel?.maxContextLength,
                promptPricePerMillion: escalationModel?.promptPricePerMillion,
                completionPricePerMillion: escalationModel?.completionPricePerMillion,
                isVisionCapable: escalationModel?.isVisionModel ?? false
            )
        }

        var battery: Float = -1
        var charging = false
#if os(iOS) || os(visionOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        battery = UIDevice.current.batteryLevel
        charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
#endif

        // Routing needs only a conservative size signal, not a second full
        // chat-template render. Rebuilding the complete prompt here used to run
        // twice on MainActor and could visibly freeze long conversations before
        // the AFM request even began.
        let historyTokens = history.reduce(0) { total, message in
            guard message.role.lowercased() != "system" else { return total }
            var serializedTokens = estimateTokensSync(message.text)
            if let toolResults = message.toolCalls?.compactMap(\.result), !toolResults.isEmpty {
                serializedTokens = Self.saturatingTokenAdd(
                    serializedTokens,
                    estimateTokensSync(toolResults.joined(separator: "\n"))
                )
            }
            if let retrieved = message.retrievedContext, !retrieved.isEmpty {
                serializedTokens = Self.saturatingTokenAdd(
                    serializedTokens,
                    estimateTokensSync(retrieved)
                )
            }
            let tokens = max(message.perf?.tokenCount ?? 0, serializedTokens)
            return Self.saturatingTokenAdd(total, max(0, tokens))
        }
        let overhead = promptOverheadBreakdown()
        let fixedOverhead = Self.saturatingTokenAdd(
            Self.saturatingTokenAdd(overhead.system, overhead.tools),
            history.count * 12 // role separators and chat-template control tokens
        )
        let promptTokens = Self.saturatingTokenAdd(
            historyTokens,
            fixedOverhead
        )

        return AutoRouteInputs(
            userMessage: userMessage,
            previousUserMessage: previousUser,
            conversationTurnCount: history.count,
            historyTokenEstimate: historyTokens,
            priorLocalRoutes: priorLocal,
            priorCloudRoutes: priorCloud,
            lastRoute: lastRoute,
            localModel: card,
            escalationModel: cloudCard,
            hasImages: imageCount > 0,
            imageCount: imageCount,
            documentCount: documentCount,
            ragArmed: activeSessionRetrievalDataset != nil,
            webSearchArmed: SettingsStore.shared.webSearchArmed,
            pythonArmed: SettingsStore.shared.pythonArmed,
            promptTokenEstimate: promptTokens,
            batteryLevel: battery,
            isCharging: charging,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            documentAccess: documentAccess
        )
    }

    /// Older installs predate the download-time parameter label; the
    /// size-in-name convention ("Qwen3.6-27B") is a near-universal fallback.
    static func routerParameterLabel(for model: LocalModel) -> String {
        if let label = model.parameterCountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        let pattern = #"(\d+(?:\.\d+)?)\s*[bB]\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(model.name.startIndex..., in: model.name)
        guard let match = regex.matches(in: model.name, range: range).last,
              let numberRange = Range(match.range(at: 1), in: model.name) else { return "" }
        return "\(model.name[numberRange])B"
    }

    /// Message-array form of an escalated turn. Local escalation clients apply
    /// the stronger model's own template, while remote chat endpoints serialize
    /// these roles directly instead of wrapping a flattened transcript in a new
    /// user message. RAG context rides in the final user turn.
    func escalationChatMessages(history: [Msg], systemPrompt: String, retrievedContext: String? = nil) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var pendingToolCallIDs: [String] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            messages.append(ChatMessage(role: "system", content: trimmedSystem))
        }
        for msg in historyWithReconstructedToolMessages(history) {
            let role: String
            switch msg.role.lowercased() {
            case "user", "🧑‍💻": role = "user"
            case "assistant", "🤖": role = "assistant"
            case "tool": role = "tool"
            case "system": continue // the leading system prompt above wins
            default: role = "user"
            }
            let text = msg.text
                .replacingOccurrences(of: noemaToolAnchorToken, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCalls = role == "assistant"
                ? serializedLoopbackToolCalls(from: msg.toolCalls)
                : nil
            if role == "assistant", let calls = msg.toolCalls {
                pendingToolCallIDs.append(contentsOf: calls.map(resolvedLoopbackToolCallID))
            }
            let toolCallID: String? = {
                guard role == "tool", !pendingToolCallIDs.isEmpty else { return nil }
                return pendingToolCallIDs.removeFirst()
            }()
            // Keep content-empty assistant messages when they carry native tool
            // calls; the OpenAI transcript requires that message to pair with the
            // following role:"tool" result.
            if text.isEmpty, toolCalls?.isEmpty ?? true, role != "tool" { continue }
            messages.append(
                ChatMessage(
                    role: role,
                    content: text,
                    toolCalls: toolCalls,
                    toolCallId: toolCallID
                )
            )
        }
        if let retrievedContext = retrievedContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !retrievedContext.isEmpty,
           let lastUser = messages.lastIndex(where: { $0.role == "user" }) {
            let existing = messages[lastUser].content
            messages[lastUser] = ChatMessage(
                role: "user",
                content: "Relevant context:\n\(retrievedContext)\n\n\(existing)",
                toolCalls: messages[lastUser].toolCalls,
                toolCallId: messages[lastUser].toolCallId
            )
        }
        return messages
    }

    /// Execution-time gate for a phone-a-friend hand-off request emitted by the
    /// local model. Centralizes every per-turn condition so the TOOL_CALL,
    /// embedded-prose, and end-of-stream intercept sites stay consistent:
    /// the static availability gate, the placeholder-reason guard (models echo
    /// the tool's own example text), and — for a REMOTE stronger model — the
    /// knowledge-base privacy gate (KB chats must not leave the device unless
    /// the user opted in).
    func phoneAFriendHandoffAllowedNow(reason: String) -> Bool {
        guard PhoneAFriendGate.isAvailable() else { return false }
        guard PhoneAFriendGate.isGenuineHandoffReason(reason) else { return false }
        let config = AutopilotConfigStore.load()
        if config.escalationTarget != .localModel,
           activeSessionRetrievalDataset != nil,
           !config.allowCloudForRAGTurns {
            return false
        }
        return true
    }

    /// Releases only the exact token carried by this escalation. Stale async
    /// completions therefore cannot clear a newer turn's guard.
    func releaseLocalEscalationTurn(_ escalation: TurnEscalation?) {
        guard let token = escalation?.localTurnToken else { return }
        #if os(macOS)
        AutopilotLocalEscalationRuntime.shared.endTurn(token: token)
        #endif
    }

    /// "Redo On-Device" / "Redo on Cloud": regenerates the answer with the
    /// route pinned; the router is bypassed and the receipt says so.
    func reroute(messageID: UUID, target: AutoRouteTarget) async {
        pendingForcedRoute = target
        AutopilotLedger.shared.recordOverride()
        await regenerateAssistantResponse(messageID: messageID)
    }
}

#endif
