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

## From the voice robustness review (low)

- **Provisional words outside a later final result's range are promoted at drain** (VoiceSegment ~36-54, ~194); a word the recognizer revised away could survive as final. Consider dropping provisional words before the finalization time instead.
- **Leading straight apostrophe** (`'tis`, `'90s`) opens quote state, so a later standalone `'` attaches back (VoiceTiming ~82).
- **`&` and dashes** attach forward and lose their space (`&roll`, `—maybe`) (VoiceTiming ~55, ~74).
- **No timeout on `preferredFormat()` / `prepare`**: a hang leaves the dot dim with no error (Finish still works) (VoiceNarration ~120-131). Add a ~10 s timeout reporting `.analyzer`.
- **First analyzer error before input runs out stops narration immediately** (VoiceNarration ~52-54); intended, revisit if live tests show it.

## D-25 live calibration

- The live loose oval around a chat bubble, about 180 × 100 pt, and wavy box around an input, about 290 × 95 pt, both stayed freeform. The two arrows worked. No original raw samples were available. Do not tune the recognizer further until new live records are collected.
- Fable 5.2 rejected the roughness-gated loose fallback. The high synthetic positive rates depended on ±0.55 pt white noise; smooth live-like ovals moved only 71%→75%, and boxes 11%→32%. The fallback, its smoothing and its positive-only calibration fixtures have been removed. Round-2 fits and independent ≤16 pt lead-in/exit trimming remain. Lollipops with long departures return to plain marks when closure fails.
- Local schema-2 `strokes.json` now preserves full-precision frame points, original sample counts, stored classifications, frame size/display scale, timing and a recognition-rules version. It keeps all samples through 5,000 per stroke, explicitly labels uniform decimation above that, and skips recording above 5,000,000 bytes per capture. Recording/copy failure is best effort. It stays out of clipboard, agent and MCP attachments and follows capture retention. See [schema and replay helper](core.md#shape-recognition-d-25).
- On recorded live strokes, investigate least-squares ellipse and rectangle fits, comparing residual with the next-best model rather than a jitter gate. Require four corner turns for rectangles, reject a single large protrusion or tail, and cap frame-aligned bounds inflation against a rotated fit. Calibrate model margins with both desired tidies and the negative cases below. This is future work, not implemented rules.
- Retained synthetic negatives each produce 0/100 tidied strokes for triangles, blobs, three-sided strokes, scribbles, rotated ovals and rotated boxes. The reviewer thin-box corpus still gives 139/300 rectangles at 2 pt corner noise. Neither result establishes live success. Earlier round-2 mutation-killing regressions remain, including hook-window, ellipse-inflation and pin-badge cases.

Fable's rejected-fallback negative corpus is preserved below as the next calibration checklist. These are reviewer-reported rates for the removed implementation, not measurements of the restored rules. The supplied review did not include denominators; ranges cover different probes, not confidence intervals.

| Negative case | Wrong tidy reported with removed fallback |
| --- | --- |
| D-shapes | 92% ellipse |
| Speech bubbles with tails | 82–85% |
| Beans | 99% |
| Blobs | 33% |
| Teardrops | 89% |
| Parallelograms | 59–87% |
| Notched boxes | 87% |
| Rounded triangles | 23% |
| Rectangles rotated 8° | 46% oversized tidy |
| Blobs larger than 800 pt | 36–39%, even with smooth input |
| Capsules | Flipped ellipse→rectangle; no rate supplied |

- Draw the failed oval and box again, and retain the local recording with the observed result before adjusting thresholds. Check rounded rectangles/capsules for the desired kind.
- Check U-turn drags from pins and areas, and arrows that already have a barb drawn at the tip. Watch for misleading or duplicate arrowheads and keep live examples for future calibration.

### strokes.json follow-ups (Fable 5.2, 2026-11-21, low)
- Add a tested record-to-`Stroke` helper (or record `badgeAnchor`) so arrow context replays from the file alone (`StrokeRecording.swift:54-57`).
- Pin replay exactness with a one-ulp round-trip fixture and a two-frame arrow case (`StrokeRecordingTests.swift:38-41`).
- Hook-trim upper bounds: assert a 6 pt near-miss is not trimmed (`ShapeRecognizerTests.swift:697`).
- Pre-check total points before encoding instead of discarding after a 5 MB overrun (`Export.swift:229-240`).
- Per-sample timestamps would need a schema bump if speed-based rules are tried.

## D-28 shape follow-up

- Wide, thin boxes still miss tidy when small bows in the long edges exceed tolerances scaled to the short side. Calibrate with recorded strokes and check that a tidy fit preserves the drawn width.

## D-27 later

Fable 5.2 found these cases in synthetic voice probes.

- A pen-down within 0.3 s after a sentence that already has a mark can take its tail. Fable reported this in roughly 5% of the fast-paced synthetic cases.
- Draw, speak, undo, then redraw needs an undo timestamp to distinguish the original narration from new speech.
- A delay of more than 2.5 s between speech and its mark can shift the fix lines.
- On the first mark, speaking with a pause and then drawing can lose the part before the pause from the fix line.
- Clean up `What it is is` to `What it is` and `bigger, um.` to `bigger,`.
- A drain timeout after a shortened final result can drop the volatile tail.

### D-28 re-check follow-ups
- Two-barb heads need each barb within about 5 pt of the tip; a 14 pt limit helps but swallows more stray dashes (owner's call).
- The head rule at the start end of a shaft swallows a second short stroke from the same start about 90% of the time; consider requiring a two-legged V there.
- Undo grouping: a plain shaft plus V takes two undos, but shaft plus two barbs disappears in one. Treat all heads of a shaft as one group.
- The start end still has a hard 20 pt margin; consider a short look-back for strokes that already have a head or target.
- A V redrawn after undoing a head usually gets its own number, because the 3 s window runs from the shaft's pen-up.
- V-leg straightness uses arc length, so 0.5 pt sample jitter flips the owner's V about 22% of the time.
