import Foundation

enum FlashcardGrade: String, Codable, Sendable {
    case again
    case good
    case easy
}

enum FlashcardCardOrigin: String, Codable, Sendable {
    case generated
    case manual
}

struct Flashcard: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var front: String
    var back: String
    var hint: String?
    /// Leitner box 1...FlashcardLeitnerScheduler.boxCount.
    var box: Int
    /// nil = new card, due immediately.
    var dueDate: Date?
    var lastReviewedAt: Date?
    var reviewCount: Int
    var lapses: Int
    var origin: FlashcardCardOrigin
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        front: String,
        back: String,
        hint: String? = nil,
        box: Int = 1,
        dueDate: Date? = nil,
        lastReviewedAt: Date? = nil,
        reviewCount: Int = 0,
        lapses: Int = 0,
        origin: FlashcardCardOrigin = .manual,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.hint = hint
        self.box = box
        self.dueDate = dueDate
        self.lastReviewedAt = lastReviewedAt
        self.reviewCount = reviewCount
        self.lapses = lapses
        self.origin = origin
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, front, back, hint, box, dueDate, lastReviewedAt
        case reviewCount, lapses, origin, createdAt, modifiedAt
    }

    // Lenient decoding: only id/front/back are required so decks written by
    // newer builds (extra fields) or older builds (missing fields) still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        front = try container.decode(String.self, forKey: .front)
        back = try container.decode(String.self, forKey: .back)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        box = try container.decodeIfPresent(Int.self, forKey: .box) ?? 1
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        lastReviewedAt = try container.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        lapses = try container.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        let originRaw = try container.decodeIfPresent(String.self, forKey: .origin)
        origin = originRaw.flatMap(FlashcardCardOrigin.init(rawValue:)) ?? .manual
        let now = Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }
}

struct FlashcardDeck: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var topic: String
    var cards: [Flashcard]
    var createdAt: Date
    var modifiedAt: Date
    // Provenance for display only. Never dereferenced at review time — the
    // source dataset may be an ephemeral attached document that has expired.
    var sourceModelName: String?
    var sourceDatasetID: String?
    var sourceDatasetName: String?

    init(
        id: UUID = UUID(),
        name: String,
        topic: String,
        cards: [Flashcard],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        sourceModelName: String? = nil,
        sourceDatasetID: String? = nil,
        sourceDatasetName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.cards = cards
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sourceModelName = sourceModelName
        self.sourceDatasetID = sourceDatasetID
        self.sourceDatasetName = sourceDatasetName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, topic, cards, createdAt, modifiedAt
        case sourceModelName, sourceDatasetID, sourceDatasetName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
        cards = try container.decodeIfPresent([Flashcard].self, forKey: .cards) ?? []
        let now = Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        sourceModelName = try container.decodeIfPresent(String.self, forKey: .sourceModelName)
        sourceDatasetID = try container.decodeIfPresent(String.self, forKey: .sourceDatasetID)
        sourceDatasetName = try container.decodeIfPresent(String.self, forKey: .sourceDatasetName)
    }
}
