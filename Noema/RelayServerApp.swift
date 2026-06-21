#if os(macOS)
import SwiftUI
import AppKit
import RelayKit

#if RELAY_SERVER_APP
@main
#endif
struct RelayServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Relay Server") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Relay Server Running")
                    .font(.headline)
                Text("CloudKit bridge active. Local replies are generated on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 320, height: 160)
            .padding()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, @preconcurrency NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await startRelay() }
    }

    private func startRelay() async {
        let provider: InferenceProvider
        if ProcessInfo.processInfo.environment["RELAY_PROVIDER"]?.lowercased() == "ollama" {
            provider = OllamaClient()
        } else {
            provider = LMStudioClient()
        }
        let containerID = RelayConfiguration.containerIdentifier
        CloudKitRelay.shared.configure(containerIdentifier: containerID, provider: provider)
        await CloudKitRelay.shared.startServerProcessing()
        await MainActor.run {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.registerForRemoteNotifications()
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String : Any]) {
        Task { await CloudKitRelay.shared.handleRemoteNotification() }
    }
}
#endif
