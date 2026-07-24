import Foundation
import Network

/// App-wide connectivity snapshot. `.satisfied` means a viable interface
/// exists (catches airplane mode / no Wi-Fi instantly), not that the internet
/// actually answers — captive portals and dead upstreams still surface through
/// the normal request-failure paths. NWPathMonitor delivers updates on its own
/// queue; `isOnline` is a lock-protected read so the MainActor routing path
/// and actors can consult it without awaiting.
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// Optimistic until the first path update so a cold launch never falsely
    /// forces the first message local.
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nowOnline = path.status == .satisfied
            self.lock.lock()
            let wasOnline = self.online
            self.online = nowOnline
            self.lock.unlock()
            // Router failures during an offline blip aren't the router's
            // fault: returning online clears the failure cool-down so the
            // LLM router is consulted again right away.
            if nowOnline && !wasOnline {
                Task { await AutopilotRouter.shared.resetDegradation() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "noema.network.reachability"))
    }

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }
}
