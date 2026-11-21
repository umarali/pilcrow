import Foundation

/// Point conversion and image downscaling. No AppKit types.
public enum Geometry {
    public static let suggestedMaxLongEdge = ImageLimits.maxLongEdge
    public static let suggestedMaxPixels = ImageLimits.maxPixels

    /// Normalizes an AppKit global screen point using only the registered point bounds.
    /// Pass the frame's bottom-left global origin, not an overlay-local point or origin.
    /// Works before capture completes. Invalid inputs or non-finite results return nil.
    public static func normalizedPoint(screenPoint: Point, frameOrigin: Point, frame: Frame) -> NormalizedPoint? {
        let bounds = frame.boundsInPoints
        guard [screenPoint.x, screenPoint.y, frameOrigin.x, frameOrigin.y].allSatisfy(\.isFinite),
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let point = NormalizedPoint(x: (screenPoint.x - frameOrigin.x) / bounds.width,
                                    y: 1 - (screenPoint.y - frameOrigin.y) / bounds.height)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    /// Converts an AppKit global screen point to top-left source pixels after capture.
    public static func pixelPoint(screenPoint: Point, frameOrigin: Point, frame: Frame) -> Point? {
        guard let point = normalizedPoint(screenPoint: screenPoint, frameOrigin: frameOrigin, frame: frame) else { return nil }
        return denormalize(point, frame: frame)
    }

    /// Maps top-left source pixels into frame fractions. Pending or failed captures return nil.
    public static func normalize(_ pixelPoint: Point, frame: Frame) -> NormalizedPoint? {
        guard frame.isComplete, let size = frame.pixelSize, pixelPoint.x.isFinite, pixelPoint.y.isFinite else { return nil }
        let point = NormalizedPoint(x: pixelPoint.x / size.width, y: pixelPoint.y / size.height)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    /// Maps frame fractions back to top-left source pixels. Pending or failed captures return nil.
    public static func denormalize(_ point: NormalizedPoint, frame: Frame) -> Point? {
        guard frame.isComplete, let size = frame.pixelSize, point.x.isFinite, point.y.isFinite else { return nil }
        let pixels = Point(x: point.x * size.width, y: point.y * size.height)
        return pixels.x.isFinite && pixels.y.isFinite ? pixels : nil
    }

    /// Shrinks `size` so the longer side is at most `maxLongEdge` and `width * height` is at most `maxPixels`.
    /// Pixel count can exceed the cap by a few floating-point ULPs. Aspect ratio is unchanged. A size that already fits is returned as it is. Values are not rounded to whole pixels.
    /// Non-finite or non-positive dimensions or caps return `0` by `0`.
    public static func fit(size: Size, maxLongEdge: Double, maxPixels: Double) -> Size {
        guard [size.width, size.height, maxLongEdge, maxPixels].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return Size(width: 0, height: 0)
        }
        var scale = 1.0
        let longEdge = max(size.width, size.height)
        if longEdge > maxLongEdge {
            scale = min(scale, maxLongEdge / longEdge)
        }
        // Taking square roots before division avoids overflowing width * height and
        // underflowing maxPixels / width / height for very large finite dimensions.
        let pixelScale = maxPixels.squareRoot() / size.width.squareRoot() / size.height.squareRoot()
        scale = min(scale, pixelScale)
        return Size(width: size.width * scale, height: size.height * scale)
    }
    /// Fits integer pixels with a one-pixel minimum on each axis, respecting both caps.
    public static func fitPixels(width: Double, height: Double, maxLongEdge: Double, maxPixels: Double) -> (width: Int, height: Int)? {
        guard [width, height, maxLongEdge, maxPixels].allSatisfy({ $0.isFinite && $0 > 0 }), maxLongEdge >= 1, maxPixels >= 1 else { return nil }
        let scale = min(1, maxLongEdge / max(width, height), maxPixels.squareRoot() / width.squareRoot() / height.squareRoot())
        let limit = min(maxLongEdge.rounded(.down), Double(Int.max).nextDown)
        var w = max(1, min((width * scale).rounded(.down), limit))
        var h = max(1, min((height * scale).rounded(.down), limit))
        if w > maxPixels / h {
            if w >= h { w = min(w, (maxPixels / h).rounded(.down)) }
            else { h = min(h, (maxPixels / w).rounded(.down)) }
        }
        return (Int(w), Int(h))
    }

}

/// Export legibility limits from D-17.5, shared by frames and per-mark crops.
public enum ImageLimits {
    public static let maxLongEdge: Double = 1600
    public static let maxPixels: Double = 1_560_000
    public static let minBadgeHeightPixels: Double = 24
}

/// Badge metrics shared by rendering, pin hit testing and arrow crop planning.
public enum MarkBadgeGeometry {
    public static let height = 20.0
    public static let pinGap = 6.0
    public static let arrowGap = 4.0

    public static func numberedBadgeWidth(id: MarkID, height: Double) -> Double {
        // Reserve 7 pt per Helvetica Bold numeral, plus 5 pt padding on each side.
        max(height, Double(7 * String(id.rawValue).count + 10) * height / Self.height)
    }

    /// Uses top-left coordinates local to the canvas. The renderer can scale the export badge.
    public static func pinBadge(at dot: Point, in canvas: Size, id: MarkID,
                                height: Double = height, gap: Double = pinGap) -> PointRect {
        let width = numberedBadgeWidth(id: id, height: height)
        let right = dot.x + gap
        let left = right + width <= canvas.width ? right : dot.x - gap - width
        let x = max(0, min(left, canvas.width - width))
        let y = max(0, min(dot.y - height / 2, canvas.height - height))
        return PointRect(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }
}
