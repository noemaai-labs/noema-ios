import Foundation

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
import UIKit

/// Presents active model/dataset downloads as a BGContinuedProcessingTask so iOS 26+
/// shows system progress UI and keeps the app alive after backgrounding. While
/// protection is active, iOS 26 downloads stay on the high-throughput default
/// URLSession. Expiration pauses the underlying user operation with resumable
/// state so system-level Cancel is honored.
@available(iOS 26.0, *)
@MainActor
final class ContinuedDownloadCoordinator {
    static let shared = ContinuedDownloadCoordinator()

    private var task: BGContinuedProcessingTask?
    // Identifier submitted but not yet launched by the scheduler. Prevents
    // resubmitting while the first request is still queued.
    private var pendingIdentifier: String?
    private weak var downloadController: DownloadController?
    private var currentTitle = ""
    private var downloadsActive = false
    // Once the scheduler expires a task, don't immediately resubmit for the same
    // download batch — that would loop submit/expire under system pressure.
    private var expiredWhileActive = false
    // A `.fail` submission that the scheduler couldn't start immediately. Avoid
    // retrying on every progress publication for the same download batch.
    private var submissionFailedWhileActive = false
    // System Live Activity updates are IPC-backed and don't need to mirror the
    // in-app progress cadence. Keep them to 1 Hz and update the subtitle only
    // when the visible whole-percent value changes.
    private let systemProgressThrottler = ProgressThrottler<String>(interval: 1.0)
    private var lastSystemProgressUnit: Int64 = -1
    private var lastSystemProgressPercent = -1

    /// Only an adopted task is active protection. A successfully submitted request
    /// can still be waiting for its launch handler; if the app resigns first, the
    /// download manager takes the safe durable handoff instead of assuming runtime.
    var protectsForegroundTransport: Bool {
        task != nil
    }

    private init() {}

    func downloadsBecameActive(title: String,
                               userInitiated: Bool,
                               controller: DownloadController) {
        downloadController = controller
        let startsNewBatch = !downloadsActive
        downloadsActive = true
        currentTitle = title
        if startsNewBatch {
            resetSystemProgressThrottle()
        }
        // Continued processing is reserved for a current explicit action. Engine
        // recovery, scheduled work, and maintenance still use the durable URLSession
        // when the app backgrounds and must not create user-visible system tasks.
        guard userInitiated else { return }
        guard task == nil,
              pendingIdentifier == nil,
              !expiredWhileActive,
              !submissionFailedWhileActive else { return }
        guard UIApplication.shared.applicationState == .active else { return }

        let identifier = "arminproducts.Noema.download.continue." + UUID().uuidString
        // Each identifier is a fresh UUID, so this registers exactly once per identifier
        // (a duplicate registration would crash per the BGTaskScheduler contract).
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] bgTask in
            guard let continued = bgTask as? BGContinuedProcessingTask else {
                bgTask.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                guard let self else {
                    continued.setTaskCompleted(success: false)
                    return
                }
                self.adopt(continued, identifier: identifier)
            }
        }
        guard registered else {
            submissionFailedWhileActive = true
            Task { await logger.log("[Download][CPT] register failed for \(identifier)") }
            return
        }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "0%")
        // Downloads are useful only when protection starts immediately. If iOS
        // cannot grant it now, the manager retains foreground speed while visible
        // and falls back to its durable background session when the app leaves.
        request.strategy = .fail
        // Install the generation marker before submit: a successful `.fail`
        // request may invoke its launch handler immediately. The handler validates
        // this exact identifier so a late callback from an older batch cannot take
        // ownership of the current batch's state.
        pendingIdentifier = identifier
        do {
            try BGTaskScheduler.shared.submit(request)
            Task { await logger.log("[Download][CPT] submitted \(identifier) title=\(title)") }
        } catch {
            if pendingIdentifier == identifier {
                pendingIdentifier = nil
            }
            submissionFailedWhileActive = true
            Task { await logger.log("[Download][CPT] submit failed: \(error.localizedDescription)") }
        }
    }

    func updateProgress(_ fraction: Double, title: String?) {
        if let title { currentTitle = title }
        guard let task else { return }
        let clamped = max(0, min(1, fraction))
        // NSProgress for one continued task must not move backward when another
        // artifact joins the batch or a more accurate Content-Length is discovered.
        let proposedUnit = Int64((clamped * Double(task.progress.totalUnitCount)).rounded())
        let progressUnit = max(lastSystemProgressUnit, proposedUnit)
        let isComplete = progressUnit >= task.progress.totalUnitCount
        guard progressUnit != lastSystemProgressUnit,
              systemProgressThrottler.shouldAllow(key: "download", force: isComplete) else { return }
        lastSystemProgressUnit = progressUnit
        task.progress.completedUnitCount = progressUnit
        let percent = Int((Double(progressUnit) / Double(max(task.progress.totalUnitCount, 1)) * 100).rounded())
        if percent != lastSystemProgressPercent {
            lastSystemProgressPercent = percent
            task.updateTitle(currentTitle, subtitle: "\(percent)%")
        }
    }

    func downloadsFinished(success: Bool) {
        downloadsActive = false
        expiredWhileActive = false
        submissionFailedWhileActive = false
        currentTitle = ""
        resetSystemProgressThrottle()
        guard let task else {
            // The batch drained before the scheduler ever launched the submitted
            // request. Cancel it and clear the pending state so the next batch can
            // submit fresh (a launch racing the cancel completes immediately in
            // adopt() because downloadsActive is already false).
            if let pendingIdentifier {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: pendingIdentifier)
                self.pendingIdentifier = nil
                Task { await logger.log("[Download][CPT] cancelled unlaunched request \(pendingIdentifier)") }
            }
            return
        }
        pendingIdentifier = nil
        self.task = nil
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: success)
        Task { await logger.log("[Download][CPT] completed success=\(success)") }
    }

    private func adopt(_ continued: BGContinuedProcessingTask, identifier: String) {
        guard pendingIdentifier == identifier, task == nil else {
            continued.setTaskCompleted(success: false)
            Task { await logger.log("[Download][CPT] rejected stale launch \(identifier)") }
            return
        }
        pendingIdentifier = nil
        guard downloadsActive else {
            continued.setTaskCompleted(success: true)
            return
        }
        // Fine enough that a slow multi-gigabyte transfer still reports measurable
        // movement at the 1 Hz system cadence instead of appearing stalled for tens
        // of seconds between 0.1% steps.
        continued.progress.totalUnitCount = 10_000
        continued.progress.completedUnitCount = 0
        resetSystemProgressThrottle()
        continued.expirationHandler = { [weak self, weak continued] in
            // The handler runs on the main queue (registered with .main), so clear
            // protection and acquire short cleanup time synchronously. BackgroundTasks
            // is completed only after the transfer has been preserved (or cleanup time
            // expires), matching the expiration-handler contract.
            MainActor.assumeIsolated {
                guard let self, let continued, self.task === continued else { return }
                self.task = nil
                self.expiredWhileActive = true
                let controller = self.downloadController
                BackgroundDownloadManager.shared.handleContinuedDownloadProtectionEnded(
                    cleanup: { [weak controller] in
                        await controller?.pauseActiveDownloadsForContinuedProcessingExpiration()
                    },
                    completion: {
                        continued.setTaskCompleted(success: false)
                        Task { await logger.log("[Download][CPT] expired by the scheduler; downloads paused") }
                    }
                )
            }
        }
        task = continued
        // Adoption can race a lifecycle fallback that began while the request was
        // merely pending. Queue restoration behind that pass so actual protection,
        // rather than callback ordering, decides the final transport.
        Task { @MainActor in
            await BackgroundDownloadManager.shared.handleContinuedDownloadProtectionBecameActive()
        }
        if !currentTitle.isEmpty {
            continued.updateTitle(currentTitle, subtitle: "0%")
        }
    }

    private func resetSystemProgressThrottle() {
        systemProgressThrottler.clear(key: "download")
        lastSystemProgressUnit = -1
        lastSystemProgressPercent = -1
    }
}
#endif
