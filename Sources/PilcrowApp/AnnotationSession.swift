import AppKit
import PilcrowCore
import os

let stateLog = Logger(subsystem: "org.pilcrow.app", category: "session")

@MainActor
final class AnnotationSession {
    enum Trigger: String {
        case hotkey, escape = "Esc", pill = "pill Finish", menu = "¶ menu"
        case displayChange = "display change"
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
    private var narration: VoiceNarration?
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
    private var arming = ShiftArming()
    private var buttonWasUp = false
    private var lastStrokeEnd: TimeInterval?
    private var needsNewPass = false
    private var pass = 1
    private var hint = SessionHint(previousCount: 3)
    private var ended = false
    private var finishStartedAt: TimeInterval = 0
    private var hudAnchor = CGRect.zero
    private let outbox: OutboxStore
    private let exports: ExportStore
    private let hotKeys: HotKeys
    let colour: PilcrowColour
    private let closing: () -> Void
    private let completed: (ApprovalExport?, String) -> Void

    init(exports: ExportStore, outbox: OutboxStore, hotKeys: HotKeys, colour: PilcrowColour,
         closing: @escaping () -> Void, completed: @escaping (ApprovalExport?, String) -> Void) {
        self.outbox = outbox
        self.exports = exports
        self.hotKeys = hotKeys
        self.colour = colour
        self.closing = closing
        self.completed = completed
    }

    func open() -> Bool {
        let screens = NSScreen.screens.filter { $0.displayID != nil }
        let pointer = NSEvent.mouseLocation
        guard let screen = screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? screens.first else {
            return false
        }
        hint = SessionHint(previousCount: UserDefaults.standard.integer(forKey: SessionHint.defaultsKey))
        UserDefaults.standard.set(hint.nextCount, forKey: SessionHint.defaultsKey)
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
        toolbar?.orderFrontRegardless()
        stateLog.notice("Session opened")
        let narration = VoiceNarration(sessionStart: t0) { [weak self] words, languageCode in
            self?.core.setTranscript(words: words, languageCode: languageCode)
        }
        self.narration = narration
        narration.start()
        updateVoiceFeedback()
        return true
    }

    static func isDrawingShift(_ flags: NSEvent.ModifierFlags) -> Bool {
        // Caps Lock and numeric-pad flags do not represent a simultaneous shortcut.
        flags.intersection([.shift, .control, .option, .command, .function]) == .shift
    }

    private func installInputHandlers() {
        let escapeRegistered = hotKeys.register(.escape) { [weak self] in self?.finish(.escape) }
        var unavailable: [HotKeys.Shortcut] = []
        if !hotKeys.isRegistered(.annotate) { unavailable.append(.annotate) }
        if !escapeRegistered { unavailable.append(.escape) }
        if !unavailable.isEmpty {
            stateLog.notice("Session shortcuts unavailable: \(unavailable.map { self.hotKeys.label(for: $0) }.joined(separator: ", "), privacy: .public)")
        }
        toolbar?.showUnavailableShortcuts(unavailable.map { self.hotKeys.label(for: $0) })
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.ended, self.activeStroke == nil else { return }
                if event.type == .leftMouseDown, Self.isDrawingShift(event.modifierFlags) {
                    let point = NSEvent.mouseLocation
                    guard !(self.toolbar.map { NSMouseInRect(point, $0.frame, false) } ?? false),
                          let display = self.panels.first(where: { NSMouseInRect(point, $0.value.frame, false) })?.key else { return }
                    // Click-through panels cannot receive an early Shift-click. The existing
                    // permission-free mouse monitor starts that pin without waiting for a tick.
                    self.arming.update(shiftHeld: true, now: event.timestamp, mouseDown: true)
                    self.begin(on: display, at: point, timestamp: event.timestamp)
                    return
                }
                guard let lastStrokeEnd = self.lastStrokeEnd, event.timestamp - self.t0 >= lastStrokeEnd else { return }
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
        let shiftHeld = Self.isDrawingShift(NSEvent.modifierFlags)
        let armed = arming.update(shiftHeld: shiftHeld, now: ProcessInfo.processInfo.systemUptime)
        let targets = PointerTargets(
            activeStroke: activeStroke?.frame.displayID,
            underPointer: panels.first { NSMouseInRect(pointer, $0.value.frame, false) }?.key,
            aboveToolbar: aboveToolbar, shiftHeld: shiftHeld, armed: armed)
        let armedDisplay = targets.ring

        for (display, panel) in panels {
            let ignoresMouse = display != targets.capture
            if panel.ignoresMouseEvents != ignoresMouse { panel.ignoresMouseEvents = ignoresMouse }
            let underPointer = NSMouseInRect(pointer, panel.frame, false) && !aboveToolbar
            let local = NSPoint(x: pointer.x - panel.frame.minX, y: pointer.y - panel.frame.minY)
            let visible = (panel.screen?.visibleFrame ?? panel.frame)
                .offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            (panel.contentView as? Canvas)?.updatePointer(local, ring: underPointer && armed,
                                                        hint: underPointer && hint.showsHint, visible: visible)
        }
        if armedDisplay != nil {
            if previousCursor == nil { previousCursor = NSCursor.current }
            NSCursor.crosshair.set()
        } else {
            restoreCursor()
        }
        toolbar?.updateVisibleFrame()
        updateVoiceFeedback()
    }

    private func updateVoiceFeedback() {
        guard let narration else { return }
        toolbar?.updateVoice(narration.feedback, level: narration.level)
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
            hint.strokeStarted()
            updateInput()
            toolbar?.clearError()
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
        updateUndoHotKey()
        panels[activeStroke.frame.displayID]?.contentView?.needsDisplay = true
    }

    private var currentMarks: [Stroke] {
        let ids = Set(currentFrameIDs.values)
        return core.liveMarks.filter { ids.contains($0.frameID) }
    }

    func undo() {
        guard !ended, activeStroke == nil else { return }
        core.undoLatestMark(in: Set(currentFrameIDs.values))
        refresh()
    }

    func keyboardLayoutChanged() {
        hotKeys.unregister(.undo)
        updateUndoHotKey()
    }

    private func updateUndoHotKey() {
        let wanted = !ended && UndoAvailability.shouldRegister(markCount: currentMarks.count, drawing: activeStroke != nil)
        if wanted {
            if !hotKeys.isRegistered(.undo) {
                _ = hotKeys.register(.undo) { [weak self] in self?.undo() }
            }
        } else { hotKeys.unregister(.undo) }
        let unavailable = [HotKeys.Shortcut.annotate, .escape, .undo].filter {
            ($0 != .undo || wanted) && !hotKeys.isRegistered($0)
        }
        toolbar?.showUnavailableShortcuts(unavailable.map { hotKeys.label(for: $0) })
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
            if !ended { toolbar?.showError(failure.rawValue) }
        } catch {
            reportCoreError(error, during: "record the capture failure")
        }
    }

    private func reportCoreError(_ error: Error, during operation: String) {
        stateLog.error("Could not \(operation, privacy: .public): \(String(describing: error), privacy: .public)")
        if !ended { toolbar?.showError("Couldn’t " + operation) }
    }

    private func refresh() {
        updateUndoHotKey()
        for panel in panels.values { panel.contentView?.needsDisplay = true }
    }

    func stopVoice() { narration?.stop() }

    func finish(_ trigger: Trigger) {
        guard !ended else { return }
        finishStartedAt = ProcessInfo.processInfo.systemUptime
        ended = true
        // Use the display under the pointer at Finish, including speech-only sessions.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? toolbar?.screen ?? NSScreen.main
        if let area = screen?.visibleFrame {
            hudAnchor = CGRect(x: area.maxX - 320 - 12, y: area.minY + 12, width: 320, height: 56)
        }
        narration?.finish()
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
            await narration?.wait()
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

        let id = UUID()
        let folder: URL
        do {
            folder = try await outbox.prepare(id)
        } catch {
            do { folder = try await exports.prepare() }
            catch {
                stateLog.error("Could not prepare a recovery export folder")
                // Text can still be copied even when no storage is writable.
                let spoken = FixList.build(session: core).transcript
                completed(ApprovalExport(id: id, folder: outbox.folder(for: id),
                    text: DeliveryText.approved(coreText: message.text, failedImages: message.attachments),
                    attachments: [], imageData: [], marks: [], spokenSummary: spoken,
                    hudAnchor: hudAnchor, finishStartedAt: finishStartedAt), "Couldn’t save capture")
                return
            }
        }

        let snapshot = core
        let images = originals
        let voiceResults = narration?.voiceResults ?? VoiceRecording.Results()
        let result = await Task.detached { [colour] in
            Export.write(session: snapshot, message: message, originals: images, to: folder,
                         voiceResults: voiceResults, colour: colour)
        }.value
        if !result.failedFiles.isEmpty { notes += " · \(result.failedFiles.count) files failed" }

        let count = result.attachments.count
        await exports.keepOnly(folder)
        var summary = count == 0 ? "Exported message" : "Exported \(count) " + (count == 1 ? "PNG" : "PNGs")
        if count > 0, result.messageWritten { summary += " and message" }
        stateLog.notice("\(summary, privacy: .public)\(notes, privacy: .public)")
        let missingFiles = message.attachments.filter { !result.attachments.contains($0) }
        let text = DeliveryText.approved(coreText: message.text, failedImages: missingFiles)
        let cropMarks = Dictionary(uniqueKeysWithValues: snapshot.liveMarks.map { ("mark-\($0.id.rawValue).png", $0.id.rawValue) })
        let attachments = result.attachments.map { name in
            OutboxManifest.Attachment(name: name, kind: cropMarks[name] == nil ? .frame : .crop, mark: cropMarks[name])
        }
        let list = FixList.build(session: snapshot, onlyFinal: false)
        let marks = list.items.map {
            ApprovalExport.Mark(number: $0.mark.rawValue, words: $0.words, thumbnail: result.thumbnails[$0.cropName])
        }
        completed(ApprovalExport(id: id, folder: folder, text: text, attachments: attachments,
            imageData: result.attachments.compactMap { result.imageData[$0] }, marks: marks,
            spokenSummary: list.transcript, hudAnchor: hudAnchor, finishStartedAt: finishStartedAt), summary + notes)
    }
}
