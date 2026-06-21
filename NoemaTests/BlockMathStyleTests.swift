import XCTest
@testable import Noema

final class BlockMathStyleTests: XCTestCase {
    func testChatStyleUsesLargerFontAndScrollingBehavior() {
        let bodyFontSize = preferredFontSize(.body)
        let style = BlockMathStyle.chat(bodyFontSize: bodyFontSize)

        XCTAssertGreaterThan(style.fontSize, bodyFontSize)
        XCTAssertEqual(style.widthBehavior, .wrapThenScroll)
        XCTAssertFalse(style.useCache)
    }

    func testStandardStyleUsesIntrinsicCachedBehavior() {
        let style = BlockMathStyle.standard(bodyFontSize: preferredFontSize(.body))

        XCTAssertEqual(style.widthBehavior, .intrinsic)
        XCTAssertTrue(style.useCache)
        XCTAssertGreaterThan(style.fontSize, 0)
    }
}

final class ChatMarkdownRenderPlannerTests: XCTestCase {
    func testMacOSPlannerFoldsHeadingIntoSelectableBlock() {
        // Headings now fold into the same textMathBlock as the surrounding prose
        // (emitted as "#"-prefixed paragraphs) so a single NSTextView can be
        // drag-selected across the heading and body together.
        let entries: [ChatMarkdownPlannerEntry] = [
            .heading(level: 1, content: "Title"),
            .text("Body text")
        ]

        let units = ChatMarkdownRenderPlanner.renderUnits(for: entries, isMacOS: true)

        XCTAssertEqual(units, [
            .textMathBlock("# Title\n\nBody text")
        ])
    }

    func testMacOSPlannerFoldsMultipleHeadingsIntoOneBlock() {
        let entries: [ChatMarkdownPlannerEntry] = [
            .heading(level: 1, content: "H1"),
            .heading(level: 2, content: "H2"),
            .heading(level: 3, content: "H3"),
            .text("Paragraph")
        ]

        let units = ChatMarkdownRenderPlanner.renderUnits(for: entries, isMacOS: true)

        XCTAssertEqual(units, [
            .textMathBlock("# H1\n\n## H2\n\n### H3\n\nParagraph")
        ])
    }

    func testMacOSPlannerPreservesExistingParagraphAndBulletGrouping() {
        let entries: [ChatMarkdownPlannerEntry] = [
            .text("Intro"),
            .bullet(marker: "•", content: "one"),
            .bullet(marker: "•", content: "two"),
            .text("Outro")
        ]

        let units = ChatMarkdownRenderPlanner.renderUnits(for: entries, isMacOS: true)

        XCTAssertEqual(units, [
            .textMathBlock("Intro\n• one\n• two\nOutro")
        ])
    }

    func testMacOSPlannerKeepsTablesAsSeparateBoundaries() {
        let entries: [ChatMarkdownPlannerEntry] = [
            .heading(level: 2, content: "Section"),
            .text("Intro"),
            .table,
            .text("Outro")
        ]

        let units = ChatMarkdownRenderPlanner.renderUnits(for: entries, isMacOS: true)

        XCTAssertEqual(units, [
            .textMathBlock("## Section\n\nIntro"),
            .entryIndex(2),
            .textMathBlock("Outro")
        ])
    }

    func testMacOSPlannerKeepsThematicBreakAsStandaloneBoundary() {
        let entries: [ChatMarkdownPlannerEntry] = [
            .text("Before"),
            .thematicBreak,
            .text("After")
        ]

        let units = ChatMarkdownRenderPlanner.renderUnits(for: entries, isMacOS: true)

        XCTAssertEqual(units, [
            .textMathBlock("Before"),
            .entryIndex(1),
            .textMathBlock("After")
        ])
    }
}
