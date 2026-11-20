import Foundation

/// Turns aligned tokens into one line of transcript text.
public enum TranscriptRenderer {
    /// Joins words with single spaces. A mark renders as `[n]`, with one space before it when something precedes it.
    /// Word text is split on Character whitespace; empty words are omitted.
    public static func render(tokens: [TranscriptToken]) -> String {
        tokens.compactMap { token in
            switch token {
            case .word(let text):
                let words = text.split(whereSeparator: \.isWhitespace)
                return words.isEmpty ? nil : words.joined(separator: " ")
            case .mark(let id):
                return "[\(id.rawValue)]"
            }
        }.joined(separator: " ")
    }
}
