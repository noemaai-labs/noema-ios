import Foundation

/// Registry providing manually curated dataset listings.
public final class ManualDatasetRegistry: DatasetRegistry, @unchecked Sendable {
    public struct Entry: Sendable {
        let record: DatasetRecord
        let details: DatasetDetails
    }

    private let entries: [Entry]

    public init(entries: [Entry] = ManualDatasetRegistry.defaultEntries) {
        self.entries = entries
    }

    public func curated() async throws -> [DatasetRecord] {
        return entries.map { $0.record }
    }

    public func details(for id: String) async throws -> DatasetDetails {
        guard let e = entries.first(where: { $0.record.id == id }) else {
            throw URLError(.badURL)
        }
        return e.details
    }

    public func searchStream(query: String, perPage: Int, maxPages: Int) -> AsyncThrowingStream<DatasetRecord, Error> {
        .init { continuation in
            continuation.finish()
        }
    }

    public static let defaultEntries: [Entry] = [
        Entry(
            record: DatasetRecord(id: "example/dataset",
                                  displayName: "Example Dataset",
                                  publisher: "example",
                                  summary: String(localized: "Sample dataset", locale: LocalizationManager.preferredLocale()),
                                  installed: false),
            details: DatasetDetails(id: "example/dataset",
                                    summary: String(localized: "Sample dataset", locale: LocalizationManager.preferredLocale()),
                                    files: [DatasetFile(id: "data.txt", name: "data.txt", sizeBytes: 1024, downloadURL: URL(string: "https://example.com/data.txt")!)],
                                    displayName: "Example Dataset")
        )
    ]
}
