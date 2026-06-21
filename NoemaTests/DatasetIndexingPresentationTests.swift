import XCTest
@testable import Noema

final class DatasetIndexingPresentationTests: XCTestCase {
    private let englishLocale = Locale(identifier: "en")

    func testStageTitlesAreLocalizedForEnglish() {
        XCTAssertEqual(DatasetIndexingPresentation.title(for: .extracting, locale: englishLocale), "Extracting")
        XCTAssertEqual(DatasetIndexingPresentation.title(for: .compressing, locale: englishLocale), "Compressing")
        XCTAssertEqual(DatasetIndexingPresentation.title(for: .embedding, locale: englishLocale), "Embedding")
        XCTAssertEqual(DatasetIndexingPresentation.title(for: .completed, locale: englishLocale), "Ready")
        XCTAssertEqual(DatasetIndexingPresentation.title(for: .failed, locale: englishLocale), "Failed")
    }

    func testCompletedPresentationUsesSuccessToneAndNoActions() {
        let presentation = DatasetIndexingPresentation.make(
            for: DatasetProcessingStatus(stage: .completed, progress: 1.0, message: "Ready for use", etaSeconds: 0),
            locale: englishLocale
        )

        XCTAssertEqual(presentation.tone, .success)
        XCTAssertEqual(presentation.actionState, .none)
        XCTAssertFalse(presentation.showsProgressBar)
        XCTAssertEqual(presentation.progressText, "Ready")
    }

    func testFailedPresentationUsesFailureToneAndNoActions() {
        let presentation = DatasetIndexingPresentation.make(
            for: DatasetProcessingStatus(stage: .failed, progress: 0.0, message: "Stopped", etaSeconds: nil),
            locale: englishLocale
        )

        XCTAssertEqual(presentation.tone, .failure)
        XCTAssertEqual(presentation.actionState, .none)
        XCTAssertEqual(presentation.progressText, "Error")
    }

    func testActionAvailabilityDependsOnEmbeddingState() {
        let paused = DatasetIndexingPresentation.make(
            for: DatasetProcessingStatus(stage: .embedding, progress: 0.0, message: "Waiting", etaSeconds: nil),
            locale: englishLocale
        )
        let running = DatasetIndexingPresentation.make(
            for: DatasetProcessingStatus(stage: .embedding, progress: 0.4, message: "Embedding", etaSeconds: 90),
            locale: englishLocale
        )

        XCTAssertEqual(paused.actionState, .startAndCancel)
        XCTAssertEqual(running.actionState, .cancelOnly)
    }

    func testProgressFormattingWithAndWithoutEta() {
        let withETA = DatasetIndexingPresentation.progressText(
            for: DatasetProcessingStatus(stage: .compressing, progress: 0.42, etaSeconds: 125),
            locale: englishLocale
        )
        let withoutETA = DatasetIndexingPresentation.progressText(
            for: DatasetProcessingStatus(stage: .compressing, progress: 0.42, etaSeconds: nil),
            locale: englishLocale
        )

        XCTAssertEqual(withETA, "42% · ~2m 05s")
        XCTAssertEqual(withoutETA, "42% · …")
    }

    func testEnglishLocalizationKeysResolve() {
        XCTAssertEqual(String(localized: "Dismiss", locale: englishLocale), "Dismiss")
        XCTAssertEqual(String(localized: "Checking embedding model…", locale: englishLocale), "Checking embedding model…")
        XCTAssertEqual(String(localized: "Ready for use", locale: englishLocale), "Ready for use")
    }

    func testEnglishFirstEmbedWarmupLocalizationKeysResolve() {
        XCTAssertEqual(String(localized: "Preparing Embedding Model", locale: englishLocale), "Preparing Embedding Model")
        XCTAssertEqual(String(localized: "First-time download from HuggingFace", locale: englishLocale), "First-time download from HuggingFace")
        XCTAssertEqual(String(localized: "Downloading embedding model…", locale: englishLocale), "Downloading embedding model…")
        XCTAssertEqual(String(localized: "Warming up embedding model…", locale: englishLocale), "Warming up embedding model…")
        XCTAssertEqual(String(localized: "Priming first embedding pass…", locale: englishLocale), "Priming first embedding pass…")
        XCTAssertEqual(
            String.localizedStringWithFormat(
                String(localized: "Embedding chunk %d of %d…", locale: englishLocale),
                2,
                8
            ),
            "Embedding chunk 2 of 8…"
        )
        XCTAssertEqual(
            String(
                localized: "Ready to compute embeddings. Tap Confirm to start. For best performance, plug in your device.",
                locale: englishLocale
            ),
            "Ready to compute embeddings. Tap Confirm to start. For best performance, plug in your device."
        )
    }
}
