import Foundation
import XCTest
@testable import Noema

final class FlashcardSchedulerTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func card(box: Int = 1, due: Date? = nil, created: Date? = nil) -> Flashcard {
        Flashcard(
            front: "f",
            back: "b",
            box: box,
            dueDate: due,
            createdAt: created ?? now,
            modifiedAt: created ?? now
        )
    }

    private func days(_ n: Int, from date: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: calendar.startOfDay(for: date))!
    }

    func testNewCardIsDue() {
        XCTAssertTrue(FlashcardLeitnerScheduler.isDue(card(due: nil), now: now, calendar: calendar))
    }

    func testFutureCardIsNotDue() {
        let future = card(box: 2, due: days(1, from: now))
        XCTAssertFalse(FlashcardLeitnerScheduler.isDue(future, now: now, calendar: calendar))
    }

    func testAgainResetsToBoxOneDueToday() {
        let graded = FlashcardLeitnerScheduler.applyGrade(.again, to: card(box: 4), now: now, calendar: calendar)
        XCTAssertEqual(graded.box, 1)
        XCTAssertEqual(graded.lapses, 1)
        XCTAssertEqual(graded.reviewCount, 1)
        XCTAssertEqual(graded.dueDate, days(0, from: now))
        XCTAssertTrue(FlashcardLeitnerScheduler.isDue(graded, now: now, calendar: calendar))
    }

    func testGoodAdvancesOneBox() {
        let graded = FlashcardLeitnerScheduler.applyGrade(.good, to: card(box: 2), now: now, calendar: calendar)
        XCTAssertEqual(graded.box, 3)
        XCTAssertEqual(graded.dueDate, days(3, from: now))
    }

    func testEasyAdvancesTwoBoxesAndCaps() {
        let graded = FlashcardLeitnerScheduler.applyGrade(.easy, to: card(box: 4), now: now, calendar: calendar)
        XCTAssertEqual(graded.box, 5)
        XCTAssertEqual(graded.dueDate, days(14, from: now))
    }

    func testQueueOrdersWeakestFirst() {
        var strong = card(box: 3, due: days(-1, from: now), created: now.addingTimeInterval(-100))
        strong.front = "strong"
        var weak = card(box: 1, due: days(-2, from: now), created: now)
        weak.front = "weak"
        var fresh = card(box: 1, due: nil, created: now.addingTimeInterval(-500))
        fresh.front = "fresh"
        let deck = FlashcardDeck(name: "d", topic: "t", cards: [strong, weak, fresh])

        let queue = FlashcardLeitnerScheduler.buildQueue(for: deck, now: now, calendar: calendar)
        XCTAssertFalse(queue.isReviewAhead)
        XCTAssertEqual(queue.cards.map(\.front), ["fresh", "weak", "strong"])
    }

    func testReviewAheadWhenNothingDue() {
        let a = card(box: 2, due: days(1, from: now))
        let b = card(box: 3, due: days(3, from: now))
        let deck = FlashcardDeck(name: "d", topic: "t", cards: [b, a])

        let queue = FlashcardLeitnerScheduler.buildQueue(for: deck, now: now, calendar: calendar)
        XCTAssertTrue(queue.isReviewAhead)
        XCTAssertEqual(queue.cards.count, 2)
        XCTAssertEqual(queue.cards.first?.dueDate, a.dueDate)
    }

    func testReviewAheadRespectsLimit() {
        let cards = (0..<30).map { card(box: 2, due: days(1 + $0 % 3, from: now)) }
        let deck = FlashcardDeck(name: "d", topic: "t", cards: cards)
        let queue = FlashcardLeitnerScheduler.buildQueue(for: deck, now: now, calendar: calendar, reviewAheadLimit: 20)
        XCTAssertEqual(queue.cards.count, 20)
    }

    func testEmptyDeckQueue() {
        let deck = FlashcardDeck(name: "d", topic: "t", cards: [])
        let queue = FlashcardLeitnerScheduler.buildQueue(for: deck, now: now, calendar: calendar)
        XCTAssertTrue(queue.cards.isEmpty)
        XCTAssertFalse(queue.isReviewAhead)
    }

    func testNormalizedClampsBoxAndForwardClockJump() {
        let skewed = card(box: 9, due: days(400, from: now))
        let fixed = FlashcardLeitnerScheduler.normalized(skewed, now: now, calendar: calendar)
        XCTAssertEqual(fixed.box, 5)
        XCTAssertEqual(fixed.dueDate, days(14, from: now))

        let negative = card(box: -2, due: days(-3, from: now))
        let fixedNegative = FlashcardLeitnerScheduler.normalized(negative, now: now, calendar: calendar)
        XCTAssertEqual(fixedNegative.box, 1)
        XCTAssertEqual(fixedNegative.dueDate, days(-3, from: now))
    }

    func testDueCountAndNextDue() {
        // Due dates must stay within each box's max interval or normalized()
        // clamps them (box 3 allows +3 days, box 4 allows +7).
        let dueCard = card(box: 1, due: days(-1, from: now))
        let futureNear = card(box: 3, due: days(2, from: now))
        let futureFar = card(box: 4, due: days(5, from: now))
        let deck = FlashcardDeck(name: "d", topic: "t", cards: [dueCard, futureNear, futureFar])
        XCTAssertEqual(FlashcardLeitnerScheduler.dueCount(in: deck, now: now, calendar: calendar), 1)
        XCTAssertEqual(FlashcardLeitnerScheduler.nextDueDate(in: deck, now: now, calendar: calendar), futureNear.dueDate)
    }
}

final class FlashcardResponseParserTests: XCTestCase {
    func testCleanEnvelope() {
        let raw = #"{"cards": [{"front": "Q1", "back": "A1"}, {"front": "Q2", "back": "A2", "hint": "h"}]}"#
        let cards = FlashcardResponseParser.parse(raw)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].front, "Q1")
        XCTAssertEqual(cards[1].hint, "h")
    }

    func testBareArray() {
        let raw = #"[{"front": "Q1", "back": "A1"}]"#
        XCTAssertEqual(FlashcardResponseParser.parse(raw).count, 1)
    }

    func testFencedJSON() {
        let raw = """
        ```json
        {"cards": [{"front": "Q1", "back": "A1"}]}
        ```
        """
        XCTAssertEqual(FlashcardResponseParser.parse(raw).count, 1)
    }

    func testProseWrappedJSON() {
        let raw = """
        Sure! Here are your flashcards:
        {"cards": [{"front": "Q1", "back": "A1"}, {"front": "Q2", "back": "A2"}]}
        Hope this helps!
        """
        XCTAssertEqual(FlashcardResponseParser.parse(raw).count, 2)
    }

    func testExplicitThinkBlockStripped() {
        let raw = """
        <think>I should write cards about {braces} here.</think>
        {"cards": [{"front": "Q1", "back": "A1"}]}
        """
        XCTAssertEqual(FlashcardResponseParser.parse(raw).count, 1)
    }

    func testImplicitOpenThinkStripped() {
        let raw = """
        The user wants cards. Let me plan: [{"front": "fake"}]
        </think>
        {"cards": [{"front": "Q1", "back": "A1"}]}
        """
        let cards = FlashcardResponseParser.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].front, "Q1")
    }

    func testUnclosedThinkYieldsNothing() {
        let raw = "<think>still reasoning about {\"cards\": [..."
        XCTAssertTrue(FlashcardResponseParser.parse(raw).isEmpty)
    }

    func testTruncatedArraySalvagesCompleteCards() {
        let raw = #"{"cards": [{"front": "Q1", "back": "A1"}, {"front": "Q2", "back": "A2"}, {"front": "Q3", "ba"#
        let cards = FlashcardResponseParser.parse(raw)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.last?.front, "Q2")
    }

    func testBareObjectStream() {
        let raw = """
        {"front": "Q1", "back": "A1"},
        {"front": "Q2", "back": "A2"}
        """
        XCTAssertEqual(FlashcardResponseParser.parse(raw).count, 2)
    }

    func testQuestionAnswerAliases() {
        let raw = #"{"cards": [{"question": "Q1", "answer": "A1"}]}"#
        let cards = FlashcardResponseParser.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].front, "Q1")
        XCTAssertEqual(cards[0].back, "A1")
    }

    func testDedupeByNormalizedFront() {
        let raw = #"{"cards": [{"front": "What is DNA?", "back": "A1"}, {"front": "what is dna", "back": "A2"}, {"front": "Other", "back": "A3"}]}"#
        XCTAssertEqual(FlashcardResponseParser.parse(raw).count, 2)
    }

    func testDropsEmptyAndClampsOversized() {
        let longFront = String(repeating: "x", count: 500)
        let raw = "{\"cards\": [{\"front\": \"  \", \"back\": \"A\"}, {\"front\": \"\(longFront)\", \"back\": \"A2\"}]}"
        let cards = FlashcardResponseParser.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertLessThanOrEqual(cards[0].front.count, FlashcardResponseParser.maxFrontLength)
    }

    func testGarbageYieldsEmpty() {
        XCTAssertTrue(FlashcardResponseParser.parse("no json here at all").isEmpty)
        XCTAssertTrue(FlashcardResponseParser.parse("").isEmpty)
    }

    func testBracesInsideStringsDoNotConfuseSalvage() {
        let raw = #"{"cards": [{"front": "What does { mean in JSON?", "back": "It opens an \"object\"."}]}"#
        let cards = FlashcardResponseParser.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].back.contains("object"))
    }

    func testStreamCounterCountsAcrossChunks() {
        var counter = FlashcardStreamCardCounter()
        let full = #"{"cards": [{"front": "Q1", "back": "A1"}, {"front": "Q2", "back": "A2"}]}"#
        for chunk in full.split(by: 7) {
            counter.feed(chunk)
        }
        counter.finalize()
        XCTAssertEqual(counter.cardsCompleted, 2)
    }

    func testStreamCounterIgnoresThinkPreamble() {
        var counter = FlashcardStreamCardCounter()
        counter.feed("<think>plan: [{\"front\": \"x\"}] </think>")
        counter.feed(#"{"cards": [{"front": "Q1", "back": "A1"}]}"#)
        counter.finalize()
        XCTAssertEqual(counter.cardsCompleted, 1)
    }

    func testStreamCounterResetsOnImplicitOpenClose() {
        var counter = FlashcardStreamCardCounter()
        counter.feed("[{\"front\": \"fake\", \"back\": \"fake\"}] </think> ")
        counter.feed(#"{"cards": [{"front": "Q1", "back": "A1"}, {"front": "Q2", "back": "A2"}]}"#)
        counter.finalize()
        XCTAssertEqual(counter.cardsCompleted, 2)
    }
}

private extension String {
    func split(by size: Int) -> [String] {
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<end]))
            index = end
        }
        return chunks
    }
}

@MainActor
final class FlashcardDeckStoreTests: XCTestCase {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashcardDeckStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRoundTrip() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FlashcardDeckStore(baseDirectory: dir)
        let deck = FlashcardDeck(
            name: "Biology",
            topic: "Cells",
            cards: [Flashcard(front: "Q", back: "A", hint: "h", origin: .generated)]
        )
        store.upsert(deck)

        let reloaded = FlashcardDeckStore(baseDirectory: dir)
        XCTAssertEqual(reloaded.decks.count, 1)
        XCTAssertEqual(reloaded.decks.first?.name, "Biology")
        XCTAssertEqual(reloaded.decks.first?.cards.first?.hint, "h")
        XCTAssertEqual(reloaded.decks.first?.cards.first?.origin, .generated)
    }

    func testCorruptFileIsQuarantinedNotOverwritten() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("FlashcardDecks.json")
        try Data("not json {{{".utf8).write(to: storeURL)

        let store = FlashcardDeckStore(baseDirectory: dir)
        XCTAssertTrue(store.decks.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(
            contents.contains { $0.hasPrefix("FlashcardDecks.json.corrupt-") },
            "expected the corrupt file to be renamed, found: \(contents)"
        )
    }

    func testUnsupportedSchemaVersionIsQuarantined() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("FlashcardDecks.json")
        let future = #"{"schema": "noema.flashcards.decks", "schemaVersion": 99, "decks": []}"#
        try Data(future.utf8).write(to: storeURL)

        let store = FlashcardDeckStore(baseDirectory: dir)
        XCTAssertTrue(store.decks.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(contents.contains { $0.hasPrefix("FlashcardDecks.json.corrupt-") })
    }

    func testApplyReviewDebouncesAndFlushPersists() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FlashcardDeckStore(baseDirectory: dir)
        let card = Flashcard(front: "Q", back: "A")
        let deck = FlashcardDeck(name: "d", topic: "t", cards: [card])
        store.upsert(deck)

        store.applyReview(deckID: deck.id, cardID: card.id, grade: .good)
        XCTAssertEqual(store.deck(id: deck.id)?.cards.first?.box, 2)

        // The graded state is debounced; before the flush a fresh reader
        // still sees the pre-review snapshot.
        let beforeFlush = FlashcardDeckStore(baseDirectory: dir)
        XCTAssertEqual(beforeFlush.deck(id: deck.id)?.cards.first?.box, 1)

        store.flushPendingSave()
        let afterFlush = FlashcardDeckStore(baseDirectory: dir)
        XCTAssertEqual(afterFlush.deck(id: deck.id)?.cards.first?.box, 2)
        XCTAssertEqual(afterFlush.deck(id: deck.id)?.cards.first?.reviewCount, 1)
    }

    func testLenientDecodingSuppliesDefaults() throws {
        let json = """
        {
            "schema": "noema.flashcards.decks",
            "schemaVersion": 1,
            "decks": [{
                "id": "\(UUID().uuidString)",
                "name": "Old",
                "topic": "t",
                "cards": [{
                    "id": "\(UUID().uuidString)",
                    "front": "Q",
                    "back": "A"
                }]
            }]
        }
        """
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(json.utf8).write(to: dir.appendingPathComponent("FlashcardDecks.json"))

        let store = FlashcardDeckStore(baseDirectory: dir)
        let card = store.decks.first?.cards.first
        XCTAssertEqual(card?.box, 1)
        XCTAssertNil(card?.dueDate)
        XCTAssertEqual(card?.reviewCount, 0)
        XCTAssertEqual(card?.origin, .manual)
    }
}
