import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let hotKeys: HotKeys
    private let recorder: ShortcutRecorder
    private let permissions: Permissions
    private let outbox: OutboxStore
    private let canClear: () -> Bool
    private let changed: () -> Void
    private let model = SettingsPresentation()
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    private var contentObservation: AnyCancellable?
    private var resizeScheduled = false
    private var monitor: Any?
    private var previousApp: NSRunningApplication?
    private var copyFeedback: [MCPSetupAgent: Task<Void, Never>] = [:]
    private var captureRefresh: Task<Void, Never>?

    init(hotKeys: HotKeys, recorder: ShortcutRecorder, permissions: Permissions, outbox: OutboxStore,
         colour: PilcrowColour, canClear: @escaping () -> Bool, clear: @escaping () -> Void,
         colourChanged: @escaping (PilcrowColour) -> Void, changed: @escaping () -> Void) {
        self.hotKeys = hotKeys
        self.recorder = recorder
        self.permissions = permissions
        self.outbox = outbox
        self.canClear = canClear
        self.changed = changed
        super.init()
        window.title = "Pilcrow Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        model.colour = colour
        model.colourChanged = colourChanged
        model.record = { [weak self] in self?.record($0) }
        model.reset = { [weak self] in self?.reset($0) }
        model.copy = { [weak self] in self?.copyCommand($0) }
        model.screenAccess = { [weak self] in self?.permissions.requestScreenAccess() }
        model.microphoneAccess = { [weak self] in self?.permissions.turnOnVoice() }
        model.reopen = { [weak self] in self?.permissions.reopen() }
        model.showCaptures = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.outbox.root])
        }
        model.clearCaptures = clear
        permissions.changed = { [weak self] in self?.refreshAccess() }
        refreshLabels()
        refreshAccess()
        window.contentView = NSHostingView(rootView: SettingsStoryView(model: model))
        contentObservation = model.objectWillChange.sink { [weak self] _ in self?.scheduleResize() }
        scheduleResize()
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard let content = self.window.contentView else { return }
            let top = self.window.frame.maxY
            self.window.setContentSize(NSSize(width: 440, height: ceil(content.fittingSize.height)))
            self.window.setFrameOrigin(NSPoint(x: self.window.frame.minX, y: top - self.window.frame.height))
        }
    }

    func show() {
        if !window.isVisible {
            if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current { previousApp = frontmost }
            window.center()
        }
        permissions.beginObserving()
        refreshCaptures()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { stopRecording(); window.close() }
    func windowDidBecomeKey(_ notification: Notification) {
        permissions.refresh()
        refreshCaptures()
    }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }
    func windowWillClose(_ notification: Notification) {
        stopRecording()
        permissions.endObserving()
        if NSRunningApplication.current.isActive { _ = previousApp?.activate() }
        previousApp = nil
    }

    private func record(_ shortcut: HotKeys.Shortcut) {
        stopRecording()
        recorder.begin(shortcut)
        model.recording = shortcut
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                // Subtype 8 is media/brightness input without fn. Other system events are not keys.
                let mediaKey = event.type == .systemDefined && event.subtype.rawValue == 8
                guard let self, self.recorder.isRecording, event.type != .systemDefined || mediaKey,
                      event.window === self.window || (mediaKey && self.window.isKeyWindow) else { return false }
                self.capture(event)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func capture(_ event: NSEvent) {
        guard let shortcut = recorder.recording else { return }
        if event.type == .systemDefined {
            recorder.unusableKey()
            model.rejection = nil
            model.recorderNote = recorder.message
            return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let input = KeyChord(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        accept(input.isResetKey ? shortcut.defaultChord : input, shortcut: shortcut, reset: input.isResetKey)
    }

    private func reset(_ shortcut: HotKeys.Shortcut) {
        if recorder.recording != shortcut { record(shortcut) }
        accept(shortcut.defaultChord, shortcut: shortcut, reset: true)
    }

    private func accept(_ chord: KeyChord, shortcut: HotKeys.Shortcut, reset: Bool) {
        let other = hotKeys.chord(for: shortcut == .annotate ? .undo : .annotate)
        let accepted = recorder.accept(chord, other: other) {
            if reset { hotKeys.settings.reset(shortcut) }
            else if shortcut == .annotate { hotKeys.settings.start = chord }
            else { hotKeys.settings.undo = chord }
            hotKeys.settings.save(to: .standard)
        }
        model.recording = recorder.recording
        if accepted {
            model.rejection = nil
            model.recorderNote = recorder.message
            changed()
        } else {
            model.rejection = SettingsRejection(shortcut: shortcut, glyph: chord.glyph, reason: recorder.message)
        }
        if !recorder.isRecording { removeMonitor() }
        refreshLabels()
    }

    func refreshLabels() {
        model.start = hotKeys.label(for: .annotate)
        model.undo = hotKeys.label(for: .undo)
    }

    private func refreshAccess() {
        model.updateAccess(screenRecording: permissions.screenGranted, microphone: permissions.microphone,
                           canStart: permissions.canStart, voiceStatus: permissions.voiceStatus,
                           voiceAction: permissions.voiceAction, voiceActionEnabled: permissions.voiceActionEnabled)
        model.reopenMessage = permissions.reopenMessage
        model.canReopen = permissions.canReopen
    }

    func refreshCaptures() {
        model.canClear = false
        captureRefresh?.cancel()
        captureRefresh = Task { [weak self] in
            guard let self else { return }
            let hasCaptures = await outbox.hasClearableCaptures()
            guard !Task.isCancelled else { return }
            model.canClear = hasCaptures && canClear()
        }
    }

    private func copyCommand(_ agent: MCPSetupAgent) {
        let command = MCPSetupCommand.build(for: agent)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command, forType: .string) else {
            model.copyError = "Couldn’t copy setup command."
            return
        }
        model.copyError = ""
        model.copied.insert(agent)
        copyFeedback[agent]?.cancel()
        copyFeedback[agent] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.model.copied.remove(agent)
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func stopRecording() {
        removeMonitor()
        recorder.stop()
        model.recording = nil
        model.rejection = nil
        model.recorderNote = ""
        refreshLabels()
    }
}
