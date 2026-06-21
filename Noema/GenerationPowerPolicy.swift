import Foundation

struct GenerationPowerPolicyDecision: Equatable, Sendable {
    let settings: ModelSettings
    let originalThreadCount: Int
    let appliedThreadCount: Int
    let originalContextLength: Int
    let appliedContextLength: Int
    let reasons: [Reason]

    enum Reason: String, Hashable, Sendable {
        case lowPowerMode
        case seriousThermal
        case criticalThermal

        var localizedTitleKey: String {
            switch self {
            case .lowPowerMode: return "Low Power Mode"
            case .seriousThermal: return "Serious thermal state"
            case .criticalThermal: return "Critical thermal state"
            }
        }
    }

    var adapted: Bool {
        originalThreadCount != appliedThreadCount
            || originalContextLength != appliedContextLength
            || !reasons.isEmpty
    }
}

enum GenerationPowerPolicy {
    struct Environment: Equatable, Sendable {
        let thermalState: ProcessInfo.ThermalState
        let lowPowerMode: Bool
        let activeProcessorCount: Int

        static var current: Self {
            Self(
                thermalState: ProcessInfo.processInfo.thermalState,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
            )
        }
    }

    static func adjustedSettings(
        _ settings: ModelSettings,
        format: ModelFormat,
        environment: Environment = .current
    ) -> GenerationPowerPolicyDecision {
        let requestedThreads = settings.cpuThreads > 0
            ? settings.cpuThreads
            : ModelSettings.recommendedInferenceThreadCount
        let originalThreads = min(max(1, requestedThreads), ModelSettings.maxInferenceThreadCount)
        let originalContext = max(1, Int(settings.contextLength.rounded()))

        guard format == .gguf || format == .mlx || format == .et else {
            return GenerationPowerPolicyDecision(
                settings: settings,
                originalThreadCount: originalThreads,
                appliedThreadCount: originalThreads,
                originalContextLength: originalContext,
                appliedContextLength: originalContext,
                reasons: []
            )
        }

        var reasons: [GenerationPowerPolicyDecision.Reason] = []
        let activeCores = max(1, environment.activeProcessorCount)
        var threadLimit = ModelSettings.maxInferenceThreadCount
        var contextLimit: Int?
        var adjusted = settings

        if environment.lowPowerMode {
            reasons.append(.lowPowerMode)
            threadLimit = min(threadLimit, max(1, activeCores / 2))
            contextLimit = min(contextLimit ?? 4096, 4096)
            adjusted.keepInMemory = false
        }

        switch environment.thermalState {
        case .critical:
            reasons.append(.criticalThermal)
            threadLimit = min(threadLimit, max(1, activeCores / 3))
            contextLimit = min(contextLimit ?? 2048, 2048)
            adjusted.keepInMemory = false
            adjusted.disableWarmup = true
        case .serious:
            reasons.append(.seriousThermal)
            threadLimit = min(threadLimit, max(1, activeCores / 2))
            contextLimit = min(contextLimit ?? 4096, 4096)
            adjusted.keepInMemory = false
            adjusted.disableWarmup = true
        case .nominal, .fair:
            break
        @unknown default:
            break
        }

        let appliedThreads = min(originalThreads, max(1, threadLimit))
        adjusted.cpuThreads = appliedThreads
        if let contextLimit {
            adjusted.contextLength = Double(min(originalContext, max(1, contextLimit)))
        }

        return GenerationPowerPolicyDecision(
            settings: adjusted,
            originalThreadCount: originalThreads,
            appliedThreadCount: appliedThreads,
            originalContextLength: originalContext,
            appliedContextLength: Int(adjusted.contextLength.rounded()),
            reasons: Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        )
    }
}
