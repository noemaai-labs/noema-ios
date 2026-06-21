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
                ToolStorePill(title: LocalizedStringKey("Math"), value: String(localized: "Always On"))
                ToolStorePill(title: LocalizedStringKey("Units"), value: String(localized: "Always On"))
                ToolStorePill(title: LocalizedStringKey("Dry Run"), value: settings.toolDryRunEnabled ? String(localized: "On") : String(localized: "Off"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openStore)
    }

    private var summaryText: String {
        let readyCount = [
            ToolStoreModel.webStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager).isReady,
            ToolStoreModel.pythonStatus(settings: settings, chatVM: chatVM, modelManager: modelManager, datasetManager: datasetManager).isReady,
            ToolStoreModel.memoryStatus(settings: settings, chatVM: chatVM, modelManager: modelManager).isReady,
            ToolStoreModel.calculatorStatus().isReady,
            ToolStoreModel.unitConverterStatus().isReady
        ].filter { $0 }.count

        return String.localizedStringWithFormat(
            String(localized: "%d of 5 tools ready"),
            readyCount
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
    @State private var pythonCheckState: ToolCheckState = .idle
    @State private var calculatorCheckState: ToolCheckState = .idle
    @State private var unitCheckState: ToolCheckState = .idle
    @State private var showAdvanced = false

    var body: some View {
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

            Section {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    advancedContent
                } label: {
                    Label(LocalizedStringKey("Advanced"), systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Tool Store"))
    }

    @ViewBuilder
    private var advancedContent: some View {
        Text(LocalizedStringKey("Chat Session"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Toggle(isOn: $settings.webSearchArmed) {
            Label(LocalizedStringKey("Web Armed"), systemImage: "globe")
        }
        .disabled(!settings.webSearchEnabled)
        Toggle(isOn: $settings.pythonArmed) {
            Label(LocalizedStringKey("Python Armed"), systemImage: "terminal.fill")
        }
        .disabled(!settings.pythonEnabled || !PythonRuntime.status().isAvailable)
        Toggle(isOn: $settings.toolDryRunEnabled) {
            Label(LocalizedStringKey("Dry-Run Tools"), systemImage: "hand.raised")
        }
        LabeledContent(LocalizedStringKey("Tool Execution"), value: settings.toolDryRunEnabled ? String(localized: "Dry Run") : String(localized: "Automatic"))

        Text(LocalizedStringKey("Context"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        LabeledContent(LocalizedStringKey("Loaded Model"), value: loadedModelText)
        LabeledContent(LocalizedStringKey("Tool Calling"), value: chatVM.supportsToolsFlag ? String(localized: "Supported") : String(localized: "Unsupported"))
        LabeledContent(LocalizedStringKey("Dataset"), value: activeDatasetText)
        LabeledContent(LocalizedStringKey("Saved Memories"), value: "\(memoryStore.entries.count)")

        Text(LocalizedStringKey("Tests"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        toolTestButton(title: LocalizedStringKey("Run Python Check"), systemImage: "play.circle", state: pythonCheckState, disabled: !PythonRuntime.status().isAvailable || pythonCheckState == .running, runningText: LocalizedStringKey("Checking Python runtime..."), action: runPythonCheck)
        toolTestButton(title: LocalizedStringKey("Run Calculator Check"), systemImage: "function", state: calculatorCheckState, disabled: calculatorCheckState == .running, runningText: LocalizedStringKey("Checking calculator..."), action: runCalculatorCheck)
        toolTestButton(title: LocalizedStringKey("Run Unit Conversion Check"), systemImage: "arrow.left.arrow.right", state: unitCheckState, disabled: unitCheckState == .running, runningText: LocalizedStringKey("Checking unit conversion..."), action: runUnitCheck)

        Text(LocalizedStringKey("Backend Compatibility"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        ForEach(ToolCompatibilityRow.defaults) { row in
            ToolCompatibilityMatrixRow(row: row)
        }
    }

    @ViewBuilder
    private func toolTestButton(title: LocalizedStringKey, systemImage: String, state: ToolCheckState, disabled: Bool, runningText: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .disabled(disabled)
        if state == .running {
            HStack {
                ProgressView()
                Text(runningText)
                    .foregroundStyle(.secondary)
            }
        } else if let message = state.message {
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(state.isSuccess ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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

    private var loadedModelText: String {
        if let remote = modelManager.activeRemoteSession {
            return String.localizedStringWithFormat(String(localized: "Remote: %@"), remote.modelName)
        }
        if let model = modelManager.loadedModel {
            return "\(model.name) · \(model.format.displayName)"
        }
        return String(localized: "No local model loaded")
    }

    private var activeDatasetText: String {
        if let dataset = modelManager.activeDataset ?? datasetManager.selectedDataset {
            return dataset.name
        }
        return String(localized: "None")
    }

    private func runPythonCheck() {
        pythonCheckState = .running
        Task {
            do {
                guard let executor = PythonRuntime.makeExecutor() else {
                    await MainActor.run {
                        pythonCheckState = .failed(String(localized: "Python runtime unavailable."))
                    }
                    return
                }
                let result = try await executor.execute(code: "print('noema-python-ok')", timeout: 30)
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    pythonCheckState = .passed(
                        String.localizedStringWithFormat(
                            String(localized: "Exit %d · %@"),
                            result.exitCode,
                            output.isEmpty ? String(localized: "No output") : output
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    pythonCheckState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func runCalculatorCheck() {
        calculatorCheckState = .running
        Task { @MainActor in
            do {
                await ToolRegistrar.shared.initializeTools()
                let result = try await ToolRegistry.shared.executeToolJSON(
                    name: "noema.math.calculate",
                    argumentsJSON: #"{"expression":"sqrt(144) + 3 * 2"}"#
                )
                calculatorCheckState = .passed(Self.compactToolResult(result, fallback: String(localized: "Calculator check passed.")))
            } catch {
                calculatorCheckState = .failed(error.localizedDescription)
            }
        }
    }

    private func runUnitCheck() {
        unitCheckState = .running
        Task { @MainActor in
            do {
                await ToolRegistrar.shared.initializeTools()
                let result = try await ToolRegistry.shared.executeToolJSON(
                    name: "noema.units.convert",
                    argumentsJSON: #"{"value":10,"from_unit":"km","to_unit":"mi"}"#
                )
                unitCheckState = .passed(Self.compactToolResult(result, fallback: String(localized: "Unit conversion check passed.")))
            } catch {
                unitCheckState = .failed(error.localizedDescription)
            }
        }
    }

    private static func compactToolResult(_ json: String, fallback: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        if let formatted = object["formatted_result"] as? String {
            if let toUnit = object["to_unit"] as? String {
                return "\(formatted) \(toUnit)"
            }
            return formatted
        }
        return fallback
    }
}

private enum ToolCheckState: Equatable {
    case idle
    case running
    case passed(String)
    case failed(String)

    var message: String? {
        switch self {
        case .idle, .running:
            return nil
        case .passed(let message), .failed(let message):
            return message
        }
    }

    var isSuccess: Bool {
        if case .passed = self { return true }
        return false
    }
}

private struct ToolReadinessStatus: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let detail: String
    let icon: String
    let tint: Color
    let isReady: Bool
}

private struct ToolReadinessRow: View {
    let status: ToolReadinessStatus

    var body: some View {
        LabeledContent {
            Text(verbatim: status.detail)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        } label: {
            Label(status.title, systemImage: status.icon)
                .foregroundStyle(status.tint)
        }
    }
}

private struct ToolCompatibilityCell: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let state: ToolCompatibilityState
}

private struct ToolCompatibilityRow: Identifiable {
    let id: String
    let backend: LocalizedStringKey
    let detail: LocalizedStringKey
    let icon: String
    let cells: [ToolCompatibilityCell]

    static var defaults: [ToolCompatibilityRow] {
        [
            ToolCompatibilityRow(
                id: "local-gguf",
                backend: LocalizedStringKey("Local GGUF"),
                detail: LocalizedStringKey("Best local tool path when the model supports function calling."),
                icon: "cpu",
                cells: standardLocalCells
            ),
            ToolCompatibilityRow(
                id: "local-slm",
                backend: LocalizedStringKey("ExecuTorch SLM"),
                detail: LocalizedStringKey("Local bundle path with tool calling enabled by Noema."),
                icon: "shippingbox",
                cells: standardLocalCells
            ),
            ToolCompatibilityRow(
                id: "openai",
                backend: LocalizedStringKey("OpenAI API"),
                detail: LocalizedStringKey("Remote tools are sent as OpenAI-style function specs."),
                icon: "bolt.horizontal.circle",
                cells: standardRemoteCells
            ),
            ToolCompatibilityRow(
                id: "openrouter",
                backend: LocalizedStringKey("OpenRouter"),
                detail: LocalizedStringKey("Depends on the selected provider model's tool support."),
                icon: "point.3.connected.trianglepath.dotted",
                cells: standardRemoteCells
            ),
            ToolCompatibilityRow(
                id: "lm-studio",
                backend: LocalizedStringKey("LM Studio"),
                detail: LocalizedStringKey("Uses the OpenAI-compatible fallback when tools are requested."),
                icon: "macmini",
                cells: standardRemoteCells
            ),
            ToolCompatibilityRow(
                id: "ollama",
                backend: LocalizedStringKey("Ollama"),
                detail: LocalizedStringKey("Requires an Ollama model that emits tool calls."),
                icon: "cube",
                cells: standardRemoteCells
            ),
            ToolCompatibilityRow(
                id: "noema-relay",
                backend: LocalizedStringKey("Noema Relay"),
                detail: LocalizedStringKey("Runs tools through the paired Mac or LAN relay session."),
                icon: "laptopcomputer.and.iphone",
                cells: standardRemoteCells
            ),
            ToolCompatibilityRow(
                id: "cloud-relay",
                backend: LocalizedStringKey("Cloud Relay"),
                detail: LocalizedStringKey("CloudKit relay transport uses the same remote tool contract."),
                icon: "icloud",
                cells: standardRemoteCells
            )
        ]
    }

    private static var standardLocalCells: [ToolCompatibilityCell] {
        [
            ToolCompatibilityCell(id: "web", title: LocalizedStringKey("Web"), state: .conditional),
            ToolCompatibilityCell(id: "python", title: LocalizedStringKey("Python"), state: .conditional),
            ToolCompatibilityCell(id: "memory", title: LocalizedStringKey("Memory"), state: .available),
            ToolCompatibilityCell(id: "retrieval", title: LocalizedStringKey("Retrieval"), state: .available)
        ]
    }

    private static var standardRemoteCells: [ToolCompatibilityCell] {
        [
            ToolCompatibilityCell(id: "web", title: LocalizedStringKey("Web"), state: .conditional),
            ToolCompatibilityCell(id: "python", title: LocalizedStringKey("Python"), state: .conditional),
            ToolCompatibilityCell(id: "memory", title: LocalizedStringKey("Memory"), state: .unavailable),
            ToolCompatibilityCell(id: "retrieval", title: LocalizedStringKey("Retrieval"), state: .available)
        ]
    }
}

private enum ToolCompatibilityState {
    case available
    case conditional
    case unavailable

    var label: LocalizedStringKey {
        switch self {
        case .available: return LocalizedStringKey("Ready")
        case .conditional: return LocalizedStringKey("Conditional")
        case .unavailable: return LocalizedStringKey("Not Available")
        }
    }

    var symbolName: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .conditional: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .available: return .green
        case .conditional: return .orange
        case .unavailable: return .secondary
        }
    }
}

private struct ToolCompatibilityMatrixRow: View {
    let row: ToolCompatibilityRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.backend)
                        .font(.system(size: 15, weight: .semibold))
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(row.cells) { cell in
                    ToolCompatibilityChip(cell: cell)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ToolCompatibilityChip: View {
    let cell: ToolCompatibilityCell

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: cell.state.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(cell.state.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(cell.title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(cell.state.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(cell.state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
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
        if let format = currentFormat(chatVM: chatVM, modelManager: modelManager), format == .mlx, modelManager.activeRemoteSession == nil {
            return String(localized: "Unavailable for local MLX")
        }
        if let format = currentFormat(chatVM: chatVM, modelManager: modelManager), format == .afm {
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
        if let format = currentFormat(chatVM: chatVM, modelManager: modelManager), format == .mlx, modelManager.activeRemoteSession == nil {
            return String(localized: "Unavailable for local MLX")
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
