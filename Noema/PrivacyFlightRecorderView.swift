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
#if os(macOS)
        // The iOS Form renders badly inside the Mac settings sheet (clipped
        // labels, wrong insets, stock buttons), so macOS gets a first-class
        // industrial-dialect layout instead. The sheet already supplies the
        // title + close, so no navigationTitle here.
        macBody
            .onAppear { checkedAt = Date() }
#else
        formBody
            .navigationTitle(LocalizedStringKey("Privacy Flight Recorder"))
            .onAppear { checkedAt = Date() }
#endif
    }

    private var formBody: some View {
        Form {
            Section(LocalizedStringKey("Flight Summary")) {
                PrivacyFlightStatusRow(
                    title: LocalizedStringKey("Privacy Mode"),
                    value: offGrid ? String(localized: "Off-grid") : String(localized: "Standard"),
                    systemImage: offGrid ? "wifi.slash" : "wifi",
                    tint: offGrid ? .green : .secondary
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
    }

#if os(macOS)
    // MARK: - macOS industrial layout

    private var macBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MacPrivacyCard(LocalizedStringKey("Flight Summary")) {
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Privacy Mode"),
                        value: offGrid ? String(localized: "Off-grid") : String(localized: "Standard"),
                        systemImage: offGrid ? "wifi.slash" : "wifi",
                        tint: offGrid ? .green : .secondary,
                        divider: false
                    )
                    MacPrivacyKeyValueRow(title: LocalizedStringKey("Network Kill Switch"), value: NetworkKillSwitch.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    MacPrivacyKeyValueRow(title: LocalizedStringKey("Active Runtime"), value: runtimeValue)
                    MacPrivacyKeyValueRow(title: LocalizedStringKey("Active Model"), value: activeModelValue)
                    MacPrivacyKeyValueRow(title: LocalizedStringKey("Active Dataset"), value: activeDatasetValue)
                    MacPrivacyKeyValueRow(title: LocalizedStringKey("Checked"), value: checkedAt.formatted(date: .abbreviated, time: .standard))
                }

                MacPrivacyCard(LocalizedStringKey("Local Surfaces")) {
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Local Model Execution"),
                        value: activeLocalModel == nil ? String(localized: "Idle") : String(localized: "Local"),
                        systemImage: "cpu",
                        tint: activeLocalModel == nil ? .secondary : .green,
                        divider: false
                    )
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Dataset Retrieval"),
                        value: activeDataset == nil ? String(localized: "Inactive") : String(localized: "Local"),
                        systemImage: "doc.text.magnifyingglass",
                        tint: activeDataset == nil ? .secondary : .green
                    )
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Persistent Memory"),
                        value: settings.memoryEnabled ? String(localized: "Local") : String(localized: "Off"),
                        systemImage: "square.stack.3d.up",
                        tint: settings.memoryEnabled ? .green : .secondary
                    )
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Python Sandbox"),
                        value: settings.pythonEnabled ? String(localized: "Local") : String(localized: "Off"),
                        systemImage: "terminal",
                        tint: settings.pythonEnabled ? .green : .secondary
                    )
                }

                MacPrivacyCard(LocalizedStringKey("Network-Capable Surfaces")) {
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Web Search"),
                        value: networkSurfaceValue(enabled: settings.webSearchEnabled),
                        systemImage: "magnifyingglass",
                        tint: networkSurfaceTint(enabled: settings.webSearchEnabled),
                        divider: false
                    )
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Remote Backends"),
                        value: remoteBackendValue,
                        systemImage: "network",
                        tint: remoteBackendTint
                    )
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Downloads and Explore"),
                        value: offGrid ? String(localized: "Blocked") : String(localized: "Allowed"),
                        systemImage: "arrow.down.circle",
                        tint: offGrid ? .green : .orange
                    )
                    MacPrivacyStatusRow(
                        title: LocalizedStringKey("Wallet Signing"),
                        value: offGrid ? String(localized: "Blocked") : String(localized: "Allowed"),
                        systemImage: "wallet.pass",
                        tint: offGrid ? .green : .orange
                    )
                }

                MacPrivacyCard(LocalizedStringKey("Off-Grid Proof Drill")) {
                    MacPrivacyActionRow(divider: false) {
                        Button {
                            runProofDrill()
                        } label: {
                            Label(LocalizedStringKey("Run Proof Drill"), systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.industrial(.prominent))
                    }

                    if drillResults.isEmpty {
                        MacPrivacyNoteRow(LocalizedStringKey("Run the drill to verify external network paths are blocked while loopback and local paths remain available."))
                    } else {
                        ForEach(drillResults) { result in
                            MacPrivacyDrillRow(result: result)
                        }
                    }
                }

                MacPrivacyCard(LocalizedStringKey("Recent Blocked Attempts")) {
                    let attempts = Array(NetworkKillSwitch.recentBlockedAttempts.prefix(8))
                    if attempts.isEmpty {
                        MacPrivacyNoteRow(LocalizedStringKey("No blocked network attempts recorded"), divider: false)
                    } else {
                        ForEach(Array(attempts.enumerated()), id: \.element.id) { index, attempt in
                            MacPrivacyBlockedAttemptRow(attempt: attempt, divider: index != 0)
                        }
                        MacPrivacyActionRow {
                            Button(role: .destructive) {
                                NetworkKillSwitch.clearBlockedAttempts()
                                checkedAt = Date()
                            } label: {
                                Label(LocalizedStringKey("Clear Blocked Attempts"), systemImage: "trash")
                            }
                            .buttonStyle(.industrial(.destructive))
                        }
                    }
                }

                MacPrivacyCard(LocalizedStringKey("Remote Session")) {
                    if let remote = modelManager.activeRemoteSession {
                        MacPrivacyKeyValueRow(title: LocalizedStringKey("Backend"), value: remote.backendName, divider: false)
                        MacPrivacyKeyValueRow(title: LocalizedStringKey("Model"), value: remote.modelName)
                        MacPrivacyKeyValueRow(title: LocalizedStringKey("Endpoint"), value: remote.endpointType.displayName)
                        MacPrivacyKeyValueRow(title: LocalizedStringKey("Transport"), value: remote.transport.label)
                    } else {
                        MacPrivacyNoteRow(LocalizedStringKey("No remote session is active"), divider: false)
                    }
                }

                MacPrivacyCard(LocalizedStringKey("Privacy Export")) {
                    MacPrivacyActionRow(divider: false) {
                        HStack(spacing: 8) {
                            Button {
                                generateExport()
                            } label: {
                                Label(LocalizedStringKey("Generate Privacy JSON"), systemImage: "doc.badge.gearshape")
                            }
                            .buttonStyle(.industrial(.tinted))

                            if let exportURL {
                                ShareLink(item: exportURL) {
                                    Label(LocalizedStringKey("Share Privacy JSON"), systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.industrial(.quiet))
                            }
                        }
                    }

                    if let exportURL {
                        MacPrivacyKeyValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                    }
                    if let exportError {
                        MacPrivacyKeyValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(AppTheme.windowBackground.ignoresSafeArea())
    }
#endif

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

private struct PrivacyStatusDot: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

private struct PrivacyFlightStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            HStack(spacing: 7) {
                PrivacyStatusDot(tint: tint)
                Text(verbatim: value)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
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
                HStack(spacing: 7) {
                    PrivacyStatusDot(tint: result.tint)
                    Text(verbatim: result.status)
                        .font(.subheadline.weight(.medium))
                }
                Text(verbatim: result.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Label {
                Text(result.title)
            } icon: {
                Image(systemName: result.systemImage)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PrivacyBlockedAttemptRow: View {
    let attempt: NetworkBlockedAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: attempt.host)
                        .font(.body.weight(.medium))
                } icon: {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(attempt.blockedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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

#if os(macOS)
// MARK: - macOS industrial rows

/// A bordered section card in the Mac industrial dialect: an
/// `IndustrialSectionHeader` over hairline-separated rows. Rows opt out of their
/// leading hairline with `divider: false` so the first row sits flush under the
/// header's own hairline.
private struct MacPrivacyCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IndustrialSectionHeader(title)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MacPrivacyKeyValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text(verbatim: value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 8)
        }
    }
}

private struct MacPrivacyStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    var tint: Color = .secondary
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .frame(width: 18)
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                IndustrialBadge(verbatim: value, tint: tint, dot: true)
            }
            .padding(.vertical, 8)
        }
    }
}

private struct MacPrivacyDrillRow: View {
    let result: PrivacyProofDrillResult
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: result.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                    Text(verbatim: result.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                IndustrialBadge(verbatim: result.status, tint: result.tint, dot: true)
            }
            .padding(.vertical, 8)
        }
    }
}

private struct MacPrivacyBlockedAttemptRow: View {
    let attempt: NetworkBlockedAttempt
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.4))
                    Text(verbatim: attempt.host)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.7))
                    Spacer(minLength: 8)
                    Text(attempt.blockedAt, style: .time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .monospacedDigit()
                }
                Text(verbatim: attempt.urlString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 8)
        }
    }
}

private struct MacPrivacyNoteRow: View {
    let text: LocalizedStringKey
    var divider: Bool = true

    init(_ text: LocalizedStringKey, divider: Bool = true) {
        self.text = text
        self.divider = divider
    }

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
    }
}

private struct MacPrivacyActionRow<Content: View>: View {
    var divider: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }
}
#endif
