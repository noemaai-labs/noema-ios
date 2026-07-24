import Foundation

/// Registry APIs for dataset listings.
public protocol DatasetRegistry: Sendable {
    func curated() async throws -> [DatasetRecord]
    func searchStream(query: String, perPage: Int, maxPages: Int) -> AsyncThrowingStream<DatasetRecord, Error>
    func details(for id: String) async throws -> DatasetDetails
}

extension DatasetRegistry {
    func search(query: String, perPage: Int, maxPages: Int) async throws -> [DatasetRecord] {
        var collected: [DatasetRecord] = []
        for try await rec in searchStream(query: query, perPage: perPage, maxPages: maxPages) {
            collected.append(rec)
        }
        return collected
    }
}
