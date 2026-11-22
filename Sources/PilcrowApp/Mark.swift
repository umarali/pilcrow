import Foundation
import CoreGraphics
import CoreText
import PilcrowCore

enum MarkRenderer {
    private static let badgeHeight = CGFloat(MarkBadgeGeometry.height)
    private static let inkWidth: CGFloat = 3
    private static let haloWidth: CGFloat = 1.5
    private static let halo = CGColor(gray: 1, alpha: 0.9)

    static func draw(_ marks: [Stroke], in context: CGContext, bounds: CGRect, frameSize: Size,
                     pixelsPerPoint: CGFloat = 1, minimumBadgeHeight: CGFloat = 0,
                     colour: PilcrowColour = .coral,
                     project: (NormalizedPoint) -> CGPoint?) {
        let badges = drawInkAndPlaceBadges(marks, in: context, bounds: bounds, frameSize: frameSize,
                                           pixelsPerPoint: pixelsPerPoint, minimumBadgeHeight: minimumBadgeHeight,
                                           colour: colour, project: project)
        for (id, badge) in badges {
            drawNumberedBadge(id, in: badge, context: context, colour: colour, scale: pixelsPerPoint)
        }
    }

    /// Draws every mark's ink, then returns where each badge goes, in drawing order.
    static func drawInkAndPlaceBadges(_ marks: [Stroke], in context: CGContext, bounds: CGRect, frameSize: Size,
                                      pixelsPerPoint: CGFloat = 1, minimumBadgeHeight: CGFloat = 0,
                                      colour: PilcrowColour = .coral,
                                      project: (NormalizedPoint) -> CGPoint?) -> [(MarkID, CGRect)] {
        let ink = colour.ink
        let badges = marks.compactMap { mark -> (Stroke, Placement)? in
            guard !mark.isDeleted, mark.absorbedInto == nil,
                  let placement = drawInk(mark, in: context, frameSize: frameSize,
                                          ink: ink, pixelsPerPoint: pixelsPerPoint, project: project) else { return nil }
            return (mark, placement)
        }
        let height = max(badgeHeight * pixelsPerPoint, minimumBadgeHeight)
        // A badge must not hide an arrowhead or another badge, so each one takes its first clear spot.
        let heads = badges.compactMap { $0.1.arrowhead?.bounds.insetBy(dx: -6 * pixelsPerPoint, dy: -6 * pixelsPerPoint) }
        var placed: [(MarkID, CGRect)] = []
        for (mark, placement) in badges {
            let candidates = badgeCandidates(mark, placement: placement, bounds: bounds,
                                             requestedHeight: height, scale: pixelsPerPoint)
            guard let first = candidates.first else { continue }
            let ownHead = placement.arrowhead.map { $0.bounds.insetBy(dx: -6 * pixelsPerPoint, dy: -6 * pixelsPerPoint) }
            let gap = 2 * pixelsPerPoint
            let badge = candidates.first { candidate in
                let padded = candidate.insetBy(dx: -gap, dy: -gap)
                return !heads.contains { $0 != ownHead && $0.intersects(padded) } && !placed.contains { $0.1.intersects(padded) }
            } ?? first
            placed.append((mark.id, badge))
        }
        return placed
    }

    private struct Placement {
        /// Preferred badge centres, best first.
        var anchors: [CGPoint]
        var arrowhead: Arrowhead?
        /// Middle of an arrow's shaft, for arrows whose start sits on another mark.
        var shaftMiddle: Arrowhead?
    }

    static func stroke(_ path: CGPath, in context: CGContext, ink: CGColor, width: CGFloat, scale: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(halo)
        context.setLineWidth(width + 2 * haloWidth * scale)
        context.addPath(path)
        context.strokePath()
        context.setStrokeColor(ink)
        context.setLineWidth(width)
        context.addPath(path)
        context.strokePath()
    }

    private static func dot(_ rect: CGRect, in context: CGContext, ink: CGColor, scale: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(halo)
        context.fillEllipse(in: rect.insetBy(dx: -haloWidth * scale, dy: -haloWidth * scale))
        context.setFillColor(ink)
        context.fillEllipse(in: rect)
    }

    private static func drawInk(_ mark: Stroke, in context: CGContext, frameSize: Size,
                                ink: CGColor, pixelsPerPoint: CGFloat, project: (NormalizedPoint) -> CGPoint?)
        -> Placement? {
        let width = inkWidth * pixelsPerPoint
        var anchors: [CGPoint]
        var arrowhead: Arrowhead?
        var shaftMiddle: Arrowhead?
        if case .area(let area) = mark.shape, let box = area.fittedBounds {
            guard let topLeft = project(NormalizedPoint(x: box.origin.x / frameSize.width,
                                                        y: box.origin.y / frameSize.height)),
                  let bottomRight = project(NormalizedPoint(x: (box.origin.x + box.size.width) / frameSize.width,
                                                            y: (box.origin.y + box.size.height) / frameSize.height)),
                  topLeft.x.isFinite, topLeft.y.isFinite, bottomRight.x.isFinite, bottomRight.y.isFinite,
                  topLeft.x < bottomRight.x, bottomRight.y < topLeft.y else { return nil }
            let rect = CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x,
                              height: topLeft.y - bottomRight.y)
            let path: CGPath
            if case .rectangle = area {
                let radius = min(5 * pixelsPerPoint, rect.width / 4, rect.height / 4)
                path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                anchors = [topLeft, CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.minY)]
            } else {
                path = CGPath(ellipseIn: rect, transform: nil)
                let diagonal = sqrt(0.5)
                // Upper left first, then the other diagonals, then the top and side midpoints.
                let directions: [(CGFloat, CGFloat)] = [(-diagonal, diagonal), (diagonal, diagonal), (-diagonal, -diagonal),
                                                        (diagonal, -diagonal), (0, 1), (-1, 0), (1, 0), (0, -1)]
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let rx = rect.width / 2, ry = rect.height / 2
                anchors = directions.map { CGPoint(x: center.x + $0.0 * rx, y: center.y + $0.1 * ry) }
            }
            stroke(path, in: context, ink: ink, width: width, scale: pixelsPerPoint)
        } else {
            guard let projected = project(mark.badgeAnchor) else { return nil }
            let anchor: CGPoint
            if mark.shaftReversed == true, case .arrow = mark.shape,
               let tail = mark.renderedPoints.last.flatMap(project) {
                anchor = tail
            } else {
                anchor = projected
            }
            anchors = [anchor]
            if mark.shape == .pin {
                dot(CGRect(x: anchor.x - width, y: anchor.y - width, width: 2 * width, height: 2 * width),
                    in: context, ink: ink, scale: pixelsPerPoint)
            } else {
                arrowhead = drawFreehand(mark, at: projected, in: context, ink: ink,
                                         pixelsPerPoint: pixelsPerPoint, project: project)
                if case .arrow(_?, _) = mark.shape {
                    shaftMiddle = middle(of: [projected] + mark.renderedPoints.compactMap(project), scale: pixelsPerPoint)
                }
            }
        }

        return Placement(anchors: anchors, arrowhead: arrowhead, shaftMiddle: shaftMiddle)
    }

    /// The point halfway along a path, with the local direction of travel.
    private static func middle(of points: [CGPoint], scale: CGFloat) -> Arrowhead? {
        guard points.count >= 2 else { return nil }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        var travelled: CGFloat = 0
        for (index, length) in lengths.enumerated() {
            if travelled + length >= total / 2, length > 0 {
                let t = (total / 2 - travelled) / length
                let a = points[index], b = points[index + 1]
                let point = CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
                // Read the direction over a wider span so jitter does not tilt the badge offset.
                let before = points[max(0, index - 3)], after = points[min(points.count - 1, index + 4)]
                let span = hypot(after.x - before.x, after.y - before.y)
                let direction = span > 0 ? CGVector(dx: (after.x - before.x) / span, dy: (after.y - before.y) / span)
                    : CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
                let half = inkWidth * scale / 2
                return Arrowhead(tip: point, direction: direction,
                                 bounds: CGRect(origin: point, size: .zero).insetBy(dx: -half, dy: -half))
            }
            travelled += length
        }
        return nil
    }

    private static func drawFreehand(_ mark: Stroke, at anchor: CGPoint, in context: CGContext, ink: CGColor,
                                     pixelsPerPoint: CGFloat, project: (NormalizedPoint) -> CGPoint?) -> Arrowhead? {
        let path = CGMutablePath()
        var previous = anchor
        var moved = false
        let arrow: Bool
        if case .arrow = mark.shape { arrow = true } else { arrow = false }
        var arrowPoints = [anchor]
        path.move(to: anchor)
        for sample in mark.renderedPoints {
            guard let point = project(sample), point != previous else { continue }
            let midpoint = CGPoint(x: (point.x + previous.x) / 2, y: (point.y + previous.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
            if arrow { arrowPoints.append(point) }
            previous = point
            moved = true
        }
        let width = inkWidth * pixelsPerPoint
        if moved {
            path.addLine(to: previous)
            if arrow, mark.shaftReversed == true { arrowPoints.reverse() }
            let head = arrow ? addArrowhead(to: path, points: arrowPoints, scale: pixelsPerPoint) : nil
            stroke(path, in: context, ink: ink, width: width, scale: pixelsPerPoint)
            return head
        } else {
            dot(CGRect(x: anchor.x - width / 2, y: anchor.y - width / 2, width: width, height: width),
                in: context, ink: ink, scale: pixelsPerPoint)
            return nil
        }
    }

    private struct Arrowhead {
        var tip: CGPoint
        var direction: CGVector
        var bounds: CGRect
    }

    private static func addArrowhead(to path: CGMutablePath, points: [CGPoint], scale: CGFloat) -> Arrowhead? {
        guard let tip = points.last else { return nil }
        var back = tip, distance: CGFloat = 0
        // A spatial baseline skips the last few jittery samples, even if they are dense.
        for point in points.dropLast().reversed() {
            let separation = hypot(tip.x - point.x, tip.y - point.y)
            if separation > distance {
                back = point
                distance = separation
            }
            if separation >= 14 * scale { break }
        }
        guard distance.isFinite, distance > 0 else { return nil }
        let dx = (tip.x - back.x) / distance, dy = (tip.y - back.y) / distance
        let length = min(13 * scale, distance)
        let spread = 0.55 * length
        let base = CGPoint(x: tip.x - length * dx, y: tip.y - length * dy)
        let left = CGPoint(x: base.x - spread * dy, y: base.y + spread * dx)
        let right = CGPoint(x: base.x + spread * dy, y: base.y - spread * dx)
        path.move(to: left)
        path.addLine(to: tip)
        path.addLine(to: right)
        let headBounds = CGRect(x: min(left.x, right.x, tip.x), y: min(left.y, right.y, tip.y),
                                width: max(left.x, right.x, tip.x) - min(left.x, right.x, tip.x),
                                height: max(left.y, right.y, tip.y) - min(left.y, right.y, tip.y))
        let halfStroke = inkWidth * scale / 2
        return Arrowhead(tip: tip, direction: CGVector(dx: dx, dy: dy),
                         bounds: headBounds.insetBy(dx: -halfStroke, dy: -halfStroke))
    }

    private static func arrowBadges(beyond head: Arrowhead, width: CGFloat, height: CGFloat,
                                    gap: CGFloat, in bounds: CGRect) -> [CGRect] {
        func badge(toward direction: CGVector, clearance: CGFloat) -> CGRect {
            let dx = direction.dx, dy = direction.dy
            let offset = abs(dx) * width / 2 + abs(dy) * height / 2 + clearance
            let x = max(bounds.minX, min(head.tip.x + dx * offset - width / 2, bounds.maxX - width))
            let y = max(bounds.minY, min(head.tip.y + dy * offset - height / 2, bounds.maxY - height))
            return CGRect(x: x, y: y, width: width, height: height)
        }

        let dx = head.direction.dx, dy = head.direction.dy
        // Beside the head first: past the tip the badge covers whatever the arrow points at.
        let sides = [CGVector(dx: -dy, dy: dx), CGVector(dx: dy, dy: -dx)].compactMap { direction -> CGRect? in
            let edgeX = direction.dx >= 0 ? head.bounds.maxX : head.bounds.minX
            let edgeY = direction.dy >= 0 ? head.bounds.maxY : head.bounds.minY
            let clearance = (edgeX - head.tip.x) * direction.dx + (edgeY - head.tip.y) * direction.dy
            let side = badge(toward: direction, clearance: clearance + gap)
            return side.intersects(head.bounds) ? nil : side
        }
        return sides + [badge(toward: head.direction, clearance: gap)]
    }

    private static func badgeCandidates(_ mark: Stroke, placement: Placement, bounds: CGRect,
                                        requestedHeight: CGFloat, scale: CGFloat) -> [CGRect] {
        let height: CGFloat
        if placement.arrowhead != nil {
            let widthAtOnePoint = MarkBadgeGeometry.numberedBadgeWidth(id: mark.id, height: 1)
            height = min(requestedHeight, bounds.height, bounds.width / widthAtOnePoint)
        } else {
            height = requestedHeight
        }
        let width = MarkBadgeGeometry.numberedBadgeWidth(id: mark.id, height: height)
        if mark.shape == .pin, let anchor = placement.anchors.first {
            let dot = Point(x: anchor.x - bounds.minX, y: bounds.maxY - anchor.y)
            let pinBadge = MarkBadgeGeometry.pinBadge(at: dot, in: Size(width: bounds.width, height: bounds.height),
                                                      id: mark.id, height: height, gap: MarkBadgeGeometry.pinGap * scale)
            return [CGRect(x: bounds.minX + pinBadge.origin.x, y: bounds.maxY - pinBadge.origin.y - height,
                           width: pinBadge.size.width, height: height)]
        }
        if let arrowhead = placement.arrowhead, let anchor = placement.anchors.first {
            let gap = MarkBadgeGeometry.arrowGap * scale
            guard case .arrow(_, _?) = mark.shape else {
                return arrowBadges(beyond: arrowhead, width: width, height: height, gap: gap, in: bounds)
            }
            // An arrow with a target is numbered away from it: mid-shaft when the start also sits on a mark, else at the tail.
            let tail = Arrowhead(tip: anchor,
                                 direction: CGVector(dx: -arrowhead.direction.dx, dy: -arrowhead.direction.dy),
                                 bounds: CGRect(origin: anchor, size: .zero)
                                     .insetBy(dx: -inkWidth * scale / 2, dy: -inkWidth * scale / 2))
            let middle = placement.shaftMiddle.map { arrowBadges(beyond: $0, width: width, height: height, gap: gap, in: bounds) }
            return (middle.map { Array($0.dropLast()) } ?? []) + arrowBadges(beyond: tail, width: width, height: height, gap: gap, in: bounds)
        }
        return placement.anchors.map { anchor in
            let x = max(bounds.minX, min(anchor.x - width / 2, bounds.maxX - width))
            let y = max(bounds.minY, min(anchor.y - height / 2, bounds.maxY - height))
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// Identical colour, Helvetica Bold numeral and pill geometry in overlays and captions.
    static func drawNumberedBadge(_ id: MarkID, in badge: CGRect, context: CGContext,
                                  colour: PilcrowColour, scale: CGFloat = 1) {
        context.saveGState()
        defer { context.restoreGState() }
        let height = badge.height
        let outline = haloWidth * scale
        let outer = badge.insetBy(dx: -outline, dy: -outline)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: outer, cornerWidth: outer.height / 2, cornerHeight: outer.height / 2, transform: nil))
        context.fillPath()
        context.setFillColor(colour.ink)
        let text = NSAttributedString(string: String(id.rawValue), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 12 * height / badgeHeight, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour.badgeText
        ])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: badge.midX - ink.midX, y: badge.midY - ink.midY)
        CTLineDraw(line, context)
    }
}
