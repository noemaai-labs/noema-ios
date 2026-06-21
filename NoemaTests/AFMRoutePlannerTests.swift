import Foundation
import XCTest
@testable import Noema

final class AFMRoutePlannerTests: XCTestCase {

    private func inputs(
        mode: AFMPrivateCloudComputeMode,
        offGrid: Bool = false,
        runtimeSupportsPCC: Bool = true,
        pccAvailable: Bool = true,
        pccQuotaExhausted: Bool = false,
        promptTokenEstimate: Int? = 500,
        onDeviceContextSize: Int? = 8192
    ) -> AFMRouteInputs {
        AFMRouteInputs(
            mode: mode,
            offGrid: offGrid,
            runtimeSupportsPCC: runtimeSupportsPCC,
            pccAvailable: pccAvailable,
            pccQuotaExhausted: pccQuotaExhausted,
            promptTokenEstimate: promptTokenEstimate,
            onDeviceContextSize: onDeviceContextSize
        )
    }

    // MARK: - Hard gates

    func testOffModeNeverRoutesOrEscalates() {
        let decision = AFMRoutePlanner.decide(inputs(mode: .off))
        XCTAssertEqual(decision.initialRoute, .onDevice)
        XCTAssertFalse(decision.allowEscalation)
        XCTAssertFalse(decision.isFallback)
        XCTAssertEqual(decision.reason, .modeOff)
    }

    func testOffGridForcesOnDeviceForAllModes() {
        for mode in AFMPrivateCloudComputeMode.allCases where mode != .off {
            let decision = AFMRoutePlanner.decide(inputs(mode: mode, offGrid: true))
            XCTAssertEqual(decision.initialRoute, .onDevice, "mode \(mode)")
            XCTAssertFalse(decision.allowEscalation, "mode \(mode)")
            XCTAssertEqual(decision.reason, .offGrid, "mode \(mode)")
        }
    }

    func testOffGridWinsEvenWithOversizedPrompt() {
        let decision = AFMRoutePlanner.decide(
            inputs(mode: .smart, offGrid: true, promptTokenEstimate: 100_000)
        )
        XCTAssertEqual(decision.initialRoute, .onDevice)
        XCTAssertEqual(decision.reason, .offGrid)
    }

    func testUnsupportedRuntimeMatchesLegacyOnDeviceBehavior() {
        for mode in AFMPrivateCloudComputeMode.allCases where mode != .off {
            let decision = AFMRoutePlanner.decide(inputs(mode: mode, runtimeSupportsPCC: false))
            XCTAssertEqual(decision.initialRoute, .onDevice, "mode \(mode)")
            XCTAssertFalse(decision.allowEscalation, "mode \(mode)")
            XCTAssertFalse(decision.isFallback, "mode \(mode)")
            XCTAssertEqual(decision.reason, .runtimeUnsupported, "mode \(mode)")
        }
    }

    // MARK: - Availability and quota

    func testPCCUnavailableDisablesEscalation() {
        let smart = AFMRoutePlanner.decide(inputs(mode: .smart, pccAvailable: false))
        XCTAssertEqual(smart.initialRoute, .onDevice)
        XCTAssertFalse(smart.allowEscalation)
        XCTAssertEqual(smart.reason, .pccUnavailable)

        let always = AFMRoutePlanner.decide(inputs(mode: .always, pccAvailable: false))
        XCTAssertEqual(always.initialRoute, .onDevice)
        XCTAssertFalse(always.isFallback, "unavailability is not a quota fallback")
        XCTAssertEqual(always.reason, .pccUnavailable)
    }

    func testQuotaExhaustedFallsBackAndFlagsAlwaysMode() {
        let always = AFMRoutePlanner.decide(inputs(mode: .always, pccQuotaExhausted: true))
        XCTAssertEqual(always.initialRoute, .onDevice)
        XCTAssertFalse(always.allowEscalation)
        XCTAssertTrue(always.isFallback)
        XCTAssertEqual(always.reason, .quotaExhausted)

        let smart = AFMRoutePlanner.decide(inputs(mode: .smart, pccQuotaExhausted: true))
        XCTAssertEqual(smart.initialRoute, .onDevice)
        XCTAssertFalse(smart.allowEscalation)
        XCTAssertFalse(smart.isFallback)
        XCTAssertEqual(smart.reason, .quotaExhausted)
    }

    // MARK: - Routing

    func testAlwaysModeRoutesToPCC() {
        let decision = AFMRoutePlanner.decide(inputs(mode: .always))
        XCTAssertEqual(decision.initialRoute, .privateCloudCompute)
        XCTAssertFalse(decision.allowEscalation)
        XCTAssertEqual(decision.reason, .alwaysPCC)
    }

    func testSmartModeOversizedPromptPreRoutesToPCC() {
        let decision = AFMRoutePlanner.decide(
            inputs(mode: .smart, promptTokenEstimate: 8000, onDeviceContextSize: 8192)
        )
        // 8000 + 1024 reserved > 8192
        XCTAssertEqual(decision.initialRoute, .privateCloudCompute)
        XCTAssertFalse(decision.allowEscalation)
        XCTAssertEqual(decision.reason, .contextRequiresPCC)
    }

    func testSmartModePromptAtBoundaryStaysOnDevice() {
        let decision = AFMRoutePlanner.decide(
            inputs(
                mode: .smart,
                promptTokenEstimate: 8192 - AFMRoutePlanner.reservedResponseTokens,
                onDeviceContextSize: 8192
            )
        )
        XCTAssertEqual(decision.initialRoute, .onDevice)
        XCTAssertTrue(decision.allowEscalation)
        XCTAssertEqual(decision.reason, .smartDefault)
    }

    func testSmartModeNeverPreRoutesBlindOnMissingCounts() {
        let noEstimate = AFMRoutePlanner.decide(
            inputs(mode: .smart, promptTokenEstimate: nil, onDeviceContextSize: 8192)
        )
        XCTAssertEqual(noEstimate.initialRoute, .onDevice)
        XCTAssertTrue(noEstimate.allowEscalation)
        XCTAssertEqual(noEstimate.reason, .smartDefault)

        let noContext = AFMRoutePlanner.decide(
            inputs(mode: .smart, promptTokenEstimate: 100_000, onDeviceContextSize: nil)
        )
        XCTAssertEqual(noContext.initialRoute, .onDevice)
        XCTAssertTrue(noContext.allowEscalation)
        XCTAssertEqual(noContext.reason, .smartDefault)
    }

    func testSmartModeDefaultOffersEscalation() {
        let decision = AFMRoutePlanner.decide(inputs(mode: .smart))
        XCTAssertEqual(decision.initialRoute, .onDevice)
        XCTAssertTrue(decision.allowEscalation)
        XCTAssertFalse(decision.isFallback)
        XCTAssertEqual(decision.reason, .smartDefault)
    }

    // MARK: - Msg persistence

    @MainActor
    func testMsgRanOnPrivateCloudComputeRoundTrips() throws {
        var msg = ChatVM.Msg(role: "🤖", text: "hello", timestamp: Date())
        msg.ranOnPrivateCloudCompute = true

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: data)
        XCTAssertEqual(decoded.ranOnPrivateCloudCompute, true)

        let plain = ChatVM.Msg(role: "🤖", text: "hello", timestamp: Date())
        let plainData = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(data: plainData, encoding: .utf8)!.contains("ranOnPrivateCloudCompute"))
        let decodedPlain = try JSONDecoder().decode(ChatVM.Msg.self, from: plainData)
        XCTAssertNil(decodedPlain.ranOnPrivateCloudCompute)
    }

    @MainActor
    func testMsgDecodesLegacyPayloadWithoutRouteKey() throws {
        let msg = ChatVM.Msg(role: "🤖", text: "legacy", timestamp: Date())
        let data = try JSONEncoder().encode(msg)
        // Simulates a chat persisted before the field existed.
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: data)
        XCTAssertNil(decoded.ranOnPrivateCloudCompute)
    }
}
