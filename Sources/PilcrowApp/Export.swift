import Darwin
import Foundation
import CoreGraphics
import ImageIO
import PilcrowCore
import UniformTypeIdentifiers
import os

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

    enum Failure: Error { case directory, missingSource, render, crop, encode }

    struct Result: Sendable {
        let attachments: [String]
        let messageWritten: Bool
        let failedFiles: [String]
    }

    static func write(session: Session, message: OutgoingMessage, originals: [Frame.ID: CGImage], to folder: URL) -> Result {
        let frames = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
        let marks = Dictionary(grouping: session.liveMarks, by: \.frameID)
        let frameIDs = Set(message.framePlans.map(\.frameID))
        var cropsByFrame: [Frame.ID: [CropPlan]] = [:]
        var written = Set<String>()
        var failures: [String] = []

        func recordFailure(_ name: String, error: Error) {
            failures.append(name)
            log.error("Could not write \(name, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        func writeFile(_ name: String, produce: (URL) throws -> Void) {
            do {
                try produce(folder.appendingPathComponent(name))
                written.insert(name)
            } catch {
                recordFailure(name, error: error)
            }
        }

        for crop in message.cropPlans {
            guard let id = crop.sourceFrameID, frameIDs.contains(id) else {
                recordFailure(crop.cropName, error: Failure.missingSource)
                continue
            }
            cropsByFrame[id, default: []].append(crop)
        }

        for plan in message.framePlans {
            autoreleasepool {
                let crops = cropsByFrame[plan.frameID] ?? []
                let composite: CGImage
                do {
                    guard let frame = frames[plan.frameID], let image = originals[plan.frameID] else {
                        throw Failure.missingSource
                    }
                    // Size the original badge for the smallest vertical scale across all outputs.
                    var sourceBadgeHeight = ImageLimits.minBadgeHeightPixels * Double(image.height) / Double(plan.outputSize.height)
                    for crop in crops {
                        let height = ImageLimits.minBadgeHeightPixels * crop.sourcePixelRect.size.height / Double(crop.outputSize.height)
                        sourceBadgeHeight = max(sourceBadgeHeight, height)
                    }
                    composite = try annotate(image, frame: frame, marks: marks[plan.frameID] ?? [],
                                             minimumBadgeHeight: ceil(sourceBadgeHeight))
                } catch {
                    recordFailure(plan.outputName, error: error)
                    for crop in crops { recordFailure(crop.cropName, error: error) }
                    return
                }

                writeFile(plan.outputName) { url in
                    try writePNG(composite, size: plan.outputSize, to: url)
                }
                for crop in crops {
                    writeFile(crop.cropName) { url in
                        let source = crop.sourcePixelRect
                        // CGImage cropping uses top-left image pixels, the same space as the Core rect.
                        let rect = CGRect(x: source.origin.x, y: source.origin.y,
                                          width: source.size.width, height: source.size.height)
                        guard let region = composite.cropping(to: rect) else { throw Failure.crop }
                        try writePNG(region, size: crop.outputSize, to: url)
                    }
                }
            }
        }

        let messageName = "message.md"
        writeFile(messageName) { url in
            try Data(message.text.utf8).write(to: url, options: .atomic)
        }
        return Result(attachments: message.attachments.filter { written.contains($0) },
                      messageWritten: written.contains(messageName), failedFiles: failures)
    }

    private static func annotate(_ image: CGImage, frame: Frame, marks: [Stroke],
                                 minimumBadgeHeight: CGFloat) throws -> CGImage {
        let context = try bitmap(width: image.width, height: image.height, colorSpace: image.colorSpace)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        let scale = min(bounds.width / frame.boundsInPoints.width, bounds.height / frame.boundsInPoints.height)
        for mark in marks {
            MarkRenderer.draw(mark, in: context, bounds: bounds, pixelsPerPoint: scale,
                              minimumBadgeHeight: minimumBadgeHeight) { point in
                guard let pixel = Geometry.denormalize(point, frame: frame) else { return nil }
                return CGPoint(x: pixel.x, y: bounds.height - pixel.y)
            }
        }
        guard let result = context.makeImage() else { throw Failure.render }
        return result
    }

    private static func bitmap(width: Int, height: Int, colorSpace: CGColorSpace?) throws -> CGContext {
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        if let colorSpace, colorSpace.model == .rgb, let context = makeContext(colorSpace) {
            return context
        }
        log.notice("Burn-in fell back to sRGB")
        guard let fallback = CGColorSpace(name: CGColorSpace.sRGB),
              let context = makeContext(fallback) else { throw Failure.render }
        return context
    }

    private static func writePNG(_ image: CGImage, size: PixelSize, to url: URL) throws {
        let output: CGImage
        if image.width == size.width, image.height == size.height {
            output = image
        } else {
            let context = try bitmap(width: size.width, height: size.height, colorSpace: image.colorSpace)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let resized = context.makeImage() else { throw Failure.render }
            output = resized
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encode }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encode }
        try (data as Data).write(to: url, options: .atomic)
    }
}
