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
    let geometry: FrameGeometry

    init(_ geometry: FrameGeometry, session: AnnotationSession) {
        self.geometry = geometry
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: geometry.size))
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
        for mark in session?.visibleMarks(on: geometry.display) ?? [] {
            mark.draw(in: context, bounds: bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard AnnotationSession.isDrawingShift(event.modifierFlags) else { return }
        session?.begin(on: geometry, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        session?.extend(on: geometry.display, to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        session?.extend(on: geometry.display, to: convert(event.locationInWindow, from: nil))
        session?.endStroke(on: geometry.display, at: event.timestamp)
    }
}
