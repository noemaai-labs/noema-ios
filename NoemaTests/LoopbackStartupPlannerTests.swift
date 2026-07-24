import Foundation
import XCTest
import NoemaPackages
@testable import Noema

final class LoopbackStartupPlannerTests: XCTestCase {
    func testFailureMessageIncludesReasonStatusAndUnchangedSettingsGuidance() {
        let diagnostics = LlamaServerBridge.StartDiagnostics(
            code: "ready_timeout",
            message: "Loopback server never became ready.",
            lastHTTPStatus: 503,
            elapsedMs: 3400,
            progress: 0.87,
            httpReady: false
        )

        let message = LoopbackStartupPlanner.formatFailureMessage(diagnostics)

        XCTAssertTrue(message.contains("Failed to start local GGUF runtime."))
        XCTAssertTrue(message.contains("Reason: Request timed out. Please try again."))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("server"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("connect"))
        XCTAssertTrue(message.contains("Status: 503, progress: 87%"))
        XCTAssertTrue(message.contains("Noema did not change this model's saved settings."))
        XCTAssertFalse(message.contains("retry:"))
        XCTAssertFalse(message.contains("Try lowering context length or resetting this model's settings."))
    }

    func testFailureMessageDoesNotSuggestAutomaticContextRecoveryWhenDiagnosticsAreMissing() {
        let message = LoopbackStartupPlanner.formatFailureMessage(nil)

        XCTAssertTrue(message.contains("Reason: The on-device model runtime could not start."))
        XCTAssertTrue(message.contains("Status: n/a, progress: 0%"))
        XCTAssertTrue(message.contains("Adjust Model Settings manually"))
        XCTAssertFalse(message.contains("safe-settings"))
        XCTAssertFalse(message.contains("template-reset"))
    }
}
