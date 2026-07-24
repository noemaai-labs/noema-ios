import Foundation
import NoemaPackages

@_silgen_name("app_available_memory")
private func c_app_available_memory() -> UInt

@_silgen_name("app_memory_footprint")
private func c_app_memory_footprint() -> UInt

extension Notification.Name {
    /// Posted when the governor crossed the critical reserve: prefetch and
    /// queued reads were shed and the UI should surface OverfitNoticeRow(.memoryStop).
    static let noemaOverfitMemoryCritical = Notification.Name("noema.overfit.memoryCritical")
    /// Posted just before the emergency server teardown.
    static let noemaOverfitMemoryEmergency = Notification.Name("noema.overfit.memoryEmergency")
}

final class OverfitGovernorController: @unchecked Sendable {
    static let shared = OverfitGovernorController()

    private let lock = NSLock()
    private var governor: OverfitMemoryGovernor?
    private var watchdog: Task<Void, Never>?

    /// Called after a paged loopback server reports ready.
    func beginPagedSession() {
        lock.lock()
        defer { lock.unlock() }
        endLocked()

        let governor = OverfitMemoryGovernor.live(
            onCritical: {
                // Shed all optional I/O first; generation itself keeps running
                // unless the emergency floor is crossed.
                LlamaServerBridge.pagedApplyPressure(3)
                NotificationCenter.default.post(name: .noemaOverfitMemoryCritical, object: nil)
            },
            onEmergency: {
                NotificationCenter.default.post(name: .noemaOverfitMemoryEmergency, object: nil)
                // Crash prevention beats grace: stopping the server abandons the
                // in-flight turn, but the client's retry planner and lease
                // bookkeeping already handle a server that died underneath them.
                LlamaServerBridge.stop()
            })
        self.governor = governor

        let budget = UInt64(c_app_available_memory()) + UInt64(c_app_memory_footprint())
        Task { await governor.start(totalBudget: budget) }

        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if LlamaServerBridge.port() <= 0 {
                    self?.endPagedSession()
                    return
                }
            }
        }
    }

    func endPagedSession() {
        lock.lock()
        defer { lock.unlock() }
        endLocked()
    }

    private func endLocked() {
        watchdog?.cancel()
        watchdog = nil
        if let governor {
            Task { await governor.stop() }
        }
        governor = nil
    }
}
