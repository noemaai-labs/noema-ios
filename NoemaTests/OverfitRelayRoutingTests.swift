import CloudKit
import XCTest
import RelayKit
@testable import Noema

final class OverfitRelayRoutingTests: XCTestCase {
    // MARK: - Advisor: nil Overfit input leaves existing decisions unchanged

    func testNilOverfitInputKeepsOffGridDecision() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .remoteFirst),
                selectedLocalModel: .init(format: .gguf, sizeGB: 4),
                remoteSelectionCount: 1,
                offGrid: true,
                lowPowerMode: false
            )
        )

        XCTAssertEqual(advice.route, .localOnly)
        XCTAssertEqual(advice.detail, .offGridLocal)
    }

    func testNilOverfitInputKeepsLargeGGUFFallbackDecision() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .localFirst),
                selectedLocalModel: .init(format: .gguf, sizeGB: 8),
                remoteSelectionCount: 1,
                offGrid: false,
                lowPowerMode: false
            )
        )

        XCTAssertEqual(advice.route, .localThenRemote)
        XCTAssertEqual(advice.detail, .largeLocalRemoteFallback)
    }

    func testNilOverfitInputKeepsRemotePriorityDecision() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .remoteFirst),
                selectedLocalModel: .init(format: .mlx, sizeGB: 4),
                remoteSelectionCount: 1,
                offGrid: false,
                lowPowerMode: false
            )
        )

        XCTAssertEqual(advice.route, .remoteThenLocal)
        XCTAssertEqual(advice.detail, .remotePriority)
    }

    // MARK: - Advisor: Overfit bias matrix

    func testRelayRecommendedPrefersRemoteWhenRemoteAvailable() {
        let advice = advice(classification: .relayRecommended, priority: .localFirst)

        XCTAssertEqual(advice.route, .remoteThenLocal)
        XCTAssertEqual(advice.detail, .remotePriority)
    }

    func testOfflineOnlyPrefersRemoteWhenRemoteAvailable() {
        let advice = advice(classification: .offlineOnly, priority: .localFirst)

        XCTAssertEqual(advice.route, .remoteThenLocal)
        XCTAssertEqual(advice.detail, .remotePriority)
    }

    func testPagedSlowKeepsLocalFirstWithRemoteFallbackEvenWhenRemotePreferred() {
        let advice = advice(classification: .pagedSlow, priority: .remoteFirst)

        XCTAssertEqual(advice.route, .localThenRemote)
        XCTAssertEqual(advice.detail, .largeLocalRemoteFallback)
    }

    func testPagedInteractiveFallsThroughToExistingHeuristics() {
        let advice = advice(classification: .pagedInteractive, priority: .localFirst)

        XCTAssertEqual(advice.route, .localThenRemote)
        XCTAssertEqual(advice.detail, .localPriority)
    }

    func testResidentInteractiveFallsThroughToExistingHeuristics() {
        let advice = advice(classification: .residentInteractive, priority: .remoteFirst)

        XCTAssertEqual(advice.route, .remoteThenLocal)
        XCTAssertEqual(advice.detail, .remotePriority)
    }

    func testRelayRecommendedWithoutRemoteStaysLocalOnly() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: false, priority: .localFirst),
                selectedLocalModel: .init(format: .gguf, sizeGB: 20),
                remoteSelectionCount: 0,
                offGrid: false,
                lowPowerMode: false,
                overfitClassification: .relayRecommended
            )
        )

        XCTAssertEqual(advice.route, .localOnly)
        XCTAssertEqual(advice.detail, .localOnly)
    }

    func testRelayRecommendedNeverEscapesOffGrid() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .remoteFirst),
                selectedLocalModel: .init(format: .gguf, sizeGB: 20),
                remoteSelectionCount: 1,
                offGrid: true,
                lowPowerMode: false,
                overfitClassification: .relayRecommended
            )
        )

        XCTAssertEqual(advice.route, .localOnly)
        XCTAssertEqual(advice.detail, .offGridLocal)
    }

    func testRelayRecommendedOutranksLowPowerHeuristic() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .localFirst),
                selectedLocalModel: .init(format: .gguf, sizeGB: 2),
                remoteSelectionCount: 1,
                offGrid: false,
                lowPowerMode: true,
                overfitClassification: .relayRecommended
            )
        )

        XCTAssertEqual(advice.route, .remoteThenLocal)
        XCTAssertEqual(advice.detail, .remotePriority)
    }

    // MARK: - Catalog wire compatibility

    func testRelayCatalogEntryRoundTripsOverfitFields() throws {
        let entry = RelayCatalogEntry(
            modelID: "model-1",
            originIdentifier: "local:foo:Q4_K_M",
            displayName: "Foo 30B (Q4_K_M)",
            provider: .local,
            identifier: "foo-30b",
            context: 8192,
            quant: "Q4_K_M",
            sizeBytes: 17_000_000_000,
            tags: ["gguf"],
            exposed: true,
            overfitClassification: OverfitFitClassification.pagedInteractive.rawValue,
            overfitMeasuredGenerationRate: 17.5
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RelayCatalogEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.overfitClassification, "pagedInteractive")
        XCTAssertEqual(try XCTUnwrap(decoded.overfitMeasuredGenerationRate), 17.5, accuracy: 0.0001)
    }

    func testRelayCatalogEntryDecodesLegacyJSONWithoutOverfitFields() throws {
        let legacyJSON = Data("""
        {
            "id": "8E2C2E7B-45F1-4B1A-9C3D-2A47E9D1B0AA",
            "modelID": "model-legacy",
            "originIdentifier": "local:legacy:Q4_K_M",
            "displayName": "Legacy 7B (Q4_K_M)",
            "providerRaw": "local",
            "identifier": "legacy-7b",
            "tags": [],
            "exposed": true,
            "health": "available"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(RelayCatalogEntry.self, from: legacyJSON)

        XCTAssertEqual(decoded.modelID, "model-legacy")
        XCTAssertNil(decoded.overfitClassification)
        XCTAssertNil(decoded.overfitMeasuredGenerationRate)
    }

    func testRelayModelRecordRoundTripsOverfitFieldsThroughCKRecord() throws {
        let record = CKRecord(recordType: RelayCatalogRecordType.model.rawValue)
        let model = RelayModelRecord(
            recordID: record.recordID,
            modelID: "model-1",
            hostDeviceID: "host-1",
            displayName: "Foo 30B (Q4_K_M)",
            provider: .local,
            endpointID: nil,
            identifier: "foo-30b",
            context: 8192,
            quant: "Q4_K_M",
            sizeBytes: 17_000_000_000,
            tags: ["gguf"],
            exposed: true,
            health: .available,
            lastChecked: nil,
            version: 3,
            overfitClassification: OverfitFitClassification.pagedSlow.rawValue,
            overfitMeasuredGenerationRate: 4.25
        )

        model.apply(to: record)
        let decoded = try XCTUnwrap(RelayModelRecord(record: record))

        XCTAssertEqual(decoded.overfitClassification, "pagedSlow")
        XCTAssertEqual(try XCTUnwrap(decoded.overfitMeasuredGenerationRate), 4.25, accuracy: 0.0001)
        XCTAssertEqual(decoded.modelID, model.modelID)
        XCTAssertEqual(decoded.version, model.version)
    }

    func testRelayModelRecordDecodesLegacyCKRecordWithoutOverfitFields() throws {
        let record = CKRecord(recordType: RelayCatalogRecordType.model.rawValue)
        record["modelID"] = "model-legacy" as CKRecordValue
        record["hostDeviceID"] = "host-1" as CKRecordValue
        record["displayName"] = "Legacy 7B" as CKRecordValue
        record["provider"] = RelayProviderKind.local.rawValue as CKRecordValue
        record["identifier"] = "legacy-7b" as CKRecordValue
        record["exposed"] = NSNumber(value: 1)
        record["health"] = RelayModelHealth.available.rawValue as CKRecordValue
        record["version"] = 1 as CKRecordValue

        let decoded = try XCTUnwrap(RelayModelRecord(record: record))

        XCTAssertNil(decoded.overfitClassification)
        XCTAssertNil(decoded.overfitMeasuredGenerationRate)
    }

    // MARK: - Helpers

    private func advice(classification: OverfitFitClassification,
                        priority: StartupPreferences.Priority) -> LocalRemoteRoutingAdvice {
        LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: priority),
                selectedLocalModel: .init(format: .gguf, sizeGB: 4),
                remoteSelectionCount: 1,
                offGrid: false,
                lowPowerMode: false,
                overfitClassification: classification
            )
        )
    }

    private func preferences(
        local: Bool,
        remote: Bool,
        priority: StartupPreferences.Priority
    ) -> StartupPreferences {
        StartupPreferences(
            localModelPath: local ? "/tmp/noema-model.gguf" : nil,
            remoteSelections: remote ? [
                .init(
                    backendID: UUID(uuidString: "F6AABCB2-F19D-4E54-8D85-6C130AF12B29")!,
                    backendName: "Mac Relay",
                    modelID: "remote-model",
                    modelName: "Remote Model"
                )
            ] : [],
            priority: priority
        )
    }
}
