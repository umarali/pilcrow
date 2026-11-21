import CoreGraphics
import ImageIO
import PilcrowCore
import XCTest
@testable import PilcrowCore
@testable import PilcrowApp

final class MarkRendererTests: XCTestCase {
    func testArrowFromPinBadgePaintsItsNumberBesideTheCurvedTip() throws {
        let canvas = CGSize(width: 400, height: 300)
        let pin = stroke(.pin, id: 1, points: [CGPoint(x: 90, y: 150)], canvas: canvas)
        let arrow = stroke(.arrow(from: 1, to: nil), id: 2,
                           points: [CGPoint(x: 99, y: 150), CGPoint(x: 210, y: 150),
                                    CGPoint(x: 250, y: 200), CGPoint(x: 250, y: 240)], canvas: canvas)
        let original = try bitmap(width: 400, height: 300) { draw(pin, in: $0, canvas: canvas) }
        let image = try bitmap(width: 400, height: 300) {
            draw([pin, arrow], in: $0, canvas: canvas)
        }
        // Preserve the source badge, including the glyph where the shaft crosses it.
        for y in 149...151 {
            for x in 100...111 {
                XCTAssertEqual(isRed(image, x: x, y: y), isRed(original, x: x, y: y))
            }
        }
        for y in 140..<160 where abs(y - 150) >= 3 {
            for x in 96..<116 {
                XCTAssertEqual(isRed(image, x: x, y: y), isRed(original, x: x, y: y))
            }
        }
        // The number sits beside the head, leaving the area past the tip (the target) clear.
        XCTAssertTrue(isRed(image, x: 228, y: 240))
        XCTAssertTrue(isRed(image, x: 250, y: 238))
        XCTAssertFalse(isRed(image, x: 250, y: 252))
        XCTAssertFalse(isRed(image, x: 250, y: 262))
    }

    func testArrowBadgeSlidesBesideTheHeadAtTheFrameEdge() throws {
        let canvas = CGSize(width: 400, height: 300)
        let arrow = stroke(.arrow(from: nil, to: nil), id: 1, points: [CGPoint(x: 160, y: 150),
                                                                 CGPoint(x: 398, y: 150)], canvas: canvas)
        let image = try bitmap(width: 400, height: 300) { draw(arrow, in: $0, canvas: canvas) }
        XCTAssertTrue(isRed(image, x: 397, y: 150))
        XCTAssertFalse(isRed(image, x: 397, y: 156))
        XCTAssertTrue(isRed(image, x: 397, y: 172))
    }

    func testTargetedArrowDrawsItsHeadAtTheTrimmedTipAndBadgeAtTheTail() throws {
        let canvas = CGSize(width: 400, height: 300)
        // End the shaft near a pin and finish with a reverse hook pointing upwards.
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 400, height: 300))
        var session = Session()
        try session.addFrame(frame)
        let pin = try session.beginStroke(at: 0, frame: frame.id, firstPoint: NormalizedPoint(x: 0.75, y: 0.5))
        session.endStroke(id: pin, at: 0.5)
        let samples = [(100.0, 150.0), (290, 150), (277, 165)].map {
            NormalizedPoint(x: $0.0 / Double(canvas.width), y: 1 - $0.1 / Double(canvas.height))
        }
        let id = try session.beginStroke(at: 1, frame: frame.id, firstPoint: samples[0])
        for point in samples.dropFirst() { session.append(point: point, to: id) }
        session.endStroke(id: id, at: 2)
        let arrow = try XCTUnwrap(session.liveMarks.last)
        XCTAssertEqual(arrow.shape, .arrow(from: nil, to: pin))
        let image = try bitmap(width: 400, height: 300) { draw(arrow, in: $0, canvas: canvas) }
        XCTAssertTrue(isRed(image, x: 281, y: 145), "Clean head at the shaft tip")
        XCTAssertFalse(isRed(image, x: 278, y: 164), "The hand-drawn hook has no visible ink")
        let badgeX = 91...109
        let tailBadge = (120...180).contains { y in abs(y - 150) > 8 && badgeX.contains { isRed(image, x: $0, y: y) } }
        XCTAssertTrue(tailBadge)
        XCTAssertFalse((120...180).contains { y in
            abs(y - 150) > 8 && (281...300).contains { isRed(image, x: $0, y: y) }
        }, "The tip area should contain only the arrowhead")
    }

    func testArrowWithAHeadAtPenDownDrawsItsTipOnThatEnd() throws {
        let canvas = CGSize(width: 400, height: 300)
        var arrow = stroke(.arrow(from: nil, to: 1), id: 2,
                           points: [CGPoint(x: 90, y: 150), CGPoint(x: 290, y: 150)], canvas: canvas)
        arrow.shaftReversed = true
        let image = try bitmap(width: 400, height: 300) { draw(arrow, in: $0, canvas: canvas) }
        XCTAssertTrue(isRed(image, x: 99, y: 145), "The head points back to pen-down")
        XCTAssertFalse(isRed(image, x: 281, y: 145), "The pen-up end has no head")
        XCTAssertTrue((268...311).contains { x in (160...183).contains { isRed(image, x: x, y: $0) } },
                      "A targeted arrow labels the tail")
    }

    func testExportCropContainsTheFullEnlargedArrowBadge() throws {
        let canvas = CGSize(width: 8000, height: 320)
        let size = Size(width: canvas.width, height: canvas.height)
        let frame = Frame(id: Frame.ID(), capturedAt: 0, displayID: 1, boundsInPoints: size, pixelSize: size)
        let arrow = stroke(.arrow(from: nil, to: nil), id: 123456, points: [CGPoint(x: 4700, y: 160),
                                                                      CGPoint(x: 4755, y: 160)],
                           canvas: canvas, frameID: frame.id)
        let session = try Session(strokes: [arrow], frames: [frame])
        let message = MessageBuilder.build(session: session)
        let plan = try XCTUnwrap(message.cropPlans.first)
        let blank = try bitmap(width: 8000, height: 320) { _ in }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = Export.write(session: session, message: message, originals: [frame.id: blank], to: folder)
        XCTAssertTrue(result.failedFiles.isEmpty)
        let png = try XCTUnwrap(result.imageData[plan.cropName])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let crop = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(crop.width, Int(plan.sourcePixelRect.size.width))
        // Nothing red touches the crop's left or right edge, so the whole enlarged badge is inside it.
        // (Top and bottom are the frame's own edges here.)
        let pixels = try XCTUnwrap(crop.dataProvider?.data as Data?)
        let row = crop.bytesPerRow, step = crop.bitsPerPixel / 8
        func red(_ x: Int, _ y: Int) -> Bool {
            let i = y * row + x * step
            return pixels[i] > 150 && pixels[i + 1] < 90 && pixels[i + 2] < 90
        }
        let edges = (0..<crop.height).flatMap { [(0, $0), (crop.width - 1, $0)] }
        XCTAssertFalse(edges.contains { red($0.0, $0.1) }, "The crop must include the whole enlarged badge")
        XCTAssertTrue((0..<crop.height).contains { y in (0..<crop.width).contains { red($0, y) } })
    }

    private func stroke(_ shape: MarkShape, id: MarkID, points: [CGPoint], canvas: CGSize,
                        frameID: Frame.ID = Frame.ID()) -> Stroke {
        let samples = points.map { NormalizedPoint(x: Double($0.x / canvas.width), y: 1 - Double($0.y / canvas.height)) }
        return Stroke(id: id, frameID: frameID, downTime: 0, upTime: 1, points: samples,
                      badgeAnchor: samples[0], shape: shape)
    }

    private func draw(_ stroke: Stroke, in context: CGContext, canvas: CGSize) {
        draw([stroke], in: context, canvas: canvas)
    }

    private func draw(_ strokes: [Stroke], in context: CGContext, canvas: CGSize) {
        MarkRenderer.draw(strokes, in: context, bounds: CGRect(origin: .zero, size: canvas),
                          frameSize: Size(width: canvas.width, height: canvas.height)) {
            CGPoint(x: $0.x * canvas.width, y: (1 - $0.y) * canvas.height)
        }
    }

    private func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        let source = CGRect(x: x, y: image.height - 1 - y, width: 1, height: 1)
        guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(source),
              let pixel = image.cropping(to: source),
              let sample = try? bitmap(width: 1, height: 1, draw: { $0.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)) }),
              let bytes = sample.dataProvider?.data as Data? else { return false }
        return bytes[0] > 150 && bytes[1] < 90 && bytes[2] < 90
    }
}
