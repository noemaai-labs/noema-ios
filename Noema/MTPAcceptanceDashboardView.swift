import SwiftUI
import NoemaPackages

struct MTPAcceptanceDashboardSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openDashboard: () -> Void

    private struct Summary: Equatable {
        var mtpCapable = 0
        var configured = 0
        var running = false
    }
    @State private var summary = Summary()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("MTP Dashboard"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openDashboard) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open MTP Dashboard"))
            }

            HStack(spacing: 8) {
                MTPDashboardPill(title: LocalizedStringKey("Installed"), value: "\(summary.mtpCapable)")
                MTPDashboardPill(title: LocalizedStringKey("Configured"), value: "\(summary.configured)")
                MTPDashboardPill(title: LocalizedStringKey("Running"), value: runningValue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openDashboard)
        .task(id: modelSignature) { await refresh() }
    }

    private var modelSignature: String {
        modelManager.downloadedModels
            .filter { $0.format == .gguf }
            .map(\.url.path)
            .joined(separator: "|")
    }

    // Warm the GGUF metadata cache off the main thread, then tally on-main.
    @MainActor
    private func refresh() async {
        let gguf = modelManager.downloadedModels.filter { $0.format == .gguf }
        let urls = gguf.map(\.url)
        await Task.detached(priority: .utility) {
            for url in urls { GGUFMetadata.prewarm(at: url) }
        }.value
        guard !Task.isCancelled else { return }
        var result = Summary()
        result.mtpCapable = gguf.filter {
            MtpLocator.hasMtpFile(alongside: $0.url) || GGUFMetadata.hasMTP(at: $0.url)
        }.count
        result.configured = gguf.filter {
            modelManager.settings(for: $0).speculativeDecoding.mtpEnabled
        }.count
        let options = LlamaServerBridge.lastStartOptions()
        result.running = options?.speculativeType == "draft-mtp"
        summary = result
    }

    private var runningValue: String {
        summary.running ? String(localized: "On") : String(localized: "Off")
    }

    private var summaryLine: String {
        if summary.mtpCapable == 0 {
            return String(localized: "No MTP-capable GGUF models detected")
        }
        let format = String(localized: "%d MTP-capable models installed")
        return String.localizedStringWithFormat(format, summary.mtpCapable)
    }
}

struct MTPAcceptanceDashboardView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var chatVM: ChatVM
    @State private var latestResponse: LoopbackResponseDiagnostics?
    @State private var checkedAt = Date()
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        platformContent
            .task { await refreshLatestResponse() }
    }

    private var platformContent: some View {
#if os(macOS)
        // The iOS Form renders badly inside the Mac settings sheet (clipped
        // labels, wrong insets, stock buttons); the sheet already supplies the
        // title + close, so macOS gets the industrial card layout with no
        // navigationTitle.
        macBody
#else
        formBody
            .navigationTitle(LocalizedStringKey("MTP Dashboard"))
#endif
    }

    private var formBody: some View {
        Form {
            Section(LocalizedStringKey("MTP Acceptance")) {
                MTPMetricRow(title: LocalizedStringKey("Draft Tokens"), value: draftTokenValue, systemImage: "bolt.fill", tint: .orange)
                MTPMetricRow(title: LocalizedStringKey("Accepted Tokens"), value: acceptedTokenValue, systemImage: "checkmark.seal.fill", tint: .green)
                MTPMetricRow(title: LocalizedStringKey("Acceptance Rate"), value: acceptanceRateValue, systemImage: "percent", tint: acceptanceTint)
                MTPMetricRow(title: LocalizedStringKey("Draft Yield"), value: draftYieldValue, systemImage: "speedometer", tint: .blue)
            }

            Section(LocalizedStringKey("Current MTP Run")) {
                MTPValueRow(title: LocalizedStringKey("Running Mode"), value: runningModeValue)
                MTPValueRow(title: LocalizedStringKey("Auto Draft Length"), value: autoDraftLengthValue)
                MTPValueRow(title: LocalizedStringKey("Draft Source"), value: draftSourceValue)
                MTPValueRow(title: LocalizedStringKey("Prompt Rate"), value: promptRateValue)
                MTPValueRow(title: LocalizedStringKey("Generation Rate"), value: generationRateValue)
                MTPValueRow(title: LocalizedStringKey("Last Response"), value: lastResponseValue)
                Button {
                    refresh()
                } label: {
                    Label(LocalizedStringKey("Refresh MTP Metrics"), systemImage: "arrow.clockwise")
                }
            }

            Section(LocalizedStringKey("MTP Guidance")) {
                ForEach(Array(guidanceRows.enumerated()), id: \.offset) { _, row in
                    Label(row, systemImage: "lightbulb")
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Installed MTP Models")) {
                if mtpRows.isEmpty {
                    Text(LocalizedStringKey("No MTP-capable GGUF models detected"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mtpRows) { row in
                        MTPInstalledModelRow(row: row)
                    }
                }
            }

            Section(LocalizedStringKey("MTP Export")) {
                Button {
                    generateExport()
                } label: {
                    Label(LocalizedStringKey("Generate MTP JSON"), systemImage: "doc.badge.gearshape")
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share MTP JSON"), systemImage: "square.and.arrow.up")
                    }
                    MTPValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                }

                if let exportError {
                    MTPValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                }
            }
        }
    }

#if os(macOS)
    private var macBody: some View {
        MacSettingsPage {
            MacSettingsCard(LocalizedStringKey("MTP Acceptance")) {
                MacSettingsStatusRow(title: LocalizedStringKey("Draft Tokens"), value: draftTokenValue, systemImage: "bolt.fill", tint: .orange, divider: false)
                MacSettingsStatusRow(title: LocalizedStringKey("Accepted Tokens"), value: acceptedTokenValue, systemImage: "checkmark.seal.fill", tint: .green)
                MacSettingsStatusRow(title: LocalizedStringKey("Acceptance Rate"), value: acceptanceRateValue, systemImage: "percent", tint: acceptanceTint)
                MacSettingsStatusRow(title: LocalizedStringKey("Draft Yield"), value: draftYieldValue, systemImage: "speedometer", tint: .blue)
            }

            MacSettingsCard(LocalizedStringKey("Current MTP Run")) {
                MacSettingsKeyValueRow(title: LocalizedStringKey("Running Mode"), value: runningModeValue, divider: false)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Auto Draft Length"), value: autoDraftLengthValue)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Draft Source"), value: draftSourceValue)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Prompt Rate"), value: promptRateValue)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Generation Rate"), value: generationRateValue)
                MacSettingsKeyValueRow(title: LocalizedStringKey("Last Response"), value: lastResponseValue)
                MacSettingsActionRow {
                    Button {
                        refresh()
                    } label: {
                        Label(LocalizedStringKey("Refresh MTP Metrics"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.industrial(.prominent))
                }
            }

            MacSettingsCard(LocalizedStringKey("MTP Guidance")) {
                ForEach(Array(guidanceRows.enumerated()), id: \.offset) { index, row in
                    MacSettingsNoteRow(row, divider: index != 0)
                }
            }

            MacSettingsCard(LocalizedStringKey("Installed MTP Models")) {
                if mtpRows.isEmpty {
                    MacSettingsNoteRow(LocalizedStringKey("No MTP-capable GGUF models detected"), divider: false)
                } else {
                    ForEach(Array(mtpRows.enumerated()), id: \.element.id) { index, row in
                        MacMTPInstalledModelRow(row: row, divider: index != 0)
                    }
                }
            }

            MacSettingsCard(LocalizedStringKey("MTP Export")) {
                MacSettingsActionRow(divider: false) {
                    Button {
                        generateExport()
                    } label: {
                        Label(LocalizedStringKey("Generate MTP JSON"), systemImage: "doc.badge.gearshape")
                    }
                    .buttonStyle(.industrial(.tinted))

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label(LocalizedStringKey("Share MTP JSON"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.industrial(.quiet))
                    }
                }

                if let exportURL {
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                }
                if let exportError {
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                }
            }
        }
    }
#endif

    private var timings: LoopbackSpeculativeTimings? {
        guard latestResponse?.speculativeType == "draft-mtp",
              latestResponse?.timings?.speculativeType == "draft-mtp" else { return nil }
        return latestResponse?.timings
    }

    private var activeLocalModel: LocalModel? {
        if let modelIdentifier = latestResponse?.modelIdentifier,
           let responseModel = modelManager.downloadedModels.first(where: {
               $0.url.path == modelIdentifier || $0.modelID == modelIdentifier
           }) {
            return responseModel
        }
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var draftTokenValue: String {
        guard let draft = timings?.draftN else { return "--" }
        return NumberFormatter.localizedString(from: NSNumber(value: draft), number: .decimal)
    }

    private var acceptedTokenValue: String {
        guard let accepted = timings?.draftNAccepted else { return "--" }
        return NumberFormatter.localizedString(from: NSNumber(value: accepted), number: .decimal)
    }

    private var acceptanceRateValue: String {
        guard let rate = timings?.acceptanceRate else { return "--" }
        return String.localizedStringWithFormat(String(localized: "%.0f%%"), rate * 100)
    }

    private var acceptanceTint: Color {
        guard let rate = timings?.acceptanceRate else { return .secondary }
        if rate >= 0.70 { return .green }
        if rate >= 0.40 { return .orange }
        return .red
    }

    private var draftYieldValue: String {
        guard let timings, let draft = timings.draftN, draft > 0 else { return "--" }
        let accepted = timings.draftNAccepted ?? 0
        let rejected = max(0, draft - accepted)
        if accepted == 0 { return String(localized: "No accepted drafts") }
        return String.localizedStringWithFormat(String(localized: "+%d accepted, %d rejected"), accepted, rejected)
    }

    private var runningModeValue: String {
        guard latestResponse?.speculativeType == "draft-mtp" else {
            return String(localized: "MTP off")
        }
        switch timings?.speculativeState {
        case "disabled_for_request":
            return String(localized: "Disabled for this request")
        case "configured":
            return String(localized: "Configured")
        case "attempted_empty":
            return String(localized: "Attempted — no proposals")
        case "paused":
            return String(localized: "Paused")
        default:
            return "draft-mtp"
        }
    }

    private var autoDraftLengthValue: String {
        guard let dynLength = timings?.draftNDyn else {
            return String(localized: "Off")
        }
        return dynLength > 0 ? "\(dynLength)" : String(localized: "Paused")
    }

    private var draftSourceValue: String {
        guard let model = activeLocalModel else {
            return String(localized: "Unavailable")
        }
        if let path = MtpLocator.mtpPath(alongside: model.url) {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if GGUFMetadata.hasMTP(at: model.url) {
            return String(localized: "Embedded MTP head")
        }
        return String(localized: "Not installed")
    }

    private var promptRateValue: String {
        guard let rate = timings?.promptPerSecond else { return "--" }
        return String.localizedStringWithFormat(String(localized: "%.1f tok/s"), rate)
    }

    private var generationRateValue: String {
        guard let rate = timings?.predictedPerSecond else { return "--" }
        return String.localizedStringWithFormat(String(localized: "%.1f tok/s"), rate)
    }

    private var lastResponseValue: String {
        guard let latestResponse else { return String(localized: "No response recorded") }
        return latestResponse.completedAt.formatted(date: .abbreviated, time: .standard)
    }

    private var guidanceRows: [LocalizedStringKey] {
        if timings?.draftN == nil {
            return [
                LocalizedStringKey("Run a GGUF prompt with MTP enabled to collect acceptance metrics."),
                LocalizedStringKey("Use the Speculative Wizard if you need help choosing MTP or a helper model.")
            ]
        }
        guard let rate = timings?.acceptanceRate else {
            return [LocalizedStringKey("The backend returned draft counts without an acceptance rate.")]
        }
        if rate >= 0.70 {
            return [LocalizedStringKey("Draft acceptance is high; confirm the benefit with a plain benchmark.")]
        }
        if rate >= 0.40 {
            return [LocalizedStringKey("Acceptance is mixed; compare against a non-MTP benchmark before keeping it on.")]
        }
        return [LocalizedStringKey("Acceptance is low; disable MTP or try a better-matched draft head.")]
    }

    private var mtpRows: [MTPInstalledModel] {
        modelManager.downloadedModels
            .filter { $0.format == .gguf }
            .compactMap { model in
                let embedded = GGUFMetadata.hasMTP(at: model.url)
                let sidecar = MtpLocator.mtpPath(alongside: model.url)
                guard embedded || sidecar != nil else { return nil }
                let settings = modelManager.settings(for: model)
                return MTPInstalledModel(
                    id: model.id,
                    name: model.name,
                    detail: embedded ? String(localized: "Embedded MTP head") : URL(fileURLWithPath: sidecar ?? "").lastPathComponent,
                    configured: settings.speculativeDecoding.mtpEnabled
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refresh() {
        checkedAt = Date()
        exportError = nil
        Task { await refreshLatestResponse() }
    }

    @MainActor
    private func refreshLatestResponse() async {
        latestResponse = await LoopbackRuntimeDiagnostics.shared.latestResponseSnapshot()
        checkedAt = Date()
    }

    private func generateExport() {
        do {
            let data = try JSONSerialization.data(withJSONObject: exportPayload(), options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-mtp-dashboard-\(Self.fileTimestamp()).json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func exportPayload() -> [String: Any] {
        [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "checkedAt": ISO8601DateFormatter().string(from: checkedAt),
            "runningMode": runningModeValue,
            "draftSource": draftSourceValue,
            "draftTokens": timings?.draftN ?? 0,
            "acceptedTokens": timings?.draftNAccepted ?? 0,
            "draftAttempts": timings?.draftAttempts ?? 0,
            "emptyDraftAttempts": timings?.draftEmptyAttempts ?? 0,
            "draftMilliseconds": timings?.draftMS ?? 0,
            "verificationMilliseconds": timings?.draftVerificationMS ?? 0,
            "rollbackMilliseconds": timings?.draftRollbackMS ?? 0,
            "acceptedPerPosition": timings?.draftAcceptedPerPosition ?? [],
            "speculativeState": timings?.speculativeState ?? "unavailable",
            "acceptanceRate": timings?.acceptanceRate ?? 0,
            "promptRate": timings?.promptPerSecond ?? 0,
            "generationRate": timings?.predictedPerSecond ?? 0,
            "models": mtpRows.map(\.exportDictionary)
        ]
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct MTPDashboardPill: View {
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

private struct MTPMetricRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .font(.headline)
                .foregroundStyle(tint)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct MTPValueRow: View {
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

private struct MTPInstalledModel: Identifiable {
    let id: String
    let name: String
    let detail: String
    let configured: Bool

    var exportDictionary: [String: Any] {
        [
            "name": name,
            "detail": detail,
            "configured": configured
        ]
    }
}

private struct MTPInstalledModelRow: View {
    let row: MTPInstalledModel

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.configured ? LocalizedStringKey("Configured") : LocalizedStringKey("Available"))
                    .font(.caption)
                    .foregroundStyle(row.configured ? .green : .secondary)
                Text(verbatim: row.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } label: {
            Label(row.name, systemImage: row.configured ? "bolt.fill" : "bolt")
        }
    }
}

#if os(macOS)
private struct MacMTPInstalledModelRow: View {
    let row: MTPInstalledModel
    var divider: Bool = true

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.configured ? "bolt.fill" : "bolt")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: row.name)
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                    Text(verbatim: row.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                IndustrialBadge(
                    verbatim: row.configured ? String(localized: "Configured") : String(localized: "Available"),
                    tint: row.configured ? .green : .secondary,
                    dot: true
                )
            }
        }
    }
}
#endif
