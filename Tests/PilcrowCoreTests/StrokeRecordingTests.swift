import XCTest
@testable import PilcrowCore

final class StrokeRecordingTests: XCTestCase {
    func testReplayPreservesLiveShapesAndArrowContextAfterJSONRoundTrip() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 997.3, height: 601.7))
        let ellipse = (0...120).map { i -> Point in
            let angle = Double(i) * 2 * .pi / 120
            return Point(x: 300.123 + 65.987 * cos(angle), y: 250.456 + 45.678 * sin(angle))
        }
        let fixtures = [
            [Point(x: 100.123456789, y: 100.987654321)],
            [Point(x: 100.123456789, y: 100.987654321), Point(x: 165.54321, y: 160.12345)],
            [Point(x: 10.123, y: 10.456), Point(x: 140.789, y: 10.456),
             Point(x: 140.789, y: 90.123), Point(x: 10.123, y: 90.123), Point(x: 10.123, y: 10.456)],
            ellipse,
            [Point(x: 600, y: 400), Point(x: 700, y: 420), Point(x: 650, y: 500), Point(x: 600, y: 400)],
            [Point(x: 800.123, y: 100.789), Point(x: 840.456, y: 110.987), Point(x: 890.123, y: 115.789)]
        ]
        var session = Session()
        try session.addFrame(frame)
        for (index, ink) in fixtures.enumerated() {
            let points = ink.map { NormalizedPoint(x: $0.x / frame.boundsInPoints.width, y: $0.y / frame.boundsInPoints.height) }
            let id = try session.beginStroke(at: Double(index * 2), frame: frame.id, firstPoint: points[0])
            for point in points.dropFirst() { session.append(point: point, to: id) }
            session.endStroke(id: id, at: Double(index * 2 + 1))
        }
        let records = session.strokes.map { StrokeRecording.Record(stroke: $0, frame: frame) }
        let data = try JSONEncoder().encode(StrokeRecording(strokes: records))
        let decoded = try JSONDecoder().decode(StrokeRecording.self, from: data)
        XCTAssertEqual(decoded.recognizerVersion, ShapeRecognizer.version)
        XCTAssertEqual(session.strokes[0].shape, .pin)
        XCTAssertEqual(session.strokes[1].shape, .arrow(from: 1, to: nil))
        guard case .area(.rectangle) = session.strokes[2].shape,
              case .area(.ellipse) = session.strokes[3].shape else { return XCTFail("Missing tidy fixtures") }
        XCTAssertEqual(session.strokes[4].shape, .area(.freeform))
        XCTAssertEqual(session.strokes[5].shape, .mark)
        for (index, record) in decoded.strokes.enumerated() {
            XCTAssertFalse(record.decimated)
            XCTAssertEqual(record.replay(existingMarks: Array(session.strokes.prefix(index))), session.strokes[index].shape)
        }
    }

    func testExactlyFiveThousandPointsRemainUndecimated() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 800, height: 500))
        let points = (0..<5000).map { NormalizedPoint(x: Double($0) / 5011, y: 0.123456789012345) }
        let stroke = Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: 1, points: points, badgeAnchor: points[0])
        let record = StrokeRecording.Record(stroke: stroke, frame: frame)
        XCTAssertFalse(record.decimated)
        XCTAssertEqual(record.resampleMethod, "none")
        XCTAssertEqual(record.originalPointCount, 5000)
        XCTAssertEqual(record.points, points.map { Point(x: $0.x * 800, y: $0.y * 500) })
    }
}
