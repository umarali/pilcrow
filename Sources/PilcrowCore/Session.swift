import Foundation

/// Strokes, frames, and words for one annotation.
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
    public private(set) var transcriptLanguageCode: String?
    public private(set) var isSealed = false
    private var nextUnallocatedMarkNumber: Int
    // The app draws one stroke at a time. Core can also receive overlapping pen-downs.
    private var releasedMarkNumbers: Set<Int> = []
    private enum HeadUndoTime: Sendable, Equatable, Codable {
        case session(Double)
        case uptime(Double)
    }
    private static let headWindow = 0.0...3.0
    private var headUndoTimes: [Int: HeadUndoTime] = [:]
    /// The next visible number. Only absorption releases a provisional number.
    public var nextMarkNumber: Int { releasedMarkNumbers.min() ?? nextUnallocatedMarkNumber }

    /// A fresh empty session cannot fail validation.
    public init() {
        id = UUID()
        strokes = []
        frames = []
        storedWords = []
        nextUnallocatedMarkNumber = 1
    }

    /// `nextMarkNumber` defaults to one past the highest existing id, or `1` when there are no strokes.
    public init(
        id: UUID = UUID(),
        strokes: [Stroke] = [],
        frames: [Frame] = [],
        words: [TranscriptWord] = [],
        nextMarkNumber: Int? = nil,
        transcriptLanguageCode: String? = nil
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
        self.transcriptLanguageCode = transcriptLanguageCode
        nextUnallocatedMarkNumber = max(nextMarkNumber ?? 1, highest + 1, 1)
    }

    /// Updates recognition and its source language together before sealing.
    public mutating func setTranscript(words: [TranscriptWord], languageCode: String?) {
        guard !isSealed else { return }
        storedWords = words
        transcriptLanguageCode = languageCode
    }

    /// Strokes that still appear in the transcript and on exported images, in session order.
    public var liveMarks: [Stroke] {
        strokes.filter { !$0.isDeleted && $0.absorbedInto == nil }
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
        let number = nextMarkNumber
        let id = MarkID(rawValue: number)
        if releasedMarkNumbers.remove(number) == nil { nextUnallocatedMarkNumber += 1 }
        if !headUndoTimes.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            // Callers without a session timestamp can still time undo on the
            // monotonic clock. The next pen-down anchors it to the session clock.
            headUndoTimes = headUndoTimes.compactMapValues { undo in
                guard case .uptime(let uptime) = undo else { return undo }
                let elapsed = now - uptime
                return Self.headWindow.contains(elapsed) ? .session(time - elapsed) : nil
            }
        }
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

    /// Records pen-lift and classifies the finished stroke in frame points.
    /// Missing, deleted, ended, non-finite, or earlier-than-down events do nothing.
    public mutating func endStroke(id: MarkID, at time: Double) {
        guard !isSealed else { return }
        guard time.isFinite, let index = strokes.firstIndex(where: { $0.id == id }), !strokes[index].isDeleted, strokes[index].upTime == nil, time >= strokes[index].downTime else { return }
        let stroke = strokes[index]
        guard let frame = frames.first(where: { $0.id == stroke.frameID }) else { return }
        let previous = strokes[..<index].lastIndex { !$0.isDeleted }
        let existing = strokes[..<index].filter { $0.frameID == frame.id }
        let result = ShapeRecognizer.classify(points: stroke.points, frameSize: frame.boundsInPoints,
                                              existingMarks: existing)
        strokes[index].shape = result.shape
        strokes[index].shaftPointCount = result.shaftPointCount
        strokes[index].upTime = time
        if let previous, absorbHead(at: index, after: previous, frame: frame, existing: existing) { return }

        switch result.shape {
        case .pin, .area:
            let target = strokes[index]
            let headed = Set(existing.lazy.filter { !$0.isDeleted }.compactMap(\.absorbedInto))
            for earlier in strokes.indices.prefix(index) where !strokes[earlier].isDeleted && strokes[earlier].absorbedInto == nil {
                // Links to undone marks count as free ends, so a redrawn target can take them over.
                var shaft = strokes[earlier]
                if case .arrow(let from, let to) = shaft.shape {
                    func live(_ id: MarkID?) -> MarkID? {
                        id.flatMap { link in strokes.contains { $0.id == link && !$0.isDeleted } ? link : nil }
                    }
                    shaft.shape = .arrow(from: live(from), to: live(to))
                }
                if let linked = ShapeRecognizer.relink(shaft, to: target, frameSize: frame.boundsInPoints,
                                                       hasSeparateHead: headed.contains(shaft.id)) {
                    strokes[earlier].shape = linked
                }
            }
        case .arrow, .mark:
            break
        }
    }

    private mutating func absorbHead(at index: Int, after previous: Int, frame: Frame, existing: [Stroke]) -> Bool {
        func follows(_ successor: Int, _ predecessor: Int) -> Bool {
            let start = strokes[successor].downTime
            let prior = strokes[predecessor]
            if let penUp = prior.upTime, Self.headWindow.contains(start - penUp) { return true }
            if case .session(let undoTime) = headUndoTimes[prior.id.rawValue] {
                return Self.headWindow.contains(start - undoTime)
            }
            return false
        }
        guard follows(index, previous) else { return false }
        if let shaft = strokes[previous].absorbedInto {
            // An orphaned head (its shaft was undone) must not absorb new ink.
            guard let parent = strokes[..<previous].firstIndex(where: { $0.id == shaft && !$0.isDeleted })
            else { return false }
            return attachHead(at: index, to: parent, pairedWith: previous, continuingHead: true,
                              frame: frame, existing: existing)
                || attachHead(at: index, to: parent, continuingHead: true, frame: frame, existing: existing)
        }
        if let parent = strokes[..<previous].lastIndex(where: { !$0.isDeleted }),
           strokes[parent].absorbedInto == nil, follows(previous, parent),
           attachHead(at: index, to: parent, pairedWith: previous, frame: frame, existing: existing) {
            return true
        }
        return attachHead(at: index, to: previous, frame: frame, existing: existing)
    }

    private mutating func attachHead(at index: Int, to parent: Int, pairedWith other: Int? = nil,
                                     continuingHead: Bool = false, frame: Frame, existing: [Stroke]) -> Bool {
        let shaft = strokes[parent]
        guard let arrow = ShapeRecognizer.absorbHead(strokes[index], into: shaft,
                                                     pairedWith: other.map { strokes[$0] },
                                                     allowSingleBarb: !continuingHead,
                                                     allowOppositeEnd: !continuingHead,
                                                     frameSize: frame.boundsInPoints, existingMarks: existing)
        else { return false }
        let first = continuingHead ? index : other ?? index
        if shaft.shape != arrow.shape || (shaft.shaftReversed == true) != arrow.reversed {
            strokes[first].shapeBeforeAbsorption = shaft.shape
            strokes[first].shaftReversedBeforeAbsorption = shaft.shaftReversed
            strokes[parent].shape = arrow.shape
            strokes[parent].shaftReversed = arrow.reversed ? true : nil
        }
        if let other, !continuingHead {
            strokes[other].absorbedInto = shaft.id
            hideAbsorbedStroke(at: other)
        }
        strokes[index].absorbedInto = shaft.id
        hideAbsorbedStroke(at: index)
        headUndoTimes.removeValue(forKey: shaft.id.rawValue)
        return true
    }

    private mutating func hideAbsorbedStroke(at index: Int) {
        let number = strokes[index].id.rawValue
        // Negative IDs are outside the pen-down allocator. Check decoded strokes too.
        let used = Set(strokes.lazy.map(\.id))
        var hidden = MarkID(rawValue: -1 - index)
        while used.contains(hidden) { hidden = MarkID(rawValue: hidden.rawValue - 1) }
        strokes[index].id = hidden
        guard number > 0 else { return }
        if number == nextUnallocatedMarkNumber - 1 {
            nextUnallocatedMarkNumber = number
            while releasedMarkNumbers.remove(nextUnallocatedMarkNumber - 1) != nil {
                nextUnallocatedMarkNumber -= 1
            }
        } else {
            releasedMarkNumbers.insert(number)
        }
    }

    /// Reverts the most recent drawing gesture in this pass.
    public mutating func undoLatestMark(in frameIDs: Set<Frame.ID>) {
        undoLatestMark(in: frameIDs, time: .uptime(ProcessInfo.processInfo.systemUptime))
    }

    /// Reverts a gesture at an explicit time on the session clock.
    public mutating func undoLatestMark(in frameIDs: Set<Frame.ID>, at time: Double) {
        guard time.isFinite else { return }
        undoLatestMark(in: frameIDs, time: .session(time))
    }

    private mutating func undoLatestMark(in frameIDs: Set<Frame.ID>, time: HeadUndoTime) {
        guard !isSealed else { return }
        let liveIDs = Set(liveMarks.map(\.id))
        guard let index = strokes.lastIndex(where: { stroke in
            guard !stroke.isDeleted, frameIDs.contains(stroke.frameID) else { return false }
            return stroke.absorbedInto.map(liveIDs.contains) ?? true
        }) else { return }
        let stroke = strokes[index]
        guard let shaft = stroke.absorbedInto, let parent = strokes.firstIndex(where: { $0.id == shaft }) else {
            deleteMark(id: stroke.id)
            return
        }
        let group = strokes.indices.filter { !strokes[$0].isDeleted && strokes[$0].absorbedInto == shaft }
        if let firstChange = group.first(where: { strokes[$0].shapeBeforeAbsorption != nil }),
           let priorShape = strokes[firstChange].shapeBeforeAbsorption,
           strokes[parent].shape != priorShape ||
                (strokes[parent].shaftReversed == true) != (strokes[firstChange].shaftReversedBeforeAbsorption == true) {
            strokes[parent].shape = priorShape
            strokes[parent].shaftReversed = strokes[firstChange].shaftReversedBeforeAbsorption
            headUndoTimes[shaft.rawValue] = time
        } else {
            deleteMark(id: shaft)
        }
        for head in group { strokes[head].isDeleted = true }
    }

    /// Hides a mark from the transcript and from image lists. The id stays reserved.
    public mutating func deleteMark(id: MarkID) {
        guard !isSealed else { return }
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return }
        strokes[index].isDeleted = true
        headUndoTimes.removeValue(forKey: id.rawValue)
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
        case transcriptLanguageCode
        case nextMarkNumber
        case releasedMarkNumbers
        case headUndoTimes
        case isSealed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isSealed, forKey: .isSealed)
        try container.encode(id, forKey: .id)
        try container.encode(strokes, forKey: .strokes)
        try container.encode(frames, forKey: .frames)
        try container.encode(words, forKey: .words)
        try container.encodeIfPresent(transcriptLanguageCode, forKey: .transcriptLanguageCode)
        try container.encode(nextUnallocatedMarkNumber, forKey: .nextMarkNumber)
        if !releasedMarkNumbers.isEmpty {
            try container.encode(releasedMarkNumbers.sorted(), forKey: .releasedMarkNumbers)
        }
        if !headUndoTimes.isEmpty {
            try container.encode(headUndoTimes, forKey: .headUndoTimes)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(UUID.self, forKey: .id)
        let decodedStrokes = try container.decode([Stroke].self, forKey: .strokes)
        let decodedFrames = try container.decode([Frame].self, forKey: .frames)
        let decodedWords = try container.decode([TranscriptWord].self, forKey: .words)
        let languageCode = try container.decodeIfPresent(String.self, forKey: .transcriptLanguageCode)
        let storedCounter = try container.decodeIfPresent(Int.self, forKey: .nextMarkNumber)
        // Deleted strokes remain stored, so their ids must also advance a stale counter.
        try self.init(id: decodedID, strokes: decodedStrokes, frames: decodedFrames,
                      words: decodedWords, nextMarkNumber: storedCounter, transcriptLanguageCode: languageCode)
        if let released = try container.decodeIfPresent([Int].self, forKey: .releasedMarkNumbers) {
            let used = Set(decodedStrokes.map { $0.id.rawValue })
            releasedMarkNumbers = Set(released.filter { $0 > 0 && $0 < nextUnallocatedMarkNumber && !used.contains($0) })
        }
        headUndoTimes = try container.decodeIfPresent([Int: HeadUndoTime].self, forKey: .headUndoTimes) ?? [:]
        if try container.decodeIfPresent(Bool.self, forKey: .isSealed) ?? false { seal() }
    }
}
