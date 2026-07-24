import Foundation

enum EnterprisePolicyGate {
    static let gracePeriod: TimeInterval = 72 * 60 * 60

    /// nil = not yet loaded from disk; .some(nil) = loaded, no policy.
    private static let snapshotState = LockIsolated<EnterpriseGateSnapshot??>(nil)
    /// Test hook for time-dependent expiry checks.
    private static let nowOverride = LockIsolated<Date?>(nil)

    // MARK: Snapshot lifecycle

    static func setSnapshot(_ snapshot: EnterpriseGateSnapshot?) {
        snapshotState.withMutableValue { $0 = .some(snapshot) }
    }

    static func resetForTesting(now: Date? = nil) {
        snapshotState.withMutableValue { $0 = nil }
        nowOverride.withMutableValue { $0 = now }
    }

    private static func current() -> EnterpriseGateSnapshot? {
        let loaded: EnterpriseGateSnapshot?? = snapshotState.withValue { $0 }
        if let loaded { return loaded }
        // First access (possibly off-main, before the manager bootstraps): load synchronously.
        let fromDisk = EnterprisePolicyStorage.loadSnapshot()
        snapshotState.withMutableValue { state in
            if state == nil { state = .some(fromDisk) }
        }
        return snapshotState.withValue { $0 } ?? nil
    }

    private static func now() -> Date {
        nowOverride.withValue { $0 } ?? Date()
    }

    // MARK: Status helpers

    static var isActive: Bool { current() != nil }

    static var activePolicy: EnterprisePolicy? { current()?.policy }

    /// Past expiry but still within the enforcement grace window.
    static func isExpired(_ snapshot: EnterpriseGateSnapshot) -> Bool {
        now() > snapshot.policy.expiresAt
    }

    static func isPastGrace(_ snapshot: EnterpriseGateSnapshot) -> Bool {
        now() > snapshot.policy.expiresAt.addingTimeInterval(gracePeriod)
    }

    // MARK: Periodic-reconnect deadline (offline dead-man's switch)

    /// Days the device may stay offline before its cached policy is wiped; nil = unlimited.
    /// A 0 from the server is also treated as "off".
    static func reconnectIntervalDays(_ snapshot: EnterpriseGateSnapshot) -> Int? {
        guard let days = snapshot.policy.reconnectIntervalDays, days > 0 else { return nil }
        return days
    }

    /// The instant by which the device must have synced again, anchored to the server-stamped
    /// `issuedAt` (refreshed on every successful sync). nil when no limit is configured.
    static func reconnectDeadline(_ snapshot: EnterpriseGateSnapshot) -> Date? {
        guard let days = reconnectIntervalDays(snapshot) else { return nil }
        return snapshot.policy.issuedAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    static func isReconnectOverdue(_ snapshot: EnterpriseGateSnapshot) -> Bool {
        guard let deadline = reconnectDeadline(snapshot) else { return false }
        return now() > deadline
    }

    /// True when a workspace is connected but the device has gone too long without a
    /// successful sync. The manager reacts by wiping all company data locally and offline.
    static var reconnectDeadlinePassed: Bool {
        guard let snapshot = current() else { return false }
        return isReconnectOverdue(snapshot)
    }

    /// The active connection's reconnect deadline, for display in settings. nil = unlimited.
    static var activeReconnectDeadline: Date? {
        guard let snapshot = current() else { return nil }
        return reconnectDeadline(snapshot)
    }

    /// Enterprise datasets are only served while the policy is trusted, within grace, and
    /// the device hasn't blown past its offline reconnect window.
    private static func datasetsTrusted(_ snapshot: EnterpriseGateSnapshot) -> Bool {
        snapshot.status == .valid && !isPastGrace(snapshot) && !isReconnectOverdue(snapshot)
    }

    // MARK: Enforcement checks

    static func allowsTool(_ toolName: String) -> Bool {
        guard let snapshot = current() else { return true }
        guard let allowed = snapshot.policy.allowedToolNames else { return true }
        return allowed.contains(toolName)
    }

    #if os(macOS)
    static func allowsMCP(serverID: String, transport: MCPTransportConfiguration, toolAlias: String? = nil) -> Bool {
        guard let snapshot = current() else { return true }
        let policy = snapshot.policy
        guard policy.mcpEnabled ?? true else { return false }
        if let allowed = policy.allowedMCPServerIDs, !allowed.contains(serverID) { return false }
        let transportName: String
        switch transport {
        case .stdio:
            guard policy.mcpLocalProcessesAllowed ?? true else { return false }
            transportName = "stdio"
        case .streamableHTTP: transportName = "streamable-http"
        case .legacySSE: transportName = "sse"
        }
        if let allowed = policy.allowedMCPTransports, !allowed.contains(transportName) { return false }
        if let toolAlias {
            if let allowed = policy.allowedMCPToolAliases, !allowed.contains(toolAlias) { return false }
            // Existing explicit tool allowlists fail closed for dynamic aliases.
            if let allowed = policy.allowedToolNames, !allowed.contains(toolAlias) { return false }
        }
        return true
    }

    static var mcpSamplingAllowed: Bool { current()?.policy.mcpSamplingAllowed ?? true }
    static var mcpElicitationAllowed: Bool { current()?.policy.mcpElicitationAllowed ?? true }
    #endif

    static func allowsModelFormat(_ format: ModelFormat) -> Bool {
        guard let snapshot = current() else { return true }
        guard let allowed = snapshot.policy.allowedModelFormats else { return true }
        return allowed.contains(format.rawValue)
    }

    static func allowsModel(modelID: String?) -> Bool {
        guard let snapshot = current() else { return true }
        guard let allowed = snapshot.policy.allowedModelIDs else { return true }
        guard let modelID, !modelID.isEmpty else {
            // Unidentifiable model under an explicit model allowlist: deny.
            return false
        }
        return allowed.contains(modelID)
    }

    static func allowsRemoteBackend(id: RemoteBackend.ID, endpointType: RemoteBackend.EndpointType) -> Bool {
        guard let snapshot = current() else { return true }
        if !snapshot.policy.remoteInferenceAllowed { return false }
        if let allowedTypes = snapshot.policy.allowedRemoteEndpointTypes,
           !allowedTypes.contains(endpointType.rawValue) {
            return false
        }
        if let allowedIDs = snapshot.policy.allowedRemoteBackendIDs,
           !allowedIDs.contains(id.uuidString.lowercased()) &&
           !allowedIDs.contains(id.uuidString) {
            return false
        }
        return true
    }

    static var remoteInferenceAllowed: Bool {
        guard let snapshot = current() else { return true }
        return snapshot.policy.remoteInferenceAllowed
    }

    static var datasetDownloadAllowed: Bool {
        guard let snapshot = current() else { return true }
        return snapshot.policy.datasetDownloadAllowed && datasetsTrusted(snapshot)
    }

    static var requiresOffGrid: Bool {
        guard let snapshot = current() else { return false }
        return snapshot.policy.requiresOffGrid
    }

    /// Non-nil when an explicit model allowlist is in force: the Explore tab is
    /// locked to exactly this list (no search).
    static var lockedModelIDs: [String]? {
        guard let snapshot = current() else { return nil }
        return snapshot.policy.allowedModelIDs
    }

    /// "full" or "datasets"; nil (pre-field cached policies) counts as "full".
    static var governanceMode: String {
        current()?.policy.governanceMode ?? "full"
    }

    static func allowsDataset(datasetID: String) -> Bool {
        let isEnterpriseDataset = datasetID.hasPrefix("\(EnterpriseDatasetStore.ownerDirectoryName)/")
        guard let snapshot = current() else {
            // Not connected: personal datasets unaffected; orphaned enterprise
            // directories (left over from a wiped connection) stay hidden.
            return !isEnterpriseDataset
        }
        guard isEnterpriseDataset else { return true }
        guard datasetsTrusted(snapshot) else { return false }
        return snapshot.policy.allowedDatasetIDs.contains(datasetID)
    }
}
