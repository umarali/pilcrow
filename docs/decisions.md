# Decision log

Each entry records what was decided, who decided it, why, and what was turned down. "User" means the maintainer chose explicitly; "Claude" means Claude proposed and the maintainer accepted it by building on it. Entries are append-only: a reversed decision gets a new entry that supersedes it.

Status values: **Active**, **Proposed** (not yet confirmed), **Superseded by D-xx**, **Open** (needs a decision).

The format and several lessons come from the maintainer's earlier project, Benji.

---

### D-01 · Core holds identity, timing, geometry and message assembly; the App holds macOS APIs
- **When / who:** 2026-11-20 · Claude, from the Benji package split
- **Why:** Keeps everything that matters testable under `swift test` with no windows, microphone or permissions.
- **Status:** Active.

### D-02 · Toggle annotation with a configurable Carbon chord plus a menu command
- **When / who:** 2026-11-20 · Claude, from Benji D-28, D-41, D-42, D-139
- **Why:** `RegisterEventHotKey` needs no Input Monitoring or Accessibility. A toggle (not hold) leaves the drawing hand free. The menu command is the fallback if registration fails.
- **Status:** Proposed.

### D-03 · A mark gets a stable number at stroke start; undo removes its transcript reference too
- **When / who:** 2026-11-20 · Claude
- **Why:** Numbers are never recycled, so `[n]` in the words always matches the badge in the image.
- **Status:** Proposed.

### D-04 · Bind each mark to a timestamped frame and a display; burn red strokes and numbers into the exported pixels once
- **When / who:** 2026-11-20 · Claude, from Benji D-50, D-96
- **Why:** What the user saw and what the agent receives must match. Capture excludes the overlay, then Core Graphics draws the stored strokes onto the image.
- **Status:** Proposed.

### D-05 · Align pen events and audio on one monotonic session clock; insert `[n]` after the word being spoken at stroke-down
- **When / who:** 2026-11-20 · Claude
- **Why:** Deterministic and explainable. In silence the number goes between the adjacent words. Review lets the user move a misplaced number.
- **Status:** Proposed.

### D-06 · Evaluate on-device SpeechAnalyzer first; fall back to WhisperKit or FluidAudio against the same offline timing fixture
- **When / who:** 2026-11-20 · Claude
- **Why:** Per-word timestamps from SpeechAnalyzer are unverified. Decide on evidence, not assumption.
- **Status:** Open until the speech spike runs.

### D-07 · Preview one transcript-plus-images message; show "sent" only on confirmed delivery; clean up temp files after consumption or cancellation
- **When / who:** 2026-11-20 · Claude, from Benji D-30, D-99, D-100
- **Why:** Capture consent and handoff consent are separate. Cancel or timeout sends nothing.
- **Status:** Proposed.

### D-08 · Stable local signing identity for development; a separate owner-run Developer ID path for releases
- **When / who:** 2026-11-20 · Claude, from Benji D-53
- **Why:** Ad-hoc re-signing makes macOS drop granted permissions on every rebuild.
- **Status:** Proposed.

### D-09 · The project is called Pilcrow
- **When / who:** 2026-11-20 · User
- **Why:** The pilcrow (¶) is the proofreader's paragraph mark, which fits redlining. Namespace is acceptable: a small Swift iOS editor and an Android Markdown app use the name; no Mac product or Homebrew collision was found. Not legal clearance.
- **Alternatives:** Subpunct (cleanest namespace, awkward to say), Paragraphos (long), Bistre, Adscript, Dele. Rejected earlier: Gules, Nib, Scrim, Sanguine, Obelus, Caret, Stet and others, mostly for clashes with existing tools.
- **Status:** Active.

### D-10 · macOS 26 and later only for v1
- **When / who:** 2026-11-20 · User
- **Why:** Matches the maintainer's Mac and Apple's new SpeechAnalyzer. Smallest test matrix.
- **Status:** Active.

### D-11 · MIT license
- **When / who:** 2026-11-20 · Claude
- **Why:** Matches the small-app tone and the licenses of the candidate dependencies (KeyboardShortcuts, WhisperKit, FluidAudio). Avoid linking FluidAudio's text-to-speech target, which may pull in GPL-licensed eSpeak NG. `perfect-freehand-swift` has no license file, so it is not a dependency; reimplement the smoothing.
- **Status:** Active.

### D-12 · First end-to-end agent target: Codex CLI
- **When / who:** 2026-11-20 · Claude default; the maintainer has not chosen
- **Why:** Codex is the only agent with a documented image flag (`codex -i`), so delivery of the pixels can be verified. Other agents get the same prompt with absolute image paths.
- **Status:** Open. Confirm which agent the maintainer uses most.

### D-13 · Mark placement with overlapping words: after every word that has started
- **When / who:** 2026-11-20 · Claude, from an Opus 5.5 review finding
- **Decision:** A mark's slot is the number of words whose start is at or before the stroke's pen-down time. For non-overlapping words this is the same as D-05 (half-open `[start, end)`, gaps go after the earlier word). With overlapping words it keeps spoken order: a mark never lands before a word that had already ended. Words or strokes with non-finite times are handled as documented in `docs/core.md`.
- **Why:** The D-05 wording ("after the word being spoken") put a mark before a short word that ended before pen-down when a long word overlapped it.
- **Status:** Active. Refines D-05.

### D-14 · Model roles for building Pilcrow
- **When / who:** 2026-11-20 · User
- **Decision:** Claude Opus 5.5 orchestrates and reviews all code and docs. Development is delegated to Codex models: Sol 6.2 for the hardest AppKit and speech work, Sol 6.1 for substantial features, Terra for well-defined pieces, Luna for small or mechanical tasks (the tiering is Claude's proposal).
- **Why:** One strong reviewer over faster builders. Delegates skip their own review step; the Opus review replaces it.
- **Supersedes:** the earlier split (GPT-6.2 Astra for design, Grok 4.7 Fast for research and scaffolding), which built milestone 1.
- **Status:** Active.

### D-15 · No modal dialogs while the overlay is on screen
- **When / who:** 2026-11-20 · Claude, after the maintainer's first live test
- **Decision:** Nothing that blocks input (modal alerts, sheets) may appear while overlay panels are up. Screen Recording is checked (preflight only) when a session opens; if it is off, drawing works normally and the toolbar shows a non-blocking notice with "Enable…". "Enable…" ends the session first, then requests access; System Settings opens only if access was requested before and is still refused. Esc, the hotkey and Finish must work in every state.
- **Why:** In the live test on macOS 26 without Screen Recording, a modal alert appeared after the first stroke while the screen-saver-level canvas still covered every display and caught the mouse. Clicks were discarded and the hotkey and Esc were deferred or ignored, so the user was locked out of the mouse.
- **Supersedes:** the milestone 1 permission alert (built under D-07 and the review fixes).
- **Status:** Active. Fix in progress; needs a re-run of the live test.

### D-16 · Direction: redline review, not recording
- **When / who:** 2026-11-20 · User chose "differentiate" after an Opus 5.5 comparison with Scrawl
- **Context:** [Scrawl](https://github.com/kitlangton/scrawl) (MIT, by Kit Langton) is a more mature, video-first tool for showing an agent a problem: it records the screen, voice and ink, picks keyframes, builds a contact sheet, and hands off by paste, an agent skill and a CLI (natively to OpenCode).
- **Decision:** Pilcrow stays still-image and review-first: precise numbered marks tied to the spoken words, an approval gate before anything is sent, a per-mark fix list, direct delivery to coding agents, and a loop that verifies the agent's fix mark by mark. Pilcrow does not try to match Scrawl's recording features.
- **Alternatives:** contribute to Scrawl instead (good for small fixes, not for this thesis); fork Scrawl (would take on Rust + GPUI, against Pilcrow's Swift-only design).
- **Status:** Active.

### D-17 · Adopt Scrawl's lessons on permissions, packaging, overlay input and image legibility
- **When / who:** 2026-11-20 · Claude, from the Opus 5.5 comparison; follows the D-15 live-test failure
- **Decision:**
  1. **Start nothing until Screen Recording is granted.** The hotkey opens no overlay without it; it brings forward a normal (non-overlay) permissions window instead. Access is confirmed with a real one-frame capture, not only `CGPreflightScreenCaptureAccess` (which can be stale). Supersedes D-15's "drawing works without permission".
  2. **Signed `Pilcrow.app` now** (moves D-08 out of the backlog): a bundle with a stable ID and a stable local signing identity, so permissions attach to Pilcrow, not to Terminal, and survive rebuilds.
  3. **Overlay input model:** the canvas is click-through by default; it catches the mouse only while ⇧ is held (modifier flags are polled, which needs no permission). Esc finishes and ⌘Z undoes via Carbon hotkeys registered only while a session is open. No Accessibility or Input Monitoring. Marker/Pointer modes go away. The menu bar stays reachable.
  4. **When to take a new screenshot:** at the first stroke of the session, and again at the next stroke after the user clicked or scrolled the app underneath (seen with a global mouse monitor, which needs no permission).
  5. **Legible images for agents:** number badges at least 24 px tall in the exported image; images and crops capped at 1600 px long edge and about 1.56 MP (Scrawl's blind-reading results). Replaces the 1568 px / 1.15 MP placeholders.
  6. **Word timing:** SpeechAnalyzer's `SpeechTranscriber` with `.audioTimeRange` gives per-run timing (as Scrawl uses it); timings are treated as estimates and carried with an `estimated` flag. Narrows D-06.
- **Status:** Active.

### D-18 · Build order for the differentiators
- **When / who:** 2026-11-20 · User chose all four; Claude set the order
- **Decision:** Wave 1: App input/permission model (D-17.1, .3, .4), the `.app` bundle (D-17.2), and in Core the per-mark fix list plus the Core API cleanups. Wave 2: wire App to Core, approval preview, direct delivery to Codex and Claude Code (CLI + agent skill, MCP later), speech. Wave 3: the verify loop. Each step is reviewed by Opus 5.5 (D-14).
- **Status:** Active.

### D-19 · Local signing: Apple Development identity first, self-signed fallback
- **When / who:** 2026-11-20 · Claude, from the Opus 5.5 review of the packaging
- **Decision:** D-08 is now active through D-17.2. For local builds, sign with an existing Apple Development identity (`PILCROW_SIGN_IDENTITY=<SHA-1>`): its designated requirement is Apple-anchored and stable, and it needs no keychain writes. Contributors without an Apple account use the self-signed "Pilcrow Local Signing" identity (`tools/create-local-signing-identity.sh`, built with the system `/usr/bin/openssl`). Ad-hoc signing still works but resets permissions on every rebuild, and the build script warns. Developer ID with notarization remains the release path. Launch with `open build/Pilcrow.app` so permissions attach to Pilcrow, not Terminal.
- **Supersedes:** D-08's status "Proposed".
- **Status:** Active.

### D-20 · Delivery v1: approval preview, then clipboard, Codex CLI, Claude Code or MCP
- **When / who:** 2026-11-21 · User chose all four destinations; Claude set the mechanism (resolves D-12)
- **Decision:** After Finish, a normal Preview window shows the exact text and the images actually written; nothing leaves until Send. Destinations: Copy to clipboard (text with absolute image paths, plus the image files); Codex CLI and Claude Code run in Terminal in a remembered project folder through a generated `send.command` opened with `open -a Terminal` (no Automation permission); MCP through `pilcrow-mcp` (D-21). "Sent" is shown only after the step really succeeded. Details: [delivery.md](delivery.md).
- **Why:** The approval gate is a core differentiator (D-16). A `.command` file avoids the Apple Events permission that scripting Terminal would need.
- **Supersedes:** D-12 (Codex CLI only, open).
- **Status:** Active.

### D-21 · Outbox and a read-only MCP server
- **When / who:** 2026-11-21 · User asked for MCP; Claude set the design
- **Decision:** On Send, approved messages are copied to `~/Library/Application Support/Pilcrow/Outbox/<id>/` with `manifest.json` (`OutboxManifest` v1 in Core). Items are kept 24 hours. `pilcrow-mcp`, bundled in the app, serves over stdio only items the user sent to MCP, read-only, with tools `pilcrow_latest`, `pilcrow_list` and `pilcrow_get`. It never writes, captures or uses the network.
- **Why:** Scrawl has no MCP server; serving only approved items keeps the approval gate intact.
- **Status:** Active.

### D-22 · Finish flow: clipboard first, a tiny HUD, review only on demand
- **When / who:** 2026-11-21 · User, after calling the approval preview window and its proposed redesign "pathetic"
- **Principle (user):** minimal input, maximum efficient and performant output. No forms.
- **Decision:** Finishing a session puts the message (words with `[n]` plus the images as files and paths) on the clipboard immediately and shows a small HUD next to the pill: a strip of numbered crops, the first line of what was said, and "⌘V into your agent". Nothing leaves the Mac until the user pastes, so the paste is the approval. A review window opens only on request from the HUD. Terminal launch (Claude Code, Codex) and MCP stay available as secondary actions, not the default.
- **Why:** The preview window put the raw agent text, file paths and controls in front of the user and asked for input on every session. Pasting into the agent the user already has open works with every agent (Claude Code, Codex, T3 Code, Conductor) and needs no extra permission.
- **Supersedes:** D-20's preview window as the default step (its destinations remain, as secondary actions).
- **Status:** Active; to be built after voice.

### D-23 · Voice: on-device SpeechAnalyzer with word timings
- **When / who:** 2026-11-21 · User asked whether Benji's local voice would do; Claude chose
- **Decision:** On-device `SpeechAnalyzer` with `SpeechTranscriber` (`.audioTimeRange`, volatile results), `DictationTranscriber` as fallback; microphone captured only during a session with `AVAudioEngine`, never stored or sent; model downloaded only when the user clicks. Microphone and model are not required to start a session; without them marks still work.
- **Why:** Benji's shipped path (`SFSpeechRecognizer`, text only) has no word timings, which Pilcrow needs to place `[n]`, and needs the Speech Recognition prompt; Benji's own D-161 already planned the move to SpeechAnalyzer, and Scrawl ships it. Benji's audio-capture robustness (device changes) is reused as a lesson.
- **Supersedes:** D-06 (open).
- **Status:** Active; in progress.

### D-24 · The HUD is one row; Review is buttons, not a form
- **When / who:** 2026-11-21 · Claude, from Opus 5.5 UX reviews against the maintainer's bar (minimal input, maximum output)
- **Decision:** The finish HUD is a single non-activating row (about 320 × 56 pt, bottom right of the screen the session ended on): a stacked crop thumbnail with a count, "Copied · ⌘V", and icon buttons for Review, the remembered agent and Discard (always last; Undo for 4 s). Review opens only on request: one-click Copy, Claude Code, Codex, MCP, Show in Finder and Discard, above a grid of numbered crops with the spoken words; no pop-ups, folder rows or raw text; a project folder is asked only on an agent's first use. A failed save keeps the capture and says so. Clipboard items are marked transient.
- **Refines:** D-22 (which described a crop strip plus the first spoken line).
- **Status:** Active. Open question for the live test: whether terminals such as iTerm2 and Ghostty paste only the image files instead of the text; if so, the clipboard becomes text-only (the text already holds the image paths).

### D-25 · Drawing: one gesture, automatic shapes, tidy only when confident
- **When / who:** 2026-11-21 · User chose the "middle" option after comparing Claude's tool-picker mockup with Fable 5.2's no-tools critique side by side
- **Decision:** There is no tool picker and no tool keys. Hold ⇧ and drag, as today; Pilcrow classifies each stroke at pen-up. A closed loop is an **area**: when it is confidently a rectangle or an ellipse it is redrawn as a clean shape at once; otherwise the ink stays as drawn. An open stroke that starts on an existing mark is an **arrow** linked to that mark: the ink stays and an arrowhead is added at the end. Any other open stroke (underline, cross-out, scribble) stays a plain **mark**. A ⇧-click without movement drops a numbered **pin**. One colour and one width. ⌘Z removes a wrong guess together with its mark. The mark's kind and link go into the agent message.
- **Why:** Minimal keys, UI and learning (user's bar). A picker is a mode on a tool whose point is no modes; ⇧1–4 would swallow `! @ # $` in the app underneath; hold-to-snap taxes every mark. The user still wanted clean rectangles and circles, so confident shapes are tidied.
- **Alternatives:** four-tool picker with ⇧1–4 and hold-to-snap (Claude's mockup); recognise but never change the ink (Fable 5.2).
- **Status:** Active; in progress.

### D-26 · Minimal pill, receipt HUD, two-key shortcuts the user can change
- **When / who:** 2026-11-21 · User, after a live test ("I don't like the ui/ux" of the pill and HUD; "allow for 2 max keys pressed and also allow user to update those keys"), choosing from Fable 5.2's critique
- **Decision:** While drawing, the pill is a mic dot and "esc" (click it to finish); a red ring at the pointer shows that ⇧ is drawing; a one-line hint sits by the pointer for the first few sessions only. No mark count, Undo, Clear pass or live caption; errors still show. After Finish the HUD is a receipt: thumbnail with count, "Copied · ⌘V", "click to review"; no icons; it fades on its own. Discard and agent sends live in Review and the ¶ menu. Shortcuts are at most two keys (one modifier other than ⇧ plus one key, or a single F-key): default ⌥D starts and finishes, Esc also finishes, ⌘Z undoes. ¶ → Shortcuts… opens a small window with two recorders (Start / finish, Undo mark).
- **Supersedes:** D-24's HUD icons; the previous three-modifier start default.
- **Status:** Active; in progress.

### D-27 · Clipboard keeps text and images; per-mark words follow the sentence
- **When / who:** 2026-11-21 · User chose to keep text + images after T3 Code pasted only the images; Claude set the word rule after the live transcript showed repeats and misassigned words
- **Decision:** The clipboard keeps the text and the image files (D-24's open question closed). The transcript keeps only finalized speech plus the current volatile tail, so no phrase appears twice. Each mark's words are the sentence spoken around it, each word belonging to one mark, with fillers and immediate repeats removed in the per-mark lines.
- **Status:** Active; in progress.

### D-28 · Forgiving shape recognition and arrowheads
- **When / who:** 2026-11-21 · User, after the round-3 live drawing test
- **Decision:** Tidy clear single loops using corners and straight runs for boxes, and curved outlines for ovals. Trim lead-ins and overshoots that return to the loop. Draw tidy shapes in the loop's frame-aligned bounds. A straight shaft can point from, to, or between pins and areas within a 20 pt margin. A short reverse hook on the same stroke or a following V can supply a hand-drawn head, including for an unlinked arrow. Pilcrow draws a clean head and keeps the original samples. A separate V uses the shaft's badge (see the amendment for undo).
- **Why:** The round-3 captures showed clear hand-drawn boxes and ovals keeping their wobbly ink, arrow shafts missing nearby marks, and a separate arrowhead getting its own number.
- **Supersedes:** D-25's strict outline fits and start-only arrow links. The original gestures and automatic pen-up classification still apply.
- **Status:** Implemented and covered by replay of the two round-3 captures.

**Amendment · 2026-11-21.** Compare box and oval fit errors and keep tails as freeform ink when they stray beyond the loop's margin. Arrows use straighter shafts and can link to areas or pins drawn later in the same frame. The tip can look ahead along the shaft to reach a nearby target. Longer drawn heads can work in one stroke, and a separate V or short barb can set the tip at either end. Absorbed gestures keep their original samples under hidden IDs and release their provisional badge numbers. Undo restores the shaft if the head changed it. If the shaft already looked the same, undo removes both. Export and the overlay paint ink before badges. Local stroke recordings use schema 3 and voice timing goes under `debug/`.

**Amendment · 2026-11-21, review re-check.** The tip look-ahead applies only to strokes that already show as arrows (a drawn head or a source link), so a plain line ending near a mark stays a line. Links to undone marks count as free ends, so a redrawn target takes them over. A head whose shaft was undone cannot absorb new ink. Two-barb contact precision, the start-end head rule, consistent undo grouping for multi-part heads and the start-end margin cliff are in the backlog.


### D-29 · Mark badge icons
- **When / who:** 2026-11-22 · User chose the mark badge.
- **Decision:** Use a disc with a pilcrow cutout for the menu bar and app icon. The menu icon turns red during annotation; the app icon places the red badge on a light rounded plate.
- **Status:** Implemented.


### D-30 · Smaller menu and Story Settings
- **When / who:** 2026-11-22 · Owner approved direction A, "Story".
- **Decision:** The status menu has four actions: Start annotating (Finish annotating during a session, with the current start shortcut as a hint), Review last capture…, Settings… (⌘,) and Quit Pilcrow (⌘Q). A separator precedes Settings. Only transient shortcut/result warnings and Screen Recording needed… appear above them when relevant. Copy, Finder and Discard stay in Review. A single 440 pt Story Settings window replaces the Shortcuts and Permissions windows: the three-step reminder contains the editable shortcut keycaps, followed by agent setup commands and quiet access/capture footers. Settings uses the existing recorder validation, hotkey conflict handling and permission recovery paths. Agent setup copies a command for the running bundle's MCP executable; it makes no connection claim.
- **Why:** The owner found the menu cluttered and the previous settings mockup form-like. Story teaches the flow in the same lines that edit the shortcuts.
- **Supersedes:** D-26's separate Shortcuts window and menu Discard placement; the separate Permissions window.
- **Status:** Implemented; build, unit tests and offscreen previews cover the change. Human interaction and permission flows await a live run.


### D-31 · Words in images, automatic MCP access and user-scope setup
- **When / who:** 2026-11-22 · Owner approved all three delivery changes.
- **Decision:** Render each mark's D-27 cleaned per-mark words directly into its exported crop, with its numbered badge and grey kind label on a white strip below the screenshot. Frames get a panel listing spoken marks in mark order. Wordless marks get no strip; wordless frames retain the existing output. Use 16 px Helvetica body text, the on-screen badge renderer and a thin divider. Keep the final PNG within 1,600 px per edge and 1.56 MP, with badges at least 24 px tall. Shrink screenshot pixels while preserving the original source crop rectangle; never shrink the caption font. Limit a crop strip to eight text lines and a frame panel to 40% of final height; truncate with an ellipsis and grey “(full words in the message)”. Keep full words in the text message, the clipboard's text and files, and the v1 manifest. Only `message-for-agent.md` adds a short hint about image captions. Review uses the resulting PNGs.
- **Decision:** The read-only MCP server exposes every valid v1 outbox capture from the last 24 hours, regardless of destination. Remove Review's MCP button. Keep ownership, permissions, file-name, link-count, size and read-only checks; discarded and cleared items remain unavailable. Keep decoding the legacy `mcp` destination.
- **Decision:** Copy for Claude Code uses `claude mcp add --scope user --transport stdio pilcrow -- <quoted bundle path>`. Codex's existing `codex mcp add pilcrow -- <quoted bundle path>` already uses its user configuration by default and stays unchanged.
- **Why:** Image-only paste targets such as T3 Code drop clipboard text, losing the spoken instruction. Requiring an extra Review → MCP click made fetching a capture through MCP pointless. Folder-scoped Claude setup hid Pilcrow outside the setup folder.
- **Supersedes:** D-27's text-only location for per-mark words, D-21/D-22's explicit MCP publication gate, and D-30's folder-scoped Claude setup command. Clipboard representations and Core crop geometry stay as before.
- **Status:** Implemented with synthetic offscreen exports and automated tests. App, clipboard targets and real agent setup still need human live checks.


### D-32 · Badges keep clear of arrowheads
- **When / who:** 2026-11-22 · Owner flagged a live capture where oval [6], drawn around the tip of arrow [5] from [4], had its badge on top of [5]'s arrowhead.
- **Decision:** Draw all ink, then place badges in mark order. Each badge takes its first candidate spot that is not on another mark's arrowhead (padded by 6 pt) or an earlier badge. Ovals try the upper-left diagonal first, then the other diagonals, then the top, sides and bottom; boxes try the top-left corner first, then the other corners. An arrow that starts on a mark and points at another gets its badge beside the middle of the shaft rather than on the outline it leaves. Arrowheads are 13 pt long instead of 10 pt. If every spot is blocked, the badge keeps its first-choice position.
- **Why:** A badge covering a head made the arrow look as if it were labelled by the shape it points at; a badge on the leaving shape's outline was ambiguous.
- **Status:** Implemented, with a renderer test rebuilt from the capture.


### D-33 · Glass Settings and Pilcrow colour
- **When / who:** 2026-11-22 · Owner approved direction B, "Glass".
- **Decision:** Keep the 440 pt Story window and its inline shortcut recorders. Put the steps, agent setup, and colour picker in Liquid Glass groups over an accent wash. Use opaque group fills when Reduce Transparency is on. A red Screen Recording card with an Open Settings button leads the stack when access is off, and the step badges turn grey. Missing Microphone access gets a smaller Turn On… pill below the title. Both buttons use the existing recovery paths, with access rechecked when the window becomes key. When both permissions are on, a small green check line shows their status.
- **Decision:** Save one of seven swatches in UserDefaults. Coral is the default, followed by Amber, Green, Teal, Blue, Violet, and Red. The choice sets the active menu-bar glyph and the accents in Settings. Overlay ink and exported frames, crops, and caption badges use the swatch's fixed light sRGB value. Strokes and arrowheads get a 1.5 pt white halo, and numbered badges get a 1.5 pt white outline. Amber uses dark badge text and the other swatches use white. The idle menu-bar icon stays a template. The static app icon is coral.
- **Why:** The owner wanted clearer groups, a visible way to recover missing access, and a choice of ink and icon colour.
- **Supersedes:** D-29's red active and app icons, and D-30's plain styling and permission links in the footer.
- **Status:** Implemented with preference, renderer, and PNG export tests and offscreen previews. Live glass, Reduce Transparency, and the permission recovery controls await a human run.
