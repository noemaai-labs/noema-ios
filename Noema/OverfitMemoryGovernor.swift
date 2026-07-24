import Foundation
import NoemaPackages

@_silgen_name("app_available_memory")
private func c_app_available_memory() -> UInt

@_silgen_name("app_memory_footprint")
private func c_app_memory_footprint() -> UInt

actor OverfitMemoryGovernor {
    /// Headroom fractions of the total budget. Each level trips once when
    /// headroom drops below its threshold and re-arms only after recovery
    /// above `recoveryFactor` times that threshold, so an oscillating reading
    /// cannot spam pressure calls.
    static let warnThreshold = 0.12
    static let pressureThreshold = 0.08
    static let criticalThreshold = 0.05
    static let emergencyThreshold = 0.03
    static let recoveryFactor = 1.5

    private let availableMemory: @Sendable () -> UInt64
    private let footprint: @Sendable () -> UInt64
    private let applyPressure: @Sendable (Int32) -> Void
    private let onCritical: @Sendable () -> Void
    private let onEmergency: @Sendable () -> Void
    private let pollIntervalNanoseconds: UInt64

    private var totalBudget: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var warnTripped = false
    private var pressureTripped = false
    private var criticalTripped = false
    private var emergencyTripped = false

    init(
        availableMemory: @escaping @Sendable () -> UInt64,
        footprint: @escaping @Sendable () -> UInt64,
        applyPressure: @escaping @Sendable (Int32) -> Void,
        onCritical: @escaping @Sendable () -> Void,
        onEmergency: @escaping @Sendable () -> Void,
        pollIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.availableMemory = availableMemory
        self.footprint = footprint
        self.applyPressure = applyPressure
        self.onCritical = onCritical
        self.onEmergency = onEmergency
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    /// Live process sources: os_proc_available_memory / phys_footprint via the
    /// same C bridge ModelRAMAdvisor uses, with mitigation routed to the
    /// native paged runtime.
    static func live(
        onCritical: @escaping @Sendable () -> Void,
        onEmergency: @escaping @Sendable () -> Void
    ) -> OverfitMemoryGovernor {
        OverfitMemoryGovernor(
            availableMemory: { UInt64(c_app_available_memory()) },
            footprint: { UInt64(c_app_memory_footprint()) },
            applyPressure: { LlamaServerBridge.pagedApplyPressure($0) },
            onCritical: onCritical,
            onEmergency: onEmergency
        )
    }

    /// Arms the ladder without polling. Tests use this and drive `pollOnce()`
    /// deterministically; production callers use `start(totalBudget:)`.
    func prepare(totalBudget: UInt64) {
        self.totalBudget = totalBudget
        warnTripped = false
        pressureTripped = false
        criticalTripped = false
        emergencyTripped = false
    }

    func start(totalBudget: UInt64) {
        stopPolling(resetLadder: true)
        prepare(totalBudget: totalBudget)
        let interval = pollIntervalNanoseconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        stopPolling(resetLadder: true)
    }

    private func stopPolling(resetLadder: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard resetLadder else { return }
        if pressureTripped {
            applyPressure(0)
        }
        warnTripped = false
        pressureTripped = false
        criticalTripped = false
        emergencyTripped = false
        totalBudget = 0
    }

    func pollOnce() {
        guard totalBudget > 0 else { return }
        let available = availableMemory()
        let fraction = Double(available) / Double(totalBudget)

        if fraction < Self.emergencyThreshold, !emergencyTripped {
            emergencyTripped = true
            log(level: "emergency", fraction: fraction, available: available)
            onEmergency()
        }
        if fraction < Self.criticalThreshold, !criticalTripped {
            criticalTripped = true
            log(level: "critical", fraction: fraction, available: available)
            onCritical()
        }
        if fraction < Self.pressureThreshold, !pressureTripped {
            pressureTripped = true
            log(level: "pressure", fraction: fraction, available: available)
            applyPressure(2)
        }
        if fraction < Self.warnThreshold, !warnTripped {
            warnTripped = true
            log(level: "warn", fraction: fraction, available: available)
        }

        if emergencyTripped, fraction > Self.emergencyThreshold * Self.recoveryFactor {
            emergencyTripped = false
        }
        if criticalTripped, fraction > Self.criticalThreshold * Self.recoveryFactor {
            criticalTripped = false
        }
        if pressureTripped, fraction > Self.pressureThreshold * Self.recoveryFactor {
            pressureTripped = false
            applyPressure(0)
        }
        if warnTripped, fraction > Self.warnThreshold * Self.recoveryFactor {
            warnTripped = false
        }
    }

    private func log(level: String, fraction: Double, available: UInt64) {
        let currentFootprint = footprint()
        Task {
            await logger.log(String(
                format: "[Overfit][Governor] %@ headroom=%.3f available=%llu footprint=%llu",
                level, fraction, available, currentFootprint
            ))
        }
    }
}
