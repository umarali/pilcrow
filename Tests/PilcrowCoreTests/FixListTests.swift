import XCTest
@testable import PilcrowCore

final class FixListTests: XCTestCase {
    private func item(points: [NormalizedPoint], anchor: NormalizedPoint? = nil,
                      pixels: Size = Size(width: 2000, height: 1000), shape: MarkShape? = nil) throws -> FixItem {
        let frame = makeFrame(points: pixels, pixels: pixels)
        let stroke = Stroke(id: 3, frameID: frame.id, downTime: 0, upTime: nil,
                            points: points, badgeAnchor: anchor ?? points.first ?? makePoint(0.5, 0.5), shape: shape)
        return try XCTUnwrap(FixList.build(session: Session(strokes: [stroke], frames: [frame])).items.first)
    }

    private func contexts(_ texts: [String], times: [Double], onlyFinal: Bool = false,
                          final: [Bool]? = nil) throws -> [String] {
        let frame = makeFrame()
        let words = texts.enumerated().map { makeWord($0.element, Double($0.offset), Double($0.offset + 1), isFinal: final?[$0.offset] ?? true) }
        let strokes = times.enumerated().map { makeStroke($0.offset + 1, at: $0.element, frameID: frame.id) }
        return try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words), onlyFinal: onlyFinal).items.map(\.words)
    }

    func testTinyStrokeExpandsAroundCenterTo320By200() throws {
        let fix = try item(points: [makePoint(0.5, 0.5)])
        XCTAssertEqual(fix.cropRect, PixelRect(origin: Point(x: 840, y: 400), size: Size(width: 320, height: 200)))
        XCTAssertEqual(fix.outputSize, PixelSize(width: 320, height: 200))
        XCTAssertNil(fix.unavailableReason)
    }

    func testTidiedAreaCropUsesFittedBoundsInsteadOfOriginalInk() throws {
        let box = PointRect(origin: Point(x: 400, y: 400), size: Size(width: 400, height: 100))
        let expected = PixelRect(origin: Point(x: 300, y: 300), size: Size(width: 600, height: 300))
        for shape in [MarkShape.area(.rectangle(box)), .area(.ellipse(box))] {
            let fix = try item(points: [makePoint(0, 0), makePoint(1, 1)], shape: shape)
            XCTAssertEqual(fix.cropRect, expected)
            XCTAssertEqual(fix.shape, shape)
        }
    }

    func testArrowCropIncludesTheFullPathIncludingIntermediateExtrema() throws {
        let points = [makePoint(0.25, 0.5), makePoint(0.5, 0.375), makePoint(0.375, 0.5)]
        let fix = try item(points: points, shape: .arrow(from: nil, to: nil))
        XCTAssertEqual(fix.cropRect, PixelRect(origin: Point(x: 375, y: 250), size: Size(width: 750, height: 375)))
    }

    func testPaddingIsQuarterOfLargerSideOnEverySide() throws {
        let fix = try item(points: [makePoint(0.3, 0.4), makePoint(0.7, 0.6)])
        XCTAssertEqual(fix.cropRect, PixelRect(origin: Point(x: 400, y: 200), size: Size(width: 1200, height: 600)))
    }

    func testPaddingHas48PointMinimum() throws {
        let fix = try item(points: [makePoint(0.5, 0.4), makePoint(0.5, 0.55)])
        XCTAssertEqual(fix.cropRect, PixelRect(origin: Point(x: 840, y: 352), size: Size(width: 320, height: 246)))
    }

    func testBadgeAnchorParticipatesInBoundingBox() throws {
        let fix = try item(points: [makePoint(0.5, 0.5)], anchor: makePoint(0.8, 0.7))
        XCTAssertEqual(fix.cropRect, PixelRect(origin: Point(x: 850, y: 350), size: Size(width: 900, height: 500)))
    }

    func testEmptyPointsStillCropAroundBadgeAnchor() throws {
        let fix = try item(points: [], anchor: makePoint(0.5, 0.5))
        XCTAssertEqual(fix.cropRect?.size, Size(width: 320, height: 200))
    }

    func testMinimumCropShiftsInsideAllFourEdges() throws {
        for (point, origin) in [(makePoint(0, 0), Point.zero), (makePoint(1, 0), Point(x: 1680, y: 0)),
                                (makePoint(0, 1), Point(x: 0, y: 800)), (makePoint(1, 1), Point(x: 1680, y: 800))] {
            let fix = try item(points: [point])
            XCTAssertEqual(fix.cropRect, PixelRect(origin: origin, size: Size(width: 320, height: 200)))
        }
    }

    func testWhollyOutOfFramePointsUseNearestEdge() throws {
        XCTAssertEqual(try item(points: [makePoint(-3, -4)]).cropRect?.origin, .zero)
        XCTAssertEqual(try item(points: [makePoint(4, 5)]).cropRect?.origin, Point(x: 1680, y: 800))
    }

    func testNegativeAndOvershootingStrokeClampsToFrame() throws {
        let fix = try item(points: [makePoint(-1, -1), makePoint(2, 2)])
        XCTAssertEqual(fix.cropRect, PixelRect(origin: .zero, size: Size(width: 2000, height: 1000)))
        XCTAssertEqual(fix.outputSize, PixelSize(width: 1600, height: 800))
    }

    func testSmallFrameClampsBelowMinimumCropSize() throws {
        let fix = try item(points: [makePoint(0.5, 0.5)], pixels: Size(width: 120, height: 80))
        XCTAssertEqual(fix.cropRect, PixelRect(origin: .zero, size: Size(width: 120, height: 80)))
        XCTAssertEqual(fix.outputSize, PixelSize(width: 120, height: 80))
    }

    func testSourceRectangleRoundsOutwardToWholePixels() throws {
        let fix = try item(points: [makePoint(0.5001, 0.5001)])
        XCTAssertEqual(fix.cropRect, PixelRect(origin: Point(x: 840, y: 400), size: Size(width: 321, height: 201)))
    }

    func testHugeStrokeOutputHonorsBothLimits() throws {
        let fix = try item(points: [makePoint(0, 0), makePoint(1, 1)], pixels: Size(width: 8000, height: 8000))
        XCTAssertEqual(fix.cropRect?.size, Size(width: 8000, height: 8000))
        XCTAssertEqual(fix.outputSize, PixelSize(width: 1248, height: 1248))
        let output = try XCTUnwrap(fix.outputSize)
        XCTAssertLessThanOrEqual(Double(output.width * output.height), ImageLimits.maxPixels)
    }

    func testHugeFiniteCoordinatesDoNotProduceNaNRectangles() throws {
        let fix = try item(points: [makePoint(-1e308, -1e308), makePoint(1e308, 1e308)])
        XCTAssertEqual(fix.cropRect, PixelRect(origin: .zero, size: Size(width: 2000, height: 1000)))
        XCTAssertEqual(try item(points: [makePoint(1e308, 1e308)]).cropRect?.origin, Point(x: 1680, y: 800))
    }

    func testNonFiniteGeometryIsReportedWithoutDroppingMark() throws {
        for point in [makePoint(.nan, 0), makePoint(0, .infinity)] {
            let fix = try item(points: [point])
            XCTAssertEqual(fix.mark, 3)
            XCTAssertNil(fix.cropRect)
            XCTAssertNil(fix.outputSize)
            XCTAssertEqual(fix.unavailableReason, .invalidGeometry)
        }
        XCTAssertEqual(try item(points: [makePoint()], anchor: makePoint(.infinity, 0)).unavailableReason, .invalidGeometry)
    }

    func testSharedClauseSplitsAndIsolatedClauseStaysWhole() throws {
        XCTAssertEqual(try contexts(["Please", "fix", "this.", "Then", "stop!"], times: [0.2, 1.2, 3.2]),
                       ["Please", "fix this.", "Then stop!"])
    }

    func testClauseTerminatorsPreservePunctuation() throws {
        for ending in [".", "?", "!", ";", ":"] {
            XCTAssertEqual(try contexts(["First" + ending, "Second" + ending], times: [0.5, 1.5]),
                           ["First" + ending, "Second" + ending])
        }
    }

    func testMarkAtClauseStartCanSplitTheNewClause() throws {
        XCTAssertEqual(try contexts(["First.", "Next", "sentence."], times: [0.5, 1, 2.5]),
                       ["First.", "Next", "sentence."])
    }

    func testClausesNearTheFirstAndLastMarks() throws {
        XCTAssertEqual(try contexts(["First.", "Tail", "words"], times: [-1, 3.1]), ["First.", "Tail words"])
    }

    func testWithoutPunctuationUsesPenDownBoundariesExclusively() throws {
        XCTAssertEqual(try contexts(["a", "b", "c", "d", "e", "f"], times: [0.5, 2.5, 4.5]),
                       ["a", "b c", "d e f"])
    }

    func testMarksInTheSameWordDoNotBorrowEarlierWords() throws {
        XCTAssertEqual(try contexts(["a", "b", "c", "d", "e", "f", "g", "h"], times: [7.1, 7.2, 7.3]),
                       ["a b c d e f g h", "", ""])
    }

    func testLeadingMarksAssignSpeechToTheClosestInterval() throws {
        XCTAssertEqual(try contexts(["later"], times: [-3, -2, -1]), ["", "", "later"])
    }

    func testNoWordsStillListsEveryMarkWithEmptyContext() throws {
        XCTAssertEqual(try contexts([], times: [0, 1]), ["", ""])
    }

    func testOnlyFinalFilteringPrecedesContextAndPlacement() throws {
        XCTAssertEqual(try contexts(["Draft.", "Final", "words!"], times: [0.5], onlyFinal: true, final: [false, true, true]), ["Final words!"])
    }

    func testRecognitionRunKeepsItsTimedSlot() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0.5, frameID: frame.id)], frames: [frame],
                                  words: [makeWord("First.\r\nSecond", 0, 1), makeWord("sentence!", 1, 2)])
        let list = FixList.build(session: session)
        XCTAssertEqual(list.transcript, "First. Second [1] sentence!")
        XCTAssertEqual(list.items.map(\.words), ["First. Second sentence!"])
    }

    func testRepairMovesTheWholeClauseAndKeepsTheGreetingInTheParagraph() throws {
        let frame = makeFrame()
        let strokes = [makeStroke(1, at: 2, frameID: frame.id, upTime: 3.4),
                       makeStroke(2, at: 3.65, frameID: frame.id)]
        let words = [makeWord("Welcome.", 0, 1), makeWord("Adjust", 1.7, 2.1), makeWord("this.", 2.1, 2.4),
                     makeWord("Slightly", 3, 3.1), makeWord("higher.", 3.1, 3.25)]
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
        XCTAssertEqual(list.transcript, "Welcome. Adjust [1] this. Slightly higher. [2]")
        XCTAssertEqual(list.items.map(\.words), ["Adjust this.", "Slightly higher."])
    }

    func testShortClauseImmediatelyBeforeNextPenDownBelongsToIt() throws {
        let frame = makeFrame()
        let strokes = [makeStroke(1, at: 1, frameID: frame.id, upTime: 2.25),
                       makeStroke(2, at: 2.4, frameID: frame.id)]
        let words = [makeWord("First.", 0.9, 1.2), makeWord("This", 2, 2.15), makeWord("piece.", 2.15, 2.3)]
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
        XCTAssertEqual(list.items.map(\.words), ["First.", "This piece."])
    }

    func testCleanupKeepsParagraphRawAndFixLineCasingAndPunctuation() throws {
        let frame = makeFrame()
        let words = phrase("Hmm... Move it move it!", from: 0.8, to: 1.1)
            + [makeWord("it!", 1.8, 1.9), makeWord("Keep 2 2.", 1.95, 2.2)]
        let session = try Session(strokes: [makeStroke(1, at: 1, frameID: frame.id)], frames: [frame],
                                  words: words, transcriptLanguageCode: "en")
        let list = FixList.build(session: session)
        XCTAssertEqual(list.transcript, "Hmm... Move it [1] move it! it! Keep 2 2.")
        XCTAssertEqual(list.items.map(\.words), ["Move it! it! Keep 2 2."])
    }

    func testRepeatCleanupKeepsSentenceStartsAndPausesOf150Milliseconds() throws {
        let frame = makeFrame()
        let mark = makeStroke(1, at: 1.2, frameID: frame.id)
        for punctuation in [".", "?", "!", ";", ":"] {
            let sentence = "Delete this\(punctuation) This shouldn't be here."
            let session = try Session(strokes: [mark], frames: [frame], words: phrase(sentence, from: 1, to: 2))
            XCTAssertEqual(FixList.build(session: session).items[0].words, sentence)
        }
        for (start, expected) in [(1.14, "Move it."), (1.15, "Move Move it."), (1.3, "Move Move it.")] {
            let words = [makeWord("Move", 0.8, 1), makeWord("Move", start, 1.45), makeWord("it.", 1.45, 1.6)]
            let session = try Session(strokes: [mark], frames: [frame], words: words)
            XCTAssertEqual(FixList.build(session: session).items[0].words, expected)
        }
    }

    func testCleanupPreservesNumbersUnitsLegitimateDoublesAndSingleCharacterCJK() throws {
        let frame = makeFrame()
        let mark = makeStroke(1, at: 1.2, frameID: frame.id)
        for sentence in ["ten pixels ten pixels", "10px 10px", "one one zero", "2 2", "point point five",
                         "that that", "had had", "plus plus", "dot dot", "谢 谢 你", "あ あ", "한 한"] {
            let session = try Session(strokes: [mark], frames: [frame], words: phrase(sentence, from: 1, to: 2),
                                      transcriptLanguageCode: "en")
            XCTAssertEqual(FixList.build(session: session).items[0].words, sentence)
        }
    }

    func testLegitimateDoublesDoNotPreventLongerRepeatCleanup() throws {
        let frame = makeFrame()
        let mark = makeStroke(1, at: 1.2, frameID: frame.id)
        let words = phrase("Check that check that box.", from: 1, to: 2)
        let session = try Session(strokes: [mark], frames: [frame], words: words)
        XCTAssertEqual(FixList.build(session: session).items[0].words, "Check that box.")
    }

    func testOnlyEnglishDropsFillersAndQuotedTextAndNamesSurvive() throws {
        let frame = makeFrame()
        let mark = makeStroke(1, at: 1.2, frameID: frame.id)
        let raw = #"Um check the Um Bongo logo and type "uh wait..." then ‘erm…’ and hmm."#
        let cleaned = #"check the Um Bongo logo and type "uh wait..." then ‘erm…’ and"#
        for languageCode: String? in ["en", "pt", "de", nil] {
            let session = try Session(strokes: [mark], frames: [frame], words: phrase(raw, from: 1, to: 2),
                                      transcriptLanguageCode: languageCode)
            let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.transcriptLanguageCode, languageCode)
            XCTAssertEqual(FixList.build(session: restored).items[0].words, languageCode == "en" ? cleaned : raw)
        }
        let words = phrase(#"Type "um wait... then uh" here."#, from: 1, to: 2.4)
        let stops = [makeStroke(1, at: 1.35, frameID: frame.id), makeStroke(2, at: 1.9, frameID: frame.id)]
        let session = try Session(strokes: stops, frames: [frame], words: words, transcriptLanguageCode: "en")
        XCTAssertEqual(FixList.build(session: session).items.map(\.words), [#"Type "um"#, #"wait... then uh" here."#])
    }

    func testPenDownAfterReferentEndsItsFragment() throws {
        let frame = makeFrame()
        let words = phrase("move this over here and delete that", from: 1, to: 3.8)
        let strokes = [1.85, 2.65, 3.85].enumerated().map {
            makeStroke($0.offset + 1, at: $0.element, frameID: frame.id, upTime: $0.element + 0.15)
        }
        var session = try Session(strokes: strokes, frames: [frame], words: words)
        let list = FixList.build(session: session)
        XCTAssertEqual(list.items.map(\.words), ["move this", "over here", "and delete that"])
        XCTAssertEqual(list.transcript, "move this [1] over here [2] and delete that [3]")
        session.deleteMark(id: 2)
        let afterUndo = FixList.build(session: session)
        XCTAssertEqual(afterUndo.items.map(\.words), ["move this", "and delete that"])
        XCTAssertEqual(afterUndo.transcript, "move this [1] over here and delete that [3]")
    }

    func testTrailingWordsGoToLastPenDownEvenWhenItSharesThePreviousSplit() throws {
        XCTAssertEqual(try contexts(["move", "this", "over", "here."], times: [0.2, 0.4]),
                       ["move", "this over here."])
    }

    func testPenDownSweepPastClauseEndKeepsNearbySpeech() throws {
        let frame = makeFrame()
        let first = makeStroke(1, at: 5.5, frameID: frame.id, upTime: 6.3)
        let words = phrase("Fix this.", from: 5, to: 5.4) + phrase("To go on this side.", from: 6, to: 7)
        for tick in 650...1000 {
            let down = Double(tick) / 100
            let second = makeStroke(2, at: down, frameID: frame.id, upTime: down + 0.3)
            let list = try FixList.build(session: Session(strokes: [first, second], frames: [frame], words: words))
            let expected = down <= 9.5 ? ["Fix this.", "To go on this side."] : ["Fix this. To go on this side.", ""]
            XCTAssertEqual(list.items.map(\.words), expected, "Pen-down at \(down) s")
        }
    }

    func testPenDownSweepMovesSingleWordsInOrderWithinClause() throws {
        let frame = makeFrame()
        let words = phrase("move this over here and delete that", from: 1, to: 3.8)
        let second = makeStroke(2, at: 2.65, frameID: frame.id)
        let third = makeStroke(3, at: 3.85, frameID: frame.id)
        var previousCounts = [1, 3, 3]
        var observedChange = false
        for tick in 125...220 {
            let down = Double(tick) / 100
            let first = makeStroke(1, at: down, frameID: frame.id)
            let list = try FixList.build(session: Session(strokes: [first, second, third], frames: [frame], words: words))
            let counts = list.items.map { $0.words.split(separator: " ").count }
            XCTAssertTrue(counts.allSatisfy { $0 > 0 }, "Empty mark at \(down) s")
            XCTAssertGreaterThanOrEqual(counts[0], previousCounts[0])
            XCTAssertLessThanOrEqual(counts[1], previousCounts[1])
            XCTAssertLessThanOrEqual(counts[0] - previousCounts[0], 1)
            XCTAssertEqual(list.items.map(\.words).joined(separator: " "), words.map(\.text).joined(separator: " "))
            observedChange = observedChange || counts != previousCounts
            previousCounts = counts
        }
        XCTAssertTrue(observedChange)
    }

    func testMatchingRecoversClausesOnEitherSideOfPenDown() throws {
        let frame = makeFrame()
        func check(_ words: [TranscriptWord], downs: [Double], expected: [String]) throws {
            let strokes = downs.enumerated().map {
                makeStroke($0.offset + 1, at: $0.element, frameID: frame.id, upTime: $0.element + 0.4)
            }
            let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
            XCTAssertEqual(list.items.map(\.words), expected, "Pen-downs \(downs)")
        }

        for delay in [0.65, 1, 2] {
            try check(phrase("Make this header smaller.", from: 1, to: 2.2)
                      + phrase("And this one blue.", from: 4, to: 5),
                      downs: [2.2 + delay, 5 + delay],
                      expected: ["Make this header smaller.", "And this one blue."])
        }
        try check(phrase("This is too wide.", from: 1.7, to: 2.9)
                  + phrase("This is the wrong colour.", from: 3.6, to: 5)
                  + phrase("Remove this.", from: 5.8, to: 6.6),
                  downs: [1, 3, 5.1],
                  expected: ["This is too wide.", "This is the wrong colour.", "Remove this."])
    }

    func testFillerOnlyMarkDoesNotBorrowFromTheNextSentence() throws {
        let frame = makeFrame()
        let words = phrase("Um.", from: 1, to: 1.2) + phrase("Move left.", from: 1.8, to: 2.3)
        let strokes = [makeStroke(1, at: 1.1, frameID: frame.id), makeStroke(2, at: 2.2, frameID: frame.id)]
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words,
                                                      transcriptLanguageCode: "en"))
        XCTAssertEqual(list.items.map(\.words), ["", "Move left."])
    }

    func testRepairKeepsStoredMarkOrderWithOutOfOrderLegacyTimestamps() throws {
        let frame = makeFrame()
        let words = phrase("First.", from: 1, to: 1.5) + phrase("Second.", from: 2, to: 2.5)
        let strokes = [makeStroke(9, at: 2.4, frameID: frame.id), makeStroke(3, at: 1.4, frameID: frame.id)]
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
        XCTAssertEqual(list.items.map(\.mark), [9, 3])
        XCTAssertEqual(list.items.map(\.words), ["First.", "Second."])
    }

    func testClauseTailTakesPrecedenceWhenThePreviousDragStillOverlaps() throws {
        let frame = makeFrame()
        let strokes = [makeStroke(1, at: 1, frameID: frame.id, upTime: 2.1),
                       makeStroke(2, at: 2.25, frameID: frame.id)]
        let words = phrase("First.", from: 0.8, to: 1.2)
            + phrase("Lift this.", from: 1.5, to: 2)
            + phrase("A little higher.", from: 2.35, to: 3)
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
        XCTAssertEqual(list.items.map(\.words), ["First.", "Lift this. A little higher."])
    }

    func testContinuingSpeechUsesTheEndOfTheLastAssignedPhrase() throws {
        let frame = makeFrame()
        let phrases = ["This box should move left.", "Align it with the header.",
                       "Make it blue like the others.", "And add a shadow."]
        let words = phrase(phrases[0], from: 2, to: 3.2) + phrase(phrases[1], from: 3.9, to: 5.5)
            + phrase(phrases[2], from: 6.2, to: 8) + phrase(phrases[3], from: 8.7, to: 9.8)
            + phrase("Thanks.", from: 12.4, to: 12.8)
        let stroke = makeStroke(1, at: 1, frameID: frame.id, upTime: 1.8)
        let list = try FixList.build(session: Session(strokes: [stroke], frames: [frame], words: words))
        XCTAssertEqual(list.items.map(\.words), [phrases.joined(separator: " ")])
        XCTAssertTrue(list.transcript.hasSuffix("Thanks."))
    }

    func testThinkingPauseKeepsTheWholeInstructionWithTheNextMark() throws {
        let frame = makeFrame()
        let strokes = [makeStroke(1, at: 1.3, frameID: frame.id, upTime: 1.9),
                       makeStroke(2, at: 5.05, frameID: frame.id, upTime: 5.6)]
        let words = phrase("Remove this divider.", from: 1, to: 2)
            + phrase("Make this header", from: 2.7, to: 3.4)
            + phrase("a bit smaller.", from: 4.2, to: 4.9)
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
        XCTAssertEqual(list.items.map(\.words), ["Remove this divider.", "Make this header a bit smaller."])
    }

    func testUndoThenRedrawInSilenceInheritsSpeech() throws {
        let frame = makeFrame()
        let words = phrase("Make this blue.", from: 5, to: 6)
        for redraw in [6.2, 6.6, 7, 8] {
            let strokes = [makeStroke(1, at: 5.4, frameID: frame.id, deleted: true, upTime: 5.9),
                           makeStroke(2, at: redraw, frameID: frame.id, upTime: redraw + 0.5)]
            let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
            XCTAssertEqual(list.items.map(\.words), ["Make this blue."], "Redraw at \(redraw) s")
        }
    }

    func testUndoAndRedrawInheritsTheSentenceThatContinuedAfterPenUp() throws {
        let frame = makeFrame()
        let sentence = "And this button should be a lot more blue."
        let words = phrase("Make this header smaller.", from: 1, to: 2.5)
            + phrase(sentence, from: 5, to: 7.4)
        for redraw in [8.0, 9.0, 9.8] {
            let strokes = [makeStroke(1, at: 1.3, frameID: frame.id, upTime: 1.9),
                           makeStroke(2, at: 5.4, frameID: frame.id, deleted: true, upTime: 5.9),
                           makeStroke(3, at: redraw, frameID: frame.id, upTime: redraw + 0.5)]
            let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
            XCTAssertEqual(list.items.map(\.mark), [1, 3])
            XCTAssertEqual(list.items.map(\.words), ["Make this header smaller.", sentence], "Redraw at \(redraw) s")
        }

        let paused = phrase("Make this header smaller.", from: 1, to: 2.5)
            + phrase("And this button", from: 5, to: 5.8)
            + phrase("should be a lot more blue.", from: 6.6, to: 7.4)
        let strokes = [makeStroke(1, at: 1.3, frameID: frame.id, upTime: 1.9),
                       makeStroke(2, at: 5.4, frameID: frame.id, deleted: true, upTime: 5.9),
                       makeStroke(3, at: 9.8, frameID: frame.id, upTime: 10.3)]
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: paused))
        XCTAssertEqual(list.items.map(\.words), ["Make this header smaller.", ""])
        XCTAssertTrue(list.transcript.contains(sentence))
    }

    func testFixLineCleansEllipsesFillersRepeatRunsAndStrayComma() throws {
        let frame = makeFrame()
        let stroke = makeStroke(1, at: 1.2, frameID: frame.id)
        let cases = [
            ("give a quick... Uh... cry", "give a quick cry"),
            ("give a quick… Uh… cry", "give a quick cry"),
            ("in in the corner", "in the corner"),
            ("is is this right", "is this right"),
            ("that that that", "that that"),
            ("had had had had", "had had"),
            ("this, this button", "this button"),
            ("this, this, please", "this, please"),
            ("wait... please", "wait please"),
            ("10 px px", "10 px px"),
        ]
        for (raw, clean) in cases {
            let session = try Session(strokes: [stroke], frames: [frame], words: phrase(raw, from: 1, to: 2),
                                      transcriptLanguageCode: "en")
            let list = FixList.build(session: session)
            XCTAssertEqual(list.items.map(\.words), [clean], raw)
            XCTAssertEqual(list.transcript.replacingOccurrences(of: " [1]", with: ""), raw)
        }
    }

    func testThreeQuickPinsAndCirclesShareButAGapOverOneSecondBreaksTheRun() throws {
        let frame = makeFrame()
        let words = phrase("Make these three bigger.", from: 1, to: 2.2)
        let ellipse = MarkShape.area(.ellipse(PointRect(origin: Point(x: 10, y: 10), size: Size(width: 20, height: 20))))
        func check(last: Double, expected: [String]) throws {
            let strokes = [2.4, 2.8, last].enumerated().map { index, down in
                Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: down, upTime: down + 0.05,
                       points: [makePoint()], badgeAnchor: makePoint(), shape: index == 1 ? ellipse : .pin)
            }
            let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
            XCTAssertEqual(list.items.map(\.words), expected)
        }
        try check(last: 3.2, expected: Array(repeating: "Make these three bigger.", count: 3))
        try check(last: 5, expected: ["Make these three bigger.", "Make these three bigger.", ""])
    }

    func testQuickGroupKeepsItsWholeSentenceWithADistantPlainMark() throws {
        let frame = makeFrame()
        let words = phrase("Increase padding.", from: 1, to: 2.2)
        let strokes = [2.4, 2.8, 3.2, 4.4].enumerated().map { index, down in
            Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: down, upTime: down + 0.05,
                   points: [makePoint()], badgeAnchor: makePoint(), shape: index == 3 ? .mark : .pin)
        }
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
        XCTAssertEqual(list.items.map(\.words), ["Increase padding.", "Increase padding.", "Increase padding.", ""])
    }

    func testThreeSilentBoxesShareAWholeInstructionBeforeOrAfterDrawing() throws {
        let frame = makeFrame()
        let sentence = "These three should be the same size."
        let box = MarkShape.area(.rectangle(PointRect(origin: Point(x: 10, y: 10), size: Size(width: 20, height: 20))))
        let strokes = [3.3, 4.1, 4.9].enumerated().map { index, down in
            Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: down, upTime: down + 0.6,
                   points: [makePoint()], badgeAnchor: makePoint(), shape: box)
        }
        let cases = [phrase(sentence, from: 1, to: 3), phrase(sentence, from: 5.9, to: 7.9),
                     phrase("These three", from: 5.9, to: 6.4) + phrase("should be the same size.", from: 7.2, to: 7.9)]
        for (index, words) in cases.enumerated() {
            let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
            XCTAssertEqual(list.items.map(\.words), Array(repeating: sentence, count: 3), "Speech pattern \(index)")
        }
    }

    func testSilentMarkNearNarratedMarkDoesNotTakeItsLastWord() throws {
        let frame = makeFrame()
        let sentence = "Make this header smaller."
        let words = phrase(sentence, from: 1, to: 2.5)
        for down in [3.2, 3.5, 4.5] {
            let strokes = [makeStroke(1, at: 1.3, frameID: frame.id, upTime: 1.9),
                           makeStroke(2, at: down, frameID: frame.id, upTime: down + 0.6)]
            let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
            XCTAssertEqual(list.items.map(\.words), [sentence, ""], "Silent mark at \(down) s")
        }
    }

    func testRemoteSpeechAndUndoneWordsStayInParagraph() throws {
        let frame = makeFrame()
        let words = phrase("Fix this.", from: 0.8, to: 1.4)
            + phrase("Make this blue.", from: 2, to: 2.8)
            + phrase("Hmm the rest of the page looks fine I guess.", from: 30, to: 33)
            + phrase("This too.", from: 60, to: 60.6)
            + phrase("Okay that is everything, thanks.", from: 64, to: 65)
        let strokes = [makeStroke(1, at: 1, frameID: frame.id, upTime: 1.5),
                       makeStroke(2, at: 2.4, frameID: frame.id, deleted: true, upTime: 2.6),
                       makeStroke(3, at: 60.2, frameID: frame.id, upTime: 60.7)]
        let list = try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words))
        XCTAssertEqual(list.items.map(\.words), ["Fix this.", "This too."])
        XCTAssertTrue(list.transcript.contains("Make this blue. Hmm the rest of the page looks fine I guess."))
        XCTAssertTrue(list.transcript.hasSuffix("Okay that is everything, thanks."))
        XCTAssertFalse(list.transcript.contains("[2]"))
    }

    func testTwoQuickPinsShareOneClause() throws {
        let frame = makeFrame()
        let words = phrase("Make these two bigger.", from: 1, to: 2.2)
        func pins(at times: [Double]) -> [Stroke] {
            times.enumerated().map { index, down in
                Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: down, upTime: down + 0.05,
                       points: [makePoint()], badgeAnchor: makePoint(), shape: .pin)
            }
        }
        var session = try Session(strokes: pins(at: [2.4, 2.9]), frames: [frame], words: words)
        let list = FixList.build(session: session)
        XCTAssertEqual(list.items.map(\.words), ["Make these two bigger.", "Make these two bigger."])
        XCTAssertEqual(list.transcript, "Make these two bigger. [1] [2]")
        session.deleteMark(id: 1)
        XCTAssertEqual(FixList.build(session: session).items.map(\.words), ["Make these two bigger."])
        let spokenBetween = try Session(strokes: pins(at: [1.85, 2.12]), frames: [frame], words: words)
        XCTAssertEqual(FixList.build(session: spokenBetween).items.map(\.words), ["Make these two", "bigger."])
    }

    private func phrase(_ text: String, from start: Double, to end: Double) -> [TranscriptWord] {
        let tokens = text.split(separator: " ")
        let duration = (end - start) / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            makeWord(String(token), start + Double(index) * duration, start + Double(index + 1) * duration)
        }
    }

    func testInvalidTimedWordsAreExcludedAndOverlapsUseAligner() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 3, frameID: frame.id)], frames: [frame], words: [makeWord("long", 0, 10), makeWord("short.", 1, 2), makeWord("invalid!", .nan, 4)])
        let list = FixList.build(session: session)
        XCTAssertEqual(list.transcript, "long short. [1]")
        XCTAssertEqual(list.items[0].words, "long short.")
    }

    func testItemsKeepLiveMarkOrderAndNamesMatchMessageBuilder() throws {
        let a = makeFrame(), b = makeFrame()
        let session = try Session(strokes: [makeStroke(9, at: 9, frameID: b.id), makeStroke(2, at: 0, frameID: a.id), makeStroke(5, at: 2, frameID: a.id, deleted: true)], frames: [a, b])
        let list = FixList.build(session: session)
        XCTAssertEqual(list.items.map(\.mark), [9, 2])
        XCTAssertEqual(list.items.map(\.imageName), ["frame-1.png", "frame-2.png"])
        XCTAssertEqual(list.items.map(\.cropName), ["mark-9.png", "mark-2.png"])
        XCTAssertEqual(list.items.map(\.frameID), [b.id, a.id])
        XCTAssertEqual(list.items.map(\.imageName), Array(MessageBuilder.build(session: session).attachments.prefix(2)))
    }

    func testPendingFrameRetainsMarkWordsAndReasonThenCompletes() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 100))
        var session = try Session(strokes: [makeStroke(3, at: 0.5, frameID: frame.id)], frames: [frame], words: [makeWord("Fix.", 0, 1)])
        let list = FixList.build(session: session)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items[0].words, "Fix.")
        XCTAssertNil(list.items[0].cropRect)
        XCTAssertNil(list.items[0].outputSize)
        XCTAssertEqual(list.items[0].unavailableReason, .pendingFrame)
        XCTAssertEqual(list.renderMarkdown(), "Fix. [3]\n\n- [3] \"Fix.\" → mark-3.png (in frame-1.png) (screenshot pending)")
        try session.completeFrame(id: frame.id, pixelSize: Size(width: 100, height: 100), capturedAt: 1)
        XCTAssertNotNil(FixList.build(session: session).items[0].cropRect)
    }

    func testMissingUnregisteredFrameIsRejectedInsteadOfSilentlyDroppingMark() {
        XCTAssertThrowsError(try Session(strokes: [makeStroke(1, at: 0, frameID: Frame.ID())])) {
            XCTAssertEqual($0 as? Session.ValidationError, .unknownFrameID)
        }
    }

    func testMarkdownIncludesFullTranscriptThenNumberedFixItemsDeterministically() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(3, at: 0.5, frameID: frame.id)], frames: [frame], words: [makeWord("Fix", 0, 1), makeWord("this!", 1, 2)])
        let list = FixList.build(session: session)
        XCTAssertEqual(list.renderMarkdown(), "Fix [3] this!\n\n- [3] \"Fix this!\" → mark-3.png (in frame-1.png)")
        XCTAssertEqual(list, FixList.build(session: session))
        XCTAssertEqual(list.renderMarkdown(), list.renderMarkdown())
        XCTAssertEqual(try JSONDecoder().decode(FixList.self, from: JSONEncoder().encode(list)), list)
    }

    func testMarkdownSanitizesQuotesMarkupAndMixedLineBreakRuns() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0.5, frameID: frame.id)], frames: [frame], words: [makeWord("\"a\"\r\n\u{2028}\n[evil](x) <tag> \\path", 0, 1)])
        let markdown = FixList.build(session: session).renderMarkdown()
        XCTAssertEqual(markdown.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(markdown.contains(#"\"a\" [evil](x) <tag> \\path"#))
    }

    func testEmptyAndWordsOnlyFixLists() throws {
        XCTAssertEqual(FixList.build(session: Session()).renderMarkdown(), "")
        let list = try FixList.build(session: Session(words: [makeWord("hello", 0, 1)]))
        XCTAssertEqual(list.renderMarkdown(), "hello")
        XCTAssertTrue(list.items.isEmpty)
    }

    func testLegibilityConstantsAreD17Values() {
        XCTAssertEqual(ImageLimits.maxLongEdge, 1600)
        XCTAssertEqual(ImageLimits.maxPixels, 1_560_000)
        XCTAssertEqual(ImageLimits.minBadgeHeightPixels, 24)
    }
}
