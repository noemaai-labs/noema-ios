import Foundation

// Pure routing policy for Apple Foundation Model turns. Deliberately free of
// FoundationModels imports and availability gates so the decision logic
// compiles and unit-tests on every toolchain (Xcode 26 included); the AFM
// client feeds it runtime facts and applies the result to the live session.

/// Where a single AFM turn runs.
enum AFMInferenceRoute: String, Codable, Sendable, Equatable {
    case onDevice
    case privateCloudCompute
}

/// Facts gathered immediately before a turn, fed to `AFMRoutePlanner.decide`.
struct AFMRouteInputs: Equatable, Sendable {
    var mode: AFMPrivateCloudComputeMode
    /// The app-wide Off-Grid kill switch. Hard privacy gate: PCC never runs while set.
    var offGrid: Bool
    /// True only when the build + OS can reference Private Cloud Compute at all
    /// (Swift 6.3+ toolchain and iOS/macOS/visionOS 27 at runtime).
    var runtimeSupportsPCC: Bool
    /// `PrivateCloudComputeLanguageModel().isAvailable`.
    var pccAvailable: Bool
    /// `quotaUsage.isLimitReached` — the per-user daily PCC quota is spent.
    var pccQuotaExhausted: Bool
    /// Exact token count of the rendered prompt (server-side history included),
    /// nil when counting failed or is unsupported.
    var promptTokenEstimate: Int?
    /// `SystemLanguageModel.contextSize`, nil when unknown.
    var onDeviceContextSize: Int?
}

/// The planner's verdict for one turn.
struct AFMRouteDecision: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case modeOff
        case offGrid
        case runtimeUnsupported
        case pccUnavailable
        case quotaExhausted
        case alwaysPCC
        case contextRequiresPCC
        case smartDefault
    }

    /// Route the turn starts on.
    let initialRoute: AFMInferenceRoute
    /// Whether the hidden capability-switch tool is offered this turn.
    let allowEscalation: Bool
    /// True when `.always` asked for PCC but the turn had to stay on-device.
    let isFallback: Bool
    let reason: Reason
}

/// What actually happened on a finished turn, reported by the AFM client so the
/// chat layer can attach the Private Cloud badge.
struct AFMTurnRouteInfo: Sendable, Equatable {
    /// Route that produced the final answer.
    let route: AFMInferenceRoute
    /// A smart-mode baton pass to PCC happened mid-turn.
    let escalatedMidTurn: Bool
    /// PCC was requested (or reached) but the answer was finished on-device.
    let fellBackToOnDevice: Bool
}

enum AFMRoutePlanner {
    /// Tokens reserved for the model's reply when judging whether a prompt
    /// still fits the on-device context.
    static let reservedResponseTokens = 1024

    static func decide(_ inputs: AFMRouteInputs) -> AFMRouteDecision {
        if inputs.mode == .off {
            return AFMRouteDecision(initialRoute: .onDevice, allowEscalation: false, isFallback: false, reason: .modeOff)
        }
        if inputs.offGrid {
            return AFMRouteDecision(initialRoute: .onDevice, allowEscalation: false, isFallback: false, reason: .offGrid)
        }
        if !inputs.runtimeSupportsPCC {
            return AFMRouteDecision(initialRoute: .onDevice, allowEscalation: false, isFallback: false, reason: .runtimeUnsupported)
        }
        if !inputs.pccAvailable {
            return AFMRouteDecision(initialRoute: .onDevice, allowEscalation: false, isFallback: false, reason: .pccUnavailable)
        }
        if inputs.pccQuotaExhausted {
            return AFMRouteDecision(
                initialRoute: .onDevice,
                allowEscalation: false,
                isFallback: inputs.mode == .always,
                reason: .quotaExhausted
            )
        }
        if inputs.mode == .always {
            return AFMRouteDecision(initialRoute: .privateCloudCompute, allowEscalation: false, isFallback: false, reason: .alwaysPCC)
        }
        // .smart: pre-route straight to PCC only when we *know* the prompt
        // cannot fit on-device; with unknown counts, stay on-device and let
        // the model escalate itself.
        if let estimate = inputs.promptTokenEstimate,
           let contextSize = inputs.onDeviceContextSize,
           estimate + Self.reservedResponseTokens > contextSize {
            return AFMRouteDecision(initialRoute: .privateCloudCompute, allowEscalation: false, isFallback: false, reason: .contextRequiresPCC)
        }
        return AFMRouteDecision(initialRoute: .onDevice, allowEscalation: true, isFallback: false, reason: .smartDefault)
    }
}
