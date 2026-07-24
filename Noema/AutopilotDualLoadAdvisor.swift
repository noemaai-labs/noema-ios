import Foundation

/// Runtime compatibility for the second local model used by Autopilot on Mac.
///
/// The embedded llama.cpp bridge owns one process-global server. `--parallel`
/// controls sequence slots inside that one server; it does not create another
/// model host. A GGUF escalation model can therefore live beside MLX (or another
/// non-GGUF resident), but two GGUF models cannot remain loaded together.
enum AutopilotLocalEscalationPolicy {
    static func supports(_ format: ModelFormat) -> Bool {
        format == .mlx || format == .gguf
    }

    static func canCoexist(escalationFormat: ModelFormat,
                           residentFormat: ModelFormat?) -> Bool {
        guard supports(escalationFormat) else { return false }
        return !(escalationFormat == .gguf && residentFormat == .gguf)
    }
}

enum AutopilotDualLoadAdvisor {

    /// Everything the RAM estimator needs about one model at one context size.
    struct ModelLoadPlan: Equatable {
        var format: ModelFormat
        var sizeBytes: Int64
        var contextLength: Int
        var layerCount: Int?
        var moeInfo: MoEInfo?
        var kvCacheEstimate: ModelRAMAdvisor.GGUFKVCacheEstimate = .f16F16
        var runtimeConfiguration: ModelRAMAdvisor.RuntimeConfiguration = .conservativeDefault
    }

    struct Assessment: Equatable {
        var fits: Bool
        /// Sum of both models' working-set estimates (each already carries
        /// ModelRAMAdvisor's fixed overhead + safety factor, so the sum is
        /// deliberately conservative) plus MLX GPU-cache headroom when the
        /// escalation model runs on MLX.
        var combinedBytes: Int64
        var residentBytes: Int64
        var escalationBytes: Int64
        var budgetBytes: Int64?
    }

    static func plan(for model: LocalModel, settings: ModelSettings) -> ModelLoadPlan {
        ModelLoadPlan(
            format: model.format,
            sizeBytes: Int64(model.sizeGB * 1_073_741_824.0),
            contextLength: max(512, Int(settings.contextLength)),
            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
            moeInfo: model.moeInfo,
            kvCacheEstimate: model.format == .gguf ? .resolved(from: settings) : .f16F16,
            runtimeConfiguration: .resolved(from: settings, modelURL: model.url)
        )
    }

    /// `resident` is the small chat model Autopilot rides on (nil when no local
    /// model is loaded — then only the escalation model is counted, and the
    /// caller should re-assess once a chat model loads).
    static func assess(resident: ModelLoadPlan?,
                       escalation: ModelLoadPlan,
                       budgetBytesOverride: Int64? = nil) -> Assessment {
        let residentEstimate = resident.map { estimate(for: $0) } ?? 0
        var escalationEstimate = estimate(for: escalation)
        if escalation.format == .mlx {
            // MLX keeps a Metal buffer cache alongside the weights; reserve it
            // so a fitting verdict survives real generation on the big model.
            escalationEstimate += Int64(MLXBridge.gpuCacheLimitBytes)
        }
        let combined = residentEstimate &+ escalationEstimate
        let budget = budgetBytesOverride ?? DeviceRAMInfo.current().conservativeLimitBytes()
        let fits = budget.map { combined <= $0 } ?? false
        return Assessment(
            fits: fits,
            combinedBytes: combined,
            residentBytes: residentEstimate,
            escalationBytes: escalationEstimate,
            budgetBytes: budget
        )
    }

    private static func estimate(for plan: ModelLoadPlan) -> Int64 {
        ModelRAMAdvisor.estimateAndBudget(
            format: plan.format,
            sizeBytes: plan.sizeBytes,
            contextLength: plan.contextLength,
            layerCount: plan.layerCount,
            moeInfo: plan.moeInfo,
            kvCacheEstimate: plan.kvCacheEstimate,
            runtimeConfiguration: plan.runtimeConfiguration
        ).estimate
    }
}
