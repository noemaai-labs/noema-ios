import Foundation

public struct PhoneAFriendTool: Tool {
    public static let toolName = "noema.assist.handoff"

    public let name = PhoneAFriendTool.toolName
    public let description = "Hand this conversation to a much more capable model when the current request is clearly beyond you: complex multi-step reasoning, tricky math or code, obscure facts you are unsure about, or high-stakes accuracy. The stronger model takes over and answers the user directly — after calling, stop writing. Use it sparingly; answer simple requests yourself."
    public let schema = """
    {"type":"object","properties":{"reason":{"type":"string","description":"One short sentence: why this request needs the stronger model."}},"required":["reason"]}
    """

    public init() {}

    // Reached only when ChatVM declined the handoff (target unavailable, or a
    // handoff already failed this turn). Nudge the model to finish on its own.
    public func call(args: Data) async throws -> Data {
        let payload: [String: Any] = [
            "status": "unavailable",
            "message": "The stronger model is not available right now. Answer the user yourself as well as you can, and do not call this tool again this turn."
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

enum PhoneAFriendGate {
    /// Whether the handoff tool should be advertised to the resident local
    /// model. Execution-time policy is re-checked in ChatVM at handoff.
    static func isAvailable() -> Bool {
        let config = AutopilotConfigStore.load()
        guard config.enabled, config.system == .phoneAFriend, config.isReadyToArm else { return false }
        // "Pause cloud escalation" withholds the hand-off tool in BOTH targets
        // (the settings footer promises exactly this); a paused local target
        // must not silently keep handing off.
        guard !config.pauseCloudEscalation else { return false }
        switch config.escalationTarget {
        case .remote:
            guard !UserDefaults.standard.bool(forKey: "offGrid"),
                  !NetworkKillSwitch.isEnabled,
                  !EnterprisePolicyGate.requiresOffGrid,
                  EnterprisePolicyGate.remoteInferenceAllowed else { return false }
            return true
        case .privateCloudCompute:
            return ApplePrivateCloudComputeAvailability.isAvailableNow
        case .localModel:
            #if os(macOS)
            return config.localEscalation != nil
            #else
            return false
            #endif
        }
    }

    /// The handoff tool is for the resident local model only — never offer it
    /// to a cloud model (a remote session or an already-escalated turn).
    static func strippingHandoff(from specs: [ToolSpec]) -> [ToolSpec] {
        specs.filter { $0.function.name != PhoneAFriendTool.toolName }
    }

    /// Reasons that indicate the model echoed the tool's own example/schema
    /// text rather than a genuine hand-off — these must NOT trigger a real
    /// full-turn escalation.
    private static let placeholderReasons: Set<String> = [
        "",
        "...",
        "one short sentence on why this needs the stronger model",
        "why this request needs the stronger model",
        "one short sentence: why this request needs the stronger model."
    ]

    static func isGenuineHandoffReason(_ reason: String) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !placeholderReasons.contains(trimmed)
    }
}
