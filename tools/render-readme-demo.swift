// Offscreen only. Run via tools/render-readme-demo.sh.
import Foundation
import PilcrowCore
import SwiftUI

@main
struct ReadmeDemoRenderer {
    private static let buttonWords = "The checkout button wraps on narrow windows, keep it on one line."
    private static let totalWords = "And this total should line up with the prices above it."
    private static let wordInterval = 0.32

    @MainActor
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let staging = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let renderer = ImageRenderer(content: CheckoutPage().environment(\.colorScheme, .light))
        renderer.scale = 2
        renderer.isOpaque = true
        guard let screenshot = renderer.cgImage else { throw DemoError.screenshot }

        let session = try makeSession(pixelSize: Size(width: Double(screenshot.width), height: Double(screenshot.height)))
        let originals = [session.frames[0].id: screenshot]
        var visibleText = await Task.detached {
            MarkTextRecognition.collect(session: session, originals: originals, budget: 5)
        }.value
        for (id, expected) in [(MarkID(rawValue: 1), CheckoutPage.buttonLabel), (MarkID(rawValue: 2), CheckoutPage.total)] {
            if visibleText[id] == expected {
                print("Mark \(id.rawValue): Vision OCR read \(expected)")
            } else {
                print("Mark \(id.rawValue): Vision OCR read \(visibleText[id] ?? "nothing"); injecting \(expected)")
                visibleText[id] = expected
            }
        }

        let message = MessageBuilder.build(session: session, visibleText: visibleText)
        let files = FileManager.default
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        let export = Export.write(session: session, message: message, originals: originals, to: staging, colour: .coral)
        guard export.failedFiles.isEmpty, export.messageWritten,
              export.attachments == ["frame-1.png", "mark-1.png", "mark-2.png"],
              let frame = export.imageData["frame-1.png"], let crop = export.imageData["mark-1.png"] else {
            throw DemoError.export(export.failedFiles)
        }
        let outbox = "~/Library/Application Support/Pilcrow/Outbox/…"
        let delivery = DeliveryText.message(approvedText: message.text,
                                            imagePaths: export.attachments.map { "\(outbox)/\($0)" })
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, data) in [("demo-frame.png", frame), ("demo-mark-1.png", crop), ("demo-message.txt", Data(delivery.utf8))] {
            try data.write(to: output.appendingPathComponent(name), options: .atomic)
            print("\(name): \(data.count) bytes")
        }
    }

    private static func makeSession(pixelSize: Size) throws -> Session {
        let frame = Frame(id: Frame.ID(), capturedAt: 0, displayID: 1, boundsInPoints: CheckoutPage.size,
                          pixelSize: pixelSize, context: FrameContext(appName: "Safari", windowTitle: "Checkout – Acme Store"))
        let buttonStart = 0.2
        let totalStart = 5.0
        var session = Session()
        try session.addFrame(frame)
        try draw(roughBox(CheckoutPage.buttonBounds.insetBy(dx: -12, dy: -10)),
                 afterFirstThreeWordsOf: buttonStart, frame: frame, session: &session)
        try draw(roughOval(CheckoutPage.totalOutline),
                 afterFirstThreeWordsOf: totalStart, frame: frame, session: &session)
        session.setTranscript(words: timedWords(buttonWords, start: buttonStart) + timedWords(totalWords, start: totalStart),
                              languageCode: "en")
        session.seal()

        let fixes = FixList.build(session: session)
        guard fixes.items.map(\.kindLabel) == [" (box)", " (oval)"] else {
            throw DemoError.shapes(fixes.items.map(\.kindLabel))
        }
        guard fixes.items.map(\.words) == [buttonWords, totalWords] else {
            throw DemoError.alignment(fixes.items.map(\.words))
        }
        return session
    }

    private static func draw(_ points: [CGPoint], afterFirstThreeWordsOf start: Double, frame: Frame,
                             session: inout Session) throws {
        let normalized = points.map { NormalizedPoint(x: $0.x / frame.boundsInPoints.width, y: $0.y / frame.boundsInPoints.height) }
        let down = start + 3 * wordInterval - 0.025
        let id = try session.beginStroke(at: down, frame: frame.id, firstPoint: normalized[0])
        for point in normalized.dropFirst() {
            session.append(point: point, to: id)
        }
        session.endStroke(id: id, at: down + 1.05)
    }

    private static func timedWords(_ sentence: String, start: Double) -> [TranscriptWord] {
        sentence.components(separatedBy: " ").enumerated().map { index, word in
            let onset = start + Double(index) * wordInterval
            let duration = min(0.28, 0.11 + 0.018 * Double(word.count))
            return TranscriptWord(text: word, start: onset, end: onset + duration)
        }
    }

    private static func roughBox(_ rect: CGRect) -> [CGPoint] {
        let samples: [(CGFloat, CGFloat)] = [
            (0.02, 0.04), (0.17, 0.01), (0.34, 0.02), (0.51, 0), (0.72, 0.02), (0.90, 0.01), (0.98, 0.05),
            (1, 0.21), (0.98, 0.42), (1.01, 0.65), (0.99, 0.86), (0.96, 0.98),
            (0.79, 1.01), (0.57, 0.99), (0.33, 1), (0.14, 0.99), (0.01, 0.95),
            (0, 0.77), (0.02, 0.55), (-0.01, 0.32), (0.01, 0.15), (0.025, 0.06),
        ]
        return samples.map { x, y in CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
    }

    private static func roughOval(_ rect: CGRect) -> [CGPoint] {
        (0...32).map { sample in
            let angle = 2 * CGFloat.pi * CGFloat(sample) / 32 - .pi / 2
            let wobble = 1 + 0.035 * sin(3 * angle) + 0.025 * cos(5 * angle)
            return CGPoint(x: rect.midX + cos(angle) * rect.width / 2 * wobble,
                           y: rect.midY + sin(angle) * rect.height / 2 * wobble)
        }
    }

    private enum DemoError: Error {
        case screenshot, shapes([String]), alignment([String]), export([String])
    }
}

private struct CheckoutPage: View {
    static let size = Size(width: 1280, height: 800)
    static let buttonLabel = "Place order"
    static let total = "$42.00"

    // The targets and raw strokes share the same top-left coordinate space as the capture.
    private static let summary = CGRect(x: 688, y: 218, width: 488, height: 514)
    private static let priceRight = summary.maxX - 30
    private static let totalY: CGFloat = 493
    private static let totalOverhang: CGFloat = 7
    static let buttonBounds = CGRect(x: summary.midX - 39, y: 600, width: 78, height: 62)
    static let totalOutline = CGRect(x: priceRight + totalOverhang - 123, y: totalY - 34, width: 137, height: 68)

    private let ink = Color(red: 0.09, green: 0.15, blue: 0.13)
    private let muted = Color(red: 0.32, green: 0.38, blue: 0.35)
    private let border = Color(red: 0.87, green: 0.89, blue: 0.86)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.96, green: 0.97, blue: 0.95)
            header
            Text("Checkout")
                .font(.system(size: 48, weight: .semibold))
                .padding(.leading, 104)
                .padding(.top, 123)
            VStack(spacing: 22) {
                deliveryCard
                paymentCard
            }
            .frame(width: 552)
            .padding(.leading, 104)
            .padding(.top, Self.summary.minY)
            orderSummary
        }
        .foregroundStyle(ink)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var header: some View {
        HStack {
            Text("Acme Store").font(.system(size: 25, weight: .semibold))
            Spacer()
            Label("Secure checkout", systemImage: "lock")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(muted)
        }
        .padding(.horizontal, 104)
        .frame(height: 77)
        .background(alignment: .bottom) { Color.white }
        .overlay(alignment: .bottom) { border.frame(height: 1) }
    }

    private var deliveryCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Delivery details")
            HStack(spacing: 14) {
                field("First name", value: "Jamie")
                field("Last name", value: "Taylor")
            }
            field("Street address", value: "24 Alder Lane")
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Standard delivery").font(.system(size: 17, weight: .medium))
                    Text("3–5 business days").font(.system(size: 15)).foregroundStyle(muted)
                }
                Spacer()
                Text("Free").font(.system(size: 17, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.95, green: 0.97, blue: 0.94), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(30)
        .background { card }
    }

    private var paymentCard: some View {
        VStack(alignment: .leading, spacing: 21) {
            sectionTitle("Payment method")
            HStack(spacing: 12) {
                Image(systemName: "creditcard").font(.system(size: 22))
                Text("Card ending in 1042").font(.system(size: 17))
                Spacer()
                Text("Edit").font(.system(size: 17, weight: .medium)).underline()
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
        .background { card }
    }

    private var orderSummary: some View {
        let summary = Self.summary
        return ZStack(alignment: .topLeading) {
            card.frame(width: summary.width, height: summary.height).position(x: summary.midX, y: summary.midY)
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Order summary").padding(.bottom, 22)
                item("Desk notebook", detail: "Sage · Qty 1", price: "$18.00")
                item("Weekly planner", detail: "Undated · Qty 1", price: "$14.00")
                item("Gel pen set", detail: "Black · Qty 1", price: "$10.00")
                border.frame(height: 1).padding(.top, 4)
            }
            .frame(width: summary.width - 60)
            .padding(.leading, summary.minX + 30)
            .padding(.top, summary.minY + 28)

            HStack {
                Text("Total").font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(Self.total).font(.system(size: 27, weight: .semibold)).monospacedDigit()
                    .offset(x: Self.totalOverhang)
            }
            .frame(width: summary.width - 60)
            .position(x: summary.midX, y: Self.totalY)

            Text(Self.buttonLabel)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(width: Self.buttonBounds.width - 24)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.buttonBounds.width, height: Self.buttonBounds.height)
                .background(ink, in: RoundedRectangle(cornerRadius: 9))
                .position(x: Self.buttonBounds.midX, y: Self.buttonBounds.midY)

            Text("By ordering, you agree to the \(Text("terms of sale").underline()).")
                .font(.system(size: 14))
                .foregroundStyle(muted)
                .position(x: summary.midX, y: 691)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 24, weight: .semibold))
    }

    private func field(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(muted)
            Text(value).font(.system(size: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(border) }
        }
    }

    private func item(_ title: String, detail: String, price: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 18, weight: .medium))
                Text(detail).font(.system(size: 15)).foregroundStyle(muted)
            }
            Spacer()
            Text(price).font(.system(size: 18)).monospacedDigit()
        }
        .frame(height: 52)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.white)
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(border) }
    }
}
