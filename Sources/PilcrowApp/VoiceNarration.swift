import AVFoundation
import CoreAudio
import PilcrowCore
import os

let voiceLog = Logger(subsystem: "org.pilcrow.app", category: "voice")

@MainActor
final class VoiceNarration {
    enum Feedback: Equatable {
        case off, warming, listening
        case failed(VoiceFailure)
    }

    struct RetryWindow {
        let duration: Duration
        private var attempts: [ContinuousClock.Instant] = []

        init(duration: Duration) { self.duration = duration }

        mutating func count(at now: ContinuousClock.Instant) -> Int {
            attempts.removeAll { now - $0 >= duration }
            return attempts.count
        }

        mutating func record(at now: ContinuousClock.Instant) {
            attempts.append(now)
        }
    }

    enum SegmentAction: Equatable {
        case advance, recover, discardRoute
        case stop(VoiceFailure)
    }

    struct SegmentRecovery {
        private var retries = RetryWindow(duration: .seconds(30))

        mutating func action(for outcome: VoiceSegment.Outcome, activeRoute: Bool,
                             exhaustedInput: Bool, at now: ContinuousClock.Instant) -> SegmentAction {
            let failure: VoiceFailure
            switch (outcome, exhaustedInput) {
            case (.finished, _):
                return .advance
            case (.drainTimedOut, _), (.failed(.analyzer), true):
                guard activeRoute else { return .recover }
                failure = .analyzer
            case (.failed(.backlog), _):
                failure = .backlog
            case (.failed(.conversion), _):
                return .stop(.conversion)
            case (.failed(let reason), _):
                guard activeRoute else { return .discardRoute }
                guard reason == .analyzer, retries.count(at: now) > 0 else { return .stop(reason) }
                failure = reason
            }

            retries.record(at: now)
            return retries.count(at: now) >= 3 ? .stop(failure) : .recover
        }
    }

    struct Transcript {
        private var earlierWords: [TranscriptWord] = []
        var segmentWords: [TranscriptWord] = []

        var words: [TranscriptWord] { earlierWords + segmentWords }

        mutating func retainTimedOutTail() {
            for index in segmentWords.indices { segmentWords[index].isFinal = true }
        }

        mutating func beginSegment(sessionStart: Double, hostSeconds: Double, latency: Double,
                                   previousAudioEnd: Double) -> VoiceTiming {
            let finalized = segmentWords.filter(\.isFinal)
            let lastWordEnd = sessionStart + (finalized.map(\.end).max() ?? -.infinity)
            earlierWords.append(contentsOf: finalized)
            segmentWords = []
            let anchor = VoiceTiming.audioAnchor(hostSeconds: hostSeconds, inputLatency: latency,
                                                 after: max(previousAudioEnd, lastWordEnd))
            return VoiceTiming(sessionStart: sessionStart, audioStart: anchor)
        }
    }

    private struct Input {
        let route: Int
        let device: AudioDeviceID
        let engine: AVAudioEngine
        let node: AVAudioInputNode
        let observer: NSObjectProtocol
        let hardwareFormat: AVAudioFormat
        let tapFormat: AVAudioFormat
        let started: ContinuousClock.Instant
    }

    private let sessionStart: Double
    private let changed: ([TranscriptWord], String?) -> Void
    private let audio = VoiceAudio()
    private var analysis: Task<Void, Never>?
    private var inputCheck: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var input: Input?
    private var route = 0
    private var currentSegment: VoiceSegment?
    private var restarts = RetryWindow(duration: .seconds(60))
    private var transcript = Transcript()
    private var waiter: CheckedContinuation<Void, Never>?
    private var routesEnabled = false
    private var finishing = false
    private var state: Feedback = .off

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    init(sessionStart: Double, changed: @escaping ([TranscriptWord], String?) -> Void) {
        self.sessionStart = sessionStart
        self.changed = changed
    }

    var feedback: Feedback {
        if input != nil, audio.reading.lastBuffer != nil { return .listening }
        return state
    }

    var level: Float { input == nil ? 0 : audio.reading.level }

    func start() {
        // Only the Permissions window can request access or install a model.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        analysis = Task { [weak self] in await self?.transcribe() }
    }

    private func transcribe() async {
        defer { if !Task.isCancelled { settle() } }
        guard let (model, status) = await VoiceModel.select(), status == .installed,
              !Task.isCancelled else { return }
        let languageCode = model.locale.language.languageCode?.identifier
        state = .warming
        voiceLog.notice("Session clock origin at uptime \(self.sessionStart, privacy: .public)")
        let firstSegment = makeSegment(model)
        guard let format = await firstSegment.preferredFormat(), !Task.isCancelled else {
            if !Task.isCancelled { report(.analyzer) }
            return
        }
        do { try await firstSegment.prepare(in: format) }
        catch {
            if !Task.isCancelled { report(.analyzer) }
            return
        }
        guard !Task.isCancelled, !finishing else { return }

        routesEnabled = true
        watchDefaultInput()
        openInput()
        var prepared: VoiceSegment? = firstSegment
        var previousEnd = -Double.infinity
        var recovery = SegmentRecovery()
        while !Task.isCancelled, let first = await audio.next() {
            guard !Task.isCancelled else { return }
            guard let hostSeconds = first.hostSeconds else {
                fail(.timing)
                return
            }
            let latency = first.latency
            let hadProvisional = transcript.segmentWords.contains { !$0.isFinal }
            let timing = transcript.beginSegment(sessionStart: sessionStart, hostSeconds: hostSeconds,
                                                 latency: latency, previousAudioEnd: previousEnd)
            if hadProvisional { changed(transcript.words, languageCode) }
            let anchor = timing.audioStart
            voiceLog.notice("First microphone buffer at uptime \(hostSeconds, privacy: .public); input latency \(latency, privacy: .public) s; segment anchor \(anchor, privacy: .public)")
            let segment = prepared ?? makeSegment(model)
            prepared = nil
            let conversion: VoiceAudio.Conversion
            do {
                conversion = try VoiceAudio.Conversion(audio: audio, first: first, destination: format,
                                                       anchor: anchor, ended: { await segment.limitDrain() })
            } catch {
                fail(.conversion)
                return
            }
            currentSegment = segment
            let outcome = await segment.run(conversion, format: format, timing: timing)
            guard !Task.isCancelled else { return }
            if case .drainTimedOut = outcome {
                transcript.retainTimedOutTail()
                changed(transcript.words, languageCode)
            }

            let action = recovery.action(for: outcome, activeRoute: first.route == input?.route,
                                         exhaustedInput: segment.exhaustedInput, at: .now)
            switch action {
            case .advance:
                break
            case .discardRoute, .recover:
                if action == .discardRoute { audio.discard(route: first.route) }
                voiceLog.notice("Retiring interrupted microphone segment")
                // Cancellation must not hold up the buffered input for the next segment.
                Task { await segment.cancelAnalyzer() }
            case .stop(let failure):
                fail(failure)
                Task { await segment.cancelAnalyzer() }
                return
            }
            previousEnd = await conversion.endUptime
            guard !Task.isCancelled else { return }
            currentSegment = nil
        }
    }

    private(set) var voiceResults = VoiceRecording.Results()

    private func makeSegment(_ model: VoiceModel) -> VoiceSegment {
        let languageCode = model.locale.language.languageCode?.identifier
        return VoiceSegment(model: model, record: { [weak self] result in
            self?.voiceResults.append(result)
        }) { [weak self] words in
            guard let self else { return }
            self.transcript.segmentWords = words
            self.changed(self.transcript.words, languageCode)
        }
    }

    static func logResult(start: Double, end: Double, isFinal: Bool, finalThrough: Double, wordCount: Int) {
        voiceLog.debug("Result range \(start, privacy: .public)–\(end, privacy: .public) s, isFinal \(isFinal, privacy: .public), finalization time \(finalThrough, privacy: .public) s, word count \(wordCount, privacy: .public)")
    }

    private func openInput() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = Self.defaultInputDevice() else {
            report(.device)
            return
        }

        let engine = AVAudioEngine()
        let node = engine.inputNode
        let hardware = node.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            report(.device)
            return
        }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            report(.device)
            return
        }

        state = .warming
        route += 1
        let route = self.route
        // The tap can start delivering before engine.start() returns. Its packets
        // share the latency measured after startup, before narration reads the anchor.
        let latency = OSAllocatedUnfairLock(initialState: 0.0)
        let audio = self.audio
        audio.open(route: route)
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, time in
            do { try audio.append(buffer, at: time, route: route, latency: latency) }
            catch {
                Task { @MainActor [weak self] in
                    guard self?.input?.route == route else { return }
                    self?.fail(.conversion)
                }
            }
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.inputConfigurationChanged(route: route)
            }
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: nil, block: tap)
        do { try engine.start() }
        catch {
            NotificationCenter.default.removeObserver(observer)
            engine.stop()
            node.removeTap(onBus: 0)
            audio.closeRoute()
            audio.discard(route: route)
            report(.engine)
            return
        }

        let started = ContinuousClock.now
        let hardwareFormat = node.inputFormat(forBus: 0)
        let tapFormat = node.outputFormat(forBus: 0)
        let presentationLatency = node.presentationLatency
        let hardwareDevice = node.auAudioUnit.deviceID
        let safetyOffset = Self.inputSafetyOffset(for: hardwareDevice == kAudioObjectUnknown ? device : hardwareDevice,
                                                 sampleRate: hardwareFormat.sampleRate)
        latency.withLock { $0 = max(0, presentationLatency.isFinite ? presentationLatency : 0) + safetyOffset }
        input = Input(route: route, device: device, engine: engine, node: node, observer: observer,
                      hardwareFormat: hardwareFormat, tapFormat: tapFormat, started: started)
        voiceLog.notice("Microphone engine started; input safety offset \(safetyOffset, privacy: .public) s")

        inputCheck = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard let self, self.input?.route == route else { return }
                let now = ContinuousClock.now
                let meter = self.audio.reading
                if let overrun = meter.overrunSince, now - overrun >= .seconds(2) {
                    self.currentSegment?.abortForBacklog()
                }
                let expired = meter.lastBuffer.map { now - $0 >= .seconds(2) } ?? (now - started >= .seconds(5))
                if expired {
                    self.stopInput()
                    self.report(.device)
                    return
                }
            }
        }
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = defaultInputAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func inputSafetyOffset(for device: AudioDeviceID, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertySafetyOffset,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
        return status == noErr && size == MemoryLayout<UInt32>.size ? Double(frames) / sampleRate : 0
    }

    private func watchDefaultInput() {
        // A device switch can keep the same sample rate and channel count.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, Self.defaultInputDevice() != self.input?.device else { return }
                self.restartInput()
            }
        }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        if status == noErr {
            defaultInputListener = listener
        } else {
            voiceLog.notice("Default microphone observation unavailable")
        }
    }

    private func inputConfigurationChanged(route: Int) {
        guard let input, input.route == route else { return }
        // AVAudioEngine stops itself before posting this notification, so a "duplicate"
        // notification may only be ignored while the engine is still running.
        if input.engine.isRunning,
           ContinuousClock.now - input.started < .milliseconds(500),
           Self.defaultInputDevice() == input.device,
           input.node.inputFormat(forBus: 0) == input.hardwareFormat,
           input.node.outputFormat(forBus: 0) == input.tapFormat {
            return
        }
        restartInput()
    }

    private func restartInput() {
        guard routesEnabled, !finishing else { return }
        let now = ContinuousClock.now
        guard restarts.count(at: now) < 5 else {
            fail(.restartLimit)
            return
        }
        restarts.record(at: now)
        voiceLog.notice("Microphone configuration changed")
        stopInput()
        openInput()
    }

    private func report(_ failure: VoiceFailure) {
        state = .failed(failure)
        voiceLog.notice("\(failure.rawValue, privacy: .public)")
    }

    private func fail(_ failure: VoiceFailure) {
        report(failure)
        stopInput()
        stopWatchingDefaultInput()
        audio.finish(discarding: true)
        currentSegment?.abort()
    }

    private func stopInput() {
        inputCheck?.cancel()
        inputCheck = nil
        guard let input else { return }
        self.input = nil
        NotificationCenter.default.removeObserver(input.observer)
        input.engine.stop()
        input.node.removeTap(onBus: 0)
        audio.closeRoute()
        voiceLog.notice("Microphone engine stopped")
    }

    private func stopWatchingDefaultInput() {
        routesEnabled = false
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultInputListener)
        }
        defaultInputListener = nil
    }

    func finish() {
        guard !finishing, analysis != nil else { return }
        finishing = true
        if !routesEnabled, currentSegment == nil {
            stop()
            return
        }
        let stopAt = ContinuousClock.now + (input == nil ? .zero : .milliseconds(250))
        finishTask = Task { [weak self] in
            do { try await Task.sleep(until: stopAt, clock: .continuous) }
            catch { return }
            guard let self else { return }
            self.stopInput()
            self.stopWatchingDefaultInput()
            self.audio.finish()
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            voiceLog.notice("Voice finish timed out")
            self.stop()
        }
    }

    func stop() {
        finishing = true
        stopInput()
        stopWatchingDefaultInput()
        audio.finish(discarding: true)
        analysis?.cancel()
        if let currentSegment {
            currentSegment.abort()
            Task { await currentSegment.cancelAnalyzer() }
        }
        settle()
    }

    private func settle() {
        finishTask?.cancel()
        finishTask = nil
        analysis = nil
        currentSegment = nil
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard analysis != nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
