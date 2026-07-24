import Foundation

// MARK: - Lens mode

enum JSpaceLensMode: String, Codable, CaseIterable, Sendable {
    case logit
    case jacobian
    case diff

    var title: String {
        switch self {
        case .logit: return "Logit"
        case .jacobian: return "Jacobian"
        case .diff: return "Diff"
        }
    }
}

// MARK: - Interventions

enum JSpaceInterventionKind: String, Codable, Sendable {
    case steer   // h += α · dir(target)
    case swap    // h += α · (dir(target) − dir(source))
}

/// A single intervention on the residual stream, applied across the layer band.
/// Token identities are carried as both a display string and (when known) a token
/// id; the MLX side resolves anything missing against the loaded tokenizer.
struct JSpaceIntervention: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = UUID()
    var kind: JSpaceInterventionKind
    /// The concept being promoted (steer target / swap "to").
    var targetText: String
    var targetTokenID: Int?
    /// The concept being suppressed (swap "from"); nil for pure steer.
    var sourceText: String?
    var sourceTokenID: Int?
    /// Signed strength as a fraction of the local residual magnitude (−1…1 typical).
    var strength: Double
    var enabled: Bool = true
}

// MARK: - Jacobian lens manifest (accompanies a converted .jlens bundle)

/// Written by scripts/jspace_convert_lens.py alongside `jacobians.safetensors`.
/// The safetensors holds one `[d,d]` fp16 matrix per key `layer_<N>`.
struct JSpaceLensManifest: Codable, Sendable, Equatable {
    var baseModel: String
    var dModel: Int
    var nLayers: Int
    var sourceLayers: [Int]
    var tieWordEmbeddings: Bool
    var finalLogitSoftcapping: Double?
}

// MARK: - Runtime config snapshot (Sendable, read on the generation thread)

struct JSpaceConfig: Sendable, Equatable {
    var enabled: Bool
    var mode: JSpaceLensMode
    /// Inclusive layer band [start, end] the readout aggregates over and
    /// interventions are applied to.
    var bandStart: Int
    var bandEnd: Int
    var topK: Int
    /// Compute a readout every `readoutStride` generated tokens (>=1). Higher =
    /// cheaper, less live.
    var readoutStride: Int
    var interventions: [JSpaceIntervention]
    /// Directory of a loaded, dimension-matched Jacobian lens bundle, or nil for
    /// the logit lens. Only consulted when `mode` is `.jacobian`/`.diff`.
    var jacobianLensPath: String?

    static let disabled = JSpaceConfig(
        enabled: false, mode: .logit, bandStart: 0, bandEnd: 0,
        topK: 12, readoutStride: 1, interventions: [], jacobianLensPath: nil
    )

    var activeInterventions: [JSpaceIntervention] { interventions.filter { $0.enabled } }
    var hasActiveInterventions: Bool { !activeInterventions.isEmpty }
}

// MARK: - Readout payloads (emitted from the generation thread)

struct JSpaceReadoutToken: Sendable, Hashable {
    let id: Int
    let text: String
    /// Lens logit for this token at this cell (higher = more promoted).
    let value: Float
}

struct JSpaceLayerReadout: Sendable {
    let layer: Int
    let tokens: [JSpaceReadoutToken]   // top-k, descending
}

/// One computed step: per-band-layer top-k readouts, plus the token the model
/// actually emitted at this step (for context in the UI).
struct JSpaceReadoutFrame: Sendable {
    let step: Int
    let emittedTokenID: Int?
    let layers: [JSpaceLayerReadout]
}

// MARK: - Model capability info (reported back from the MLX side)

/// Status of a Jacobian-lens bundle load (reported from the generation thread).
enum JSpaceLensStatus: Sendable, Equatable {
    case none
    case loaded(base: String, layers: Int)
    case failed(reason: String)
}

struct JSpaceModelInfo: Sendable, Equatable {
    /// True when the loaded model exposes the residual/unembedding hooks the viewer
    /// needs (residual capture + final norm + unembedding).
    var supported: Bool
    var reason: String?
    var layerCount: Int
    var hiddenSize: Int
    var family: String
    /// Number of layers that expose `mlp.down_proj` (i.e. can be steered). Fewer
    /// than `layerCount` on MoE / linear-attention architectures; 0 = view-only.
    var steerableLayers: Int = 0

    var canSteer: Bool { steerableLayers > 0 }

    static let unknown = JSpaceModelInfo(
        supported: false, reason: "No compatible model loaded",
        layerCount: 0, hiddenSize: 0, family: "—", steerableLayers: 0
    )
}

// MARK: - Runtime bridge

/// Thread-safe hand-off between the MainActor UI controller and the MLX generation
/// thread. The controller writes the config; the MLX hooks read the config and push
/// readout frames + model info back. No MLX types cross this boundary — only the
/// Sendable value types above.
final class JSpaceLensRuntime: @unchecked Sendable {
    static let shared = JSpaceLensRuntime()
    private init() {}

    private let lock = NSLock()
    private var _config = JSpaceConfig.disabled
    private var _onReadout: (@Sendable (JSpaceReadoutFrame) -> Void)?
    private var _onModelInfo: (@Sendable (JSpaceModelInfo) -> Void)?
    private var _onLensStatus: (@Sendable (JSpaceLensStatus) -> Void)?
    private var _lastModelInfo: JSpaceModelInfo?

    // Written by the controller, read on the generation thread.
    var config: JSpaceConfig {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }

    /// True when a generation should install hooks at all.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _config.enabled
    }

    // Sinks are installed by the controller and invoked from the generation thread.
    func setReadoutSink(_ sink: (@Sendable (JSpaceReadoutFrame) -> Void)?) {
        lock.lock(); _onReadout = sink; lock.unlock()
    }
    func setModelInfoSink(_ sink: (@Sendable (JSpaceModelInfo) -> Void)?) {
        lock.lock(); _onModelInfo = sink; lock.unlock()
    }
    func setLensStatusSink(_ sink: (@Sendable (JSpaceLensStatus) -> Void)?) {
        lock.lock(); _onLensStatus = sink; lock.unlock()
    }
    func reportLensStatus(_ status: JSpaceLensStatus) {
        lock.lock(); let sink = _onLensStatus; lock.unlock()
        sink?(status)
    }

    /// The most recently probed model info (retained so a freshly opened panel can
    /// show capability without waiting for a generation).
    var lastModelInfo: JSpaceModelInfo? {
        lock.lock(); defer { lock.unlock() }; return _lastModelInfo
    }

    func emitReadout(_ frame: JSpaceReadoutFrame) {
        lock.lock(); let sink = _onReadout; lock.unlock()
        sink?(frame)
    }
    func reportModelInfo(_ info: JSpaceModelInfo) {
        lock.lock(); _lastModelInfo = info; let sink = _onModelInfo; lock.unlock()
        sink?(info)
    }
}
