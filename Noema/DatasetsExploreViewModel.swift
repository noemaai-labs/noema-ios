import Foundation
import Combine

enum DatasetSource {
    case huggingFace, openTextbooks
}

@MainActor
final class DatasetsExploreViewModel: ObservableObject {
    @Published private(set) var recommended: [DatasetRecord] = []
    /// Curated Knowledge Packs, loaded independently of `recommended` so they
    /// render in their own "Knowledge Packs" lane (each card carries a category
    /// chip) rather than colliding with the OTL recommended set.
    @Published private(set) var knowledgePacks: [DatasetRecord] = []
    @Published private(set) var searchResults: [DatasetRecord] = []
    @Published var searchText: String = ""
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingSearch = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var canLoadMore = false
    @Published var searchError: String?
    @Published private(set) var source: DatasetSource = .openTextbooks

    private var registry: any DatasetRegistry
    private var hfRegistry: any DatasetRegistry
    private var otlRegistry: any DatasetRegistry
    private let packRegistry: any DatasetRegistry = ManualDatasetRegistry(entries: CuratedDatasets.knowledgePacks)
    private var searchTask: Task<Void, Never>?
    private var page = 0
    private var cancellables: Set<AnyCancellable> = []

    init(hfRegistry: any DatasetRegistry, otlRegistry: any DatasetRegistry) {
        self.hfRegistry = hfRegistry
        self.otlRegistry = otlRegistry
        // self.registry = hfRegistry
        self.registry = otlRegistry
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] in self?.handleSearchInput($0) }
            .store(in: &cancellables)
    }

    func loadCurated() async {
        if recommended.isEmpty {
            let reg = registry
            if let list = try? await reg.curated() {
                let mapped = list.map { rec in
                    DatasetRecord(id: rec.id,
                                  displayName: rec.displayName,
                                  publisher: rec.publisher,
                                  summary: rec.summary,
                                  installed: Self.isInstalled(rec.id))
                }
                var seen = Set<String>()
                recommended = mapped.filter { seen.insert($0.id).inserted }
            }
        }
    }

    /// Loads the curated Knowledge Packs into their own lane (independent of the
    /// OTL-backed `recommended` set). Re-runs cheaply to refresh `installed`.
    func loadKnowledgePacks() async {
        guard let list = try? await packRegistry.curated() else { return }
        knowledgePacks = list.map { rec in
            DatasetRecord(id: rec.id,
                          displayName: rec.displayName,
                          publisher: rec.publisher,
                          summary: rec.summary,
                          installed: Self.isInstalled(rec.id),
                          category: rec.category,
                          license: rec.license,
                          chunkCount: rec.chunkCount)
        }
    }

    func details(for id: String) async -> DatasetDetails? {
        // Knowledge Packs are served from their own registry.
        if id.hasPrefix(KnowledgePackCatalog.idPrefix) {
            return try? await packRegistry.details(for: id)
        }
        let reg = registry
        return try? await reg.details(for: id)
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

    func triggerSearch() { handleSearchInput(searchText) }

    private func search(query: String, reset: Bool) async {
        if reset {
            page = 0
            searchResults.removeAll()
        }

        isLoadingSearch = true
        let reg = registry
        let startPage = page
        let perPage = 50
        var collected: [DatasetRecord] = []
        do {
            for try await rec in reg.searchStream(query: query, perPage: perPage, maxPages: startPage + 1) {
                collected.append(rec)
            }
        } catch {
            if let err = error as? HuggingFaceDatasetRegistry.RegistryError {
                switch err {
                case .badStatus(let code):
                    if code == 429 {
                        searchError = "There was an error fetching results from Hugging Face, please try again later"
                    } else if code == 401 {
                        searchError = "Unauthorized – please check your Hugging Face token in Settings"
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
        let startIndex = startPage * perPage
        let slice = startIndex < collected.count ? collected[startIndex...] : []
        let mapped = slice.map { rec in
            DatasetRecord(id: rec.id,
                          displayName: rec.displayName,
                          publisher: rec.publisher,
                          summary: rec.summary,
                          installed: Self.isInstalled(rec.id))
        }
        var seen = Set(searchResults.map { $0.id })
        let unique = mapped.filter { seen.insert($0.id).inserted }
        searchResults.append(contentsOf: unique)
        canLoadMore = unique.count == perPage
        isLoadingSearch = false

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

    func updateHFRegistry(_ reg: any DatasetRegistry) {
        hfRegistry = reg
        if source == .huggingFace {
            registry = reg
            recommended.removeAll()
            searchResults.removeAll()
        }
    }

    private static func isInstalled(_ id: String) -> Bool {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        for comp in id.split(separator: "/") { url.appendPathComponent(String(comp), isDirectory: true) }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            return !files.isEmpty
        }
        return false
    }
}
