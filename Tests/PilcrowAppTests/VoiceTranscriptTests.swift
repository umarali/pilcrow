import PilcrowCore
import XCTest
@testable import PilcrowApp

final class VoiceTranscriptTests: XCTestCase {
    func testRevisionUsesResultRangeRatherThanEstimatedWordBoundaries() {
        var transcript = VoiceSegment.Transcript()
        transcript.receive([
            TranscriptWord(text: "Hey", start: 0.1, end: 0.3, isFinal: false),
            TranscriptWord(text: "there", start: 0.3, end: 0.6, isFinal: false),
        ], in: 0...2, isFinal: false, finalThrough: 0)
        transcript.receive([
            TranscriptWord(text: "Hey", start: 0.8, end: 1.1, isFinal: false),
            TranscriptWord(text: "there,", start: 1.1, end: 1.4, isFinal: false),
        ], in: 0.75...2.5, isFinal: false, finalThrough: 0)
        XCTAssertEqual(transcript.words.map(\.text), ["Hey", "there,"])
        XCTAssertEqual(transcript.words.map(\.start), [0.8, 1.1])
        transcript.receive([
            TranscriptWord(text: "Hey", start: 1.6, end: 1.8, isFinal: true),
            TranscriptWord(text: "there.", start: 1.8, end: 2.1, isFinal: true),
        ], in: 1.5...2.5, isFinal: true, finalThrough: 2.5)
        XCTAssertEqual(transcript.words.map(\.text), ["Hey", "there."])
        XCTAssertEqual(transcript.words.map(\.start), [1.6, 1.8])
    }

    func testFinalSupersedesRevisionAndKeepsDisjointTail() {
        let timing = VoiceTiming(sessionStart: 100, audioStart: 101)
        var transcript = VoiceSegment.Transcript()
        receive("to go up it", in: 0...1, timing: timing, into: &transcript)
        receive("to go up", in: 0...1.1, timing: timing, into: &transcript)
        receive("so we have padding", in: 1.2...2, timing: timing, into: &transcript)
        receive("to go up,", in: 0...1.2, timing: timing, isFinal: true, finalThrough: 1.2, into: &transcript)

        XCTAssertEqual(transcript.words.map(\.text), ["to", "go", "up,", "so", "we", "have", "padding"])
        XCTAssertEqual(transcript.words.map(\.isFinal), [true, true, true, false, false, false, false])
        XCTAssertEqual(transcript.words.first?.start, 1)
        XCTAssertEqual(transcript.words[2].end, 2.2)
        XCTAssertEqual(transcript.words[3].start, 2.2)
        XCTAssertEqual(transcript.words.last?.end, 3)
    }

    func testWatermarkFinalizesUnchangedResultAsAUnit() {
        let timing = VoiceTiming(sessionStart: 10, audioStart: 10)
        var transcript = VoiceSegment.Transcript()
        receive("down below", in: 0...1, timing: timing, finalThrough: 0.6, into: &transcript)
        XCTAssertEqual(transcript.words.map(\.isFinal), [false, false])
        receive("down below.", in: 0.25...1.1, timing: timing, finalThrough: 0.6, into: &transcript)
        receive("next", in: 1.1...2, timing: timing, finalThrough: 1.1, into: &transcript)
        XCTAssertEqual(transcript.words.map(\.text), ["down", "below.", "next"])
        XCTAssertEqual(transcript.words.map(\.isFinal), [true, true, false])
    }

    func testStaleVolatileCannotReplaceFinalOrRemoveAdjacentTail() {
        let timing = VoiceTiming(sessionStart: 0, audioStart: 0)
        var transcript = VoiceSegment.Transcript()
        receive("like that.", in: 0...1, timing: timing, isFinal: true, finalThrough: 1, into: &transcript)
        receive("next", in: 1...2, timing: timing, into: &transcript)
        receive("like this", in: 0...1.05, timing: timing, into: &transcript)
        XCTAssertEqual(transcript.words.map(\.text), ["like", "that.", "next"])
        XCTAssertEqual(transcript.words.map(\.isFinal), [true, true, false])
    }

    func testOutOfOrderResultsReturnWordsInAudioOrder() {
        let timing = VoiceTiming(sessionStart: 0, audioStart: 0)
        var transcript = VoiceSegment.Transcript()
        receive("later.", in: 2...3, timing: timing, isFinal: true, into: &transcript)
        receive("earlier.", in: 0...2, timing: timing, isFinal: true, into: &transcript)
        XCTAssertEqual(transcript.words.map(\.text), ["earlier.", "later."])
        XCTAssertEqual(transcript.words.map(\.start), [0, 2])
    }

    func testOverlappingFinalKeepsTailAndEmptyFinalDoesNotBlock() {
        let timing = VoiceTiming(sessionStart: 0, audioStart: 0)
        var transcript = VoiceSegment.Transcript()
        receive("one two.", in: 0...2, timing: timing, isFinal: true, into: &transcript)
        receive("two.", in: 1.95...2.1, wordRange: 1.95...1.99, timing: timing, isFinal: true, into: &transcript)
        receive("", in: 2...2, timing: timing, isFinal: true, into: &transcript)
        receive("three", in: 2...3, timing: timing, isFinal: true, into: &transcript)
        XCTAssertEqual(transcript.words.map(\.text), ["one", "two.", "three"])
        XCTAssertEqual(transcript.words.last?.start, 2)

        transcript.receive([
            TranscriptWord(text: "three", start: 2.95, end: 2.99, isFinal: true),
            TranscriptWord(text: "four.", start: 2.99, end: 3.25, isFinal: true),
            TranscriptWord(text: "five.", start: 3.25, end: 3.5, isFinal: true),
        ], in: 2.95...3.5, isFinal: true, finalThrough: 3.5)
        XCTAssertEqual(transcript.words.map(\.text), ["one", "two.", "three", "four.", "five."])
    }

    func testVolatileStartingInsideFinalizedAudioKeepsNewWords() {
        let timing = VoiceTiming(sessionStart: 0, audioStart: 0)
        var transcript = VoiceSegment.Transcript()
        receive("one two.", in: 0...2, timing: timing, isFinal: true, into: &transcript)
        receive("three four", in: 1.95...3, timing: timing, into: &transcript)
        XCTAssertEqual(transcript.words.map(\.text), ["one", "two.", "three", "four"])
        XCTAssertEqual(transcript.words.map(\.isFinal), [true, true, false, false])
    }

    func testWordStraddlingFinalBoundaryUsesItsMidpoint() {
        let timing = VoiceTiming(sessionStart: 0, audioStart: 0)
        for resultStart in [2.8, 3.0] {
            var transcript = VoiceSegment.Transcript()
            receive("one two three.", in: 0...3, timing: timing, isFinal: true, into: &transcript)
            transcript.receive([
                TranscriptWord(text: "three", start: 2.8, end: 3.1, isFinal: true),
                TranscriptWord(text: "four", start: 2.98, end: 3.25, isFinal: true),
                TranscriptWord(text: "five.", start: 3.25, end: 3.5, isFinal: true),
            ], in: resultStart...3.5, isFinal: true, finalThrough: 3.5)
            XCTAssertEqual(transcript.words.map(\.text), ["one", "two", "three.", "four", "five."])
        }
    }

    func testZeroLengthFinalWithWordsDoesNotCoverFollowingFinal() {
        let timing = VoiceTiming(sessionStart: 0, audioStart: 0)
        var transcript = VoiceSegment.Transcript()
        receive("and", in: 2...2, timing: timing, isFinal: true, into: &transcript)
        receive("then this.", in: 2...3, timing: timing, isFinal: true, into: &transcript)
        XCTAssertEqual(transcript.words.map(\.text), ["and", "then", "this."])
    }

    func testFinishWaitsForFinalAfterAnalyzerDrain() {
        let timing = VoiceTiming(sessionStart: 100, audioStart: 100)
        var transcript = VoiceSegment.Transcript()
        var drain = VoiceSegment.Drain()
        receive("like this", in: 0...1, timing: timing, into: &transcript)
        drain.analyzerFinished = true
        XCTAssertFalse(drain.isComplete)
        XCTAssertEqual(transcript.words.map(\.text), ["like", "this"])
        XCTAssertEqual(transcript.words.map(\.isFinal), [false, false])

        receive("like that.", in: 0...1, timing: timing, isFinal: true, finalThrough: 1, into: &transcript)
        drain.resultsFinished = true
        XCTAssertTrue(drain.isComplete)
        XCTAssertEqual(transcript.words.map(\.text), ["like", "that."])
        XCTAssertEqual(transcript.words.map(\.isFinal), [true, true])
        XCTAssertEqual(transcript.words.last?.end, 1)
    }

    func testHandoffOffsetsNewAudioAndRetainsOnlyFinalizedHistory() {
        var narration = VoiceNarration.Transcript()
        let oldTiming = narration.beginSegment(sessionStart: 100, hostSeconds: 101.125, latency: 0.125,
                                               previousAudioEnd: -.infinity)
        var old = VoiceSegment.Transcript()
        receive("over here", in: 0...1, timing: oldTiming, isFinal: true, finalThrough: 1, into: &old)
        receive("stale words", in: 1...2, timing: oldTiming, into: &old)
        narration.segmentWords = old.words
        XCTAssertEqual(narration.words.map(\.text), ["over", "here", "stale", "words"])

        let newTiming = narration.beginSegment(sessionStart: 100, hostSeconds: 103, latency: 0.25,
                                               previousAudioEnd: 102.875)
        XCTAssertEqual(newTiming.audioStart, 102.875)
        XCTAssertEqual(narration.words.map(\.text), ["over", "here"])
        var new = VoiceSegment.Transcript()
        receive("over here", in: 0...1, timing: newTiming, isFinal: true, finalThrough: 1, into: &new)
        narration.segmentWords = new.words
        XCTAssertEqual(narration.words.map(\.text), ["over", "here", "over", "here"])
        XCTAssertEqual(narration.words[0].start, 1)
        XCTAssertEqual(narration.words[1].end, 2)
        XCTAssertEqual(narration.words[2].start, 2.875)
        XCTAssertEqual(narration.words[3].end, 3.875)
    }

    func testDrainTimeoutPreservesProvisionalTailAcrossHandoff() {
        var narration = VoiceNarration.Transcript()
        let timing = narration.beginSegment(sessionStart: 100, hostSeconds: 101, latency: 0,
                                            previousAudioEnd: -.infinity)
        var old = VoiceSegment.Transcript()
        receive("move this", in: 0...1, timing: timing, isFinal: true, finalThrough: 1, into: &old)
        receive("over here", in: 1...2, timing: timing, into: &old)
        narration.segmentWords = old.words
        narration.retainTimedOutTail()
        let newTiming = narration.beginSegment(sessionStart: 100, hostSeconds: 102.6, latency: 0,
                                               previousAudioEnd: 102.8)
        XCTAssertEqual(narration.words.map(\.text), ["move", "this", "over", "here"])
        XCTAssertTrue(narration.words.allSatisfy(\.isFinal))
        XCTAssertEqual(newTiming.audioStart, 103)
    }

    func testLiveExampleAThroughOutgoingMessage() throws {
        let timing = VoiceTiming(sessionStart: 10, audioStart: 10)
        var transcript = VoiceSegment.Transcript()
        receive("I would like to make a few changes so like, um,", in: 0...2.6, timing: timing,
                isFinal: true, finalThrough: 2.6, into: &transcript)
        receive("Instead of showing this here.", in: 3.3...4.3, timing: timing,
                isFinal: true, finalThrough: 4.3, into: &transcript)
        receive("I I would like to move it.", in: 4.7...5.9, timing: timing,
                isFinal: true, finalThrough: 5.9, into: &transcript)
        receive("on on the left", in: 5.95...6.65, timing: timing, isFinal: true, finalThrough: 6.65, into: &transcript)
        receive("like that like that", in: 7.3...7.95, wordRange: 7.3...7.39, timing: timing, into: &transcript)
        receive("like that", in: 7.3...7.95, wordRange: 7.41...7.47, timing: timing, into: &transcript)
        receive("like that.", in: 7.3...7.95, wordRange: 7.5...7.8, timing: timing,
                isFinal: true, finalThrough: 7.95, into: &transcript)
        let session = try makeSession(words: transcript.words, penDowns: [4.25, 6.09, 7.65])

        XCTAssertEqual(FixList.build(session: session).items.map(\.words), [
            "Instead of showing this here.", "I would like to move it. on the left", "like that.",
        ])
        XCTAssertEqual(MessageBuilder.build(session: session).text, """
        I would like to make a few changes so like, um, Instead of showing this here. [1] I I would like to move it. on [2] on the left like [3] that.

        - [1] "Instead of showing this here." → mark-1.png (in frame-1.png)
        - [2] "I would like to move it. on the left" → mark-2.png (in frame-1.png)
        - [3] "like that." → mark-3.png (in frame-1.png)
        """)
    }

    func testLiveExampleBThroughOutgoingMessage() throws {
        let timing = VoiceTiming(sessionStart: 10, audioStart: 10)
        var transcript = VoiceSegment.Transcript()
        receive("Hey there, so I'm just gonna", in: 0...1.3, timing: timing, into: &transcript)
        receive("Hey there, so, I'm just... gonna give a quick... Uh... cry to this, so...", in: 0...3.3,
                timing: timing, isFinal: true, finalThrough: 3.3, into: &transcript)
        receive("I want this piece.", in: 4...4.75, timing: timing, isFinal: true, finalThrough: 4.75, into: &transcript)
        receive("To to go on this side.", in: 4.9...6, timing: timing, isFinal: true, finalThrough: 6, into: &transcript)
        receive("And... this And... this", in: 6.2...6.6, wordRange: 6.2...6.32, timing: timing, into: &transcript)
        receive("And this", in: 6.2...6.6, wordRange: 6.35...6.6, timing: timing,
                isFinal: true, finalThrough: 6.6, into: &transcript)
        receive("this following box.", in: 7.28...7.9, timing: timing, isFinal: true, finalThrough: 7.9, into: &transcript)
        receive("to go up it", in: 8.05...9.2, wordRange: 8.85...9.2, timing: timing, into: &transcript)
        receive("up to go up it", in: 8.05...9.25, wordRange: 8.55...8.8, timing: timing, into: &transcript)
        receive("to go up,", in: 8.05...9.25, wordRange: 8.05...8.5, timing: timing,
                isFinal: true, finalThrough: 9.25, into: &transcript)
        receive("so that we have some good padding from down below.", in: 9.25...11.1, timing: timing,
                isFinal: true, finalThrough: 11.1, into: &transcript)
        let session = try makeSession(words: transcript.words, penDowns: [4.7, 5.12, 6.57, 7.84, 8.4],
                                      shapes: [.area(.freeform), .arrow(from: 1, to: nil), .area(.freeform),
                                               .area(.freeform), .arrow(from: 4, to: nil)])

        XCTAssertEqual(FixList.build(session: session).items.map(\.words), [
            "I want this piece.", "To go on this side.", "And this", "this following box.",
            "to go up, so that we have some good padding from down below.",
        ])
        XCTAssertEqual(MessageBuilder.build(session: session).text, """
        Hey there, so, I'm just... gonna give a quick... Uh... cry to this, so... I want this piece. [1] To to [2] go on this side. And this [3] this following box. [4] to go up, [5] so that we have some good padding from down below.

        - [1] (area) "I want this piece." → mark-1.png (in frame-1.png)
        - [2] (arrow starting at [1]) "To go on this side." → mark-2.png (in frame-1.png)
        - [3] (area) "And this" → mark-3.png (in frame-1.png)
        - [4] (area) "this following box." → mark-4.png (in frame-1.png)
        - [5] (arrow starting at [4]) "to go up, so that we have some good padding from down below." → mark-5.png (in frame-1.png)
        """)
    }

    private func receive(_ text: String, in range: ClosedRange<Double>, wordRange: ClosedRange<Double>? = nil,
                         timing: VoiceTiming,
                         isFinal: Bool = false, finalThrough: Double = -.infinity,
                         into transcript: inout VoiceSegment.Transcript) {
        let words = timing.words(in: [.init(text: text, range: wordRange ?? range)], resultRange: range, isFinal: isFinal)
        let sessionRange = timing.sessionSeconds(range.lowerBound)...timing.sessionSeconds(range.upperBound)
        transcript.receive(words, in: sessionRange, isFinal: isFinal, finalThrough: timing.sessionSeconds(finalThrough))
    }

    private func makeSession(words: [TranscriptWord], penDowns: [Double], shapes: [MarkShape] = []) throws -> Session {
        let frame = Frame(id: Frame.ID(), capturedAt: 0, displayID: 1,
                          boundsInPoints: Size(width: 800, height: 600), pixelSize: Size(width: 1600, height: 1200))
        let point = NormalizedPoint(x: 0.4, y: 0.4)
        let strokes = penDowns.enumerated().map { index, time in
            Stroke(id: MarkID(rawValue: index + 1), frameID: frame.id, downTime: time, upTime: time + 0.15,
                   points: [point], badgeAnchor: point, shape: shapes.isEmpty ? nil : shapes[index])
        }
        return try Session(strokes: strokes, frames: [frame], words: words, transcriptLanguageCode: "en")
    }
}
