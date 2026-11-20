import Foundation
@testable import PilcrowCore

func makePoint(_ x: Double = 0.25, _ y: Double = 0.75) -> NormalizedPoint {
    NormalizedPoint(x: x, y: y)
}

func makeFrame(
    id: Frame.ID = Frame.ID(),
    capturedAt: Double = 0,
    displayID: UInt32 = 1,
    points: Size = Size(width: 100, height: 80),
    pixels: Size = Size(width: 200, height: 160)
) -> Frame {
    Frame(
        id: id,
        capturedAt: capturedAt,
        displayID: displayID,
        boundsInPoints: points,
        pixelSize: pixels
    )
}

func makeWord(_ text: String, _ start: Double, _ end: Double, isFinal: Bool = true) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end, isFinal: isFinal)
}

func makeStroke(
    _ id: Int,
    at downTime: Double,
    frameID: Frame.ID,
    deleted: Bool = false,
    upTime: Double? = nil
) -> Stroke {
    let anchor = NormalizedPoint(x: 0.2, y: 0.4)
    return Stroke(
        id: MarkID(rawValue: id),
        frameID: frameID,
        downTime: downTime,
        upTime: upTime ?? downTime + 0.2,
        points: [anchor],
        badgeAnchor: anchor,
        isDeleted: deleted
    )
}

func fixedUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000" + suffix)!
}
