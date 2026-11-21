// Offscreen only. Build/run via tools/render-settings-previews.sh; no app delegate,
// windows, event loop, permission queries, pasteboard access or hotkey registration.
import AppKit
import Carbon
import SwiftUI

@main
struct SettingsPreviewRenderer {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/pilcrow-settings-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["light", "dark", "rejected-command-v", "mic-off"] {
            let dark = name == "dark" || name == "mic-off"
            let model = SettingsPresentation()
            model.icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") ?? NSImage(size: NSSize(width: 46, height: 46))
            model.start = "⌥D"
            model.undo = "⌘Z"
            model.canClear = true
            model.access = SettingsAccessLine.lines(screenRecording: true, microphone: name == "mic-off" ? .denied : .on)
            // Fixed synthetic input keeps previews reproducible across keyboard layouts.
            model.defaultLabel = { $0 == .annotate ? "⌥D" : "⌘Z" }
            if name == "rejected-command-v" {
                let us = KeyboardLayout { code, _ in KeyChord.usNames[code]?.lowercased() }
                let chord = KeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey))
                model.recording = .annotate
                model.rejection = SettingsRejection(shortcut: .annotate, glyph: chord.glyph(layout: us),
                    reason: chord.validationError(action: .annotate, layout: us)!)
            }
            let host = NSHostingView(rootView: SettingsStoryView(model: model).environment(\.colorScheme, dark ? .dark : .light).environment(\.displayScale, 2))
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
    }
}
