import CoreGraphics
import Foundation

enum PilcrowColour: String, CaseIterable, Sendable {
    case coral, amber, green, teal, blue, violet, red

    static let defaultsKey = "Pilcrow.Colour"

    var name: String { rawValue.capitalized }

    private var palette: (light: UInt32, dark: UInt32) {
        switch self {
        case .coral: (0xF0644F, 0xFF7A66)
        case .amber: (0xF29D12, 0xFFB340)
        case .green: (0x2EA66A, 0x48D28A)
        case .teal: (0x12A2A6, 0x3DD2D0)
        case .blue: (0x3478F6, 0x4A90FF)
        case .violet: (0x7C5CF2, 0x9F86FF)
        case .red: (0xE3141F, 0xFF453A)
        }
    }

    func accent(dark: Bool) -> CGColor { Self.sRGB(dark ? palette.dark : palette.light) }

    // Ink is composited onto arbitrary screenshots, independent of appearance.
    var ink: CGColor { accent(dark: false) }
    var badgeText: CGColor { self == .amber ? Self.sRGB(0x3B2600) : CGColor(gray: 1, alpha: 1) }

    static func settingsNumeral(on fill: CGColor) -> CGColor {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let components = fill.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return CGColor(gray: 1, alpha: 1) }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(components[0]) + 0.7152 * linear(components[1]) + 0.0722 * linear(components[2])
        let whiteContrast = 1.05 / (luminance + 0.05)
        return CGColor(gray: whiteContrast < 3 ? 0 : 1, alpha: 1)
    }

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .coral
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    private static func sRGB(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
