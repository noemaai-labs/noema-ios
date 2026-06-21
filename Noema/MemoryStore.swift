import Foundation
import Combine

enum MemoryScope: String, CaseIterable, Codable, Equatable, Sendable {
    case allChats
    case currentProject
    case temporary

    var localizedTitle: String {
        switch self {
        case .allChats:
            return String(localized: "All Chats")
        case .currentProject:
            return String(localized: "Current Project")
        case .temporary:
            return String(localized: "Temporary")
        }
    }
}

struct MemoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var scope: MemoryScope?
    var expiresAt: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        scope: MemoryScope? = .allChats,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.scope = scope
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var effectiveScope: MemoryScope {
        scope ?? .allChats
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

enum MemoryConflictKind: String, Codable, Equatable, Sendable {
    case contradiction
    case preference

    var localizedSummary: String {
        switch self {
        case .contradiction:
            return String(localized: "Opposite wording on a similar topic")
        case .preference:
            return String(localized: "Preference or avoidance may conflict")
        }
    }
}

struct MemoryConflict: Identifiable, Codable, Equatable, Sendable {
    let entryID: UUID
    let title: String
    let kind: MemoryConflictKind

    var id: String { "\(entryID.uuidString)-\(kind.rawValue)" }
}

struct MemoryReviewItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var scope: MemoryScope?
    var expiresAt: Date?
    var possibleConflicts: [MemoryConflict]?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        scope: MemoryScope? = .allChats,
        expiresAt: Date? = nil,
        possibleConflicts: [MemoryConflict] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.scope = scope
        self.expiresAt = expiresAt
        self.possibleConflicts = possibleConflicts
        self.createdAt = createdAt
    }

    var effectiveScope: MemoryScope {
        scope ?? .allChats
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

enum MemoryStoreError: LocalizedError, Equatable {
    case missingIdentifier
    case notFound
    case duplicateTitle
    case maximumEntriesReached
    case emptyTitle
    case emptyContent
    case stringNotFound
    case invalidInsertIndex
    case reviewItemNotFound

    var errorDescription: String? {
        switch self {
        case .missingIdentifier:
            return String(localized: "Provide either an entry id or a title.")
        case .notFound:
            return String(localized: "Memory entry not found.")
        case .duplicateTitle:
            return String(localized: "A memory entry with that title already exists.")
        case .maximumEntriesReached:
            return String(localized: "You can store up to 20 memory entries.")
        case .emptyTitle:
            return String(localized: "Memory title cannot be empty.")
        case .emptyContent:
            return String(localized: "Memory content cannot be empty.")
        case .stringNotFound:
            return String(localized: "The text to replace was not found in the memory entry.")
        case .invalidInsertIndex:
            return String(localized: "Insert index is outside the memory entry content.")
        case .reviewItemNotFound:
            return String(localized: "Memory review item not found.")
        }
    }
}

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    static let maximumEntries = 20

    @Published private(set) var entries: [MemoryEntry] = []
    @Published private(set) var reviewItems: [MemoryReviewItem] = []

    private let fileURL: URL
    private let reviewFileURL: URL
    private let notificationCenter: NotificationCenter

    init(
        fileURL: URL = MemoryStore.defaultFileURL(),
        reviewFileURL: URL = MemoryStore.defaultReviewFileURL(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.fileURL = fileURL
        self.reviewFileURL = reviewFileURL
        self.notificationCenter = notificationCenter
        self.entries = Self.loadEntries(from: fileURL)
        self.reviewItems = Self.loadReviewItems(from: reviewFileURL)
    }

    nonisolated static func defaultDirectory() -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func defaultFileURL() -> URL {
        defaultDirectory().appendingPathComponent("memories.json")
    }

    nonisolated static func defaultReviewFileURL() -> URL {
        defaultDirectory().appendingPathComponent("memory_review_inbox.json")
    }

    func reload() {
        entries = Self.loadEntries(from: fileURL)
        reviewItems = Self.loadReviewItems(from: reviewFileURL)
    }

    func promptSnapshot() -> String {
        Self.promptSnapshot(entries: entries)
    }

    nonisolated static func promptSnapshotFromDisk() -> String {
        promptSnapshot(entries: loadEntries(from: defaultFileURL()))
    }

    nonisolated static func promptSnapshot(entries: [MemoryEntry]) -> String {
        renderPromptSnapshot(entries: entries)
    }

    func entry(id: String?, title: String?) throws -> MemoryEntry {
        let index = try resolveIndex(id: id, title: title)
        return entries[index]
    }

    func create(
        title: String,
        content: String,
        scope: MemoryScope? = .allChats,
        expiresAt: Date? = nil
    ) throws -> MemoryEntry {
        guard entries.count < Self.maximumEntries else {
            throw MemoryStoreError.maximumEntriesReached
        }
        let normalizedTitle = try normalizedTitle(title)
        let normalizedContent = try normalizedContent(content)
        try assertTitleAvailable(normalizedTitle)

        let entry = MemoryEntry(title: normalizedTitle, content: normalizedContent, scope: scope, expiresAt: expiresAt)
        entries.append(entry)
        persist()
        return entry
    }

    func proposeCreate(
        title: String,
        content: String,
        scope: MemoryScope? = .allChats,
        expiresAt: Date? = nil
    ) throws -> MemoryReviewItem {
        let normalizedTitle = try normalizedTitle(title)
        let normalizedContent = try normalizedContent(content)
        let conflicts = Self.detectConflicts(
            candidateTitle: normalizedTitle,
            candidateContent: normalizedContent,
            entries: entries,
            excluding: nil
        )
        let item = MemoryReviewItem(
            title: normalizedTitle,
            content: normalizedContent,
            scope: scope,
            expiresAt: expiresAt,
            possibleConflicts: conflicts
        )
        reviewItems.insert(item, at: 0)
        persistReviewItems()
        return item
    }

    func possibleConflicts(title: String, content: String, excluding excludedID: UUID? = nil) -> [MemoryConflict] {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, !normalizedContent.isEmpty else { return [] }
        return Self.detectConflicts(
            candidateTitle: normalizedTitle,
            candidateContent: normalizedContent,
            entries: entries,
            excluding: excludedID
        )
    }

    @discardableResult
    func approveReviewItem(id: UUID) throws -> MemoryEntry {
        guard let index = reviewItems.firstIndex(where: { $0.id == id }) else {
            throw MemoryStoreError.reviewItemNotFound
        }
        let item = reviewItems[index]
        let entry = try create(
            title: item.title,
            content: item.content,
            scope: item.scope,
            expiresAt: item.expiresAt
        )
        reviewItems.remove(at: index)
        persistReviewItems()
        return entry
    }

    @discardableResult
    func rejectReviewItem(id: UUID) throws -> MemoryReviewItem {
        guard let index = reviewItems.firstIndex(where: { $0.id == id }) else {
            throw MemoryStoreError.reviewItemNotFound
        }
        let item = reviewItems.remove(at: index)
        persistReviewItems()
        return item
    }

    func replace(id: String?, title: String?, content: String) throws -> MemoryEntry {
        let index = try resolveIndex(id: id, title: title)
        entries[index].content = try normalizedContent(content)
        entries[index].updatedAt = Date()
        persist()
        return entries[index]
    }

    func insert(id: String?, title: String?, content: String, at insertAt: Int?) throws -> MemoryEntry {
        let index = try resolveIndex(id: id, title: title)
        let insertion = try normalizedContent(content)
        let existing = entries[index].content
        let resolvedIndex = insertAt ?? existing.count
        guard resolvedIndex >= 0, resolvedIndex <= existing.count else {
            throw MemoryStoreError.invalidInsertIndex
        }

        let insertionIndex = existing.index(existing.startIndex, offsetBy: resolvedIndex)
        entries[index].content.insert(contentsOf: insertion, at: insertionIndex)
        entries[index].updatedAt = Date()
        persist()
        return entries[index]
    }

    func stringReplace(
        id: String?,
        title: String?,
        oldString: String,
        newString: String
    ) throws -> MemoryEntry {
        let index = try resolveIndex(id: id, title: title)
        guard !oldString.isEmpty else { throw MemoryStoreError.stringNotFound }
        guard entries[index].content.contains(oldString) else {
            throw MemoryStoreError.stringNotFound
        }

        entries[index].content = entries[index].content.replacingOccurrences(of: oldString, with: newString)
        entries[index].updatedAt = Date()
        persist()
        return entries[index]
    }

    @discardableResult
    func delete(id: String?, title: String?) throws -> MemoryEntry {
        let index = try resolveIndex(id: id, title: title)
        let removed = entries.remove(at: index)
        persist()
        return removed
    }

    func rename(id: String?, title: String?, newTitle: String) throws -> MemoryEntry {
        let index = try resolveIndex(id: id, title: title)
        let normalized = try normalizedTitle(newTitle)
        try assertTitleAvailable(normalized, excluding: entries[index].id)
        entries[index].title = normalized
        entries[index].updatedAt = Date()
        persist()
        return entries[index]
    }

    func updateEntry(
        id: UUID,
        title: String,
        content: String,
        scope: MemoryScope? = .allChats,
        expiresAt: Date? = nil
    ) throws -> MemoryEntry {
        let index = try resolveIndex(id: id.uuidString, title: nil)
        let normalizedTitle = try normalizedTitle(title)
        let normalizedContent = try normalizedContent(content)
        try assertTitleAvailable(normalizedTitle, excluding: entries[index].id)
        entries[index].title = normalizedTitle
        entries[index].content = normalizedContent
        entries[index].scope = scope
        entries[index].expiresAt = expiresAt
        entries[index].updatedAt = Date()
        persist()
        return entries[index]
    }

    private func resolveIndex(id: String?, title: String?) throws -> Int {
        if let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedID.isEmpty,
           let uuid = UUID(uuidString: trimmedID),
           let index = entries.firstIndex(where: { $0.id == uuid }) {
            return index
        }

        if let normalizedTitle = normalizedLookupTitle(title),
           let index = entries.firstIndex(where: {
               $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedTitle
           }) {
            return index
        }

        if (id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw MemoryStoreError.missingIdentifier
        }

        throw MemoryStoreError.notFound
    }

    private func normalizedTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MemoryStoreError.emptyTitle }
        return title
    }

    private func normalizedContent(_ raw: String) throws -> String {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw MemoryStoreError.emptyContent }
        return content
    }

    private func normalizedLookupTitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func assertTitleAvailable(_ title: String, excluding excludedID: UUID? = nil) throws {
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let collision = entries.contains {
            $0.id != excludedID
                && $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
        }
        if collision {
            throw MemoryStoreError.duplicateTitle
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: [.atomic])
        }
        notificationCenter.post(name: .memoryStoreDidChange, object: nil)
    }

    private func persistReviewItems() {
        try? FileManager.default.createDirectory(
            at: reviewFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(reviewItems) {
            try? data.write(to: reviewFileURL, options: [.atomic])
        }
        notificationCenter.post(name: .memoryStoreDidChange, object: nil)
    }

    nonisolated private static func renderPromptSnapshot(entries: [MemoryEntry]) -> String {
        let header = """
        Persistent Memory:
        This memory persists across multiple conversations on this device.
        Every memory entry is about the user: their identity, preferences, constraints, environment, or other durable user-specific context.
        Interpret first-person statements inside memories as statements about the user, not about yourself.
        Read it before relying on remembered preferences or project facts.
        Write to it only when a fact is durable, reusable, and likely to help in future conversations.
        Avoid saving transient details, guesses, or secrets unless the user explicitly asks you to remember them.
        """

        let activeEntries = entries.filter { !$0.isExpired }
        guard !activeEntries.isEmpty else {
            return header + "\n\nEntries:\n- None yet."
        }

        let renderedEntries = activeEntries.enumerated().map { index, entry in
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let scope = entry.effectiveScope.rawValue
            return "\(index + 1). \(title)\n   id: \(entry.id.uuidString)\n   scope: \(scope)\n   content: \(content)"
        }.joined(separator: "\n")

        return header + "\n\nEntries:\n" + renderedEntries
    }

    nonisolated private static func detectConflicts(
        candidateTitle: String,
        candidateContent: String,
        entries: [MemoryEntry],
        excluding excludedID: UUID?
    ) -> [MemoryConflict] {
        let candidateText = "\(candidateTitle) \(candidateContent)"
        let candidateTopics = topicTokens(in: candidateText)
        guard !candidateTopics.isEmpty else { return [] }

        let candidateNegative = hasNegativeCue(candidateText)
        let candidatePreference = preferencePolarity(candidateText)

        return entries.compactMap { entry in
            guard entry.id != excludedID, !entry.isExpired else { return nil }
            let entryText = "\(entry.title) \(entry.content)"
            let overlap = candidateTopics.intersection(topicTokens(in: entryText)).count
            guard overlap >= 2 || (overlap >= 1 && candidatePreference != nil) else { return nil }

            if let candidatePreference,
               let existingPreference = preferencePolarity(entryText),
               candidatePreference != existingPreference {
                return MemoryConflict(entryID: entry.id, title: entry.title, kind: .preference)
            }

            if overlap >= 2, candidateNegative != hasNegativeCue(entryText) {
                return MemoryConflict(entryID: entry.id, title: entry.title, kind: .contradiction)
            }

            return nil
        }
    }

    nonisolated private static func topicTokens(in text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "about", "after", "also", "because", "before", "being", "cannot", "could", "does", "doesnt",
            "dont", "from", "have", "into", "like", "love", "never", "only", "prefer", "should", "that",
            "their", "there", "these", "they", "this", "user", "uses", "want", "wants", "when", "with",
            "would", "your"
        ]
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(normalized.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4, !stopwords.contains(trimmed) else { return nil }
            return trimmed
        })
    }

    nonisolated private static func hasNegativeCue(_ text: String) -> Bool {
        let padded = " " + text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) + " "
        return [
            " avoid ", " avoids ", " cannot ", " can't ", " did not ", " didn't ", " dislike ", " dislikes ",
            " does not ", " doesn't ", " do not ", " don't ", " hate ", " hates ", " is not ", " isn't ",
            " never ", " no longer ", " not "
        ].contains { padded.contains($0) }
    }

    nonisolated private static func preferencePolarity(_ text: String) -> Bool? {
        let padded = " " + text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) + " "
        let positive = [" like ", " likes ", " love ", " loves ", " prefer ", " prefers ", " wants "]
        let negative = [" avoid ", " avoids ", " dislike ", " dislikes ", " hate ", " hates "]
        if negative.contains(where: { padded.contains($0) }) { return false }
        if positive.contains(where: { padded.contains($0) }) { return true }
        return nil
    }

    nonisolated private static func loadEntries(from fileURL: URL) -> [MemoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MemoryEntry].self, from: data)) ?? []
    }

    nonisolated private static func loadReviewItems(from fileURL: URL) -> [MemoryReviewItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MemoryReviewItem].self, from: data)) ?? []
    }
}
