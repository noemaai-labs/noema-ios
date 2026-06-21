import SwiftUI

struct PrivacyFlightRecorderSummaryContent: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    let openRecorder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: offGrid ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(offGrid ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Privacy Flight Recorder"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openRecorder) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Privacy Flight Recorder"))
            }

            HStack(spacing: 8) {
                PrivacyFlightPill(title: LocalizedStringKey("Off-grid"), value: offGrid ? String(localized: "On") : String(localized: "Off"))
                PrivacyFlightPill(title: LocalizedStringKey("Runtime"), value: runtimePillValue)
                PrivacyFlightPill(title: LocalizedStringKey("Network"), value: offGrid ? String(localized: "Blocked") : String(localized: "Allowed"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openRecorder)
    }

    private var offGrid: Bool {
        UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
    }

    private var summaryLine: String {
        if offGrid {
            return String(localized: "Network paths are blocked by Off-grid Mode")
        }
        if modelManager.activeRemoteSession != nil {
            return String(localized: "Remote runtime is active")
        }
        if activeLocalModel != nil {
            return String(localized: "Current runtime is local")
        }
        return String(localized: "Review local, remote, and tool privacy state")
    }

    private var runtimePillValue: String {
        if modelManager.activeRemoteSession != nil { return String(localized: "Remote") }
        if activeLocalModel != nil { return String(localized: "Local") }
        return chatVM.hasActiveChatModel ? String(localized: "Active") : String(localized: "None")
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }
}

struct PrivacyFlightRecorderView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @ObservedObject private var settings = SettingsStore.shared
    @State private var checkedAt = Date()
    @State private var drillResults: [PrivacyProofDrillResult] = []
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Flight Summary")) {
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Privacy Mode"),
                    value: offGrid ? String(localized: "Off-grid") : String(localized: "Standard"),
                    systemImage: offGrid ? "wifi.slash" : "wifi",
                    tint: offGrid ? .green : .accentColor
                )
                PrivacyFlightValueRow(title: LocalizedStringKey("Network Kill Switch"), value: NetworkKillSwitch.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                PrivacyFlightValueRow(title: LocalizedStringKey("Active Runtime"), value: runtimeValue)
                PrivacyFlightValueRow(title: LocalizedStringKey("Active Model"), value: activeModelValue)
                PrivacyFlightValueRow(title: LocalizedStringKey("Active Dataset"), value: activeDatasetValue)
                PrivacyFlightValueRow(title: LocalizedStringKey("Checked"), value: checkedAt.formatted(date: .abbreviated, time: .standard))
            }

            Section(LocalizedStringKey("Local Surfaces")) {
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Local Model Execution"),
                    value: activeLocalModel == nil ? String(localized: "Idle") : String(localized: "Local"),
                    systemImage: "cpu",
                    tint: activeLocalModel == nil ? .secondary : .green
                )
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Dataset Retrieval"),
                    value: activeDataset == nil ? String(localized: "Inactive") : String(localized: "Local"),
                    systemImage: "doc.text.magnifyingglass",
                    tint: activeDataset == nil ? .secondary : .green
                )
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Persistent Memory"),
                    value: settings.memoryEnabled ? String(localized: "Local") : String(localized: "Off"),
                    systemImage: "square.stack.3d.up",
                    tint: settings.memoryEnabled ? .green : .secondary
                )
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Python Sandbox"),
                    value: settings.pythonEnabled ? String(localized: "Local") : String(localized: "Off"),
                    systemImage: "terminal",
                    tint: settings.pythonEnabled ? .green : .secondary
                )
            }

            Section(LocalizedStringKey("Network-Capable Surfaces")) {
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Web Search"),
                    value: networkSurfaceValue(enabled: settings.webSearchEnabled),
                    systemImage: "magnifyingglass",
                    tint: networkSurfaceTint(enabled: settings.webSearchEnabled)
                )
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Remote Backends"),
                    value: remoteBackendValue,
                    systemImage: "network",
                    tint: remoteBackendTint
                )
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Downloads and Explore"),
                    value: offGrid ? String(localized: "Blocked") : String(localized: "Allowed"),
                    systemImage: "arrow.down.circle",
                    tint: offGrid ? .green : .orange
                )
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Wallet Signing"),
                    value: offGrid ? String(localized: "Blocked") : String(localized: "Allowed"),
                    systemImage: "wallet.pass",
                    tint: offGrid ? .green : .orange
                )
            }

            Section(LocalizedStringKey("Off-Grid Proof Drill")) {
                Button {
                    runProofDrill()
                } label: {
                    Label(LocalizedStringKey("Run Proof Drill"), systemImage: "checkmark.shield")
                }

                if drillResults.isEmpty {
                    Text(LocalizedStringKey("Run the drill to verify external network paths are blocked while loopback and local paths remain available."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(drillResults) { result in
                        PrivacyProofDrillRow(result: result)
                    }
                }
            }

            Section(LocalizedStringKey("Recent Blocked Attempts")) {
                let attempts = NetworkKillSwitch.recentBlockedAttempts
                if attempts.isEmpty {
                    Text(LocalizedStringKey("No blocked network attempts recorded"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(attempts.prefix(8)) { attempt in
                        PrivacyBlockedAttemptRow(attempt: attempt)
                    }

                    Button(role: .destructive) {
                        NetworkKillSwitch.clearBlockedAttempts()
                        checkedAt = Date()
                    } label: {
                        Label(LocalizedStringKey("Clear Blocked Attempts"), systemImage: "trash")
                    }
                }
            }

            Section(LocalizedStringKey("Remote Session")) {
                if let remote = modelManager.activeRemoteSession {
                    PrivacyFlightValueRow(title: LocalizedStringKey("Backend"), value: remote.backendName)
                    PrivacyFlightValueRow(title: LocalizedStringKey("Model"), value: remote.modelName)
                    PrivacyFlightValueRow(title: LocalizedStringKey("Endpoint"), value: remote.endpointType.displayName)
                    PrivacyFlightValueRow(title: LocalizedStringKey("Transport"), value: remote.transport.label)
                } else {
                    Text(LocalizedStringKey("No remote session is active"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Privacy Export")) {
                Button {
                    generateExport()
                } label: {
                    Label(LocalizedStringKey("Generate Privacy JSON"), systemImage: "doc.badge.gearshape")
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share Privacy JSON"), systemImage: "square.and.arrow.up")
                    }
                    PrivacyFlightValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                }

                if let exportError {
                    PrivacyFlightValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Privacy Flight Recorder"))
        .onAppear { checkedAt = Date() }
    }

    private var offGrid: Bool {
        UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var activeDataset: LocalDataset? {
        modelManager.activeDataset ?? datasetManager.selectedDataset
    }

    private var runtimeValue: String {
        if let remote = modelManager.activeRemoteSession {
            return "\(String(localized: "Remote")) · \(remote.backendName)"
        }
        if activeLocalModel != nil {
            return String(localized: "Local")
        }
        return chatVM.hasActiveChatModel ? String(localized: "Active") : String(localized: "Inactive")
    }

    private var activeModelValue: String {
        if let model = activeLocalModel { return model.name }
        if let remote = modelManager.activeRemoteSession { return remote.modelName }
        return String(localized: "No model loaded")
    }

    private var activeDatasetValue: String {
        activeDataset?.name ?? String(localized: "None")
    }

    private var remoteBackendValue: String {
        if offGrid { return String(localized: "Blocked") }
        if modelManager.activeRemoteSession != nil { return String(localized: "Active") }
        if modelManager.remoteBackends.isEmpty { return String(localized: "None configured") }
        return String.localizedStringWithFormat(String(localized: "%d configured"), modelManager.remoteBackends.count)
    }

    private var remoteBackendTint: Color {
        if offGrid { return .green }
        if modelManager.activeRemoteSession != nil { return .orange }
        return modelManager.remoteBackends.isEmpty ? .secondary : .orange
    }

    private func networkSurfaceValue(enabled: Bool) -> String {
        if offGrid { return String(localized: "Blocked") }
        return enabled ? String(localized: "Allowed") : String(localized: "Off")
    }

    private func networkSurfaceTint(enabled: Bool) -> Color {
        if offGrid { return .green }
        return enabled ? .orange : .secondary
    }

    private func generateExport() {
        do {
            let data = try JSONSerialization.data(withJSONObject: exportPayload(), options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-privacy-flight-\(Self.fileTimestamp()).json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func exportPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "checkedAt": ISO8601DateFormatter().string(from: checkedAt),
            "offGrid": offGrid,
            "networkKillSwitch": NetworkKillSwitch.isEnabled,
            "runtime": runtimeValue,
            "activeModel": activeModelValue,
            "activeDataset": activeDatasetValue,
            "webSearchEnabled": settings.webSearchEnabled,
            "pythonEnabled": settings.pythonEnabled,
            "memoryEnabled": settings.memoryEnabled,
            "webSearchArmed": settings.webSearchArmed,
            "pythonArmed": settings.pythonArmed,
            "proofDrill": drillResults.map(\.exportDictionary),
            "recentBlockedAttempts": NetworkKillSwitch.recentBlockedAttempts.map { attempt in
                [
                    "url": attempt.urlString,
                    "host": attempt.host,
                    "blockedAt": ISO8601DateFormatter().string(from: attempt.blockedAt)
                ]
            }
        ]

        if let model = activeLocalModel {
            payload["localModel"] = [
                "name": model.name,
                "modelID": model.modelID,
                "format": model.format.displayName,
                "path": model.url.path
            ]
        }

        if let dataset = activeDataset {
            payload["dataset"] = [
                "name": dataset.name,
                "url": dataset.url.path
            ]
        }

        if let remote = modelManager.activeRemoteSession {
            payload["remoteSession"] = [
                "backend": remote.backendName,
                "model": remote.modelName,
                "endpoint": remote.endpointType.displayName,
                "transport": remote.transport.label
            ]
        }

        return payload
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func runProofDrill() {
        checkedAt = Date()
        drillResults = Self.proofSurfaces.map { surface in
            let blockedNow = NetworkKillSwitch.shouldBlock(url: surface.url)
            let wouldBlock = NetworkKillSwitch.wouldBlock(url: surface.url)
            let status: String
            let tint: Color
            let detail: String

            if blockedNow {
                status = String(localized: "Blocked")
                tint = .green
                detail = surface.url.host ?? surface.url.scheme ?? surface.url.absoluteString
            } else if wouldBlock {
                status = String(localized: "Would block in Off-grid")
                tint = .orange
                detail = surface.url.host ?? surface.url.scheme ?? surface.url.absoluteString
            } else {
                status = String(localized: "Allowed")
                tint = surface.expectedAllowed ? .green : .secondary
                detail = surface.reason
            }

            return PrivacyProofDrillResult(
                title: surface.title,
                status: status,
                detail: detail,
                systemImage: surface.systemImage,
                tint: tint,
                urlString: surface.url.absoluteString
            )
        }
    }

    private static let proofSurfaces: [PrivacyProofSurface] = [
        PrivacyProofSurface(
            title: LocalizedStringKey("Web Search Endpoint"),
            url: URL(string: "https://searx.example/search?q=noema")!,
            systemImage: "magnifyingglass",
            expectedAllowed: false,
            reason: String(localized: "External HTTP(S)")
        ),
        PrivacyProofSurface(
            title: LocalizedStringKey("Model Download Endpoint"),
            url: URL(string: "https://huggingface.co/noema/model/resolve/main/model.gguf")!,
            systemImage: "arrow.down.circle",
            expectedAllowed: false,
            reason: String(localized: "External HTTP(S)")
        ),
        PrivacyProofSurface(
            title: LocalizedStringKey("Remote Backend Endpoint"),
            url: URL(string: "http://192.168.0.10:11434/api/chat")!,
            systemImage: "network",
            expectedAllowed: false,
            reason: String(localized: "LAN HTTP(S)")
        ),
        PrivacyProofSurface(
            title: LocalizedStringKey("Wallet Signer Endpoint"),
            url: URL(string: "https://wallet.example/sign")!,
            systemImage: "wallet.pass",
            expectedAllowed: false,
            reason: String(localized: "External HTTP(S)")
        ),
        PrivacyProofSurface(
            title: LocalizedStringKey("Loopback Runtime Endpoint"),
            url: URL(string: "http://127.0.0.1:8080/health")!,
            systemImage: "cpu",
            expectedAllowed: true,
            reason: String(localized: "Loopback allowed")
        ),
        PrivacyProofSurface(
            title: LocalizedStringKey("Local File Path"),
            url: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/noema-local-file"),
            systemImage: "folder",
            expectedAllowed: true,
            reason: String(localized: "Not a network request")
        )
    ]
}

private struct PrivacyProofSurface {
    let title: LocalizedStringKey
    let url: URL
    let systemImage: String
    let expectedAllowed: Bool
    let reason: String
}

private struct PrivacyProofDrillResult: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let status: String
    let detail: String
    let systemImage: String
    let tint: Color
    let urlString: String

    var exportDictionary: [String: Any] {
        [
            "status": status,
            "detail": detail,
            "url": urlString
        ]
    }
}

private struct PrivacyFlightPill: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct PrivacyFlightStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct PrivacyFlightValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct PrivacyProofDrillRow: View {
    let result: PrivacyProofDrillResult

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: result.status)
                    .font(.body.weight(.medium))
                    .foregroundStyle(result.tint)
                Text(verbatim: result.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Label(result.title, systemImage: result.systemImage)
                .foregroundStyle(result.tint)
        }
        .padding(.vertical, 2)
    }
}

private struct PrivacyBlockedAttemptRow: View {
    let attempt: NetworkBlockedAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(attempt.host, systemImage: "wifi.slash")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.green)
                Spacer(minLength: 8)
                Text(attempt.blockedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: attempt.urlString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}
