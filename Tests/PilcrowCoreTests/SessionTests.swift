import XCTest
@testable import PilcrowCore

final class SessionTests: XCTestCase {
    func testFirstStrokeStartsAtOneAndCounterAdvances() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let first = try! session.beginStroke(at: 0.5, frame: frame, firstPoint: makePoint(0.1, 0.2))
        let second = try! session.beginStroke(at: 1.5, frame: frame, firstPoint: makePoint(0.3, 0.4))

        XCTAssertEqual(first.rawValue, 1)
        XCTAssertEqual(second.rawValue, 2)
        XCTAssertEqual(session.nextMarkNumber, 3)
        XCTAssertEqual(session.strokes.map(\.id), [first, second])
        XCTAssertEqual(session.strokes[0].downTime, 0.5)
        XCTAssertEqual(session.strokes[0].frameID, frame)
        XCTAssertEqual(session.strokes[0].points, [makePoint(0.1, 0.2)])
        XCTAssertEqual(session.strokes[0].badgeAnchor, makePoint(0.1, 0.2))
        XCTAssertFalse(session.strokes[0].isDeleted)
    }

    func testDeleteDoesNotRecycleTheMarkNumber() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let first = try! session.beginStroke(at: 1, frame: frame, firstPoint: makePoint())
        session.endStroke(id: first, at: 1.4)
        session.deleteMark(id: first)
        let second = try! session.beginStroke(at: 2, frame: frame, firstPoint: makePoint())

        XCTAssertEqual(first.rawValue, 1)
        XCTAssertEqual(second.rawValue, 2)
        XCTAssertEqual(session.strokes.count, 2)
        XCTAssertTrue(session.strokes[0].isDeleted)
        XCTAssertEqual(session.liveMarks.map(\.id), [second])
        XCTAssertEqual(session.nextMarkNumber, 3)
    }

    func testUndoOfTheMostRecentLiveMarkDoesNotReuseItsNumber() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let point = makePoint()
        let first = try! session.beginStroke(at: 0, frame: frame, firstPoint: point)
        let second = try! session.beginStroke(at: 1, frame: frame, firstPoint: point)
        session.deleteMark(id: second)
        let third = try! session.beginStroke(at: 2, frame: frame, firstPoint: point)

        XCTAssertEqual([first, second, third].map(\.rawValue), [1, 2, 3])
        XCTAssertEqual(session.liveMarks.map(\.id.rawValue), [1, 3])
        XCTAssertEqual(session.nextMarkNumber, 4)
    }

    func testAppendAddsPointsWithoutMovingTheBadgeAnchor() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let id = try! session.beginStroke(at: 0.25, frame: frame, firstPoint: makePoint(0, 1))
        session.append(point: makePoint(0.5, 0.5), to: id)
        session.append(point: makePoint(1, 0), to: id)

        XCTAssertEqual(
            session.strokes[0].points,
            [makePoint(0, 1), makePoint(0.5, 0.5), makePoint(1, 0)]
        )
        XCTAssertEqual(session.strokes[0].badgeAnchor, makePoint(0, 1))
        XCTAssertEqual(session.strokes[0].id, id)
    }

    func testEndStrokeRecordsUpTime() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let id = try! session.beginStroke(at: 0.5, frame: frame, firstPoint: makePoint())
        session.endStroke(id: id, at: 1.25)
        XCTAssertEqual(session.strokes[0].upTime, 1.25)
        XCTAssertEqual(session.strokes[0].downTime, 0.5)
    }

    func testInProgressStrokeHasNoUpTimeAndStaysLive() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let id = try! session.beginStroke(at: 2, frame: frame, firstPoint: makePoint())
        XCTAssertNil(session.strokes[0].upTime)
        XCTAssertEqual(session.liveMarks.map(\.id), [id])
    }

    func testUnknownMarkIDIsIgnored() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let kept = try! session.beginStroke(at: 0, frame: frame, firstPoint: makePoint())
        session.append(point: makePoint(0.9, 0.9), to: MarkID(rawValue: 9))
        session.endStroke(id: MarkID(rawValue: 9), at: 4)
        session.deleteMark(id: MarkID(rawValue: 9))

        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertEqual(session.strokes[0].id, kept)
        XCTAssertEqual(session.strokes[0].points.count, 1)
        XCTAssertNil(session.strokes[0].upTime)
        XCTAssertFalse(session.strokes[0].isDeleted)
        XCTAssertEqual(session.nextMarkNumber, 2)
    }

    func testLiveMarksHideDeletedStrokesAndKeepSessionOrder() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let first = try! session.beginStroke(at: 0, frame: frame, firstPoint: makePoint())
        let second = try! session.beginStroke(at: 1, frame: frame, firstPoint: makePoint())
        let third = try! session.beginStroke(at: 2, frame: frame, firstPoint: makePoint())
        session.deleteMark(id: second)

        XCTAssertEqual(session.liveMarks.map(\.id), [first, third])
        XCTAssertEqual(session.strokes.count, 3)
    }

    func testFramesWithMarksFollowsFirstStrokeOrderAndSkipsEmptyFrames() {
        let dropped = makeFrame(id: fixedUUID("A1"))
        let untouched = makeFrame(id: fixedUUID("A2"))
        let early = makeFrame(id: fixedUUID("A3"))
        let late = makeFrame(id: fixedUUID("A4"))
        var session = try! Session(frames: [dropped, late, untouched, early])

        let gone = try! session.beginStroke(at: 0, frame: dropped.id, firstPoint: makePoint())
        session.deleteMark(id: gone)
        _ = try! session.beginStroke(at: 1, frame: early.id, firstPoint: makePoint())
        _ = try! session.beginStroke(at: 2, frame: late.id, firstPoint: makePoint())
        _ = try! session.beginStroke(at: 3, frame: early.id, firstPoint: makePoint())

        XCTAssertEqual(session.framesWithMarks.map(\.id), [early.id, late.id])
    }

    func testInitAdvancesCounterPastExistingIDsIncludingDeleted() {
        let frame = Frame.ID()
        let session = try! Session(
            strokes: [
                makeStroke(4, at: 0, frameID: frame, deleted: true),
                makeStroke(17, at: 1, frameID: frame),
            ], frames: [makeFrame(id: frame)]
        )
        XCTAssertEqual(session.nextMarkNumber, 18)

        var resumed = session
        let issued = try! resumed.beginStroke(at: 2, frame: frame, firstPoint: makePoint())
        XCTAssertEqual(issued.rawValue, 18)
    }

    func testStaleCounterAdvancesPastExistingIDs() {
        let frame = makeFrame()
        let session = try! Session(strokes: [makeStroke(5, at: 0, frameID: frame.id)], frames: [frame], nextMarkNumber: 1)
        XCTAssertEqual(session.nextMarkNumber, 6)
    }

    func testEndAndAppendIgnoreInvalidTransitions() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let id = try! session.beginStroke(at: 2, frame: frame, firstPoint: makePoint())
        session.endStroke(id: id, at: 1)
        XCTAssertNil(session.strokes[0].upTime)
        session.endStroke(id: id, at: 3)
        session.endStroke(id: id, at: 4)
        session.append(point: makePoint(1, 1), to: id)
        XCTAssertEqual(session.strokes[0].upTime, 3)
        XCTAssertEqual(session.strokes[0].points.count, 1)
        session.deleteMark(id: id)
        session.append(point: makePoint(1, 1), to: id)
        XCTAssertEqual(session.strokes[0].points.count, 1)
        let open = try! session.beginStroke(at: 5, frame: frame, firstPoint: makePoint())
        session.deleteMark(id: open)
        session.append(point: makePoint(1, 1), to: open)
        session.endStroke(id: open, at: 6)
        XCTAssertEqual(session.strokes[1].points.count, 1)
        XCTAssertNil(session.strokes[1].upTime)
    }

    func testDeleteIsIdempotentAndDoesNotMoveTheCounter() {
        let frame = Frame.ID()
        var session = try! Session(frames: [makeFrame(id: frame)])
        let id = try! session.beginStroke(at: 0, frame: frame, firstPoint: makePoint())
        session.deleteMark(id: id)
        session.deleteMark(id: id)
        XCTAssertTrue(session.strokes[0].isDeleted)
        XCTAssertEqual(session.nextMarkNumber, 2)
        XCTAssertTrue(session.liveMarks.isEmpty)
        XCTAssertTrue(session.framesWithMarks.isEmpty)
    }
    func testFrameAndStrokeIdentityValidation() throws {
        let frame = makeFrame()
        var session = Session()
        XCTAssertThrowsError(try session.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint()))
        XCTAssertEqual(session.nextMarkNumber, 1)
        XCTAssertNoThrow(try session.addFrame(frame))
        XCTAssertThrowsError(try session.addFrame(frame))
        XCTAssertNoThrow(try session.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint()))
        XCTAssertThrowsError(try Session(frames: [frame, frame]))
        let stroke = makeStroke(1, at: 0, frameID: frame.id)
        XCTAssertThrowsError(try Session(strokes: [stroke, stroke], frames: [frame]))
        XCTAssertThrowsError(try Session(strokes: [stroke]))
    }

    func testBeginStrokeRejectsNonFiniteTime() throws {
        let frame = makeFrame()
        var session = try Session(frames: [frame])

        XCTAssertThrowsError(try session.beginStroke(at: .nan, frame: frame.id, firstPoint: makePoint()))
        XCTAssertThrowsError(try session.beginStroke(at: .infinity, frame: frame.id, firstPoint: makePoint()))
        XCTAssertThrowsError(try session.beginStroke(at: -.infinity, frame: frame.id, firstPoint: makePoint()))
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertEqual(session.nextMarkNumber, 1)
    }

    func testEndStrokeRejectsNonFiniteTimeAndSessionStillEncodes() throws {
        let frame = makeFrame()

        // +infinity exercises the finite guard; -infinity also fails the earlier-than-down check.
        for time in [Double.infinity, -Double.infinity, Double.nan] {
            var session = try Session(frames: [frame])
            let id = try session.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint())

            session.endStroke(id: id, at: time)

            XCTAssertNil(session.strokes[0].upTime)
            XCTAssertNoThrow(try JSONEncoder().encode(session))
        }
    }

    func testExhaustedMarkNumbersAreRejected() throws {
        let frame = makeFrame()
        XCTAssertThrowsError(
            try Session(strokes: [makeStroke(Int.max, at: 0, frameID: frame.id)], frames: [frame])
        ) { error in
            XCTAssertEqual(error as? Session.ValidationError, .exhaustedMarkIDs)
        }

        var exhausted = try Session(frames: [frame], nextMarkNumber: Int.max)
        XCTAssertThrowsError(try exhausted.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint()))
        XCTAssertTrue(exhausted.strokes.isEmpty)
        XCTAssertEqual(exhausted.nextMarkNumber, Int.max)
    }

    func testEmptySessionDoesNotThrow() {
        let session = Session()
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.frames.isEmpty)
        XCTAssertEqual(session.nextMarkNumber, 1)
    }

    func testPendingFrameAcceptsStrokeAndCompletesWithoutChangingMark() throws {
        let frame = Frame(id: Frame.ID(), displayID: 7, boundsInPoints: Size(width: 800, height: 600))
        var session = Session()
        try session.addFrame(frame)
        let mark = try session.beginStroke(at: 1, frame: frame.id, firstPoint: makePoint())
        XCTAssertFalse(session.frames[0].isComplete)
        try session.completeFrame(id: frame.id, pixelSize: Size(width: 1600, height: 1200), capturedAt: 1.1)
        XCTAssertTrue(session.frames[0].isComplete)
        XCTAssertEqual(session.frames[0].capturedAt, 1.1)
        XCTAssertEqual(session.strokes[0].id, mark)
        XCTAssertEqual(session.strokes[0].frameID, frame.id)
        XCTAssertEqual(session.strokes[0].badgeAnchor, makePoint())
    }

    func testUpdateFrameRejectsUnknownIDAndCoordinateSpaceChanges() throws {
        let frame = makeFrame()
        var session = try Session(frames: [frame])
        XCTAssertThrowsError(try session.updateFrame(makeFrame())) { XCTAssertEqual($0 as? Session.ValidationError, .unknownFrameID) }
        var moved = frame
        moved.boundsInPoints.width += 1
        XCTAssertThrowsError(try session.updateFrame(moved)) { XCTAssertEqual($0 as? Session.ValidationError, .frameGeometryMismatch) }
        moved = frame
        moved.displayID += 1
        XCTAssertThrowsError(try session.updateFrame(moved))
        XCTAssertEqual(session.frames, [frame])
        var completed = frame
        completed.capturedAt = 3
        try session.updateFrame(completed)
        XCTAssertEqual(session.frames[0].capturedAt, 3)
    }

    func testInvalidCaptureMetadataIsRejectedAtomically() throws {
        let pending = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 100))
        var session = try Session(frames: [pending])
        for size in [Size(width: 0, height: 5), Size(width: .infinity, height: 5), Size(width: 5, height: .nan)] {
            XCTAssertThrowsError(try session.completeFrame(id: pending.id, pixelSize: size, capturedAt: 1)) { XCTAssertEqual($0 as? Session.ValidationError, .invalidFrameCapture) }
        }
        XCTAssertThrowsError(try session.completeFrame(id: pending.id, pixelSize: Size(width: 20, height: 20), capturedAt: .infinity))
        var half = pending
        half.capturedAt = 1
        XCTAssertThrowsError(try session.updateFrame(half))
        XCTAssertThrowsError(try Session(frames: [half]))
        XCTAssertEqual(session.frames, [pending])
    }

    func testBeginStrokeErrorReasonsPreserveState() throws {
        let frame = makeFrame()
        var session = Session()
        XCTAssertThrowsError(try session.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint())) { XCTAssertEqual($0 as? Session.ValidationError, .unknownFrameID) }
        try session.addFrame(frame)
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try session.beginStroke(at: time, frame: frame.id, firstPoint: makePoint())) { XCTAssertEqual($0 as? Session.ValidationError, .nonFiniteTime) }
        }
        var exhausted = try Session(frames: [frame], nextMarkNumber: Int.max)
        XCTAssertThrowsError(try exhausted.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint())) { XCTAssertEqual($0 as? Session.ValidationError, .exhaustedMarkIDs) }
        XCTAssertEqual(session.nextMarkNumber, 1)
        XCTAssertTrue(session.strokes.isEmpty)
    }

}
