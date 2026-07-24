import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ReviewTurnSignals: Equatable {
    let usedRAG: Bool
    let usedWebSearch: Bool
    let usedRemoteInference: Bool

    static func positiveCompletion(
        answerText: String?,
        retrievedContext: String?,
        usedWebSearch: Bool,
        webResultCount: Int,
        webError: String?,
        usedRemoteBackend: Bool,
        ranOnPrivateCloudCompute: Bool,
        hasFailedToolCall: Bool
    ) -> ReviewTurnSignals? {
        guard let answerText else { return nil }
        let trimmedAnswer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebError = webError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Only a clean, visible answer is a positive moment. Tool/search failures and
        // warning placeholders must never be followed by a review request.
        guard !trimmedAnswer.isEmpty,
              trimmedAnswer != "(no output)",
              !trimmedAnswer.hasPrefix("⚠️"),
              trimmedWebError.isEmpty,
              !hasFailedToolCall else { return nil }

        let usedRAG = !(retrievedContext?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return ReviewTurnSignals(
            usedRAG: usedRAG,
            usedWebSearch: usedWebSearch && webResultCount > 0,
            usedRemoteInference: usedRemoteBackend || ranOnPrivateCloudCompute
        )
    }
}

@MainActor
enum ReviewGate {
    static let minDaysBetweenRequests = 90
    static let minSessionsBeforeFirstPrompt = 5

    static let minWebSearchUsesForPrompt = 5
    static let minRemoteUsesForPrompt = 1

    static func shouldPrompt(now: Date = .now,
                             sessions: Int,
                             lastRequestDate: Date?,
                             milestones: ReviewPrompter.Milestones) -> Bool {
        guard sessions >= minSessionsBeforeFirstPrompt else { return false }
        if let last = lastRequestDate {
            let days = Calendar.current.dateComponents([.day], from: last, to: now).day ?? 0
            if days < minDaysBetweenRequests { return false }
        }

        // Milestone logic: sessions + a successful RAG, remote, or repeated web-search experience.
        let ragQualified = (milestones.datasetEmbeddedCount > 0 && milestones.ragUsedCount > 0)
        let remoteQualified = milestones.remoteUsedCount >= minRemoteUsesForPrompt
        let webQualified = milestones.webSearchUsedCount >= minWebSearchUsesForPrompt
        return ragQualified || remoteQualified || webQualified
    }
}

@MainActor
final class ReviewPrompter {
    static let shared = ReviewPrompter()

    struct Milestones {
        var datasetEmbeddedCount: Int
        var ragUsedCount: Int
        var webSearchUsedCount: Int
        var remoteUsedCount: Int
    }

    private let d: UserDefaults
    private var didTrackCurrentProcessSession = false
    private var pendingPromptTask: Task<Void, Never>?

    private enum Key {
        static let lastRequestDate = "review.lastRequestDate"
        // Read-only migration sources from the original dual-cooldown implementation.
        static let lastPromptDate = "review.lastPromptDate"
        static let lastAttemptDate = "review.lastAttemptDate"
        static let sessionCount = "review.sessionCount"
        static let ragUsedCount = "review.ragUsedCount"
        static let datasetEmbeddedCount = "review.datasetEmbeddedCount"
        static let webSearchUsedCount = "review.webSearchUsedCount"
        static let remoteUsedCount = "review.remoteUsedCount"
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
    }

    func trackSession() {
        guard !didTrackCurrentProcessSession else { return }
        didTrackCurrentProcessSession = true
        let c = d.integer(forKey: Key.sessionCount)
        d.set(c + 1, forKey: Key.sessionCount)
    }

    private func noteRAGUsed() {
        let c = d.integer(forKey: Key.ragUsedCount)
        d.set(c + 1, forKey: Key.ragUsedCount)
    }

    func noteDatasetEmbedded() {
        let c = d.integer(forKey: Key.datasetEmbeddedCount)
        d.set(c + 1, forKey: Key.datasetEmbeddedCount)
    }

    private func noteWebSearchUsed() {
        let c = d.integer(forKey: Key.webSearchUsedCount)
        d.set(c + 1, forKey: Key.webSearchUsedCount)
    }

    private func noteRemoteUsed() {
        let c = d.integer(forKey: Key.remoteUsedCount)
        d.set(c + 1, forKey: Key.remoteUsedCount)
    }

    func recordPositiveTurn(_ signals: ReviewTurnSignals, chatVM: ChatVM) {
        if signals.usedRAG { noteRAGUsed() }
        if signals.usedWebSearch { noteWebSearchUsed() }
        if signals.usedRemoteInference { noteRemoteUsed() }

        // Let the completed answer settle before asking. If the user immediately
        // starts another task, the idle guard below suppresses the request.
        pendingPromptTask?.cancel()
        pendingPromptTask = Task { @MainActor [weak chatVM] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let chatVM else { return }
            self.safeMaybePromptIfEligible(chatVM: chatVM)
        }
    }

    // Recheck the live UI state after the positive-moment delay.
    private func safeMaybePromptIfEligible(chatVM: ChatVM?) {
        // Don’t show if actively generating or dataset processing banner is up
        if let vm = chatVM {
            if vm.isStreaming { return }
            if vm.injectionStage != .none { return }
            if vm.stillLoading || vm.loading { return }
            if vm.datasetManager?.processingStatus.values.contains(where: { status in
                status.stage != .completed && status.stage != .failed
            }) == true { return }
        }
        // Don’t prompt if app is not in foreground
        #if canImport(UIKit)
        if UIApplication.shared.applicationState != .active { return }
        #elseif canImport(AppKit)
        if !NSApplication.shared.isActive { return }
        #endif
        maybePrompt()
    }

    private func maybePrompt() {
        let sessions = d.integer(forKey: Key.sessionCount)
        let lastRequest = Self.mostRecentRequestDate(
            current: d.object(forKey: Key.lastRequestDate) as? Date,
            legacyPrompt: d.object(forKey: Key.lastPromptDate) as? Date,
            legacyAttempt: d.object(forKey: Key.lastAttemptDate) as? Date
        )
        let milestones = Milestones(
            datasetEmbeddedCount: d.integer(forKey: Key.datasetEmbeddedCount),
            ragUsedCount: d.integer(forKey: Key.ragUsedCount),
            webSearchUsedCount: d.integer(forKey: Key.webSearchUsedCount),
            remoteUsedCount: d.integer(forKey: Key.remoteUsedCount)
        )
        guard ReviewGate.shouldPrompt(sessions: sessions,
                                      lastRequestDate: lastRequest,
                                      milestones: milestones) else { return }
        guard requestReviewIfAppropriate() else { return }
        d.set(Date(), forKey: Key.lastRequestDate)
    }

    nonisolated static func mostRecentRequestDate(
        current: Date?,
        legacyPrompt: Date?,
        legacyAttempt: Date?
    ) -> Date? {
        [current, legacyPrompt, legacyAttempt].compactMap { $0 }.max()
    }

    // MARK: - StoreKit bridge
    #if canImport(StoreKit) && canImport(UIKit)
    private func requestReviewIfAppropriate() -> Bool {
        guard let scene = UIApplication.shared
            .connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return false }
        // iOS 16+ replacement for the deprecated SKStoreReviewController.requestReview(in:).
        AppStore.requestReview(in: scene)
        return true
    }
    #elseif canImport(StoreKit) && canImport(AppKit)
    private func requestReviewIfAppropriate() -> Bool {
        let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
        guard let controller = window?.contentViewController else { return false }
        AppStore.requestReview(in: controller)
        return true
    }
    #else
    private func requestReviewIfAppropriate() -> Bool { false }
    #endif

    // MARK: - Fallback deep link (Settings entry point)
    func openWriteReviewPageIfAvailable() {
        guard let appID = Bundle.main.infoDictionary?["AppStoreID"] as? String,
              !appID.isEmpty else { return }
        #if canImport(UIKit)
        let url = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        let url = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!
        NSWorkspace.shared.open(url)
        #endif
    }
}
