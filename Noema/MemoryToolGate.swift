import Foundation

struct MemoryToolGate {
    /// `afmKind` lets an AFM client gate on its own variant; other callers fall back to
    /// the persisted kind of the loaded model.
    static func isAvailable(currentFormat: ModelFormat? = nil, afmKind: AppleFoundationModelKind? = nil) -> Bool {
        guard EnterprisePolicyGate.allowsTool("noema.memory") else { return false }
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "memoryEnabled") as? Bool ?? true
        guard enabled else { return false }

        let isRemote = defaults.object(forKey: "currentModelIsRemote") as? Bool ?? false
        guard !isRemote else { return false }

        // Resolve current model format (fallback to persisted if not provided)
        var fmt = currentFormat
        if fmt == nil, let fmtStr = defaults.string(forKey: "currentModelFormat") {
            if let f = ModelFormat(compatibleRawValue: fmtStr) {
                fmt = f
            }
        }
        // AFM never uses the loopback loop. The PCC server model (32K context) calls
        // the native FoundationModels memory tool, so it passes; the on-device model
        // stays excluded — the snapshot would balloon its small context.
        if fmt == .afm {
            let kind = afmKind ?? AppleFoundationModelKind.persistedCurrentKind()
            if kind != .privateCloudCompute { return false }
        }
        // Local MLX tool calling is unreliable — same rejection as every other gate
        // (web/python/deterministic/on-device) so the chips, Tool Store, and prompt
        // guidance all agree. Remote was already rejected above.
        if fmt == .mlx { return false }

        let supportsFunctionCalling = defaults.object(forKey: "currentModelSupportsFunctionCalling") as? Bool ?? false
        guard supportsFunctionCalling else { return false }

        return true
    }
}
