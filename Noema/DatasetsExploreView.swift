#if os(iOS) || os(visionOS)
// DatasetsExploreView.swift
import SwiftUI
import Foundation
import UniformTypeIdentifiers
import PDFKit

struct DatasetsExploreView: View {
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var downloadController: DownloadController
    @EnvironmentObject var datasetManager: DatasetManager
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @StateObject private var vm: DatasetsExploreViewModel
    @State private var selected: DatasetDetails?
    @State private var loadingDetail = false
    @State private var showSlowHint = false
    @State private var detailTask: Task<Void, Never>? = nil
    @State private var hintTask: Task<Void, Never>? = nil
    @AppStorage("huggingFaceToken") private var huggingFaceToken = ""

    // Import flow state
    @State private var showImporter = false
    @State private var importNotice: String?
    @State private var pendingPickedURLs: [URL] = []
    @State private var showNameSheet = false
    @State private var datasetName: String = ""
    @State private var importedDataset: LocalDataset?
    @State private var askStartIndexing = false
    @State private var datasetToIndex: LocalDataset?

    init() {
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken") ?? ""
        let hf = CombinedDatasetRegistry(
            primary: HuggingFaceDatasetRegistry(token: token),
            extras: [ManualDatasetRegistry(entries: CuratedDatasets.hf)]
        )
        let otl = OpenTextbookLibraryDatasetRegistry()
        _vm = StateObject(wrappedValue: DatasetsExploreViewModel(hfRegistry: hf, otlRegistry: otl))
    }

    var body: some View {
        contentView
        .sheet(item: $selected, content: detailSheet)
        .sheet(item: $importedDataset) { ds in
            LocalDatasetDetailView(dataset: ds)
                .environmentObject(datasetManager)
        }
        .overlay(alignment: .center) { loadingOverlay }
        .overlay(alignment: .center) { Group { if vm.isLoadingSearch { ProgressView() } } }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: allowedUTTypes(),
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let accepted = urls.filter { allowedExtensions().contains($0.pathExtension.lowercased()) || TranscriptionMediaSupport.isSupported($0) }
                guard !accepted.isEmpty else {
                    // Everything picked was unsupported (e.g. CSV/TSV) — tell the user
                    // instead of silently doing nothing.
                    importNotice = DatasetDocumentSupport.skippedMessage(for: urls)
                    return
                }
                pendingPickedURLs = accepted
                datasetName = suggestName(from: accepted) ?? String(localized: "Imported Dataset")
                showNameSheet = true
            case .failure:
                break
            }
        }
        .datasetImportNotice($importNotice)
        .sheet(isPresented: $showNameSheet) {
            DatasetImportNamePromptView(
                datasetName: $datasetName,
                onCancel: { showNameSheet = false },
                onImport: { await performImport() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(LocalizedStringKey("Start indexing now?"), isPresented: $askStartIndexing, titleVisibility: .visible) {
            Button(LocalizedStringKey("Start")) {
                if let ds = datasetToIndex {
                    datasetManager.startIndexing(dataset: ds)
                }
            }
            Button(LocalizedStringKey("Later"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("We'll extract text and prepare embeddings. You can also start later from the dataset details."))
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Label(LocalizedStringKey("Import"), systemImage: "square.and.arrow.down")
                }
                .guideHighlight(.exploreImportButton)
            }
        }
        .task { await vm.loadCurated() }
        // Search requested from outside the view hierarchy (Siri / App Intents)
        .onAppear { consumePendingExploreSearchIfNeeded() }
        .onReceive(tabRouter.$pendingExploreSearch) { _ in
            consumePendingExploreSearchIfNeeded()
        }
    }

    /// Runs a search handed over by an App Intent once this view owns Explore.
    private func consumePendingExploreSearchIfNeeded() {
        DispatchQueue.main.async {
            guard let query = tabRouter.consumePendingExploreSearch(for: .datasets) else { return }
            vm.searchText = query
            vm.triggerSearch()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            ipadContent
        } else {
            phoneContent
        }
    }

    private var searchHint: LocalizedStringKey { LocalizedStringKey("Search for any subject you're interested in.") }

    private var isSearchEmpty: Bool { vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Layouts

    private var ipadContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(LocalizedStringKey("Explore Datasets"))
                    .font(FontTheme.heading(size: 32))
                    .foregroundStyle(Color.primary)
                Text(LocalizedStringKey("Browse curated datasets for retrieval"))
                    .font(FontTheme.body(size: 16))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 36)

            ScrollView {
                VStack(alignment: .center, spacing: 48) {
                    if !datasetManager.datasets.isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            Text(LocalizedStringKey("Datasets"))
                                .font(FontTheme.heading(size: 24))
                                .padding(.horizontal, 4)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
                                ForEach(datasetManager.datasets) { dataset in
                                    localDatasetCard(dataset)
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                    }

                    if isSearchEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            if vm.recommended.isEmpty {
                                Text(searchHint)
                                    .font(FontTheme.body(size: 16))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
                                    ForEach(vm.recommended, content: recordCard)
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            Text(LocalizedStringKey("Results"))
                                .font(FontTheme.heading(size: 24))
                                .padding(.horizontal, 4)

                            if vm.searchResults.isEmpty && !vm.isLoadingSearch {
                                Text(LocalizedStringKey("No datasets found. Try different keywords."))
                                    .font(FontTheme.body(size: 16))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
                                    ForEach(vm.searchResults, content: recordCard)
                                }

                                if vm.canLoadMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .onAppear { vm.loadNextPage() }
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 64)
            }
        }
        .searchable(text: $vm.searchText, prompt: Text(LocalizedStringKey("Search datasets")))
        .onSubmit(of: .search) { vm.triggerSearch() }
        .onChange(of: vm.searchText) { _ in vm.triggerSearch() }
        .onChange(of: huggingFaceToken, perform: updateRegistry)
        .guideHighlight(.exploreDatasetList)
    }

    private var phoneContent: some View {
        List {
            if isSearchEmpty {
                Text(searchHint)
                    .foregroundStyle(.secondary)
            } else {
                Section(LocalizedStringKey("Results")) {
                    ForEach(vm.searchResults, content: recordRow)
                    if vm.canLoadMore {
                        ProgressView().onAppear { vm.loadNextPage() }
                    }
                }
            }
        }
        .searchable(text: $vm.searchText, prompt: Text(LocalizedStringKey("Search datasets")))
        .onSubmit(of: .search) { vm.triggerSearch() }
        .onChange(of: vm.searchText) { _ in vm.triggerSearch() }
        .onChange(of: huggingFaceToken, perform: updateRegistry)
        .guideHighlight(.exploreDatasetList)
    }

    @ViewBuilder
    private func recordRow(_ record: DatasetRecord) -> some View {
        Button { startOpen(record) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !record.publisher.isEmpty {
                    Text(record.publisher)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let summary = record.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func localDatasetCard(_ dataset: LocalDataset) -> some View {
        Button {
            importedDataset = dataset
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text(dataset.name)
                        .font(FontTheme.heading(size: 18))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Spacer()
                    if dataset.isIndexed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green.gradient)
                    }
                }

                Spacer()

                HStack {
                    if !dataset.source.isEmpty {
                        Text(dataset.source)
                            .font(FontTheme.caption(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "folder.fill")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 4)
        }
        .visionHoverHighlight(cornerRadius: 12)
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func recordCard(_ record: DatasetRecord) -> some View {
        Button { startOpen(record) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(record.displayName)
                        .font(FontTheme.heading(size: 18))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Spacer()
                    if record.installed {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green.gradient)
                    }
                }

                if let summary = record.summary, !summary.isEmpty {
                    Text(summary)
                        .font(FontTheme.body(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack {
                    if !record.publisher.isEmpty {
                        Text(record.publisher.uppercased())
                            .font(FontTheme.caption(size: 11))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 4)
        }
        .visionHoverHighlight(cornerRadius: 12)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailSheet(_ detail: DatasetDetails) -> some View {
        DatasetDetailView(detail: detail)
            .environmentObject(downloadController)
    }

    @MainActor
    private func open(_ record: DatasetRecord) async {
        loadingDetail = true
        if let d = await vm.details(for: record.id) {
            if Task.isCancelled { loadingDetail = false; return }
            selected = d
        }
        loadingDetail = false
        showSlowHint = false
        hintTask?.cancel(); hintTask = nil
    }

    private func startOpen(_ record: DatasetRecord) {
        detailTask?.cancel()
        hintTask?.cancel()
        showSlowHint = false
        loadingDetail = true
        // Schedule slow-hint after delay if still loading
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            if !Task.isCancelled && loadingDetail {
                withAnimation(.snappy) { showSlowHint = true }
            }
        }
        detailTask = Task { [record, self] in
            await self.open(record)
        }
    }

    private func cancelLoading() {
        detailTask?.cancel(); detailTask = nil
        hintTask?.cancel(); hintTask = nil
        withAnimation(.snappy) {
            showSlowHint = false
            loadingDetail = false
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if loadingDetail {
            ZStack {
                Color.black.opacity(0.05).ignoresSafeArea()
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(1.1)
                    if showSlowHint {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey("This dataset is taking a while to load, still working…"))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Button(LocalizedStringKey("Cancel")) { cancelLoading() }
                                .buttonStyle(.bordered)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .glassifyIfAvailable(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
                .shadow(radius: 8)
                .padding()
                .transition(.scale.combined(with: .opacity))
            }
            .animation(.snappy, value: showSlowHint)
        }
    }
    
    private func updateRegistry(_ token: String) {
        let hf = CombinedDatasetRegistry(primary: HuggingFaceDatasetRegistry(token: token),
                                         extras: [ManualDatasetRegistry(entries: CuratedDatasets.hf)])
        vm.updateHFRegistry(hf)
        Task { await vm.loadCurated() }
    }

    // MARK: - Import helpers
    private func allowedExtensions() -> Set<String> { DatasetDocumentSupport.acceptedExtensions }
    private func allowedUTTypes() -> [UTType] { DatasetDocumentSupport.allowedUTTypes() }
    private func suggestName(from urls: [URL]) -> String? {
        // Prefer first PDF title metadata
        if let pdfURL = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            if let doc = PDFDocument(url: pdfURL), let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }
        // Fallback to first epub/txt filename
        if let u = urls.first {
            return u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        }
        return nil
    }
    private func performImport() async {
        let name = datasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pendingPickedURLs.isEmpty, !name.isEmpty else { return }
        if let ds = await datasetManager.importDocuments(from: pendingPickedURLs, suggestedName: name) {
            importedDataset = ds
            datasetToIndex = ds
            askStartIndexing = true
        }
        // Reset state
        pendingPickedURLs.removeAll()
        showNameSheet = false
    }
}


#elseif os(macOS)

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

private enum DatasetModalPresentation: Equatable {
    case remoteDetail
    case localDetail
    case namePrompt
}

struct DatasetsExploreView: View {
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var downloadController: DownloadController
    @EnvironmentObject var datasetManager: DatasetManager
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @EnvironmentObject var chromeState: ExploreChromeState
    @EnvironmentObject var macModalPresenter: MacModalPresenter
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var chatVM: ChatVM
    @StateObject private var vm: DatasetsExploreViewModel
    @State private var selected: DatasetDetails?
    @State private var loadingDetail = false
    @State private var showSlowHint = false
    @State private var detailTask: Task<Void, Never>? = nil
    @State private var hintTask: Task<Void, Never>? = nil
    @AppStorage("huggingFaceToken") private var huggingFaceToken = ""

    // Import flow state
    @State private var pendingPickedURLs: [URL] = []
    @State private var showNameSheet = false
    @State private var datasetName: String = ""
    @State private var importedDataset: LocalDataset?
    @State private var askStartIndexing = false
    @State private var datasetToIndex: LocalDataset?
    @State private var activeModal: DatasetModalPresentation?

    init() {
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken") ?? ""
        let hf = CombinedDatasetRegistry(
            primary: HuggingFaceDatasetRegistry(token: token),
            extras: [ManualDatasetRegistry(entries: CuratedDatasets.hf)]
        )
        let otl = OpenTextbookLibraryDatasetRegistry()
        _vm = StateObject(wrappedValue: DatasetsExploreViewModel(hfRegistry: hf, otlRegistry: otl))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Centered Header
            VStack(spacing: 8) {
                Text(LocalizedStringKey("Explore Datasets"))
                    .font(FontTheme.heading(size: 32)) // Serif heading
                    .foregroundStyle(Color.primary)
                Text(LocalizedStringKey("Browse curated datasets for retrieval"))
                    .font(FontTheme.body(size: 16))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.bottom, 48)
            
            ScrollView {
                VStack(alignment: .center, spacing: 48) { // Generous spacing
                    if !datasetManager.datasets.isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            Text(LocalizedStringKey("Datasets"))
                                .font(FontTheme.heading(size: 24))
                                .padding(.horizontal, 4)
                            
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
                                ForEach(datasetManager.datasets) { dataset in
                                    localDatasetCard(dataset)
                                }
                            }
                        }
                        .frame(maxWidth: 1000) // Limit width for "focused island" feel
                    }

                    if vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            if vm.recommended.isEmpty {
                                Text(LocalizedStringKey("Search for any subject you're interested in."))
                                    .font(FontTheme.body(size: 16))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
                                    ForEach(vm.recommended, content: recordCard)
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            Text(LocalizedStringKey("Results"))
                                .font(FontTheme.heading(size: 24))
                                .padding(.horizontal, 4)
                            
                            if vm.searchResults.isEmpty && !vm.isLoadingSearch {
                                Text(LocalizedStringKey("No datasets found. Try different keywords."))
                                    .font(FontTheme.body(size: 16))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
                                    ForEach(vm.searchResults, content: recordCard)
                                }
                                
                                if vm.canLoadMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .onAppear { vm.loadNextPage() }
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 64)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(item: $datasetManager.embedAlert) { info in
            Alert(title: Text(info.message))
        }
        .confirmationDialog(LocalizedStringKey("Start indexing now?"), isPresented: $askStartIndexing, titleVisibility: .visible) {
            Button(LocalizedStringKey("Start")) {
                if let ds = datasetToIndex {
                    datasetManager.startIndexing(dataset: ds)
                }
            }
            Button(LocalizedStringKey("Later"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("We'll extract text and prepare embeddings. You can also start later from the dataset details."))
        }
        .alert(item: $datasetManager.embedAlert) { info in
            Alert(title: Text(info.message))
        }
        .overlay(alignment: .center) { loadingOverlay }
        .overlay(alignment: .center) { if vm.isLoadingSearch { ProgressView() } }
        .onChange(of: huggingFaceToken, perform: updateRegistry)
        .task { await vm.loadCurated() }
        .onAppear {
            chromeState.activeSection = .datasets
            chromeState.toggleAction = nil
            chromeState.searchPlaceholder = LocalizedStringKey("Search datasets")
            chromeState.searchText = vm.searchText
            chromeState.isSearchVisible = true
            chromeState.searchSubmitAction = { vm.triggerSearch() }
            consumePendingExploreSearchIfNeeded()
        }
        // Search requested from outside the view hierarchy (Siri / App Intents)
        .onReceive(tabRouter.$pendingExploreSearch) { _ in
            consumePendingExploreSearchIfNeeded()
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
            guard chromeState.activeSection == .datasets else { return }
            chromeState.isSearchVisible = false
            chromeState.searchSubmitAction = nil
            chromeState.activeSection = nil
        }
        .onChangeCompat(of: selected) { _, detail in
            guard let detail else {
                if activeModal == .remoteDetail {
                    dismissActiveModal()
                }
                return
            }
            presentDatasetDetail(detail)
        }
        .onChangeCompat(of: importedDataset) { _, dataset in
            guard let dataset else {
                if activeModal == .localDetail {
                    dismissActiveModal()
                }
                return
            }
            presentImportedDatasetDetail(dataset)
        }
        .onChangeCompat(of: showNameSheet) { _, show in
            if show {
                presentNamePrompt()
            } else if activeModal == .namePrompt {
                dismissActiveModal()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                presentImporter()
            } label: {
                Label(LocalizedStringKey("Import"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(GlassButtonStyle.glass(isActive: false))
            .padding(24)
        }
    }

    /// Runs a search handed over by an App Intent once this view owns Explore.
    private func consumePendingExploreSearchIfNeeded() {
        DispatchQueue.main.async {
            guard let query = tabRouter.consumePendingExploreSearch(for: .datasets) else { return }
            vm.searchText = query
            vm.triggerSearch()
        }
    }

    @ViewBuilder
    private func localDatasetCard(_ dataset: LocalDataset) -> some View {
        Button {
            importedDataset = dataset
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                // Header Row
                HStack(alignment: .top) {
                    Text(dataset.name)
                        .font(FontTheme.heading(size: 18))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Spacer()
                    if dataset.isIndexed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green.gradient)
                    }
                }
                
                Spacer()
                
                // Metadata Row
                HStack {
                    if !dataset.source.isEmpty {
                        Text(dataset.source)
                            .font(FontTheme.caption(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "folder.fill")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 4)
        }
        .visionHoverHighlight(cornerRadius: 12)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func recordCard(_ record: DatasetRecord) -> some View {
        Button { startOpen(record) } label: {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(alignment: .top) {
                    Text(record.displayName)
                        .font(FontTheme.heading(size: 18))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Spacer()
                    if record.installed {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green.gradient)
                    }
                }
                
                if let summary = record.summary, !summary.isEmpty {
                    Text(summary)
                        .font(FontTheme.body(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer(minLength: 8)
                
                // Metadata Row
                HStack {
                    if !record.publisher.isEmpty {
                        Text(record.publisher.uppercased())
                            .font(FontTheme.caption(size: 11))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 4)
        }
        .visionHoverHighlight(cornerRadius: 12)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailSheet(_ detail: DatasetDetails) -> some View {
        DatasetDetailView(detail: detail)
            .environmentObject(downloadController)
    }

    private func startOpen(_ record: DatasetRecord) {
        detailTask?.cancel()
        hintTask?.cancel()
        showSlowHint = false
        loadingDetail = true
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            if !Task.isCancelled && loadingDetail {
                withAnimation(.snappy) { showSlowHint = true }
            }
        }
        detailTask = Task { [record, self] in
            await self.open(record)
        }
    }

    @MainActor
    private func open(_ record: DatasetRecord) async {
        loadingDetail = true
        if let d = await vm.details(for: record.id) {
            if Task.isCancelled { loadingDetail = false; return }
            selected = d
        }
        loadingDetail = false
        showSlowHint = false
        hintTask?.cancel(); hintTask = nil
    }

    private func cancelLoading() {
        detailTask?.cancel(); detailTask = nil
        hintTask?.cancel(); hintTask = nil
        withAnimation(.snappy) {
            showSlowHint = false
            loadingDetail = false
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if loadingDetail {
            ZStack {
                Color.black.opacity(0.05).ignoresSafeArea()
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(1.1)
                    if showSlowHint {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey("This dataset is taking a while to load, still working…"))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Button("Cancel") { cancelLoading() }
                                .buttonStyle(.bordered)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .shadow(radius: 8)
                .padding()
                .transition(.scale.combined(with: .opacity))
            }
            .animation(.snappy, value: showSlowHint)
        }
    }

    private func presentDatasetDetail(_ detail: DatasetDetails) {
        activeModal = .remoteDetail
        macModalPresenter.present(
            title: detail.displayName ?? detail.id,
            subtitle: nil,
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 600,
                idealWidth: 660,
                maxWidth: 760,
                minHeight: 560,
                idealHeight: 620,
                maxHeight: 780
            ),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            onDismiss: {
                activeModal = nil
                selected = nil
            }
        ) {
            detailSheet(detail)
        }
    }

    private func presentImportedDatasetDetail(_ dataset: LocalDataset) {
        activeModal = .localDetail
        macModalPresenter.present(
            title: dataset.name,
            subtitle: dataset.source.isEmpty ? nil : dataset.source,
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 600,
                idealWidth: 660,
                maxWidth: 760,
                minHeight: 560,
                idealHeight: 620,
                maxHeight: 780
            ),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            onDismiss: {
                activeModal = nil
                importedDataset = nil
            }
        ) {
            LocalDatasetDetailView(dataset: dataset)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(chatVM)
        }
    }

    private func presentNamePrompt() {
        activeModal = .namePrompt
        macModalPresenter.present(
            title: String(localized: "Import Dataset"),
            subtitle: nil,
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 360,
                idealWidth: 400,
                maxWidth: 460,
                minHeight: 220,
                idealHeight: 240,
                maxHeight: 320
            ),
            onDismiss: {
                activeModal = nil
                showNameSheet = false
            }
        ) {
            nameSheet
        }
    }

    private func dismissActiveModal() {
        guard activeModal != nil else { return }
        activeModal = nil
        if macModalPresenter.isPresented {
            macModalPresenter.dismiss()
        }
    }

    private func presentImporter() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedUTTypes()
        panel.canChooseFiles = true
        panel.title = String(localized: "Import Documents")
        if panel.runModal() == .OK {
            let (accepted, rejected) = DatasetDocumentSupport.partition(panel.urls)
            guard !accepted.isEmpty else {
                // Everything picked was unsupported (e.g. CSV/TSV) — explain rather
                // than silently doing nothing.
                if let message = DatasetDocumentSupport.skippedMessage(for: rejected) {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Unsupported file type")
                    alert.informativeText = message
                    alert.runModal()
                }
                return
            }
            pendingPickedURLs = accepted
            datasetName = suggestName(from: accepted) ?? String(localized: "Imported Dataset")
            showNameSheet = true
        }
    }

    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey("Name your dataset"))
                .font(.headline)
            TextField(LocalizedStringKey("Dataset name"), text: $datasetName)
                .textFieldStyle(.roundedBorder)
            Spacer()
            HStack {
                Button(LocalizedStringKey("Cancel")) { showNameSheet = false }
                Spacer()
                Button(LocalizedStringKey("Import")) { Task { await performImport() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(datasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 180)
    }

    private func updateRegistry(_ token: String) {
        let hf = CombinedDatasetRegistry(primary: HuggingFaceDatasetRegistry(token: token),
                                         extras: [ManualDatasetRegistry(entries: CuratedDatasets.hf)])
        vm.updateHFRegistry(hf)
        Task { await vm.loadCurated() }
    }

    private func allowedExtensions() -> Set<String> { DatasetDocumentSupport.acceptedExtensions }

    private func allowedUTTypes() -> [UTType] { DatasetDocumentSupport.allowedUTTypes() }

    private func suggestName(from urls: [URL]) -> String? {
        if let pdfURL = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            if let doc = PDFDocument(url: pdfURL),
               let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }
        if let u = urls.first {
            return u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        }
        return nil
    }

    private func performImport() async {
        let name = datasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pendingPickedURLs.isEmpty, !name.isEmpty else { return }
        if let ds = await datasetManager.importDocuments(from: pendingPickedURLs, suggestedName: name) {
            importedDataset = ds
            datasetToIndex = ds
            askStartIndexing = true
        }
        pendingPickedURLs.removeAll()
        showNameSheet = false
    }
}

#endif
