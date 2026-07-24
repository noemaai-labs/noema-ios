import Foundation
import XCTest
@testable import Noema

final class OverfitMemoryGovernorTests: XCTestCase {

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func append(_ event: String) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(event)
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func makeGovernor(
        available: LockedBox<UInt64>,
        events: EventLog,
        pollIntervalNanoseconds: UInt64 = 250_000_000
    ) -> OverfitMemoryGovernor {
        OverfitMemoryGovernor(
            availableMemory: { available.value },
            footprint: { 2_000_000_000 },
            applyPressure: { events.append("pressure:\($0)") },
            onCritical: { events.append("critical") },
            onEmergency: { events.append("emergency") },
            pollIntervalNanoseconds: pollIntervalNanoseconds
        )
    }

    // MARK: - Ladder escalation

    func testLadderEscalatesThroughEveryLevelExactlyOnce() async {
        let available = LockedBox<UInt64>(500)
        let events = EventLog()
        let governor = makeGovernor(available: available, events: events)
        await governor.prepare(totalBudget: 1000)

        await governor.pollOnce()                       // 0.50 headroom
        XCTAssertEqual(events.events, [])

        available.value = 110                           // 0.11 -> warn (log only)
        await governor.pollOnce()
        XCTAssertEqual(events.events, [])

        available.value = 79                            // 0.079 -> pressure
        await governor.pollOnce()
        XCTAssertEqual(events.events, ["pressure:2"])

        available.value = 49                            // 0.049 -> critical
        await governor.pollOnce()
        XCTAssertEqual(events.events, ["pressure:2", "critical"])

        available.value = 29                            // 0.029 -> emergency
        await governor.pollOnce()
        XCTAssertEqual(events.events, ["pressure:2", "critical", "emergency"])

        // Holding at the same level never re-fires.
        await governor.pollOnce()
        await governor.pollOnce()
        XCTAssertEqual(events.events, ["pressure:2", "critical", "emergency"])
    }

    func testDirectDropFiresEveryCrossedLevelInSeverityOrder() async {
        let available = LockedBox<UInt64>(500)
        let events = EventLog()
        let governor = makeGovernor(available: available, events: events)
        await governor.prepare(totalBudget: 1000)

        available.value = 10                            // 0.01 crosses everything at once
        await governor.pollOnce()
        XCTAssertEqual(events.events, ["emergency", "critical", "pressure:2"])
    }

    // MARK: - Hysteresis

    func testRecoveryReArmsOnlyLevelsAboveOneAndAHalfTimesTheirThreshold() async {
        let available = LockedBox<UInt64>(500)
        let events = EventLog()
        let governor = makeGovernor(available: available, events: events)
        await governor.prepare(totalBudget: 1000)

        available.value = 29
        await governor.pollOnce()                       // trips everything
        XCTAssertEqual(events.events, ["emergency", "critical", "pressure:2"])

        // 0.10 clears emergency (>0.045) and critical (>0.075) but not the
        // pressure level (needs >0.12), so pagedApplyPressure(0) must not fire.
        available.value = 100
        await governor.pollOnce()
        XCTAssertEqual(events.events, ["emergency", "critical", "pressure:2"])

        // A renewed dip below critical re-fires it because it re-armed...
        available.value = 49
        await governor.pollOnce()
        XCTAssertEqual(events.events, ["emergency", "critical", "pressure:2", "critical"])

        // ...while pressure stayed latched, so no duplicate pressure:2.
        available.value = 130                           // 0.13 > 0.12 re-arms pressure
        await governor.pollOnce()
        XCTAssertEqual(
            events.events,
            ["emergency", "critical", "pressure:2", "critical", "pressure:0"]
        )

        available.value = 70                            // 0.07 -> pressure fires again
        await governor.pollOnce()
        XCTAssertEqual(
            events.events,
            ["emergency", "critical", "pressure:2", "critical", "pressure:0", "pressure:2"]
        )
    }

    func testZeroBudgetNeverFires() async {
        let available = LockedBox<UInt64>(0)
        let events = EventLog()
        let governor = makeGovernor(available: available, events: events)
        await governor.prepare(totalBudget: 0)
        await governor.pollOnce()
        XCTAssertEqual(events.events, [])
    }

    // MARK: - Poll loop lifecycle

    func testStartPollsAndStopResetsAppliedPressure() async throws {
        let available = LockedBox<UInt64>(70)
        let events = EventLog()
        let governor = makeGovernor(
            available: available,
            events: events,
            pollIntervalNanoseconds: 2_000_000
        )
        await governor.start(totalBudget: 1000)

        var sawPressure = false
        for _ in 0..<300 {
            if events.events.contains("pressure:2") {
                sawPressure = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawPressure, "poll loop never observed the low-memory reading")

        await governor.stop()
        XCTAssertEqual(events.events.last, "pressure:0",
                       "stop must release pressure it applied")

        // A stopped governor is inert even if memory keeps falling.
        let countAfterStop = events.events.count
        available.value = 5
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(events.events.count, countAfterStop)
    }

    func testStopWithoutTrippedPressureDoesNotTouchPressure() async {
        let available = LockedBox<UInt64>(900)
        let events = EventLog()
        let governor = makeGovernor(available: available, events: events)
        await governor.start(totalBudget: 1000)
        await governor.stop()
        XCTAssertFalse(events.events.contains("pressure:0"))
    }
}
