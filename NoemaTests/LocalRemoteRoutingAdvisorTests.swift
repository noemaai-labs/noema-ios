import XCTest
@testable import Noema

final class LocalRemoteRoutingAdvisorTests: XCTestCase {
    func testOffGridUsesLocalAndSkipsRemoteSelections() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .remoteFirst),
                selectedLocalModel: .init(format: .gguf, sizeGB: 4),
                remoteSelectionCount: 1,
                offGrid: true,
                lowPowerMode: false
            )
        )

        XCTAssertEqual(advice.route, .localOnly)
        XCTAssertEqual(advice.detail, .offGridLocal)
    }

    func testOffGridBlocksRemoteOnlyStartup() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: false, remote: true, priority: .remoteFirst),
                selectedLocalModel: nil,
                remoteSelectionCount: 1,
                offGrid: true,
                lowPowerMode: false
            )
        )

        XCTAssertEqual(advice.route, .blocked)
        XCTAssertEqual(advice.detail, .offGridNoLocal)
    }

    func testLargeLocalGGUFCallsOutRemoteFallbackWhenLocalFirst() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .localFirst),
                selectedLocalModel: .init(format: .gguf, sizeGB: 8),
                remoteSelectionCount: 1,
                offGrid: false,
                lowPowerMode: false
            )
        )

        XCTAssertEqual(advice.route, .localThenRemote)
        XCTAssertEqual(advice.detail, .largeLocalRemoteFallback)
    }

    func testLowPowerFavorsEfficientLocalModelBeforeRemote() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .remoteFirst),
                selectedLocalModel: .init(format: .et, sizeGB: 2),
                remoteSelectionCount: 1,
                offGrid: false,
                lowPowerMode: true
            )
        )

        XCTAssertEqual(advice.route, .localThenRemote)
        XCTAssertEqual(advice.detail, .lowPowerLocalEfficient)
    }

    func testRemotePriorityUsesRemoteThenLocalWhenBothConfigured() {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: .init(
                preferences: preferences(local: true, remote: true, priority: .remoteFirst),
                selectedLocalModel: .init(format: .mlx, sizeGB: 4),
                remoteSelectionCount: 1,
                offGrid: false,
                lowPowerMode: false
            )
        )

        XCTAssertEqual(advice.route, .remoteThenLocal)
        XCTAssertEqual(advice.detail, .remotePriority)
    }

    private func preferences(
        local: Bool,
        remote: Bool,
        priority: StartupPreferences.Priority
    ) -> StartupPreferences {
        StartupPreferences(
            localModelPath: local ? "/tmp/noema-model.gguf" : nil,
            remoteSelections: remote ? [
                .init(
                    backendID: UUID(uuidString: "F6AABCB2-F19D-4E54-8D85-6C130AF12B29")!,
                    backendName: "Mac Relay",
                    modelID: "remote-model",
                    modelName: "Remote Model"
                )
            ] : [],
            priority: priority
        )
    }
}
