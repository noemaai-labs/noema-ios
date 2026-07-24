import Foundation

/// Combines results from multiple registries for datasets.
/// Search and details fall back to the primary registry when others fail.
final class CombinedDatasetRegistry: DatasetRegistry, @unchecked Sendable {
    private let primary: DatasetRegistry
    private let extras: [DatasetRegistry]

    init(primary: DatasetRegistry, extras: [DatasetRegistry]) {
        self.primary = primary
        self.extras = extras
    }

    func curated() async throws -> [DatasetRecord] {
        var results: [DatasetRecord] = []
        for reg in extras {
            do { results += try await reg.curated() } catch {}
        }
        return results
    }

    func searchStream(query: String, perPage: Int, maxPages: Int) -> AsyncThrowingStream<DatasetRecord, Error> {
        primary.searchStream(query: query, perPage: perPage, maxPages: maxPages)
    }

    func details(for id: String) async throws -> DatasetDetails {
        for reg in extras {
            if let d = try? await reg.details(for: id) { return d }
        }
        return try await primary.details(for: id)
    }
}
