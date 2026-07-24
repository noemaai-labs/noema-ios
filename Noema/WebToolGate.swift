import Foundation

struct WebToolGate {
    // Background-safe gate that avoids MainActor by reading persisted defaults directly.
    // `afmKind` lets an AFM client gate on its own variant; callers that don't know it
    // (UI chips, prompt builders) fall back to the persisted kind of the loaded model.
    static func isAvailable(currentFormat: ModelFormat? = nil, afmKind: AppleFoundationModelKind? = nil) -> Bool {
        guard EnterprisePolicyGate.allowsTool("noema.web.retrieve") else { return false }
        let d = UserDefaults.standard
        let enabled = d.object(forKey: "webSearchEnabled") as? Bool ?? true
        let offGrid = d.object(forKey: "offGrid") as? Bool ?? false
        // Keep kill switch in sync even if settings change outside SettingsView
        NetworkKillSwitch.setEnabled(offGrid)
        if offGrid { return false }

        let armed = d.object(forKey: "webSearchArmed") as? Bool ?? false
        // Datasets take precedence: when a dataset is selected or indexing, web search is disabled.
        let selectedDatasetID = d.string(forKey: "selectedDatasetID") ?? ""
        let indexingDatasetID = d.string(forKey: "indexingDatasetIDPersisted") ?? ""
        let datasetActiveOrIndexing = (!selectedDatasetID.isEmpty) || (!indexingDatasetID.isEmpty)
        // Resolve current model format (fallback to persisted if not provided)
        var fmt = currentFormat
        if fmt == nil, let fmtStr = d.string(forKey: "currentModelFormat") {
            if let f = ModelFormat(compatibleRawValue: fmtStr) {
                fmt = f
            }
        }

        // Only allow when the loaded model supports function calling (from model card/capability detector).
        // MLX local models now call tools natively via their own chat template, so they are no longer
        // blanket-excluded — the supportsFunctionCalling check below still gates non-tool-capable models.
        // AFM: the PCC server model calls FoundationModels tools natively, so it passes; the
        // on-device model stays excluded (small model, limited context, no native tool wiring).
        if let f = fmt, f == .afm {
            let kind = afmKind ?? AppleFoundationModelKind.persistedCurrentKind()
            if kind != .privateCloudCompute { return false }
        }
        let supportsFunctionCalling = d.object(forKey: "currentModelSupportsFunctionCalling") as? Bool ?? false
        if supportsFunctionCalling == false { return false }

        // Basic availability check (dataset use overrides and disables web search)
        return enabled && armed && !datasetActiveOrIndexing
    }
}
