import XCTest
@testable import Noema

final class BackgroundModelUnloadPolicyTests: XCTestCase {
    func testKeepsModelWhileStreaming() {
        let decision = policy.decision(for: profile(format: .gguf, isStreaming: true))

        XCTAssertEqual(decision, .keep(reason: "generation in progress"))
    }

    func testKeepsLightweightLocalRuntimesReady() {
        XCTAssertEqual(
            policy.decision(for: profile(format: .et, estimatedWorkingSetBytes: 4_000_000_000)),
            .keep(reason: "lightweight runtime kept ready")
        )
        XCTAssertEqual(
            policy.decision(for: profile(format: .ane, estimatedWorkingSetBytes: 4_000_000_000)),
            .keep(reason: "lightweight runtime kept ready")
        )
        XCTAssertEqual(
            policy.decision(for: profile(format: .afm, estimatedWorkingSetBytes: 4_000_000_000)),
            .keep(reason: "lightweight runtime kept ready")
        )
    }

    func testUnloadsLargeGGUFImmediatelyInBackground() {
        let decision = policy.decision(
            for: profile(
                format: .gguf,
                estimatedWorkingSetBytes: 5_000_000_000,
                sceneState: .background
            )
        )

        XCTAssertEqual(decision, .unload(delaySeconds: 0, reason: "large local runtime"))
    }

    func testDelaysLargeGGUFUnloadWhenSceneIsInactive() {
        let decision = policy.decision(
            for: profile(
                format: .gguf,
                estimatedWorkingSetBytes: 5_000_000_000,
                sceneState: .inactive
            )
        )

        XCTAssertEqual(decision, .unload(delaySeconds: 90, reason: "large local runtime"))
    }

    func testKeepsSmallMLXRuntimeUnderThreshold() {
        let decision = policy.decision(
            for: profile(format: .mlx, estimatedWorkingSetBytes: 750_000_000)
        )

        XCTAssertEqual(decision, .keep(reason: "working set below background threshold"))
    }

    private var policy: BackgroundModelUnloadPolicy {
        BackgroundModelUnloadPolicy(isEnabled: true, inactiveDelaySeconds: 90)
    }

    private func profile(
        format: ModelFormat?,
        isStreaming: Bool = false,
        estimatedWorkingSetBytes: Int64? = 5_000_000_000,
        sceneState: BackgroundModelUnloadPolicy.SceneState = .background
    ) -> BackgroundModelUnloadPolicy.Profile {
        BackgroundModelUnloadPolicy.Profile(
            hasActiveChatModel: true,
            isStreaming: isStreaming,
            format: format,
            estimatedWorkingSetBytes: estimatedWorkingSetBytes,
            memoryBudgetBytes: 6_000_000_000,
            sceneState: sceneState
        )
    }
}
