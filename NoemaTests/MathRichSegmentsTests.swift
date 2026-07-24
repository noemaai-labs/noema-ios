import XCTest
@testable import Noema

final class MathRichSegmenterTests: XCTestCase {
    // MARK: - Helpers

    private func paragraphTokens(_ segment: MathRichSegment) -> [MathRichInlineToken]? {
        if case .paragraph(_, _, let tokens) = segment { return tokens }
        return nil
    }

    private func onlyText(_ tokens: [MathRichInlineToken]) -> String {
        tokens.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined()
    }

    // MARK: - Tests

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

    func testHeadingAfterLeadingNewlineStillDetected() {
        // A grouped source can begin "\n### Heading"; the single newline
        // collapses to a space, which must not defeat heading detection.
        let segments = MathRichSegmenter.segments(from: "\n### 1. Equations of motion\n\nBody")
        guard case .paragraph(_, let level, let tokens)? = segments.first else {
            return XCTFail("expected a paragraph segment")
        }
        XCTAssertEqual(level, 3)
        XCTAssertEqual(tokens, [.text("1. Equations of motion")])
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

    // MARK: - Inline math and currency

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

    func testExplicitNumericDollarSpansRenderAsMath() {
        let tokens = firstParagraphTokens("eigenvalues $3, -2, 5$, then $4$ and $-3$")
        XCTAssertEqual(inlineMaths(tokens), ["3, -2, 5", "4", "-3"])
        XCTAssertFalse(onlyText(tokens).contains("$"))
    }

    func testSingleDollarVariableListRendersAsMath() {
        let tokens = firstParagraphTokens("for all vectors $u, v$ in V and scalars $r, s$")
        XCTAssertEqual(inlineMaths(tokens), ["u, v", "r, s"])
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

    func testCommaSeparatedProseBetweenDollarsStaysLiteral() {
        let tokens = firstParagraphTokens("say $hello, world$ out loud")
        XCTAssertTrue(inlineMaths(tokens).isEmpty)
    }

    func testEscapedDollarsStayLiteral() {
        let tokens = firstParagraphTokens("price \\$5 and \\$10 today")
        XCTAssertTrue(inlineMaths(tokens).isEmpty)
    }

    // MARK: - Boxed expressions

    func testBareBoxedInProseRendersAsInlineMath() {
        let tokens = firstParagraphTokens("Final answer: \\boxed{\\sqrt{6gR}} m/s.")
        XCTAssertEqual(inlineMaths(tokens), ["\\boxed{\\sqrt{6gR}}"])
        XCTAssertEqual(onlyText(tokens), "Final answer:  m/s.")
    }

    func testBareBoxedHasNoDelimiterProvenance() {
        let tokens = firstParagraphTokens("x = \\boxed{42}")
        let provenance = tokens.compactMap { token -> Bool? in
            if case .inlineMath(_, let hadDelimiters) = token { return hadDelimiters }
            return nil
        }
        XCTAssertEqual(provenance, [false])
    }

    func testBareFboxNormalizesToBoxed() {
        let tokens = firstParagraphTokens("result \\fbox{x+1} here")
        XCTAssertEqual(inlineMaths(tokens), ["\\boxed{x+1}"])
    }

    func testDelimitedBlockBoxedKeepsOuterBox() {
        let segments = MathRichSegmenter.segments(from: "$$\\boxed{x^2}$$")
        guard case .block(let latex)? = segments.first else {
            return XCTFail("expected a block segment")
        }
        XCTAssertEqual(latex, "\\boxed{x^2}")
    }

    func testDelimitedInlineBoxedKeepsOuterBox() {
        let tokens = firstParagraphTokens("answer \\(\\boxed{42}\\) done")
        XCTAssertEqual(inlineMaths(tokens), ["\\boxed{42}"])
    }

    func testSingleDollarBoxedKeepsOuterBox() {
        let tokens = firstParagraphTokens("answer $\\boxed{42}$ done")
        XCTAssertEqual(inlineMaths(tokens), ["\\boxed{42}"])
    }

    func testInteriorBoxIsStrippedInsideExpression() {
        let segments = MathRichSegmenter.segments(from: "$$x = \\boxed{5}$$")
        guard case .block(let latex)? = segments.first else {
            return XCTFail("expected a block segment")
        }
        XCTAssertEqual(latex, "x = 5")
    }

    func testUnclosedBareBoxedStaysLiteral() {
        let source = "Final \\boxed{\\sqrt{6gR"
        let tokens = firstParagraphTokens(source)
        XCTAssertTrue(inlineMaths(tokens).isEmpty)
        XCTAssertEqual(onlyText(tokens), source)
    }

    func testBoxedWithoutBracesStaysLiteral() {
        let tokens = firstParagraphTokens("the \\boxed macro takes one argument")
        XCTAssertTrue(inlineMaths(tokens).isEmpty)
    }

    func testUnwrapBoxed() {
        let simple = MathTokenizer.unwrapBoxed("\\boxed{\\sqrt{6gR}}")
        XCTAssertEqual(simple.latex, "\\sqrt{6gR}")
        XCTAssertTrue(simple.boxed)

        let nested = MathTokenizer.unwrapBoxed("\\boxed{\\fbox{y}}")
        XCTAssertEqual(nested.latex, "y")
        XCTAssertTrue(nested.boxed)

        let plain = MathTokenizer.unwrapBoxed("x^2")
        XCTAssertEqual(plain.latex, "x^2")
        XCTAssertFalse(plain.boxed)

        let partial = MathTokenizer.unwrapBoxed("\\boxed{a} + b")
        XCTAssertEqual(partial.latex, "\\boxed{a} + b")
        XCTAssertFalse(partial.boxed)
    }

    func testUnwrapBoxedToleratesTrailingPunctuation() {
        let result = MathTokenizer.unwrapBoxed("\\boxed{u_{\\min} = \\sqrt{5gR}}.")
        XCTAssertEqual(result.latex, "u_{\\min} = \\sqrt{5gR}.")
        XCTAssertTrue(result.boxed)
    }

    func testDelimitedBlockBoxedWithTrailingPeriodKeepsBox() {
        let segments = MathRichSegmenter.segments(from: "$$\\boxed{x^2}.$$")
        guard case .block(let latex)? = segments.first else {
            return XCTFail("expected a block segment")
        }
        XCTAssertEqual(latex, "\\boxed{x^2.}")
    }

    // MARK: - Unsupported command sanitization

    func testTagInBlockMathBecomesVisibleNumber() {
        let segments = MathRichSegmenter.segments(from: "$$x = y \\tag{1}$$")
        guard case .block(let latex)? = segments.first else {
            return XCTFail("expected a block segment")
        }
        XCTAssertEqual(latex, "x = y \\qquad (\\text{1})")
    }

    func testCommonDotsAliasNormalizesToSupportedCommand() {
        let tokens = firstParagraphTokens(
            "• **Formula**: $\\lambda_1 + \\lambda_2 + \\dots + \\lambda_n = \\text{tr}(A)$"
        )
        XCTAssertEqual(
            inlineMaths(tokens),
            ["\\lambda_1 + \\lambda_2 + \\ldots + \\lambda_n = \\text{tr}(A)"]
        )
    }

    func testDotsRewriteDoesNotChangeLongerCommandNames() {
        XCTAssertEqual(
            MathTokenizer.sanitizeUnsupportedCommands("\\dots + \\dotsb"),
            "\\ldots + \\dotsb"
        )
    }

    func testDisplayBlockWithTagStripsTag() {
        let source = "\\[\nN = \\frac{mM}{M+m\\sin^2\\theta}\\,\\bigl(g\\cos\\theta + R\\dot{\\theta}^2\\bigr). \\tag{2}\n\\]"
        let segments = MathRichSegmenter.segments(from: source)
        guard case .block(let latex)? = segments.first else {
            return XCTFail("expected a block segment")
        }
        XCTAssertFalse(latex.contains("\\tag"))
        XCTAssertTrue(latex.hasSuffix("\\qquad (\\text{2})"))
    }

    func testStarredTagRewritten() {
        XCTAssertEqual(MathTokenizer.sanitizeUnsupportedCommands("x \\tag*{2b}"),
                       "x \\qquad (\\text{2b})")
    }

    func testLabelNotagNonumberRemoved() {
        XCTAssertEqual(MathTokenizer.sanitizeUnsupportedCommands("x \\label{eq:main} = y \\notag"),
                       "x  = y ")
        XCTAssertEqual(MathTokenizer.sanitizeUnsupportedCommands("x \\nonumber"), "x ")
    }

    func testMalformedOrLookalikeTagsLeftAlone() {
        XCTAssertEqual(MathTokenizer.sanitizeUnsupportedCommands("x \\tag y"), "x \\tag y")
        XCTAssertEqual(MathTokenizer.sanitizeUnsupportedCommands("\\tagged{q}"), "\\tagged{q}")
        XCTAssertEqual(MathTokenizer.sanitizeUnsupportedCommands("\\labelled{q}"), "\\labelled{q}")
    }

    func testDollarSpanIsMathClassification() {
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("A"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("\\lambda"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("x^2"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("a + b"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("u, v"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("α, β"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("20"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("-3"))
        XCTAssertTrue(MathTokenizer.dollarSpanIsMath("3, -2, 5"))
        XCTAssertFalse(MathTokenizer.dollarSpanIsMath("70 million"))
        XCTAssertFalse(MathTokenizer.dollarSpanIsMath("the value"))
        XCTAssertFalse(MathTokenizer.dollarSpanIsMath("hello, world"))
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

@MainActor
final class MathBaselineTests: XCTestCase {
    func testInlineBaselineTracksDescent() {
        let fontSize: CGFloat = 16
        let insets = MathRenderTuning.inlineInsets(for: fontSize)
        guard let plain = renderMathImage(latex: "m", fontSize: fontSize,
                                          isDisplayMode: false, color: .label, insets: insets),
              let subscripted = renderMathImage(latex: "y_{b}", fontSize: fontSize,
                                                isDisplayMode: false, color: .label, insets: insets) else {
            return XCTFail("expected both spans to render")
        }
        // A deeper descent puts the baseline further above the image bottom.
        XCTAssertGreaterThan(subscripted.baselineFromBottom, plain.baselineFromBottom)
        // A descender-free letter's baseline hugs the bottom inset (modulo the
        // tiny-span vertical-centering adjustment).
        XCTAssertEqual(plain.baselineFromBottom, insets.bottom, accuracy: fontSize * 0.15)
    }

    func testLongDisplayMathStaysOnOneTypesetLine() {
        let fontSize: CGFloat = 20
        let insets = MathRenderTuning.blockInsets(for: fontSize)
        let samples = [
            #"\tfrac{1}{2}mv_b^2 + \tfrac{1}{2}MV^2 = \tfrac{1}{2}mv_{\mathrm{top}}^2 + mgR + \tfrac{1}{2}MV_{\mathrm{top}}^2"#,
            #"v^2 = u^2 - 2gR(1-\cos\theta) + gR(1-\cos\theta) = u^2 - 2gR(1-\cos\theta)"#
        ]

        for latex in samples {
            guard let rendered = renderMathImage(latex: latex, fontSize: fontSize,
                                                  isDisplayMode: true, color: .label,
                                                  insets: insets) else {
                return XCTFail("expected sample equation to render")
            }

            // A single display row containing fractions is comfortably under
            // three font-heights including Noema's safety insets. The former
            // label-snapshot path wrapped the tail and returned a much taller,
            // visibly cropped bitmap.
            XCTAssertLessThan(rendered.image.size.height, fontSize * 3,
                              "display equation unexpectedly reflowed: \(latex)")
            XCTAssertGreaterThan(rendered.image.size.width, rendered.image.size.height * 4,
                                 "long display equation should remain a wide single row")
        }
    }
}
