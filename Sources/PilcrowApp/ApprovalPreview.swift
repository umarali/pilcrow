import AppKit
import PilcrowCore

private final class ReviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 || (modifiers == .command && event.charactersIgnoringModifiers == "w") {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ReviewDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Read-only crops and spoken words; each toolbar action is a single explicit send.
@MainActor
final class ApprovalPreview: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let capture: FinishedCapture
    private let statusChanged: (String) -> Void
    private let discarded: () -> Void
    private let finished: () -> Void
    private let window = ReviewWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private var available: [Destination: Bool] = [:]
    private var agentButtons: [Destination: NSButton] = [:]
    private var buttons: [NSButton] = []
    private var folderPanel: NSOpenPanel?
    private var closed = false
    private var pendingSend = false
    private let identifiers = ["copy", "claudeCode", "codexCLI", "finder", "discard"]
        .map { NSToolbarItem.Identifier($0) }
    var isSending: Bool { pendingSend || capture.isSending }

    init(capture: FinishedCapture, statusChanged: @escaping (String) -> Void,
         discarded: @escaping () -> Void, finished: @escaping () -> Void) {
        self.capture = capture
        self.statusChanged = statusChanged
        self.discarded = discarded
        self.finished = finished
        super.init()
        buildWindow()
    }

    func show() {
        window.center()
        bringForward()
        refreshCommands()
    }

    private func refreshCommands() {
        for destination in [Destination.claudeCode, .codexCLI] {
            guard let command = destination.command else { continue }
            let shell = capture.shellPath
            Task { [weak self] in
                let found = await CommandAvailability.shared.available(command, shellPath: shell, refresh: true)
                guard let self, !self.closed else { return }
                self.available[destination] = found
                self.updateControls()
            }
        }
    }

    func bringForward() { NSApp.activate(); window.makeKeyAndOrderFront(nil) }

    func cancel() {
        guard !isSending, !closed else { return }
        folderPanel?.cancel(nil)
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isSending }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        folderPanel?.cancel(nil)
        folderPanel = nil
        finished()
        NSApp.hide(nil)
    }

    private func buildWindow() {
        window.title = "Review"
        window.minSize = NSSize(width: 780, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: "CaptureReview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        let crops = NSStackView()
        crops.orientation = .vertical
        crops.alignment = .leading
        crops.spacing = 20
        let marks = capture.approval.marks
        for index in stride(from: 0, to: marks.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 20
            for mark in marks[index..<min(index + 2, marks.count)] {
                let tile = NSStackView()
                tile.orientation = .vertical
                tile.alignment = .leading
                tile.spacing = 8
                let heading = NSTextField(labelWithString: "\(mark.number)")
                heading.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
                tile.addArrangedSubview(heading)
                if let cgImage = mark.thumbnail {
                    let image = NSImageView()
                    image.image = NSImage(cgImage: cgImage, size: .zero)
                    image.imageScaling = .scaleProportionallyUpOrDown
                    image.setAccessibilityLabel("Mark \(mark.number)")
                    image.widthAnchor.constraint(equalTo: tile.widthAnchor).isActive = true
                    image.heightAnchor.constraint(equalToConstant: 220).isActive = true
                    tile.addArrangedSubview(image)
                } else {
                    let missing = NSTextField(labelWithString: "Screenshot unavailable")
                    missing.textColor = .secondaryLabelColor
                    tile.addArrangedSubview(missing)
                }
                if !mark.words.isEmpty {
                    let words = NSTextField(wrappingLabelWithString: mark.words)
                    words.font = .systemFont(ofSize: 15)
                    words.isSelectable = true
                    words.widthAnchor.constraint(equalTo: tile.widthAnchor).isActive = true
                    tile.addArrangedSubview(words)
                }
                row.addArrangedSubview(tile)
            }
            if index + 1 == marks.count { row.addArrangedSubview(NSView()) }
            crops.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: crops.widthAnchor).isActive = true
        }
        if marks.isEmpty {
            let words = NSTextField(wrappingLabelWithString: capture.approval.spokenSummary)
            words.font = .systemFont(ofSize: 17)
            words.isSelectable = true
            words.widthAnchor.constraint(equalTo: crops.widthAnchor).isActive = true
            crops.addArrangedSubview(words)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = ReviewDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        crops.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(crops)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            crops.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            crops.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            crops.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            crops.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        window.contentView = scroll
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let button: NSButton
        switch identifier.rawValue {
        case "copy": button = action("Copy", symbol: "doc.on.doc", selector: #selector(copyCapture))
        case "claudeCode", "codexCLI":
            let destination: Destination = identifier.rawValue == "claudeCode" ? .claudeCode : .codexCLI
            button = action(destination.title, symbol: "terminal", selector: #selector(sendAgent(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(destination.rawValue)
            agentButtons[destination] = button
            let chevron = action("", symbol: "chevron.down", selector: #selector(projectMenu(_:)))
            chevron.identifier = button.identifier
            chevron.toolTip = "Change project…"
            chevron.setAccessibilityLabel("Change \(destination.title) project")
            let split = NSStackView(views: [button, chevron])
            split.spacing = 0
            item.view = split
        case "finder": button = action("Show in Finder", symbol: "folder", selector: #selector(showInFinder))
        case "discard": button = action("Discard", symbol: "trash", selector: #selector(discardCapture))
        default: return nil
        }
        item.label = button.title
        if item.view == nil { item.view = button }
        updateControls()
        return item
    }

    private func action(_ title: String, symbol: String, selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(title)
        buttons.append(button)
        return button
    }

    private func updateControls() {
        buttons.forEach { $0.isEnabled = !isSending && folderPanel == nil }
        for (destination, button) in agentButtons {
            button.isEnabled = !isSending && folderPanel == nil && available[destination] == true
            button.toolTip = available[destination] == true
                ? "Send to \(destination.title)" + (FinishedCapture.project(for: destination).map { " in " + $0.lastPathComponent } ?? "")
                : destination.title + " not found"
        }
    }

    @objc private func copyCapture() {
        do { try capture.copy(); statusChanged("Copied · ⌘V"); window.subtitle = "Copied" }
        catch { window.subtitle = "Couldn’t copy capture"; statusChanged(window.subtitle) }
    }

    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([capture.approval.folder]) }

    @objc private func projectMenu(_ sender: NSButton) {
        guard !isSending, let raw = sender.identifier?.rawValue else { return }
        let menu = NSMenu()
        let change = menu.addItem(withTitle: "Change project…", action: #selector(changeProject(_:)), keyEquivalent: "")
        change.target = self
        change.representedObject = raw
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func changeProject(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let destination = Destination(rawValue: raw) else { return }
        chooseProject(for: destination, thenSend: false)
    }

    @objc private func sendAgent(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let destination = Destination(rawValue: raw),
              available[destination] == true, !isSending else { return }
        if let project = FinishedCapture.project(for: destination) { send(to: destination, project: project) }
        else { chooseProject(for: destination, thenSend: true) }
    }

    private func chooseProject(for destination: Destination, thenSend: Bool) {
        guard !isSending, folderPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FinishedCapture.project(for: destination)
        panel.prompt = thenSend ? "Send" : "Choose"
        panel.title = destination.title + " project"
        folderPanel = panel
        updateControls()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.closed else { return }
            self.folderPanel = nil
            if response == .OK, let url = panel.url {
                // Only this agent's folder changes; choosing is not a new default agent.
                UserDefaults.standard.set(url.path, forKey: "DeliveryProject." + destination.rawValue)
                if thenSend { self.send(to: destination, project: url) }
            }
            self.updateControls()
        }
    }

    private func send(to destination: Destination, project: URL?) {
        guard !isSending, !closed else { return }
        pendingSend = true
        updateControls()
        Task {
            do {
                let retentionFailed = try await capture.send(to: destination, project: project)
                statusChanged("Sent to " + destination.title + (retentionFailed ? " · Couldn’t remove expired captures" : ""))
                pendingSend = false
                window.close()
            } catch {
                pendingSend = false
                window.subtitle = "Couldn’t send to " + destination.title
                statusChanged(window.subtitle)
                // Capture.send refreshed the cache after failure; update these controls too.
                if let command = destination.command {
                    available[destination] = await CommandAvailability.shared.available(command, shellPath: capture.shellPath)
                }
                updateControls()
                if available[destination] != false { agentButtons[destination]?.toolTip = error.localizedDescription }
            }
        }
    }

    @objc private func discardCapture() {
        guard !isSending else { return }
        pendingSend = true
        updateControls()
        Task {
            do {
                try await capture.discard()
                pendingSend = false
                window.close()
                discarded()
            } catch {
                pendingSend = false
                window.subtitle = "Couldn’t discard capture"
                statusChanged(window.subtitle)
                updateControls()
            }
        }
    }
}
