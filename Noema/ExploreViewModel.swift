#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS)
import Foundation
import Combine

enum ExploreSearchMode: String {
    case gguf = "GGUF"
    case mlx = "MLX"
    case et  = "ET"
    case ane = "ANE"
    case afm = "AFM"
    case coreai = "CoreAI"

    var displayName: String {
        switch self {
        case .ane:
            return "CML"
        case .coreai:
            return "Core AI"
        default:
            return rawValue
        }
    }

    var formatFilter: ModelFormat {
        switch self {
        case .gguf:
            return .gguf
        case .mlx:
            return .mlx
        case .et:
            return .et
        case .ane:
            return .ane
        case .afm:
            return .afm
        case .coreai:
            return .coreai
        }
    }

    func includes(_ record: ModelRecord) -> Bool {
        switch self {
        case .gguf:
            return record.formats.contains(.gguf)
        case .mlx:
            return record.formats.contains(.mlx)
        case .et:
            return record.formats.contains(.et)
        case .ane:
            return record.formats.contains(.ane)
        case .afm:
            return record.formats.contains(.afm)
        case .coreai:
            return record.formats.contains(.coreai)
        }
    }
}
@MainActor
final class ExploreViewModel: ObservableObject {
    @Published private(set) var recommended: [ModelRecord] = []
    @Published private(set) var trendingRecords: [ModelRecord] = []
    @Published private(set) var cachedRecords: [ModelRecord] = []
    @Published private(set) var searchResults: [ModelRecord] = []
    @Published var searchText: String = ""
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var isLoadingSearch = false
    @Published var searchError: String?
    @Published var searchMode: ExploreSearchMode = ExploreSearchMode.gguf {
        didSet {
        }
    }
    
    // Filter manager for text/vision filtering
    private var filterManager: ModelTypeFilterManager?

    private var registry: any ModelRegistry
    private var searchTask: Task<Void, Never>?
    private var page = 0
    private var cancellables: Set<AnyCancellable> = []
    private var prefetchedVisionRepos: Set<String> = []

    init(registry: any ModelRegistry) {
        self.registry = registry
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] in self?.handleSearchInput($0) }
            .store(in: &cancellables)
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { _ in }
            .store(in: &cancellables)
    }

    deinit {
        // Ensure any in-flight search is cancelled to avoid retaining self via task closures.
        searchTask?.cancel()
    }
    
    func setFilterManager(_ manager: ModelTypeFilterManager) {
        self.filterManager = manager
    }

    func loadCurated(force: Bool = false) async {
        if force { recommended.removeAll() }
        if recommended.isEmpty {
            let reg = registry
            if let list = try? await reg.curated() {
                print("[ExploreVM] curated() returned \(list.count) records")
                var seen = Set<String>()
                let deduped = list.filter { seen.insert($0.id).inserted }
                recommended = Self.prioritizeAuthors(in: deduped)
                print("[ExploreVM] recommended set to \(recommended.count) records")
                prefetchVisionStatus(for: recommended)
            } else {
                print("[ExploreVM] curated() returned nil (threw or empty)")
            }
        }
    }

    func loadTrending(force: Bool = false, format: ModelFormat?) async {
        if force { trendingRecords.removeAll() }
        guard trendingRecords.isEmpty else { return }
        guard !NetworkKillSwitch.isEnabled else { return }
        guard let format else {
            trendingRecords = []
            return
        }
        let reg = registry
        if let list = try? await reg.trending(format: format) {
            var seen = Set<String>()
            trendingRecords = list.filter { seen.insert($0.id).inserted }
            prefetchVisionStatus(for: trendingRecords)
        }
    }

    func loadCachedRecords() {
        cachedRecords = ExploreModelDetailCache.records()
    }

    func details(for id: String, preferCached: Bool = false, allowNetwork: Bool = true) async -> ModelDetails? {
        if preferCached, let snapshot = ExploreModelDetailCache.snapshot(repoID: id) {
            return snapshot.details
        }

        guard allowNetwork, !NetworkKillSwitch.isEnabled else {
            searchError = String(localized: "No offline Explore cache is available for this model.")
            return nil
        }

        let reg = registry
        do {
            let details = try await reg.details(for: id)
            ExploreModelDetailCache.save(details)
            loadCachedRecords()
            return details
        } catch {
            if let snapshot = ExploreModelDetailCache.snapshot(repoID: id) {
                return snapshot.details
            }
            searchError = error.localizedDescription
            return nil
        }
    }

    private func handleSearchInput(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { isSearching = false; isLoadingSearch = false; return }
        isSearching = true
        searchTask = Task { [weak self] in
            await self?.search(query: trimmed, reset: true)
        }
    }

    func triggerSearch() {
        handleSearchInput(searchText)
    }

    private func search(query: String, reset: Bool) async {
        if reset {
            page = 0
            searchResults.removeAll()
        }

        isLoadingSearch = true
        let reg = registry
        let mode = searchMode
        let formatFilter: ModelFormat? = mode.formatFilter
        let startPage = page
        var existing = reset ? Set<String>() : Set(searchResults.map { $0.id })

        var fetched: [ModelRecord] = []
        var unfilteredResults: [ModelRecord] = []
        var pageCount = 0
        
        var includeVisionModels = (mode == .gguf || mode == .mlx || mode == .et || mode == .ane)
        if mode == .afm {
            includeVisionModels = false
        }
        var visionOnly = false
        if let fm = filterManager, UIConstants.showMultimodalUI {
            switch fm.filter {
            case .vision:
                includeVisionModels = true
                visionOnly = true
            case .text:
                includeVisionModels = false
            case .all:
                includeVisionModels = true
            }
        }
        
        do {
            for try await rec in reg.searchStream(query: query, page: startPage, format: formatFilter, includeVisionModels: includeVisionModels, visionOnly: visionOnly) {
                pageCount += 1
                unfilteredResults.append(rec)
                
                // Apply filtering based on mode and, if set, the Vision/Text filter.
                var shouldInclude = false
                let isVLM = (rec.pipeline_tag == "image-text-to-text")
                switch mode {
                case .gguf:
                    // In GGUF mode, only allow repos that advertise GGUF.
                    // If Vision filter is active, require VLM as well.
                    shouldInclude = mode.includes(rec) && (!visionOnly || isVLM)
                case .mlx:
                    // In MLX mode, require an actual MLX signal. Namespace-only
                    // matches from GGUF publishers are intentionally not enough.
                    // If Vision filter is active, require VLM as well.
                    shouldInclude = mode.includes(rec) && (!visionOnly || isVLM)
                case .et:
                    // ET mode uses Hugging Face `filter=executorch`.
                    shouldInclude = mode.includes(rec) && (!visionOnly || isVLM)
                case .ane:
                    // ANE mode uses Hugging Face `filter=coreml`.
                    shouldInclude = mode.includes(rec) && (!visionOnly || isVLM)
                case .afm:
                    // AFM mode is local-only and text-only.
                    shouldInclude = mode.includes(rec) && !isVLM
                case .coreai:
                    // CoreAI mode searches Hugging Face repos tagged "coreai"/"aimodel".
                    // No vision chat support yet, so honor a strict vision-only filter.
                    shouldInclude = mode.includes(rec) && !visionOnly
                }
                
                #if DEBUG
                if !shouldInclude {
                    print("[ExploreViewModel] Filtered out: \(rec.id) formats: \(rec.formats) mode: \(mode)")
                }
                #endif
                
                if shouldInclude && existing.insert(rec.id).inserted {
                    fetched.append(rec)
                }
            }
        } catch {
            if let err = error as? HuggingFaceRegistry.RegistryError {
                if case .badStatus(let code) = err {
                    if code == 401 {
                        searchError = "Unauthorized – please check your Hugging Face token in Settings"
                    } else if code == 429 {
                        searchError = "There was an error fetching results from Hugging Face, please try again later"
                    } else {
                        searchError = err.localizedDescription
                    }
                }
            } else if let urlErr = error as? URLError {
                searchError = "Network error: \(urlErr.code.rawValue)"
            } else {
                searchError = error.localizedDescription
            }

        }
    
        let prioritized = Self.prioritizeAuthors(in: fetched)
        // Append, then re-dedupe and re-prioritize to avoid any duplicates slipping through
        let appended = searchResults + prioritized
        var seenFinal = Set<String>()
        searchResults = appended.filter { seenFinal.insert($0.id).inserted }
        searchResults = Self.prioritizeAuthors(in: searchResults)
        canLoadMore = pageCount == 50
        isLoadingSearch = false
        prefetchVisionStatus(for: searchResults)
    }

    func loadNextPage() {
        guard isSearching && canLoadMore && !isLoadingPage else { return }
        isLoadingPage = true
        page += 1
        searchTask = Task { [weak self, page] in
            guard let self = self else { return }
            let trimmed = self.searchText.trimmingCharacters(in: .whitespaces)
            await self.search(query: trimmed, reset: false)
            await MainActor.run { self.isLoadingPage = false }
        }
    }

    func toggleMode() {
        if !DeviceGPUInfo.supportsGPUOffload {
            // Pre-A13: skip MLX entirely; cycle GGUF -> ET -> ANE -> GGUF.
            switch searchMode {
            case .gguf:
                searchMode = .et
            case .mlx:
                // If somehow set to MLX, jump to GGUF
                searchMode = .gguf
            case .et:
                searchMode = .ane
            case .ane:
                searchMode = .gguf
            case .coreai:
                searchMode = .gguf
            case .afm:
                searchMode = .gguf
            }
        } else {
            // GPU-capable cycle: GGUF -> MLX -> ET -> ANE -> CoreAI -> GGUF.
            // CoreAI is skipped below OS 27, where those models are hidden.
            switch searchMode {
            case .gguf:
                searchMode = .mlx
            case .mlx:
                searchMode = .et
            case .et:
                searchMode = .ane
            case .ane:
                searchMode = ModelFormat.isCoreAIRuntimeAvailable ? .coreai : .gguf
            case .coreai:
                searchMode = .gguf
            case .afm:
                searchMode = .gguf
            }
        }

        handleSearchInput(searchText)
    }

    func updateRegistry(_ reg: any ModelRegistry) {
        registry = reg
    }

    private func prefetchVisionStatus(for records: [ModelRecord]) {
        guard let filterManager else { return }
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authToken = (token?.isEmpty ?? true) ? nil : token
        // Prefetch for GGUF/MLX repos and also any with an explicit VLM pipeline tag so
        // Vision mode results on iOS/macOS can resolve quickly.
        let repos = records
            .filter { $0.formats.contains(.gguf) || $0.formats.contains(.mlx) || $0.formats.contains(.et) || $0.formats.contains(.ane) || ($0.pipeline_tag == "image-text-to-text") }
            .map(\.id)
            .filter { !prefetchedVisionRepos.contains($0) }
        guard !repos.isEmpty else { return }
        prefetchedVisionRepos.formUnion(repos)
        Task {
            for repo in repos.prefix(24) {
                let known = await MainActor.run { filterManager.knownVisionStatus(for: repo) }
                if known != nil { continue }
                let isVision = await VisionModelDetector.isVisionModel(repoId: repo, token: authToken)
                await MainActor.run {
                    filterManager.updateVisionStatus(repoId: repo, isVision: isVision)
                }
            }
        }
    }
}

private extension ExploreViewModel {
    static func prioritizeAuthors(in records: [ModelRecord]) -> [ModelRecord] {
        let priorityAuthors: [String] = ["unsloth", "bartowski", "lmstudio-community", "second-state"]
        let prioritySet = Set(priorityAuthors.map { $0.lowercased() })

        let (priority, others) = records.stablePartition { rec in
            prioritySet.contains(rec.publisher.lowercased())
        }

        return priority + others
    }
}

private extension Array {
    func stablePartition(by belongsInFirstPartition: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        first.reserveCapacity(count)
        second.reserveCapacity(count)
        for element in self {
            if belongsInFirstPartition(element) {
                first.append(element)
            } else {
                second.append(element)
            }
        }
        return (first, second)
    }
}
#endif
