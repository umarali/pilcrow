import AppKit

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
        for mark in session?.visibleMarks(on: display) ?? [] {
            MarkRenderer.draw(mark, in: context, bounds: bounds) { point in
                CGPoint(x: bounds.minX + point.x * bounds.width,
                        y: bounds.minY + (1 - point.y) * bounds.height)
            }
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
