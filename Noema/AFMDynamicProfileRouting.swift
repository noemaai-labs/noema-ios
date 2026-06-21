import Foundation

// Framework-native AFM <-> Private Cloud Compute routing via Dynamic Profiles
// (WWDC26 "baton-pass" pattern). The on-device branch carries a hidden
// capability-switch tool; when the model calls it, the route state flips and
// the framework re-resolves the profile so Private Cloud Compute finishes the
// turn with the full shared transcript. Nothing here is recorded as a visible
// Noema tool call.
//
// Dynamic Profiles and `PrivateCloudComputeLanguageModel` are iOS 27 / Xcode 27
// SDK symbols absent from the iOS 26 SDK, so the whole file is compile-gated
// with `#if NOEMA_ENABLE_XCODE27_APIS` in addition to the runtime `@available`
// checks. Compiler version alone is not a reliable SDK-symbol gate.

#if canImport(FoundationModels)
#if NOEMA_ENABLE_XCODE27_APIS
import FoundationModels

/// Mutable per-session routing state shared between the AFM client, the hidden
/// switch tool, and the dynamic profile body. NSLock-guarded because the tool
/// fires on the framework's inference executor while the client mutates it
/// from its own tasks.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
final class AFMRouteStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _route: AFMInferenceRoute = .onDevice
    private var _allowEscalation = false
    private var _escalatedThisTurn = false
    private var _fellBackToOnDevice = false

    var route: AFMInferenceRoute {
        lock.lock(); defer { lock.unlock() }
        return _route
    }

    var allowEscalation: Bool {
        lock.lock(); defer { lock.unlock() }
        return _allowEscalation
    }

    var escalatedThisTurn: Bool {
        lock.lock(); defer { lock.unlock() }
        return _escalatedThisTurn
    }

    /// Start-of-turn reset: escalation never outlives the turn that asked for it.
    func applyDecision(_ decision: AFMRouteDecision) {
        lock.lock(); defer { lock.unlock() }
        _route = decision.initialRoute
        _allowEscalation = decision.allowEscalation
        _escalatedThisTurn = false
        _fellBackToOnDevice = decision.isFallback
    }

    /// The on-device model asked for the baton pass.
    func noteEscalation() {
        lock.lock(); defer { lock.unlock() }
        guard _route == .onDevice else { return }
        _route = .privateCloudCompute
        _escalatedThisTurn = true
    }

    /// PCC failed mid-turn (quota/network/service); finish on-device.
    func noteFallbackToOnDevice() {
        lock.lock(); defer { lock.unlock() }
        _route = .onDevice
        _allowEscalation = false
        _fellBackToOnDevice = true
    }

    func turnRouteInfo() -> AFMTurnRouteInfo {
        lock.lock(); defer { lock.unlock() }
        return AFMTurnRouteInfo(
            route: _route,
            escalatedMidTurn: _escalatedThisTurn,
            fellBackToOnDevice: _fellBackToOnDevice
        )
    }
}

/// The hidden baton: calling it flips the route state so the profile
/// re-resolves onto Private Cloud Compute, which then writes the final answer
/// with the full transcript. Deliberately takes no AFMToolRecorder — the
/// handoff must never surface as a tool card in the chat.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
final class AFMCapabilitySwitchTool: FoundationModels.Tool {
    static let toolName = "request_deeper_assistance"

    let name = AFMCapabilitySwitchTool.toolName
    let description = "Call this when the user's request needs deeper reasoning, broader knowledge, or longer context than you can handle well. A more capable model will seamlessly take over and write the final answer. Do not mention this handoff to the user."

    private let onEscalate: @Sendable () -> Void

    init(onEscalate: @escaping @Sendable () -> Void) {
        self.onEscalate = onEscalate
    }

    @Generable
    struct Arguments {
        @Guide(description: "A brief reason why this request needs more capability.")
        var reason: String
    }

    func call(arguments: Arguments) async throws -> String {
        onEscalate()
        return "Handoff accepted. If no other model takes over, answer the user yourself."
    }
}

/// Shared instructions + tool surface for both profile branches. Identical
/// content on both sides keeps the transcript coherent across the handoff and
/// is friendliest to the KV cache (static instructions first, conditional
/// escalation tool last).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct NoemaAFMInstructions: DynamicInstructions {
    let instructions: String
    let tools: [any FoundationModels.Tool]
    let escalationTool: AFMCapabilitySwitchTool?

    var body: some DynamicInstructions {
        if !instructions.isEmpty {
            Instructions(instructions)
        }
        tools
        if let escalationTool {
            escalationTool
        }
    }
}

/// One session, two hats: on-device by default, Private Cloud Compute when the
/// route state says so. The body is re-resolved by the framework per inference
/// step, so flipping `stateBox` mid-turn hands the baton without rebuilding the
/// session or losing the transcript.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct NoemaAFMRoutingProfile: LanguageModelSession.DynamicProfile {
    let stateBox: AFMRouteStateBox
    let instructions: String
    let tools: [any FoundationModels.Tool]
    let guardrails: SystemLanguageModel.Guardrails
    private let escalationTool: AFMCapabilitySwitchTool
    private let pccModel: PrivateCloudComputeLanguageModel

    init(
        stateBox: AFMRouteStateBox,
        instructions: String,
        tools: [any FoundationModels.Tool],
        guardrails: SystemLanguageModel.Guardrails
    ) {
        self.stateBox = stateBox
        self.instructions = instructions
        self.tools = tools
        self.guardrails = guardrails
        self.escalationTool = AFMCapabilitySwitchTool(onEscalate: { stateBox.noteEscalation() })
        self.pccModel = PrivateCloudComputeLanguageModel()
    }

    var body: some LanguageModelSession.DynamicProfile {
        switch stateBox.route {
        case .onDevice:
            Profile {
                NoemaAFMInstructions(
                    instructions: instructions,
                    tools: tools,
                    escalationTool: stateBox.allowEscalation ? escalationTool : nil
                )
            }
            .model(SystemLanguageModel(guardrails: guardrails))
            .onToolCall { (call: Transcript.ToolCall) in
                if call.toolName == AFMCapabilitySwitchTool.toolName {
                    stateBox.noteEscalation()
                }
            }
        case .privateCloudCompute:
            Profile {
                NoemaAFMInstructions(
                    instructions: instructions,
                    tools: tools,
                    escalationTool: nil
                )
            }
            .model(pccModel)
            // A mid-turn handoff means the on-device model already judged the
            // request hard; spend moderate reasoning on it. `.always` turns
            // keep the latency-optimized default.
            .reasoningLevel(stateBox.escalatedThisTurn ? .moderate : nil)
            .transcriptErrorHandlingPolicy(.revertTranscript)
        }
    }
}
#endif
#endif
