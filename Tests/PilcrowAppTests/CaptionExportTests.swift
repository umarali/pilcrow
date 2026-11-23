import CoreGraphics
import ImageIO
import PilcrowCore
import XCTest
import Vision
@testable import PilcrowApp

final class CaptionExportTests: XCTestCase {
    func testWordsAppendAStripOnlyToTheirMark() throws {
        let (session, original) = try fixture()
        let message = MessageBuilder.build(session: session)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = Export.write(session: session, message: message, originals: [session.frames[0].id: original],
                                  to: folder, colour: .teal)
        XCTAssertTrue(result.failedFiles.isEmpty)
        let fixes = FixList.build(session: session).items
        XCTAssertFalse(fixes[0].words.isEmpty)
        XCTAssertTrue(fixes[1].words.isEmpty)
        let spoken = try image(result, "mark-1.png")
        let silent = try image(result, "mark-2.png")
        let screenshotHeight = try XCTUnwrap(message.cropPlans.first).outputSize.height
        XCTAssertGreaterThan(spoken.height, screenshotHeight)
        XCTAssertEqual(silent.height, message.cropPlans[1].outputSize.height)
        XCTAssertFalse(try tealBands(spoken, xRange: 0..<spoken.width, yRange: 0..<screenshotHeight).isEmpty)
        XCTAssertEqual(try tealBands(spoken, xRange: 10..<60, yRange: screenshotHeight..<spoken.height).count, 1)
        XCTAssertFalse(try tealBands(silent, xRange: 0..<silent.width).isEmpty)
    }

    func testSixLongCaptionsFitFinalLimitsAndKeepBadgesLegible() throws {
        let (session, original) = try fixture(markCount: 6, spokenCount: 6, long: true)
        let message = MessageBuilder.build(session: session)
        let fixes = FixList.build(session: session).items
        XCTAssertEqual(fixes.filter { !$0.words.isEmpty }.count, 6)
        try withExport(session, original, colour: .teal) { result, _ in
            for name in message.attachments {
                let png = try image(result, name)
                XCTAssertLessThanOrEqual(max(png.width, png.height), 1600, name)
                XCTAssertLessThanOrEqual(png.width * png.height, 1_560_000, name)
            }
            let frame = try image(result, "frame-1.png")
            let bands = try tealBands(frame, xRange: 10..<60)
            XCTAssertEqual(bands.count, 6, "One caption badge for each spoken mark")
            XCTAssertTrue(bands.allSatisfy { $0.count >= 24 }, "Caption badges must stay legible")
            // Sample just left of each box edge so its vertical outline cannot
            // inflate the measured badge height. Three columns contain two badges each.
            let screenshotBands = try (0..<3).flatMap { column in
                let center = Int(Double(frame.width) * (0.25 + Double(column) * 0.25))
                return try tealBands(frame, xRange: (center - 8)..<(center - 2), yRange: 0..<(frame.height * 3 / 5))
            }
            XCTAssertEqual(screenshotBands.count, 6)
            XCTAssertTrue(screenshotBands.allSatisfy { $0.count >= 24 }, "Screenshot badges must stay legible too")
            let panelStart = try XCTUnwrap(bands.first?.lowerBound) - 16
            XCTAssertLessThanOrEqual(Double(frame.height - panelStart), Double(frame.height) * 0.4 + 2)
            let preview = URL(fileURLWithPath: "/private/tmp/pilcrow-caption-preview", isDirectory: true)
            if FileManager.default.fileExists(atPath: preview.appendingPathComponent(".render-fixture").path) {
                try XCTUnwrap(result.imageData["frame-1.png"]).write(to: preview.appendingPathComponent("six-caption-frame.png"))
                let metrics: [String: Any] = ["sourceWidth": 1600, "sourceHeight": 900, "captionCount": 6,
                    "outputWidth": frame.width, "outputHeight": frame.height, "outputPixels": frame.width * frame.height,
                    "captionBadgePixelHeights": bands.map(\.count), "screenshotBadgePixelHeights": screenshotBands.map(\.count)]
                try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
                    .write(to: preview.appendingPathComponent("six-caption-metrics.json"))
            }
        }
    }


    func testTwentySpokenMarksKeepTheAnnotatedFrameWhenCaptionsOverflow() throws {
        let (session, original) = try fixture(markCount: 20, spokenCount: 20)
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(FixList.build(session: session).items.filter { !$0.words.isEmpty }.count, 20)
        try withExport(session, original, colour: .teal) { result, folder in
            XCTAssertTrue(result.attachments.contains("frame-1.png"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("frame-1.png").path))
            XCTAssertEqual(result.attachments.count, 21)
            let frame = try image(result, "frame-1.png")
            XCTAssertEqual(frame.width, 1600)
            XCTAssertEqual(frame.height, 900)
            XCTAssertFalse(try tealBands(frame, xRange: 390..<570).isEmpty, "The fallback frame keeps the ink")
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("message.md"), encoding: .utf8), message.text)
        }
    }

    func testLongCaptionTruncationIsVisibleInPNGAndPreview() throws {
        let (session, original) = try fixture(long: true)
        try withExport(session, original) { result, folder in
            let png = try image(result, "mark-1.png")
            let sourceHeight = try XCTUnwrap(MessageBuilder.build(session: session).cropPlans.first).outputSize.height
            XCTAssertLessThanOrEqual(png.height - sourceHeight, 8 * 22 + 32)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let panel = try XCTUnwrap(png.cropping(to: CGRect(x: 0, y: sourceHeight, width: png.width, height: png.height - sourceHeight)))
            try VNImageRequestHandler(cgImage: panel).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(words.contains("full words in the message"), words)
            XCTAssertTrue(words.contains("box"), words)
            let preview = URL(fileURLWithPath: "/private/tmp/pilcrow-caption-preview", isDirectory: true)
            // Opt-in offscreen fixture output, never real screen contents.
            if FileManager.default.fileExists(atPath: preview.appendingPathComponent(".render-fixture").path) {
                for name in ["frame-1.png", "mark-1.png", "mark-2.png"] {
                    try XCTUnwrap(result.imageData[name]).write(to: preview.appendingPathComponent(name))
                }
            }
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("message.md"), encoding: .utf8),
                           MessageBuilder.build(session: session).text)
        }
    }

    func testWordlessFrameAndCropKeepTheirPixelsAndSizes() throws {
        let (session, original) = try fixture(spokenCount: 0)
        let message = MessageBuilder.build(session: session)
        try withExport(session, original) { first, _ in
            // An empty/filtered narration must produce the identical wordless export.
            var other = session
            other.setTranscript(words: [TranscriptWord(text: "", start: 0, end: 1, isFinal: true)], languageCode: "en")
            try withExport(other, original) { second, _ in
                XCTAssertEqual(first.imageData, second.imageData)
            }
            let frame = try image(first, "frame-1.png")
            XCTAssertEqual(frame.width, 1600)
            XCTAssertEqual(frame.height, 900)
            for plan in message.cropPlans {
                let png = try image(first, plan.cropName)
                XCTAssertEqual(png.width, plan.outputSize.width)
                XCTAssertEqual(png.height, plan.outputSize.height)
            }
        }
    }

    func testAgentFileHintDoesNotChangeClipboardTextOrTextOnlyMessage() {
        let paths = ["/tmp/mark-1.png"]
        let clipboard = DeliveryText.message(approvedText: "Full words", imagePaths: paths)
        XCTAssertEqual(clipboard, "Full words\n\nImages (read these first):\n/tmp/mark-1.png")
        XCTAssertEqual(DeliveryText.fileMessage(approvedText: "Full words", imagePaths: paths),
                       clipboard + "\n\nThe images also contain each mark's words under its badge.")
        XCTAssertEqual(DeliveryText.fileMessage(approvedText: "Full words", imagePaths: []), "Full words")
    }

    func testCaptionUsesCleanedFixWordsRatherThanRawParagraph() throws {
        let (session, original) = try fixture(narration: "um um make make this label clearer.")
        let fix = try XCTUnwrap(FixList.build(session: session).items.first)
        XCTAssertEqual(fix.words, "make this label clearer.")
        XCTAssertTrue(MessageBuilder.build(session: session).text.contains("um um make make"))
        try withExport(session, original) { result, _ in
            let png = try image(result, "mark-1.png")
            let height = try XCTUnwrap(MessageBuilder.build(session: session).cropPlans.first).outputSize.height
            let panel = try XCTUnwrap(png.cropping(to: CGRect(x: 0, y: height, width: png.width, height: png.height - height)))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: panel).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains(fix.words), text)
            XCTAssertFalse(text.contains("um"), text)
            XCTAssertFalse(text.contains("make make"), text)
        }
    }

    private func fixture(markCount: Int = 2, spokenCount: Int = 1, long: Bool = false, narration: String? = nil) throws -> (Session, CGImage) {
        let size = Size(width: 1600, height: 900)
        let frame = Frame(id: Frame.ID(), capturedAt: 0, displayID: 1, boundsInPoints: size, pixelSize: size)
        let strokes = (0..<markCount).map { index in
            let rowPitch = markCount > 6 ? 0.10 : 0.25
            let point = NormalizedPoint(x: 0.25 + Double(index % 3) * 0.25, y: 0.25 + Double(index / 3) * rowPitch)
            let box = PointRect(origin: Point(x: point.x * 1600, y: point.y * 900), size: Size(width: 160, height: 60))
            return Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: Double(index) * 10,
                          upTime: Double(index) * 10 + 1, points: [point], badgeAnchor: point, shape: .area(.rectangle(box)))
        }
        let text = long ? (1...80).map { "Increase spacing near detail \($0) so the label stays readable" }.joined(separator: " ") + "." : "Make this label easier to read."
        let words = (0..<spokenCount).map { index in
            TranscriptWord(text: narration ?? text, start: Double(index) * 10, end: Double(index) * 10 + 1, isFinal: true)
        }
        let session = try Session(strokes: strokes, frames: [frame], words: words, transcriptLanguageCode: "en")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        // Synthetic landmarks make the screenshot boundary and source crop easy to inspect.
        context.setFillColor(CGColor(gray: 0.82, alpha: 1))
        for y in stride(from: 90, through: 810, by: 90) {
            context.fill(CGRect(x: 100, y: y, width: 1400, height: 2))
        }
        return (session, try XCTUnwrap(context.makeImage()))
    }

    private func withExport(_ session: Session, _ original: CGImage, colour: PilcrowColour = .coral,
                            body: (Export.Result, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = Export.write(session: session, message: MessageBuilder.build(session: session),
                                  originals: [session.frames[0].id: original], to: folder, colour: colour)
        XCTAssertTrue(result.failedFiles.isEmpty)
        try body(result, folder)
    }

    private func tealBands(_ image: CGImage, xRange: Range<Int>, yRange: Range<Int>? = nil) throws -> [Range<Int>] {
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let step = image.bitsPerPixel / 8
        var bands: [Range<Int>] = []
        for y in yRange ?? 0..<image.height {
            let teal = xRange.contains { x in
                let offset = y * image.bytesPerRow + x * step
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                // Teal has much less red than green or blue, even along an antialiased edge.
                return green - red > 90 && abs(green - blue) < 25
            }
            if teal {
                if let last = bands.last, last.upperBound == y { bands[bands.count - 1] = last.lowerBound..<(y + 1) }
                else { bands.append(y..<(y + 1)) }
            }
        }
        return bands
    }

    private func image(_ result: Export.Result, _ name: String) throws -> CGImage {
        let data = try XCTUnwrap(result.imageData[name])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
