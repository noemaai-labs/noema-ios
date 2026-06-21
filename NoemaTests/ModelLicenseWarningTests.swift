import XCTest
@testable import Noema

final class ModelLicenseWarningTests: XCTestCase {
    func testPermissiveLicensesDoNotRequireConfirmation() {
        XCTAssertEqual(ModelLicenseWarningPolicy.level(for: "Apache 2.0"), .permissive)
        XCTAssertEqual(ModelLicenseWarningPolicy.level(for: "MIT"), .permissive)
        XCTAssertFalse(ModelLicenseWarningPolicy.level(for: "BSD-3-Clause").requiresDownloadConfirmation)
    }

    func testRestrictiveLicensesRequireConfirmation() {
        let nonCommercial = ModelLicenseWarningPolicy.level(for: "Non-commercial license")
        let ccNC = ModelLicenseWarningPolicy.level(for: "CC-BY-NC-4.0")

        XCTAssertEqual(nonCommercial, .restricted)
        XCTAssertEqual(ccNC, .restricted)
        XCTAssertTrue(nonCommercial.requiresDownloadConfirmation)
        XCTAssertTrue(ccNC.requiresDownloadConfirmation)
    }

    func testUnknownLicensesRequireConfirmation() {
        XCTAssertEqual(ModelLicenseWarningPolicy.level(for: nil), .unknown)
        XCTAssertEqual(ModelLicenseWarningPolicy.level(for: "Unknown"), .unknown)
        XCTAssertTrue(ModelLicenseWarningPolicy.level(for: "No license listed").requiresDownloadConfirmation)
    }

    func testCustomLicensesAreReviewOnly() {
        let llama = ModelLicenseWarningPolicy.level(for: "Llama 3 Community License")
        let openRAIL = ModelLicenseWarningPolicy.level(for: "OpenRAIL")

        XCTAssertEqual(llama, .review)
        XCTAssertEqual(openRAIL, .review)
        XCTAssertFalse(llama.requiresDownloadConfirmation)
        XCTAssertFalse(openRAIL.requiresDownloadConfirmation)
    }
}
