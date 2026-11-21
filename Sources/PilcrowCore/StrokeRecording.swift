import Foundation

/// Local calibration evidence. Version 3 preserves frame points and records reversed shafts.
public struct StrokeRecording: Codable, Sendable {
    public let version: Int
    public let recognizerVersion: String
    public let strokes: [Record]

    public init(strokes: [Record]) {
        version = 3
        recognizerVersion = ShapeRecognizer.version
        self.strokes = strokes
    }

    public struct Record: Codable, Sendable {
        public static let pointLimit = 5_000
        public let id: MarkID
        public let frameID: Frame.ID
        public let frameSize: Size
        /// Capture pixels per frame point; nil when capture metadata is unavailable.
        public let displayScale: Double?
        public let shape: MarkShape?
        /// Original samples in top-left frame points. No rounding or smoothing.
        public let points: [Point]
        public let originalPointCount: Int
        public let decimated: Bool
        public let resampleMethod: String
        public let downTime: Double
        public let upTime: Double?
        public let absorbedInto: MarkID?
        /// The rendered tip in frame points when it differs from the last recorded sample.
        public let shaftEnd: Point?
        public let shaftReversed: Bool?

        public init(stroke: Stroke, frame: Frame) {
            id = stroke.id
            frameID = stroke.frameID
            frameSize = frame.boundsInPoints
            displayScale = frame.pixelSize.map { $0.width / frame.boundsInPoints.width }
            shape = stroke.shape
            originalPointCount = stroke.points.count
            decimated = originalPointCount > Self.pointLimit
            resampleMethod = decimated ? "uniform-index" : "none"
            let count = min(Self.pointLimit, originalPointCount)
            points = (0..<count).map { index in
                // Uniform index decimation preserves endpoints and original values.
                let source = count <= 1 ? 0 : Int((Double(index) * Double(stroke.points.count - 1)
                    / Double(count - 1)).rounded())
                let point = stroke.points[source]
                return Point(x: point.x * frame.boundsInPoints.width, y: point.y * frame.boundsInPoints.height)
            }
            downTime = stroke.downTime
            upTime = stroke.upTime
            absorbedInto = stroke.absorbedInto
            shaftReversed = stroke.shaftReversed
            let renderedTip: NormalizedPoint?
            if shaftReversed == true {
                renderedTip = stroke.renderedPoints.first
            } else {
                renderedTip = stroke.shaftPointCount == nil ? nil : stroke.renderedPoints.last
            }
            shaftEnd = renderedTip.map {
                Point(x: $0.x * frame.boundsInPoints.width, y: $0.y * frame.boundsInPoints.height)
            }
        }

        /// Uses current rules. Pass the marks that preceded this stroke at pen-up
        /// for arrow context. Decimated records cannot promise an exact replay.
        public func replay(existingMarks: [Stroke] = []) -> MarkShape {
            ShapeRecognizer.classify(framePoints: points, frameSize: frameSize,
                                     existingMarks: existingMarks.filter { $0.frameID == frameID }).shape
        }

        // Keep the displayScale field explicit, even when capture was unavailable.
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(frameID, forKey: .frameID)
            try values.encode(frameSize, forKey: .frameSize)
            try values.encode(displayScale, forKey: .displayScale)
            try values.encodeIfPresent(shape, forKey: .shape)
            try values.encode(points, forKey: .points)
            try values.encode(originalPointCount, forKey: .originalPointCount)
            try values.encode(decimated, forKey: .decimated)
            try values.encode(resampleMethod, forKey: .resampleMethod)
            try values.encode(downTime, forKey: .downTime)
            try values.encodeIfPresent(upTime, forKey: .upTime)
            try values.encodeIfPresent(absorbedInto, forKey: .absorbedInto)
            try values.encodeIfPresent(shaftEnd, forKey: .shaftEnd)
            try values.encodeIfPresent(shaftReversed, forKey: .shaftReversed)
        }
    }
}
