import Foundation
import RelayKit

private enum RelayLANRefreshConstants {
    // Reduce chatter and avoid long UI "Trying to connect" stalls.
    // Throttle how often we ask the Mac to refresh LAN status,
    // and tighten the timeout so we don't block on minute-long waits.
    static let throttle: TimeInterval = 45
    static let timeout: TimeInterval = 12
    static let timeoutRetryDelay: TimeInterval = 0
}

@MainActor
extension AppModelManager {
    // Track LAN refresh attempts per backend during the app session (MainActor-isolated for safety).
    private static var lanRefreshPerformed: Set<RemoteBackend.ID> = []
    func remoteBackend(withID id: RemoteBackend.ID) -> RemoteBackend? {
        remoteBackends.first { $0.id == id }
    }

    /// Remote backends the active Noema Teams policy permits (everything, when no
    /// workspace is connected). UI lists use this to grey out blocked backends;
    /// execution is independently guarded in ChatVM.activateRemoteSession.
    var policyAllowedRemoteBackends: [RemoteBackend] {
        remoteBackends.filter {
            EnterprisePolicyGate.allowsRemoteBackend(id: $0.id, endpointType: $0.endpointType)
        }
    }

    func isRemoteBackendAllowedByPolicy(_ backend: RemoteBackend) -> Bool {
        EnterprisePolicyGate.allowsRemoteBackend(id: backend.id, endpointType: backend.endpointType)
    }

    func setLMStudioRemoteDownloadTarget(_ backendID: RemoteBackend.ID?) {
        guard let backendID else {
            activeLMStudioRemoteDownloadTargetID = nil
            return
        }
        guard let backend = remoteBackends.first(where: { $0.id == backendID }),
              backend.endpointType == .lmStudio else {
            activeLMStudioRemoteDownloadTargetID = nil
            return
        }
        activeLMStudioRemoteDownloadTargetID = backend.id
    }

    func clearLMStudioRemoteDownloadTarget() {
        activeLMStudioRemoteDownloadTargetID = nil
    }

    func refreshRemoteBackends(offGrid: Bool) {
        guard !offGrid else { return }
        for backend in remoteBackends {
            guard isRemoteBackendAllowedByPolicy(backend) else { continue }
            Task { [weak self] in
                await self?.fetchRemoteModels(for: backend.id)
            }
        }
    }

    func addRemoteBackend(from draft: RemoteBackendDraft) async throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw RemoteBackendError.validationFailed(String(localized: "Please provide a backend name."))
        }
        if remoteBackends.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw RemoteBackendError.validationFailed(String(localized: "A backend with this name already exists."))
        }
        await LocalNetworkPermissionRequester.shared.ensurePrompt()
        let backend = try RemoteBackend(from: draft)
        if let duplicateMessage = duplicateRelayDeviceMessage(for: backend) {
            throw RemoteBackendError.validationFailed(duplicateMessage)
        }
        try await prepareCredentials(for: backend, draft: draft, existing: nil)
        remoteBackends.append(backend)
        remoteBackends.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistRemoteBackends()
        normalizeLMStudioRemoteDownloadTargetIfNeeded()
        await fetchRemoteModels(for: backend.id)
    }

    func deleteRemoteBackend(id: RemoteBackend.ID) {
        if let index = remoteBackends.firstIndex(where: { $0.id == id }) {
            let backend = remoteBackends[index]
            if backend.endpointType == .openRouter {
                try? RemoteBackendCredentialStore.removeOpenRouterAPIKey(for: backend.id)
            }
            remoteBackends.remove(at: index)
            persistRemoteBackends()
        }
        clearRemoteSettings(for: id)
        clearOpenRouterFavorites(for: id)
        remoteBackendsFetching.remove(id)
        StartupPreferencesStore.removeRemoteSelections(for: id)
        var autopilotConfig = AutopilotConfigStore.load()
        var autopilotConfigChanged = false
        if autopilotConfig.routerSelection?.backendID == id {
            autopilotConfig.routerSelection = nil
            autopilotConfigChanged = true
        }
        if autopilotConfig.escalationSelection?.backendID == id {
            autopilotConfig.escalationSelection = nil
            autopilotConfigChanged = true
        }
        if autopilotConfigChanged {
            AutopilotConfigStore.save(autopilotConfig)
        }
        if activeRemoteSession?.backendID == id {
            activeRemoteSession = nil
        }
        normalizeLMStudioRemoteDownloadTargetIfNeeded()
    }

    func updateRemoteBackend(id: RemoteBackend.ID, using draft: RemoteBackendDraft) async throws {
        guard let index = remoteBackends.firstIndex(where: { $0.id == id }) else {
            throw RemoteBackendError.validationFailed(String(localized: "Backend not found."))
        }
        let existing = remoteBackends[index]
        let updated = try existing.updating(from: draft)
        if let duplicateMessage = duplicateRelayDeviceMessage(for: updated, excluding: existing.id) {
            throw RemoteBackendError.validationFailed(duplicateMessage)
        }
        try await prepareCredentials(for: updated, draft: draft, existing: existing)
        remoteBackends[index] = updated
        remoteBackends.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistRemoteBackends()
        StartupPreferencesStore.updateRemoteBackend(updated)
        if activeRemoteSession?.backendID == id {
            let previous = activeRemoteSession
            activeRemoteSession = ActiveRemoteSession(
                backendID: updated.id,
                backendName: updated.name,
                modelID: previous?.modelID ?? "",
                modelName: previous?.modelName ?? "",
                endpointType: updated.endpointType,
                transport: previous?.transport ?? .direct,
                streamingEnabled: previous?.streamingEnabled ?? true
            )
        }
        normalizeLMStudioRemoteDownloadTargetIfNeeded()
    }

    func fetchRemoteModels(for backendID: RemoteBackend.ID) async {
        guard let backend = remoteBackends.first(where: { $0.id == backendID }) else { return }
        guard isRemoteBackendAllowedByPolicy(backend) else { return }
        if remoteBackendsFetching.contains(backendID) { return }
        remoteBackendsFetching.insert(backendID)
        defer { remoteBackendsFetching.remove(backendID) }
        do {
            let previousLAN = backend.relayLANURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousSSID = backend.relayWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await RemoteBackendAPI.fetchModels(for: backend)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let timestamp = Date()
            let summary = RemoteBackend.ConnectionSummary.success(
                statusCode: result.statusCode,
                reason: result.reason,
                timestamp: timestamp
            )
            let trimmedLAN = result.relayLANURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSSID = result.relayWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lanURLUpdate: String??
            let wifiSSIDUpdate: String??
            let interfaceUpdate: RelayLANInterface??
            if backend.endpointType == .noemaRelay {
                if result.lanMetadataProvided {
                    lanURLUpdate = .some(trimmedLAN)
                    wifiSSIDUpdate = .some(trimmedSSID)
                    interfaceUpdate = .some(result.relayLANInterface)
                } else {
                    // Preserve previously known LAN metadata when the relay
                    // snapshot omits capabilities. This lets iOS continue to
                    // probe and adopt LAN based on reachability/same‑subnet
                    // without waiting for CloudKit commands to succeed.
                    lanURLUpdate = nil
                    wifiSSIDUpdate = nil
                    interfaceUpdate = nil
                }
            } else {
                if result.lanMetadataProvided {
                    lanURLUpdate = .some(trimmedLAN)
                    wifiSSIDUpdate = .some(trimmedSSID)
                    interfaceUpdate = .some(result.relayLANInterface)
                } else {
                    lanURLUpdate = nil
                    wifiSSIDUpdate = nil
                    interfaceUpdate = nil
                }
            }
            updateRemoteBackend(
                backendID: backendID,
                with: result.models,
                error: nil,
                summary: summary,
                relayEjectsOnDisconnect: result.relayEjectsOnDisconnect,
                relayHostStatus: result.relayHostStatus,
                relayLANURL: lanURLUpdate,
                relayWiFiSSID: wifiSSIDUpdate,
                relayAPIToken: .some(result.relayAPIToken),
                relayLANInterface: interfaceUpdate
            )
            // Run a same-subnet adoption check immediately on endpoint load/reload
            // so the familiar "Same-subnet match …; using LAN" message appears
            // even before a chat session is started.
#if os(iOS) || os(visionOS)
            if backend.endpointType == .noemaRelay,
               let updated = remoteBackends.first(where: { $0.id == backendID }),
               updated.relayLANChatEndpointURL != nil,
               (updated.relayWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false),
               let host = updated.relayLANChatEndpointURL?.host,
               LANSubnet.isSameSubnet(host: host) {
                await logger.log("[RemoteChat] [LAN] Same-subnet match for '\(updated.name)' (host=\(host)); using LAN")
            }
#endif
            // If this is a Noema Relay and we already have a cached LAN URL,
            // perform a one-time early LAN health probe on iOS to surface
            // connectivity logs before the user loads a model.
#if os(iOS) || os(visionOS)
            if backend.endpointType == .noemaRelay,
               !lanInitialProbePerformed.contains(backendID),
               let updated = remoteBackends.first(where: { $0.id == backendID }),
               updated.relayLANChatEndpointURL != nil {
                lanInitialProbePerformed.insert(backendID)
                Task { [weak self] in
                    await self?.performInitialLANHealthProbeIfCached(for: backendID)
                }
            }
#endif
            if backend.endpointType == .noemaRelay {
                // Only force a LAN refresh if we previously had LAN metadata
                // and it has now disappeared (likely stale cache to clear).
                let hadPreviousLAN = (previousLAN?.isEmpty == false) || (previousSSID?.isEmpty == false)
                let shouldForceRefresh = hadPreviousLAN && (trimmedLAN == nil)
                if !Self.lanRefreshPerformed.contains(backendID) {
                    Self.lanRefreshPerformed.insert(backendID)
                    await requestRelayLANRefresh(for: backendID,
                                                 reason: "models-refresh",
                                                 force: shouldForceRefresh)
                    if shouldForceRefresh,
                       previousLAN != nil,
                       trimmedLAN == nil {
                        await logger.log("[RemoteBackendAPI] [LAN] Cleared stale LAN metadata for '\(backend.name)' (previousLAN=\(previousLAN ?? "nil"), previousSSID=\(previousSSID ?? "nil")).")
                    }
                }

#if os(iOS) || os(visionOS)
                // Bonjour fallback: if no LAN URL is currently known, try to discover
                // a running Noema relay on the local network and adopt it immediately.
                let hasLAN = (remoteBackends.first { $0.id == backendID })?.relayLANURLString?.isEmpty == false
                if !hasLAN {
                    Task { [weak self] in
                        if let url = await LANServiceDiscovery.shared.discoverNoemaLANURL(timeout: 2.5),
                           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await logger.log("[RemoteBackend] [LAN] Bonjour discovered relay at \(url) for '\(backend.name)'; adopting.")
                            await self?.applyRelayLANMetadata(for: backendID,
                                                              lanURL: url,
                                                              wifiSSID: nil,
                                                              hostStatus: result.relayHostStatus,
                                                              interface: nil)
                        }
                    }
                }
#endif
            }
        } catch {
            if error is CancellationError {
                return
            }
            let timestamp = Date()
            let errorDescription: String = {
                if let backendError = error as? RemoteBackendError {
                    if let backend = remoteBackends.first(where: { $0.id == backendID }) {
                        if backend.endpointType == .ollama,
                           case .validationFailed(let message) = backendError,
                           message.contains("OLLAMA_HOST") {
                            Task { @MainActor in
                                await logger.log("[RemoteBackendAPI] ⚠️ Ollama advisory presented to user")
                            }
                        }
                    }
                    switch backendError {
                    case .unexpectedStatus(let code, _):
                        let reason = RemoteBackend.normalizedStatusReason(for: code)
                        return RemoteBackend.statusErrorDescription(for: code, reason: reason)
                    case .validationFailed(let message):
                        return message
                    default:
                        return RemoteBackend.localizedErrorDescription(for: backendError)
                    }
                }
                return RemoteBackend.localizedErrorDescription(for: error)
            }()

            let summary: RemoteBackend.ConnectionSummary = {
                if let backendError = error as? RemoteBackendError {
                    switch backendError {
                    case .unexpectedStatus(let code, _):
                        let reason = RemoteBackend.normalizedStatusReason(for: code)
                        return .failure(statusCode: code, reason: reason, timestamp: timestamp)
                    case .validationFailed(let message):
                        return .failure(message: message, timestamp: timestamp)
                    default:
                        return .failure(message: errorDescription, timestamp: timestamp)
                    }
                }
                return .failure(message: errorDescription, timestamp: timestamp)
            }()

            updateRemoteBackend(
                backendID: backendID,
                with: nil,
                error: errorDescription,
                summary: summary
            )
        }
    }

#if os(iOS) || os(visionOS)
    /// Run once per backend (per app launch): if we have a cached LAN URL,
    /// try an unauthenticated /v1/health GET with short timeouts so LAN
    /// switchover signals appear before model load.
    private func performInitialLANHealthProbeIfCached(for backendID: RemoteBackend.ID) async {
        guard let backend = remoteBackends.first(where: { $0.id == backendID }),
              backend.endpointType == .noemaRelay else { return }

        // Prefer lightweight health probe first
        if let healthURL = backend.relayLANHealthEndpointURL {
            var req = URLRequest(url: healthURL)
            req.httpMethod = "GET"
            req.timeoutInterval = 3
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 3
            cfg.timeoutIntervalForResource = 3
            cfg.waitsForConnectivity = false
            let session = URLSession(configuration: cfg)
            NetworkKillSwitch.track(session: session)
            defer { session.invalidateAndCancel() }
            await logger.log("[RemoteChat] [LAN] Health probe → \(healthURL.absoluteString) for '\(backend.name)'")
            do {
                guard !NetworkKillSwitch.shouldBlock(request: req) else { return }
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    // If the host is on Ethernet (no SSID) but we're on the same subnet,
                    // surface an early same-subnet match log to mirror runtime behavior.
                    if let host = backend.relayLANChatEndpointURL?.host,
                       LANSubnet.isSameSubnet(host: host) {
                        await logger.log("[RemoteChat] [LAN] Same-subnet match for '\(backend.name)' (host=\(host)); using LAN")
                    }
                    return
                }
            } catch { /* fall through to HEAD check */ }
        }

        // Fallback: HEAD the chat endpoint with short timeouts
        guard let url = backend.relayLANChatEndpointURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = backend.relayAuthorizationHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        defer { session.invalidateAndCancel() }
        await logger.log("[RemoteChat] [LAN] HEAD probe → \(url.absoluteString) for '\(backend.name)'")
        do {
            guard !NetworkKillSwitch.shouldBlock(request: request) else { return }
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<400, 401, 403, 405:
                    if let host = backend.relayLANChatEndpointURL?.host,
                       LANSubnet.isSameSubnet(host: host) {
                        await logger.log("[RemoteChat] [LAN] Same-subnet match for '\(backend.name)' (host=\(host)); using LAN")
                    }
                default:
                    await logger.log("[RemoteChat] [LAN] HEAD probe failed with status #\(http.statusCode) for '\(backend.name)'; treating as unreachable")
                }
            }
        } catch {
            // URLError(.badServerResponse) or raw-data decode issues can still indicate reachability; no-op here
        }
    }
#endif

    func requestRelayLANRefresh(for backendID: RemoteBackend.ID,
                                reason: String,
                                force: Bool) async {
        guard let backend = remoteBackends.first(where: { $0.id == backendID }) else { return }
        guard backend.endpointType == .noemaRelay else { return }
        if !force,
           let last = relayLANRefreshTimestamps[backendID],
           Date().timeIntervalSince(last) < RelayLANRefreshConstants.throttle {
            return
        }
        if activeRelayLANRefreshes.contains(backendID) { return }
        let containerID = backend.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerID.isEmpty else { return }
        guard let hostIDRaw = backend.relayHostDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostIDRaw.isEmpty else { return }
#if os(macOS)
        if RelayManagementViewModel.shared.serverState != .running && !force {
            await logger.log("[RemoteBackend] [LAN] Skipping LAN refresh for '\(backend.name)' because relay is inactive.")
            return
        }
#endif
        activeRelayLANRefreshes.insert(backendID)
        defer {
            activeRelayLANRefreshes.remove(backendID)
            relayLANRefreshTimestamps[backendID] = Date()
        }
        do {
            await logger.log("[RemoteBackend] [LAN] Requesting LAN status refresh (\(reason)) for '\(backend.name)'.")
            let command = try await RelayCatalogClient.shared.createCommand(
                containerIdentifier: containerID,
                hostDeviceID: hostIDRaw,
                verb: "POST",
                path: "/network/refresh",
                body: nil
            )
            let result = try await RelayCatalogClient.shared.waitForCommand(
                containerIdentifier: containerID,
                commandID: command.recordID,
                timeout: RelayLANRefreshConstants.timeout
            )
            await logger.log("[RemoteBackend] [LAN] LAN refresh command completed with state=\(result.state.rawValue) for '\(backend.name)'.")
            guard result.state == .succeeded else { return }
            if let data = result.result {
                do {
                    let payload = try JSONDecoder().decode(RelayLANStatusPayload.self, from: data)
                    let lanURL = payload.lanURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let wifiSSID = payload.wifiSSID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let interfaceLabel = payload.interface?.rawValue ?? "nil"
                    await logger.log("[RemoteBackend] [LAN] Updated LAN metadata for '\(backend.name)' → lanURL=\(lanURL ?? "nil") ssid=\(wifiSSID ?? "nil") interface=\(interfaceLabel).")
                    applyRelayLANMetadata(
                        for: backendID,
                        lanURL: lanURL,
                        wifiSSID: wifiSSID,
                        hostStatus: payload.hostStatus,
                        interface: payload.interface
                    )
                } catch {
                    await logger.log("[RemoteBackend] [LAN] Failed to decode LAN refresh payload for '\(backend.name)': \(error.localizedDescription)")
                }
            }
        } catch {
            if let relayError = error as? RelayError, case .timeout = relayError {
                // Don't immediately re-fetch the catalog on timeout; this caused
                // repeated reconnect loops. We'll just log and let normal throttled
                // refreshes or user actions trigger the next attempt.
                await logger.log("[RemoteBackend] [LAN] LAN refresh command timed out for '\(backend.name)' after \(RelayLANRefreshConstants.timeout)s; skipping immediate retry.")
            } else {
                await logger.log("[RemoteBackend] [LAN] LAN refresh command failed for '\(backend.name)': \(error.localizedDescription)")
            }
        }
    }

    func refreshRemoteBackendsForRelay() async {
        let targets = remoteBackends.filter { !$0.endpointType.isRelay }
        for backend in targets {
            await fetchRemoteModels(for: backend.id)
        }
    }

    func updateRemoteBackend(
        backendID: RemoteBackend.ID,
        with models: [RemoteModel]?,
        error: String?,
        summary: RemoteBackend.ConnectionSummary?,
        relayEjectsOnDisconnect: Bool? = nil,
        relayHostStatus: RelayHostStatus? = nil,
        relayLANURL: String?? = nil,
        relayWiFiSSID: String?? = nil,
        relayAPIToken: String?? = nil,
        relayLANInterface: RelayLANInterface?? = nil
    ) {
        guard let index = remoteBackends.firstIndex(where: { $0.id == backendID }) else { return }
        var backend = remoteBackends[index]
        if let models {
            let deduped = dedupe(models: models, backend: backend)
            backend.cachedModels = deduped
            backend.lastFetched = summary?.timestamp ?? Date()
            backend.lastError = nil
        }
        if let error {
            backend.lastError = error
        }
        if let summary {
            backend.lastConnectionSummary = summary
        }
        if let relayEjectsOnDisconnect {
            backend.relayEjectsOnDisconnect = relayEjectsOnDisconnect
        }
        if let relayHostStatus {
            backend.relayHostStatus = relayHostStatus
        } else if models != nil && backend.endpointType.isRelay {
            // Clear stale status when relay reports running via exposed catalog
            backend.relayHostStatus = nil
        }
        if let relayLANURL {
            if let value = relayLANURL?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                backend.relayLANURLString = value
            } else {
                backend.relayLANURLString = nil
            }
        }
        if let relayWiFiSSID {
            if let value = relayWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                backend.relayWiFiSSID = value
            } else {
                backend.relayWiFiSSID = nil
            }
        }
        if let relayAPIToken {
            if let value = relayAPIToken?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                backend.relayAPIToken = value
            } else {
                backend.relayAPIToken = nil
            }
        }
        if let relayLANInterface {
            backend.relayLANInterface = relayLANInterface
        }
        remoteBackends[index] = backend
        normalizeLMStudioRemoteDownloadTargetIfNeeded()
        persistRemoteBackends()
        StartupPreferencesStore.updateRemoteBackend(backend)
    }

    func applyRelayLANMetadata(for backendID: RemoteBackend.ID,
                               lanURL: String?,
                               wifiSSID: String?,
                               hostStatus: RelayHostStatus?,
                               interface: RelayLANInterface?) {
        updateRemoteBackend(
            backendID: backendID,
            with: nil,
            error: nil,
            summary: nil,
            relayEjectsOnDisconnect: nil,
            relayHostStatus: hostStatus,
            relayLANURL: .some(lanURL),
            relayWiFiSSID: .some(wifiSSID),
            relayAPIToken: nil,
            relayLANInterface: .some(interface)
        )
    }

    private func dedupe(models: [RemoteModel], backend: RemoteBackend) -> [RemoteModel] {
        var seen: Set<String> = []
        var output: [RemoteModel] = []
        for model in models {
            if seen.insert(model.id).inserted {
                output.append(model)
            }
        }
        for custom in backend.customModelIDs {
            if seen.insert(custom).inserted {
                output.append(RemoteModel.makeCustom(id: custom))
            }
        }
        output.sort { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return output
    }

    private func persistRemoteBackends() {
        RemoteBackendsStore.save(remoteBackends)
    }

    private func prepareCredentials(for backend: RemoteBackend,
                                    draft: RemoteBackendDraft,
                                    existing: RemoteBackend?) async throws {
        let trimmedDraftKey = draft.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingOpenRouterKey: String? = {
            guard let existing, existing.endpointType == .openRouter else { return nil }
            if let stored = (try? RemoteBackendCredentialStore.openRouterAPIKey(for: existing.id)) ?? nil,
               !stored.isEmpty {
                return stored
            }
            let legacy = existing.authHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return legacy.isEmpty ? nil : legacy
        }()

        if backend.endpointType == .openRouter {
            let effectiveKey = trimmedDraftKey.isEmpty ? (existingOpenRouterKey ?? "") : trimmedDraftKey
            guard !effectiveKey.isEmpty else {
                throw RemoteBackendError.validationFailed(String(localized: "Please provide an OpenRouter API key."))
            }
            let keyChanged = existing?.endpointType != .openRouter || trimmedDraftKey.isEmpty == false && trimmedDraftKey != existingOpenRouterKey
            if keyChanged {
                _ = try await RemoteBackendAPI.verifyOpenRouterAPIKey(effectiveKey, backendID: backend.id)
            }
            try RemoteBackendCredentialStore.setOpenRouterAPIKey(effectiveKey, for: backend.id)
        } else if let existing, existing.endpointType == .openRouter {
            try? RemoteBackendCredentialStore.removeOpenRouterAPIKey(for: existing.id)
        }
    }

    private func normalizeLMStudioRemoteDownloadTargetIfNeeded() {
        guard let targetID = activeLMStudioRemoteDownloadTargetID else { return }
        guard let backend = remoteBackends.first(where: { $0.id == targetID }),
              backend.endpointType == .lmStudio else {
            activeLMStudioRemoteDownloadTargetID = nil
            return
        }
    }

    private func duplicateRelayDeviceMessage(for backend: RemoteBackend,
                                             excluding backendID: RemoteBackend.ID? = nil) -> String? {
        guard backend.endpointType == .noemaRelay,
              let hostID = backend.relayHostDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostID.isEmpty else {
            return nil
        }
        let normalizedHostID = hostID.lowercased()
        let hasDuplicate = remoteBackends.contains { existing in
            if let backendID, existing.id == backendID { return false }
            guard existing.endpointType == .noemaRelay,
                  let existingHost = existing.relayHostDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !existingHost.isEmpty else {
                return false
            }
            return existingHost.lowercased() == normalizedHostID
        }
        return hasDuplicate ? String(localized: "This Noema Relay device is already configured.") : nil
    }
}
