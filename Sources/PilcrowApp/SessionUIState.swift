import Foundation

/// Delays only the visible ring and crosshair, so typing capitals does not flash them.
/// Mouse capture never waits for it: see `PointerTargets`.
struct ShiftArming {
    static let delay: TimeInterval = 0.200
    private var heldSince: TimeInterval?
    private(set) var isArmed = false

    @discardableResult
    mutating func update(shiftHeld: Bool, now: TimeInterval, mouseDown: Bool = false) -> Bool {
        guard shiftHeld else { heldSince = nil; isArmed = false; return false }
        if heldSince == nil { heldSince = now }
        if mouseDown || now - (heldSince ?? now) >= Self.delay { isArmed = true }
        return isArmed
    }
}

/// Which display takes the mouse and which shows the ring.
/// The canvas captures the mouse as soon as ⇧ alone is held, so an early ⇧-click or ⇧-drag
/// never reaches the app underneath; the ring and crosshair wait for `ShiftArming`.
struct PointerTargets<Display: Equatable>: Equatable {
    let capture: Display?
    let ring: Display?

    init(activeStroke: Display?, underPointer: Display?, aboveToolbar: Bool, shiftHeld: Bool, armed: Bool) {
        if let activeStroke {
            capture = activeStroke
            ring = activeStroke
        } else if aboveToolbar {
            capture = nil
            ring = nil
        } else {
            capture = shiftHeld ? underPointer : nil
            ring = shiftHeld && armed ? underPointer : nil
        }
    }
}

struct ReceiptText: Equatable {
    let status: String
    let detail: String
    var announcement: String { status + ". " + detail }

    init(marks: Int, copied: Bool, saveFailed: Bool) {
        status = saveFailed ? (copied ? "Couldn’t save · copied" : "Couldn’t save or copy")
            : (copied ? "Copied · ⌘V" : "Couldn’t copy")
        detail = marks == 0 ? "Words only · click to review"
            : "\(marks) \(marks == 1 ? "mark" : "marks") · click to review"
    }
}

struct UndoAvailability {
    static func shouldRegister(markCount: Int, drawing: Bool) -> Bool { markCount > (drawing ? 1 : 0) }
}
