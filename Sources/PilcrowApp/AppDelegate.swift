import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let start = NSMenuItem(title: "Start annotating", action: #selector(toggleFromMenu), keyEquivalent: "")
    private let reveal = NSMenuItem(title: "Show last export in Finder", action: #selector(showExport), keyEquivalent: "")
    private let result = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let screenRecording = NSMenuItem(title: "Screen Recording: " + Permissions.State.unverified.rawValue,
                                             action: nil, keyEquivalent: "")
    private let shortcutWarning = NSMenuItem(title: "Shortcut unavailable " + HotKeys.Shortcut.annotate.label,
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
    private var annotateRetry: Task<Void, Never>?
    private var session: AnnotationSession?
    private var lastExport: URL?
    private let exports = ExportStore()
    private var displayLayout: [CGDirectDisplayID: DisplayLayout] = [:]
    private var checkingStart = false
    private var finishing = false

    private struct DisplayLayout: Equatable {
        let frame: NSRect
        let scale: CGFloat
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        exports.removeStale()
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
        for entry in [start, reveal] {
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(screenRecording)
        menu.addItem(result)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        item.menu = menu
        registerAnnotateHotKey()
        permissions.refreshPreflight()
    }

    private func registerAnnotateHotKey() {
        let label = HotKeys.Shortcut.annotate.label
        shortcutWarning.isHidden = true
        item.button?.title = "¶"
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
            self.item.button?.title = "¶ ⚠"
            self.item.button?.toolTip = "Pilcrow · Shortcut unavailable"
            stateLog.notice("Hotkey unavailable")
        }
    }

    private func tryRegisterAnnotateHotKey() -> Bool {
        hotKeys.register(.annotate) { [weak self] in self?.toggle(.hotkey) }
    }

    private func releaseAnnotateHotKey() {
        annotateRetry?.cancel()
        annotateRetry = nil
        hotKeys.unregister(.annotate)
    }

    @objc private func toggleFromMenu() { toggle(.menu) }

    private func toggle(_ trigger: AnnotationSession.Trigger) {
        guard !finishing, !checkingStart else { return }
        if let session { session.finish(trigger); return }
        guard permissions.canStart else { return }
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
        let current = AnnotationSession(exports: exports, hotKeys: hotKeys, closing: { [weak self] in
            self?.finishing = true
            self?.start.isEnabled = false
        }, completed: { [weak self] url, message in
            guard let self else { return }
            if let url {
                self.lastExport = url
                self.reveal.isEnabled = true
            }
            self.result.title = message
            self.result.isHidden = false
            self.item.button?.toolTip = message
            self.start.title = "Start annotating"
            self.finishing = false
            self.session = nil
            self.start.isEnabled = true
        })
        if current.open() {
            session = current
            start.title = "Finish annotating"
            result.isHidden = true
        } else {
            result.title = "No display available"
            result.isHidden = false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        permissions.refreshPreflight()
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

    func applicationWillTerminate(_ notification: Notification) {
        releaseAnnotateHotKey()
        exports.keepOnly(nil)
    }

    @objc private func showExport() {
        if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
    }
}
