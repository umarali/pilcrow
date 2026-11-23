# Pilcrow

Draw numbered marks on your Mac and export annotated screenshots, per-mark crops, and a Markdown fix list. Pilcrow lets you annotate your screen out loud and give a coding agent one message with your words and marked screenshots.

> **Status: pre-alpha.** Drawing, frame export and Core wiring passed live runs with Screen Recording granted. Clipboard-first Finish, on-demand Review, delivery and on-device voice narration are built. Human live tests are pending for those features. See [docs/status.md](docs/status.md) for what is built and what has been verified.

## How it works

1. Press ⌥D to start. If Screen Recording is off, Pilcrow opens Settings. Open Pilcrow → Settings… or press ⌘, and click the inline keycaps to change Start / finish and Undo mark. Defaults follow D and Z on the current keyboard layout; custom shortcuts keep the physical key you recorded. Start rejects common app and terminal shortcuts. Allowed ⌥ chords show a note when they type a character in other apps.
2. Hold ⇧ and draw numbered marks. A ⇧-click drops a pin. A pointer ring appears once ⇧ has been held for a moment. Release ⇧ to interact with the app underneath. The first three sessions show a pointer hint until the first stroke.
3. Press ⌥D again, press Esc, or click the small “esc” pill to finish. The pill shows a mic-level dot when voice is running and grows only for errors or warnings.
4. Press ⌘V in your agent. A small receipt HUD confirms the copy without taking focus. Click anywhere on it to open Review; it fades after about five seconds, with hovering keeping it visible.

Pilcrow tidies clear hand-drawn boxes and ovals when you lift the pen. A loop with a long tail keeps its ink. Draw a straight line from, to, or between pins and areas for an arrow. The tip can reach across a gap, and an area or pin you draw later can complete a link on the same capture. Draw a head on the same stroke, or add a V or a pair of barbs at either end of the shaft. A single short barb works only at the pen-up end. A separate head shares the shaft's number. ⌘Z restores the earlier shaft if the head changed it and removes the arrow if it already looked the same. The fix list labels boxes, circles, ovals, areas, points and arrows, including any linked mark numbers.

With voice narration on, Pilcrow links each mark to the words you spoke as you drew it.

## Sending to your agent

Exported PNGs include each mark's cleaned words below its screenshot, so image-only paste targets keep the instruction. Long captions are capped with a note pointing to the full message. Finish copies your words, numbered marks and image paths/files; press ⌘V in your agent. The small HUD shows a crop/count, “Copied · ⌘V” and “N marks · click to review”, or “Words only · click to review”. Review shows numbered crops with the spoken words underneath and one-click Copy, Claude Code, Codex, Finder and Discard actions. Each terminal agent remembers its project. Review last capture… remains in the Pilcrow menu after the HUD hides; Copy, Finder and Discard are in Review. See [delivery.md](docs/delivery.md) for details and MCP setup.

Settings groups the three-step reminder with inline shortcut recorders, agent setup commands, and the Pilcrow colour picker on Liquid Glass. Access and capture controls are on the same page. Choose one of seven swatches with a click. Coral is the default. The active menu icon, overlay and exported marks follow your pick, and a white halo keeps ink legible against the screenshot. The Finder icon is coral.

## Requirements

- Apple silicon Mac, macOS 26 or later.
- Xcode 26 or later (the full Xcode, selected with `xcode-select`).

## Build and test

```bash
xcrun swift build
./tools/test.sh
```

### Build the app

Run `./tools/build-app.sh` to produce `build/Pilcrow.app`, or add `--debug` for a debug build. See [docs/building.md](docs/building.md) for signing and permission details.

## Privacy

Screen Recording is required to start annotating. If access is off, Pilcrow opens Settings. Click **Open Settings ↗** in the red Screen Recording card to start macOS recovery. The first click requests access. After that, the button opens the Screen Recording pane in System Settings. Pilcrow also offers a reopen option if macOS still reports access as off. Pilcrow confirms access with a small screenshot from the main display. It discards the check image immediately and excludes its own windows from captures.

Pilcrow takes a still screenshot at the first mark on each display in a pass. After you click or scroll the app underneath, the next mark starts a fresh pass. Typing by itself keeps you in the same pass. Pilcrow samples ⇧ about 60 times a second. As soon as it sees ⇧ alone, the overlay takes the mouse, so a ⇧-click or ⇧-drag goes to Pilcrow, not the app underneath; a ⇧-click within the first sampling tick (about 16 ms) is caught by the mouse monitor instead. The ring and crosshair appear only after 200 ms of continuous ⇧, so typing capitals does not flash them. While a session is open, Pilcrow takes Esc to finish. It takes the configured Undo mark shortcut, ⌘Z by default, only while a completed mark in the current pass can be undone. Undo returns to the underlying app after the last such mark is removed and is taken again after the next mark. Pilcrow uses Carbon shortcuts and mouse events for the overlay and requires neither Accessibility nor Input Monitoring access.

Voice narration is optional. In the Pilcrow menu, open **Settings…** and click **Turn On…** below the title. Pilcrow requests microphone access and downloads the on-device speech model if needed. If you previously denied access, the button opens the Microphone pane in System Settings. If the microphone is already on and the speech model is missing, click **Turn on** beside the model note. Pilcrow uses the microphone during annotation and for about a quarter second after Finish to catch the last word. Transcription runs on this Mac. Pilcrow never saves or sends microphone audio. You can draw and export marks without setting up voice. Use Review to inspect the words before pasting.

Finish exports images directly into a private local outbox, kept for up to 24 hours, with the manifest written last. If saving fails, Pilcrow keeps a recovery export and still copies the text with paths to those copies. Recovery exports survive later sessions and Quit; Show in Finder lets you find them. Pilcrow prepares all clipboard items before one write and never reads previous clipboard contents. It adds `org.nspasteboard.TransientType` to ask clipboard managers not to retain screenshot captures; clipboard managers may choose whether to honor it. Outbox writes and cleanup run off the main thread. Delivery logs contain destination and outcome, not message text or user paths. Clipboard and CLI delivery hand the approved content to the selected app or agent; that destination controls any further processing. A configured agent can read every valid outbox capture from the last 24 hours across projects, including screenshots, window titles and recognized text. It reads locally over stdio after Finish without a Review click. Discarded and cleared captures are unavailable. Each capture best-effort keeps local schema-3 `strokes.json` calibration data with full-precision frame points, shape labels, timing, frame size/display scale and the recognizer version. The file keeps all samples through 5,000 points per mark, including separate arrowheads, with a 5 MB capture cap. A separate local `debug/voice.json` keeps final word times, speech result ranges and flags, and pen-down and pen-up times under 1 MB. Both follow capture retention and stay out of the clipboard and agent or MCP attachments.

## Related work

[Scrawl](https://github.com/kitlangton/scrawl) by Kit Langton records your screen, voice and ink and hands an agent a contact sheet of keyframes. Pilcrow pairs still screenshots with numbered marks tied to your words and a fix list you can verify. You choose where to paste or send the message. A configured agent can also fetch every valid capture from the last 24 hours across projects, including window titles and recognized text, as soon as you Finish. Several of Pilcrow's design decisions (permissions, packaging, overlay input, image legibility) follow lessons documented in Scrawl's repository; see [docs/decisions.md](docs/decisions.md) D-16 and D-17.

## Name

A pilcrow (¶) is the proofreader's paragraph mark.

## License

MIT. See [LICENSE](LICENSE).

## Agent setup

Settings → Copy for Claude Code copies a bundle-specific command using user scope, so Pilcrow is available from any folder:

```bash
claude mcp add --scope user --transport stdio pilcrow -- '/Applications/Pilcrow.app/Contents/MacOS/pilcrow-mcp'
```

Codex's command already uses its user configuration by default:

```bash
codex mcp add pilcrow -- '/Applications/Pilcrow.app/Contents/MacOS/pilcrow-mcp'
```

Both commands quote the actual bundle path, including spaces and apostrophes. Copying never runs setup. Once configured, ask the agent for the latest Pilcrow capture after Finish. See [delivery.md](docs/delivery.md) for the local read-only MCP contract.
