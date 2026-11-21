import AVFoundation
import os
import Speech

enum VoiceFailure: String, Error {
    case conversion = "Audio conversion failed"
    case timing = "Microphone timing unavailable"
    case backlog = "Speech analyzer fell behind"
    case device = "Microphone disconnected"
    case engine = "Microphone could not start"
    case restartLimit = "Microphone restart limit reached"
    case analyzer = "Speech analyzer stopped"
}

/// One bounded FIFO for the session, including audio captured during an analyzer handoff.
final class VoiceAudio: Sendable {
    struct Packet: @unchecked Sendable {
        // The tap gives the reader an owned copy and never accesses it again.
        let buffer: AVAudioPCMBuffer
        let route: Int
        let sequence: Int
        let hostSeconds: Double?
        let sampleTime: AVAudioFramePosition?
        let routeLatency: OSAllocatedUnfairLock<Double>

        var latency: Double { routeLatency.withLock { $0 } }

        var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }

        func follows(_ previous: Packet) -> Bool {
            guard route == previous.route, sequence == previous.sequence + 1,
                  buffer.format == previous.buffer.format else { return false }
            guard let sampleTime, let last = previous.sampleTime else { return true }
            return sampleTime == last + AVAudioFramePosition(previous.buffer.frameLength)
        }
    }

    struct Meter {
        var lastBuffer: ContinuousClock.Instant?
        var overrunSince: ContinuousClock.Instant?
        var level: Float = 0
    }

    private struct State {
        var route: Int?
        var sequence = 0
        var packets: [Packet] = []
        var duration: Double = 0
        var meter = Meter()
        var waiter: CheckedContinuation<Read, Never>?
        var ended = false

        mutating func wakeReader() {
            waiter?.resume(returning: .retry)
            waiter = nil
        }
    }

    private enum Read {
        case packet(Packet), end, retry
    }

    private static let bufferLimit = 15.0
    private let state = OSAllocatedUnfairLock(initialState: State())

    var reading: Meter { state.withLock { $0.meter } }

    func open(route: Int) {
        state.withLock {
            $0.route = route
            $0.sequence = 0
            $0.meter.lastBuffer = nil
            $0.meter.level = 0
        }
    }

    func closeRoute() {
        state.withLock {
            $0.route = nil
            $0.wakeReader()
        }
    }

    func finish(discarding: Bool = false) {
        state.withLock {
            $0.ended = true
            if discarding {
                $0.packets.removeAll()
                $0.duration = 0
            }
            $0.wakeReader()
        }
    }

    func discard(route: Int) {
        state.withLock {
            while let first = $0.packets.first, first.route == route {
                $0.duration -= $0.packets.removeFirst().duration
            }
            $0.wakeReader()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, route: Int,
                latency: OSAllocatedUnfairLock<Double>) throws {
        guard buffer.frameLength > 0 else { return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw VoiceFailure.conversion
        }
        copy.frameLength = buffer.frameLength
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(sources, destinations) {
            guard let from = source.mData, let to = destination.mData,
                  source.mDataByteSize <= destination.mDataByteSize else { throw VoiceFailure.conversion }
            memcpy(to, from, Int(source.mDataByteSize))
        }
        let hostSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
        let sampleTime = time.isSampleTimeValid ? time.sampleTime : nil
        let now = ContinuousClock.now
        let level = Self.peak(copy)
        // This closure runs synchronously on the tap thread. Only the owned packet leaves it.
        let overrun = state.withLockUnchecked { state in
            guard state.route == route, !state.ended else { return false }
            let packet = Packet(buffer: copy, route: route, sequence: state.sequence,
                                hostSeconds: hostSeconds, sampleTime: sampleTime, routeLatency: latency)
            state.sequence += 1
            state.meter.lastBuffer = now
            state.meter.level = level
            state.packets.append(packet)
            state.duration += packet.duration
            var dropped = false
            while state.duration > Self.bufferLimit, !state.packets.isEmpty {
                state.duration -= state.packets.removeFirst().duration
                dropped = true
            }
            state.wakeReader()
            guard dropped, state.meter.overrunSince == nil else { return false }
            state.meter.overrunSince = now
            return true
        }
        if overrun { voiceLog.notice("Speech analyzer fell behind; discarded oldest buffered audio") }
    }

    /// A boundary stays at the head of the queue for the next analyzer. Closing a
    /// route wakes a reader even if the replacement device has yet to deliver audio.
    func next(after previous: Packet? = nil) async -> Packet? {
        while !Task.isCancelled {
            let read = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Read, Never>) in
                    state.withLock { state in
                        if Task.isCancelled {
                            continuation.resume(returning: .end)
                        } else if let packet = state.packets.first {
                            if let previous, !packet.follows(previous) {
                                continuation.resume(returning: .end)
                            } else {
                                state.duration -= state.packets.removeFirst().duration
                                state.meter.overrunSince = nil
                                continuation.resume(returning: .packet(packet))
                            }
                        } else if state.ended || (previous != nil && state.route != previous?.route) {
                            continuation.resume(returning: .end)
                        } else {
                            // One waiter slot: release any previous reader before replacing it,
                            // so an abandoned conversion task cannot leak with its analyzer.
                            state.waiter?.resume(returning: .end)
                            state.waiter = continuation
                        }
                    }
                }
            } onCancel: {
                state.withLock { $0.wakeReader() }
            }
            switch read {
            case .packet(let packet): return packet
            case .end: return nil
            case .retry: continue
            }
        }
        return nil
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let stride = buffer.stride
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[frame * stride]))
            }
        }
        return min(1, peak)
    }
}

extension VoiceAudio {
    /// Pull conversion from the analyzer's iterator so there is only one backlog.
    actor Conversion {
        private let audio: VoiceAudio
        private let converter: AVAudioConverter?
        private let ended: @Sendable () async -> Void
        private var packet: Packet
        private var isFirst = true
        private var isFinished = false
        private var converted: [AnalyzerInput] = []
        private(set) var endUptime: Double

        init(audio: VoiceAudio, first: Packet, destination: AVAudioFormat, anchor: Double,
             ended: @escaping @Sendable () async -> Void) throws {
            self.audio = audio
            self.packet = first
            self.ended = ended
            self.endUptime = anchor
            if first.buffer.format == destination {
                converter = nil
            } else {
                guard let converter = AVAudioConverter(from: first.buffer.format, to: destination) else {
                    throw VoiceFailure.conversion
                }
                converter.primeMethod = .normal
                converter.downmix = first.buffer.format.channelCount > destination.channelCount
                self.converter = converter
            }
        }

        func next() async throws -> AnalyzerInput? {
            while converted.isEmpty {
                guard !isFinished, !Task.isCancelled else { return nil }
                let input = isFirst ? packet : await audio.next(after: packet)
                isFirst = false
                if let input {
                    packet = input
                    endUptime += input.duration
                    guard let converter else { return AnalyzerInput(buffer: input.buffer) }
                    let capacity = ceil(input.duration * converter.outputFormat.sampleRate) + 32
                    guard capacity.isFinite, capacity > 0, capacity <= Double(AVAudioFrameCount.max) else {
                        throw VoiceFailure.conversion
                    }
                    converted = try Self.convert(input, with: converter, capacity: AVAudioFrameCount(capacity))
                } else {
                    isFinished = true
                    guard !Task.isCancelled else { return nil }
                    await ended()
                    if let converter { converted = try Self.convert(nil, with: converter, capacity: 1024) }
                }
            }
            return converted.removeFirst()
        }

        private static func convert(_ input: Packet?, with converter: AVAudioConverter,
                                    capacity: AVAudioFrameCount) throws -> [AnalyzerInput] {
            let supplied = OSAllocatedUnfairLock(initialState: false)
            var output: [AnalyzerInput] = []
            repeat {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
                    throw VoiceFailure.conversion
                }
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { _, state in
                    guard let input else {
                        state.pointee = .endOfStream
                        return nil
                    }
                    let firstRequest = supplied.withLock { wasSupplied in
                        defer { wasSupplied = true }
                        return !wasSupplied
                    }
                    state.pointee = firstRequest ? .haveData : .noDataNow
                    return firstRequest ? input.buffer : nil
                }
                guard status != .error, error == nil else { throw VoiceFailure.conversion }
                if buffer.frameLength > 0 { output.append(AnalyzerInput(buffer: buffer)) }
                if status != .haveData || buffer.frameLength == 0 { return output }
            } while true
        }
    }
}
