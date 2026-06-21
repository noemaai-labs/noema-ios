import Foundation
import XCTest
@testable import Noema

final class LoopbackFailureInjectionTests: XCTestCase {
    func testReadinessProbeReportsHealthTimeoutWhenBridgeNeverLoads() async {
        let script = ProbeScript(statuses: [], bridgeReadyStates: [false, false, false, false])
        let clock = ProbeClock(step: 0.2)

        let result = await LoopbackReadinessProbe.run(
            timeout: 0.5,
            intervalNanos: 0,
            now: { clock.now() },
            bridgeReady: { await script.nextBridgeReady() },
            healthStatus: { await script.nextStatus() },
            sleep: { _ in }
        )

        XCTAssertFalse(result.ready)
        XCTAssertNil(result.statusCode)
        XCTAssertFalse(result.usedBridgeFallback)
        XCTAssertGreaterThan(result.attempts, 0)
    }

    func testReadinessProbeTreatsStuckLoadingProgressAsNotReady() async {
        let script = ProbeScript(
            statuses: [503, 503, 503, 503],
            bridgeReadyStates: [false, false, false, false, false]
        )
        let clock = ProbeClock(step: 0.12)

        let result = await LoopbackReadinessProbe.run(
            timeout: 0.5,
            intervalNanos: 0,
            now: { clock.now() },
            bridgeReady: { await script.nextBridgeReady() },
            healthStatus: { await script.nextStatus() },
            sleep: { _ in }
        )

        XCTAssertFalse(result.ready)
        XCTAssertEqual(result.statusCode, 503)
        XCTAssertFalse(result.usedBridgeFallback)
    }

    func testReadinessProbeAllowsBridgeFallbackAfterRepeatedNon200Responses() async {
        let script = ProbeScript(
            statuses: [503, 503, 503, 503, 503, 503],
            bridgeReadyStates: [true]
        )
        let clock = ProbeClock(step: 0.01)

        let result = await LoopbackReadinessProbe.run(
            timeout: 2,
            intervalNanos: 0,
            now: { clock.now() },
            bridgeReady: { await script.nextBridgeReady() },
            healthStatus: { await script.nextStatus() },
            sleep: { _ in }
        )

        XCTAssertTrue(result.ready)
        XCTAssertEqual(result.statusCode, 503)
        XCTAssertEqual(result.attempts, 5)
        XCTAssertTrue(result.usedBridgeFallback)
    }

    func testRetryPlannerCoversRetryRestartAndFailureBranches() {
        let readyBeforeRestart = LoopbackReadyProbeResult(
            ready: true,
            statusCode: 200,
            attempts: 1,
            elapsedMs: 20,
            usedBridgeFallback: false
        )
        let notReady = LoopbackReadyProbeResult(
            ready: false,
            statusCode: nil,
            attempts: 3,
            elapsedMs: 500,
            usedBridgeFallback: false
        )
        let readyAfterRestart = LoopbackReadyProbeResult(
            ready: true,
            statusCode: 200,
            attempts: 2,
            elapsedMs: 80,
            usedBridgeFallback: false
        )

        XCTAssertEqual(
            LoopbackRetryPlanner.decision(
                preRestartProbe: readyBeforeRestart,
                restartedPort: nil,
                postRestartProbe: nil
            ),
            .retryWithoutRestart
        )
        XCTAssertEqual(
            LoopbackRetryPlanner.decision(
                preRestartProbe: notReady,
                restartedPort: 5555,
                postRestartProbe: readyAfterRestart
            ),
            .restartAndRetry(port: 5555)
        )
        XCTAssertEqual(
            LoopbackRetryPlanner.decision(
                preRestartProbe: notReady,
                restartedPort: 5555,
                postRestartProbe: notReady
            ),
            .fail
        )
        XCTAssertEqual(
            LoopbackRetryPlanner.decision(
                preRestartProbe: notReady,
                restartedPort: nil,
                postRestartProbe: nil
            ),
            .fail
        )
    }
}

private final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)
    private let step: TimeInterval

    init(step: TimeInterval) {
        self.step = step
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current = current.addingTimeInterval(step)
        return value
    }
}

private actor ProbeScript {
    private var statuses: [Int?]
    private var bridgeReadyStates: [Bool]

    init(statuses: [Int?], bridgeReadyStates: [Bool]) {
        self.statuses = statuses
        self.bridgeReadyStates = bridgeReadyStates
    }

    func nextStatus() -> Int? {
        guard !statuses.isEmpty else { return nil }
        return statuses.removeFirst()
    }

    func nextBridgeReady() -> Bool {
        guard !bridgeReadyStates.isEmpty else { return false }
        return bridgeReadyStates.removeFirst()
    }
}
