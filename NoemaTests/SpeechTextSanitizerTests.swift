import XCTest
@testable import Noema

final class SpeechTextSanitizerTests: XCTestCase {
    private let reps = SpeechTextSanitizer.Replacements(
        codeOmitted: "Code omitted.",
        formulaOmitted: "Formula omitted.",
        tableOmitted: "Table omitted."
    )

    private func sanitize(_ text: String) -> String {
        SpeechTextSanitizer.sanitize(text, replacements: reps)
    }

    // MARK: Sanitizer

    func testStripsCompleteThinkBlock() {
        XCTAssertEqual(sanitize("<think>secret reasoning</think>The answer is 42."), "The answer is 42.")
    }

    func testDropsUnterminatedThinkBlock() {
        XCTAssertEqual(sanitize("Intro. <think>still reasoning about"), "Intro.")
    }

    func testDropsPreambleBeforeBareCloseTag() {
        XCTAssertEqual(sanitize("implicit reasoning stream</think>Visible answer."), "Visible answer.")
    }

    func testReplacesFencedCode() {
        let text = "Here is code:\n```swift\nlet x = 1\nprint(x)\n```\nDone."
        XCTAssertEqual(sanitize(text), "Here is code:\nCode omitted.\nDone.")
    }

    func testUnterminatedFenceHidesStreamingCode() {
        let text = "Look:\n```python\nimport os\nos.remove("
        XCTAssertEqual(sanitize(text), "Look:\nCode omitted.")
    }

    func testReplacesDisplayMath() {
        XCTAssertEqual(sanitize("Result: $$e = mc^2$$ as shown."), "Result: Formula omitted. as shown.")
        XCTAssertEqual(sanitize("Result: \\[x^2\\] here."), "Result: Formula omitted. here.")
    }

    func testInlineMathKeepsSimpleContentReplacesCommands() {
        XCTAssertEqual(sanitize("Let \\(x\\) be small."), "Let x be small.")
        XCTAssertEqual(sanitize("So \\(\\frac{a}{b}\\) wins."), "So Formula omitted. wins.")
    }

    func testReplacesTableWithSinglePlaceholder() {
        let text = "Data:\n| a | b |\n|---|---|\n| 1 | 2 |\nEnd."
        XCTAssertEqual(sanitize(text), "Data:\nTable omitted.\nEnd.")
    }

    func testStripsInlineMarkdown() {
        XCTAssertEqual(sanitize("# Title\nThis is **bold** and *italic* and `code`."),
                       "Title\nThis is bold and italic and code.")
        XCTAssertEqual(sanitize("See [the docs](https://example.com) now."), "See the docs now.")
        XCTAssertEqual(sanitize("- First item\n- Second item"), "First item\nSecond item")
        XCTAssertEqual(sanitize("1. Apples\n2. Pears"), "Apples\nPears")
        XCTAssertEqual(sanitize("> quoted wisdom"), "quoted wisdom")
        XCTAssertEqual(sanitize("Before\n---\nAfter"), "Before\nAfter")
    }

    func testStripsToolAnchorToken() {
        XCTAssertEqual(sanitize("Before\(noemaToolAnchorToken) after."), "Before after.")
    }

    // MARK: Chunker

    func testDecimalPointIsNotABoundary() {
        let (sentences, _) = SpeechSentenceChunker.stableSentences(in: "It costs $5.99 today. Next up", isFinal: false)
        XCTAssertEqual(sentences, ["It costs $5.99 today."])
    }

    func testBoundaryNeedsLookahead() {
        var result = SpeechSentenceChunker.stableSentences(in: "Hello world.", isFinal: false)
        XCTAssertEqual(result.sentences, [])

        result = SpeechSentenceChunker.stableSentences(in: "Hello world. Mo", isFinal: false)
        XCTAssertEqual(result.sentences, ["Hello world."])
    }

    func testFinalFlushEmitsUnpunctuatedTail() {
        let (sentences, _) = SpeechSentenceChunker.stableSentences(in: "First. And a trailing tail", isFinal: true)
        XCTAssertEqual(sentences, ["First.", "And a trailing tail"])
    }

    func testNewlineActsAsBoundary() {
        let (sentences, _) = SpeechSentenceChunker.stableSentences(in: "First line\nSecond li", isFinal: false)
        XCTAssertEqual(sentences, ["First line"])
    }

    func testLetterlessSegmentMergesForward() {
        let (sentences, _) = SpeechSentenceChunker.stableSentences(in: "... Hello there. Done now", isFinal: false)
        XCTAssertEqual(sentences, ["... Hello there."])
    }

    func testCJKTerminalNeedsNoTrailingSpace() {
        let (sentences, _) = SpeechSentenceChunker.stableSentences(in: "你好世界。这是下一句", isFinal: false)
        XCTAssertEqual(sentences, ["你好世界。"])
    }

    // MARK: Composer

    func testComposerStreamsSentencesOnce() {
        let composer = SpeechStreamComposer(replacements: reps)
        XCTAssertEqual(composer.ingest("The sky is blue"), [])
        XCTAssertEqual(composer.ingest("The sky is blue. Grass i"), ["The sky is blue."])
        XCTAssertEqual(composer.ingest("The sky is blue. Grass is green. En"), ["Grass is green."])
        XCTAssertEqual(composer.flush("The sky is blue. Grass is green. End"), ["End"])
    }

    func testComposerSurvivesThinkRewrite() {
        let composer = SpeechStreamComposer(replacements: reps)
        XCTAssertEqual(composer.ingest("Sure. <thi"), ["Sure."])
        XCTAssertEqual(composer.ingest("Sure. <think>hidden reasoning"), [])
        XCTAssertEqual(composer.ingest("Sure. <think>hidden</think> The answer is 42. Ok"), ["The answer is 42."])
    }

    func testComposerSurvivesShrinkingRewrite() {
        let composer = SpeechStreamComposer(replacements: reps)
        XCTAssertEqual(composer.ingest("Checking the weather now. Cal"), ["Checking the weather now."])
        XCTAssertEqual(composer.ingest("Checking the weather now."), [])
        XCTAssertEqual(composer.flush("Checking the weather now. It is 20 degrees outside."),
                       ["It is 20 degrees outside."])
    }

    func testComposerNeverSpeaksCodeContent() {
        let composer = SpeechStreamComposer(replacements: reps)
        _ = composer.ingest("Try this:\n```swift\nlet secret = 1\n")
        let sentences = composer.flush("Try this:\n```swift\nlet secret = 1\n```\nThat works.")
        XCTAssertFalse(sentences.joined().contains("secret"))
        XCTAssertTrue(sentences.contains("That works."))
    }
}
