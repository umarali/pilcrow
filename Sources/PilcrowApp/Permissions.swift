import AppKit
import AVFoundation
import Speech

@MainActor
final class Permissions {
    enum State: String {
        case off = "Off"
        case unverified = "Not yet verified"
        case checking = "Checking…"
        case available = "Available"
        case needsReopen = "macOS needs Pilcrow to reopen"
    }

    private static let requestedKey = "ScreenRecordingRequested"
    private let stateChanged: (State) -> Void
    private let willReopen: () -> Void
    private let reopenDidFail: () -> Void
    private(set) var state: State = .unverified {
        didSet {
            guard oldValue != state else { return }
            stateChanged(state)
            updateRow()
        }
    }
    private var probe: Task<Void, Never>?
    private var probeTimeout: Task<Void, Never>?
    private var startCheck: ((State) -> Void)?
    private var observing = false
    var changed: (() -> Void)?
    private(set) var screenGranted = false
    private var poll: Timer?
    private var requesting = false
    private var reopening = false
    private var requestingMicrophone = false
    private(set) var voiceStatus = ""
    private(set) var voiceAction: String?
    private(set) var voiceActionEnabled = false
    private var selectedModel: (VoiceModel, AssetInventory.Status)?
    private var modelCheck: Task<Void, Never>?
    private var modelCheckedAt: ContinuousClock.Instant?
    private var voiceSetup: Task<Void, Never>?
    private var modelProgress: Progress?
    private var modelDownloadFailed = false
    private var reopenFailed = false
    init(stateChanged: @escaping (State) -> Void,
         willReopen: @escaping () -> Void, reopenDidFail: @escaping () -> Void) {
        self.stateChanged = stateChanged
        self.willReopen = willReopen
        self.reopenDidFail = reopenDidFail
    }

    var microphone: SettingsMicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .on
        case .notDetermined: .undetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    var canStart: Bool { !requesting && !reopening && !requestingMicrophone }

    func checkForStart(_ completion: @escaping (State) -> Void) {
        precondition(startCheck == nil)
        startCheck = completion
        updateVoiceRow()
        if refreshPreflight() { runProbe() }
    }

    @discardableResult
    func refreshPreflight() -> Bool {
        screenGranted = CGPreflightScreenCaptureAccess()
        guard screenGranted else {
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
                } else if self.observing {
                    self.pollPreflight()
                }
                return
            }
            self.screenGranted = CGPreflightScreenCaptureAccess()
            let state: State = !self.screenGranted ? .off : (available ? .available : .needsReopen)
            self.state = state
            self.completeStartCheck(state)
        }
        // Leave a stuck probe tracked so no later check starts another one over it.
        probeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self else { return }
            self.probeTimeout = nil
            self.screenGranted = CGPreflightScreenCaptureAccess()
            let state: State = self.screenGranted ? .needsReopen : .off
            self.state = state
            self.completeStartCheck(state)
        }
    }

    private func completeStartCheck(_ state: State) {
        let completion = startCheck
        startCheck = nil
        if completion != nil { updateVoiceRow() }
        completion?(state)
    }

    func beginObserving() {
        observing = true
        refresh()
        checkVoiceModel(refresh: true)
        if poll == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            poll = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func endObserving() {
        observing = false
        poll?.invalidate()
        poll = nil
    }

    func refresh() {
        pollPreflight()
        checkVoiceModel()
        updateRow()
    }

    private func checkVoiceModel(refresh: Bool = false) {
        // Poll the reported download state while the window is visible. Keep showing
        // the last status during background queries, including when the window reopens.
        let ageLimit: Duration = selectedModel?.1 == .downloading ? .seconds(3) : .seconds(60)
        let stale = modelCheckedAt.map { ContinuousClock.now - $0 >= ageLimit } ?? true
        if refresh || stale, modelCheck == nil, voiceSetup == nil {
            modelCheck = Task { [weak self] in
                let selection = await VoiceModel.select()
                guard let self else { return }
                self.selectedModel = selection
                self.modelCheckedAt = .now
                self.modelCheck = nil
                if selection?.1 == .installed { self.modelDownloadFailed = false }
                self.updateVoiceRow()
            }
        }
        updateVoiceRow()
    }

    private func updateVoiceRow() {
        var buttonTitle: String?
        defer {
            voiceAction = buttonTitle
            voiceActionEnabled = canStart && startCheck == nil && buttonTitle != nil
                && (modelCheck == nil || buttonTitle != "Turn on")
            changed?()
        }
        if requestingMicrophone {
            voiceStatus = "Waiting for microphone access…"
            return
        }
        if voiceSetup != nil {
            if let modelProgress, !modelProgress.isIndeterminate {
                voiceStatus = "Downloading " + modelProgress.fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
            } else {
                voiceStatus = "Downloading speech model…"
            }
            return
        }
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        switch access {
        case .denied:
            voiceStatus = "Microphone access denied"
            buttonTitle = "Open System Settings…"
            return
        case .restricted:
            voiceStatus = "Microphone access restricted"
            buttonTitle = "Open System Settings…"
            return
        case .authorized, .notDetermined:
            break
        @unknown default:
            voiceStatus = "Microphone unavailable"
            return
        }
        guard modelCheckedAt != nil || modelCheck == nil else {
            voiceStatus = "Checking speech model…"
            return
        }
        switch selectedModel?.1 {
        case .installed where access == .authorized:
            voiceStatus = "On"
        case .installed:
            voiceStatus = "Uses the microphone during annotation"
            buttonTitle = "Turn on"
        case .supported:
            if modelDownloadFailed {
                voiceStatus = "Speech model download failed"
            } else if access == .authorized {
                voiceStatus = "Downloads an on-device speech model"
            } else {
                voiceStatus = "Uses the microphone and downloads a speech model"
            }
            buttonTitle = "Turn on"
        case .downloading:
            voiceStatus = "Downloading speech model…"
        default:
            voiceStatus = "Speech model unavailable"
        }
    }

    func turnOnVoice() {
        guard canStart, startCheck == nil, observing, voiceSetup == nil else { return }
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        if access == .denied || access == .restricted {
            if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(settings)
            }
            return
        }
        guard modelCheck == nil, access == .authorized || access == .notDetermined,
              let (model, status) = selectedModel, status == .supported || status == .installed else { return }
        requestingMicrophone = access == .notDetermined
        modelDownloadFailed = false
        voiceSetup = Task {
            defer {
                voiceSetup = nil
                modelProgress = nil
                updateVoiceRow()
            }
            if requestingMicrophone {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                voiceLog.notice("Microphone permission request granted: \(granted, privacy: .public)")
                requestingMicrophone = false
                updateRow()
                guard granted else { return }
            }
            guard status == .supported else { return }
            updateVoiceRow()
            // The Turn on click consents to installation once microphone access is granted.
            let modules = [model.makeTranscriber().module]
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    modelProgress = request.progress
                    updateVoiceRow()
                    try await request.downloadAndInstall()
                }
            } catch {
                modelDownloadFailed = true
                voiceLog.notice("Speech model download failed")
            }
            let status = await AssetInventory.status(forModules: modules)
            selectedModel = (model, status)
            modelCheckedAt = .now
            if status == .installed { modelDownloadFailed = false }
        }
        updateRow()
        updateVoiceRow()
    }

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var previouslyRequested: Bool { UserDefaults.standard.bool(forKey: Self.requestedKey) }

    var reopenMessage: String? {
        guard state == .needsReopen || (state == .off && previouslyRequested) else { return nil }
        if reopenFailed { return "Couldn’t reopen Pilcrow. Quit and open it again." }
        if !isBundled { return "Quit and relaunch the Pilcrow executable." }
        return state == .needsReopen ? state.rawValue : "Already turned it on?"
    }
    var canReopen: Bool { isBundled && canStart && reopenMessage != nil }

    private func updateRow() { changed?() }

    func requestScreenAccess() {
        guard canStart, startCheck == nil else { return }
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
                    if self.observing {
                        self.pollPreflight()
                    } else {
                        self.refreshPreflight()
                    }
                    self.updateRow()
                }
            }
        case .available:
            break
        case .needsReopen:
            reopen()
        case .unverified, .checking:
            break
        }
    }

    func reopen() {
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
