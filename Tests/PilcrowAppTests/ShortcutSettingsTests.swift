import Carbon
import XCTest
@testable import PilcrowApp

final class ShortcutSettingsTests: XCTestCase {
    private let us = KeyboardLayout { code, modifiers in
        modifiers == 0 ? KeyChord.usNames[code]?.lowercased() : nil
    }
    private func chord(_ key: Int, _ modifiers: Int = 0) -> KeyChord {
        KeyChord(keyCode: UInt32(key), modifiers: UInt32(modifiers))
    }

    func testStartCannotTakePasteOrTerminalInterrupt() {
        XCTAssertNotNil(chord(kVK_ANSI_V, cmdKey).validationError(layout: us))
        XCTAssertNotNil(chord(kVK_ANSI_C, controlKey).validationError(layout: us))
    }

    func testDefaultsAreTwoKeyChords() {
        XCTAssertEqual(KeyChord.startDefault(layout: us), chord(kVK_ANSI_D, optionKey))
        XCTAssertEqual(KeyChord.undoDefault(layout: us), chord(kVK_ANSI_Z, cmdKey))
        XCTAssertNil(KeyChord.startDefault.validationError(other: .undoDefault))
        XCTAssertNil(KeyChord.undoDefault.validationError(other: .startDefault, action: .undo))
    }

    func testEachSingleAllowedModifierWorks() {
        for modifier in [cmdKey, optionKey, controlKey] {
            XCTAssertNil(chord(kVK_ANSI_K, modifier).validationError(layout: us))
        }
    }

    func testAllTwentyBareFunctionKeysWorkAndFormat() {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in codes.enumerated() {
            XCTAssertNil(chord(code).validationError(layout: us))
            XCTAssertEqual(chord(code).glyph(layout: us), "F\(index + 1)")
        }
    }

    func testShiftIsReservedEvenWithAnotherModifierOrFunctionKey() {
        for modifiers in [shiftKey, shiftKey | cmdKey, shiftKey | optionKey | controlKey] {
            XCTAssertEqual(chord(kVK_ANSI_D, modifiers).validationError(layout: us), "⇧ is reserved for drawing.")
            XCTAssertNotNil(chord(kVK_F6, modifiers).validationError(layout: us))
        }
    }

    func testMultipleModifiersAndUnknownModifierBitsAreRejected() {
        for modifiers in [cmdKey | optionKey, cmdKey | controlKey, optionKey | controlKey,
                          cmdKey | optionKey | controlKey, alphaLock, 1 << 25] {
            XCTAssertNotNil(chord(kVK_ANSI_D, modifiers).validationError(layout: us))
        }
    }

    func testUnmodifiedLetterAndSpaceAreRejectedButModifiedSpaceWorks() {
        XCTAssertNotNil(chord(kVK_ANSI_D).validationError(layout: us))
        XCTAssertNotNil(chord(kVK_Space).validationError(layout: us))
        XCTAssertNil(chord(kVK_Space, optionKey).validationError(layout: us))
        XCTAssertEqual(chord(kVK_Space, optionKey).glyph(layout: us), "⌥Space")
    }

    func testReservedKeysAreRejectedWithOrWithoutModifier() {
        for code in [kVK_Escape, kVK_Return, kVK_Tab, kVK_ANSI_KeypadEnter] {
            for modifier in [0, cmdKey, optionKey, controlKey] {
                XCTAssertNotNil(chord(code, modifier).validationError(layout: us))
            }
        }
    }

    func testModifierKeysAndUnknownHardwareCodesAreRejected() {
        for code in [kVK_Command, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
                     kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function, 255] {
            XCTAssertNotNil(chord(code, cmdKey).validationError(layout: us))
        }
    }

    func testDuplicateShortcutIsRejected() {
        XCTAssertEqual(KeyChord.startDefault.validationError(other: .startDefault),
                       "That shortcut is already used by the other action.")
    }

    func testGlyphsUseStandardModifierAndKeyNames() {
        XCTAssertEqual(KeyChord.startDefault(layout: us).glyph(layout: us), "⌥D")
        XCTAssertEqual(KeyChord.undoDefault(layout: us).glyph(layout: us), "⌘Z")
        XCTAssertEqual(chord(kVK_F6).glyph(layout: us), "F6")
        XCTAssertEqual(chord(kVK_LeftArrow, controlKey).glyph(layout: us), "⌃←")
        XCTAssertEqual(chord(kVK_F20, optionKey).glyph(layout: us), "⌥F20")
        XCTAssertEqual(chord(kVK_ANSI_Backslash, cmdKey).glyph(layout: us), "⌘\\")
    }

    func testDecodeRoundTrip() throws {
        let start = chord(kVK_F6)
        let undo = chord(kVK_ANSI_K, controlKey)
        XCTAssertEqual(ShortcutSettings.decode(start: try JSONEncoder().encode(start), undo: try JSONEncoder().encode(undo)),
                       ShortcutSettings(start: start, undo: undo))
    }

    func testMissingMalformedAndInvalidPersistenceFallBackIndependently() throws {
        XCTAssertEqual(ShortcutSettings.decode(start: nil, undo: nil), ShortcutSettings())
        let valid = try JSONEncoder().encode(chord(kVK_F6))
        for invalid in [Data("bad".utf8), Data("{}".utf8), try JSONEncoder().encode(chord(kVK_ANSI_D)),
                        Data(#"{"keyCode":-1,"modifiers":0}"#.utf8)] {
            XCTAssertEqual(ShortcutSettings.decode(start: invalid, undo: valid),
                           ShortcutSettings(undo: chord(kVK_F6)))
            XCTAssertEqual(ShortcutSettings.decode(start: valid, undo: invalid),
                           ShortcutSettings(start: chord(kVK_F6)))
        }
    }

    func testDuplicateSavedValuesAlwaysProduceDistinctValidFallbacks() throws {
        for value in [KeyChord.startDefault, .undoDefault, chord(kVK_F6)] {
            let data = try JSONEncoder().encode(value)
            let result = ShortcutSettings.decode(start: data, undo: data)
            XCTAssertNotEqual(result.start, result.undo)
            XCTAssertNil(result.start.validationError(other: result.undo))
            XCTAssertNil(result.undo.validationError(other: result.start, action: .undo))
        }
    }

    func testInjectedDefaultsPersistWithoutUsingStandardDomain() throws {
        let name = "PilcrowTests.Shortcuts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ShortcutSettings(start: chord(kVK_F6), undo: chord(kVK_ANSI_K, controlKey))
        settings.save(to: defaults)
        XCTAssertEqual(ShortcutSettings.load(from: defaults), settings)
    }

    func testHintAppearsInExactlyFirstThreeSessions() {
        var count = 0
        var visibility: [Bool] = []
        for _ in 0..<6 {
            let session = SessionHint(previousCount: count)
            visibility.append(session.showsHint)
            count = session.nextCount
        }
        XCTAssertEqual(visibility, [true, true, true, false, false, false])
        XCTAssertEqual(count, 3)
    }

    func testFirstStrokeHidesHintForRestOfSession() {
        var hint = SessionHint(previousCount: 0)
        XCTAssertTrue(hint.showsHint)
        hint.strokeStarted()
        XCTAssertFalse(hint.showsHint)
        hint.strokeStarted()
        XCTAssertFalse(hint.showsHint)
        XCTAssertEqual(hint.nextCount, 1)
    }

    func testHintCounterHandlesNegativeAndHugeSavedCounts() {
        XCTAssertTrue(SessionHint(previousCount: -1).showsHint)
        XCTAssertEqual(SessionHint(previousCount: -1).nextCount, 1)
        XCTAssertFalse(SessionHint(previousCount: Int.max).showsHint)
        XCTAssertEqual(SessionHint(previousCount: Int.max).nextCount, 3)
    }
}
