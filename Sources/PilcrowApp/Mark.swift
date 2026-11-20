import Foundation
import CoreGraphics
import CoreText
import PilcrowCore

enum MarkRenderer {
    private static let badgeHeight: CGFloat = 20

    static func draw(_ mark: Stroke, in context: CGContext, bounds: CGRect,
                     pixelsPerPoint: CGFloat = 1, minimumBadgeHeight: CGFloat = 0,
                     project: (NormalizedPoint) -> CGPoint?) {
        guard let anchor = project(mark.badgeAnchor) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let red = CGColor(srgbRed: 0.89, green: 0.08, blue: 0.12, alpha: 1)
        context.setStrokeColor(red)
        context.setFillColor(red)
        let stroke = 3 * pixelsPerPoint
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let path = CGMutablePath()
        var previous = anchor
        var moved = false
        path.move(to: anchor)
        for sample in mark.points {
            guard let point = project(sample), point != previous else { continue }
            let midpoint = CGPoint(x: (point.x + previous.x) / 2, y: (point.y + previous.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
            previous = point
            moved = true
        }
        if moved {
            path.addLine(to: previous)
            context.addPath(path)
            context.strokePath()
        } else {
            context.fillEllipse(in: CGRect(x: anchor.x - stroke / 2, y: anchor.y - stroke / 2,
                                           width: stroke, height: stroke))
        }

        let height = max(badgeHeight * pixelsPerPoint, minimumBadgeHeight)
        let magnification = height / badgeHeight
        let text = NSAttributedString(string: String(mark.id.rawValue), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 12 * magnification, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = max(height, ceil(ink.width) + 10 * magnification)
        let x = max(bounds.minX, min(anchor.x - width / 2, bounds.maxX - width))
        let y = max(bounds.minY, min(anchor.y - height / 2, bounds.maxY - height))
        let badge = CGRect(x: x, y: y, width: width, height: height)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: badge.midX - ink.midX, y: badge.midY - ink.midY)
        CTLineDraw(line, context)
    }
}
