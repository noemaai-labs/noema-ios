// DatasetLiveActivityController.swift
import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Combine
import UIKit

// IMPORTANT: This declaration mirrors the widget-extension copy in
// `NoemaEmbeddingActivity/DatasetIndexingAttributes.swift`. ActivityKit
// matches the running activity to the widget UI by type name and Codable
// shape, so the two must stay byte-for-byte compatible. `stage` reuses the
// app's `DatasetProcessingStage`, which encodes to the same raw values as the
// extension's local copy.
struct DatasetIndexingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var stage: DatasetProcessingStage
        var progress: Double
        var stageTitle: String
        var detail: String?
        var etaText: String?
        var isPaused: Bool
    }

    var datasetID: String
    var name: String
}

/// Drives the system Live Activity (lock screen + Dynamic Island) for dataset
/// preparation. Observes `DatasetManager.processingStatus` and starts, updates
/// and ends one activity per dataset with an active pipeline.
@MainActor
final class DatasetLiveActivityController {
    static let shared = DatasetLiveActivityController()

    private var activities: [String: Activity<DatasetIndexingAttributes>] = [:]
    private var lastStage: [String: DatasetProcessingStage] = [:]
    private var lastStatus: [String: DatasetProcessingStatus] = [:]
    private var lastUpdateAt: [String: Date] = [:]
    private var lastRequestAttemptAt: [String: Date] = [:]
    private var cancellable: AnyCancellable?
    private var didCleanUpStaleActivities = false
    /// While the app is backgrounded, work is suspended (iOS forbids GPU use
    /// there) — every activity renders a "open Noema to continue" state.
    private var appBackgrounded = false

    /// Minimum interval between ActivityKit updates per dataset. Progress is
    /// already coalesced upstream; this keeps the system update rate modest.
    private let updateInterval: TimeInterval = 1.0
    /// Minimum interval between `Activity.request` retries (requests fail
    /// while the app is backgrounded; retry once it is foregrounded again).
    private let requestRetryInterval: TimeInterval = 5.0

    private init() {}

    func bind(to manager: DatasetManager) {
        cleanUpStaleActivitiesIfNeeded()
        cancellable = manager.$processingStatus.sink { [weak manager] statuses in
            MainActor.assumeIsolated {
                guard let manager else { return }
                var names: [String: String] = [:]
                for dataset in manager.datasets {
                    names[dataset.datasetID] = dataset.name
                }
                DatasetLiveActivityController.shared.sync(statuses: statuses, names: names)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DatasetLiveActivityController.shared.setAppBackgrounded(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DatasetLiveActivityController.shared.setAppBackgrounded(false)
            }
        }
    }

    /// Flips every tracked activity into (or out of) the paused presentation
    /// immediately, without waiting for the next pipeline status update —
    /// the lock screen should urge the user back the moment work suspends.
    private func setAppBackgrounded(_ backgrounded: Bool) {
        guard appBackgrounded != backgrounded else { return }
        appBackgrounded = backgrounded
        for (id, activity) in activities {
            guard let status = lastStatus[id] else { continue }
            lastUpdateAt[id] = Date()
            let content = ActivityContent(
                state: contentState(for: status, paused: backgrounded),
                staleDate: Date(timeIntervalSinceNow: 1800)
            )
            let box = SendableBox(value: activity)
            Task { await box.value.update(content) }
        }
    }

    // MARK: - Sync

    private func sync(statuses: [String: DatasetProcessingStatus], names: [String: String]) {
        // Statuses that vanished without a terminal stage were cancelled.
        for (id, activity) in activities where statuses[id] == nil {
            end(activity, finalState: nil, lingerSeconds: nil)
            forget(id)
        }

        for (id, status) in statuses {
            switch status.stage {
            case .completed, .failed:
                // Only finalize activities we actually started; `completed`
                // statuses also exist permanently for every indexed dataset.
                guard let activity = activities[id] else { continue }
                end(
                    activity,
                    finalState: contentState(for: status),
                    lingerSeconds: status.stage == .completed ? 6 : 8
                )
                forget(id)
            case .embedding where status.progress <= 0.0001:
                // Paused at the user-confirmation gate: no background work is
                // running, so a lock-screen activity would just sit stalled.
                if let activity = activities[id] {
                    end(activity, finalState: nil, lingerSeconds: nil)
                    forget(id)
                }
            case .extracting, .compressing, .embedding:
                upsert(id: id, name: names[id] ?? fallbackName(id), status: status)
            }
        }
    }

    private func upsert(id: String, name: String, status: DatasetProcessingStatus) {
        let state = contentState(for: status, paused: appBackgrounded)
        let now = Date()
        lastStatus[id] = status

        if let activity = activities[id] {
            let stageChanged = lastStage[id] != status.stage
            let elapsed = now.timeIntervalSince(lastUpdateAt[id] ?? .distantPast)
            guard stageChanged || elapsed >= updateInterval else { return }
            lastStage[id] = status.stage
            lastUpdateAt[id] = now
            // Generous stale date: while paused in the background (screen
            // locked) the last content stays accurate until the user returns.
            let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 1800))
            let box = SendableBox(value: activity)
            Task { await box.value.update(content) }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let lastAttempt = lastRequestAttemptAt[id], now.timeIntervalSince(lastAttempt) < requestRetryInterval {
            return
        }
        lastRequestAttemptAt[id] = now

        let attributes = DatasetIndexingAttributes(datasetID: id, name: name)
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 1800))
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            activities[id] = activity
            lastStage[id] = status.stage
            lastUpdateAt[id] = now
            Task { await logger.log("[LiveActivity] Started for \(id)") }
        } catch {
            Task { await logger.log("[LiveActivity] request failed for \(id): \(error.localizedDescription)") }
        }
    }

    // MARK: - Helpers

    private func end(
        _ activity: Activity<DatasetIndexingAttributes>,
        finalState: DatasetIndexingAttributes.ContentState?,
        lingerSeconds: TimeInterval?
    ) {
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = lingerSeconds
            .map { .after(Date(timeIntervalSinceNow: $0)) } ?? .immediate
        let box = SendableBox(value: activity)
        Task { await box.value.end(content, dismissalPolicy: policy) }
    }

    private func forget(_ id: String) {
        activities[id] = nil
        lastStage[id] = nil
        lastStatus[id] = nil
        lastUpdateAt[id] = nil
        lastRequestAttemptAt[id] = nil
    }

    /// Ends leftovers from a previous app session (e.g. force-quit mid-index);
    /// indexing never auto-resumes on launch, so they are always stale.
    private func cleanUpStaleActivitiesIfNeeded() {
        guard !didCleanUpStaleActivities else { return }
        didCleanUpStaleActivities = true
        Task {
            for activity in Activity<DatasetIndexingAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func contentState(for status: DatasetProcessingStatus, paused: Bool = false) -> DatasetIndexingAttributes.ContentState {
        let locale = LocalizationManager.preferredLocale()
        let isTerminal = status.stage == .completed || status.stage == .failed
        if paused && !isTerminal {
            return DatasetIndexingAttributes.ContentState(
                stage: status.stage,
                progress: max(0, min(1, status.progress)),
                stageTitle: String(localized: "Paused", locale: locale),
                detail: String(localized: "Open Noema to continue", locale: locale),
                etaText: nil,
                isPaused: true
            )
        }
        let presentation = DatasetIndexingPresentation.make(for: status, locale: locale)
        let detail = presentation.message == presentation.title ? nil : presentation.message
        let etaText: String? = {
            guard let eta = status.etaSeconds, eta > 0 else { return nil }
            return String.localizedStringWithFormat(
                String(localized: "~%dm %02ds", locale: locale),
                Int(eta) / 60,
                Int(eta) % 60
            )
        }()
        return DatasetIndexingAttributes.ContentState(
            stage: status.stage,
            progress: max(0, min(1, status.progress)),
            stageTitle: presentation.title,
            detail: detail,
            etaText: etaText,
            isPaused: false
        )
    }

    private func fallbackName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

/// `Activity` is not declared `Sendable`, but ActivityKit documents `update`
/// and `end` as safe to call from any context. This box carries the reference
/// into the detached continuation without losing the MainActor bookkeeping.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
}
#endif
