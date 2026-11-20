import Darwin
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

struct CapturedMarks: Sendable {
    let image: CGImage
    let geometry: FrameGeometry
    let marks: [MarkSnapshot]
}

@MainActor
final class ExportStore {
    private let files = FileManager.default
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let log = Logger(subsystem: "org.pilcrow.app", category: "export")
    private var folders: [URL: Int32] = [:]

    func prepare() throws -> URL {
        let folder = temporary.appendingPathComponent("pilcrow-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let descriptor = lockOwnedDirectory(folder) else { throw Export.Failure.directory }
        folders[folder] = descriptor
        return folder
    }

    func keepOnly(_ latest: URL?) {
        for folder in Array(folders.keys) where folder != latest { discard(folder) }
    }

    func discard(_ folder: URL) {
        guard let descriptor = folders[folder], remove(folder, lockedBy: descriptor) else { return }
        folders.removeValue(forKey: folder)
        close(descriptor)
    }

    func removeStale() {
        guard let candidates = try? files.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) else {
            log.error("Could not list the temporary export directory")
            return
        }
        for folder in candidates {
            let name = folder.lastPathComponent
            guard name.hasPrefix("pilcrow-"), let uuid = UUID(uuidString: String(name.dropFirst("pilcrow-".count))),
                  name == "pilcrow-" + uuid.uuidString, let descriptor = lockOwnedDirectory(folder) else { continue }
            _ = remove(folder, lockedBy: descriptor)
            close(descriptor)
        }
    }

    private func lockOwnedDirectory(_ folder: URL) -> Int32? {
        // A running Pilcrow instance holds this lock while it owns the directory.
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func remove(_ folder: URL, lockedBy descriptor: Int32) -> Bool {
        // Check that the path still names the directory we locked before deleting it.
        var locked = stat()
        var named = stat()
        guard fstat(descriptor, &locked) == 0 else { return false }
        if lstat(folder.path, &named) != 0 { return errno == ENOENT }
        guard named.st_dev == locked.st_dev, named.st_ino == locked.st_ino,
              named.st_uid == geteuid() else { return true }
        do {
            try files.removeItem(at: folder)
            return true
        } catch {
            log.error("Could not remove a temporary export")
            return false
        }
    }
}

enum Export {
    private static let log = Logger(subsystem: "org.pilcrow.app", category: "export")
    private static let maxEdge: CGFloat = 1_600
    private static let maxPixels: CGFloat = 1_560_000

    enum Failure: Error { case directory, render, encode }

    static func write(_ frames: [CapturedMarks], to folder: URL) throws {
        for (index, frame) in frames.enumerated() {
            try write(frame, to: folder.appendingPathComponent("frame-\(index + 1).png"))
        }
    }

    private static func write(_ frame: CapturedMarks, to url: URL) throws {
        let g = frame.geometry
        let sourceWidth = CGFloat(g.width)
        let sourceHeight = CGFloat(g.height)
        let fit = min(1, maxEdge / max(sourceWidth, sourceHeight), (maxPixels / sourceWidth / sourceHeight).squareRoot())
        let width = max(1, Int((sourceWidth * fit).rounded(.down)))
        let height = max(1, Int((sourceHeight * fit).rounded(.down)))
        let xScale = CGFloat(width) / sourceWidth
        let yScale = CGFloat(height) / sourceHeight
        let pixelsPerPoint = g.scale * min(xScale, yScale)

        func bitmapContext(in space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        let sourceContext = frame.image.colorSpace.flatMap { $0.model == .rgb ? bitmapContext(in: $0) : nil }
        if sourceContext == nil { log.notice("Burn-in fell back to sRGB") }
        guard let context = sourceContext ?? bitmapContext(in: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw Failure.render
        }
        context.interpolationQuality = .high
        context.draw(frame.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: xScale, y: yScale)
        context.concatenate(g.bitmapTransform)
        for mark in frame.marks {
            mark.draw(in: context, bounds: CGRect(origin: .zero, size: g.size), pixelsPerPoint: pixelsPerPoint)
        }
        guard let composite = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encode }
        CGImageDestinationAddImage(destination, composite, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encode }
    }
}
