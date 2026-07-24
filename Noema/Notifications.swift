import Foundation

extension Notification.Name {
    static let thinkToggled = Notification.Name("Noema.thinkToggled")
    static let embeddingModelAvailabilityChanged = Notification.Name("Noema.embeddingModelAvailabilityChanged")
    static let memoryStoreDidChange = Notification.Name("Noema.memoryStoreDidChange")
    static let llamaLogMessage = Notification.Name("Noema.llamaLogMessage")
    static let mlxModelLoadProgress = Notification.Name("Noema.mlxModelLoadProgress")
    static let relayWillLoadLocalModel = Notification.Name("Noema.relayWillLoadLocalModel")
    static let downloadEngineDidChange = Notification.Name("Noema.downloadEngineDidChange")
    static let downloadMaintenanceRequested = Notification.Name("Noema.downloadMaintenanceRequested")
    // Posted by BackgroundDownloadManager when a background URLSession download finishes but
    // no in-memory continuation is available (e.g., after app restart). Allows controllers
    // to reconcile and finalize installs.
    static let backgroundDownloadCompleted = Notification.Name("Noema.backgroundDownloadCompleted")
    // Posted by BackgroundDownloadManager when a transfer restarts from byte zero (the server
    // rejected or ignored a resume). Engine byte counts are monotonic, so without this signal
    // the stale larger count freezes the visible progress until the new transfer catches up.
    static let backgroundDownloadRestarted = Notification.Name("Noema.backgroundDownloadRestarted")
}
