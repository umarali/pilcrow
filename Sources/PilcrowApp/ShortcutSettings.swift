import Carbon
import Foundation

/// A snapshot translator, also injectable for deterministic layout tests.
struct KeyboardLayout {
    let translate: (UInt32, UInt32) -> String?

    static var current: Self {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return Self { _, _ in nil }
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return Self { code, modifiers in
            guard code <= 127 else { return nil }
            return data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return nil }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKey: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown),
                    (modifiers >> 8) & 0xFF, keyboardType, OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                    &deadKey, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
        }
    }

    func character(for code: UInt32, modifiers: UInt32 = 0) -> String? {
        translate(code, modifiers) ?? (modifiers == 0 ? KeyChord.usNames[code]?.lowercased() : nil)
    }

    /// The character a shortcut means, as apps match it: with ⌘ held, non-Latin layouts
    /// (Russian, Greek, Hebrew) and "Dvorak - QWERTY ⌘" produce Latin letters. ⌃ chords
    /// translate to control characters, mapped back to their letters.
    func shortcutCharacter(for code: UInt32, modifiers: UInt32) -> String? {
        if modifiers & UInt32(controlKey) != 0, let text = translate(code, UInt32(controlKey)),
           let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1,
           (1...0x1A).contains(scalar.value), let letter = Unicode.Scalar(scalar.value + 0x60) {
            return String(Character(letter))
        }
        if modifiers & UInt32(optionKey) == 0 || modifiers & UInt32(cmdKey) != 0 {
            if let text = translate(code, UInt32(cmdKey)), Self.isPrintable(text) { return text.lowercased() }
        }
        return character(for: code)?.lowercased()
    }

    func keyCode(for character: String, modifiers: UInt32, fallback: UInt32) -> UInt32 {
        // Defaults follow letters, never keypad keys or modifier/function keys.
        let codes = (0...50).map(UInt32.init)
        let wanted = character.lowercased()
        let unmodified = codes.first { translate($0, 0)?.lowercased() == wanted }
        let commanded = codes.first { translate($0, UInt32(cmdKey))?.lowercased() == wanted }
        return (modifiers & UInt32(cmdKey) != 0 ? commanded ?? unmodified : unmodified ?? commanded) ?? fallback
    }

    private static func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

struct KeyChord: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static var startDefault: Self { startDefault(layout: .current) }
    static var undoDefault: Self { undoDefault(layout: .current) }
    static func startDefault(layout: KeyboardLayout) -> Self {
        Self(keyCode: layout.keyCode(for: "d", modifiers: UInt32(optionKey), fallback: UInt32(kVK_ANSI_D)),
             modifiers: UInt32(optionKey))
    }
    static func undoDefault(layout: KeyboardLayout) -> Self {
        Self(keyCode: layout.keyCode(for: "z", modifiers: UInt32(cmdKey), fallback: UInt32(kVK_ANSI_Z)),
             modifiers: UInt32(cmdKey))
    }
    static let escape = KeyChord(keyCode: UInt32(kVK_Escape), modifiers: 0)
    private static let functionCodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                                 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let usNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        36: "Return", 48: "Tab", 49: "Space", 50: "`", 51: "⌫", 53: "Esc", 65: ".", 67: "*", 69: "+", 71: "⌧", 75: "/",
        78: "−", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6",
        89: "7", 91: "8", 92: "9", 93: "¥", 94: "_", 95: ",", 102: "英数", 104: "かな",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←",
        124: "→", 125: "↓", 126: "↑", 10: "§"
    ]
    private static let keypad: Set<UInt32> = [65, 67, 69, 71, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95]

    var isResetKey: Bool { modifiers == 0 && [UInt32(kVK_Delete), UInt32(kVK_ForwardDelete)].contains(keyCode) }
    var glyph: String { glyph(layout: .current) }
    func glyph(layout: KeyboardLayout) -> String {
        let prefix = (modifiers & UInt32(controlKey) != 0 ? "⌃" : "")
            + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "")
            + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
        if let index = Self.functionCodes.firstIndex(of: keyCode) { return prefix + "F\(index + 1)" }
        if Self.keypad.contains(keyCode) { return prefix + "Keypad " + (Self.usNames[keyCode] ?? "?") }
        let name = (keyCode < 51 && ![36, 48, 49].contains(keyCode)) || [93, 94].contains(keyCode)
            ? layout.shortcutCharacter(for: keyCode, modifiers: modifiers).map(Self.displayCase) : Self.usNames[keyCode]
        return prefix + (name ?? "?")
    }

    /// Upper-cases letters for display without expanding ß to "SS".
    private static func displayCase(_ text: String) -> String {
        let upper = text.uppercased()
        return upper.count == text.count ? upper : text
    }

    func validationError(other: KeyChord? = nil, action: HotKeys.Shortcut = .annotate,
                         layout: KeyboardLayout = .current) -> String? {
        if let error = structuralValidationError(other: other) { return error }
        let character = layout.shortcutCharacter(for: keyCode, modifiers: modifiers) ?? ""
        if modifiers == UInt32(cmdKey) {
            let common = ["q": "Quit", "w": "Close", "h": "Hide", "m": "Minimize", "c": "Copy", "v": "Paste",
                          "x": "Cut", "a": "Select All", "s": "Save", "z": "Undo", "n": "New", "t": "New Tab",
                          "f": "Find", "p": "Print", "o": "Open", "r": "Reload", ",": "Settings", ".": "Cancel",
                          " ": "Spotlight", "space": "Spotlight", "\t": "Switch Apps", "tab": "Switch Apps", "`": "Switch Windows"]
            if let meaning = common[character], !(action == .undo && character == "z") {
                return "\(glyph(layout: layout)) is \(meaning) in every app."
            }
            // Tab has a control character on some layouts and no translation on others.
            if keyCode == UInt32(kVK_Tab) { return "⌘Tab switches apps." }
            if action == .annotate, keyCode == UInt32(kVK_Delete) { return "⌘⌫ is Delete in every app." }
        }
        if action == .annotate, modifiers == UInt32(controlKey), ["c", "d", "z"].contains(character) {
            let meaning = ["c": "Interrupt", "d": "End of Input", "z": "Suspend"][character]!
            return "\(glyph(layout: layout)) is \(meaning) in terminals."
        }
        return nil
    }

    func structuralValidationError(other: KeyChord? = nil) -> String? {
        let allowed = UInt32(cmdKey | optionKey | controlKey)
        if modifiers & UInt32(shiftKey) != 0 { return "⇧ is reserved for drawing." }
        guard modifiers & ~allowed == 0 else { return "Use one of ⌘, ⌥ or ⌃." }
        guard ![36, 48, 53, 76].contains(keyCode) else { return "Esc, Return and Tab are reserved." }
        guard Self.usNames[keyCode] != nil || Self.functionCodes.contains(keyCode) else {
            return "Press fn with the F-key, or choose a key with ⌘, ⌥ or ⌃."
        }
        guard modifiers.nonzeroBitCount == 1 || (modifiers == 0 && Self.functionCodes.contains(keyCode)) else {
            return "Use one modifier and a key, or an F-key alone."
        }
        if self == other { return "That shortcut is already used by the other action." }
        return nil
    }

    func optionNote(layout: KeyboardLayout = .current) -> String? {
        guard modifiers == UInt32(optionKey), let text = layout.translate(keyCode, modifiers),
              !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) &&
                  !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return "\(glyph(layout: layout)) types \(text) in other apps; it won't while Pilcrow uses it."
    }
}

struct ShortcutSettings: Equatable, Sendable {
    private var customStart: KeyChord?
    private var customUndo: KeyChord?
    var start: KeyChord { get { chord(for: .annotate, layout: .current) } set { customStart = newValue } }
    var undo: KeyChord { get { chord(for: .undo, layout: .current) } set { customUndo = newValue } }
    func chord(for action: HotKeys.Shortcut, layout: KeyboardLayout) -> KeyChord {
        switch action {
        case .annotate: customStart ?? .startDefault(layout: layout)
        case .undo: customUndo ?? .undoDefault(layout: layout)
        case .escape: .escape
        }
    }
    init(start: KeyChord? = nil, undo: KeyChord? = nil) { customStart = start; customUndo = undo }
    mutating func reset(_ action: HotKeys.Shortcut) {
        if action == .annotate { customStart = nil } else if action == .undo { customUndo = nil }
    }
    static let startKey = "Shortcut.Start"
    static let undoKey = "Shortcut.Undo"

    static func decode(start: Data?, undo: Data?, layout: KeyboardLayout = .current) -> Self {
        func chord(_ data: Data?) -> KeyChord? {
            guard let data, let value = try? JSONDecoder().decode(KeyChord.self, from: data),
                  value.structuralValidationError() == nil else { return nil }
            return value
        }
        // Check structure only on load. A layout change must never remap a saved
        // physical chord because its new character has a different app meaning.
        var result = Self(start: chord(start), undo: chord(undo))
        if result.chord(for: .annotate, layout: layout) == result.chord(for: .undo, layout: layout) {
            result.customUndo = nil
            if result.chord(for: .annotate, layout: layout) == result.chord(for: .undo, layout: layout) { result.customStart = nil }
        }
        return result
    }
    static func load(from defaults: UserDefaults) -> Self {
        decode(start: defaults.data(forKey: startKey), undo: defaults.data(forKey: undoKey))
    }
    func save(to defaults: UserDefaults) {
        for (key, value) in [(Self.startKey, customStart), (Self.undoKey, customUndo)] {
            if let value { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}

/// No AppKit events or Carbon registration needed to exercise release/probe/restore.
final class ShortcutRecorder {
    private(set) var recording: HotKeys.Shortcut?
    private(set) var message = ""
    var isRecording: Bool { recording != nil }
    private let release: () -> Void
    private let register: (HotKeys.Shortcut, KeyChord) -> Bool
    private let restore: () -> Void

    init(release: @escaping () -> Void, register: @escaping (HotKeys.Shortcut, KeyChord) -> Bool,
         restore: @escaping () -> Void) {
        self.release = release; self.register = register; self.restore = restore
    }
    func begin(_ action: HotKeys.Shortcut) {
        stop()
        recording = action
        message = "Esc cancels · Delete resets to default"
        release()
    }
    func unusableKey() { message = "Press fn with the F-key" }
    @discardableResult
    func accept(_ chord: KeyChord, other: KeyChord, layout: KeyboardLayout = .current, commit: () -> Void) -> Bool {
        guard let recording else { return false }
        if let error = chord.validationError(other: other, action: recording, layout: layout) {
            message = error; return false
        }
        guard register(recording, chord) else {
            stop()
            message = "macOS or another app is using that shortcut."
            return false
        }
        commit()
        stop()
        message = chord.optionNote(layout: layout) ?? ""
        return true
    }
    func stop() {
        guard isRecording else { return }
        recording = nil
        message = ""
        restore()
    }
}

struct SessionHint: Equatable {
    static let defaultsKey = "DrawingHint.SessionCount"
    private(set) var showsHint: Bool
    let nextCount: Int

    init(previousCount: Int) {
        let count = max(0, previousCount)
        showsHint = count < 3
        nextCount = min(count, 3) + (count < 3 ? 1 : 0)
    }

    mutating func strokeStarted() { showsHint = false }
}
