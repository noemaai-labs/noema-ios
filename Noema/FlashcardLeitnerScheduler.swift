import Foundation

struct FlashcardReviewQueue: Equatable {
    let cards: [Flashcard]
    /// True when nothing was due and the queue surfaces not-yet-due cards
    /// instead ("Review All"). Grades during review-ahead apply normally.
    let isReviewAhead: Bool
}

enum FlashcardLeitnerScheduler {
    static let boxCount = 5
    /// Days until next review, indexed by box - 1.
    static let intervalDaysByBox = [0, 1, 3, 7, 14]

    static func interval(forBox box: Int) -> Int {
        intervalDaysByBox[max(1, min(box, boxCount)) - 1]
    }

    static func isDue(_ card: Flashcard, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = card.dueDate else { return true }
        return calendar.startOfDay(for: due) <= calendar.startOfDay(for: now)
    }

    static func dueCount(in deck: FlashcardDeck, now: Date = Date(), calendar: Calendar = .current) -> Int {
        deck.cards.reduce(0) { count, card in
            count + (isDue(normalized(card, now: now, calendar: calendar), now: now, calendar: calendar) ? 1 : 0)
        }
    }

    static func nextDueDate(in deck: FlashcardDeck, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        deck.cards
            .map { normalized($0, now: now, calendar: calendar) }
            .compactMap(\.dueDate)
            .filter { calendar.startOfDay(for: $0) > calendar.startOfDay(for: now) }
            .min()
    }

    static func applyGrade(
        _ grade: FlashcardGrade,
        to card: Flashcard,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Flashcard {
        var updated = card
        switch grade {
        case .again:
            updated.box = 1
            updated.lapses += 1
        case .good:
            updated.box = min(card.box + 1, boxCount)
        case .easy:
            updated.box = min(card.box + 2, boxCount)
        }
        let today = calendar.startOfDay(for: now)
        updated.dueDate = calendar.date(byAdding: .day, value: interval(forBox: updated.box), to: today) ?? today
        updated.lastReviewedAt = now
        updated.reviewCount += 1
        updated.modifiedAt = now
        return updated
    }

    /// Clamps state that clock jumps or corrupted files could have skewed: box
    /// stays in range, and a card is never scheduled further out than its box's
    /// interval allows (so a forward clock jump at grade time can't strand it).
    static func normalized(_ card: Flashcard, now: Date = Date(), calendar: Calendar = .current) -> Flashcard {
        var fixed = card
        fixed.box = max(1, min(card.box, boxCount))
        if let due = card.dueDate {
            let today = calendar.startOfDay(for: now)
            let maxDue = calendar.date(byAdding: .day, value: interval(forBox: fixed.box), to: today) ?? today
            if calendar.startOfDay(for: due) > maxDue {
                fixed.dueDate = maxDue
            }
        }
        return fixed
    }

    static func buildQueue(
        for deck: FlashcardDeck,
        now: Date = Date(),
        calendar: Calendar = .current,
        reviewAheadLimit: Int = 20
    ) -> FlashcardReviewQueue {
        let cards = deck.cards.map { normalized($0, now: now, calendar: calendar) }
        guard !cards.isEmpty else { return FlashcardReviewQueue(cards: [], isReviewAhead: false) }

        let due = cards.filter { isDue($0, now: now, calendar: calendar) }
        if !due.isEmpty {
            let ordered = due.sorted { a, b in
                if a.box != b.box { return a.box < b.box }
                let aDue = a.dueDate ?? .distantPast
                let bDue = b.dueDate ?? .distantPast
                if aDue != bDue { return aDue < bDue }
                return a.createdAt < b.createdAt
            }
            return FlashcardReviewQueue(cards: ordered, isReviewAhead: false)
        }

        let ahead = cards
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
            .prefix(reviewAheadLimit)
        return FlashcardReviewQueue(cards: Array(ahead), isReviewAhead: true)
    }
}
