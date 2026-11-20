# Status

What has been done, and how it was checked. Only these words are used: **live-verified** (run by a person on a real Mac), **unit-tested**, **built**, **untested**.

Last updated 2026-11-20.

| Area | State |
|---|---|
| Package skeleton (Core, App, tests) | built |
| Core: session model, numbering, undo, pending/failed frames, seal | unit-tested (160 tests, 0 failures; Swift 6 mode; reviewed by Opus 5.5 with mutation testing) |
| Core: per-mark fix list, single message builder, frame and crop plans, App wiring contract | unit-tested; Opus 5.5: ready for App wiring (wave 2) |
| Core: speech-to-mark alignment (`Aligner`) | unit-tested on synthetic words and strokes only; real speech timing untested |
| Core: transcript rendering, message builder | unit-tested |
| Core: geometry (point flip, scale, size caps) | unit-tested; caps 1600 px / 1.56 MP and 24 px badges (D-17.5) |
| App: menu-bar item, hotkey (default ⇧⌥⌘J), overlay panels | built; wave 1 drawing live-verified as described below |
| App: screen capture excluding Pilcrow's windows (5 s timeout) and private export cleanup | built; wave 1 capture and PNG export live-verified as described below |
| App: live test 2026-11-20, Screen Recording not granted | **failed**: a modal permission alert after the first stroke locked out the mouse (see D-15). Fix built (0 warnings) and reviewed by Opus 5.5; awaiting a live re-test |
| App: live test 2 (2026-11-20 22:57, wave 1 build, signed `Pilcrow.app`, Screen Recording granted) | **passed**: hotkey start → permission probe passed → overlay → hold-⇧ drawing (2 marks) → capture on the first stroke (display 2, overlay excluded) → Esc finish → 1 PNG, 1600×900, opaque, display colour profile kept, export folder mode 700, badges 1 and 2 legible and correctly placed. Not exercised: denial and Quit & Reopen flows, ⌘Z undo, new pass after click/scroll, multiple displays, full-screen Space, Dock changes |
| App: live test 3 (2026-11-21 00:17, wave 2 App↔Core wiring, signed `Pilcrow.app`) | **passed**: permission kept across a rebuild (stable signing identity); two displays (2× laptop, 1× external) each captured on first stroke; undo removed marks 2 and 3 and numbering continued at 4 (no reuse); export: `frame-1.png` 1549×1006 and `frame-2.png` 1600×900 (opaque, capped), `mark-1.png` 641×667 (320×333 pt at 2×) and `mark-4.png` 321×201 (320×200 pt at 1×), `message.md` with the per-mark list; marks and badges correctly placed in frames and crops; overlay excluded; folder mode 700. Not exercised: new pass after click/scroll, denied/timeout captures, full-screen Space |
| App: Core session wiring for timing, capture outcomes, drawing, undo and clear pass | built; wave 2 live test pending |
| App: sealed Core message export, annotated originals, per-mark crop PNGs and `message.md` | built; wave 2 live test pending |
| Speech and word timing | not started (word timestamps from SpeechAnalyzer are unverified, see D-06) |
| Handoff to an agent | not started |
| CI workflow | untested (never run on GitHub) |
| Signing and release | not started |

## Next

1. A person runs the [Wave 2 wiring checks](live-test-m1.md#wave-2-wiring) and the remaining Screen Recording, full-screen and mixed-Retina checks.
2. Build the approval preview, then direct delivery as described in the [roadmap](roadmap.md).
3. Check SpeechAnalyzer word timing for D-06.
