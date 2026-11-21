import XCTest
@testable import PilcrowCore

final class FinalCoreTests: XCTestCase {
    private func contexts(_ texts: [String], slots: [Int]) throws -> [String] {
        let frame = makeFrame()
        let words = texts.enumerated().map { makeWord($0.element, Double($0.offset), Double($0.offset + 1)) }
        let strokes = slots.enumerated().map { makeStroke($0.offset + 1, at: Double($0.element) - 0.5, frameID: frame.id) }
        return try FixList.build(session: Session(strokes: strokes, frames: [frame], words: words)).items.map(\.words)
    }

    func testOneMarkGetsTheWholeUnpunctuatedClause() throws {
        let words = (1...40).map { "w\($0)" }
        XCTAssertEqual(try contexts(words, slots: [20]), [words.joined(separator: " ")])
    }

    func testLongClauseDoesNotAbsorbEarlierSpeech() throws {
        let sentence = ["Make"] + (2..<30).map { "w\($0)" } + ["end."]
        let words = ["Before."] + sentence + ["After."]
        XCTAssertEqual(try contexts(words, slots: [16, 32]), [sentence.joined(separator: " "), "After."])
    }

    func testSameTimeMarksDoNotBorrowFromTheNextSentence() throws {
        let words = ["Make", "these", "bigger.", "Then", "align", "the", "footer."]
        XCTAssertEqual(try contexts(words, slots: [3, 3, 5]),
                       ["Make these bigger.", "", "Then align the footer."])
    }

    func testHundredEarlierSentencesCannotLeakIntoSharedClause() throws {
        let words = (1...100).map { "Sentence\($0)." } + ["Make", "a", "b", "c", "d."]
        XCTAssertEqual(try contexts(words, slots: [102, 103]), ["Make a", "b c d."])
    }

    func testTranscriptBlockOpenersAreEscapedAndFixListSurvives() throws {
        let cases = [("1. item", "1\\. item"), ("12) item", "12\\) item"),
                     ("- item", "\\- item"), ("+ item", "\\+ item"), ("* item", "\\* item"),
                     ("---", "\\---"), ("+++", "\\+++"), ("***", "\\***"),
                     ("# heading", "\\# heading"), ("###### heading", "\\###### heading"),
                     ("```swift", "\\```swift"), ("~~~", "\\~~~"), ("___", "\\___"),
                     (">quote", "\\>quote"), ("<div>", "\\<div>"), ("</div>", "\\</div>"),
                     ("<!DOCTYPE html>", "\\<!DOCTYPE html>"), ("<?xml version>", "\\<?xml version>")]
        let frame = makeFrame()
        for (input, expected) in cases {
            let session = try Session(strokes: [makeStroke(1, at: 1, frameID: frame.id)], frames: [frame], words: [makeWord(input, 0, 1)])
            let text = MessageBuilder.build(session: session).text
            XCTAssertTrue(text.hasPrefix(expected + " [1]\n\n- [1]"), input)
            XCTAssertTrue(text.contains("\n\n- [1]"), input)
            XCTAssertEqual(TextSanitizer.markdownTranscript(input), expected)
        }
    }

    func testTranscriptSanitizerLeavesOrdinaryTextUnchanged() {
        for text in ["3.5 percent", "1.5x faster", "-5 degrees", "#1 priority", "<3 love", "``code``", "####### x",
                     "~tilde", "_under", "make <b> bold", "2024 was good"] {
            XCTAssertEqual(TextSanitizer.markdownTranscript(text), text)
        }
    }

    func testFractionalCapturePixelsAreRejectedAtomically() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 80))
        for size in [Size(width: 200.5, height: 160), Size(width: 200, height: 160.5)] {
            var session = try Session(frames: [frame])
            XCTAssertThrowsError(try session.completeFrame(id: frame.id, pixelSize: size, capturedAt: 1)) {
                XCTAssertEqual($0 as? Session.ValidationError, .invalidFrameCapture)
            }
            XCTAssertEqual(session.frames, [frame])
        }
    }

    func testDenormalizeRejectsDirectInvalidFrameMetadata() {
        for size in [Size(width: 0, height: 0), Size(width: -1, height: 20), Size(width: .infinity, height: 20)] {
            let frame = makeFrame(capturedAt: 1, pixels: size)
            XCTAssertNil(Geometry.denormalize(makePoint(), frame: frame))
        }
    }
    func testSealFinalizesPendingAndFreezesEveryMutation() throws {
        let pending = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 80))
        let failed = Frame(id: Frame.ID(), displayID: 2, boundsInPoints: pending.boundsInPoints)
        let complete = makeFrame()
        var session = try Session(frames: [pending, failed, complete], words: [makeWord("Fix!", 0, 1)])
        let mark = try session.beginStroke(at: 0, frame: pending.id, firstPoint: makePoint())
        _ = try session.beginStroke(at: 1, frame: failed.id, firstPoint: makePoint())
        _ = try session.beginStroke(at: 2, frame: complete.id, firstPoint: makePoint())
        try session.failFrame(id: failed.id)
        let before = MessageBuilder.build(session: session)
        XCTAssertEqual(before.pendingImages, [pending.id])
        XCTAssertEqual(before.failedImages, [failed.id])
        session.seal()
        XCTAssertTrue(session.isSealed)
        let snapshot = session
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.failedImages, [pending.id, failed.id])
        XCTAssertTrue(message.pendingImages.isEmpty)
        XCTAssertFalse(message.text.contains("screenshot pending"))
        XCTAssertEqual(message.framePlans.map(\.frameID), [complete.id])
        let attempts: [(inout Session) throws -> Void] = [
            { try $0.addFrame(makeFrame()) },
            { try $0.updateFrame(complete) },
            { try $0.completeFrame(id: pending.id, pixelSize: Size(width: 200, height: 160), capturedAt: 1) },
            { try $0.completeFrame(id: failed.id, pixelSize: Size(width: 200, height: 160), capturedAt: 1) },
            { try $0.completeFrame(id: complete.id, pixelSize: Size(width: 400, height: 320), capturedAt: 2) },
            { try $0.failFrame(id: pending.id) },
            { _ = try $0.beginStroke(at: 2, frame: pending.id, firstPoint: makePoint()) },
        ]
        for attempt in attempts {
            XCTAssertThrowsError(try attempt(&session)) { XCTAssertEqual($0 as? Session.ValidationError, .sealedSession) }
        }
        session.append(point: makePoint(1, 1), to: mark)
        session.endStroke(id: mark, at: 3)
        session.deleteMark(id: mark)
        session.words = [makeWord("Late recognition", 0, 1)]
        session.words.append(makeWord("Also late", 2, 3))
        session.seal()
        XCTAssertEqual(session, snapshot)
        XCTAssertEqual(MessageBuilder.build(session: session), message)
        var decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertThrowsError(try decoded.completeFrame(id: failed.id, pixelSize: Size(width: 200, height: 160), capturedAt: 1))
    }

    func testLegacySessionDefaultsToOpenAndSealedDecodeFinalizesPending() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 100, height: 80))
        let session = try Session(frames: [frame])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json.removeValue(forKey: "isSealed")
        var decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.isSealed)
        XCTAssertNoThrow(try decoded.beginStroke(at: 0, frame: frame.id, firstPoint: makePoint()))
        json["isSealed"] = true
        decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.frames[0].captureFailed)
        XCTAssertTrue(decoded.isSealed)
    }

    func testLegacyMissingImagesDecodesAsFailedAndNewOutcomesRoundTrip() throws {
        let id = Frame.ID()
        let json: [String: Any] = ["text": "legacy", "attachments": [], "missingImages": [id.uuidString]]
        let legacy = try JSONDecoder().decode(OutgoingMessage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.failedImages, [id])
        XCTAssertTrue(legacy.pendingImages.isEmpty)
        let message = OutgoingMessage(text: "new", attachments: [], pendingImages: [Frame.ID()], failedImages: [id])
        XCTAssertEqual(try JSONDecoder().decode(OutgoingMessage.self, from: JSONEncoder().encode(message)), message)
    }

    func testPlansCarryFrameIDsNamesAndFittedPixelSizes() throws {
        let a = makeFrame(points: Size(width: 2000, height: 1000), pixels: Size(width: 4000, height: 2000))
        let b = makeFrame(points: Size(width: 2000, height: 2000), pixels: Size(width: 8000, height: 8000))
        var session = try Session(strokes: [makeStroke(1, at: 0, frameID: b.id), makeStroke(2, at: 1, frameID: a.id)], frames: [a, b])
        session.seal()
        let message = MessageBuilder.build(session: session)
        XCTAssertEqual(message.framePlans.map(\.frameID), [b.id, a.id])
        XCTAssertEqual(message.framePlans.map(\.outputName), ["frame-1.png", "frame-2.png"])
        XCTAssertEqual(message.framePlans.map(\.outputSize), [PixelSize(width: 1248, height: 1248), PixelSize(width: 1600, height: 800)])
        XCTAssertEqual(message.cropPlans.map(\.sourceFrameID), [b.id, a.id])
        XCTAssertEqual(message.cropPlans.map(\.sourceFrameName), ["frame-1.png", "frame-2.png"])
        XCTAssertEqual(try JSONDecoder().decode(OutgoingMessage.self, from: JSONEncoder().encode(message)), message)
    }

    func testLegacyCropPlanDecodesWithoutInventingFrameIdentity() throws {
        let frame = makeFrame()
        let message = try MessageBuilder.build(session: Session(strokes: [makeStroke(1, at: 0, frameID: frame.id)], frames: [frame]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        var plans = try XCTUnwrap(json["cropPlans"] as? [[String: Any]])
        plans[0].removeValue(forKey: "sourceFrameID")
        json["cropPlans"] = plans
        json.removeValue(forKey: "framePlans")
        let decoded = try JSONDecoder().decode(OutgoingMessage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.cropPlans[0].sourceFrameID)
        XCTAssertEqual(decoded.cropPlans[0].sourcePixelRect, message.cropPlans[0].sourcePixelRect)
        XCTAssertTrue(decoded.framePlans.isEmpty)
    }

    func testTranscriptTimingDefaultsToEstimatedAndPreservesExplicitFlag() throws {
        let legacy = Data(#"{"text":"word","start":0,"end":1,"isFinal":true}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(TranscriptWord.self, from: legacy).isEstimated)
        XCTAssertTrue(makeWord("word", 0, 1).isEstimated)
        for estimated in [true, false] {
            let word = TranscriptWord(text: "word", start: 0, end: 1, isEstimated: estimated)
            XCTAssertEqual(try JSONDecoder().decode(TranscriptWord.self, from: JSONEncoder().encode(word)), word)
        }
    }

    func testTranscriptGuardsEachIndentedLine() {
        XCTAssertEqual(TextSanitizer.markdownTranscript("plain\n  ```swift\n\t~~~\n+ item\n12) item\n<div>"),
                       "plain\n  \\```swift\n\t\\~~~\n\\+ item\n12\\) item\n\\<div>")
    }

    func testDuplicatePenDownLeavesTheSecondMarkEmptyAndKeepsTheLaterSplit() throws {
        let words = (1...40).map { "w\($0)" }
        XCTAssertEqual(try contexts(words, slots: [20, 20, 24]),
                       [words[..<20].joined(separator: " "), "", words[20...].joined(separator: " ")])
    }

    func testMarkOnLastWordKeepsTheWordsSinceThePreviousSplit() throws {
        let sentence = (1...19).map { "x\($0)" } + ["end."]
        XCTAssertEqual(try contexts(sentence, slots: [2, 20]),
                       [sentence[..<2].joined(separator: " "), sentence[2...].joined(separator: " ")])
    }

    func testClauseAfterTheFirstGoesToItsOwnPenDown() throws {
        let second = (0..<29).map { "Y\($0)" } + ["end."]
        XCTAssertEqual(try contexts(["Earlier."] + second, slots: [0, 5]),
                       ["Earlier.", second.joined(separator: " ")])
    }

    func testAppWiringSequenceProducesStableSealedExportSnapshot() throws {
        var session = Session()
        // Synthetic offsets from the App's monotonic t0; no capture or clock APIs are needed.
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 800, height: 600))
        let origin = Point(x: -800, y: 0)
        try session.addFrame(frame)
        let point = try XCTUnwrap(Geometry.normalizedPoint(screenPoint: Point(x: -400, y: 300), frameOrigin: origin, frame: frame))
        let kept = try session.beginStroke(at: 1, frame: frame.id, firstPoint: point)
        session.append(point: makePoint(0.6, 0.6), to: kept)
        session.endStroke(id: kept, at: 1.5)
        let undone = try session.beginStroke(at: 2, frame: frame.id, firstPoint: point)
        session.deleteMark(id: undone)
        session.words = [makeWord("Fix this.", 0, 2)]
        try session.completeFrame(id: frame.id, pixelSize: Size(width: 1600, height: 1200), capturedAt: 1)
        session.seal()
        let preview = MessageBuilder.build(session: session)
        XCTAssertEqual(preview.framePlans.map(\.frameID), [frame.id])
        XCTAssertEqual(preview.cropPlans.map(\.sourceFrameID), [frame.id])
        XCTAssertEqual(preview.attachments, ["frame-1.png", "mark-1.png"])
        XCTAssertTrue(preview.text.contains("Fix this. [1]"))
        XCTAssertFalse(preview.text.contains("[2]"))
        XCTAssertThrowsError(try session.completeFrame(id: frame.id, pixelSize: Size(width: 3200, height: 2400), capturedAt: 3))
        XCTAssertEqual(MessageBuilder.build(session: session), preview)
    }

}
