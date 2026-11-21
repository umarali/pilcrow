import Foundation

/// Classifies completed ink without changing its recorded points.
public enum ShapeRecognizer {
    public static let version = "d28-forgiving-v2"
    private static let arrowMargin = 20.0
    private static let straightnessLimit = 1.2
    private static let minimumShaftLength = 30.0
    private static let loopSamples = 160
    private static let bendWindow = 10.0

    struct Recognition {
        var shape: MarkShape
        var shaftPointCount: Int? = nil
    }

    /// Supply marks from this frame in drawing order. That order breaks ties between hits.
    public static func recognize(points: [NormalizedPoint], frameSize: Size, existingMarks: [Stroke]) -> MarkShape {
        classify(points: points, frameSize: frameSize, existingMarks: existingMarks).shape
    }

    static func classify(points: [NormalizedPoint], frameSize: Size, existingMarks: [Stroke]) -> Recognition {
        guard let ink = framePoints(points, size: frameSize) else { return Recognition(shape: .mark) }
        return classify(framePoints: ink, frameSize: frameSize, existingMarks: existingMarks)
    }

    // Replay uses stored frame points directly, without a divide/multiply round trip.
    static func classify(framePoints ink: [Point], frameSize: Size, existingMarks: [Stroke]) -> Recognition {
        guard frameSize.width.isFinite, frameSize.width > 0,
              frameSize.height.isFinite, frameSize.height > 0,
              ink.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = ink.first else { return Recognition(shape: .mark) }
        let box = bounds(of: ink, first: first)
        let diagonal = hypot(box.size.width, box.size.height)
        guard diagonal.isFinite else { return Recognition(shape: .mark) }
        if diagonal <= 6 { return Recognition(shape: .pin) }

        let offsets = pathOffsets(ink)
        guard let length = offsets.last, length.isFinite else { return Recognition(shape: .mark) }
        let canEncloseArea = min(box.size.width, box.size.height) >= 3 && length >= 16
        if canEncloseArea {
            let interval = closedInterval(in: ink, offsets: offsets, length: length, box: box)
            if let area = recognizeArea(ink, offsets: offsets, interval: interval) {
                return Recognition(shape: .area(area))
            }
        }

        let bend = firstSharpBend(in: ink, offsets: offsets)
        let head = hookTip(in: ink, offsets: offsets, length: length, firstBend: bend)
        // A tiny loop at the end of a hook should not swallow a headed arrow.
        if head == nil, canEncloseArea,
           let interval = loopWithLongTail(in: ink, offsets: offsets, length: length),
           let area = recognizeArea(ink, offsets: offsets, interval: interval, preservingTailOnly: true) {
            return Recognition(shape: .area(area))
        }

        let tipIndex = head ?? ink.count - 1
        guard isShaft(from: first, to: ink[tipIndex], length: offsets[tipIndex]),
              head != nil || bend == nil else { return Recognition(shape: .mark) }
        let shape = arrow(in: ink, offsets: offsets, tipIndex: tipIndex,
                          near: existingMarks, size: frameSize, hasHead: head != nil)
        if case .arrow = shape {
            return Recognition(shape: shape, shaftPointCount: head.map { $0 + 1 })
        }
        return Recognition(shape: .mark)
    }

    private static func recognizeArea(_ original: [Point], offsets: [Double],
                                      interval: ClosedRange<Double>?, preservingTailOnly: Bool = false) -> MarkShape.Area? {
        let loop = interval.map { clip(original, offsets: offsets, to: $0) } ?? original
        let loopBox = bounds(of: loop, first: loop[0])
        let shortSide = min(loopBox.size.width, loopBox.size.height)
        let diagonal = hypot(loopBox.size.width, loopBox.size.height)
        let gap = distance(loop[0], loop[loop.count - 1])
        let loopOffsets = pathOffsets(loop)
        guard shortSide >= 3, let loopLength = loopOffsets.last, loopLength >= 16,
              gap <= 0.28 * diagonal else { return nil }
        if gap > 0.55 * shortSide, isMissingSide(loop, offsets: loopOffsets, length: loopLength, span: shortSide) {
            return nil
        }

        let closed = loop + [loop[0]]
        let closedOffsets = loopOffsets + [loopLength + gap]
        let perimeter = loopLength + gap
        guard perimeter.isFinite else { return nil }
        let sampleCount = Int(min(1024, max(Double(loopSamples), 6 * (perimeter / shortSide))))
        let samples = Array(resample(closed, offsets: closedOffsets, length: perimeter,
                                     count: sampleCount).dropLast())
        let center = Point(x: loopBox.origin.x + loopBox.size.width / 2,
                           y: loopBox.origin.y + loopBox.size.height / 2)
        let tilt = ellipseTilt(samples, in: loopBox)
        let cosine = cos(tilt), sine = sin(tilt)
        let oriented = loop.map { point in
            let x = point.x - center.x, y = point.y - center.y
            return Point(x: x * cosine + y * sine, y: y * cosine - x * sine)
        }
        let orientedBox = bounds(of: oriented, first: oriented[0])
        let scale = max(loopBox.size.width, loopBox.size.height)
        let frameArea = loopBox.size.width / scale * (loopBox.size.height / scale)
        let orientedArea = orientedBox.size.width / scale * (orientedBox.size.height / scale)
        let useOrientedBox = orientedBox.isValid && orientedArea < frameArea
        guard enclosesArea(useOrientedBox ? oriented : loop, box: useOrientedBox ? orientedBox : loopBox) else { return nil }

        let circuit = angularTravel(closed, around: center)
        let overall = angularTravel(original, around: center)
        let fullTurn = 2 * Double.pi
        guard shortSide >= 12,
              abs(abs(circuit.net) - fullTurn) < 1e-6,
              circuit.total <= 1.4 * fullTurn,
              abs(overall.net) <= 1.4 * fullTurn else { return preservingTailOnly ? nil : .freeform }

        if let interval {
            let limit = max(14, 0.3 * shortSide)
            // Most discarded samples lie close to the seam or follow the loop. The
            // sampled ring gives a quick upper bound when a sample is close to a vertex.
            for (point, offset) in zip(original, offsets) where !interval.contains(offset) {
                if !samples.contains(where: { distance(point, $0) <= limit }),
                   nearestGap(to: point, on: closed) > limit {
                    return .freeform
                }
            }
        }

        // The fallback can recognize a long-tailed loop, but only the normal
        // seam search can trim ink for a fitted outline.
        if preservingTailOnly { return nil }

        let relative = loop.map { Point(x: ($0.x - center.x) / scale, y: ($0.y - center.y) / scale) }
        let hullArea = area(convexHull(relative))
        let loopArea = area(relative)
        guard loopArea >= 0.8 * hullArea else { return .freeform }

        let window = max(2, Int((0.16 * shortSide / perimeter * Double(sampleCount)).rounded()))
        let corners = cornerIndices(samples, window: window, minimumAngle: 52)
        let boxCorners = corners.count == 3 ? cornerIndices(samples, window: window, minimumAngle: 42) : corners
        if (4...5).contains(boxCorners.count), hasStraightRuns(samples, ink: loop, corners: boxCorners, span: shortSide) {
            return .rectangle(loopBox)
        }
        if corners.count == 3, hasStraightRuns(samples, ink: loop, corners: corners, span: shortSide) {
            return .freeform
        }
        guard corners.count <= 3 else { return .freeform }
        return fittedOutline(oriented, in: orientedBox, displayedBounds: loopBox)
    }

    private static func closedInterval(in ink: [Point], offsets: [Double], length: Double,
                                       box: PointRect) -> ClosedRange<Double>? {
        let endGap = distance(ink[0], ink[ink.count - 1])
        guard endGap > 3.5 else { return nil }
        let seamTolerance = max(4, 0.045 * hypot(box.size.width, box.size.height))
        // Find endpoints on either end of the ink, with at least 60% of the travel between them.
        // Project onto edges so a return between two samples can still close the loop.
        let samples = resample(ink, offsets: offsets, length: length)
        var bestGap = endGap
        var start = 0.0, end = Double(loopSamples)
        for early in 0..<(loopSamples * 2 / 5) {
            for late in (early + loopSamples * 3 / 5)...loopSamples {
                let a = samples[early], b = samples[late]
                let earlyFraction = projection(of: b, onto: a, to: samples[early + 1])
                let earlyGap = distance(b, interpolate(a, samples[early + 1], fraction: earlyFraction))
                if Double(late - early) - earlyFraction >= Double(loopSamples) * 0.6, earlyGap < bestGap {
                    bestGap = earlyGap
                    start = Double(early) + earlyFraction
                    end = Double(late)
                }
                let lateFraction = projection(of: a, onto: samples[late - 1], to: b)
                let lateGap = distance(a, interpolate(samples[late - 1], b, fraction: lateFraction))
                if Double(late - 1 - early) + lateFraction >= Double(loopSamples) * 0.6, lateGap < bestGap {
                    bestGap = lateGap
                    start = Double(early)
                    end = Double(late - 1) + lateFraction
                }
            }
        }
        guard bestGap <= seamTolerance, bestGap + 0.75 < endGap else { return nil }
        return (length * (start / Double(loopSamples)))...(length * (end / Double(loopSamples)))
    }

    private static func loopWithLongTail(in ink: [Point], offsets: [Double],
                                         length: Double) -> ClosedRange<Double>? {
        guard length >= 32, distance(ink[0], ink[ink.count - 1]) > 14 else { return nil }
        // A long tail can occupy more than 40% of the travel. Look for a close
        // return to either endpoint after the stroke has moved away from it.
        var best: (range: ClosedRange<Double>, gap: Double)?
        for start in [true, false] {
            let anchor = start ? ink[0] : ink[ink.count - 1]
            var leftAnchor = false
            for step in 1..<ink.count {
                let a = start ? step - 1 : ink.count - step
                let b = start ? step : ink.count - step - 1
                if leftAnchor {
                    let fraction = projection(of: anchor, onto: ink[a], to: ink[b])
                    let gap = distance(anchor, interpolate(ink[a], ink[b], fraction: fraction))
                    let seam = offsets[a] + (offsets[b] - offsets[a]) * fraction
                    let travel = start ? seam : length - seam
                    if travel >= 32, travel < 0.6 * length, gap <= 4, gap < (best?.gap ?? .infinity) {
                        best = (start ? 0...seam : seam...length, gap)
                    }
                }
                if distance(anchor, ink[b]) >= 12 { leftAnchor = true }
            }
        }
        return best?.range
    }

    private static func clip(_ ink: [Point], offsets: [Double], to interval: ClosedRange<Double>) -> [Point] {
        var edge = 0
        let first = sample(ink, offsets: offsets, at: interval.lowerBound, edge: &edge)
        let interior = zip(ink, offsets).compactMap { point, offset in
            interval.lowerBound < offset && offset < interval.upperBound ? point : nil
        }
        let last = sample(ink, offsets: offsets, at: interval.upperBound, edge: &edge)
        return [first] + interior + [last]
    }

    private static func isMissingSide(_ loop: [Point], offsets: [Double], length: Double, span: Double) -> Bool {
        var edge = 0
        let first = loop[0], last = loop[loop.count - 1]
        let after = sample(loop, offsets: offsets, at: 0.2 * span, edge: &edge)
        let before = sample(loop, offsets: offsets, at: length - 0.2 * span, edge: &edge)
        let limit = 55 * Double.pi / 180
        return turn(from: before, through: last, to: first) > limit
            && turn(from: last, through: first, to: after) > limit
    }

    private static func cornerIndices(_ samples: [Point], window: Int, minimumAngle: Double) -> [Int] {
        let count = samples.count
        let angles = samples.indices.map { i in
            turn(from: samples[(i - window + count) % count], through: samples[i],
                 to: samples[(i + window) % count])
        }
        return angles.indices.filter { i in
            angles[i] >= minimumAngle * .pi / 180 && (-window...window).allSatisfy { step in
                let j = (i + step + count) % count
                return angles[j] < angles[i] || (angles[j] == angles[i] && i <= j)
            }
        }
    }

    private static func hasStraightRuns(_ samples: [Point], ink: [Point], corners: [Int], span: Double) -> Bool {
        let tolerance = 0.16 * span
        for (first, last) in zip(corners, corners.dropFirst() + [corners[0] + samples.count]) {
            let a = samples[first], b = samples[last % samples.count]
            let chord = distance(a, b)
            guard chord >= 0.20 * span else { return false }
            var length = 0.0
            for index in (first + 1)...last {
                let point = samples[index % samples.count]
                length += distance(samples[(index - 1) % samples.count], point)
                let fraction = projection(of: point, onto: a, to: b)
                guard distance(point, interpolate(a, b, fraction: fraction)) <= tolerance else { return false }
            }
            if chord < 0.9 * length { return false }
        }
        let vertices = corners.map { samples[$0] }
        let outline = vertices + [vertices[0]]
        // A cusp shorter than the sampling interval can still be meaningful ink.
        return ink.allSatisfy { nearestGap(to: $0, on: outline) <= tolerance }
    }

    private static func fittedOutline(_ ink: [Point], in box: PointRect,
                                      displayedBounds: PointRect) -> MarkShape.Area {
        let a = box.size.width / 2, b = box.size.height / 2
        let offsets = pathOffsets(ink)
        guard a > 0, b > 0, let length = offsets.last, length > 0 else { return .freeform }
        let x = box.origin.x + a, y = box.origin.y + b
        let shortAxis = min(a, b)
        func ovalError(_ u: Double, _ v: Double) -> Double {
            abs(hypot(u / a, v / b) - 1)
        }
        let samples = resample(ink, offsets: offsets, length: length)
        var oval = 0.0, rectangle = 0.0
        for point in samples {
            let u = abs(point.x - x), v = abs(point.y - y)
            oval += ovalError(u, v)
            rectangle += min(abs(a - u), abs(b - v)) / shortAxis
        }
        let count = Double(samples.count)
        if oval > 0.75 * rectangle {
            return rectangle / count <= 0.08 ? .rectangle(displayedBounds) : .freeform
        }
        guard oval / count <= 0.20,
              ink.allSatisfy({ ovalError(abs($0.x - x), abs($0.y - y)) <= 0.60 }) else { return .freeform }
        return .ellipse(displayedBounds)
    }

    private static func convexHull(_ points: [Point]) -> [Point] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func half(_ ordered: some Sequence<Point>) -> [Point] {
            var result: [Point] = []
            for point in ordered {
                while result.count >= 2 {
                    let a = result[result.count - 2], b = result[result.count - 1]
                    guard (b.x - a.x) * (point.y - a.y) <= (b.y - a.y) * (point.x - a.x) else { break }
                    result.removeLast()
                }
                result.append(point)
            }
            return Array(result.dropLast())
        }
        return half(sorted) + half(sorted.reversed())
    }

    private static func area(_ points: [Point]) -> Double {
        guard let first = points.first else { return 0 }
        return abs(zip(points, points.dropFirst() + [first]).reduce(0.0) { sum, pair in
            sum + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        }) / 2
    }

    private static func hookTip(in ink: [Point], offsets: [Double], length: Double, firstBend: Int?) -> Int? {
        guard ink.count >= 3 else { return nil }
        let tailLimit = min(90, length * 0.35)
        guard tailLimit >= 12 else { return nil }
        let latestTip = firstBend.map { offsets[$0] + bendWindow } ?? length
        var best: (index: Int, angle: Double)?
        var edge = 0
        for i in 1..<(ink.count - 1) where length - offsets[i] >= 12 {
            // For a two-legged hook, keep the first reversal at the shaft tip.
            guard offsets[i] < latestTip, offsets[i] >= minimumShaftLength else { continue }
            let tip = ink[i]
            let before = sample(ink, offsets: offsets, at: offsets[i] - 14, edge: &edge)
            var afterEdge = i
            let after = sample(ink, offsets: offsets, at: min(length, offsets[i] + 16), edge: &afterEdge)
            guard distance(tip, after) >= 6, isShaft(from: ink[0], to: tip, length: offsets[i]) else { continue }
            let angle = turn(from: before, through: tip, to: after)
            guard angle >= 115 * .pi / 180, angle > (best?.angle ?? 0) else { continue }
            // A head must fit in the tip half of the shaft even if its traced
            // length is inflated by retracing or jitter.
            let radius = min(tailLimit, 0.55 * distance(ink[0], tip))
            guard radius >= 12 else { continue }
            var extent = 0.0
            for point in ink[(i + 1)...] {
                extent = max(extent, distance(point, tip))
                if extent > radius { break }
            }
            guard (12...radius).contains(extent) else { continue }
            best = (i, angle)
        }
        return best?.index
    }

    static func absorbHead(_ head: Stroke, into shaft: Stroke, previousPenUp: Double?,
                           allowOppositeEnd: Bool, frameSize: Size,
                           existingMarks: [Stroke]) -> (shape: MarkShape, reversed: Bool)? {
        guard shaft.shape == .mark || isArrow(shaft.shape),
              let penUp = previousPenUp, (0...3).contains(head.downTime - penUp),
              shaft.frameID == head.frameID,
              let first = head.points.first, let last = head.points.last,
              first != last, let ink = framePoints(head.points, size: frameSize),
              let path = framePoints(Array(shaft.renderedPoints), size: frameSize),
              let start = path.first, let end = path.last else { return nil }
        let offsets = pathOffsets(path)
        guard let length = offsets.last, isShaft(from: start, to: end, length: length),
              firstSharpBend(in: path, offsets: offsets) == nil else { return nil }

        let currentDirection = shaft.shaftReversed == true
        for reversed in [currentDirection, !currentDirection] {
            if reversed != currentDirection && (!allowOppositeEnd || shaft.shaftPointCount != nil) { break }
            let oriented = reversed ? Array(path.reversed()) : path
            guard isArrowhead(ink, atEndOf: oriented) else { continue }
            if reversed == currentDirection, let shape = shaft.shape, isArrow(shape) {
                return (shape, reversed)
            }
            let shape = arrow(in: oriented, offsets: pathOffsets(oriented), tipIndex: oriented.count - 1,
                              near: existingMarks, size: frameSize, hasHead: true)
            return (shape, reversed)
        }
        return nil
    }

    private static func isArrow(_ shape: MarkShape?) -> Bool {
        if case .arrow = shape { return true }
        return false
    }

    private static func isArrowhead(_ ink: [Point], atEndOf path: [Point]) -> Bool {
        let first = ink[0], last = ink[ink.count - 1], tip = path[path.count - 1]
        let box = bounds(of: ink, first: first)
        guard max(box.size.width, box.size.height) <= 110,
              nearestGap(to: tip, on: ink) <= 24 else { return false }
        let back = path.reversed().first { distance($0, tip) >= 30 } ?? path[0]
        let span = distance(back, tip)
        guard span > 0 else { return false }
        let bx = (back.x - tip.x) / span, by = (back.y - tip.y) / span
        let offsets = pathOffsets(ink)
        guard let length = offsets.last, length >= 12, length.isFinite else { return false }

        // A single barb needs a tighter location gate than a two-legged head.
        let chord = distance(first, last)
        if (12...55).contains(chord), chord >= 0.9 * length {
            let firstTouches = distance(first, tip) <= distance(last, tip)
            let contact = firstTouches ? first : last
            let outer = firstTouches ? last : first
            let opening = ((outer.x - contact.x) * bx + (outer.y - contact.y) * by) / chord
            return distance(contact, tip) <= 6 && (0.42...0.97).contains(opening)
        }
        guard ink.count >= 3 else { return false }
        for i in 1..<(ink.count - 1) {
            let apex = ink[i]
            let firstLeg = offsets[i], secondLeg = length - firstLeg
            let l1 = distance(first, apex), l2 = distance(last, apex)
            guard min(firstLeg, secondLeg) >= max(6, length * 0.25),
                  l1 >= 0.9 * firstLeg, l2 >= 0.9 * secondLeg,
                  max(l1, l2) <= 3 * min(l1, l2),
                  distance(apex, tip) <= max(24, 1.2 * max(l1, l2)),
                  (55 * .pi / 180...150 * .pi / 180).contains(turn(from: first, through: apex, to: last))
            else { continue }
            let sx = (first.x - apex.x) / l1 + (last.x - apex.x) / l2
            let sy = (first.y - apex.y) / l1 + (last.y - apex.y) / l2
            if sx * bx + sy * by >= 0.5 * hypot(sx, sy) { return true }
        }
        return false
    }

    private static func firstSharpBend(in ink: [Point], offsets: [Double]) -> Int? {
        guard ink.count >= 3, let length = offsets.last else { return nil }
        var leadingEdge = 0, trailingEdge = 0
        for i in 1..<(ink.count - 1) where offsets[i] >= bendWindow && length - offsets[i] >= bendWindow {
            let before = sample(ink, offsets: offsets, at: offsets[i] - bendWindow, edge: &leadingEdge)
            let after = sample(ink, offsets: offsets, at: offsets[i] + bendWindow, edge: &trailingEdge)
            if turn(from: before, through: ink[i], to: after) >= 60 * .pi / 180 { return i }
        }
        return nil
    }

    private static func isShaft(from start: Point, to tip: Point, length: Double) -> Bool {
        length >= minimumShaftLength && length <= straightnessLimit * distance(start, tip)
    }

    private static func arrow(in ink: [Point], offsets: [Double], tipIndex: Int,
                              near marks: [Stroke], size: Size, hasHead: Bool) -> MarkShape {
        struct Hit {
            let id: MarkID
            let region: ArrowRegion
            let gap: Double
            let onBadge: Bool
            var score: (Double, Double) { (onBadge ? 0 : abs(gap), region.footprint) }
        }
        let regions = marks.reversed().compactMap { mark -> (MarkID, ArrowRegion)? in
            guard !mark.isDeleted, mark.absorbedInto == nil, mark.upTime != nil,
                  let region = arrowRegion(for: mark, size: size) else { return nil }
            return (mark.id, region)
        }
        guard !regions.isEmpty else { return hasHead ? .arrow(from: nil, to: nil) : .mark }

        func hit(at point: Point) -> Hit? {
            var best: Hit?
            for (id, region) in regions {
                let gap = region.gap(point)
                let onBadge = region.badgeContains(point)
                guard onBadge || gap <= arrowMargin else { continue }
                let candidate = Hit(id: id, region: region, gap: gap, onBadge: onBadge)
                if let best, best.score <= candidate.score { continue }
                best = candidate
            }
            return best
        }

        let start = ink[0], tip = ink[tipIndex]
        let startHit = hit(at: start), tipHit = hit(at: tip)
        if let startHit, startHit.id == tipHit?.id {
            return hasHead ? .arrow(from: nil, to: nil) : .mark
        }

        let chord = distance(start, tip)
        func directed(_ hit: Hit?, at point: Point, opposite: Point, probe: Point) -> MarkID? {
            guard let hit else { return nil }
            let otherGap = hit.region.gap(opposite)
            guard otherGap > 0, !hit.region.badgeContains(opposite) else { return nil }
            if hit.onBadge || hit.gap <= 0 { return hit.id }
            // Check both overall clearance and the initial direction at the outline.
            // A long underline can get far away by running past the edge of a box.
            let probeGap = hit.region.gap(probe)
            guard otherGap - hit.gap >= 0.5 * chord,
                  probeGap - hit.gap >= 0.20 * distance(point, probe) else { return nil }
            return hit.id
        }

        var edge = 0
        let leaving = sample(ink, offsets: offsets, at: 14, edge: &edge)
        let approaching = sample(ink, offsets: offsets, at: offsets[tipIndex] - 14, edge: &edge)
        let from = directed(startHit, at: start, opposite: tip, probe: leaving)
        var to = directed(tipHit, at: tip, opposite: start, probe: approaching)
        if to == nil, tipHit == nil {
            let reach = min(90, 0.3 * chord)
            var backEdge = 0
            let back = sample(ink, offsets: offsets, at: max(0, offsets[tipIndex] - 30), edge: &backEdge)
            let span = distance(back, tip)
            let candidates = regions.filter { id, region in
                id != startHit?.id && region.gap(start) > arrowMargin
            }
            if span > 0, reach > 0, !candidates.isEmpty {
                let dx = (tip.x - back.x) / span, dy = (tip.y - back.y) / span
                var step = min(4, reach)
                while to == nil {
                    let ahead = Point(x: tip.x + dx * step, y: tip.y + dy * step)
                    to = candidates.first { _, region in
                        region.gap(ahead) <= region.rayTolerance || region.badgeContains(ahead)
                    }?.0
                    if step == reach { break }
                    step = min(step + 4, reach)
                }
            }
        }
        guard hasHead || from != nil || to != nil else { return .mark }
        return .arrow(from: from, to: to)
    }

    /// Fills free endpoints using a newly completed target on the same frame.
    static func relink(_ shaft: Stroke, to target: Stroke, frameSize: Size) -> MarkShape? {
        guard !shaft.isDeleted, shaft.absorbedInto == nil, shaft.upTime != nil,
              case .arrow(let from, let to) = shaft.shape, from == nil || to == nil,
              from != target.id, to != target.id, shaft.frameID == target.frameID,
              let path = framePoints(Array(shaft.renderedPoints), size: frameSize), path.count >= 2 else { return nil }
        let ink = shaft.shaftReversed == true ? Array(path.reversed()) : path
        guard case .arrow(let newFrom, let newTo) = arrow(in: ink, offsets: pathOffsets(ink),
                                                         tipIndex: ink.count - 1, near: [target],
                                                         size: frameSize, hasHead: true) else { return nil }
        return .arrow(from: from ?? newFrom, to: to ?? newTo)
    }

    private static func pathOffsets(_ ink: [Point]) -> [Double] {
        var offsets = [0.0]
        for (a, b) in zip(ink, ink.dropFirst()) {
            offsets.append(offsets[offsets.count - 1] + distance(a, b))
        }
        return offsets
    }

    private static func resample(_ ink: [Point], offsets: [Double], length: Double,
                                 count: Int = loopSamples) -> [Point] {
        var edge = 0
        return (0...count).map { index in
            sample(ink, offsets: offsets, at: length * (Double(index) / Double(count)), edge: &edge)
        }
    }

    private static func sample(_ ink: [Point], offsets: [Double], at offset: Double, edge: inout Int) -> Point {
        while edge < ink.count - 2, offsets[edge + 1] <= offset { edge += 1 }
        let length = offsets[edge + 1] - offsets[edge]
        guard length > 0 else { return ink[edge] }
        let fraction = min(1, max(0, (offset - offsets[edge]) / length))
        return interpolate(ink[edge], ink[edge + 1], fraction: fraction)
    }

    private static func projection(of point: Point, onto a: Point, to b: Point) -> Double {
        let span = distance(a, b)
        guard span > 0 else { return 0 }
        let along = (point.x - a.x) * ((b.x - a.x) / span) + (point.y - a.y) * ((b.y - a.y) / span)
        return min(1, max(0, along / span))
    }

    private static func turn(from a: Point, through b: Point, to c: Point) -> Double {
        let incoming = atan2(b.y - a.y, b.x - a.x)
        let outgoing = atan2(c.y - b.y, c.x - b.x)
        return abs((outgoing - incoming).remainder(dividingBy: 2 * .pi))
    }

    private static func framePoints(_ points: [NormalizedPoint], size: Size) -> [Point]? {
        let result = points.map { Point(x: $0.x * size.width, y: $0.y * size.height) }
        return result.allSatisfy { $0.x.isFinite && $0.y.isFinite } ? result : nil
    }

    private static func bounds(of points: [Point], first: Point) -> PointRect {
        var low = first, high = first
        for point in points.dropFirst() {
            low = Point(x: min(low.x, point.x), y: min(low.y, point.y))
            high = Point(x: max(high.x, point.x), y: max(high.y, point.y))
        }
        return PointRect(origin: low, size: Size(width: high.x - low.x, height: high.y - low.y))
    }

    private static func enclosesArea(_ points: [Point], box: PointRect) -> Bool {
        // Translate before taking the signed area so large frame offsets don't dominate it.
        // Scale by the short side for a dimensionless calculation without multiplying large spans.
        let scale = min(box.size.width, box.size.height)
        let relative = points.map {
            Point(x: ($0.x - box.origin.x) / scale, y: ($0.y - box.origin.y) / scale)
        }
        // The closing edge contributes zero when the origin is the first vertex.
        let first = relative[0]
        let twiceArea = zip(relative, relative.dropFirst()).reduce(0.0) { sum, pair in
            let (a, b) = pair
            return sum + (a.x - first.x) * (b.y - first.y) - (b.x - first.x) * (a.y - first.y)
        }
        let boxArea = max(box.size.width, box.size.height) / scale
        // A shallow there-and-back stroke can fill half of its very narrow box.
        let minimumRatio = boxArea >= 4 ? 0.55 : 0.30
        return abs(twiceArea) / 2 >= max(8 / scale / scale, minimumRatio * boxArea)
    }

    private static func angularTravel(_ ink: [Point], around center: Point) -> (net: Double, total: Double) {
        var previous = atan2(ink[0].y - center.y, ink[0].x - center.x)
        var net = 0.0, total = 0.0
        for point in ink.dropFirst() {
            let angle = atan2(point.y - center.y, point.x - center.x)
            let step = (angle - previous).remainder(dividingBy: 2 * .pi)
            net += step
            total += abs(step)
            previous = angle
        }
        return (net, total)
    }

    private static func ellipseTilt(_ samples: [Point], in box: PointRect) -> Double {
        // The covariance gives the major-axis direction. Ignore it when the axis is
        // weakly defined, since small asymmetries can rotate a nearly round oval.
        let scale = max(box.size.width, box.size.height)
        let offsets = samples.map {
            Point(x: ($0.x - box.origin.x) / scale, y: ($0.y - box.origin.y) / scale)
        }
        let count = Double(offsets.count)
        let xMean = offsets.reduce(0) { $0 + $1.x } / count
        let yMean = offsets.reduce(0) { $0 + $1.y } / count
        var xx = 0.0, yy = 0.0, xy = 0.0
        for offset in offsets {
            let x = offset.x - xMean, y = offset.y - yMean
            xx += x * x
            yy += y * y
            xy += x * y
        }
        if hypot(xx - yy, 2 * xy) <= 0.22 * (xx + yy) { return 0 }
        // Measure tilt relative to the closest axis, including tall ellipses.
        return atan2(xx >= yy ? 2 * xy : -2 * xy, abs(xx - yy)) / 2
    }

    private struct ArrowRegion {
        var footprint: Double
        var gap: (Point) -> Double
        var pinBadge: PointRect? = nil
        var rayTolerance = 0.0

        func badgeContains(_ point: Point) -> Bool {
            guard let pinBadge else { return false }
            return ShapeRecognizer.rectangleGap(from: point, to: pinBadge) <= 1e-9
        }
    }

    private static func arrowRegion(for mark: Stroke, size: Size) -> ArrowRegion? {
        switch mark.shape {
        case .area(.rectangle(let box)) where box.isValid:
            return ArrowRegion(footprint: box.size.width * box.size.height, gap: { rectangleGap(from: $0, to: box) })
        case .area(.ellipse(let box)) where box.isValid:
            return ArrowRegion(footprint: box.size.width * box.size.height * .pi / 4, gap: { ellipseGap(from: $0, to: box) })
        case .area(.freeform):
            guard var path = framePoints([mark.badgeAnchor] + mark.points, size: size) else { return nil }
            let box = bounds(of: path, first: path[0])
            path.append(path[0])
            return ArrowRegion(footprint: box.size.width * box.size.height, gap: { point in
                let gap = nearestGap(to: point, on: path)
                return contains(point, polygon: path) ? -gap : gap
            })
        case .pin:
            guard let dot = framePoints([mark.badgeAnchor], size: size)?.first else { return nil }
            let badge = MarkBadgeGeometry.pinBadge(at: dot, in: size, id: mark.id)
            return ArrowRegion(footprint: badge.size.width * badge.size.height,
                               gap: { distance($0, dot) }, pinBadge: badge, rayTolerance: 3)
        default:
            return nil
        }
    }

    // A negative gap is the distance to the outline from inside the shape.
    private static func rectangleGap(from point: Point, to box: PointRect) -> Double {
        let dx = max(box.origin.x - point.x, point.x - (box.origin.x + box.size.width))
        let dy = max(box.origin.y - point.y, point.y - (box.origin.y + box.size.height))
        if dx <= 0, dy <= 0 { return max(dx, dy) }
        return hypot(max(0, dx), max(0, dy))
    }

    private static func ellipseGap(from point: Point, to box: PointRect) -> Double {
        let a = box.size.width / 2, b = box.size.height / 2
        let x = abs(point.x - (box.origin.x + a)), y = abs(point.y - (box.origin.y + b))
        let radius = hypot(x / a, y / b)
        if radius <= 1 {
            // The exact outside distance decides eligibility. For an interior hit,
            // a local-normal estimate suffices to rank it against other outlines.
            guard radius > 0 else { return -min(a, b) }
            let normalScale = hypot((x / a) / a, (y / b) / b) / radius
            return max(-min(a, b), (radius - 1) / normalScale)
        }
        // For an outside point, the closest point lies at (a²x/(a²+t), b²y/(b²+t)).
        // Increase t until that point lies on the ellipse.
        var low = 0.0, high = hypot(a * x, b * y)
        for _ in 0..<32 {
            let t = (low + high) / 2
            if hypot(a * x / (a * a + t), b * y / (b * b + t)) > 1 {
                low = t
            } else {
                high = t
            }
        }
        return hypot(x * low / (a * a + low), y * low / (b * b + low))
    }

    private static func contains(_ point: Point, polygon: [Point]) -> Bool {
        var inside = false
        for (a, b) in zip(polygon, polygon.dropFirst()) where (a.y > point.y) != (b.y > point.y) {
            let edgeX = a.x + (b.x - a.x) * ((point.y - a.y) / (b.y - a.y))
            if point.x < edgeX { inside.toggle() }
        }
        return inside
    }

    private static func nearestGap(to point: Point, on path: [Point]) -> Double {
        zip(path, path.dropFirst()).reduce(distance(point, path[0])) { best, edge in
            let fraction = projection(of: point, onto: edge.0, to: edge.1)
            return min(best, distance(point, interpolate(edge.0, edge.1, fraction: fraction)))
        }
    }

    private static func interpolate(_ a: Point, _ b: Point, fraction: Double) -> Point {
        Point(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }

    private static func distance(_ a: Point, _ b: Point) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
