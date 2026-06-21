import SwiftUI
#if os(macOS)
import AppKit

private func performMediumImpact() {
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
    @State private var showPicker = false
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
    }

    var body: some View {
        HStack(spacing: 8) {
            selectorButton
            if isAdvancedMode {
                advancedControlsButton
            }
            if case .local(let model) = status, !chatVM.loading {
                settingsButton(for: model)
                ejectButton {
                    performMediumImpact()
                    modelManager.loadedModel = nil
                    Task { await chatVM.unload() }
                }
            } else if case .remote = status {
                ejectButton {
                    performMediumImpact()
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
            performMediumImpact()
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

        // Compact native capsule: a small status dot carries the load state,
        // the title stays plain text, and one quiet surface replaces the old
        // tinted backgrounds.
        return Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
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
                Capsule()
                    .fill(ChatTheme.quietSurface)
                    .overlay(
                        Capsule()
                            .stroke(ChatTheme.hairline, lineWidth: 1)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Choose a model (⌘L)"))
        .keyboardShortcut("l", modifiers: [.command])
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
            .frame(minWidth: 600, maxWidth: 640, minHeight: 520, maxHeight: 700)
        }
    }

    private func ejectButton(action: @escaping () -> Void) -> some View {
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
        .help(String(localized: "Unload model"))
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
        if let remote = modelManager.activeRemoteSession {
            return .remote(remote)
        }
        if chatVM.loading {
            return .loading
        }
        if let loaded = modelManager.loadedModel {
            return .local(loaded)
        }
        return .unloaded
    }

    /// Small status dot in the selector capsule: green = local model ready,
    /// blue = remote session, orange = loading, gray = nothing loaded.
    private var statusDotColor: Color {
        switch status {
        case .remote:
            return .blue
        case .local:
            return .green
        case .loading:
            return .orange
        case .unloaded:
            return Color.secondary.opacity(0.45)
        }
    }

    private var selectorLabel: (title: String, subtitle: String?) {
        switch status {
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
        VStack(alignment: .leading, spacing: 16) {
            header
            modelList
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            modelManager.refresh()
            models = modelManager.downloadedModels
        }
        .onReceive(modelManager.$downloadedModels) { models = $0 }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model Library")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Spacer()
                Button {
                    tabRouter.selection = .explore
                    UserDefaults.standard.set(ExploreSection.models.rawValue, forKey: "exploreSection")
                    isPresented = false
                } label: {
                    Label("Open Model Library", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.link)
            }

            TextField(text: $searchText, prompt: Text("Type to filter models…")) {
                Text("Type to filter models…")
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Picker(selection: $sort) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.titleKey).tag(option)
                    }
                } label: {
                    Text("Sort")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
            }
        }
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if tabRouter.isAFMHiddenNoticeVisible {
                    afmHiddenNotice
                }
                modelSection(title: "Downloaded", models: filteredModels)
                if filteredModels.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text("No models match your search.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                        Button {
                            tabRouter.selection = .explore
                            UserDefaults.standard.set(ExploreSection.models.rawValue, forKey: "exploreSection")
                            isPresented = false
                        } label: {
                            Text("Browse Explore tab")
                        }
                        .buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func modelSection(title: String, models: [LocalModel]) -> some View {
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 4)

                ForEach(models, id: \.id) { model in
                    MacModelRow(
                        model: model,
                        isLoading: loadingModelID == model.id,
                        isActive: chatVM.loadedModelURL?.path == model.url.path,
                        manualParams: manualParams,
                        onSelect: {
                            if manualParams {
                                presentSettings(for: model)
                            } else {
                                let settings = modelManager.settings(for: model)
                                startLoad(for: model, settings: settings)
                            }
                        }
                    )
                }
            }
        }
    }

    private var afmHiddenNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Foundation Model is hidden. You can re-enable it in Settings.")
                .font(.system(size: 12, weight: .semibold))
            Button {
                tabRouter.dismissAFMHiddenNotice()
                tabRouter.selection = .settings
                isPresented = false
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: $manualParams) {
                Text("Manually choose parameters")
            }
            .toggleStyle(.switch)
            Spacer()
            if let dataset = modelManager.activeDataset {
                Label {
                    Text("Using \(dataset.name)")
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
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

private struct MacModelRow: View {
    let model: LocalModel
    let isLoading: Bool
    let isActive: Bool
    let manualParams: Bool
    let onSelect: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 14) {
                statusIcon
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(model.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isFavourite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.yellow)
                        }
                        if model.isMultimodal {
                            Image(systemName: "photo")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        if model.isToolCapable {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    statusBadges

                    Text(model.modelID)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 2)

                    chipRow(items: summaryChips)
                        .padding(.top, 4)

                    if model.format != .afm {
                        ModelRAMAdvisor.badge(
                            format: model.format,
                            sizeBytes: modelSizeBytes,
                            contextLength: max(512, Int(model.sizeGB > 0 ? 4096 : 512)),
                            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
                            moeInfo: model.moeInfo
                        )
                        .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 10) {
                    if model.format != .afm {
                        Text(formattedSize)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: manualParams ? "slider.horizontal.3" : "arrow.right.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isActive ? Color.green : Color.accentColor.opacity(0.78))
                    }
                }
                .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(isActive ? 0.10 : 0.045), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusBadges: some View {
        HStack(spacing: 6) {
            if isActive {
                badge(String(localized: "Active"), color: .green)
            } else {
                badge(String(localized: "Downloaded"), color: .blue)
            }
            badge(model.format.displayName, color: formatColor)
            if let source = model.slmSourceFormatLabel {
                badge(source, color: .cyan)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statusIcon: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else if isActive {
                Circle()
                    .fill(.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: formatIconName)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(formatColor)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                isActive
                    ? Color.green.opacity(0.10)
                    : Color(nsColor: .controlBackgroundColor)
            )
    }

    private var summaryChips: [String] {
        var items: [String] = []
        if let parameterCountLabel = model.parameterCountLabel, !parameterCountLabel.isEmpty {
            items.append(parameterCountLabel)
        }
        if !model.quant.isEmpty && model.format != .ane {
            items.append(model.quant)
        }
        if !model.architectureFamily.isEmpty && model.format != .et && model.format != .ane && model.format != .afm {
            items.append(model.architectureFamily.uppercased())
        }
        if items.isEmpty {
            items.append(model.format.displayName)
        }
        return items
    }

    @ViewBuilder
    private func chipRow(items: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    detailChip(label: item)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(Array(items.prefix(2).enumerated()), id: \.offset) { _, item in
                        detailChip(label: item)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Array(items.dropFirst(2).enumerated()), id: \.offset) { _, item in
                        detailChip(label: item)
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(FontTheme.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func detailChip(label: String) -> some View {
        Text(label)
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var formatIconName: String {
        switch model.format {
        case .gguf:
            return "cpu"
        case .mlx:
            return "bolt.horizontal.circle"
        case .et:
            return "shippingbox.circle"
        case .ane:
            return "apple.logo"
        case .afm:
            return "sparkles"
        case .coreai:
            return "cpu"
        }
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

    private var formattedSize: String {
        localizedByteCountString(bytes: modelSizeBytes, locale: locale)
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
            kvCacheEstimate: kvCacheEstimate
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
