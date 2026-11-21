import XCTest
@testable import PilcrowCore

/// Synthetic mouse/trackpad outlines. Seeds, sizes and seams are fixed so rates
/// describe this corpus, not an estimate of live drawing success.
final class ShapeCalibrationTests: XCTestCase {
    private struct RNG {
        var state: UInt64
        mutating func value(_ low: Double, _ high: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return low + (high - low) * Double(state >> 11) / Double(UInt64.max >> 11)
        }
    }
    private typealias XY = (x: Double, y: Double)
    private func classify(_ ink: [XY]) -> String {
        let shape = ShapeRecognizer.recognize(points: ink.map { NormalizedPoint(x: $0.x / 1000, y: $0.y / 800) },
                                              frameSize: Size(width: 1000, height: 800), existingMarks: [])
        switch shape {
        case .area(.ellipse): return "ellipse"
        case .area(.rectangle): return "rectangle"
        case .area(.freeform): return "freeform"
        default: return "mark"
        }
    }
    func testSeededShapeClasses() {
        for kind in ["triangle", "blob", "three sides", "scribble", "rotated oval", "rotated box"] {
            var tidy = 0
            for seed in 0..<100 {
                var rng = RNG(state: UInt64(seed + 91))
                let width = rng.value(120, 320), height = rng.value(60, 140)
                var ink: [XY]
                switch kind {
                case "triangle": ink = [(0, 0), (width, height / 3), (width / 3, height), (0, 0)]
                case "three sides": ink = [(0, 0), (width, 0), (width, height), (0, height)]
                case "scribble": ink = (0...8).map { (Double($0 % 2) * width, Double($0) * height / 8) }
                case "blob": ink = (0...120).map { i in
                    let a = Double(i) * 2 * .pi / 120
                    let r = 1 + 0.28 * cos(3 * a) + 0.13 * sin(5 * a)
                    return (width / 2 * cos(a) * r, height / 2 * sin(a) * r)
                }
                case "rotated oval": ink = (0...120).map { i in
                    let a = Double(i) * 2 * .pi / 120
                    return (width / 2 * cos(a), width / 5 * sin(a))
                }
                default: ink = [(0, 0), (width, 0), (width, height), (0, height), (0, 0)]
                }
                let rotation = kind.hasPrefix("rotated") ? rng.value(18, 40) * .pi / 180 : 0
                let transformed = ink.map { p -> XY in
                    (350 + p.x * cos(rotation) - p.y * sin(rotation) + rng.value(-0.6, 0.6),
                     200 + p.x * sin(rotation) + p.y * cos(rotation) + rng.value(-0.6, 0.6))
                }
                let result = classify(transformed)
                if result == "ellipse" || result == "rectangle" { tidy += 1 }
            }
            print("CALIBRATION \(kind): tidy=\(tidy)/100")
            XCTAssertEqual(tidy, kind.hasPrefix("rotated") ? 100 : 0, kind)
        }
    }
}
