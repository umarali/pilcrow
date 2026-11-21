import XCTest
@testable import PilcrowCore

final class SessionCodableTests: XCTestCase {
    func testShapesRoundTripAndLegacyStrokeDecodesWithoutShape() throws {
        let frame = makeFrame()
        let box = PointRect(origin: Point(x: 200, y: 100), size: Size(width: 200, height: 100))
        let shapes: [MarkShape] = [.pin, .area(.rectangle(box)), .area(.ellipse(box)), .area(.freeform),
                                   .arrow(from: 2, to: nil), .arrow(from: nil, to: nil), .mark]
        let strokes = shapes.enumerated().map { index, shape in
            Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: 0, upTime: 1,
                   points: [makePoint()], badgeAnchor: makePoint(), shape: shape)
        }
        let session = try Session(strokes: strokes, frames: [frame])
        let encoded = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: encoded), session)

        let legacy = Data("""
        {"id":1,"frameID":"\(frame.id.uuidString)","downTime":0,"upTime":1,
         "points":[{"x":0.5,"y":0.5}],"badgeAnchor":{"x":0.5,"y":0.5},"isDeleted":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(Stroke.self, from: legacy)
        XCTAssertNil(decoded.shape)
        XCTAssertEqual(decoded.upTime, 1)
        XCTAssertEqual(decoded.points, [makePoint(0.5, 0.5)])
    }

    func testLegacyLinkedToDecodesAsArrowSource() throws {
        let decoder = JSONDecoder()
        let legacy = Data(#"{"arrow":{"linkedTo":2}}"#.utf8)
        XCTAssertEqual(try decoder.decode(MarkShape.self, from: legacy), .arrow(from: 2, to: nil))
        let both = MarkShape.arrow(from: 2, to: 3)
        let data = try JSONEncoder().encode(both)
        XCTAssertEqual(try decoder.decode(MarkShape.self, from: data), both)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("linkedTo"))
    }

    func testSessionRoundTrip() throws {
        let sessionID = fixedUUID("01")
        let openFrame = makeFrame(id: fixedUUID("02"), capturedAt: 1.5, displayID: 42)
        let finishedFrame = makeFrame(
            id: fixedUUID("03"),
            capturedAt: 4,
            displayID: 7,
            points: Size(width: 800, height: 600),
            pixels: Size(width: 1600, height: 1200)
        )
        let anchor = NormalizedPoint(x: 0.25, y: 0.5)
        let finished = Stroke(
            id: MarkID(rawValue: 1),
            frameID: finishedFrame.id,
            downTime: 4.25,
            upTime: 4.8,
            points: [anchor, NormalizedPoint(x: 0.5, y: 0.75)],
            badgeAnchor: anchor,
            isDeleted: false
        )
        let deleted = Stroke(
            id: MarkID(rawValue: 2),
            frameID: finishedFrame.id,
            downTime: 5,
            upTime: 5.2,
            points: [NormalizedPoint(x: 0.1, y: 0.1)],
            badgeAnchor: NormalizedPoint(x: 0.1, y: 0.1),
            isDeleted: true
        )
        let open = Stroke(
            id: MarkID(rawValue: 3),
            frameID: openFrame.id,
            downTime: 6,
            upTime: nil,
            points: [NormalizedPoint(x: 0.8, y: 0.2)],
            badgeAnchor: NormalizedPoint(x: 0.8, y: 0.2),
            isDeleted: false
        )
        // The counter sits past the stored ids so a later delete-and-reload cannot reuse 4...8.
        let session = try! Session(
            id: sessionID,
            strokes: [finished, deleted, open],
            frames: [openFrame, finishedFrame],
            words: [
                makeWord("sign", 4, 4.5),
                makeWord("out", 4.5, 5, isFinal: false),
            ],
            nextMarkNumber: 9
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.nextMarkNumber, 9)
        XCTAssertTrue(decoded.strokes[1].isDeleted)
        XCTAssertNil(decoded.strokes[2].upTime)
        XCTAssertEqual(decoded.frames[1].displayID, 7)
        XCTAssertEqual(decoded.words[1].isFinal, false)

        var resumed = decoded
        let issued = try! resumed.beginStroke(at: 7, frame: openFrame.id, firstPoint: anchor)
        XCTAssertEqual(issued.rawValue, 9)
        XCTAssertEqual(resumed.nextMarkNumber, 10)
    }
    func testDecodeRepairsMissingOrStaleCounterAndRejectsDuplicates() throws {
        let frame = makeFrame()
        let stroke = makeStroke(5, at: 0, frameID: frame.id)
        let original = try Session(strokes: [stroke], frames: [frame])
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for value in [nil, 1] as [Int?] {
            json["nextMarkNumber"] = value
            let data = try JSONSerialization.data(withJSONObject: json)
            var decoded = try JSONDecoder().decode(Session.self, from: data)
            let issued = try decoded.beginStroke(at: 1, frame: frame.id, firstPoint: makePoint())
            XCTAssertEqual(issued.rawValue, 6)
            decoded.deleteMark(id: issued)
            XCTAssertFalse(decoded.strokes[0].isDeleted)
            XCTAssertEqual(decoded.strokes.count, 2)
        }
        let strokes = try XCTUnwrap(json["strokes"] as? [Any])
        json["strokes"] = strokes + strokes
        XCTAssertThrowsError(try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json)))
        json["strokes"] = strokes
        let frames = try XCTUnwrap(json["frames"] as? [Any])
        json["frames"] = frames + frames
        XCTAssertThrowsError(try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testDecodingStrokeWithMissingFrameFailsWithValidationError() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0, frameID: frame.id)], frames: [frame])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json["frames"] = []
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(Session.self, from: data)) { error in
            XCTAssertEqual(error as? Session.ValidationError, .unknownFrameID)
        }
    }

    func testPendingFrameRoundTripsAndCanCompleteAfterReload() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 80))
        let session = try Session(strokes: [makeStroke(1, at: 0, frameID: frame.id)], frames: [frame])
        var decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
        XCTAssertNil(decoded.frames[0].capturedAt)
        XCTAssertNil(decoded.frames[0].pixelSize)
        try decoded.completeFrame(id: frame.id, pixelSize: Size(width: 200, height: 160), capturedAt: 1)
        XCTAssertTrue(decoded.frames[0].isComplete)
    }

}
