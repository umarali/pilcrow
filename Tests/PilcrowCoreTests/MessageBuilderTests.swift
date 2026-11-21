import XCTest
@testable import PilcrowCore

final class MessageBuilderTests: XCTestCase {
    func testShapeLabelsOnlyChangeFixListLinesAndDeletedTargetsLoseTheirLink() throws {
        let frame = makeFrame()
        let box = PointRect(origin: Point(x: 100, y: 100), size: Size(width: 200, height: 100))
        let shapes: [MarkShape?] = [.area(.rectangle(box)), .area(.ellipse(box)), .area(.freeform),
                                    .arrow(from: 1, to: nil), .pin, .mark, nil]
        let strokes = shapes.enumerated().map { index, shape in
            Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: 1, upTime: 2,
                   points: [makePoint()], badgeAnchor: makePoint(), shape: shape)
        }
        var session = try Session(strokes: strokes, frames: [frame], words: [makeWord("Fix.", 0, 1)])
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.text, """
        Fix. [1] [2] [3] [4] [5] [6] [7]

        - [1] (box) "Fix." → mark-1.png (in frame-1.png)
        - [2] (oval) → mark-2.png (in frame-1.png)
        - [3] (area) → mark-3.png (in frame-1.png)
        - [4] (arrow starting at [1]) → mark-4.png (in frame-1.png)
        - [5] (point) → mark-5.png (in frame-1.png)
        - [6] → mark-6.png (in frame-1.png)
        - [7] → mark-7.png (in frame-1.png)
        """)

        session.deleteMark(id: 1)
        let updated = MessageBuilder.build(session: session)
        XCTAssertTrue(updated.text.contains("- [4] (arrow) → mark-4.png (in frame-1.png)"))
        XCTAssertFalse(updated.text.contains("[1]"))
        XCTAssertTrue(updated.attachments.contains("mark-4.png"))
        XCTAssertFalse(updated.attachments.contains("mark-1.png"))
        XCTAssertEqual(session.strokes[3].shape, .arrow(from: 1, to: nil))
        XCTAssertEqual(FixList.build(session: session).items.first { $0.mark == 4 }?.shape, .arrow(from: nil, to: nil))
    }

    func testArrowDirectionLabelsKeepEachSurvivingLink() throws {
        let frame = makeFrame()
        let shapes: [MarkShape] = [.pin, .pin, .arrow(from: nil, to: 2), .arrow(from: 1, to: 2)]
        let strokes = shapes.enumerated().map { index, shape in
            Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: Double(index), upTime: Double(index + 1),
                   points: [makePoint()], badgeAnchor: makePoint(), shape: shape)
        }
        var session = try Session(strokes: strokes, frames: [frame])
        let text = MessageBuilder.build(session: session).text
        XCTAssertTrue(text.contains("- [3] (arrow pointing at [2]) → mark-3.png"))
        XCTAssertTrue(text.contains("- [4] (arrow from [1] to [2]) → mark-4.png"))
        session.deleteMark(id: 2)
        let updated = MessageBuilder.build(session: session).text
        XCTAssertTrue(updated.contains("- [3] (arrow) → mark-3.png"))
        XCTAssertTrue(updated.contains("- [4] (arrow starting at [1]) → mark-4.png"))
    }

    func testEllipseLabelsUseTheFittedAspectRatio() throws {
        let frame = makeFrame()
        let dimensions = [Size(width: 125, height: 100), Size(width: 100, height: 126)]
        let strokes = dimensions.enumerated().map { index, size in
            Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: Double(index),
                   upTime: Double(index + 1), points: [makePoint()], badgeAnchor: makePoint(),
                   shape: .area(.ellipse(PointRect(origin: .zero, size: size))))
        }
        let text = MessageBuilder.build(session: try Session(strokes: strokes, frames: [frame])).text
        XCTAssertTrue(text.contains("- [1] (circle)"))
        XCTAssertTrue(text.contains("- [2] (oval)"))
    }

    func testNamesAndAttachmentsFollowFirstStrokeRatherThanFrameOrTimeOrder() throws {
        let a = makeFrame(), b = makeFrame(), unused = makeFrame()
        let session = try Session(strokes: [makeStroke(3, at: 9, frameID: b.id), makeStroke(4, at: 1, frameID: a.id)], frames: [a, unused, b])
        XCTAssertEqual(MessageBuilder.filenames(for: session), [b.id: "frame-1.png", a.id: "frame-2.png"])
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.attachments, ["frame-1.png", "frame-2.png", "mark-3.png", "mark-4.png"])
        XCTAssertEqual(message.text, "[4] [3]\n\n- [3] → mark-3.png (in frame-1.png)\n- [4] → mark-4.png (in frame-2.png)")
    }

    func testSingleMarkMatchesSignOutExample() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(17, at: 1.2, frameID: frame.id)], frames: [frame], words: [makeWord("sign", 0, 1), makeWord("out", 1, 2), makeWord("over", 2, 3), makeWord("here", 3, 4)])
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.text, "sign out [17] over here\n\n- [17] \"sign out over here\" → mark-17.png (in frame-1.png)")
        XCTAssertEqual(message.attachments, ["frame-1.png", "mark-17.png"])
    }

    func testDeletedFramesAreOmittedAndNamesStayConsecutive() throws {
        let a = makeFrame(), b = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0, frameID: a.id, deleted: true), makeStroke(2, at: 1, frameID: b.id)], frames: [a, b])
        XCTAssertEqual(MessageBuilder.filenames(for: session), [b.id: "frame-1.png"])
        XCTAssertEqual(MessageBuilder.build(session: session).attachments, ["frame-1.png", "mark-2.png"])
    }

    func testDeletedFirstStrokeStillDeterminesOrderForFrameWithOtherLiveMarks() throws {
        let a = makeFrame(), b = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0, frameID: a.id, deleted: true), makeStroke(2, at: 1, frameID: b.id), makeStroke(3, at: 2, frameID: a.id)], frames: [b, a])
        XCTAssertEqual(MessageBuilder.filenames(for: session), [a.id: "frame-1.png", b.id: "frame-2.png"])
    }

    func testRepeatedFrameHasOneFrameAttachmentAndTwoCrops() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0, frameID: frame.id), makeStroke(2, at: 1, frameID: frame.id)], frames: [frame])
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.attachments, ["frame-1.png", "mark-1.png", "mark-2.png"])
        XCTAssertEqual(message.text, "[1] [2]\n\n- [1] → mark-1.png (in frame-1.png)\n- [2] → mark-2.png (in frame-1.png)")
    }

    func testPendingCaptureIsNamedReportedAndNotAttached() throws {
        let pending = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 100))
        let complete = makeFrame()
        var session = try Session(strokes: [makeStroke(1, at: 0, frameID: pending.id), makeStroke(2, at: 1, frameID: complete.id)], frames: [complete, pending])
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.attachments, ["frame-2.png", "mark-2.png"])
        XCTAssertEqual(message.missingImages, [pending.id])
        XCTAssertEqual(message.text, "[1] [2]\n\n- [1] → mark-1.png (in frame-1.png) (screenshot pending)\n- [2] → mark-2.png (in frame-2.png)")
        try session.completeFrame(id: pending.id, pixelSize: Size(width: 200, height: 200), capturedAt: 2)
        XCTAssertEqual(MessageBuilder.build(session: session).attachments, ["frame-1.png", "frame-2.png", "mark-1.png", "mark-2.png"])
        XCTAssertTrue(MessageBuilder.build(session: session).missingImages.isEmpty)
    }

    func testEmptyAndDeletedOnlyMessagesAreEmpty() throws {
        XCTAssertTrue(MessageBuilder.build(session: Session()).isEmpty)
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0, frameID: frame.id, deleted: true)], frames: [frame])
        XCTAssertTrue(MessageBuilder.build(session: session, destinationHint: "codex").isEmpty)
    }

    func testWordsOnlyAndDestinationHint() throws {
        let session = try Session(words: [makeWord("hello", 0, 1)])
        let message = MessageBuilder.build(session: session, destinationHint: "codex")
        XCTAssertEqual(message.text, "hello")
        XCTAssertEqual(message.destinationHint, "codex")
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testOnlyFinalRealignsAndBuildIsDeterministic() throws {
        let frame = makeFrame()
        let session = try Session(strokes: [makeStroke(1, at: 0.5, frameID: frame.id)], frames: [frame], words: [makeWord("draft", 0, 1, isFinal: false), makeWord("final", 1, 2)])
        let message = MessageBuilder.build(session: session, onlyFinal: true)
        XCTAssertEqual(message.text, "[1] final\n\n- [1] \"final\" → mark-1.png (in frame-1.png)")
        XCTAssertEqual(message, MessageBuilder.build(session: session, onlyFinal: true))
    }

    func testGeneratedNamesAreSafeAndUnique() throws {
        let frames = (0..<20).map { _ in makeFrame() }
        let session = try Session(strokes: frames.enumerated().map { makeStroke($0.offset + 1, at: Double($0.offset), frameID: $0.element.id) }, frames: frames.reversed())
        let names = MessageBuilder.filenames(for: session)
        XCTAssertEqual(Set(names.values).count, 20)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(names[frame.id], "frame-\(index + 1).png")
            XCTAssertFalse(names[frame.id]!.contains(where: { $0.isNewline || $0 == "/" || $0 == "\\" }))
        }
    }

    func testSingleLineSanitizerHandlesCRLFAndMixedFilenameRuns() {
        for name in ["a\r\nb", "a\n\u{2028}\nb", "a\r\n\u{85}\u{2029}b"] {
            XCTAssertEqual(TextSanitizer.singleLine(name), "a b")
        }
        for separator in ["\r", "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(TextSanitizer.singleLine("a\(separator)b"), "a b")
        }
    }

    func testOutgoingMessageDecodesWithoutMissingImagesKey() throws {
        let message = try JSONDecoder().decode(OutgoingMessage.self, from: Data(#"{"text":"old message","attachments":[]}"#.utf8))
        XCTAssertEqual(message.text, "old message")
        XCTAssertEqual(message.missingImages, [])
        XCTAssertEqual(message.cropPlans, [])
        XCTAssertNil(message.destinationHint)
    }
}
