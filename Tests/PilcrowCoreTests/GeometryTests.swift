import XCTest
@testable import PilcrowCore

final class GeometryTests: XCTestCase {
    func testRetinaScaleFlipsTheVerticalAxis() throws {
        // 144 by 90 points at scale 2 is 288 by 180 pixels.
        // The frame's bottom-left is screen point (100, 200).
        let frame = Frame(
            id: Frame.ID(),
            capturedAt: 0,
            displayID: 1,
            boundsInPoints: Size(width: 144, height: 90),
            pixelSize: Size(width: 288, height: 180)
        )
        let origin = Point(x: 100, y: 200)

        let topLeft = try XCTUnwrap(Geometry.pixelPoint(
            screenPoint: Point(x: 100, y: 290),
            frameOrigin: origin,
            frame: frame
        ))
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-9)

        let bottomLeft = try XCTUnwrap(Geometry.pixelPoint(
            screenPoint: Point(x: 100, y: 200),
            frameOrigin: origin,
            frame: frame
        ))
        XCTAssertEqual(bottomLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(bottomLeft.y, 180, accuracy: 1e-9)

        // 12 points right and 15 points up from the frame origin.
        // Pixel x = 24. Pixel y = (90 - 15) * 2 = 150.
        let inner = try XCTUnwrap(Geometry.pixelPoint(
            screenPoint: Point(x: 112, y: 215),
            frameOrigin: origin,
            frame: frame
        ))
        XCTAssertEqual(inner.x, 24, accuracy: 1e-9)
        XCTAssertEqual(inner.y, 150, accuracy: 1e-9)
    }

    func testNormalizeAndDenormalizeRoundTrip() throws {
        let frame = makeFrame(
            points: Size(width: 144, height: 90),
            pixels: Size(width: 288, height: 180)
        )
        let normalized = try XCTUnwrap(Geometry.normalize(Point(x: 144, y: 90), frame: frame))
        XCTAssertEqual(normalized.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 1e-12)

        let pixels = try XCTUnwrap(Geometry.denormalize(normalized, frame: frame))
        XCTAssertEqual(pixels.x, 144, accuracy: 1e-9)
        XCTAssertEqual(pixels.y, 90, accuracy: 1e-9)

        let corners = Geometry.denormalize(NormalizedPoint(x: 0, y: 0), frame: frame)
        XCTAssertEqual(corners, Point.zero)
        let far = try XCTUnwrap(Geometry.denormalize(NormalizedPoint(x: 1, y: 1), frame: frame))
        XCTAssertEqual(far.x, 288, accuracy: 1e-9)
        XCTAssertEqual(far.y, 180, accuracy: 1e-9)
    }

    func testNormalizeOfZeroPixelSizeIsNil() {
        let frame = makeFrame(pixels: Size(width: 0, height: 0))
        XCTAssertNil(Geometry.normalize(Point(x: 5, y: 5), frame: frame))
    }

    func testFit2400x1600MeetsLongEdgeAndPixelCaps() {
        let fitted = Geometry.fit(
            size: Size(width: 2400, height: 1600),
            maxLongEdge: 1600,
            maxPixels: 1_560_000
        )
        let scale = (1_560_000.0 / (2400.0 * 1600.0)).squareRoot()
        XCTAssertEqual(fitted.width, 2400 * scale, accuracy: 1e-6)
        XCTAssertEqual(fitted.height, 1600 * scale, accuracy: 1e-6)
        XCTAssertEqual(fitted.width / fitted.height, 2400.0 / 1600.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(fitted.width * fitted.height, 1_560_000 + 1e-4)
        XCTAssertLessThanOrEqual(max(fitted.width, fitted.height), 1600)
        // 1600 would be the long-edge-only width. The pixel cap is tighter, so the result is smaller.
        XCTAssertLessThan(fitted.width, 1600)
    }

    func testFitDoesNotUpscale() {
        let size = Size(width: 100, height: 80)
        let fitted = Geometry.fit(size: size, maxLongEdge: 1600, maxPixels: 1_560_000)
        XCTAssertEqual(fitted, size)
    }

    func testFitHandlesHugeFiniteDimensionsWithoutOverflow() {
        let fitted = Geometry.fit(
            size: Size(width: 1e200, height: 1e200),
            maxLongEdge: 1600,
            maxPixels: 1_560_000
        )

        XCTAssertGreaterThan(fitted.width, 0)
        XCTAssertGreaterThan(fitted.height, 0)
        XCTAssertTrue(fitted.width.isFinite)
        XCTAssertTrue(fitted.height.isFinite)
        XCTAssertLessThanOrEqual(max(fitted.width, fitted.height), 1600)
        XCTAssertLessThanOrEqual(fitted.width * fitted.height, 1_560_000 + 1e-4)
    }

    func testFitLongEdgeBindsBeforeThePixelCap() {
        let fitted = Geometry.fit(
            size: Size(width: 3000, height: 100),
            maxLongEdge: 1600,
            maxPixels: 1_560_000
        )
        let scale = 1600.0 / 3000.0
        XCTAssertEqual(fitted.width, 1600, accuracy: 1e-9)
        XCTAssertEqual(fitted.height, 100 * scale, accuracy: 1e-9)
        XCTAssertLessThan(fitted.width * fitted.height, 1_560_000 + 1e-4)
    }

    func testFitOfNonPositiveSizeIsZero() {
        XCTAssertEqual(
            Geometry.fit(size: Size(width: 0, height: 40), maxLongEdge: 100, maxPixels: 100),
            Size(width: 0, height: 0)
        )
        XCTAssertEqual(
            Geometry.fit(size: Size(width: 40, height: 40), maxLongEdge: 0, maxPixels: 100),
            Size(width: 0, height: 0)
        )
        XCTAssertEqual(
            Geometry.fit(size: Size(width: .infinity, height: 10), maxLongEdge: 100, maxPixels: 100),
            Size(width: 0, height: 0)
        )
        XCTAssertEqual(
            Geometry.fit(size: Size(width: 10, height: .nan), maxLongEdge: 100, maxPixels: 100),
            Size(width: 0, height: 0)
        )
    }

    func testPixelPointUsesActualImageSizeOnNegativeOrigin() {
        let frame = makeFrame(points: Size(width: 100, height: 100), pixels: Size(width: 150, height: 150))
        let point = Geometry.pixelPoint(screenPoint: Point(x: -150, y: -50), frameOrigin: Point(x: -200, y: -100), frame: frame)
        XCTAssertEqual(point, Point(x: 75, y: 75))
    }

    func testPixelPointUsesIndependentScalesAndMapsFrameCorners() {
        let frame = makeFrame(points: Size(width: 200, height: 100), pixels: Size(width: 600, height: 200))
        let origin = Point(x: -300, y: -200)
        let nearTopRight = Geometry.pixelPoint(screenPoint: Point(x: -110, y: -193), frameOrigin: origin, frame: frame)
        XCTAssertEqual(nearTopRight, Point(x: 570, y: 186))

        let topLeft = Geometry.pixelPoint(screenPoint: Point(x: -300, y: -100), frameOrigin: origin, frame: frame)
        XCTAssertEqual(topLeft, Point.zero)

        let bottomLeft = Geometry.pixelPoint(screenPoint: origin, frameOrigin: origin, frame: frame)
        XCTAssertEqual(bottomLeft, Point(x: 0, y: 200))
    }

    func testFitPixelsCapsSweepAndExtremeAspectRatios() throws {
        for width in [1.0, 10, 100, 1500, 100000] {
            for height in [1.0, 3, 1000] {
                for cap in [1.0, 17, 1600] {
                    for pixels in [1.0, 37, 1560000] {
                        let fitted = try XCTUnwrap(Geometry.fitPixels(width: width, height: height, maxLongEdge: cap, maxPixels: pixels))
                        XCTAssertGreaterThanOrEqual(min(fitted.width, fitted.height), 1)
                        XCTAssertLessThanOrEqual(Double(max(fitted.width, fitted.height)), cap)
                        XCTAssertLessThanOrEqual(Double(fitted.width) * Double(fitted.height), pixels)
                        XCTAssertLessThanOrEqual(Double(fitted.width), width)
                        XCTAssertLessThanOrEqual(Double(fitted.height), height)
                    }
                }
            }
        }
        let thin = try XCTUnwrap(Geometry.fitPixels(width: 100000, height: 1, maxLongEdge: 1600, maxPixels: 100))
        XCTAssertEqual(thin.width, 100); XCTAssertEqual(thin.height, 1)
        let pixelCap = try XCTUnwrap(Geometry.fitPixels(width: 1500, height: 1000, maxLongEdge: 2000, maxPixels: 1000000))
        XCTAssertEqual(pixelCap.width, 1224); XCTAssertEqual(pixelCap.height, 816)
        let small = try XCTUnwrap(Geometry.fitPixels(width: 10, height: 10, maxLongEdge: 1600, maxPixels: 1_560_000))
        XCTAssertEqual(small.width, 10)
        XCTAssertEqual(small.height, 10)
        XCTAssertNil(Geometry.fitPixels(width: .infinity, height: 1, maxLongEdge: 2, maxPixels: 2))
        XCTAssertNil(Geometry.fitPixels(width: 1, height: 1, maxLongEdge: 2, maxPixels: 0))
    }

    func testFitPixelsHugeFiniteSquareDoesNotUnderflow() throws {
        let size = try XCTUnwrap(Geometry.fitPixels(width: 1e200, height: 1e200, maxLongEdge: 1600, maxPixels: 1_560_000))
        XCTAssertEqual(size.width, 1248)
        XCTAssertEqual(size.height, 1248)
    }

    func testFitPixelsSubpixelInputHasOnePixelMinimum() throws {
        let size = try XCTUnwrap(Geometry.fitPixels(width: 0.5, height: 0.5, maxLongEdge: 1600, maxPixels: 1_560_000))
        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 1)
    }

}
