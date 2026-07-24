import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXNN

// MARK: - Capture (read the residual stream)

/// Replaces a block's `input_layernorm`. Captures the residual (its input) and
/// forwards to the real norm. Weights are copied so the forward output is identical.
final class JSpaceCaptureRMSNorm: RMSNorm {
    let jsLayer: Int
    weak var session: JSpaceMLXSession?

    init(like original: RMSNorm, layer: Int, session: JSpaceMLXSession) {
        self.jsLayer = layer
        self.session = session
        super.init(dimensions: original.weight.shape[0], eps: original.eps)
        // Copy the trained weight in (the same mechanism used to load weights).
        update(parameters: ModuleParameters.unflattened([("weight", original.weight)]))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        session?.noteResidual(layer: jsLayer, x: x)
        return super.callAsFunction(x)
    }
}

// MARK: - Steer (write into the residual stream)

/// Wraps a block's `mlp.down_proj`. Delegates to the original (so quantized
/// matmuls stay correct) and adds the session's steering vector to the output,
/// which the skip connection folds into the residual.
final class JSpaceSteerLinear: Linear {
    let jsLayer: Int
    let inner: Linear
    weak var session: JSpaceMLXSession?

    init(wrapping inner: Linear, layer: Int, session: JSpaceMLXSession) {
        self.jsLayer = layer
        self.inner = inner
        self.session = session
        // Dummy super storage; the real compute goes through `inner`.
        super.init(weight: inner.weight, bias: inner.bias)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let out = inner(x)
        if let session, let add = session.steerAddition(layer: jsLayer, like: out) {
            return out + add
        }
        return out
    }
}

// MARK: - Session (per-generation state, gen-thread only)

final class JSpaceMLXSession {
    struct SteerDir { let dir: MLXArray; let strength: Float }

    // Resolved unembedding path.
    let normModule: RMSNorm
    let lmHead: Linear?
    let embModule: Embedding
    let vocabSize: Int
    /// Number of transformer blocks. Readable resid_post layers are 0..<layerCount.
    let layerCount: Int
    /// The capture index that triggers a readout (the final norm's synthetic index).
    let maxCaptureLayer: Int

    // Lens mode + optional loaded Jacobian lens (nil => logit lens).
    let mode: JSpaceLensMode
    let lens: JSpaceJacobianLens?

    // Steering directions per band layer (fixed for the generation).
    var steerDirsByLayer: [Int: [SteerDir]] = [:]

    // Token id -> display string, capturing the tokenizer decode closure.
    private let decodeToken: (Int) -> String
    private var decodeCache: [Int: String] = [:]

    // Per-step captured last-position residuals keyed by BLOCK index b; the value
    // is the input to block b, which equals resid_post[b-1] (the lens's source).
    private var captured: [Int: MLXArray] = [:]
    private var step = 0

    init(normModule: RMSNorm, lmHead: Linear?, embModule: Embedding,
         vocabSize: Int, layerCount: Int, maxCaptureLayer: Int, mode: JSpaceLensMode,
         lens: JSpaceJacobianLens?, decode: @escaping (Int) -> String) {
        self.normModule = normModule
        self.lmHead = lmHead
        self.embModule = embModule
        self.vocabSize = vocabSize
        self.layerCount = layerCount
        self.maxCaptureLayer = maxCaptureLayer
        self.mode = mode
        self.lens = lens
        self.decodeToken = decode
    }

    // Called from every CaptureRMSNorm during the forward pass.
    func noteResidual(layer: Int, x: MLXArray) {
        // Only read during single-token decode steps. Skipping the multi-token
        // prompt prefill avoids pinning every layer's full-prompt activation.
        guard x.ndim >= 2, x.shape[x.ndim - 2] == 1 else { return }
        // Last position across the sequence: [B, seq, d] -> [B, d].
        captured[layer] = x[0..., -1, 0...]
        if layer == maxCaptureLayer {
            finishStep()
        }
    }

    // Called from every band SteerLinear.
    func steerAddition(layer: Int, like out: MLXArray) -> MLXArray? {
        guard let dirs = steerDirsByLayer[layer], !dirs.isEmpty else { return nil }
        // Scale each direction by the local per-token residual magnitude so the
        // same strength behaves consistently across layers.
        let mag = sqrt((out * out).mean(axis: -1, keepDims: true))   // [B, seq, 1]
        var add: MLXArray?
        for sd in dirs {
            let term = sd.dir * (mag * sd.strength)                 // [d]·[B,seq,1] -> [B,seq,d]
            add = (add == nil) ? term : (add! + term)
        }
        return add
    }

    private func finishStep() {
        defer { captured.removeAll(keepingCapacity: true) }
        let cfg = JSpaceLensRuntime.shared.config
        step += 1
        guard cfg.enabled, vocabSize > 0, layerCount > 0 else { return }
        guard step % max(1, cfg.readoutStride) == 0 else { return }
        let k = max(1, min(cfg.topK, vocabSize))

        // Decode EVERY layer, not just the band: the band is applied later, in the
        // UI, so the panel can re-slice any layer range after generation without a
        // recompute (matching Neuronpedia). resid_post[l] == the input to block l+1
        // (and, for the final block, the input to the model's final norm).
        var layers: [Int] = []
        var hs: [MLXArray] = []
        layers.reserveCapacity(layerCount)
        hs.reserveCapacity(layerCount)
        for l in 0..<layerCount {
            guard let h = captured[l + 1] else { continue }
            layers.append(l)
            hs.append(h)
        }
        guard !layers.isEmpty else { return }

        // One batched [rows, vocab] projection instead of `rows` skinny matvecs.
        let logits: MLXArray
        if lens == nil || mode == .logit {
            logits = batchedLensLogits(concatenated(hs, axis: 0))
        } else {
            // Jacobian / Diff: transport each fitted layer's residual through J_l;
            // layers the lens didn't fit are dropped from this frame.
            var fitted: [Int] = []
            var transported: [MLXArray] = []
            var rawFitted: [MLXArray] = []
            for (i, l) in layers.enumerated() {
                guard let J = lens!.matrix(l) else { continue }
                fitted.append(l)
                transported.append(matmul(hs[i].asType(.float32), J.transposed()).asType(hs[i].dtype))
                rawFitted.append(hs[i])
            }
            guard !fitted.isEmpty else { return }
            layers = fitted
            let tLogits = batchedLensLogits(concatenated(transported, axis: 0))
            logits = (mode == .diff)
                ? tLogits - batchedLensLogits(concatenated(rawFitted, axis: 0))
                : tLogits
        }

        let layerReadouts = batchedTopK(logits, layers: layers, k: k)
        guard !layerReadouts.isEmpty else { return }
        JSpaceLensRuntime.shared.emitReadout(
            JSpaceReadoutFrame(step: step, emittedTokenID: nil, layers: layerReadouts)
        )
    }

    /// W_U · finalNorm(X) with optional Gemma logit softcap, batched over the leading
    /// axis. X is [rows, d]; returns [rows, vocab] fp32.
    private func batchedLensLogits(_ X: MLXArray) -> MLXArray {
        let normed = normModule(X)
        var logits = (lmHead?.callAsFunction(normed) ?? embModule.asLinear(normed)).asType(.float32)
        if let c = lens?.softcap {
            logits = tanh(logits / c) * c
        }
        return logits
    }

    /// Per-row top-k over a [rows, vocab] logit matrix, paired back to `layers`.
    /// Uses argPartition (O(vocab)) instead of a full argSort — the k winners are
    /// gathered, pulled to the CPU, and ordered there (k is tiny). Decoding all 64
    /// layers per step makes the saved sort cost meaningful.
    private func batchedTopK(_ logits: MLXArray, layers: [Int], k: Int) -> [JSpaceLayerReadout] {
        let rows = layers.count
        guard rows > 0 else { return [] }
        let kth = max(0, vocabSize - k)
        let topIdx = argPartition(logits, kth: kth, axis: -1)[0..., kth...]  // [rows, k], unordered
        let topVals = takeAlong(logits, topIdx, axis: -1)                    // [rows, k]
        let idsArr = topIdx.asArray(Int32.self)                             // row-major [rows*k]
        let valsArr = topVals.asArray(Float.self)
        let cols = idsArr.count / rows
        guard cols > 0, idsArr.count == rows * cols, valsArr.count == rows * cols else { return [] }

        var out: [JSpaceLayerReadout] = []
        out.reserveCapacity(rows)
        for r in 0..<rows {
            var pairs: [(id: Int, value: Float)] = []
            pairs.reserveCapacity(cols)
            for j in 0..<cols {
                let idx = r * cols + j
                pairs.append((Int(idsArr[idx]), valsArr[idx]))
            }
            pairs.sort { $0.value > $1.value }   // rank 1 first
            let tokens = pairs.map {
                JSpaceReadoutToken(id: $0.id, text: decodeCached($0.id), value: $0.value)
            }
            out.append(JSpaceLayerReadout(layer: layers[r], tokens: tokens))
        }
        return out
    }

    private func decodeCached(_ id: Int) -> String {
        if let s = decodeCache[id] { return s }
        let s = decodeToken(id)
        decodeCache[id] = s
        return s
    }
}

// MARK: - Structure resolution + install

enum JSpaceMLXHooks {

    /// Resolved module tree of the loaded model.
    struct Structure {
        var embed: Embedding
        var finalNorm: RMSNorm
        var finalNormKey: String
        var lmHead: Linear?
        var inputNorms: [(layer: Int, module: RMSNorm, key: String)]
        var downProjs: [(layer: Int, module: Linear, key: String)]
        var hiddenSize: Int
        var vocabSize: Int
        var family: String
        var layerCount: Int
    }

    /// A live installation; call `remove()` to restore the original modules.
    final class Installed {
        let model: Module
        let session: JSpaceMLXSession
        private let restore: [(String, Module)]
        private var removed = false

        init(model: Module, session: JSpaceMLXSession, restore: [(String, Module)]) {
            self.model = model
            self.session = session
            self.restore = restore
        }

        func remove() {
            guard !removed else { return }
            removed = true
            model.update(modules: NestedDictionary<String, Module>.unflattened(restore))
        }
    }

    /// Walk the module tree and identify the residual/unembedding structure.
    static func resolveStructure(_ model: Module) -> Structure? {
        var embed: Embedding?
        var finalNorm: RMSNorm?
        var finalNormKey: String?
        var lmHead: Linear?
        var inputNorms: [(Int, RMSNorm, String)] = []
        var downProjs: [(Int, Linear, String)] = []

        for (key, module) in model.namedModules() {
            if key.hasSuffix("embed_tokens"), let e = module as? Embedding {
                embed = e
            } else if key == "lm_head" || key.hasSuffix(".lm_head"), let l = module as? Linear {
                lmHead = l
            } else if let idx = layerIndex(in: key, suffix: "input_layernorm"),
                      let n = module as? RMSNorm {
                inputNorms.append((idx, n, key))
            } else if let idx = layerIndex(in: key, suffix: "mlp.down_proj"),
                      let l = module as? Linear {
                downProjs.append((idx, l, key))
            } else if (key == "model.norm" || key.hasSuffix(".model.norm")
                       || key == "norm" || key.hasSuffix(".model.language_model.norm")),
                      let n = module as? RMSNorm {
                finalNorm = n
                finalNormKey = key
            }
        }

        // The viewer (residual readout) only needs the residual captures + the
        // unembedding path. down_proj is required solely for steering, which some
        // architectures (MoE / linear-attention layers) don't expose per-layer —
        // those still support viewing.
        guard let embed, let finalNorm, let finalNormKey, !inputNorms.isEmpty else {
            return nil
        }

        inputNorms.sort { $0.0 < $1.0 }
        downProjs.sort { $0.0 < $1.0 }

        let hidden = finalNorm.weight.shape.first ?? 0
        let vocab = lmHead?.weight.shape.first ?? embed.weight.shape.first ?? 0
        let family = String(describing: type(of: model))
            .replacingOccurrences(of: "Model", with: "")
        let layerCount = (inputNorms.last?.0 ?? -1) + 1

        return Structure(
            embed: embed, finalNorm: finalNorm, finalNormKey: finalNormKey, lmHead: lmHead,
            inputNorms: inputNorms.map { ($0.0, $0.1, $0.2) },
            downProjs: downProjs.map { ($0.0, $0.1, $0.2) },
            hiddenSize: hidden, vocabSize: vocab, family: family, layerCount: layerCount
        )
    }

    /// Parse "…layers.<N>.<suffix>" and return N.
    private static func layerIndex(in key: String, suffix: String) -> Int? {
        guard key.hasSuffix(suffix) else { return nil }
        guard let range = key.range(of: "layers.") else { return nil }
        let after = key[range.upperBound...]
        let digits = after.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Report capability to the UI without installing hooks (called at model load).
    static func reportModelInfo(for model: Module) {
        if let s = resolveStructure(model) {
            JSpaceLensRuntime.shared.reportModelInfo(
                JSpaceModelInfo(supported: true, reason: nil,
                                layerCount: s.layerCount, hiddenSize: s.hiddenSize,
                                family: s.family, steerableLayers: s.downProjs.count)
            )
        } else {
            let family = String(describing: type(of: model)).replacingOccurrences(of: "Model", with: "")
            JSpaceLensRuntime.shared.reportModelInfo(
                JSpaceModelInfo(supported: false,
                                reason: "\(family): residual/MLP hooks not found (needs a dense Llama/Qwen-family text model)",
                                layerCount: 0, hiddenSize: 0, family: family)
            )
        }
    }

    /// Install hooks if the lens is enabled and the model is compatible. Returns
    /// nil (no-op) otherwise. `encode`/`decode` bridge the loaded tokenizer.
    static func installIfActive(
        on model: Module,
        encode: (String) -> [Int],
        decode: @escaping (Int) -> String
    ) -> Installed? {
        let cfg = JSpaceLensRuntime.shared.config
        guard cfg.enabled else { return nil }
        guard let s = resolveStructure(model) else {
            reportModelInfo(for: model)
            return nil
        }
        reportModelInfo(for: model)

        // The final block's resid_post feeds the model's final norm, not any block's
        // input_layernorm, so we wrap the final norm too (synthetic index = layerCount)
        // to make the deepest layer readable — Neuronpedia shows the last layer.
        let finalCaptureLayer = s.layerCount
        // Load the fitted Jacobian lens when the mode calls for it (cached).
        let lens: JSpaceJacobianLens? = (cfg.mode == .logit)
            ? nil
            : JSpaceJacobianLensStore.shared.lens(atPath: cfg.jacobianLensPath)
        let session = JSpaceMLXSession(
            normModule: s.finalNorm, lmHead: s.lmHead, embModule: s.embed,
            vocabSize: s.vocabSize, layerCount: s.layerCount,
            maxCaptureLayer: finalCaptureLayer, mode: cfg.mode,
            lens: lens, decode: decode
        )

        let lo = max(0, min(cfg.bandStart, cfg.bandEnd))
        let hi = max(cfg.bandStart, cfg.bandEnd)

        // Build the swaps and remember originals for restore.
        var swaps: [(String, Module)] = []
        var restore: [(String, Module)] = []

        for entry in s.inputNorms {
            swaps.append((entry.key, JSpaceCaptureRMSNorm(like: entry.module, layer: entry.layer, session: session)))
            restore.append((entry.key, entry.module))
        }
        // Capture resid_post of the last block (the final norm's input). The wrapper
        // copies the norm's weight and forwards untouched, so the forward is identical;
        // session.normModule keeps the original module for the (separate) readout math.
        swaps.append((s.finalNormKey, JSpaceCaptureRMSNorm(like: s.finalNorm, layer: finalCaptureLayer, session: session)))
        restore.append((s.finalNormKey, s.finalNorm))

        if cfg.hasActiveInterventions {
            session.steerDirsByLayer = buildSteerDirsByLayer(
                cfg: cfg, embed: s.embed, encode: encode, lens: lens, bandLo: lo, bandHi: hi
            )
            for entry in s.downProjs where entry.layer >= lo && entry.layer <= hi {
                swaps.append((entry.key, JSpaceSteerLinear(wrapping: entry.module, layer: entry.layer, session: session)))
                restore.append((entry.key, entry.module))
            }
        }

        model.update(modules: NestedDictionary<String, Module>.unflattened(swaps))
        return Installed(model: model, session: session, restore: restore)
    }

    /// Per-band-layer steering directions. With a lens, the direction for token t at
    /// layer l is J_l.T · e(t) (pull the token's readout direction back through J_l);
    /// without a lens it's the raw embedding direction, shared across the band.
    private static func buildSteerDirsByLayer(
        cfg: JSpaceConfig, embed: Embedding, encode: (String) -> [Int],
        lens: JSpaceJacobianLens?, bandLo: Int, bandHi: Int
    ) -> [Int: [JSpaceMLXSession.SteerDir]] {
        func embVec(text: String, id: Int?) -> MLXArray? {
            guard let tokenID = id ?? encode(text).first else { return nil }
            return embed(MLXArray([tokenID]))[0]                // [d], model dtype
        }
        func conceptVec(_ iv: JSpaceIntervention) -> MLXArray? {
            switch iv.kind {
            case .steer:
                return embVec(text: iv.targetText, id: iv.targetTokenID)
            case .swap:
                guard let to = embVec(text: iv.targetText, id: iv.targetTokenID) else { return nil }
                guard let from = embVec(text: iv.sourceText ?? "", id: iv.sourceTokenID) else { return to }
                return to - from
            }
        }

        let concepts = cfg.activeInterventions.compactMap { iv -> (MLXArray, Float)? in
            guard let c = conceptVec(iv) else { return nil }
            return (c, Float(iv.strength))
        }
        guard !concepts.isEmpty, bandHi >= bandLo else { return [:] }

        var byLayer: [Int: [JSpaceMLXSession.SteerDir]] = [:]
        for layer in bandLo...bandHi {
            var dirs: [JSpaceMLXSession.SteerDir] = []
            for (concept, strength) in concepts {
                let raw: MLXArray
                if let J = lens?.matrix(layer) {
                    raw = matmul(J.transposed(), concept.asType(.float32))
                } else {
                    raw = concept
                }
                dirs.append(.init(dir: unit(raw).asType(concept.dtype), strength: strength))
            }
            byLayer[layer] = dirs
        }
        return byLayer
    }

    private static func unit(_ v: MLXArray) -> MLXArray {
        let n = sqrt(sum(v * v)) + 1e-6
        return v / n
    }
}
#endif
