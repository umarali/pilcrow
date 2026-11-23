# Guide for coding agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the project rules and [docs/architecture.md](docs/architecture.md) for how the code fits together.

## Where things are

- `Sources/PilcrowCore/`: pure logic: session model, shape recognition, speech-to-mark alignment, message assembly, geometry. Foundation only. The exact contract is [docs/core.md](docs/core.md).
- `Sources/PilcrowApp/`: the macOS app: overlay, shortcuts, screen capture, voice, export, delivery, Settings. Depends on Core, never the reverse.
- `Sources/PilcrowMCP/`: the read-only stdio MCP server.
- `Tests/`: unit tests for all three. Fixtures are synthetic or sanitized recordings.
- `docs/decisions.md` is append-only. Never renumber or rewrite an entry; add one that supersedes it.

## Check your work

```bash
./tools/test.sh          # unit tests with a throwaway HOME
xcrun swift build        # compiles Core, App and MCP
```

Use `xcrun swift`, not a `swift` found first on `PATH`, which can be a toolchain that cannot read the macOS 26 SDK.

## Rules for agents

- Never launch the app or request Screen Recording, Microphone, Accessibility or Input Monitoring. Agents build and unit test; a person runs the app ([manual testing](docs/manual-testing.md)).
- Never capture the real screen or record real audio, including in tests.
- Stay inside this repository.
- Say exactly what you verified: unit-tested, built, or untested. Only a person can live-verify.
