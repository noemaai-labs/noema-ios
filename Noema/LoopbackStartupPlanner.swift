import Foundation
import NoemaPackages

enum LoopbackStartupPlanner {
    static func formatFailureMessage(_ diagnostics: LlamaServerBridge.StartDiagnostics?) -> String {
        let reason = diagnostics?.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? diagnostics!.message
            : (diagnostics?.code ?? "startup_failed")
        let status = diagnostics?.lastHTTPStatus.map(String.init) ?? "n/a"
        let progress = Int(round((diagnostics?.progress ?? 0) * 100))
        let settingsUnchanged = String(
            localized: "Noema did not change this model's saved settings. Adjust Model Settings manually if you want to try a smaller context or different runtime options.",
            locale: LocalizationManager.preferredLocale()
        )
        return [
            "Failed to start local GGUF runtime.",
            "Reason: \(reason)",
            "Status: \(status), progress: \(progress)%",
            settingsUnchanged
        ].joined(separator: "\n")
    }
}
