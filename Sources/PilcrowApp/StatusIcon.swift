import AppKit

@MainActor
enum StatusIcon {
    enum State { case idle, annotating, warning }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16))
            // The coordinates below are the supplied 18 × 18 mark, reflected into AppKit's y-up space.
            path.move(to: NSPoint(x: 7.5, y: 13.5))
            path.line(to: NSPoint(x: 13, y: 13.5))
            path.line(to: NSPoint(x: 13, y: 4.5))
            path.line(to: NSPoint(x: 11.5, y: 4.5))
            path.line(to: NSPoint(x: 11.5, y: 12))
            path.line(to: NSPoint(x: 9.5, y: 12))
            path.line(to: NSPoint(x: 9.5, y: 4.5))
            path.line(to: NSPoint(x: 8, y: 4.5))
            path.line(to: NSPoint(x: 8, y: 8.5))
            path.line(to: NSPoint(x: 7.5, y: 8.5))
            path.appendArc(withCenter: NSPoint(x: 7.5, y: 11), radius: 2.5,
                           startAngle: 270, endAngle: 90, clockwise: true)
            path.close()
            path.windingRule = .evenOdd
            (state == .annotating ? NSColor(srgbRed: 0.89, green: 0.08, blue: 0.12, alpha: 1) : .black).setFill()
            path.fill()
            return true
        }
        image.isTemplate = state != .annotating
        return image
    }
}
