import Foundation
import SwiftUI

@MainActor
final class OpenTextbookPager: ObservableObject {
    @Published var items: [DatasetRecord] = []
    @Published var hasMore = true
    private var page = 1
    private var isLoading = false
    private let query: String
    private let perPage: Int
    private let registry: OpenTextbookLibraryDatasetRegistry
    private var seen = Set<String>()

    init(query: String, perPage: Int = 100, registry: OpenTextbookLibraryDatasetRegistry = OpenTextbookLibraryDatasetRegistry()) {
        self.query = query
        self.perPage = perPage
        self.registry = registry
    }

    func loadNextPage() {
        guard !isLoading && hasMore else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let results = try await registry.fetchPage(query: query, page: page, perPage: perPage)
                var newItems: [DatasetRecord] = []
                for r in results {
                    if !seen.contains(r.id) {
                        seen.insert(r.id)
                        newItems.append(r)
                    }
                }
                items.append(contentsOf: newItems)
                page += 1
                if results.count < perPage { hasMore = false }
            } catch {
                hasMore = false
            }
        }
    }
}
