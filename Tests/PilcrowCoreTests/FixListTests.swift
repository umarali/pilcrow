import XCTest
@testable import PilcrowCore

final class FixListTests: XCTestCase {
    private func item(points: [NormalizedPoint], anchor: NormalizedPoint? = nil,
                      pixels: Size = Size(width: 2000, height: 1000)) throws -> FixItem {
        let frame = makeFrame(points: pixels, pixels: pixels)
        let stroke = Stroke(id: 3, frameID: frame.id, downTime: 0, upTime: nil,
                            points: points, badgeAnchor: anchor ?? points.first ?? makePoint(0.5, 0.5))
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

    func testSharedSentenceFallsBackWhileIsolatedSentenceStaysWhole() throws {
        XCTAssertEqual(try contexts(["Please", "fix", "this.", "Then", "stop!"], times: [0.2, 1.2, 3.2]),
                       ["Please fix", "fix this.", "Then stop!"])
    }

    func testAllFourSentenceTerminators() throws {
        for ending in [".", "?", "!", "…"] {
            XCTAssertEqual(try contexts(["First" + ending, "Second" + ending], times: [0.5, 1.5]), ["First" + ending, "Second" + ending])
        }
    }

    func testSlotAtSentenceBoundaryBelongsToPrecedingWord() throws {
        XCTAssertEqual(try contexts(["First.", "Next", "sentence."], times: [0.5, 1, 2.5]), ["First.", "Next sentence.", "sentence."])
    }

    func testLeadingTrailingAndUnterminatedSentenceContexts() throws {
        XCTAssertEqual(try contexts(["First.", "Tail", "words"], times: [-1, 9]), ["First.", "Tail words"])
    }

    func testWithoutPunctuationUsesNeighboringMarkSlotsExclusively() throws {
        XCTAssertEqual(try contexts(["a", "b", "c", "d", "e", "f"], times: [0.5, 2.5, 4.5]),
                       ["a b c", "b c d e", "d e f"])
    }

    func testSameSlotMarksShareShortSentence() throws {
        XCTAssertEqual(try contexts(["a", "b", "c", "d", "e", "f", "g", "h"], times: [7.1, 7.2, 7.3]),
                       ["a b c d e f g h", "a b c d e f g h", "a b c d e f g h"])
    }

    func testLeadingSameSlotMarksShareShortSentence() throws {
        XCTAssertEqual(try contexts(["later"], times: [-3, -2, -1]), ["later", "later", "later"])
    }

    func testNoWordsStillListsEveryMarkWithEmptyContext() throws {
        XCTAssertEqual(try contexts([], times: [0, 1]), ["", ""])
    }

    func testOnlyFinalFilteringPrecedesContextAndPlacement() throws {
        XCTAssertEqual(try contexts(["Draft.", "Final", "words!"], times: [0.5], onlyFinal: true, final: [false, true, true]), ["Final words!"])
    }

    func testRecognitionRunSplitsForSentenceBoundariesButKeepsTimedSlot() throws {
        XCTAssertEqual(try contexts(["First.\r\nSecond", "sentence!"], times: [0.5]), ["Second sentence!"])
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
