import AppKit
import os

let stateLog = Logger(subsystem: "org.pilcrow.app", category: "session")

@MainActor
private final class PassFrame {
    private static let captureTimeout: Duration = .seconds(5)

    let geometry: FrameGeometry
    let pass: Int
    var marks: [Mark] = []
    private var outcome: CaptureOutcome?
    private var capture: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var waiter: CheckedContinuation<CaptureOutcome, Never>?

    init(_ geometry: FrameGeometry, pass: Int) {
        self.geometry = geometry
        self.pass = pass
        let expires = ContinuousClock.now + Self.captureTimeout
        capture = Task { [weak self] in
            let result = await Capture.frame(geometry)
            guard !Task.isCancelled, let self else { return }
            let resolved: CaptureOutcome = ContinuousClock.now < expires ? result : .timedOut
            self.resolve(resolved)
        }
        // A stuck ScreenCaptureKit call cannot be cancelled. Finish is still bounded by
        // this timeout because it waits for the resolved outcome, not the capture task.
        deadline = Task { [weak self] in
            do { try await Task.sleep(until: expires, clock: .continuous) }
            catch { return }
            self?.resolve(.timedOut)
        }
    }

    func cancel() {
        resolve(.unavailable)
    }

    func result() async -> CaptureOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation {
            precondition(waiter == nil, "A frame supports one result waiter")
            waiter = $0
        }
    }

    private func resolve(_ result: CaptureOutcome) {
        guard outcome == nil else { return }
        outcome = result
        let status: String
        switch result {
        case .image: status = "captured"
        case .permissionNeeded: status = "permission needed"
        case .unavailable: status = "unavailable"
        case .timedOut: status = "timed out"
        }
        stateLog.notice("Frame for pass \(self.pass, privacy: .public), display \(self.geometry.display, privacy: .public): \(status, privacy: .public)")
        capture?.cancel()
        capture = nil
        deadline?.cancel()
        deadline = nil
        waiter?.resume(returning: result)
        waiter = nil
    }
}

@MainActor
final class AnnotationSession {
    enum Trigger: String {
        case hotkey, escape = "Esc", pill = "pill Finish", menu = "¶ menu"
        case permissionsWindow = "permissions window Start", displayChange = "display change"
    }

    private var panels: [CGDirectDisplayID: CanvasPanel] = [:]
    private var toolbar: Toolbar?
    private var mouseMonitor: Any?
    private var inputTimer: Timer?
    private var previousCursor: NSCursor?
    private var frames: [PassFrame] = []
    private var active: (frame: PassFrame, mark: Mark)?
    private var dragDisplay: CGDirectDisplayID?
    private var lastStrokeEnd: TimeInterval?
    private var needsNewPass = false
    private var nextNumber = 1
    private var pass = 1
    private var ended = false
    private let exports: ExportStore
    private let hotKeys: HotKeys
    private let closing: () -> Void
    private let completed: (URL?, String) -> Void

    init(exports: ExportStore, hotKeys: HotKeys,
         closing: @escaping () -> Void, completed: @escaping (URL?, String) -> Void) {
        self.exports = exports
        self.hotKeys = hotKeys
        self.closing = closing
        self.completed = completed
    }

    func open() -> Bool {
        let screens = NSScreen.screens.filter { $0.displayID != nil }
        let pointer = NSEvent.mouseLocation
        guard let screen = screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? screens.first else {
            return false
        }
        for item in screens {
            guard let id = item.displayID else { continue }
            let panel = CanvasPanel(frame: item.frame)
            let geometry = FrameGeometry(display: id, size: item.frame.size, scale: item.backingScaleFactor)
            panel.contentView = Canvas(geometry, session: self)
            panels[id] = panel
            panel.orderFrontRegardless()
        }
        toolbar = Toolbar(screen: screen, session: self)
        installInputHandlers()
        refreshToolbar()
        toolbar?.orderFrontRegardless()
        stateLog.notice("Session opened")
        return true
    }

    static func isDrawingShift(_ flags: NSEvent.ModifierFlags) -> Bool {
        // Caps Lock and numeric-pad flags do not represent a simultaneous shortcut.
        flags.intersection([.shift, .control, .option, .command, .function]) == .shift
    }

    private func installInputHandlers() {
        let escapeRegistered = hotKeys.register(.escape) { [weak self] in self?.finish(.escape) }
        let undoRegistered = hotKeys.register(.undo) { [weak self] in self?.undo() }
        var unavailable: [HotKeys.Shortcut] = []
        if !escapeRegistered { unavailable.append(.escape) }
        if !undoRegistered { unavailable.append(.undo) }
        if !unavailable.isEmpty {
            stateLog.notice("Session shortcuts unavailable: \(unavailable.map(\.label).joined(separator: ", "), privacy: .public)")
        }
        toolbar?.showUnavailableShortcuts(unavailable)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.ended, self.dragDisplay == nil,
                      let lastStrokeEnd = self.lastStrokeEnd, event.timestamp >= lastStrokeEnd else { return }
                self.needsNewPass = true
            }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateInput() }
        }
        inputTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateInput() {
        if dragDisplay != nil, NSEvent.pressedMouseButtons & 1 == 0 {
            completeStroke(at: ProcessInfo.processInfo.systemUptime)
            stateLog.notice("Stroke ended after mouse release without mouse-up")
        }
        let pointer = NSEvent.mouseLocation
        let aboveToolbar = toolbar.map { NSMouseInRect(pointer, $0.frame, false) } ?? false
        let armedDisplay: CGDirectDisplayID?
        if let dragDisplay {
            armedDisplay = dragDisplay
        } else if !aboveToolbar, Self.isDrawingShift(NSEvent.modifierFlags) {
            armedDisplay = panels.first { NSMouseInRect(pointer, $0.value.frame, false) }?.key
        } else {
            armedDisplay = nil
        }

        for (display, panel) in panels {
            let ignoresMouse = display != armedDisplay
            if panel.ignoresMouseEvents != ignoresMouse { panel.ignoresMouseEvents = ignoresMouse }
        }
        if armedDisplay != nil {
            if previousCursor == nil { previousCursor = NSCursor.current }
            NSCursor.crosshair.set()
        } else {
            restoreCursor()
        }
        toolbar?.updateVisibleFrame()
    }

    private func restoreCursor() {
        previousCursor?.set()
        previousCursor = nil
    }

    func visibleMarks(on display: CGDirectDisplayID) -> [Mark] {
        frames.first { $0.pass == pass && $0.geometry.display == display }?.marks ?? []
    }

    func begin(on geometry: FrameGeometry, at point: CGPoint) {
        guard !ended, dragDisplay == nil else { return }
        if needsNewPass {
            pass += 1
            needsNewPass = false
        }
        let frame: PassFrame
        if let existing = frames.first(where: { $0.pass == pass && $0.geometry == geometry }) {
            frame = existing
        } else {
            frame = PassFrame(geometry, pass: pass)
            frames.append(frame)
        }
        let mark = Mark(number: nextNumber, start: point)
        nextNumber += 1
        frame.marks.append(mark)
        active = (frame, mark)
        dragDisplay = geometry.display
        refresh()
    }

    func extend(on display: CGDirectDisplayID, to point: CGPoint) {
        guard let active, active.frame.geometry.display == display else { return }
        active.mark.append(point)
        panels[display]?.contentView?.needsDisplay = true
    }

    func endStroke(on display: CGDirectDisplayID, at timestamp: TimeInterval) {
        guard dragDisplay == display else { return }
        completeStroke(at: timestamp)
        updateInput()
    }

    private func completeStroke(at timestamp: TimeInterval) {
        active = nil
        dragDisplay = nil
        lastStrokeEnd = timestamp
    }

    func undo() {
        guard !ended else { return }
        let latest = frames.filter { $0.pass == pass }.max {
            ($0.marks.last?.number ?? 0) < ($1.marks.last?.number ?? 0)
        }
        guard let latest, latest.marks.popLast() != nil else { return }
        active = nil
        discardEmptyFrames()
        refresh()
    }

    func clearPass() {
        guard !ended else { return }
        active = nil
        for frame in frames where frame.pass == pass { frame.marks.removeAll() }
        discardEmptyFrames()
        refresh()
    }

    private func discardEmptyFrames() {
        frames.removeAll { frame in
            guard frame.marks.isEmpty else { return false }
            frame.cancel()
            return true
        }
    }

    private func refresh() {
        for panel in panels.values { panel.contentView?.needsDisplay = true }
        refreshToolbar()
    }

    private func refreshToolbar() {
        toolbar?.update(marks: frames.reduce(0) { $0 + $1.marks.count },
                        hasCurrentMarks: frames.contains { $0.pass == pass && !$0.marks.isEmpty })
    }

    func finish(_ trigger: Trigger) {
        guard !ended else { return }
        ended = true
        active = nil
        dragDisplay = nil
        hotKeys.unregister(.escape)
        hotKeys.unregister(.undo)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        inputTimer?.invalidate()
        inputTimer = nil
        toolbar?.orderOut(nil)
        for panel in panels.values { panel.orderOut(nil) }
        restoreCursor()
        closing()
        stateLog.notice("Session finished via \(trigger.rawValue, privacy: .public)")
        discardEmptyFrames()
        let marked = frames
        frames.removeAll()
        Task {
            var captured: [CapturedMarks] = []
            var timedOut = 0
            var permissionNeeded = false
            for frame in marked {
                switch await frame.result() {
                case let .image(image):
                    captured.append(CapturedMarks(image: image, geometry: frame.geometry,
                                                  marks: frame.marks.map { $0.snapshot() }))
                case .timedOut:
                    timedOut += 1
                case .permissionNeeded:
                    permissionNeeded = true
                case .unavailable:
                    break
                }
            }
            let timeoutNote = timedOut == 0 ? "" : " · \(timedOut) timed out"
            let permissionNote = permissionNeeded ? " · Screen Recording off" : ""
            guard !captured.isEmpty else {
                let result = marked.isEmpty ? "No marks to export" : "No frame to export"
                let message = result + permissionNote + timeoutNote
                stateLog.notice("Export skipped: \(message, privacy: .public)")
                completed(nil, message)
                return
            }
            do {
                let folder = try exports.prepare()
                do {
                    let ready = captured
                    try await Task.detached { try Export.write(ready, to: folder) }.value
                } catch {
                    exports.discard(folder)
                    throw error
                }
                exports.keepOnly(folder)
                let missing = marked.count - captured.count
                let suffix = missing == 0 ? "" : " · \(missing) without a frame"
                stateLog.notice("Export completed: \(captured.count, privacy: .public) PNGs, \(missing, privacy: .public) missing frames, \(timedOut, privacy: .public) timeouts")
                completed(folder, "Exported \(captured.count) PNG" + (captured.count == 1 ? "" : "s")
                          + suffix + permissionNote + timeoutNote)
            } catch {
                stateLog.notice("Export failed")
                completed(nil, "Couldn’t write the PNG export" + timeoutNote)
            }
        }
    }
}
