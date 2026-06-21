import Foundation

struct QuantComparisonProfile: Identifiable, Equatable {
    enum Tier: Int, Comparable, Equatable {
        case low = 0
        case medium = 1
        case high = 2

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: String
    let label: String
    let format: ModelFormat
    let sizeBytes: Int64
    let quality: Tier
    let speed: Tier
    let ram: Tier
    let context: Tier
    let isBestQuality: Bool
    let isSmallest: Bool

    static func make(for quants: [QuantInfo], contextLength: Int = 4096) -> [QuantComparisonProfile] {
        guard !quants.isEmpty else { return [] }

        let qualityScores = quants.map { qualityScore(for: $0) }
        let maxQuality = qualityScores.max() ?? 0
        let minQuality = qualityScores.min() ?? 0
        let smallestSize = quants.map(\.sizeBytes).filter { $0 > 0 }.min()
        let largestSize = quants.map(\.sizeBytes).filter { $0 > 0 }.max()

        return quants.enumerated().map { index, quant in
            let qualityScore = qualityScores[index]
            let quality = qualityTier(score: qualityScore, min: minQuality, max: maxQuality)
            let speed = speedTier(for: quant, smallestSize: smallestSize, largestSize: largestSize)
            let ram = ramTier(for: quant, contextLength: contextLength)
            let context = contextTier(for: quant)
            return QuantComparisonProfile(
                id: "\(quant.label)-\(quant.format.rawValue)",
                label: quant.label,
                format: quant.format,
                sizeBytes: quant.sizeBytes,
                quality: quality,
                speed: speed,
                ram: ram,
                context: context,
                isBestQuality: qualityScore == maxQuality,
                isSmallest: smallestSize.map { quant.sizeBytes == $0 } ?? false
            )
        }
    }

    private static func qualityScore(for quant: QuantInfo) -> Double {
        let descriptor = quant.quantTypeDescriptor
        var score: Double = {
            if descriptor.family == .fullPrecision { return 16.0 }
            if descriptor.family == .q8_0 { return 8.4 }
            return Double(descriptor.nominalBits ?? quant.inferredBitWidth ?? 4)
        }()

        switch descriptor.family {
        case .fullPrecision:
            score += 1.0
        case .mxfp:
            score += 0.7
        case .iq:
            score += 0.35
        case .kQuant:
            score += 0.25
        case .legacy:
            score -= 0.2
        case .q8_0:
            score += 0.2
        case .generic:
            break
        }

        if descriptor.isUD {
            score += 0.3
        }

        switch descriptor.tier {
        case "XL":
            score += 0.35
        case "L":
            score += 0.25
        case "M":
            score += 0.15
        case "S":
            score += 0.05
        case "XS", "XXS":
            score -= 0.15
        default:
            break
        }

        return score
    }

    private static func qualityTier(score: Double, min: Double, max: Double) -> Tier {
        guard max > min else { return .medium }
        let normalized = (score - min) / (max - min)
        if normalized >= 0.72 { return .high }
        if normalized >= 0.30 { return .medium }
        return .low
    }

    private static func speedTier(for quant: QuantInfo, smallestSize: Int64?, largestSize: Int64?) -> Tier {
        switch quant.format {
        case .ane, .et, .afm, .coreai:
            return .high
        case .mlx, .gguf:
            break
        }

        guard let smallestSize, let largestSize, smallestSize > 0, largestSize > smallestSize, quant.sizeBytes > 0 else {
            if let bits = quant.inferredBitWidth {
                if bits <= 3 { return .high }
                if bits <= 5 { return .medium }
                return .low
            }
            return .medium
        }

        let span = Double(largestSize - smallestSize)
        let normalized = Double(quant.sizeBytes - smallestSize) / span
        if normalized <= 0.30 { return .high }
        if normalized <= 0.70 { return .medium }
        return .low
    }

    private static func ramTier(for quant: QuantInfo, contextLength: Int) -> Tier {
        let fits = ModelRAMAdvisor.fitsInRAM(
            format: quant.format,
            sizeBytes: quant.sizeBytes,
            contextLength: contextLength,
            layerCount: nil
        )
        guard fits else { return .low }

        let (estimate, budget) = ModelRAMAdvisor.estimateAndBudget(
            format: quant.format,
            sizeBytes: quant.sizeBytes,
            contextLength: contextLength,
            layerCount: nil
        )
        guard let budget, budget > 0 else { return .medium }
        let ratio = Double(estimate) / Double(budget)
        if ratio <= 0.55 { return .high }
        if ratio <= 0.85 { return .medium }
        return .low
    }

    private static func contextTier(for quant: QuantInfo) -> Tier {
        guard let maxContext = ModelRAMAdvisor.maxContextUnderBudget(
            format: quant.format,
            sizeBytes: quant.sizeBytes,
            layerCount: nil
        ) else {
            if let bits = quant.inferredBitWidth, bits <= 4 { return .high }
            return .medium
        }

        if maxContext >= 8192 { return .high }
        if maxContext >= 4096 { return .medium }
        return .low
    }
}
