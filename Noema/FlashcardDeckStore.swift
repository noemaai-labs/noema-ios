import Foundation

@MainActor
final class FlashcardDeckStore: ObservableObject {
    static let shared = FlashcardDeckStore()

    @Published private(set) var decks: [FlashcardDeck] = []

    private struct Envelope: Codable {
        var schema: String
        var schemaVersion: Int
        var decks: [FlashcardDeck]
    }

    private static let schema = "noema.flashcards.decks"
    private static let schemaVersion = 1
    private static let saveDebounceNanoseconds: UInt64 = 750_000_000

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let baseDirectoryOverride: URL?
    private var pendingSaveTask: Task<Void, Never>?

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryOverride = baseDirectory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        load()
    }

    func deck(id: UUID) -> FlashcardDeck? {
        decks.first { $0.id == id }
    }

    func upsert(_ deck: FlashcardDeck) {
        var updated = deck
        updated.modifiedAt = Date()
        if let index = decks.firstIndex(where: { $0.id == deck.id }) {
            decks[index] = updated
        } else {
            decks.insert(updated, at: 0)
        }
        persistNow()
    }

    func rename(deckID: UUID, to name: String) {
        guard let index = decks.firstIndex(where: { $0.id == deckID }) else { return }
        decks[index].name = name
        decks[index].modifiedAt = Date()
        persistNow()
    }

    func delete(deckID: UUID) {
        decks.removeAll { $0.id == deckID }
        persistNow()
    }

    func addCard(_ card: Flashcard, to deckID: UUID) {
        guard let index = decks.firstIndex(where: { $0.id == deckID }) else { return }
        decks[index].cards.append(card)
        decks[index].modifiedAt = Date()
        persistNow()
    }

    func updateCard(_ card: Flashcard, in deckID: UUID) {
        guard let deckIndex = decks.firstIndex(where: { $0.id == deckID }),
              let cardIndex = decks[deckIndex].cards.firstIndex(where: { $0.id == card.id }) else { return }
        var updated = card
        updated.modifiedAt = Date()
        decks[deckIndex].cards[cardIndex] = updated
        decks[deckIndex].modifiedAt = updated.modifiedAt
        persistNow()
    }

    func deleteCard(id: UUID, from deckID: UUID) {
        guard let index = decks.firstIndex(where: { $0.id == deckID }) else { return }
        decks[index].cards.removeAll { $0.id == id }
        decks[index].modifiedAt = Date()
        persistNow()
    }

    /// Grades arrive every few seconds during a study session, so review
    /// writes are debounced; structural mutations above persist immediately.
    func applyReview(deckID: UUID, cardID: UUID, grade: FlashcardGrade, now: Date = Date()) {
        guard let deckIndex = decks.firstIndex(where: { $0.id == deckID }),
              let cardIndex = decks[deckIndex].cards.firstIndex(where: { $0.id == cardID }) else { return }
        let graded = FlashcardLeitnerScheduler.applyGrade(
            grade,
            to: decks[deckIndex].cards[cardIndex],
            now: now
        )
        decks[deckIndex].cards[cardIndex] = graded
        decks[deckIndex].modifiedAt = now
        scheduleDebouncedSave()
    }

    func flushPendingSave() {
        guard pendingSaveTask != nil else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        persistNow()
    }

    private func scheduleDebouncedSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.pendingSaveTask = nil
            self.persistNow()
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            decks = []
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schema == Self.schema, envelope.schemaVersion <= Self.schemaVersion else {
                quarantineStoreFile(reason: "unsupported schema \(envelope.schema) v\(envelope.schemaVersion)")
                decks = []
                return
            }
            decks = envelope.decks.sorted { $0.modifiedAt > $1.modifiedAt }
        } catch {
            // Unlike BoardingPassDraftStore, don't let the next persist()
            // silently overwrite user-authored decks — quarantine the file.
            quarantineStoreFile(reason: error.localizedDescription)
            decks = []
        }
    }

    private func quarantineStoreFile(reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantineURL = storeURL.appendingPathExtension("corrupt-\(stamp)")
        try? fileManager.moveItem(at: storeURL, to: quarantineURL)
        Task { await logger.log("[Flashcards] Deck store unreadable (\(reason)) — quarantined to \(quarantineURL.lastPathComponent)") }
    }

    private func persistNow() {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let envelope = Envelope(schema: Self.schema, schemaVersion: Self.schemaVersion, decks: decks)
            let data = try encoder.encode(envelope)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Task { await logger.log("[Flashcards] Failed to persist decks: \(error.localizedDescription)") }
        }
    }

    private var storeURL: URL {
        baseDirectory.appendingPathComponent("FlashcardDecks.json")
    }

    private var baseDirectory: URL {
        if let baseDirectoryOverride {
            return baseDirectoryOverride
        }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return documents.appendingPathComponent("Flashcards", isDirectory: true)
    }
}
