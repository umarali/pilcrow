import Foundation

/// Stable mark number. Issued once by `Session` and never reused.
public struct MarkID: Sendable, Equatable, Hashable, Comparable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: MarkID, rhs: MarkID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension MarkID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }
}

/// A point in points or in pixels. The function that uses it names the space.
public struct Point: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

/// Width and height in one unit, either points or pixels.
public struct Size: Sendable, Equatable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A point on a frame. Origin is the top-left. `x` and `y` are fractions of the frame, normally in `0...1`.
public struct NormalizedPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A registered capture, pending or failed until capture metadata is available.
public struct Frame: Identifiable, Sendable, Equatable, Hashable, Codable {
    public typealias ID = UUID
    public var id: ID
    /// Seconds on the session clock.
    public var capturedAt: Double?
    public var displayID: UInt32
    /// Size of the frame in AppKit points. The screen origin is not stored.
    public var boundsInPoints: Size
    public var pixelSize: Size?
    public var captureFailed: Bool

    /// Register this before pen-down; complete it after asynchronous capture succeeds.
    public init(id: ID, displayID: UInt32, boundsInPoints: Size) {
        self.id = id
        self.displayID = displayID
        self.boundsInPoints = boundsInPoints
        capturedAt = nil
        pixelSize = nil
        captureFailed = false
    }

    public var isComplete: Bool {
        guard !captureFailed, let capturedAt, let pixelSize else { return false }
        return capturedAt.isFinite && pixelSize.width.isFinite && pixelSize.height.isFinite
            && pixelSize.width > 0 && pixelSize.height > 0
    }

    public init(
        id: ID,
        capturedAt: Double,
        displayID: UInt32,
        boundsInPoints: Size,
        pixelSize: Size
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.displayID = displayID
        self.boundsInPoints = boundsInPoints
        self.pixelSize = pixelSize
        captureFailed = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, displayID, boundsInPoints, pixelSize, captureFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        capturedAt = try container.decodeIfPresent(Double.self, forKey: .capturedAt)
        displayID = try container.decode(UInt32.self, forKey: .displayID)
        boundsInPoints = try container.decode(Size.self, forKey: .boundsInPoints)
        pixelSize = try container.decodeIfPresent(Size.self, forKey: .pixelSize)
        captureFailed = try container.decodeIfPresent(Bool.self, forKey: .captureFailed) ?? false
    }
}

/// One freehand mark. `upTime` stays nil until `Session.endStroke`.
public struct Stroke: Identifiable, Sendable, Equatable, Hashable, Codable {
    public var id: MarkID
    public var frameID: Frame.ID
    /// Seconds on the session clock when the pen touched down.
    public var downTime: Double
    /// Seconds on the session clock when the pen lifted. Nil while the stroke is open.
    public var upTime: Double?
    public var points: [NormalizedPoint]
    /// Where the number is drawn. `beginStroke` sets this to the first point.
    public var badgeAnchor: NormalizedPoint
    public var isDeleted: Bool

    public init(
        id: MarkID,
        frameID: Frame.ID,
        downTime: Double,
        upTime: Double?,
        points: [NormalizedPoint],
        badgeAnchor: NormalizedPoint,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.frameID = frameID
        self.downTime = downTime
        self.upTime = upTime
        self.points = points
        self.badgeAnchor = badgeAnchor
        self.isDeleted = isDeleted
    }
}

/// One recognised word, timed on the session clock.
public struct TranscriptWord: Sendable, Equatable, Hashable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    public var isFinal: Bool

    /// Speech timing is an estimate unless the producer explicitly states otherwise.
    public var isEstimated: Bool

    public init(text: String, start: Double, end: Double, isFinal: Bool = true, isEstimated: Bool = true) {
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
        self.isEstimated = isEstimated
    }

    private enum CodingKeys: String, CodingKey {
        case text, start, end, isFinal, isEstimated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)
        isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? true
    }
}
