import SwiftUI

struct ToolStoreSummaryContent: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var memoryStore: MemoryStore
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    @ObservedObject var datasetManager: DatasetManager
    let openStore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Tool Store"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openStore) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Tool Store"))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], alignment: .leading, spacing: 8) {
                ToolStorePill(title: LocalizedStringKey("Web"), value: settings.webSearchEnabled ? String(localized: "On") : String(localized: "Off"))
                ToolStorePill(title: LocalizedStringKey("Python"), value: settings.pythonEnabled ? String(localized: "On") : String(localized: "Off"))
                ToolStorePill(title: LocalizedStringKey("Memory"), value: settings.memoryEnabled ? String(localized: "On") : String(localized: "Off"))
                ToolStorePill(title: LocalizedStringKey("Datasets"), value: settings.datasetSearchToolEnabled ? String(localized: "On") : String(localized: "Off"))
                ToolStorePill(title: LocalizedStringKey("Charts"), value: settings.chartToolEnabled ? String(localized: "On") : String(localized: "Off"))
                ToolStorePill(title: LocalizedStringKey("PDF"), value: settings.pdfToolEnabled ? String(localized: "On") : String(localized: "Off"))
                ToolStorePill(title: LocalizedStringKey("Calendar"), value: settings.calendarToolEnabled ? String(localized: "On") : String(localized: "Off"))
                ToolStorePill(title: LocalizedStringKey("Math"), value: String(localized: "Always On"))
                ToolStorePill(title: LocalizedStringKey("Units"), value: String(localized: "Always On"))
                ToolStorePill(title: LocalizedStringKey("Dry Run"), value: settings.toolDryRunEnabled ? String(localized: "On") : String(localized: "Off"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openStore)
    }

    private var summaryText: String {
        var readiness = [
            ToolStoreModel.webStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager).isReady,
            ToolStoreModel.pythonStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager).isReady,
            ToolStoreModel.memoryStatus(settings: settings, chatVM: chatVM, modelManager: modelManager).isReady,
            settings.datasetSearchToolEnabled,
            settings.chartToolEnabled,
            settings.calendarToolEnabled,
            ToolStoreModel.calculatorStatus().isReady,
            ToolStoreModel.unitConverterStatus().isReady
        ]
        readiness.append(settings.pdfToolEnabled)
        let readyCount = readiness.filter { $0 }.count

        return String.localizedStringWithFormat(
            String(localized: "%1$d of %2$d tools ready"),
            readyCount, readiness.count
        )
    }
}

private struct ToolStorePill: View {
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

private struct ToolStoreToolRow: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var isOn: Binding<Bool>? = nil
    let status: ToolReadinessStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let isOn {
                    Toggle("", isOn: isOn)
                        .labelsHidden()
                } else {
                    Text(LocalizedStringKey("Always on"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: status.isReady ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status.isReady ? Color.green : Color.secondary)
                Text(verbatim: status.detail)
                    .font(.caption)
                    .foregroundStyle(status.isReady ? Color.green : Color.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ToolStoreView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var memoryStore = MemoryStore.shared
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager

    var body: some View {
#if os(macOS)
        macBody
#else
        formBody
            .navigationTitle(LocalizedStringKey("Tool Store"))
#endif
    }

    private var formBody: some View {
        Form {
            Section {
                Text(LocalizedStringKey("Tools let the model do more than chat — search the web, run Python, do math, or recall saved memories. Turn on the tools you want available, then arm them from the + button in a chat."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ToolStoreToolRow(
                    icon: "globe",
                    tint: .blue,
                    title: LocalizedStringKey("Web Search"),
                    detail: LocalizedStringKey("Look up current information online."),
                    isOn: webSearchEnabledBinding,
                    status: ToolStoreModel.webStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager)
                )
                ToolStoreToolRow(
                    icon: "terminal",
                    tint: .green,
                    title: LocalizedStringKey("Python"),
                    detail: LocalizedStringKey("Write and run code to compute or analyze."),
                    isOn: pythonEnabledBinding,
                    status: ToolStoreModel.pythonStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager)
                )
                ToolStoreToolRow(
                    icon: "brain",
                    tint: .purple,
                    title: LocalizedStringKey("Memory"),
                    detail: LocalizedStringKey("Remember useful facts across conversations."),
                    isOn: $settings.memoryEnabled,
                    status: ToolStoreModel.memoryStatus(settings: settings, chatVM: chatVM, modelManager: modelManager)
                )
                ToolStoreToolRow(
                    icon: "text.magnifyingglass",
                    tint: .indigo,
                    title: LocalizedStringKey("Dataset Search"),
                    detail: LocalizedStringKey("Search your indexed documents and knowledge packs."),
                    isOn: $settings.datasetSearchToolEnabled,
                    status: ToolStoreModel.localToolStatus(enabled: settings.datasetSearchToolEnabled)
                )
                ToolStoreToolRow(
                    icon: "chart.bar",
                    tint: .pink,
                    title: LocalizedStringKey("Charts"),
                    detail: LocalizedStringKey("Draw charts from data and show them in chat."),
                    isOn: $settings.chartToolEnabled,
                    status: ToolStoreModel.localToolStatus(enabled: settings.chartToolEnabled)
                )
                ToolStoreToolRow(
                    icon: "doc.richtext",
                    tint: .red,
                    title: LocalizedStringKey("PDF Reader"),
                    detail: LocalizedStringKey("Read attached PDFs page by page."),
                    isOn: $settings.pdfToolEnabled,
                    status: ToolStoreModel.localToolStatus(enabled: settings.pdfToolEnabled)
                )
                ToolStoreToolRow(
                    icon: "calendar",
                    tint: .cyan,
                    title: LocalizedStringKey("Calendar"),
                    detail: LocalizedStringKey("Read upcoming events and add new ones, with your permission."),
                    isOn: $settings.calendarToolEnabled,
                    status: ToolStoreModel.localToolStatus(enabled: settings.calendarToolEnabled)
                )
                ToolStoreToolRow(
                    icon: "function",
                    tint: .orange,
                    title: LocalizedStringKey("Calculator"),
                    detail: LocalizedStringKey("Evaluate math expressions exactly."),
                    isOn: nil,
                    status: ToolStoreModel.calculatorStatus()
                )
                ToolStoreToolRow(
                    icon: "arrow.left.arrow.right",
                    tint: .teal,
                    title: LocalizedStringKey("Unit Converter"),
                    detail: LocalizedStringKey("Convert between units of measure."),
                    isOn: nil,
                    status: ToolStoreModel.unitConverterStatus()
                )
            } header: {
                Text(LocalizedStringKey("Tools"))
            } footer: {
                Text(LocalizedStringKey("Math and unit conversion are always available. The model only uses a tool when it helps answer your message."))
            }
        }
    }

#if os(macOS)
    private var macBody: some View {
        MacSettingsPage {
            MacSettingsCard(LocalizedStringKey("Tools")) {
                MacSettingsNoteRow(LocalizedStringKey("Tools let the model do more than chat — search the web, run Python, do math, or recall saved memories. Turn on the tools you want available, then arm them from the + button in a chat."), divider: false)

                Group {
                    MacToolStoreRow(
                        icon: "globe",
                        tint: .blue,
                        title: LocalizedStringKey("Web Search"),
                        detail: LocalizedStringKey("Look up current information online."),
                        isOn: webSearchEnabledBinding,
                        status: ToolStoreModel.webStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager)
                    )
                    MacToolStoreRow(
                        icon: "terminal",
                        tint: .green,
                        title: LocalizedStringKey("Python"),
                        detail: LocalizedStringKey("Write and run code to compute or analyze."),
                        isOn: pythonEnabledBinding,
                        status: ToolStoreModel.pythonStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager)
                    )
                    MacToolStoreRow(
                        icon: "brain",
                        tint: .purple,
                        title: LocalizedStringKey("Memory"),
                        detail: LocalizedStringKey("Remember useful facts across conversations."),
                        isOn: $settings.memoryEnabled,
                        status: ToolStoreModel.memoryStatus(settings: settings, chatVM: chatVM, modelManager: modelManager)
                    )
                    MacToolStoreRow(
                        icon: "text.magnifyingglass",
                        tint: .indigo,
                        title: LocalizedStringKey("Dataset Search"),
                        detail: LocalizedStringKey("Search your indexed documents and knowledge packs."),
                        isOn: $settings.datasetSearchToolEnabled,
                        status: ToolStoreModel.localToolStatus(enabled: settings.datasetSearchToolEnabled)
                    )
                    MacToolStoreRow(
                        icon: "chart.bar",
                        tint: .pink,
                        title: LocalizedStringKey("Charts"),
                        detail: LocalizedStringKey("Draw charts from data and show them in chat."),
                        isOn: $settings.chartToolEnabled,
                        status: ToolStoreModel.localToolStatus(enabled: settings.chartToolEnabled)
                    )
                    MacToolStoreRow(
                        icon: "doc.richtext",
                        tint: .red,
                        title: LocalizedStringKey("PDF Reader"),
                        detail: LocalizedStringKey("Read attached PDFs page by page."),
                        isOn: $settings.pdfToolEnabled,
                        status: ToolStoreModel.localToolStatus(enabled: settings.pdfToolEnabled)
                    )
                    MacToolStoreRow(
                        icon: "calendar",
                        tint: .cyan,
                        title: LocalizedStringKey("Calendar"),
                        detail: LocalizedStringKey("Read upcoming events and add new ones, with your permission."),
                        isOn: $settings.calendarToolEnabled,
                        status: ToolStoreModel.localToolStatus(enabled: settings.calendarToolEnabled)
                    )
                    MacToolStoreRow(
                        icon: "function",
                        tint: .orange,
                        title: LocalizedStringKey("Calculator"),
                        detail: LocalizedStringKey("Evaluate math expressions exactly."),
                        isOn: nil,
                        status: ToolStoreModel.calculatorStatus()
                    )
                    MacToolStoreRow(
                        icon: "arrow.left.arrow.right",
                        tint: .teal,
                        title: LocalizedStringKey("Unit Converter"),
                        detail: LocalizedStringKey("Convert between units of measure."),
                        isOn: nil,
                        status: ToolStoreModel.unitConverterStatus()
                    )
                }

                MacSettingsNoteRow(LocalizedStringKey("Math and unit conversion are always available. The model only uses a tool when it helps answer your message."))
            }
        }
    }
#endif

    private var webSearchEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.webSearchEnabled },
            set: { enabled in
                settings.webSearchEnabled = enabled
                if !enabled {
                    settings.webSearchArmed = false
                }
            }
        )
    }

    private var pythonEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.pythonEnabled },
            set: { enabled in
                settings.pythonEnabled = enabled
                if !enabled {
                    settings.pythonArmed = false
                }
            }
        )
    }

}

#if os(macOS)
/// A tool row in the Mac industrial dialect: icon chip, mono-caps title over a
/// muted description, a switch (or an "Always on" badge), and a readiness line.
private struct MacToolStoreRow: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var isOn: Binding<Bool>? = nil
    let status: ToolReadinessStatus
    var divider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if divider { IndustrialHairline() }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .textCase(.uppercase)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(Color.primary.opacity(0.75))
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    if let isOn {
                        Toggle("", isOn: isOn)
                            .toggleStyle(IndustrialToggleStyle())
                    } else {
                        IndustrialBadge(LocalizedStringKey("Always on"), tint: .secondary)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: status.isReady ? "checkmark.circle.fill" : "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(status.isReady ? Color.green : Color.primary.opacity(0.4))
                    Text(verbatim: status.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(status.isReady ? Color.green : Color.primary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
        }
    }
}
#endif

private struct ToolReadinessStatus: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let detail: String
    let icon: String
    let tint: Color
    let isReady: Bool
}

@MainActor
private enum ToolStoreModel {
    static func webStatus(settings: SettingsStore, chatVM: ChatVM, modelManager: AppModelManager, datasetManager: DatasetManager) -> ToolReadinessStatus {
        status(
            id: "web",
            title: LocalizedStringKey("Web Search"),
            ready: WebToolGate.isAvailable(currentFormat: currentFormat(chatVM: chatVM, modelManager: modelManager)),
            iconReady: "globe",
            iconBlocked: "globe.badge.xmark",
            detail: webDetail(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager)
        )
    }

    static func pythonStatus(settings: SettingsStore, chatVM: ChatVM, modelManager: AppModelManager, datasetManager: DatasetManager) -> ToolReadinessStatus {
        status(
            id: "python",
            title: LocalizedStringKey("Python"),
            ready: PythonToolGate.isAvailable(currentFormat: currentFormat(chatVM: chatVM, modelManager: modelManager)),
            iconReady: "terminal",
            iconBlocked: "terminal",
            detail: pythonDetail(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager)
        )
    }

    static func memoryStatus(settings: SettingsStore, chatVM: ChatVM, modelManager: AppModelManager) -> ToolReadinessStatus {
        status(
            id: "memory",
            title: LocalizedStringKey("Memory"),
            ready: MemoryToolGate.isAvailable(currentFormat: currentFormat(chatVM: chatVM, modelManager: modelManager)),
            iconReady: "brain",
            iconBlocked: "brain",
            detail: memoryDetail(settings: settings, chatVM: chatVM, modelManager: modelManager)
        )
    }

    static func calculatorStatus() -> ToolReadinessStatus {
        status(
            id: "calculator",
            title: LocalizedStringKey("Calculator"),
            ready: true,
            iconReady: "function",
            iconBlocked: "function",
            detail: String(localized: "Local deterministic"),
            tintReady: .green
        )
    }

    static func unitConverterStatus() -> ToolReadinessStatus {
        status(
            id: "unit-converter",
            title: LocalizedStringKey("Unit Converter"),
            ready: true,
            iconReady: "arrow.left.arrow.right",
            iconBlocked: "arrow.left.arrow.right",
            detail: String(localized: "Local deterministic"),
            tintReady: .green
        )
    }

    /// On-device tools (dataset search, charts, PDF reading, calendar) are ready
    /// whenever their master toggle is on — they run fully locally.
    static func localToolStatus(enabled: Bool) -> ToolReadinessStatus {
        status(
            id: "local-tool",
            title: LocalizedStringKey("On-device"),
            ready: enabled,
            iconReady: "checkmark.circle.fill",
            iconBlocked: "circle",
            detail: enabled ? String(localized: "Ready") : String(localized: "Disabled in Settings")
        )
    }

    private static func status(
        id: String,
        title: LocalizedStringKey,
        ready: Bool,
        iconReady: String,
        iconBlocked: String,
        detail: String,
        tintReady: Color = .green
    ) -> ToolReadinessStatus {
        ToolReadinessStatus(
            id: id,
            title: title,
            detail: detail,
            icon: ready ? iconReady : iconBlocked,
            tint: ready ? tintReady : .secondary,
            isReady: ready
        )
    }

    private static func currentFormat(chatVM: ChatVM, modelManager: AppModelManager) -> ModelFormat? {
        chatVM.loadedModelFormat ?? modelManager.loadedModel?.format
    }

    private static var datasetActiveOrIndexing: Bool {
        let defaults = UserDefaults.standard
        let selectedDatasetID = defaults.string(forKey: "selectedDatasetID") ?? ""
        let indexingDatasetID = defaults.string(forKey: "indexingDatasetIDPersisted") ?? ""
        return !selectedDatasetID.isEmpty || !indexingDatasetID.isEmpty
    }

    private static func webDetail(settings: SettingsStore, chatVM: ChatVM, modelManager: AppModelManager, datasetManager: DatasetManager) -> String {
        if !settings.webSearchEnabled { return String(localized: "Disabled in Settings") }
        if NetworkKillSwitch.isEnabled { return String(localized: "Off-Grid blocks network tools") }
        if datasetActiveOrIndexing || modelManager.activeDataset != nil || datasetManager.selectedDataset != nil {
            return String(localized: "Dataset retrieval is active")
        }
        if chatVM.afmChatToolsUnavailable {
            return String(localized: "Unavailable for Apple Foundation Models")
        }
        if !chatVM.supportsToolsFlag { return String(localized: "Loaded model lacks tool calling") }
        if !settings.webSearchArmed { return String(localized: "Arm from Tool Store or chat") }
        return String(localized: "Ready")
    }

    private static func pythonDetail(settings: SettingsStore, chatVM: ChatVM, modelManager: AppModelManager, datasetManager: DatasetManager) -> String {
        if !settings.pythonEnabled { return String(localized: "Disabled in Settings") }
        let runtimeStatus = PythonRuntime.status()
        if !runtimeStatus.isAvailable {
            return runtimeStatus.reason ?? String(localized: "Python runtime unavailable.")
        }
        if datasetActiveOrIndexing || modelManager.activeDataset != nil || datasetManager.selectedDataset != nil {
            return String(localized: "Dataset retrieval is active")
        }
        if !chatVM.supportsToolsFlag { return String(localized: "Loaded model lacks tool calling") }
        if !settings.pythonArmed { return String(localized: "Arm from Tool Store or chat") }
        return String(localized: "Ready")
    }

    private static func memoryDetail(settings: SettingsStore, chatVM: ChatVM, modelManager: AppModelManager) -> String {
        if !settings.memoryEnabled { return String(localized: "Disabled in Settings") }
        if modelManager.activeRemoteSession != nil { return String(localized: "Local models only") }
        if !chatVM.supportsToolsFlag { return String(localized: "Loaded model lacks tool calling") }
        return String(localized: "Ready")
    }
}
