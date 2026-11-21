import Darwin
import Foundation
import PilcrowCore

struct DeliveryFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Only the App calls this store. An injectable root also allows disposable
/// filesystem probes without touching Application Support.
actor OutboxStore {
    let root: URL
    private let files = FileManager.default
    private var exporting: [UUID: Int32] = [:]
    private var discarded: [UUID: Int32] = [:]

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pilcrow/Outbox", isDirectory: true)) {
        self.root = root
    }

    nonisolated func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Hold an item lock across background export; retention cannot remove it.
    func prepare(_ id: UUID) throws -> URL {
        try prepareRoot()
        guard let rootDescriptor = lockDirectory(root) else { throw DeliveryFailure("Couldn’t save capture") }
        defer { close(rootDescriptor) }
        let item = folder(for: id)
        try files.createDirectory(at: item, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let descriptor = lockDirectory(item) else { throw DeliveryFailure("Couldn’t save capture") }
        exporting[id] = descriptor
        return item
    }

    func releaseExport(_ id: UUID) {
        if let descriptor = exporting.removeValue(forKey: id) { close(descriptor) }
    }

    func create(_ approval: ApprovalExport, imageData: [Data], destination: Destination, project: URL?,
                shellPath: String = LoginShell.path) throws -> URL {
        defer { releaseExport(approval.id) }
        guard imageData.count == approval.attachments.count else {
            throw DeliveryFailure("Couldn’t save every image. The capture was kept.")
        }
        let item = folder(for: approval.id)
        if approval.folder != item, !files.fileExists(atPath: item.path) {
            // Retry a partial publication using the retained recovery bytes.
            _ = try prepare(approval.id)
        } else if exporting[approval.id] == nil,
                  !files.fileExists(atPath: item.appendingPathComponent("manifest.json").path),
                  let descriptor = lockDirectory(item) {
            // An unpublished item (no manifest yet) is re-locked whatever its folder, so a
            // failed first publication never blocks later sends.
            exporting[approval.id] = descriptor
        }
        try validateParents()
        guard let rootDescriptor = lockDirectory(root) else { throw DeliveryFailure("Couldn’t save capture") }
        defer { close(rootDescriptor) }
        guard exporting[approval.id] != nil else { throw DeliveryFailure("Couldn’t save capture") }
        // Normal Finish exported here already. Write bytes again only for recovery
        // from an earlier failure to prepare the outbox.
        if approval.folder != item {
            for (attachment, data) in zip(approval.attachments, imageData) {
                try data.write(to: item.appendingPathComponent(attachment.name), options: .atomic)
            }
        }
        if approval.folder != item { Export.copyCalibrationData(from: approval.folder, to: item) }
        let paths = approval.imageURLs(in: item).map(\.path)
        let messageURL = item.appendingPathComponent("message-for-agent.md")
        try Data(DeliveryText.message(approvedText: approval.text, imagePaths: paths).utf8)
            .write(to: messageURL, options: .atomic)
        try writeCommand(destination: destination, project: project, paths: paths,
                         messageURL: messageURL, item: item, shellPath: shellPath)
        let manifest = OutboxManifest(id: approval.id, createdAt: Date(), destination: destination,
                                      text: approval.text, attachments: approval.attachments)
        try OutboxManifest.encoder().encode(manifest).write(to: item.appendingPathComponent("manifest.json"), options: .atomic)
        return item
    }

    /// Reuse the clipboard item; publish MCP only after an explicit secondary Send.
    func route(_ approval: ApprovalExport, destination: Destination, project: URL?, shellPath: String) throws -> URL {
        try validateParents()
        guard let rootDescriptor = lockDirectory(root) else { throw DeliveryFailure("The outbox is busy.") }
        defer { close(rootDescriptor) }
        let item = folder(for: approval.id)
        guard let descriptor = lockDirectory(item) else { throw DeliveryFailure("This capture is no longer available. Finish a new annotation.") }
        defer { close(descriptor) }
        let manifestURL = item.appendingPathComponent("manifest.json")
        var manifest = try OutboxManifest.decoder().decode(OutboxManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.id == approval.id else { throw DeliveryFailure("This capture is no longer available.") }
        try writeCommand(destination: destination, project: project, paths: approval.imageURLs(in: item).map(\.path),
                         messageURL: item.appendingPathComponent("message-for-agent.md"), item: item, shellPath: shellPath)
        // The manifest records MCP availability, not the most recent send.
        if manifest.destination != .mcp { manifest.destination = destination }
        try OutboxManifest.encoder().encode(manifest).write(to: manifestURL, options: .atomic)
        return item
    }

    private func writeCommand(destination: Destination, project: URL?, paths: [String], messageURL: URL,
                              item: URL, shellPath: String) throws {
        guard destination.command != nil else { return }
        guard let project, let script = DeliveryText.script(destination: destination, projectPath: project.path,
            imagePaths: paths, messagePath: messageURL.path, shellPath: shellPath) else {
            throw DeliveryFailure("Choose a project folder before sending.")
        }
        // Re-check on the store executor immediately before writing the command.
        var directory: ObjCBool = false
        guard files.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else {
            throw DeliveryFailure("The project folder no longer exists. Choose another folder in Review.")
        }
        let scriptURL = item.appendingPathComponent("send.command")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    /// Unpublish while holding the item lock until filesystem deletion completes.
    @discardableResult
    func beginDiscard(_ id: UUID) throws -> Bool {
        var info = stat()
        if lstat(folder(for: id).path, &info) != 0, errno == ENOENT { return false }
        try validateParents()
        guard let rootDescriptor = lockDirectory(root) else { throw DeliveryFailure("Couldn’t discard capture") }
        defer { close(rootDescriptor) }
        guard let descriptor = lockDirectory(folder(for: id)) else { throw DeliveryFailure("Couldn’t discard capture") }
        do {
            try files.moveItem(at: folder(for: id), to: discardedFolder(id))
            discarded[id] = descriptor
            return true
        } catch { close(descriptor); throw error }
    }

    func finishDiscard(_ id: UUID) throws {
        guard let descriptor = discarded[id] else { return }
        try remove(discardedFolder(id), descriptor: descriptor)
        discarded.removeValue(forKey: id)
        close(descriptor)
    }

    private func discardedFolder(_ id: UUID) -> URL {
        root.appendingPathComponent(".discarded-" + id.uuidString, isDirectory: true)
    }

    private func remove(_ item: URL, descriptor: Int32) throws {
        var locked = stat()
        var named = stat()
        guard fstat(descriptor, &locked) == 0, lstat(item.path, &named) == 0,
              locked.st_ino == named.st_ino, locked.st_dev == named.st_dev else {
            throw DeliveryFailure("The capture changed before it could be removed.")
        }
        try files.removeItem(at: item)
    }

    /// Retention is best effort on Send. Explicit Clear still reports prune errors.
    func pruneBeforeSend(now: Date = Date()) -> Bool {
        do { try prune(now: now); return true }
        catch { return false }
    }

    /// The Settings footer reads metadata only, with the same ownership/name policy as Clear.
    func hasClearableCaptures() -> Bool {
        guard (try? validateParents()) != nil, let rootDescriptor = lockDirectory(root) else { return false }
        defer { close(rootDescriptor) }
        guard let candidates = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return false }
        return candidates.contains { item in
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid() else { return false }
            let name = item.lastPathComponent
            let id = name.hasPrefix(".discarded-") ? String(name.dropFirst(".discarded-".count)) : name
            guard UUID(uuidString: id) != nil, let descriptor = lockDirectory(item) else { return false }
            close(descriptor)
            return true
        }
    }

    func prune(now: Date = Date(), clearAll: Bool = false) throws {
        // An absent outbox is normal on first launch. Do not create it until Finish.
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) != 0 {
            if errno == ENOENT { return }
            throw DeliveryFailure("Couldn’t inspect the outbox.")
        }
        try validateParents()
        guard let rootDescriptor = lockDirectory(root) else { throw DeliveryFailure("Couldn’t secure the outbox.") }
        defer { close(rootDescriptor) }
        let candidates = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var failed = false
        for item in candidates {
            var info = stat()
            guard lstat(item.path, &info) == 0 else { continue }
            let candidate = DeliveryText.RetentionCandidate(
                name: item.lastPathComponent, isDirectory: info.st_mode & S_IFMT == S_IFDIR,
                isSymlink: info.st_mode & S_IFMT == S_IFLNK, isOwnedByUser: info.st_uid == geteuid(),
                createdAt: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec)
                    + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000))
            let discardedID = item.lastPathComponent.hasPrefix(".discarded-")
                ? UUID(uuidString: String(item.lastPathComponent.dropFirst(".discarded-".count))) : nil
            guard DeliveryText.shouldRemove(candidate, now: now, clearAll: clearAll) ||
                    (discardedID != nil && candidate.isDirectory && !candidate.isSymlink && candidate.isOwnedByUser),
                  let descriptor = lockDirectory(item) else { continue }
            defer { close(descriptor) }
            var locked = stat()
            var named = stat()
            // Same lock + identity check as temporary export cleanup. Reject
            // symlinks and replacements, and leave items another writer has locked.
            guard fstat(descriptor, &locked) == 0, lstat(item.path, &named) == 0,
                  locked.st_ino == named.st_ino, locked.st_dev == named.st_dev,
                  named.st_mode & S_IFMT == S_IFDIR, named.st_uid == geteuid() else { continue }
            do { try files.removeItem(at: item) } catch { failed = true }
        }
        if failed { throw DeliveryFailure("Couldn’t remove some recent captures.") }
    }

    private func prepareRoot() throws {
        // Application Support may already be shared with other apps. Only the
        // Pilcrow and Outbox parents are made private; never chmod Library itself.
        let parent = root.deletingLastPathComponent()
        let support = parent.deletingLastPathComponent()
        try ensureDirectory(support, makePrivate: false)
        try ensureDirectory(parent, makePrivate: true)
        try ensureDirectory(root, makePrivate: true)
    }

    private func validateParents() throws {
        for url in [root.deletingLastPathComponent().deletingLastPathComponent(), root.deletingLastPathComponent()] {
            guard let descriptor = ownedDirectory(url) else { throw DeliveryFailure("The outbox parent is not a user-owned directory.") }
            close(descriptor)
        }
    }

    private func ensureDirectory(_ url: URL, makePrivate: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw DeliveryFailure("Couldn’t inspect an outbox folder.") }
            try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard let descriptor = ownedDirectory(url) else { throw DeliveryFailure("The outbox folder is not a user-owned directory.") }
        defer { close(descriptor) }
        if makePrivate && fchmod(descriptor, 0o700) != 0 { throw DeliveryFailure("Couldn’t make the outbox private.") }
    }

    private func ownedDirectory(_ url: URL) -> Int32? {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else { close(descriptor); return nil }
        return descriptor
    }

    private func lockDirectory(_ url: URL) -> Int32? {
        guard let descriptor = ownedDirectory(url) else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return descriptor
    }
}
