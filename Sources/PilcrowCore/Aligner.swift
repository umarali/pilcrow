import Foundation

public enum TranscriptToken: Sendable, Equatable, Hashable, Codable {
    case word(String)
    case mark(MarkID)
}

/// Inserts mark tokens into a word list by stroke-down time.
public enum Aligner {
    /// Places live strokes among words.
    ///
    /// A mark follows all words that have started by its down time.
    /// Non-finite words are dropped; non-finite marks trail in id order.
    ///
    /// - Parameter onlyFinal: When `true`, non-final words are dropped before placement. Default `false`.
    public static func place(
        words: [TranscriptWord],
        strokes: [Stroke],
        onlyFinal: Bool = false
    ) -> [TranscriptToken] {
        place(sortedWords: sortedWords(words, onlyFinal: onlyFinal), sortedStrokes: sortedLiveStrokes(strokes))
    }

    static func sortedWords(_ words: [TranscriptWord], onlyFinal: Bool) -> [TranscriptWord] {
        words.enumerated()
            .filter { _, word in word.start.isFinite && word.end.isFinite && (!onlyFinal || word.isFinal) }
            .sorted { lhs, rhs in
                if lhs.element.start != rhs.element.start {
                    return lhs.element.start < rhs.element.start
                }
                if lhs.element.end != rhs.element.end {
                    return lhs.element.end < rhs.element.end
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func sortedLiveStrokes(_ strokes: [Stroke]) -> [Stroke] {
        sortedStrokes(strokes.filter { !$0.isDeleted && $0.absorbedInto == nil })
    }

    private static func sortedStrokes(_ strokes: [Stroke]) -> [Stroke] {
        strokes.sorted { lhs, rhs in
            if lhs.downTime.isFinite != rhs.downTime.isFinite { return lhs.downTime.isFinite }
            if !lhs.downTime.isFinite { return lhs.id < rhs.id }
            if lhs.downTime != rhs.downTime { return lhs.downTime < rhs.downTime }
            return lhs.id < rhs.id
        }
    }

    static func place(sortedWords: [TranscriptWord], sortedStrokes: [Stroke],
                      toleratesWordStarts: Bool = false) -> [TranscriptToken] {
        guard !sortedWords.isEmpty else {
            return sortedStrokes.map { .mark($0.id) }
        }

        // Slot 0 is before the first word. Slot `i + 1` is immediately after word `i`.
        var marksAtSlot = Array(repeating: [TranscriptToken](), count: sortedWords.count + 1)
        for stroke in sortedStrokes {
            let slot = slot(for: stroke.downTime, in: sortedWords, toleratesWordStarts: toleratesWordStarts)
            marksAtSlot[slot].append(.mark(stroke.id))
        }

        var tokens: [TranscriptToken] = []
        tokens.reserveCapacity(sortedWords.count + sortedStrokes.count)
        for index in sortedWords.indices {
            tokens.append(contentsOf: marksAtSlot[index])
            tokens.append(.word(sortedWords[index].text))
        }
        tokens.append(contentsOf: marksAtSlot[sortedWords.count])
        return tokens
    }

    private static let clausePause = 0.6
    private static let thinkingPause = 1.5
    private static let clauseTail = 0.3
    private static let leadGap = 0.5
    private static let maximumDistance = 2.5
    private static let quickMarkGap = 1.0

    private struct Fragment {
        let words: Range<Int>
        let interval: ClosedRange<Double>
        var owner: Int?
        var sharedThrough: Int? = nil
        var isWholeClause = true
        var reserved = false
    }

    /// Returns word indices in paragraph order, with ownership in stored mark order.
    static func contexts(words: [TranscriptWord], strokes: [Stroke], hasText: [Bool]) -> [MarkID: [Int]] {
        let strokes = strokes.filter { $0.downTime.isFinite && $0.absorbedInto == nil }
        guard !strokes.isEmpty, !words.isEmpty else { return [:] }

        let clauses = clauses(in: words)
        var fragments = initialFragments(words: words, clauses: clauses, strokes: strokes)
        resolveUndo(&fragments, clauses: clauses, strokes: strokes)
        groupQuickMarks(&fragments, words: words, strokes: strokes, hasText: hasText)
        fragments = repair(fragments, strokes: strokes, hasText: hasText)
        shareSilentRuns(&fragments, words: words, strokes: strokes, hasText: hasText)

        var contexts: [MarkID: [Int]] = [:]
        for fragment in fragments {
            guard let owner = fragment.owner else { continue }
            for mark in owner...(fragment.sharedThrough ?? owner) {
                contexts[strokes[mark].id, default: []].append(contentsOf: fragment.words)
            }
        }
        return contexts
    }

    private static func initialFragments(words: [TranscriptWord], clauses: [ArraySlice<TranscriptWord>],
                                         strokes: [Stroke]) -> [Fragment] {
        let byTime = strokes.indices.sorted {
            if strokes[$0].downTime != strokes[$1].downTime {
                return strokes[$0].downTime < strokes[$1].downTime
            }
            return $0 < $1
        }
        var fragments: [Fragment] = []
        var lastOwner: Int?
        var speechEnd = -Double.infinity
        let punctuated = words.contains { endsClause($0.text) }

        func note(_ owner: Int, _ range: Range<Int>, _ end: Double) {
            let fragmentEnd = max(words[range.lowerBound].start, words[range].map(\.end).max() ?? end)
            speechEnd = owner == lastOwner ? max(speechEnd, fragmentEnd) : fragmentEnd
            lastOwner = owner
        }

        var index = 0
        while index < clauses.count {
            // A sentence: clauses separated only by a short pause, with no terminal punctuation.
            var upper = index + 1
            while punctuated, upper < clauses.count,
                  let previous = clauses[upper - 1].last, !endsClause(previous.text),
                  clauses[upper][clauses[upper].startIndex].start - (clauses[upper - 1].map(\.end).max() ?? 0) < thinkingPause {
                upper += 1
            }
            let firstFragment = fragments.count
            var pending: [Int] = []
            var sentenceOwner: Int?
            var sentenceStart = Double.infinity, sentenceEnd = -Double.infinity

            func assignPending(to owner: Int) {
                for fragment in pending {
                    fragments[fragment].owner = owner
                    note(owner, fragments[fragment].words, fragments[fragment].interval.upperBound)
                }
                pending.removeAll()
            }

            for clause in clauses[index..<upper] {
                let start = clause[clause.startIndex].start
                let end = max(start, clause.map(\.end).max() ?? start)
                let interval = start...end
                // Keep a separate intro in the paragraph unless the repair needs it.
                guard strokes[byTime[0]].downTime - end < clausePause else {
                    fragments.append(Fragment(words: clause.indices, interval: interval, owner: nil))
                    continue
                }
                sentenceStart = min(sentenceStart, start)
                sentenceEnd = max(sentenceEnd, end)

                let hasOnset = strokes.contains { start <= $0.downTime && $0.downTime < end }
                let nextStart = clause.endIndex < words.endIndex ? words[clause.endIndex].start : .infinity
                let onsets = byTime.enumerated().compactMap { position, index -> Int? in
                    let down = strokes[index].downTime
                    guard down >= start else { return nil }
                    // Once the next clause starts, keep this tail with its own pen-downs.
                    if down >= end, hasOnset, down >= nextStart { return nil }
                    if down - end <= clauseTail { return index }
                    let previousUp = position > 0 ? penUp(strokes[byTime[position - 1]]) : -.infinity
                    return down - end <= leadGap && end > previousUp ? index : nil
                }
                if onsets.isEmpty {
                    // A stroke drawn across this clause owns it outright.
                    let touching = byTime.min {
                        proximity(of: strokes[$0], to: interval) < proximity(of: strokes[$1], to: interval)
                    }.flatMap { distance(from: strokes[$0], to: interval) == 0 ? $0 : nil }
                    if let touching {
                        assignPending(to: touching)
                        fragments.append(Fragment(words: clause.indices, interval: interval, owner: touching))
                        note(touching, clause.indices, end)
                        sentenceOwner = touching
                    } else if let sentenceOwner {
                        fragments.append(Fragment(words: clause.indices, interval: interval, owner: sentenceOwner))
                        note(sentenceOwner, clause.indices, end)
                    } else {
                        pending.append(fragments.count)
                        fragments.append(Fragment(words: clause.indices, interval: interval, owner: nil))
                    }
                    continue
                }
                let assigned = split(clause, among: onsets, strokes: strokes)
                if let first = assigned.first {
                    assignPending(to: first.owner)
                }
                fragments.append(contentsOf: assigned.map {
                    Fragment(words: $0.words, interval: interval, owner: $0.owner, isWholeClause: assigned.count == 1)
                })
                if let last = assigned.last {
                    note(last.owner, last.words, end)
                    sentenceOwner = last.owner
                }
            }
            if !pending.isEmpty {
                let interval = sentenceStart...sentenceEnd
                let nearest = byTime.min {
                    proximity(of: strokes[$0], to: interval) < proximity(of: strokes[$1], to: interval)
                }
                let owner: Int?
                if let nearest, distance(from: strokes[nearest], to: interval) <= maximumDistance {
                    owner = nearest
                } else if let lastOwner, sentenceStart - speechEnd <= maximumDistance, sentenceStart >= strokes[lastOwner].downTime {
                    owner = lastOwner
                } else {
                    owner = nil
                }
                if let owner {
                    assignPending(to: owner)
                }
            }
            // Keep a sentence with one owner intact during ordered repair.
            if fragments.count - firstFragment > 1, let owner = fragments[firstFragment].owner,
               fragments[firstFragment...].allSatisfy({ $0.owner == owner && $0.isWholeClause }) {
                let range = fragments[firstFragment].words.lowerBound..<clauses[upper - 1].endIndex
                fragments.replaceSubrange(firstFragment..., with: [
                    Fragment(words: range, interval: sentenceStart...sentenceEnd, owner: owner)
                ])
            }
            index = upper
        }
        return fragments
    }

    private static func resolveUndo(_ fragments: inout [Fragment], clauses: [ArraySlice<TranscriptWord>], strokes: [Stroke]) {
        var replacement: Int?
        var redraws: [Int: Int] = [:]
        for index in strokes.indices.reversed() {
            let stroke = strokes[index]
            if !stroke.isDeleted {
                replacement = index
            } else if let replacement {
                let up = penUp(stroke)
                let down = strokes[replacement].downTime
                guard up <= down else { continue }
                // Speech already under way when the pen lifted is still about this mark.
                let narrated = Set(fragments.lazy.filter { $0.owner == index }.flatMap(\.words))
                let hasNewSpeech = clauses.contains { clause in
                    let beganByPenUp = clause[clause.startIndex].start <= up
                    return clause.indices.contains { word in
                        up < clause[word].start && clause[word].start <= down
                            && !(beganByPenUp && narrated.contains(word))
                    }
                }
                if !hasNewSpeech { redraws[index] = replacement }
            }
        }
        for index in fragments.indices {
            guard let owner = fragments[index].owner, strokes[owner].isDeleted else { continue }
            fragments[index].owner = redraws[owner]
            fragments[index].reserved = redraws[owner] == nil
        }
    }

    private static func groupQuickMarks(_ fragments: inout [Fragment], words: [TranscriptWord], strokes: [Stroke],
                                        hasText: [Bool]) {
        var lastFragment: [Int: Int] = [:]
        for index in fragments.indices {
            if let owner = fragments[index].owner { lastFragment[owner] = index }
        }
        var lastShared = -1
        for index in fragments.indices {
            guard let owner = fragments[index].owner, owner > lastShared, lastFragment[owner] == index,
                  fragments[index].isWholeClause, isQuickShape(strokes[owner]),
                  fragments[index].words.contains(where: { hasText[$0] }),
                  strokes[owner].downTime >= fragments[index].interval.lowerBound,
                  strokes[owner].downTime - fragments[index].interval.upperBound <= leadGap
            else { continue }

            var last = owner
            for next in strokes.indices.dropFirst(owner + 1) {
                let before = strokes[last].downTime, after = strokes[next].downTime
                guard lastFragment[next] == nil, isQuickShape(strokes[next]), !strokes[next].isDeleted,
                      before < after, after - before <= quickMarkGap,
                      !words.contains(where: { before < $0.start && $0.start <= after }) else { break }
                last = next
            }
            if last > owner {
                fragments[index].sharedThrough = last
                lastShared = last
            }
        }
    }

    private static func isQuickShape(_ stroke: Stroke) -> Bool {
        switch stroke.shape {
        case .pin, .area(.ellipse): true
        default: false
        }
    }

    /// Share a single sentence just before or after an otherwise silent run of marks.
    private static func shareSilentRuns(_ fragments: inout [Fragment], words: [TranscriptWord], strokes: [Stroke],
                                        hasText: [Bool]) {
        var assignments = Array(repeating: 0, count: strokes.count)
        for fragment in fragments {
            guard let owner = fragment.owner else { continue }
            for mark in owner...(fragment.sharedThrough ?? owner) { assignments[mark] += 1 }
        }

        func isSilent(from start: Double, to end: Double) -> Bool {
            !words.contains { $0.start < end && $0.end > start }
        }

        func canShare(_ first: Int, _ second: Int) -> Bool {
            let before = strokes[first], after = strokes[second]
            let gap = after.downTime - penUp(before)
            return before.downTime < after.downTime && gap >= 0 && gap <= quickMarkGap
                && isSilent(from: before.downTime, to: penUp(after))
        }

        for index in fragments.indices {
            let fragment = fragments[index]
            guard let owner = fragment.owner, assignments[owner] == 1, fragment.sharedThrough == nil,
                  fragment.isWholeClause, fragment.words.contains(where: { hasText[$0] }),
                  endsClause(words[fragment.words.upperBound - 1].text) else { continue }
            let firstWord = fragment.words.lowerBound
            if firstWord > 0, !endsClause(words[firstWord - 1].text),
               words[firstWord].start - words[firstWord - 1].end < thinkingPause { continue }

            var first = owner
            var last = owner
            let lead = fragment.interval.lowerBound - penUp(strokes[owner])
            let lag = strokes[owner].downTime - fragment.interval.upperBound
            if lead >= 0, lead <= quickMarkGap,
               isSilent(from: strokes[owner].downTime, to: fragment.interval.lowerBound) {
                while first > 0, assignments[first - 1] == 0, !strokes[first - 1].isDeleted,
                      canShare(first - 1, first) {
                    first -= 1
                }
            } else if lag >= 0, lag <= quickMarkGap,
                      isSilent(from: fragment.interval.upperBound, to: penUp(strokes[owner])) {
                while last + 1 < strokes.count, assignments[last + 1] == 0, !strokes[last + 1].isDeleted,
                      canShare(last, last + 1) {
                    last += 1
                }
            }
            guard first < last else { continue }
            fragments[index].owner = first
            fragments[index].sharedThrough = last
            for mark in first...last { assignments[mark] = 1 }
        }
    }

    private struct MatchScore: Comparable {
        var shared = 0
        var covered = 0
        var unchanged = 0
        var distance = 0.0

        static func < (lhs: MatchScore, rhs: MatchScore) -> Bool {
            (lhs.shared, lhs.covered, lhs.unchanged, -lhs.distance)
                < (rhs.shared, rhs.covered, rhs.unchanged, -rhs.distance)
        }
    }

    private static func repair(_ fragments: [Fragment], strokes: [Stroke],
                               hasText: [Bool]) -> [Fragment] {
        let whole = fragments.indices.filter { index in
            let fragment = fragments[index]
            return !fragment.reserved && fragment.words.contains(where: { hasText[$0] })
        }
        var covered: Set<Int> = []
        var followers: Set<Int> = []
        var sharedHosts: Set<Int> = []
        var last = -1
        var ordered = true
        for fragment in fragments {
            guard let owner = fragment.owner else { continue }
            ordered = ordered && owner >= last
            last = fragment.sharedThrough ?? owner
            if fragment.words.contains(where: { hasText[$0] }) { covered.formUnion(owner...last) }
            if last > owner {
                sharedHosts.insert(owner)
                followers.formUnion((owner + 1)...last)
            }
        }
        let eligible = strokes.indices.filter { mark in
            guard !strokes[mark].isDeleted, !followers.contains(mark) else { return false }
            return covered.contains(mark) || whole.contains {
                distance(from: strokes[mark], to: fragments[$0].interval) <= maximumDistance
            }
        }
        if ordered, eligible.allSatisfy(covered.contains) { return fragments }

        let anchors = match(whole, to: eligible, fragments: fragments, strokes: strokes, sharedHosts: sharedHosts)

        // Anchors divide the transcript into ordered ranges. Keep preferred owners when
        // they fit between anchors, and move only nearby fragments across a boundary.
        var nextAnchor = 0
        var repaired: [Fragment] = []
        var lowerOwner = -1
        for index in fragments.indices {
            var fragment = fragments[index]
            if nextAnchor < anchors.count, anchors[nextAnchor].fragment == index {
                let mark = anchors[nextAnchor].mark
                if fragment.owner != mark { fragment.sharedThrough = nil }
                fragment.owner = mark
                repaired.append(fragment)
                lowerOwner = fragment.sharedThrough ?? mark
                nextAnchor += 1
            } else if let owner = fragment.owner {
                let upperOwner = nextAnchor < anchors.count ? anchors[nextAnchor].mark : strokes.count - 1
                let between = min(max(owner, lowerOwner), upperOwner)
                if between != owner {
                    fragment.owner = !strokes[between].isDeleted && !sharedHosts.contains(between)
                        && !followers.contains(between) && distance(from: strokes[between], to: fragment.interval) <= maximumDistance
                        ? between : nil
                }
                if let owner = fragment.owner { lowerOwner = owner }
                repaired.append(fragment)
            }
        }
        return repaired
    }

    /// Find a maximum ordered matching. Each step skips a fragment, skips a mark, or
    /// matches both. Ties preserve initial owners, then favor proximity to speech.
    private static func match(_ units: [Int], to marks: [Int], fragments: [Fragment], strokes: [Stroke],
                              sharedHosts: Set<Int>) -> [(fragment: Int, mark: Int)] {
        enum Step { case skipMark, skipUnit, match }
        var steps = Array(repeating: Array(repeating: Step.skipMark, count: units.count + 1), count: marks.count + 1)
        var previous = Array(repeating: MatchScore(), count: units.count + 1)
        for (row, mark) in marks.enumerated() {
            var current = previous
            for (column, unit) in units.enumerated() {
                let j = column + 1
                if current[j - 1] > current[j] {
                    current[j] = current[j - 1]
                    steps[row + 1][j] = .skipUnit
                }

                let fragment = fragments[unit]
                let unchanged = fragment.owner == mark
                let shared = unchanged && fragment.sharedThrough != nil
                if sharedHosts.contains(mark), !shared { continue }
                guard unchanged || distance(from: strokes[mark], to: fragment.interval) <= maximumDistance else { continue }
                var score = previous[column]
                score.shared += shared ? 1 : 0
                score.covered += 1
                score.unchanged += unchanged ? 1 : 0
                score.distance += min(maximumDistance, distance(from: strokes[mark], to: fragment.interval))
                if score > current[j] {
                    current[j] = score
                    steps[row + 1][j] = .match
                }
            }
            previous = current
        }

        var row = marks.count
        var column = units.count
        var anchors: [(fragment: Int, mark: Int)] = []
        while row > 0, column > 0 {
            switch steps[row][column] {
            case .skipMark: row -= 1
            case .skipUnit: column -= 1
            case .match:
                anchors.append((units[column - 1], marks[row - 1]))
                row -= 1
                column -= 1
            }
        }
        return anchors.reversed()
    }

    private static func split(_ clause: ArraySlice<TranscriptWord>, among onsets: [Int],
                              strokes: [Stroke]) -> [(owner: Int, words: Range<Int>)] {
        var fragments: [(owner: Int, words: Range<Int>)] = []
        var lower = clause.startIndex
        for index in onsets {
            let upper = splitPoint(in: clause, at: strokes[index].downTime)
            guard upper > lower else { continue }
            fragments.append((index, lower..<upper))
            lower = upper
        }
        if lower < clause.endIndex, let last = onsets.last,
           let owner = onsets.first(where: { strokes[$0].downTime == strokes[last].downTime }) {
            if let previous = fragments.last, previous.owner == owner {
                fragments[fragments.count - 1].words = previous.words.lowerBound..<clause.endIndex
            } else {
                fragments.append((owner, lower..<clause.endIndex))
            }
        }
        return fragments
    }

    private static let wordStartTolerance = 0.075

    private static func splitPoint(in clause: ArraySlice<TranscriptWord>, at time: Double) -> Int {
        // A clause speaker owns at least its first word.
        (clause.lastIndex { hasSpoken($0, by: time) } ?? clause.startIndex) + 1
    }

    private static func hasSpoken(_ word: TranscriptWord, by time: Double) -> Bool {
        word.start <= time && (time >= word.end || time >= word.start + wordStartTolerance)
    }

    private static func penUp(_ stroke: Stroke) -> Double {
        let down = stroke.downTime
        guard let up = stroke.upTime, up.isFinite else { return down }
        return max(down, up)
    }

    private static func distance(from stroke: Stroke, to interval: ClosedRange<Double>) -> Double {
        max(0, stroke.downTime - interval.upperBound, interval.lowerBound - penUp(stroke))
    }

    private static func proximity(of stroke: Stroke, to clause: ClosedRange<Double>) -> (Double, Double, Int, Double) {
        let down = stroke.downTime, up = penUp(stroke)
        let start = clause.lowerBound, end = clause.upperBound
        let overlap = max(0, min(up, end) - max(down, start))
        return (distance(from: stroke, to: clause), -overlap, down >= start ? 0 : 1, max(down - end, start - down))
    }

    private static func clauses(in words: [TranscriptWord]) -> [ArraySlice<TranscriptWord>] {
        var clauses: [ArraySlice<TranscriptWord>] = []
        var start = words.startIndex
        var end = words[start].end
        for index in words.indices.dropLast() {
            end = max(end, words[index].end)
            let next = words[index + 1]
            guard next.start - end >= clausePause || endsClause(words[index].text) else { continue }
            clauses.append(words[start...index])
            start = index + 1
            end = next.end
        }
        clauses.append(words[start...])
        return clauses
    }

    private static func endsClause(_ word: String) -> Bool {
        let text = word.reversed().drop(while: { "\"'”’»)]}".contains($0) })
        guard let punctuation = text.first else { return false }
        if ";:?!；：。？！".contains(punctuation) { return true }
        guard punctuation == "." else { return false }
        let stem = String(text.dropFirst().reversed()).lowercased()
        return !stem.contains(".") && stem.count > 1 && stem != "etc"
    }

    /// Index of the slot where a mark at `time` is inserted. See `place`.
    private static func slot(for time: Double, in words: [TranscriptWord], toleratesWordStarts: Bool) -> Int {
        guard time.isFinite else { return words.count }
        let started = words.prefix { $0.start <= time }
        guard toleratesWordStarts else { return started.count }
        return started.lastIndex { hasSpoken($0, by: time) }.map { $0 + 1 } ?? 0
    }
}
