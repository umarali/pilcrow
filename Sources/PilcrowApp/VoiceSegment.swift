import AVFoundation
import PilcrowCore
import Speech

/// One contiguous audio timeline and its recognizer results.
@MainActor
final class VoiceSegment {
    enum Outcome {
        case finished
        case drainTimedOut
        case failed(VoiceFailure)
    }

    struct Transcript {
        private struct Result {
            let range: ClosedRange<Double>
            let words: [TranscriptWord]
            let isFinal: Bool

            func covers(_ midpoint: Double) -> Bool {
                range.lowerBound <= midpoint && midpoint < range.upperBound
            }

            func overlaps(_ other: ClosedRange<Double>) -> Bool {
                // Audio ranges are half-open. An empty range is a point at its start.
                if range.lowerBound == other.lowerBound { return true }
                return range.lowerBound < other.upperBound && other.lowerBound < range.upperBound
            }
        }

        private var finalized: [Result] = []
        private var provisional: [Result] = []
        private var finalThrough = -Double.infinity

        var words: [TranscriptWord] {
            (finalized + provisional).flatMap { result in
                let isFinal = result.isFinal || result.range.upperBound <= finalThrough
                return result.words.map { word in
                    var word = word
                    word.isFinal = isFinal
                    return word
                }
            }.sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
        }

        mutating func receive(_ words: [TranscriptWord], in range: ClosedRange<Double>,
                              isFinal: Bool, finalThrough: Double) {
            if !finalThrough.isNaN { self.finalThrough = max(self.finalThrough, finalThrough) }
            var retained = words.map { word in
                (word: word, midpoint: word.start + (word.end - word.start) / 2)
            }
            // Attributed word times can extend outside the result's nominal range.
            let firstMidpoint = retained.map(\.midpoint).min() ?? .infinity
            let lastMidpoint = retained.map(\.midpoint).max() ?? -.infinity
            var overlapsFinal = false
            for prior in finalized where prior.overlaps(range)
                || (firstMidpoint < prior.range.upperBound && prior.range.lowerBound <= lastMidpoint) {
                overlapsFinal = true
                let before = retained.count
                retained.removeAll { prior.covers($0.midpoint) }
                let dropped = before - retained.count
                if dropped > 0, isFinal {
                    voiceLog.notice("Dropped \(dropped, privacy: .public) overlapping final words from \(range.lowerBound, privacy: .public)–\(range.upperBound, privacy: .public) s, covered by \(prior.range.lowerBound, privacy: .public)–\(prior.range.upperBound, privacy: .public) s")
                }
            }
            // A wholly stale volatile result must not revoke a newer tail.
            guard isFinal || !overlapsFinal || !retained.isEmpty else { return }
            // Run timing can move between hypotheses. Replace the whole overlapping result.
            provisional.removeAll { $0.overlaps(range) }
            guard !retained.isEmpty else { return }
            let result = Result(range: range, words: retained.map(\.word), isFinal: isFinal)
            if isFinal {
                finalized.append(result)
            } else {
                // Some unchanged hypotheses become final via the watermark without a new result.
                provisional.append(result)
            }
        }
    }

    struct Drain {
        var analyzerFinished = false
        var resultsFinished = false

        var isComplete: Bool { analyzerFinished && resultsFinished }
    }

    private static let drainLimit: Duration = .milliseconds(1500)
    private let analyzer: SpeechAnalyzer
    private let transcriber: VoiceModel.Transcriber
    private var analysis: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var outcome: Outcome?
    private var drain = Drain()
    private var prepared = false
    private(set) var exhaustedInput = false
    private var transcript = Transcript()
    private var timing: VoiceTiming?
    private let record: (VoiceRecording.Result) -> Void
    private let changed: ([TranscriptWord]) -> Void

    init(model: VoiceModel, record: @escaping (VoiceRecording.Result) -> Void,
         changed: @escaping ([TranscriptWord]) -> Void) {
        let transcriber = model.makeTranscriber()
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber.module])
        self.record = record
        self.changed = changed
    }

    func preferredFormat() async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module])
    }

    func prepare(in format: AVAudioFormat) async throws {
        try await analyzer.prepareToAnalyze(in: format)
        prepared = true
    }

    func run(_ conversion: VoiceAudio.Conversion, format: AVAudioFormat, timing: VoiceTiming) async -> Outcome {
        if let outcome { return outcome }
        self.timing = timing
        let analyzer = self.analyzer
        analysis = Task { [weak self] in
            do {
                if self?.prepared == false { try await self?.prepare(in: format) }
                try Task.checkCancellation()
                let inputs = AsyncThrowingStream<AnalyzerInput, Error>(unfolding: { try await conversion.next() })
                voiceLog.notice("Analyzer started")
                if let lastSample = try await analyzer.analyzeSequence(inputs) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                self?.drain.analyzerFinished = true
                self?.completeIfDrained()
            } catch {
                self?.resolve(.failed(error as? VoiceFailure ?? .analyzer))
            }
        }
        let transcriber = self.transcriber
        results = Task { [weak self] in
            do {
                switch transcriber {
                case .speech(let speech):
                    for try await result in speech.results {
                        guard !Task.isCancelled else { return }
                        self?.receive(result, text: result.text)
                    }
                case .dictation(let dictation):
                    for try await result in dictation.results {
                        guard !Task.isCancelled else { return }
                        self?.receive(result, text: result.text)
                    }
                }
                self?.drain.resultsFinished = true
                self?.completeIfDrained()
            } catch {
                self?.resolve(.failed(.analyzer))
            }
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func limitDrain() {
        guard deadline == nil, outcome == nil else { return }
        exhaustedInput = true
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: Self.drainLimit) }
            catch { return }
            voiceLog.notice("Analyzer drain timed out")
            self?.resolve(.drainTimedOut)
        }
    }

    func abort() { resolve(.failed(.analyzer)) }

    func abortForBacklog() {
        // An exhausted iterator already has a drain deadline.
        guard deadline == nil else { return }
        resolve(.failed(.backlog))
    }

    func cancelAnalyzer() async { await analyzer.cancelAndFinishNow() }

    private func receive(_ result: any SpeechModuleResult, text: AttributedString) {
        guard outcome == nil, let timing else { return }
        let start = timing.sessionSeconds(result.range.start.seconds)
        let end = timing.sessionSeconds(result.range.end.seconds)
        let words = Self.words(in: text, resultRange: result.range, timing: timing, isFinal: result.isFinal)
        let finalThrough = timing.sessionSeconds(result.resultsFinalizationTime.seconds)
        VoiceNarration.logResult(start: start, end: end, isFinal: result.isFinal, finalThrough: finalThrough,
                                 wordCount: words.count)
        guard start.isFinite, end.isFinite, end >= start else { return }
        record(VoiceRecording.Result(start: start, end: end, isFinal: result.isFinal,
                                     finalWords: result.isFinal ? words : nil))
        transcript.receive(words, in: start...end, isFinal: result.isFinal, finalThrough: finalThrough)
        publish()
    }

    static func words(in text: AttributedString, resultRange: CMTimeRange,
                      timing: VoiceTiming, isFinal: Bool) -> [TranscriptWord] {
        let start = resultRange.start.seconds
        let end = resultRange.end.seconds
        guard start.isFinite, end.isFinite, start <= end else { return [] }
        let runs = text.runs.map { attributes in
            let run = String(String.UnicodeScalarView(text[attributes.range].unicodeScalars))
            let range: ClosedRange<Double>?
            if let time = attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
               time.start.seconds.isFinite, time.end.seconds.isFinite, time.start <= time.end {
                range = time.start.seconds...time.end.seconds
            } else {
                range = nil
            }
            return VoiceTiming.Run(text: run, range: range)
        }
        return timing.words(in: runs, resultRange: start...end, isFinal: isFinal)
    }

    private func publish() {
        let words = transcript.words
        let finalCount = words.count(where: \.isFinal)
        voiceLog.info("Words: \(finalCount, privacy: .public) final, \(words.count - finalCount, privacy: .public) provisional")
        changed(words)
    }

    private func completeIfDrained() {
        // The result stream can still have a queued final after the analyzer returns.
        guard outcome == nil, drain.isComplete else { return }
        resolve(.finished)
    }

    private func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        deadline?.cancel()
        deadline = nil
        let finalized: Bool
        switch outcome {
        case .finished:
            finalized = true
        case .drainTimedOut, .failed:
            finalized = false
            analysis?.cancel()
            results?.cancel()
        }
        analysis = nil
        results = nil
        voiceLog.notice("Analyzer stopped, finalized: \(finalized, privacy: .public)")
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}
