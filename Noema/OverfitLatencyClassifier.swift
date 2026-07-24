import Foundation

enum OverfitFitClassification: String, Codable, Sendable {
    case residentInteractive
    case pagedInteractive
    case pagedSlow
    case offlineOnly
    case relayRecommended
    case unsupported
}

struct OverfitLatencyThresholds: Sendable {
    let interactiveP50Ms: Double
    let interactiveP95Ms: Double
    let interactiveStallsPer128: Int
    let slowP50Ms: Double
    let slowP95Ms: Double
    let slowStallsPer128: Int
    let stallFloorMs: Double

    /// Pinned by OverfitLatencyClassifierTests — tune only through the table.
    static let production = OverfitLatencyThresholds(
        interactiveP50Ms: 150,
        interactiveP95Ms: 350,
        interactiveStallsPer128: 0,
        slowP50Ms: 400,
        slowP95Ms: 1200,
        slowStallsPer128: 2,
        stallFloorMs: 1000
    )
}

struct OverfitLatencySample: Codable, Equatable, Sendable {
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let stallsPer128Tokens: Double
    let tokenCount: Int
}

enum OverfitLatencyClassifier {
    /// Percentile summary of inter-token intervals (first token excluded by
    /// the caller; TTFT is judged separately).
    static func summarize(interTokenLatenciesMs latencies: [Double],
                          thresholds: OverfitLatencyThresholds = .production) -> OverfitLatencySample? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> Double {
            let rank = p * Double(sorted.count - 1)
            let low = Int(rank.rounded(.down))
            let high = Int(rank.rounded(.up))
            guard low != high else { return sorted[low] }
            let fraction = rank - Double(low)
            return sorted[low] * (1 - fraction) + sorted[high] * fraction
        }
        let stalls = latencies.filter { $0 > thresholds.stallFloorMs }.count
        return OverfitLatencySample(
            p50Ms: percentile(0.50),
            p95Ms: percentile(0.95),
            p99Ms: percentile(0.99),
            stallsPer128Tokens: Double(stalls) * 128.0 / Double(latencies.count),
            tokenCount: latencies.count
        )
    }

    static func classify(_ sample: OverfitLatencySample,
                         thresholds: OverfitLatencyThresholds = .production) -> OverfitFitClassification {
        if sample.p50Ms <= thresholds.interactiveP50Ms,
           sample.p95Ms <= thresholds.interactiveP95Ms,
           Int(sample.stallsPer128Tokens.rounded(.up)) <= thresholds.interactiveStallsPer128 {
            return .pagedInteractive
        }
        if sample.p50Ms <= thresholds.slowP50Ms,
           sample.p95Ms <= thresholds.slowP95Ms,
           Int(sample.stallsPer128Tokens.rounded(.up)) <= thresholds.slowStallsPer128 {
            return .pagedSlow
        }
        return .offlineOnly
    }
}
