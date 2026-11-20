# Guide for coding agents

## Where things are

- `Sources/PilcrowCore/`: pure logic (session model, speech-to-mark alignment, transcript rendering, message assembly, screen geometry). Foundation only: no AppKit, no capture, no audio. API and rules: [docs/core.md](docs/core.md).
- `Sources/PilcrowApp/`: the thin macOS shell (overlay window, hotkey, screen capture, microphone). Depends on Core, never the reverse.
- `Tests/`: unit tests for Core, using synthetic fixtures only.
- `docs/`: `decisions.md` is append-only. Never renumber an entry; a reversed decision gets a new entry that supersedes it.

## Check your work

```bash
./tools/test.sh          # unit tests, throwaway HOME, no inherited secrets
xcrun swift build        # compiles Core and App
```

Use `xcrun swift`, never a `swift` found first on `PATH` (it can be a stale toolchain that cannot read the macOS 26 SDK).

## Rules

- Work only inside your assigned checkout. Never read or write the home folder, key files, or anything outside the repo.
- No API keys on command lines, in logs or in commits.
- Never request or use Screen Recording, Microphone, Speech Recognition, Accessibility or Input Monitoring permissions, and never launch the app. Agents build and unit test; a human runs the app.
- Tests use synthetic strokes, transcripts and images. Never capture the real screen or record real audio.
- Automated browser or UI tests run headless only.
- Consent changes (what is captured, what is sent, to where) need a test that shows what is still asked.
- Only show UI states backed by real events: "recording", "captured", "sent" must derive from actual events, never from a timer or a guess.
- Do not copy code, prompts, assets, colours or copy from other products. Check a dependency's `LICENSE` before adding it; a package with no license file is not a dependency.
- Don't commit, push, merge, force-push or delete branches unless the brief says so.
- Report: what changed, check results as counts, and what is not verified. Say exactly what is live-verified, unit-tested, built or untested.
