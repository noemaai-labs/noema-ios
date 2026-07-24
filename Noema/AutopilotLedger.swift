import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Autopilot bookkeeping: per-decision records (ring-capped) plus rolled-up
// counters powering the "94% on-device · ≈1.2 Wh saved" tally. All energy
// figures are order-of-magnitude ESTIMATES, never measurements — every UI
// surface that shows them must say so.

enum EnergyEstimator {
    /// Sustained package power during LLM inference, watts. Round-number
    /// estimates of typical device classes under GPU/ANE-bound load.
    static var devicePowerWatts: Double {
#if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? 10 : 7
#elseif os(visionOS)
        return 10
#else
        // Apple Silicon Macs: laptops throttle near 25W under Metal inference;
        // desktops have more headroom. Without a cheap laptop/desktop signal,
        // use the laptop figure — it under-claims savings, which is the safe bias.
        return 25
#endif
    }

    /// Frontier-class cloud chat query, Wh, including datacenter overhead (PUE),
    /// networking, and idle amortization. Public estimates span ~0.3–3+ Wh.
    static let cloudWhPerQuery: Double = 2.0

    /// One router decision (~900 tokens on a small model) plus the request path.
    static let routerWhPerDecision: Double = 0.05

    static func localWh(durationSeconds: Double) -> Double {
        max(0, durationSeconds) * devicePowerWatts / 3600
    }

    /// Accrues only on locally-answered Autopilot turns: what the cloud query
    /// would have cost minus what the device actually spent.
    static func whSaved(localDurationSeconds: Double) -> Double {
        max(0, cloudWhPerQuery - localWh(durationSeconds: localDurationSeconds))
    }
}

@MainActor
final class AutopilotLedger: ObservableObject {
    static let shared = AutopilotLedger()

    struct Record: Codable, Equatable {
        var date: Date
        var target: AutoRouteTarget
        var decidedBy: AutoRouteDecision.DecidedBy
        var category: String?
        var tokenCount: Int
        var durationSeconds: Double
        var estWhSaved: Double
        var estUSDSaved: Double?
        var corrected: Bool
    }

    struct Totals: Codable, Equatable {
        var localTurns: Int = 0
        var cloudTurns: Int = 0
        var overrides: Int = 0
        var whSaved: Double = 0
        var usdSaved: Double = 0
        var routerSpendUSD: Double = 0

        var totalTurns: Int { localTurns + cloudTurns }
        var onDeviceFraction: Double {
            totalTurns == 0 ? 0 : Double(localTurns) / Double(totalTurns)
        }
    }

    private struct Persisted: Codable {
        var totals: Totals
        var records: [Record]
    }

    @Published private(set) var totals = Totals()
    @Published private(set) var records: [Record] = []

    private static let maxRecords = 50
    private static let storageKey = "autopilot.ledger.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            totals = decoded.totals
            records = decoded.records
        }
    }

    func record(route: RouteDecisionRecord,
                tokenCount: Int,
                durationSeconds: Double,
                escalationPromptPricePerMillion: Double?,
                escalationCompletionPricePerMillion: Double?,
                promptTokenEstimate: Int?) {
        var whSaved = 0.0
        var usdSaved: Double?
        let answerTarget = route.answerTarget
        if answerTarget == .local {
            whSaved = EnergyEstimator.whSaved(localDurationSeconds: durationSeconds)
            whSaved = max(0, whSaved - EnergyEstimator.routerWhPerDecision)
            if let completionPrice = escalationCompletionPricePerMillion {
                var saved = Double(tokenCount) * completionPrice / 1_000_000
                if let promptTokens = promptTokenEstimate, let promptPrice = escalationPromptPricePerMillion {
                    saved += Double(promptTokens) * promptPrice / 1_000_000
                }
                usdSaved = saved
            }
            totals.localTurns += 1
            totals.whSaved += whSaved
            if let usdSaved { totals.usdSaved += usdSaved }
        } else {
            totals.cloudTurns += 1
        }

        records.append(Record(
            date: Date(),
            target: answerTarget,
            decidedBy: route.decidedBy,
            category: route.category,
            tokenCount: tokenCount,
            durationSeconds: durationSeconds,
            estWhSaved: whSaved,
            estUSDSaved: usdSaved,
            corrected: route.userOverride
        ))
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        persist()
    }

    func recordRouterSpend(promptTokens: Int?,
                           completionTokens: Int?,
                           promptPricePerMillion: Double?,
                           completionPricePerMillion: Double?) {
        guard let promptTokens, let completionTokens else { return }
        let promptCost = Double(promptTokens) * (promptPricePerMillion ?? 0) / 1_000_000
        let completionCost = Double(completionTokens) * (completionPricePerMillion ?? 0) / 1_000_000
        guard promptCost + completionCost > 0 else { return }
        totals.routerSpendUSD += promptCost + completionCost
        totals.usdSaved = max(0, totals.usdSaved - (promptCost + completionCost))
        persist()
    }

    func recordOverride() {
        totals.overrides += 1
        persist()
    }

    func reset() {
        totals = Totals()
        records = []
        persist()
    }

    private func persist() {
        let payload = Persisted(totals: totals, records: records)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
