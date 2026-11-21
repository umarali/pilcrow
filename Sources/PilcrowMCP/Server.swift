import Foundation
import Darwin
import PilcrowCore

struct Server {
    static let protocolVersion = "2025-11-25"
    static let maxBase64Bytes = 10_000_000
    static let empty = "No Pilcrow captures have been sent to MCP in the last 24 hours."
    let root: URL
    var now: Date? = nil
    var beforeServing: (() -> Void)? = nil
    var beforeAttachmentRead: ((String) -> Void)? = nil

    private var tools: [[String: Any]] {
        let emptySchema: [String: Any] = ["type": "object", "properties": [:], "additionalProperties": false]
        let context = "Pilcrow provides screenshots and a numbered fix list the user annotated on their Mac with Pilcrow and explicitly sent to this agent; [n] in the text matches badge n in the images."
        let annotations: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]
        return [
            ["name": "pilcrow_latest", "title": "Latest Pilcrow capture", "description": "\(context) Return the latest capture and its images.", "annotations": annotations, "inputSchema": emptySchema],
            ["name": "pilcrow_list", "title": "List Pilcrow captures", "description": "\(context) List up to 20 recent captures.", "annotations": annotations, "inputSchema": emptySchema],
            ["name": "pilcrow_get", "title": "Get Pilcrow capture", "description": "\(context) Return a capture or a single mark.", "annotations": annotations, "inputSchema": ["type": "object", "properties": ["id": ["type": "string"], "mark": ["type": "integer"]], "required": ["id"], "additionalProperties": false]]
        ]
    }

    func handle(_ data: Data) -> Data? {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return encode(error: -32700, message: "Parse error", id: NSNull()) }
        guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return encode(error: -32600, message: "Invalid Request", id: NSNull())
        }
        guard let id = request["id"] else { return nil }
        guard id is String || ((id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue.rounded(.towardZero) == $0.doubleValue } ?? false) else {
            return encode(error: -32600, message: "Invalid Request", id: NSNull())
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String
            let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            result = ["protocolVersion": requested.flatMap { supported.contains($0) ? $0 : nil } ?? Self.protocolVersion, "serverInfo": ["name": "pilcrow-mcp", "version": PilcrowCore.version], "capabilities": ["tools": [:]], "instructions": "Use pilcrow_latest for the latest capture, or pilcrow_list and pilcrow_get to select one. Read the numbered fix list alongside the matching image badges."]
        case "ping": result = [:]
        case "tools/list": result = ["tools": tools]
        case "tools/call":
            guard let params = request["params"] as? [String: Any], let name = params["name"] as? String else {
                return encode(error: -32602, message: "Invalid params", id: id)
            }
            if params["arguments"] != nil && !(params["arguments"] is [String: Any]) {
                return encode(error: -32602, message: "Invalid arguments", id: id)
            }
            guard ["pilcrow_latest", "pilcrow_list", "pilcrow_get"].contains(name) else { return encode(error: -32602, message: "Unknown tool", id: id) }
            result = call(name, arguments: params["arguments"] as? [String: Any] ?? [:])
        default: return encode(error: -32601, message: "Method not found", id: id)
        }
        return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func encode(error: Int, message: String, id: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": error, "message": message]], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func text(_ value: String, error: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": value]]]
        if error { result["isError"] = true }
        return result
    }
    private func call(_ name: String, arguments: [String: Any]) -> [String: Any] {
        if name != "pilcrow_get" && !arguments.isEmpty { return text("This tool takes no arguments.", error: true) }
        var requestedMark: Int?
        if name == "pilcrow_get" {
            guard Set(arguments.keys).isSubset(of: ["id", "mark"]), arguments["id"] is String else { return text("An id string is required.", error: true) }
            if let value = arguments["mark"] {
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                      n.doubleValue.rounded(.towardZero) == n.doubleValue, let mark = Int(exactly: n.doubleValue) else { return text("mark must be an integer.", error: true) }
                requestedMark = mark
            }
        }
        let items = loadItems()
        if name == "pilcrow_list" {
            guard !items.isEmpty else { return text(Self.empty) }
            let formatter = ISO8601DateFormatter()
            return text(items.prefix(20).map { item in
                "\(item.manifest.id.uuidString) | \(formatter.string(from: item.manifest.createdAt)) | \(fixLines(item.manifest.text).count) marks | \(item.images.map { $0.attachment.name }.joined(separator: ", "))"
            }.joined(separator: "\n"))
        }
        beforeServing?()
        let selected: (item: Item, folder: Int32)?
        if name == "pilcrow_get" {
            guard let item = items.first(where: { $0.manifest.id.uuidString.caseInsensitiveCompare(arguments["id"] as? String ?? "") == .orderedSame }),
                  let folder = openFolder(for: item) else { return text("Capture id not found.", error: true) }
            selected = (item, folder)
        } else {
            selected = items.lazy.compactMap { item in openFolder(for: item).map { (item, $0) } }.first
        }
        guard let (item, folder) = selected else { return text(Self.empty) }
        defer { close(folder) }
        var images = item.images
        var message = item.manifest.text
        if let mark = requestedMark {
            guard let line = fixLines(message).first(where: { $0.0 == mark })?.1 else { return text("Mark \(mark) not found.", error: true) }
            message = line
            images = images.filter { $0.attachment.kind == .crop && $0.attachment.mark == mark }
        }
        var content: [[String: Any]] = [["type": "text", "text": message]]
        var remaining = Self.maxBase64Bytes
        for image in images {
            let attachment = image.attachment
            guard let size = attachmentSize(folder, attachment.name), size == image.size else {
                content.append(unavailableLine(attachment, in: item.folder))
                continue
            }
            // The encoded length is checked before reading and again after reading.
            let encodedSize = ((size + 2) / 3) * 4
            if encodedSize > remaining {
                content.append(["type": "text", "text": "Image omitted (response limit): \(attachment.name) — \(item.folder.appendingPathComponent(attachment.name).path)"])
                continue
            }
            beforeAttachmentRead?(attachment.name)
            guard let data = readFile(folder, attachment.name, limit: remaining / 4 * 3, attachment: true),
                  data.count == size, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                content.append(unavailableLine(attachment, in: item.folder))
                continue
            }
            let encoded = data.base64EncodedString()
            guard encoded.utf8.count <= remaining else {
                content.append(["type": "text", "text": "Image omitted (response limit): \(attachment.name) — \(item.folder.appendingPathComponent(attachment.name).path)"])
                continue
            }
            remaining -= encoded.utf8.count
            content.append(["type": "image", "mimeType": "image/png", "data": encoded])
        }
        return ["content": content]
    }

    private func unavailableLine(_ attachment: OutboxManifest.Attachment, in folder: URL) -> [String: Any] {
        ["type": "text", "text": "Image unavailable: \(attachment.name) (\(folder.appendingPathComponent(attachment.name).standardizedFileURL.path))"]
    }

    private func fixLines(_ text: String) -> [(Int, String)] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("- ["), let end = line.firstIndex(of: "]"), let mark = Int(line[line.index(line.startIndex, offsetBy: 3)..<end]) else { return nil }
            return (mark, line)
        }
    }
    private struct Item {
        let manifest: OutboxManifest
        let folder: URL
        let device: dev_t
        let inode: ino_t
        let images: [Image]
    }
    private struct Image {
        let attachment: OutboxManifest.Attachment
        let size: Int
    }
    private func loadItems() -> [Item] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return [] }
        defer { close(rootFD) }
        var result: [Item] = []
        let now = now ?? Date()
        for name in names {
            let folder = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { continue }
            defer { close(folder) }
            var info = stat()
            guard fstat(folder, &info) == 0, safeFolder(info),
                  let manifestData = readFile(folder, "manifest.json", limit: 1_048_576),
                  let manifest = try? OutboxManifest.decoder().decode(OutboxManifest.self, from: manifestData),
                  manifest.version == 1, manifest.destination == .mcp,
                  name.caseInsensitiveCompare(manifest.id.uuidString) == .orderedSame,
                  manifest.createdAt <= now, manifest.createdAt >= now.addingTimeInterval(-86400) else { continue }
            let ordered = manifest.attachments.enumerated().sorted {
                let a = $0.element, b = $1.element
                if a.kind != b.kind { return a.kind == .crop }
                if a.kind == .crop && a.mark != b.mark { return (a.mark ?? Int.max) < (b.mark ?? Int.max) }
                return $0.offset < $1.offset
            }
            let images = ordered.compactMap { entry -> Image? in
                let attachment = entry.element
                guard let size = attachmentSize(folder, attachment.name) else { return nil }
                return Image(attachment: attachment, size: size)
            }
            result.append(Item(manifest: manifest, folder: root.appendingPathComponent(name, isDirectory: true), device: info.st_dev, inode: info.st_ino, images: images))
        }
        return result.sorted { $0.manifest.createdAt == $1.manifest.createdAt ? $0.manifest.id.uuidString < $1.manifest.id.uuidString : $0.manifest.createdAt > $1.manifest.createdAt }
    }
    private func safeFolder(_ info: stat) -> Bool {
        info.st_uid == getuid() && (info.st_mode & 0o022) == 0
    }
    private func openFolder(for item: Item) -> Int32? {
        let fd = open(item.folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, safeFolder(info), info.st_dev == item.device, info.st_ino == item.inode else {
            close(fd)
            return nil
        }
        return fd
    }
    private func attachmentSize(_ directory: Int32, _ name: String) -> Int? {
        // ASCII-only validation also excludes NUL, controls, separators and traversal.
        let bytes = Array(name.utf8)
        let prefix: Int
        if bytes.starts(with: Array("frame-".utf8)) { prefix = 6 }
        else if bytes.starts(with: Array("mark-".utf8)) { prefix = 5 }
        else { return nil }
        guard bytes.count > prefix + 4, bytes.suffix(4).elementsEqual(Array(".png".utf8)),
              bytes[prefix..<(bytes.count - 4)].allSatisfy({ (48...57).contains($0) }) else { return nil }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= Int64(Int.max / 4 * 3 - 2) else { return nil }
        return Int(info.st_size)
    }
    private func readFile(_ directory: Int32, _ name: String, limit: Int, attachment: Bool = false) -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= limit,
              !attachment || (info.st_nlink == 1 && info.st_uid == getuid()) else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; return nil }
            guard data.count + count <= limit else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
