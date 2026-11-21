import Carbon
import Foundation
import XCTest
@testable import PilcrowApp

final class UIReviewFixTests: XCTestCase {
    private let us = KeyboardLayout { code, modifiers in
        guard modifiers == 0 else { return nil }
        return KeyChord.usNames[code]?.lowercased()
    }
    private func layout(_ changes: [UInt32: String]) -> KeyboardLayout {
        KeyboardLayout { code, modifiers in
            guard modifiers == 0 else { return nil }
            return changes[code] ?? KeyChord.usNames[code]?.lowercased()
        }
    }
    private func chord(_ code: Int, _ modifiers: Int) -> KeyChord {
        KeyChord(keyCode: UInt32(code), modifiers: UInt32(modifiers))
    }
    private func assertDefaults(_ layout: KeyboardLayout, d: UInt32, z: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        let start = KeyChord.startDefault(layout: layout)
        let undo = KeyChord.undoDefault(layout: layout)
        XCTAssertEqual(start.keyCode, d, file: file, line: line)
        XCTAssertEqual(undo.keyCode, z, file: file, line: line)
        XCTAssertEqual(start.glyph(layout: layout), "⌥D", file: file, line: line)
        XCTAssertEqual(undo.glyph(layout: layout), "⌘Z", file: file, line: line)
    }
    func testUSDefaultsFollowCharacters() { assertDefaults(us, d: 2, z: 6) }
    func testGermanDefaultsFollowCharacters() { assertDefaults(layout([6: "y", 16: "z"]), d: 2, z: 16) }
    func testFrenchDefaultsFollowCharacters() { assertDefaults(layout([0: "q", 12: "a", 6: "w", 13: "z"]), d: 2, z: 13) }
    func testDvorakDefaultsFollowCharacters() { assertDefaults(layout([2: "e", 4: "d", 6: ";", 44: "z"]), d: 4, z: 44) }
    /// Translators that honour modifiers, like UCKeyTranslate: ⌘ gives Latin letters.
    private func commandLatin(_ plain: [UInt32: String]) -> KeyboardLayout {
        KeyboardLayout { code, modifiers in
            let latin = KeyChord.usNames[code]?.lowercased()
            if modifiers == UInt32(cmdKey) { return latin }
            if modifiers == UInt32(controlKey) {
                guard let latin, let scalar = latin.unicodeScalars.first, latin.count == 1,
                      ("a"..."z").contains(latin), let control = Unicode.Scalar(scalar.value - 0x60) else { return nil }
                return String(Character(control))
            }
            return modifiers == 0 ? plain[code] ?? latin : nil
        }
    }
    func testRussianDeniesCommonChordsAndLabelsCommandChordsInLatin() {
        let russian = commandLatin([2: "в", 6: "я", 8: "с", 9: "м", 12: "й", 13: "ц"])
        XCTAssertEqual(KeyChord.undoDefault(layout: russian).keyCode, 6)
        XCTAssertEqual(KeyChord.undoDefault(layout: russian).glyph(layout: russian), "⌘Z")
        XCTAssertEqual(KeyChord.startDefault(layout: russian).keyCode, 2)
        XCTAssertEqual(chord(12, cmdKey).glyph(layout: russian), "⌘Q")
        XCTAssertNotNil(chord(12, cmdKey).validationError(layout: russian))
        XCTAssertNotNil(chord(9, cmdKey).validationError(layout: russian))
        XCTAssertNotNil(chord(13, cmdKey).validationError(layout: russian))
        XCTAssertNotNil(chord(8, controlKey).validationError(layout: russian))
        XCTAssertEqual(chord(8, controlKey).glyph(layout: russian), "⌃C")
    }
    func testDvorakQwertyCommandUsesQwertyForCommandAndDvorakForOption() {
        let dvorakCommand = commandLatin([2: "e", 4: "d", 6: ";", 44: "z"])
        let undo = KeyChord.undoDefault(layout: dvorakCommand)
        XCTAssertEqual(undo.keyCode, 6)
        XCTAssertEqual(undo.glyph(layout: dvorakCommand), "⌘Z")
        let start = KeyChord.startDefault(layout: dvorakCommand)
        XCTAssertEqual(start.keyCode, 4)
        XCTAssertEqual(start.glyph(layout: dvorakCommand), "⌥D")
        XCTAssertNotNil(chord(9, cmdKey).validationError(layout: dvorakCommand))
    }
    func testSharpSIsNotExpandedAndCommandDeleteIsDeniedForStart() {
        XCTAssertEqual(chord(27, optionKey).glyph(layout: layout([27: "ß"])), "⌥ß")
        XCTAssertNotNil(chord(51, cmdKey).validationError(action: .annotate, layout: us))
    }
    func testUnavailableLayoutFallsBackToUS() { assertDefaults(KeyboardLayout { _, _ in nil }, d: 2, z: 6) }
    func testCustomPhysicalCodeStaysFixedButGlyphFollowsLayout() {
        let custom = chord(6, cmdKey)
        XCTAssertEqual(custom.glyph(layout: us), "⌘Z")
        XCTAssertEqual(custom.glyph(layout: layout([6: "y"])), "⌘Y")
        XCTAssertEqual(custom.glyph(layout: layout([6: "w"])), "⌘W")
        XCTAssertEqual(custom.glyph(layout: layout([6: ";"])), "⌘;")
        XCTAssertEqual(custom.keyCode, 6)
    }
    func testStoredCustomCodeSurvivesLayoutChangesEvenWhenCharacterBecomesReserved() throws {
        let custom = chord(6, cmdKey)
        let bytes = try JSONEncoder().encode(custom)
        let french = layout([6: "w", 13: "z"])
        let loaded = ShortcutSettings.decode(start: nil, undo: bytes, layout: french)
        XCTAssertEqual(loaded.chord(for: .undo, layout: french), custom)
        XCTAssertEqual(loaded.chord(for: .undo, layout: french).glyph(layout: french), "⌘W")
        XCTAssertNotNil(custom.validationError(action: .undo, layout: french), "New recordings still apply current-layout policy")
    }
    func testDefaultSettingsResolveAgainButCustomOverridesDoNot() {
        let german = layout([6: "y", 16: "z"])
        let defaults = ShortcutSettings()
        XCTAssertEqual(defaults.chord(for: .undo, layout: us).keyCode, 6)
        XCTAssertEqual(defaults.chord(for: .undo, layout: german).keyCode, 16)
        let custom = ShortcutSettings(undo: chord(6, cmdKey))
        XCTAssertEqual(custom.chord(for: .undo, layout: german).keyCode, 6)
    }
    func testOversizedStoredKeyCodeFallsBackWithoutTranslationTrap() throws {
        let invalid = try JSONEncoder().encode(KeyChord(keyCode: .max, modifiers: UInt32(cmdKey)))
        XCTAssertEqual(ShortcutSettings.decode(start: invalid, undo: nil), ShortcutSettings())
    }
    func testStartDeniesEveryStandardCommandCharacter() {
        let reserved = Array("qwhmcvxaszntfpor, .`").map(String.init) + ["\t"]
        for character in reserved {
            let translated = KeyboardLayout { code, _ in code == 2 ? character : nil }
            XCTAssertNotNil(chord(2, cmdKey).validationError(layout: translated), character)
        }
        XCTAssertEqual(chord(9, cmdKey).validationError(layout: us), "⌘V is Paste in every app.")
    }
    func testUndoAllowsCommandZButDeniesCommonCommands() {
        XCTAssertNil(chord(6, cmdKey).validationError(action: .undo, layout: us))
        for code in [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_V, kVK_ANSI_C, kVK_Tab, kVK_Space, kVK_ANSI_Grave] {
            XCTAssertNotNil(chord(code, cmdKey).validationError(action: .undo, layout: us))
        }
    }
    func testTerminalControlsUseTranslatedCharactersForStartOnly() {
        for character in ["c", "d", "z"] {
            let translated = KeyboardLayout { _, _ in character }
            XCTAssertNotNil(chord(2, controlKey).validationError(layout: translated))
            XCTAssertNil(chord(2, controlKey).validationError(action: .undo, layout: translated))
        }
        XCTAssertNil(chord(6, controlKey).validationError(layout: layout([6: "y"])))
    }
    func testDvorakCommandZIsAllowedForUndoAtItsPhysicalPosition() {
        let dvorak = layout([2: "e", 4: "d", 6: ";", 44: "z"])
        XCTAssertNotNil(chord(44, cmdKey).validationError(layout: dvorak))
        XCTAssertNil(chord(44, cmdKey).validationError(action: .undo, layout: dvorak))
        XCTAssertNil(chord(6, cmdKey).validationError(layout: dvorak))
    }
    func testOptionVisibleCharacterGetsNoteAndIsAllowed() {
        let translated = KeyboardLayout { code, modifiers in code == 2 ? (modifiers == 0 ? "d" : "∂") : nil }
        let candidate = chord(2, optionKey)
        XCTAssertNil(candidate.validationError(layout: translated))
        XCTAssertEqual(candidate.optionNote(layout: translated), "⌥D types ∂ in other apps; it won't while Pilcrow uses it.")
    }
    func testOptionInvisibleCharacterAndOtherModifiersGetNoNote() {
        for text in ["", " ", "\n", "\u{7F}"] {
            XCTAssertNil(chord(2, optionKey).optionNote(layout: KeyboardLayout { _, _ in text }))
        }
        XCTAssertNil(chord(2, cmdKey).optionNote(layout: KeyboardLayout { _, _ in "∂" }))
    }
    func testModifiedDeleteCanBeValidatedAndRecordedWithoutReset() {
        var committed = false
        let model = ShortcutRecorder(release: {}, register: { _, _ in true }, restore: {})
        // ⌘⌫ is denied as the always-on start shortcut, but a session-only Undo may use it.
        model.begin(.undo)
        let candidate = chord(kVK_Delete, cmdKey)
        XCTAssertNil(candidate.validationError(action: .undo, layout: us))
        XCTAssertFalse(candidate.isResetKey)
        XCTAssertTrue(chord(kVK_Delete, 0).isResetKey)
        XCTAssertTrue(chord(kVK_ForwardDelete, 0).isResetKey)
        XCTAssertTrue(model.accept(candidate, other: chord(kVK_F6, 0), layout: us) { committed = true })
        XCTAssertTrue(committed)
    }
    func testKeypadNamesAreDistinct() {
        XCTAssertEqual(chord(kVK_ANSI_Keypad1, optionKey).glyph(layout: us), "⌥Keypad 1")
        XCTAssertNotEqual(chord(kVK_ANSI_Keypad1, optionKey).glyph(layout: us), chord(kVK_ANSI_1, optionKey).glyph(layout: us))
    }
    func testRecorderReleasesProbesConflictThenRestoresWithoutCommit() {
        var events: [String] = []
        let model = ShortcutRecorder(release: { events.append("release") }, register: { action, candidate in
            XCTAssertEqual(action, .annotate)
            XCTAssertEqual(candidate.keyCode, UInt32(kVK_F6))
            events.append("candidate"); return false
        }, restore: { events.append("restore") })
        model.begin(.annotate)
        XCTAssertTrue(model.isRecording)
        XCTAssertFalse(model.accept(chord(kVK_F6, 0), other: chord(kVK_F7, 0), layout: us) { events.append("commit") })
        XCTAssertEqual(events, ["release", "candidate", "restore"])
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(model.message, "macOS or another app is using that shortcut.")
    }
    func testRecorderCommitsBeforeRestoreAndKeepsOptionNote() {
        var events: [String] = []
        let model = ShortcutRecorder(release: { events.append("release") }, register: { _, _ in events.append("candidate"); return true },
                                     restore: { events.append("restore") })
        model.begin(.undo)
        let translated = KeyboardLayout { _, modifiers in modifiers == 0 ? "d" : "∂" }
        XCTAssertTrue(model.accept(chord(2, optionKey), other: chord(kVK_F6, 0), layout: translated) { events.append("commit") })
        XCTAssertEqual(events, ["release", "candidate", "commit", "restore"])
        XCTAssertTrue(model.message.contains("types ∂"))
    }
    func testRecorderInvalidCandidateStaysReleasedUntilCancelAndRestoresOnce() {
        var events: [String] = []
        let model = ShortcutRecorder(release: { events.append("release") }, register: { _, _ in events.append("probe"); return true },
                                     restore: { events.append("restore") })
        model.begin(.annotate)
        XCTAssertFalse(model.accept(chord(9, cmdKey), other: chord(kVK_F6, 0), layout: us) { XCTFail("Must not save Paste") })
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(events, ["release"])
        model.stop(); model.stop()
        XCTAssertEqual(events, ["release", "restore"])
    }
    func testRecorderUnusableMediaEventShowsFnHint() {
        let model = ShortcutRecorder(release: {}, register: { _, _ in XCTFail("No candidate"); return false }, restore: {})
        model.begin(.annotate); model.unusableKey()
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(model.message, "Press fn with the F-key")
    }
    func testResetDefaultsRemovesPhysicalOverridesFromPersistence() throws {
        let name = "PilcrowTests.Shortcuts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ShortcutSettings(start: chord(kVK_F6, 0), undo: chord(kVK_F7, 0))
        settings.save(to: defaults)
        XCTAssertNotNil(defaults.data(forKey: ShortcutSettings.startKey))
        settings.reset(.annotate); settings.reset(.undo); settings.save(to: defaults)
        XCTAssertNil(defaults.data(forKey: ShortcutSettings.startKey))
        XCTAssertNil(defaults.data(forKey: ShortcutSettings.undoKey))
        XCTAssertEqual(ShortcutSettings.load(from: defaults), ShortcutSettings())
    }
    func testReceiptMarkedSuccessAndPluralization() {
        XCTAssertEqual(ReceiptText(marks: 1, copied: true, saveFailed: false).detail, "1 mark · click to review")
        let text = ReceiptText(marks: 3, copied: true, saveFailed: false)
        XCTAssertEqual(text.status, "Copied · ⌘V")
        XCTAssertEqual(text.announcement, "Copied · ⌘V. 3 marks · click to review")
    }
    func testReceiptSpeechOnlyAndFailureStates() {
        XCTAssertEqual(ReceiptText(marks: 0, copied: true, saveFailed: false).detail, "Words only · click to review")
        XCTAssertEqual(ReceiptText(marks: 0, copied: false, saveFailed: false).status, "Couldn’t copy")
        XCTAssertEqual(ReceiptText(marks: 2, copied: true, saveFailed: true).status, "Couldn’t save · copied")
        XCTAssertEqual(ReceiptText(marks: 2, copied: false, saveFailed: true).status, "Couldn’t save or copy")
    }
    func testRingWaitsForContinuousShiftDelay() {
        var state = ShiftArming()
        XCTAssertFalse(state.update(shiftHeld: true, now: 0))
        XCTAssertFalse(state.update(shiftHeld: true, now: ShiftArming.delay - 0.001))
        XCTAssertTrue(state.update(shiftHeld: true, now: ShiftArming.delay))
        XCTAssertFalse(state.update(shiftHeld: false, now: 1))
    }
    func testCapitalLetterTapDoesNotArmAndReleaseRestartsDelay() {
        var state = ShiftArming()
        XCTAssertFalse(state.update(shiftHeld: true, now: 0))
        XCTAssertFalse(state.update(shiftHeld: false, now: 0.08))
        XCTAssertFalse(state.update(shiftHeld: true, now: 0.10))
        XCTAssertFalse(state.update(shiftHeld: true, now: 0.10 + ShiftArming.delay - 0.001))
        XCTAssertTrue(state.update(shiftHeld: true, now: 0.10 + ShiftArming.delay))
    }
    func testMouseIsCapturedAsSoonAsShiftIsHeldButRingWaits() {
        let early = PointerTargets(activeStroke: nil, underPointer: 2, aboveToolbar: false, shiftHeld: true, armed: false)
        XCTAssertEqual(early.capture, 2)
        XCTAssertNil(early.ring)
        let armed = PointerTargets(activeStroke: nil, underPointer: 2, aboveToolbar: false, shiftHeld: true, armed: true)
        XCTAssertEqual(armed, PointerTargets(activeStroke: nil, underPointer: 2, aboveToolbar: false, shiftHeld: true, armed: true))
        XCTAssertEqual(armed.ring, 2)
        let released = PointerTargets(activeStroke: nil, underPointer: 2, aboveToolbar: false, shiftHeld: false, armed: false)
        XCTAssertNil(released.capture)
        XCTAssertNil(released.ring)
        let overPill = PointerTargets(activeStroke: nil, underPointer: 2, aboveToolbar: true, shiftHeld: true, armed: true)
        XCTAssertNil(overPill.capture)
        let drawing = PointerTargets(activeStroke: 1, underPointer: 2, aboveToolbar: true, shiftHeld: false, armed: false)
        XCTAssertEqual(drawing.capture, 1)
        XCTAssertEqual(drawing.ring, 1)
    }
    func testQuickShiftMouseDownArmsImmediatelyUntilRelease() {
        var state = ShiftArming()
        XCTAssertTrue(state.update(shiftHeld: true, now: 0, mouseDown: true))
        XCTAssertTrue(state.update(shiftHeld: true, now: 0.01))
        XCTAssertFalse(state.update(shiftHeld: false, now: 0.02))
        XCTAssertFalse(state.update(shiftHeld: false, now: 0.03, mouseDown: true))
    }
    func testUndoRegistrationOnlyHasCompletedUndoableMarks() {
        XCTAssertFalse(UndoAvailability.shouldRegister(markCount: 0, drawing: false))
        XCTAssertTrue(UndoAvailability.shouldRegister(markCount: 1, drawing: false))
        XCTAssertFalse(UndoAvailability.shouldRegister(markCount: 1, drawing: true))
        XCTAssertTrue(UndoAvailability.shouldRegister(markCount: 2, drawing: true), "Keep the handler while drawing over a completed mark; undo() ignores the drag")
        XCTAssertFalse(UndoAvailability.shouldRegister(markCount: 0, drawing: false))
        XCTAssertTrue(UndoAvailability.shouldRegister(markCount: 1, drawing: false))
    }
    func testStagedDiscardKeepsLockedItemOutOfRetentionUntilDeletion() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Pilcrow/Outbox")
        let store = OutboxStore(root: root)
        let id = UUID()
        let folder = try await store.prepare(id)
        try Data("synthetic".utf8).write(to: folder.appendingPathComponent("payload"))
        await store.releaseExport(id)
        let staged = try await store.beginDiscard(id)
        XCTAssertTrue(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let hidden = root.appendingPathComponent(".discarded-" + id.uuidString)
        try await store.prune(clearAll: true)
        XCTAssertEqual(try Data(contentsOf: hidden.appendingPathComponent("payload")), Data("synthetic".utf8))
        try await store.finishDiscard(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hidden.path))
    }
}
