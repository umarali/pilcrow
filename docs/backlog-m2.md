# Milestone 2 backlog

Open findings from the Opus 5.5 reviews on 2026-11-20, carried into milestone 2 (wiring the App to Core). None blocks a live test of milestone 1. Remove an item when it is fixed, and say which test proves it.

## Core

The Core API and test items that were here were fixed in wave 1 (Sol 6.1, reviewed by Opus 5.5 on 2026-11-20; 113 tests). Remaining Core follow-ups are in progress and tracked in the wave 1 fix brief.

## App

- **Capture colour space:** `SCStreamConfiguration` never sets `colorSpaceName`, so P3 may be clipped at capture. Set it to the display's colour space; log when burn-in falls back to sRGB.
- **System consent sheet:** recent macOS may show "keep allowing screen recording" on the first `SCShareableContent` call, possibly under the overlay. If the live test shows it, detect it and hide the panels as the request path does.
- **Robustness:** comment that a stuck ScreenCaptureKit call cannot be cancelled (small leak, Finish still bounded); `precondition(waiter == nil)` in `PassFrame.result()`.
- **Toolbar placement:** reposition the toolbar when the screen's `visibleFrame` changes (Dock resize), not only on display changes.

## From the first live test and the D-15 fix review

- **Signed `Pilcrow.app` bundle (D-08).** As a bare executable launched from Terminal, Screen Recording is most likely attributed to Terminal, not Pilcrow. Build a proper `.app` with a bundle ID, `Info.plist` usage strings and a stable local signing identity so permissions attach to Pilcrow and survive rebuilds.
- **Capture outcome logs at `.notice`.** "display missing", "geometry changed", "dimensions differ" and similar log at `.info`, which `log show` often drops. Raise them to `.notice`.
- **Error codes for non-ScreenCaptureKit errors.** `Capture.swift:82` logs only the step; also log `(error as NSError).domain` and `.code` as public.
- **"Requested once" flag vs a permission reset.** After `tccutil reset ScreenCapture` the flag stays set, so the next Enable… shows the prompt and opens Settings together. Consider clearing the flag when preflight shows no record, or document it.
- **Log why a session finished** (hotkey, Finish, display change, Enable…).
- **Enforce Swift 6 checking.** The package builds in Swift 5 mode; strict-concurrency builds are clean but not enforced. Switch the targets to `.swiftLanguageMode(.v6)` or add the strict flag in CI.

## From the wave 1 App review (low, after the live test)

- **Poll can clip a normal stroke.** The 60 Hz button poll can end a stroke just before its own mouse-up arrives (lost last point, misleading log line). End the stroke only after the button reads up on two consecutive polls or ~50 ms after the last canvas mouse event.
- **Start does nothing while a permission request or Quit & Reopen is in flight.** Show the permissions window instead of returning silently.
- **Cursor restore** may force an arrow over the app underneath after ⇧ is released; only reset the cursor if the crosshair was set.
- **Export-failure message** omits the "Screen Recording off" note when frames also failed for permission.
- **Stray file** `Tests/PilcrowCoreTests/test-results.log` triggers a SwiftPM "unhandled file" warning; delete it or exclude it.


## From the wave 2 wiring review (low)

- **⌘Z during a drag** deletes the in-progress stroke but keeps `activeStroke`, so the rest of the drag is dropped. Ignore undo while a stroke is active, or end it first (AnnotationSession ~234).
- **Pill error never clears** after a later stroke succeeds (Toolbar ~74). Clear it on the next successful pen-down.
- **`message.md` can name files that failed to write.** The approval preview must reconcile the text with the files actually written (Export ~158).
- **Overlay badge vs export badge size** differ (20 pt live vs about 23.5 pt at 2× / 29 pt at 1× exported, from the 24 px minimum). Allowed by the contract; consider matching the live badge to the export.
