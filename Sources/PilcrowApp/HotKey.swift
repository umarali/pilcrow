import Carbon

final class HotKeys {
    enum Shortcut: UInt32 {
        case annotate = 1
        case escape
        case undo

        var defaultChord: KeyChord {
            switch self {
            case .annotate: .startDefault
            case .escape: .escape
            case .undo: .undoDefault
            }
        }

    }

    private struct Registration {
        let ref: EventHotKeyRef
        let pressed: @MainActor () -> Void
    }

    private static let signature: OSType = 0x50696C63 // Pilc
    var settings = ShortcutSettings.load(from: .standard)
    func chord(for shortcut: Shortcut) -> KeyChord {
        switch shortcut {
        case .annotate: settings.start
        case .undo: settings.undo
        case .escape: .escape
        }
    }
    func label(for shortcut: Shortcut) -> String {
        shortcut == .escape ? "Esc" : chord(for: shortcut).glyph
    }

    private var handler: EventHandlerRef?
    private var registrations: [Shortcut: Registration] = [:]

    func isRegistered(_ shortcut: Shortcut) -> Bool { registrations[shortcut] != nil }

    @MainActor
    func register(_ shortcut: Shortcut, chord proposed: KeyChord? = nil, pressed: @escaping @MainActor () -> Void) -> Bool {
        unregister(shortcut)
        let chord = proposed ?? chord(for: shortcut)
        // Preserve saved physical keys across layouts, but never take a newly
        // reserved app/terminal command when restoring or refreshing registration.
        guard shortcut == .escape || chord.validationError(action: shortcut) == nil else { return false }
        let target = GetApplicationEventTarget()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            guard InstallEventHandler(target, { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == HotKeys.signature,
                      let shortcut = Shortcut(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
                let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard let pressed = hotKeys.registrations[shortcut]?.pressed else {
                        return OSStatus(eventNotHandledErr)
                    }
                    pressed()
                    return noErr
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        }

        let id = EventHotKeyID(signature: Self.signature, id: shortcut.rawValue)
        var ref: EventHotKeyRef?
        guard RegisterEventHotKey(chord.keyCode, chord.modifiers, id, target,
                                  UInt32(kEventHotKeyExclusive), &ref) == noErr, let ref else { return false }
        registrations[shortcut] = Registration(ref: ref, pressed: pressed)
        return true
    }

    @MainActor
    func unregister(_ shortcut: Shortcut) {
        if let registration = registrations.removeValue(forKey: shortcut) {
            UnregisterEventHotKey(registration.ref)
        }
    }

    deinit {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
