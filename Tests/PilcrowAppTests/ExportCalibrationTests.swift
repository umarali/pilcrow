import XCTest
import Foundation
import CoreGraphics
import PilcrowCore
@testable import PilcrowApp

final class ExportCalibrationTests: XCTestCase {
    private func withFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    func testExportRecordsFramePointsTimesAndShapeWithoutAttachingCalibration() async throws {
        try await withFolder { folder in
            let size = Size(width: 800, height: 500)
            let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: size)
            let points = (0..<5001).map { i in NormalizedPoint(x: Double(i) / 5000, y: 0.24689123456789) }
            let stroke = Stroke(id: 17, frameID: frame.id, downTime: 1.25, upTime: 2.5,
                                points: points, badgeAnchor: points[0], shape: .mark)
            let deleted = Stroke(id: 18, frameID: frame.id, downTime: 3, upTime: 4,
                                 points: [points[0]], badgeAnchor: points[0], isDeleted: true, shape: .pin)
            let session = try Session(strokes: [stroke, deleted], frames: [frame])
            let message = MessageBuilder.build(session: session)
            let result = Export.write(session: session, message: message, originals: [:], to: folder)
            XCTAssertTrue(result.messageWritten)
            XCTAssertTrue(result.failedFiles.isEmpty)
            XCTAssertFalse(result.attachments.contains("strokes.json"))
            XCTAssertNil(result.imageData["strokes.json"])
            let data = try Data(contentsOf: folder.appendingPathComponent("strokes.json"))
            XCTAssertLessThan(data.count, Export.strokeDataLimit)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["version"] as? Int, 3)
            XCTAssertEqual(object["recognizerVersion"] as? String, ShapeRecognizer.version)
            let records = try XCTUnwrap(object["strokes"] as? [[String: Any]])
            XCTAssertEqual(records.count, 1)
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record["id"] as? Int, 17)
            XCTAssertEqual(record["frameID"] as? String, frame.id.uuidString)
            let frameSize = try XCTUnwrap(record["frameSize"] as? [String: Double])
            XCTAssertEqual(frameSize, ["width": 800, "height": 500])
            XCTAssertEqual(record["downTime"] as? Double, 1.25)
            XCTAssertEqual(record["upTime"] as? Double, 2.5)
            let shapeData = try JSONSerialization.data(withJSONObject: XCTUnwrap(record["shape"]))
            XCTAssertEqual(try JSONDecoder().decode(MarkShape.self, from: shapeData), .mark)
            let samples = try XCTUnwrap(record["points"] as? [[String: Double]])
            XCTAssertEqual(record["originalPointCount"] as? Int, 5001)
            XCTAssertEqual(record["decimated"] as? Bool, true)
            XCTAssertEqual(record["resampleMethod"] as? String, "uniform-index")
            XCTAssertTrue(record["displayScale"] is NSNull)
            XCTAssertEqual(samples.count, 5000)
            XCTAssertEqual(samples.first, ["x": 0, "y": points[0].y * 500])
            XCTAssertEqual(samples.last, ["x": 800, "y": points[0].y * 500])
            for (index, sample) in samples.enumerated() {
                let source = Int((Double(index) * 5000 / 4999).rounded())
                XCTAssertEqual(try XCTUnwrap(sample["x"]), points[source].x * 800)
                XCTAssertEqual(try XCTUnwrap(sample["y"]), points[source].y * 500)
            }
            let manifest = OutboxManifest(id: UUID(), createdAt: Date(), destination: .mcp,
                                          text: message.text, attachments: [])
            XCTAssertFalse(String(decoding: try OutboxManifest.encoder().encode(manifest), as: UTF8.self).contains("strokes.json"))
            XCTAssertFalse(DeliveryText.message(approvedText: message.text, imagePaths: result.attachments).contains("strokes.json"))
            XCTAssertEqual(session.strokes[0].points, points, "Recording must preserve the session's original samples")
        }
    }

    func testVoiceRecordingKeepsOrderedResultsAndFinalWordsLocal() async throws {
        try await withFolder { folder in
            var session = Session()
            let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 800, height: 500))
            try session.addFrame(frame)
            let mark = try session.beginStroke(at: 1, frame: frame.id, firstPoint: NormalizedPoint(x: 0.2, y: 0.3))
            session.endStroke(id: mark, at: 1.4)
            let word = TranscriptWord(text: "Here", start: 0.2, end: 0.7, isEstimated: false)
            session.words = [word, TranscriptWord(text: "draft", start: 1.6, end: 2, isFinal: false)]
            var events = VoiceRecording.Results()
            events.append(.init(start: 0.1, end: 0.5, isFinal: false, finalWords: nil))
            events.append(.init(start: 0.1, end: 0.8, isFinal: true, finalWords: [word]))
            // The raw result trace keeps even a repeated final result suppressed by the transcript.
            events.append(.init(start: 0.1, end: 0.8, isFinal: true, finalWords: [word]))

            let message = MessageBuilder.build(session: session)
            let result = Export.write(session: session, message: message, originals: [:], to: folder,
                                      voiceResults: events)
            let url = folder.appendingPathComponent("debug/voice.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("voice.json").path))
            let data = try Data(contentsOf: url)
            let recording = try JSONDecoder().decode(VoiceRecording.self, from: data)
            XCTAssertLessThan(data.count, 1_000_000)
            XCTAssertEqual(recording.finalWords, [word])
            XCTAssertEqual(recording.results.map(\.isFinal), [false, true, true])
            XCTAssertEqual(recording.results.map(\.end), [0.5, 0.8, 0.8])
            XCTAssertEqual(recording.results.last?.finalWords, [word])
            XCTAssertFalse(recording.resultsTruncated)
            XCTAssertEqual(recording.marks.map(\.id), [mark])
            XCTAssertEqual(recording.marks.first?.downTime, 1)
            XCTAssertEqual(recording.marks.first?.upTime, 1.4)
            XCTAssertFalse(result.attachments.contains("voice.json"))
            XCTAssertNil(result.imageData["voice.json"])
            let agentText = DeliveryText.message(approvedText: message.text, imagePaths: result.attachments)
            XCTAssertFalse(agentText.contains("voice.json"))
        }
    }

    func testVoiceRecordingFlagsTruncatedResults() async throws {
        try await withFolder { folder in
            var events = VoiceRecording.Results()
            events.append(.init(start: 0, end: 1, isFinal: false, finalWords: nil))
            let oversized = TranscriptWord(text: String(repeating: "a", count: 500_000), start: 1, end: 2)
            events.append(.init(start: 1, end: 2, isFinal: true, finalWords: [oversized]))
            let session = Session()
            _ = Export.write(session: session, message: MessageBuilder.build(session: session), originals: [:],
                             to: folder, voiceResults: events)
            let data = try Data(contentsOf: folder.appendingPathComponent("debug/voice.json"))
            let recording = try JSONDecoder().decode(VoiceRecording.self, from: data)
            XCTAssertLessThan(data.count, 1_000_000)
            XCTAssertEqual(recording.results.count, 1)
            XCTAssertTrue(recording.resultsTruncated)
        }
    }

    func testStrokeExportKeepsTheAbsorbedVWithoutAnExtraFixLine() throws {
        var session = Session()
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 800, height: 500))
        try session.addFrame(frame)
        func draw(_ points: [NormalizedPoint], at down: Double) throws -> MarkID {
            let id = try session.beginStroke(at: down, frame: frame.id, firstPoint: points[0])
            for point in points.dropFirst() { session.append(point: point, to: id) }
            session.endStroke(id: id, at: down + 0.5)
            return id
        }
        let shaft = try draw([.init(x: 0.1, y: 0.5), .init(x: 0.5, y: 0.5)], at: 0)
        let head = try draw([.init(x: 0.475, y: 0.47), .init(x: 0.5, y: 0.5), .init(x: 0.475, y: 0.53)], at: 1)
        let recording = try JSONDecoder().decode(StrokeRecording.self, from: Export.strokeData(session: session))
        XCTAssertEqual(recording.strokes.first?.id, shaft)
        XCTAssertLessThan(try XCTUnwrap(recording.strokes.last?.id.rawValue), 0)
        XCTAssertEqual(session.nextMarkNumber, head.rawValue)
        XCTAssertEqual(recording.strokes.last?.absorbedInto, shaft)
        XCTAssertEqual(recording.strokes.last?.points.count, 3)
        let message = MessageBuilder.build(session: session)
        XCTAssertTrue(message.text.contains("- [1] (arrow) → mark-1.png"))
        XCTAssertFalse(message.text.contains("[2]"))
    }

    func testSmallAndEmptyStrokesKeepOriginalSamplesAndOptionalClassification() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 800, height: 500))
        let points = [NormalizedPoint(x: -0.01234, y: 1.12345), NormalizedPoint(x: 0.12345, y: 0.5)]
        let strokes = [Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: nil, points: points, badgeAnchor: points[0]),
                       Stroke(id: 2, frameID: frame.id, downTime: 1, upTime: nil, points: [], badgeAnchor: points[0])]
        let data = try Export.strokeData(session: Session(strokes: strokes, frames: [frame]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(object["strokes"] as? [[String: Any]])
        XCTAssertEqual(records[0]["points"] as? [[String: Double]], points.map { ["x": $0.x * 800, "y": $0.y * 500] })
        XCTAssertEqual(records[0]["originalPointCount"] as? Int, 2)
        XCTAssertEqual(records[0]["decimated"] as? Bool, false)
        XCTAssertEqual(records[0]["resampleMethod"] as? String, "none")
        XCTAssertNil(records[0]["shape"])
        XCTAssertNil(records[0]["upTime"])
        XCTAssertEqual((records[1]["points"] as? [Any])?.count, 0)
    }

    func testCalibrationSurvivesRecoveryAndOutboxPublication() async throws {
        try await withFolder { parent in
            let source = parent.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let bytes = Data("{\"version\":1,\"strokes\":[]}".utf8)
            try bytes.write(to: source.appendingPathComponent("strokes.json"))
            let voice = Data(#"{"version":1,"results":[],"finalWords":[],"marks":[],"resultsTruncated":false}"#.utf8)
            try voice.write(to: source.appendingPathComponent("voice.json"))
            var session = Session()
            let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 800, height: 500))
            try session.addFrame(frame)
            let pin = try session.beginStroke(at: 0, frame: frame.id, firstPoint: NormalizedPoint(x: 0.2, y: 0.3))
            session.endStroke(id: pin, at: 0.5)
            let message = MessageBuilder.build(session: session)
            let result = Export.write(session: session, message: message, originals: [:], to: parent)
            XCTAssertTrue(result.messageWritten)
            let approval = ApprovalExport(id: UUID(), folder: source, text: message.text, attachments: [],
                                          imageData: [], marks: [], spokenSummary: "", hudAnchor: .zero,
                                          finishStartedAt: 0)
            let exports = ExportStore(temporary: parent)
            let recovered = try await exports.recover(approval)
            XCTAssertEqual(try Data(contentsOf: recovered.folder.appendingPathComponent("strokes.json")), bytes)
            XCTAssertEqual(try Data(contentsOf: recovered.folder.appendingPathComponent("debug/voice.json")), voice)
            let root = parent.appendingPathComponent("Pilcrow/Outbox")
            let store = OutboxStore(root: root)
            // Injectable root's Application Support parent is our disposable parent.
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: false)
            _ = try await store.prepare(approval.id)
            let item = try await store.create(recovered, imageData: [], destination: .clipboard, project: nil,
                                               shellPath: "/bin/zsh")
            XCTAssertEqual(try Data(contentsOf: item.appendingPathComponent("strokes.json")), bytes)
            XCTAssertEqual(try Data(contentsOf: item.appendingPathComponent("debug/voice.json")), voice)
            let agentMessage = try String(contentsOf: item.appendingPathComponent("message-for-agent.md"), encoding: .utf8)
            let exportedMessage = try String(contentsOf: parent.appendingPathComponent("message.md"), encoding: .utf8)
            XCTAssertEqual(agentMessage, exportedMessage)
            XCTAssertTrue(agentMessage.contains("- [1] (point) → mark-1.png"))
            let manifest = try OutboxManifest.decoder().decode(OutboxManifest.self,
                from: Data(contentsOf: item.appendingPathComponent("manifest.json")))
            XCTAssertTrue(manifest.attachments.isEmpty)
            await exports.discard(recovered.folder)
        }
    }

    func testCalibrationCopyRejectsLinksAndToleratesLegacyAbsence() async throws {
        try await withFolder { parent in
            let source = parent.appendingPathComponent("source"), target = parent.appendingPathComponent("target")
            for folder in [source, target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
            Export.copyCalibrationData(from: source, to: target)
            let outside = parent.appendingPathComponent("other.json")
            try Data("private".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("strokes.json"), withDestinationURL: outside)
            Export.copyCalibrationData(from: source, to: target)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("strokes.json").path))
            try Data("private".utf8).write(to: parent.appendingPathComponent("voice.json"))
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("debug"), withDestinationURL: parent)
            Export.copyCalibrationData(from: source, to: target)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("debug/voice.json").path))
        }
    }
    func testCalibrationWriteFailureDoesNotCountAsDeliveryFailure() async throws {
        try await withFolder { folder in
            // A directory at each optional file path makes the atomic write fail.
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("debug"),
                                                    withIntermediateDirectories: false)
            for name in ["strokes.json", "debug/voice.json"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name),
                                                        withIntermediateDirectories: false)
            }
            let session = Session()
            let result = Export.write(session: session, message: MessageBuilder.build(session: session),
                                      originals: [:], to: folder)
            XCTAssertTrue(result.messageWritten)
            XCTAssertTrue(result.failedFiles.isEmpty)
        }
    }

    func testBrokenCalibrationDoesNotBlockRecoveryOrPublication() async throws {
        try await withFolder { parent in
            let source = parent.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("strokes.json"),
                                                    withIntermediateDirectories: false)
            let approval = ApprovalExport(id: UUID(), folder: source, text: "Synthetic text", attachments: [],
                                          imageData: [], marks: [], spokenSummary: "", hudAnchor: .zero,
                                          finishStartedAt: 0)
            let exports = ExportStore(temporary: parent)
            let recovered = try await exports.recover(approval)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.folder.appendingPathComponent("message-for-agent.md").path))
            let root = parent.appendingPathComponent("Pilcrow/Outbox")
            let store = OutboxStore(root: root)
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: false)
            // Use the broken original, so publication independently exercises copy failure.
            let item = try await store.create(approval, imageData: [], destination: .clipboard, project: nil,
                                              shellPath: "/bin/zsh")
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.appendingPathComponent("manifest.json").path))
            await exports.discard(recovered.folder)
        }
    }

    func testNonDecimatedExportReplaysLiveClassificationExactly() throws {
        let frame = Frame(id: Frame.ID(), capturedAt: 0, displayID: 1,
                          boundsInPoints: Size(width: 1512, height: 982),
                          pixelSize: Size(width: 3024, height: 1964))
        var session = Session()
        try session.addFrame(frame)
        let ellipse = (0...160).map { i -> NormalizedPoint in
            let angle = Double(i) * 2 * .pi / 160
            return NormalizedPoint(x: (310.123456789 + 87.23456789 * cos(angle)) / 1512,
                                   y: (220.987654321 + 43.87654321 * sin(angle)) / 982)
        }
        let id = try session.beginStroke(at: 1, frame: frame.id, firstPoint: ellipse[0])
        for point in ellipse.dropFirst() { session.append(point: point, to: id) }
        session.endStroke(id: id, at: 2)
        let data = try Export.strokeData(session: session)
        let recording = try JSONDecoder().decode(StrokeRecording.self, from: data)
        let record = try XCTUnwrap(recording.strokes.first)
        guard case .area(.ellipse) = session.strokes[0].shape else { return XCTFail("Expected live ellipse") }
        XCTAssertFalse(record.decimated)
        XCTAssertEqual(record.originalPointCount, ellipse.count)
        XCTAssertEqual(record.displayScale, 2)
        XCTAssertEqual(record.points, ellipse.map { Point(x: $0.x * 1512, y: $0.y * 982) })
        XCTAssertEqual(record.replay(), session.strokes[0].shape)
        XCTAssertEqual(record.replay(), record.shape)
    }

    func testTotalRecordingCapSkipsOptionalFileAndOversizedCopy() async throws {
        try await withFolder { parent in
            let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: Size(width: 1512, height: 982))
            let points = (0..<5000).map { i in
                NormalizedPoint(x: Double(i) / 5001.1234567, y: Double(i) / 7001.7654321)
            }
            let strokes = (1...50).map { id in
                Stroke(id: MarkID(rawValue: id), frameID: frame.id, downTime: Double(id), upTime: Double(id) + 0.5,
                       points: points, badgeAnchor: points[0], shape: .mark)
            }
            let session = try Session(strokes: strokes, frames: [frame])
            XCTAssertThrowsError(try Export.strokeData(session: session))
            let result = Export.write(session: session, message: MessageBuilder.build(session: session),
                                      originals: [:], to: parent)
            XCTAssertTrue(result.messageWritten)
            XCTAssertTrue(result.failedFiles.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("strokes.json").path))

            let source = parent.appendingPathComponent("source"), target = parent.appendingPathComponent("target")
            for folder in [source, target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
            let url = source.appendingPathComponent("strokes.json")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(Export.strokeDataLimit + 1))
            try handle.close()
            Export.copyCalibrationData(from: source, to: target)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("strokes.json").path))
        }
    }

}
