import Foundation
import CoreGraphics
import class Vision.VNRecognizeTextRequest
import class Vision.VNImageRequestHandler
import PilcrowCore

/// Uses only original screenshot pixels, before ink or spoken captions are rendered.
enum MarkTextRecognition {
    private static let queue = DispatchQueue(label: "org.pilcrow.mark-text", qos: .userInitiated)
    private static let cropPadding = 48.0
    private static let pointLabelReach = 24.0
    private static let maxCropPixels = 1_000_000.0

    /// Call off the main actor. One deadline covers all marks and frames, including queue time.
    /// A serial worker bounds outstanding Vision work across successive captures.
    static func collect(session: Session, originals: [Frame.ID: CGImage], budget: TimeInterval = 0.6,
                        recognize injected: ((CGImage, Stroke, Frame) -> String?)? = nil) -> [MarkID: String] {
        guard budget > 0, !originals.isEmpty else { return [:] }
        let deadline = DispatchTime.now() + budget
        let frames = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
        let work = session.liveMarks.compactMap { mark -> Work? in
            guard let frame = frames[mark.frameID], frame.isComplete, let image = originals[mark.frameID],
                  let region = Region(mark: mark, frame: frame), let crop = Crop(image, region: region, frame: frame)
            else { return nil }
            return Work(mark: mark, frame: frame, image: image, region: region, crop: crop)
        }.sorted {
            ($0.crop.area, $0.mark.id.rawValue) < ($1.crop.area, $1.mark.id.rawValue)
        }
        guard !work.isEmpty, DispatchTime.now() < deadline else { return [:] }
        let state = Collection(deadline: deadline)
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            defer { finished.signal() }
            for item in work {
                guard state.hasTime else { break }
                let text: String?
                if let injected {
                    text = injected(item.image, item.mark, item.frame)
                } else {
                    text = recognize(item.image, region: item.region, crop: item.crop)
                }
                if let text { state.record(text, for: item.mark.id) }
            }
        }
        _ = finished.wait(timeout: deadline)
        return state.close()
    }

    private struct Work {
        let mark: Stroke
        let frame: Frame
        let image: CGImage
        let region: Region
        let crop: Crop
    }

    private struct Crop {
        let pixels: CGRect
        let sx: Double
        let sy: Double
        var area: Double { pixels.width * pixels.height }

        init?(_ image: CGImage, region: Region, frame: Frame) {
            sx = Double(image.width) / frame.boundsInPoints.width
            sy = Double(image.height) / frame.boundsInPoints.height
            let padded = region.bounds.insetBy(dx: -cropPadding, dy: -cropPadding)
            pixels = CGRect(x: padded.minX * sx, y: padded.minY * sy,
                            width: padded.width * sx, height: padded.height * sy).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !pixels.isEmpty, !pixels.isNull, area <= maxCropPixels else { return nil }
        }

        // Vision uses bottom-left normalized coordinates; frame and crop coordinates start at the top left.
        func frameRect(_ box: CGRect) -> CGRect {
            CGRect(x: (pixels.minX + box.minX * pixels.width) / sx,
                   y: (pixels.minY + (1 - box.maxY) * pixels.height) / sy,
                   width: box.width * pixels.width / sx, height: box.height * pixels.height / sy)
        }

        func mayBeClipped(_ box: CGRect) -> Bool {
            let marginX = 2 / pixels.width, marginY = 2 / pixels.height
            return !CGRect(x: marginX, y: marginY, width: 1 - 2 * marginX, height: 1 - 2 * marginY).contains(box)
        }
    }

    private final class Collection: @unchecked Sendable {
        let deadline: DispatchTime
        private let lock = NSLock()
        private var closed = false
        private var texts: [MarkID: String] = [:]
        init(deadline: DispatchTime) { self.deadline = deadline }
        var hasTime: Bool {
            lock.lock(); defer { lock.unlock() }
            return !closed && DispatchTime.now() < deadline
        }
        func record(_ text: String, for id: MarkID) {
            lock.lock(); defer { lock.unlock() }
            if !closed, DispatchTime.now() < deadline, let text = VisibleText.concise(text) {
                texts[id] = text
            }
        }
        func close() -> [MarkID: String] {
            lock.lock(); defer { lock.unlock() }
            closed = true
            return texts
        }
    }

    static func recognize(_ image: CGImage, mark: Stroke, frame: Frame) -> String? {
        guard let region = Region(mark: mark, frame: frame), let crop = Crop(image, region: region, frame: frame) else { return nil }
        return recognize(image, region: region, crop: crop)
    }

    private struct Word {
        let text: Substring
        let rect: CGRect
        let clipped: Bool
    }

    private static func recognize(_ image: CGImage, region: Region, crop: Crop) -> String? {
        guard let pixels = image.cropping(to: crop.pixels) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: pixels, orientation: .up).perform([request]) }
        catch { return nil }

        let lines = (request.results ?? []).compactMap { observation -> [Word]? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.6 else { return nil }
            let tokens = candidate.string.split(whereSeparator: { $0.isWhitespace })
            let words = tokens.compactMap { word -> Word? in
                guard let box = try? candidate.boundingBox(for: word.startIndex..<word.endIndex)?.boundingBox,
                      !box.isEmpty else { return nil }
                return Word(text: word, rect: crop.frameRect(box), clipped: crop.mayBeClipped(box))
            }
            // Missing geometry can make a point label look complete when it is only a fragment.
            return region.target == nil || words.count == tokens.count ? words : nil
        }
        let text: String
        if let target = region.target {
            guard let label = nearestLabel(in: lines, to: target) else { return nil }
            text = label
        } else {
            text = lines.flatMap { $0 }.filter { !$0.clipped && region.includes($0.rect) }.map(\.text).joined(separator: " ")
        }
        return VisibleText.concise(text)
    }

    private static func nearestLabel(in lines: [[Word]], to target: CGPoint) -> String? {
        var labels: [(words: [Word], contains: Bool, distance: Double)] = []
        for line in lines {
            // Vision can put adjacent controls in one line. Split gaps much wider than a word space.
            var groups: [[Word]] = []
            for word in line {
                if let previous = groups.last?.last {
                    let gap = max(word.rect.minX - previous.rect.maxX, previous.rect.minX - word.rect.maxX)
                    if gap <= max(8, 0.75 * max(previous.rect.height, word.rect.height)) {
                        groups[groups.count - 1].append(word)
                        continue
                    }
                }
                groups.append([word])
            }
            for words in groups {
                let bounds = words.reduce(CGRect.null) { $0.union($1.rect) }
                let distance = distance(from: target, to: bounds)
                if distance <= pointLabelReach { labels.append((words, bounds.contains(target), distance)) }
            }
        }
        labels.sort {
            if $0.contains != $1.contains { return $0.contains }
            return $0.distance < $1.distance
        }
        guard let first = labels.first, !first.words.contains(where: \.clipped) else { return nil }
        if labels.count > 1 {
            let second = labels[1]
            if first.contains == second.contains, second.distance - first.distance <= 4 { return nil }
        }
        return first.words.map(\.text).joined(separator: " ")
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    struct Region {
        let bounds: CGRect
        let target: CGPoint?
        private let accepts: (CGRect) -> Bool
        func includes(_ text: CGRect) -> Bool { accepts(text) }

        init?(mark: Stroke, frame: Frame) {
            let size = frame.boundsInPoints
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            func point(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
            let points = mark.renderedPoints.map(point)
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let frameRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            let raw: CGRect
            let targetPoint: CGPoint?
            let accept: (CGRect) -> Bool
            switch mark.shape {
            case .pin, .arrow:
                let tip: CGPoint
                if case .arrow = mark.shape {
                    guard let end = mark.shaftReversed == true ? points.first : points.last else { return nil }
                    tip = end
                } else { tip = point(mark.badgeAnchor) }
                guard tip.x.isFinite, tip.y.isFinite else { return nil }
                let radius = 56.0
                raw = CGRect(x: tip.x - radius, y: tip.y - radius, width: 2 * radius, height: 2 * radius)
                targetPoint = tip
                accept = { distance(from: tip, to: $0) <= pointLabelReach }
            case .area(let area):
                targetPoint = nil
                if let fitted = area.fittedBounds {
                    raw = CGRect(x: fitted.origin.x, y: fitted.origin.y, width: fitted.size.width, height: fitted.size.height)
                } else {
                    guard let box = Self.bounds(points), points.count >= 3 else { return nil }
                    raw = box
                }
                let areaBounds = raw
                switch area {
                case .rectangle:
                    accept = { areaBounds.contains($0) }
                case .ellipse:
                    accept = { rect in
                        // The corner farthest from the ellipse's centre determines containment.
                        let x = max(abs(rect.minX - areaBounds.midX), abs(rect.maxX - areaBounds.midX)) / (areaBounds.width / 2)
                        let y = max(abs(rect.minY - areaBounds.midY), abs(rect.maxY - areaBounds.midY)) / (areaBounds.height / 2)
                        return x * x + y * y <= 1
                    }
                case .freeform:
                    let path = CGMutablePath()
                    path.addLines(between: points)
                    path.closeSubpath()
                    accept = { rect in
                        areaBounds.contains(rect) && CGPath(rect: rect, transform: nil).subtracting(path, using: .evenOdd).isEmpty
                    }
                }
            case .mark, nil:
                targetPoint = nil
                guard let box = Self.bounds(points) else { return nil }
                raw = box.insetBy(dx: -14, dy: -28)
                accept = { rect in
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    let tolerance = rect.height / 2 + 14
                    if points.count == 1 { return hypot(center.x - points[0].x, center.y - points[0].y) <= tolerance }
                    return zip(points, points.dropFirst()).contains { a, b in
                        let dx = b.x - a.x, dy = b.y - a.y
                        let length = dx * dx + dy * dy
                        let t = length > 0 ? min(1, max(0, ((center.x - a.x) * dx + (center.y - a.y) * dy) / length)) : 0
                        return hypot(center.x - a.x - t * dx, center.y - a.y - t * dy) <= tolerance
                    }
                }
            }
            guard raw.minX.isFinite, raw.minY.isFinite, raw.width.isFinite, raw.height.isFinite else { return nil }
            let clipped = raw.intersection(frameRect)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            bounds = clipped
            target = targetPoint
            accepts = accept
        }

        private static func bounds(_ points: [CGPoint]) -> CGRect? {
            guard let first = points.first else { return nil }
            var lowX = first.x, highX = first.x, lowY = first.y, highY = first.y
            for p in points { lowX = min(lowX, p.x); highX = max(highX, p.x); lowY = min(lowY, p.y); highY = max(highY, p.y) }
            return CGRect(x: lowX, y: lowY, width: highX - lowX, height: highY - lowY)
        }
    }
}
