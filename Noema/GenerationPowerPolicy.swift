import Foundation

struct GenerationPowerPolicyDecision: Equatable, Sendable {
    let settings: ModelSettings
    let originalThreadCount: Int
    let appliedThreadCount: Int
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
            || !reasons.isEmpty
    }
}

/// Launch gate for Noema Overfit paged execution. Paged decode adds sustained
/// storage and CPU traffic on top of inference, so thermals gate it harder
/// than a resident launch: critical heat refuses outright, and degraded
/// conditions tell the caller to shrink IO fan-out and context instead.
enum OverfitPagedLaunchGate: Equatable, Sendable {
    case allowed
    /// Launch may proceed, but callers should lower paged IO depth/prefetch
    /// and context for the listed conditions.
    case allowedReduced(reasons: [GenerationPowerPolicyDecision.Reason])
    case blocked(reason: GenerationPowerPolicyDecision.Reason)
}

enum GenerationPowerPolicy {
    struct Environment: Equatable, Sendable {
        let thermalState: ProcessInfo.ThermalState
        let lowPowerMode: Bool
        let activeProcessorCount: Int

        init(
            thermalState: ProcessInfo.ThermalState,
            lowPowerMode: Bool,
            activeProcessorCount: Int
        ) {
            self.thermalState = thermalState
            self.lowPowerMode = lowPowerMode
            self.activeProcessorCount = activeProcessorCount
        }

        static var current: Self {
            Self(
                thermalState: ProcessInfo.processInfo.thermalState,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
            )
        }
    }

    static func pagedLaunchGate(environment: Environment = .current) -> OverfitPagedLaunchGate {
        if environment.thermalState == .critical {
            return .blocked(reason: .criticalThermal)
        }
        var reasons: [GenerationPowerPolicyDecision.Reason] = []
        if environment.thermalState == .serious {
            reasons.append(.seriousThermal)
        }
        if environment.lowPowerMode {
            reasons.append(.lowPowerMode)
        }
        guard reasons.isEmpty else {
            return .allowedReduced(reasons: reasons.sorted { $0.rawValue < $1.rawValue })
        }
        return .allowed
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

        guard format == .gguf || format == .mlx || format == .et else {
            return GenerationPowerPolicyDecision(
                settings: settings,
                originalThreadCount: originalThreads,
                appliedThreadCount: originalThreads,
                reasons: []
            )
        }

        var reasons: [GenerationPowerPolicyDecision.Reason] = []
        let activeCores = max(1, environment.activeProcessorCount)
        var threadLimit = ModelSettings.maxInferenceThreadCount
        var adjusted = settings

        if environment.lowPowerMode {
            reasons.append(.lowPowerMode)
            threadLimit = min(threadLimit, max(1, activeCores / 2))
            adjusted.keepInMemory = false
        }

        switch environment.thermalState {
        case .critical:
            reasons.append(.criticalThermal)
            threadLimit = min(threadLimit, max(1, activeCores / 3))
            adjusted.keepInMemory = false
            adjusted.disableWarmup = true
        case .serious:
            reasons.append(.seriousThermal)
            threadLimit = min(threadLimit, max(1, activeCores / 2))
            adjusted.keepInMemory = false
            adjusted.disableWarmup = true
        case .nominal, .fair:
            break
        @unknown default:
            break
        }

        let appliedThreads = min(originalThreads, max(1, threadLimit))
        adjusted.cpuThreads = appliedThreads

        return GenerationPowerPolicyDecision(
            settings: adjusted,
            originalThreadCount: originalThreads,
            appliedThreadCount: appliedThreads,
            reasons: Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        )
    }
}
