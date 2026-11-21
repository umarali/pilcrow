import AppKit
import PilcrowCore
import os

/// Clipboard, HUD and Review share the same immutable message and attachment bytes.
@MainActor
final class FinishedCapture {
    let approval: ApprovalExport
    let outbox: OutboxStore
    let exports: ExportStore
    let shellPath: String
    private(set) var published: Bool
    private var clipboardChange: Int?
    private var stagedOutbox = false
    private var stagedRecovery = false
    private(set) var isDiscarded = false
    private(set) var isSending = false
    private let log = Logger(subsystem: "org.pilcrow.app", category: "delivery")
    var agentText: String {
        DeliveryText.message(approvedText: approval.text, imagePaths: approval.imageURLs(in: approval.folder).map(\.path))
    }

    init(approval: ApprovalExport, outbox: OutboxStore, exports: ExportStore, shellPath: String, published: Bool) {
        self.approval = approval
        self.outbox = outbox
        self.exports = exports
        self.shellPath = shellPath
        self.published = published
    }

    /// Prepare all representations before clearing; never read clipboard contents.
    func copy() throws {
        guard !isDiscarded else { return }
        let text = NSPasteboardItem()
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        guard text.setString(agentText, forType: .string), text.setData(Data(), forType: transient) else {
            throw DeliveryFailure("Couldn’t copy capture")
        }
        var objects = [text]
        for url in approval.imageURLs(in: approval.folder) {
            let image = NSPasteboardItem()
            guard image.setString(url.absoluteString, forType: .fileURL), image.setData(Data(), forType: transient) else {
                throw DeliveryFailure("Couldn’t copy capture")
            }
            objects.append(image)
        }
        let board = NSPasteboard.general
        board.clearContents()
        clipboardChange = nil
        guard board.writeObjects(objects) else { throw DeliveryFailure("Couldn’t copy capture") }
        clipboardChange = board.changeCount
    }

    func send(to destination: Destination, project: URL?) async throws -> Bool {
        guard !isSending, !isDiscarded else { throw DeliveryFailure("Capture unavailable") }
        isSending = true
        defer { isSending = false }
        let retentionFailed = !(await outbox.pruneBeforeSend())
        do {
            if !published {
                _ = try await outbox.create(approval, imageData: approval.imageData,
                    destination: .clipboard, project: nil, shellPath: shellPath)
                // Keep recovery paths valid for the text already on the clipboard.
                published = true
            }
            let item = try await outbox.route(approval, destination: destination, project: project, shellPath: shellPath)
            if destination.command != nil {
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    throw DeliveryFailure("Couldn’t find Terminal. The capture was kept.")
                }
                _ = try await NSWorkspace.shared.open([item.appendingPathComponent("send.command")],
                    withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
            log.notice("Delivery destination \(destination.rawValue, privacy: .public): succeeded")
            return retentionFailed
        } catch {
            log.error("Delivery destination \(destination.rawValue, privacy: .public): failed")
            if let command = destination.command {
                _ = await CommandAvailability.shared.available(command, shellPath: shellPath, refresh: true)
            }
            throw error
        }
    }

    func discard() async throws {
        guard !isSending, !isDiscarded else { return }
        isSending = true
        defer { isSending = false }
        if approval.folder != outbox.folder(for: approval.id) {
            try await exports.beginDiscard(approval.folder)
            stagedRecovery = true
        }
        do {
            stagedOutbox = try await outbox.beginDiscard(approval.id)
        } catch {
            if stagedRecovery { try? await exports.undoDiscard(approval.folder); stagedRecovery = false }
            throw error
        }
        isDiscarded = true
        if let clipboardChange, NSPasteboard.general.changeCount == clipboardChange {
            NSPasteboard.general.clearContents()
        }
    }

    func finishDiscard() async throws {
        guard isDiscarded, !isSending else { return }
        isSending = true
        defer { isSending = false }
        if stagedOutbox { try await outbox.finishDiscard(approval.id); stagedOutbox = false }
        if stagedRecovery { await exports.discard(approval.folder); stagedRecovery = false }
    }

    static func project(for destination: Destination) -> URL? {
        UserDefaults.standard.string(forKey: "DeliveryProject." + destination.rawValue)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

}

private final class ReceiptView: NSVisualEffectView {
    var review: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { review?() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func accessibilityPerformPress() -> Bool { review?(); return true }
}

private final class FinishPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FinishHUD: NSObject {
    private let capture: FinishedCapture
    private let review: () -> Void
    private let panel = FinishPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
    private var timer: Timer?
    private var hideAt = ContinuousClock.now
    private var dismissed = false
    private let text: ReceiptText

    init(capture: FinishedCapture, copied: Bool, saveFailed: Bool, review: @escaping () -> Void) {
        self.capture = capture
        self.text = ReceiptText(marks: capture.approval.marks.count, copied: copied, saveFailed: saveFailed)
        self.review = review
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = OverlayPanel.overlaySpaces.union(.ignoresCycle)
        panel.animationBehavior = .none
        let material = ReceiptView()
        material.review = { [weak self] in self?.openReview() }
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true
        material.setAccessibilityElement(true)
        material.setAccessibilityRole(.button)
        material.setAccessibilityLabel("Review capture")
        let status = NSTextField(labelWithString: text.status)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        let detail = NSTextField(labelWithString: text.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for label in [status, detail] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        material.setAccessibilityValue(text.announcement)
        let words = NSStackView(views: [status, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 3
        let stack = NSStackView(views: [thumbnail(), words])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: material.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: material.centerYAnchor)
        ])
        panel.contentView = material
    }

    private func thumbnail() -> NSView {
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.widthAnchor.constraint(equalToConstant: 40).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let count = capture.approval.marks.count
        let image = NSImageView(frame: NSRect(x: 0, y: 3, width: 35, height: 30))
        if let cgImage = capture.approval.marks.first?.thumbnail {
            image.image = NSImage(cgImage: cgImage, size: .zero)
        } else {
            image.image = NSImage(systemSymbolName: count == 0 ? "text.quote" : "photo", accessibilityDescription: nil)
        }
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 4
        image.layer?.masksToBounds = true
        tile.addSubview(image)
        if count > 0 {
            let badge = NSTextField(labelWithString: "\(count)")
            badge.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            badge.alignment = .center
            badge.textColor = .white
            badge.drawsBackground = true
            badge.backgroundColor = .systemRed
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 7
            badge.layer?.masksToBounds = true
            badge.frame = NSRect(x: 21, y: 0, width: 19, height: 14)
            tile.addSubview(badge)
        }
        return tile
    }

    func show() {
        let anchor = capture.approval.hudAnchor
        let area = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? anchor
        panel.setFrame(NSRect(x: max(area.minX + 12, min(anchor.maxX, area.maxX - 12) - 320),
            y: max(area.minY + 12, min(anchor.minY, area.maxY - 68)), width: 320, height: 56), display: false)
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if let contentView = panel.contentView {
            NSAccessibility.post(element: contentView, notification: .announcementRequested, userInfo: [
                .announcement: text.announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        hideAt = .now + .seconds(5)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) {
                    self.hideAt = .now + .seconds(5)
                } else if ContinuousClock.now >= self.hideAt { self.dismiss() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        timer?.invalidate()
        timer = nil
        panel.ignoresMouseEvents = true
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { Task { @MainActor in panel.orderOut(nil) } })
    }

    private func openReview() {
        guard !dismissed, !capture.isDiscarded else { return }
        dismiss()
        review()
    }
}
