import Foundation
import SwiftUI
import Combine

@MainActor
final class JSpaceLensController: ObservableObject {
    static let shared = JSpaceLensController()

    // MARK: User-facing knobs (drive the runtime config)

    @Published var enabled = false { didSet { pushConfig() } }
    @Published var mode: JSpaceLensMode = .logit { didSet { pushConfig() } }
    @Published var bandStart = 0 { didSet { clampBand(); pushConfig(); reaggregate() } }
    @Published var bandEnd = 0 { didSet { clampBand(); pushConfig(); reaggregate() } }
    @Published var topK = 12 { didSet { pushConfig() } }
    @Published var readoutStride = 1 { didSet { pushConfig() } }
    @Published var interventions: [JSpaceIntervention] = [] { didSet { pushConfig() } }

    // MARK: Reported / derived state

    @Published private(set) var modelInfo: JSpaceModelInfo = .unknown
    /// True once a supported model has been observed and the band has been seeded.
    @Published private(set) var bandSeeded = false

    // MARK: Jacobian lens

    @Published private(set) var lensStatus: JSpaceLensStatus = .none
    @Published private(set) var lensManifest: JSpaceLensManifest?
    private var jacobianLensPath: String?

    /// True when a loaded lens matches the current model's hidden size — the gate
    /// for the Jacobian/Diff modes.
    var canUseJacobian: Bool {
        guard let m = lensManifest, modelInfo.supported else { return false }
        return m.dModel == modelInfo.hiddenSize
    }

    // MARK: Live readout

    /// The readout list: each token with its within-band Count and a per-layer
    /// occurrence profile (the "Count by Layer" heatmap). Sorted by Count, desc.
    /// Re-derived from `layerCounts` on every band change — no regeneration needed.
    /// Only republished at the (throttled) reaggregate cadence, never per token.
    @Published private(set) var countedTokens: [CountedToken] = []
    /// Published at the reaggregate cadence (not per token) so the step readout
    /// doesn't re-render the panel on every generated token.
    @Published private(set) var lastStep = 0
    /// Whether the last generation actually installed hooks (for the status dot).
    /// Published only on transition, never on every frame.
    @Published private(set) var isReadingLive = false

    // MARK: Intervention feedback + counterfactual

    /// A transient confirmation shown when a steer/swap is armed (so `+`/`⇄` visibly
    /// do something even when the Interventions list is scrolled off-screen).
    @Published private(set) var confirmation: String?
    private var confirmationTask: Task<Void, Never>?

    /// The counterfactual comparison — populated by the chat view model when the user
    /// hits "Apply & re-run": it re-runs the last prompt with the interventions active
    /// and streams the steered answer here, next to the untouched original. It is its
    /// own `ObservableObject` so the per-token stream only re-renders the panel that
    /// observes it, not everything watching the controller.
    @Published private(set) var counterfactual: CounterfactualRun?
    /// Coarse mirror of `counterfactual?.isRunning` for views that observe the
    /// controller (the sidebar's Apply button) without observing the run itself.
    @Published private(set) var counterfactualRunning = false

    @MainActor
    final class CounterfactualRun: ObservableObject {
        let prompt: String            // the user message being re-run
        let original: String          // the original (unsteered) answer, verbatim
        let interventions: [String]   // human-readable summaries, e.g. "␣love → ␣hate"
        @Published var steered: String = ""   // the steered answer, streamed in
        @Published var isRunning: Bool = true
        @Published var error: String?

        init(prompt: String, original: String, interventions: [String]) {
            self.prompt = prompt
            self.original = original
            self.interventions = interventions
        }
    }

    /// A token as shown in the readout: `count` is within the current band; `perLayer`
    /// is dense over all layers (index == layer) for the heatmap; `peak` normalizes it.
    struct CountedToken: Identifiable, Equatable {
        let id: Int          // token id
        let text: String
        let count: Int       // occurrences within the selected band
        let perLayer: [Int]  // occurrences per layer, all layers
        let peak: Int        // max(perLayer), for row-local heatmap normalization
    }

    // MARK: Aggregation state

    /// `layerCounts[layer][tokenID]` = how many readout steps had this token in that
    /// layer's top-k. Band-independent, so band changes re-slice it instantly.
    private var layerCounts: [[Int: Int]] = []
    private var tokenTexts: [Int: String] = [:]
    private var tokenTotals: [Int: Int] = [:]   // across all layers; for pruning
    private var readoutLayerCount = 0
    /// The latest frame's step, tracked without publishing; surfaced to `lastStep`
    /// only when we reaggregate (so per-token step ticks don't re-render the panel).
    private var pendingStep = 0
    private let maxDisplayed = 48
    private let maxDistinctTokens = 4000
    private var reaggregatePending = false
    private var liveResetTimer: Task<Void, Never>?
    private var seededLayerCount = -1

    private init() {
        // Bridge the generation-thread sinks onto the MainActor.
        JSpaceLensRuntime.shared.setReadoutSink { [weak self] frame in
            Task { @MainActor in self?.ingest(frame) }
        }
        JSpaceLensRuntime.shared.setModelInfoSink { [weak self] info in
            Task { @MainActor in self?.ingestModelInfo(info) }
        }
        JSpaceLensRuntime.shared.setLensStatusSink { [weak self] status in
            Task { @MainActor in self?.lensStatus = status }
        }
        // Adopt any capability already probed before the panel opened.
        if let info = JSpaceLensRuntime.shared.lastModelInfo {
            ingestModelInfo(info)
        }
    }

    // MARK: Config plumbing

    private func pushConfig() {
        JSpaceLensRuntime.shared.config = JSpaceConfig(
            enabled: enabled && modelInfo.supported,
            mode: mode,
            bandStart: bandStart,
            bandEnd: bandEnd,
            topK: max(1, min(topK, 50)),
            readoutStride: max(1, readoutStride),
            interventions: interventions,
            jacobianLensPath: canUseJacobian ? jacobianLensPath : nil
        )
    }

    // MARK: Jacobian lens loading

    /// Point at a converted `.jlens` bundle directory (manifest.json +
    /// jacobians.safetensors). Validates the hidden size against the loaded model;
    /// the heavy matrix load happens lazily on the next Jacobian-mode generation.
    func loadJacobianLens(directoryURL: URL) {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(JSpaceLensManifest.self, from: data)
            if modelInfo.supported, manifest.dModel != modelInfo.hiddenSize {
                lensManifest = nil
                jacobianLensPath = nil
                lensStatus = .failed(reason: "Lens is for d=\(manifest.dModel); loaded model is d=\(modelInfo.hiddenSize)")
                pushConfig()
                return
            }
            lensManifest = manifest
            jacobianLensPath = directoryURL.path
            lensStatus = .loaded(base: manifest.baseModel, layers: manifest.sourceLayers.count)
            pushConfig()
        } catch {
            lensStatus = .failed(reason: "Couldn't read manifest.json: \(error.localizedDescription)")
        }
    }

    func clearJacobianLens() {
        lensManifest = nil
        jacobianLensPath = nil
        lensStatus = .none
        if mode != .logit { mode = .logit } else { pushConfig() }
    }

    private func clampBand() {
        // Only assign on actual change: bandStart/bandEnd have didSet observers that
        // call back into clampBand, so a no-op assignment would recurse forever.
        let maxLayer = max(0, modelInfo.layerCount - 1)
        let cs = min(max(0, bandStart), maxLayer)
        let ce = min(max(cs, bandEnd), maxLayer)
        if cs != bandStart { bandStart = cs }
        if ce != bandEnd { bandEnd = ce }
    }

    private func ingestModelInfo(_ info: JSpaceModelInfo) {
        modelInfo = info
        if info.supported, info.layerCount > 0, seededLayerCount != info.layerCount {
            // Seed to the mid-network "workspace" band (paper: ~⅓…⅔ depth).
            // Reseed whenever a differently sized model loads.
            bandStart = info.layerCount / 3
            bandEnd = min(info.layerCount - 1, (info.layerCount * 2) / 3)
            bandSeeded = true
            seededLayerCount = info.layerCount
        }
        clampBand()
        pushConfig()
    }

    // MARK: Readout ingestion

    private func ingest(_ frame: JSpaceReadoutFrame) {
        // Publish the live flag only on the false→true transition, not every token.
        if !isReadingLive { isReadingLive = true }
        // A new generation restarts the session's step counter, so a step lower than
        // the last one we saw means a fresh response — clear the tally so the readout
        // reflects the current answer, not the whole chat (matches Neuronpedia).
        if frame.step < pendingStep {
            layerCounts = []
            tokenTexts.removeAll()
            tokenTotals.removeAll()
            readoutLayerCount = 0
        }
        pendingStep = frame.step

        // Size the cache to the model's depth (frames now carry every layer).
        let lc = max(modelInfo.layerCount, (frame.layers.map(\.layer).max() ?? -1) + 1)
        if readoutLayerCount != lc {
            readoutLayerCount = lc
            layerCounts = Array(repeating: [:], count: lc)
        }
        // Count each (layer, token) top-k appearance — a stable cumulative tally,
        // not a decaying blend, so the list reads clean and is band-sliceable.
        for layer in frame.layers where layer.layer >= 0 && layer.layer < layerCounts.count {
            for tok in layer.tokens {
                layerCounts[layer.layer][tok.id, default: 0] += 1
                tokenTotals[tok.id, default: 0] += 1
                tokenTexts[tok.id] = tok.text
            }
        }
        pruneIfNeeded()
        scheduleReaggregate()

        // Drop the "live" flag shortly after the stream goes quiet.
        liveResetTimer?.cancel()
        liveResetTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { self?.isReadingLive = false }
        }
    }

    /// Rebuild `countedTokens` from the retained per-layer cache for the current band.
    /// Called immediately on band changes (instant re-slice) and, throttled, live.
    private func reaggregate() {
        // Surface the step here (throttled) rather than per token.
        if lastStep != pendingStep { lastStep = pendingStep }
        guard readoutLayerCount > 0, !layerCounts.isEmpty else {
            if !countedTokens.isEmpty { countedTokens = [] }
            return
        }
        let lo = min(bandStart, bandEnd)
        let hi = min(max(bandStart, bandEnd), layerCounts.count - 1)
        guard lo >= 0, lo <= hi else { countedTokens = []; return }

        // Sum each token's occurrences within the band.
        var bandTotal: [Int: Int] = [:]
        for l in lo...hi {
            for (id, c) in layerCounts[l] { bandTotal[id, default: 0] += c }
        }
        let top = bandTotal
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxDisplayed)

        countedTokens = top.compactMap { entry in
            guard let text = tokenTexts[entry.key] else { return nil }
            var perLayer = [Int](repeating: 0, count: readoutLayerCount)
            var peak = 0
            for l in 0..<readoutLayerCount {
                let c = layerCounts[l][entry.key] ?? 0
                perLayer[l] = c
                if c > peak { peak = c }
            }
            return CountedToken(id: entry.key, text: text, count: entry.value,
                                perLayer: perLayer, peak: peak)
        }
    }

    /// Coalesce reaggregation during live streaming so the MainActor isn't rebuilding
    /// the list on every generated token.
    private func scheduleReaggregate() {
        guard !reaggregatePending else { return }
        reaggregatePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            self.reaggregatePending = false
            self.reaggregate()
        }
    }

    /// Cap the number of distinct tokens tracked by dropping single-occurrence noise.
    private func pruneIfNeeded() {
        guard tokenTotals.count > maxDistinctTokens else { return }
        let doomed = tokenTotals.filter { $0.value <= 1 }.map(\.key)
        guard !doomed.isEmpty else { return }
        let doomedSet = Set(doomed)
        for l in layerCounts.indices {
            for id in doomedSet where layerCounts[l][id] != nil { layerCounts[l].removeValue(forKey: id) }
        }
        for id in doomedSet { tokenTotals.removeValue(forKey: id); tokenTexts.removeValue(forKey: id) }
    }

    func resetReadout() {
        layerCounts = []
        tokenTexts.removeAll()
        tokenTotals.removeAll()
        readoutLayerCount = 0
        countedTokens = []
        pendingStep = 0
        lastStep = 0
    }

    // MARK: Intervention helpers (called from the UI)

    func addSteer(tokenID: Int, text: String, strength: Double = 0.6) {
        interventions.append(
            JSpaceIntervention(kind: .steer, targetText: text, targetTokenID: tokenID,
                               sourceText: nil, sourceTokenID: nil, strength: strength)
        )
        flashConfirmation("Steering “\(cleanToken(text))” armed — Apply & re-run to see it.")
    }

    func addSwap(fromID: Int, fromText: String, toText: String, strength: Double = 0.8) {
        interventions.append(
            JSpaceIntervention(kind: .swap, targetText: toText, targetTokenID: nil,
                               sourceText: fromText, sourceTokenID: fromID, strength: strength)
        )
        flashConfirmation("Swap “\(cleanToken(fromText))”→“\(cleanToken(toText))” armed — Apply & re-run.")
    }

    func removeIntervention(_ id: UUID) {
        interventions.removeAll { $0.id == id }
    }

    func updateStrength(_ id: UUID, _ strength: Double) {
        guard let i = interventions.firstIndex(where: { $0.id == id }) else { return }
        interventions[i].strength = strength
    }

    func toggleIntervention(_ id: UUID) {
        guard let i = interventions.firstIndex(where: { $0.id == id }) else { return }
        interventions[i].enabled.toggle()
    }

    func clearInterventions() { interventions.removeAll() }

    /// One-line summaries of the enabled interventions, for the counterfactual panel.
    func interventionSummaries() -> [String] {
        interventions.filter(\.enabled).map { iv in
            switch iv.kind {
            case .steer: return "→ \(cleanToken(iv.targetText))"
            case .swap:  return "\(cleanToken(iv.sourceText ?? "?")) → \(cleanToken(iv.targetText))"
            }
        }
    }

    private func cleanToken(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: "\n", with: "⏎")
        return t.hasPrefix(" ") ? "␣" + t.dropFirst() : (t.isEmpty ? "∅" : t)
    }

    // MARK: Confirmation flash

    private func flashConfirmation(_ message: String) {
        confirmation = message
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { self?.confirmation = nil }
        }
    }

    // MARK: Counterfactual plumbing (driven by the chat view model)

    /// Steering only installs when the lens is enabled + has interventions, so arming
    /// a re-run forces the lens on.
    func armForCounterfactual() { if !enabled { enabled = true } }

    func beginCounterfactual(prompt: String, original: String, interventions: [String]) {
        counterfactual = CounterfactualRun(prompt: prompt, original: original, interventions: interventions)
        counterfactualRunning = true
    }
    func appendCounterfactual(_ token: String) { counterfactual?.steered.append(token) }
    /// Mark the current run done. No-op if the panel was already dismissed (e.g. the
    /// user closed it mid-run), so a cancel doesn't leave a stray banner.
    func finishCounterfactual(error: String? = nil) {
        counterfactualRunning = false
        guard let run = counterfactual else { return }
        run.isRunning = false
        run.error = error
    }
    func clearCounterfactual() { counterfactual = nil; counterfactualRunning = false }

    /// Surface a reason the re-run couldn't start (model not loaded, still streaming,
    /// no interventions) as the same transient banner used for steer/swap confirmation.
    func reportCounterfactualBlocked(_ message: String) { flashConfirmation(message) }
}
