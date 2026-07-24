import SwiftUI
import Foundation
import RelayKit
import Combine
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import NoemaPackages
#if canImport(MLX)
import MLX
#endif

#if canImport(UIKit) || os(macOS)
extension ChatVM {
    /// Tool capability for a remote model: the catalog signal is authoritative
    /// when present (OpenRouter); backends without capability metadata stay
    /// permissive — the request-level parameter gate in RemoteChatService
    /// still applies on the wire.
    static func remoteModelSupportsTools(_ model: RemoteModel) -> Bool {
        guard model.supportedParameters != nil else { return true }
        return model.supportsTools
    }

    /// Relay transports can't deliver image bytes end-to-end regardless of
    /// the host model's capability.
    static func remoteEndpointSupportsImages(_ endpointType: RemoteBackend.EndpointType) -> Bool {
        switch endpointType {
        case .noemaRelay, .cloudRelay: return false
        default: return true
        }
    }

    func activateRemoteSession(backend: RemoteBackend, model: RemoteModel, settings: ModelSettings? = nil) async throws {
        // Noema Teams policy: every remote chat session is created here, so this is the
        // single choke point for remote-inference and backend allowlists.
        guard EnterprisePolicyGate.remoteInferenceAllowed else {
            throw RemoteBackendError.validationFailed(String(
                localized: "Remote inference is disabled by your organization's policy.",
                locale: LocalizationManager.preferredLocale()
            ))
        }
        guard EnterprisePolicyGate.allowsRemoteBackend(id: backend.id, endpointType: backend.endpointType) else {
            throw RemoteBackendError.validationFailed(String(
                localized: "This remote backend is not allowed by your organization's policy.",
                locale: LocalizationManager.preferredLocale()
            ))
        }
        if !backend.isCloudRelay {
            guard backend.chatEndpointURL != nil else {
                throw RemoteBackendError.invalidEndpoint
            }
        }
        let modelIdentifier = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelIdentifier.isEmpty else {
            throw RemoteBackendError.validationFailed("Model identifier missing.")
        }

        let resolvedSettings: ModelSettings = {
            if let settings {
                if let manager = modelManager {
                    return manager.clampedRemoteSettings(settings, maxContextLength: model.maxContextLength)
                }
                return settings
            }
            if let manager = modelManager {
                return manager.remoteSettings(for: backend.id, model: model)
            }
            return ModelSettings.default(for: model.compatibilityFormat ?? .gguf)
        }()

        systemPromptToolAvailabilityOverride = nil
        await Self.unloadDetachedClient(detachClientAndUnloadResources())

        // Do NOT clear active dataset when switching to a remote session.
        // RAG injection works with remote backends; keep the user's selection.

        // Preload LM Studio models on "Use" so first chat token doesn't wait on model load.
        // Skip if the selected model is already reported as loaded by the server.
        if backend.endpointType == .lmStudio && !model.isLoadedOnBackend {
            try await RemoteBackendAPI.requestLoad(for: backend, modelID: modelIdentifier, settings: resolvedSettings)
        }

        let defaults = UserDefaults.standard
        let pendingRemoteFormat = model.compatibilityFormat ?? .gguf
        defaults.set(pendingRemoteFormat.rawValue, forKey: "currentModelFormat")
        defaults.set(true, forKey: "currentModelIsRemote")
        defaults.set(Self.remoteModelSupportsTools(model), forKey: "currentModelSupportsFunctionCalling")
        defaults.set(false, forKey: "currentModelSupportsReasoning")
        currentModelSupportsReasoning = false

        let specs = PhoneAFriendGate.strippingHandoff(from: await fetchEnabledToolSpecs())

        let service = RemoteChatService(backend: backend, modelID: modelIdentifier, toolSpecs: specs)
        remoteService = service
        let backendID = backend.id
        await service.setTransportObserver { [weak self] transport, streaming in
            await MainActor.run {
                guard let self else { return }
                self.updateActiveRemoteTransport(for: backendID, transport: transport, streaming: streaming)
            }
        }
#if os(iOS) || os(visionOS)
        await service.setLANRefreshHandler { [weak self] in
            guard let self else { return nil }
            return await self.refreshRelayBackend(backendID: backendID)
        }
#endif
        // Preflight LAN adoption (iOS/visionOS) before establishing UI session state
        var initialLANSSID: String? = nil
#if os(iOS) || os(visionOS)
        initialLANSSID = await service.preflightLANAdoption()
#endif

        activeRemoteBackendID = backend.id
        activeRemoteModelID = modelIdentifier

        do {
        if backend.endpointType == .noemaRelay {
            let containerID = backend.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !containerID.isEmpty else {
                throw RemoteBackendError.validationFailed("Missing CloudKit container identifier for relay.")
            }
            guard let hostDeviceID = backend.relayHostDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !hostDeviceID.isEmpty else {
                throw RemoteBackendError.validationFailed("Missing host device ID for relay.")
            }
            let recordName: String
            if let relayRecord = model.relayRecordName, !relayRecord.isEmpty {
                recordName = relayRecord
            } else if modelIdentifier.hasPrefix("model-") {
                recordName = modelIdentifier
            } else {
                recordName = "model-\(modelIdentifier)"
            }
            let payload: [String: Any] = [
                "modelRef": recordName,
                "ensure": "loaded"
            ]
            let body = try JSONSerialization.data(withJSONObject: payload, options: [])
            let command = try await RelayCatalogClient.shared.createCommand(
                containerIdentifier: containerID,
                hostDeviceID: hostDeviceID,
                verb: "POST",
                path: "/models/activate",
                body: body
            )
            let result = try await RelayCatalogClient.shared.waitForCommand(
                containerIdentifier: containerID,
                commandID: command.recordID,
                // Don't block the UI for minutes. Wait briefly and then
                // allow streaming to proceed; the Mac can finish activation
                // in the background.
                timeout: 25
            )
            if result.state != .succeeded {
                if let data = result.result,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["error"] as? String {
                    throw RemoteBackendError.validationFailed(message)
                }
                throw RemoteBackendError.validationFailed("Relay activation failed.")
            }
        } } catch let relayError as RelayError {
            if case .timeout = relayError {
                // Continue without failing; first message will proceed once the
                // Mac finishes activation. This avoids indefinite spinners.
                await logger.log("[RemoteBackendAPI] ⚠️ Relay activation timed out; continuing without blocking UI.")
            } else {
                throw relayError
            }
        }

        await service.updateConversationID(activeSessionID)
        if backend.endpointType == .noemaRelay {
            await service.updateRelayContainerID(backend.baseURLString)
        } else if backend.endpointType == .cloudRelay {
            let containerID = RelayConfiguration.containerIdentifier
            await service.updateRelayContainerID(containerID)
        } else {
            await service.updateRelayContainerID(nil)
        }

        let textStream: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error> = { [weak self] input in
            guard let self else { return AsyncThrowingStream { continuation in continuation.finish() } }
            guard let remote = await self.remoteService else {
                return AsyncThrowingStream { continuation in continuation.finish() }
            }
            return await remote.stream(for: input)
        }

        client = AnyLLMClient(
            textStream: textStream,
            cancel: { [weak self] in
                Task { await self?.remoteService?.cancelActiveStream() }
            }
        )

        await service.updateToolSpecs(specs)

        loadedFormat = model.compatibilityFormat ?? .gguf
        // Vision rides the OpenAI content-parts shape in RemoteChatService;
        // flipping this on enables the attach button and vision system-prompt
        // guidance for capable remote models. Relay transports can't deliver
        // image bytes (the LAN relay server rejects parts with 400, CloudKit
        // relay strips them), so they never advertise vision.
        supportsImageInput = Self.remoteEndpointSupportsImages(backend.endpointType) && model.isVisionModel
        promptTemplate = nil
        promptTemplateSourceLabel = PromptTemplateSource.defaultTemplate.rawValue
        inferenceBackendSummary = nil
        loadError = nil
        loadedURL = nil
        loadedSettings = resolvedSettings
        modelLoaded = true
        AccessibilityAnnouncer.announceLocalized("Model loaded.")
        currentKind = ModelKind.detect(id: modelIdentifier)
        modelManager?.loadedModel = nil
        // A full remote session and Autopilot are mutually exclusive: Autopilot
        // needs the local model resident, and activation just unloaded it.
        modelManager?.autoRoutingArmed = false
        let defaultTransport: RemoteSessionTransport
        let defaultStreaming: Bool
        switch backend.endpointType {
        case .noemaRelay:
            #if os(iOS) || os(visionOS)
            if let _ = initialLANSSID {
                defaultTransport = .lan(ssid: initialLANSSID ?? "")
            } else {
                defaultTransport = .cloudRelay
            }
            #else
            defaultTransport = .cloudRelay
            #endif
            defaultStreaming = false
        case .cloudRelay:
            defaultTransport = .cloudRelay
            defaultStreaming = false
        default:
            defaultTransport = .direct
            defaultStreaming = true
        }
        modelManager?.activeRemoteSession = ActiveRemoteSession(
            backendID: backend.id,
            backendName: backend.name,
            modelID: modelIdentifier,
            modelName: model.name,
            endpointType: backend.endpointType,
            transport: defaultTransport,
            streamingEnabled: defaultStreaming
        )

        if let fmt = loadedFormat { defaults.set(fmt.rawValue, forKey: "currentModelFormat") }
        defaults.set(true, forKey: "currentModelIsRemote")
        defaults.set(Self.remoteModelSupportsTools(model), forKey: "currentModelSupportsFunctionCalling")
        defaults.set(false, forKey: "currentModelSupportsReasoning")
        currentModelSupportsReasoning = false

        systemPromptToolAvailabilityOverride = toolAvailability(from: specs)

    }

    func refreshActiveRemoteBackendIfNeeded(updatedBackendID: RemoteBackend.ID, activeModelID: String) async throws {
        guard let service = remoteService,
              let currentBackendID = activeRemoteBackendID,
              currentBackendID == updatedBackendID,
              let backend = modelManager?.remoteBackend(withID: updatedBackendID) else {
            return
        }
        await service.updateBackend(backend)
        await service.updateModelID(activeModelID)
        activeRemoteModelID = activeModelID
        let specs = PhoneAFriendGate.strippingHandoff(from: await fetchEnabledToolSpecs())
        await service.updateToolSpecs(specs)
        systemPromptToolAvailabilityOverride = toolAvailability(from: specs)
        if let refreshedModel = backend.cachedModels.first(where: { $0.id == activeModelID }) {
            supportsImageInput = Self.remoteEndpointSupportsImages(backend.endpointType) && refreshedModel.isVisionModel
            UserDefaults.standard.set(Self.remoteModelSupportsTools(refreshedModel),
                                      forKey: "currentModelSupportsFunctionCalling")
        }
#if os(iOS) || os(visionOS)
        requestImmediateLANCheck(reason: "active-backend-refresh")
#endif
    }

#if os(iOS) || os(visionOS)
    func requestImmediateLANCheck(reason: String) {
        Task {
            guard let service = await self.remoteService else { return }
            await service.forceLANRefresh(reason: reason)
        }
    }

    func forceLANOverride(reason: String) {
        Task {
            guard let service = await self.remoteService else { return }
            await service.setLANManualOverride(true, reason: reason)
        }
    }

    private func refreshRelayBackend(backendID: RemoteBackend.ID) async -> RemoteBackend? {
        guard let manager = modelManager else { return nil }
        await manager.fetchRemoteModels(for: backendID)
        return manager.remoteBackend(withID: backendID)
    }
#endif

    private func updateActiveRemoteTransport(for backendID: RemoteBackend.ID,
                                             transport: RemoteSessionTransport,
                                             streaming: Bool) {
        guard let session = modelManager?.activeRemoteSession,
              session.backendID == backendID else {
            return
        }
        modelManager?.activeRemoteSession = ActiveRemoteSession(
            backendID: session.backendID,
            backendName: session.backendName,
            modelID: session.modelID,
            modelName: session.modelName,
            endpointType: session.endpointType,
            transport: transport,
            streamingEnabled: streaming
        )
    }

    func deactivateRemoteSession() {
        let backendID = activeRemoteBackendID
        let modelID = activeRemoteModelID
        var relayContext: (containerID: String, hostDeviceID: String, recordName: String)? = nil
        if let backendID, let modelID,
           let backend = modelManager?.remoteBackend(withID: backendID),
           backend.endpointType == .noemaRelay,
           backend.relayEjectsOnDisconnect {
            let containerID = backend.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            let hostID = backend.relayHostDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !containerID.isEmpty, !hostID.isEmpty {
                let recordName = modelID.hasPrefix("model-") ? modelID : "model-\(modelID)"
                relayContext = (containerID, hostID, recordName)
            }
        }
        if let context = relayContext {
            Task {
                await sendRelayDeactivateCommand(containerID: context.containerID,
                                                 hostDeviceID: context.hostDeviceID,
                                                 recordName: context.recordName)
            }
        }
        Self.beginDetachedClientUnload(detachClientAndUnloadResources())
    }

    private func sendRelayDeactivateCommand(containerID: String, hostDeviceID: String, recordName: String) async {
        let payload: [String: Any] = [
            "modelRef": recordName,
            "ensure": "unloaded"
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        do {
            let command = try await RelayCatalogClient.shared.createCommand(
                containerIdentifier: containerID,
                hostDeviceID: hostDeviceID,
                verb: "POST",
                path: "/models/deactivate",
                body: body
            )
            let result = try await RelayCatalogClient.shared.waitForCommand(
                containerIdentifier: containerID,
                commandID: command.recordID,
                timeout: 60
            )
            if result.state != .succeeded {
                await logger.log("[RemoteBackendAPI] ⚠️ Relay eject returned state=\(result.state.rawValue)")
            }
        } catch {
            await logger.log("[RemoteBackendAPI] ❌ Failed to request relay eject: \(error.localizedDescription)")
        }
    }
}
#endif
