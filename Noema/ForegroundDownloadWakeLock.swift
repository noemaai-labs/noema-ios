import Foundation

#if canImport(UIKit)
import UIKit

@MainActor
final class ForegroundDownloadWakeLock {
    static let shared = ForegroundDownloadWakeLock()

    private var engaged = false

    private init() {}

    func update(hasActiveForegroundDownloads: Bool, isSceneActive: Bool) {
        let shouldEngage = hasActiveForegroundDownloads && isSceneActive
        guard engaged != shouldEngage else { return }
        engaged = shouldEngage
        UIApplication.shared.isIdleTimerDisabled = shouldEngage
        Task { await logger.log("[Download][WakeLock] active=\(shouldEngage)") }
    }

    func release() {
        update(hasActiveForegroundDownloads: false, isSceneActive: false)
    }
}
#elseif os(macOS)
@MainActor
final class ForegroundDownloadWakeLock {
    static let shared = ForegroundDownloadWakeLock()

    // App Nap would throttle timers and networking for an occluded window even
    // though the download session runs in-process; hold an activity assertion
    // while any download is live, regardless of window/scene activation.
    private var activityToken: NSObjectProtocol?

    private init() {}

    func update(hasActiveForegroundDownloads: Bool, isSceneActive: Bool) {
        if hasActiveForegroundDownloads {
            guard activityToken == nil else { return }
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Model download"
            )
            Task { await logger.log("[Download][WakeLock] active=true (App Nap deferred)") }
        } else if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
            Task { await logger.log("[Download][WakeLock] active=false") }
        }
    }

    func release() {
        update(hasActiveForegroundDownloads: false, isSceneActive: false)
    }
}
#else
@MainActor
final class ForegroundDownloadWakeLock {
    static let shared = ForegroundDownloadWakeLock()

    private init() {}

    func update(hasActiveForegroundDownloads: Bool, isSceneActive: Bool) {}
    func release() {}
}
#endif
