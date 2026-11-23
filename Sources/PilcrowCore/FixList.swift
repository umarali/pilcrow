import Foundation

/// A source rectangle in the frame's top-left pixel coordinates.
public struct PixelRect: Sendable, Equatable, Hashable, Codable {
    public let origin: Point
    public let size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }
}

public struct PixelSize: Sendable, Equatable, Hashable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct FixItem: Sendable, Equatable, Hashable, Codable {
    public enum UnavailableReason: String, Sendable, Codable {
        case pendingFrame, failedFrame, missingFrame, invalidGeometry
    }

    public let mark: MarkID
    public let frameID: Frame.ID
    public let imageName: String
    public let cropName: String
    public let cropRect: PixelRect?
    public let outputSize: PixelSize?
    public let unavailableReason: UnavailableReason?
    public let words: String
    public let shape: MarkShape?
    public let visibleText: String?
    public let frameContext: FrameContext?

    /// Human-readable kind shared by fix lines and exported image captions.
    public var kindLabel: String {
        switch shape {
        case .pin: return " (point)"
        case .area(.rectangle): return " (box)"
        case .area(.ellipse(let bounds)):
            let longSide = max(bounds.size.width, bounds.size.height)
            let shortSide = min(bounds.size.width, bounds.size.height)
            return longSide / shortSide <= 1.25 ? " (circle)" : " (oval)"
        case .area(.freeform): return " (area)"
        case .arrow(let from?, let to?): return " (arrow from [\(from.rawValue)] to [\(to.rawValue)])"
        case .arrow(let from?, nil): return " (arrow starting at [\(from.rawValue)])"
        case .arrow(nil, let to?): return " (arrow pointing at [\(to.rawValue)])"
        case .arrow(nil, nil): return " (arrow)"
        case .mark, nil: return ""
        }
    }
}

/// A deterministic export description. Core plans crops; the App produces the image files.
public struct FixList: Sendable, Equatable, Codable {
    private static let minimumCropHeight = 200.0

    public let transcript: String
    public let items: [FixItem]

    public static func build(session: Session, onlyFinal: Bool = false, visibleText: [MarkID: String] = [:]) -> FixList {
        let words = Aligner.sortedWords(session.words, onlyFinal: onlyFinal)
        let tokens = Aligner.place(sortedWords: words, sortedStrokes: Aligner.sortedLiveStrokes(session.strokes),
                                   toleratesWordStarts: true)
        let cleanup = TranscriptCleanup(sortedWords: words, languageCode: session.transcriptLanguageCode)
        let contexts = Aligner.contexts(words: cleanup.words, strokes: session.strokes,
                                        hasText: cleanup.cleanedText.map { !$0.isEmpty })
        let names = MessageBuilder.filenames(for: session)
        let frames = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
        let live = session.liveMarks
        let liveFrames = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.frameID) })
        let items = live.map { stroke -> FixItem in
            let crop = crop(for: stroke, frame: frames[stroke.frameID])
            let shape: MarkShape?
            if case .arrow(let from, let to) = stroke.shape {
                shape = .arrow(from: from.flatMap { liveFrames[$0] == stroke.frameID ? $0 : nil },
                               to: to.flatMap { liveFrames[$0] == stroke.frameID ? $0 : nil })
            } else {
                shape = stroke.shape
            }
            return FixItem(mark: stroke.id, frameID: stroke.frameID,
                           imageName: names[stroke.frameID] ?? "screenshot unavailable", cropName: "mark-\(stroke.id.rawValue).png",
                           cropRect: crop.rect, outputSize: crop.size, unavailableReason: crop.reason,
                           words: cleanup.text(for: contexts[stroke.id, default: []]), shape: shape,
                           visibleText: visibleText[stroke.id].flatMap(VisibleText.concise), frameContext: frames[stroke.frameID]?.context)
        }
        return FixList(transcript: TranscriptRenderer.render(tokens: tokens), items: items)
    }

    /// No trailing newline. Missing crops keep their planned names and state the reason.
    func renderMarkdown() -> String {
        var shownFrames = Set<Frame.ID>()
        let list = items.map { item in
            let reason: String
            switch item.unavailableReason {
            case .pendingFrame: reason = " (screenshot pending)"
            case .failedFrame, .missingFrame: reason = " (screenshot not available)"
            case .invalidGeometry: reason = " (crop not available: invalid geometry)"
            case nil: reason = ""
            }
            let words = item.words.isEmpty ? "" : " \"\(TextSanitizer.markdownQuoted(item.words))\""
            let target = item.visibleText.map { " on \"\(TextSanitizer.markdownQuoted($0))\"" } ?? ""
            var header = ""
            if let label = item.frameContext?.messageLabel, shownFrames.insert(item.frameID).inserted {
                header = "\(item.imageName) — \(label)\n"
            }
            return header + "- [\(item.mark.rawValue)]\(item.kindLabel)\(words)\(target) → \(item.cropName) (in \(item.imageName))\(reason)"
        }.joined(separator: "\n")
        return [TextSanitizer.markdownTranscript(transcript), list].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func crop(for stroke: Stroke, frame: Frame?) -> (rect: PixelRect?, size: PixelSize?, reason: FixItem.UnavailableReason?) {
        guard let frame else { return (nil, nil, .missingFrame) }
        guard !frame.captureFailed else { return (nil, nil, .failedFrame) }
        guard frame.isComplete, let pixels = frame.pixelSize else { return (nil, nil, .pendingFrame) }
        let bounds = frame.boundsInPoints
        guard let box = cropBox(for: stroke, frameSize: bounds) else { return (nil, nil, .invalidGeometry) }
        let badgePadding: Double
        if case .arrow = stroke.shape {
            badgePadding = arrowBadgePadding(id: stroke.id, frameSize: bounds, pixels: pixels)
        } else {
            badgePadding = 0
        }
        let padding = max(48, 0.25 * max(box.size.width, box.size.height), badgePadding)
        let width = min(bounds.width, max(320, box.size.width + 2 * padding))
        let height = min(bounds.height, max(minimumCropHeight, box.size.height + 2 * padding))
        let x = min(bounds.width - width, max(0, box.center.x - width / 2))
        let y = min(bounds.height - height, max(0, box.center.y - height / 2))
        // Round outwards so source pixels touched by the requested rectangle are retained.
        let scaleX = pixels.width / bounds.width, scaleY = pixels.height / bounds.height
        let origin = Point(x: (x * scaleX).rounded(.down), y: (y * scaleY).rounded(.down))
        let size = Size(width: min(pixels.width, ((x + width) * scaleX).rounded(.up)) - origin.x,
                        height: min(pixels.height, ((y + height) * scaleY).rounded(.up)) - origin.y)
        guard let output = Geometry.fitPixels(width: size.width, height: size.height,
                                               maxLongEdge: ImageLimits.maxLongEdge, maxPixels: ImageLimits.maxPixels) else {
            return (nil, nil, .invalidGeometry)
        }
        return (PixelRect(origin: origin, size: size), PixelSize(width: output.width, height: output.height), nil)
    }

    private static func arrowBadgePadding(id: MarkID, frameSize: Size, pixels: Size) -> Double {
        let scaleY = pixels.height / frameSize.height
        let scale = min(pixels.width / frameSize.width, scaleY)
        guard let frameOutput = Geometry.fitPixels(width: pixels.width, height: pixels.height,
                                                   maxLongEdge: ImageLimits.maxLongEdge,
                                                   maxPixels: ImageLimits.maxPixels) else { return 0 }
        // A crop has at least the frame's scale before rounding. Allow for losing one
        // output row when floored, using the shortest crop the planner can produce.
        let frameOutputHeight = Double(frameOutput.height)
        let minimumOutputHeight = max(1, (min(1, minimumCropHeight / frameSize.height) * frameOutputHeight).rounded(.down))
        let maximumShrink = pixels.height / frameOutputHeight * (1 + 1 / minimumOutputHeight)
        let height = max(MarkBadgeGeometry.height * scale,
                         ceil((ImageLimits.minBadgeHeightPixels + 1) * maximumShrink))
        let width = MarkBadgeGeometry.numberedBadgeWidth(id: id, height: height)
        // The diagonal covers the badge's reach from its anchor in any direction.
        // At an edge, also allow room to clear the 10 pt head and its barbs.
        return hypot(width, height) / scale + MarkBadgeGeometry.arrowGap + 20
    }

    private static func cropBox(for stroke: Stroke, frameSize: Size) -> (center: Point, size: Size)? {
        if case .area(let area) = stroke.shape, let box = area.fittedBounds {
            guard box.isValid else { return nil }
            let center = Point(x: box.origin.x + box.size.width / 2, y: box.origin.y + box.size.height / 2)
            return (center, box.size)
        }
        let points = stroke.shape == .pin ? [stroke.badgeAnchor] : Array(stroke.renderedPoints) + [stroke.badgeAnchor]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            return nil
        }
        // Infinite intermediate spans are deliberate: huge finite points then request the full frame.
        let bounds = frameSize
        let lowX = minX * bounds.width, highX = maxX * bounds.width
        let lowY = minY * bounds.height, highY = maxY * bounds.height
        let finiteX = lowX.isFinite && highX.isFinite
        let finiteY = lowY.isFinite && highY.isFinite
        let spanX = finiteX ? highX - lowX : (maxX - minX) * bounds.width
        let spanY = finiteY ? highY - lowY : (maxY - minY) * bounds.height
        let centerX = finiteX ? lowX / 2 + highX / 2 : (minX / 2 + maxX / 2) * bounds.width
        let centerY = finiteY ? lowY / 2 + highY / 2 : (minY / 2 + maxY / 2) * bounds.height
        return (Point(x: centerX, y: centerY), Size(width: spanX, height: spanY))
    }
}
