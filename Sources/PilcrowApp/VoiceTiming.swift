import Foundation
import PilcrowCore

/// Maps the recognizer's per-stream timeline to the same uptime clock as pen-down.
struct VoiceTiming {
    struct Run {
        let text: String
        let range: ClosedRange<Double>?
    }

    private struct Token {
        var text = ""
        var parts: [(run: Int, count: Int)] = []

        mutating func addCharacters(_ count: Int, in run: Int) {
            if parts.last?.run == run {
                parts[parts.count - 1].count += count
            } else {
                parts.append((run, count))
            }
        }

        mutating func append(_ token: Token) {
            text += token.text
            for part in token.parts { addCharacters(part.count, in: part.run) }
        }
    }

    let sessionStart: Double
    let audioStart: Double

    static func audioAnchor(hostSeconds: Double, inputLatency: Double, after previousEnd: Double) -> Double {
        let latency = inputLatency.isFinite && inputLatency >= 0 ? inputLatency : 0
        return max(previousEnd, hostSeconds - latency)
    }

    func sessionSeconds(_ recognizerSeconds: Double) -> Double {
        recognizerSeconds + (audioStart - sessionStart)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic }
            || (character.isLetter && String(character).range(
                of: #"[\p{scx=Hira}\p{scx=Kana}\p{scx=Hang}]"#, options: .regularExpression) != nil)
    }

    private static func followsWord(_ character: Character, timed: Bool) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .openPunctuation, .initialPunctuation, .dashPunctuation:
                return false
            case .closePunctuation, .finalPunctuation:
                return true
            default:
                return !timed || scalar == "…" || scalar.properties.isTerminalPunctuation
            }
        }
    }

    private func tokens(in runs: [Run]) -> [Token] {
        var words: [Token] = []
        var prefix = Token()
        let straightQuotes: Set<Character> = ["\"", "'"]
        var openQuotes: Set<Character> = []
        func append(_ token: Token) {
            guard !token.text.isEmpty else { return }
            if token.text.allSatisfy(\.isPunctuation) {
                let timed = token.parts.contains { runs[$0.run].range != nil }
                let attaches: Bool
                if token.text.count == 1, let quote = token.text.first, straightQuotes.contains(quote) {
                    attaches = openQuotes.remove(quote) != nil
                    if !attaches { openQuotes.insert(quote) }
                } else {
                    attaches = token.text.allSatisfy { Self.followsWord($0, timed: timed) }
                }
                if attaches, prefix.text.isEmpty, !words.isEmpty {
                    words[words.count - 1].append(token)
                } else {
                    prefix.append(token)
                }
            } else {
                if let first = token.text.first, straightQuotes.contains(first) { openQuotes.insert(first) }
                if let last = token.text.last, straightQuotes.contains(last) { openQuotes.remove(last) }
                prefix.append(token)
                words.append(prefix)
                prefix = Token()
            }
        }

        // Count grapheme clusters and retain the runs that supplied each word, including
        // the rare case where a run boundary falls inside a grapheme cluster.
        var runEnd = 0
        let runEnds = runs.map {
            runEnd += $0.text.utf8.count
            return runEnd
        }
        var run = 0
        var previousRun = 0
        var previous: Character?
        var offset = 0
        var token = Token()
        for character in runs.map(\.text).joined() {
            while runEnds[run] <= offset { run += 1 }
            let end = offset + String(character).utf8.count
            if character.isWhitespace {
                append(token)
                token = Token()
                previous = nil
            } else {
                if let previous, previousRun != run,
                   runs[previousRun].range != nil, runs[run].range != nil,
                   Self.isCJK(previous) || Self.isCJK(character) {
                    append(token)
                    token = Token()
                }
                token.text.append(character)
                token.addCharacters(1, in: run)
                while runEnds[run] < end {
                    run += 1
                    if runEnds[run] > runEnds[run - 1] { token.addCharacters(1, in: run) }
                }
                previous = character
                previousRun = run
            }
            offset = end
        }
        append(token)
        if !prefix.text.isEmpty { words.append(prefix) }
        return words
    }

    func words(in runs: [Run], resultRange: ClosedRange<Double>, isFinal: Bool) -> [TranscriptWord] {
        let words = tokens(in: runs)
        var uses = Array(repeating: 0, count: runs.count)
        var lengths = uses
        for word in words {
            for part in word.parts {
                uses[part.run] += 1
                lengths[part.run] += part.count
            }
        }

        var consumedByRun = Array(repeating: 0, count: runs.count)
        let ranges = words.map { word -> ClosedRange<Double>? in
            var range: ClosedRange<Double>?
            for part in word.parts {
                let index = part.run
                guard let run = runs[index].range else { continue }
                let length = lengths[index]
                let duration = run.upperBound - run.lowerBound
                let start = run.lowerBound + duration * (Double(consumedByRun[index]) / Double(length))
                consumedByRun[index] += part.count
                let end = consumedByRun[index] == length ? run.upperBound
                    : run.lowerBound + duration * (Double(consumedByRun[index]) / Double(length))
                range = range.map { min($0.lowerBound, start)...max($0.upperBound, end) } ?? start...end
            }
            return range
        }

        func makeWord(_ index: Int, range: ClosedRange<Double>, estimated: Bool) -> TranscriptWord {
            TranscriptWord(text: words[index].text, start: sessionSeconds(range.lowerBound),
                           end: sessionSeconds(range.upperBound), isFinal: isFinal, isEstimated: estimated)
        }

        var result: [TranscriptWord] = []
        var index = 0
        var cursor = resultRange.lowerBound
        while index < words.count {
            if let range = ranges[index] {
                let parts = words[index].parts
                let estimated = parts.count != 1 || uses[parts[0].run] != 1
                result.append(makeWord(index, range: range, estimated: estimated))
                cursor = range.upperBound
                index += 1
            } else {
                let first = index
                while index < words.count, ranges[index] == nil { index += 1 }
                let upcoming = index < ranges.count ? ranges[index]?.lowerBound : nil
                let end = max(cursor, upcoming ?? resultRange.upperBound)
                let length = words[first..<index].reduce(0) { $0 + $1.text.count }
                var consumed = 0
                let start = cursor
                for i in first..<index {
                    consumed += words[i].text.count
                    let next = consumed == length ? end : start + (end - start) * Double(consumed) / Double(length)
                    result.append(makeWord(i, range: cursor...next, estimated: true))
                    cursor = next
                }
            }
        }
        return result
    }
}
