import XCTest
@testable import PilcrowCore

/// Retains the reviewer's rv2/Helpers.swift thin-box generator and its seeds,
/// so the new smooth rounded corpus cannot hide that earlier failure mode.
final class ShapeReviewerCalibrationTests: XCTestCase {
    private typealias XY = (x: Double, y: Double)
    struct RNG { var s: UInt64
        mutating func u() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
        mutating func r(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
        mutating func g() -> Double { (u() + u() + u() + u() - 2) * 1.732 } }
    private func densify(_ v: [XY], step: Double = 4) -> [XY] {
        var out: [XY] = []
        for (a, b) in zip(v, v.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for i in 0..<n { let t = Double(i) / Double(n); out.append((a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)) }
        }
        out.append(v.last!); return out
    }
    /// low-frequency hand tremor: smooth noise of amplitude amp added along the path
    private func tremor(_ ink: [XY], amp: Double, rng: inout RNG) -> [XY] {
        let p1 = rng.r(0, 6.28), p2 = rng.r(0, 6.28), p3 = rng.r(0, 6.28), p4 = rng.r(0, 6.28)
        let f1 = rng.r(0.02, 0.05), f2 = rng.r(0.05, 0.11)
        var out: [XY] = []
        for (i, p) in ink.enumerated() {
            let t = Double(i)
            out.append((p.x + amp * (0.7 * sin(f1 * t + p1) + 0.3 * sin(f2 * t + p2)), p.y + amp * (0.7 * sin(f1 * t + p3) + 0.3 * sin(f2 * t + p4))))
        }
        return out
    }
    private func handBox(w: Double, h: Double, err: Double, rng: inout RNG) -> [XY] {
        let x = 400.0, y = 300.0
        var c: [XY] = []
        for p in [(x, y), (x + w, y), (x + w, y + h), (x, y + h)] as [XY] { c.append((p.x + err * rng.g(), p.y + err * rng.g())) }
        let closure: XY = (c[0].x + err * rng.g() + rng.r(-6, 10), c[0].y + err * rng.g())
        let overshoot = closure.x > c[0].x
        var v: [XY] = [c[0]]
        for i in 1..<4 {
            let p = c[i - 1], q = c[i], n = c[(i + 1) % 4]
            let rd = min(rng.r(1, 2.5) * err, h / 3)
            let d1 = hypot(q.x - p.x, q.y - p.y), d2 = hypot(n.x - q.x, n.y - q.y)
            let a: XY = (q.x + (p.x - q.x) * rd / d1, q.y + (p.y - q.y) * rd / d1)
            let b: XY = (q.x + (n.x - q.x) * rd / d2, q.y + (n.y - q.y) * rd / d2)
            v.append(a)
            for k in 1..<4 { let t = Double(k) / 4
                v.append(((1 - t) * (1 - t) * a.x + 2 * t * (1 - t) * q.x + t * t * b.x, (1 - t) * (1 - t) * a.y + 2 * t * (1 - t) * q.y + t * t * b.y)) }
            v.append(b)
        }
        if overshoot {
            v.append(c[0])
            v.append(closure)
        } else {
            v.append((closure.x, c[0].y + rng.r(2, 8)))
        }
        return tremor(densify(v, step: 3), amp: err * 0.4, rng: &rng)
    }
    func testReviewerThinBoxesAtTwoPointCornerNoise() {
        var rectangles = 0
        for trial in 0..<300 {
            var rng = RNG(s: UInt64(trial * 104729 + 7))
            let ink = handBox(w: 300, h: 24, err: 2, rng: &rng)
            let shape = ShapeRecognizer.recognize(points: ink.map { NormalizedPoint(x: $0.x / 1512, y: $0.y / 982) },
                frameSize: Size(width: 1512, height: 982), existingMarks: [])
            if case .area(.rectangle) = shape { rectangles += 1 }
        }
        print("CALIBRATION reviewer thin boxes, 2 pt corner noise: rectangle=\(rectangles)/300")
        XCTAssertGreaterThanOrEqual(rectangles, 138)
    }
}
