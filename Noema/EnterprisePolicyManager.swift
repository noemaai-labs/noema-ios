// EnterprisePolicyManager.swift
// Owns the Noema Teams connection lifecycle: enrollment, the device token (Keychain),
// the cached policy snapshot, periodic refresh, dataset sync, and the off-grid mapping.
// Enforcement itself happens synchronously in EnterprisePolicyGate.
import Foundation
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

@MainActor
final class EnterprisePolicyManager: ObservableObject {
    static let shared = EnterprisePolicyManager()

    @Published private(set) var state: EnterpriseConnectionState = .none
    @Published private(set) var policy: EnterprisePolicy?
    @Published private(set) var availableDatasets: [EnterpriseDatasetManifest] = []
    /// LocalDataset IDs ("Enterprise/<id>") currently saved on this device.
    @Published private(set) var installedDatasetIDs: Set<String> = []
    /// Datasets with a "Save to Stored" download in flight (for per-row spinners).
    @Published private(set) var installingDatasetIDs: Set<String> = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var lastErrorMessage: String?
    /// Verification code echoed back by the server in developer mode only.
    @Published private(set) var devVerificationCode: String?

    private let client: EnterpriseAPIClient
    private let verifier: PolicySignatureVerifier
    private var refreshTimer: Timer?

    private static let keychainService = "ai.noema.enterprise"
    private static let keychainTokenAccount = "deviceToken"
    private static let lastSyncDefaultsKey = "enterpriseLastSyncAt"
    private static let forcedOffGridDefaultsKey = "enterpriseOffGridForced"
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    init(client: EnterpriseAPIClient = .shared, verifier: PolicySignatureVerifier = StubPolicySignatureVerifier()) {
        self.client = client
        self.verifier = verifier
        bootstrap()
    }

    // MARK: Device token

    private var deviceToken: String? {
        // try? flattens the thrown error and the not-found nil into one optional.
        guard let data = try? KeychainStore.read(service: Self.keychainService, account: Self.keychainTokenAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func storeDeviceToken(_ token: String) {
        try? KeychainStore.write(
            service: Self.keychainService,
            account: Self.keychainTokenAccount,
            data: Data(token.utf8)
        )
    }

    private func clearDeviceToken() {
        try? KeychainStore.delete(service: Self.keychainService, account: Self.keychainTokenAccount)
    }

    // MARK: Bootstrap & state

    private func bootstrap() {
        let snapshot = EnterprisePolicyStorage.loadSnapshot()
        EnterprisePolicyGate.setSnapshot(snapshot)
        policy = snapshot?.policy
        if let timestamp = UserDefaults.standard.object(forKey: Self.lastSyncDefaultsKey) as? Date {
            lastSyncAt = timestamp
        }
        recomputeState()
        applyOffGridMapping()
        scheduleRefreshTimer()
        Task {
            // Offline dead-man's switch: if the device has gone too long without a sync,
            // wipe all company data on launch before doing anything else (no network needed).
            if await enforceReconnectDeadlineIfNeeded() { return }
            await refreshInstalledDatasets()
            if state.isEnrolledOnDevice {
                await refreshPolicy()
            }
        }
    }

    private func recomputeState() {
        let context = EnterprisePolicyStorage.loadContext()
        let snapshot = EnterprisePolicyStorage.loadSnapshot()

        if let context {
            switch context.phase {
            case .awaitingCode:
                if let enrollmentID = context.enrollmentID {
                    state = .awaitingEmailVerification(enrollmentID: enrollmentID)
                    return
                }
            case .pendingApproval:
                if let enrollmentID = context.enrollmentID {
                    state = .pendingApproval(enrollmentID: enrollmentID)
                    return
                }
            case .revoked:
                state = .deviceRevoked
                return
            case .invalid:
                state = .policyInvalid
                return
            case .disconnected:
                state = .disconnected
                return
            case .connected:
                break
            }
        }
        guard deviceToken != nil, let snapshot else {
            state = .none
            return
        }
        switch snapshot.status {
        case .revoked: state = .deviceRevoked
        case .invalid: state = .policyInvalid
        case .valid:
            state = EnterprisePolicyGate.isExpired(snapshot) ? .policyExpired : .connected
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                await EnterprisePolicyManager.shared.refreshPolicy()
            }
        }
    }

    /// Call when the app becomes active.
    func refreshIfEnrolled() {
        Task {
            if await enforceReconnectDeadlineIfNeeded() { return }
            guard state.isEnrolledOnDevice else { return }
            await refreshPolicy()
        }
    }

    /// Days the device may stay offline before its company data is wiped (nil = unlimited).
    var reconnectIntervalDays: Int? {
        guard let days = EnterprisePolicyGate.activePolicy?.reconnectIntervalDays, days > 0 else { return nil }
        return days
    }

    /// When the device must next reach the workspace before its data is auto-wiped.
    var reconnectDeadline: Date? { EnterprisePolicyGate.activeReconnectDeadline }

    // MARK: Connect flow

    var storedContext: EnterpriseStoredContext? { EnterprisePolicyStorage.loadContext() }

    private static func currentDeviceName() -> String {
#if os(iOS) || os(visionOS)
        return UIDevice.current.name
#else
        return Host.current().localizedName ?? "Mac"
#endif
    }

    private static func currentPlatform() -> String {
#if os(visionOS)
        return "visionOS"
#elseif os(iOS)
        return "iOS"
#else
        return "macOS"
#endif
    }

    func connect(companyCode: String, email: String) async {
        let code = companyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty, mail.contains("@") else { return }
        isBusy = true
        lastErrorMessage = nil
        devVerificationCode = nil
        state = .connecting
        defer { isBusy = false }
        do {
            let lookup = try await client.lookup(companyCode: code)
            let start = try await client.startEnrollment(
                companyCode: code,
                email: mail,
                deviceName: Self.currentDeviceName(),
                platform: Self.currentPlatform()
            )
            devVerificationCode = start.debugCode
            EnterprisePolicyStorage.saveContext(
                EnterpriseStoredContext(
                    phase: .awaitingCode,
                    companyCode: code,
                    tenantName: lookup.tenantName,
                    email: mail,
                    enrollmentID: start.enrollmentID
                )
            )
            state = .awaitingEmailVerification(enrollmentID: start.enrollmentID)
        } catch {
            lastErrorMessage = error.localizedDescription
            state = .none
        }
    }

    func submitVerificationCode(_ code: String) async {
        guard case .awaitingEmailVerification(let enrollmentID) = state else { return }
        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }
        do {
            let result = try await client.verifyEnrollment(enrollmentID: enrollmentID, code: code)
            try await handleEnrollResult(result, enrollmentID: enrollmentID)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func pollPendingApproval() async {
        guard case .pendingApproval(let enrollmentID) = state else { return }
        do {
            let result = try await client.enrollmentStatus(enrollmentID: enrollmentID)
            try await handleEnrollResult(result, enrollmentID: enrollmentID)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func handleEnrollResult(_ result: EnterpriseEnrollResultResponse, enrollmentID: String) async throws {
        var context = EnterprisePolicyStorage.loadContext()
        switch result.status {
        case "approved":
            guard let token = result.deviceToken, let policy = result.policy else {
                throw EnterpriseAPIError.decoding
            }
            storeDeviceToken(token)
            context?.phase = .connected
            context?.enrollmentID = nil
            if let context { EnterprisePolicyStorage.saveContext(context) }
            let raw = (try? EnterprisePolicy.encoder().encode(policy)) ?? Data()
            await apply(policy: policy, rawPayload: raw)
            await syncDatasets()
        case "pending_approval":
            context?.phase = .pendingApproval
            context?.enrollmentID = enrollmentID
            if let context { EnterprisePolicyStorage.saveContext(context) }
            state = .pendingApproval(enrollmentID: enrollmentID)
        case "denied":
            cancelEnrollment()
            lastErrorMessage = String(
                localized: "Your access request was declined by an administrator.",
                locale: LocalizationManager.preferredLocale()
            )
        default:
            break // awaiting_code / completed: nothing to change
        }
    }

    func cancelEnrollment() {
        EnterprisePolicyStorage.clearAll()
        devVerificationCode = nil
        state = .none
    }

    // MARK: Policy refresh & application

    func refreshPolicy(force: Bool = false) async {
        guard let token = deviceToken else { return }
        if isBusy && !force { return }
        do {
            let (fetched, raw) = try await client.fetchPolicy(deviceToken: token)
            await apply(policy: fetched, rawPayload: raw)
            await syncDatasets()
        } catch EnterpriseAPIError.deviceRevoked {
            markRevoked()
        } catch EnterpriseAPIError.invalidToken {
            // The server no longer recognizes this device token — the workspace was deleted, or this
            // device/membership was removed. The connection can't recover: fully disconnect and wipe.
            await markWorkspaceClosed()
        } catch EnterpriseAPIError.paymentRequired(let message) {
            // Workspace trial/subscription lapsed. Keep enforcing the cached snapshot — it
            // degrades on its own through the normal expiry path — and surface the billing
            // reason so the admin knows to subscribe.
            lastErrorMessage = message.isEmpty
                ? String(localized: "Your organization's Noema Teams subscription has ended.", locale: LocalizationManager.preferredLocale())
                : message
            recomputeState()
            if await enforceReconnectDeadlineIfNeeded() { return }
            Task { await logger.log("[Enterprise] policy refresh: payment required — \(message)") }
        } catch {
            // Network/server trouble: keep enforcing the cached snapshot, but if the device
            // has now been offline past its reconnect window, wipe all company data locally.
            recomputeState()
            if await enforceReconnectDeadlineIfNeeded() { return }
            Task { await logger.log("[Enterprise] policy refresh failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Periodic-reconnect enforcement

    /// If the device has gone past its reconnect deadline, wipe all company data locally.
    /// Purely time-based and offline-safe — it never needs the network, so a removed user
    /// whose device never comes back online still loses access once the window elapses.
    /// Returns true if it wiped.
    @discardableResult
    func enforceReconnectDeadlineIfNeeded() async -> Bool {
        guard EnterprisePolicyGate.reconnectDeadlinePassed else { return false }
        await wipeForExpiredConnection()
        return true
    }

    /// Local, offline equivalent of `disconnect()`: drops the token, snapshot, context, and
    /// every saved company dataset, then restores any policy-forced off-grid state. Leaves an
    /// explanatory message so the connect screen tells the user why their data disappeared.
    private func wipeForExpiredConnection() async {
        let days = EnterprisePolicyGate.activePolicy?.reconnectIntervalDays ?? 0
        await performLocalWipe(message: String(
            format: String(
                localized: "This device went more than %lld days without reaching your workspace, so all company data and access were removed automatically. Reconnect to restore access.",
                locale: LocalizationManager.preferredLocale()
            ),
            Int64(days)
        ))
        Task { await logger.log("[Enterprise] reconnect deadline passed (\(days)d offline) — wiped local company data") }
    }

    /// A device token the server no longer recognizes (HTTP 401) means the workspace was deleted,
    /// or this device/membership was removed — the connection can never recover. Fully disconnect
    /// and erase company data locally, same as a revoke, with a clear explanation for the user.
    private func markWorkspaceClosed() async {
        await performLocalWipe(message: String(
            localized: "This workspace is no longer available — it may have been closed by your organization or your access ended. Company data has been removed from this device.",
            locale: LocalizationManager.preferredLocale()
        ))
        Task { await logger.log("[Enterprise] device token rejected (401) — workspace closed/access ended; wiped local company data") }
    }

    /// Shared local teardown: drop the token, snapshot, context, and saved datasets, restore any
    /// policy-forced off-grid state, then land in `.disconnected` with an explanatory `message`.
    private func performLocalWipe(message: String) async {
        let requiredOffGrid = EnterprisePolicyGate.requiresOffGrid
        clearDeviceToken()
        EnterprisePolicyGate.setSnapshot(nil)
        EnterprisePolicyStorage.clearAll()
        UserDefaults.standard.removeObject(forKey: Self.lastSyncDefaultsKey)
        if requiredOffGrid {
            applyOffGridMapping() // clears the allowlist and restores forced off-grid
        }
        await EnterpriseDatasetStore.shared.purgeAll()
        policy = nil
        availableDatasets = []
        installedDatasetIDs = []
        lastSyncAt = nil
        devVerificationCode = nil
        lastErrorMessage = message
        state = .disconnected
    }

    private func apply(policy: EnterprisePolicy, rawPayload: Data) async {
        do {
            try verifier.verify(policy: policy, rawPayload: rawPayload)
        } catch {
            markInvalid()
            return
        }
        let snapshot = EnterpriseGateSnapshot(policy: policy, status: .valid)
        EnterprisePolicyStorage.saveSnapshot(snapshot, rawPayload: rawPayload)
        EnterprisePolicyGate.setSnapshot(snapshot)
        self.policy = policy
        lastSyncAt = Date()
        UserDefaults.standard.set(lastSyncAt, forKey: Self.lastSyncDefaultsKey)
        if var context = EnterprisePolicyStorage.loadContext() {
            context.phase = .connected
            context.tenantName = policy.tenantName
            EnterprisePolicyStorage.saveContext(context)
        } else {
            EnterprisePolicyStorage.saveContext(
                EnterpriseStoredContext(
                    phase: .connected,
                    companyCode: policy.companyCode,
                    tenantName: policy.tenantName,
                    email: policy.userEmail,
                    enrollmentID: nil
                )
            )
        }
        applyOffGridMapping()
        recomputeState()
    }

    private func syncDatasets() async {
        guard let token = deviceToken, let policy else { return }
        do {
            let manifests = try await client.fetchDatasetManifests(deviceToken: token)
            availableDatasets = manifests
            await EnterpriseDatasetStore.shared.sync(
                manifests: manifests,
                allowedDatasetIDs: Set(policy.allowedDatasetIDs),
                downloadAllowed: EnterprisePolicyGate.datasetDownloadAllowed,
                deviceToken: token
            )
            await refreshInstalledDatasets()
        } catch {
            Task { await logger.log("[Enterprise] dataset sync failed: \(error.localizedDescription)") }
        }
    }

    private func refreshInstalledDatasets() async {
        let manifests = await EnterpriseDatasetStore.shared.installedManifests()
        installedDatasetIDs = Set(manifests.map(\.datasetID))
    }

    /// "Save to Stored": user-initiated download of one company dataset. Once on disk
    /// the existing dataset pipeline takes over (Stored listing + indexing).
    func installDataset(_ manifest: EnterpriseDatasetManifest) async {
        guard let token = deviceToken, EnterprisePolicyGate.datasetDownloadAllowed else { return }
        guard !installingDatasetIDs.contains(manifest.datasetID) else { return }
        installingDatasetIDs.insert(manifest.datasetID)
        defer { installingDatasetIDs.remove(manifest.datasetID) }
        lastErrorMessage = nil
        do {
            try await EnterpriseDatasetStore.shared.install(manifest: manifest, deviceToken: token)
            await refreshInstalledDatasets()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func removeDataset(_ manifest: EnterpriseDatasetManifest) async {
        await EnterpriseDatasetStore.shared.remove(enterpriseDatasetID: manifest.enterpriseDatasetID)
        await refreshInstalledDatasets()
    }

    func fetchDatasetFiles(_ manifest: EnterpriseDatasetManifest) async throws -> [EnterpriseDatasetFile] {
        guard let token = deviceToken else { throw EnterpriseAPIError.invalidToken }
        return try await client.fetchDatasetFiles(
            deviceToken: token,
            enterpriseDatasetID: manifest.enterpriseDatasetID
        )
    }

    /// Temp-file URL for QuickLook; never lands in the dataset root.
    func previewURL(for manifest: EnterpriseDatasetManifest, file: EnterpriseDatasetFile) async throws -> URL {
        guard let token = deviceToken else { throw EnterpriseAPIError.invalidToken }
        return try await EnterpriseDatasetStore.shared.previewFile(
            manifest: manifest,
            file: file,
            deviceToken: token
        )
    }

    private func markRevoked() {
        updateSnapshotStatus(.revoked)
        if var context = EnterprisePolicyStorage.loadContext() {
            context.phase = .revoked
            EnterprisePolicyStorage.saveContext(context)
        }
        state = .deviceRevoked
        Task { await EnterpriseDatasetStore.shared.purgeAll() }
    }

    private func markInvalid() {
        updateSnapshotStatus(.invalid)
        if var context = EnterprisePolicyStorage.loadContext() {
            context.phase = .invalid
            EnterprisePolicyStorage.saveContext(context)
        }
        state = .policyInvalid
    }

    private func updateSnapshotStatus(_ status: EnterpriseEnforcementStatus) {
        guard var snapshot = EnterprisePolicyStorage.loadSnapshot() else { return }
        snapshot.status = status
        EnterprisePolicyStorage.saveSnapshot(snapshot, rawPayload: nil)
        EnterprisePolicyGate.setSnapshot(snapshot)
    }

    // MARK: Off-grid mapping

    /// requiresOffGrid resolves into the existing offGrid setting + NetworkKillSwitch,
    /// with a narrow HTTPS allowlist for the workspace host so policy sync (and governed
    /// dataset downloads) keep working. We only undo what we forced ourselves.
    private func applyOffGridMapping() {
        let defaults = UserDefaults.standard
        if EnterprisePolicyGate.requiresOffGrid {
            if let host = EnterpriseAPIClient.apiHost {
                NetworkKillSwitch.setEnterpriseAllowedHosts([host])
            }
            if !(defaults.object(forKey: "offGrid") as? Bool ?? false) {
                defaults.set(true, forKey: Self.forcedOffGridDefaultsKey)
            }
            defaults.set(true, forKey: "offGrid")
            NetworkKillSwitch.setEnabled(true)
        } else {
            NetworkKillSwitch.setEnterpriseAllowedHosts([])
            if defaults.bool(forKey: Self.forcedOffGridDefaultsKey) {
                defaults.set(false, forKey: Self.forcedOffGridDefaultsKey)
                defaults.set(false, forKey: "offGrid")
                NetworkKillSwitch.setEnabled(false)
            }
        }
    }

    var offGridForcedByPolicy: Bool { EnterprisePolicyGate.requiresOffGrid }

    // MARK: Disconnect

    /// `keepDatasets` is only honored for dataset-only workspaces: saved company
    /// datasets are re-homed as personal Imported datasets. Under Full Noema Control
    /// company data is always deleted when leaving.
    func disconnect(keepDatasets: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        if let token = deviceToken {
            try? await client.disconnect(deviceToken: token)
        }
        let canKeepDatasets = keepDatasets && EnterprisePolicyGate.governanceMode == "datasets"
        clearDeviceToken()
        let requiredOffGrid = EnterprisePolicyGate.requiresOffGrid
        EnterprisePolicyGate.setSnapshot(nil)
        EnterprisePolicyStorage.clearAll()
        UserDefaults.standard.removeObject(forKey: Self.lastSyncDefaultsKey)
        if requiredOffGrid {
            applyOffGridMapping() // clears the allowlist and restores forced off-grid
        }
        if canKeepDatasets {
            await EnterpriseDatasetStore.shared.rehomeAllToImported()
        } else {
            await EnterpriseDatasetStore.shared.purgeAll()
        }
        policy = nil
        availableDatasets = []
        installedDatasetIDs = []
        lastSyncAt = nil
        devVerificationCode = nil
        state = .disconnected
    }
}
