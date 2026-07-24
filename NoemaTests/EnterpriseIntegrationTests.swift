import Foundation
import XCTest
@testable import Noema

// MARK: - Kill switch allowlist

final class NetworkKillSwitchEnterpriseAllowlistTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NetworkKillSwitch.setEnabled(false)
        NetworkKillSwitch.setEnterpriseAllowedHosts([])
    }

    override func tearDown() {
        NetworkKillSwitch.setEnabled(false)
        NetworkKillSwitch.setEnterpriseAllowedHosts([])
        super.tearDown()
    }

    func testAllowlistedHostPassesOnlyOverHTTPS() throws {
        NetworkKillSwitch.setEnterpriseAllowedHosts(["api.noemaai.com"])
        NetworkKillSwitch.setEnabled(true)

        XCTAssertFalse(NetworkKillSwitch.shouldBlock(url: URL(string: "https://api.noemaai.com/v1/teams/policy")))
        // Plain HTTP to the same host stays blocked.
        XCTAssertTrue(NetworkKillSwitch.shouldBlock(url: URL(string: "http://api.noemaai.com/v1/teams/policy")))
        // Other hosts stay blocked.
        XCTAssertTrue(NetworkKillSwitch.shouldBlock(url: URL(string: "https://example.com")))
        XCTAssertTrue(NetworkKillSwitch.shouldBlock(url: URL(string: "https://search.noemaai.com/v1/search")))
        // Loopback unaffected.
        XCTAssertFalse(NetworkKillSwitch.shouldBlock(url: URL(string: "http://127.0.0.1:8080")))
    }

    func testHostMatchingIsCaseInsensitive() {
        NetworkKillSwitch.setEnterpriseAllowedHosts(["API.NoemaAI.com"])
        NetworkKillSwitch.setEnabled(true)
        XCTAssertFalse(NetworkKillSwitch.shouldBlock(url: URL(string: "https://api.noemaai.com/x")))
    }

    func testClearingAllowlistRestoresBlocking() {
        NetworkKillSwitch.setEnterpriseAllowedHosts(["api.noemaai.com"])
        NetworkKillSwitch.setEnabled(true)
        XCTAssertFalse(NetworkKillSwitch.shouldBlock(url: URL(string: "https://api.noemaai.com/x")))
        NetworkKillSwitch.setEnterpriseAllowedHosts([])
        XCTAssertTrue(NetworkKillSwitch.shouldBlock(url: URL(string: "https://api.noemaai.com/x")))
    }

    func testWouldBlockHonorsAllowlist() {
        NetworkKillSwitch.setEnterpriseAllowedHosts(["api.noemaai.com"])
        XCTAssertFalse(NetworkKillSwitch.wouldBlock(url: URL(string: "https://api.noemaai.com/x")))
        XCTAssertTrue(NetworkKillSwitch.wouldBlock(url: URL(string: "https://example.com")))
    }
}

// MARK: - Tool gates under policy

final class ToolGateEnterprisePolicyTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let touchedKeys = [
        "webSearchEnabled", "webSearchArmed", "pythonEnabled", "pythonArmed",
        "memoryEnabled", "offGrid", "currentModelIsRemote", "currentModelFormat",
        "currentModelSupportsFunctionCalling", "selectedDatasetID", "indexingDatasetIDPersisted",
    ]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in touchedKeys {
            savedDefaults[key] = defaults.object(forKey: key)
        }
        EnterprisePolicyGate.resetForTesting()
        EnterprisePolicyGate.setSnapshot(nil)
        // Make every legacy gate condition pass so only enterprise policy decides.
        defaults.set(true, forKey: "webSearchEnabled")
        defaults.set(true, forKey: "webSearchArmed")
        defaults.set(true, forKey: "pythonEnabled")
        defaults.set(true, forKey: "pythonArmed")
        defaults.set(true, forKey: "memoryEnabled")
        defaults.set(false, forKey: "offGrid")
        defaults.set(false, forKey: "currentModelIsRemote")
        defaults.set("GGUF", forKey: "currentModelFormat")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
        defaults.set("", forKey: "selectedDatasetID")
        defaults.set("", forKey: "indexingDatasetIDPersisted")
        NetworkKillSwitch.setEnabled(false)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in touchedKeys {
            if let value = savedDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        EnterprisePolicyGate.resetForTesting()
        EnterprisePolicyGate.setSnapshot(nil)
        NetworkKillSwitch.setEnabled(false)
        super.tearDown()
    }

    private func activate(allowedToolNames: [String]?) {
        EnterprisePolicyGate.setSnapshot(
            EnterpriseGateSnapshot(
                policy: EnterpriseTestFixtures.policy(allowedToolNames: allowedToolNames),
                status: .valid
            )
        )
    }

    func testGatesOpenWithoutPolicy() {
        XCTAssertTrue(WebToolGate.isAvailable(currentFormat: .gguf))
        XCTAssertTrue(PythonToolGate.isAvailable(currentFormat: .gguf))
        XCTAssertTrue(MemoryToolGate.isAvailable(currentFormat: .gguf))
    }

    func testPolicyBlocksEachGateRegardlessOfUserToggles() {
        activate(allowedToolNames: [])
        XCTAssertFalse(WebToolGate.isAvailable(currentFormat: .gguf))
        XCTAssertFalse(PythonToolGate.isAvailable(currentFormat: .gguf))
        XCTAssertFalse(MemoryToolGate.isAvailable(currentFormat: .gguf))
    }

    func testPolicyAllowsListedToolsOnly() {
        activate(allowedToolNames: ["noema.web.retrieve"])
        XCTAssertTrue(WebToolGate.isAvailable(currentFormat: .gguf))
        XCTAssertFalse(PythonToolGate.isAvailable(currentFormat: .gguf))
        XCTAssertFalse(MemoryToolGate.isAvailable(currentFormat: .gguf))
    }

    @MainActor
    func testToolManagerHonorsPolicy() async {
        activate(allowedToolNames: ["noema.math.calculate"])
        let pythonAvailable = await ToolManager.shared.isToolAvailable("noema.python.execute")
        XCTAssertFalse(pythonAvailable)
        let webAvailable = await ToolManager.shared.isToolAvailable("noema.web.retrieve")
        XCTAssertFalse(webAvailable)
    }
}

// MARK: - Manager state machine (storage-driven)

@MainActor
final class EnterpriseStateMachineTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enterprise-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        EnterprisePolicyStorage.directoryOverrideForTesting = tempDir
        EnterprisePolicyGate.resetForTesting()
        try? KeychainStore.delete(service: "ai.noema.enterprise", account: "deviceToken")
        // Background refresh from bootstrap must never reach the real server in tests.
        UserDefaults.standard.set("http://127.0.0.1:9", forKey: "enterpriseAPIBaseURL")
    }

    override func tearDown() async throws {
        EnterprisePolicyStorage.directoryOverrideForTesting = nil
        EnterprisePolicyGate.resetForTesting()
        EnterprisePolicyGate.setSnapshot(nil)
        NetworkKillSwitch.setEnterpriseAllowedHosts([])
        NetworkKillSwitch.setEnabled(false)
        try? KeychainStore.delete(service: "ai.noema.enterprise", account: "deviceToken")
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: "enterpriseAPIBaseURL")
        UserDefaults.standard.removeObject(forKey: "enterpriseOffGridForced")
        UserDefaults.standard.removeObject(forKey: "offGrid")
        try await super.tearDown()
    }

    private func storeToken() {
        try? KeychainStore.write(
            service: "ai.noema.enterprise",
            account: "deviceToken",
            data: Data("ntd_test-token".utf8)
        )
    }

    private func context(_ phase: EnterpriseStoredContext.Phase, enrollmentID: String? = nil) {
        EnterprisePolicyStorage.saveContext(
            EnterpriseStoredContext(
                phase: phase,
                companyCode: "ACME-DEV001",
                tenantName: "Acme Research",
                email: "eng@acme.test",
                enrollmentID: enrollmentID
            )
        )
    }

    private func snapshot(expiresAt: Date, status: EnterpriseEnforcementStatus = .valid) {
        EnterprisePolicyStorage.saveSnapshot(
            EnterpriseGateSnapshot(
                policy: EnterpriseTestFixtures.policy(expiresAt: expiresAt),
                status: status
            ),
            rawPayload: nil
        )
    }

    func testFreshInstallIsNone() {
        XCTAssertEqual(EnterprisePolicyManager(verifier: StubPolicySignatureVerifier()).state, .none)
    }

    func testAwaitingVerificationRestoredFromContext() {
        context(.awaitingCode, enrollmentID: "enroll-1")
        let manager = EnterprisePolicyManager()
        XCTAssertEqual(manager.state, .awaitingEmailVerification(enrollmentID: "enroll-1"))
    }

    func testPendingApprovalRestoredFromContext() {
        context(.pendingApproval, enrollmentID: "enroll-2")
        let manager = EnterprisePolicyManager()
        XCTAssertEqual(manager.state, .pendingApproval(enrollmentID: "enroll-2"))
    }

    func testConnectedWithValidSnapshotAndToken() {
        storeToken()
        context(.connected)
        snapshot(expiresAt: Date().addingTimeInterval(3600))
        let manager = EnterprisePolicyManager()
        XCTAssertEqual(manager.state, .connected)
        XCTAssertNotNil(manager.policy)
    }

    func testExpiredSnapshotYieldsPolicyExpired() {
        storeToken()
        context(.connected)
        snapshot(expiresAt: Date().addingTimeInterval(-3600))
        let manager = EnterprisePolicyManager()
        XCTAssertEqual(manager.state, .policyExpired)
    }

    func testRevokedContextYieldsDeviceRevoked() {
        storeToken()
        context(.revoked)
        snapshot(expiresAt: Date().addingTimeInterval(3600), status: .revoked)
        let manager = EnterprisePolicyManager()
        XCTAssertEqual(manager.state, .deviceRevoked)
    }

    func testInvalidContextYieldsPolicyInvalid() {
        storeToken()
        context(.invalid)
        snapshot(expiresAt: Date().addingTimeInterval(3600), status: .invalid)
        let manager = EnterprisePolicyManager()
        XCTAssertEqual(manager.state, .policyInvalid)
    }

    func testDisconnectedContextYieldsDisconnected() {
        context(.disconnected)
        let manager = EnterprisePolicyManager()
        XCTAssertEqual(manager.state, .disconnected)
    }

    func testReapplyingPolicyRestoresMandatoryOffGridAfterSettingsReset() {
        let manager = EnterprisePolicyManager()
        let snapshot = EnterpriseGateSnapshot(
            policy: EnterpriseTestFixtures.policy(requiresOffGrid: true),
            status: .valid
        )
        EnterprisePolicyGate.setSnapshot(snapshot)
        UserDefaults.standard.set(false, forKey: "offGrid")
        UserDefaults.standard.removeObject(forKey: "enterpriseOffGridForced")
        NetworkKillSwitch.setEnabled(false)

        manager.reapplyOffGridMapping()

        XCTAssertTrue(UserDefaults.standard.bool(forKey: "offGrid"))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "enterpriseOffGridForced"))
        XCTAssertTrue(NetworkKillSwitch.isEnabled)
    }

    func testReconnectDeadlinePassedWipesCompanyData() async throws {
        storeToken()
        context(.connected)
        // A saved company dataset that must be purged when the window elapses.
        let datasetRoot = EnterpriseDatasetStore.rootDirectory
        try? FileManager.default.removeItem(at: datasetRoot)
        try FileManager.default.createDirectory(
            at: datasetRoot.appendingPathComponent("ds-1"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: datasetRoot) }

        let manager = EnterprisePolicyManager()
        // Last sync 30 days ago with a 7-day reconnect window → overdue.
        let overdue = EnterpriseGateSnapshot(
            policy: EnterpriseTestFixtures.policy(
                reconnectIntervalDays: 7,
                issuedAt: Date().addingTimeInterval(-30 * 86_400),
                expiresAt: Date().addingTimeInterval(-29 * 86_400)
            ),
            status: .valid
        )
        EnterprisePolicyStorage.saveSnapshot(overdue, rawPayload: nil)
        EnterprisePolicyGate.setSnapshot(overdue)

        _ = await manager.enforceReconnectDeadlineIfNeeded()

        // Whether the explicit call or the bootstrap task performed it, the end state is a
        // full local wipe: no token, no snapshot/context, datasets gone, explanatory message.
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(EnterprisePolicyStorage.loadSnapshot())
        XCTAssertNil(EnterprisePolicyStorage.loadContext())
        XCTAssertNil(try? KeychainStore.read(service: "ai.noema.enterprise", account: "deviceToken"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: datasetRoot.path))
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    func testWithinReconnectWindowDoesNotWipe() async {
        storeToken()
        context(.connected)
        let fresh = EnterpriseGateSnapshot(
            policy: EnterpriseTestFixtures.policy(
                reconnectIntervalDays: 30,
                issuedAt: Date().addingTimeInterval(-2 * 86_400),
                expiresAt: Date().addingTimeInterval(3600)
            ),
            status: .valid
        )
        EnterprisePolicyStorage.saveSnapshot(fresh, rawPayload: nil)
        EnterprisePolicyGate.setSnapshot(fresh)

        let manager = EnterprisePolicyManager()
        let wiped = await manager.enforceReconnectDeadlineIfNeeded()
        XCTAssertFalse(wiped)
        XCTAssertNotNil(EnterprisePolicyStorage.loadSnapshot())
    }

    func testCancelEnrollmentClearsEverything() {
        context(.awaitingCode, enrollmentID: "enroll-3")
        let manager = EnterprisePolicyManager()
        manager.cancelEnrollment()
        XCTAssertEqual(manager.state, .none)
        XCTAssertNil(EnterprisePolicyStorage.loadContext())
    }

    func testSnapshotPersistenceRoundTrip() {
        let policy = EnterpriseTestFixtures.policy(allowedToolNames: ["noema.memory"])
        EnterprisePolicyStorage.saveSnapshot(
            EnterpriseGateSnapshot(policy: policy, status: .valid),
            rawPayload: Data("{}".utf8)
        )
        let loaded = EnterprisePolicyStorage.loadSnapshot()
        XCTAssertEqual(loaded?.policy.allowedToolNames, ["noema.memory"])
        XCTAssertEqual(loaded?.status, .valid)
        EnterprisePolicyStorage.clearAll()
        XCTAssertNil(EnterprisePolicyStorage.loadSnapshot())
        XCTAssertNil(EnterprisePolicyStorage.loadContext())
    }
}

// MARK: - API client (no network; deterministic paths only)

final class EnterpriseAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "enterpriseAPIBaseURL")
        NetworkKillSwitch.setEnabled(false)
        NetworkKillSwitch.setEnterpriseAllowedHosts([])
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "enterpriseAPIBaseURL")
        NetworkKillSwitch.setEnabled(false)
        NetworkKillSwitch.setEnterpriseAllowedHosts([])
        super.tearDown()
    }

    func testDefaultBaseURL() {
        XCTAssertEqual(EnterpriseAPIClient.baseURL().host, "api.noemaai.com")
    }

    func testUserDefaultsOverrideWins() {
        UserDefaults.standard.set("http://127.0.0.1:8787", forKey: "enterpriseAPIBaseURL")
        XCTAssertEqual(EnterpriseAPIClient.baseURL().absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(EnterpriseAPIClient.apiHost, "127.0.0.1")
    }

    func testInvalidOverrideFallsBack() {
        UserDefaults.standard.set("not a url", forKey: "enterpriseAPIBaseURL")
        XCTAssertEqual(EnterpriseAPIClient.baseURL().host, "api.noemaai.com")
    }

    func testKillSwitchBlocksClientWhenHostNotAllowlisted() async {
        NetworkKillSwitch.setEnabled(true)
        let client = EnterpriseAPIClient()
        do {
            _ = try await client.lookup(companyCode: "ACME-DEV001")
            XCTFail("Expected the kill switch to block the request")
        } catch let error as EnterpriseAPIError {
            guard case .network = error else {
                return XCTFail("Expected .network, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Dataset store

final class EnterpriseDatasetStoreTests: XCTestCase {
    func testRootLivesUnderLocalLLMDatasetsEnterprise() {
        let root = EnterpriseDatasetStore.rootDirectory
        let components = root.pathComponents
        XCTAssertEqual(Array(components.suffix(2)), ["LocalLLMDatasets", "Enterprise"])
        XCTAssertEqual(EnterpriseDatasetStore.ownerDirectoryName, "Enterprise")
    }

    func testRemoveDatasetsNotInKeepSetAndPurgeAll() async throws {
        let fm = FileManager.default
        let root = EnterpriseDatasetStore.rootDirectory
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root.appendingPathComponent("keep-me"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("drop-me"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let store = EnterpriseDatasetStore()
        await store.removeDatasets(notIn: ["keep-me"])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("keep-me").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("drop-me").path))

        await store.purgeAll()
        XCTAssertFalse(fm.fileExists(atPath: root.path))
    }

    func testInstalledManifestsRoundTrip() async throws {
        let fm = FileManager.default
        let root = EnterpriseDatasetStore.rootDirectory
        try? fm.removeItem(at: root)
        let datasetDir = root.appendingPathComponent("abc-123")
        try fm.createDirectory(at: datasetDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let manifest = EnterpriseDatasetManifest(
            enterpriseDatasetID: "abc-123",
            datasetID: "Enterprise/abc-123",
            tenantID: "tenant-1",
            name: "Handbook",
            description: nil,
            version: 3,
            allowedRoleIDs: [],
            embeddingModelID: nil,
            chunkCount: 0,
            createdAt: Date(),
            updatedAt: Date(),
            sourceMetadata: nil,
            hashMetadata: nil,
            signatureMetadata: nil
        )
        let data = try EnterprisePolicy.encoder().encode(manifest)
        try data.write(to: datasetDir.appendingPathComponent(".enterprise-manifest.json"))

        let store = EnterpriseDatasetStore()
        let installed = await store.installedManifests()
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.name, "Handbook")
        XCTAssertEqual(installed.first?.version, 3)
        XCTAssertEqual(installed.first?.datasetID, "Enterprise/abc-123")
    }
}
