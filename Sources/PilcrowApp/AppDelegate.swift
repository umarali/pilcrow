import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let start = NSMenuItem(title: "Start annotating", action: #selector(toggleFromMenu), keyEquivalent: "")
    private let reviewLast = NSMenuItem(title: "Review last capture…", action: #selector(reviewLastCapture), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    private let result = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let screenRecording = NSMenuItem(title: "Screen Recording needed…", action: #selector(showSettings), keyEquivalent: "")
    private let shortcutWarning = NSMenuItem(title: "Shortcut unavailable", action: nil, keyEquivalent: "")
    private lazy var permissions: Permissions = Permissions(stateChanged: { [weak self] _ in
        self?.screenRecording.isHidden = self?.permissions.screenGranted == true
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
    private var settings: SettingsWindow?
    private var annotateRetry: Task<Void, Never>?
    private var session: AnnotationSession?
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
        let menu = makeStatusMenu()
        menu.delegate = self
        item.menu = menu
        NSApp.mainMenu = makeApplicationMenu()
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

    /// Also used by tests without launching the app or registering hotkeys.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for warning in [shortcutWarning, result] {
            warning.isEnabled = false
            warning.isHidden = true
        }
        screenRecording.isHidden = true
        for entry in [shortcutWarning, result, screenRecording, start, reviewLast] {
            entry.target = self
            menu.addItem(entry)
        }
        reviewLast.isEnabled = false
        menu.addItem(.separator())
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = menu.addItem(withTitle: "Quit Pilcrow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        updateShortcutDisplay()
        return menu
    }

    /// Key equivalents must also work while a normal Pilcrow window is key.
    func makeApplicationMenu() -> NSMenu {
        let main = NSMenu()
        let application = NSMenu()
        let settingsCommand = application.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsCommand.target = self
        application.addItem(.separator())
        let quit = application.addItem(withTitle: "Quit Pilcrow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        let item = NSMenuItem(title: "Pilcrow", action: nil, keyEquivalent: "")
        item.submenu = application
        main.addItem(item)
        return main
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
        settings?.refreshLabels()
        session?.keyboardLayoutChanged()
        updateShortcutDisplay()
    }

    @objc private func showSettings() {
        guard canShowSettings else { return }
        presentSettings()
    }

    private func presentSettings() {
        if settings == nil {
            settings = SettingsWindow(hotKeys: hotKeys, recorder: recorder, permissions: permissions,
                outbox: outbox, canClear: { [weak self] in self?.canClearCaptures == true },
                clear: { [weak self] in self?.clearSentCaptures() },
                changed: { [weak self] in self?.updateShortcutDisplay() })
        }
        settings?.show()
    }

    @objc private func toggleFromMenu() { toggle(.menu) }

    private var canShowSettings: Bool {
        session == nil && !checkingStart && !finishing && !deliveryBusy && !clearingSent && !quitting
    }

    private var canClearCaptures: Bool { canShowSettings }

    private func toggle(_ trigger: AnnotationSession.Trigger) {
        guard !finishing, !deliveryBusy, !clearingSent, !quitting, !recorder.isRecording else { return }
        if let session { session.finish(trigger); return }
        if let preview {
            guard !preview.isSending else { preview.bringForward(); return }
            preview.cancel()
        }
        guard permissions.canStart else {
            presentSettings()
            return
        }
        guard !checkingStart else { return }
        checkingStart = true
        stateLog.notice("Start requested via \(trigger.rawValue, privacy: .public)")
        permissions.checkForStart { [weak self] state in
            guard let self else { return }
            self.checkingStart = false
            if state == .available {
                self.settings?.close()
                self.openSession()
            } else {
                self.presentSettings()
            }
        }
    }

    private func openSession() {
        settings?.close()
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

    @objc private func reviewLastCapture() {
        guard canShowSettings, let capture = finishedCapture else { return }
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

    private func captureDiscarded(_ capture: FinishedCapture) {
        hud?.dismiss()
        hud = nil
        finishedCapture = nil
        showResult("Discarded capture")
        Task {
            do { try await capture.finishDiscard() }
            catch { showResult("Couldn’t remove capture") }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        screenRecording.isHidden = permissions.refreshPreflight()
        reviewLast.isEnabled = finishedCapture != nil && canShowSettings
        settingsItem.isEnabled = canShowSettings
        screenRecording.isEnabled = canShowSettings
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
        settings?.close()
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
        guard canClearCaptures else { return }
        clearingSent = true
        settings?.refreshCaptures()
        hud?.dismiss()
        preview?.cancel()
        Task {
            defer { clearingSent = false; settings?.refreshCaptures() }
            do {
                try await outbox.prune(clearAll: true)
                finishedCapture = nil
                showResult("Cleared recent captures")
            } catch { showResult("Couldn’t clear some recent captures") }
        }
    }

}
