import Foundation
import CoreGraphics
import class Vision.VNRecognizeTextRequest
import class Vision.VNImageRequestHandler
import PilcrowCore

/// Uses only original screenshot pixels, before ink or spoken captions are rendered.
enum MarkTextRecognition {
    private static let queue = DispatchQueue(label: "org.pilcrow.mark-text", qos: .userInitiated)

    /// Call off the main actor. One deadline covers all marks and frames, including queue time.
    /// A serial worker bounds outstanding Vision work across successive captures.
    static func collect(session: Session, originals: [Frame.ID: CGImage], budget: TimeInterval = 0.6,
                        recognize: @escaping (CGImage, Stroke, Frame) -> String? = recognize) -> [MarkID: String] {
        guard budget > 0 else { return [:] }
        let state = Collection(deadline: ProcessInfo.processInfo.systemUptime + budget)
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            defer { finished.signal() }
            let frames = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
            for mark in session.liveMarks {
                guard state.hasTime else { break }
                guard let frame = frames[mark.frameID], frame.isComplete,
                      let image = originals[mark.frameID] else { continue }
                if let text = recognize(image, mark, frame) { state.record(text, for: mark.id) }
            }
        }
        _ = finished.wait(timeout: .now() + budget)
        return state.close()
    }

    private final class Collection: @unchecked Sendable {
        let deadline: TimeInterval
        private let lock = NSLock()
        private var closed = false
        private var texts: [MarkID: String] = [:]
        init(deadline: TimeInterval) { self.deadline = deadline }
        var hasTime: Bool {
            lock.lock(); defer { lock.unlock() }
            return !closed && ProcessInfo.processInfo.systemUptime < deadline
        }
        func record(_ text: String, for id: MarkID) {
            lock.lock(); defer { lock.unlock() }
            if !closed, ProcessInfo.processInfo.systemUptime < deadline, let text = VisibleText.concise(text) {
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
        guard let region = Region(mark: mark, frame: frame) else { return nil }
        let sx = Double(image.width) / frame.boundsInPoints.width
        let sy = Double(image.height) / frame.boundsInPoints.height
        let pixels = CGRect(x: region.bounds.minX * sx, y: region.bounds.minY * sy,
                            width: region.bounds.width * sx, height: region.bounds.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, !pixels.isNull, let crop = image.cropping(to: pixels) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request]) }
        catch { return nil }
        let text = (request.results ?? []).flatMap { observation -> [String] in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.6 else { return [] }
            // Filter individual words so one OCR line cannot pull text outside an oval
            // or freeform boundary into the selected text.
            return candidate.string.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
                guard let box = try? candidate.boundingBox(for: word.startIndex..<word.endIndex)?.boundingBox else { return nil }
                // Vision uses bottom-left normalized coordinates; crops use top-left pixels.
                let rect = CGRect(x: (pixels.minX + box.minX * pixels.width) / sx,
                                  y: (pixels.minY + (1 - box.maxY) * pixels.height) / sy,
                                  width: box.width * pixels.width / sx, height: box.height * pixels.height / sy)
                return region.includes(rect) ? String(word) : nil
            }
        }.joined(separator: " ")
        return VisibleText.concise(text)
    }

    struct Region {
        let bounds: CGRect
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
                accept = { rect in
                    let dx = max(rect.minX - tip.x, 0, tip.x - rect.maxX)
                    let dy = max(rect.minY - tip.y, 0, tip.y - rect.maxY)
                    return hypot(dx, dy) <= radius
                }
            case .area(let area):
                if let fitted = area.fittedBounds {
                    raw = CGRect(x: fitted.origin.x, y: fitted.origin.y, width: fitted.size.width, height: fitted.size.height)
                } else {
                    guard let box = Self.bounds(points), points.count >= 3 else { return nil }
                    raw = box
                }
                let areaBounds = raw
                accept = { rect in
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    switch area {
                    case .rectangle: return areaBounds.contains(center)
                    case .ellipse:
                        let x = (center.x - areaBounds.midX) / (areaBounds.width / 2)
                        let y = (center.y - areaBounds.midY) / (areaBounds.height / 2)
                        return x * x + y * y <= 1
                    case .freeform:
                        var inside = false
                        var previous = points.last!
                        for next in points {
                            if (next.y > center.y) != (previous.y > center.y),
                               center.x < (previous.x - next.x) * (center.y - next.y) / (previous.y - next.y) + next.x {
                                inside.toggle()
                            }
                            previous = next
                        }
                        return inside
                    }
                }
            case .mark, nil:
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
