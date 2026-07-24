import Foundation

/// Registry APIs used across concurrency domains
public protocol ModelRegistry: Sendable {
    func curated() async throws -> [ModelRecord]
    /// Streams search results as soon as individual records are fetched.
    func searchStream(query: String, page: Int, format: ModelFormat?, includeVisionModels: Bool, visionOnly: Bool) -> AsyncThrowingStream<ModelRecord, Error>
    func details(for id: String) async throws -> ModelDetails
    /// Repos trending on the source this week; registries without a trending
    /// feed return an empty list.
    func trending(format: ModelFormat?) async throws -> [ModelRecord]
}

extension ModelRegistry {
    public func trending(format: ModelFormat?) async throws -> [ModelRecord] { [] }
}

extension ModelRegistry {
    /// Convenience to collect a full result page.
    func search(query: String, page: Int, format: ModelFormat? = nil, includeVisionModels: Bool = true, visionOnly: Bool = false) async throws -> [ModelRecord] {
        var collected: [ModelRecord] = []
        for try await rec in searchStream(query: query, page: page, format: format, includeVisionModels: includeVisionModels, visionOnly: visionOnly) {
            collected.append(rec)
        }
        return collected
    }
}
