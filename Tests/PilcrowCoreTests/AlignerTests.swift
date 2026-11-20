import XCTest
@testable import PilcrowCore

final class AlignerTests: XCTestCase {
    private let frame = Frame.ID()

    func testMarkAtExactWordStart() {
        let words = [makeWord("alpha", 1, 2), makeWord("beta", 2, 3)]
        let strokes = [makeStroke(1, at: 1, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("alpha"), .mark(1), .word("beta")]
        )
    }

    func testMarkAtExactWordEndBelongsToNextWord() {
        // alpha is [0, 1) and beta is [1, 2). t = 1 is the first instant of beta, not the last of alpha.
        let words = [makeWord("alpha", 0, 1), makeWord("beta", 1, 2), makeWord("gamma", 2, 4)]
        let strokes = [makeStroke(7, at: 1, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("alpha"), .word("beta"), .mark(7), .word("gamma")]
        )
    }

    func testMarkAtExactEndOfLastWordIsTrailing() {
        let words = [makeWord("alpha", 1, 2)]
        let strokes = [makeStroke(3, at: 2, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("alpha"), .mark(3)]
        )
    }

    func testMarkInSilenceGapGoesAfterEarlierWord() {
        let words = [makeWord("alpha", 1, 2), makeWord("beta", 3, 4)]
        let strokes = [
            makeStroke(2, at: 2.5, frameID: frame),
            makeStroke(1, at: 2.2, frameID: frame),
        ]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("alpha"), .mark(1), .mark(2), .word("beta")]
        )
    }

    func testMarkAtExactEndBeforeALaterWordStaysInTheGap() {
        // t = 2 equals alpha's end, but beta has not started. The instant is silence, so the mark
        // sits after alpha. It does not jump to beta.
        let words = [makeWord("alpha", 0, 2), makeWord("beta", 3, 4)]
        let strokes = [makeStroke(5, at: 2, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("alpha"), .mark(5), .word("beta")]
        )
    }

    func testMarkBeforeFirstWordIsLeading() {
        let words = [makeWord("hello", 1, 2), makeWord("there", 2, 3)]
        let strokes = [makeStroke(4, at: 0.25, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.mark(4), .word("hello"), .word("there")]
        )
    }

    func testMarkAfterLastWordIsTrailing() {
        let words = [makeWord("alpha", 0, 1), makeWord("beta", 1, 2)]
        let strokes = [makeStroke(8, at: 9, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("alpha"), .word("beta"), .mark(8)]
        )
    }

    func testTwoMarksInOneWordFollowDownTime() {
        let words = [makeWord("hello", 0, 5)]
        let strokes = [
            makeStroke(2, at: 3, frameID: frame),
            makeStroke(1, at: 1, frameID: frame),
        ]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("hello"), .mark(1), .mark(2)]
        )
    }

    func testMarksWithTheSameDownTimeFollowID() {
        let words = [makeWord("hello", 0, 5)]
        let strokes = [
            makeStroke(5, at: 1, frameID: frame),
            makeStroke(3, at: 1, frameID: frame),
        ]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("hello"), .mark(3), .mark(5)]
        )
    }

    func testDeletedStrokeIsOmitted() {
        let words = [makeWord("hello", 0, 2), makeWord("there", 2, 4)]
        let strokes = [
            makeStroke(1, at: 0.5, frameID: frame, deleted: true),
            makeStroke(2, at: 0.5, frameID: frame),
            makeStroke(3, at: 3, frameID: frame, deleted: true),
        ]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("hello"), .mark(2), .word("there")]
        )
    }

    func testEmptyTranscriptYieldsMarksInOrder() {
        let strokes = [
            makeStroke(2, at: 5, frameID: frame),
            makeStroke(1, at: 1, frameID: frame),
            makeStroke(9, at: 1, frameID: frame, deleted: true),
            makeStroke(4, at: 1, frameID: frame),
        ]
        XCTAssertEqual(
            Aligner.place(words: [], strokes: strokes),
            [.mark(1), .mark(4), .mark(2)]
        )
    }

    func testUnfinalisedWordsArePlacedByDefault() {
        let words = [
            makeWord("um", 0, 1, isFinal: false),
            makeWord("go", 1, 2, isFinal: true),
        ]
        let strokes = [makeStroke(1, at: 0.4, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("um"), .mark(1), .word("go")]
        )
    }

    func testOnlyFinalDropsUnfinalisedWordsAndRealigns() {
        let words = [
            makeWord("um", 0, 1, isFinal: false),
            makeWord("go", 1, 2, isFinal: true),
        ]
        let strokes = [makeStroke(1, at: 0.4, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes, onlyFinal: true),
            [.mark(1), .word("go")]
        )
    }

    func testOnlyFinalWithNoFinalWordsYieldsMarks() {
        let words = [makeWord("um", 0, 1, isFinal: false)]
        let strokes = [makeStroke(6, at: 0.2, frameID: frame), makeStroke(2, at: 0.1, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes, onlyFinal: true),
            [.mark(2), .mark(6)]
        )
    }

    func testWordsAreSortedByStart() {
        let words = [makeWord("beta", 2, 3), makeWord("alpha", 0, 1)]
        let strokes = [makeStroke(1, at: 0.5, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("alpha"), .mark(1), .word("beta")]
        )
    }

    func testSeveralLeadingMarksKeepStrokeOrder() {
        let words = [makeWord("hello", 1, 2)]
        let strokes = [
            makeStroke(2, at: 0.2, frameID: frame),
            makeStroke(1, at: 0.1, frameID: frame),
            makeStroke(4, at: 0.2, frameID: frame),
        ]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.mark(1), .mark(2), .mark(4), .word("hello")]
        )
    }

    func testNonFiniteTimesAreHandledDeterministically() {
        let words = [makeWord("later", 2, 3), makeWord("bad", .nan, 2), makeWord("first", 0, 1), makeWord("badEnd", 1, .infinity)]
        let strokes = [makeStroke(3, at: .nan, frameID: frame), makeStroke(2, at: -.infinity, frameID: frame), makeStroke(1, at: 0.5, frameID: frame)]
        XCTAssertEqual(Aligner.place(words: words, strokes: strokes), [.word("first"), .mark(1), .word("later"), .mark(2), .mark(3)])
    }

    func testOverlappingWordsPrecedeTheMark() {
        // The shorter word ended before the stroke while the long word overlaps it.
        let words = [makeWord("long", 0, 10), makeWord("short", 1, 2)]
        let strokes = [makeStroke(1, at: 3, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("long"), .word("short"), .mark(1)]
        )
    }

    func testOpenStrokeIsPlacedFromDownTime() {
        let open = Stroke(
            id: MarkID(rawValue: 3),
            frameID: frame,
            downTime: 1.5,
            upTime: nil,
            points: [makePoint()],
            badgeAnchor: makePoint(),
            isDeleted: false
        )
        let words = [makeWord("hello", 1, 2)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: [open]),
            [.word("hello"), .mark(3)]
        )
    }

    func testEqualStartsKeepOriginalOrderWhenEndsMatch() {
        let words = [makeWord("one", 0, 2), makeWord("two", 0, 2)]
        let strokes = [makeStroke(1, at: 0.5, frameID: frame)]
        XCTAssertEqual(
            Aligner.place(words: words, strokes: strokes),
            [.word("one"), .word("two"), .mark(1)]
        )
    }
}
