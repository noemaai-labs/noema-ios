import XCTest
@testable import Noema

final class MathRichSegmenterTests: XCTestCase {
    // Helpers ---------------------------------------------------------------

    private func paragraphTokens(_ segment: MathRichSegment) -> [MathRichInlineToken]? {
        if case .paragraph(_, _, let tokens) = segment { return tokens }
        return nil
    }

    private func onlyText(_ tokens: [MathRichInlineToken]) -> String {
        tokens.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined()
    }

    // Tests -----------------------------------------------------------------

    func testPlainParagraphProducesSingleParagraph() {
        let segments = MathRichSegmenter.segments(from: "Hello world")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(paragraphTokens(segments[0]).map(onlyText), "Hello world")
    }

    func testDoubleNewlineSplitsParagraphs() {
        let segments = MathRichSegmenter.segments(from: "First\n\nSecond")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(paragraphTokens(segments[0]).map(onlyText), "First")
        XCTAssertEqual(paragraphTokens(segments[1]).map(onlyText), "Second")
    }

    func testSingleNewlineBecomesSpace() {
        let segments = MathRichSegmenter.segments(from: "First\nSecond")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(paragraphTokens(segments[0]).map(onlyText), "First Second")
    }

    func testBulletPrefixDetected() {
        let segments = MathRichSegmenter.segments(from: "• Item one")
        guard case .paragraph(let marker, let level, let tokens)? = segments.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(marker, "•")
        XCTAssertNil(level)
        XCTAssertEqual(onlyText(tokens), "Item one")
    }

    func testOrderedBulletPrefixDetected() {
        let segments = MathRichSegmenter.segments(from: "1. First step")
        guard case .paragraph(let marker, _, let tokens)? = segments.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(marker, "1.")
        XCTAssertEqual(onlyText(tokens), "First step")
    }

    func testHeadingPrefixDetected() {
        let segments = MathRichSegmenter.segments(from: "## Section Title")
        guard case .paragraph(let marker, let level, let tokens)? = segments.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertNil(marker)
        XCTAssertEqual(level, 2)
        XCTAssertEqual(onlyText(tokens), "Section Title")
    }

    func testDelimitedInlineMathCarriesDelimiterProvenance() {
        let segments = MathRichSegmenter.segments(from: "before \\(x^2\\) after")
        guard let tokens = paragraphTokens(segments[0]) else { return XCTFail("expected a paragraph") }
        let mathTokens = tokens.compactMap { token -> Bool? in
            if case .inlineMath(_, let hadDelimiters) = token { return hadDelimiters }
            return nil
        }
        XCTAssertEqual(mathTokens, [true], "delimited inline math should record hadDelimiters == true")
    }

    func testHeuristicInlineMathHasNoDelimiters() {
        let segments = MathRichSegmenter.segments(from: "value \\frac{1}{2} done")
        guard let tokens = paragraphTokens(segments[0]) else { return XCTFail("expected a paragraph") }
        let mathTokens = tokens.compactMap { token -> Bool? in
            if case .inlineMath(_, let hadDelimiters) = token { return hadDelimiters }
            return nil
        }
        XCTAssertEqual(mathTokens, [false], "heuristic inline math should record hadDelimiters == false")
    }

    func testBlockMathProducesBlockSegment() {
        let segments = MathRichSegmenter.segments(from: "$$x^2 + y^2$$")
        guard case .block(let latex)? = segments.first else {
            return XCTFail("expected a block segment")
        }
        XCTAssertTrue(latex.contains("x^2"))
    }

    func testUnclosedInlineMathProducesIncomplete() {
        let segments = MathRichSegmenter.segments(from: "tail \\(x")
        XCTAssertTrue(segments.contains { if case .incomplete = $0 { return true } else { return false } },
                      "unterminated inline math should produce an incomplete segment")
    }

    // Single-$ inline math + currency guard ---------------------------------

    private func inlineMaths(_ tokens: [MathRichInlineToken]) -> [String] {
        tokens.compactMap { if case .inlineMath(let latex, _) = $0 { return latex } else { return nil } }
    }

    private func firstParagraphTokens(_ source: String) -> [MathRichInlineToken] {
        let segments = MathRichSegmenter.segments(from: source)
        guard let first = segments.first, let tokens = paragraphTokens(first) else { return [] }
        return tokens
    }

    func testSingleDollarVariableRendersAsMath() {
        let tokens = firstParagraphTokens("The matrix $A$ is square.")
        XCTAssertEqual(inlineMaths(tokens), ["A"])
    }

    func testSingleDollarMacroRendersAsMath() {
        let tokens = firstParagraphTokens("scaling factor $\\lambda$ here")
        XCTAssertEqual(inlineMaths(tokens), ["\\lambda"])
    }

    func testSingleDollarBraceMacroRendersAsMath() {
        let tokens = firstParagraphTokens("vector $\\mathbf{v}$ stays")
        XCTAssertEqual(inlineMaths(tokens), ["\\mathbf{v}"])
    }

    func testSingleDollarOperatorExpressionRendersAsMath() {
        let tokens = firstParagraphTokens("we know $a + b$ holds")
        XCTAssertEqual(inlineMaths(tokens), ["a + b"])
    }

    func testCurrencyAmountsStayLiteral() {
        let source = "It raised $70 million in 2024 and spent $20."
        let tokens = firstParagraphTokens(source)
        XCTAssertTrue(inlineMaths(tokens).isEmpty, "currency amounts must not parse as math")
        XCTAssertEqual(onlyText(tokens), source)
    }

    func testTwoCurrencyAmountsDoNotFormSpan() {
        // The reported bug: "$70 million ... $20" wrapped everything between the
        // two dollar signs in LaTeX.
        let source = "revenue of $70 million versus $20"
        let tokens = firstParagraphTokens(source)
        XCTAssertTrue(inlineMaths(tokens).isEmpty)
        XCTAssertEqual(onlyText(tokens), source)
    }

    func testMixedMathAndCurrencyOnSameLine() {
        let tokens = firstParagraphTokens("variable $x$ but it costs $20")
        XCTAssertEqual(inlineMaths(tokens), ["x"])
        XCTAssertTrue(onlyText(tokens).contains("$20"), "trailing amount must remain literal")
    }

    func testPlainWordsBetweenDollarsStayLiteral() {
        let tokens = firstParagraphTokens("pay $the full amount$ now")
        XCTAssertTrue(inlineMaths(tokens).isEmpty)
    }

    func testEscapedDollarsStayLiteral() {
        let tokens = firstParagraphTokens("price \\$5 and \\$10 today")
        XCTAssertTrue(inlineMaths(tokens).isEmpty)
    }

    func testDollarSpanIsMathClassification() {
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("A"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("\\lambda"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("x^2"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("a + b"))
        XCTAssertFalse(MathTokenizer.dollarSpanIsMath("20"))
        XCTAssertFalse(MathTokenizer.dollarSpanIsMath("70 million"))
        XCTAssertFalse(MathTokenizer.dollarSpanIsMath("the value"))
        XCTAssertFalse(MathTokenizer.dollarSpanIsMath(""))
    }
}

final class LatexCopyTransformTests: XCTestCase {
    private func attachmentString(latexSource: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let str = NSMutableAttributedString(attachment: attachment)
        str.addAttribute(.noemaLatexSource, value: latexSource,
                         range: NSRange(location: 0, length: str.length))
        return str
    }

    func testAttachmentReplacedWithLatexSource() {
        let result = NSMutableAttributedString(string: "a")
        result.append(attachmentString(latexSource: "\\(x\\)"))
        result.append(NSAttributedString(string: "b"))

        XCTAssertEqual(LatexCopyTransform.plainText(from: result), "a\\(x\\)b")
    }

    func testPlainTextPassthroughWithoutAttachments() {
        let result = NSAttributedString(string: "just text")
        XCTAssertEqual(LatexCopyTransform.plainText(from: result), "just text")
    }

    func testMultipleAttachments() {
        let result = NSMutableAttributedString(string: "x=")
        result.append(attachmentString(latexSource: "\\(a\\)"))
        result.append(NSAttributedString(string: " and "))
        result.append(attachmentString(latexSource: "$$\nb\n$$"))

        XCTAssertEqual(LatexCopyTransform.plainText(from: result), "x=\\(a\\) and $$\nb\n$$")
    }

    func testDiscontiguousRangesJoinedWithNewline() {
        // "a" + attachment("\(x\)") + "b"  → indices 0,1,2
        let result = NSMutableAttributedString(string: "a")
        result.append(attachmentString(latexSource: "\\(x\\)"))
        result.append(NSAttributedString(string: "b"))

        let ranges = [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)]
        XCTAssertEqual(LatexCopyTransform.plainText(from: result, ranges: ranges), "a\nb")
    }

    func testSelectingAttachmentRangeYieldsLatex() {
        let result = NSMutableAttributedString(string: "a")
        result.append(attachmentString(latexSource: "\\(x\\)"))
        result.append(NSAttributedString(string: "b"))

        let ranges = [NSRange(location: 1, length: 1)]
        XCTAssertEqual(LatexCopyTransform.plainText(from: result, ranges: ranges), "\\(x\\)")
    }

    func testRangeClampedToBounds() {
        let result = NSAttributedString(string: "abc")
        let ranges = [NSRange(location: 1, length: 99)]
        XCTAssertEqual(LatexCopyTransform.plainText(from: result, ranges: ranges), "bc")
    }
}
