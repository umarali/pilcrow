import AppKit
import Foundation

// Render in a 1024-point coordinate space; every output starts from the vector artwork.
func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22,
                      color: CGColor(gray: 0, alpha: 0.18))
    context.addPath(plate)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(plate)
    context.clip()
    let colors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                  CGColor(srgbRed: 0.933, green: 0.941, blue: 0.953, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()
    context.addPath(plate)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.07))
    context.setLineWidth(2)
    context.strokePath()

    // Scale the same 18 × 18 badge so its 16-point disc occupies 60% of the plate.
    let scale = 824.0 * 0.60 / 16.0
    context.translateBy(x: 512 - 9 * scale, y: 512 - 9 * scale)
    context.scaleBy(x: scale, y: scale)
    let badge = CGMutablePath()
    badge.addEllipse(in: CGRect(x: 1, y: 1, width: 16, height: 16))
    badge.move(to: CGPoint(x: 7.5, y: 13.5))
    for point in [CGPoint(x: 13, y: 13.5), CGPoint(x: 13, y: 4.5), CGPoint(x: 11.5, y: 4.5),
                  CGPoint(x: 11.5, y: 12), CGPoint(x: 9.5, y: 12), CGPoint(x: 9.5, y: 4.5),
                  CGPoint(x: 8, y: 4.5), CGPoint(x: 8, y: 8.5), CGPoint(x: 7.5, y: 8.5)] {
        badge.addLine(to: point)
    }
    badge.addArc(center: CGPoint(x: 7.5, y: 11), radius: 2.5,
                 startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
    badge.closeSubpath()
    context.addPath(badge)
    context.setFillColor(CGColor(srgbRed: 240 / 255, green: 100 / 255, blue: 79 / 255, alpha: 1))
    context.drawPath(using: .eoFill)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("pilcrow-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        try render(size: points * scale).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed: \(process.terminationStatus)") }
if CommandLine.arguments.contains("--previews") {
    let directory = URL(fileURLWithPath: "/private/tmp/pilcrow-icon-preview", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [32, 1024] { try render(size: size).write(to: directory.appendingPathComponent("app-\(size).png")) }
}
