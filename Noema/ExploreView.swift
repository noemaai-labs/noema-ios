// ExploreView.swift
import Combine
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS)

/// Simple badge label style used to display small status indicators.
struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
        }
        .padding(4)
        .background(
            Capsule().fill(Color(.systemGray5))
        )
    }
}

extension LabelStyle where Self == BadgeLabelStyle {
    static var badge: BadgeLabelStyle { .init() }
}

enum ExploreImportRequest: Equatable {
    case ggufFiles
    case ggufFolder
    case mlxFolder

    var allowedContentTypes: [UTType] {
        switch self {
        case .ggufFiles:
            let types = [
                UTType(filenameExtension: "gguf"),
                UTType(filenameExtension: "mmproj")
            ].compactMap { $0 }
            return types.isEmpty ? [.data] : types
        case .ggufFolder, .mlxFolder:
            return [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .ggufFiles:
            return true
        case .ggufFolder, .mlxFolder:
            return false
        }
    }
}

struct ExploreView: View {
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var chatVM: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var downloadController: DownloadController
    @EnvironmentObject var filterManager: ModelTypeFilterManager
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @EnvironmentObject var localizationManager: LocalizationManager
#if os(macOS)
    @EnvironmentObject var macModalPresenter: MacModalPresenter
    @EnvironmentObject var chromeState: ExploreChromeState
#endif
    @AppStorage("huggingFaceToken") private var huggingFaceToken = ""
    @AppStorage("offGrid") private var offGrid = false
    @StateObject private var vm: ExploreViewModel

    init() {
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken") ?? ""
        _vm = StateObject(wrappedValue: ExploreViewModel(
            registry: CombinedRegistry(primary: HuggingFaceRegistry(token: token),
                                       extras: [ManualModelRegistry(), AppleFoundationModelRegistry()])))
    }
    @State private var selected: ModelDetails?
    @State private var selectedFormatFilter: ModelFormat?
#if canImport(LeapSDK) && !os(macOS)
    @State private var selectedSLMGroup: SLMModelGroup?
#endif
    @State private var loadingDetail = false
    @State private var openingModelId: String?
    // Import flow state
    @State private var showImportMenu = false
    @State private var activeImportRequest: ExploreImportRequest?
    // Drives `.fileImporter` presentation. Kept separate from `activeImportRequest`
    // so the dismissal (isPresented = false) doesn't wipe the routing data that the
    // completion handler needs — see the fileImporter below.
    @State private var isImporterPresented = false
    @State private var pendingPickedURLs: [URL] = []
    @State private var importError: String?
    @State private var importSuccess: String?
    @State private var isImporting = false

    private enum ImportFormat: Equatable { case gguf, ggufFolder, mlx }

#if canImport(LeapSDK) && !os(macOS)
    private struct SLMModelGroup: Identifiable, Hashable {
        let groupKey: String
        let modelID: String
        let displayName: String
        let entries: [LeapCatalogEntry]
        var id: String { groupKey }
    }
#endif

    var body: some View { contentView }

    private var remoteDownloadTargetBackend: RemoteBackend? {
        modelManager.activeLMStudioRemoteDownloadTargetBackend
    }

    private var isRemoteDownloadModeActive: Bool {
        remoteDownloadTargetBackend != nil
    }

    private var effectiveSearchMode: ExploreSearchMode {
        isRemoteDownloadModeActive ? .gguf : vm.searchMode
    }

    private var afmAvailabilityState: AppleFoundationModelAvailabilityState {
        AppleFoundationModelAvailability.current
    }

    @ViewBuilder
    private var contentView: some View {
        listView
            .onChangeCompat(of: huggingFaceToken) { _, newValue in
                updateRegistry(newValue)
            }
            .onChangeCompat(of: filterManager.filter) { _, _ in
                // Trigger a new search when filter changes
                if !vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    vm.triggerSearch()
                }
            }
            .onChangeCompat(of: localizationManager.locale) { _, _ in
                updateRegistry(huggingFaceToken)
                Task { await vm.loadCurated(force: true) }
            }
            .task {
                vm.loadCachedRecords()
                await vm.loadCurated()
                vm.setFilterManager(filterManager)
            }
            .onAppear {
                vm.loadCachedRecords()
                enforceGGUFSearchModeIfNeeded(triggerSearch: true)
                enforceAFMSearchModeIfNeeded(triggerSearch: true)
                // Belt-and-suspenders: on visionOS real hardware, .task may not
                // fire reliably in certain TabView lifecycle scenarios.
                if vm.recommended.isEmpty {
                    Task {
                        await vm.loadCurated()
                        vm.setFilterManager(filterManager)
                    }
                }
            }
#if !os(macOS)
            // Title provided by parent container
            .toolbar {
                searchModeToolbar
                importToolbar
            }
#endif
#if os(macOS)
            .onChangeCompat(of: selected) { _, detail in
                if let detail {
                    presentDetail(detail)
                } else if macModalPresenter.isPresented {
                    selectedFormatFilter = nil
                    macModalPresenter.dismiss()
                }
            }
#else
            .sheet(item: $selected, onDismiss: {
                selectedFormatFilter = nil
            }, content: detailSheet)
#if canImport(LeapSDK)
            .sheet(item: $selectedSLMGroup, content: slmDetailSheet)
#endif
#endif
            .overlay { if loadingDetail { ProgressView() } }
            .overlay { if vm.isLoadingSearch { ProgressView() } }
            .overlay { searchEmptyOverlay }
            .overlay {
                if isImporting {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                            Text(LocalizedStringKey("Importing & Scanning..."))
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        .padding(32)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                    }
                }
            }
            .onChangeCompat(of: downloadController.navigateToDetail) { _, newValue in
                handleNavigation(newValue)
            }
            .onChangeCompat(of: remoteDownloadTargetBackend?.id) { _, _ in
                enforceGGUFSearchModeIfNeeded(triggerSearch: true)
            }
            .onChangeCompat(of: vm.searchMode) { _, _ in
                enforceGGUFSearchModeIfNeeded(triggerSearch: false)
                enforceAFMSearchModeIfNeeded(triggerSearch: false)
            }
            .alert(LocalizedStringKey("Error"), isPresented: hasSearchError) {
                Button(LocalizedStringKey("OK"), role: .cancel) { vm.searchError = nil }
            } message: {
                Text(vm.searchError ?? "")
            }
            .alert(LocalizedStringKey("Import Failed"), isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button(LocalizedStringKey("OK"), role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? String(localized: "Unknown error"))
            }
            .alert(LocalizedStringKey("Import Complete"), isPresented: Binding(
                get: { importSuccess != nil },
                set: { if !$0 { importSuccess = nil } }
            )) {
                Button(LocalizedStringKey("OK"), role: .cancel) { importSuccess = nil }
            } message: {
                Text(importSuccess ?? "")
            }
#if os(macOS)
            .onAppear {
                chromeState.activeSection = .models
                chromeState.searchMode = effectiveSearchMode
                chromeState.toggleAction = { toggleSearchModeIfAllowed() }
                chromeState.searchPlaceholder = LocalizedStringKey("Search models")
                chromeState.searchText = vm.searchText
                chromeState.isSearchVisible = true
                chromeState.searchSubmitAction = { vm.triggerSearch() }
            }
            .onChange(of: vm.searchMode) { newValue in
                _ = newValue
                chromeState.searchMode = effectiveSearchMode
            }
            .onChangeCompat(of: chromeState.searchText) { _, newValue in
                if vm.searchText != newValue {
                    vm.searchText = newValue
                }
            }
            .onChangeCompat(of: vm.searchText) { _, newValue in
                if chromeState.searchText != newValue {
                    chromeState.searchText = newValue
                }
            }
            .onDisappear {
                guard chromeState.activeSection == .models else { return }
                chromeState.toggleAction = nil
                chromeState.isSearchVisible = false
                chromeState.searchSubmitAction = nil
                chromeState.activeSection = nil
            }
            // Bring the import menu into the content area to avoid adding a toolbar that shifts layout.
            .overlay(alignment: .topTrailing) {
                importMenuButton
                    .padding(.top, AppTheme.padding)
                    .padding(.trailing, AppTheme.padding)
            }
#endif
            .onReceive(walkthrough.$step) { step in
                switch step {
                case .exploreModelTypes:
                    if vm.searchMode != .gguf {
                        vm.searchMode = .gguf
                        vm.triggerSearch()
                    }
                case .exploreMLX:
                    if DeviceGPUInfo.supportsGPUOffload && vm.searchMode != .mlx {
                        vm.searchMode = .mlx
                        vm.triggerSearch()
                    }
                case .exploreSLM:
                    if vm.searchMode != .et {
                        vm.searchMode = .et
                        vm.triggerSearch()
                    }
                default:
                    break
                }
            }
            // Search requested from outside the view hierarchy (Siri / App Intents)
            .onAppear { consumePendingExploreSearchIfNeeded() }
            .onReceive(tabRouter.$pendingExploreSearch) { _ in
                consumePendingExploreSearchIfNeeded()
            }
            // File importers for iOS/visionOS (mac uses NSOpenPanel; tvOS lacks Files access)
            #if !os(tvOS)
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: activeImportRequest?.allowedContentTypes ?? [.data],
                allowsMultipleSelection: activeImportRequest?.allowsMultipleSelection ?? false
            ) { result in
                // Capture the routing case BEFORE clearing it. SwiftUI sets
                // `isPresented` to false *before* calling onCompletion; because
                // presentation is now driven by `isImporterPresented` (not by
                // `activeImportRequest != nil`), that dismissal no longer nils this
                // value out from under us. Previously it did, so the guard below
                // failed and folder/file selection silently did nothing.
                let request = activeImportRequest
                activeImportRequest = nil

                guard case .success(let urls) = result, let request else { return }

                switch request {
                case .ggufFiles:
                    Task { await importGGUF(urls: urls) }
                case .ggufFolder:
                    if let url = urls.first {
                        Task { await importGGUF(urls: [url]) }
                    }
                case .mlxFolder:
                    if let url = urls.first {
                        Task { await importMLX(directory: url) }
                    }
                }
            }
            #endif
    }

    /// Runs a search handed over by an App Intent once this view owns Explore.
    private func consumePendingExploreSearchIfNeeded() {
        DispatchQueue.main.async {
            guard let query = tabRouter.consumePendingExploreSearch(for: .models) else { return }
            vm.searchText = query
            vm.triggerSearch()
        }
    }

    @ViewBuilder
    private var listView: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                listContent
            }
            .padding(AppTheme.padding)
            .padding(.bottom, 40)
        }
        .background(AppTheme.windowBackground)
        #elseif os(visionOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                listContent
            }
            .padding(AppTheme.padding)
            .padding(.bottom, 40)
        }
        .searchable(text: $vm.searchText, prompt: Text(LocalizedStringKey("Search models")))
        .onSubmit(of: .search) { vm.triggerSearch() }
        #else
        List { listContent }
            .searchable(text: $vm.searchText, prompt: Text(LocalizedStringKey("Search models")))
            .onSubmit(of: .search) { vm.triggerSearch() }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.windowBackground)
            .contentMargins(.bottom, 40, for: .scrollContent)
        #endif
    }

    private func exploreCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .padding(.vertical, 12)
                .padding(.horizontal, AppTheme.padding)
            Divider()
        }
    }

    private func updateRegistry(_ token: String) {
        vm.updateRegistry(CombinedRegistry(primary: HuggingFaceRegistry(token: token),
                                           extras: [ManualModelRegistry(), AppleFoundationModelRegistry()]))
    }

    private func toggleSearchModeIfAllowed() {
        guard !isRemoteDownloadModeActive else { return }
        vm.toggleMode()
    }

    private func enforceGGUFSearchModeIfNeeded(triggerSearch: Bool) {
        guard isRemoteDownloadModeActive else { return }
        guard vm.searchMode != .gguf else { return }
        vm.searchMode = .gguf
        if triggerSearch {
            vm.triggerSearch()
        }
    }

    private func enforceAFMSearchModeIfNeeded(triggerSearch: Bool) {
        guard vm.searchMode == .afm else { return }
        vm.searchMode = .gguf
        if triggerSearch {
            vm.triggerSearch()
        }
    }

    private var slmListBottomInset: CGFloat {
#if os(iOS)
        // Height budget for the Explore switch bar plus a bit of breathing room
        // so the final ET entry can scroll fully above the menubar.
        UIConstants.defaultPadding * 2 + 40
#else
        0
#endif
    }

    private var slmIPadCardHeight: CGFloat {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 126 : 0
#else
        0
#endif
    }

#if canImport(LeapSDK) && !os(macOS)
    private var groupedSLMModels: [SLMModelGroup] {
        var order: [String] = []
        var buckets: [String: [LeapCatalogEntry]] = [:]
        for entry in vm.filteredLeap {
            let key = slmSanitizedModelKey(for: entry)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(entry)
        }

        return order.compactMap { key in
            guard let entries = buckets[key], !entries.isEmpty else { return nil }
            var quantIndexByKey: [String: Int] = [:]
            var merged: [LeapCatalogEntry] = []
            for entry in entries {
                let quantKey = entry.quantization.lowercased()
                if let idx = quantIndexByKey[quantKey] {
                    if slmEntryIsPreferred(entry, over: merged[idx]) {
                        merged[idx] = entry
                    }
                } else {
                    quantIndexByKey[quantKey] = merged.count
                    merged.append(entry)
                }
            }
            guard !merged.isEmpty else { return nil }
            let representative = entries.min(by: { slmEntrySortKey($0) < slmEntrySortKey($1) }) ?? merged[0]
            return SLMModelGroup(
                groupKey: key,
                modelID: representative.modelID,
                displayName: representative.displayName,
                entries: merged
            )
        }
    }

    private var filteredSLMModelGroups: [SLMModelGroup] {
        groupedSLMModels.filter(slmShouldIncludeGroup)
    }

    private func slmShouldIncludeGroup(_ group: SLMModelGroup) -> Bool {
        guard UIConstants.showMultimodalUI else { return true }
        switch filterManager.filter {
        case .all:
            return true
        case .text:
            return !slmGroupIsVision(group)
        case .vision:
            return slmGroupIsVision(group)
        }
    }

    private func slmGroupIsVision(_ group: SLMModelGroup) -> Bool {
        if group.entries.contains(where: { $0.isVision }) { return true }
        if LeapCatalogService.isVisionQuantizationSlug(group.modelID) { return true }
        return LeapCatalogService.isVisionQuantizationSlug(group.displayName)
    }

    private func slmSanitizedModelKey(for entry: LeapCatalogEntry) -> String {
        let base = (LeapCatalogService.name(for: entry.modelID) ?? entry.displayName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return slmSanitizeName(base)
        }
        return slmSanitizeName(entry.modelID)
    }

    private func slmSanitizeName(_ value: String) -> String {
        let lowered = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        let decimalNormalized = lowered.replacingOccurrences(of: #"(?<=\d)[._](?=\d)"#, with: "p", options: .regularExpression)
        let compact = decimalNormalized.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
        return compact.isEmpty ? lowered.replacingOccurrences(of: " ", with: "") : compact
    }

    private func slmEntrySortKey(_ entry: LeapCatalogEntry) -> (Int, Int, String, String) {
        let artifactRank = (entry.artifactKind == .manifest) ? 0 : 1
        let underscorePenalty = entry.modelID.contains("_") ? 1 : 0
        return (artifactRank, underscorePenalty, entry.modelID.lowercased(), entry.slug.lowercased())
    }

    private func slmEntryIsPreferred(_ lhs: LeapCatalogEntry, over rhs: LeapCatalogEntry) -> Bool {
        slmEntrySortKey(lhs) < slmEntrySortKey(rhs)
    }
#endif

    private func handleNavigation(_ detail: ModelDetails?) {
        if let d = detail {
            selectedFormatFilter = nil
            selected = d
            downloadController.navigateToDetail = nil
        }
    }

    private var hasSearchError: Binding<Bool> {
        Binding(get: { vm.searchError != nil }, set: { if !$0 { vm.searchError = nil } })
    }

    @ViewBuilder
    private func detailSheet(_ detail: ModelDetails) -> some View {
        ExploreDetailView(
            detail: detail,
            downloadController: downloadController,
            remoteDownloadTargetBackendID: remoteDownloadTargetBackend?.id,
            formatFilter: selectedFormatFilter
        )
            .environmentObject(modelManager)
            .environmentObject(chatVM)
#if os(macOS)
            .frame(minWidth: 640, idealWidth: 720, minHeight: 640, idealHeight: 760)
#endif
    }

#if canImport(LeapSDK) && !os(macOS)
    @ViewBuilder
    private func slmDetailSheet(_ group: SLMModelGroup) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    exploreCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.displayName)
                                .font(FontTheme.largeTitle)
                                .foregroundStyle(AppTheme.text)
                            Text(group.modelID)
                                .font(FontTheme.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    exploreCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(LocalizedStringKey("Available Quantizations"))
                                .font(FontTheme.heading)
                                .foregroundStyle(AppTheme.text)
                            ForEach(group.entries) { entry in
                                LeapRowView(entry: entry, openAction: { e, url, runner in
                                    selectedSLMGroup = nil
                                    openLeap(entry: e, url: url, runner: runner)
                                })
                                .environmentObject(downloadController)
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, AppTheme.padding)
            }
            .background(Color.detailSheetBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Close")) { selectedSLMGroup = nil }
                }
            }
        }
    }
#endif

#if os(macOS)
    private func presentDetail(_ detail: ModelDetails) {
        macModalPresenter.present(
            title: nil,
            subtitle: nil,
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 660,
                idealWidth: 720,
                maxWidth: 800,
                minHeight: 620,
                idealHeight: 700,
                maxHeight: 820
            ),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            onDismiss: {
                selected = nil
                selectedFormatFilter = nil
            }
        ) {
            ExploreDetailView(
                detail: detail,
                downloadController: downloadController,
                remoteDownloadTargetBackendID: remoteDownloadTargetBackend?.id,
                formatFilter: selectedFormatFilter
            )
                .environmentObject(modelManager)
                .environmentObject(chatVM)
                .environmentObject(tabRouter)
        }
    }
#endif

    @ViewBuilder
    private var searchEmptyOverlay: some View {
        // Use the rendered result set (live + offline-cached matches) so the empty
        // state doesn't appear while cached models are still shown below.
        if vm.isSearching && !vm.isLoadingSearch && filteredSearchResults.isEmpty {
            VStack(spacing: 8) {
                Text(String.localizedStringWithFormat(String(localized: "No models found for '%@'"), vm.searchText))
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text(emptyStateSuggestion)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var listContent: some View {
        if let target = remoteDownloadTargetBackend {
            remoteDownloadModeBanner(for: target)
#if !os(macOS) && !os(visionOS)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: AppTheme.padding, bottom: 8, trailing: AppTheme.padding))
#endif
        }
        if effectiveSearchMode == .afm, let reason = afmModeStatusMessage {
            afmStatusBanner(reason: reason)
#if !os(macOS) && !os(visionOS)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: AppTheme.padding, bottom: 8, trailing: AppTheme.padding))
#endif
        }
#if canImport(LeapSDK) && !os(macOS) && !os(visionOS)
        if effectiveSearchMode == .et {
            slmSections
        } else {
            standardSections
        }
#else
        standardSections
#endif
    }

    @ViewBuilder
    private func remoteDownloadModeBanner(for backend: RemoteBackend) -> some View {
        exploreCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("Remote endpoint download mode"))
                        .font(FontTheme.body.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(String.localizedStringWithFormat(String(localized: "New downloads from Explore will be sent to %@ until you clear this mode."), backend.name))
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Button(LocalizedStringKey("Clear")) {
                    modelManager.clearLMStudioRemoteDownloadTarget()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func afmStatusBanner(reason: String) -> some View {
        exploreCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "apple.intelligence")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("AFM currently unavailable"))
                        .font(FontTheme.body.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(reason)
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
            }
        }
    }

    private var afmModeStatusMessage: String? {
        guard effectiveSearchMode == .afm else { return nil }
        guard afmAvailabilityState.isSupportedDevice else { return nil }
        guard !afmAvailabilityState.isAvailableNow else { return nil }
        return afmAvailabilityState.unavailableReason?.message
    }

#if canImport(LeapSDK) && !os(macOS)
    @ViewBuilder
    private var slmSections: some View {
        let visibleGroups = filteredSLMModelGroups

        slmListRow(bottom: 12) {
            exploreCard {
                HStack(spacing: 10) {
                    Text(LocalizedStringKey("ET Models - ExecuTorch"))
                        .font(FontTheme.heading(size: 20))
                        .foregroundStyle(AppTheme.text)
                    Spacer(minLength: 8)
                    Text(effectiveSearchMode.displayName)
                        .font(FontTheme.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(searchModeGradient, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }

        if UIDevice.current.userInterfaceIdiom == .pad {
            slmListRow(horizontal: 0, bottom: 0) {
                if visibleGroups.isEmpty {
                    slmEmptyStateCard
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(visibleGroups) { group in
                            exploreCard {
                                slmGroupRow(group, titleLineLimit: 2)
                            }
                            .frame(height: slmIPadCardHeight, alignment: .topLeading)
                        }
                    }
                    .padding(.horizontal, AppTheme.padding)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
            }
        } else {
            if visibleGroups.isEmpty {
                slmListRow(bottom: 12) {
                    slmEmptyStateCard
                }
            } else {
                ForEach(visibleGroups) { group in
                    slmListRow(bottom: 12) {
                        exploreCard {
                            slmGroupRow(group)
                        }
                    }
                }
            }
        }
    }

    private func slmListRow<Content: View>(
        horizontal: CGFloat = AppTheme.padding,
        bottom: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: horizontal, bottom: bottom, trailing: horizontal))
    }

    @ViewBuilder
    private var slmEmptyStateCard: some View {
        exploreCard {
            VStack(spacing: 8) {
                Text(String.localizedStringWithFormat(String(localized: "No models found for '%@'"), vm.searchText))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(emptyStateSuggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func slmGroupRow(_ group: SLMModelGroup, titleLineLimit: Int? = nil) -> some View {
        Button(action: { selectedSLMGroup = group }) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(group.displayName)
                            .font(FontTheme.body)
                            .fontWeight(.medium)
                            .foregroundStyle(AppTheme.text)
                            .lineLimit(titleLineLimit)

                        if UIConstants.showMultimodalUI && slmGroupIsVision(group) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.yellow, lineWidth: 2)
                                    .frame(width: 22, height: 22)
                                Image(systemName: "eye.fill")
                                    .foregroundColor(Color.yellow)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .accessibilityLabel(LocalizedStringKey("Vision-capable model"))
                            .help(LocalizedStringKey("Vision-capable model"))
                        }
                    }
                    Text(group.modelID)
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(group.entries.count)")
                    .font(FontTheme.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.systemGray5), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
#endif

    @ViewBuilder
    private var heroSection: some View {
        if vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey("Discover Intelligence"))
                        .font(FontTheme.largeTitle)
                        .foregroundStyle(AppTheme.text)
                    Text(LocalizedStringKey("Explore the latest open-source models optimized for your Mac."))
                        .font(FontTheme.body)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.bottom, 8)
                
                let featuredModels = filteredRecommended
                if !featuredModels.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(featuredModels.enumerated()), id: \.element.id) { index, featured in
                            featuredCard(featured)
                            if index < featuredModels.count - 1 {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func featuredCard(_ featured: ModelRecord) -> some View {
        Button { Task { await open(featured) } } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(featured.displayName)
                        .font(FontTheme.body.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                        .lineLimit(1)
                    Text(featured.publisher)
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if featured.pipeline_tag == "image-text-to-text" {
                    Image(systemName: "eye.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.purple)
                        .help(LocalizedStringKey("Vision"))
                }
                if showsFitsBadge(for: featured) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                        .help(LocalizedStringKey("Fits on your device"))
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .visionHoverHighlight(cornerRadius: 14)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var standardSections: some View {
        if vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            #if os(macOS) || os(visionOS)
            VStack(alignment: .leading, spacing: 24) {
                heroSection
            }
            #else
            // iOS implementation
            Section {
                heroSection
                    .padding(.horizontal, 0)
                    .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: AppTheme.padding, bottom: 0, trailing: AppTheme.padding))
            #endif
        } else {
            #if os(macOS) || os(visionOS)
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringKey("Results"))
                    .font(FontTheme.heading)
                    .foregroundStyle(AppTheme.text)
                LazyVStack(spacing: 16) {
                    ForEach(filteredSearchResults, id: \._stableKey) { record in
                        exploreCard { recordButton(record, context: .search).buttonStyle(.plain) }
                    }
                    if vm.canLoadMore {
                        ProgressView().onAppear { vm.loadNextPage() }
                    }
                }
            }
            #else
            Section(LocalizedStringKey("Results")) {
                ForEach(filteredSearchResults, id: \._stableKey) { record in
                    recordButton(record, context: .search)
                }
                if vm.canLoadMore {
                    ProgressView().onAppear { vm.loadNextPage() }
                }
            }
            #endif
        }
    }

    // MARK: - Filtered Results
    
    private var filteredRecommended: [ModelRecord] {
        var seen = Set<String>()
        let mode = effectiveSearchMode
        return vm.recommended.filter { rec in
            guard seen.insert(rec.id).inserted else { return false }
            if rec.formats.contains(.afm) {
                return filterManager.shouldIncludeModel(rec)
            }
            // CoreAI-only catalog entries are isolated to the CoreAI tab so they
            // never leak into other format modes (e.g. ET's pass-through filter).
            // Multi-format curated entries that merely carry a CoreAI quant keep
            // showing in every mode, like MLX/ET/CML extras do.
            if rec.formats == [.coreai] {
                return mode == .coreai && filterManager.shouldIncludeModel(rec)
            }

            // Respect the GGUF/MLX toggle when showing curated recommendations
            // on iOS/iPadOS so formats don’t mix across modes.
            let matchesMode = mode == .et ? true : mode.includes(rec)

            return matchesMode
                && filterManager.shouldIncludeModel(rec)
        }
    }

    private var emptyStateSuggestion: String {
        // Replace placeholder in localized bullet list with the current mode hint.
        String(format: String(localized: "Try bullet"), modeSwitchHint)
    }

    private var modeSwitchHint: String {
#if os(macOS)
        return String(localized: "Switching between GGUF/MLX modes")
#else
        return DeviceGPUInfo.supportsGPUOffload
        ? String(localized: "Switching between GGUF/MLX modes")
        : String(localized: "Switching between GGUF/ET modes")
#endif
    }

    private var filteredSearchResults: [ModelRecord] {
        var seen = Set<String>()
        let liveResults = vm.searchResults.filter { rec in
            filterManager.shouldIncludeModel(rec) && seen.insert(rec.id).inserted
        }
        // Surface offline-cached models that match the query so previously viewed
        // models stay findable without a network round-trip. Cached entries are
        // only used while searching — never on the featured page.
        let query = vm.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return liveResults }
        let cachedMatches = vm.cachedRecords.filter { rec in
            guard rec.formats.contains(.afm) == false else { return false }
            guard effectiveSearchMode.includes(rec) else { return false }
            guard filterManager.shouldIncludeModel(rec) else { return false }
            guard recordMatchesQuery(rec, query: query) else { return false }
            return seen.insert(rec.id).inserted
        }
        return liveResults + cachedMatches
    }

    private func recordMatchesQuery(_ record: ModelRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = [
            record.id,
            record.displayName,
            record.publisher,
            record.summary ?? "",
            (record.tags ?? []).joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()
        return haystack.contains(query)
    }

    private enum RecordBadgeContext { case curated, search, cached }

    /// Conservative gate for the “Fits on your device” badge so it only shows
    /// when we have a curated minimum RAM hint that is comfortably under the
    /// device’s per‑app budget. This avoids promising a fit when the detailed
    /// quant estimates in the detail sheet would later show a red X.
    private func showsFitsBadge(for record: ModelRecord) -> Bool {
        guard record.hasInstallableQuant, let minRAM = record.minRAMBytes else { return false }
        guard let budget = DeviceRAMInfo.current().conservativeLimitBytes() else { return false }

        let safetyMargin = 0.92
        return Double(minRAM) <= Double(budget) * safetyMargin
    }

    @ViewBuilder
    private func recordButton(_ record: ModelRecord, context: RecordBadgeContext) -> some View {
        let showsVisionEye = context == .search
        let showsVisionLabel = context == .curated

        Button { Task { await open(record) } } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: context == .cached ? "clock.arrow.circlepath" : "cube.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(context == .cached ? Color.orange : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        (context == .cached ? Color.orange : Color.accentColor).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(record.displayName)
                            .font(FontTheme.body.weight(.medium))
                            .foregroundStyle(AppTheme.text)
                            .lineLimit(1)
                        
                        if UIConstants.showMultimodalUI && !record.formats.contains(.afm) {
                            if record.pipeline_tag == "image-text-to-text" {
                                if showsVisionEye {
                                    Image(systemName: "eye.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.purple)
                                        .help(LocalizedStringKey("Vision-capable model"))
                                }
                            } else {
                                VisionBadge(repoId: record.id, token: huggingFaceToken, showsIcon: showsVisionEye)
                            }
                        }
                        
                        if showsFitsBadge(for: record) {
                            Text(LocalizedStringKey("Fits"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15), in: Capsule())
                        }
                        
                        if context == .cached {
                            Text(LocalizedStringKey("Offline cache"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                        
                        if showsVisionLabel && record.pipeline_tag == "image-text-to-text" {
                            Text(LocalizedStringKey("Vision"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15), in: Capsule())
                        }
                        
                        if !record.formats.contains(.afm) {
                            ToolBadge(repoId: record.id, token: huggingFaceToken)
                        }
                        if record.isReasoningModel {
                            Image(systemName: "brain")
                                .font(.caption2)
                                .foregroundColor(.purple)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        if !record.publisher.isEmpty {
                            Text(authorListText(for: record))
                                .font(FontTheme.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                        }
                        if !record.hasInstallableQuant {
                            Text("•")
                                .font(FontTheme.caption)
                                .foregroundStyle(AppTheme.tertiaryText)
                            Text(LocalizedStringKey("No quant files available"))
                                .font(FontTheme.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func authorListText(for record: ModelRecord) -> String {
        // Currently HF search returns a single owner (publisher). We surface it, and if we
        // later enrich with more authors from metadata, join them here.
        return record.publisher
    }

    @ToolbarContentBuilder
    private var searchModeToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .automatic) {
            Button(action: { toggleSearchModeIfAllowed() }) {
                Text(effectiveSearchMode.displayName)
            }
            .buttonStyle(.glass(color: searchModeColor, isActive: true))
            .disabled(isRemoteDownloadModeActive)
            .guideHighlight(.exploreModelToggle)
        }
        #else
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { toggleSearchModeIfAllowed() }) {
                Text(effectiveSearchMode.displayName)
            }
            .buttonStyle(.glass(color: searchModeColor, isActive: true))
            .disabled(isRemoteDownloadModeActive)
            .guideHighlight(.exploreModelToggle)
        }
        #endif
    }

    private var searchModeGradient: LinearGradient {
        switch effectiveSearchMode {
        case .gguf:
            return ModelFormat.gguf.tagGradient
        case .mlx:
            return ModelFormat.mlx.tagGradient
        case .et:
            return ModelFormat.et.tagGradient
        case .ane:
            return ModelFormat.ane.tagGradient
        case .afm:
            return ModelFormat.afm.tagGradient
        case .coreai:
            return ModelFormat.coreai.tagGradient
        }
    }
    private var searchModeColor: Color {
        switch effectiveSearchMode {
        case .gguf: return .blue
        case .mlx: return .purple
        case .et:
#if os(macOS)
            return .purple
#else
            return .orange
#endif
        case .ane:
            return .green
        case .afm:
            return .indigo
        case .coreai:
            return .purple
        }
    }

    // MARK: - Import Toolbar

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .automatic) { EmptyView() }
        #else
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button(action: { presentImporter(.gguf) }) {
                    Label(LocalizedStringKey("Import GGUF"), systemImage: "tray.and.arrow.down.fill")
                }
                Button(action: { presentImporter(.ggufFolder) }) {
                    Label(LocalizedStringKey("Import GGUF Folder"), systemImage: "folder.badge.plus")
                }
                if supportsMLXImport {
                    Button(action: { presentImporter(.mlx) }) {
                        Label(LocalizedStringKey("Import MLX"), systemImage: "bolt.fill")
                    }
                }
            } label: {
                Label(LocalizedStringKey("Import"), systemImage: "square.and.arrow.down")
            }
            .accessibilityLabel(LocalizedStringKey("Import"))
        }
        #endif
    }

    #if os(macOS)
    private var importMenuButton: some View {
        Menu {
            Button(action: { presentImporter(.gguf) }) {
                Label(LocalizedStringKey("Import GGUF"), systemImage: "tray.and.arrow.down.fill")
            }
            if supportsMLXImport {
                Button(action: { presentImporter(.mlx) }) {
                    Label(LocalizedStringKey("Import MLX"), systemImage: "bolt.fill")
                }
            }
        } label: {
            Label(LocalizedStringKey("Import"), systemImage: "square.and.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help(LocalizedStringKey("Import"))
    }
    #endif

    private var supportsMLXImport: Bool {
        #if os(iOS) || os(visionOS) || os(tvOS)
        return DeviceGPUInfo.supportsGPUOffload
        #else
        return true
        #endif
    }

    private func ggufFileAllowedTypes() -> [UTType] {
        ExploreImportRequest.ggufFiles.allowedContentTypes
    }

    @MainActor
    private func presentImporter(_ format: ImportFormat) {
#if os(tvOS)
        importError = String(localized: "Model import isn’t available on tvOS.")
        return
#elseif os(macOS)
        switch format {
        case .gguf:
            presentMacGGUFImporter()
        case .ggufFolder:
            presentMacGGUFImporter()
        case .mlx:
            guard supportsMLXImport else { return }
            presentMacMLXImporter()
        }
#else
        let request: ExploreImportRequest
        switch format {
        case .gguf:
            request = .ggufFiles
        case .ggufFolder:
            request = .ggufFolder
        case .mlx:
            guard supportsMLXImport else { return }
            request = .mlxFolder
        }
        // Set the routing data first so the importer reads the right content types,
        // then present via the dedicated boolean. Driving presentation off
        // `isImporterPresented` keeps `activeImportRequest` alive for the completion
        // handler and makes repeated re-presentation reliable (the old optional-derived
        // binding could no-op when the same request was re-selected).
        activeImportRequest = request
        isImporterPresented = true
#endif
    }

#if os(macOS)
    @MainActor
    private func presentMacGGUFImporter() {
        let panel = NSOpenPanel()
        // Include `.folder` so a directory of GGUF shards can be selected directly.
        // Without it, AppKit leaves the Import button disabled while a plain folder is
        // highlighted (the user perceives "nothing happens"). importGGUF already
        // recurses directory roots, so a chosen folder imports correctly.
        panel.allowedContentTypes = ggufFileAllowedTypes() + [UTType.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Import")

        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await importGGUF(urls: urls) }
        }
    }

    @MainActor
    private func presentMacMLXImporter() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.folder]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Import")

        if panel.runModal() == .OK, let url = panel.urls.first {
            Task { await importMLX(directory: url) }
        }
    }
#endif

    @MainActor
    private func open(_ record: ModelRecord) async {
        if openingModelId == record.id { return }
        if record.formats.contains(.afm), let reason = afmUnavailableReasonForOpen {
            vm.searchError = reason
            return
        }
        openingModelId = record.id
        defer { openingModelId = nil }

        // Avoid prefetching HF metadata here to reduce unnecessary calls
        // We'll fetch details and metadata only when needed in the detail view

        loadingDetail = true
        if let d = await vm.details(for: record.id, preferCached: offGrid, allowNetwork: !offGrid) {
            selectedFormatFilter = nil
            selected = d
        }
        loadingDetail = false
    }

    private var afmUnavailableReasonForOpen: String? {
        guard afmAvailabilityState.isSupportedDevice else {
            return String(localized: "Apple Foundation Models are not supported on this device.")
        }
        guard !afmAvailabilityState.isAvailableNow else { return nil }
        return afmAvailabilityState.unavailableReason?.message
    }

#if canImport(LeapSDK)
    @MainActor
    private func openLeap(entry: LeapCatalogEntry, url: URL, runner: ModelRunner) {
        let architectureLabels = LocalModel.architectureLabels(for: url, format: .et, modelID: entry.modelID)
        let isVision = entry.isVision || LeapCatalogService.bundleLikelyVision(at: url)
        let local = modelManager.downloadedModels.first(where: { $0.modelID == entry.modelID && $0.quant == entry.quantization }) ??
            LocalModel(
                modelID: entry.modelID,
                name: entry.displayName,
                url: url,
                quant: entry.quantization,
                architecture: architectureLabels.display,
                architectureFamily: architectureLabels.family,
                format: .et,
                sizeGB: Double(entry.sizeBytes) / 1_073_741_824.0,
                isMultimodal: isVision,
                isToolCapable: true,
                isDownloaded: true,
                downloadDate: Date(),
                lastUsedDate: nil,
                isFavourite: false,
                totalLayers: 0,
                moeInfo: nil
            )
        var settings = modelManager.settings(for: local)
        settings.contextLength = max(1, settings.contextLength)
        chatVM.activate(runner: runner, url: url, settings: settings)
        modelManager.updateSettings(settings, for: local)
        modelManager.markModelUsed(local)
        tabRouter.selection = .chat
    }
#endif
}

private struct VisionBadge: View {
    let repoId: String
    let token: String
    let showsIcon: Bool
    @State private var isVision = false
    @EnvironmentObject var filterManager: ModelTypeFilterManager

    var body: some View {
        Group {
            if isVision && showsIcon {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    Image(systemName: "eye.fill")
                        .foregroundColor(Color.yellow)
                        .font(.system(size: 11, weight: .semibold))
                }
                .help(LocalizedStringKey("Vision-capable model"))
            } else if isVision {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onAppear {
            updateFromFilter()
        }
        .onReceive(filterManager.$visionStatusVersion) { _ in
            updateFromFilter()
        }
        .task(id: repoId) {
            await ensureVisionStatus()
        }
    }

    private func updateFromFilter() {
        if let status = filterManager.knownVisionStatus(for: repoId) {
            isVision = status
        }
    }

    private func ensureVisionStatus() async {
        let known = await MainActor.run { filterManager.knownVisionStatus(for: repoId) }
        if let known {
            await MainActor.run { isVision = known }
            return
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let vision = await VisionModelDetector.isVisionModel(repoId: repoId, token: trimmedToken.isEmpty ? nil : trimmedToken)
        await MainActor.run {
            filterManager.updateVisionStatus(repoId: repoId, isVision: vision)
            isVision = vision
        }
    }
}

private struct ToolBadge: View {
    let repoId: String
    let token: String
    @State private var isToolCapable = false
    
    var body: some View {
        Group {
            if isToolCapable {
                HStack(spacing: 2) {
                    Image(systemName: "wrench.fill")
                        .font(.caption2)
                    Text(LocalizedStringKey("Tools"))
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                )
            }
        }
        .task(id: repoId) {
            isToolCapable = await ToolCapabilityDetector.isToolCapable(repoId: repoId, token: token)
        }
    }
}

private extension ModelRecord {
    // Stable view key to avoid duplicate ID warnings when records collide in the same section
    var _stableKey: String {
        let fmtHash = formats.hashValue
        let tag = (pipeline_tag ?? "").hashValue
        return "\(id)|\(fmtHash)|\(tag)"
    }
}

struct ExploreDetailView: View, Identifiable {
    let id = UUID()
    let detail: ModelDetails
    let downloadController: DownloadController
    let remoteDownloadTargetBackendID: RemoteBackend.ID?
    let formatFilter: ModelFormat?
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var chatVM: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @Environment(\.macModalDismiss) private var macModalDismiss
#endif
    @State private var progressMap: [String: Double] = [:]
    @State private var speedMap: [String: Double] = [:]
    @State private var downloading: Set<String> = []
    @State private var remoteDownloadStatusMap: [String: RemoteBackendAPI.LMStudioDownloadJobStatus] = [:]
    @State private var remoteDownloadErrorMap: [String: String] = [:]
    @State private var remotePollingTasks: [String: Task<Void, Never>] = [:]
    @AppStorage("huggingFaceToken") private var huggingFaceToken = ""
    @AppStorage("offGrid") private var offGrid = false
    @State private var quantSort: QuantSortOption = .quant
    @State private var metaVersion: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heroHeader

                    if let remoteBackend = remoteDownloadTargetBackend {
                        infoCard(title: LocalizedStringKey("Remote endpoint download mode")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String.localizedStringWithFormat(String(localized: "New downloads from this screen will be sent to %@."), remoteBackend.name))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let unavailable = remoteModeUnavailableReason {
                                    Label(unavailable, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    if let note = curatedModelNote {
                        curatedModelNoteCard(note)
                    }

                    if let guidance = moeGuidance {
                        moeGuidanceCard(guidance)
                    }

                    infoCard(title: LocalizedStringKey("Available Quantizations"), trailing: {
                        Picker(LocalizedStringKey("Sort"), selection: $quantSort) {
                            ForEach(QuantSortOption.allCases, id: \.self) { opt in
                                Text(opt.titleKey).tag(opt)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityLabel(LocalizedStringKey("Sort quantizations"))
                    }) {
                        if eligibleQuants.isEmpty {
                            Text(LocalizedStringKey("No quant files available"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(sortedQuants.enumerated()), id: \.element.id) { index, q in
                                    if index > 0 {
                                        Divider().opacity(0.5)
                                    }
                                    quantTile(for: q)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 32)
                .padding(.horizontal, 28)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color.detailSheetBackground.ignoresSafeArea())
            #if !os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LocalizedStringKey("Close")) { close() } }
            }
            #endif
            .onAppear {
                if downloadController.items.contains(where: { $0.detail.id == detail.id }) {
                    downloadController.showOverlay = false
                }
                if remoteDownloadTargetBackendID != nil && remoteDownloadTargetBackend == nil {
                    modelManager.clearLMStudioRemoteDownloadTarget()
                }
            }
            .task(id: detail.id) {
                if detail.quants.contains(where: { $0.format == .afm }) {
                    return
                }
                // Ensure Hub metadata (gguf.architecture) is cached for badges like MoE
                let token = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = await HuggingFaceMetadataCache.fetchAndCache(repoId: detail.id, token: token.isEmpty ? nil : token)
                metaVersion &+= 1
            }
            .onDisappear {
                if !downloadController.items.isEmpty {
                    downloadController.showOverlay = true
                }
                cancelAllRemotePolling()
            }
        }
    }

    private var eligibleQuants: [QuantInfo] {
        // Hide CoreAI quants from users below OS 27, even on multi-format models
        // that ship a CoreAI variant alongside GGUF/MLX/etc.
        let base = ModelFormat.isCoreAIRuntimeAvailable
            ? detail.quants
            : detail.quants.filter { $0.format != .coreai }
        guard let formatFilter else { return base }
        return base.filter { $0.format == formatFilter }
    }

    private var lowBitOnlyRepository: Bool {
        !eligibleQuants.isEmpty && eligibleQuants.allSatisfy(\.isLowBitQuant)
    }

    private var sortedQuants: [QuantInfo] {
        switch quantSort {
        case .quant:
            return eligibleQuants.sorted { a, b in
                quantSortKey(a) < quantSortKey(b)
            }
        case .sizeSmall:
            return eligibleQuants.sorted { $0.sizeBytes < $1.sizeBytes }
        case .sizeLarge:
            return eligibleQuants.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    private var remoteDownloadTargetBackend: RemoteBackend? {
        guard let remoteDownloadTargetBackendID else { return nil }
        guard let backend = modelManager.remoteBackend(withID: remoteDownloadTargetBackendID),
              backend.endpointType == .lmStudio else {
            return nil
        }
        return backend
    }

    private var isRemoteDownloadMode: Bool {
        remoteDownloadTargetBackend != nil
    }

    private var remoteModeUnavailableReason: String? {
        guard isRemoteDownloadMode else { return nil }
        if offGrid {
            return String(localized: "Remote access is disabled in Off-Grid mode.")
        }
        guard let backend = remoteDownloadTargetBackend else {
            return String(localized: "Remote endpoint download target is unavailable.")
        }
        if let summary = backend.lastConnectionSummary, summary.kind == .failure {
            return summary.displayLine
        }
        if let error = backend.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        return nil
    }

    private func quantSortKey(_ q: QuantInfo) -> (Int, Int, Int, Int, Int, String) {
        // Lower tuple compares first; smaller values rank higher
        let label = q.label.uppercased()
        // Core AI bundles are platform targets, not a quality ladder — rank by
        // fit for the current device, then by size (smaller first).
        if q.format == .coreai {
            let familyRank = CoreAIBundleFamily.detect(from: q.label)?.sortRank ?? 9
            return (9, familyRank, Int(clamping: q.sizeBytes), 0, 0, label)
        }
        let bits = q.inferredBitWidth ?? 999
        let formatRank: Int = {
            switch q.format {
            case .gguf: return 0
            case .mlx: return 5
            case .et: return 6
            case .ane: return 7
            case .afm: return 8
            case .coreai: return 9
            }
        }()

        // Variant and family ranking targeted for common GGUF patterns
        // Priority: K_M → K_L → K_S → K (no suffix) → _0 → _1 → IQ* → others
        let hasKM = label.contains("_K_M")
        let hasKL = label.contains("_K_L")
        let hasKS = label.contains("_K_S")
        let hasKOnly = label.contains("_K") && !(hasKM || hasKL || hasKS)
        let has0 = label.contains("_0")
        let has1 = label.contains("_1")
        let isIQ = label.contains("IQ")

        let groupRank: Int = {
            if hasKM { return 0 }
            if hasKL { return 1 }
            if hasKS { return 2 }
            if hasKOnly { return 3 }
            if has0 { return 4 }
            if has1 { return 5 }
            if isIQ { return 6 }
            return 9
        }()

        // Secondary within-group rank (e.g., distinguish 0 vs 1, or prefer KM over KL over KS already handled)
        let variantRank: Int = {
            if has0 { return 0 }
            if has1 { return 1 }
            return 0
        }()

        // Some labels include model scale (e.g., Q3_K_M_XS). Prefer XS/XXS before larger variants when bits tie
        let scaleRank: Int = {
            if label.contains("_XXS") { return 0 }
            if label.contains("_XS") { return 1 }
            if label.contains("_S") { return 2 }
            if label.contains("_M") { return 3 }
            if label.contains("_L") { return 4 }
            if label.contains("_XL") { return 5 }
            return 3
        }()

        return (formatRank, groupRank, bits, variantRank, scaleRank, label)
    }

    private func fileURL(for info: QuantInfo) -> URL {
        InstalledModelsStore.localModelURL(for: info, modelID: detail.id)
    }

    @MainActor
    private func download(info: QuantInfo) async {
        if info.format == .coreai, info.downloadURL.scheme?.lowercased() == "coreai" {
            // Local-catalog CoreAI entries are export recipes, not downloadable
            // artifacts. Hugging Face repos with real .aimodel files download normally.
            remoteDownloadErrorMap[info.label] = CoreAIModelRegistry.sideLoadNotice
            return
        }
        if isRemoteDownloadMode {
            await startRemoteDownload(info: info)
            return
        }
        downloading.insert(info.label)
        progressMap[info.label] = 0
        speedMap[info.label] = 0
        downloadController.start(detail: detail, quant: info)
    }

    private func cancelDownload(label: String) {
        guard !isRemoteDownloadMode else { return }
        let id = "\(detail.id)-\(label)"
        downloadController.cancel(itemID: id)
        downloading.remove(label)
    }

    @MainActor
    private func startRemoteDownload(info: QuantInfo) async {
        let label = info.label
        remoteDownloadErrorMap[label] = nil

        guard let backend = remoteDownloadTargetBackend else {
            remoteDownloadErrorMap[label] = String(localized: "Remote endpoint download target is unavailable.")
            return
        }

        guard info.format == .gguf else {
            remoteDownloadErrorMap[label] = String(localized: "Remote endpoint downloads currently support GGUF quantizations only.")
            return
        }

        if let unavailableReason = remoteModeUnavailableReason {
            remoteDownloadErrorMap[label] = unavailableReason
            return
        }

        downloading.insert(label)
        progressMap[label] = 0
        speedMap[label] = 0

        let modelReference = remoteDownloadModelReference()
        do {
            let status = try await RemoteBackendAPI.startLMStudioDownload(
                for: backend,
                model: modelReference,
                quantization: info.label
            )
            applyRemoteDownloadStatus(status, for: label)

            if status.status.isTerminal {
                finalizeRemoteDownloadStatus(status, for: label, backendID: backend.id)
                return
            }

            guard let jobID = status.jobID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jobID.isEmpty else {
                if status.status == .completed || status.status == .alreadyDownloaded {
                    finalizeRemoteDownloadStatus(status, for: label, backendID: backend.id)
                    return
                }
                downloading.remove(label)
                remoteDownloadErrorMap[label] = String(localized: "Remote endpoint did not return a download job ID.")
                return
            }

            startRemoteDownloadPolling(backendID: backend.id, quantLabel: label, jobID: jobID)
        } catch {
            downloading.remove(label)
            remoteDownloadErrorMap[label] = RemoteBackend.localizedErrorDescription(for: error)
        }
    }

    @MainActor
    private func applyRemoteDownloadStatus(_ status: RemoteBackendAPI.LMStudioDownloadJobStatus, for quantLabel: String) {
        remoteDownloadStatusMap[quantLabel] = status
        if let progress = status.progress {
            progressMap[quantLabel] = progress
        }
        if let speed = status.bytesPerSecond {
            speedMap[quantLabel] = speed
        }
        switch status.status {
        case .downloading, .paused:
            downloading.insert(quantLabel)
        case .completed, .alreadyDownloaded, .failed:
            downloading.remove(quantLabel)
        }
        if status.status != .failed {
            remoteDownloadErrorMap[quantLabel] = nil
        }
    }

    @MainActor
    private func finalizeRemoteDownloadStatus(_ status: RemoteBackendAPI.LMStudioDownloadJobStatus,
                                              for quantLabel: String,
                                              backendID: RemoteBackend.ID) {
        downloading.remove(quantLabel)
        remotePollingTasks[quantLabel]?.cancel()
        remotePollingTasks[quantLabel] = nil

        switch status.status {
        case .completed, .alreadyDownloaded:
            Task { await refreshRemoteBackendModels(backendID: backendID) }
        case .failed:
            if remoteDownloadErrorMap[quantLabel] == nil {
                remoteDownloadErrorMap[quantLabel] = String(localized: "Remote model download failed.")
            }
        case .downloading, .paused:
            break
        }
    }

    @MainActor
    private func startRemoteDownloadPolling(backendID: RemoteBackend.ID, quantLabel: String, jobID: String) {
        remotePollingTasks[quantLabel]?.cancel()
        remotePollingTasks[quantLabel] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }

                let backend = await MainActor.run(resultType: RemoteBackend?.self) {
                    modelManager.remoteBackend(withID: backendID)
                }
                guard let backend else {
                    await MainActor.run {
                        downloading.remove(quantLabel)
                        remoteDownloadErrorMap[quantLabel] = String(localized: "Remote endpoint download target is unavailable.")
                        remotePollingTasks[quantLabel] = nil
                    }
                    return
                }

                do {
                    let status = try await RemoteBackendAPI.fetchLMStudioDownloadStatus(for: backend, jobID: jobID)
                    await MainActor.run {
                        applyRemoteDownloadStatus(status, for: quantLabel)
                    }
                    if status.status.isTerminal {
                        await MainActor.run {
                            finalizeRemoteDownloadStatus(status, for: quantLabel, backendID: backendID)
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        downloading.remove(quantLabel)
                        remoteDownloadErrorMap[quantLabel] = RemoteBackend.localizedErrorDescription(for: error)
                        remotePollingTasks[quantLabel] = nil
                    }
                    return
                }
            }
        }
    }

    @MainActor
    private func refreshRemoteBackendModels(backendID: RemoteBackend.ID) async {
        await modelManager.fetchRemoteModels(for: backendID)
    }

    private func cancelAllRemotePolling() {
        for (_, task) in remotePollingTasks {
            task.cancel()
        }
        remotePollingTasks.removeAll()
    }

    private func remoteDownloadModelReference() -> String {
        let trimmedModelID = detail.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModelID.lowercased().hasPrefix("http://") || trimmedModelID.lowercased().hasPrefix("https://") {
            return trimmedModelID
        }
        return "https://huggingface.co/\(trimmedModelID)"
    }

    private func remoteStatusText(for quantLabel: String) -> String? {
        guard let status = remoteDownloadStatusMap[quantLabel]?.status else { return nil }
        switch status {
        case .downloading:
            return String(localized: "Downloading")
        case .paused:
            return String(localized: "Paused")
        case .completed:
            return String(localized: "Downloaded")
        case .failed:
            return String(localized: "Failed")
        case .alreadyDownloaded:
            return String(localized: "Downloaded")
        }
    }

    private func close() {
#if os(macOS)
        macModalDismiss()
#else
        dismiss()
#endif
    }

    @MainActor
    private func useModel(info: QuantInfo) async {
        let url = fileURL(for: info)
        let name = url.deletingPathExtension().lastPathComponent
        
        // Detect vision capability strictly via projector presence for GGUF models
        let token = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = HuggingFaceMetadataCache.cached(repoId: detail.id)
        var isVision = meta?.hasProjectorFile ?? false

        if !isVision {
            switch info.format {
            case .gguf:
                isVision = ModelVisionDetector.guessLlamaVisionModel(from: url)
                if !isVision {
                    isVision = await VisionModelDetector.isVisionModel(repoId: detail.id, token: token.isEmpty ? nil : token)
                }
            case .mlx:
                isVision = MLXBridge.isVLMModel(at: url)
            case .et:
                let slug = detail.id.isEmpty ? url.deletingPathExtension().lastPathComponent : detail.id
                isVision = LeapCatalogService.isVisionQuantizationSlug(slug)
            case .ane:
                isVision = false
            case .afm:
                isVision = false
            case .coreai:
                isVision = false
            }
        }
        // For capabilities on open, check hub/template hints with a single call; fallback to local scan
        var isToolCapable = info.format == .afm ? true : await ToolCapabilityDetector.isToolCapable(repoId: detail.id, token: token)
        if isToolCapable == false {
            isToolCapable = ToolCapabilityDetector.isToolCapableLocal(url: url, format: info.format)
        }

        let moeInfo: MoEInfo?
        switch info.format {
        case .gguf, .mlx:
            moeInfo = ModelScanner.moeInfo(for: url, format: info.format)
        case .et, .ane, .afm, .coreai:
            moeInfo = nil
        }
        let architectureLabels = LocalModel.architectureLabels(for: url, format: info.format, modelID: detail.id)
        let local = LocalModel(
            modelID: detail.id,
            name: name,
            url: url,
            quant: info.label,
            parameterCountLabel: detail.parameterCountLabel,
            architecture: architectureLabels.display,
            architectureFamily: architectureLabels.family,
            format: info.format,
            sizeGB: Double(info.sizeBytes) / 1_073_741_824.0,
            isMultimodal: isVision,
            isToolCapable: isToolCapable,
            isDownloaded: true,
            downloadDate: Date(),
            lastUsedDate: nil,
            isFavourite: false,
            totalLayers: ModelScanner.layerCount(for: url, format: info.format),
            moeInfo: moeInfo
        )
        let settings = modelManager.settings(for: local)
        await chatVM.unload()
        if info.format == .afm,
           let reason = AppleFoundationModelAvailability.current.unavailableReason,
           !AppleFoundationModelAvailability.isAvailableNow {
            modelManager.loadedModel = nil
            remoteDownloadErrorMap[info.label] = reason.message
            return
        }
        if await chatVM.load(url: url, settings: settings, format: info.format) {
            // Persist effective settings for last used
            modelManager.updateSettings(settings, for: local)
            modelManager.markModelUsed(local)
            // Persist capabilities immediately so badges and image button show correctly
            modelManager.setCapabilities(modelID: detail.id, quant: info.label, isMultimodal: isVision, isToolCapable: isToolCapable)
        } else {
            modelManager.loadedModel = nil
        }
        tabRouter.selection = .stored
        close()
    }
}

// MARK: - Import helpers

extension ExploreView {
    @MainActor
    private func importGGUF(urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        
        do {
            let fm = FileManager.default
            let now = Date()
            let scopedRoots = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for url in scopedRoots {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let importPlans = GGUFImportSupport.modelImportPlans(from: urls, fileManager: fm)

            guard !importPlans.isEmpty else {
                importError = String(localized: "No GGUF model files found in selection.")
                return
            }

            for plan in importPlans {
                // Derive repo name (strip quant token from filename when possible)
                let normalizedWeightName = URL(
                    fileURLWithPath: GGUFShardNaming.strippedShardPath(plan.primaryWeight.lastPathComponent)
                )
                .deletingPathExtension()
                .lastPathComponent
                let baseName = normalizedWeightName
                let quantToken = QuantExtractor.shortLabel(from: baseName, format: .gguf)
                let repoName = deriveRepoName(from: baseName, removing: quantToken)
                let modelID = "local/\(repoName)"
                // Destination directory for this model
                let destDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                var copiedWeights: [URL] = []
                copiedWeights.reserveCapacity(plan.weightFiles.count)
                for weight in plan.weightFiles {
                    let destWeight = uniqueDestination(for: destDir.appendingPathComponent(weight.lastPathComponent))
                    try safeCopy(from: weight, to: destWeight)
                    copiedWeights.append(destWeight)
                }

                var copiedProjector: URL? = nil
                if let projector = plan.projector {
                    let destination = uniqueDestination(for: destDir.appendingPathComponent(projector.lastPathComponent))
                    try safeCopy(from: projector, to: destination)
                    copiedProjector = destination
                }

                var copiedMTP: URL? = nil
                if let mtp = plan.mtp {
                    let destination = uniqueDestination(for: destDir.appendingPathComponent(mtp.lastPathComponent))
                    try safeCopy(from: mtp, to: destination)
                    copiedMTP = destination
                }

                for sidecar in plan.sidecars {
                    let destination = destDir.appendingPathComponent(sidecar.lastPathComponent)
                    try safeCopy(from: sidecar, to: destination)
                }

                GGUFImportSupport.writeArtifactsJSON(
                    in: destDir,
                    weightFiles: copiedWeights,
                    projector: copiedProjector,
                    mtp: copiedMTP
                )

                // Resolve canonical URL (prefers first valid .gguf inside directories)
                let canonical = InstalledModelsStore.canonicalURL(for: copiedWeights.first ?? destDir, format: .gguf)
                // Compute metadata
                let size = copiedWeights.reduce(into: Int64(0)) { total, file in
                    let bytes = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                    total += bytes
                }
                let layers = ModelScanner.layerCount(for: canonical, format: .gguf)

                // Vision detection: check for external projector OR embedded projector (e.g. Llama 3.2 Vision)
                var isVision = ProjectorLocator.hasProjectorFile(in: canonical.deletingLastPathComponent())
                if !isVision {
                    isVision = ModelVisionDetector.guessLlamaVisionModel(from: canonical)
                }
                
                let isToolCap = ToolCapabilityDetector.isToolCapableLocal(url: canonical, format: .gguf)
                let moeInfo = ModelScanner.moeInfo(for: canonical, format: .gguf) ?? .denseFallback
                // Persist MoE cache asynchronously
                Task { await MoEDetectionStore.shared.update(info: moeInfo, modelID: modelID, quantLabel: quantToken) }
                let projectorName = copiedProjector?.lastPathComponent ?? "none"
                let sidecarNames = plan.sidecars.map(\.lastPathComponent).sorted().joined(separator: ",")
                Task {
                    await logger.log(
                        "[GGUFImport] model=\(baseName) weights=\(copiedWeights.map(\.lastPathComponent).joined(separator: ",")) projector=\(projectorName) sidecars=[\(sidecarNames)]"
                    )
                }

                let installed = InstalledModel(
                    modelID: modelID,
                    quantLabel: quantToken,
                    url: canonical,
                    format: .gguf,
                    sizeBytes: size,
                    lastUsed: nil,
                    installDate: now,
                    checksum: nil,
                    isFavourite: false,
                    totalLayers: layers,
                    isMultimodal: isVision,
                    isToolCapable: isToolCap,
                    moeInfo: moeInfo
                )
                modelManager.install(installed)
            }

            importSuccess = importPlans.count == 1
                ? String(localized: "Imported 1 model. Find it in the Stored tab.")
                : String(localized: "Imported \(importPlans.count) models. Find them in the Stored tab.")
        } catch {
            if let err = error as? CocoaError,
               (err.code == .fileReadNoPermission || err.code == .fileWriteNoPermission) {
                let path = (err.userInfo[NSFilePathErrorKey] as? String) ?? "selected files"
                importError = String(localized: "Import failed: Permission denied for \(path). Please allow access when prompted or move the files to a readable location.")
            } else {
                importError = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func importMLX(directory: URL) async {
        guard supportsMLXImport else { return }
        isImporting = true
        defer { isImporting = false }
        
        do {
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
                importError = String(localized: "Selected path is not a directory.")
                return
            }

            let folderName = directory.lastPathComponent
            let repoName = InstalledModelsStore.normalizedRepoName(for: .mlx, modelID: "local/\(folderName)")
            let modelID = "local/\(repoName)"
            let destDir = InstalledModelsStore.baseDir(for: .mlx, modelID: modelID)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Copy entire folder contents into destination (merge-safe)
            try copyDirectoryContents(from: directory, to: destDir)

            // Copying an empty (or fully-unreadable) directory succeeds without throwing,
            // which would otherwise register a phantom model with no files and no feedback.
            // Mirror the GGUF importer's empty-guard.
            let copiedContents = (try? fm.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil)) ?? []
            let hasMLXWeights = copiedContents.contains { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasSuffix(".safetensors") || name == "config.json" || name.hasSuffix(".npz")
            }
            guard !copiedContents.isEmpty, hasMLXWeights else {
                try? fm.removeItem(at: destDir)
                importError = String(localized: "No MLX model files were found in the selected folder. Make sure you pick the folder that contains config.json and the .safetensors weights.")
                return
            }

            // Determine canonical directory
            let canonical = InstalledModelsStore.canonicalURL(for: destDir, format: .mlx)
            // Derive quant label from directory name or files
            let quantLabel = deriveMLXQuantLabel(from: directory)
            // Gather metadata
            let size = folderSize(at: canonical)
            let isVision = MLXBridge.isVLMModel(at: canonical)
            let isToolCap = ToolCapabilityDetector.isToolCapableLocal(url: canonical, format: .mlx)
            let moeInfo = ModelScanner.moeInfo(for: canonical, format: .mlx) ?? .denseFallback
            Task { await MoEDetectionStore.shared.update(info: moeInfo, modelID: modelID, quantLabel: quantLabel) }

            let installed = InstalledModel(
                modelID: modelID,
                quantLabel: quantLabel,
                url: canonical,
                format: .mlx,
                sizeBytes: size,
                lastUsed: nil,
                installDate: Date(),
                checksum: nil,
                isFavourite: false,
                totalLayers: 0,
                isMultimodal: isVision,
                isToolCapable: isToolCap,
                moeInfo: moeInfo
            )
            modelManager.install(installed)
            importSuccess = String(localized: "Imported \(folderName). Find it in the Stored tab.")
        } catch {
            if let err = error as? CocoaError,
               (err.code == .fileReadNoPermission || err.code == .fileWriteNoPermission) {
                let path = (err.userInfo[NSFilePathErrorKey] as? String) ?? directory.path
                importError = String(localized: "Import failed: Permission denied for \(path). Please allow access when prompted or move the model folder to a readable location.")
            } else {
                importError = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Small utilities

    private func deriveRepoName(from baseName: String, removing token: String) -> String {
        // Remove the quant token from the original string using case-insensitive search
        if let r = baseName.range(of: token, options: .caseInsensitive) {
            var trimmed = baseName
            trimmed.removeSubrange(r)
            trimmed = trimmed.replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            trimmed = trimmed.replacingOccurrences(of: "[-_]+$", with: "", options: .regularExpression)
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? baseName : trimmed
        }
        return baseName
    }

    private func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var idx = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(idx)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            idx += 1
        }
    }

    private func safeCopy(from: URL, to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) {
            // Remove stale file before copying
            try? fm.removeItem(at: to)
        }
        try fm.copyItem(at: from, to: to)
    }

    private func copyDirectoryContents(from srcDir: URL, to dstDir: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil)
        for item in items {
            let scoped = item.startAccessingSecurityScopedResource()
            defer { if scoped { item.stopAccessingSecurityScopedResource() } }

            let dest = dstDir.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try copyDirectoryContents(from: item, to: dest)
            } else {
                try safeCopy(from: item, to: dest)
            }
        }
    }

    private func folderSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
                    total += size
                }
            }
        }
        return total
    }

    private func deriveMLXQuantLabel(from directory: URL) -> String {
        // Combine folder and file names to look for bitness tokens
        var corpus = directory.lastPathComponent
        if let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let names = items.map { $0.lastPathComponent }.joined(separator: " ")
            corpus += " " + names
        }
        let short = QuantExtractor.shortLabel(from: corpus, format: .mlx)
        return short.isEmpty ? "MLX" : short
    }
}

enum GGUFImportSupport {
    struct ModelImportPlan {
        let primaryWeight: URL
        let weightFiles: [URL]
        let projector: URL?
        let mtp: URL?
        let sidecars: [URL]
    }

    private static let projectorKeywords = ["mmproj", "projector", "image_proj"]
    private static let mtpKeywords = ["mtp", "draft", "nextn"]
    private static let sidecarExtensions = Set(["json", "jinja"])
    private static let sidecarFilenames = Set(["chat_template.txt"])
    private static let excludedSidecarNames = Set(["artifacts.json", "ds_markers.cache.json"])

    static func isImportCandidate(_ url: URL) -> Bool {
        isWeightFile(url) || isProjector(url) || isMTP(url) || isSidecar(url)
    }

    static func isProjector(_ url: URL) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "mmproj"
            || projectorKeywords.contains(where: { lowerName.contains($0) })
    }

    static func isSidecar(_ url: URL) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        if excludedSidecarNames.contains(lowerName) { return false }
        if sidecarFilenames.contains(lowerName) { return true }
        return sidecarExtensions.contains(url.pathExtension.lowercased())
    }

    static func isWeightFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gguf" && !isProjector(url) && !isMTP(url)
    }

    static func isMTP(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else { return false }
        let lowerName = url.lastPathComponent.lowercased()
        guard !isProjector(url) else { return false }
        return mtpKeywords.contains(where: { lowerName.contains($0) })
    }

    static func collectImportableFiles(from roots: [URL], fileManager: FileManager = .default) -> [URL] {
        var collected: [String: URL] = [:]

        func addIfSupported(_ url: URL) {
            guard isImportCandidate(url) else { return }
            collected[url.standardizedFileURL.path] = url
        }

        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let next = enumerator?.nextObject() as? URL {
                    if let values = try? next.resourceValues(forKeys: [.isRegularFileKey]),
                       values.isRegularFile == true {
                        addIfSupported(next)
                    }
                }
            } else {
                addIfSupported(root)
            }
        }

        return collected.values.sorted { $0.path < $1.path }
    }

    static func modelImportPlans(from roots: [URL], fileManager: FileManager = .default) -> [ModelImportPlan] {
        let selectedWeights = collectSelectedWeightFiles(from: roots, fileManager: fileManager)
        guard !selectedWeights.isEmpty else { return [] }

        var grouped: [String: [URL]] = [:]
        for weight in selectedWeights {
            let key = GGUFShardNaming.splitGroupKey(forPath: weight.path) ?? "single:\(weight.standardizedFileURL.path)"
            grouped[key, default: []].append(weight)
        }

        return grouped.values.compactMap { weights in
            let orderedWeights = orderedWeightFiles(weights)
            guard let primaryWeight = orderedWeights.first else { return nil }
            let scopeDirectory = primaryWeight.deletingLastPathComponent()
            let scopeFiles = scopeFiles(in: scopeDirectory, fileManager: fileManager)
            let projectors = scopeFiles.filter(isProjector)
            let projector = matchedProjector(for: orderedWeights, among: projectors, directory: scopeDirectory)
            let mtp = matchedMTP(for: orderedWeights, among: scopeFiles.filter(isMTP), directory: scopeDirectory)
            let sidecars = deduplicatedSidecars(from: scopeFiles.filter(isSidecar))
            return ModelImportPlan(
                primaryWeight: primaryWeight,
                weightFiles: orderedWeights,
                projector: projector,
                mtp: mtp,
                sidecars: sidecars
            )
        }
        .sorted { $0.primaryWeight.path < $1.primaryWeight.path }
    }

    @discardableResult
    static func writeArtifactsJSON(in directory: URL, weightFiles: [URL], projector: URL?, mtp: URL? = nil) -> URL {
        let artifactsURL = directory.appendingPathComponent("artifacts.json")
        var payload: [String: Any] = [:]
        if let primaryWeight = weightFiles.first?.lastPathComponent {
            payload["weights"] = primaryWeight
        }
        if weightFiles.count > 1 {
            payload["weightShards"] = weightFiles.map(\.lastPathComponent)
        }
        payload["mmproj"] = projector?.lastPathComponent ?? NSNull()
        payload["mmprojChecked"] = true
        payload["mtp"] = mtp?.lastPathComponent ?? NSNull()
        payload["mtpChecked"] = true
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: artifactsURL, options: [.atomic])
        }
        return artifactsURL
    }

    private static func collectSelectedWeightFiles(from roots: [URL], fileManager: FileManager) -> [URL] {
        var collected: [String: URL] = [:]

        func add(_ url: URL) {
            collected[url.standardizedFileURL.path] = url
        }

        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let next = enumerator?.nextObject() as? URL {
                    if let values = try? next.resourceValues(forKeys: [.isRegularFileKey]),
                       values.isRegularFile == true,
                       isWeightFile(next) {
                        add(next)
                    }
                }
                continue
            }

            guard isWeightFile(root) else { continue }
            for expanded in siblingWeights(for: root, fileManager: fileManager) {
                add(expanded)
            }
        }

        return collected.values.sorted { $0.path < $1.path }
    }

    private static func siblingWeights(for weight: URL, fileManager: FileManager) -> [URL] {
        guard let split = GGUFShardNaming.parseSplitFilename(weight.lastPathComponent) else {
            return [weight]
        }
        let directory = weight.deletingLastPathComponent()
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let siblings = contents.filter { candidate in
            guard isWeightFile(candidate),
                  let candidateSplit = GGUFShardNaming.parseSplitFilename(candidate.lastPathComponent) else {
                return false
            }
            return candidateSplit.baseStem.caseInsensitiveCompare(split.baseStem) == .orderedSame
                && candidateSplit.partCount == split.partCount
        }
        return siblings.isEmpty ? [weight] : orderedWeightFiles(siblings)
    }

    private static func orderedWeightFiles(_ weights: [URL]) -> [URL] {
        weights.sorted { lhs, rhs in
            let lhsSplit = GGUFShardNaming.parseSplitFilename(lhs.lastPathComponent)
            let rhsSplit = GGUFShardNaming.parseSplitFilename(rhs.lastPathComponent)
            switch (lhsSplit, rhsSplit) {
            case let (l?, r?):
                if l.partIndex != r.partIndex {
                    return l.partIndex < r.partIndex
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private static func scopeFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        var files: [URL] = []
        for entry in contents.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let subfiles = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                files.append(contentsOf: subfiles.filter { candidate in
                    var nestedIsDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: candidate.path, isDirectory: &nestedIsDirectory) else { return false }
                    return !nestedIsDirectory.boolValue
                })
            } else {
                files.append(entry)
            }
        }
        return files
    }

    private static func deduplicatedSidecars(from sidecars: [URL]) -> [URL] {
        var byName: [String: URL] = [:]
        for sidecar in sidecars.sorted(by: { $0.path < $1.path }) {
            byName[sidecar.lastPathComponent.lowercased()] = byName[sidecar.lastPathComponent.lowercased()] ?? sidecar
        }
        return byName.values.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func matchedProjector(for weights: [URL], among projectors: [URL], directory: URL) -> URL? {
        guard !projectors.isEmpty else { return nil }

        if let hinted = hintedProjector(in: directory, among: projectors) {
            return hinted
        }
        if projectors.count == 1 {
            return projectors[0]
        }

        let weightTokens = Set(normalizedTokens(for: weights.first))
        let weightStem = normalizedStem(for: weights.first)

        return projectors.sorted { lhs, rhs in
            let leftScore = projectorScore(lhs, weightTokens: weightTokens, weightStem: weightStem)
            let rightScore = projectorScore(rhs, weightTokens: weightTokens, weightStem: weightStem)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }.first
    }

    private static func matchedMTP(for weights: [URL], among mtpFiles: [URL], directory: URL) -> URL? {
        guard !mtpFiles.isEmpty else { return nil }

        if let hinted = hintedMTP(in: directory, among: mtpFiles) {
            return hinted
        }
        if mtpFiles.count == 1 {
            return mtpFiles[0]
        }

        let weightTokens = Set(normalizedTokens(for: weights.first))
        let weightStem = normalizedStem(for: weights.first)
        return mtpFiles.sorted { lhs, rhs in
            let leftScore = mtpScore(lhs, weightTokens: weightTokens, weightStem: weightStem)
            let rightScore = mtpScore(rhs, weightTokens: weightTokens, weightStem: weightStem)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }.first
    }

    private static func hintedProjector(in directory: URL, among projectors: [URL]) -> URL? {
        let artifactsURL = directory.appendingPathComponent("artifacts.json")
        guard let data = try? Data(contentsOf: artifactsURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = payload["mmproj"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let normalizedHint = raw.replacingOccurrences(of: "\\", with: "/")
        let hintedName = URL(fileURLWithPath: normalizedHint).lastPathComponent.lowercased()
        return projectors.first(where: { candidate in
            let candidatePath = candidate.path.lowercased().replacingOccurrences(of: "\\", with: "/")
            return candidate.lastPathComponent.lowercased() == hintedName
                || candidatePath.hasSuffix(normalizedHint.lowercased())
        })
    }

    private static func hintedMTP(in directory: URL, among mtpFiles: [URL]) -> URL? {
        let artifactsURL = directory.appendingPathComponent("artifacts.json")
        guard let data = try? Data(contentsOf: artifactsURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = payload["mtp"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let normalizedHint = raw.replacingOccurrences(of: "\\", with: "/")
        let hintedName = URL(fileURLWithPath: normalizedHint).lastPathComponent.lowercased()
        return mtpFiles.first(where: { candidate in
            let candidatePath = candidate.path.lowercased().replacingOccurrences(of: "\\", with: "/")
            return candidate.lastPathComponent.lowercased() == hintedName
                || candidatePath.hasSuffix(normalizedHint.lowercased())
        })
    }

    private static func projectorScore(_ candidate: URL, weightTokens: Set<String>, weightStem: String) -> Int {
        let candidateTokens = Set(normalizedTokens(for: candidate))
        var score = weightTokens.intersection(candidateTokens).count * 100
        let candidateStem = normalizedStem(for: candidate)
        if !weightStem.isEmpty, !candidateStem.isEmpty {
            if candidateStem.contains(weightStem) || weightStem.contains(candidateStem) {
                score += 50
            }
        }
        let upper = candidate.lastPathComponent.uppercased()
        if upper.contains("F16") { score += 10 }
        if upper.contains("F32") { score += 8 }
        if candidate.pathExtension.lowercased() == "mmproj" { score += 5 }
        return score
    }

    private static func mtpScore(_ candidate: URL, weightTokens: Set<String>, weightStem: String) -> Int {
        let candidateTokens = Set(normalizedTokens(for: candidate))
        var score = weightTokens.intersection(candidateTokens).count * 100
        let candidateStem = normalizedStem(for: candidate)
        if !weightStem.isEmpty, !candidateStem.isEmpty {
            if candidateStem.contains(weightStem) || weightStem.contains(candidateStem) {
                score += 50
            }
        }
        let lower = candidate.lastPathComponent.lowercased()
        if lower.contains("mtp-") || lower.contains("-mtp") { score += 30 }
        if lower.contains("nextn") { score += 20 }
        if lower.contains("draft") { score += 10 }
        if lower.contains("f16") || lower.contains("f32") { score += 5 }
        return score
    }

    private static func normalizedStem(for url: URL?) -> String {
        guard let url else { return "" }
        let stripped = GGUFShardNaming.strippedShardPath(url.lastPathComponent)
        return URL(fileURLWithPath: stripped)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
    }

    private static func normalizedTokens(for url: URL?) -> [String] {
        let stopwords: Set<String> = [
            "gguf", "mmproj", "projector", "image", "proj", "vision",
            "clip", "siglip", "model", "main", "weights", "weight",
            "mtp", "draft", "nextn",
            "f16", "f32", "bf16", "of"
        ]
        let raw = normalizedStem(for: url)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return raw
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                guard !token.isEmpty else { return false }
                if stopwords.contains(token) { return false }
                if token.allSatisfy(\.isNumber) { return false }
                if token.hasPrefix("q"), token.dropFirst().contains(where: \.isNumber) {
                    return false
                }
                return true
            }
    }
}

private extension ExploreDetailView {
    var heroHeader: some View {
        let name = (detail.id.split(separator: "/").last).map(String.init) ?? detail.id
        let owner = (detail.id.split(separator: "/").first).map(String.init)

        return VStack(alignment: .leading, spacing: 12) {
            Text(name)
                .font(FontTheme.largeTitle)
                .foregroundStyle(AppTheme.text)

            if lowBitOnlyRepository {
                VStack(alignment: .leading, spacing: 6) {
                    Label(LocalizedStringKey("Low-quality quantizations"), systemImage: "exclamationmark.triangle.fill")
                        .font(FontTheme.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.orange)

                    Text(LocalizedStringKey("This repository only includes 1-bit or 2-bit quantizations. They may be degraded compared with higher-bit builds."))
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let owner, owner != name {
                Text(owner)
                    .font(FontTheme.body)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let summary = detail.summary, !summary.isEmpty {
                Text(summary)
                    .font(FontTheme.body)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let parameterCountLabel = detail.parameterCountLabel, !parameterCountLabel.isEmpty {
                Text(parameterCountLabel)
                    .font(FontTheme.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.orange)
            }

            if ExploreModelDetailCache.cachedAt(repoID: detail.id) != nil {
                Label(LocalizedStringKey("Available offline"), systemImage: "externaldrive.fill")
                    .font(FontTheme.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.green)
                    .accessibilityLabel(LocalizedStringKey("Available offline"))
            }

            if UIConstants.showMultimodalUI && detail.isVision {
                Label(LocalizedStringKey("Vision-capable"), systemImage: "eye.fill")
                    .font(FontTheme.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.visionAccent.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.visionAccent)
                    .accessibilityLabel("Vision-capable model")
            }

            if isMoE {
                Label(LocalizedStringKey("Mixture-of-Experts"), systemImage: "circle.grid.3x3.fill")
                    .font(FontTheme.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.moeAccent.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.moeAccent)
                    .accessibilityLabel(LocalizedStringKey("Mixture-of-Experts model"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isMoE: Bool {
        // Depend on metaVersion so the header updates after metadata fetch
        _ = metaVersion
        return detail.isMoE
    }

    private var curatedModelNote: CuratedModelNote? {
        CuratedModelNotes.note(for: detail.id)
    }

    private var moeGuidance: ModelMoEGuidance? {
        _ = metaVersion
        return ModelMoEGuidance.make(for: detail)
    }

    func curatedModelNoteCard(_ note: CuratedModelNote) -> some View {
        infoCard(title: LocalizedStringKey("Curated Notes")) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: note.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(note.titleKey))
                        .font(FontTheme.body.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(LocalizedStringKey(note.bodyKey))
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func moeGuidanceCard(_ guidance: ModelMoEGuidance) -> some View {
        infoCard(title: LocalizedStringKey("MoE Guidance")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(LocalizedStringKey(guidance.summaryKey))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(guidance.metrics) { metric in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: metric.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.moeAccent)
                                .frame(width: 18)

                            Text(LocalizedStringKey(metric.titleKey))
                                .font(FontTheme.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.text)

                            Spacer(minLength: 12)

                            Text(metric.value)
                                .font(FontTheme.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Label(LocalizedStringKey(guidance.cautionKey), systemImage: "exclamationmark.triangle.fill")
                    .font(FontTheme.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Flat, industrial "spec-sheet" section: an uppercase tracked header over a
    // hairline rule, with content flush to the view's margins. No card fill, shadow,
    // or inner padding — those wasted horizontal space and added visual bulk.
    func infoCard<Content: View, Trailing: View>(
        title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer(minLength: 16)
                trailing()
            }

            Rectangle()
                .fill(AppTheme.cardStroke)
                .frame(height: 1)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func infoCard<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        infoCard(title: title, trailing: { EmptyView() }, content: content)
    }

    func quantTile(for quant: QuantInfo) -> some View {
        let remoteStatus = remoteDownloadStatusMap[quant.label]
        let remoteCompleted = remoteStatus?.status == .completed || remoteStatus?.status == .alreadyDownloaded
        let remoteUnsupportedReason: String? = {
            guard isRemoteDownloadMode else { return nil }
            if quant.format != .gguf {
                return String(localized: "Remote endpoint downloads currently support GGUF quantizations only.")
            }
            if let unavailable = remoteModeUnavailableReason {
                return unavailable
            }
            return nil
        }()
        let afmOpenUnavailableReason: String? = {
            guard quant.format == .afm else { return nil }
            let state = AppleFoundationModelAvailability.current
            guard state.isSupportedDevice, !state.isAvailableNow else { return nil }
            return state.unavailableReason?.message
        }()
        return QuantRow(
            canonicalID: detail.id,
            info: quant,
            progress: Binding(
                get: {
                    if isRemoteDownloadMode {
                        return progressMap[quant.label, default: 0]
                    }
                    return progressMap[quant.label, default: 0]
                },
                set: { _ in }
            ),
            speed: Binding(
                get: {
                    if isRemoteDownloadMode {
                        return speedMap[quant.label, default: 0]
                    }
                    return speedMap[quant.label, default: 0]
                },
                set: { _ in }
            ),
            downloading: downloading.contains(quant.label),
            remoteMode: isRemoteDownloadMode,
            remoteStatusText: remoteStatusText(for: quant.label),
            remoteErrorText: remoteDownloadErrorMap[quant.label],
            remoteUnsupportedReason: remoteUnsupportedReason,
            remoteCompleted: remoteCompleted,
            openUnavailableReason: afmOpenUnavailableReason,
            showsLowQualityMarker: quant.isLowBitQuant && !lowBitOnlyRepository,
            downloadController: downloadController,
            openAction: { await useModel(info: quant) },
            downloadAction: { await download(info: quant) },
            cancelAction: { cancelDownload(label: quant.label) }
        )
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuantRowDownloadSnapshot: Equatable {
    var isPresent = false
    var progress = 0.0
    var speed = 0.0
    var status: DownloadJobState?
    var errorDescription: String?
    var isRetryableError = false
    var canPause = false
    var canResume = false
    var completed = false

    init() {}

    init(item: DownloadController.Item) {
        isPresent = true
        // Quantize progress (0.5% steps) and speed (10 KB/s steps) so that
        // removeDuplicates() in the Combine pipeline can actually filter out
        // tiny fluctuations, reducing unnecessary SwiftUI view invalidations.
        progress = (item.progress * 200).rounded() / 200
        speed = (item.speed / 10_000).rounded() * 10_000
        status = item.status
        errorDescription = item.error?.localizedDescription
        isRetryableError = item.error?.isRetryable == true
        canPause = item.canPause
        canResume = item.canResume || item.status == .paused
        completed = item.completed || item.status == .completed
    }
}

@MainActor
private final class QuantRowDownloadObserver: ObservableObject {
    @Published private(set) var snapshot = QuantRowDownloadSnapshot()

    private var cancellable: AnyCancellable?
    private var observedItemID: String?

    func observe(downloadController: DownloadController, itemID: String) {
        guard observedItemID != itemID else { return }
        observedItemID = itemID
        snapshot = Self.snapshot(for: itemID, in: downloadController.items)

        cancellable = downloadController.itemsPublisher
            .map { Self.snapshot(for: itemID, in: $0) }
            .removeDuplicates()
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] snapshot in
                self?.snapshot = snapshot
            }
    }

    private static func snapshot(for itemID: String, in items: [DownloadController.Item]) -> QuantRowDownloadSnapshot {
        guard let item = items.first(where: { $0.id == itemID }) else {
            return QuantRowDownloadSnapshot()
        }
        return QuantRowDownloadSnapshot(item: item)
    }
}

struct QuantRow: View {
    let canonicalID: String
    let info: QuantInfo
    @Binding var progress: Double
    @Binding var speed: Double
    let downloading: Bool
    let remoteMode: Bool
    let remoteStatusText: String?
    let remoteErrorText: String?
    let remoteUnsupportedReason: String?
    let remoteCompleted: Bool
    let openUnavailableReason: String?
    let showsLowQualityMarker: Bool
    let downloadController: DownloadController
    let openAction: () async -> Void
    let downloadAction: () async -> Void
    let cancelAction: () -> Void
    @EnvironmentObject var modelManager: AppModelManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var localDownloadObserver = QuantRowDownloadObserver()
    @State private var showQuantTypeInfo = false
    @State private var showDownloadPlan = false

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    var body: some View {
        Group {
#if os(macOS)
            regularLayout
#else
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
#endif
        }
        .padding(.vertical, 4)
        .onAppear {
            localDownloadObserver.observe(downloadController: downloadController, itemID: itemID)
        }
        .onChangeCompat(of: itemID) { _, newValue in
            localDownloadObserver.observe(downloadController: downloadController, itemID: newValue)
        }
    }

    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                metadataBlock
                    .layoutPriority(1)
                Spacer(minLength: 8)
                suitabilityBadge
                trailingControls
            }
            if showDownloadPlan {
                DownloadPlanPreview(rootTitle: info.label, plan: downloadPlan, byteCountFormatter: Self.byteCountFormatter)
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataBlock
            if remoteMode && remoteStatusNeedsStackedLayout {
                HStack(alignment: .center, spacing: 10) {
                    suitabilityBadge
                    Spacer(minLength: 8)
                }
                remoteTrailingControls
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    suitabilityBadge
                    Spacer(minLength: 8)
                    trailingControls
                }
            }
            if showDownloadPlan {
                DownloadPlanPreview(rootTitle: info.label, plan: downloadPlan, byteCountFormatter: Self.byteCountFormatter)
            }
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayTitle)
                    .font(FontTheme.body)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if coreAIFamily?.isRecommendedOnThisDevice == true {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .help(LocalizedStringKey("Recommended for this device"))
                        .accessibilityLabel(LocalizedStringKey("Recommended for this device"))
                }
                if showsLowQualityMarker {
                    lowQualityQuantBadge
                }
            }
            .lineLimit(2)

            HStack(spacing: 4) {
                quantMetaButton
                downloadPlanToggle
            }

            if let coreAIFamily {
                Text(coreAIFamily.caption)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Core AI labels carry the family as a "family/" prefix; the meta line
    /// already names the family, so the title shows just the bundle stem.
    private var displayTitle: String {
        guard info.format == .coreai, let slash = info.label.lastIndex(of: "/") else {
            return info.label
        }
        let stem = String(info.label[info.label.index(after: slash)...])
        return stem.isEmpty ? info.label : stem
    }

    private var downloadPlanToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                showDownloadPlan.toggle()
            }
        } label: {
            Image(systemName: showDownloadPlan ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey("Download Plan"))
        .accessibilityLabel(LocalizedStringKey("Download Plan"))
        .accessibilityValue(showDownloadPlan ? Text(LocalizedStringKey("Expanded")) : Text(LocalizedStringKey("Collapsed")))
    }

    private var coreAIFamily: CoreAIBundleFamily? {
        guard info.format == .coreai else { return nil }
        return CoreAIBundleFamily.detect(from: info.label)
    }

    private var lowQualityQuantBadge: some View {
        Label(LocalizedStringKey("Low quality"), systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var suitabilityBadge: some View {
        let defaultCtx = 4096
        let assessment = ModelDeviceFitAdvisor.assess(
            format: info.format,
            sizeBytes: info.sizeBytes,
            contextLength: defaultCtx,
            layerCount: nil,
            benchmark: installedBenchmarkResult
        )
        
        let labelText: String = {
            switch assessment.status {
            case .works: return "FITS"
            case .tight: return "TIGHT FIT"
            case .unlikely: return "DOESN'T FIT"
            }
        }()
        
        let color: Color = {
            switch assessment.status {
            case .works: return Color.green
            case .tight: return Color.orange
            case .unlikely: return Color.red
            }
        }()

        Text(LocalizedStringKey(labelText))
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(color.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.2), lineWidth: 0.5)
            )
            .help(LocalizedStringKey("Device fit assessment"))
    }

    @ViewBuilder
    private var trailingControls: some View {
        if remoteMode {
            remoteTrailingControls
        } else if localDownloadSnapshot.isPresent && !localDownloadSnapshot.completed {
            VStack(spacing: 8) {
                if let error = localDownloadSnapshot.errorDescription {
                    // Show error state
                    VStack {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: downloadColumnWidth)
                    .padding(.leading, 4)
                } else {
                    // Show normal progress
                    // Give the macOS layout extra width so the progress bar matches the tile span.
                    VStack(alignment: .trailing, spacing: 4) {
                        if let localStatusText, !localStatusText.isEmpty {
                            Text(localStatusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        ModernDownloadProgressView(progress: displayedProgress, speed: displayedSpeed)
                    }
                    .frame(width: downloadColumnWidth)
                    .padding(.leading, 4)
                }
                HStack {
                    Spacer()
                    
                    if localDownloadSnapshot.isRetryableError {
                        // Show retry button for network errors
                        Button(action: { downloadController.resume(itemID: itemID) }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(LocalizedStringKey("Retry download"))
                    } else if localDownloadSnapshot.status == .paused || localDownloadSnapshot.canResume {
                        // Show resume button for intentionally paused downloads
                        Button(action: { downloadController.resume(itemID: itemID) }) {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderless)
                    } else if localDownloadSnapshot.canPause {
                        // Show pause button for active downloads
                        Button(action: { downloadController.pause(itemID: itemID) }) {
                            Image(systemName: "pause.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    
                    Button(action: cancelAction) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } else if isDownloaded {
            VStack {
                Label(LocalizedStringKey("Ready"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.badge)
                    .foregroundColor(.green)
                if let reason = openUnavailableReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: downloadColumnWidth)
                        .multilineTextAlignment(.center)
                }
                Button(LocalizedStringKey("Open")) { Task { await openAction() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(openUnavailableReason != nil)
            }
        } else {
            Button(LocalizedStringKey("Download")) { Task { await downloadAction() } }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var remoteTrailingControls: some View {
        let alignment: HorizontalAlignment = (isCompactLayout && remoteStatusNeedsStackedLayout) ? .leading : .trailing
        let textAlignment: TextAlignment = (isCompactLayout && remoteStatusNeedsStackedLayout) ? .leading : .trailing
        if let unsupported = remoteUnsupportedReason {
            VStack(alignment: alignment, spacing: 4) {
                Label(LocalizedStringKey("Unavailable"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(unsupported)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(textAlignment)
            }
        } else if downloading {
            VStack(alignment: alignment, spacing: 6) {
                if let remoteStatusText, !remoteStatusText.isEmpty {
                    Text(remoteStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(textAlignment)
                }
                ModernDownloadProgressView(progress: displayedProgress, speed: displayedSpeed)
                    .frame(
                        maxWidth: (isCompactLayout && remoteStatusNeedsStackedLayout) ? .infinity : downloadColumnWidth,
                        alignment: (isCompactLayout && remoteStatusNeedsStackedLayout) ? .leading : .trailing
                    )
            }
        } else if let remoteErrorText, !remoteErrorText.isEmpty {
            VStack(alignment: alignment, spacing: 6) {
                Text(remoteErrorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .multilineTextAlignment(textAlignment)
                Button(LocalizedStringKey("Retry")) { Task { await downloadAction() } }
                    .buttonStyle(.bordered)
            }
        } else if remoteCompleted {
            Label(LocalizedStringKey("Downloaded on Remote Endpoint"), systemImage: "checkmark.circle.fill")
                .labelStyle(.badge)
                .foregroundColor(.green)
        } else {
            Button(LocalizedStringKey("Download")) { Task { await downloadAction() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var isDownloaded: Bool {
        modelManager.downloadedModels.contains { $0.modelID == canonicalID && $0.quant == info.label }
    }

    private var installedBenchmarkResult: ModelBenchmarkResult? {
        guard let model = modelManager.downloadedModels.first(where: { $0.modelID == canonicalID && $0.quant == info.label }) else {
            return nil
        }
        return ModelBenchmarkResultStore.result(for: model)?.result
    }

    private var itemID: String {
        "\(canonicalID)-\(info.label)"
    }

    private var localDownloadSnapshot: QuantRowDownloadSnapshot {
        localDownloadObserver.snapshot
    }

    private var displayedProgress: Double {
        remoteMode ? progress : localDownloadSnapshot.progress
    }

    private var displayedSpeed: Double {
        remoteMode ? speed : localDownloadSnapshot.speed
    }

    private var localStatusText: String? {
        guard localDownloadSnapshot.errorDescription == nil else { return nil }
        return localDownloadSnapshot.status?.statusLabelKey
    }

    private var downloadColumnWidth: CGFloat {
#if os(macOS)
        return 320
#else
        return 104
#endif
    }

    private var isCompactLayout: Bool {
#if os(macOS)
        return false
#else
        return horizontalSizeClass == .compact
#endif
    }

    private var remoteStatusNeedsStackedLayout: Bool {
        if let reason = remoteUnsupportedReason, !reason.isEmpty { return true }
        if let error = remoteErrorText, !error.isEmpty { return true }
        return downloading
    }

    private var sizeText: String {
        guard info.sizeBytes > 0 else {
            return String(localized: "Unknown size")
        }
        return Self.byteCountFormatter.string(fromByteCount: info.sizeBytes)
    }

    private var speedText: String {
        guard speed > 0 else { return "--" }
        let kb = speed / 1024
        if kb > 1024 { return String(format: "%.1f MB/s", kb / 1024) }
        return String(format: "%.0f KB/s", kb)
    }

    private var downloadPlan: ModelDownloadPlan {
        ModelDownloadPlan.make(for: info)
    }

    private var quantMetaButton: some View {
        let descriptor = info.quantTypeDescriptor
        return Button(action: { showQuantTypeInfo = true }) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(info.format.tagGradient)
                        .frame(width: 5, height: 5)
                    Text(info.format.displayName.uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(AppTheme.text.opacity(0.85))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )

                if let coreAIFamily {
                    Text(coreAIFamily.displayName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                
                Text(sizeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey("Quant type details"))
        .popover(isPresented: $showQuantTypeInfo) {
            VStack(alignment: .leading, spacing: 10) {
                Text(descriptor.title)
                    .font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical, showsIndicators: true) {
                    Text(descriptor.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)

                HStack {
                    Spacer()
                    Button(LocalizedStringKey("OK")) { showQuantTypeInfo = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .lineLimit(nil)
            .frame(maxWidth: 360, alignment: .leading)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

}

private struct DownloadPlanPreview: View {
    let rootTitle: String
    let plan: ModelDownloadPlan
    let byteCountFormatter: ByteCountFormatter

    private var dependencyGraph: ModelDependencyGraph {
        ModelDependencyGraph.make(rootTitle: rootTitle, plan: plan)
    }

    private var visibleEntries: [ModelDownloadPlan.Entry] {
        Array(plan.entries.prefix(6))
    }

    private var hiddenCount: Int {
        max(0, plan.entries.count - visibleEntries.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(LocalizedStringKey("Download Plan"), systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Spacer(minLength: 8)
                Text(totalText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 6) {
                ForEach(visibleEntries) { entry in
                    DownloadPlanEntryView(entry: entry, byteCountFormatter: byteCountFormatter)
                }
            }

            if hiddenCount > 0 {
                Text(String.localizedStringWithFormat(String(localized: "%d more install items"), hiddenCount))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if plan.installTimeCheckCount > 0 {
                Text(LocalizedStringKey("Some sidecars are checked during install."))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DownloadDependencyGraphView(graph: dependencyGraph)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalText: String {
        let size = plan.knownTotalBytes > 0
            ? byteCountFormatter.string(fromByteCount: plan.knownTotalBytes)
            : String(localized: "Size unknown")
        let files = String.localizedStringWithFormat(String(localized: "%d known files"), plan.knownFileCount)
        if plan.unknownSizeCount > 0 {
            return String.localizedStringWithFormat(String(localized: "%@ · %@ · %d unknown sizes"), size, files, plan.unknownSizeCount)
        }
        return "\(size) · \(files)"
    }
}

private struct DownloadDependencyGraphView: View {
    let graph: ModelDependencyGraph

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(LocalizedStringKey("Dependency Graph"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.text)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    dependencyNode(graph.root)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .padding(.top, 10)
                    VStack(alignment: .leading, spacing: 5) {
                        dependencyGroup(
                            title: "Required",
                            systemImage: "checkmark.seal.fill",
                            nodes: graph.requiredDependencies
                        )
                        dependencyGroup(
                            title: "Optional",
                            systemImage: "plus.circle",
                            nodes: graph.optionalDependencies
                        )
                        dependencyGroup(
                            title: "Install checks",
                            systemImage: "magnifyingglass",
                            nodes: graph.installChecks
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func dependencyGroup(title: LocalizedStringKey, systemImage: String, nodes: [ModelDependencyGraph.Node]) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(nodes.isEmpty ? AppTheme.secondaryText.opacity(0.7) : AppTheme.text)
                .frame(width: 94, alignment: .leading)
            if nodes.isEmpty {
                Text(LocalizedStringKey("None"))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                HStack(spacing: 5) {
                    ForEach(nodes.prefix(4)) { node in
                        dependencyNode(node)
                    }
                    if nodes.count > 4 {
                        Text("+\(nodes.count - 4)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                    }
                }
            }
        }
    }

    private func dependencyNode(_ node: ModelDependencyGraph.Node) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconName(for: node))
                .font(.caption2.weight(.semibold))
            Text(nodeTitle(for: node))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(foregroundColor(for: node))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(backgroundColor(for: node), in: Capsule())
        .accessibilityLabel(Text(nodeTitle(for: node)))
        .accessibilityValue(Text(node.detail))
    }

    private func nodeTitle(for node: ModelDependencyGraph.Node) -> String {
        guard node.role != .root else { return String(localized: "Selected quant") }
        if let entryKind = node.entryKind {
            return title(for: entryKind)
        }
        return node.title
    }

    private func title(for kind: ModelDownloadPlan.Entry.Kind) -> String {
        switch kind {
        case .weights, .weightShard:
            return String(localized: "Weights")
        case .config:
            return String(localized: "Config")
        case .importanceMatrix:
            return String(localized: "iMatrix")
        case .mtp:
            return String(localized: "MTP")
        case .tokenizer:
            return String(localized: "Tokenizer")
        case .template:
            return String(localized: "Template")
        case .processor:
            return String(localized: "Processor")
        case .projector:
            return String(localized: "Projector")
        case .params:
            return String(localized: "Params")
        }
    }

    private func iconName(for node: ModelDependencyGraph.Node) -> String {
        switch node.role {
        case .root:
            return "cube"
        case .required:
            return "checkmark.circle.fill"
        case .optional:
            return "plus.circle"
        case .installCheck:
            return "magnifyingglass"
        }
    }

    private func foregroundColor(for node: ModelDependencyGraph.Node) -> Color {
        switch node.role {
        case .root:
            return Color.accentColor
        case .required:
            return AppTheme.text
        case .optional, .installCheck:
            return AppTheme.secondaryText
        }
    }

    private func backgroundColor(for node: ModelDependencyGraph.Node) -> Color {
        switch node.role {
        case .root:
            return Color.accentColor.opacity(0.12)
        case .required:
            return Color.green.opacity(0.12)
        case .optional:
            return Color.secondary.opacity(0.10)
        case .installCheck:
            return Color.orange.opacity(0.12)
        }
    }
}

private struct DownloadPlanEntryView: View {
    let entry: ModelDownloadPlan.Entry
    let byteCountFormatter: ByteCountFormatter

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: iconName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(kindTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                        .lineLimit(1)
                    if entry.isRequired {
                        Text(LocalizedStringKey("Required"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.red)
                            .lineLimit(1)
                    }
                }
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var kindTitle: LocalizedStringKey {
        switch entry.kind {
        case .weights, .weightShard:
            return "Weights"
        case .config:
            return "Config"
        case .importanceMatrix:
            return "iMatrix"
        case .mtp:
            return "MTP"
        case .tokenizer:
            return "Tokenizer"
        case .template:
            return "Template"
        case .processor:
            return "Processor"
        case .projector:
            return "Projector"
        case .params:
            return "Params"
        }
    }

    private var detailText: String {
        let sizeText: String
        if let size = entry.sizeBytes, size > 0 {
            sizeText = byteCountFormatter.string(fromByteCount: size)
        } else if entry.isResolvedDuringInstall {
            sizeText = String(localized: "Install-time check")
        } else {
            sizeText = String(localized: "Size unknown")
        }
        return "\(entry.relativePath) · \(sizeText)"
    }

    private var iconName: String {
        switch entry.kind {
        case .weights, .weightShard:
            return "shippingbox"
        case .config, .params:
            return "doc.text"
        case .importanceMatrix:
            return "slider.horizontal.3"
        case .mtp:
            return "forward.end.fill"
        case .tokenizer:
            return "textformat.abc"
        case .template:
            return "text.bubble"
        case .processor, .projector:
            return "photo"
        }
    }

    private var iconColor: Color {
        entry.isResolvedDuringInstall ? AppTheme.secondaryText : Color.accentColor
    }
}

#if canImport(LeapSDK)
struct LeapRowView: View {
    let entry: LeapCatalogEntry
    let titleLineLimit: Int?
    let openAction: (LeapCatalogEntry, URL, ModelRunner) -> Void
    @EnvironmentObject var downloadController: DownloadController
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var chatVM: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @State private var state: LeapBundleDownloader.State = .notInstalled
    @State private var progress = 0.0
    @State private var speed = 0.0
    @State private var expectedBytes: Int64 = 0
    private let downloader = LeapBundleDownloader.shared

    init(
        entry: LeapCatalogEntry,
        titleLineLimit: Int? = nil,
        openAction: @escaping (LeapCatalogEntry, URL, ModelRunner) -> Void
    ) {
        self.entry = entry
        self.titleLineLimit = titleLineLimit
        self.openAction = openAction
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(FontTheme.body)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.text)
                    .lineLimit(titleLineLimit)
                
                HStack(spacing: 6) {
                    formatPill(entry.sourceFormatLabel)

                    Text(subtitleText)
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    
                    if entry.sizeBytes > 0 {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText)
                        
                        ModelRAMAdvisor.badge(format: .et, sizeBytes: entry.sizeBytes, contextLength: 4096, layerCount: nil)
                            .scaleEffect(0.9)
                    }
                }
            }
            
            Spacer()
            
            actionButton
        }
        .padding(.vertical, 8)
        .onAppear { refresh() }
        .onReceive(downloadController.leapItemsPublisher) { _ in
            if let item = downloadController.leapItems.first(where: { $0.id == entry.slug }) {
                progress = item.progress
                speed = item.speed
                if item.expectedBytes > 0 { expectedBytes = item.expectedBytes }
                state = .downloading(progress)
            } else {
                refresh()
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notInstalled:
            Button(action: { start() }) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Download"))
            
        case .failed(let msg):
            Button(action: { start() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    if msg == "Paused" {
                        Text("Resume")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            
        case .downloading(let p):
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(p * 100))%")
                        .font(FontTheme.caption)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(speedText(speed))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.01, p)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 24, height: 24)
                
                Button(action: { downloadController.cancel(itemID: entry.slug) }) {
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
            
        case .installed:
            Button(action: { load() }) {
                Text("Open")
                    .font(FontTheme.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func refresh() {
        Task { @MainActor in
            state = await downloader.statusAsync(for: entry)
            if case .downloading(let p) = state { progress = p }
        }
    }

    private var sizeText: String {
        let bytes = expectedBytes > 0 ? expectedBytes : entry.sizeBytes
        if bytes <= 0 { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var subtitleText: String {
        var parts: [String] = []
        if !entry.quantization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(entry.quantization)
        }
        let size = sizeText
        if !size.isEmpty { parts.append(size) }
        if !parts.isEmpty { return parts.joined(separator: " • ") }
        return entry.slug
    }

    private func speedText(_ speed: Double) -> String {
        guard speed > 0 else { return "--" }
        let kb = speed / 1024
        if kb > 1024 { return String(format: "%.1f MB/s", kb / 1024) }
        return String(format: "%.0f KB/s", kb)
    }

    @ViewBuilder
    private func formatPill(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .foregroundStyle(AppTheme.secondaryText)
    }

    private func start() {
        downloadController.startLeap(entry: entry)
    }

    private func load() {
        guard case .installed(let url) = state else { return }
        Task { @MainActor in
            var settings = modelManager
                .downloadedModels
                .first(where: {
                    $0.modelID == entry.modelID
                    && $0.quant.caseInsensitiveCompare(entry.quantization) == .orderedSame
                })
                .map { modelManager.settings(for: $0) }
            ?? ModelSettings.default(for: .et)
            settings.contextLength = max(1, settings.contextLength)

            if let slmGGUF = SLMArtifactResolver.ggufURLIfPresent(for: url) {
                let success = await chatVM.load(url: slmGGUF, settings: settings, format: .gguf, forceReload: true)
                if success {
                    let architectureLabels = LocalModel.architectureLabels(for: slmGGUF, format: .et, modelID: entry.modelID)
                    let local = modelManager.downloadedModels.first(where: { $0.modelID == entry.modelID && $0.quant.caseInsensitiveCompare(entry.quantization) == .orderedSame }) ??
                        LocalModel(
                            modelID: entry.modelID,
                            name: entry.displayName,
                            url: slmGGUF,
                            quant: entry.quantization,
                            architecture: architectureLabels.display,
                            architectureFamily: architectureLabels.family,
                            format: .et,
                            sizeGB: Double(entry.sizeBytes) / 1_073_741_824.0,
                            isMultimodal: entry.isVision,
                            isToolCapable: true,
                            isDownloaded: true,
                            downloadDate: Date(),
                            lastUsedDate: nil,
                            isFavourite: false,
                            totalLayers: 0,
                            moeInfo: nil
                        )
                    modelManager.updateSettings(settings, for: local)
                    modelManager.markModelUsed(local)
                    tabRouter.selection = .chat
                } else {
                    state = .failed(chatVM.loadError ?? "Load failed")
                }
                return
            }

            chatVM.loadingProgressTracker.startLoading(for: .et)
            chatVM.loadingProgressTracker.reportBackendProgress(0.12)
            defer { chatVM.loadingProgressTracker.completeLoading() }
            do {
                LeapBundleDownloader.sanitizeBundleIfNeeded(at: url)
                chatVM.loadingProgressTracker.reportBackendProgress(0.25)
                let runner = try await LeapRunnerLoader.load(url: url, settings: settings)
                chatVM.loadingProgressTracker.reportBackendProgress(0.88)
                openAction(entry, url, runner)
                chatVM.loadingProgressTracker.reportBackendProgress(0.95)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
#endif

private enum QuantSortOption: String, CaseIterable, Identifiable {
    case quant
    case sizeSmall
    case sizeLarge

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .quant: return LocalizedStringKey("Quant")
        case .sizeSmall: return LocalizedStringKey("Size ↑")
        case .sizeLarge: return LocalizedStringKey("Size ↓")
        }
    }
}

struct ReadmeCollapseView: View {
    let markdown: String?
    let loading: Bool
    let retry: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading) {
            if let md = markdown {
                if expanded {
                    Text((try? AttributedString(markdown: md, options: .init(interpretedSyntax: .full))) ?? AttributedString(md))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text((try? AttributedString(markdown: preview(from: md), options: .init(interpretedSyntax: .full))) ?? AttributedString(preview(from: md)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(
                            LinearGradient(colors: [.clear, Color(.systemBackground)],
                                           startPoint: .center, endPoint: .bottom)
                                .allowsHitTesting(false)
                        )
                }
            } else if loading {
                ProgressView()
            } else {
                Button("Retry") { retry() }
            }
        }
        .onTapGesture { withAnimation { expanded.toggle() } }
    }

    private func preview(from md: String) -> String {
        let lines = md.split(separator: "\n")
        return lines.prefix(3).joined(separator: "\n")
    }
}

#endif
