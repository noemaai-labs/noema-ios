// EnterprisePolicyGate.swift
// Synchronous, background-safe enforcement core for Noema Teams policy.
//
// Mirrors how WebToolGate/PythonToolGate stay off the main actor: all checks are
// static, lock-protected, and read a cached snapshot. When no workspace is
// connected everything returns true and consumer Noema behaves exactly as before.
//
// Failure semantics (fail closed):
//   - expired within the 72h grace window: cached policy keeps being enforced
//   - expired past grace / revoked device / invalid policy: allowlist restrictions
//     and boolean restrictions REMAIN in force, and enterprise datasets are denied
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
