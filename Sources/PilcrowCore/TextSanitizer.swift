import Foundation

enum TextSanitizer {
    /// Replaces each run of newline characters with one space.
    static func singleLine(_ value: String) -> String {
        var result = ""
        var inNewlineRun = false

        for character in value {
            if character.isNewline {
                if !inNewlineRun {
                    result.append(" ")
                    inNewlineRun = true
                }
            } else {
                result.append(character)
                inNewlineRun = false
            }
        }

        return result
    }
    /// Keeps quoted list prose on one line; escapes only backslashes and double quotes.
    static func markdownQuoted(_ value: String) -> String {
        let escaped = Set("\\\"".map { $0 })
        return singleLine(value).map { escaped.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    /// Escapes block openers on every transcript line, including indented ones.
    static func markdownTranscript(_ value: String) -> String {
        value.components(separatedBy: "\n").map { line in
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            let prose = line.dropFirst(indentation.count)
            guard let escaped = escapedBlockOpener(prose) else { return line }
            return String(indentation) + escaped
        }.joined(separator: "\n")
    }

    private static func escapedBlockOpener(_ prose: Substring) -> String? {
        guard let first = prose.first else { return nil }
        let rest = prose.dropFirst()

        if first == ">" { return "\\" + prose }

        if first == "<", let next = rest.first {
            return next.isLetter || "/!?".contains(next) ? "\\" + prose : nil
        }

        if first == "#" {
            let count = prose.prefix { $0 == "#" }.count
            guard count <= 6 && (count == prose.count || prose.dropFirst(count).first?.isWhitespace == true) else { return nil }
            return "\\" + prose
        }

        if first == "`" || first == "~" || first == "_" {
            let count = prose.prefix { $0 == first }.count
            return count >= 3 ? "\\" + prose : nil
        }

        if first == "-" || first == "+" || first == "*" {
            let count = prose.prefix { $0 == first }.count
            return count >= 3 || rest.first?.isWhitespace == true ? "\\" + prose : nil
        }

        if first.isNumber {
            let digits = prose.prefix(while: { $0.isNumber })
            guard let delimiter = prose.dropFirst(digits.count).first,
                  delimiter == "." || delimiter == ")" else { return nil }
            let afterDelimiter = prose.dropFirst(digits.count + 1)
            guard afterDelimiter.isEmpty || afterDelimiter.first?.isWhitespace == true else { return nil }
            return String(digits) + "\\" + String(delimiter) + String(afterDelimiter)
        }

        return nil
    }
}
