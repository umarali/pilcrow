// Offscreen only. Build/run via tools/render-settings-previews.sh; no app delegate,
// windows, event loop, permission queries, pasteboard access or hotkey registration.
import AppKit
import Carbon
import CoreText
import PilcrowCore
import SwiftUI

@main
struct SettingsPreviewRenderer {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/pilcrow-settings-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["light", "dark", "screen-off", "mic-off", "teal", "rejected-command-v"] {
            let dark = name == "dark"
            let model = SettingsPresentation()
            model.start = "⌥D"
            model.undo = "⌘Z"
            model.canClear = true
            model.colour = name == "teal" ? .teal : .coral
            model.access = SettingsAccessLine.lines(screenRecording: name != "screen-off",
                                                    microphone: name == "mic-off" ? .denied : .on)
            // Fixed synthetic input keeps previews reproducible across keyboard layouts.
            model.defaultLabel = { $0 == .annotate ? "⌥D" : "⌘Z" }
            if name == "rejected-command-v" {
                let us = KeyboardLayout { code, _ in KeyChord.usNames[code]?.lowercased() }
                let chord = KeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey))
                model.recording = .annotate
                model.rejection = SettingsRejection(shortcut: .annotate, glyph: chord.glyph(layout: us),
                    reason: chord.validationError(action: .annotate, layout: us)!)
            }
            let host = NSHostingView(rootView: SettingsStoryView(model: model)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.displayScale, 2))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.wantsLayer = true
            host.layoutSubtreeIfNeeded()
            func scaleLayers(_ layer: CALayer) {
                layer.contentsScale = 2
                layer.rasterizationScale = 2
                layer.sublayers?.forEach(scaleLayers)
            }
            if let layer = host.layer { scaleLayers(layer) }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap for \(name)") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("No PNG for \(name)") }
            let url = output.appendingPathComponent(name + ".png")
            try png.write(to: url)
            print("\(url.path) · \(Int(host.frame.width)) × \(Int(host.frame.height)) pt · \(rep.pixelsWide) × \(rep.pixelsHigh) px")
        }
        try renderCoralCrop(to: output)
    }

    private static func renderCoralCrop(to output: URL) throws {
        let size = Size(width: 360, height: 220)
        let pixels = Size(width: size.width * 2, height: size.height * 2)
        let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        let coral = PilcrowColour.coral.ink
        let charcoal = CGColor(srgbRed: 0.14, green: 0.14, blue: 0.18, alpha: 1)
        let white = CGColor(gray: 1, alpha: 1)

        func fill(_ rect: CGRect, with colour: CGColor, radius: CGFloat = 0) {
            context.setFillColor(colour)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, colour: CGColor) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    (bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour
            ]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        fill(CGRect(x: 0, y: 0, width: size.width, height: size.height), with: charcoal)
        text("Project appearance", x: 34, y: 170, size: 20, bold: true, colour: white)
        text("Choose a colour for this workspace.", x: 34, y: 152, size: 12, colour: CGColor(gray: 0.72, alpha: 1))
        fill(CGRect(x: 34, y: 83, width: 292, height: 54), with: coral, radius: 9)
        text("ACCENT COLOUR", x: 48, y: 120, size: 9, bold: true, colour: charcoal)
        for (index, shade) in PilcrowColour.allCases.enumerated() {
            let x = 48 + CGFloat(index) * 39
            fill(CGRect(x: x, y: 90, width: 23, height: 22), with: shade.ink, radius: 4)
        }
        text("Changes apply to all views.", x: 34, y: 54, size: 12, colour: CGColor(gray: 0.72, alpha: 1))
        fill(CGRect(x: 228, y: 34, width: 98, height: 27), with: CGColor(gray: 0.31, alpha: 1), radius: 8)
        text("Save changes", x: 241, y: 43, size: 11, bold: true, colour: white)

        let frame = Frame(id: Frame.ID(), capturedAt: 0, displayID: 1, boundsInPoints: size, pixelSize: pixels)
        let points = [NormalizedPoint(x: 85 / size.width, y: 0.54), NormalizedPoint(x: 279 / size.width, y: 0.54)]
        let mark = Stroke(id: 1, frameID: frame.id, downTime: 0, upTime: 1, points: points,
                          badgeAnchor: points[0], shape: .arrow(from: nil, to: nil))
        let words = [TranscriptWord(text: "Give the accent swatches a bit more spacing.", start: 0, end: 1, isFinal: true)]
        let session = try Session(strokes: [mark], frames: [frame], words: words, transcriptLanguageCode: "en")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pilcrow-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = Export.write(session: session, message: MessageBuilder.build(session: session),
                                  originals: [frame.id: context.makeImage()!], to: folder, colour: .coral)
        guard result.failedFiles.isEmpty, let crop = result.imageData["mark-1.png"] else {
            throw Export.Failure.render
        }
        let url = output.appendingPathComponent("coral-mark-crop.png")
        try crop.write(to: url)
        print(url.path)
    }
}
