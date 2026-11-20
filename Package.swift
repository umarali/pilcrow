// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pilcrow",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PilcrowCore", targets: ["PilcrowCore"]),
        .executable(name: "Pilcrow", targets: ["PilcrowApp"]),
    ],
    targets: [
        // Pure logic: no AppKit, no capture, no audio. Everything here runs under `swift test`.
        .target(name: "PilcrowCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        // Thin macOS shell: windows, hotkey, capture, microphone. Depends on Core, never the reverse.
        .executableTarget(name: "PilcrowApp", dependencies: ["PilcrowCore"]),
        .testTarget(name: "PilcrowCoreTests", dependencies: ["PilcrowCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    swiftLanguageModes: [.v5]
)
