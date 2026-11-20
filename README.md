# Pilcrow

Draw numbered red marks on your Mac and export screenshots with the marks drawn in. Pilcrow's goal is to let you redline your screen out loud and give a coding agent one message with your words and marked screenshots.

> **Status: pre-alpha.** Milestone 1 was live-tested once on 2026-11-20. The old Screen Recording alert blocked input during that run. The redesigned permission flow still needs a live test. Microphone capture, speech transcription, and agent handoff are planned. See [docs/status.md](docs/status.md) for what is built and what has been verified.

## How it works

1. Press ⇧⌥⌘J to open a transparent overlay over the app you are reviewing. If Screen Recording is off, Pilcrow opens its permissions window.
2. Hold ⇧ and draw numbered red marks. Release ⇧ to interact with the app underneath.
3. Finish to export local PNGs with the marks drawn onto the screenshots.

The planned speech and review workflow will link each mark to the words you spoke as you drew it, then let you approve the message before sending it.

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

Screen Recording is required to start annotating. If access is off, Pilcrow opens a permissions window and asks macOS for access only when you click Grant…. Once access has been requested, the window offers System Settings and a reopen option in case macOS still reports access as off. Pilcrow confirms access with a small screenshot from the main display. It discards the check image immediately and excludes its own windows from captures.

Milestone 1 takes a still screenshot at the first mark on each display in a pass. After you click or scroll the app underneath, the next mark starts a fresh pass. Typing by itself keeps you in the same pass. Pilcrow samples ⇧ about 60 times a second, so a click within a few milliseconds of pressing or releasing ⇧ may go to the wrong place. While a session is open, Pilcrow takes Esc to finish and ⌘Z to undo a mark, so those shortcuts are unavailable in the app underneath. Pilcrow uses Carbon shortcuts and mouse events for the overlay and requires neither Accessibility nor Input Monitoring access.

Milestone 1 keeps only its latest local PNG export, removes its exports on quit, and clears stale Pilcrow export folders at the next launch.

## Related work

[Scrawl](https://github.com/kitlangton/scrawl) by Kit Langton records your screen, voice and ink and hands an agent a contact sheet of keyframes. Pilcrow takes a narrower, still-image approach: numbered marks tied to your words, an approval step before anything is sent, and a fix list you can verify. Several of Pilcrow's design decisions (permissions, packaging, overlay input, image legibility) follow lessons documented in Scrawl's repository; see [docs/decisions.md](docs/decisions.md) D-16 and D-17.

## Name

A pilcrow (¶) is the proofreader's paragraph mark.

## License

MIT. See [LICENSE](LICENSE).
