import Foundation

/// Strokes, frames, and words for one annotation. Mark numbers only increase.
public struct Session: Sendable, Equatable, Codable {
    public enum ValidationError: Error, Equatable {
        case duplicateStrokeID, duplicateFrameID, unknownFrameID, exhaustedMarkIDs
        case nonFiniteTime, nonFinitePoint, invalidFrameBounds, invalidFrameCapture, frameGeometryMismatch, invalidFrameTransition, sealedSession
    }
    public var id: UUID
    public private(set) var strokes: [Stroke]
    public private(set) var frames: [Frame]
    private var storedWords: [TranscriptWord]
    /// Recognition updates after sealing are ignored.
    public var words: [TranscriptWord] {
        get { storedWords }
        set { if !isSealed { storedWords = newValue } }
    }
    public private(set) var isSealed = false
    /// Raw value of the next `MarkID`. Delete and undo do not decrease it.
    public private(set) var nextMarkNumber: Int

    /// A fresh empty session cannot fail validation.
    public init() {
        id = UUID()
        strokes = []
        frames = []
        storedWords = []
        nextMarkNumber = 1
    }

    /// `nextMarkNumber` defaults to one past the highest existing id, or `1` when there are no strokes.
    public init(
        id: UUID = UUID(),
        strokes: [Stroke] = [],
        frames: [Frame] = [],
        words: [TranscriptWord] = [],
        nextMarkNumber: Int? = nil
    ) throws {
        guard Set(strokes.map(\.id)).count == strokes.count else { throw ValidationError.duplicateStrokeID }
        guard Set(frames.map(\.id)).count == frames.count else { throw ValidationError.duplicateFrameID }
        guard strokes.allSatisfy({ stroke in frames.contains(where: { $0.id == stroke.frameID }) }) else { throw ValidationError.unknownFrameID }
        try frames.forEach(Self.validateCapture)
        let highest = strokes.map(\.id.rawValue).max() ?? 0
        guard highest < Int.max else { throw ValidationError.exhaustedMarkIDs }
        self.id = id
        self.strokes = strokes
        self.frames = frames
        self.storedWords = words
        self.nextMarkNumber = max(nextMarkNumber ?? 1, highest + 1, 1)
    }

    /// Strokes that still appear in the transcript and on exported images, in session order.
    public var liveMarks: [Stroke] {
        strokes.filter { !$0.isDeleted }
    }

    /// Frames with live marks, ordered by their first stored stroke, including deleted strokes.
    public var framesWithMarks: [Frame] {
        let used = Set(liveMarks.map(\.frameID))
        var seen = Set<Frame.ID>()
        let byID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        return strokes.compactMap { stroke in
            guard used.contains(stroke.frameID), seen.insert(stroke.frameID).inserted else { return nil }
            return byID[stroke.frameID]
        }
    }

    /// Registers a pending or complete frame. Duplicate IDs throw without mutation.
    public mutating func addFrame(_ frame: Frame) throws {
        guard !isSealed else { throw ValidationError.sealedSession }
        guard !frames.contains(where: { $0.id == frame.id }) else { throw ValidationError.duplicateFrameID }
        try Self.validateCapture(frame)
        frames.append(frame)
    }

    /// Replaces capture metadata for an existing ID; the coordinate space cannot change.
    public mutating func updateFrame(_ frame: Frame) throws {
        guard !isSealed else { throw ValidationError.sealedSession }
        guard let index = frames.firstIndex(where: { $0.id == frame.id }) else { throw ValidationError.unknownFrameID }
        guard frames[index].displayID == frame.displayID,
              frames[index].boundsInPoints == frame.boundsInPoints else { throw ValidationError.frameGeometryMismatch }
        try Self.validateCapture(frame)
        guard !frames[index].isComplete || frame.isComplete else { throw ValidationError.invalidFrameTransition }
        frames[index] = frame
    }

    public mutating func completeFrame(id: Frame.ID, pixelSize: Size, capturedAt: Double) throws {
        guard !isSealed else { throw ValidationError.sealedSession }
        guard var frame = frames.first(where: { $0.id == id }) else { throw ValidationError.unknownFrameID }
        frame.pixelSize = pixelSize
        frame.capturedAt = capturedAt
        frame.captureFailed = false
        try updateFrame(frame)
    }

    /// Records a failed pending capture. Complete frames cannot regress. A later completion may retry it.
    public mutating func failFrame(id: Frame.ID) throws {
        guard !isSealed else { throw ValidationError.sealedSession }
        guard var frame = frames.first(where: { $0.id == id }) else { throw ValidationError.unknownFrameID }
        frame.captureFailed = true
        try updateFrame(frame)
    }

    private static func validateCapture(_ frame: Frame) throws {
        let bounds = frame.boundsInPoints
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw ValidationError.invalidFrameBounds
        }
        guard !frame.captureFailed || (frame.pixelSize == nil && frame.capturedAt == nil) else {
            throw ValidationError.invalidFrameTransition
        }
        guard (frame.pixelSize == nil && frame.capturedAt == nil) || frame.isComplete else {
            throw ValidationError.invalidFrameCapture
        }
        if let pixels = frame.pixelSize {
            guard pixels.width.rounded() == pixels.width, pixels.height.rounded() == pixels.height else {
                throw ValidationError.invalidFrameCapture
            }
            // Log ratios avoid overflowing extreme but finite aspect ratios.
            let relativeAspect = log(pixels.width) - log(pixels.height) - log(bounds.width) + log(bounds.height)
            guard relativeAspect >= log(0.99) - 1e-12, relativeAspect <= log(1.01) + 1e-12 else {
                throw ValidationError.frameGeometryMismatch
            }
        }
    }

    /// Starts a stroke on a registered frame, which may still be pending.
    public mutating func beginStroke(at time: Double, frame: Frame.ID, firstPoint: NormalizedPoint) throws -> MarkID {
        guard !isSealed else { throw ValidationError.sealedSession }
        guard time.isFinite else { throw ValidationError.nonFiniteTime }
        guard frames.contains(where: { $0.id == frame }) else { throw ValidationError.unknownFrameID }
        guard nextMarkNumber < Int.max else { throw ValidationError.exhaustedMarkIDs }
        guard firstPoint.x.isFinite, firstPoint.y.isFinite else { throw ValidationError.nonFinitePoint }
        let id = MarkID(rawValue: nextMarkNumber)
        nextMarkNumber += 1
        strokes.append(
            Stroke(
                id: id,
                frameID: frame,
                downTime: time,
                upTime: nil,
                points: [firstPoint],
                badgeAnchor: firstPoint,
                isDeleted: false
            )
        )
        return id
    }

    /// Adds a finite sample. Non-finite points and missing, ended, or deleted strokes are no-ops. Later points do not move `badgeAnchor`.
    public mutating func append(point: NormalizedPoint, to id: MarkID) {
        guard !isSealed else { return }
        guard point.x.isFinite, point.y.isFinite, let index = strokes.firstIndex(where: { $0.id == id }), !strokes[index].isDeleted, strokes[index].upTime == nil else { return }
        strokes[index].points.append(point)
    }

    /// Records a finite pen-lift time. Missing, deleted, ended, non-finite, or earlier-than-down events do nothing.
    public mutating func endStroke(id: MarkID, at time: Double) {
        guard !isSealed else { return }
        guard time.isFinite, let index = strokes.firstIndex(where: { $0.id == id }), !strokes[index].isDeleted, strokes[index].upTime == nil, time >= strokes[index].downTime else { return }
        strokes[index].upTime = time
    }

    /// Hides a mark from the transcript and from image lists. The id stays reserved.
    public mutating func deleteMark(id: MarkID) {
        guard !isSealed else { return }
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return }
        strokes[index].isDeleted = true
    }

    /// Finalizes capture outcomes and freezes frame, stroke and transcript mutations. Idempotent.
    public mutating func seal() {
        guard !isSealed else { return }
        for index in frames.indices where !frames[index].isComplete {
            frames[index].captureFailed = true
        }
        isSealed = true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case strokes
        case frames
        case words
        case nextMarkNumber
        case isSealed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isSealed, forKey: .isSealed)
        try container.encode(id, forKey: .id)
        try container.encode(strokes, forKey: .strokes)
        try container.encode(frames, forKey: .frames)
        try container.encode(words, forKey: .words)
        try container.encode(nextMarkNumber, forKey: .nextMarkNumber)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(UUID.self, forKey: .id)
        let decodedStrokes = try container.decode([Stroke].self, forKey: .strokes)
        let decodedFrames = try container.decode([Frame].self, forKey: .frames)
        let decodedWords = try container.decode([TranscriptWord].self, forKey: .words)
        let storedCounter = try container.decodeIfPresent(Int.self, forKey: .nextMarkNumber)
        // Deleted strokes remain stored, so their ids must also advance a stale counter.
        try self.init(id: decodedID, strokes: decodedStrokes, frames: decodedFrames,
                      words: decodedWords, nextMarkNumber: storedCounter)
        if try container.decodeIfPresent(Bool.self, forKey: .isSealed) ?? false { seal() }
    }
}
