import AppKit
import Carbon

@MainActor
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    private let hotKeys: HotKeys
    private let recorder: ShortcutRecorder
    private let changed: () -> Void
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 180),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private var fields: [HotKeys.Shortcut: NSButton] = [:]
    private let reason = NSTextField(labelWithString: "")
    private var monitor: Any?

    init(hotKeys: HotKeys, recorder: ShortcutRecorder, changed: @escaping () -> Void) {
        self.hotKeys = hotKeys
        self.recorder = recorder
        self.changed = changed
        super.init()
        window.title = "Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (shortcut, title) in [(HotKeys.Shortcut.annotate, "Start / finish"), (.undo, "Undo mark")] {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let field = NSButton(title: hotKeys.label(for: shortcut), target: self, action: #selector(record(_:)))
            field.bezelStyle = .rounded
            field.tag = Int(shortcut.rawValue)
            field.widthAnchor.constraint(equalToConstant: 234).isActive = true
            field.setAccessibilityLabel(title + " shortcut")
            field.toolTip = "Click to record. Esc cancels; Delete resets the default."
            fields[shortcut] = field
            stack.addArrangedSubview(NSStackView(views: [label, field]))
        }
        reason.font = .systemFont(ofSize: 11)
        reason.textColor = .secondaryLabelColor
        reason.maximumNumberOfLines = 2
        reason.setAccessibilityElement(true)
        stack.addArrangedSubview(reason)
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])
        window.contentView = content
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { stopRecording(); window.close() }
    func windowWillClose(_ notification: Notification) { stopRecording() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    @objc private func record(_ sender: NSButton) {
        stopRecording()
        guard let shortcut = HotKeys.Shortcut(rawValue: UInt32(sender.tag)) else { return }
        recorder.begin(shortcut)
        reason.stringValue = "Esc cancels · Delete resets · Press fn with the F-key"
        sender.title = "Press 2 keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                // System-defined subtype 8 is a media/brightness key (an F-key pressed without fn);
                // other subtypes, such as mouse-button changes (7), are not key presses.
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
            reason.stringValue = recorder.message
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
        let reset = input.isResetKey
        let chord = reset ? shortcut.defaultChord : input
        let other = hotKeys.chord(for: shortcut == .annotate ? .undo : .annotate)
        let accepted = recorder.accept(chord, other: other) {
            if reset { hotKeys.settings.reset(shortcut) }
            else if shortcut == .annotate { hotKeys.settings.start = chord }
            else { hotKeys.settings.undo = chord }
            hotKeys.settings.save(to: .standard)
        }
        if !recorder.isRecording { removeMonitor(); refreshLabels() }
        reason.stringValue = recorder.message
        if accepted { changed() }
    }

    func refreshLabels() {
        for (shortcut, field) in fields where recorder.recording != shortcut {
            field.title = hotKeys.label(for: shortcut)
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func stopRecording() {
        removeMonitor()
        recorder.stop()
        refreshLabels()
        reason.stringValue = ""
    }
}
