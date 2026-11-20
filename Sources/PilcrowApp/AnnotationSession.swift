import AppKit
import PilcrowCore
import os

let stateLog = Logger(subsystem: "org.pilcrow.app", category: "session")

@MainActor
final class AnnotationSession {
    enum Trigger: String {
        case hotkey, escape = "Esc", pill = "pill Finish", menu = "¶ menu"
        case permissionsWindow = "permissions window Start", displayChange = "display change"
    }

    private struct Display {
        let origin: Point
        let bounds: Size
        let scale: CGFloat

        init(_ screen: NSScreen) {
            origin = Point(x: screen.frame.minX, y: screen.frame.minY)
            bounds = Size(width: screen.frame.width, height: screen.frame.height)
            scale = screen.backingScaleFactor
        }
    }

    private var panels: [CGDirectDisplayID: CanvasPanel] = [:]
    private var toolbar: Toolbar?
    private var mouseMonitor: Any?
    private var inputTimer: Timer?
    private var previousCursor: NSCursor?
    private var core = Session()
    private var t0: TimeInterval = 0
    private var displays: [CGDirectDisplayID: Display] = [:]
    private var currentFrameIDs: [CGDirectDisplayID: Frame.ID] = [:]
    private var pendingCaptures: [Frame.ID: CaptureTask] = [:]
    private var originals: [Frame.ID: CGImage] = [:]
    private var captureFailures: [Frame.ID: CaptureFailure] = [:]
    private var activeStroke: (id: MarkID, frame: Frame)?
    private var buttonWasUp = false
    private var lastStrokeEnd: TimeInterval?
    private var needsNewPass = false
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
        t0 = ProcessInfo.processInfo.systemUptime
        for item in screens {
            guard let id = item.displayID else { continue }
            displays[id] = Display(item)
            let panel = CanvasPanel(frame: item.frame)
            panel.contentView = Canvas(display: id, size: item.frame.size, session: self)
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
                guard let self, !self.ended, self.activeStroke == nil,
                      let lastStrokeEnd = self.lastStrokeEnd, event.timestamp - self.t0 >= lastStrokeEnd else { return }
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
        if activeStroke != nil {
            let buttonIsUp = NSEvent.pressedMouseButtons & 1 == 0
            if buttonIsUp && buttonWasUp {
                completeStroke(at: ProcessInfo.processInfo.systemUptime)
                stateLog.notice("Stroke ended after mouse release without mouse-up")
            } else {
                buttonWasUp = buttonIsUp
            }
        }
        let pointer = NSEvent.mouseLocation
        let aboveToolbar = toolbar.map { NSMouseInRect(pointer, $0.frame, false) } ?? false
        let armedDisplay: CGDirectDisplayID?
        if let activeStroke {
            armedDisplay = activeStroke.frame.displayID
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
        guard let previousCursor else { return }
        previousCursor.set()
        self.previousCursor = nil
    }

    func visibleMarks(on display: CGDirectDisplayID) -> [Stroke] {
        guard let frameID = currentFrameIDs[display] else { return [] }
        return core.liveMarks.filter { $0.frameID == frameID }
    }

    func begin(on display: CGDirectDisplayID, at point: CGPoint, timestamp: TimeInterval) {
        guard !ended, activeStroke == nil, let geometry = displays[display] else { return }
        let existingID = needsNewPass ? nil : currentFrameIDs[display]
        let frame: Frame
        if let existingID {
            guard let registered = core.frames.first(where: { $0.id == existingID }) else {
                reportCoreError(Session.ValidationError.unknownFrameID, during: "find the current frame")
                return
            }
            frame = registered
        } else {
            frame = Frame(id: Frame.ID(), displayID: display, boundsInPoints: geometry.bounds)
        }
        guard let firstPoint = normalized(point, in: frame) else { return }

        if existingID == nil {
            do {
                try core.addFrame(frame)
            } catch {
                reportCoreError(error, during: "register the frame")
                return
            }
            let capturePass = needsNewPass ? pass + 1 : pass
            pendingCaptures[frame.id] = CaptureTask(frame: frame, scale: geometry.scale) { [weak self] result in
                self?.receiveCapture(result, for: frame.id, display: display, pass: capturePass)
            }
        }
        do {
            let mark = try core.beginStroke(at: timestamp - t0, frame: frame.id, firstPoint: firstPoint)
            if needsNewPass {
                pass += 1
                needsNewPass = false
                currentFrameIDs = [display: frame.id]
                discardUnusedCaptures()
            } else {
                currentFrameIDs[display] = frame.id
            }
            activeStroke = (mark, frame)
            refresh()
        } catch {
            if existingID == nil { pendingCaptures[frame.id]?.cancel() }
            reportCoreError(error, during: "begin the stroke")
        }
    }

    func extend(on display: CGDirectDisplayID, to point: CGPoint) {
        guard let activeStroke, activeStroke.frame.displayID == display else { return }
        buttonWasUp = false
        guard let sample = normalized(point, in: activeStroke.frame) else { return }
        core.append(point: sample, to: activeStroke.id)
        panels[display]?.contentView?.needsDisplay = true
    }

    func endStroke(on display: CGDirectDisplayID, at timestamp: TimeInterval) {
        guard activeStroke?.frame.displayID == display else { return }
        completeStroke(at: timestamp)
        updateInput()
    }

    private func normalized(_ point: CGPoint, in frame: Frame) -> NormalizedPoint? {
        guard let origin = displays[frame.displayID]?.origin else { return nil }
        return Geometry.normalizedPoint(screenPoint: Point(x: point.x, y: point.y), frameOrigin: origin, frame: frame)
    }

    private func completeStroke(at uptime: TimeInterval) {
        guard let activeStroke else { return }
        let time = uptime - t0
        core.endStroke(id: activeStroke.id, at: time)
        self.activeStroke = nil
        buttonWasUp = false
        lastStrokeEnd = time
    }

    private var currentMarks: [Stroke] {
        let ids = Set(currentFrameIDs.values)
        return core.liveMarks.filter { ids.contains($0.frameID) }
    }

    func undo() {
        guard !ended, let latest = currentMarks.last else { return }
        core.deleteMark(id: latest.id)
        refresh()
    }

    func clearPass() {
        guard !ended else { return }
        for mark in currentMarks { core.deleteMark(id: mark.id) }
        refresh()
    }

    private func discardUnusedCaptures() {
        let retained = Set(core.liveMarks.map(\.frameID))
        for id in Array(pendingCaptures.keys) where !retained.contains(id) {
            pendingCaptures[id]?.cancel()
        }
        originals = originals.filter { retained.contains($0.key) }
        captureFailures = captureFailures.filter { retained.contains($0.key) }
    }

    private func receiveCapture(_ outcome: CaptureOutcome, for id: Frame.ID, display: CGDirectDisplayID, pass: Int) {
        pendingCaptures.removeValue(forKey: id)
        guard !core.isSealed else { return }
        guard let frame = core.frames.first(where: { $0.id == id }) else {
            reportCoreError(Session.ValidationError.unknownFrameID, during: "resolve the capture")
            return
        }
        guard !frame.isComplete, !frame.captureFailed else { return }

        let status: String
        switch outcome {
        case let .image(image, uptime):
            do {
                try core.completeFrame(id: id, pixelSize: Size(width: Double(image.width), height: Double(image.height)),
                                       capturedAt: uptime - t0)
                originals[id] = image
                status = "captured"
            } catch {
                reportCoreError(error, during: "complete the capture")
                recordCaptureFailure(.invalidCapture, for: id)
                status = CaptureFailure.invalidCapture.rawValue
            }
        case .failed(let failure):
            recordCaptureFailure(failure, for: id)
            status = failure.rawValue
        }
        stateLog.notice("Frame for pass \(pass, privacy: .public), display \(display, privacy: .public): \(status, privacy: .public)")
    }

    private func recordCaptureFailure(_ failure: CaptureFailure, for id: Frame.ID) {
        do {
            try core.failFrame(id: id)
            captureFailures[id] = failure
        } catch {
            reportCoreError(error, during: "record the capture failure")
        }
    }

    private func reportCoreError(_ error: Error, during operation: String) {
        stateLog.error("Could not \(operation, privacy: .public): \(String(describing: error), privacy: .public)")
        if !ended { toolbar?.showError("Couldn’t " + operation) }
    }

    private func refresh() {
        for panel in panels.values { panel.contentView?.needsDisplay = true }
        refreshToolbar()
    }

    private func refreshToolbar() {
        toolbar?.update(marks: core.liveMarks.count, hasCurrentMarks: !currentMarks.isEmpty)
    }

    func finish(_ trigger: Trigger) {
        guard !ended else { return }
        ended = true
        completeStroke(at: ProcessInfo.processInfo.systemUptime)
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
        discardUnusedCaptures()
        let captures = core.framesWithMarks.compactMap { pendingCaptures[$0.id] }
        Task {
            for capture in captures { await capture.wait() }
            core.seal()
            let message = MessageBuilder.build(session: core, onlyFinal: false)
            guard !message.isEmpty else {
                stateLog.notice("Nothing to send")
                completed(nil, "Nothing to send")
                return
            }
            await export(message)
        }
    }

    private func export(_ message: OutgoingMessage) async {
        let timedOut = captureFailures.values.count { $0 == .timedOut }
        let invalid = captureFailures.values.count { $0 == .invalidCapture }
        let missing = message.failedImages.count
        var notes = ""
        if missing > 0 { notes += " · \(missing) without a frame" }
        if captureFailures.values.contains(.permissionNeeded) { notes += " · Screen Recording off" }
        if timedOut > 0 { notes += " · \(timedOut) timed out" }
        if invalid > 0 { notes += " · \(invalid) invalid captures" }

        let folder: URL
        do {
            folder = try exports.prepare()
        } catch {
            stateLog.error("Could not prepare the export folder: \(String(describing: error), privacy: .public)")
            completed(nil, "Couldn’t write the export" + notes)
            return
        }

        let snapshot = core
        let images = originals
        let result = await Task.detached {
            Export.write(session: snapshot, message: message, originals: images, to: folder)
        }.value
        if !result.failedFiles.isEmpty { notes += " · \(result.failedFiles.count) files failed" }

        let count = result.attachments.count
        guard count > 0 || result.messageWritten else {
            exports.discard(folder)
            completed(nil, "Couldn’t write the export" + notes)
            return
        }

        exports.keepOnly(folder)
        var summary = count == 0 ? "Exported message" : "Exported \(count) " + (count == 1 ? "PNG" : "PNGs")
        if count > 0, result.messageWritten { summary += " and message" }
        stateLog.notice("\(summary, privacy: .public)\(notes, privacy: .public)")
        completed(folder, summary + notes)
    }
}
