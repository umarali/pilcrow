import Foundation
import XCTest
@testable import PilcrowCore

final class Round3ReplayTests: XCTestCase {
    private func replay(_ name: String, limit: Int = .max) throws -> Session {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "live-round3"))
        let capture = try JSONDecoder().decode(StrokeRecording.self, from: Data(contentsOf: url))
        var session = Session()
        for record in capture.strokes.prefix(limit) {
            if !session.frames.contains(where: { $0.id == record.frameID }) {
                let frame = Frame(id: record.frameID, displayID: 1, boundsInPoints: record.frameSize)
                try session.addFrame(frame)
            }
            let points = record.points.map {
                NormalizedPoint(x: $0.x / record.frameSize.width, y: $0.y / record.frameSize.height)
            }
            let id = try session.beginStroke(at: record.downTime, frame: record.frameID,
                                             firstPoint: XCTUnwrap(points.first))
            for point in points.dropFirst() { session.append(point: point, to: id) }
            session.endStroke(id: id, at: try XCTUnwrap(record.upTime))
        }
        return session
    }

    private func kind(_ mark: Stroke) -> String {
        switch mark.shape {
        case .area(.rectangle): "box"
        case .area(.ellipse): "ellipse"
        case .area(.freeform): "area"
        case .arrow: "arrow"
        case .pin: "pin"
        case .mark, nil: "mark"
        }
    }

    func testCaptureAReplaysBoxesAndArrows() throws {
        let session = try replay("capture-a")
        XCTAssertEqual(session.liveMarks.map(\.id), [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(session.liveMarks.map(kind), ["box", "arrow", "box", "box", "arrow", "box", "arrow", "mark", "arrow"])
        let byID = Dictionary(uniqueKeysWithValues: session.strokes.map { ($0.id, $0) })
        XCTAssertEqual(byID[2]?.shape, .arrow(from: 1, to: 3))
        XCTAssertEqual(byID[5]?.shape, .arrow(from: 3, to: nil))
        XCTAssertEqual(session.strokes.count, 10)
        let head = session.strokes[5]
        XCTAssertLessThan(head.id.rawValue, 0)
        XCTAssertEqual(head.absorbedInto, 5)
        XCTAssertEqual(byID[7]?.shape, .arrow(from: nil, to: 6))
        XCTAssertEqual(byID[9]?.shape, .arrow(from: nil, to: 4))
        let arrow = try XCTUnwrap(byID[7])
        XCTAssertLessThan(arrow.renderedPoints.count, arrow.points.count)
        let recording = StrokeRecording.Record(stroke: arrow, frame: try XCTUnwrap(session.frames.first))
        XCTAssertEqual(recording.points.count, 71)
        let shaftEnd = try XCTUnwrap(recording.shaftEnd)
        XCTAssertEqual(shaftEnd.x, 1220.3, accuracy: 2)
        XCTAssertEqual(shaftEnd.y, 774.4, accuracy: 2)
        XCTAssertEqual(session.nextMarkNumber, 10)

        // The original shaft was already an arrow, so undo removes both gestures.
        var prefix = try replay("capture-a", limit: 6)
        prefix.undoLatestMark(in: Set(prefix.frames.map(\.id)))
        XCTAssertEqual(prefix.liveMarks.map(\.id), [1, 2, 3, 4])
        XCTAssertTrue(prefix.strokes[4].isDeleted)
        XCTAssertTrue(prefix.strokes[5].isDeleted)
    }

    func testCaptureBReplaysEllipsesAndBoxes() throws {
        let session = try replay("capture-b")
        XCTAssertEqual(session.liveMarks.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(session.liveMarks.map(kind), ["ellipse", "ellipse", "box", "box", "box"])
    }
}
