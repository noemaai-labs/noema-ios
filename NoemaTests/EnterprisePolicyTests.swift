import Foundation
import XCTest
@testable import Noema

// MARK: - Shared fixtures

enum EnterpriseTestFixtures {
    /// Mirrors server/teams-api/fixtures/policy.json (the backend contract test
    /// asserts the same key set). Prefer reading the shared file; fall back to the
    /// embedded copy when tests run outside the repo checkout.
    static func canonicalPolicyJSON() -> Data {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // NoemaTests
            .deletingLastPathComponent() // Noema (project dir)
            .deletingLastPathComponent() // repo root
        let shared = repoRoot
            .appendingPathComponent("server/teams-api/fixtures/policy.json")
        if let data = try? Data(contentsOf: shared) {
            return data
        }
        return Data(embeddedPolicyJSON.utf8)
    }

    static let embeddedPolicyJSON = """
    {
      "tenantID": "11111111-1111-1111-1111-111111111111",
      "tenantName": "Acme Research",
      "workspaceSlug": "acme",
      "companyCode": "ACME-DEV001",
      "membershipID": "22222222-2222-2222-2222-222222222222",
      "userEmail": "eng@acme.test",
      "displayName": "Erin Engineer",
      "roleIDs": ["33333333-3333-3333-3333-333333333333"],
      "roleNames": ["Engineering"],
      "deviceID": "44444444-4444-4444-4444-444444444444",
      "allowedModelFormats": ["GGUF", "MLX"],
      "allowedModelIDs": null,
      "allowedRemoteBackendIDs": ["55555555-5555-5555-5555-555555555555"],
      "allowedRemoteEndpointTypes": ["openAI", "lmStudio"],
      "allowedToolNames": ["noema.web.retrieve", "noema.memory", "noema.math.calculate", "noema.units.convert"],
      "allowedDatasetIDs": ["Enterprise/66666666-6666-6666-6666-666666666666"],
      "requiresOffGrid": false,
      "remoteInferenceAllowed": false,
      "datasetDownloadAllowed": true,
      "governanceMode": "full",
      "issuedAt": "2026-06-09T12:00:00Z",
      "expiresAt": "2026-06-10T12:00:00Z",
      "policyVersion": 7,
      "signatureMetadata": {"scheme": "unsigned-v1", "keyID": null, "signature": null}
    }
    """

    static func decodedPolicy() throws -> EnterprisePolicy {
        try EnterprisePolicy.decoder().decode(EnterprisePolicy.self, from: canonicalPolicyJSON())
    }

    static func policy(
        allowedModelFormats: [String]? = nil,
        allowedModelIDs: [String]? = nil,
        allowedRemoteBackendIDs: [String]? = nil,
        allowedRemoteEndpointTypes: [String]? = nil,
        allowedToolNames: [String]? = nil,
        allowedDatasetIDs: [String] = [],
        requiresOffGrid: Bool = false,
        remoteInferenceAllowed: Bool = true,
        datasetDownloadAllowed: Bool = true,
        reconnectIntervalDays: Int? = nil,
        issuedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(3600),
        scheme: String = "unsigned-v1"
    ) -> EnterprisePolicy {
        EnterprisePolicy(
            tenantID: "tenant-1",
            tenantName: "Acme Research",
            workspaceSlug: "acme",
            companyCode: "ACME-DEV001",
            membershipID: "member-1",
            userEmail: "eng@acme.test",
            displayName: "Erin",
            roleIDs: ["role-1"],
            roleNames: ["Engineering"],
            deviceID: "device-1",
            allowedModelFormats: allowedModelFormats,
            allowedModelIDs: allowedModelIDs,
            allowedRemoteBackendIDs: allowedRemoteBackendIDs,
            allowedRemoteEndpointTypes: allowedRemoteEndpointTypes,
            allowedToolNames: allowedToolNames,
            allowedDatasetIDs: allowedDatasetIDs,
            requiresOffGrid: requiresOffGrid,
            remoteInferenceAllowed: remoteInferenceAllowed,
            datasetDownloadAllowed: datasetDownloadAllowed,
            reconnectIntervalDays: reconnectIntervalDays,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            policyVersion: 1,
            signatureMetadata: EnterpriseSignatureMetadata(scheme: scheme, keyID: nil, signature: nil)
        )
    }
}

// MARK: - Codable contract

final class EnterprisePolicyCodableTests: XCTestCase {
    func testDecodesCanonicalFixture() throws {
        let policy = try EnterpriseTestFixtures.decodedPolicy()
        XCTAssertEqual(policy.tenantName, "Acme Research")
        XCTAssertEqual(policy.companyCode, "ACME-DEV001")
        XCTAssertEqual(policy.roleNames, ["Engineering"])
        XCTAssertEqual(policy.allowedModelFormats, ["GGUF", "MLX"])
        XCTAssertNil(policy.allowedModelIDs) // null = unrestricted
        XCTAssertEqual(policy.allowedToolNames?.count, 4)
        XCTAssertEqual(policy.allowedDatasetIDs, ["Enterprise/66666666-6666-6666-6666-666666666666"])
        XCTAssertFalse(policy.requiresOffGrid)
        XCTAssertFalse(policy.remoteInferenceAllowed)
        XCTAssertTrue(policy.datasetDownloadAllowed)
        XCTAssertEqual(policy.policyVersion, 7)
        XCTAssertEqual(policy.governanceMode, "full")
        XCTAssertEqual(policy.signatureMetadata.scheme, "unsigned-v1")

        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: policy.issuedAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 9)
        components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: policy.expiresAt)
        XCTAssertEqual(components.day, 10)
    }

    func testRoundTripPreservesEquality() throws {
        let policy = try EnterpriseTestFixtures.decodedPolicy()
        let encoded = try EnterprisePolicy.encoder().encode(policy)
        let decoded = try EnterprisePolicy.decoder().decode(EnterprisePolicy.self, from: encoded)
        XCTAssertEqual(policy, decoded)
    }

    func testEmptyArrayIsNotUnrestricted() throws {
        var policy = try EnterpriseTestFixtures.decodedPolicy()
        policy.allowedToolNames = []
        let encoded = try EnterprisePolicy.encoder().encode(policy)
        let decoded = try EnterprisePolicy.decoder().decode(EnterprisePolicy.self, from: encoded)
        XCTAssertEqual(decoded.allowedToolNames, [])
        XCTAssertNotNil(decoded.allowedToolNames)
    }

    func testManifestDecoding() throws {
        let json = """
        {
          "enterpriseDatasetID": "66666666-6666-6666-6666-666666666666",
          "datasetID": "Enterprise/66666666-6666-6666-6666-666666666666",
          "tenantID": "11111111-1111-1111-1111-111111111111",
          "name": "Acme Handbook",
          "description": "Employee handbook",
          "version": 2,
          "allowedRoleIDs": ["role-1"],
          "embeddingModelID": null,
          "chunkCount": 0,
          "createdAt": "2026-06-09T12:00:00Z",
          "updatedAt": "2026-06-09T12:00:00Z",
          "sourceMetadata": {"uploadedBy": "admin@acme.test", "fileCount": 2},
          "hashMetadata": {"algorithm": "sha256", "contentHash": "abc"},
          "signatureMetadata": {"scheme": "unsigned-v1", "keyID": null, "signature": null}
        }
        """
        let manifest = try EnterprisePolicy.decoder().decode(EnterpriseDatasetManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.name, "Acme Handbook")
        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.datasetID, "Enterprise/\(manifest.enterpriseDatasetID)")
        XCTAssertEqual(manifest.hashMetadata?.contentHash, "abc")
    }

    func testVerifierAcceptsUnsignedV1AndRejectsUnknownScheme() throws {
        let verifier = StubPolicySignatureVerifier()
        let good = EnterpriseTestFixtures.policy()
        XCTAssertNoThrow(try verifier.verify(policy: good, rawPayload: Data()))
        let bad = EnterpriseTestFixtures.policy(scheme: "ed25519-v9")
        XCTAssertThrowsError(try verifier.verify(policy: bad, rawPayload: Data())) { error in
            XCTAssertEqual(error as? EnterprisePolicyError, .unknownSignatureScheme("ed25519-v9"))
        }
    }
}

// MARK: - Gate enforcement

final class EnterprisePolicyGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EnterprisePolicyGate.resetForTesting()
        EnterprisePolicyGate.setSnapshot(nil)
    }

    override func tearDown() {
        EnterprisePolicyGate.resetForTesting()
        EnterprisePolicyGate.setSnapshot(nil)
        super.tearDown()
    }

    private func activate(_ policy: EnterprisePolicy, status: EnterpriseEnforcementStatus = .valid) {
        EnterprisePolicyGate.setSnapshot(EnterpriseGateSnapshot(policy: policy, status: status))
    }

    func testInactiveGateAllowsEverythingExceptOrphanedEnterpriseDatasets() {
        XCTAssertFalse(EnterprisePolicyGate.isActive)
        XCTAssertTrue(EnterprisePolicyGate.allowsTool("noema.python.execute"))
        XCTAssertTrue(EnterprisePolicyGate.allowsModelFormat(.mlx))
        XCTAssertTrue(EnterprisePolicyGate.allowsModel(modelID: "anything"))
        XCTAssertTrue(EnterprisePolicyGate.allowsRemoteBackend(id: UUID(), endpointType: .openAI))
        XCTAssertTrue(EnterprisePolicyGate.remoteInferenceAllowed)
        XCTAssertTrue(EnterprisePolicyGate.datasetDownloadAllowed)
        XCTAssertFalse(EnterprisePolicyGate.requiresOffGrid)
        XCTAssertTrue(EnterprisePolicyGate.allowsDataset(datasetID: "Imported/notes"))
        // Orphaned enterprise directories stay hidden without an active policy.
        XCTAssertFalse(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/leftover"))
    }

    func testNilAllowlistsAreUnrestricted() {
        activate(EnterpriseTestFixtures.policy())
        XCTAssertTrue(EnterprisePolicyGate.allowsTool("noema.python.execute"))
        XCTAssertTrue(EnterprisePolicyGate.allowsModelFormat(.coreai))
        XCTAssertTrue(EnterprisePolicyGate.allowsModel(modelID: "any/model"))
        XCTAssertTrue(EnterprisePolicyGate.allowsRemoteBackend(id: UUID(), endpointType: .ollama))
    }

    func testToolAllowlist() {
        activate(EnterpriseTestFixtures.policy(allowedToolNames: ["noema.memory"]))
        XCTAssertTrue(EnterprisePolicyGate.allowsTool("noema.memory"))
        XCTAssertFalse(EnterprisePolicyGate.allowsTool("noema.python.execute"))
        XCTAssertFalse(EnterprisePolicyGate.allowsTool("noema.web.retrieve"))
    }

    func testModelFormatAllowlist() {
        activate(EnterpriseTestFixtures.policy(allowedModelFormats: ["GGUF", "MLX"]))
        XCTAssertTrue(EnterprisePolicyGate.allowsModelFormat(.gguf))
        XCTAssertTrue(EnterprisePolicyGate.allowsModelFormat(.mlx))
        XCTAssertFalse(EnterprisePolicyGate.allowsModelFormat(.afm))
        XCTAssertFalse(EnterprisePolicyGate.allowsModelFormat(.coreai))
    }

    func testModelIDAllowlistDeniesUnknownModels() {
        activate(EnterpriseTestFixtures.policy(allowedModelIDs: ["org/approved-model"]))
        XCTAssertTrue(EnterprisePolicyGate.allowsModel(modelID: "org/approved-model"))
        XCTAssertFalse(EnterprisePolicyGate.allowsModel(modelID: "org/other-model"))
        // Unidentifiable model under an explicit allowlist: deny.
        XCTAssertFalse(EnterprisePolicyGate.allowsModel(modelID: nil))
    }

    func testRemoteBackendChecks() {
        let allowedID = UUID()
        let otherID = UUID()
        activate(EnterpriseTestFixtures.policy(
            allowedRemoteBackendIDs: [allowedID.uuidString.lowercased()],
            allowedRemoteEndpointTypes: ["openAI"]
        ))
        XCTAssertTrue(EnterprisePolicyGate.allowsRemoteBackend(id: allowedID, endpointType: .openAI))
        XCTAssertFalse(EnterprisePolicyGate.allowsRemoteBackend(id: otherID, endpointType: .openAI))
        XCTAssertFalse(EnterprisePolicyGate.allowsRemoteBackend(id: allowedID, endpointType: .ollama))
    }

    func testRemoteInferenceDisabledBlocksAllBackends() {
        activate(EnterpriseTestFixtures.policy(remoteInferenceAllowed: false))
        XCTAssertFalse(EnterprisePolicyGate.remoteInferenceAllowed)
        XCTAssertFalse(EnterprisePolicyGate.allowsRemoteBackend(id: UUID(), endpointType: .openAI))
    }

    func testDatasetAllowlist() {
        activate(EnterpriseTestFixtures.policy(allowedDatasetIDs: ["Enterprise/abc"]))
        XCTAssertTrue(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/abc"))
        XCTAssertFalse(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/other"))
        // Personal datasets are never policy-gated.
        XCTAssertTrue(EnterprisePolicyGate.allowsDataset(datasetID: "Imported/mine"))
        XCTAssertTrue(EnterprisePolicyGate.allowsDataset(datasetID: "OTL/textbook"))
    }

    func testExpiredWithinGraceKeepsEnforcingCachedPolicy() {
        let expired = EnterpriseTestFixtures.policy(
            allowedToolNames: ["noema.memory"],
            allowedDatasetIDs: ["Enterprise/abc"],
            expiresAt: Date().addingTimeInterval(-3600) // 1h past expiry, well within 72h grace
        )
        activate(expired)
        XCTAssertFalse(EnterprisePolicyGate.allowsTool("noema.python.execute"))
        XCTAssertTrue(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/abc"))
    }

    func testPastGraceFailsClosedForDatasetsButKeepsRestrictions() {
        let longGone = EnterpriseTestFixtures.policy(
            allowedToolNames: ["noema.memory"],
            allowedDatasetIDs: ["Enterprise/abc"],
            expiresAt: Date().addingTimeInterval(-(EnterprisePolicyGate.gracePeriod + 3600))
        )
        activate(longGone)
        // Restrictions remain in force.
        XCTAssertFalse(EnterprisePolicyGate.allowsTool("noema.python.execute"))
        XCTAssertTrue(EnterprisePolicyGate.allowsTool("noema.memory"))
        // Enterprise datasets are denied.
        XCTAssertFalse(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/abc"))
        XCTAssertFalse(EnterprisePolicyGate.datasetDownloadAllowed)
    }

    func testRevokedKeepsRestrictionsAndDeniesDatasets() {
        let policy = EnterpriseTestFixtures.policy(
            allowedToolNames: ["noema.memory"],
            allowedDatasetIDs: ["Enterprise/abc"]
        )
        activate(policy, status: .revoked)
        XCTAssertFalse(EnterprisePolicyGate.allowsTool("noema.python.execute"))
        XCTAssertFalse(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/abc"))
        XCTAssertTrue(EnterprisePolicyGate.allowsDataset(datasetID: "Imported/mine"))
    }

    func testInvalidPolicyKeepsRestrictionsAndDeniesDatasets() {
        let policy = EnterpriseTestFixtures.policy(
            allowedModelFormats: ["GGUF"],
            allowedDatasetIDs: ["Enterprise/abc"]
        )
        activate(policy, status: .invalid)
        XCTAssertFalse(EnterprisePolicyGate.allowsModelFormat(.mlx))
        XCTAssertTrue(EnterprisePolicyGate.allowsModelFormat(.gguf))
        XCTAssertFalse(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/abc"))
    }

    func testRequiresOffGrid() {
        activate(EnterpriseTestFixtures.policy(requiresOffGrid: true))
        XCTAssertTrue(EnterprisePolicyGate.requiresOffGrid)
    }

    // MARK: Reconnect deadline (offline dead-man's switch)

    func testNoReconnectIntervalMeansNoDeadline() {
        // issuedAt long ago, but no interval configured → never overdue, no deadline.
        activate(EnterpriseTestFixtures.policy(
            reconnectIntervalDays: nil,
            issuedAt: Date().addingTimeInterval(-365 * 86_400)
        ))
        XCTAssertNil(EnterprisePolicyGate.activeReconnectDeadline)
        XCTAssertFalse(EnterprisePolicyGate.reconnectDeadlinePassed)
    }

    func testReconnectDeadlineIsIssuedAtPlusInterval() {
        let issued = Date(timeIntervalSince1970: 1_000_000)
        activate(EnterpriseTestFixtures.policy(reconnectIntervalDays: 7, issuedAt: issued))
        XCTAssertEqual(
            EnterprisePolicyGate.activeReconnectDeadline,
            issued.addingTimeInterval(7 * 86_400)
        )
    }

    func testWithinReconnectWindowKeepsServingDatasets() {
        // Synced 3 days ago, 7-day window: still trusted even though the short policy TTL expired.
        activate(EnterpriseTestFixtures.policy(
            allowedDatasetIDs: ["Enterprise/abc"],
            reconnectIntervalDays: 7,
            issuedAt: Date().addingTimeInterval(-3 * 86_400),
            expiresAt: Date().addingTimeInterval(-2 * 86_400)
        ))
        XCTAssertFalse(EnterprisePolicyGate.reconnectDeadlinePassed)
        XCTAssertTrue(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/abc"))
    }

    func testPastReconnectWindowFlagsOverdueAndDeniesDatasets() {
        // Last sync 10 days ago, 7-day window: overdue → datasets denied, download blocked.
        activate(EnterpriseTestFixtures.policy(
            allowedToolNames: ["noema.memory"],
            allowedDatasetIDs: ["Enterprise/abc"],
            reconnectIntervalDays: 7,
            issuedAt: Date().addingTimeInterval(-10 * 86_400),
            expiresAt: Date().addingTimeInterval(-9 * 86_400)
        ))
        XCTAssertTrue(EnterprisePolicyGate.reconnectDeadlinePassed)
        XCTAssertFalse(EnterprisePolicyGate.allowsDataset(datasetID: "Enterprise/abc"))
        XCTAssertFalse(EnterprisePolicyGate.datasetDownloadAllowed)
        // Other restrictions still apply while overdue.
        XCTAssertTrue(EnterprisePolicyGate.allowsTool("noema.memory"))
        XCTAssertFalse(EnterprisePolicyGate.allowsTool("noema.python.execute"))
    }

    func testZeroReconnectIntervalIsTreatedAsOff() {
        activate(EnterpriseTestFixtures.policy(
            reconnectIntervalDays: 0,
            issuedAt: Date().addingTimeInterval(-365 * 86_400)
        ))
        XCTAssertNil(EnterprisePolicyGate.activeReconnectDeadline)
        XCTAssertFalse(EnterprisePolicyGate.reconnectDeadlinePassed)
    }
}
