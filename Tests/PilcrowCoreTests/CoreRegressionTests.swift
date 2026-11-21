import XCTest
@testable import PilcrowCore

final class CoreRegressionTests: XCTestCase {
    private func contexts(_ texts: [String], times: [Double]) throws -> [String] {
        let frame = makeFrame()
        let words = texts.enumerated().map { makeWord($0.element, Double($0.offset), Double($0.offset + 1)) }
        let strokes = times.enumerated().map { makeStroke($0.offset + 1, at: $0.element, frameID: frame.id) }
        return try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words)).items.map(\.words)
    }

    func testUnpunctuatedWordsSplitAtSuccessivePenDowns() throws {
        let words = (1...30).map { "w\($0)" } + ["end."]
        XCTAssertEqual(try contexts(words, times: [2.5, 9.5, 19.5]),
                       [words[..<3].joined(separator: " "), words[3..<10].joined(separator: " "), words[10...].joined(separator: " ")])
    }

    func testShortClauseSplitsWithoutSharingWords() throws {
        XCTAssertEqual(try contexts(["a", "b", "c", "d", "e", "f."], times: [0.5, 2.5, 4.5]),
                       ["a", "b c", "d e f."])
    }

    func testAbbreviationsBeforeLowercaseWordsKeepSentenceContext() throws {
        for abbreviation in ["e.g.", "i.e.", "etc."] {
            XCTAssertEqual(try contexts(["Please", "fix", abbreviation, "this", "button.", "Next."], times: [2.5, 5.5]),
                           ["Please fix \(abbreviation) this button.", "Next."])
        }
    }

    func testBeginStrokeRejectsNonFinitePointWithoutMutation() throws {
        let frame = makeFrame()
        var session = try Session(frames: [frame])
        XCTAssertThrowsError(try session.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint(.nan, 0)))
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertEqual(session.nextMarkNumber, 1)
    }

    func testAppendIgnoresNonFinitePointsAndRemainsEncodable() throws {
        let frame = makeFrame()
        var session = try Session(frames: [frame])
        let id = try session.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint())
        for point in [makePoint(.nan, 0), makePoint(0, .infinity), makePoint(-.infinity, 0)] {
            session.append(point: point, to: id)
        }
        XCTAssertEqual(session.strokes[0].points, [makePoint()])
        XCTAssertNoThrow(try JSONEncoder().encode(session))
    }

    func testAddFrameRejectsInvalidPointBounds() throws {
        for size in [Size(width: .nan, height: 80), Size(width: 100, height: .infinity), Size(width: -1, height: 80), Size(width: 100, height: 0)] {
            var session = Session()
            XCTAssertThrowsError(try session.addFrame(Frame(id: Frame.ID(), displayID: 1, boundsInPoints: size))) { XCTAssertEqual($0 as? Session.ValidationError, .invalidFrameBounds) }
            XCTAssertTrue(session.frames.isEmpty)
        }
    }

    func testCompletedFrameCannotBecomePending() throws {
        let frame = makeFrame()
        var session = try Session(frames: [frame])
        let pending = Frame(id: frame.id, displayID: frame.displayID, boundsInPoints: frame.boundsInPoints)
        XCTAssertThrowsError(try session.updateFrame(pending)) { XCTAssertEqual($0 as? Session.ValidationError, .invalidFrameTransition) }
        XCTAssertEqual(session.frames, [frame])
    }

    func testCompletionRejectsAspectMismatchAtomically() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 80))
        var session = try Session(frames: [frame])
        XCTAssertThrowsError(try session.completeFrame(id: frame.id, pixelSize: Size(width: 200, height: 100), capturedAt: 1))
        XCTAssertEqual(session.frames, [frame])
    }

    func testRetinaMinimumCropIsMeasuredInPoints() throws {
        let frame = makeFrame(points: Size(width: 1000, height: 500), pixels: Size(width: 2000, height: 1000))
        let stroke = Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: nil, points: [makePoint(0.5, 0.5)], badgeAnchor: makePoint(0.5, 0.5))
        let item = try XCTUnwrap(FixList.build(session: Session(strokes: [stroke], frames: [frame])).items.first)
        XCTAssertEqual(item.cropRect, PixelRect(origin: Point(x: 680, y: 300), size: Size(width: 640, height: 400)))
    }

    func testMessageCombinesFixListAndFrameAndCropAttachments() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0.5, frameID: frame.id)], frames: [frame], words: [makeWord("Fix!", 0, 1)])
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.text, "Fix! [1]\n\n- [1] \"Fix!\" → mark-1.png (in frame-1.png)")
        XCTAssertEqual(message.attachments, ["frame-1.png", "mark-1.png"])
    }

    func testQuotedContextDoesNotEscapeMarkdownPunctuation() {
        XCTAssertEqual(TextSanitizer.markdownQuoted("#fix _this_ [x] \"quote\" \\path\r\nline"),
                       "#fix _this_ [x] \\\"quote\\\" \\\\path line")
    }

    func testPendingFrameNormalizesGlobalPointsWithoutPixels() throws {
        var frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 800, height: 600))
        let origin = Point(x: -1200, y: -400)
        let screen = Point(x: -1000, y: 50)
        let point = try XCTUnwrap(Geometry.normalizedPoint(screenPoint: screen, frameOrigin: origin, frame: frame))
        XCTAssertEqual(point, makePoint(0.25, 0.25))
        XCTAssertEqual(Geometry.normalizedPoint(screenPoint: origin, frameOrigin: origin, frame: frame), makePoint(0, 1))
        XCTAssertEqual(Geometry.normalizedPoint(screenPoint: Point(x: -400, y: 200), frameOrigin: origin, frame: frame), makePoint(1, 0))
        XCTAssertEqual(Geometry.normalizedPoint(screenPoint: Point(x: -1400, y: 350), frameOrigin: origin, frame: frame), makePoint(-0.25, -0.25))
        XCTAssertNil(Geometry.pixelPoint(screenPoint: screen, frameOrigin: origin, frame: frame))
        XCTAssertNil(Geometry.normalize(.zero, frame: frame))
        XCTAssertNil(Geometry.denormalize(point, frame: frame))
        frame.capturedAt = 1
        frame.pixelSize = Size(width: 1600, height: 1200)
        XCTAssertEqual(Geometry.normalizedPoint(screenPoint: screen, frameOrigin: origin, frame: frame), point)
        XCTAssertEqual(Geometry.pixelPoint(screenPoint: screen, frameOrigin: origin, frame: frame), Point(x: 400, y: 300))
    }

    func testNormalizedScreenPointRejectsNonFiniteInputsAndInvalidBounds() {
        let frame = makeFrame()
        for value in [Double.nan, .infinity, -.infinity] {
            for point in [Point(x: value, y: 0), Point(x: 0, y: value)] {
                XCTAssertNil(Geometry.normalizedPoint(screenPoint: point, frameOrigin: .zero, frame: frame))
                XCTAssertNil(Geometry.normalizedPoint(screenPoint: .zero, frameOrigin: point, frame: frame))
                XCTAssertNil(Geometry.normalize(point, frame: frame))
                XCTAssertNil(Geometry.denormalize(makePoint(point.x, point.y), frame: frame))
            }
        }
        for size in [Size(width: 0, height: 80), Size(width: 100, height: -1), Size(width: .nan, height: 80), Size(width: 100, height: .infinity)] {
            var invalid = frame
            invalid.boundsInPoints = size
            XCTAssertNil(Geometry.normalizedPoint(screenPoint: .zero, frameOrigin: .zero, frame: invalid))
        }
        XCTAssertNil(Geometry.normalizedPoint(screenPoint: Point(x: 1e308, y: 0), frameOrigin: Point(x: -1e308, y: 0), frame: frame))
    }

    func testBeginStrokeValidationOrderWithCompetingErrors() throws {
        let frame = makeFrame()
        let unknown = Frame.ID()
        var session = try Session(frames: [frame], nextMarkNumber: Int.max)
        let badPoint = makePoint(.nan, .infinity)
        XCTAssertThrowsError(try session.beginStroke(at: .nan, frame: unknown, firstPoint: badPoint)) { XCTAssertEqual($0 as? Session.ValidationError, .nonFiniteTime) }
        XCTAssertThrowsError(try session.beginStroke(at: 0, frame: unknown, firstPoint: badPoint)) { XCTAssertEqual($0 as? Session.ValidationError, .unknownFrameID) }
        XCTAssertThrowsError(try session.beginStroke(at: 0, frame: frame.id, firstPoint: badPoint)) { XCTAssertEqual($0 as? Session.ValidationError, .exhaustedMarkIDs) }
        session = try Session(frames: [frame])
        for value in [Double.nan, .infinity, -.infinity] {
            for point in [makePoint(value, 0), makePoint(0, value)] {
                XCTAssertThrowsError(try session.beginStroke(at: 0, frame: frame.id, firstPoint: point)) { XCTAssertEqual($0 as? Session.ValidationError, .nonFinitePoint) }
            }
        }
        XCTAssertEqual(session.nextMarkNumber, 1)
        XCTAssertTrue(session.strokes.isEmpty)
    }

    func testFailedCaptureIsDistinctRoundTripsAndCanRetry() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 80))
        var session = try Session(strokes: [makeStroke(7, at: 0, frameID: frame.id)], frames: [frame])
        XCTAssertEqual(FixList.build(session: session).items[0].unavailableReason, .pendingFrame)
        XCTAssertTrue(MessageBuilder.build(session: session).text.contains("screenshot pending"))
        try session.failFrame(id: frame.id)
        try session.failFrame(id: frame.id)
        XCTAssertTrue(session.frames[0].captureFailed)
        XCTAssertFalse(session.frames[0].isComplete)
        let failed = MessageBuilder.build(session: session)
        XCTAssertTrue(failed.text.contains("screenshot not available"))
        XCTAssertFalse(failed.text.contains("failedFrame"))
        XCTAssertEqual(failed.missingImages, [frame.id])
        XCTAssertTrue(failed.attachments.isEmpty)
        XCTAssertTrue(failed.cropPlans.isEmpty)
        XCTAssertEqual(FixList.build(session: session).items[0].unavailableReason, .failedFrame)
        XCTAssertNil(Geometry.denormalize(makePoint(), frame: session.frames[0]))
        session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(session.frames[0].captureFailed)
        try session.completeFrame(id: frame.id, pixelSize: Size(width: 200, height: 160), capturedAt: 1)
        XCTAssertFalse(session.frames[0].captureFailed)
        XCTAssertTrue(session.frames[0].isComplete)
        XCTAssertEqual(session.liveMarks.map(\.id), [7])
        XCTAssertEqual(MessageBuilder.build(session: session).attachments, ["frame-1.png", "mark-7.png"])
        let completed = session
        XCTAssertThrowsError(try session.failFrame(id: frame.id)) { XCTAssertEqual($0 as? Session.ValidationError, .invalidFrameTransition) }
        XCTAssertEqual(session, completed)
        XCTAssertThrowsError(try session.failFrame(id: Frame.ID())) { XCTAssertEqual($0 as? Session.ValidationError, .unknownFrameID) }
    }

    func testLegacyFrameJSONDefaultsToNotFailed() throws {
        for frame in [makeFrame(), Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 80))] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
            json.removeValue(forKey: "captureFailed")
            let decoded = try JSONDecoder().decode(Frame.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded, frame)
        }
    }

    func testAspectToleranceIncludesOnePercentButRejectsBeyondIt() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 100))
        for width in [198.0, 200, 202] {
            var session = try Session(frames: [frame])
            XCTAssertNoThrow(try session.completeFrame(id: frame.id, pixelSize: Size(width: width, height: 200), capturedAt: 1))
        }
        for width in [197.0, 203.0] {
            var session = try Session(frames: [frame])
            XCTAssertThrowsError(try session.completeFrame(id: frame.id, pixelSize: Size(width: width, height: 200), capturedAt: 1)) { XCTAssertEqual($0 as? Session.ValidationError, .frameGeometryMismatch) }
            XCTAssertEqual(session.frames, [frame])
        }
        let mismatch = makeFrame(points: Size(width: 100, height: 100), pixels: Size(width: 220, height: 200))
        var session = Session()
        XCTAssertThrowsError(try session.addFrame(mismatch)) { XCTAssertEqual($0 as? Session.ValidationError, .frameGeometryMismatch) }
        XCTAssertThrowsError(try Session(frames: [mismatch])) { XCTAssertEqual($0 as? Session.ValidationError, .frameGeometryMismatch) }
    }

    func testLongClauseKeepsAllOfItsWords() throws {
        let sentence = ["Word1"] + (2..<30).map { "word\($0)" } + ["end."]
        let words = ["Before."] + sentence + ["Next."]
        XCTAssertEqual(try contexts(words, times: [1.75, 31.5]), [sentence.joined(separator: " "), "Next."])
    }

    func testTerminatorsSplitBeforeLowercaseAndDigits() throws {
        for ending in [".", "?", "!"] {
            XCTAssertEqual(try contexts(["First" + ending, "second", "sentence."], times: [0.5, 2.5]),
                           ["First" + ending, "second sentence."])
        }
        XCTAssertEqual(try contexts(["First.", "2", "items."], times: [0.5, 2.5]), ["First.", "2 items."])
    }

    func testFractionalCropOriginAboveHalfPixelRoundsDown() throws {
        let frame = makeFrame(points: Size(width: 2000, height: 1000), pixels: Size(width: 2000, height: 1000))
        let point = makePoint(0.500375, 0.50075)
        let stroke = Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: nil, points: [point], badgeAnchor: point)
        let item = try XCTUnwrap(FixList.build(session: Session(strokes: [stroke], frames: [frame])).items.first)
        XCTAssertEqual(item.cropRect, PixelRect(origin: Point(x: 840, y: 400), size: Size(width: 321, height: 201)))
    }

    func testHugeSpanWithFiniteAndOverflowingEndpointsFallsBackToFullFrame() throws {
        let frame = makeFrame(points: Size(width: 2000, height: 1000), pixels: Size(width: 4000, height: 2000))
        for extent in [8e304, 1e308] {
            let points = [makePoint(-extent, 0.5), makePoint(extent, 0.5)]
            let stroke = Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: nil, points: points, badgeAnchor: points[0])
            let item = try XCTUnwrap(FixList.build(session: Session(strokes: [stroke], frames: [frame])).items.first)
            XCTAssertEqual(item.cropRect, PixelRect(origin: .zero, size: Size(width: 4000, height: 2000)))
            XCTAssertEqual(item.outputSize, PixelSize(width: 1600, height: 800))
        }
    }

    func testCropPlanUsesPerAxisScaleAndSourcePixelsBeforeOutputCap() throws {
        let frame = makeFrame(points: Size(width: 1000, height: 500), pixels: Size(width: 2020, height: 1000))
        let points = [makePoint(0.3, 0.4), makePoint(0.7, 0.6)]
        let stroke = Stroke(id: 9, frameID: frame.id, downTime: 0, upTime: nil, points: points, badgeAnchor: points[0])
        let message = try MessageBuilder.build(session: Session(strokes: [stroke], frames: [frame]))
        let plan = try XCTUnwrap(message.cropPlans.first)
        XCTAssertEqual(plan.sourceFrameName, "frame-1.png")
        XCTAssertEqual(plan.sourcePixelRect, PixelRect(origin: Point(x: 404, y: 200), size: Size(width: 1212, height: 600)))
        XCTAssertEqual(plan.outputSize, PixelSize(width: 1212, height: 600))
        XCTAssertEqual(plan.cropName, "mark-9.png")
        XCTAssertEqual(try JSONDecoder().decode(OutgoingMessage.self, from: JSONEncoder().encode(message)), message)

        let large = makeFrame(points: Size(width: 2000, height: 2000), pixels: Size(width: 8000, height: 8000))
        let mark = Stroke(id: 1, frameID: large.id, downTime: 0, upTime: nil, points: [makePoint(0, 0), makePoint(1, 1)], badgeAnchor: makePoint(0, 0))
        let capped = try MessageBuilder.build(session: Session(strokes: [mark], frames: [large]))
        XCTAssertEqual(capped.cropPlans[0].sourcePixelRect.size, Size(width: 8000, height: 8000))
        XCTAssertEqual(capped.cropPlans[0].outputSize, PixelSize(width: 1248, height: 1248))
    }

    func test48PointPaddingConvertsToRetinaPixels() throws {
        let frame = makeFrame(points: Size(width: 1000, height: 500), pixels: Size(width: 2000, height: 1000))
        let points = [makePoint(0.5, 0.4), makePoint(0.5, 0.7)]
        let stroke = Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: nil, points: points, badgeAnchor: points[0])
        let item = try XCTUnwrap(FixList.build(session: Session(strokes: [stroke], frames: [frame])).items.first)
        XCTAssertEqual(item.cropRect, PixelRect(origin: Point(x: 680, y: 304), size: Size(width: 640, height: 492)))
    }

    func testTranscriptMarkdownEscapesOnlyLeadingBlockMarker() throws {
        let cases = [("# heading", "\\# heading"), ("- list", "\\- list"), ("> quote", "\\> quote"), ("1. item", "1\\. item"), ("123. item", "123\\. item"), ("normal # _text_", "normal # _text_")]
        for (input, expected) in cases {
            let session = try Session(words: [makeWord(input, 0, 1)])
            XCTAssertEqual(MessageBuilder.build(session: session).text, expected)
        }
    }

    func testDeletingAllMarksRenumbersOnlyTheNextBuild() throws {
        let a = makeFrame(), b = makeFrame()
        var session = try Session(strokes: [makeStroke(1, at: 0, frameID: a.id), makeStroke(2, at: 1, frameID: b.id)], frames: [a, b])
        let original = MessageBuilder.build(session: session)
        session.deleteMark(id: 1)
        let final = MessageBuilder.build(session: session)
        XCTAssertEqual(original.attachments, ["frame-1.png", "frame-2.png", "mark-1.png", "mark-2.png"])
        XCTAssertEqual(final.attachments, ["frame-1.png", "mark-2.png"])
        XCTAssertEqual(final.cropPlans[0].sourceFrameName, "frame-1.png")
        XCTAssertEqual(final.cropPlans[0].cropName, "mark-2.png")
    }


    func testInvalidStoredGeometryOmitsCropButKeepsCompleteFrameAttachment() throws {
        let frame = makeFrame()
        let stroke = Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: nil, points: [makePoint(.nan, 0)], badgeAnchor: makePoint())
        let message = try MessageBuilder.build(session: Session(strokes: [stroke], frames: [frame]))
        XCTAssertEqual(message.attachments, ["frame-1.png"])
        XCTAssertTrue(message.cropPlans.isEmpty)
        XCTAssertTrue(message.missingImages.isEmpty)
        XCTAssertTrue(message.text.contains("crop not available: invalid geometry"))
        XCTAssertFalse(message.text.contains("invalidGeometry"))
    }

    func testDecodedSessionRejectsInvalidBoundsAspectAndFailedCaptureMetadata() throws {
        let original = try Session(frames: [makeFrame()])
        let data = try JSONEncoder().encode(original)
        for change in 0..<3 {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var frames = try XCTUnwrap(json["frames"] as? [[String: Any]])
            let reason: Session.ValidationError
            switch change {
            case 0:
                frames[0]["boundsInPoints"] = ["width": -1, "height": 80]
                reason = .invalidFrameBounds
            case 1:
                frames[0]["pixelSize"] = ["width": 300, "height": 160]
                reason = .frameGeometryMismatch
            default:
                frames[0]["captureFailed"] = true
                reason = .invalidFrameTransition
            }
            json["frames"] = frames
            XCTAssertThrowsError(try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))) { XCTAssertEqual($0 as? Session.ValidationError, reason) }
        }
    }

}
