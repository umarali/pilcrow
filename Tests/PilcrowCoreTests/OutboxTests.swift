import XCTest
import Foundation
@testable import PilcrowCore

final class OutboxTests: XCTestCase {
    func testManifestRoundTripAndDateAndDestinations() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = OutboxManifest(createdAt: date, destination: .mcp, text: "approved", attachments: [.init(name: "mark-1.png", kind: .crop, mark: 1)])
        let data = try OutboxManifest.encoder().encode(manifest)
        XCTAssertEqual(try OutboxManifest.decoder().decode(OutboxManifest.self, from: data), manifest)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("2023-11-14T22:13:20Z"))
        XCTAssertEqual(Destination.allCases.map(\.rawValue), ["clipboard", "codex-cli", "claude-code", "mcp"])
    }
}
