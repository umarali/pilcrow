import AppKit

private final class PillView: NSView {
    var finish: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { finish?() }
    // Make labels and empty capsule space one click target.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func accessibilityPerformPress() -> Bool { finish?(); return true }
}

final class Toolbar: OverlayPanel {
    private let errorLabel = NSTextField(labelWithString: "")
    private let shortcutWarning = NSTextField(labelWithString: "")
    private let voiceError = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let voiceDot = NSTextField(labelWithString: "●")
    private var voiceFeedback: VoiceNarration.Feedback?
    private var voiceBrightness: Int?
    private var area: NSRect

    init(screen: NSScreen, session: AnnotationSession) {
        area = screen.visibleFrame
        super.init(frame: .zero)
        allowsToolTipsWhenApplicationIsInactive = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let esc = NSTextField(labelWithString: "esc")
        esc.font = .systemFont(ofSize: 12, weight: .medium)
        esc.textColor = .white
        voiceDot.font = .systemFont(ofSize: 9)
        voiceDot.setAccessibilityLabel("Microphone input level")
        voiceDot.isHidden = true
        let controls = NSStackView(views: [voiceDot, esc])
        controls.spacing = 5
        controls.alignment = .centerY
        controls.detachesHiddenViews = true
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.detachesHiddenViews = true
        stack.addArrangedSubview(controls)
        for label in [shortcutWarning, errorLabel, voiceError] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .white
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
            label.widthAnchor.constraint(lessThanOrEqualToConstant: max(60, min(420, area.width - 56))).isActive = true
            label.isHidden = true
            stack.addArrangedSubview(label)
        }
        stack.spacing = 3
        let pill = PillView()
        pill.finish = { [weak session] in session?.finish(.pill) }
        pill.setAccessibilityElement(true)
        pill.setAccessibilityRole(.button)
        pill.setAccessibilityLabel("Finish annotation")
        pill.toolTip = "Finish annotation"
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.98).cgColor
        pill.layer?.cornerRadius = 13
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        contentView = pill
        resizeAndPosition()
    }

    override var canBecomeKey: Bool { false }

    func showUnavailableShortcuts(_ labels: [String]) {
        let message = labels.isEmpty ? "" : "Shortcut unavailable: " + labels.joined(separator: ", ")
        if !message.isEmpty, message != shortcutWarning.stringValue { announce(message) }
        shortcutWarning.stringValue = message
        shortcutWarning.isHidden = labels.isEmpty
        resizeAndPosition()
    }

    func showError(_ message: String) {
        if errorLabel.isHidden || errorLabel.stringValue != message { announce(message) }
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        resizeAndPosition()
    }

    func clearError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        resizeAndPosition()
    }

    func updateVoice(_ feedback: VoiceNarration.Feedback, level: Float) {
        let brightness = feedback == .listening ? Int((min(1, max(0, level * 4)) * 8).rounded()) : 0
        if brightness != voiceBrightness {
            voiceBrightness = brightness
            voiceDot.textColor = NSColor.systemGreen.withAlphaComponent(0.35 + 0.65 * Double(brightness) / 8)
        }
        guard feedback != voiceFeedback else { return }
        voiceFeedback = feedback
        voiceDot.isHidden = feedback != .listening && feedback != .warming
        voiceError.isHidden = true
        if case .failed(let failure) = feedback {
            announce(failure.rawValue)
            voiceError.stringValue = failure.rawValue
            voiceError.isHidden = false
        }
        resizeAndPosition()
    }

    func updateVisibleFrame() {
        guard let updated = screen?.visibleFrame, updated != area else { return }
        area = updated
        resizeAndPosition()
    }

    private func announce(_ message: String) {
        guard let contentView else { return }
        NSAccessibility.post(element: contentView, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    private func resizeAndPosition() {
        let fitting = stack.fittingSize
        let width = max(44, ceil(fitting.width) + 24)
        let height = max(26, ceil(fitting.height) + 10)
        let newFrame = NSRect(x: area.maxX - width - 12, y: area.minY + 12, width: width, height: height)
        if frame != newFrame { setFrame(newFrame, display: isVisible) }
    }
}
