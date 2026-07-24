import Foundation
#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

struct NoemaSpotlightIndexRecord: Sendable, Hashable {
    let uniqueIdentifier: String
    let title: String
    let contentDescription: String
    let keywords: [String]
}

@MainActor
final class NoemaSpotlightIndexingService {
    static let shared = NoemaSpotlightIndexingService()

    private let chatDomain = "noema.chats"
    private let datasetDomain = "noema.datasets"
    private var chatTask: Task<Void, Never>?
    private var datasetTask: Task<Void, Never>?
    // Last successfully donated content per domain. Re-donating identical
    // records churns the OS-side donation translator (repeated
    // LNSpotlightCascadeTranslator failures in the log) for no gain.
    private var lastChatDigest: Int?
    private var lastDatasetDigest: Int?

    private init() {}

    func scheduleChatTitleIndex(records: [NoemaSpotlightIndexRecord]) {
        let digest = Self.digest(records)
        guard digest != lastChatDigest else { return }
        chatTask?.cancel()
        chatTask = Task { [chatDomain] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await Self.replaceDomain(chatDomain, records: records)
            await MainActor.run { Self.shared.lastChatDigest = digest }
        }
    }

    func scheduleDatasetNameIndex(records: [NoemaSpotlightIndexRecord]) {
        let digest = Self.digest(records)
        guard digest != lastDatasetDigest else { return }
        datasetTask?.cancel()
        datasetTask = Task { [datasetDomain] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            await Self.replaceDomain(datasetDomain, records: records)
            await MainActor.run { Self.shared.lastDatasetDigest = digest }
        }
    }

    private static func digest(_ records: [NoemaSpotlightIndexRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(records)
        return hasher.finalize()
    }

    func removeDatasetRecord(datasetID: String) {
        let identifier = Self.datasetIdentifier(for: datasetID)
        Task {
            await Self.deleteItems(identifiers: [identifier])
        }
    }

    static func chatIdentifier(for sessionID: UUID) -> String {
        "noema.chat.\(sessionID.uuidString)"
    }

    static func datasetIdentifier(for datasetID: String) -> String {
        "noema.dataset.\(datasetID)"
    }

    nonisolated private static func replaceDomain(_ domain: String, records: [NoemaSpotlightIndexRecord]) async {
#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                let items = records.map { searchableItem(for: $0, domain: domain) }
                guard !items.isEmpty else {
                    continuation.resume()
                    return
                }
                CSSearchableIndex.default().indexSearchableItems(items) { _ in
                    continuation.resume()
                }
            }
        }
#else
        _ = domain
        _ = records
#endif
    }

    nonisolated private static func deleteItems(identifiers: [String]) async {
#if canImport(CoreSpotlight)
        guard CSSearchableIndex.isIndexingAvailable(), !identifiers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers) { _ in
                continuation.resume()
            }
        }
#else
        _ = identifiers
#endif
    }

#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
    nonisolated private static func searchableItem(for record: NoemaSpotlightIndexRecord, domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = record.title
        attributes.contentDescription = record.contentDescription
        attributes.keywords = record.keywords
        return CSSearchableItem(
            uniqueIdentifier: record.uniqueIdentifier,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }
#endif
}
