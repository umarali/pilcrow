import Foundation
import CoreGraphics
import CoreText

final class Mark {
    let number: Int
    let start: CGPoint
    private var previous: CGPoint
    private var moved = false
    private let path = CGMutablePath()

    init(number: Int, start: CGPoint) {
        self.number = number
        self.start = start
        previous = start
        path.move(to: start)
    }

    func append(_ point: CGPoint) {
        guard point != previous else { return }
        let midpoint = CGPoint(x: (point.x + previous.x) / 2, y: (point.y + previous.y) / 2)
        path.addQuadCurve(to: midpoint, control: previous)
        previous = point
        moved = true
    }

    func snapshot() -> MarkSnapshot {
        MarkSnapshot(number: number, start: start, path: path, end: moved ? previous : nil)
    }

    func draw(in context: CGContext, bounds: CGRect) {
        MarkSnapshot.draw(number: number, start: start, path: path, end: moved ? previous : nil,
                          in: context, bounds: bounds)
    }
}

// The SDK does not mark CGPath Sendable. This snapshot owns an immutable copy
// and never exposes it, so the export task cannot share the live CGMutablePath.
struct MarkSnapshot: @unchecked Sendable {
    private static let badgeHeight: CGFloat = 20

    private let number: Int
    private let start: CGPoint
    private let path: CGPath?
    private let end: CGPoint?

    fileprivate init(number: Int, start: CGPoint, path: CGPath, end: CGPoint?) {
        self.number = number
        self.start = start
        self.path = path.copy()
        self.end = end
    }

    func draw(in context: CGContext, bounds: CGRect, pixelsPerPoint: CGFloat) {
        let magnification = max(1, 24 / (Self.badgeHeight * pixelsPerPoint))
        Self.draw(number: number, start: start, path: path, end: end,
                  in: context, bounds: bounds, magnification: magnification)
    }

    fileprivate static func draw(number: Int, start: CGPoint, path: CGPath?, end: CGPoint?,
                                 in context: CGContext, bounds: CGRect, magnification: CGFloat = 1) {
        context.saveGState()
        defer { context.restoreGState() }
        let red = CGColor(srgbRed: 0.89, green: 0.08, blue: 0.12, alpha: 1)
        context.setStrokeColor(red)
        context.setFillColor(red)
        let stroke = 3 * magnification
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if let path, let end {
            context.addPath(path)
            context.addLine(to: end)
            context.strokePath()
        } else {
            context.fillEllipse(in: CGRect(x: start.x - stroke / 2, y: start.y - stroke / 2,
                                           width: stroke, height: stroke))
        }
        let text = NSAttributedString(string: String(number), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 12 * magnification, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let height = badgeHeight * magnification
        let width = max(height, ceil(ink.width) + 10 * magnification)
        let x = max(0, min(start.x - width / 2, bounds.width - width))
        let y = max(0, min(start.y - height / 2, bounds.height - height))
        let badge = CGRect(x: x, y: y, width: width, height: height)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: badge.midX - ink.midX, y: badge.midY - ink.midY)
        CTLineDraw(line, context)
    }
}
