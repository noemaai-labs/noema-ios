import Foundation

struct MemoryToolGate {
    static func isAvailable(currentFormat: ModelFormat? = nil) -> Bool {
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
        // AFM uses its own FoundationModels tool system; the loopback memory tool
        // is incompatible with it and would also balloon the limited AFM context.
        if fmt == .afm { return false }

        let supportsFunctionCalling = defaults.object(forKey: "currentModelSupportsFunctionCalling") as? Bool ?? false
        guard supportsFunctionCalling else { return false }

        return true
    }
}
