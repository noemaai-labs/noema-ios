import XCTest
@testable import Noema

final class SensitiveDataDetectorTests: XCTestCase {
    func testScanSummarizesSensitiveFindingsWithoutValues() {
        let text = """
        Email me at ada@example.com or call 415-555-1234.
        SSN: 123-45-6789
        Card: 4242 4242 4242 4242
        Office: 123 Main Street
        Passport: A1234567
        api_key = sk-abcdefghijklmnopqrstuvwxyz123456
        password: correct-horse
        """

        let summary = SensitiveDataDetector.scan(text)

        XCTAssertEqual(
            summary.findings,
            [
                SensitiveDataFinding(kind: .emailAddress, count: 1),
                SensitiveDataFinding(kind: .phoneNumber, count: 1),
                SensitiveDataFinding(kind: .socialSecurityNumber, count: 1),
                SensitiveDataFinding(kind: .creditCardNumber, count: 1),
                SensitiveDataFinding(kind: .postalAddress, count: 1),
                SensitiveDataFinding(kind: .identityNumber, count: 1),
                SensitiveDataFinding(kind: .apiKey, count: 1),
                SensitiveDataFinding(kind: .password, count: 1)
            ]
        )
        XCTAssertEqual(summary.totalCount, 8)
        XCTAssertEqual(summary.logSummary, "email=1,phone=1,ssn=1,credit_card=1,address=1,id_number=1,api_key=1,password=1")
    }

    func testScanRejectsNonLuhnLongNumbersAsCards() {
        let summary = SensitiveDataDetector.scan("Ticket number 1234 5678 9012 3456 is not a card.")

        XCTAssertFalse(summary.findings.contains { $0.kind == .creditCardNumber })
    }

    func testRedactedRemotePreviewRemovesMatchedValues() {
        let redacted = SensitiveDataDetector.redactedForRemotePreview(
            "Contact ada@example.com with password: secret123 and card 4242424242424242."
        )

        XCTAssertFalse(redacted.contains("ada@example.com"))
        XCTAssertFalse(redacted.contains("secret123"))
        XCTAssertFalse(redacted.contains("4242424242424242"))
        XCTAssertTrue(redacted.contains("<email>"))
        XCTAssertTrue(redacted.contains("<password>"))
        XCTAssertTrue(redacted.contains("<credit_card>"))
    }

    func testRemoteRedactionIsOptIn() {
        let text = "Email ada@example.com about account number 12345-67890."

        let disabled = SensitiveDataDetector.redactedForRemote(text, enabled: false)
        XCTAssertEqual(disabled.text, text)
        XCTAssertFalse(disabled.redacted)
        XCTAssertEqual(disabled.summary.totalCount, 2)

        let enabled = SensitiveDataDetector.redactedForRemote(text, enabled: true)
        XCTAssertTrue(enabled.redacted)
        XCTAssertFalse(enabled.text.contains("ada@example.com"))
        XCTAssertFalse(enabled.text.contains("12345-67890"))
        XCTAssertTrue(enabled.text.contains("<email>"))
        XCTAssertTrue(enabled.text.contains("<id_number>"))
    }
}
