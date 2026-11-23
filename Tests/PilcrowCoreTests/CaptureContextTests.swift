import XCTest
@testable import PilcrowCore

final class CaptureContextTests: XCTestCase {
    private func session(context: FrameContext? = nil) throws -> Session {
        let size = Size(width: 1600, height: 900)
        let frame = Frame(id: UUID(), capturedAt: 0, displayID: 1, boundsInPoints: size, pixelSize: size, context: context)
        let marks = (1...2).map { id in
            Stroke(id: MarkID(rawValue: id), frameID: frame.id, downTime: Double(id), upTime: Double(id) + 0.1,
                   points: [NormalizedPoint(x: 0.5, y: 0.5)], badgeAnchor: NormalizedPoint(x: 0.5, y: 0.5), shape: .pin)
        }
        return try Session(strokes: marks, frames: [frame])
    }

    func testMessageWithoutContextKeepsExistingForm() throws {
        XCTAssertEqual(MessageBuilder.build(session: try session()).text,
            "[1] [2]\n\n- [1] (point) → mark-1.png (in frame-1.png)\n- [2] (point) → mark-2.png (in frame-1.png)")
    }

    func testFrameHeaderAppearsOnceAndOCRIsPerMark() throws {
        let context = FrameContext(appName: "Safari", windowTitle: "Pilcrow – Settings", bundleID: "com.apple.Safari")
        let text = MessageBuilder.build(session: try session(context: context), visibleText: [1: "Save changes"]).text
        XCTAssertEqual(text, "[1] [2]\n\nframe-1.png — Safari · \"Pilcrow – Settings\"\n- [1] (point) on \"Save changes\" → mark-1.png (in frame-1.png)\n- [2] (point) → mark-2.png (in frame-1.png)")
        XCTAssertFalse(text.contains("com.apple.Safari"))
    }

    func testOCRWithoutWindowAndQuotedMultilineContext() throws {
        let text = MessageBuilder.build(session: try session(), visibleText: [2: " Save\n\"changes\" "]).text
        XCTAssertTrue(text.contains("on \"Save \\\"changes\\\"\""), text)
        let context = FrameContext(appName: "App\nname", windowTitle: "A\"B\nC")
        let other = MessageBuilder.build(session: try session(context: context)).text
        XCTAssertTrue(other.contains("frame-1.png — App name · \"A\\\"B C\"\n"), other)
        XCTAssertFalse(MessageBuilder.build(session: try session(context: FrameContext())).text.contains("—"))
    }


    func testFrameHeaderCapsBothNamesAt120Graphemes() throws {
        let name = String(repeating: "a", count: 120)
        let titleCharacter = "👨‍👩‍👧‍👦"
        let title = String(repeating: titleCharacter, count: 119) + "…"
        let context = FrameContext(appName: name + " excess", windowTitle: title + " excess")
        let text = MessageBuilder.build(session: try session(context: context)).text
        let header = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("frame-1.png") })
        XCTAssertEqual(header, "frame-1.png — \(name.dropLast())… · \"\(title)\"")
        XCTAssertEqual(FrameContext(appName: name).messageLabel, name)
    }

    func testVisibleTextTruncationAndEmptyInput() {
        XCTAssertNil(VisibleText.concise(" \n\t "))
        XCTAssertEqual(VisibleText.concise(String(repeating: "a", count: 80)), String(repeating: "a", count: 80))
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(VisibleText.concise(String(repeating: family, count: 81)), String(repeating: family, count: 79) + "…")
    }

    func testOldManifestAndFrameDecodeWithoutContext() throws {
        let json = """
        {"version":1,"id":"00000000-0000-0000-0000-000000000001","createdAt":"2026-11-23T00:00:00Z",
        "destination":"clipboard","text":"old","attachments":[{"name":"frame-1.png","kind":"frame"},{"name":"mark-1.png","kind":"crop","mark":1}]}
        """
        let manifest = try OutboxManifest.decoder().decode(OutboxManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.attachments[0].context)
        XCTAssertNil(manifest.attachments[1].visibleText)
        let oldFrame = """
        {"id":"00000000-0000-0000-0000-000000000001","displayID":1,"boundsInPoints":{"width":1600,"height":900}}
        """
        XCTAssertNil(try JSONDecoder().decode(Frame.self, from: Data(oldFrame.utf8)).context)
    }

    func testNewManifestRoundTripsOptionalFields() throws {
        let context = FrameContext(appName: "Xcode", windowTitle: "Pilcrow", bundleID: "com.apple.dt.Xcode")
        let manifest = OutboxManifest(createdAt: Date(timeIntervalSince1970: 0), destination: .clipboard, text: "message",
            attachments: [.init(name: "frame-1.png", kind: .frame, context: context),
                          .init(name: "mark-1.png", kind: .crop, mark: 1, visibleText: "Save changes")])
        XCTAssertEqual(try OutboxManifest.decoder().decode(OutboxManifest.self, from: OutboxManifest.encoder().encode(manifest)), manifest)
        let frame = try XCTUnwrap(try session(context: context).frames.first)
        XCTAssertEqual(try JSONDecoder().decode(Frame.self, from: JSONEncoder().encode(frame)), frame)
    }
}
