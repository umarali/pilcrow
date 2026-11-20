import XCTest
@testable import PilcrowCore

final class TranscriptRendererTests: XCTestCase {
    func testMarkAttachesToThePrecedingWordWithOneSpace() {
        let tokens: [TranscriptToken] = [
            .word("sign"),
            .word("out"),
            .mark(17),
            .word("over"),
            .word("here"),
        ]
        XCTAssertEqual(TranscriptRenderer.render(tokens: tokens), "sign out [17] over here")
    }

    func testPunctuationStaysInsideTheWord() {
        let tokens: [TranscriptToken] = [
            .word("Please"),
            .word("don't"),
            .mark(4),
            .word("stop."),
        ]
        XCTAssertEqual(TranscriptRenderer.render(tokens: tokens), "Please don't [4] stop.")
    }

    func testLeadingMarksHaveNoExtraSpace() {
        let tokens: [TranscriptToken] = [.mark(1), .mark(2), .word("hello")]
        XCTAssertEqual(TranscriptRenderer.render(tokens: tokens), "[1] [2] hello")
    }

    func testConsecutiveMarksAreSeparatedByOneSpace() {
        let tokens: [TranscriptToken] = [.word("hello"), .mark(1), .mark(2)]
        XCTAssertEqual(TranscriptRenderer.render(tokens: tokens), "hello [1] [2]")
    }

    func testEmptyTokenListRendersEmptyString() {
        XCTAssertEqual(TranscriptRenderer.render(tokens: []), "")
    }

    func testTrimsAndSkipsEmptyWords() {
        XCTAssertEqual(TranscriptRenderer.render(tokens: [.word("  hello "), .word(" \n"), .mark(1), .word(" world ")]), "hello [1] world")
    }

    func testCommaStaysAttachedToItsWord() {
        let tokens: [TranscriptToken] = [.word("hello,"), .mark(1), .word("world")]
        XCTAssertEqual(TranscriptRenderer.render(tokens: tokens), "hello, [1] world")
    }

    func testNewlineRunsInsideWordBecomeOneSpace() {
        XCTAssertEqual(
            TranscriptRenderer.render(tokens: [.word("first\r\n\nsecond")]),
            "first second"
        )
    }

    func testWhitespaceRunsInsideWordBecomeSingleSpaces() {
        XCTAssertEqual(
            TranscriptRenderer.render(tokens: [.word(" a  \n  b\t\t c ")]),
            "a b c"
        )
    }
    func testWhitespaceWithCombiningMarkDoesNotOrphanAccent() {
        // Splitting removes the whole whitespace grapheme. Scalar trimming would attach its accent to h.
        XCTAssertEqual(TranscriptRenderer.render(tokens: [.word(" \u{0301}hello")]), "hello")
    }

    func testCRLFAndMixedNewlineRunsInWordsCollapseOnce() {
        for text in ["a\r\nb", "a\n\u{2028}\nb", "a\t\r\n \u{85}b"] {
            XCTAssertEqual(TranscriptRenderer.render(tokens: [.word(text)]), "a b")
        }
    }

}
