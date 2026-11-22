import Foundation
import XCTest
@testable import PilcrowApp

final class PilcrowColourTests: XCTestCase {
    func testMissingAndUnknownPreferencesDefaultToCoral() throws {
        let name = "PilcrowColourTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PilcrowColour.load(from: defaults), .coral)
        defaults.set("unknown", forKey: PilcrowColour.defaultsKey)
        XCTAssertEqual(PilcrowColour.load(from: defaults), .coral)
    }

    @MainActor
    func testSelectingSwatchesPersistsEachChoice() throws {
        let name = "PilcrowColourTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsPresentation()
        model.colourChanged = { $0.save(to: defaults) }
        for choice in PilcrowColour.allCases.dropFirst() + [.coral] {
            model.selectColour(choice)
            XCTAssertEqual(model.colour, choice)
            XCTAssertEqual(try PilcrowColour.load(from: XCTUnwrap(UserDefaults(suiteName: name))), choice)
        }
    }
}
