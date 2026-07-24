#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct JSpaceLensSidebar: View {
    @ObservedObject private var controller = JSpaceLensController.shared
    let hide: () -> Void
    /// Re-runs the last prompt with the active interventions and opens the
    /// counterfactual panel. Supplied by the chat view.
    var runCounterfactual: () -> Void = {}

    @State private var swapSource: JSpaceLensController.CountedToken?
    @State private var swapTargetText: String = ""
    @State private var showLensImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            IndustrialHairline()
            if let confirmation = controller.confirmation {
                confirmationBanner(confirmation)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !controller.interventions.isEmpty { interventionsActionBar }
                    modelSection
                    controlsSection
                    lensSection
                    if controller.enabled { readoutSection }
                    interventionsSection
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
        .frame(minWidth: 300, idealWidth: 344, maxWidth: 380, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Color.primary.opacity(0.08).frame(width: 1).ignoresSafeArea()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isReadingLive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text("J-Space Lens")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            IndustrialIconButton(systemImage: "sidebar.trailing", help: "Close") { hide() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Confirmation + interventions action bar

    /// Transient banner so tapping ＋ / ⇄ visibly registers even when the detailed
    /// Interventions list is scrolled out of view.
    private func confirmationBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.10))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: controller.confirmation)
    }

    /// Prominent bar at the top of the scroll: how many interventions are armed +
    /// the Apply & re-run action that opens the counterfactual panel.
    private var interventionsActionBar: some View {
        let count = controller.interventions.filter(\.enabled).count
        let cfRunning = controller.counterfactualRunning
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IndustrialBadge(verbatim: count == 1 ? "1 ACTIVE" : "\(count) ACTIVE",
                                tint: .blue, dot: true)
                Text(verbatim: "intervention\(count == 1 ? "" : "s") armed")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button {
                    runCounterfactual()
                } label: {
                    HStack(spacing: 5) {
                        if cfRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.circle.fill").font(.system(size: 12))
                        }
                        Text(cfRunning ? "Running…" : "Apply & re-run")
                    }
                }
                .buttonStyle(.industrial(.prominent))
                .disabled(count == 0 || cfRunning)
                Button("Clear") { controller.clearInterventions() }
                    .buttonStyle(.industrial(.quiet))
                Spacer(minLength: 0)
            }
            Text("Re-runs your last prompt with these edits to the residual stream and shows the original vs. steered answer side by side — your chat stays as-is.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.blue.opacity(0.18), lineWidth: 1))
        )
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            IndustrialSectionHeader("Model", dotColor: controller.modelInfo.supported ? .green : .orange) {
                IndustrialBadge(
                    verbatim: controller.modelInfo.supported ? "SUPPORTED" : "UNSUPPORTED",
                    tint: controller.modelInfo.supported ? .green : .orange,
                    dot: false
                )
            }
            if controller.modelInfo.supported {
                HStack(spacing: 14) {
                    IndustrialStatPair(label: "Family", value: controller.modelInfo.family)
                    IndustrialStatPair(label: "Layers", value: "\(controller.modelInfo.layerCount)")
                    IndustrialStatPair(label: "d", value: "\(controller.modelInfo.hiddenSize)")
                }
                if controller.modelInfo.canSteer {
                    IndustrialStatPair(label: "Steerable",
                                       value: "\(controller.modelInfo.steerableLayers)/\(controller.modelInfo.layerCount) layers")
                } else {
                    Text("View-only architecture (MoE / linear-attention): the layer-by-layer readout works, but there's no per-layer MLP to steer.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(verbatim: controller.modelInfo.reason
                     ?? "Load an MLX model. The lens needs a standard residual stream + unembedding (Llama/Qwen-family text or VLM).")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            IndustrialSectionHeader("Lens")
            Toggle(isOn: $controller.enabled) {
                Text("Read the residual stream")
                    .font(.system(size: 13))
            }
            .toggleStyle(IndustrialToggleStyle())
            .disabled(!controller.modelInfo.supported)

            if controller.modelInfo.supported && !controller.enabled {
                Text("Turn this on, then send a message. The readout below fills as the model generates — each row is a token the workspace is “thinking”. Tap ＋ to steer toward one, ⇄ to swap it for another.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modePicker

            if controller.modelInfo.supported {
                IndustrialSliderRow(
                    label: "Band start", value: bandStartBinding,
                    range: 0...Double(max(1, controller.modelInfo.layerCount - 1)), step: 1,
                    display: "L\(controller.bandStart)"
                )
                IndustrialSliderRow(
                    label: "Band end", value: bandEndBinding,
                    range: 0...Double(max(1, controller.modelInfo.layerCount - 1)), step: 1,
                    display: "L\(controller.bandEnd)"
                )
                IndustrialStepperRow(label: "Top-k", display: "\(controller.topK)",
                                     value: $controller.topK, range: 4...30)
                IndustrialStepperRow(label: "Every N tokens", display: "\(controller.readoutStride)",
                                     value: $controller.readoutStride, range: 1...8)
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(JSpaceLensMode.allCases, id: \.self) { m in
                let locked = (m != .logit) && !controller.canUseJacobian
                Button(m.title) { if !locked { controller.mode = m } }
                    .buttonStyle(.industrial(controller.mode == m ? .prominent : .quiet))
                    .disabled(locked)
                    .help(locked ? "Load a matching Jacobian lens to enable" : "")
            }
            Spacer()
        }
    }

    // MARK: Jacobian lens

    @ViewBuilder
    private var lensSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            IndustrialSectionHeader("Jacobian Lens", dotColor: controller.canUseJacobian ? .green : nil) {
                if controller.lensManifest != nil {
                    Button("Clear") { controller.clearJacobianLens() }
                        .buttonStyle(.industrial(.quiet))
                }
            }
            switch controller.lensStatus {
            case .loaded(let base, let layers):
                IndustrialStatPair(label: "Base", value: base)
                IndustrialStatPair(label: "Layers", value: "\(layers)")
                if !controller.canUseJacobian {
                    Text("Dimension mismatch with the loaded model — Jacobian mode stays off.")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let reason):
                Text(verbatim: reason)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                Text("Logit lens only. Load a converted lens bundle to unlock true Jacobian + Diff.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Load lens bundle…") { showLensImporter = true }
                .buttonStyle(.industrial(.tinted))
        }
        .fileImporter(isPresented: $showLensImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                // Keep the security scope for the session: the multi-GB matrix load
                // happens later on the generation thread (process-wide access).
                _ = url.startAccessingSecurityScopedResource()
                controller.loadJacobianLens(directoryURL: url)
            }
        }
    }

    // MARK: Readout

    private var bandLo: Int { min(controller.bandStart, controller.bandEnd) }
    private var bandHi: Int { max(controller.bandStart, controller.bandEnd) }

    private var readoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            IndustrialSectionHeader("J-Lens Readout",
                                    detail: bandDetail,
                                    dotColor: controller.isReadingLive ? .green : Color.secondary.opacity(0.35)) {
                HStack(spacing: 8) {
                    if controller.lastStep > 0 {
                        // Fixed-width, monospaced-digit slot so the step counter ticking
                        // during generation never reflows the header or the Reset button.
                        Text(verbatim: "step \(controller.lastStep)")
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .lineLimit(1)
                            .frame(width: 70, alignment: .trailing)
                    }
                    Button("Reset") { controller.resetReadout() }
                        .buttonStyle(.industrial(.quiet))
                }
            }
            if let source = swapSource { swapEditor(source) }
            if controller.countedTokens.isEmpty {
                Text(verbatim: controller.isReadingLive ? "Reading…" : "Send a message to read the workspace.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                bandRuler
                ForEach(controller.countedTokens) { tok in
                    CountedRow(
                        tok: tok, bandLo: bandLo, bandHi: bandHi,
                        canSteer: controller.modelInfo.canSteer, display: display,
                        onSteer: { controller.addSteer(tokenID: tok.id, text: tok.text) },
                        onSwap: { swapSource = tok; swapTargetText = "" }
                    )
                }
                Text("Count = how often each token tops the layer's residual within the band. The strip is its depth profile across all \(controller.modelInfo.layerCount) layers; the band is highlighted. ␣ marks a leading space (a word-start token).")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// Only the layer band — the step lives in a fixed-width trailing slot so it can
    /// tick without shifting the header (the band changes only when you drag it).
    private var bandDetail: String? {
        controller.modelInfo.layerCount > 0 ? "L\(bandLo)–L\(bandHi)" : nil
    }

    /// A thin non-interactive layer axis showing where the band sits across depth,
    /// aligned to the heatmap column (empty leading cells match the token + count
    /// columns) so it reads as the strips' header. L0 / L(max) sit at the track ends.
    private var bandRuler: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CountedRow.tokenWidth, height: 1)
            Color.clear.frame(width: CountedRow.countWidth, height: 1)
            LayerBandTrack(layerCount: max(controller.modelInfo.layerCount, 1),
                           bandLo: bandLo, bandHi: bandHi)
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    Text(verbatim: "L0")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .offset(y: -9)
                }
                .overlay(alignment: .trailing) {
                    Text(verbatim: "L\(max(controller.modelInfo.layerCount - 1, 0))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .offset(y: -9)
                }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func swapEditor(_ source: JSpaceLensController.CountedToken) -> some View {
        let sourceHasSpace = source.text.hasPrefix(" ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: display(source.text))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField(sourceHasSpace ? "␣token" : "token", text: $swapTargetText)
                    .industrialField(width: 110)
                    .onSubmit { commitSwap(source) }
                Spacer()
                Button("Swap") { commitSwap(source) }
                    .buttonStyle(.industrial(.prominent))
                    .disabled(swapTargetText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("×") { swapSource = nil }
                    .buttonStyle(.industrial(.quiet))
            }
            if sourceHasSpace {
                Text("This token starts with a space (␣) — start your replacement with a space too so it lands on the same word boundary. (Noema adds one if you forget.)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func commitSwap(_ source: JSpaceLensController.CountedToken) {
        let target = swapTargetText.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        // Preserve the leading space of the source token so the replacement lives
        // in the same word-boundary regime.
        let normalized = source.text.hasPrefix(" ") && !target.hasPrefix(" ") ? " " + target : target
        controller.addSwap(fromID: source.id, fromText: source.text, toText: normalized)
        swapSource = nil
        swapTargetText = ""
    }

    // MARK: Interventions

    private var interventionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            IndustrialSectionHeader("Interventions",
                                    detail: controller.interventions.isEmpty ? nil : "\(controller.interventions.count)") {
                if !controller.interventions.isEmpty {
                    Button("Clear") { controller.clearInterventions() }
                        .buttonStyle(.industrial(.destructive))
                }
            }
            if controller.interventions.isEmpty {
                Text("Steer or swap a token above to edit the model's latent workspace. Applies on the next message across the layer band.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(controller.interventions) { iv in
                    interventionRow(iv)
                }
            }
        }
    }

    private func interventionRow(_ iv: JSpaceIntervention) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IndustrialBadge(verbatim: iv.kind == .steer ? "STEER" : "SWAP",
                                tint: iv.kind == .steer ? .blue : .purple)
                Text(verbatim: interventionLabel(iv))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(
                    get: { iv.enabled },
                    set: { _ in controller.toggleIntervention(iv.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                IndustrialIconButton(systemImage: "trash", tint: .red) {
                    controller.removeIntervention(iv.id)
                }
            }
            IndustrialSliderRow(
                label: nil,
                value: Binding(
                    get: { iv.strength },
                    set: { controller.updateStrength(iv.id, $0) }
                ),
                range: -1.0...1.0,
                display: String(format: "%+.2f", iv.strength)
            )
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func interventionLabel(_ iv: JSpaceIntervention) -> String {
        switch iv.kind {
        case .steer: return "→ \(display(iv.targetText))"
        case .swap: return "\(display(iv.sourceText ?? "?")) → \(display(iv.targetText))"
        }
    }

    // MARK: Footnote

    private var footnote: some View {
        Text("Logit lens: each layer's residual decoded through the model's own unembedding — the tokens it is disposed to say. Runs fully on-device.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    /// Make whitespace visible in token strings. A leading space becomes `␣` (the
    /// standard "space" glyph, not a bullet) so `␣the` reads as "space + the" — i.e.
    /// a word-start token — and a lone space token reads as `␣`.
    private func display(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix(" ") { s = "␣" + s.dropFirst() }
        s = s.replacingOccurrences(of: "\n", with: "⏎")
        return s.isEmpty ? "∅" : s
    }

    private var bandStartBinding: Binding<Double> {
        Binding(get: { Double(controller.bandStart) }, set: { controller.bandStart = Int($0.rounded()) })
    }
    private var bandEndBinding: Binding<Double> {
        Binding(get: { Double(controller.bandEnd) }, set: { controller.bandEnd = Int($0.rounded()) })
    }
}

// MARK: - Count-by-layer readout row

/// One token row: `token | count | per-layer heatmap`. The heatmap draws every
/// layer as a cell whose intensity is that layer's occurrence count (row-normalized),
/// with the selected band tinted in the accent color and the rest muted — so the same
/// strip shows both the token's full depth profile and which slice the count reflects.
/// Steer/swap are revealed on hover so they don't compete with the data.
private struct CountedRow: View {
    static let tokenWidth: CGFloat = 92
    static let countWidth: CGFloat = 26

    let tok: JSpaceLensController.CountedToken
    let bandLo: Int
    let bandHi: Int
    let canSteer: Bool
    let display: (String) -> String
    let onSteer: () -> Void
    let onSwap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: display(tok.text))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.tokenWidth, alignment: .leading)
            Text(verbatim: "\(tok.count)")
                .industrialStat()
                .frame(width: Self.countWidth, alignment: .trailing)
            ZStack(alignment: .trailing) {
                LayerHeatmap(perLayer: tok.perLayer, peak: tok.peak, bandLo: bandLo, bandHi: bandHi)
                    .frame(maxWidth: .infinity)
                    .frame(height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                if hovering && canSteer {
                    HStack(spacing: 1) {
                        IndustrialIconButton(systemImage: "plus.circle", help: "Steer toward this token") { onSteer() }
                        IndustrialIconButton(systemImage: "arrow.left.arrow.right", help: "Swap this token for another") { onSwap() }
                    }
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hovering = $0 }
    }
}

/// The per-token "Count by Layer" strip. One vertical cell per layer; in-band cells
/// use the accent color, out-of-band cells a neutral gray, each scaled by the token's
/// occurrence count at that layer (normalized to its own peak).
private struct LayerHeatmap: View {
    let perLayer: [Int]
    let peak: Int
    let bandLo: Int
    let bandHi: Int

    var body: some View {
        Canvas { ctx, size in
            let n = perLayer.count
            guard n > 0, size.width > 0 else { return }
            let cellW = size.width / CGFloat(n)
            for i in 0..<n {
                let norm = peak > 0 ? Double(perLayer[i]) / Double(peak) : 0
                let inBand = i >= bandLo && i <= bandHi
                let rect = CGRect(x: CGFloat(i) * cellW, y: 0,
                                  width: max(cellW - 0.5, 0.5), height: size.height)
                let intensity = norm <= 0 ? 0.06 : (0.18 + 0.82 * norm)
                let color = inBand
                    ? Color.accentColor.opacity(intensity)
                    : Color.primary.opacity(intensity * 0.4)
                ctx.fill(Path(rect), with: .color(color))
            }
        }
        .background(Color.primary.opacity(0.04))
    }
}

/// The band ruler above the strips: a full-width track with the selected layer band
/// marked, so the highlighted columns in each heatmap read as "this range".
private struct LayerBandTrack: View {
    let layerCount: Int
    let bandLo: Int
    let bandHi: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let per = layerCount > 0 ? w / CGFloat(layerCount) : 0
            let x = CGFloat(max(0, bandLo)) * per
            let bandW = CGFloat(max(1, bandHi - bandLo + 1)) * per
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Color.accentColor.opacity(0.85))
                    .frame(width: max(bandW, 3))
                    .offset(x: min(x, max(0, w - max(bandW, 3))))
            }
        }
    }
}
#endif
