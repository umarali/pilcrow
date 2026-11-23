import AppKit
import CoreText
@testable import PilcrowCore
import XCTest
@testable import PilcrowApp

final class CaptureContextTests: XCTestCase {
    private func fixture(count: Int = 1) throws -> (Session, CGImage) {
        let size = Size(width: 1600, height: 900)
        let frame = Frame(id: UUID(), capturedAt: 0, displayID: 1, boundsInPoints: size, pixelSize: size,
                          context: FrameContext(appName: "Safari", windowTitle: "Pilcrow – Settings", bundleID: "com.apple.Safari"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        var marks: [Stroke] = []
        for index in 0..<count {
            let y = Double(80 + index * 130)
            context.textPosition = CGPoint(x: 100, y: 900 - y - 18)
            let text = NSAttributedString(string: "Save changes", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            let point = NormalizedPoint(x: 90 / 1600.0, y: (y - 10) / 900.0)
            marks.append(Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: Double(index),
                upTime: Double(index) + 0.1, points: [point], badgeAnchor: point,
                shape: .area(.rectangle(PointRect(origin: Point(x: 90, y: y - 10), size: Size(width: 160, height: 50))))))
        }
        return (try Session(strokes: marks, frames: [frame]), try XCTUnwrap(context.makeImage()))
    }

    func testVisionRecognizesEighteenPointHelveticaInBox() throws {
        let (session, image) = try fixture()
        XCTAssertEqual(MarkTextRecognition.recognize(image, mark: session.liveMarks[0], frame: session.frames[0]), "Save changes")
    }

    func testDeadlineOmitsLateTextAndReturnsBeforeWorkFinishes() throws {
        let (session, image) = try fixture()
        let start = ProcessInfo.processInfo.systemUptime
        let text = MarkTextRecognition.collect(session: session, originals: [session.frames[0].id: image], budget: 0.025) { _, _, _ in
            Thread.sleep(forTimeInterval: 0.15)
            return "Too late"
        }
        XCTAssertTrue(text.isEmpty)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.12)
    }

    func testVisionRecognizesUnderlineStrikePinAndReversedArrowTip() throws {
        let (session, image) = try fixture()
        let frame = session.frames[0]
        var mark = session.liveMarks[0]
        for y in [89.0, 102.0] {
            mark.shape = .mark
            mark.points = [.init(x: 90 / 1600.0, y: y / 900.0), .init(x: 250 / 1600.0, y: y / 900.0)]
            XCTAssertEqual(MarkTextRecognition.recognize(image, mark: mark, frame: frame), "Save changes")
        }
        mark.shape = .pin
        mark.badgeAnchor = .init(x: 155 / 1600.0, y: 90 / 900.0)
        XCTAssertEqual(MarkTextRecognition.recognize(image, mark: mark, frame: frame), "Save changes")
        mark.shape = .arrow(from: nil, to: nil)
        mark.shaftReversed = true
        mark.points = [.init(x: 155 / 1600.0, y: 90 / 900.0), .init(x: 500 / 1600.0, y: 200 / 900.0)]
        XCTAssertEqual(MarkTextRecognition.recognize(image, mark: mark, frame: frame), "Save changes")
    }

    func testVisionFiltersWordsOutsideFreeformOnSameLine() throws {
        let (session, image) = try fixture()
        var mark = session.liveMarks[0]
        mark.shape = .area(.freeform)
        mark.points = [Point(x: 90, y: 70), Point(x: 250, y: 70), Point(x: 90, y: 100)].map {
            NormalizedPoint(x: $0.x / 1600.0, y: $0.y / 900.0)
        }
        XCTAssertEqual(MarkTextRecognition.recognize(image, mark: mark, frame: session.frames[0]), "Save")
    }

    func testDeadlineKeepsReadyTextAndSkipsRest() throws {
        let (session, image) = try fixture(count: 5)
        // Let any prior injected slow request finish without involving the main actor.
        let text = MarkTextRecognition.collect(session: session, originals: [session.frames[0].id: image], budget: 0.3) { _, mark, _ in
            if mark.id.rawValue > 1 { Thread.sleep(forTimeInterval: 0.4) }
            return "Save changes"
        }
        XCTAssertEqual(text, [1: "Save changes"])
        XCTAssertTrue(MarkTextRecognition.collect(session: session, originals: [:], budget: 0).isEmpty)
    }

    func testAreaMasksRejectTextOutsideOvalAndFreeform() throws {
        let (session, _) = try fixture()
        let frame = session.frames[0]
        var mark = session.liveMarks[0]
        let bounds = PointRect(origin: Point(x: 100, y: 100), size: Size(width: 200, height: 100))
        mark.shape = .area(.ellipse(bounds))
        let oval = try XCTUnwrap(MarkTextRecognition.Region(mark: mark, frame: frame))
        XCTAssertTrue(oval.includes(CGRect(x: 190, y: 140, width: 20, height: 20)))
        XCTAssertFalse(oval.includes(CGRect(x: 100, y: 100, width: 10, height: 10)))
        mark.shape = .area(.freeform)
        mark.points = [Point(x: 100, y: 100), Point(x: 300, y: 100), Point(x: 100, y: 300)].map {
            NormalizedPoint(x: $0.x / 1600.0, y: $0.y / 900.0)
        }
        let freeform = try XCTUnwrap(MarkTextRecognition.Region(mark: mark, frame: frame))
        XCTAssertTrue(freeform.includes(CGRect(x: 130, y: 130, width: 10, height: 10)))
        XCTAssertFalse(freeform.includes(CGRect(x: 270, y: 270, width: 10, height: 10)))
    }

    func testArrowUsesTipPinUsesPointAndLinesFollowInk() throws {
        let (session, _) = try fixture()
        var mark = session.liveMarks[0]
        let frame = session.frames[0]
        mark.points = [.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.2)]
        mark.shape = .arrow(from: nil, to: nil)
        let arrow = try XCTUnwrap(MarkTextRecognition.Region(mark: mark, frame: frame))
        XCTAssertTrue(arrow.includes(CGRect(x: 1280, y: 175, width: 20, height: 20)))
        XCTAssertFalse(arrow.includes(CGRect(x: 160, y: 175, width: 20, height: 20)))
        mark.shape = .pin
        mark.badgeAnchor = .init(x: 0.1, y: 0.2)
        let pin = try XCTUnwrap(MarkTextRecognition.Region(mark: mark, frame: frame))
        XCTAssertTrue(pin.includes(CGRect(x: 160, y: 175, width: 20, height: 20)))
        mark.shape = .mark
        let line = try XCTUnwrap(MarkTextRecognition.Region(mark: mark, frame: frame))
        XCTAssertTrue(line.includes(CGRect(x: 600, y: 160, width: 60, height: 18)))
        XCTAssertFalse(line.includes(CGRect(x: 600, y: 260, width: 60, height: 18)))
    }

    func testRegionClipsToFrameAndBlankPixelsGiveNoText() throws {
        let (session, image) = try fixture()
        var mark = session.liveMarks[0]
        mark.shape = .pin
        mark.badgeAnchor = .init(x: 0, y: 0)
        XCTAssertEqual(try XCTUnwrap(MarkTextRecognition.Region(mark: mark, frame: session.frames[0])).bounds,
                       CGRect(x: 0, y: 0, width: 56, height: 56))
        XCTAssertNil(MarkTextRecognition.recognize(image, mark: mark, frame: session.frames[0]))
    }

    func testWindowSelectionExcludesOwnAndNonNormalWindowsAndFallsBackOnDisplay() throws {
        let display = CGRect(x: 1600, y: -900, width: 1600, height: 900)
        func window(_ title: String, pid: Int, layer: Int = 0, rect: CGRect = CGRect(x: 1700, y: -800, width: 400, height: 400)) -> [String: Any] {
            [kCGWindowName as String: title, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: 1, kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        let windows = [window("Own", pid: 99), window("HUD", pid: 2, layer: 8),
                       window("Other display", pid: 3, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       window("Front", pid: 4), window("Under mark", pid: 5, rect: display)]
        let under = WindowContext.select(windows, point: CGPoint(x: 3000, y: -100), display: display, excludingPID: 99)
        XCTAssertEqual(under?[kCGWindowName as String] as? String, "Under mark")
        let fallback = WindowContext.select(Array(windows.dropLast()), point: CGPoint(x: 3000, y: -100), display: display, excludingPID: 99)
        XCTAssertEqual(fallback?[kCGWindowName as String] as? String, "Front")
        XCTAssertNil(WindowContext.select([], point: .zero, display: display, excludingPID: 99))
    }

    func testPublicationRecoveryAndRoutingKeepContextAndMessage() async throws {
        let (session, image) = try fixture()
        let text: [MarkID: String] = [1: "Save changes"]
        let message = MessageBuilder.build(session: session, visibleText: text)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = OutboxStore(root: temporary.appendingPathComponent("Outbox"))
        let exports = ExportStore(temporary: temporary)
        let id = UUID()
        let folder = try await store.prepare(id)
        let result = Export.write(session: session, message: message, originals: [session.frames[0].id: image], to: folder)
        XCTAssertTrue(result.failedFiles.isEmpty)
        let attachments = Export.attachments(session: session, message: message, names: result.attachments, visibleText: text)
        let approval = ApprovalExport(id: id, folder: folder, text: message.text, attachments: attachments,
            imageData: result.attachments.compactMap { result.imageData[$0] }, marks: [], spokenSummary: "",
            hudAnchor: .zero, finishStartedAt: 0)
        _ = try await store.create(approval, imageData: approval.imageData, destination: .clipboard, project: nil)
        let manifest = try OutboxManifest.decoder().decode(OutboxManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.attachments.first?.context, session.frames[0].context)
        XCTAssertEqual(manifest.attachments.last?.visibleText, "Save changes")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("message.md"), encoding: .utf8), message.text)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("message-for-agent.md"), encoding: .utf8).hasPrefix(message.text))
        _ = try await store.route(approval, destination: .clipboard, project: nil, shellPath: "/bin/zsh")
        let routed = try OutboxManifest.decoder().decode(OutboxManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(routed.attachments, manifest.attachments)
        let recovered = try await exports.recover(approval)
        XCTAssertEqual(recovered.attachments, approval.attachments)
        XCTAssertTrue(try String(contentsOf: recovered.folder.appendingPathComponent("message-for-agent.md"), encoding: .utf8).hasPrefix(message.text))
    }

    func testFiveMarkOCRMeasurement() throws {
        let (session, image) = try fixture(count: 5)
        var elapsed: [Double] = []
        var counts: [Int] = []
        for _ in 0..<6 {
            let start = ProcessInfo.processInfo.systemUptime
            let text = MarkTextRecognition.collect(session: session, originals: [session.frames[0].id: image])
            elapsed.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            counts.append(text.count)
            XCTAssertTrue(text.values.allSatisfy { $0 == "Save changes" }, "\(text)")
        }
        print("OCR-MEASUREMENT 1600x900 Helvetica18 five boxes ms=\(elapsed) completed=\(counts)")
        XCTAssertTrue(counts.contains(5), "At least one full five-mark recognition must complete")
    }
}
