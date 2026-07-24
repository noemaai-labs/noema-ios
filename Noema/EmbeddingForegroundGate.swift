import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Tracks whether the app may submit GPU work. iOS rejects Metal command
/// buffers while the app is backgrounded (e.g. the screen is locked), which
/// leaves the llama.cpp backend in a sticky error state. Long-running
/// embedding loops poll this gate at batch boundaries: pause while
/// backgrounded, then recover the backend and retry once foregrounded.
final class EmbeddingForegroundGate: @unchecked Sendable {
    static let shared = EmbeddingForegroundGate()

    private let lock = NSLock()
    private var backgrounded = false
    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setBackgrounded(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setBackgrounded(false)
            }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.setBackgrounded(UIApplication.shared.applicationState == .background)
            }
        }
        #endif
    }

    var isBackgrounded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgrounded
    }

    /// Suspends until the app returns to the foreground. Cancellation-aware;
    /// while the app is fully suspended the sleep simply freezes and resumes
    /// together with the process.
    func waitUntilForeground() async throws {
        while isBackgrounded {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    #if canImport(UIKit)
    @MainActor
    private func setBackgrounded(_ value: Bool) {
        lock.lock()
        backgrounded = value
        lock.unlock()
        if value {
            // Buy a short window of background runtime so the in-flight batch
            // can fail fast and the "paused" state reaches the in-app status
            // and the Live Activity before the process suspends.
            endBackgroundTask()
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "EmbeddingPauseHandoff") { [weak self] in
                Task { @MainActor in
                    self?.endBackgroundTask()
                }
            }
            Task { await logger.log("[Embed] App backgrounded – embedding will pause at the next batch boundary") }
        } else {
            endBackgroundTask()
            Task { await logger.log("[Embed] App foregrounded – embedding may resume") }
        }
    }

    @MainActor
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    #endif
}
