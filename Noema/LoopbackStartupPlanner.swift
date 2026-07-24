import Foundation
import NoemaPackages

enum LoopbackStartupPlanner {
    static func formatFailureMessage(_ diagnostics: LlamaServerBridge.StartDiagnostics?) -> String {
        let locale = LocalizationManager.preferredLocale()
        let reason: String
        switch diagnostics?.code {
        case "listener_timeout", "ready_timeout":
            reason = String(localized: "Request timed out. Please try again.", locale: locale)
        default:
            reason = String(localized: "The on-device model runtime could not start.", locale: locale)
        }
        let status = diagnostics?.lastHTTPStatus.map(String.init) ?? "n/a"
        let progress = Int(round((diagnostics?.progress ?? 0) * 100))
        let settingsUnchanged = String(
            localized: "Noema did not change this model's saved settings. Adjust Model Settings manually if you want to try a smaller context or different runtime options.",
            locale: locale
        )
        return [
            "Failed to start local GGUF runtime.",
            "Reason: \(reason)",
            "Status: \(status), progress: \(progress)%",
            settingsUnchanged
        ].joined(separator: "\n")
    }
}
