import XCTest
@testable import Noema

final class PrivacyFeatureLabelAdvisorTests: XCTestCase {
    func testDefaultProfileShowsLocalAndNetworkCapableLabels() {
        let labels = PrivacyFeatureLabelAdvisor.labels(
            for: PrivacyFeatureLabelProfile(
                offGrid: false,
                webSearchEnabled: true,
                pythonEnabled: true,
                memoryEnabled: true,
                remoteRedactionEnabled: false
            )
        )

        XCTAssertEqual(labels.first(where: { $0.id == "local_model" })?.state, .local)
        XCTAssertEqual(labels.first(where: { $0.id == "dataset_retrieval" })?.state, .local)
        XCTAssertEqual(labels.first(where: { $0.id == "memory" })?.state, .local)
        XCTAssertEqual(labels.first(where: { $0.id == "python" })?.state, .localSandbox)
        XCTAssertEqual(labels.first(where: { $0.id == "web_search" })?.state, .optionalNetwork)
        XCTAssertEqual(labels.first(where: { $0.id == "remote_backends" })?.state, .remote)
        XCTAssertEqual(labels.first(where: { $0.id == "downloads_explore" })?.state, .optionalNetwork)
    }

    func testOffGridBlocksNetworkCapableLabels() {
        let labels = PrivacyFeatureLabelAdvisor.labels(
            for: PrivacyFeatureLabelProfile(
                offGrid: true,
                webSearchEnabled: true,
                pythonEnabled: true,
                memoryEnabled: true,
                remoteRedactionEnabled: false
            )
        )

        XCTAssertEqual(labels.first(where: { $0.id == "web_search" })?.state, .blocked)
        XCTAssertEqual(labels.first(where: { $0.id == "remote_backends" })?.state, .blocked)
        XCTAssertEqual(labels.first(where: { $0.id == "downloads_explore" })?.state, .blocked)
        XCTAssertEqual(labels.first(where: { $0.id == "python" })?.state, .localSandbox)
    }

    func testDisabledToolsAndRemoteRedactionDetailsAreReflected() {
        let labels = PrivacyFeatureLabelAdvisor.labels(
            for: PrivacyFeatureLabelProfile(
                offGrid: false,
                webSearchEnabled: false,
                pythonEnabled: false,
                memoryEnabled: false,
                remoteRedactionEnabled: true
            )
        )

        XCTAssertEqual(labels.first(where: { $0.id == "web_search" })?.state, .off)
        XCTAssertEqual(labels.first(where: { $0.id == "python" })?.state, .off)
        XCTAssertEqual(labels.first(where: { $0.id == "memory" })?.state, .off)
        XCTAssertEqual(
            labels.first(where: { $0.id == "remote_backends" })?.detailKey,
            "Remote prompts can leave the device; sensitive-data redaction is enabled."
        )
    }
}
