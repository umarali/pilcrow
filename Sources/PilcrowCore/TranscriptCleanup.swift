import Foundation

/// Cleans fix-line text using the quote and sentence context of the whole paragraph.
struct TranscriptCleanup {
    private static let fillers: Set<String> = ["um", "uh", "erm", "hmm"]
    private static let ellipsis = #"(?:\.{3,}|…+)(?=["'”’»\)\]\}]*$)"#
    private static let terminals = ".?!;:。？！；："
    private static let closingPunctuation = "\"'”’»」』)]}"
    private static let openingQuotes: [Character: Character] = ["“": "”", "‘": "’", "«": "»", "「": "」", "『": "』"]
    private static let repeatGap = 0.15
    private static let maxRepeatWords = 4
    private static let legitimateDoubles: Set<String> = ["that", "had", "plus", "dot", "no", "very", "more"]
    private static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "trillion", "half", "quarter",
    ]
    private static let units: Set<String> = [
        "percent",
        "px", "pixel", "pixels", "pt", "point", "points", "em", "rem", "vw", "vh",
        "mm", "cm", "m", "km", "in", "inch", "inches", "ft", "feet", "yd", "mi",
        "s", "ms", "sec", "secs", "second", "seconds", "min", "mins", "minute", "minutes",
        "hr", "hrs", "hour", "hours", "g", "kg", "lb", "lbs", "oz", "ml", "l", "hz", "khz", "mhz", "ghz",
    ]

    let words: [TranscriptWord]
    private let quoted: [Bool]
    let cleanedText: [String]
    private let unitBesideNumber: Set<Int>

    init(sortedWords: [TranscriptWord], languageCode: String?) {
        words = sortedWords.flatMap { word in
            word.text.split(whereSeparator: \.isWhitespace).map { token in
                var word = word
                word.text = String(token)
                return word
            }
        }
        var quotes: [Character] = []
        let quoted = words.map { Self.readQuotes(in: $0.text, open: &quotes) }
        self.quoted = quoted
        let removesFillers = languageCode?.lowercased() == "en"
        var atSentenceStart = true
        cleanedText = zip(words, quoted).map { word, quoted in
            let startsSentence = atSentenceStart
            if word.text.contains(where: { $0.isLetter || $0.isNumber }) {
                atSentenceStart = false
            }
            if Self.hasTerminal(word.text) { atSentenceStart = true }
            guard !quoted else { return word.text }
            let text = word.text.replacingOccurrences(of: Self.ellipsis, with: "", options: .regularExpression)
            let isName = !startsSentence && text.first(where: \.isLetter)?.isUppercase == true
            return removesFillers && !isName && Self.fillers.contains(Self.key(text)) ? "" : text
        }
        unitBesideNumber = Self.unitsBesideNumbers(in: words)
    }

    func text(for indices: [Int]) -> String {
        var retained: [TranscriptWord] = []
        var repeatKeys: [String?] = []
        var segmentStart = 0
        var previousIndex: Int?
        for index in indices {
            if let previousIndex, previousIndex + 1 != index || Self.hasTerminal(words[previousIndex].text) {
                segmentStart = retained.count
            }
            previousIndex = index

            var word = words[index]
            word.text = cleanedText[index]
            guard !word.text.isEmpty else { continue }
            retained.append(word)
            repeatKeys.append(quoted[index] || unitBesideNumber.contains(index) ? nil : Self.repeatKey(word.text))
            let maxLength = min(Self.maxRepeatWords, (retained.count - segmentStart) / 2)
            guard maxLength > 0,
                  let length = (1...maxLength).reversed().first(where: {
                      Self.repeats($0, in: retained, keys: repeatKeys, segmentStart: segmentStart)
                  }) else { continue }
            let last = retained.count - length - 1
            let suffix = word.text.reversed().prefix { ",.;:!?".contains($0) }
            if retained[last].text.last == "," { retained[last].text.removeLast() }
            if retained[last].text.last?.isLetter == true { retained[last].text += String(suffix.reversed()) }
            // Keep the latest end for comparison with a third immediate copy.
            retained[last].end = word.end
            retained.removeLast(length)
            repeatKeys.removeLast(length)
        }
        return retained.map(\.text).joined(separator: " ")
    }

    private static func readQuotes(in text: String, open: inout [Character]) -> Bool {
        let characters = Array(text)
        var quoted = !open.isEmpty
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if (character == "'" || character == "’"), previous?.isLetter == true, next?.isLetter == true {
                continue // Apostrophe within a word.
            }
            if character == open.last {
                open.removeLast()
            } else if let closing = openingQuotes[character] {
                open.append(closing)
                quoted = true
            } else if (character == "\"" || character == "'"),
                      previous?.isLetter != true, previous?.isNumber != true {
                open.append(character)
                quoted = true
            }
        }
        return quoted
    }

    private static func hasTerminal(_ text: String) -> Bool {
        let end = text.reversed().drop(while: { closingPunctuation.contains($0) })
        return end.first.map { terminals.contains($0) || $0 == "…" } ?? false
    }

    private static func isNumber(_ key: String) -> Bool {
        key.contains(where: \.isNumber) || key.split(separator: "-").contains { numberWords.contains(String($0)) }
    }

    private static func unitsBesideNumbers(in words: [TranscriptWord]) -> Set<Int> {
        let keys = words.map { key($0.text) }
        var protected: Set<Int> = []
        var start = 0
        while start < keys.count {
            let unit = keys[start]
            guard units.contains(unit) else {
                start += 1
                continue
            }
            // Treat a run of identical unit tokens next to a number as a literal.
            var end = start + 1
            while end < keys.count, keys[end] == unit, !hasTerminal(words[end - 1].text) { end += 1 }
            let hasNumberBefore = start > 0 && !hasTerminal(words[start - 1].text) && isNumber(keys[start - 1])
            let hasNumberAfter = end < keys.count && !hasTerminal(words[end - 1].text) && isNumber(keys[end])
            if hasNumberBefore || hasNumberAfter { protected.formUnion(start..<end) }
            start = end
        }
        return protected
    }

    private static func key(_ text: String) -> String {
        let start = text.drop(while: \.isPunctuation)
        return String(start.reversed().drop(while: \.isPunctuation).reversed()).lowercased()
    }

    private static func repeatKey(_ text: String) -> String? {
        let key = key(text)
        guard key.contains(where: \.isLetter), !isNumber(key) else { return nil }
        if key.count == 1,
           key.unicodeScalars.contains(where: { $0.properties.isIdeographic })
            || key.range(of: #"[\p{scx=Hira}\p{scx=Kana}\p{scx=Hang}]"#, options: .regularExpression) != nil {
            return nil
        }
        return key
    }

    private static func repeats(_ length: Int, in words: [TranscriptWord], keys: [String?], segmentStart: Int) -> Bool {
        let start = words.count - 2 * length
        let middle = start + length
        if length == 1, let key = keys[start], legitimateDoubles.contains(key) {
            // Keep the first double. A third immediate copy collapses into the second.
            guard start > segmentStart, keys[start - 1] == key,
                  words[start].start < words[start - 1].end + repeatGap else { return false }
        }
        for index in start..<middle {
            guard let original = keys[index], original == keys[index + length] else { return false }
        }
        return (start + 1..<words.count).allSatisfy { index in
            words[index].start < words[index - 1].end + repeatGap
        }
    }
}
