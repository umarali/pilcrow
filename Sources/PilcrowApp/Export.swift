import Darwin
import Foundation
import CoreGraphics
import ImageIO
import PilcrowCore
import UniformTypeIdentifiers
import os

actor ExportStore {
    private let files = FileManager.default
    private let temporary: URL
    private let log = Logger(subsystem: "org.pilcrow.app", category: "export")
    private var folders: [URL: Int32] = [:]
    private var retained = Set<URL>()
    private var staged: [URL: URL] = [:]

    init(temporary: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) {
        self.temporary = temporary
    }

    func prepare() throws -> URL {
        let folder = temporary.appendingPathComponent("pilcrow-recovery-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let descriptor = lockOwnedDirectory(folder) else { throw Export.Failure.directory }
        folders[folder] = descriptor
        return folder
    }

    func keepOnly(_ latest: URL?) {
        for folder in Array(folders.keys) where folder != latest && !retained.contains(folder) { discard(folder) }
    }

    func discard(_ folder: URL) {
        guard let descriptor = folders[folder], remove(staged[folder] ?? folder, lockedBy: descriptor) else { return }
        staged.removeValue(forKey: folder)
        retained.remove(folder)
        folders.removeValue(forKey: folder)
        close(descriptor)
    }

    /// Recovery exports survive new sessions and Quit. Only explicit Discard removes them.
    func retain(_ folder: URL) { retained.insert(folder) }

    func beginDiscard(_ folder: URL) throws {
        guard folders[folder] != nil else { throw DeliveryFailure("Couldn’t discard capture") }
        let hidden = folder.deletingLastPathComponent().appendingPathComponent(".discarded-" + folder.lastPathComponent)
        try files.moveItem(at: folder, to: hidden)
        staged[folder] = hidden
    }

    func undoDiscard(_ folder: URL) throws {
        guard let hidden = staged[folder] else { return }
        try files.moveItem(at: hidden, to: folder)
        staged.removeValue(forKey: folder)
    }

    func recover(_ approval: ApprovalExport) throws -> ApprovalExport {
        let folder: URL
        if folders[approval.folder] != nil {
            folder = approval.folder
            retain(folder)
        } else {
            folder = try prepare()
            // Keep even a partial recovery on error; the original is also retained.
            retain(folder)
            for (attachment, bytes) in zip(approval.attachments, approval.imageData) {
                try bytes.write(to: folder.appendingPathComponent(attachment.name), options: .atomic)
            }
        }
        if folder != approval.folder { Export.copyCalibrationData(from: approval.folder, to: folder) }
        let recovered = approval.relocated(to: folder)
        try Data(DeliveryText.fileMessage(approvedText: recovered.text,
            imagePaths: recovered.imageURLs(in: folder).map(\.path)).utf8)
            .write(to: folder.appendingPathComponent("message-for-agent.md"), options: .atomic)
        return recovered
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
    static let strokeDataLimit = 5_000_000
    static let voiceDataLimit = 999_999
    private static let log = Logger(subsystem: "org.pilcrow.app", category: "export")

    enum Failure: Error { case directory, missingSource, render, crop, encode }

    struct Result: Sendable {
        let attachments: [String]
        let imageData: [String: Data]
        let thumbnails: [String: CGImage]
        let messageWritten: Bool
        let failedFiles: [String]
    }

    static func write(session: Session, message: OutgoingMessage, originals: [Frame.ID: CGImage], to folder: URL,
                      voiceResults: VoiceRecording.Results = VoiceRecording.Results(), colour: PilcrowColour = .coral) -> Result {
        let frames = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
        let marks = Dictionary(grouping: session.liveMarks, by: \.frameID)
        let frameIDs = Set(message.framePlans.map(\.frameID))
        let fixes = FixList.build(session: session).items
        var cropsByFrame: [Frame.ID: [CropPlan]] = [:]
        var written = Set<String>()
        var failures: [String] = []
        var imageData: [String: Data] = [:]
        var thumbnails: [String: CGImage] = [:]

        func recordFailure(_ name: String, error: Error) {
            failures.append(name)
            log.error("Export file write failed")
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
                    // Leave one output pixel for antialiasing at fractional badge positions.
                    let targetBadgeHeight = ImageLimits.minBadgeHeightPixels + 1
                    var sourceBadgeHeight = targetBadgeHeight * Double(image.height) / Double(plan.outputSize.height)
                    for crop in crops {
                        let height = targetBadgeHeight * crop.sourcePixelRect.size.height / Double(crop.outputSize.height)
                        sourceBadgeHeight = max(sourceBadgeHeight, height)
                    }
                    composite = try annotate(image, frame: frame, marks: marks[plan.frameID] ?? [],
                                             minimumBadgeHeight: ceil(sourceBadgeHeight), colour: colour)
                } catch {
                    recordFailure(plan.outputName, error: error)
                    for crop in crops { recordFailure(crop.cropName, error: error) }
                    return
                }

                // Wordless exports keep the existing render and resize path unchanged.
                // Captioned outputs size their screenshot first, then enlarge its source
                // badges for that scale and append text at native pixel size.
                func captioned(size: PixelSize, sourceRect: CGRect?, items: [FixItem], framePanel: Bool) throws -> CGImage? {
                    guard !items.isEmpty, let frame = frames[plan.frameID], let original = originals[plan.frameID] else { return nil }
                    let sourceHeight = sourceRect?.height ?? CGFloat(original.height)
                    let sourceScale = min(CGFloat(original.width) / frame.boundsInPoints.width,
                                          CGFloat(original.height) / frame.boundsInPoints.height)
                    let badge = max(ImageLimits.minBadgeHeightPixels + 1,
                                    MarkBadgeGeometry.height * sourceScale * CGFloat(size.height) / sourceHeight)
                    let layout = try ExportCaptions.layout(size: size, items: items, badgeHeight: badge, frame: framePanel)
                    let annotated = try annotate(original, frame: frame, marks: marks[plan.frameID] ?? [],
                        minimumBadgeHeight: badge * sourceHeight / CGFloat(layout.screenshot.height), colour: colour)
                    let region: CGImage
                    if let sourceRect {
                        guard let cropped = annotated.cropping(to: sourceRect) else { throw Failure.crop }
                        region = cropped
                    } else { region = annotated }
                    return try ExportCaptions.render(region, layout: layout, colour: colour)
                }
                writeFile(plan.outputName) { url in
                    let items = fixes.filter { $0.frameID == plan.frameID && !$0.words.isEmpty }
                    let output = try captioned(size: plan.outputSize, sourceRect: nil, items: items, framePanel: true)
                    imageData[plan.outputName] = try writePNG(output ?? composite,
                        size: output.map { PixelSize(width: $0.width, height: $0.height) } ?? plan.outputSize, to: url)
                }
                for crop in crops {
                    writeFile(crop.cropName) { url in
                        let source = crop.sourcePixelRect
                        // CGImage cropping uses top-left image pixels, the same space as the Core rect.
                        let rect = CGRect(x: source.origin.x, y: source.origin.y,
                                          width: source.size.width, height: source.size.height)
                        guard let region = composite.cropping(to: rect) else { throw Failure.crop }
                        let items = fixes.filter { $0.cropName == crop.cropName && !$0.words.isEmpty }
                        let caption = try captioned(size: crop.outputSize, sourceRect: rect, items: items, framePanel: false)
                        let output = caption ?? region
                        let size = caption.map { PixelSize(width: $0.width, height: $0.height) } ?? crop.outputSize
                        imageData[crop.cropName] = try writePNG(output, size: size, to: url)
                        thumbnails[crop.cropName] = try? thumbnail(output)
                    }
                }
            }
        }

        let messageName = "message.md"
        writeFile(messageName) { url in
            try Data(message.text.utf8).write(to: url, options: .atomic)
        }
        // Calibration is optional and never contributes to user-visible failures.
        do {
            let data = try strokeData(session: session)
            try data.write(to: folder.appendingPathComponent("strokes.json"), options: .atomic)
        } catch {
            log.error("Skipped local stroke recording: encoding, size limit or write failure")
        }
        do {
            let data = try JSONEncoder().encode(VoiceRecording(session: session, results: voiceResults))
            guard data.count <= voiceDataLimit else { throw Failure.encode }
            let debug = try makeDebugDirectory(in: folder)
            try data.write(to: debug.appendingPathComponent("voice.json"), options: .atomic)
        } catch {
            log.error("Skipped local voice recording: encoding, size limit or write failure")
        }
        return Result(attachments: message.attachments.filter { written.contains($0) },
                      imageData: imageData, thumbnails: thumbnails,
                      messageWritten: written.contains(messageName), failedFiles: failures)
    }

    /// Local calibration evidence only. Attachment lists and clipboard messages
    /// are built separately from PNG plans and never include this data.
    static func strokeData(session: Session) throws -> Data {
        let frames = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
        let live = Set(session.liveMarks.map(\.id))
        let records = session.strokes.compactMap { mark -> StrokeRecording.Record? in
            guard !mark.isDeleted, live.contains(mark.absorbedInto ?? mark.id),
                  let frame = frames[mark.frameID] else { return nil }
            return StrokeRecording.Record(stroke: mark, frame: frame)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(StrokeRecording(strokes: records))
        guard data.count <= strokeDataLimit else { throw Failure.encode }
        return data
    }

    /// Optional local evidence must never block recovery or publication. Copy
    /// the known regular file without loading it back into process memory.
    static func copyCalibrationData(from source: URL, to destination: URL) {
        copyCalibrationFile("strokes.json", limit: strokeDataLimit, from: source, to: destination)
        let debug = source.appendingPathComponent("debug", isDirectory: true)
        let descriptor = open(debug.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else { return }
            copyCalibrationFile("voice.json", limit: voiceDataLimit, from: debug, to: destination,
                                directoryDescriptor: descriptor, intoDebug: true)
        } else if errno == ENOENT {
            // Recovery can still publish an export made before voice data moved.
            copyCalibrationFile("voice.json", limit: voiceDataLimit, from: source, to: destination, intoDebug: true)
        }
    }

    private static func makeDebugDirectory(in folder: URL) throws -> URL {
        let debug = folder.appendingPathComponent("debug", isDirectory: true)
        if mkdir(debug.path, 0o700) != 0 {
            var info = stat()
            guard errno == EEXIST, lstat(debug.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw Failure.encode }
        }
        return debug
    }

    private static func copyCalibrationFile(_ name: String, limit: Int, from source: URL, to destination: URL,
                                            directoryDescriptor: Int32? = nil, intoDebug: Bool = false) {
        let sourceURL = source.appendingPathComponent(name)
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let descriptor = directoryDescriptor.map { openat($0, name, flags) } ?? open(sourceURL.path, flags)
        if descriptor < 0 {
            if errno != ENOENT { log.error("Skipped local calibration copy: source unavailable") }
            return // Includes exports made before calibration recording.
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= limit else {
            log.error("Skipped local calibration copy: invalid source or size limit")
            return
        }
        do {
            let folder = intoDebug ? try makeDebugDirectory(in: destination) : destination
            let targetURL = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            // Reject a link/replacement raced into the path while copying.
            var named = stat(), copied = stat()
            guard lstat(sourceURL.path, &named) == 0, named.st_dev == info.st_dev, named.st_ino == info.st_ino,
                  lstat(targetURL.path, &copied) == 0, copied.st_mode & S_IFMT == S_IFREG,
                  copied.st_size == info.st_size else {
                try? FileManager.default.removeItem(at: targetURL)
                log.error("Skipped local calibration copy: source changed")
                return
            }
        } catch {
            log.error("Skipped local calibration copy: copy failed")
        }
    }

    private static func annotate(_ image: CGImage, frame: Frame, marks: [Stroke],
                                 minimumBadgeHeight: CGFloat, colour: PilcrowColour) throws -> CGImage {
        let context = try bitmap(width: image.width, height: image.height, colorSpace: image.colorSpace)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        let scale = min(bounds.width / frame.boundsInPoints.width, bounds.height / frame.boundsInPoints.height)
        MarkRenderer.draw(marks, in: context, bounds: bounds, frameSize: frame.boundsInPoints, pixelsPerPoint: scale,
                          minimumBadgeHeight: minimumBadgeHeight, colour: colour) { point in
            guard let pixel = Geometry.denormalize(point, frame: frame) else { return nil }
            return CGPoint(x: pixel.x, y: bounds.height - pixel.y)
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

    private static func thumbnail(_ image: CGImage) throws -> CGImage {
        let scale = min(1, 640 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let context = try bitmap(width: width, height: height, colorSpace: image.colorSpace)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { throw Failure.render }
        return thumbnail
    }

    private static func writePNG(_ image: CGImage, size: PixelSize, to url: URL) throws -> Data {
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
        let bytes = data as Data
        try bytes.write(to: url, options: .atomic)
        return bytes
    }
}
