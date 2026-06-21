import SwiftUI
import NoemaPackages

struct LoopbackServerHealthSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openHealth: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(statusTint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Loopback Health"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openHealth) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Loopback Health"))
            }

            HStack(spacing: 8) {
                LoopbackHealthPill(title: LocalizedStringKey("Port"), value: portValue)
                LoopbackHealthPill(title: LocalizedStringKey("Bridge"), value: bridgeValue)
                LoopbackHealthPill(title: LocalizedStringKey("Probe"), value: probeValue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openHealth)
    }

    private var summaryLine: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else { return String(localized: "Loopback server is not running") }
        if LlamaServerBridge.isLoading() {
            let progress = Int((LlamaServerBridge.loadProgress() * 100).rounded())
            return String.localizedStringWithFormat(String(localized: "Port %d, loading %d%%"), port, progress)
        }
        if let diagnostics = LlamaServerBridge.lastStartDiagnostics(), !diagnostics.httpReady {
            return diagnostics.message
        }
        return String.localizedStringWithFormat(String(localized: "Port %d, ready"), port)
    }

    private var statusIcon: String {
        let port = Int(LlamaServerBridge.port())
        if port <= 0 { return "server.rack" }
        if LlamaServerBridge.isLoading() { return "hourglass.circle.fill" }
        if LlamaServerBridge.lastStartDiagnostics()?.httpReady == false { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusTint: Color {
        let port = Int(LlamaServerBridge.port())
        if port <= 0 { return .secondary }
        if LlamaServerBridge.isLoading() { return .orange }
        if LlamaServerBridge.lastStartDiagnostics()?.httpReady == false { return .red }
        return .green
    }

    private var portValue: String {
        let port = Int(LlamaServerBridge.port())
        return port > 0 ? "\(port)" : String(localized: "Off")
    }

    private var bridgeValue: String {
        if LlamaServerBridge.isLoading() { return String(localized: "Loading") }
        return Int(LlamaServerBridge.port()) > 0 ? String(localized: "Ready") : String(localized: "Off")
    }

    private var probeValue: String {
        guard let diagnostics = LlamaServerBridge.lastStartDiagnostics() else {
            return String(localized: "Unknown")
        }
        return diagnostics.httpReady ? String(localized: "Ready") : String(localized: "Failed")
    }
}

struct LoopbackServerHealthView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var chatVM: ChatVM
    @State private var probeResult: LoopbackHealthProbeResult?
    @State private var isProbing = false
    @State private var checkedAt = Date()
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Server Status")) {
                LoopbackHealthStatusRow(
                    title: LocalizedStringKey("Bridge State"),
                    value: bridgeStateValue,
                    systemImage: bridgeStatusIcon,
                    tint: bridgeTint
                )
                LoopbackHealthValueRow(title: LocalizedStringKey("Loopback Port"), value: portValue)
                LoopbackHealthValueRow(title: LocalizedStringKey("Load Progress"), value: loadProgressValue)
                LoopbackHealthValueRow(title: LocalizedStringKey("Current Model"), value: currentModelValue)
                LoopbackHealthValueRow(title: LocalizedStringKey("Last Checked"), value: checkedAt.formatted(date: .omitted, time: .standard))
            }

            Section(LocalizedStringKey("HTTP Probe")) {
                LoopbackHealthStatusRow(
                    title: LocalizedStringKey("Health Endpoint"),
                    value: healthEndpointValue,
                    systemImage: healthEndpointIcon,
                    tint: healthEndpointTint
                )
                LoopbackHealthValueRow(title: LocalizedStringKey("Probe URL"), value: probeResult?.urlString ?? baseURLValue)
                LoopbackHealthValueRow(title: LocalizedStringKey("HTTP Status"), value: httpStatusValue)
                LoopbackHealthValueRow(title: LocalizedStringKey("Latency"), value: latencyValue)
                Button {
                    runProbe()
                } label: {
                    Label(isProbing ? LocalizedStringKey("Checking Health") : LocalizedStringKey("Check Health"), systemImage: "arrow.clockwise")
                }
                .disabled(isProbing || Int(LlamaServerBridge.port()) <= 0)
            }

            Section(LocalizedStringKey("Last Start Diagnostics")) {
                if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
                    LoopbackHealthValueRow(title: LocalizedStringKey("Code"), value: diagnostics.code)
                    LoopbackHealthValueRow(title: LocalizedStringKey("Message"), value: diagnostics.message)
                    LoopbackHealthValueRow(title: LocalizedStringKey("HTTP Ready"), value: diagnostics.httpReady ? String(localized: "Ready") : String(localized: "Failed"))
                    LoopbackHealthValueRow(title: LocalizedStringKey("Last HTTP Status"), value: diagnostics.lastHTTPStatus.map(String.init) ?? "--")
                    LoopbackHealthValueRow(title: LocalizedStringKey("Elapsed"), value: String.localizedStringWithFormat(String(localized: "%d ms"), diagnostics.elapsedMs))
                } else {
                    Text(LocalizedStringKey("No start diagnostics recorded"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Start Options")) {
                if let options = LlamaServerBridge.lastStartOptions() {
                    LoopbackHealthValueRow(title: LocalizedStringKey("GGUF File"), value: URL(fileURLWithPath: options.ggufPath).lastPathComponent)
                    LoopbackHealthValueRow(title: LocalizedStringKey("Projector File"), value: options.mmprojPath.isEmpty ? String(localized: "None") : URL(fileURLWithPath: options.mmprojPath).lastPathComponent)
                    LoopbackHealthValueRow(title: LocalizedStringKey("MTP File"), value: options.mtpPath.isEmpty ? String(localized: "None") : URL(fileURLWithPath: options.mtpPath).lastPathComponent)
                    LoopbackHealthValueRow(title: LocalizedStringKey("Speculative Type"), value: options.speculativeType.isEmpty ? String(localized: "Off") : options.speculativeType)
                    LoopbackHealthValueRow(title: LocalizedStringKey("Argument Count"), value: "\(options.argv.count)")
                } else {
                    Text(LocalizedStringKey("No start options recorded"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Health Export")) {
                Button {
                    generateExport()
                } label: {
                    Label(LocalizedStringKey("Generate Health JSON"), systemImage: "doc.badge.gearshape")
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share Health JSON"), systemImage: "square.and.arrow.up")
                    }
                    LoopbackHealthValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                }

                if let exportError {
                    LoopbackHealthValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Loopback Health"))
        .task {
            if Int(LlamaServerBridge.port()) > 0 {
                await probeHealth()
            }
        }
    }

    private var currentModelValue: String {
        if let url = chatVM.loadedModelURL,
           let model = modelManager.downloadedModels.first(where: { $0.url == url || $0.url.path == url.path }) {
            return model.name
        }
        if let model = modelManager.loadedModel {
            return model.name
        }
        if let url = chatVM.loadedModelURL {
            return url.lastPathComponent
        }
        return String(localized: "No local model loaded")
    }

    private var portValue: String {
        let port = Int(LlamaServerBridge.port())
        return port > 0 ? "\(port)" : String(localized: "Not running")
    }

    private var bridgeStateValue: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else { return String(localized: "Not running") }
        if LlamaServerBridge.isLoading() { return String(localized: "Loading") }
        return String(localized: "Ready")
    }

    private var bridgeStatusIcon: String {
        let port = Int(LlamaServerBridge.port())
        if port <= 0 { return "server.rack" }
        return LlamaServerBridge.isLoading() ? "hourglass.circle.fill" : "checkmark.circle.fill"
    }

    private var bridgeTint: Color {
        let port = Int(LlamaServerBridge.port())
        if port <= 0 { return .secondary }
        return LlamaServerBridge.isLoading() ? .orange : .green
    }

    private var loadProgressValue: String {
        let progress = Int((LlamaServerBridge.loadProgress() * 100).rounded())
        return "\(progress)%"
    }

    private var baseURLValue: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else { return String(localized: "Unavailable") }
        return "http://127.0.0.1:\(port)"
    }

    private var healthEndpointValue: String {
        if isProbing { return String(localized: "Checking") }
        guard let probeResult else { return String(localized: "Not checked") }
        if probeResult.ready { return String(localized: "Ready") }
        if let status = probeResult.statusCode {
            return String.localizedStringWithFormat(String(localized: "HTTP %d"), status)
        }
        return String(localized: "Unreachable")
    }

    private var healthEndpointIcon: String {
        if isProbing { return "hourglass.circle.fill" }
        guard let probeResult else { return "questionmark.circle" }
        return probeResult.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var healthEndpointTint: Color {
        if isProbing { return .orange }
        guard let probeResult else { return .secondary }
        return probeResult.ready ? .green : .red
    }

    private var httpStatusValue: String {
        probeResult?.statusCode.map(String.init) ?? "--"
    }

    private var latencyValue: String {
        guard let elapsedMs = probeResult?.elapsedMs else { return "--" }
        return String.localizedStringWithFormat(String(localized: "%d ms"), elapsedMs)
    }

    private func runProbe() {
        Task { await probeHealth() }
    }

    @MainActor
    private func probeHealth() async {
        isProbing = true
        defer {
            isProbing = false
            checkedAt = Date()
        }
        probeResult = await LoopbackHealthProbe.run()
    }

    private func generateExport() {
        do {
            let data = try JSONSerialization.data(withJSONObject: exportPayload(), options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-loopback-health-\(Self.fileTimestamp()).json")
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
            "bridgeState": bridgeStateValue,
            "port": Int(LlamaServerBridge.port()),
            "loadProgress": LlamaServerBridge.loadProgress(),
            "currentModel": currentModelValue,
            "healthEndpoint": healthEndpointValue,
            "httpStatus": probeResult?.statusCode ?? 0,
            "latencyMs": probeResult?.elapsedMs ?? 0,
            "probeURL": probeResult?.urlString ?? ""
        ]

        if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
            payload["lastStartDiagnostics"] = [
                "code": diagnostics.code,
                "message": diagnostics.message,
                "lastHTTPStatus": diagnostics.lastHTTPStatus ?? 0,
                "elapsedMs": diagnostics.elapsedMs,
                "progress": diagnostics.progress,
                "httpReady": diagnostics.httpReady
            ]
        }

        if let options = LlamaServerBridge.lastStartOptions() {
            payload["startOptions"] = [
                "port": options.port,
                "ggufPath": options.ggufPath,
                "mmprojPath": options.mmprojPath,
                "mtpPath": options.mtpPath,
                "speculativeType": options.speculativeType,
                "argv": options.argv
            ]
        }

        return payload
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct LoopbackHealthProbeResult {
    let ready: Bool
    let statusCode: Int?
    let elapsedMs: Int
    let urlString: String
}

private enum LoopbackHealthProbe {
    static func run() async -> LoopbackHealthProbeResult {
        let started = Date()
        let port = Int(LlamaServerBridge.port())
        guard port > 0, let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            return LoopbackHealthProbeResult(
                ready: false,
                statusCode: nil,
                elapsedMs: 0,
                urlString: ""
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 1.5
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var lastStatus: Int?
        var lastURL = baseURL.absoluteString
        for path in ["health", "v1/health", "v1/models"] {
            let url = baseURL.appendingPathComponent(path)
            lastURL = url.absoluteString
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 1.5
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    lastStatus = http.statusCode
                    let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1000))
                    if (200..<300).contains(http.statusCode) {
                        return LoopbackHealthProbeResult(
                            ready: true,
                            statusCode: http.statusCode,
                            elapsedMs: elapsed,
                            urlString: url.absoluteString
                        )
                    }
                }
            } catch {
                continue
            }
        }

        let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1000))
        return LoopbackHealthProbeResult(
            ready: false,
            statusCode: lastStatus,
            elapsedMs: elapsed,
            urlString: lastURL
        )
    }
}

private struct LoopbackHealthPill: View {
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

private struct LoopbackHealthStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct LoopbackHealthValueRow: View {
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
