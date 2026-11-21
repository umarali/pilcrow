import Foundation
import PilcrowCore

/// Local timing evidence. Recognition and published transcript state are owned by VoiceSegment.
struct VoiceRecording: Codable, Sendable {
    struct Result: Codable, Sendable {
        var start: Double
        var end: Double
        var isFinal: Bool
        var finalWords: [TranscriptWord]?
    }

    struct Results: Sendable {
        private(set) var events: [Result] = []
        private(set) var truncated = false
        private var bytes = 0

        mutating func append(_ event: Result) {
            guard !truncated else { return }
            // Keep room for retained words, mark timing and the outer JSON.
            guard let data = try? JSONEncoder().encode(event), bytes + data.count + 1 <= 480_000 else {
                truncated = true
                return
            }
            bytes += data.count + 1
            events.append(event)
        }
    }

    struct Mark: Codable, Sendable {
        var id: MarkID
        var downTime: Double
        var upTime: Double?
        var absorbedInto: MarkID?
        var isDeleted: Bool
    }

    let version: Int
    let finalWords: [TranscriptWord]
    let results: [Result]
    let marks: [Mark]
    let resultsTruncated: Bool

    init(session: Session, results: Results) {
        version = 1
        finalWords = session.words.filter(\.isFinal)
        self.results = results.events
        resultsTruncated = results.truncated
        marks = session.strokes.map {
            Mark(id: $0.id, downTime: $0.downTime, upTime: $0.upTime, absorbedInto: $0.absorbedInto, isDeleted: $0.isDeleted)
        }
    }
}
