import Foundation

struct PythonToolGate {
    /// Background-safe gate that avoids MainActor by reading persisted defaults directly.
    /// `afmKind` lets an AFM client gate on its own variant; other callers fall back to
    /// the persisted kind of the loaded model.
    static func isAvailable(currentFormat: ModelFormat? = nil, afmKind: AppleFoundationModelKind? = nil) -> Bool {
        guard EnterprisePolicyGate.allowsTool("noema.python.execute") else { return false }
        let d = UserDefaults.standard

        // Master toggle from Settings
        let enabled = d.object(forKey: "pythonEnabled") as? Bool ?? true
        guard enabled else { return false }

        // Chat-level arm toggle
        let armed = d.object(forKey: "pythonArmed") as? Bool ?? false
        guard armed else { return false }

        // Datasets take precedence: when a dataset is selected or indexing, tools are disabled.
        let selectedDatasetID = d.string(forKey: "selectedDatasetID") ?? ""
        let indexingDatasetID = d.string(forKey: "indexingDatasetIDPersisted") ?? ""
        let datasetActiveOrIndexing = (!selectedDatasetID.isEmpty) || (!indexingDatasetID.isEmpty)
        if datasetActiveOrIndexing { return false }

        // Resolve current model format (fallback to persisted if not provided)
        var fmt = currentFormat
        if fmt == nil, let fmtStr = d.string(forKey: "currentModelFormat") {
            if let f = ModelFormat(compatibleRawValue: fmtStr) {
                fmt = f
            }
        }

        // MLX local models now call tools natively via their own chat template, so they
        // are no longer excluded here (supportsFunctionCalling still gates capability).
        // AFM never uses the loopback loop: the PCC server model calls FoundationModels
        // tools natively so it passes; the on-device model stays excluded.
        if let f = fmt, f == .afm {
            let kind = afmKind ?? AppleFoundationModelKind.persistedCurrentKind()
            if kind != .privateCloudCompute { return false }
        }

        // Only allow when the loaded model supports function calling
        let supportsFunctionCalling = d.object(forKey: "currentModelSupportsFunctionCalling") as? Bool ?? false
        if supportsFunctionCalling == false { return false }

        guard PythonRuntime.status().isAvailable else { return false }

        return true
    }
}
