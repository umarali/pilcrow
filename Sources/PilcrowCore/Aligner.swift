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
        let sortedWords = words.enumerated()
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

        let sortedStrokes = strokes
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.downTime.isFinite != rhs.downTime.isFinite { return lhs.downTime.isFinite }
                if !lhs.downTime.isFinite { return lhs.id < rhs.id }
                if lhs.downTime != rhs.downTime {
                    return lhs.downTime < rhs.downTime
                }
                return lhs.id < rhs.id
            }

        guard !sortedWords.isEmpty else {
            return sortedStrokes.map { .mark($0.id) }
        }

        // Slot 0 is before the first word. Slot `i + 1` is immediately after word `i`.
        var marksAtSlot = Array(repeating: [TranscriptToken](), count: sortedWords.count + 1)
        for stroke in sortedStrokes {
            let slot = slot(for: stroke.downTime, in: sortedWords)
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

    /// Index of the slot where a mark at `time` is inserted. See `place`.
    private static func slot(for time: Double, in words: [TranscriptWord]) -> Int {
        guard time.isFinite else { return words.count }
        return words.prefix { $0.start <= time }.count
    }
}
