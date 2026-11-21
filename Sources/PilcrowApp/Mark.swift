import Foundation
import CoreGraphics
import CoreText
import PilcrowCore

enum MarkRenderer {
    private static let badgeHeight = CGFloat(MarkBadgeGeometry.height)
    private static let inkWidth: CGFloat = 3
    private static let red = CGColor(srgbRed: 0.89, green: 0.08, blue: 0.12, alpha: 1)

    static func draw(_ marks: [Stroke], in context: CGContext, bounds: CGRect, frameSize: Size,
                     pixelsPerPoint: CGFloat = 1, minimumBadgeHeight: CGFloat = 0,
                     project: (NormalizedPoint) -> CGPoint?) {
        let badges = marks.compactMap { mark -> (Stroke, CGPoint, Arrowhead?)? in
            guard !mark.isDeleted, mark.absorbedInto == nil,
                  let placement = drawInk(mark, in: context, frameSize: frameSize,
                                          pixelsPerPoint: pixelsPerPoint, project: project) else { return nil }
            return (mark, placement.anchor, placement.arrowhead)
        }
        let height = max(badgeHeight * pixelsPerPoint, minimumBadgeHeight)
        for (mark, anchor, arrowhead) in badges {
            drawBadge(mark, at: anchor, arrowhead: arrowhead, in: context, bounds: bounds,
                      requestedHeight: height, scale: pixelsPerPoint)
        }
    }

    private static func drawInk(_ mark: Stroke, in context: CGContext, frameSize: Size,
                                pixelsPerPoint: CGFloat, project: (NormalizedPoint) -> CGPoint?)
        -> (anchor: CGPoint, arrowhead: Arrowhead?)? {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(red)
        context.setFillColor(red)
        let stroke = inkWidth * pixelsPerPoint
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let anchor: CGPoint
        var arrowhead: Arrowhead?
        if case .area(let area) = mark.shape, let box = area.fittedBounds {
            guard let topLeft = project(NormalizedPoint(x: box.origin.x / frameSize.width,
                                                        y: box.origin.y / frameSize.height)),
                  let bottomRight = project(NormalizedPoint(x: (box.origin.x + box.size.width) / frameSize.width,
                                                            y: (box.origin.y + box.size.height) / frameSize.height)),
                  topLeft.x.isFinite, topLeft.y.isFinite, bottomRight.x.isFinite, bottomRight.y.isFinite,
                  topLeft.x < bottomRight.x, bottomRight.y < topLeft.y else { return nil }
            let rect = CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x,
                              height: topLeft.y - bottomRight.y)
            if case .rectangle = area {
                let radius = min(5 * pixelsPerPoint, rect.width / 4, rect.height / 4)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                anchor = topLeft
            } else {
                context.addEllipse(in: rect)
                let diagonal = sqrt(0.5)
                anchor = CGPoint(x: rect.midX - diagonal * rect.width / 2,
                                 y: rect.midY + diagonal * rect.height / 2)
            }
            context.strokePath()
        } else {
            guard let projected = project(mark.badgeAnchor) else { return nil }
            if mark.shaftReversed == true, case .arrow = mark.shape,
               let tail = mark.renderedPoints.last.flatMap(project) {
                anchor = tail
            } else {
                anchor = projected
            }
            if mark.shape == .pin {
                context.fillEllipse(in: CGRect(x: anchor.x - stroke, y: anchor.y - stroke,
                                               width: 2 * stroke, height: 2 * stroke))
            } else {
                arrowhead = drawFreehand(mark, at: projected, in: context, pixelsPerPoint: pixelsPerPoint, project: project)
            }
        }

        return (anchor, arrowhead)
    }

    private static func drawFreehand(_ mark: Stroke, at anchor: CGPoint, in context: CGContext,
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
        if moved {
            path.addLine(to: previous)
            if arrow, mark.shaftReversed == true { arrowPoints.reverse() }
            let head = arrow ? addArrowhead(to: path, points: arrowPoints, scale: pixelsPerPoint) : nil
            context.addPath(path)
            context.strokePath()
            return head
        } else {
            let stroke = inkWidth * pixelsPerPoint
            context.fillEllipse(in: CGRect(x: anchor.x - stroke / 2, y: anchor.y - stroke / 2,
                                           width: stroke, height: stroke))
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
        let length = min(10 * scale, distance)
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

    private static func arrowBadge(beyond head: Arrowhead, width: CGFloat, height: CGFloat,
                                   gap: CGFloat, in bounds: CGRect) -> CGRect {
        func badge(toward direction: CGVector, clearance: CGFloat) -> CGRect {
            let dx = direction.dx, dy = direction.dy
            let offset = abs(dx) * width / 2 + abs(dy) * height / 2 + clearance
            let x = max(bounds.minX, min(head.tip.x + dx * offset - width / 2, bounds.maxX - width))
            let y = max(bounds.minY, min(head.tip.y + dy * offset - height / 2, bounds.maxY - height))
            return CGRect(x: x, y: y, width: width, height: height)
        }

        let dx = head.direction.dx, dy = head.direction.dy
        // Beside the head first: past the tip the badge covers whatever the arrow points at.
        for direction in [CGVector(dx: -dy, dy: dx), CGVector(dx: dy, dy: -dx)] {
            let edgeX = direction.dx >= 0 ? head.bounds.maxX : head.bounds.minX
            let edgeY = direction.dy >= 0 ? head.bounds.maxY : head.bounds.minY
            let clearance = (edgeX - head.tip.x) * direction.dx + (edgeY - head.tip.y) * direction.dy
            let side = badge(toward: direction, clearance: clearance + gap)
            if !side.intersects(head.bounds) { return side }
        }
        return badge(toward: head.direction, clearance: gap)
    }

    private static func drawBadge(_ mark: Stroke, at anchor: CGPoint, arrowhead: Arrowhead?, in context: CGContext,
                                  bounds: CGRect, requestedHeight: CGFloat, scale: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(red)
        let height: CGFloat
        if arrowhead != nil {
            let widthAtOnePoint = MarkBadgeGeometry.numberedBadgeWidth(id: mark.id, height: 1)
            height = min(requestedHeight, bounds.height, bounds.width / widthAtOnePoint)
        } else {
            height = requestedHeight
        }
        let magnification = height / badgeHeight
        let text = NSAttributedString(string: String(mark.id.rawValue), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 12 * magnification, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let badge: CGRect
        if mark.shape == .pin {
            let dot = Point(x: anchor.x - bounds.minX, y: bounds.maxY - anchor.y)
            let pinBadge = MarkBadgeGeometry.pinBadge(at: dot, in: Size(width: bounds.width, height: bounds.height),
                                                      id: mark.id, height: height, gap: MarkBadgeGeometry.pinGap * scale)
            badge = CGRect(x: bounds.minX + pinBadge.origin.x, y: bounds.maxY - pinBadge.origin.y - height,
                           width: pinBadge.size.width, height: height)
        } else if let arrowhead {
            let width = MarkBadgeGeometry.numberedBadgeWidth(id: mark.id, height: height)
            let badgeAnchor: Arrowhead
            if case .arrow(_, _?) = mark.shape {
                badgeAnchor = Arrowhead(tip: anchor,
                                       direction: CGVector(dx: -arrowhead.direction.dx, dy: -arrowhead.direction.dy),
                                       bounds: CGRect(origin: anchor, size: .zero)
                                           .insetBy(dx: -inkWidth * scale / 2, dy: -inkWidth * scale / 2))
            } else {
                badgeAnchor = arrowhead
            }
            badge = arrowBadge(beyond: badgeAnchor, width: width, height: height,
                               gap: MarkBadgeGeometry.arrowGap * scale, in: bounds)
        } else {
            let width = max(height, ceil(ink.width) + 10 * magnification)
            let x = max(bounds.minX, min(anchor.x - width / 2, bounds.maxX - width))
            let y = max(bounds.minY, min(anchor.y - height / 2, bounds.maxY - height))
            badge = CGRect(x: x, y: y, width: width, height: height)
        }
        context.addPath(CGPath(roundedRect: badge, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: badge.midX - ink.midX, y: badge.midY - ink.midY)
        CTLineDraw(line, context)
    }
}
