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
}

/// A deterministic export description. Core plans crops; the App produces the image files.
public struct FixList: Sendable, Equatable, Codable {
    public let transcript: String
    public let items: [FixItem]

    public static func build(session: Session, onlyFinal: Bool = false) -> FixList {
        let tokens = Aligner.place(words: session.words, strokes: session.strokes, onlyFinal: onlyFinal)
        let names = MessageBuilder.filenames(for: session)
        let frames = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
        let items = session.liveMarks.map { stroke -> FixItem in
            let crop = crop(for: stroke, frame: frames[stroke.frameID])
            return FixItem(mark: stroke.id, frameID: stroke.frameID,
                           imageName: names[stroke.frameID] ?? "screenshot unavailable", cropName: "mark-\(stroke.id.rawValue).png",
                           cropRect: crop.rect, outputSize: crop.size, unavailableReason: crop.reason,
                           words: context(for: stroke.id, tokens: tokens))
        }
        return FixList(transcript: TranscriptRenderer.render(tokens: tokens), items: items)
    }

    /// No trailing newline. Missing crops keep their planned names and state the reason.
    func renderMarkdown() -> String {
        let list = items.map { item in
            let reason: String
            switch item.unavailableReason {
            case .pendingFrame: reason = " (screenshot pending)"
            case .failedFrame, .missingFrame: reason = " (screenshot not available)"
            case .invalidGeometry: reason = " (crop not available: invalid geometry)"
            case nil: reason = ""
            }
            return "- [\(item.mark.rawValue)] \"\(TextSanitizer.markdownQuoted(item.words))\" → \(item.cropName) (in \(item.imageName))\(reason)"
        }.joined(separator: "\n")
        return [TextSanitizer.markdownTranscript(transcript), list].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func context(for mark: MarkID, tokens: [TranscriptToken]) -> String {
        // Flatten recognition runs only after alignment, so a run retains its original timed slot.
        var words: [String] = []
        var marks: [(id: MarkID, slot: Int)] = []
        for token in tokens {
            switch token {
            case .word(let text): words += text.split(whereSeparator: \.isWhitespace).map(String.init)
            case .mark(let id): marks.append((id, words.count))
            }
        }
        guard let index = marks.firstIndex(where: { $0.id == mark }), !words.isEmpty else { return "" }
        let slot = marks[index].slot
        let endsSentence: (Int) -> Bool = { index in
            guard let last = words[index].last else { return false }
            if "?!…".contains(last) { return true }
            guard last == "." else { return false }
            guard index + 1 < words.count else { return true }
            guard let next = words[index + 1].first else { return false }
            return next.isUppercase || next.isNumber
        }
        // A boundary slot belongs to the word on its left, except slot zero.
        let anchor = max(0, slot - 1)
        let sentenceStart = (0..<anchor).last(where: endsSentence).map { $0 + 1 } ?? 0
        let sentenceEnd = (anchor..<words.count).first(where: endsSentence).map { $0 + 1 } ?? words.count
        let sharesSentence = marks.enumerated().contains { otherIndex, other in
            let otherAnchor = max(0, other.slot - 1)
            return otherIndex != index && other.slot != slot && (sentenceStart..<sentenceEnd).contains(otherAnchor)
        }
        if sentenceEnd - sentenceStart <= 25 && !sharesSentence {
            return words[sentenceStart..<sentenceEnd].joined(separator: " ")
        }
        // Equal-slot marks never bound one another.
        let previous = marks.map(\.slot).filter { $0 < slot }.max() ?? sentenceStart
        let next = marks.map(\.slot).filter { $0 > slot }.min() ?? sentenceEnd
        let left = max(sentenceStart, slot - 12, previous)
        let right = min(sentenceEnd, slot + 6, next)
        // For slot > 0, left <= slot - 1 < slot <= right; at slot 0, left is 0 and right is at least 1.
        return words[left..<right].joined(separator: " ")
    }

    private static func crop(for stroke: Stroke, frame: Frame?) -> (rect: PixelRect?, size: PixelSize?, reason: FixItem.UnavailableReason?) {
        guard let frame else { return (nil, nil, .missingFrame) }
        guard !frame.captureFailed else { return (nil, nil, .failedFrame) }
        guard frame.isComplete, let pixels = frame.pixelSize else { return (nil, nil, .pendingFrame) }
        let points = stroke.points + [stroke.badgeAnchor]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return (nil, nil, .invalidGeometry) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            return (nil, nil, .invalidGeometry)
        }
        // Infinite intermediate spans are deliberate: huge finite points then request the full frame.
        let bounds = frame.boundsInPoints
        let lowX = minX * bounds.width, highX = maxX * bounds.width
        let lowY = minY * bounds.height, highY = maxY * bounds.height
        let finiteX = lowX.isFinite && highX.isFinite
        let finiteY = lowY.isFinite && highY.isFinite
        let spanX = finiteX ? highX - lowX : (maxX - minX) * bounds.width
        let spanY = finiteY ? highY - lowY : (maxY - minY) * bounds.height
        let padding = max(48, 0.25 * max(spanX, spanY))
        let width = min(bounds.width, max(320, spanX + 2 * padding))
        let height = min(bounds.height, max(200, spanY + 2 * padding))
        let centerX = finiteX ? lowX / 2 + highX / 2 : (minX / 2 + maxX / 2) * bounds.width
        let centerY = finiteY ? lowY / 2 + highY / 2 : (minY / 2 + maxY / 2) * bounds.height
        let x = min(bounds.width - width, max(0, centerX - width / 2))
        let y = min(bounds.height - height, max(0, centerY - height / 2))
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
}
