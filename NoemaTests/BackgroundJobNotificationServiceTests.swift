import XCTest
@testable import Noema

final class BackgroundJobNotificationServiceTests: XCTestCase {
    func testDownloadCompletedSummaryUsesLocalizedBodyAndStableMetadata() {
        let url = URL(fileURLWithPath: "/tmp/noema/model.gguf")

        let first = BackgroundJobNotificationService.downloadCompletedSummary(
            destinationURL: url,
            locale: Locale(identifier: "en")
        )
        let second = BackgroundJobNotificationService.downloadCompletedSummary(
            destinationURL: url,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(first.identifier, second.identifier)
        XCTAssertEqual(first.title, "Download complete")
        XCTAssertEqual(first.body, "model.gguf finished downloading in the background.")
        XCTAssertEqual(first.threadIdentifier, "noema.background.downloads")
        XCTAssertEqual(first.userInfo["kind"], "download_completed")
        XCTAssertNotNil(first.userInfo["pathHash"])
        XCTAssertFalse(first.userInfo.values.contains(url.path))
    }
}
