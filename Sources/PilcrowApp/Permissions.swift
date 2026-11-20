import AppKit

@MainActor
final class Permissions: NSObject, NSWindowDelegate {
    enum State: String {
        case off = "Off"
        case unverified = "Not yet verified"
        case checking = "Checking…"
        case available = "Available"
        case needsReopen = "macOS needs Pilcrow to reopen"
    }

    private static let requestedKey = "ScreenRecordingRequested"
    private let stateChanged: (State) -> Void
    private let start: () -> Void
    private let willReopen: () -> Void
    private let reopenDidFail: () -> Void
    private var state: State = .unverified {
        didSet {
            guard oldValue != state else { return }
            stateChanged(state)
            if window != nil { updateRow() }
        }
    }
    private var probe: Task<Void, Never>?
    private var probeTimeout: Task<Void, Never>?
    private var startCheck: ((State) -> Void)?
    private var window: NSWindow?
    private var poll: Timer?
    private var previousApp: NSRunningApplication?
    private var requesting = false
    private var reopening = false
    private var reopenFailed = false
    private let status = NSTextField(labelWithString: "")
    private let action = NSButton(title: "", target: nil, action: nil)
    private let reopenRow = NSStackView()
    private let reopenHelp = NSTextField(labelWithString: "")
    private let reopenButton = NSButton(title: "Quit & Reopen", target: nil, action: nil)

    init(stateChanged: @escaping (State) -> Void, start: @escaping () -> Void,
         willReopen: @escaping () -> Void, reopenDidFail: @escaping () -> Void) {
        self.stateChanged = stateChanged
        self.start = start
        self.willReopen = willReopen
        self.reopenDidFail = reopenDidFail
        super.init()
    }

    var canStart: Bool { !requesting && !reopening }

    func checkForStart(_ completion: @escaping (State) -> Void) {
        precondition(startCheck == nil)
        startCheck = completion
        if refreshPreflight() { runProbe() }
    }

    @discardableResult
    func refreshPreflight() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            probe?.cancel()
            state = .off
            completeStartCheck(.off)
            return false
        }
        if state == .off { state = .unverified }
        return true
    }

    private func pollPreflight() {
        if canStart, refreshPreflight(), state == .unverified { runProbe() }
    }

    private func runProbe() {
        if probe != nil {
            if probeTimeout == nil {
                state = .needsReopen
                completeStartCheck(.needsReopen)
            }
            return
        }

        state = .checking
        stateLog.notice("Screen Recording probe started")
        probe = Task { [weak self] in
            let available = await Capture.probe()
            guard let self else { return }
            self.probe = nil
            self.probeTimeout?.cancel()
            self.probeTimeout = nil
            if Task.isCancelled {
                if self.startCheck != nil, self.refreshPreflight() {
                    self.runProbe()
                } else if self.window?.isVisible == true {
                    self.pollPreflight()
                }
                return
            }
            let state: State = !CGPreflightScreenCaptureAccess() ? .off : (available ? .available : .needsReopen)
            self.state = state
            self.completeStartCheck(state)
        }
        // Leave a stuck probe tracked so no later check starts another one over it.
        probeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self else { return }
            self.probeTimeout = nil
            let state: State = CGPreflightScreenCaptureAccess() ? .needsReopen : .off
            self.state = state
            self.completeStartCheck(state)
        }
    }

    private func completeStartCheck(_ state: State) {
        let completion = startCheck
        startCheck = nil
        completion?(state)
    }

    func show() {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        let opening = !window.isVisible
        if opening {
            if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
                previousApp = frontmost
            }
            window.center()
        }
        updateRow()
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        // The Start check serves as the opening probe. Sample again in case access
        // changed while the window was coming forward.
        if opening { pollPreflight() }
        if poll == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollPreflight() }
            }
            poll = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func close() {
        if window?.isVisible == true { window?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        if NSRunningApplication.current.isActive { _ = previousApp?.activate() }
        previousApp = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pilcrow Permissions"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let name = NSTextField(labelWithString: "Screen Recording")
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        status.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        action.bezelStyle = .rounded
        action.target = self
        action.action = #selector(performAction)
        reopenHelp.textColor = .secondaryLabelColor
        reopenButton.bezelStyle = .rounded
        reopenButton.target = self
        reopenButton.action = #selector(reopen)
        reopenRow.alignment = .centerY
        reopenRow.addArrangedSubview(reopenHelp)
        reopenRow.addArrangedSubview(reopenButton)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.detachesHiddenViews = true
        let row = NSStackView(views: [labels, action])
        row.alignment = .centerY
        row.distribution = .equalSpacing
        rows.addArrangedSubview(row)
        rows.addArrangedSubview(reopenRow)
        rows.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            row.widthAnchor.constraint(equalTo: rows.widthAnchor)
        ])
        window.contentView = content
        return window
    }

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var previouslyRequested: Bool { UserDefaults.standard.bool(forKey: Self.requestedKey) }

    private func updateRow() {
        status.stringValue = state.rawValue
        action.isHidden = false
        action.isEnabled = canStart
        reopenRow.isHidden = state != .off || !previouslyRequested
        reopenButton.isHidden = !isBundled
        reopenButton.isEnabled = canStart
        switch state {
        case .off:
            action.title = previouslyRequested ? "Open System Settings…" : "Grant…"
            if isBundled {
                reopenHelp.stringValue = reopenFailed ? "Couldn’t reopen Pilcrow. Quit and open it again." : "Already turned it on?"
            } else {
                reopenHelp.stringValue = "Already turned it on? Quit and relaunch the Pilcrow executable."
            }
        case .unverified, .checking:
            action.isHidden = true
        case .available:
            action.title = "Start annotating"
        case .needsReopen:
            if !isBundled {
                status.stringValue += ". Quit and relaunch the Pilcrow executable."
                action.isHidden = true
            } else {
                if reopenFailed { status.stringValue = "Couldn’t reopen Pilcrow. Quit and open it again." }
                action.title = "Quit & Reopen"
            }
        }
    }

    @objc private func performAction() {
        guard canStart else { return }
        switch state {
        case .off:
            if refreshPreflight() {
                runProbe()
                return
            }
            if previouslyRequested {
                if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(settings)
                }
            } else {
                requesting = true
                UserDefaults.standard.set(true, forKey: Self.requestedKey)
                updateRow()
                DispatchQueue.main.async {
                    let granted = CGRequestScreenCaptureAccess()
                    stateLog.notice("Screen Recording request returned granted: \(granted, privacy: .public)")
                    self.requesting = false
                    if self.window?.isVisible == true {
                        self.pollPreflight()
                    } else {
                        self.refreshPreflight()
                    }
                    self.updateRow()
                }
            }
        case .available:
            start()
        case .needsReopen:
            reopen()
        case .unverified, .checking:
            break
        }
    }

    @objc private func reopen() {
        guard isBundled, canStart,
              state == .needsReopen || (state == .off && previouslyRequested) else { return }
        reopening = true
        reopenFailed = false
        updateRow()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        willReopen()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            let opened = app != nil && error == nil
            Task { @MainActor in
                if opened {
                    NSApp.terminate(nil)
                } else {
                    self.reopening = false
                    self.reopenFailed = true
                    self.reopenDidFail()
                    self.updateRow()
                }
            }
        }
    }
}
