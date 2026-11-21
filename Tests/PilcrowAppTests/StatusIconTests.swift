import AppKit
import XCTest
@testable import PilcrowApp

@MainActor
final class StatusIconTests: XCTestCase {
    func testSizesAndTemplateFlags() {
        for state in [StatusIcon.State.idle, .annotating, .warning] {
            let image = StatusIcon.image(state)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertEqual(image.isTemplate, state != .annotating)
        }
    }

    func testCutoutAndRedBadge() throws {
        for state in [StatusIcon.State.idle, .annotating, .warning] {
            let image = StatusIcon.image(state)
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 180,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(in: NSRect(x: 0, y: 0, width: 180, height: 180))
            NSGraphicsContext.restoreGraphicsState()
            // colorAt uses top-down rows, matching the supplied SVG coordinates.
            let stem = try XCTUnwrap(rep.colorAt(x: 122, y: 100)?.usingColorSpace(.sRGB))
            let disc = try XCTUnwrap(rep.colorAt(x: 35, y: 90)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(stem.alphaComponent, 0.01)
            XCTAssertGreaterThan(disc.alphaComponent, 0.99)
            if state == .annotating {
                XCTAssertEqual(disc.redComponent, 0.89, accuracy: 0.02)
                XCTAssertEqual(disc.greenComponent, 0.08, accuracy: 0.02)
                XCTAssertEqual(disc.blueComponent, 0.12, accuracy: 0.02)
            }
        }
    }
}
