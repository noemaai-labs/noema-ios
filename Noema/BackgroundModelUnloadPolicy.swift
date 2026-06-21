import Foundation

struct BackgroundModelUnloadPolicy: Equatable, Sendable {
    enum SceneState: Equatable, Sendable {
        case active
        case inactive
        case background
    }

    struct Profile: Equatable, Sendable {
        var hasActiveChatModel: Bool
        var isStreaming: Bool
        var format: ModelFormat?
        var estimatedWorkingSetBytes: Int64?
        var memoryBudgetBytes: Int64?
        var sceneState: SceneState
    }

    enum Decision: Equatable, Sendable {
        case keep(reason: String)
        case unload(delaySeconds: TimeInterval, reason: String)

        var shouldUnload: Bool {
            if case .unload = self { return true }
            return false
        }
    }

    static let enabledKey = "backgroundUnloadLargeModelsEnabled"
    static let inactiveDelaySecondsKey = "backgroundUnloadInactiveDelaySeconds"
    static let defaultInactiveDelaySeconds: TimeInterval = 120
    static let largeWorkingSetThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024

    var isEnabled: Bool
    var inactiveDelaySeconds: TimeInterval

    init(isEnabled: Bool = true, inactiveDelaySeconds: TimeInterval = Self.defaultInactiveDelaySeconds) {
        self.isEnabled = isEnabled
        self.inactiveDelaySeconds = max(0, inactiveDelaySeconds)
    }

    init(defaults: UserDefaults) {
        let storedEnabled = defaults.object(forKey: Self.enabledKey) as? Bool
        let storedDelay = defaults.object(forKey: Self.inactiveDelaySecondsKey) as? Double
        self.init(
            isEnabled: storedEnabled ?? true,
            inactiveDelaySeconds: storedDelay ?? Self.defaultInactiveDelaySeconds
        )
    }

    func decision(for profile: Profile) -> Decision {
        guard isEnabled else {
            return .keep(reason: "policy disabled")
        }
        guard profile.sceneState != .active else {
            return .keep(reason: "scene active")
        }
        guard profile.hasActiveChatModel else {
            return .keep(reason: "no active chat model")
        }
        guard !profile.isStreaming else {
            return .keep(reason: "generation in progress")
        }
        guard let format = profile.format else {
            return .keep(reason: "no local runtime format")
        }

        switch format {
        case .et, .ane, .afm, .coreai:
            return .keep(reason: "lightweight runtime kept ready")
        case .gguf:
            return unloadDecision(for: profile, fallbackToLargeRuntime: true)
        case .mlx:
            return unloadDecision(for: profile, fallbackToLargeRuntime: false)
        }
    }

    private func unloadDecision(for profile: Profile, fallbackToLargeRuntime: Bool) -> Decision {
        let threshold = largeThreshold(memoryBudgetBytes: profile.memoryBudgetBytes)
        let isLarge = profile.estimatedWorkingSetBytes.map { $0 >= threshold } ?? fallbackToLargeRuntime
        guard isLarge else {
            return .keep(reason: "working set below background threshold")
        }
        let delay = profile.sceneState == .inactive ? inactiveDelaySeconds : 0
        return .unload(delaySeconds: delay, reason: "large local runtime")
    }

    private func largeThreshold(memoryBudgetBytes: Int64?) -> Int64 {
        guard let memoryBudgetBytes, memoryBudgetBytes > 0 else {
            return Self.largeWorkingSetThresholdBytes
        }
        return max(Self.largeWorkingSetThresholdBytes, memoryBudgetBytes / 3)
    }
}
