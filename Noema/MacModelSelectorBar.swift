import SwiftUI

extension Notification.Name {
    static let noemaOpenAutopilotSetup = Notification.Name("noemaOpenAutopilotSetup")
}

#if os(macOS)
import AppKit

private func performAlignmentHaptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

/// Localized size formatter that respects the view's locale (ByteCountFormatter does not expose locale).
private func localizedByteCountString(bytes: Int64, locale: Locale) -> String {
    let useGB = bytes >= 1_073_741_824
    let value = useGB ? Double(bytes) / 1_073_741_824.0 : Double(bytes) / 1_048_576.0
    let unit: UnitInformationStorage = useGB ? .gigabytes : .megabytes

    let formatter = MeasurementFormatter()
    formatter.locale = locale
    formatter.unitOptions = .providedUnit
    formatter.unitStyle = .medium
    formatter.numberFormatter.locale = locale
    formatter.numberFormatter.maximumFractionDigits = 1
    formatter.numberFormatter.minimumFractionDigits = 0
    return formatter.string(from: Measurement(value: value, unit: unit))
}

struct MacModelSelectorBar: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var macModalPresenter: MacModalPresenter
    @EnvironmentObject private var walkthrough: GuidedWalkthroughManager
    @EnvironmentObject private var macChatChrome: MacChatChromeState
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPicker = false
    @State private var dotPulsing = false
    @State private var showOffloadWarning = false
    @State private var pendingLoad: (LocalModel, ModelSettings)?
    @AppStorage("hideGGUFOffloadWarning") private var hideGGUFOffloadWarning = false
    @AppStorage("isAdvancedMode") private var isAdvancedMode = false

    private let controlHeight: CGFloat = 30
    private let controlCornerRadius: CGFloat = 8

    private enum Status {
        case unloaded
        case loading
        case local(LocalModel)
        case remote(ActiveRemoteSession)
        case auto(LocalModel)
    }

    var body: some View {
        HStack(spacing: 8) {
            selectorButton
            if isAdvancedMode {
                advancedControlsButton
            }
            if case .auto(let model) = status, !chatVM.loading {
                settingsButton(for: model)
                // Eject unloads the resident model only; Autopilot stays armed and
                // re-engages when a model loads again. Disarming lives on the picker's
                // "Turn Off" control (and Settings), so eject never silently ends it.
                ejectButton {
                    performAlignmentHaptic()
                    modelManager.loadedModel = nil
                    Task { await chatVM.unload() }
                }
            } else if case .local(let model) = status, !chatVM.loading {
                settingsButton(for: model)
                ejectButton {
                    performAlignmentHaptic()
                    modelManager.loadedModel = nil
                    Task { await chatVM.unload() }
                }
            } else if case .remote = status {
                ejectButton {
                    performAlignmentHaptic()
                    chatVM.deactivateRemoteSession()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Model doesn't support GPU offload",
            isPresented: $showOffloadWarning,
            titleVisibility: .visible
        ) {
            Button("Load") {
                if let (model, settings) = pendingLoad {
                    startLoad(for: model, settings: settings, bypassWarning: true)
                    pendingLoad = nil
                }
            }
            Button("Don't show again") {
                hideGGUFOffloadWarning = true
                if let (model, settings) = pendingLoad {
                    startLoad(for: model, settings: settings, bypassWarning: true)
                    pendingLoad = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingLoad = nil
            }
        } message: {
            if DeviceGPUInfo.supportsGPUOffload {
                Text("This model doesn't support GPU offload and may run slowly. Consider an MLX model.")
            } else {
                Text("This model doesn't support GPU offload and may run slowly. Fastest option: use an ET model.")
            }
        }
    }

    private var advancedControlsButton: some View {
        Button {
            performAlignmentHaptic()
            withAnimation(.easeInOut(duration: 0.2)) {
                macChatChrome.showAdvancedControls.toggle()
            }
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 12, weight: .medium))
                .frame(width: controlHeight, height: controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                        .fill(macChatChrome.showAdvancedControls ? Color.accentColor.opacity(0.12) : ChatTheme.quietSurface)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(macChatChrome.showAdvancedControls ? Color.accentColor : Color.secondary)
        .help(
            macChatChrome.showAdvancedControls
            ? String(localized: "Hide advanced controls")
            : String(localized: "Show advanced controls")
        )
    }

    private var selectorButton: some View {
        let label = selectorLabel

        // Compact quiet surface: a small status dot carries the load state
        // and the title stays plain text.
        return Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .opacity(dotOpacity)
                Text(label.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = label.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 4)
                if chatVM.loading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: controlHeight)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                    .fill(ChatTheme.quietSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                            .stroke(ChatTheme.hairline, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Choose a model (⌘L)"))
        .keyboardShortcut("l", modifiers: [.command])
        .onAppear { syncDotPulse(deciding: chatVM.autoRoutingStage == .deciding) }
        .onChange(of: chatVM.autoRoutingStage) { _, stage in
            syncDotPulse(deciding: stage == .deciding)
        }
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            MacModelPicker(
                isPresented: $showPicker,
                macModalPresenter: macModalPresenter
            )
            .environmentObject(chatVM)
            .environmentObject(modelManager)
            .environmentObject(datasetManager)
            .environmentObject(tabRouter)
            .environmentObject(walkthrough)
            .frame(minWidth: 440, maxWidth: 480, minHeight: 420, maxHeight: 560)
        }
    }

    private func ejectButton(help: String = String(localized: "Unload model"), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "eject")
                .font(.system(size: 12, weight: .medium))
                .frame(width: controlHeight, height: controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                        .fill(ChatTheme.quietSurface)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func settingsButton(for model: LocalModel) -> some View {
        Button {
            presentSettings(for: model)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
                .frame(width: controlHeight, height: controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                        .fill(ChatTheme.quietSurface)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(String(localized: "Adjust model settings"))
    }

    private func presentSettings(for model: LocalModel) {
        macModalPresenter.present(
            title: model.name,
            subtitle: String(localized: "Model Settings"),
            showCloseButton: true,
            dimensions: .modelSettings,
            contentInsets: EdgeInsets(top: 20, leading: 24, bottom: 28, trailing: 24)
        ) {
            ModelSettingsView(model: model) { settings in
                macModalPresenter.dismiss()
                startLoad(for: model, settings: settings)
            }
            .environmentObject(modelManager)
            .environmentObject(chatVM)
            .environmentObject(walkthrough)
        }
    }

    private var status: Status {
        if modelManager.autoRoutingArmed,
           chatVM.modelLoaded,
           let loaded = modelManager.loadedModel,
           modelManager.activeRemoteSession == nil {
            return .auto(loaded)
        }
        if let remote = modelManager.activeRemoteSession {
            return .remote(remote)
        }
        if chatVM.loading {
            return .loading
        }
        // Only treat the model as locally loaded when the runtime is actually resident.
        // After the background unload controller frees the model on app exit,
        // `modelManager.loadedModel` lingers as the last selection while `modelLoaded`
        // flips false — the selector must not keep advertising a freed model.
        if chatVM.modelLoaded, let loaded = modelManager.loadedModel {
            return .local(loaded)
        }
        return .unloaded
    }

    /// Small status dot in the selector button: green = local model ready,
    /// blue = remote session, cyan = Autopilot, orange = loading, gray = nothing loaded.
    private var statusDotColor: Color {
        switch status {
        case .remote:
            return .blue
        case .local:
            return .green
        case .auto:
            return .cyan
        case .loading:
            return .orange
        case .unloaded:
            return Color.secondary.opacity(0.45)
        }
    }

    private var dotOpacity: Double {
        if chatVM.autoRoutingStage == .deciding && reduceMotion { return 0.7 }
        return dotPulsing ? 0.35 : 1
    }

    private func syncDotPulse(deciding: Bool) {
        if deciding, !reduceMotion {
            guard !dotPulsing else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                dotPulsing = true
            }
        } else if dotPulsing {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dotPulsing = false
            }
        }
    }

    private var selectorLabel: (title: String, subtitle: String?) {
        switch status {
        case .auto(let model):
            return (String(localized: "Autopilot"), autoSubtitle(for: model))
        case .local(let model):
            return (model.name, statusSubtitle)
        case .remote(let session):
            return (session.modelName, remoteSubtitle(for: session))
        case .loading:
            return (String(localized: "Loading model…"), statusSubtitle)
        case .unloaded:
            return (String(localized: "Select a model to load"), nil)
        }
    }

    private var statusSubtitle: String {
        if let dataset = modelManager.activeDataset, datasetManager.indexingDatasetID != dataset.datasetID {
            return String(localized: "Using \(dataset.name)")
        }
        if case .local(let model) = status {
            return subtitle(for: model)
        }
        if case .loading = status {
            return String(localized: "Please wait")
        }
        return String(localized: "Models Library")
    }

    private func subtitle(for model: LocalModel) -> String {
        var parts: [String] = []
        if !model.quant.isEmpty {
            parts.append(model.quant)
        }
        parts.append(model.format.displayName)
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        parts.append(localizedByteCountString(bytes: sizeBytes, locale: locale))
        return parts.joined(separator: " · ")
    }

    private func autoSubtitle(for model: LocalModel) -> String {
        let config = AutopilotConfigStore.load()
        guard config.isReadyToArm,
              EnterprisePolicyGate.remoteInferenceAllowed || !config.requiresCloudConsent,
              let escalationModelName = config.escalationDisplayName else {
            return String(localized: "local only")
        }
        return "\(model.name) · \(escalationModelName)"
    }

    private func remoteSubtitle(for session: ActiveRemoteSession) -> String {
        var parts: [String] = [session.backendName]
        parts.append(session.transport.label)
        if session.streamingEnabled {
            parts.append(String(localized: "Streaming"))
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func startLoad(for model: LocalModel, settings: ModelSettings, bypassWarning: Bool = false) {
        if model.format == .gguf && !DeviceGPUInfo.supportsGPUOffload && !hideGGUFOffloadWarning && !bypassWarning {
            pendingLoad = (model, settings)
            showOffloadWarning = true
            return
        }

        pendingLoad = nil

        Task { @MainActor in
            _ = await performModelLoad(
                model: model,
                settings: settings,
                chatVM: chatVM,
                modelManager: modelManager,
                tabRouter: tabRouter
            )
        }
    }
}

private struct MacModelPicker: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var walkthrough: GuidedWalkthroughManager
    @Environment(\.locale) private var locale
    let macModalPresenter: MacModalPresenter

    @State private var searchText = ""
    @State private var sort: SortOption = .recent
    @AppStorage("macManualModelParams") private var manualParams = false
    @State private var models: [LocalModel] = []
    @State private var loadingModelID: LocalModel.ID?
    @State private var pendingLoad: (LocalModel, ModelSettings)?
    @State private var showOffloadWarning = false
    @AppStorage("hideGGUFOffloadWarning") private var hideGGUFOffloadWarning = false
    @State private var highlightedIndex: Int?
    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?

    enum SortOption: String, CaseIterable, Identifiable {
        case recent = "Recency"
        case size = "Size"
        case name = "Name"

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .recent: return LocalizedStringKey("Recency")
            case .size: return LocalizedStringKey("Size")
            case .name: return LocalizedStringKey("Name")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modelList
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            models = modelManager.downloadedModels
            // Popover focus isn't accepted until the panel finishes presenting.
            DispatchQueue.main.async { searchFocused = true }
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .task { await modelManager.refreshAsync() }
        .onReceive(modelManager.$downloadedModels) { models = $0 }
        .onChange(of: searchText) { _, _ in highlightedIndex = nil }
        .alert("Load Failed", isPresented: Binding(
            get: { chatVM.loadError != nil },
            set: { _ in chatVM.loadError = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(chatVM.loadError ?? "")
        }
        .confirmationDialog(
            "Model doesn't support GPU offload",
            isPresented: $showOffloadWarning,
            titleVisibility: .visible
        ) {
            Button("Load") {
                if let (model, settings) = pendingLoad {
                    startLoad(for: model, settings: settings, bypassWarning: true)
                    pendingLoad = nil
                }
            }
            Button("Don't show again") {
                hideGGUFOffloadWarning = true
                if let (model, settings) = pendingLoad {
                    startLoad(for: model, settings: settings, bypassWarning: true)
                    pendingLoad = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingLoad = nil
            }
        } message: {
            if DeviceGPUInfo.supportsGPUOffload {
                Text("This model doesn't support GPU offload and may run slowly. Consider an MLX model.")
            } else {
                Text("This model doesn't support GPU offload and may run slowly. Fastest option: use an ET model.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            IndustrialSectionHeader("Model Library") {
                Button {
                    openExplore()
                } label: {
                    Label("Open Model Library", systemImage: "arrow.up.right")
                }
                .buttonStyle(.industrial(.quiet))
            }

            HStack(spacing: 8) {
                searchField
                Picker(selection: $sort) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.titleKey).tag(option)
                    }
                } label: {
                    Text("Sort")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return TextField(text: $searchText, prompt: Text("Type to filter models…")) {
            Text("Type to filter models…")
        }
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .focused($searchFocused)
        .onSubmit { activateHighlighted() }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(shape.fill(Color.primary.opacity(0.05)))
        .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func openExplore() {
        tabRouter.selection = .explore
        UserDefaults.standard.set(ExploreSection.models.rawValue, forKey: "exploreSection")
        isPresented = false
    }

    /// The popover's field editor consumes Escape (completion menu) and the
    /// arrow keys (caret movement) before SwiftUI's .onKeyPress ever sees
    /// them, so list navigation is intercepted one level down, at the event
    /// monitor. Return stays with the field's onSubmit.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Escape
                if searchText.isEmpty {
                    isPresented = false
                } else {
                    searchText = ""
                }
                return nil
            case 125: // Down arrow
                moveHighlight(by: 1)
                return nil
            case 126: // Up arrow
                moveHighlight(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func moveHighlight(by delta: Int) {
        let count = filteredModels.count
        guard count > 0 else { return }
        if let current = highlightedIndex {
            highlightedIndex = ((current + delta) % count + count) % count
        } else {
            highlightedIndex = delta > 0 ? 0 : count - 1
        }
    }

    private func activateHighlighted() {
        let list = filteredModels
        guard !list.isEmpty else { return }
        activate(list[min(highlightedIndex ?? 0, list.count - 1)])
    }

    private func activate(_ model: LocalModel) {
        if manualParams {
            presentSettings(for: model)
        } else {
            startLoad(for: model, settings: modelManager.settings(for: model))
        }
    }

    private var modelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if tabRouter.isAFMHiddenNoticeVisible {
                        afmHiddenNotice
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        IndustrialSectionHeader("Automatic")
                        AutopilotPickerRow(isPresented: $isPresented)
                    }
                    modelSection(title: "Downloaded", models: filteredModels)
                    if filteredModels.isEmpty {
                        VStack(spacing: 10) {
                            Text("No models match your search.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button {
                                openExplore()
                            } label: {
                                Text("Browse Explore tab")
                            }
                            .buttonStyle(.industrial(.quiet))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: highlightedIndex) { _, index in
                guard let index, filteredModels.indices.contains(index) else { return }
                proxy.scrollTo(filteredModels[index].id, anchor: nil)
            }
        }
    }

    @ViewBuilder
    private func modelSection(title: LocalizedStringKey, models: [LocalModel]) -> some View {
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                IndustrialSectionHeader(title)

                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    MacModelRow(
                        model: model,
                        isLoading: loadingModelID == model.id,
                        isActive: chatVM.loadedModelURL?.path == model.url.path,
                        isHighlighted: highlightedIndex == index,
                        onSelect: { activate(model) },
                        onLoad: { startLoad(for: model, settings: modelManager.settings(for: model)) },
                        onSettings: { presentSettings(for: model) }
                    )
                    .id(model.id)
                    if index < models.count - 1 {
                        IndustrialHairline()
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    private var afmHiddenNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Foundation Model is hidden. You can re-enable it in Settings.")
                .font(.system(size: 12))
            Button {
                tabRouter.dismissAFMHiddenNotice()
                tabRouter.selection = .settings
                isPresented = false
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.industrial(.quiet))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: $manualParams) {
                Text("Manually choose parameters")
                    .font(.system(size: 12))
            }
            .toggleStyle(IndustrialToggleStyle())
            Spacer()
            if let dataset = modelManager.activeDataset {
                Label {
                    Text("Using \(dataset.name)")
                        .font(.system(size: 11, design: .monospaced))
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10))
                }
                .foregroundColor(.secondary)
            }
        }
    }

    private var filteredModels: [LocalModel] {
        var base = models.filter(\.isDownloaded)
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            base = base.filter {
                $0.name.lowercased().contains(needle)
                || $0.modelID.lowercased().contains(needle)
                || $0.quant.lowercased().contains(needle)
                || $0.architectureFamily.lowercased().contains(needle)
            }
        }
        switch sort {
        case .recent:
            base.sort {
                let lhs = $0.lastUsedDate ?? $0.downloadDate
                let rhs = $1.lastUsedDate ?? $1.downloadDate
                return lhs > rhs
            }
        case .size:
            base.sort { $0.sizeGB > $1.sizeGB }
        case .name:
            base.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return base
    }

    private func presentSettings(for model: LocalModel) {
        isPresented = false
        macModalPresenter.present(
            title: model.name,
            subtitle: String(localized: "Model Settings"),
            showCloseButton: true,
            dimensions: .modelSettings,
            contentInsets: EdgeInsets(top: 20, leading: 24, bottom: 28, trailing: 24)
        ) {
            ModelSettingsView(model: model) { settings in
                macModalPresenter.dismiss()
                startLoad(for: model, settings: settings)
            }
            .environmentObject(modelManager)
            .environmentObject(chatVM)
            .environmentObject(walkthrough)
        }
    }

    @MainActor
    private func startLoad(for model: LocalModel, settings: ModelSettings, bypassWarning: Bool = false) {
        if model.format == .gguf && !DeviceGPUInfo.supportsGPUOffload && !hideGGUFOffloadWarning && !bypassWarning {
            pendingLoad = (model, settings)
            showOffloadWarning = true
            return
        }

        loadingModelID = model.id
        Task { @MainActor in
            defer { loadingModelID = nil }
            let success = await performModelLoad(
                model: model,
                settings: settings,
                chatVM: chatVM,
                modelManager: modelManager,
                tabRouter: tabRouter
            )
            if success {
                isPresented = false
            }
        }
    }
}

private struct AutopilotPickerRow: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var hovering = false
    @State private var config = AutopilotConfigStore.load()

    private var enterpriseBlocked: Bool {
        !EnterprisePolicyGate.remoteInferenceAllowed && config.requiresCloudConsent
    }
    private var configured: Bool { config.isReadyToArm }
    private var localModelLoaded: Bool { chatVM.modelLoaded && modelManager.loadedModel != nil }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(configured ? Color.cyan : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                    .frame(width: 12, height: 12)

                Text("Autopilot")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(verbatim: metadata)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                Spacer(minLength: 8)

                if enterpriseBlocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                } else if !configured {
                    Button {
                        openSetup()
                    } label: {
                        Text("Set Up…")
                    }
                    .buttonStyle(.industrial(.quiet))
                }
                if configured {
                    if modelManager.autoRoutingArmed {
                        Button {
                            modelManager.autoRoutingArmed = false
                        } label: {
                            Text("Turn Off")
                        }
                        .buttonStyle(.industrial(.quiet))
                    }
                    IndustrialBadge("Auto", tint: .cyan)
                    if modelManager.autoRoutingArmed {
                        IndustrialBadge("Active", tint: .green)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.045) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(enterpriseBlocked)
        .help(modelManager.autoRoutingArmed
              ? String(localized: "Turn off Autopilot")
              : String(localized: "Turn on Autopilot"))
        .onAppear { config = AutopilotConfigStore.load() }
    }

    private var metadata: String {
        guard configured, let escalation = config.escalationDisplayName else {
            return String(localized: "not set up")
        }
        guard localModelLoaded, let loaded = modelManager.loadedModel else {
            return String(localized: "engages when a model loads")
        }
        return "\(loaded.name) → \(escalation)"
    }

    private func handleTap() {
        if configured {
            if modelManager.autoRoutingArmed {
                // Disarm in place so the Active badge visibly drops.
                modelManager.autoRoutingArmed = false
            } else {
                // Arming without a loaded model is fine: Autopilot engages as
                // soon as a local model loads.
                modelManager.autoRoutingArmed = true
                isPresented = false
            }
        } else {
            openSetup()
        }
    }

    private func openSetup() {
        NotificationCenter.default.post(name: .noemaOpenAutopilotSetup, object: nil)
        isPresented = false
    }
}

private struct MacModelRow: View {
    let model: LocalModel
    let isLoading: Bool
    let isActive: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onLoad: () -> Void
    let onSettings: () -> Void
    @Environment(\.locale) private var locale
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                statusIndicator

                Text(model.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                capabilityGlyphs

                Text(metadata)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                Spacer(minLength: 8)

                if model.format != .afm && !fitsInMemory {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("Likely over memory budget")
                }
                IndustrialBadge(verbatim: model.format.displayName, tint: formatColor)
                if isActive {
                    IndustrialBadge("Active", tint: .green)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHighlighted
                          ? Color.primary.opacity(0.07)
                          : (hovering ? Color.primary.opacity(0.045) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Load") { onLoad() }
            Button("Load with Settings…") { onSettings() }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.url])
            }
            Button("Copy Model ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.modelID, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                Circle()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 12, height: 12)
    }

    @ViewBuilder
    private var capabilityGlyphs: some View {
        if model.isFavourite {
            Image(systemName: "star.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
        }
        if model.isMultimodal {
            Image(systemName: "photo")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        if model.isToolCapable {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var metadata: String {
        var parts: [String] = []
        if !model.quant.isEmpty {
            parts.append(model.quant)
        }
        parts.append(model.format.displayName)
        if model.sizeGB > 0 {
            parts.append(localizedByteCountString(bytes: modelSizeBytes, locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    private var fitsInMemory: Bool {
        // Paged (Noema Overfit) installs run through the paged plan and are
        // judged by the canary, never by a resident-alone or package-total
        // file size. The probe is memoized per URL.
        if model.format == .gguf, OverfitPagedInstallCache.isPaged(model.url) {
            return true
        }
        return ModelRAMAdvisor.fitsInRAM(
            format: model.format,
            sizeBytes: modelSizeBytes,
            contextLength: max(512, Int(model.sizeGB > 0 ? 4096 : 512)),
            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
            moeInfo: model.moeInfo
        )
    }

    private var formatColor: Color {
        switch model.format {
        case .gguf:
            return .blue
        case .mlx:
            return .orange
        case .et:
            return .cyan
        case .ane:
            return .green
        case .afm:
            return .indigo
        case .coreai:
            return .purple
        }
    }

    private var modelSizeBytes: Int64 {
        Int64(model.sizeGB * 1_073_741_824.0)
    }
}

@MainActor
private func performModelLoad(
    model: LocalModel,
    settings: ModelSettings,
    chatVM: ChatVM,
    modelManager: AppModelManager,
    tabRouter: TabRouter
) async -> Bool {
    if model.format == .et {
        var effectiveSettings = modelManager.normalizeLocalSettings(settings, for: model)
        effectiveSettings.contextLength = max(1, effectiveSettings.contextLength)
        let success = await chatVM.load(url: model.url, settings: effectiveSettings, format: .et, forceReload: true)
        if success {
            modelManager.updateSettings(effectiveSettings, for: model)
            modelManager.markModelUsed(model)
            modelManager.loadedModel = model
            modelManager.activeRemoteSession = nil
            tabRouter.selection = .chat
            return true
        }
        modelManager.loadedModel = nil
        return false
    }

    await chatVM.unload()
    try? await Task.sleep(nanoseconds: 200_000_000)

    let normalizedSettings = modelManager.normalizeLocalSettings(settings, for: model)
    let bypass = UserDefaults.standard.bool(forKey: "bypassRAMCheck")
    if !bypass {
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        let context = Int(normalizedSettings.contextLength)
        let layerHint = model.totalLayers > 0 ? model.totalLayers : nil
        let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: normalizedSettings)
        if !ModelRAMAdvisor.fitsInRAM(
            format: model.format,
            sizeBytes: sizeBytes,
            contextLength: context,
            layerCount: layerHint,
            moeInfo: model.moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: .resolved(from: normalizedSettings, modelURL: model.url)
        ) {
            AppSoundPlayer.play(.error)
            Haptics.error()
            chatVM.loadError = String(localized: "Model likely exceeds memory budget. Lower context or choose a smaller quant.")
            return false
        }
    }

    var pendingFlagSet = false
    defer {
        if pendingFlagSet {
            UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
        }
    }

    UserDefaults.standard.set(true, forKey: "bypassRAMLoadPending")
    pendingFlagSet = true

    var loadURL = model.url
    switch model.format {
    case .gguf:
        loadURL = resolveGGUFURL(from: loadURL, model: model)
    case .mlx:
        loadURL = resolveMLXURL(from: loadURL, model: model)
    case .et:
        break
    case .ane:
        chatVM.loadError = String(localized: "Apple bundle models aren't supported on macOS yet.")
        modelManager.loadedModel = nil
        return false
    case .afm:
        loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: model.modelID)
        try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
    case .coreai:
        loadURL = InstalledModelsStore.baseDir(for: .coreai, modelID: model.modelID)
        try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
    }

    guard loadURL != URL(fileURLWithPath: "/dev/null") else {
        return false
    }

    if await chatVM.load(url: loadURL, settings: normalizedSettings, format: model.format) {
        modelManager.updateSettings(normalizedSettings, for: model)
        modelManager.markModelUsed(model)
        modelManager.loadedModel = model
        modelManager.activeRemoteSession = nil
        tabRouter.selection = .chat
        return true
    } else {
        modelManager.loadedModel = nil
        return false
    }
}

private func resolveGGUFURL(from url: URL, model: LocalModel) -> URL {
    var resolved = url
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
        if isDir.boolValue {
            if let candidate = InstalledModelsStore.firstGGUF(in: resolved) {
                resolved = candidate
            }
        } else if resolved.pathExtension.lowercased() != "gguf" {
            if let candidate = InstalledModelsStore.firstGGUF(in: resolved.deletingLastPathComponent()) {
                resolved = candidate
            }
        }
    } else if let candidate = InstalledModelsStore.firstGGUF(in: InstalledModelsStore.baseDir(for: .gguf, modelID: model.modelID)) {
        resolved = candidate
    } else {
        resolved = URL(fileURLWithPath: "/dev/null")
    }
    return resolved
}

private func resolveMLXURL(from url: URL, model: LocalModel) -> URL {
    var resolved = url
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
        resolved = isDir.boolValue ? resolved : resolved.deletingLastPathComponent()
    } else {
        let base = InstalledModelsStore.baseDir(for: .mlx, modelID: model.modelID)
        if FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue {
            resolved = base
        } else {
            resolved = URL(fileURLWithPath: "/dev/null")
        }
    }
    return resolved
}
#endif
