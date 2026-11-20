import AppKit

private final class ToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Toolbar: OverlayPanel {
    private let undo = ToolbarButton()
    private let clear = ToolbarButton()
    private let count = NSTextField(labelWithString: "0 marks")
    private let hint = NSTextField(labelWithString: "Hold ⇧ to draw")
    private let shortcutWarning = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var area: NSRect
    private weak var session: AnnotationSession?

    init(screen: NSScreen, session: AnnotationSession) {
        self.session = session
        area = screen.visibleFrame
        super.init(frame: .zero)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let finish = ToolbarButton()
        configure(undo, "Undo", #selector(undoMark))
        configure(clear, "Clear pass", #selector(clearPass))
        configure(finish, "Finish", #selector(finishSession))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .white
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        count.textColor = .white
        shortcutWarning.font = .systemFont(ofSize: 12)
        shortcutWarning.textColor = .white
        shortcutWarning.isHidden = true

        let controls = NSStackView(views: [count, hint, undo, clear, finish])
        controls.spacing = 6
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.detachesHiddenViews = true
        stack.addArrangedSubview(controls)
        stack.addArrangedSubview(shortcutWarning)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.spacing = 2

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.98).cgColor
        pill.layer?.cornerRadius = 19
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        contentView = pill
    }

    override var canBecomeKey: Bool { false }

    func showUnavailableShortcuts(_ shortcuts: [HotKeys.Shortcut]) {
        var hints = ["Hold ⇧ to draw"]
        if !shortcuts.contains(.escape) { hints.append("Esc finish") }
        if !shortcuts.contains(.undo) { hints.append("⌘Z undo mark") }
        hint.stringValue = hints.joined(separator: " · ")
        shortcutWarning.stringValue = "Shortcut unavailable: " + shortcuts.map(\.label).joined(separator: ", ")
        shortcutWarning.isHidden = shortcuts.isEmpty
    }

    func update(marks: Int, hasCurrentMarks: Bool) {
        undo.isEnabled = hasCurrentMarks
        clear.isEnabled = hasCurrentMarks
        count.stringValue = "\(marks) " + (marks == 1 ? "mark" : "marks")
        resizeAndPosition()
    }

    func updateVisibleFrame() {
        guard let updated = screen?.visibleFrame, updated != area else { return }
        area = updated
        setFrameOrigin(NSPoint(x: area.maxX - frame.width - 12, y: area.minY + 12))
    }

    private func resizeAndPosition() {
        let fitting = stack.fittingSize
        let width = ceil(fitting.width) + 32
        let height = max(38, ceil(fitting.height))
        let newFrame = NSRect(x: area.maxX - width - 12, y: area.minY + 12, width: width, height: height)
        if frame != newFrame { setFrame(newFrame, display: isVisible) }
    }

    private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    @objc private func undoMark() { session?.undo() }
    @objc private func clearPass() { session?.clearPass() }
    @objc private func finishSession() { session?.finish(.pill) }
}
