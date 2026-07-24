import XCTest
@testable import RelayKit

final class RelayCloudKitAccessTests: XCTestCase {
#if os(macOS)
    func testUnavailableDebugProcessDoesNotConstructContainer() {
        XCTAssertNil(
            RelayCloudKitAccess.containerIfAvailable("iCloud.example.Noema.unavailable-to-tests")
        )
    }
#endif

    func testAuthorizationRequiresMatchingContainerCloudKitServiceAndTeam() {
        XCTAssertTrue(
            RelayCloudKitAccess.isAuthorized(
                containerIdentifier: "iCloud.example.Noema",
                entitledContainerIdentifiers: ["iCloud.example.Noema"],
                services: ["CloudKit"],
                teamIdentifier: "TEAM123",
                signatureTeamIdentifier: "TEAM123"
            )
        )
    }

    func testAuthorizationRejectsUnsignedProcess() {
        XCTAssertFalse(
            RelayCloudKitAccess.isAuthorized(
                containerIdentifier: "iCloud.example.Noema",
                entitledContainerIdentifiers: ["iCloud.example.Noema"],
                services: ["CloudKit"],
                teamIdentifier: nil,
                signatureTeamIdentifier: nil
            )
        )
    }

    func testAuthorizationRejectsAdHocSignatureWithClaimedTeamEntitlement() {
        XCTAssertFalse(
            RelayCloudKitAccess.isAuthorized(
                containerIdentifier: "iCloud.example.Noema",
                entitledContainerIdentifiers: ["iCloud.example.Noema"],
                services: ["CloudKit"],
                teamIdentifier: "TEAM123",
                signatureTeamIdentifier: nil
            )
        )
    }

    func testAuthorizationRejectsDifferentSignatureTeam() {
        XCTAssertFalse(
            RelayCloudKitAccess.isAuthorized(
                containerIdentifier: "iCloud.example.Noema",
                entitledContainerIdentifiers: ["iCloud.example.Noema"],
                services: ["CloudKit"],
                teamIdentifier: "TEAM123",
                signatureTeamIdentifier: "OTHERTEAM"
            )
        )
    }

    func testAuthorizationRejectsDifferentContainer() {
        XCTAssertFalse(
            RelayCloudKitAccess.isAuthorized(
                containerIdentifier: "iCloud.example.Noema",
                entitledContainerIdentifiers: ["iCloud.example.Other"],
                services: ["CloudKit"],
                teamIdentifier: "TEAM123",
                signatureTeamIdentifier: "TEAM123"
            )
        )
    }
}
