import Carbon

final class HotKeys {
    enum Shortcut: UInt32 {
        case annotate = 1
        case escape
        case undo

        var label: String {
            switch self {
            case .annotate: "⇧⌥⌘J"
            case .escape: "Esc"
            case .undo: "⌘Z"
            }
        }

        fileprivate var chord: (key: Int, modifiers: Int) {
            switch self {
            // Avoid common shortcuts and VoiceOver's Control–Option.
            case .annotate: (kVK_ANSI_J, cmdKey | shiftKey | optionKey)
            case .escape: (kVK_Escape, 0)
            case .undo: (kVK_ANSI_Z, cmdKey)
            }
        }
    }

    private struct Registration {
        let ref: EventHotKeyRef
        let pressed: @MainActor () -> Void
    }

    private static let signature: OSType = 0x50696C63 // Pilc
    private var handler: EventHandlerRef?
    private var registrations: [Shortcut: Registration] = [:]

    @MainActor
    func register(_ shortcut: Shortcut, pressed: @escaping @MainActor () -> Void) -> Bool {
        precondition(registrations[shortcut] == nil)
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

        let chord = shortcut.chord
        let id = EventHotKeyID(signature: Self.signature, id: shortcut.rawValue)
        var ref: EventHotKeyRef?
        guard RegisterEventHotKey(UInt32(chord.key), UInt32(chord.modifiers), id, target,
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
