// ModelRAMAdvisor.swift
import SwiftUI

@_silgen_name("app_available_memory")
fileprivate func c_app_available_memory() -> UInt

enum ModelRAMAdvisor {
    struct GGUFKVCacheEstimate: Equatable, Sendable {
        let kCacheQuant: CacheQuant
        let vCacheQuant: CacheQuant

        static let f16F16 = Self(kCacheQuant: .f16, vCacheQuant: .f16)

        init(kCacheQuant: CacheQuant = .f16, vCacheQuant: CacheQuant = .f16) {
            self.kCacheQuant = kCacheQuant
            self.vCacheQuant = vCacheQuant
        }

        var combinedBytesPerElement: Double {
            Self.bytesPerElement(for: kCacheQuant) + Self.bytesPerElement(for: vCacheQuant)
        }

        static func resolved(from settings: ModelSettings) -> Self {
            Self(
                kCacheQuant: settings.kCacheQuant,
                vCacheQuant: settings.flashAttention ? settings.vCacheQuant : .f16
            )
        }

        static func resolvedFromEnvironment() -> Self {
            let kQuant = quantFromEnvironment(named: "LLAMA_K_QUANT") ?? .f16
            let vQuant: CacheQuant = flashAttentionEnabledFromEnvironment()
                ? (quantFromEnvironment(named: "LLAMA_V_QUANT") ?? .f16)
                : .f16
            return Self(kCacheQuant: kQuant, vCacheQuant: vQuant)
        }

        private static func quantFromEnvironment(named name: String) -> CacheQuant? {
            guard let value = environmentValue(named: name) else { return nil }
            return CacheQuant(rawValue: value.uppercased())
        }

        private static func flashAttentionEnabledFromEnvironment() -> Bool {
            guard let rawValue = environmentValue(named: "LLAMA_FLASH_ATTENTION") else {
                return false
            }
            if let numeric = Int(rawValue) {
                return numeric > 0
            }
            switch rawValue.lowercased() {
            case "on", "enabled", "true", "yes":
                return true
            default:
                return false
            }
        }

        private static func environmentValue(named name: String) -> String? {
            guard let rawValue = getenv(name) else { return nil }
            let value = String(cString: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        private static func bytesPerElement(for quant: CacheQuant) -> Double {
            // Exact bytes/element from the vendored ggml block layouts:
            // q8_0 = 34/32, q5_0 = 22/32, q5_1 = 24/32, q4_0 = 18/32,
            // q4_1 = 20/32, iq4_nl = 18/32.
            switch quant {
            case .f32:
                return 4.0
            case .f16:
                return 2.0
            case .q8_0:
                return 34.0 / 32.0
            case .q5_0:
                return 22.0 / 32.0
            case .q5_1:
                return 24.0 / 32.0
            case .q4_0:
                return 18.0 / 32.0
            case .q4_1:
                return 20.0 / 32.0
            case .iq4_nl:
                return 18.0 / 32.0
            }
        }
    }

    /// Returns the current available bytes the app may allocate before hitting its limit.
    /// Uses os_proc_available_memory via C bridge. Returns nil if unavailable or zero.
    private static func availableMemoryBytes() -> Int64? {
        let v = Int64(c_app_available_memory())
        return v > 0 ? v : nil
    }
    /// Conservative multiplier from quant file size to approximate working set in RAM
    /// for weights and runtime overheads (not including KV cache which scales with context).
    /// Values vary per format; these are rough heuristics.
    private static func baseWeightsMultiplier(for format: ModelFormat) -> Double {
        switch format {
        case .gguf: return 1.3   // slightly more conservative
        case .mlx:  return 1.2   // slightly more conservative
        case .et:  return 1.1   // slightly more conservative
        case .ane: return 1.0
        case .afm: return 1.0
        case .coreai: return 1.0
        }
    }

    /// Approximate hidden size from known quant sizes when explicit metadata is unavailable.
    /// This is a heuristic to scale KV cache cost with model capacity.
    private static func approximateHiddenSize(format: ModelFormat, sizeBytes: Int64) -> Int {
        // Heuristic buckets derived from common Llama/Mistral quants
        let gb = Double(sizeBytes) / 1_073_741_824.0
        switch format {
        case .gguf:
            if gb < 3.0 { return 3072 }     // very small (e.g., 3B/4B)
            if gb < 6.0 { return 4096 }     // 7B class
            if gb < 12.0 { return 5120 }    // 13B class
            if gb < 24.0 { return 6656 }    // 30B class
            return 8192                      // 70B class and above
        case .mlx, .ane, .et, .afm, .coreai:
            // MLX/Apple/ET models vary widely; use a modest default
            if gb < 3.0 { return 3072 }
            if gb < 6.0 { return 4096 }
            if gb < 12.0 { return 5120 }
            return 6144
        }
    }

    private static func combinedKVBytesPerElement(format: ModelFormat,
                                                  kvCacheEstimate: GGUFKVCacheEstimate) -> Double {
        switch format {
        case .gguf:
            return kvCacheEstimate.combinedBytesPerElement
        case .mlx, .ane, .et, .afm, .coreai:
            return 4.0
        }
    }

    /// Estimate KV cache memory in bytes given context length and optional architecture hints.
    /// GQA-aware heuristic: KV size scales with num_kv_heads/num_attention_heads factor (typically 1/8 for Llama-2/3).
    /// Rough formula: layers * context * hidden_size * (k_bytes + v_bytes) * gqa_factor.
    private static func estimateKVBytes(format: ModelFormat,
                                        sizeBytes: Int64,
                                        contextLength: Int,
                                        layerCount: Int?,
                                        kvCacheEstimate: GGUFKVCacheEstimate) -> Int64 {
        let layers = max(1, layerCount ?? 32)
        let hidden = approximateHiddenSize(format: format, sizeBytes: sizeBytes)
        let combinedBytesPerElement = combinedKVBytesPerElement(format: format, kvCacheEstimate: kvCacheEstimate)
        // Typical GQA ratios:
        // - Llama 7B/8B: n_kv_head = n_head / 8
        // - Many 13B: n_kv_head = n_head / 8 or /4
        // - 70B: often /8
        // Without header parsing of n_head/n_kv_head, assume a safer 1/4 reduction for GGUF and 1/2 for others
        let gqaFactor: Double = {
            switch format {
            case .gguf: return 0.45 // more conservative KV estimate
            case .mlx, .ane, .et, .afm, .coreai: return 0.6
            }
        }()
        let kv = Double(layers) * Double(max(1, contextLength)) * Double(hidden) * combinedBytesPerElement
        let adjustedKV = max(0.0, min(kv * gqaFactor, Double(Int64.max)))
        return Int64(adjustedKV)
    }

    private static func estimatedWeightBytes(format: ModelFormat, sizeBytes: Int64, moeInfo: MoEInfo?, layerCount: Int?) -> Int64 {
        let baseMultiplier = baseWeightsMultiplier(for: format)

        // Fallback to dense heuristic when we cannot confidently reason about MoE structure
        guard format == .gguf,
              let info = moeInfo,
              info.isMoE,
              let totalLayers = info.totalLayerCount ?? layerCount,
              totalLayers > 0 else {
            return Int64(Double(sizeBytes) * baseMultiplier)
        }

        // Dimensions and layer breakdown
        let expertCount = max(info.expertCount, 1)
        let activeExperts = min(max(info.defaultUsed ?? 2, 1), expertCount) // typical top-2 gating fallback
        let hiddenSize = info.hiddenSize ?? approximateHiddenSize(format: format, sizeBytes: sizeBytes)
        let feedForwardSize = info.feedForwardSize ?? hiddenSize * 4
        let moeLayers = max(info.moeLayerCount ?? totalLayers, 0)
        let denseLayers = max(totalLayers - moeLayers, 0)

        // Parameter accounting (very coarse but architecture-aware):
        // - Attention per layer ~ 4 * d * d (q,k,v,o projections)
        // - FFN (SwiGLU-style) per layer ~ 3 * d * f
        // - MoE FFN per layer ~ (#experts) * (3 * d * f)
        // - Embedding params ~ vocab * d (optional when available)
        let d = Double(hiddenSize)
        let f = Double(feedForwardSize)
        let L = Double(totalLayers)
        let coefficient = 3.0

        let attentionParams = L * 4.0 * d * d
        let denseFFNParams = Double(denseLayers) * coefficient * d * f
        let perExpertParams = coefficient * d * f
        let allMoEParams = Double(moeLayers) * Double(expertCount) * perExpertParams
        let embeddingParams = info.vocabSize.map { Double($0) * d } ?? 0.0

        // Total parameter count represented by the quant file (used to derive bytes/param)
        let totalParams = attentionParams + denseFFNParams + allMoEParams + embeddingParams
        guard totalParams > 0 else {
            return Int64(Double(sizeBytes) * baseMultiplier)
        }

        // Convert active parameter set into bytes using bytes-per-param implied by the quant file
        let bytesPerParam = Double(sizeBytes) / totalParams

        // Active MoE parameters: only a subset of experts are used per MoE layer at inference time
        let activeMoEParams = Double(moeLayers) * Double(activeExperts) * perExpertParams
        let activeParams = attentionParams + denseFFNParams + activeMoEParams + embeddingParams

        // Apply base multiplier to approximate runtime expansion/allocator overhead
        var weightsBytes = activeParams * bytesPerParam * baseMultiplier

        // Modest extra safety for MoE routing/gating buffers without double-counting global safety later
        let moeSafety: Double = 1.05
        weightsBytes *= moeSafety

        // Prevent overflow and return
        let clamped = max(0.0, min(weightsBytes, Double(Int64.max)))
        return Int64(clamped)
    }

    /// Whether a model of given format and size likely fits within the device RAM budget
    /// for a specific context length and (optional) layer count.
    static func fitsInRAM(format: ModelFormat,
                          sizeBytes: Int64,
                          contextLength: Int,
                          layerCount: Int?,
                          moeInfo: MoEInfo? = nil,
                          kvCacheEstimate: GGUFKVCacheEstimate = .f16F16) -> Bool {
        let (estimate, conservativeBudget) = budgetAndEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate
        )
        let liveAvailable = availableMemoryBytes()

#if os(macOS) || targetEnvironment(macCatalyst)
        if let conservativeBudget, let liveAvailable, liveAvailable > 0 {
            return estimate <= max(conservativeBudget, liveAvailable)
        }
        if let conservativeBudget {
            return estimate <= conservativeBudget
        }
        if let liveAvailable, liveAvailable > 0 {
            return estimate <= liveAvailable
        }
        // If no budget or availability information is present, default to permissive (legacy behavior)
        return true
#else
        if let liveAvailable, liveAvailable > 0 {
            if let conservativeBudget {
                return estimate <= min(conservativeBudget, liveAvailable)
            }
            return estimate <= liveAvailable
        }
        if let conservativeBudget {
            return estimate <= conservativeBudget
        }
        // If no budget information is available at all, default to permissive (legacy behavior)
        return true
#endif
    }

    /// Backwards-compatible overload (assumes a default context of 4096 and unknown layer count).
    static func fitsInRAM(format: ModelFormat, sizeBytes: Int64) -> Bool {
        return fitsInRAM(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: 4096,
            layerCount: nil,
            moeInfo: nil,
            kvCacheEstimate: .f16F16
        )
    }

    /// Exposes the raw estimate and device budget for UI display.
    static func estimateAndBudget(format: ModelFormat,
                                  sizeBytes: Int64,
                                  contextLength: Int,
                                  layerCount: Int?,
                                  moeInfo: MoEInfo? = nil,
                                  kvCacheEstimate: GGUFKVCacheEstimate = .f16F16) -> (estimate: Int64, budget: Int64?) {
        return budgetAndEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate
        )
    }

    /// Compute maximum context that fits under budget for this model on this device.
    /// Returns nil if no budget info is available.
    static func maxContextUnderBudget(format: ModelFormat,
                                      sizeBytes: Int64,
                                      layerCount: Int?,
                                      moeInfo: MoEInfo? = nil,
                                      upperBound: Int? = nil,
                                      kvCacheEstimate: GGUFKVCacheEstimate = .f16F16,
                                      budgetBytesOverride: Int64? = nil) -> Int? {
        let info = DeviceRAMInfo.current()
        guard let budget = budgetBytesOverride ?? info.conservativeLimitBytes() else { return nil }
        // Invert estimate: budget ≈ safety*(weights + kv(ctx)) + overhead
        let safety: Double = 1.10
        let overhead: Int64 = 200 * 1024 * 1024
        let weights = estimatedWeightBytes(format: format, sizeBytes: sizeBytes, moeInfo: moeInfo, layerCount: layerCount)
        let remaining = max(Int64(0), Int64(Double(budget) / safety) - (weights + overhead))
        if remaining <= 0 { return 512 }
        // Solve remaining ≈ kv(ctx)
        // kv(ctx) ≈ 2 * layers * ctx * hidden * 2B * gqa
        // So ctx ≈ remaining / (const)
        let hidden = approximateHiddenSize(format: format, sizeBytes: sizeBytes)
        let layers = max(1, layerCount ?? 32)
        let gqa: Double = (format == .gguf) ? 0.45 : 0.6
        let denom = Double(layers * hidden) * combinedKVBytesPerElement(format: format, kvCacheEstimate: kvCacheEstimate) * gqa
        if denom <= 0 { return 512 }
        let ctx = Int(Double(remaining) / denom)
        let resolvedUpperBound = upperBound.map { max(512, $0) } ?? Int.max
        return max(512, min(ctx, resolvedUpperBound))
    }

    /// Returns (estimateWorkingSetBytes, budgetBytes)
    private static func budgetAndEstimate(format: ModelFormat,
                                          sizeBytes: Int64,
                                          contextLength: Int,
                                          layerCount: Int?,
                                          moeInfo: MoEInfo?,
                                          kvCacheEstimate: GGUFKVCacheEstimate) -> (Int64, Int64?) {
        let info = DeviceRAMInfo.current()
        let budgetBytes: Int64? = info.conservativeLimitBytes()
        // Weights + overheads
        let weights = estimatedWeightBytes(format: format, sizeBytes: sizeBytes, moeInfo: moeInfo, layerCount: layerCount)
        // KV cache scales roughly linearly with context
        let kv = estimateKVBytes(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            kvCacheEstimate: kvCacheEstimate
        )
        // Slightly higher fixed overhead to account for fragmentation and allocator slop
        let overhead: Int64 = 200 * 1024 * 1024
        // Add a small safety margin on top of all components
        let safetyFactor: Double = 1.10
        let estimate = Int64(Double(weights &+ kv &+ overhead) * safetyFactor)
        return (estimate, budgetBytes)
    }

    @ViewBuilder
    static func badge(format: ModelFormat, sizeBytes: Int64, contextLength: Int = 4096, layerCount: Int? = nil, moeInfo: MoEInfo? = nil) -> some View {
        let (estimate, budget) = budgetAndEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: .f16F16
        )
        let fits: Bool = {
            guard let budget else { return true }
            return estimate <= budget
        }()
        RAMBadgeView(fits: fits, estimate: estimate, budget: budget, context: contextLength)
    }
}

private struct RAMBadgeView: View {
    let fits: Bool
    let estimate: Int64
    let budget: Int64?
    let context: Int
    @State private var showInfo = false
    @Environment(\.locale) private var locale

    private var color: Color { fits ? .green : .red }
    private var symbol: String { fits ? "checkmark" : "xmark" }

    private func localizedMemoryString(_ bytes: Int64) -> String {
        let useGB = bytes >= 1_073_741_824
        let value = useGB ? Double(bytes) / 1_073_741_824.0 : Double(bytes) / 1_048_576.0
        let unit: UnitInformationStorage = useGB ? .gigabytes : .megabytes

        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.locale = locale
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.numberFormatter.minimumFractionDigits = 0
        return formatter.string(from: Measurement(value: value, unit: unit))
    }

    private var infoText: String {
        let estStr = localizedMemoryString(estimate)
        let budStr = budget.map { localizedMemoryString($0) } ?? "--"
        let ctxFormatter = NumberFormatter()
        ctxFormatter.locale = locale
        ctxFormatter.numberStyle = .decimal
        let ctx = ctxFormatter.string(from: NSNumber(value: context)) ?? "\(context)"
        return String.localizedStringWithFormat(
            String(localized: "Estimate: %@\nBudget: %@\nContext length: %@ tokens\n\nThis is an estimate based on your device’s memory budget, context length (KV cache), and typical runtime overheads. Actual usage may vary.", locale: locale),
            estStr, budStr, ctx
        )
    }

    var body: some View {
        Button(action: { showInfo = true }) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(color.opacity(0.15))
                .clipShape(Capsule())
                .accessibilityLabel(fits ? LocalizedStringKey("Model likely fits in RAM") : LocalizedStringKey("Model may not fit in RAM"))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol).foregroundColor(color)
                    Text(fits ? LocalizedStringKey("Fits in RAM (estimated)") : LocalizedStringKey("May not fit (estimated)"))
                        .font(.headline)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    Text(infoText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)

                HStack {
                    Spacer()
                    Button(LocalizedStringKey("OK")) { showInfo = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 420, alignment: .leading)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}
