import AppKit
import PilcrowCore

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

class OverlayPanel: NSPanel {
    // Accessory app + screenSaver level for other apps' full-screen Spaces. On macOS 26
    // canJoinAllApplications also opts a floating panel into other apps' Stage Manager sets.
    // Its mutually exclusive peers are primary/auxiliary, distinct from fullScreenAuxiliary.
    static let overlaySpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .canJoinAllApplications]

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = Self.overlaySpaces
    }

    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class CanvasPanel: OverlayPanel {
    override init(frame: NSRect) {
        super.init(frame: frame)
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
}

final class Canvas: NSView {
    weak var session: AnnotationSession?
    let display: CGDirectDisplayID
    private var pointer = NSPoint.zero
    private var ring = false
    private var hintFrame = NSRect.zero
    private static let hintText = NSAttributedString(string: "Hold ⇧ and drag · say what you want", attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white
    ])

    private static let hintSize = hintText.size()

    func updatePointer(_ point: NSPoint, ring: Bool, hint: Bool, visible: NSRect) {
        var next = NSRect.zero
        if hint {
            let width = min(Self.hintSize.width + 20, max(0, visible.width - 8))
            let height = Self.hintSize.height + 12
            let x = max(visible.minX + 4, min(point.x + 18, visible.maxX - width - 4))
            let y = max(visible.minY + 4, min(point.y - height - 16, visible.maxY - height - 4))
            next = NSRect(x: x, y: y, width: width, height: height)
        }
        if !ring && !self.ring && next.isEmpty && hintFrame.isEmpty { return }
        guard pointer != point || self.ring != ring || hintFrame != next else { return }
        if self.ring { setNeedsDisplay(NSRect(x: pointer.x - 13, y: pointer.y - 13, width: 26, height: 26)) }
        if !hintFrame.isEmpty { setNeedsDisplay(hintFrame.insetBy(dx: -1, dy: -1)) }
        pointer = point
        self.ring = ring
        hintFrame = next
        if ring { setNeedsDisplay(NSRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26)) }
        if !next.isEmpty { setNeedsDisplay(next.insetBy(dx: -1, dy: -1)) }
    }

    init(display: CGDirectDisplayID, size: CGSize, session: AnnotationSession) {
        self.display = display
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        // A zero-alpha region can pass hits through a borderless window even when drawing is armed.
        context.setFillColor(CGColor(gray: 0, alpha: 0.01))
        context.fill(dirtyRect)
        let frameSize = Size(width: bounds.width, height: bounds.height)
        MarkRenderer.draw(session?.visibleMarks(on: display) ?? [], in: context, bounds: bounds,
                          frameSize: frameSize) { point in
            CGPoint(x: bounds.minX + point.x * bounds.width,
                    y: bounds.minY + (1 - point.y) * bounds.height)
        }
        if ring {
            context.setStrokeColor(CGColor(srgbRed: 0.89, green: 0.08, blue: 0.12, alpha: 0.85))
            context.setLineWidth(2)
            context.strokeEllipse(in: NSRect(x: pointer.x - 10, y: pointer.y - 10, width: 20, height: 20))
        }
        if !hintFrame.isEmpty {
            NSColor(white: 0.16, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: hintFrame, xRadius: hintFrame.height / 2, yRadius: hintFrame.height / 2).fill()
            Self.hintText.draw(in: hintFrame.insetBy(dx: 10, dy: 6))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard AnnotationSession.isDrawingShift(event.modifierFlags),
              let point = screenPoint(for: event) else { return }
        session?.begin(on: display, at: point, timestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        if let point = screenPoint(for: event) {
            session?.extend(on: display, to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let point = screenPoint(for: event) {
            session?.extend(on: display, to: point)
        }
        session?.endStroke(on: display, at: event.timestamp)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint? {
        window?.convertPoint(toScreen: event.locationInWindow)
    }
}
