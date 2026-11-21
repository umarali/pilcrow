import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let start = NSMenuItem(title: "Start annotating", action: #selector(toggleFromMenu), keyEquivalent: "")
    private let reviewLast = NSMenuItem(title: "Review last capture…", action: #selector(reviewLastCapture), keyEquivalent: "")
    private let reveal = NSMenuItem(title: "Show last capture in Finder", action: #selector(showExport), keyEquivalent: "")
    private let copyLast = NSMenuItem(title: "Copy last capture", action: #selector(copyLastCapture), keyEquivalent: "")
    private let discardLast = NSMenuItem(title: "Discard last capture", action: #selector(discardLastCapture), keyEquivalent: "")
    private let shortcutsItem = NSMenuItem(title: "Shortcuts…", action: #selector(showShortcuts), keyEquivalent: "")
    private let result = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let clearSent = NSMenuItem(title: "Clear recent captures", action: #selector(clearSentCaptures), keyEquivalent: "")
    private let permissionsItem = NSMenuItem(title: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
    private let screenRecording = NSMenuItem(title: "Screen Recording: " + Permissions.State.unverified.rawValue,
                                             action: nil, keyEquivalent: "")
    private let shortcutWarning = NSMenuItem(title: "Shortcut unavailable",
                                             action: nil, keyEquivalent: "")
    private lazy var permissions = Permissions(stateChanged: { [weak self] state in
        self?.screenRecording.title = "Screen Recording: " + state.rawValue
    }, start: { [weak self] in
        self?.toggle(.permissionsWindow)
    }, willReopen: { [weak self] in
        self?.releaseAnnotateHotKey()
    }, reopenDidFail: { [weak self] in
        self?.registerAnnotateHotKey()
    })
    private let hotKeys = HotKeys()
    private lazy var recorder = ShortcutRecorder(release: { [weak self] in
        self?.releaseAnnotateHotKey()
    }, register: { [weak self] shortcut, chord in
        guard let self else { return false }
        if shortcut == .annotate {
            return self.hotKeys.register(.annotate, chord: chord) { [weak self] in self?.toggle(.hotkey) }
        }
        let registered = self.hotKeys.register(.undo, chord: chord, pressed: {})
        self.hotKeys.unregister(.undo)
        return registered
    }, restore: { [weak self] in self?.registerAnnotateHotKey() })
    private var shortcuts: ShortcutsWindow?
    private var annotateRetry: Task<Void, Never>?
    private var session: AnnotationSession?
    private var lastExport: URL?
    private let exports = ExportStore()
    private let outbox = OutboxStore()
    private var preview: ApprovalPreview?
    private var hud: FinishHUD?
    private var finishedCapture: FinishedCapture?
    private var clearingSent = false
    private var quitting = false
    private var deliveryBusy: Bool { finishedCapture?.isSending == true || preview?.isSending == true }
    private var displayLayout: [CGDirectDisplayID: DisplayLayout] = [:]
    private var checkingStart = false
    private var finishing = false

    private struct DisplayLayout: Equatable {
        let frame: NSRect
        let scale: CGFloat
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await exports.removeStale()
            if !(await outbox.pruneBeforeSend()) { showResult("Couldn’t remove expired captures") }
        }
        displayLayout = snapshotDisplays()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        result.isEnabled = false
        result.isHidden = true
        reveal.isEnabled = false
        screenRecording.isEnabled = false
        shortcutWarning.isEnabled = false
        shortcutWarning.isHidden = true
        menu.addItem(shortcutWarning)
        for entry in [start, reviewLast, copyLast, reveal, clearSent, shortcutsItem, permissionsItem] {
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(screenRecording)
        menu.addItem(result)
        menu.addItem(.separator())
        discardLast.target = self
        menu.addItem(discardLast)
        let quit = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        item.menu = menu
        item.button?.setAccessibilityLabel("Pilcrow")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(keyboardLayoutChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        registerAnnotateHotKey()
        permissions.refreshPreflight()
        Task {
            let shell = await Task.detached { LoginShell.path }.value
            async let claude = CommandAvailability.shared.available("claude", shellPath: shell)
            async let codex = CommandAvailability.shared.available("codex", shellPath: shell)
            _ = await (claude, codex)
        }
    }

    private func registerAnnotateHotKey() {
        guard !recorder.isRecording else { return }
        annotateRetry?.cancel()
        annotateRetry = nil
        let label = hotKeys.label(for: .annotate)
        updateShortcutDisplay()
        shortcutWarning.title = "Shortcut unavailable " + label
        shortcutWarning.isHidden = true
        updateStatusIcon()
        item.button?.toolTip = "Pilcrow · " + label
        guard !tryRegisterAnnotateHotKey() else { return }
        stateLog.notice("Hotkey registration failed, retrying for up to 3 seconds")
        annotateRetry = Task { [weak self] in
            for _ in 0..<3 {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.tryRegisterAnnotateHotKey() {
                    self.annotateRetry = nil
                    stateLog.notice("Hotkey registered after retry")
                    return
                }
            }
            guard let self else { return }
            self.annotateRetry = nil
            self.shortcutWarning.isHidden = false
            self.updateStatusIcon()
            self.item.button?.toolTip = "Pilcrow · Shortcut unavailable"
            stateLog.notice("Hotkey unavailable")
        }
    }

    private func updateStatusIcon() {
        let warning = !shortcutWarning.isHidden
        item.button?.image = StatusIcon.image(session != nil && !finishing ? .annotating : (warning ? .warning : .idle))
        item.button?.title = warning ? " ⚠" : ""
        item.button?.imagePosition = .imageLeft
    }

    private func tryRegisterAnnotateHotKey() -> Bool {
        hotKeys.isRegistered(.annotate) || hotKeys.register(.annotate) { [weak self] in self?.toggle(.hotkey) }
    }

    private func releaseAnnotateHotKey() {
        annotateRetry?.cancel()
        annotateRetry = nil
        hotKeys.unregister(.annotate)
    }

    private func updateShortcutDisplay() {
        let title = session == nil ? "Start annotating" : "Finish annotating"
        start.title = title
        // Presentation only. Carbon owns the action, so the menu has no key equivalent.
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
        start.attributedTitle = NSAttributedString(string: title + "\t" + hotKeys.settings.start.glyph,
            attributes: [.paragraphStyle: paragraph])
    }

    @objc private func keyboardLayoutChanged() {
        releaseAnnotateHotKey()
        registerAnnotateHotKey()
        shortcuts?.refreshLabels()
        session?.keyboardLayoutChanged()
        updateShortcutDisplay()
    }

    @objc private func showShortcuts() {
        guard canShowPermissions else { return }
        if shortcuts == nil {
            shortcuts = ShortcutsWindow(hotKeys: hotKeys, recorder: recorder,
                changed: { [weak self] in self?.updateShortcutDisplay() })
        }
        shortcuts?.show()
    }

    @objc private func toggleFromMenu() { toggle(.menu) }

    @objc private func showPermissions() {
        guard canShowPermissions else { return }
        permissions.show()
    }

    private var canShowPermissions: Bool {
        session == nil && !checkingStart && !finishing && !deliveryBusy && !clearingSent && !quitting
    }

    private func toggle(_ trigger: AnnotationSession.Trigger) {
        guard !finishing, !deliveryBusy, !clearingSent, !quitting, !recorder.isRecording else { return }
        if let session { session.finish(trigger); return }
        if let preview {
            guard !preview.isSending else { preview.bringForward(); return }
            preview.cancel()
        }
        guard permissions.canStart else {
            permissions.show()
            return
        }
        guard !checkingStart else { return }
        checkingStart = true
        stateLog.notice("Start requested via \(trigger.rawValue, privacy: .public)")
        permissions.checkForStart { [weak self] state in
            guard let self else { return }
            self.checkingStart = false
            if state == .available {
                self.permissions.close()
                self.openSession()
            } else {
                self.permissions.show()
            }
        }
    }

    private func openSession() {
        shortcuts?.close()
        hud?.dismiss()
        hud = nil
        let current = AnnotationSession(exports: exports, outbox: outbox, hotKeys: hotKeys, closing: { [weak self] in
            self?.finishing = true
            self?.updateStatusIcon()
            self?.start.isEnabled = false
        }, completed: { [weak self] approval, message in
            guard let self else { return }
            self.showResult(message)
            self.session = nil
            self.updateStatusIcon()
            self.updateShortcutDisplay()
            guard let approval else {
                self.finishing = false
                self.start.isEnabled = true
                return
            }
            Task {
                let shell = await Task.detached { LoginShell.path }.value
                var kept = approval
                var saveFailed = false
                do {
                    let folder = try await self.outbox.create(approval, imageData: approval.imageData,
                        destination: .clipboard, project: nil, shellPath: shell)
                    kept = approval.relocated(to: folder)
                    if approval.folder != folder { await self.exports.discard(approval.folder) }
                } catch {
                    saveFailed = true
                    // Never delete the only export. A recovery copy uses its own
                    // paths, so the clipboard stays useful even without a manifest.
                    if let recovered = try? await self.exports.recover(approval) { kept = recovered }
                    await self.exports.retain(kept.folder)
                }
                let capture = FinishedCapture(approval: kept, outbox: self.outbox,
                    exports: self.exports, shellPath: shell, published: !saveFailed)
                self.lastExport = kept.folder
                self.reveal.isEnabled = true
                self.finishedCapture = capture
                var copied = false
                do { try capture.copy(); copied = true }
                catch { self.showResult("Couldn’t copy capture") }
                self.showResult(saveFailed ? "Couldn’t save capture" : (copied ? "Copied · ⌘V" : "Couldn’t copy capture"))
                self.showHUD(capture, copied: copied, saveFailed: saveFailed)
                let milliseconds = (ProcessInfo.processInfo.systemUptime - approval.finishStartedAt) * 1000
                stateLog.notice("Finish-to-HUD: \(milliseconds, privacy: .public) ms, including voice drain")
                self.finishing = false
                self.start.isEnabled = true
                if !(await self.outbox.pruneBeforeSend()) {
                    stateLog.error("Outbox retention: failed after Finish")
                }
            }
        })
        if current.open() {
            session = current
            updateStatusIcon()
            updateShortcutDisplay()
            result.isHidden = true
        } else {
            result.title = "No display available"
            result.isHidden = false
        }
    }

    private func showHUD(_ capture: FinishedCapture, copied: Bool, saveFailed: Bool) {
        hud?.dismiss()
        let hud = FinishHUD(capture: capture, copied: copied, saveFailed: saveFailed,
            review: { [weak self] in self?.review(capture) })
        self.hud = hud
        hud.show()
    }

    @objc private func copyLastCapture() {
        guard canShowPermissions, let capture = finishedCapture, !capture.isDiscarded else { return }
        do { try capture.copy(); showResult("Copied · ⌘V") }
        catch { showResult("Couldn’t copy capture") }
    }

    @objc private func reviewLastCapture() {
        guard canShowPermissions, let capture = finishedCapture else { return }
        hud?.dismiss()
        if let preview { preview.bringForward() }
        else { review(capture) }
    }

    private func review(_ capture: FinishedCapture) {
        guard !capture.isSending else { return }
        let preview = ApprovalPreview(capture: capture,
            statusChanged: { [weak self] in self?.showResult($0) },
            discarded: { [weak self] in self?.captureDiscarded(capture) },
            finished: { [weak self] in self?.preview = nil })
        self.preview = preview
        preview.show()
    }

    @objc private func discardLastCapture() {
        guard canShowPermissions, let capture = finishedCapture, !capture.isDiscarded else { return }
        Task {
            do {
                try await capture.discard()
                preview?.cancel()
                captureDiscarded(capture)
            } catch { showResult("Couldn’t discard capture") }
        }
    }

    private func captureDiscarded(_ capture: FinishedCapture) {
        hud?.dismiss()
        hud = nil
        finishedCapture = nil
        lastExport = nil
        reveal.isEnabled = false
        showResult("Discarded capture")
        Task {
            do { try await capture.finishDiscard() }
            catch { showResult("Couldn’t remove capture") }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        permissions.refreshPreflight()
        reviewLast.isEnabled = finishedCapture != nil && canShowPermissions
        copyLast.isEnabled = finishedCapture != nil && canShowPermissions
        clearSent.isEnabled = !finishing && !deliveryBusy && !clearingSent && !quitting
        permissionsItem.isEnabled = canShowPermissions
        shortcutsItem.isEnabled = canShowPermissions
        discardLast.isEnabled = finishedCapture != nil && canShowPermissions
        start.isEnabled = !finishing && !deliveryBusy && !clearingSent && !quitting && !recorder.isRecording
        updateShortcutDisplay()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        let updated = snapshotDisplays()
        guard updated != displayLayout else { return }
        displayLayout = updated
        session?.finish(.displayChange)
    }

    private func snapshotDisplays() -> [CGDirectDisplayID: DisplayLayout] {
        var layout: [CGDirectDisplayID: DisplayLayout] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            layout[id] = DisplayLayout(frame: screen.frame, scale: screen.backingScaleFactor)
        }
        return layout
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        guard !finishing, !deliveryBusy, !clearingSent else {
            showResult("Send in progress. Quit after delivery finishes.")
            return .terminateCancel
        }
        shortcuts?.close()
        quitting = true
        start.isEnabled = false
        session?.stopVoice()
        Task {
            hud?.dismiss()
            await exports.keepOnly(nil)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        releaseAnnotateHotKey()
    }

    private func showResult(_ message: String) {
        result.title = message
        result.isHidden = false
        item.button?.toolTip = message
    }

    @objc private func clearSentCaptures() {
        guard !finishing, !deliveryBusy, !clearingSent, !quitting else { return }
        clearingSent = true
        hud?.dismiss()
        preview?.cancel()
        Task {
            defer { clearingSent = false }
            do {
                try await outbox.prune(clearAll: true)
                lastExport = nil
                reveal.isEnabled = false
                finishedCapture = nil
                showResult("Cleared recent captures")
            } catch { showResult("Couldn’t clear some recent captures") }
        }
    }

    @objc private func showExport() {
        if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
    }
}
