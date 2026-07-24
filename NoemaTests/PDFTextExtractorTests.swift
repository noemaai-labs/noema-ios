import XCTest
@testable import Noema

#if canImport(PDFKit)
import CoreGraphics

final class PDFTextExtractorTests: XCTestCase {
    private final class PageProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedValues: [(Int, Int)] = []

        func record(completed: Int, total: Int) {
            lock.lock()
            recordedValues.append((completed, total))
            lock.unlock()
        }

        var values: [(Int, Int)] {
            lock.lock()
            defer { lock.unlock() }
            return recordedValues
        }
    }

    func testCollapsedPDFKitTextTriggersLayoutRepair() {
        let text = """
        Subsetdrift. Thefrozen120/100-itemsubsetstrackedreservedfullsetswithin∼2 pointsacrosstheproject,withexactly
        itemsflip). Cross-vendordriftisreal;wereportnumbersonlyfromparity-passingsilicon,andthefailedparityJSON
        """

        XCTAssertTrue(PDFTextExtractor.needsLayoutRepair(text))
    }

    func testNormalProseDoesNotTriggerLayoutRepair() {
        let text = """
        Subset drift. The frozen 120/100-item subsets tracked reserved full sets within two points across the project.
        Cross-vendor drift is real; we report numbers only from parity-passing silicon.
        """

        XCTAssertFalse(PDFTextExtractor.needsLayoutRepair(text))
    }

    func testRepairTransfersWhitespaceButPreservesNativeCharacters() {
        let native = "Subsetdrift. Thefrozen120/100-itemsubsetstrackedreservedfullsetswithin∼2 pointsacrosstheproject,withexactly"
        let oracle = "Subset drift. The frozen 120/100-item subsets tracked reserved full sets within ~2 points across the project, with exactly"

        let repaired = PDFTextExtractor.repairWhitespace(in: native, using: [oracle])

        XCTAssertEqual(
            repaired,
            "Subset drift. The frozen 120/100-item subsets tracked reserved full sets within ∼2 points across the project, with exactly"
        )
        XCTAssertTrue(repaired.contains("∼2"), "The native math symbol must survive OCR-assisted repair")
    }

    func testRepairDoesNotAdoptOCRCharacterSubstitutions() {
        let native = "NOEMA-2B-v2leadsatbothbudgets."
        let oracle = "NoFMA-2B-v2 leads at both budgets."

        let repaired = PDFTextExtractor.repairWhitespace(in: native, using: [oracle])

        XCTAssertEqual(repaired, "NOEMA-2B-v2 leads at both budgets.")
        XCTAssertFalse(repaired.contains("NoFMA"))
    }

    func testRepairPreservesExistingWhitespaceExactly() {
        let native = "  Existing\tspacing stays.  Missinggap fixed.  "
        let oracle = "Existing spacing stays. Missing gap fixed."

        XCTAssertEqual(
            PDFTextExtractor.repairWhitespace(in: native, using: [oracle]),
            "  Existing\tspacing stays.  Missing gap fixed.  "
        )
    }

    func testPlainTextSearchFallsBackToCollapsedWhitespace() {
        XCTAssertTrue(
            PDFTextExtractor.containsPlainText(
                "Subset drift",
                in: "Subsetdrift. Thefrozen120-itemsubsets.",
                ignoreCase: true
            )
        )
        XCTAssertFalse(
            PDFTextExtractor.containsPlainText(
                "reserved headline",
                in: "Subsetdrift. Thefrozen120-itemsubsets.",
                ignoreCase: true
            )
        )
    }

    func testDocumentExtractionReportsEveryCompletedPage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-progress-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()

        let recorder = PageProgressRecorder()
        _ = try PDFTextExtractor.documentText(
            from: url,
            ocrEmptyPages: false,
            onPageProgress: { completed, total in
                recorder.record(completed: completed, total: total)
            }
        )

        XCTAssertEqual(recorder.values.map(\.0), [1, 2, 3])
        XCTAssertEqual(recorder.values.map(\.1), [3, 3, 3])
    }
}
#endif
