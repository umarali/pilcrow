import Foundation

/// A visible mark number or an internal ID for an absorbed gesture.
/// A pen-down number is provisional until the stroke finishes.
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
    /// App/window under the first mark, captured without Accessibility.
    public var context: FrameContext?

    /// Register this before pen-down; complete it after asynchronous capture succeeds.
    public init(id: ID, displayID: UInt32, boundsInPoints: Size, context: FrameContext? = nil) {
        self.context = context
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
        pixelSize: Size,
        context: FrameContext? = nil
    ) {
        self.context = context
        self.id = id
        self.capturedAt = capturedAt
        self.displayID = displayID
        self.boundsInPoints = boundsInPoints
        self.pixelSize = pixelSize
        captureFailed = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, displayID, boundsInPoints, pixelSize, captureFailed, context
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        capturedAt = try container.decodeIfPresent(Double.self, forKey: .capturedAt)
        displayID = try container.decode(UInt32.self, forKey: .displayID)
        boundsInPoints = try container.decode(Size.self, forKey: .boundsInPoints)
        pixelSize = try container.decodeIfPresent(Size.self, forKey: .pixelSize)
        context = try container.decodeIfPresent(FrameContext.self, forKey: .context)
        captureFailed = try container.decodeIfPresent(Bool.self, forKey: .captureFailed) ?? false
    }
}

/// A fitted shape's bounds in top-left frame points.
public struct PointRect: Sendable, Equatable, Hashable, Codable {
    public let origin: Point
    public let size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    var isValid: Bool {
        size.width.isFinite && size.width > 0 && (origin.x + size.width).isFinite
            && size.height.isFinite && size.height > 0 && (origin.y + size.height).isFinite
    }
}

public enum MarkShape: Sendable, Equatable, Hashable, Codable {
    public enum Area: Sendable, Equatable, Hashable, Codable {
        case rectangle(PointRect), ellipse(PointRect), freeform

        public var fittedBounds: PointRect? {
            switch self {
            case .rectangle(let bounds), .ellipse(let bounds): return bounds
            case .freeform: return nil
            }
        }
    }

    case pin, area(Area), arrow(from: MarkID?, to: MarkID?), mark

    // Match the synthesized representation used by saved sessions and stroke recordings.
    private enum Payload: Codable {
        case pin, area(Area), arrow(from: MarkID?, to: MarkID?, linkedTo: MarkID?), mark
    }

    public init(from decoder: Decoder) throws {
        switch try Payload(from: decoder) {
        case .pin: self = .pin
        case .area(let area): self = .area(area)
        case .arrow(let from, let to, let linkedTo): self = .arrow(from: from ?? linkedTo, to: to)
        case .mark: self = .mark
        }
    }

    public func encode(to encoder: Encoder) throws {
        let payload: Payload
        switch self {
        case .pin: payload = .pin
        case .area(let area): payload = .area(area)
        case .arrow(let from, let to): payload = .arrow(from: from, to: to, linkedTo: nil)
        case .mark: payload = .mark
        }
        try payload.encode(to: encoder)
    }
}

/// One drawn mark. `upTime` stays nil until `Session.endStroke`.
public struct Stroke: Identifiable, Sendable, Equatable, Hashable, Codable {
    public var id: MarkID
    public var frameID: Frame.ID
    /// Seconds on the session clock when the pen touched down.
    public var downTime: Double
    /// Seconds on the session clock when the pen lifted. Nil while the stroke is open.
    public var upTime: Double?
    public var points: [NormalizedPoint]
    /// The freehand badge anchor. `beginStroke` sets this to the first point.
    public var badgeAnchor: NormalizedPoint
    public var isDeleted: Bool
    /// Nil while drawing or when decoding a mark saved before shape recognition.
    public var shape: MarkShape?
    /// A same-stroke head begins after this prefix of the original samples.
    public internal(set) var shaftPointCount: Int?
    /// True when a separate head was drawn at the shaft's pen-down end.
    public internal(set) var shaftReversed: Bool?
    /// A separate head keeps its samples under a hidden ID and points to the visible shaft.
    public internal(set) var absorbedInto: MarkID?
    /// Set when the hidden head changed the visible shaft.
    internal var shapeBeforeAbsorption: MarkShape?
    internal var shaftReversedBeforeAbsorption: Bool?

    public var renderedPoints: ArraySlice<NormalizedPoint> {
        guard case .arrow = shape, let count = shaftPointCount, count >= 2 else { return points[...] }
        return points.prefix(count)
    }

    public init(
        id: MarkID,
        frameID: Frame.ID,
        downTime: Double,
        upTime: Double?,
        points: [NormalizedPoint],
        badgeAnchor: NormalizedPoint,
        isDeleted: Bool = false,
        shape: MarkShape? = nil
    ) {
        self.id = id
        self.frameID = frameID
        self.downTime = downTime
        self.upTime = upTime
        self.points = points
        self.badgeAnchor = badgeAnchor
        self.isDeleted = isDeleted
        self.shape = shape
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
