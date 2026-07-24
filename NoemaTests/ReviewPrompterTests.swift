import XCTest
@testable import Noema

@MainActor
final class ReviewPrompterTests: XCTestCase {
    func testGateRequiresFiveSessionsAndACompletedMilestone() {
        let milestones = ReviewPrompter.Milestones(
            datasetEmbeddedCount: 1,
            ragUsedCount: 1,
            webSearchUsedCount: 0,
            remoteUsedCount: 0
        )

        XCTAssertFalse(
            ReviewGate.shouldPrompt(
                sessions: 4,
                lastRequestDate: nil,
                milestones: milestones
            )
        )
        XCTAssertTrue(
            ReviewGate.shouldPrompt(
                sessions: 5,
                lastRequestDate: nil,
                milestones: milestones
            )
        )
    }

    func testGateUsesSingleNinetyDayRequestCooldown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let milestones = ReviewPrompter.Milestones(
            datasetEmbeddedCount: 0,
            ragUsedCount: 0,
            webSearchUsedCount: 0,
            remoteUsedCount: 1
        )
        let eightyNineDaysAgo = Calendar.current.date(byAdding: .day, value: -89, to: now)!
        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: now)!

        XCTAssertFalse(
            ReviewGate.shouldPrompt(
                now: now,
                sessions: 5,
                lastRequestDate: eightyNineDaysAgo,
                milestones: milestones
            )
        )
        XCTAssertTrue(
            ReviewGate.shouldPrompt(
                now: now,
                sessions: 5,
                lastRequestDate: ninetyDaysAgo,
                milestones: milestones
            )
        )
    }

    func testLegacyCooldownMigrationUsesMostRecentDate() {
        let oldest = Date(timeIntervalSince1970: 100)
        let newest = Date(timeIntervalSince1970: 300)
        let middle = Date(timeIntervalSince1970: 200)

        XCTAssertEqual(
            ReviewPrompter.mostRecentRequestDate(
                current: middle,
                legacyPrompt: oldest,
                legacyAttempt: newest
            ),
            newest
        )
    }

    func testSessionIsCountedOncePerAppProcess() {
        let suiteName = "ReviewPrompterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prompter = ReviewPrompter(defaults: defaults)

        prompter.trackSession()
        prompter.trackSession()

        XCTAssertEqual(defaults.integer(forKey: "review.sessionCount"), 1)
    }

    func testPositiveCompletionCapturesSuccessfulMilestones() {
        let signals = ReviewTurnSignals.positiveCompletion(
            answerText: "Here is the grounded answer.",
            retrievedContext: "Relevant document context",
            usedWebSearch: true,
            webResultCount: 3,
            webError: nil,
            usedRemoteBackend: true,
            ranOnPrivateCloudCompute: false,
            hasFailedToolCall: false
        )

        XCTAssertEqual(
            signals,
            ReviewTurnSignals(
                usedRAG: true,
                usedWebSearch: true,
                usedRemoteInference: true
            )
        )
    }

    func testNegativeCompletionsNeverBecomeReviewMoments() {
        XCTAssertNil(signals(answerText: nil))
        XCTAssertNil(signals(answerText: "(no output)"))
        XCTAssertNil(signals(answerText: "⚠️ Model failed"))
        XCTAssertNil(signals(answerText: "Fallback answer", webError: "No results found"))
        XCTAssertNil(signals(answerText: "Fallback answer", hasFailedToolCall: true))
    }

    func testWebMilestoneRequiresAtLeastOneSuccessfulResult() {
        let signals = signals(
            answerText: "A valid answer without usable search evidence",
            usedWebSearch: true,
            webResultCount: 0
        )

        XCTAssertEqual(signals?.usedWebSearch, false)
    }

    private func signals(
        answerText: String?,
        usedWebSearch: Bool = false,
        webResultCount: Int = 0,
        webError: String? = nil,
        hasFailedToolCall: Bool = false
    ) -> ReviewTurnSignals? {
        ReviewTurnSignals.positiveCompletion(
            answerText: answerText,
            retrievedContext: nil,
            usedWebSearch: usedWebSearch,
            webResultCount: webResultCount,
            webError: webError,
            usedRemoteBackend: false,
            ranOnPrivateCloudCompute: false,
            hasFailedToolCall: hasFailedToolCall
        )
    }
}
