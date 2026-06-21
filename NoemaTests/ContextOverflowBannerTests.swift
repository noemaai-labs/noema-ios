import XCTest
@testable import Noema

final class ContextOverflowBannerTests: XCTestCase {
    @MainActor
    func testContextOverflowBannerIsScopedToActiveSession() {
        let vm = makeChatVMWithTwoSessions()
        let sessionA = vm.sessions[0]
        let sessionB = vm.sessions[1]

        vm.activeSessionID = sessionA.id
        vm.registerContextOverflowForTesting(
            strategy: .stopAtLimit,
            promptTokens: 5_000,
            contextTokens: 4_096
        )

        XCTAssertEqual(vm.contextOverflowBanner?.strategy, .stopAtLimit)
        XCTAssertEqual(vm.contextOverflowBanner?.promptTokens, 5_000)
        XCTAssertEqual(vm.contextOverflowBanner(for: sessionA.id)?.contextTokens, 4_096)

        vm.activeSessionID = sessionB.id
        XCTAssertNil(vm.contextOverflowBanner)

        vm.activeSessionID = sessionA.id
        XCTAssertEqual(vm.contextOverflowBanner?.strategy, .stopAtLimit)
        XCTAssertEqual(vm.contextOverflowBanner?.promptTokens, 5_000)
    }

    @MainActor
    func testStartNewSessionHidesBannerButRetainsExistingSessionBanner() throws {
        let vm = makeChatVMWithTwoSessions()
        let originalSession = vm.sessions[0]

        vm.activeSessionID = originalSession.id
        vm.registerContextOverflowForTesting(
            strategy: .truncateMiddle,
            promptTokens: 6_000,
            contextTokens: 4_096
        )

        vm.startNewSession()

        let newSession = try XCTUnwrap(vm.sessions.first)
        XCTAssertEqual(vm.activeSessionID, newSession.id)
        XCTAssertNil(vm.contextOverflowBanner)
        XCTAssertEqual(vm.contextOverflowBanner(for: originalSession.id)?.strategy, .truncateMiddle)
        XCTAssertEqual(vm.contextOverflowBanner(for: originalSession.id)?.promptTokens, 6_000)
    }

    @MainActor
    func testRegisterContextOverflowUsesStreamingSessionWhenItDiffersFromActiveSession() {
        let vm = makeChatVMWithTwoSessions()
        let activeSession = vm.sessions[0]
        let streamingSession = vm.sessions[1]

        vm.activeSessionID = activeSession.id
        vm.setStreamSessionIndexForTesting(1)
        vm.registerContextOverflowForTesting(
            strategy: .rollingWindow,
            promptTokens: 5_500,
            contextTokens: 4_096
        )

        XCTAssertNil(vm.contextOverflowBanner)
        XCTAssertEqual(vm.contextOverflowBanner(for: streamingSession.id)?.strategy, .rollingWindow)
        XCTAssertEqual(vm.contextOverflowBanner(for: streamingSession.id)?.promptTokens, 5_500)
        XCTAssertNil(vm.contextOverflowBanner(for: activeSession.id))
    }

    @MainActor
    func testDeletingSessionRemovesStoredContextOverflowBanner() {
        let vm = makeChatVMWithTwoSessions()
        let sessionA = vm.sessions[0]
        let sessionB = vm.sessions[1]

        vm.activeSessionID = sessionA.id
        vm.registerContextOverflowForTesting(
            strategy: .stopAtLimit,
            promptTokens: 5_200,
            contextTokens: 4_096
        )

        vm.delete(sessionA)

        XCTAssertNil(vm.contextOverflowBanner(for: sessionA.id))
        XCTAssertEqual(vm.activeSessionID, sessionB.id)
        XCTAssertNil(vm.contextOverflowBanner)
    }

    @MainActor
    func testDismissActiveContextOverflowBannerOnlyClearsActiveSession() {
        let vm = makeChatVMWithTwoSessions()
        let sessionA = vm.sessions[0]
        let sessionB = vm.sessions[1]

        vm.activeSessionID = sessionA.id
        vm.registerContextOverflowForTesting(
            strategy: .rollingWindow,
            promptTokens: 5_000,
            contextTokens: 4_096
        )
        vm.activeSessionID = sessionB.id
        vm.registerContextOverflowForTesting(
            strategy: .truncateMiddle,
            promptTokens: 6_000,
            contextTokens: 4_096
        )

        vm.dismissActiveContextOverflowBanner()

        XCTAssertNil(vm.contextOverflowBanner(for: sessionB.id))
        XCTAssertEqual(vm.contextOverflowBanner(for: sessionA.id)?.strategy, .rollingWindow)
    }

    @MainActor
    private func makeChatVMWithTwoSessions() -> ChatVM {
        let vm = ChatVM()
        let sessionA = ChatVM.Session(
            title: "Chat A",
            messages: [ChatVM.Msg(role: "system", text: "System A", timestamp: Date())],
            date: Date()
        )
        let sessionB = ChatVM.Session(
            title: "Chat B",
            messages: [ChatVM.Msg(role: "system", text: "System B", timestamp: Date())],
            date: Date()
        )
        vm.sessions = [sessionA, sessionB]
        vm.activeSessionID = sessionA.id
        vm.setStreamSessionIndexForTesting(nil)
        return vm
    }
}
