import XCTest
@testable import PilcrowCore

final class ShapeRecognizerTests: XCTestCase {
    private typealias XY = (x: Double, y: Double)
    private let frameSize = Size(width: 1600, height: 400)

    private func point(_ xy: XY) -> NormalizedPoint {
        NormalizedPoint(x: xy.x / frameSize.width, y: xy.y / frameSize.height)
    }

    private func recognize(_ ink: [XY], near marks: [Stroke] = []) -> MarkShape {
        ShapeRecognizer.recognize(points: ink.map(point), frameSize: frameSize, existingMarks: marks)
    }

    private func polyline(_ vertices: [XY], samplesPerEdge: Int = 10) -> [XY] {
        zip(vertices, vertices.dropFirst()).flatMap { a, b in
            (0..<samplesPerEdge).map { sample -> XY in
                let t = Double(sample) / Double(samplesPerEdge)
                return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            }
        } + vertices.suffix(1)
    }

    private func jitter(_ points: [XY], seed: UInt64, amplitude: Double) -> [XY] {
        var state = seed
        func offset() -> Double {
            state = state &* 6364136223846793005 &+ 1
            return (Double(state >> 48) / 65535 * 2 - 1) * amplitude
        }
        return points.map { ($0.x + offset(), $0.y + offset()) }
    }

    private func oval(rx: Double, ry: Double, rotation: Double = 0, sweep: Double = 360,
                      radialScale: (Double) -> Double = { _ in 1 }) -> [XY] {
        (0...96).map { step in
            let angle = Double(step) / 96 * (sweep * .pi / 180)
            let x = rx * cos(angle) * radialScale(angle)
            let y = ry * sin(angle) * radialScale(angle)
            return (300 + x * cos(rotation) - y * sin(rotation),
                    200 + x * sin(rotation) + y * cos(rotation))
        }
    }

    private func target(_ shape: MarkShape?, id: MarkID = 7, ink: [XY] = [(200, 100)],
                        deleted: Bool = false, ended: Bool = true) -> Stroke {
        Stroke(id: id, frameID: Frame.ID(), downTime: 0, upTime: ended ? 1 : nil, points: ink.map(point),
               badgeAnchor: point(ink[0]), isDeleted: deleted, shape: shape)
    }

    func testPinUsesExtentRatherThanCumulativeTravel() {
        let pins: [[XY]] = [
            [(800, 200)],
            [(800, 200), (802, 200), (800, 200)],
            [(800, 200), (803, 200), (800, 200)],
            [(800, 200), (801, 200), (800, 201), (801, 201), (800, 200)],
            [(800, 200), (802, 202), (803, 203)],
            [(800, 200), (804.2, 204.2)]
        ]
        for ink in pins { XCTAssertEqual(recognize(ink), .pin) }
        XCTAssertEqual(recognize([(800, 200), (804.3, 204.3)]), .mark)
    }

    func testJitteredBoxesTidyAcrossAspectRatiosAndClosureStyles() {
        let sizes: [XY] = [(76, 76), (220, 40), (40, 180)]
        for (index, size) in sizes.enumerated() {
            for closure in [-8.0, 0.0, 8.0] {
                let x = 200.0, y = 80.0
                let mid = x + size.x / 2
                let corners = [(mid, y), (x + size.x, y), (x + size.x, y + size.y),
                               (x, y + size.y), (x, y), (mid + closure, y)]
                let ink = jitter(polyline(corners), seed: UInt64(index + 21), amplitude: 1.15)
                guard case .area(.rectangle(let box)) = recognize(ink) else {
                    XCTFail("Expected a box for \(size) and closure \(closure)")
                    continue
                }
                XCTAssertEqual(box.origin.x, x, accuracy: 1.2)
                XCTAssertEqual(box.origin.y, y, accuracy: 1.2)
                XCTAssertEqual(box.size.width, size.x, accuracy: 2.4)
                XCTAssertEqual(box.size.height, size.y, accuracy: 2.4)
                XCTAssertEqual(recognize(Array(ink.reversed())), .area(.rectangle(box)))
            }
        }
    }

    func testJitteredCirclesAndAxisAlignedEllipsesTidyInFramePoints() {
        let radii: [XY] = [(44, 44), (99, 27), (29, 79)]
        for (index, radius) in radii.enumerated() {
            let ink = jitter(Array(oval(rx: radius.x, ry: radius.y).dropLast(2)),
                             seed: UInt64(index + 7), amplitude: 1)
            guard case .area(.ellipse(let box)) = recognize(ink) else {
                XCTFail("Expected an ellipse with radii \(radius)")
                continue
            }
            XCTAssertEqual(box.origin.x, 300 - radius.x, accuracy: 1.2)
            XCTAssertEqual(box.origin.y, 200 - radius.y, accuracy: 1.2)
            XCTAssertEqual(box.size.width, 2 * radius.x, accuracy: 2.4)
            XCTAssertEqual(box.size.height, 2 * radius.y, accuracy: 2.4)
        }
    }

    func testSlopedRoundedBoxesTidyAtTextAndButtonSizes() {
        for (width, height, seed) in [(300.0, 24.0, 53 as UInt64), (220, 40, 71)] {
            for slope in [2.8, 3.4] {
                let x = 150.0, y = 80.0, radius = 4.0
                let corners: [XY] = [(x, y + slope), (x + width, y),
                                     (x + width - 1, y + height), (x + 1, y + height + 1)]
                var rounded = [XY]()
                for (i, corner) in corners.enumerated() {
                    let before = corners[(i + 3) % 4], after = corners[(i + 1) % 4]
                    func inset(toward point: XY) -> XY {
                        let scale = radius / hypot(point.x - corner.x, point.y - corner.y)
                        return (corner.x + scale * (point.x - corner.x), corner.y + scale * (point.y - corner.y))
                    }
                    let a = inset(toward: before), b = inset(toward: after)
                    rounded.append(contentsOf: (0...4).map { step in
                        let t = Double(step) / 4, u = 1 - t
                        return (u * u * a.x + 2 * t * u * corner.x + t * t * b.x,
                                u * u * a.y + 2 * t * u * corner.y + t * t * b.y)
                    })
                }
                let ink = jitter(polyline(rounded + [rounded[0]], samplesPerEdge: 4), seed: seed, amplitude: 0.35)
                guard case .area(.rectangle(let box)) = recognize(ink) else {
                    XCTFail("Expected a tidy \(width) by \(height) rounded box with slope \(slope) pt")
                    continue
                }
                XCTAssertEqual(box.size.width, width, accuracy: 2)
                XCTAssertEqual(box.size.height, height, accuracy: 2)
            }
        }
    }


    func testSlantedParallelogramsTidyToFrameAlignedBoxes() {
        for (height, slope) in [(24.0, 5.6), (100, 30), (160, 45)] {
            let ink = polyline([(100, 100), (400, 100 + slope), (400, 100 + height + slope),
                                (100, 100 + height), (100, 100)], samplesPerEdge: 12)
            guard case .area(.rectangle(let bounds)) = recognize(jitter(ink, seed: 81, amplitude: 0.03)) else {
                return XCTFail("Expected a box at height \(height), slope \(slope)")
            }
            XCTAssertEqual(bounds.size.width, 300, accuracy: 0.1)
            XCTAssertEqual(bounds.size.height, height + slope, accuracy: 0.1)
        }
    }


    func testShallowEdgeBendsKeepTheBox() {
        for (height, depth) in [(20.0, 1.9), (32, 3.0)] {
            let ink = polyline([(100, 100), (108, 100 + depth), (392, 100 + depth), (400, 100),
                                (400, 100 + height), (392, 100 + height - depth),
                                (108, 100 + height - depth), (100, 100 + height), (100, 100)])
            guard case .area(.rectangle) = recognize(jitter(ink, seed: 81, amplitude: 0.04)) else {
                return XCTFail("Expected a box at height \(height), depth \(depth)")
            }
        }
    }


    func testFiveCornerBoxCanTidyButADistinctInwardNotchKeepsItsInk() {
        let clipped = polyline([(124, 100), (300, 100), (300, 220), (100, 220),
                                (100, 124), (124, 100)])
        guard case .area(.rectangle) = recognize(jitter(clipped, seed: 17, amplitude: 0.03)) else {
            return XCTFail("Expected a tidy box with a clipped corner")
        }
        let notched = polyline([(100, 100), (184, 100), (200, 170), (216, 100),
                                (300, 100), (300, 220), (100, 220), (100, 100)])
        XCTAssertEqual(recognize(notched), .area(.freeform))
    }

    func testWobbledOvalsTidyAtFiveAndTwentyDegrees() {
        for (rx, ry) in [(35.0, 14.0), (60, 22), (120, 30), (23, 76)] {
            for (seed, phase) in [(13 as UInt64, 0.4), (47, 2.5), (91, 4.6)] {
                func ink(tilt: Double) -> [XY] {
                    let points = oval(rx: rx, ry: ry, rotation: tilt * .pi / 180) { angle in
                        1 + 0.06 * sin(2 * angle + phase) + 0.03 * sin(3 * angle + phase)
                    }
                    return jitter(points, seed: seed, amplitude: 0.15)
                }
                guard case .area(.ellipse) = recognize(ink(tilt: 5)) else {
                    XCTFail("Expected a tidy \(rx) by \(ry) oval with seed \(seed)")
                    continue
                }
                assertEllipse(true, for: ink(tilt: 20))
            }
        }
    }


    func testOvalToleratesShallowWobbleButRejectsDeepIndentation() {
        for radius in [35.0, 100] {
            let shallow = oval(rx: radius, ry: radius) { 1 - 0.08 * pow(sin(2 * $0), 2) }
            assertEllipse(true, for: jitter(shallow, seed: 25, amplitude: 0.025))
            let deep = oval(rx: radius, ry: radius) { 1 - 0.52 * pow(sin(2 * $0), 2) }
            XCTAssertEqual(recognize(deep), .area(.freeform))
        }
    }

    func testRotatedBoxesAndEllipsesUseFrameAlignedBounds() {
        let square: [XY] = [(-45, -45), (45, -45), (45, 45), (-45, 45), (-45, -45)]
        for degrees in [12.0, 26.0, 45.0] {
            let angle = degrees * .pi / 180
            let rotated = square.map { p in
                (300 + p.x * cos(angle) - p.y * sin(angle), 200 + p.x * sin(angle) + p.y * cos(angle))
            }
            let ink = jitter(polyline(rotated), seed: 41, amplitude: 1)
            guard case .area(.rectangle(let bounds)) = recognize(ink) else {
                return XCTFail("Expected a box at \(degrees)°")
            }
            XCTAssertEqual(bounds.size.width, ink.map(\.x).max()! - ink.map(\.x).min()!, accuracy: 0.01)
            XCTAssertEqual(bounds.size.height, ink.map(\.y).max()! - ink.map(\.y).min()!, accuracy: 0.01)
        }
        let tilted = oval(rx: 90, ry: 23, rotation: .pi / 6)
        guard case .area(.ellipse(let bounds)) = recognize(tilted) else { return XCTFail("Expected an oval") }
        XCTAssertEqual(bounds.size.width, tilted.map(\.x).max()! - tilted.map(\.x).min()!, accuracy: 0.01)
        XCTAssertEqual(bounds.size.height, tilted.map(\.y).max()! - tilted.map(\.y).min()!, accuracy: 0.01)
    }

    func testTrianglesBlobsAndRepeatedCircuitsStayFreeform() {
        let triangle = polyline([(250, 170), (335, 190), (282, 265), (250, 170)])
        XCTAssertEqual(recognize(jitter(triangle, seed: 19, amplitude: 1)), .area(.freeform))
        let blob = oval(rx: 58, ry: 47) { 1 + 0.28 * cos(3 * $0) + 0.13 * sin(5 * $0) }
        XCTAssertEqual(recognize(jitter(blob, seed: 21, amplitude: 1)), .area(.freeform))
        let circle = oval(rx: 50, ry: 50)
        XCTAssertEqual(recognize(circle + circle.dropFirst()), .area(.freeform))
    }

    func testSmallLoopsNeedDeliberateTravelAndStayFreeform() {
        XCTAssertEqual(recognize(oval(rx: 3, ry: 3)), .area(.freeform))
        XCTAssertEqual(recognize(oval(rx: 2.4, ry: 2.4)), .mark)
        let smallBox = [(200.0, 100.0), (211, 100), (211, 111), (200, 111), (200, 100)]
        XCTAssertEqual(recognize(smallBox), .area(.freeform))
    }

    func testAreaMinimumSpanTravelAndAbsoluteArea() {
        for height in [2.95, 3.05] {
            let ink = polyline([(200, 100), (214, 100), (214, 100 + height),
                                (200, 100 + height), (200, 100)])
            XCTAssertEqual(recognize(jitter(ink, seed: 62, amplitude: 0.006)),
                           height < 3 ? .mark : .area(.freeform))
        }
        for gap in [0.9, 0.7] {
            // The other dimensions yield a 16.8 pt perimeter and a 6.1 pt diagonal.
            let ink = polyline([(200, 100), (205.2, 100), (205.2, 103.2), (200, 103.2), (200, 100 + gap)])
            XCTAssertEqual(recognize(jitter(ink, seed: 52, amplitude: 0.003)),
                           gap > 0.8 ? .mark : .area(.freeform))
        }
        for width in [0.94, 1.06] {
            let ink = polyline([(200, 100), (207, 100), (207, 100.8), (200 + width, 100.8),
                                (200 + width, 103.2), (200, 103.2), (200, 100)])
            XCTAssertEqual(recognize(jitter(ink, seed: 73, amplitude: 0.003)),
                           width < 1 ? .mark : .area(.freeform))
        }
    }

    func testLongThreeSidedStrokesStayOpenButSmallSeamGapsClose() {
        for height in [18.0, 30, 40] {
            let open = polyline([(400, 300), (550, 300), (550, 300 + height), (400, 300 + height)])
            XCTAssertEqual(recognize(jitter(open, seed: 87, amplitude: 0.35)), .mark)
        }
        for height in [20.0, 40, 60, 80] {
            let corners: [XY] = [(400, 100), (550, 100), (550, 100 + height), (400, 100 + height)]
            let gap = min(height - 4, 0.28 * hypot(150, height) - 1)
            let closed = polyline(corners + [(400, 100 + gap)])
            guard case .area(.rectangle) = recognize(jitter(closed, seed: 87, amplitude: 0.15)) else {
                return XCTFail("Expected the small seam gap to close for height \(height)")
            }
            if height >= 60 {
                let open = polyline(corners + [(400, 100 + 0.28 * hypot(150, height) + 1)])
                XCTAssertEqual(recognize(jitter(open, seed: 87, amplitude: 0.15)), .mark)
            }
        }
    }

    func testFreeformAreaRatiosAtOrdinaryAndSlenderCutoffs() {
        for width in [18.0, 19] {
            // A 100 × 80 pt L shape enclosing about 29.3% or 30.1% of its box.
            let ink = polyline([(100, 100), (200, 100), (200, 111), (100 + width, 111),
                                (100 + width, 180), (100, 180), (100, 100)])
            XCTAssertEqual(recognize(jitter(ink, seed: 90, amplitude: 0.025)),
                           width < 19 ? .mark : .area(.freeform))
        }
        for tipHeight in [2.2, 2.6] {
            // A 160 × 24 pt wedge enclosing about 54.6% or 55.4% of its box.
            let ink = polyline([(100, 100), (260, 112 - tipHeight / 2), (260, 112 + tipHeight / 2),
                                (100, 124), (100, 100)])
            XCTAssertEqual(recognize(jitter(ink, seed: 90, amplitude: 0.02)),
                           tipHeight < 2.4 ? .mark : .area(.freeform))
        }
    }

    func testWedgeWithAnAspectBetweenThreeAndFourUsesTheOrdinaryAreaRatio() {
        let wedge = polyline([(100, 100), (206, 115), (100, 130), (100, 100)])
        XCTAssertEqual(recognize(jitter(wedge, seed: 90, amplitude: 0.04)), .area(.freeform))
    }


    func testSmallEllipseToleratesWobbleWithoutTidyingADeepNotch() {
        let radius = 15.0
        for (depth, shouldTidy) in [(2.0, true), (12.0, false)] {
            let notched = oval(rx: radius, ry: radius) { angle in
                let profile = max(0, 1 - abs(angle - .pi / 4) / (.pi / 24))
                return 1 - depth / radius * profile
            }
            assertEllipse(shouldTidy, for: jitter(notched, seed: 25, amplitude: 0.025))
        }
    }

    private func assertEllipse(_ expected: Bool, for ink: [XY], file: StaticString = #filePath, line: UInt = #line) {
        let result = recognize(ink)
        if expected {
            guard case .area(.ellipse) = result else {
                return XCTFail("Expected an ellipse, got \(result)", file: file, line: line)
            }
        } else {
            XCTAssertEqual(result, .area(.freeform), file: file, line: line)
        }
    }

    func testSmallCircleTidyThresholdDoesNotProduceABox() {
        XCTAssertEqual(recognize(oval(rx: 5.95, ry: 5.95)), .area(.freeform))
        for radius in [6.05, 8, 12] {
            guard case .area(.ellipse) = recognize(oval(rx: radius, ry: radius)) else {
                XCTFail("Expected an ellipse at radius \(radius)")
                continue
            }
        }
    }

    func testABriefNotchDoesNotDisappearBetweenFitSamples() {
        let notchedBox: [XY] = [(100, 100), (122, 100), (122, 107), (122, 100),
                                (1000, 100), (1000, 120), (100, 120), (100, 100)]
        XCTAssertEqual(recognize(notchedBox), .area(.freeform))
    }

    func testSmallClosureThresholdStillUsesThePointSpaceDiagonal() {
        let corners: [XY] = [(200, 100), (230, 100), (230, 140), (200, 140)]
        // A 50 pt diagonal allows a 14 pt gap at 28%.
        guard case .area(.rectangle) = recognize(corners + [(200, 113.8)]) else {
            return XCTFail("Expected a box just inside the diagonal limit")
        }
        XCTAssertEqual(recognize(corners + [(200, 114.2)]), .mark)
    }

    func testUnderlinesZigzagsAndScribblesStayPlain() {
        let examples: [[XY]] = [
            [(200, 100), (250, 101), (300, 99), (350, 102)],
            [(200, 100), (330, 110), (220, 116), (335, 129)],
            [(200, 100), (270, 150), (230, 195), (305, 125), (320, 155), (350, 105)],
            // A closed bow tie cancels its enclosed area.
            [(200, 100), (300, 200), (200, 200), (300, 100), (200, 100)]
        ]
        for ink in examples {
            XCTAssertEqual(recognize(ink), .mark)
        }
    }

    func testAreaEdgeStartsRequireClosenessAndAnOutwardDrag() {
        let box = PointRect(origin: Point(x: 200, y: 100), size: Size(width: 120, height: 70))
        let mark = target(.area(.rectangle(box)))
        for start: XY in [(260, 130), (320, 150), (339.9, 150)] {
            XCTAssertEqual(recognize([start, (450, 150)], near: [mark]), .arrow(from: 7, to: nil))
        }
        for ink: [XY] in [[(340.1, 150), (450, 150)], [(204, 96), (380, 96)],
                          [(196, 150), (360, 150)], [(324, 110), (326, 197)]] {
            XCTAssertEqual(recognize(polyline(ink), near: [mark]), .mark)
        }
    }

    func testOutsideAreaMustGainAtLeastHalfTheChordInDistance() {
        let box = PointRect(origin: Point(x: 200, y: 100), size: Size(width: 120, height: 70))
        let mark = target(.area(.rectangle(box)))
        for gain in [25.5, 26.5] {
            let ink = polyline([(196, 105), (196 - gain, 150)])
            XCTAssertEqual(recognize(ink, near: [mark]), gain < 26 ? .mark : .arrow(from: 7, to: nil))
        }
    }

    func testEllipseHitUsesItsCurvedEdgeInFramePoints() {
        let box = PointRect(origin: Point(x: 220, y: 176), size: Size(width: 160, height: 48))
        let mark = target(.area(.ellipse(box)))
        XCTAssertEqual(recognize([(300, 200), (450, 240)], near: [mark]), .arrow(from: 7, to: nil))
        XCTAssertEqual(recognize([(380, 176), (450, 240)], near: [mark]), .mark)
        let angle = Double.pi / 4
        let nx = cos(angle) / 80, ny = sin(angle) / 24
        let norm = hypot(nx, ny)
        let surface = (x: 300 + 80 * cos(angle), y: 200 + 24 * sin(angle))
        for delta in [19.9, 20.1] {
            let start = (surface.x + delta * nx / norm, surface.y + delta * ny / norm)
            XCTAssertEqual(recognize([start, (450, 240)], near: [mark]),
                           delta < 20 ? .arrow(from: 7, to: nil) : .mark)
        }
    }

    func testFreeformAreaInteriorAndEdgeCanSourceArrows() {
        let triangle = target(.area(.freeform), ink: [(200, 100), (340, 100), (270, 200), (203, 102)])
        XCTAssertEqual(recognize([(270, 140), (430, 230)], near: [triangle]), .arrow(from: 7, to: nil))
        XCTAssertEqual(recognize([(210, 190), (430, 230)], near: [triangle]), .mark)
        XCTAssertEqual(recognize([(270, 96), (270, 40)], near: [triangle]), .arrow(from: 7, to: nil))
        XCTAssertEqual(recognize([(270, 79.9), (270, 40)], near: [triangle]), .mark)
        XCTAssertEqual(recognize([(270, 96), (370, 96)], near: [triangle]), .mark)
    }

    func testDeletedAndOpenTargetsAreSkippedAndMostRecentFinishedHitWins() {
        let marks = [target(.pin, id: 1), target(.pin, id: 2),
                     target(.pin, id: 3, deleted: true), target(nil, id: 4, ended: false)]
        let ink: [XY] = [(202, 103), (320, 180)]
        XCTAssertEqual(recognize(ink, near: marks), .arrow(from: 2, to: nil))
        XCTAssertEqual(recognize(ink, near: Array(marks.suffix(2))), .mark)
        XCTAssertEqual(recognize([(202, 103)], near: marks), .pin)
        let loop: [XY] = [(202, 103), (250, 103), (250, 145), (202, 145), (202, 103)]
        guard case .area(.rectangle) = recognize(loop, near: marks) else {
            return XCTFail("A closed box should take precedence over an arrow hit")
        }
    }

    func testPlainAndHeadedStrokesInsideBoxAndOverlappingOval() {
        let box = target(.area(.rectangle(PointRect(origin: Point(x: 100, y: 100),
                                                    size: Size(width: 400, height: 200)))))
        let openInk: [[XY]] = [
            [(180, 150), (330, 151)],
            [(180, 150), (194, 165), (226, 125)],
            [(130, 130), (470, 270)],
            [(400, 150), (519.9, 150)]
        ]
        for ink in openInk { XCTAssertEqual(recognize(polyline(ink), near: [box]), .mark) }
        let headed = polyline([(180, 150), (330, 150), (309, 135)])
        XCTAssertEqual(recognize(headed, near: [box]), .arrow(from: nil, to: nil))
        XCTAssertEqual(recognize([(400, 150), (520.1, 150)], near: [box]), .arrow(from: 7, to: nil))
        guard case .area(.ellipse) = recognize(oval(rx: 40, ry: 20, sweep: 410), near: [box]) else {
            return XCTFail("An overlapping loop inside a box must take precedence")
        }
    }

    func testShortOrIndirectDragsStayPlain() {
        let pin = target(.pin)
        XCTAssertEqual(recognize([(200, 100), (229.9, 100)], near: [pin]), .mark)
        XCTAssertEqual(recognize([(200, 100), (230.1, 100)], near: [pin]), .arrow(from: 7, to: nil))
        for angle in [2.04, 2.06] {
            // A smooth arc with a 100 pt chord crosses the 120 pt travel limit.
            let radius = 50 / sin(angle / 2)
            let ink: [XY] = (0...50).map { step in
                let theta = angle * (Double(step) / 50 - 0.5)
                return (250 + radius * sin(theta), 100 + radius * (cos(theta) - cos(angle / 2)))
            }
            XCTAssertEqual(recognize(ink, near: [pin]), angle < 2.05 ? .arrow(from: 7, to: nil) : .mark)
        }
        XCTAssertEqual(recognize(polyline([(200, 100), (290, 100), (290, 138)]), near: [pin]), .mark)
        XCTAssertEqual(recognize(polyline([(200, 100), (240, 109), (272, 125), (305, 152)]),
                                 near: [pin]), .arrow(from: 7, to: nil))
    }

    func testSeparateStrokesOfDrawingsStayPlainThroughSession() throws {
        let drawings: [(String, [[XY]])] = [
            ("four-sided box", [[(400, 300), (520, 301)], [(521, 303), (520, 380)],
                               [(518, 381), (400, 380)], [(401, 378), (400, 302)]]),
            ("two L strokes", [[(400, 300), (520, 300), (520, 380)],
                               [(402, 302), (400, 380), (518, 381)]]),
            ("T", [[(400, 300), (460, 300)], [(430, 301), (430, 370)]]),
            ("H", [[(400, 300), (400, 370)], [(450, 300), (450, 370)], [(401, 335), (449, 335)]]),
            ("A", [[(430, 300), (400, 370)], [(430, 300), (460, 370)], [(414, 345), (446, 345)]]),
            ("E", [[(400, 300), (400, 370)], [(400, 300), (445, 300)],
                   [(400, 335), (440, 335)], [(400, 370), (445, 370)]]),
            ("X", [[(400, 300), (460, 360)], [(460, 300), (400, 360)]]),
            ("plus", [[(430, 300), (430, 360)], [(400, 330), (460, 330)]])
        ]
        for (name, strokes) in drawings {
            var session = Session()
            let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
            try session.addFrame(frame)
            for (index, stroke) in strokes.enumerated() {
                let length = zip(stroke, stroke.dropFirst()).reduce(0.0) {
                    $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
                }
                let samples = polyline(stroke, samplesPerEdge: max(3, Int(length / 3) / (stroke.count - 1)))
                let ink = jitter(samples, seed: UInt64(index + 25), amplitude: 0.45).map(point)
                let time = Double(index)
                let id = try session.beginStroke(at: time, frame: frame.id, firstPoint: ink[0])
                for sample in ink.dropFirst() { session.append(point: sample, to: id) }
                session.endStroke(id: id, at: time + 0.5)
            }
            XCTAssertEqual(session.strokes.map(\.shape), Array(repeating: .mark, count: strokes.count), name)
        }
    }

    func testPlainInkAndArrowShaftsCannotSourceArrows() {
        let underline = target(.mark, ink: [(200, 100), (360, 101)])
        let legacy = target(nil, ink: [(200, 100), (360, 101)])
        let arrow = target(.arrow(from: 1, to: nil), ink: [(320, 140), (550, 240)])
        for mark in [underline, legacy] {
            XCTAssertEqual(recognize([(280, 101), (280, 180)], near: [mark]), .mark)
            XCTAssertEqual(recognize([(363, 102), (395, 156)], near: [mark]), .mark)
        }
        XCTAssertEqual(recognize([(430, 188), (430, 120)], near: [arrow]), .mark)
        XCTAssertEqual(recognize([(555, 246), (650, 247)], near: [arrow]), .mark)

        let destination = target(.area(.rectangle(PointRect(origin: Point(x: 500, y: 200),
                                                            size: Size(width: 100, height: 80)))), id: 8)
        XCTAssertEqual(recognize([(555, 246), (650, 347)], near: [destination, arrow]), .arrow(from: 8, to: nil))
    }

    func testUnderlinesStrikeThroughAndTicksNearShapesStayPlain() {
        let circledWord = oval(rx: 35, ry: 13, sweep: 372)
        let boxInk = polyline([(400, 290), (560, 290), (560, 312), (400, 312), (400, 291)])
        let specimens: [([XY], [[XY]])] = [
            (circledWord, [[(280, 218), (470, 219)], [(235, 218), (470, 219)]]),
            (boxInk, [[(402, 321), (640, 322)], [(402, 332), (640, 333)],
                      [(392, 301), (585, 302)], [(568, 301), (580, 316), (610, 263)]]),
            ([(500, 200)], [[(492, 200), (504, 215), (534, 162)],
                            [(494, 200), (506, 215), (536, 162)]])
        ]
        for (source, strokes) in specimens {
            let shape = recognize(source)
            XCTAssertNotEqual(shape, .mark)
            for (index, stroke) in strokes.enumerated() {
                let ink = jitter(polyline(stroke), seed: UInt64(index + 27), amplitude: 0.35)
                XCTAssertEqual(recognize(ink, near: [target(shape, ink: source)]), .mark, "\(stroke)")
            }
        }
    }

    func testSmallestContainingMarkWinsInEitherDrawingOrder() {
        let circle = target(.area(.ellipse(PointRect(origin: Point(x: 220, y: 130),
                                                       size: Size(width: 60, height: 60)))), id: 1)
        let box = target(.area(.rectangle(PointRect(origin: Point(x: 100, y: 80),
                                                       size: Size(width: 250, height: 180)))), id: 2)
        for marks in [[circle, box], [box, circle]] {
            XCTAssertEqual(recognize([(250, 160), (420, 270)], near: marks), .arrow(from: 1, to: nil))
            XCTAssertEqual(recognize([(282, 160), (420, 270)], near: marks), .arrow(from: 1, to: nil))
            XCTAssertEqual(recognize([(250, 160), (261, 195)], near: marks), .mark)
            XCTAssertEqual(recognize([(250, 160), (310, 195)], near: marks), .arrow(from: 1, to: nil))
        }
    }

    func testNearestOutlineWinsOutsideTwoAdjacentBoxes() {
        let left = target(.area(.rectangle(PointRect(origin: Point(x: 100, y: 80),
                                                     size: Size(width: 100, height: 80)))), id: 1)
        let right = target(.area(.rectangle(PointRect(origin: Point(x: 208, y: 80),
                                                      size: Size(width: 100, height: 80)))), id: 2)
        XCTAssertEqual(recognize([(203, 155), (203, 190)], near: [left, right]), .arrow(from: 1, to: nil))
        XCTAssertEqual(recognize([(205, 155), (205, 190)], near: [right, left]), .arrow(from: 2, to: nil))
    }

    func testSmallerFootprintBreaksAnEqualOutlineDistanceInEitherOrder() {
        let small = target(.area(.rectangle(PointRect(origin: Point(x: 200, y: 100),
                                                        size: Size(width: 60, height: 40)))), id: 1)
        let large = target(.area(.rectangle(PointRect(origin: Point(x: 200, y: 80),
                                                        size: Size(width: 160, height: 80)))), id: 2)
        for marks in [[small, large], [large, small]] {
            XCTAssertEqual(recognize([(205, 120), (130, 120)], near: marks), .arrow(from: 1, to: nil))
        }
    }

    func testPinBadgeHitIncludesRightEdgeAndFlipsNearFrameEdge() {
        let pin = target(.pin, ink: [(200, 100)])
        for start: XY in [(216, 100), (225.9, 109.9)] {
            XCTAssertEqual(recognize([start, (310, 180)], near: [pin]), .arrow(from: 7, to: nil))
        }
        XCTAssertEqual(recognize([(226.1, 100), (310, 180)], near: [pin]), .mark)
        XCTAssertEqual(recognize([(220, 100), (200, 110), (215, 101)], near: [pin]), .mark)
        let edgePin = target(.pin, ink: [(1590, 4)])
        XCTAssertEqual(recognize([(1570, 17), (1450, 80)], near: [edgePin]), .arrow(from: 7, to: nil))
    }

    func testPassingBackThroughEarlyInkClosesTheLoop() {
        for sweep in [332.0, 325, 310, 360, 395, 420, 449, 503] {
            let ink = oval(rx: 40, ry: 40, sweep: sweep)
            if sweep == 310 {
                XCTAssertEqual(recognize(ink), .mark)
            } else {
                guard case .area(.ellipse(let box)) = recognize(ink) else {
                    XCTFail("Expected a tidy circle after sweeping \(sweep) degrees")
                    continue
                }
                XCTAssertEqual(box.size.width, 80, accuracy: 0.4)
                XCTAssertEqual(box.size.height, 80, accuracy: 0.4)
            }
        }
        XCTAssertEqual(recognize(oval(rx: 40, ry: 40, sweep: 507)), .area(.freeform))
    }

    func testLoopOverlapRespectsOnePointFourTurnLimit() {
        let inside = jitter(oval(rx: 40, ry: 40, sweep: 468), seed: 51, amplitude: 0.14)
        let outside = jitter(oval(rx: 40, ry: 40, sweep: 530), seed: 51, amplitude: 0.14)
        assertEllipse(true, for: inside)
        XCTAssertEqual(recognize(outside), .area(.freeform))
    }


    func testSlenderTiltedOvalsTidyAcrossAspectRatios() {
        for tilt in [0.0, 3, 7, 9, -9] {
            for (rx, ry) in [(150.0, 20.0), (20.0, 150)] {
                let ink = jitter(oval(rx: rx, ry: ry, rotation: tilt * .pi / 180), seed: 19, amplitude: 0.3)
                assertEllipse(true, for: ink)
            }
        }
    }


    func testNearlyRoundOvalsTidyAcrossTheFormerTiltLimit() {
        for tilt in [9.0, 12] {
            let ink = jitter(oval(rx: 48, ry: 25, rotation: tilt * .pi / 180), seed: 93, amplitude: 0.15)
            assertEllipse(true, for: ink)
        }
    }

    func testOvalsWithWeakAndClearMajorAxesBothTidy() {
        assertEllipse(true, for: jitter(oval(rx: 31, ry: 26, rotation: 24 * .pi / 180),
                                        seed: 38, amplitude: 0.12))
        assertEllipse(true, for: jitter(oval(rx: 36, ry: 24, rotation: 13 * .pi / 180),
                                         seed: 38, amplitude: 0.12))
    }

    func testClosingSegmentCountsTowardAngularTravel() {
        let gappedCircle = oval(rx: 40, ry: 40, sweep: 335)
        let ink = Array(gappedCircle[...40]) + Array(gappedCircle[17..<40].reversed()) + gappedCircle[18...]
        // The backwards leg adds about 160°. Ink alone stays below 504°.
        // Including the closing edge takes it above that limit.
        XCTAssertEqual(recognize(jitter(ink, seed: 52, amplitude: 0.12)), .area(.freeform))
    }

    func testShortExitHooksDoNotInflateTidiedBounds() {
        for (width, height) in [(120.0, 80.0), (220, 40)] {
            for spur in [6.0, 10.0, 14.0] {
                let path = polyline([(400, 225), (400 + width, 225), (400 + width, 225 + height),
                                     (400, 225 + height), (400, 225 - spur)], samplesPerEdge: 30)
                let ink = jitter(path, seed: 73, amplitude: 0.2)
                guard case .area(.rectangle(let box)) = recognize(ink) else {
                    XCTFail("Expected a rectangle with a \(spur) pt exit hook")
                    continue
                }
                XCTAssertEqual(box.origin.y, 225, accuracy: 2)
                XCTAssertEqual(box.size.height, height, accuracy: 2)
            }
        }
        let loop = oval(rx: 40, ry: 40)
        for spur in [6.0, 10.0, 14.0] {
            let tail = polyline([(340, 200), (340 + spur, 200 - spur / 3)])
            let ink = jitter(loop + tail.dropFirst(), seed: 45, amplitude: 0.2)
            guard case .area(.ellipse(let box)) = recognize(ink) else {
                XCTFail("Expected a circle with a \(spur) pt exit hook")
                continue
            }
            XCTAssertEqual(box.size.width, 80, accuracy: 2)
        }
        let longExit = polyline([(340, 200), (372, 189)])
        // The roughly 34 pt exit strays over 24 pt from the 80 pt loop.
        XCTAssertEqual(recognize(jitter(loop + longExit.dropFirst(), seed: 45, amplitude: 0.2)), .area(.freeform))
    }

    func testNearMissExitAndLeadInHooksUseTheLoopBounds() {
        for miss in [1.5, 3.5] {
            for leadIn in [false, true] {
                var ink = polyline([(400, 225), (520, 225), (520, 305),
                                    (400 - miss, 305), (400 - miss, 213)], samplesPerEdge: 40)
                if leadIn { ink.reverse() }
                guard case .area(.rectangle(let box)) = recognize(ink) else {
                    XCTFail("Expected a box with a near-miss hook, miss=\(miss), leadIn=\(leadIn)")
                    continue
                }
                XCTAssertEqual(box.origin.y, 225, accuracy: 1)
                XCTAssertEqual(box.size.height, 80, accuracy: 1)
            }
        }
    }


    func testLeadInsAndOvershootsKeepInkBeyondTheLoopMargin() {
        let circle = oval(rx: 40, ry: 40)
        for length in [23.0, 32, 135, 300] {
            let tail = polyline([(340, 200), (340 + length, 200 - length / 3)])
            let stroke = circle + tail.dropFirst()
            for ink in [stroke, Array(stroke.reversed())] {
                let shape = recognize(ink)
                if length > 23 {
                    XCTAssertEqual(shape, .area(.freeform), "Keep the \(length) pt tail")
                } else if case .area(.ellipse(let bounds)) = shape {
                    XCTAssertEqual(bounds.size.width, 80, accuracy: 2)
                } else {
                    XCTFail("Expected an ellipse with a short tail")
                }
            }
        }
    }

    func testSlenderOvalUsesFrameBoundsAfterTilt() {
        for (rx, ry) in [(150.0, 20.0), (20.0, 150.0)] {
            let ink = oval(rx: rx, ry: ry, rotation: 5.5 * .pi / 180)
            guard case .area(.ellipse(let bounds)) = recognize(ink) else { return XCTFail("Expected an oval") }
            XCTAssertEqual(bounds.size.width, ink.map(\.x).max()! - ink.map(\.x).min()!, accuracy: 0.01)
            XCTAssertEqual(bounds.size.height, ink.map(\.y).max()! - ink.map(\.y).min()!, accuracy: 0.01)
        }
    }

    func testArrowTipCannotEndInsideItsSourcePinBadge() {
        let pin = target(.pin, ink: [(200, 100)])
        // A direct 32 pt drag clears the dot by >12 pt but ends on its badge.
        XCTAssertEqual(recognize([(196, 100), (226, 110)], near: [pin]), .mark)
        XCTAssertEqual(recognize([(196, 100), (227, 111)], near: [pin]), .arrow(from: 7, to: nil))
    }

    func testPinBadgeStartDoesNotNeedOutwardGainFromTheDot() {
        let pin = target(.pin, ink: [(200, 100)])
        // Starts on the badge, crosses above the dot and gains less than half
        // the chord in distance from it. Badge starts are source hits.
        XCTAssertEqual(recognize([(225, 109), (190, 73)], near: [pin]), .arrow(from: 7, to: nil))
    }

    func testSlenderRetracesAndScribbleOutsStayPlain() {
        let ink: [[XY]] = [
            [(200, 100), (300, 105), (200, 110), (300, 115), (200, 120)],
            [(200, 100), (350, 102), (200, 104)]
        ]
        for stroke in ink {
            XCTAssertEqual(recognize(polyline(stroke)), .mark)
            XCTAssertEqual(recognize(polyline(Array(stroke.reversed()))), .mark)
        }
    }

    func testConcaveLoopsOpenArcAndTwoTurnSpiralStayUntidied() {
        let ell = polyline([(100, 100), (230, 100), (230, 135), (135, 135),
                            (135, 230), (100, 230), (100, 100)])
        let vertices = (0..<10).map { index -> XY in
            let angle = Double(index) * .pi / 5
            let radius = index.isMultiple(of: 2) ? 60.0 : 25.0
            return (350 + radius * cos(angle), 150 + radius * sin(angle))
        }
        let star = polyline(vertices + [vertices[0]])
        for ink in [ell, star] {
            XCTAssertEqual(recognize(ink), .area(.freeform))
        }

        // The missing chord is 40% of the circular bounds' diagonal.
        let missingAngle = 2 * asin(0.4 * sqrt(2.0)) * 180 / .pi
        XCTAssertEqual(recognize(oval(rx: 60, ry: 60, sweep: 360 - missingAngle)), .mark)
        let spiral = oval(rx: 80, ry: 80, sweep: 720) { 1 - 0.55 * $0 / (4 * .pi) }
        switch recognize(spiral) {
        case .mark, .area(.freeform): break
        default: XCTFail("A two-turn spiral should retain its ink")
        }
    }

    func testArrowCanPointAtOrBetweenMarks() {
        let left = target(.area(.rectangle(PointRect(origin: Point(x: 100, y: 100),
                                                     size: Size(width: 100, height: 80)))), id: 1)
        let right = target(.area(.rectangle(PointRect(origin: Point(x: 350, y: 100),
                                                      size: Size(width: 100, height: 80)))), id: 2)
        let marks = [left, right]
        XCTAssertEqual(recognize([(280, 140), (330.1, 140)], near: marks), .arrow(from: nil, to: 2))
        XCTAssertEqual(recognize([(280, 140), (329.9, 140)], near: marks), .mark)
        XCTAssertEqual(recognize([(219.9, 140), (330.1, 140)], near: marks), .arrow(from: 1, to: 2))
        XCTAssertEqual(recognize([(330.1, 140), (219.9, 140)], near: marks), .arrow(from: 2, to: 1))
        XCTAssertEqual(recognize([(120, 190), (180, 190)], near: marks), .mark)
    }

    func testSeparateHeadPromotesAndUndoRestoresPlainShaftAfterReload() throws {
        var session = Session()
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
        try session.addFrame(frame)
        func draw(_ ink: [XY], at time: Double) throws -> MarkID {
            let id = try session.beginStroke(at: time, frame: frame.id, firstPoint: point(ink[0]))
            for sample in ink.dropFirst() { session.append(point: point(sample), to: id) }
            session.endStroke(id: id, at: time + 0.5)
            return id
        }
        let shaft = try draw([(400, 300), (550, 300)], at: 0)
        let original = session
        let head = [(530.0, 286.0), (550.0, 300.0), (530.0, 314.0)]
        for (ink, time) in [(head, 3.51), (head.map { ($0.0 + 45, $0.1) }, 1),
                            ([(515.0, 235.0), (550.0, 300.0), (515.0, 365.0)], 1),
                            ([(570.0, 286.0), (550.0, 300.0), (570.0, 314.0)], 1)] {
            _ = try draw(ink, at: time)
            XCTAssertEqual(session.liveMarks.count, 2)
            XCTAssertEqual(session.strokes[0].shape, .mark)
            session = original
        }
        let absorbed = try draw(head, at: 3.5)
        XCTAssertEqual(session.liveMarks.map(\.id), [shaft])
        XCTAssertEqual(session.liveMarks.first?.shape, .arrow(from: nil, to: nil))
        XCTAssertEqual(session.strokes.last?.absorbedInto, shaft)
        XCTAssertLessThan(try XCTUnwrap(session.strokes.last?.id.rawValue), 0)
        XCTAssertEqual(session.strokes.last?.points, head.map(point))
        let aligner = Aligner.place(words: [], strokes: session.strokes)
        XCTAssertEqual(TranscriptRenderer.render(tokens: aligner), "[1]")

        var reloaded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        reloaded.undoLatestMark(in: [frame.id])
        XCTAssertEqual(reloaded.liveMarks.map(\.id), [shaft])
        XCTAssertEqual(reloaded.liveMarks.first?.shape, .mark)
        XCTAssertTrue(reloaded.strokes.last?.isDeleted == true)
        XCTAssertEqual(reloaded.nextMarkNumber, absorbed.rawValue)
        reloaded.undoLatestMark(in: [frame.id])
        XCTAssertTrue(reloaded.liveMarks.isEmpty)
    }

    func testTightEndHookMakesAnUnlinkedArrowAndKeepsRawInk() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
        var session = Session()
        try session.addFrame(frame)
        let ink = [(100.0, 100.0), (230, 100), (217, 88), (222, 99)].map(point)
        let id = try session.beginStroke(at: 0, frame: frame.id, firstPoint: ink[0])
        for sample in ink.dropFirst() { session.append(point: sample, to: id) }
        session.endStroke(id: id, at: 1)
        let arrow = try XCTUnwrap(session.liveMarks.first)
        XCTAssertEqual(arrow.shape, .arrow(from: nil, to: nil))
        XCTAssertEqual(arrow.points, ink)
        XCTAssertEqual(Array(arrow.renderedPoints), Array(ink.prefix(2)))
    }

    func testTwoBarbsAtShaftStartReverseArrowAndReuseNumber() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
        var session = Session()
        try session.addFrame(frame)
        func draw(_ ink: [XY], at time: Double) throws -> MarkID {
            let id = try session.beginStroke(at: time, frame: frame.id, firstPoint: point(ink[0]))
            for sample in ink.dropFirst() { session.append(point: point(sample), to: id) }
            session.endStroke(id: id, at: time + 0.5)
            return id
        }

        let pin = try draw([(300, 300)], at: 0)
        let shaft = try draw([(300, 300), (500, 300)], at: 1)
        XCTAssertEqual(session.liveMarks.last?.shape, .arrow(from: pin, to: nil))
        let first = try draw([(300, 300), (322, 288)], at: 3)
        XCTAssertEqual(session.liveMarks.last?.shape, .arrow(from: nil, to: pin))
        XCTAssertEqual(session.liveMarks.last?.shaftReversed, true)
        let afterFirst = session
        let second = try draw([(322, 312), (300, 300)], at: 5.5)
        XCTAssertEqual(first, second)
        XCTAssertEqual(session.liveMarks.map(\.id), [pin, shaft])
        XCTAssertEqual(session.strokes.suffix(2).map(\.absorbedInto), [shaft, shaft])
        let next = try draw([(700, 500)], at: 7)
        XCTAssertEqual(next, first)
        XCTAssertEqual(Set(session.strokes.map(\.id)).count, 5)

        var reloaded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(afterFirst))
        let arrow = try XCTUnwrap(reloaded.liveMarks.last)
        let record = StrokeRecording.Record(stroke: arrow, frame: frame)
        XCTAssertEqual(record.shaftReversed, true)
        XCTAssertEqual(try XCTUnwrap(record.shaftEnd).x, 300, accuracy: 0.01)
        reloaded.undoLatestMark(in: [frame.id])
        XCTAssertEqual(reloaded.liveMarks.last?.shape, .arrow(from: pin, to: nil))
        XCTAssertNil(reloaded.liveMarks.last?.shaftReversed)
    }

    func testAbsorbedNumberCanBeReusedAfterAnOverlappingPenDown() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
        var session = Session()
        try session.addFrame(frame)
        let shaft = try session.beginStroke(at: 0, frame: frame.id, firstPoint: point((300, 300)))
        session.append(point: point((500, 300)), to: shaft)
        session.endStroke(id: shaft, at: 1)
        let head = try session.beginStroke(at: 2, frame: frame.id, firstPoint: point((480, 285)))
        let other = try session.beginStroke(at: 2.5, frame: frame.id, firstPoint: point((700, 500)))
        session.append(point: point((500, 300)), to: head)
        session.append(point: point((480, 315)), to: head)
        session.endStroke(id: head, at: 3)
        session.endStroke(id: other, at: 3.5)
        XCTAssertEqual(session.liveMarks.map(\.id), [shaft, other])

        var reloaded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(reloaded.nextMarkNumber, head.rawValue)
        let reclaimed = try reloaded.beginStroke(at: 4, frame: frame.id, firstPoint: point((700, 550)))
        XCTAssertEqual(reclaimed, head)
        XCTAssertEqual(reloaded.nextMarkNumber, other.rawValue + 1)
    }

    func testLaterPinsRelinkOnlyFreeEndsInTheirFrame() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
        let other = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
        var session = Session()
        try session.addFrame(frame)
        try session.addFrame(other)
        func draw(_ ink: [XY], in frame: Frame, at time: Double) throws -> MarkID {
            let id = try session.beginStroke(at: time, frame: frame.id, firstPoint: point(ink[0]))
            for sample in ink.dropFirst() { session.append(point: point(sample), to: id) }
            session.endStroke(id: id, at: time + 0.5)
            return id
        }

        let arrow = try draw([(300, 300), (500, 300), (480, 285)], in: frame, at: 0)
        XCTAssertEqual(session.liveMarks.first?.shape, .arrow(from: nil, to: nil))
        _ = try draw([(540, 300)], in: other, at: 1)
        XCTAssertEqual(session.liveMarks.first?.shape, .arrow(from: nil, to: nil))
        let from = try draw([(300, 300)], in: frame, at: 2)
        let to = try draw([(540, 300)], in: frame, at: 3)
        _ = try draw([(501, 300)], in: frame, at: 4)
        XCTAssertEqual(session.liveMarks.first?.id, arrow)
        XCTAssertEqual(session.liveMarks.first?.shape, .arrow(from: from, to: to))
    }

    func testFullHeadKeepsLinkAndShortFlickStaysPlain() {
        let pin = target(.pin)
        let full: [XY] = [(200, 100), (350, 100), (324, 85), (350, 100), (324, 115)]
        XCTAssertEqual(recognize(polyline(full), near: [pin]), .arrow(from: 7, to: nil))
        XCTAssertEqual(recognize(polyline([(200, 100), (400, 100), (391, 97)])), .mark)
    }

    func testInvalidOrEmptyInkStaysPlain() {
        XCTAssertEqual(recognize([]), .mark)
        XCTAssertEqual(recognize([(200, 100), (.infinity, 102)]), .mark)
        XCTAssertEqual(ShapeRecognizer.recognize(points: [point((200, 100))],
                                                frameSize: Size(width: 0, height: 400), existingMarks: []), .mark)
    }

    // Fable re-check N1: tip look-ahead must not turn a plain underline into an arrow.
    func testPlainLineEndingShortOfABoxStaysALine() {
        let box = target(.area(.rectangle(PointRect(origin: Point(x: 400, y: 280), size: Size(width: 100, height: 60)))),
                         id: 1, ink: [(400, 280)])
        for gap in [25.0, 40, 60] {
            XCTAssertEqual(recognize(polyline([(100, 310), (400 - gap, 310)]), near: [box]), .mark, "gap \(gap)")
        }
    }

    // Fable re-check N2: an arrow whose target was undone links to the redrawn target.
    func testArrowRelinksToARedrawnTargetAfterUndo() throws {
        let frame = Frame(id: Frame.ID(), displayID: 1, boundsInPoints: frameSize)
        var session = Session()
        try session.addFrame(frame)
        func draw(_ ink: [XY], at time: Double) throws -> MarkID {
            let id = try session.beginStroke(at: time, frame: frame.id, firstPoint: point(ink[0]))
            for sample in ink.dropFirst() { session.append(point: point(sample), to: id) }
            session.endStroke(id: id, at: time + 0.5)
            return id
        }
        let pin = try draw([(100, 200)], at: 0)
        let shaft = try draw(polyline([(100, 200), (240, 200)]), at: 1)
        let circle = try draw(oval(rx: 25, ry: 25), at: 5)
        XCTAssertEqual(session.liveMarks.first { $0.id == shaft }?.shape, .arrow(from: pin, to: circle))
        session.undoLatestMark(in: [frame.id])
        let redrawn = try draw(oval(rx: 25, ry: 25), at: 9)
        XCTAssertEqual(session.liveMarks.first { $0.id == shaft }?.shape, .arrow(from: pin, to: redrawn))
    }
}
