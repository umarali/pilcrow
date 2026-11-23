# Contributing to Pilcrow

Use macOS 26 or later and Xcode 26 or later. Select the full Xcode
installation with `xcode-select`. Use the [GitHub issues](https://github.com/umarali/pilcrow/issues)
for the roadmap, backlog and bug reports.

## Build and test

From the repository root, run these commands.

```sh
xcrun swift build
./tools/test.sh
./tools/build-app.sh
```

Use `xcrun swift` so the compiler comes from the selected Xcode.
The test script supplies a throwaway home and a minimal environment.
Building and unit testing leave the app closed and request no permissions.

The bundle is `build/Pilcrow.app`. Set `PILCROW_SIGN_IDENTITY` to the
SHA-1 of an existing Apple Development identity for stable macOS permissions.
See [Building Pilcrow](docs/building.md) for other local signing options and
permission resets. Launch the bundle for [manual testing](docs/manual-testing.md).

## Project rules

- Keep `PilcrowCore` Foundation-only. Put macOS integration in `PilcrowApp`.
  See the [architecture](docs/architecture.md) and [Core contract](docs/core.md).
- Use synthetic or sanitized fixtures in tests. Tests must never capture the
  real screen or microphone.
- Drive UI states from real events. Recording, capture and delivery receipts
  reflect what the app observed.
- A change to what the app captures, sends or makes available needs a test
  showing what the user is still asked to approve.
- Keep the [decision log](docs/decisions.md) append-only. Add a superseding
  entry when a decision changes and keep the earlier entry and its number.
- Use original code, assets, colours and copy. Check a dependency's license
  before adding it.

## Report a recognizer or voice problem

Use a disposable window and non-sensitive narration to reproduce it. Include
your macOS and Pilcrow versions, numbered marks, steps and expected and actual
results. In **Review → Show in Finder**, find the capture folder.

- **Recognizer miss.** Attach `strokes.json` if available. It contains gesture
  coordinates relative to the display frame, frame sizes, timing and shape
  results. The coordinates can reveal what you drew.
- **Voice alignment.** Attach `debug/voice.json` if available. It contains
  recognized words and their times, analyzer result ranges and mark timings,
  including undo and absorbed-head information. Read the transcript before sharing.

Neither JSON file contains screenshot pixels or audio samples. Frame and crop
PNGs can show private screen content. If you attach an image, use a disposable
reproduction. See [Manual testing](docs/manual-testing.md#collect-evidence) for
logs and the outbox path.

## Pull requests

Explain the change and how you verified it. Run the build and test commands.
Update the affected docs and append a decision entry for a behaviour change.
For macOS behaviour that needs a live check, report what you tested on a real
Mac and what remains untested.
