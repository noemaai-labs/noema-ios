import Combine
import NoemaPackages
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS)

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
#if os(macOS)
    @State private var detailModalID: UUID?
#endif
    @State private var loadingDetail = false
    @State private var openingModelId: String?
    @State private var showAllCuratedModels = false
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
                await vm.loadTrending(format: trendingFormat)
            }
            .onChangeCompat(of: effectiveSearchMode) { _, _ in
                showAllCuratedModels = false
                Task { await vm.loadTrending(force: true, format: trendingFormat) }
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
                } else if let id = macModalPresenter.presentation?.id, id == detailModalID {
                    selectedFormatFilter = nil
                    macModalPresenter.dismiss()
                }
            }
#else
            .sheet(item: $selected, onDismiss: {
                selectedFormatFilter = nil
            }, content: detailSheet)
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
                chromeState.importGGUFAction = { presentImporter(.gguf) }
                chromeState.importMLXAction = { presentImporter(.mlx) }
                chromeState.isImportVisible = true
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
                chromeState.importGGUFAction = nil
                chromeState.importMLXAction = nil
                chromeState.isImportVisible = false
                guard chromeState.activeSection == .models else { return }
                chromeState.toggleAction = nil
                chromeState.isSearchVisible = false
                chromeState.searchSubmitAction = nil
                chromeState.activeSection = nil
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
                case .exploreET:
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
                .padding(.vertical, exploreCardVerticalPadding)
                .padding(.horizontal, AppTheme.padding)
            Divider()
        }
    }

#if os(macOS)
    private var exploreCardVerticalPadding: CGFloat { 8 }
#else
    private var exploreCardVerticalPadding: CGFloat { 12 }
#endif

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
                detailModalID = nil
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
        detailModalID = macModalPresenter.presentation?.id
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
        standardSections
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
                .buttonStyle(.industrial(.quiet))
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

    @ViewBuilder
    private var heroSection: some View {
        if vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 24) {
#if !os(macOS)
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey("Discover Intelligence"))
                        .font(FontTheme.largeTitle)
                        .foregroundStyle(AppTheme.text)
                    Text(LocalizedStringKey("Explore the latest open-source models optimized for your Mac."))
                        .font(FontTheme.body)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.bottom, 8)
#endif

                let allFeaturedModels = allFilteredRecommended
                let featuredModels = filteredRecommended
                if !allFeaturedModels.isEmpty {
#if os(macOS)
                    VStack(alignment: .leading, spacing: 0) {
                        curatedCatalogHeader(
                            visibleCount: featuredModels.count,
                            totalCount: allFeaturedModels.count
                        )
                        ForEach(Array(featuredModels.enumerated()), id: \.element.id) { index, featured in
                            IndustrialHoverRow {
                                featuredCard(featured)
                            }
                            if index < featuredModels.count - 1 {
                                IndustrialHairline().padding(.leading, 10)
                            }
                        }
                    }
#else
                    VStack(alignment: .leading, spacing: 8) {
                        curatedCatalogHeader(
                            visibleCount: featuredModels.count,
                            totalCount: allFeaturedModels.count
                        )
                        VStack(spacing: 0) {
                            ForEach(Array(featuredModels.enumerated()), id: \.element.id) { index, featured in
                                featuredCard(featured)
                                if index < featuredModels.count - 1 {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                    }
#endif
                }

                if effectiveSearchMode == .gguf {
                    OverfitModelCollectionLink {
                        Task { await open(Self.overfitCatalogRecord) }
                    }
                }

                let trendingModels = filteredTrending
                if !trendingModels.isEmpty {
#if os(macOS)
                    VStack(alignment: .leading, spacing: 0) {
                        IndustrialSectionHeader("Trending this week", detail: "\(trendingModels.count)")
                        ForEach(Array(trendingModels.enumerated()), id: \.element.id) { index, record in
                            IndustrialHoverRow {
                                featuredCard(record)
                            }
                            if index < trendingModels.count - 1 {
                                IndustrialHairline().padding(.leading, 10)
                            }
                        }
                    }
#else
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey("Trending this week"))
                            .font(FontTheme.body.weight(.semibold))
                            .foregroundStyle(AppTheme.text)
                        VStack(spacing: 0) {
                            ForEach(Array(trendingModels.enumerated()), id: \.element.id) { index, record in
                                featuredCard(record)
                                if index < trendingModels.count - 1 {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                    }
#endif
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func curatedCatalogHeader(visibleCount: Int, totalCount: Int) -> some View {
        let countText = String.localizedStringWithFormat(
            String(localized: "Showing %d of %d models"),
            visibleCount,
            totalCount
        )
        let title: LocalizedStringKey = showAllCuratedModels ? "Featured" : "Fits on your device"

#if os(macOS)
        IndustrialSectionHeader(title, detail: countText) {
            curatedVisibilityButton
        }
#else
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FontTheme.body.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text(countText)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer(minLength: 8)
            curatedVisibilityButton
        }
#endif
    }

    private var curatedVisibilityButton: some View {
        Button {
            withAnimation(.snappy) {
                showAllCuratedModels.toggle()
            }
        } label: {
            Label(
                showAllCuratedModels
                    ? LocalizedStringKey("Show only models that fit")
                    : LocalizedStringKey("Show all models"),
                systemImage: showAllCuratedModels ? "line.3.horizontal.decrease.circle.fill" : "eye.fill"
            )
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityValue(showAllCuratedModels ? LocalizedStringKey("Show all models") : LocalizedStringKey("Fits on your device"))
    }

    private func featuredCard(_ featured: ModelRecord) -> some View {
        Button { Task { await open(featured) } } label: {
#if os(macOS)
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(featured.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.text)
                        .lineLimit(1)
                    Text(featured.publisher)
                        .textCase(.uppercase)
                        .industrialStat()
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if featured.pipeline_tag == "image-text-to-text" {
                    ExploreVisionCapabilityBadge()
                }
                if showsFitsBadge(for: featured) {
                    IndustrialBadge("Fits", tint: .green)
                } else if showAllCuratedModels && curatedFitStatus(for: featured) == .tooLarge {
                    IndustrialBadge("May not fit", tint: .orange)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.3))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
#else
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
                    ExploreVisionCapabilityBadge()
                }
                if showsFitsBadge(for: featured) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                        .help(LocalizedStringKey("Fits on your device"))
                } else if showAllCuratedModels && curatedFitStatus(for: featured) == .tooLarge {
                    recordBadge(LocalizedStringKey("May not fit"), tint: .orange)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
#endif
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
            Section {
                heroSection
                    .padding(.horizontal, 0)
                    .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: AppTheme.padding, bottom: 0, trailing: AppTheme.padding))
            #endif
        } else {
            #if os(macOS)
            VStack(alignment: .leading, spacing: 8) {
                IndustrialSectionHeader(
                    "Results",
                    detail: filteredSearchResults.isEmpty ? nil : "\(filteredSearchResults.count)"
                )
                LazyVStack(spacing: 0) {
                    ForEach(filteredSearchResults, id: \._stableKey) { record in
                        exploreCard {
                            IndustrialHoverRow {
                                recordButton(record, context: .search).buttonStyle(.plain)
                            }
                        }
                    }
                    if vm.canLoadMore {
                        ProgressView().onAppear { vm.loadNextPage() }
                    }
                }
            }
            #elseif os(visionOS)
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
    
    private var trendingFormat: ModelFormat? {
        switch effectiveSearchMode {
        case .gguf: return .gguf
        case .mlx: return .mlx
        default: return nil
        }
    }

    /// Trending Hub repos for the active format, minus anything already
    /// featured, capped so the section stays a shelf rather than a feed.
    private var filteredTrending: [ModelRecord] {
        let featuredIDs = Set(allFilteredRecommended.map(\.id))
        let mode = effectiveSearchMode
        var seen = Set<String>()
        let matches = vm.trendingRecords.filter { rec in
            guard seen.insert(rec.id).inserted else { return false }
            guard !featuredIDs.contains(rec.id) else { return false }
            return mode.includes(rec) && filterManager.shouldIncludeModel(rec)
        }
        return Array(matches.prefix(8))
    }

    private var allFilteredRecommended: [ModelRecord] {
        var seen = Set<String>()
        let mode = effectiveSearchMode
        let matches = vm.recommended.filter { rec in
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

            return mode.includes(rec)
                && filterManager.shouldIncludeModel(rec)
        }
        return matches.sorted { lhs, rhs in
            let lhsIsNoema = lhs.id == "NoemaAI-labs/Noema-2B-GGUF"
            let rhsIsNoema = rhs.id == "NoemaAI-labs/Noema-2B-GGUF"
            if lhsIsNoema != rhsIsNoema { return lhsIsNoema }

            let lhsRAM = lhs.minimumRAMBytes(for: mode.formatFilter) ?? Int64.max
            let rhsRAM = rhs.minimumRAMBytes(for: mode.formatFilter) ?? Int64.max
            if lhsRAM != rhsRAM { return lhsRAM < rhsRAM }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var filteredRecommended: [ModelRecord] {
        let matches = allFilteredRecommended
        guard !showAllCuratedModels else { return matches }
        return matches.filter {
            CuratedModelDeviceFit.shouldShowByDefault(
                $0,
                format: effectiveSearchMode.formatFilter
            )
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
        curatedFitStatus(for: record) == .fits
    }

    private func curatedFitStatus(for record: ModelRecord) -> CuratedModelDeviceFit.Status {
        CuratedModelDeviceFit.status(for: record, format: effectiveSearchMode.formatFilter)
    }

    @ViewBuilder
    private func recordButton(_ record: ModelRecord, context: RecordBadgeContext) -> some View {
        let showsVisionEye = context == .search
        let showsVisionLabel = context == .curated

        Button { Task { await open(record) } } label: {
            HStack(alignment: .center, spacing: recordRowIconSpacing) {
#if os(macOS)
                Circle()
                    .fill(context == .cached ? Color.orange : Color.accentColor)
                    .frame(width: 6, height: 6)
#else
                Image(systemName: context == .cached ? "clock.arrow.circlepath" : "cube.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(context == .cached ? Color.orange : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        (context == .cached ? Color.orange : Color.accentColor).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
#endif

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(record.displayName)
                            .font(FontTheme.body.weight(.medium))
                            .foregroundStyle(AppTheme.text)
                            .lineLimit(1)
                        
                        if UIConstants.showMultimodalUI && !record.formats.contains(.afm) {
                            if record.pipeline_tag == "image-text-to-text" {
                                if showsVisionEye {
                                    ExploreVisionCapabilityBadge()
                                }
                            } else {
                                VisionBadge(repoId: record.id, token: huggingFaceToken, showsIcon: showsVisionEye)
                            }
                        }
                        
                        if showsFitsBadge(for: record) {
                            recordBadge(LocalizedStringKey("Fits"), tint: .green)
                        }

                        if context == .cached {
                            recordBadge(LocalizedStringKey("Offline cache"), tint: .orange)
                        }

                        if showsVisionLabel && record.pipeline_tag == "image-text-to-text" {
                            recordBadge(LocalizedStringKey("Vision"), tint: .purple)
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

#if os(macOS)
    private var recordRowIconSpacing: CGFloat { 10 }
#else
    private var recordRowIconSpacing: CGFloat { 14 }
#endif

    @ViewBuilder
    private func recordBadge(_ title: LocalizedStringKey, tint: Color) -> some View {
#if os(macOS)
        IndustrialBadge(title, tint: tint)
#else
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
#endif
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

    private static let overfitCatalogRecord = ModelRecord(
        id: "NoemaAI-labs/Noema-Overfit",
        displayName: "Noema Overfit",
        publisher: "Noema",
        summary: nil,
        hasInstallableQuant: true,
        formats: [.gguf],
        installed: false,
        tags: ["gguf", "noema", "paged", "moe"],
        pipeline_tag: "text-generation",
        minRAMBytes: nil,
        supportsVision: false
    )

    private var afmUnavailableReasonForOpen: String? {
        guard afmAvailabilityState.isSupportedDevice else {
            return String(localized: "Apple Foundation Models are not supported on this device.")
        }
        guard !afmAvailabilityState.isAvailableNow else { return nil }
        return afmAvailabilityState.unavailableReason?.message
    }

}

/// A single, deliberate entry point for the paged-model catalog. It opens the
/// live Hub repo inside Explore so its packages use Noema's download pipeline.
private struct OverfitModelCollectionLink: View {
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false
#if os(macOS)
    @State private var isHovering = false
#endif

    var body: some View {
        Button(action: onOpen) {
#if os(macOS)
            macContent
#else
            touchContent
#endif
        }
        .buttonStyle(OverfitCollectionLinkStyle(reduceMotion: reduceMotion))
        .opacity(isRevealed ? 1 : 0)
        .offset(y: isRevealed || reduceMotion ? 0 : 6)
        .onAppear {
            guard !isRevealed else { return }
            withAnimation(AppMotion.resolve(AppMotion.submenu, reduceMotion: reduceMotion)) {
                isRevealed = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(LocalizedStringKey("Open in Explore"))
    }

#if os(macOS)
    private var macContent: some View {
        HStack(alignment: .center, spacing: 14) {
            OverfitExpertBankMark(isRevealed: isRevealed, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey("Paged model collection"))
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Color.indigo)
                Text(LocalizedStringKey("Noema Overfit"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Text(LocalizedStringKey("Run larger models by paging experts from storage."))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 8) {
                IndustrialBadge("Mixture-of-Experts", tint: .indigo, dot: true)
                Label(LocalizedStringKey("Open in Explore"), systemImage: "chevron.right")
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.35)
                    .foregroundStyle(Color.indigo)
                    .offset(x: isHovering && !reduceMotion ? 2 : 0)
                    .animation(AppMotion.resolve(AppMotion.snappy, reduceMotion: reduceMotion), value: isHovering)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.indigo.opacity(isHovering ? 0.10 : 0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.indigo.opacity(isHovering ? 0.32 : 0.20), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(AppMotion.resolve(AppMotion.snappy, reduceMotion: reduceMotion), value: isHovering)
    }
#else
    private var touchContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                OverfitExpertBankMark(isRevealed: isRevealed, reduceMotion: reduceMotion)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("Paged model collection"))
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.45)
                        .foregroundStyle(Color.indigo)
                    Text(LocalizedStringKey("Noema Overfit"))
                        .font(FontTheme.heading)
                        .foregroundStyle(AppTheme.text)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.indigo)
            }

            Text(LocalizedStringKey("Run larger models by paging experts from storage."))
                .font(FontTheme.body)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(LocalizedStringKey("Mixture-of-Experts"))
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.indigo)
                Spacer(minLength: 8)
                Text(LocalizedStringKey("Open in Explore"))
                    .font(FontTheme.caption.weight(.semibold))
                    .foregroundStyle(Color.indigo)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.indigo.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.indigo.opacity(0.22), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .visionHoverHighlight(cornerRadius: 14)
    }
#endif
}

private struct OverfitExpertBankMark: View {
    let isRevealed: Bool
    let reduceMotion: Bool

    private let heights: [CGFloat] = [13, 22, 29, 19, 25]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index == 2 ? Color.indigo : Color.indigo.opacity(0.38))
                    .frame(width: 4, height: height)
                    .scaleEffect(y: isRevealed || reduceMotion ? 1 : 0.2, anchor: .bottom)
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.42, dampingFraction: 0.78)
                                .delay(Double(index) * 0.035),
                        value: isRevealed
                    )
            }
        }
        .frame(width: 48, height: 48)
        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.indigo.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

private struct OverfitCollectionLinkStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(AppMotion.resolve(.easeOut(duration: 0.10), reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

private struct ExploreVisionCapabilityBadge: View {
    var body: some View {
        Group {
#if os(macOS)
            IndustrialBadge("Vision", tint: .purple)
#else
            Image(systemName: "eye.fill")
                .font(.caption2)
                .foregroundStyle(Color.purple)
#endif
        }
        .accessibilityLabel(LocalizedStringKey("Vision-capable model"))
        .help(LocalizedStringKey("Vision-capable model"))
    }
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
                ExploreVisionCapabilityBadge()
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
#if os(macOS)
                IndustrialBadge("Tools", tint: .secondary)
#else
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
#endif
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    @State private var pendingProjectorChoice: PendingProjectorChoice?
    @State private var availableProjectorArtifacts: [VisionProjectorArtifact] = []
    @State private var selectedProjectorArtifactID = "__app_default__"

    private static let appDefaultProjectorSelectionID = "__app_default__"
    private static let projectorByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private struct PendingProjectorChoice: Identifiable {
        let id = UUID()
        let quant: QuantInfo
        let preference: VisionProjectorDownloadPreference
        let alternatives: [VisionProjectorArtifact]
    }

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

                    if shouldShowModelCard {
                        ModelCardSection(
                            repoID: detail.id,
                            token: huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }

                    projectorQualityOverrideRow

                    infoCard(title: artifactSectionTitle, trailing: {
                        Picker(LocalizedStringKey("Sort"), selection: $quantSort) {
                            ForEach(QuantSortOption.allCases, id: \.self) { opt in
                                Text(opt.titleKey(isModelCatalog: isPagedModelCatalog)).tag(opt)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityLabel(
                            LocalizedStringKey(isPagedModelCatalog ? "Sort models" : "Sort quantizations")
                        )
                    }) {
                        if eligibleQuants.isEmpty {
                            Text(LocalizedStringKey(isPagedModelCatalog ? "No models yet" : "No quant files available"))
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
            // On macOS this view lives inside a fixed-frame MacModalHost card, so
            // ignoring the safe area only lets the opaque fill bleed past the card's
            // rounded edge. Keep the extension on iOS where it's a full-screen sheet.
            #if os(macOS)
            .background(Color.detailSheetBackground)
            #else
            .background(Color.detailSheetBackground.ignoresSafeArea())
            #endif
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
            .task(id: projectorOptionsTaskID) {
                await refreshProjectorOptions()
            }
            .onDisappear {
                if !downloadController.items.isEmpty {
                    downloadController.showOverlay = true
                }
                cancelAllRemotePolling()
            }
        }
        .sheet(item: $pendingProjectorChoice) { choice in
            VisionProjectorFallbackSheet(
                modelID: detail.id,
                preference: choice.preference,
                alternatives: choice.alternatives,
                onSelect: { artifact in
                    pendingProjectorChoice = nil
                    beginLocalDownload(
                        info: choice.quant,
                        projectorDecision: .selected(artifact)
                    )
                },
                onWithoutVision: {
                    pendingProjectorChoice = nil
                    beginLocalDownload(info: choice.quant, projectorDecision: .skip)
                },
                onCancel: {
                    pendingProjectorChoice = nil
                }
            )
        }
    }

    /// README fetching only makes sense for Hugging Face repos: an
    /// "owner/name" id with at least one HTTP-downloadable artifact. Apple
    /// Foundation and local CoreAI catalog entries have no hub model card.
    private var shouldShowModelCard: Bool {
        guard !detail.quants.contains(where: { $0.format == .afm }) else { return false }
        let parts = detail.id.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return detail.quants.isEmpty || detail.quants.contains { $0.downloadURL.scheme?.hasPrefix("http") == true }
    }

    private var isPagedModelCatalog: Bool {
        !detail.quants.isEmpty && detail.quants.allSatisfy(\.isPagedPackage)
    }

    private var artifactSectionTitle: LocalizedStringKey {
        isPagedModelCatalog ? "Models" : "Available Quantizations"
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
        if isPagedModelCatalog {
            let modelName = (q.pagedModelDisplayName ?? q.label).uppercased()
            return (0, 0, 0, 0, 0, modelName)
        }
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
            guard !info.isPagedPackage else {
                remoteDownloadErrorMap[info.label] = String(
                    localized: "Paged packages can only be downloaded to this device."
                )
                return
            }
            await startRemoteDownload(info: info)
            return
        }
        guard info.format == .gguf else {
            beginLocalDownload(info: info)
            return
        }

        // The multipart installer already owns the complete manifest,
        // resident-GGUF, and expert-bank plan. Paged packages do not carry a
        // vision projector, so do not run the unrelated projector probe.
        if info.isPagedPackage {
            beginLocalDownload(info: info, projectorDecision: .skip)
            return
        }

        if let projectorOverrideArtifact {
            beginLocalDownload(
                info: info,
                projectorDecision: .selected(projectorOverrideArtifact)
            )
            return
        }

        downloading.insert(info.label)
        progressMap[info.label] = 0
        speedMap[info.label] = 0

        let token = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = await VisionModelDetector.projectorDownloadPlan(
            repoIDs: VisionModelDetector.repositoryCandidates(
                modelID: detail.id,
                downloadURL: info.downloadURL
            ),
            token: token.isEmpty ? nil : token,
            preference: .current
        )
        guard !Task.isCancelled else {
            downloading.remove(info.label)
            return
        }

        if plan.requiresUserChoice {
            downloading.remove(info.label)
            pendingProjectorChoice = PendingProjectorChoice(
                quant: info,
                preference: plan.preference,
                alternatives: plan.alternatives
            )
            return
        }

        let decision: DownloadController.ProjectorDownloadDecision = plan.selected
            .map { .selected($0) }
            ?? .automatic
        downloadController.start(
            detail: detail,
            quant: info,
            projectorDecision: decision
        )
    }

    @MainActor
    private func beginLocalDownload(
        info: QuantInfo,
        projectorDecision: DownloadController.ProjectorDownloadDecision = .automatic
    ) {
        downloading.insert(info.label)
        progressMap[info.label] = 0
        speedMap[info.label] = 0
        downloadController.start(
            detail: detail,
            quant: info,
            projectorDecision: projectorDecision
        )
    }

    @ViewBuilder
    private var projectorQualityOverrideRow: some View {
        if !isRemoteDownloadMode, !availableProjectorArtifacts.isEmpty {
            Group {
                if horizontalSizeClass == .compact {
                    VStack(alignment: .leading, spacing: 10) {
                        projectorOverrideLabel
                        projectorOverridePicker
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        projectorOverrideLabel
                        Spacer(minLength: 12)
                        projectorOverridePicker
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var projectorOverrideLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.visionAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("mmproj File for This Model")
                    .font(FontTheme.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text("Overrides only this model's companion mmproj download.")
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private var projectorOverridePicker: some View {
        Picker("mmproj File for This Model", selection: $selectedProjectorArtifactID) {
            Text(appDefaultProjectorLabel)
                .tag(Self.appDefaultProjectorSelectionID)
            ForEach(availableProjectorArtifacts) { artifact in
                Text(projectorOptionLabel(artifact))
                    .tag(artifact.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(LocalizedStringKey("mmproj File for This Model"))
    }

    private var projectorOverrideArtifact: VisionProjectorArtifact? {
        guard selectedProjectorArtifactID != Self.appDefaultProjectorSelectionID else { return nil }
        return availableProjectorArtifacts.first { $0.id == selectedProjectorArtifactID }
    }

    private var appDefaultProjectorLabel: String {
        let preference = VisionProjectorDownloadPreference.current
        let title = String(localized: String.LocalizationValue(preference.mmprojTitleKey))
        return String.localizedStringWithFormat(String(localized: "App Default (%@)"), title)
    }

    private func projectorOptionLabel(_ artifact: VisionProjectorArtifact) -> String {
        var components = ["\(artifact.qualityLabel) mmproj"]
        if artifact.size > 0 {
            components.append(Self.projectorByteFormatter.string(fromByteCount: artifact.size))
        }
        return components.joined(separator: " · ")
    }

    private var projectorOptionsTaskID: String {
        let token = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = formatFilter?.rawValue ?? "all"
        return "\(detail.id)|\(format)|\(token)"
    }

    private var projectorRepositoryCandidates: [String] {
        var candidates: [String] = []
        for quant in eligibleQuants where quant.format == .gguf {
            for repositoryID in VisionModelDetector.repositoryCandidates(
                modelID: detail.id,
                downloadURL: quant.downloadURL
            ) where !candidates.contains(repositoryID) {
                candidates.append(repositoryID)
            }
        }
        return candidates
    }

    @MainActor
    private func refreshProjectorOptions() async {
        guard !isRemoteDownloadMode, !projectorRepositoryCandidates.isEmpty else {
            availableProjectorArtifacts = []
            selectedProjectorArtifactID = Self.appDefaultProjectorSelectionID
            return
        }

        let token = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = await VisionModelDetector.projectorDownloadPlan(
            repoIDs: projectorRepositoryCandidates,
            token: token.isEmpty ? nil : token,
            preference: .highestQuality
        )
        guard !Task.isCancelled else { return }

        let ordered = [plan.selected].compactMap { $0 } + plan.alternatives
        var seenQualities: Set<String> = []
        let uniqueQualities = ordered.filter {
            seenQualities.insert($0.qualityLabel.uppercased()).inserted
        }
        availableProjectorArtifacts = uniqueQualities

        if selectedProjectorArtifactID != Self.appDefaultProjectorSelectionID,
           !uniqueQualities.contains(where: { $0.id == selectedProjectorArtifactID }) {
            selectedProjectorArtifactID = Self.appDefaultProjectorSelectionID
        }
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
                isVision = ETModelResolver.isVisionIdentifier(slug)
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

            // Paged Overfit packages (`.noema-paged` directories) import as one
            // unit: resident.gguf deliberately lacks the expert tensors that live
            // in the sibling expert banks, so copying it alone orphans the model.
            var pagedPackageDirs: [URL] = []
            var seenPagedPackagePaths = Set<String>()
            for url in urls {
                for dir in GGUFImportSupport.pagedPackageDirectories(near: url, fileManager: fm) {
                    if seenPagedPackagePaths.insert(dir.standardizedFileURL.path).inserted {
                        pagedPackageDirs.append(dir)
                    }
                }
            }

            let importPlans = GGUFImportSupport.modelImportPlans(from: urls, fileManager: fm)

            guard !importPlans.isEmpty || !pagedPackageDirs.isEmpty else {
                importError = String(localized: "No GGUF model files found in selection.")
                return
            }

            for packageDir in pagedPackageDirs {
                let installed = try await importPagedPackage(at: packageDir, installDate: now)
                modelManager.install(installed)
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

            let importedCount = importPlans.count + pagedPackageDirs.count
            importSuccess = importedCount == 1
                ? String(localized: "Imported 1 model. Find it in the Stored tab.")
                : String(localized: "Imported \(importedCount) models. Find them in the Stored tab.")
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

    /// Installs a `.noema-paged` package directory as a single model. The copy
    /// and validation run off the main actor: expert banks reach tens of
    /// gigabytes and the importing overlay must stay live meanwhile.
    @MainActor
    private func importPagedPackage(at sourceDir: URL, installDate now: Date) async throws -> InstalledModel {
        let stem = sourceDir.deletingPathExtension().lastPathComponent
        let modelID = "local/\(stem)"
        let destBase = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)

        let pkg = try await Task.detached(priority: .userInitiated) {
            try GGUFImportSupport.installPagedPackage(from: sourceDir, into: destBase)
        }.value

        let canonical = InstalledModelsStore.canonicalURL(for: pkg.residentGGUFURL, format: .gguf)
        let quantLabel = GGUFShardNaming.normalizedQuantLabel(for: stem + ".gguf", repoID: nil) + " · Paged"
        let layers = ModelScanner.layerCount(for: canonical, format: .gguf)
        var isVision = ProjectorLocator.hasProjectorFile(in: canonical.deletingLastPathComponent())
        if !isVision {
            isVision = ModelVisionDetector.guessLlamaVisionModel(from: canonical)
        }
        let isToolCap = ToolCapabilityDetector.isToolCapableLocal(url: canonical, format: .gguf)
        let moeInfo = ModelScanner.moeInfo(for: canonical, format: .gguf) ?? .denseFallback
        Task { await MoEDetectionStore.shared.update(info: moeInfo, modelID: modelID, quantLabel: quantLabel) }
        Task {
            await logger.log("[GGUFImport] paged package=\(sourceDir.lastPathComponent) fingerprint=\(pkg.manifest.fingerprint)")
        }

        let packageBytes = Int64(clamping: pkg.totalSizeBytes)
        return InstalledModel(
            modelID: modelID,
            quantLabel: quantLabel,
            url: canonical,
            format: .gguf,
            sizeBytes: packageBytes,
            lastUsed: nil,
            installDate: now,
            checksum: nil,
            isFavourite: false,
            totalLayers: layers,
            isMultimodal: isVision,
            isToolCapable: isToolCap,
            moeInfo: moeInfo,
            pagedPackageFingerprint: pkg.manifest.fingerprint,
            pagedPackageBytes: packageBytes
        )
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
    private static let mtpKeywords = ["mtp", "nextn"]
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
            // A neighboring `.noema-paged` directory must not leak its
            // manifest.json (or anything else) into this plan's sidecars.
            let scopeFiles = scopeFiles(in: scopeDirectory, fileManager: fileManager)
                .filter { !isInsidePagedPackage($0) }
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
        if let primary = weightFiles.first {
            MtpLocator.invalidateCache(alongside: primary)
        }
        return artifactsURL
    }

    // MARK: - Paged (.noema-paged) packages

    /// True when `url` lives inside a `.noema-paged` directory. Name-based on
    /// purpose: members must be excluded from per-file import plans even when
    /// sandbox scope stops us from reading the package's manifest.
    static func isInsidePagedPackage(_ url: URL) -> Bool {
        let suffix = "." + NoemaPagedPackageManifest.packageDirectoryExtension
        return url.standardizedFileURL.pathComponents.dropLast().contains { $0.lowercased().hasSuffix(suffix) }
    }

    /// Resolves one picked URL to the `.noema-paged` package directories it
    /// denotes: the URL itself when it is a package, packages sitting at the
    /// top level of a picked folder, or the enclosing package when the user
    /// picked a file from inside one.
    static func pagedPackageDirectories(near root: URL, fileManager fm: FileManager = .default) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }

        if !isDirectory.boolValue {
            guard let package = enclosingPagedPackageByName(for: root) else { return [] }
            return [package]
        }
        if root.pathExtension.lowercased() == NoemaPagedPackageManifest.packageDirectoryExtension {
            return [root]
        }
        if let package = PagedPackageLocator.enclosingPackage(for: root) {
            return [package]
        }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children
            .filter { child in
                (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && child.pathExtension.lowercased() == NoemaPagedPackageManifest.packageDirectoryExtension
            }
            .sorted { $0.path < $1.path }
    }

    /// Walks up by directory name only — unlike `PagedPackageLocator` it does
    /// not require the manifest to be readable, so a bare resident.gguf pick
    /// still redirects to its package and fails with a package error (not a
    /// silently orphaned copy) when the manifest is inaccessible.
    private static func enclosingPagedPackageByName(for url: URL) -> URL? {
        var current = url.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<16 {
            if current.pathExtension.lowercased() == NoemaPagedPackageManifest.packageDirectoryExtension {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path.count >= current.path.count { return nil }
            current = parent
        }
        return nil
    }

    /// Copies a whole `.noema-paged` package into `baseDir` and returns the
    /// validated destination package. Copying (not moving) matches the MLX
    /// folder importer — the user's original stays put — and FileManager
    /// clones on same-volume APFS, so no second copy of the payload is
    /// written. Runs synchronously; call off the main actor.
    static func installPagedPackage(from sourceDir: URL, into baseDir: URL, fileManager fm: FileManager = .default) throws -> NoemaPagedPackage {
        // Fail before a potentially multi-minute copy, not after.
        let source = try NoemaPagedPackage.load(at: sourceDir)

        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let destination = baseDir.appendingPathComponent(sourceDir.lastPathComponent, isDirectory: true)

        if fm.fileExists(atPath: destination.path) {
            // Re-import of the identical package: keep the installed copy
            // rather than re-copying tens of gigabytes.
            if let existing = try? NoemaPagedPackage.load(at: destination),
               existing.manifest.fingerprint == source.manifest.fingerprint {
                try existing.validate(level: .structural)
                PagedPackageLocator.excludeFromBackupIfNeeded(destination)
                writePagedArtifactsJSON(in: baseDir, package: existing)
                return existing
            }
            try fm.removeItem(at: destination)
        }

        do {
            try fm.copyItem(at: sourceDir, to: destination)
            let package = try NoemaPagedPackage.load(at: destination)
            try package.validate(level: .structural)
            PagedPackageLocator.excludeFromBackupIfNeeded(destination)
            writePagedArtifactsJSON(in: baseDir, package: package)
            return package
        } catch {
            // A package that fails validation is unusable as a unit; drop the
            // partial copy so a retry starts clean.
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// `artifacts.json` for a paged install must point at the resident GGUF
    /// through the package directory (mirrors the download pipeline), not at
    /// a bare filename in the model root like `writeArtifactsJSON` records.
    private static func writePagedArtifactsJSON(in baseDir: URL, package: NoemaPagedPackage) {
        let payload: [String: Any] = [
            "weights": package.directoryURL.lastPathComponent + "/" + package.manifest.resident.path,
            "mmproj": NSNull(),
            "mmprojChecked": true,
            "mtp": NSNull(),
            "mtpChecked": true
        ]
        let artifactsURL = baseDir.appendingPathComponent("artifacts.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: artifactsURL, options: [.atomic])
        }
        MtpLocator.invalidateCache(alongside: package.residentGGUFURL)
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
                       isWeightFile(next),
                       !isInsidePagedPackage(next) {
                        add(next)
                    }
                }
                continue
            }

            guard isWeightFile(root), !isInsidePagedPackage(root) else { continue }
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
        guard let target = weights.first else { return nil }
        let validated = mtpFiles.filter {
            if case .sidecarValidated = GGUFMetadata.mtpCapability(targetURL: target, sidecarURL: $0) {
                return true
            }
            return false
        }
        guard !validated.isEmpty else { return nil }

        if let hinted = hintedMTP(in: directory, among: validated) {
            return hinted
        }
        if validated.count == 1 {
            return validated[0]
        }

        let weightTokens = Set(normalizedTokens(for: weights.first))
        let weightStem = normalizedStem(for: weights.first)
        let scored = validated.map {
            ($0, mtpScore($0, weightTokens: weightTokens, weightStem: weightStem))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }),
              scored.filter({ $0.1 == best.1 }).count == 1 else {
            return nil
        }
        return best.0
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
#if os(macOS)
            Text(name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.text)
#else
            Text(name)
                .font(FontTheme.largeTitle)
                .foregroundStyle(AppTheme.text)
#endif

            if lowBitOnlyRepository {
                VStack(alignment: .leading, spacing: 6) {
#if os(macOS)
                    IndustrialBadge("Low-quality quantizations", tint: .orange, systemImage: "exclamationmark.triangle.fill")
#else
                    Label(LocalizedStringKey("Low-quality quantizations"), systemImage: "exclamationmark.triangle.fill")
                        .font(FontTheme.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.orange)
#endif

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

#if os(macOS)
            HStack(spacing: 6) {
                if let parameterCountLabel = detail.parameterCountLabel, !parameterCountLabel.isEmpty {
                    IndustrialBadge(verbatim: parameterCountLabel, tint: .orange)
                }
                if ExploreModelDetailCache.cachedAt(repoID: detail.id) != nil {
                    IndustrialBadge("Available offline", tint: .green, systemImage: "externaldrive.fill")
                        .accessibilityLabel(LocalizedStringKey("Available offline"))
                }
                if UIConstants.showMultimodalUI && detail.isVision {
                    IndustrialBadge("Vision-capable", tint: Color.visionAccent, systemImage: "eye.fill")
                        .accessibilityLabel("Vision-capable model")
                }
                if isMoE {
                    IndustrialBadge("Mixture-of-Experts", tint: Color.moeAccent)
                        .accessibilityLabel(LocalizedStringKey("Mixture-of-Experts model"))
                }
            }
#else
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
#endif
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
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer(minLength: 16)
                trailing()
            }

            IndustrialHairline()

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
            if quant.isPagedPackage {
                return String(localized: "Paged packages can only be downloaded to this device.")
            }
            if let unavailable = remoteModeUnavailableReason {
                return unavailable
            }
            return nil
        }()
        let afmOpenUnavailableReason: String? = {
            guard quant.format == .afm else { return nil }
            if detail.id == AppleFoundationModelRegistry.privateCloudModelID {
                let status = ApplePrivateCloudComputeAvailability.status
                return status.isAvailableForRequests ? nil : status.message
            }
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
            remoteStatusText: nil,
            remotePaused: remoteStatus?.status == .paused,
            remoteErrorText: remoteDownloadErrorMap[quant.label],
            remoteUnsupportedReason: remoteUnsupportedReason,
            remoteCompleted: remoteCompleted,
            openUnavailableReason: afmOpenUnavailableReason,
            showsLowQualityMarker: quant.isLowBitQuant && !lowBitOnlyRepository,
            downloadController: downloadController,
            openAction: { await useModel(info: quant) },
            downloadAction: { await download(info: quant) },
            cancelAction: { cancelDownload(label: quant.label) },
            hubToken: huggingFaceToken
        )
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VisionProjectorFallbackSheet: View {
    let modelID: String
    let preference: VisionProjectorDownloadPreference
    let alternatives: [VisionProjectorArtifact]
    let onSelect: (VisionProjectorArtifact) -> Void
    let onWithoutVision: () -> Void
    let onCancel: () -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preferred Projector Unavailable")
                                .font(.title2.weight(.semibold))
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "No %@ projector is available for %@."),
                                    String(localized: String.LocalizationValue(preference.titleKey)),
                                    modelID
                                )
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    }

                    Text("Choose an available mmproj alternative. This only changes the projector downloaded with this model; your default preference stays the same.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Available Projectors")
                            .font(.headline)

                        ForEach(Array(alternatives.enumerated()), id: \.element.id) { index, artifact in
                            Button {
                                onSelect(artifact)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(verbatim: artifact.qualityLabel)
                                                .font(.headline)
                                            if index == 0 {
                                                Text("Best Available")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 7)
                                                    .padding(.vertical, 3)
                                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                                            }
                                        }
                                        Text(verbatim: artifact.filename)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        if artifact.size > 0 {
                                            Text(verbatim: Self.byteFormatter.string(fromByteCount: artifact.size))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                String.localizedStringWithFormat(
                                    String(localized: "Download %@ projector"),
                                    artifact.qualityLabel
                                )
                            )
                        }
                    }

                    Button(role: .destructive, action: onWithoutVision) {
                        Label("Continue Without Vision", systemImage: "photo.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text("The model weights will still download and work for text. You can add an mmproj later or download the model again with another default projector preference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Vision Projector")
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 650)
#endif
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
    // Unread; kept so Onboarding/GuidedWalkthrough call sites keep compiling.
    let remoteStatusText: String?
    var remotePaused: Bool = false
    let remoteErrorText: String?
    let remoteUnsupportedReason: String?
    let remoteCompleted: Bool
    let openUnavailableReason: String?
    let showsLowQualityMarker: Bool
    let downloadController: DownloadController
    let openAction: () async -> Void
    let downloadAction: () async -> Void
    let cancelAction: () -> Void
    var hubToken: String = ""
    @EnvironmentObject var modelManager: AppModelManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var localDownloadObserver = QuantRowDownloadObserver()
    @State private var showQuantTypeInfo = false
    @State private var showDownloadPlan = false
    @State private var remotePagedManifest: NoemaPagedPackageManifest?
    @State private var remotePagedManifestFailed = false
    // Flips the row to its active state the instant Download is tapped; the
    // observer's snapshot lags ~0.5s behind (coalesced + throttled publisher).
    @State private var pendingDownloadStart = false

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
        .onChangeCompat(of: localDownloadSnapshot.isPresent) { _, present in
            if present { pendingDownloadStart = false }
        }
        .task(id: pagedManifestTaskID) {
            await loadRemotePagedManifestIfNeeded()
        }
    }

    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                metadataBlock
                    .layoutPriority(1)
                Spacer(minLength: 8)
                suitabilityBadge
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(3)
                if !isDownloadActive {
                    trailingControls
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(4)
                }
            }
            if isDownloadActive {
                activeDownloadRow
            }
            if showDownloadPlan {
                DownloadPlanPreview(rootTitle: info.label, plan: downloadPlan, byteCountFormatter: Self.byteCountFormatter)
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataBlock
            if isDownloadActive {
                HStack(alignment: .center, spacing: 10) {
                    suitabilityBadge
                    Spacer(minLength: 8)
                }
                activeDownloadRow
            } else if remoteMode && remoteStatusNeedsStackedLayout {
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

            if info.isPagedPackage {
                pagedEstimateSummary
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
        if let modelName = info.pagedModelDisplayName {
            return modelName
        }
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
#if os(macOS)
        IndustrialBadge("Low quality", tint: .orange, systemImage: "exclamationmark.triangle.fill")
#else
        Label(LocalizedStringKey("Low quality"), systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12), in: Capsule())
#endif
    }

    @ViewBuilder
    private var suitabilityBadge: some View {
        // A resident-fit estimate reads "doesn't fit" for a model the paged
        // plan runs on purpose, so an installed paged copy shows its canary
        // verdict instead. Until one exists, the neutral PAGED marker rides
        // beside the estimate rather than guessing a classification.
        if let pagedURL = installedPagedModelURL {
            if let classification = OverfitPagedFitCache.classification(forModelAt: pagedURL) {
                OverfitClassificationChip(classification: classification)
            } else {
                HStack(spacing: 6) {
                    assessmentBadge
                    OverfitPagedChip()
                }
            }
        } else if info.isPagedPackage {
            HStack(spacing: 6) {
                if let estimate = remotePagedEstimate {
                    fitBadge(
                        status: estimate.status,
                        architectureSupported: estimate.architectureSupported
                    )
                }
                OverfitPagedChip()
            }
        } else {
            assessmentBadge
        }
    }

    /// URL of the locally installed copy of this quant when it is a paged
    /// install. The paged probe is memoized per URL, so row bodies never
    /// stat the disk.
    private var installedPagedModelURL: URL? {
        guard !remoteMode, info.format == .gguf,
              let url = modelManager.downloadedModels.first(where: {
                  $0.modelID == canonicalID && $0.quant == info.label
              })?.url,
              OverfitPagedInstallCache.isPaged(url) else {
            return nil
        }
        return url
    }

    private var remotePagedEstimate: OverfitRemotePackageEstimate? {
        guard let manifest = remotePagedManifest else { return nil }
        return OverfitRemotePackageAdvisor.assess(
            manifest: manifest,
            manifestBytes: info.pagedManifestDownloadPart?.sizeBytes ?? 0
        )
    }

    private var pagedManifestTaskID: String {
        guard installedPagedModelURL == nil,
              let url = info.pagedManifestDownloadPart?.downloadURL else {
            return "none"
        }
        return "\(url.absoluteString)|\(hubToken.hashValue)"
    }

    @MainActor
    private func loadRemotePagedManifestIfNeeded() async {
        remotePagedManifest = nil
        remotePagedManifestFailed = false
        guard installedPagedModelURL == nil,
              let url = info.pagedManifestDownloadPart?.downloadURL else { return }
        let trimmed = hubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let manifest = try await OverfitRemoteManifestStore.shared.manifest(
                at: url,
                token: trimmed.isEmpty ? nil : trimmed
            )
            guard !Task.isCancelled else { return }
            remotePagedManifest = manifest
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            remotePagedManifestFailed = true
        }
    }

    @ViewBuilder
    private var pagedEstimateSummary: some View {
        if let estimate = remotePagedEstimate {
            let resident = Self.byteCountFormatter.string(fromByteCount: estimate.residentBytes)
            let bank = Self.byteCountFormatter.string(fromByteCount: estimate.expertBankBytes)
            let workingSet = Self.byteCountFormatter.string(fromByteCount: estimate.workingSetBytes)
            let budget = estimate.budgetBytes.map {
                Self.byteCountFormatter.string(fromByteCount: $0)
            } ?? String(localized: "Budget unknown")
            let context = String.localizedStringWithFormat(
                String(localized: "%lld tokens"),
                Int64(estimate.contextCapTokens)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(String.localizedStringWithFormat(
                    String(localized: "Resident %@ · Expert bank %@ · Context %@"),
                    resident,
                    bank,
                    context
                ))
                Text(String.localizedStringWithFormat(
                    String(localized: "Estimated for this device: %@ working set against %@ memory budget."),
                    workingSet,
                    budget
                ))
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        } else if !remotePagedManifestFailed && installedPagedModelURL == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(LocalizedStringKey("Loading paged estimate…"))
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.secondaryText)
        } else if remotePagedManifestFailed {
            Label(LocalizedStringKey("Paged estimate unavailable"), systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    @ViewBuilder
    private var assessmentBadge: some View {
        let defaultCtx = 4096
        // An installed paged copy is judged by the paged runtime's working set
        // (resident + bank + staging), never by the quant's download size.
        let assessment = ModelDeviceFitAdvisor.assess(
            format: info.format,
            sizeBytes: info.sizeBytes,
            contextLength: defaultCtx,
            layerCount: nil,
            modelURL: installedPagedModelURL,
            benchmark: installedBenchmarkResult
        )
        
        fitBadge(status: assessment.status, architectureSupported: true)
    }

    private func fitBadge(
        status: ModelDeviceFitAssessment.Status,
        architectureSupported: Bool
    ) -> some View {
        let labelText: String = {
            guard architectureSupported else { return "UNSUPPORTED" }
            switch status {
            case .works: return "FITS"
            case .tight: return "TIGHT FIT"
            case .unlikely: return "DOESN'T FIT"
            }
        }()

        let color: Color = {
            guard architectureSupported else { return Color.gray }
            switch status {
            case .works: return Color.green
            case .tight: return Color.orange
            case .unlikely: return Color.red
            }
        }()

        return Text(LocalizedStringKey(labelText))
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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
        } else if isDownloaded {
            VStack {
                IndustrialBadge("Ready", tint: .green, systemImage: "checkmark")
                if let reason = openUnavailableReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: downloadColumnWidth)
                        .multilineTextAlignment(.center)
                }
                Button(LocalizedStringKey("Open")) { Task { await openAction() } }
                    .buttonStyle(.industrial(.prominent))
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(openUnavailableReason != nil)
            }
        } else {
            Button(LocalizedStringKey("Download")) {
                pendingDownloadStart = true
                Task { @MainActor in
                    await downloadAction()
                    if !downloadController.items.contains(where: { $0.id == itemID }) {
                        pendingDownloadStart = false
                    }
                }
            }
                .buttonStyle(.industrial(.prominent))
                .fixedSize(horizontal: true, vertical: false)
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
        } else if let remoteErrorText, !remoteErrorText.isEmpty {
            VStack(alignment: alignment, spacing: 6) {
                Text(remoteErrorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .multilineTextAlignment(textAlignment)
                Button(LocalizedStringKey("Retry")) { Task { await downloadAction() } }
                    .buttonStyle(.industrial(.tinted))
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else if remoteCompleted {
            IndustrialBadge("Downloaded on Remote Endpoint", tint: .green, systemImage: "checkmark")
        } else {
            Button(LocalizedStringKey("Download")) { Task { await downloadAction() } }
                .buttonStyle(.industrial(.prominent))
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var isDownloadActive: Bool {
        if remoteMode {
            return downloading && remoteUnsupportedReason == nil
        }
        if localDownloadSnapshot.isPresent {
            return !localDownloadSnapshot.completed
        }
        return pendingDownloadStart
    }

    @ViewBuilder
    private var activeDownloadRow: some View {
        if !remoteMode, let error = localDownloadSnapshot.errorDescription {
            HStack(alignment: .center, spacing: 12) {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                localActionCluster
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                DownloadProgressCluster(
                    progress: displayedProgress,
                    speed: displayedSpeed,
                    statusKey: activeStatusKey
                )
                if !remoteMode {
                    localActionCluster
                }
            }
        }
    }

    private var localActionCluster: DownloadActionCluster {
        let snapshot = localDownloadSnapshot
        let resume = { downloadController.resume(itemID: itemID) }
        let showRetry = snapshot.isRetryableError
        let showResume = !showRetry && (snapshot.status == .paused || snapshot.canResume)
        let showPause = !showRetry && !showResume && snapshot.canPause
        return DownloadActionCluster(
            onResume: showResume ? resume : nil,
            onPause: showPause ? { downloadController.pause(itemID: itemID) } : nil,
            onRetry: showRetry ? resume : nil,
            onCancel: {
                pendingDownloadStart = false
                cancelAction()
            }
        )
    }

    private var activeStatusKey: LocalizedStringKey? {
        if remoteMode {
            return remotePaused ? "Paused" : nil
        }
        guard let status = localDownloadSnapshot.status else { return nil }
        switch status {
        case .queued, .scheduled, .preparing, .paused, .waitingForConnectivity, .retrying, .verifying, .finalizing:
            return LocalizedStringKey(status.statusLabelKey)
        case .downloading, .completed, .failed, .cancelled:
            return nil
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
        return false
    }

    private var sizeText: String {
        guard info.sizeBytes > 0 else {
            return String(localized: "Unknown size")
        }
        let formatted = Self.byteCountFormatter.string(fromByteCount: info.sizeBytes)
        guard info.isPagedPackage else { return formatted }
        return "\(String(localized: "Download")) \(formatted)"
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

                if let pagedQuant = info.pagedQuantDisplayLabel {
                    Text(pagedQuant)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: true, vertical: false)
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

                if info.isPagedPackage {
                    Divider()
                    Text(LocalizedStringKey("Overfit (Paged Experts)"))
                        .font(.subheadline.weight(.semibold))
                    pagedEstimateSummary
                }

                HStack {
                    Spacer()
                    Button(LocalizedStringKey("OK")) { showQuantTypeInfo = false }
                        .buttonStyle(.industrial(.tinted))
                }
            }
            .padding(12)
            .lineLimit(nil)
            .frame(maxWidth: 360, alignment: .leading)
#if !os(macOS)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
#endif
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

private enum QuantSortOption: String, CaseIterable, Identifiable {
    case quant
    case sizeSmall
    case sizeLarge

    var id: String { rawValue }

    func titleKey(isModelCatalog: Bool) -> LocalizedStringKey {
        switch self {
        case .quant: return LocalizedStringKey(isModelCatalog ? "Model" : "Quant")
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
    @State private var blocks: [ReadmeMarkdown.Block] = []

    private let collapsedBlockLimit = 3

    var body: some View {
        VStack(alignment: .leading) {
            if let md = markdown, !md.isEmpty {
                if blocks.isEmpty {
                    ProgressView()
                } else if expanded || blocks.count <= collapsedBlockLimit {
                    ReadmeMarkdownView(blocks: blocks)
                } else {
                    ReadmeMarkdownView(blocks: Array(blocks.prefix(collapsedBlockLimit)))
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
        .task(id: markdown) {
            guard let markdown, !markdown.isEmpty else {
                blocks = []
                return
            }
            blocks = await Task.detached(priority: .userInitiated) {
                ReadmeMarkdown.parse(markdown)
            }.value
        }
    }
}

#endif
