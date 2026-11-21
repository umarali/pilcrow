import XCTest
import Foundation
import Darwin
import PilcrowCore
@testable import PilcrowMCP

final class ServerTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private var png: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXQAAAAASUVORK5CYII=")! }
    @discardableResult private func item(_ root: URL, date: Date = Date(), destination: Destination = .mcp, attachments: [OutboxManifest.Attachment] = [], text: String = "Words [1]\n\n- [1] \"Words\" → mark-1.png (in frame.png)") throws -> OutboxManifest {
        let manifest = OutboxManifest(createdAt: date, destination: destination, text: text, attachments: attachments)
        let dir = root.appendingPathComponent(manifest.id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try OutboxManifest.encoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for a in attachments where !a.name.contains("/") && !a.name.contains("..") && !a.name.contains("\0") && a.name != "manifest.json" { try png.write(to: dir.appendingPathComponent(a.name)) }
        return manifest
    }
    private func request(_ server: Server, _ value: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(server.handle(data))) as? [String: Any])
    }
    private func call(_ server: Server, _ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        try XCTUnwrap(request(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])["result"] as? [String: Any])
    }
    private func contents(_ result: [String: Any]) throws -> [[String: Any]] { try XCTUnwrap(result["content"] as? [[String: Any]]) }
    func testProtocol() throws {
        try withRoot { root in
            let s = Server(root: root)
            let initialized = try XCTUnwrap(request(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize"])["result"] as? [String: Any])
            XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-11-25")
            XCTAssertEqual((initialized["serverInfo"] as? [String: String])?["version"], PilcrowCore.version)
            let list = try XCTUnwrap(request(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])["result"] as? [String: Any])
            let tools = try XCTUnwrap(list["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["pilcrow_latest", "pilcrow_list", "pilcrow_get"])
            let schema = try XCTUnwrap(tools.last?["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["required"] as? [String], ["id"])
            XCTAssertEqual(((schema["properties"] as? [String: [String: String]])?["mark"])?["type"], "integer")
            XCTAssertNotNil(try request(s, ["jsonrpc": "2.0", "id": 3, "method": "ping"])["result"])
            XCTAssertEqual((try request(s, ["jsonrpc": "2.0", "id": 4, "method": "nope"])["error"] as? [String: Any])?["code"] as? Int, -32601)
            let malformed = try XCTUnwrap(s.handle(Data("{".utf8)))
            XCTAssertEqual(((try JSONSerialization.jsonObject(with: malformed) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int, -32700)
            XCTAssertNil(s.handle(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)))
        }
    }
    func testToolsAndOrdering() throws {
        try withRoot { root in
            let attachments: [OutboxManifest.Attachment] = [.init(name: "frame-1.png", kind: .frame), .init(name: "mark-2.png", kind: .crop, mark: 2), .init(name: "mark-1.png", kind: .crop, mark: 1)]
            _ = try item(root, date: Date().addingTimeInterval(-50))
            let latest = try item(root, attachments: attachments, text: "Text\n- [1] first\n- [2] second")
            let dir = root.appendingPathComponent(latest.id.uuidString)
            try (png + Data([1])).write(to: dir.appendingPathComponent("mark-1.png")); try (png + Data([2])).write(to: dir.appendingPathComponent("mark-2.png")); try (png + Data([3])).write(to: dir.appendingPathComponent("frame-1.png"))
            let s = Server(root: root)
            let blocks = try contents(call(s, "pilcrow_latest"))
            XCTAssertEqual(blocks.first?["text"] as? String, latest.text)
            XCTAssertEqual(blocks.dropFirst().compactMap { $0["data"] as? String }, [png + Data([1]), png + Data([2]), png + Data([3])].map { $0.base64EncodedString() })
            XCTAssertTrue(blocks.dropFirst().allSatisfy { $0["mimeType"] as? String == "image/png" })
            let listing = try XCTUnwrap(contents(call(s, "pilcrow_list")).first?["text"] as? String)
            XCTAssertTrue(listing.hasPrefix(latest.id.uuidString)); XCTAssertTrue(listing.contains("2 marks"))
            let single = try contents(call(s, "pilcrow_get", ["id": latest.id.uuidString, "mark": 2]))
            XCTAssertEqual(single.first?["text"] as? String, "- [2] second"); XCTAssertEqual(single.count, 2)
            XCTAssertEqual(try contents(call(s, "pilcrow_get", ["id": latest.id.uuidString])).count, 4)
            XCTAssertEqual(try call(s, "pilcrow_get", ["id": "missing"])["isError"] as? Bool, true)
            XCTAssertEqual(try call(s, "pilcrow_get", ["id": latest.id.uuidString, "mark": 999])["isError"] as? Bool, true)
        }
    }
    func testLocalStrokeCalibrationIsIgnoredAndCannotBecomeAnAttachment() throws {
        try withRoot { root in
            let manifest = try item(root, attachments: [.init(name: "frame-1.png", kind: .frame),
                                                       .init(name: "strokes.json", kind: .crop, mark: 1)])
            let folder = root.appendingPathComponent(manifest.id.uuidString)
            let secret = "LOCAL-STROKE-POINTS-ONLY"
            try Data(secret.utf8).write(to: folder.appendingPathComponent("strokes.json"))
            let server = Server(root: root)
            let blocks = try contents(call(server, "pilcrow_latest"))
            XCTAssertEqual(blocks.count, 2)
            XCTAssertEqual(blocks.last?["data"] as? String, png.base64EncodedString())
            let listing = try XCTUnwrap(contents(call(server, "pilcrow_list")).first?["text"] as? String)
            XCTAssertTrue(listing.contains(manifest.id.uuidString))
            XCTAssertFalse(listing.contains("strokes.json"))
            let response = try JSONSerialization.data(withJSONObject: blocks)
            XCTAssertFalse(String(decoding: response, as: UTF8.self).contains(secret))
        }
    }
    func testFilteringAndEmpty() throws {
        try withRoot { root in
            let s = Server(root: root)
            XCTAssertEqual(try contents(call(s, "pilcrow_latest")).first?["text"] as? String, Server.empty)
            _ = try item(root, date: Date().addingTimeInterval(-90000))
            let invalid = try item(root)
            let invalidPath = root.appendingPathComponent(invalid.id.uuidString).appendingPathComponent("manifest.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: invalidPath)) as? [String: Any]); object["version"] = 2
            try JSONSerialization.data(withJSONObject: object).write(to: invalidPath)
            let hidden = try item(root, destination: .mcp)
            let hiddenDir = root.appendingPathComponent(hidden.id.uuidString)
            let parent = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let external = parent.appendingPathComponent("item")
            try FileManager.default.moveItem(at: hiddenDir, to: external)
            try FileManager.default.createSymbolicLink(at: hiddenDir, withDestinationURL: external)
            XCTAssertEqual(try contents(call(s, "pilcrow_list")).first?["text"] as? String, Server.empty)
            let attachments: [OutboxManifest.Attachment] = [.init(name: "frame-1.png", kind: .frame), .init(name: "frame-2.png", kind: .frame), .init(name: "../bad.png", kind: .frame), .init(name: "frame-3.png", kind: .frame)]
            let valid = try item(root, attachments: attachments)
            let dir = root.appendingPathComponent(valid.id.uuidString)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("frame-2.png"))
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("frame-2.png").path, withDestinationPath: "frame-1.png")
            try Data(repeating: 0, count: 10_000_001).write(to: dir.appendingPathComponent("frame-3.png"))
            XCTAssertEqual(try contents(call(s, "pilcrow_latest")).count, 3)
        }
    }
    func testEveryDestinationIsAvailableWithoutPublishingToMCP() throws {
        for destination in Destination.allCases {
            try withRoot { root in
                let manifest = try item(root, destination: destination)
                let server = Server(root: root)
                XCTAssertEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, manifest.text)
                XCTAssertTrue(try XCTUnwrap(contents(call(server, "pilcrow_list")).first?["text"] as? String).contains(manifest.id.uuidString))
                XCTAssertEqual(try contents(call(server, "pilcrow_get", ["id": manifest.id.uuidString])).first?["text"] as? String, manifest.text)
            }
        }
    }
    func testDiscardedAndClearedClipboardCapturesAreNotServed() throws {
        try withRoot { root in
            let manifest = try item(root, destination: .clipboard)
            let folder = root.appendingPathComponent(manifest.id.uuidString)
            let server = Server(root: root)
            XCTAssertEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, manifest.text)
            // OutboxStore.beginDiscard unpublishes using this rename before deleting.
            let staged = root.appendingPathComponent(".discarded-" + manifest.id.uuidString)
            try FileManager.default.moveItem(at: folder, to: staged)
            XCTAssertEqual(try contents(call(server, "pilcrow_list")).first?["text"] as? String, Server.empty)
            XCTAssertEqual(try call(server, "pilcrow_get", ["id": manifest.id.uuidString])["isError"] as? Bool, true)
            try FileManager.default.removeItem(at: staged)
            let cleared = try item(root, destination: .clipboard)
            // Settings Clear removes eligible UUID directories, leaving no manifest to serve.
            try FileManager.default.removeItem(at: root.appendingPathComponent(cleared.id.uuidString))
            XCTAssertEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, Server.empty)
            XCTAssertEqual(try call(server, "pilcrow_get", ["id": cleared.id.uuidString])["isError"] as? Bool, true)
        }
    }

    func testDiscardBetweenListingAndServingDoesNotReturnClipboardCapture() throws {
        try withRoot { root in
            let manifest = try item(root, destination: .clipboard, attachments: [.init(name: "mark-1.png", kind: .crop, mark: 1)])
            var server = Server(root: root)
            server.beforeServing = {
                try? FileManager.default.moveItem(at: root.appendingPathComponent(manifest.id.uuidString),
                    to: root.appendingPathComponent(".discarded-" + manifest.id.uuidString))
            }
            XCTAssertEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, Server.empty)
        }
    }
    func testRetentionUsesRequestTime() throws {
        try withRoot { root in
            let date = Date()
            _ = try item(root, date: date)
            var server = Server(root: root, now: date.addingTimeInterval(100))
            XCTAssertNotEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, Server.empty)
            server.now = date.addingTimeInterval(86401)
            XCTAssertEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, Server.empty)
        }
    }
    func testListLimit() throws {
        try withRoot { root in
            for i in 0..<23 { _ = try item(root, date: Date().addingTimeInterval(Double(-i))) }
            let listing = try XCTUnwrap(contents(call(Server(root: root), "pilcrow_list")).first?["text"] as? String)
            XCTAssertEqual(listing.components(separatedBy: "\n").count, 20)
        }
    }
    func testNegotiationMetadataAndInvalidRequests() throws {
        try withRoot { root in
            let server = Server(root: root)
            for version in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "unknown"] {
                let result = try XCTUnwrap(request(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": version]])["result"] as? [String: Any])
                XCTAssertEqual(result["protocolVersion"] as? String, version == "unknown" ? "2025-11-25" : version)
                XCTAssertNotNil(result["instructions"] as? String)
            }
            let tools = try XCTUnwrap((request(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            for tool in tools {
                XCTAssertNotNil(tool["title"] as? String)
                XCTAssertTrue((tool["description"] as? String ?? "").contains("badge"))
                let annotations = try XCTUnwrap(tool["annotations"] as? [String: Bool])
                XCTAssertEqual(annotations["readOnlyHint"], true); XCTAssertEqual(annotations["openWorldHint"], false)
            }
            for (method, code) in [("server/discover", -32601), ("tools/call", -32602)] {
                let response = try request(server, ["jsonrpc": "2.0", "id": 1, "method": method, "params": ["name": "unknown"]])
                XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, code)
            }
            for id: Any in [1.5, true, NSNull(), [1]] {
                XCTAssertEqual((try request(server, ["jsonrpc": "2.0", "id": id, "method": "ping"])["error"] as? [String: Any])?["code"] as? Int, -32600)
            }
            let batch = try XCTUnwrap(server.handle(Data("[]".utf8)))
            XCTAssertEqual(((try JSONSerialization.jsonObject(with: batch) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int, -32600)
            XCTAssertEqual(try call(server, "pilcrow_latest", ["extra": 1])["isError"] as? Bool, true)
            XCTAssertEqual(try call(server, "pilcrow_get", ["id": 1])["isError"] as? Bool, true)
        }
    }
    func testAttachmentSecurityAndFolderIdentity() throws {
        try withRoot { root in
            let names = ["frame-1.png", "frame-2.png", "frame-3.png", "frame-4.png", "frame-5.png", "manifest.json", "frame-6.png\0suffix", "../frame-8.png", "sub/../frame-8.png"]
            let manifest = try item(root, attachments: names.map { .init(name: $0, kind: .frame) })
            let dir = root.appendingPathComponent(manifest.id.uuidString)
            let external = root.appendingPathComponent("outside.png"); try png.write(to: external)
            try png.write(to: root.appendingPathComponent("frame-8.png"))
            try png.write(to: dir.appendingPathComponent("frame-6.png"))
            try FileManager.default.removeItem(at: dir.appendingPathComponent("frame-1.png"))
            XCTAssertEqual(link(external.path, dir.appendingPathComponent("frame-1.png").path), 0)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("frame-2.png"))
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("frame-2.png").path, withDestinationPath: external.path)
            try Data("not a PNG".utf8).write(to: dir.appendingPathComponent("frame-3.png"))
            try FileManager.default.removeItem(at: dir.appendingPathComponent("frame-4.png"))
            XCTAssertEqual(mkfifo(dir.appendingPathComponent("frame-4.png").path, 0o600), 0)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("frame-5.png"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("frame-5.png"), withIntermediateDirectories: false)
            let server = Server(root: root)
            let listing = try XCTUnwrap(contents(call(server, "pilcrow_list")).first?["text"] as? String)
            XCTAssertTrue(listing.contains("frame-3.png"), "Listing must not read the non-PNG file")
            let served = try contents(call(server, "pilcrow_latest"))
            XCTAssertEqual(served.count, 2)
            XCTAssertTrue(served.compactMap { $0["text"] as? String }.joined().contains("Image unavailable: frame-3.png (\(dir.appendingPathComponent("frame-3.png").path))"))
            XCTAssertEqual(chmod(dir.path, 0o720), 0)
            XCTAssertEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, Server.empty)
            XCTAssertEqual(chmod(dir.path, 0o700), 0)
            let mismatch = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: dir, to: mismatch)
            XCTAssertEqual(try contents(call(server, "pilcrow_latest")).first?["text"] as? String, Server.empty)
        }
    }
    func testPayloadBudgetAndListMetadataOnly() throws {
        try withRoot { root in
            let attachments: [OutboxManifest.Attachment] = [.init(name: "frame-1.png", kind: .frame), .init(name: "frame-2.png", kind: .frame), .init(name: "mark-1.png", kind: .crop, mark: 1)]
            let manifest = try item(root, attachments: attachments)
            let dir = root.appendingPathComponent(manifest.id.uuidString)
            // Sparse, valid-signature files: one individually too large and one exceeds the remaining budget.
            for (name, size) in [("frame-1.png", 7_500_001), ("frame-2.png", 7_499_970)] {
                let url = dir.appendingPathComponent(name)
                let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: UInt64(size)); try handle.close()
            }
            let server = Server(root: root)
            let listing = try XCTUnwrap(contents(call(server, "pilcrow_list")).first?["text"] as? String)
            XCTAssertTrue(listing.contains("frame-1.png")); XCTAssertTrue(listing.contains("frame-2.png"))
            let blocks = try contents(call(server, "pilcrow_latest"))
            XCTAssertEqual(blocks.filter { $0["type"] as? String == "image" }.count, 1)
            XCTAssertEqual(blocks.compactMap { $0["data"] as? String }.reduce(0) { $0 + $1.utf8.count }, png.base64EncodedString().utf8.count)
            let omitted = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertTrue(omitted.contains(dir.appendingPathComponent("frame-1.png").path))
            XCTAssertTrue(omitted.contains(dir.appendingPathComponent("frame-2.png").path))
        }
    }
    func testJSONSerializationKeepsNearBudgetResponseWithinLineLimit() throws {
        try withRoot { root in
            let manifest = try item(root, attachments: [.init(name: "frame-1.png", kind: .frame)])
            let file = root.appendingPathComponent(manifest.id.uuidString).appendingPathComponent("frame-1.png")
            var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
            data.append(Data(repeating: 255, count: 7_500_000 - data.count))
            try data.write(to: file)
            let requestData = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "pilcrow_latest"]])
            let response = try XCTUnwrap(Server(root: root).handle(requestData))
            let line = String(decoding: response, as: UTF8.self)
            XCTAssertFalse(line.contains("\\/"))
            XCTAssertLessThanOrEqual(response.count, Server.maxBase64Bytes + 64_000)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            let blocks = try contents(result)
            let encoded = try XCTUnwrap(blocks.first { $0["type"] as? String == "image" }?["data"] as? String)
            XCTAssertEqual(encoded.utf8.count, Server.maxBase64Bytes)
            XCTAssertGreaterThan(encoded.filter { $0 == "/" }.count, 1_000_000)
        }
    }
    func testImageUnavailableForInvalidPNGAndChangedSize() throws {
        try withRoot { root in
            let attachments: [OutboxManifest.Attachment] = [.init(name: "frame-1.png", kind: .frame), .init(name: "frame-2.png", kind: .frame)]
            let manifest = try item(root, attachments: attachments)
            let dir = root.appendingPathComponent(manifest.id.uuidString)
            try Data("not png".utf8).write(to: dir.appendingPathComponent("frame-1.png"))
            var server = Server(root: root)
            server.beforeAttachmentRead = { name in
                if name == "frame-2.png" { try? (self.png + Data([1])).write(to: dir.appendingPathComponent(name)) }
            }
            let blocks = try contents(call(server, "pilcrow_latest"))
            let messages = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertTrue(messages.contains("Image unavailable: frame-1.png (\(dir.appendingPathComponent("frame-1.png").path))"))
            XCTAssertTrue(messages.contains("Image unavailable: frame-2.png (\(dir.appendingPathComponent("frame-2.png").path))"))
            XCTAssertFalse(blocks.contains { $0["type"] as? String == "image" })
        }
    }
    func testServingSkipsReplacedItemFolder() throws {
        try withRoot { root in
            let manifest = try item(root, attachments: [.init(name: "frame-1.png", kind: .frame)])
            let dir = root.appendingPathComponent(manifest.id.uuidString)
            let heldFD = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(heldFD, 0)
            defer { close(heldFD) }
            var server = Server(root: root)
            server.beforeServing = {
                let replacement = root.appendingPathComponent("replacement")
                try? FileManager.default.copyItem(at: dir, to: replacement)
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.moveItem(at: replacement, to: dir)
            }
            let blocks = try contents(call(server, "pilcrow_latest"))
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks.first?["text"] as? String, Server.empty)
        }
    }
    func testListingDoesNotReadImagesAndOmitsNonRegularFiles() throws {
        try withRoot { root in
            let attachments: [OutboxManifest.Attachment] = [
                .init(name: "frame-1.png", kind: .frame), .init(name: "frame-2.png", kind: .frame), .init(name: "frame-3.png", kind: .frame)
            ]
            let manifest = try item(root, attachments: attachments)
            let dir = root.appendingPathComponent(manifest.id.uuidString)
            XCTAssertEqual(chmod(dir.appendingPathComponent("frame-1.png").path, 0o000), 0)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("frame-2.png"))
            XCTAssertEqual(mkfifo(dir.appendingPathComponent("frame-2.png").path, 0o600), 0)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("frame-3.png"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("frame-3.png"), withIntermediateDirectories: false)

            let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("pilcrow-mcp")
            let process = Process(); process.executableURL = executable
            process.environment = ["PILCROW_OUTBOX_DIR": root.path]
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"pilcrow_list\"}}\n".utf8))
            try input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let finished = !process.isRunning
            if !finished { process.terminate() }
            process.waitUntilExit()
            XCTAssertTrue(finished, "Listing blocked while inspecting an image")
            let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(response.contains("frame-1.png"), "Listing must include unreadable regular files without reading them")
            XCTAssertFalse(response.contains("frame-2.png"), "Listing must hide FIFO attachments")
            XCTAssertFalse(response.contains("frame-3.png"), "Listing must hide directory attachments")
        }
    }
    func testOtherWritableFoldersRejected() throws {
        try withRoot { root in
            _ = try item(root)
            let dir = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
            let server = Server(root: root)
            for mode: mode_t in [0o702, 0o707] {
                XCTAssertEqual(chmod(dir.path, mode), 0)
                XCTAssertEqual(try contents(call(server, "pilcrow_list")).first?["text"] as? String, Server.empty)
                XCTAssertEqual(chmod(dir.path, 0o700), 0)
            }
        }
    }
    func testAttachmentNamesRequireDigit() throws {
        try withRoot { root in
            let names = ["frame-x.png", "frame-.png", "mark-.png"]
            let manifest = try item(root, attachments: names.map { .init(name: $0, kind: .frame) })
            let listing = try XCTUnwrap(contents(call(Server(root: root), "pilcrow_list")).first?["text"] as? String)
            for name in names { XCTAssertFalse(listing.contains(name), "Invalid attachment name was listed: \(name)") }
            XCTAssertEqual(try contents(call(Server(root: root), "pilcrow_latest")).count, 1, "Invalid attachment names must not be served for \(manifest.id)")
        }
    }
    func testAttachmentBudgetExactBoundary() throws {
        try withRoot { root in
            let manifest = try item(root, attachments: [.init(name: "frame-1.png", kind: .frame)])
            let file = root.appendingPathComponent(manifest.id.uuidString).appendingPathComponent("frame-1.png")
            var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
            data.append(Data(repeating: 1, count: 7_500_000 - data.count))
            try data.write(to: file)
            let server = Server(root: root)
            var blocks = try contents(call(server, "pilcrow_latest"))
            XCTAssertEqual(blocks.filter { $0["type"] as? String == "image" }.count, 1)
            XCTAssertEqual(blocks.compactMap { $0["data"] as? String }.first?.utf8.count, Server.maxBase64Bytes)

            var oneByteOver = data
            oneByteOver.append(1)
            try oneByteOver.write(to: file)
            blocks = try contents(call(server, "pilcrow_latest"))
            XCTAssertFalse(blocks.contains { $0["type"] as? String == "image" })
            XCTAssertTrue(blocks.compactMap { $0["text"] as? String }.joined().contains("Image omitted (response limit): frame-1.png"))
        }
    }
    func testLowercaseFolderNameMatchesManifestID() throws {
        try withRoot { root in
            let manifest = try item(root)
            let original = root.appendingPathComponent(manifest.id.uuidString)
            let lowercase = root.appendingPathComponent(manifest.id.uuidString.lowercased())
            try FileManager.default.moveItem(at: original, to: lowercase)
            let listing = try XCTUnwrap(contents(call(Server(root: root), "pilcrow_list")).first?["text"] as? String)
            XCTAssertTrue(listing.contains(manifest.id.uuidString))
        }
    }
    func testFIFOManifestDoesNotBlockSubprocess() throws {
        try withRoot { root in
            let dir = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            XCTAssertEqual(mkfifo(dir.appendingPathComponent("manifest.json").path, 0o600), 0)
            let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("pilcrow-mcp")
            let process = Process(); process.executableURL = executable
            process.environment = ["PILCROW_OUTBOX_DIR": root.path]
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"pilcrow_list\"}}\n".utf8))
            try input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let finished = !process.isRunning
            if !finished { process.terminate() }
            process.waitUntilExit()
            XCTAssertTrue(finished, "FIFO blocked the server")
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }
    func testFutureAndRetentionBoundaries() throws {
        try withRoot { root in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = try item(root, date: now.addingTimeInterval(1), text: "future")
            _ = try item(root, date: now.addingTimeInterval(-86401), text: "old")
            XCTAssertEqual(try contents(call(Server(root: root, now: now), "pilcrow_list")).first?["text"] as? String, Server.empty)
            let boundary = try item(root, date: now.addingTimeInterval(-86400))
            XCTAssertTrue(try XCTUnwrap(contents(call(Server(root: root, now: now), "pilcrow_list")).first?["text"] as? String).contains(boundary.id.uuidString))
        }
    }
    func testStdio() throws {
        try withRoot { root in
            _ = try item(root, text: "Subprocess capture")
            let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("pilcrow-mcp")
            let process = Process(); process.executableURL = executable
            process.environment = ["PILCROW_OUTBOX_DIR": root.path]
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"pilcrow_latest\"}}\n".utf8))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            XCTAssertEqual(lines.count, 2); XCTAssertTrue(lines[0].contains("2025-11-25")); XCTAssertTrue(lines[1].contains("Subprocess capture"))
        }
    }
}
