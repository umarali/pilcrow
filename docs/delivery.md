# Delivery: clipboard first, Review on demand

D-22 supersedes D-20's default Preview step. Finish copies the sealed message locally. Pasting into your agent is the approval. Terminal and MCP delivery still require an explicit action.

## Finish and the HUD

Every Finish path closes the overlays, waits for bounded capture and voice outcomes, seals Core, and exports the final message. An empty message creates no outbox item and shows no HUD. Every non-empty message, including speech-only captures, copies and shows the HUD.

Pilcrow exports PNGs directly into a private `~/Library/Application Support/Pilcrow/Outbox/<id>/` folder with mode 0700. An item lock protects export from retention. It writes `message-for-agent.md` and Core's v1 `manifest.json` **last**, initially with destination `clipboard`. Successful PNGs are written once on the normal path. The message contains Core's text and any image-failure note, followed, when images exist, by `Images (read these first):` and one absolute image path per line. Failed images are described but not attached.

If outbox preparation fails, export uses a private temporary recovery folder. If publication fails after direct export, retained PNG bytes produce a recovery copy without re-encoding. Pilcrow keeps the original until recovery succeeds and never discards the only export on failure. The clipboard text uses the retained export's paths. The HUD shows **Couldn’t save · copied** if copying succeeded, or **Couldn’t save or copy** otherwise. Clicking it opens Review, with Copy and Show in Finder available there. Recovery folders named `pilcrow-recovery-<UUID>` survive later sessions, Quit and Pilcrow's legacy temporary-export cleanup. They are outside normal outbox retention; explicit Discard can remove the current recovery. If recovery storage also fails, the original folder and in-memory capture remain available for retry.

Pilcrow prepares the string item and image file-URL items before clearing the clipboard, then calls `writeObjects` once. Each item includes `org.nspasteboard.TransientType` to ask clipboard managers not to retain it. No concealed marker is used. Pilcrow never reads the previous clipboard contents or attempts to restore them. Preparation failure leaves the previous clipboard alone; write failure can leave it empty. Copy is available again from Review, opened through **Review last capture…** in the ¶ menu.

D-26 makes the HUD a receipt: one horizontal row, 320 × 56 pt, with 12 pt corners and a system material. A crop thumbnail has a count badge; speech-only captures use `text.quote`. Beside it are **Copied · ⌘V** and **N marks · click to review**, or **Words only · click to review**. Clicking anywhere opens Review, including on failure. There are no icon buttons. The panel cannot become key or main. It appears on the display under the pointer at Finish, at the visible area's bottom right. It keeps the overlay's screen-saver-level, stationary, all-Spaces/full-screen behavior. Visibility over full-screen Spaces still needs a human run.

The HUD fades in/out over 180 ms, or immediately with Reduce Motion. It hides after about five seconds; hovering keeps it visible and gives five seconds after leaving. Failure receipts use the same timing. Starting another session dismisses it. Auto-hide keeps the capture. VoiceOver receives a high-priority announcement of the receipt status and detail when it appears, including save/copy failures. Its accessible button is “Review capture”; the pill is “Finish annotation” and announces errors.

**Discard** is in Review, opened through **Review last capture…** in the ¶ menu. It removes the published item path and conditionally clears the clipboard only if its change count still matches Pilcrow's copy. A newer copy is preserved. Locked staging and recovery rollback still protect the filesystem operation; successful discard finalizes deletion without a HUD Undo state. A later retention pass removes abandoned outbox staging folders after a crash.

Export, outbox writes, routing, deletion and pruning run off the main actor. Thumbnail `CGImage`s pass directly from export to HUD and Review, with no thumbnail PNG encoding or decoding. Retention runs after HUD presentation. A content-free notice logs `Finish-to-HUD` in milliseconds, measured from the initial Finish press, including voice drain, capture wait, export, publication, copy and HUD presentation. It excludes completion of the fade. No live latency has been measured in the build/test-only implementation run.

## Shortcuts during annotation

Defaults resolve the characters D and Z in the current keyboard layout. Input-source changes refresh labels and Carbon registrations; recorded custom chords retain their physical key codes. If a saved physical chord becomes reserved after a layout change, its key code and display stay intact but registration is refused until a compatible layout returns or the user records another chord. If layout data is unavailable, names and defaults use US mapping. Resetting a recorder with unmodified Delete removes its saved override; modified Delete remains recordable. Keypad names are distinct. Laptop F-keys may need fn, as the recorder hint explains.

Start rejects common ⌘ app/system commands and terminal ⌃C, ⌃D and ⌃Z, with inline reasons based on the current character. Undo allows ⌘Z but rejects the other reserved ⌘ commands. Allowed ⌥ chords show a note when they type a visible character in other apps. Esc is fixed for Finish. Undo is registered only while a completed mark in the current pass is undoable; the action ignores an in-progress drag and releases its registration after the last completed mark is undone. The overlay captures the mouse as soon as ⇧ alone is held; the ring and crosshair appear after 200 ms of continuous ⇧. Start also rejects ⌘⌫. Shortcut characters are resolved with their modifiers, so ⌘ chords on Russian, Greek, Hebrew and Dvorak – QWERTY ⌘ layouts are checked and labelled by the Latin letter apps match.

## Review on demand

**Review**, also available as **Review last capture…** in the ¶ menu, opens an 800 × 640 pt normal, resizable window. Its toolbar is Copy, Claude Code, Codex, MCP, Show in Finder, Discard, each an icon and short label. The main content is a two-column grid of numbered crops with read-only spoken words beneath each. Missing crops have a placeholder; speech-only captures show the words. There are no destination pop-ups, folder chooser rows, hint lines, editable fields or exact-text disclosure.

Each terminal button sends immediately using that agent's remembered project. First use asks for a project with `NSOpenPanel` and sends after selection. The button's small chevron offers **Change project…**, which updates only that agent's folder. Missing commands disable the corresponding button with a **Codex not found** or **Claude Code not found** tooltip. MCP's tooltip is **Let your agent fetch it via the Pilcrow MCP server**.

Esc, ⌘W and window close keep the copied capture and call `NSApp.hide(nil)` to return focus. A send in progress blocks close, new annotation, Settings → Clear and Quit. Focus return and immediate ⌘V need live verification.

## Secondary sends and delivery fixes

Explicit sends reuse the same item, immutable message and attachments without copying again. A recovered capture first retries publication; its recovery paths remain valid for the clipboard already handed off. The store writes `send.command`, then atomically replaces the manifest **last**, preserving the item ID and creation time. Once destination becomes `mcp`, it stays `mcp` after later sends. **The manifest records MCP availability, not necessarily the most recent delivery destination.** Clipboard/CLI-only items stay invisible to MCP. Terminal acceptance does not confirm that an agent started or read the images.

- **F1, comma paths:** Codex uses `-i '<comma-separated absolute paths>'` only when images exist and none contains a comma. Otherwise it relies on message paths. Text-only sends omit `-i` and the image-path section.
- **F2, compatible shell:** resolve the passwd login shell, using `$SHELL` only if lookup is unavailable. Accept absolute executables named zsh, bash, sh, ksh or dash; otherwise use `/bin/zsh`. Detection and execution use the same allowed shell with `-ilc`.
- **F3, executable detection:** zsh uses `whence -p`, bash uses `type -P`, and other allowed shells use `command -v`. A unique sentinel pair isolates output from startup chatter, even without a trailing newline. Require successful exit and one absolute executable file path between sentinels. zsh/bash find the executable even when an alias or function shadows it. Detection is cached per command and login shell for the app's lifetime, with concurrent requests coalesced. Review open and failed sends refresh it. Keep only a bounded output tail and log no shell output. The three-second deadline sends SIGTERM to the startup process group, then SIGKILL after about 0.5 seconds and reaps the shell.
- **Argument handling:** quote paths and the inner command. Resolve the executable path again with the shell-specific lookup before `exec`, bypassing aliases and functions. Change to the chosen project after shell startup. Both agents receive `--` before the prompt argument. Real CLI acceptance still needs a human run, including a leading-dash prompt.
- **F5, folder race:** re-check that the project is a directory immediately before command write. Failure keeps the copied item. Change project… in Review chooses a replacement. The script's `cd ... || exit $?` handles removal after that check.
- **F6, disk work:** writes and pruning use actor executors. Retention failure does not block copying or sending and logs no capture contents.

Codex runs `exec "$pilcrow_executable" [-i '<paths>'] -- "$(/bin/cat '<message path>')"` after resolving codex. Claude Code uses the same form without `-i`, resolving claude and reading message paths. The generated script has mode 0700. NSWorkspace opens it with Terminal explicitly selected, without an `open` subprocess or Apple Events permission. No agent starts until a terminal toolbar button in Review is clicked. Failures keep the capture, show a short status and refresh detection; details stay in tooltips.

## Outbox retention

Items are kept for 24 hours, then pruned on launch, after Finish and on secondary sends. Pilcrow/Outbox/item directories have mode 0700. Cleanup selects user-owned UUID directories, rejects symlinks, locks them and checks identity before deleting. Locked exports and staged discard items are skipped. Failure does not block a new capture. Review → **Show in Finder** reveals the retained capture folder. Settings → **Show** reveals the outbox folder. Settings → **Clear** removes eligible recent outbox items without confirmation, dismisses stale UI and leaves clipboard contents and copies in other apps alone. Discard conditionally clears Pilcrow's own clipboard copy.

## `pilcrow-mcp` (read-only MCP server)

A separate executable bundled at `Pilcrow.app/Contents/MacOS/pilcrow-mcp` serves MCP over newline-delimited JSON-RPC stdio. MCP 2026-07-28 is the current revision; as described in the [versioning page](https://modelcontextprotocol.io/specification/versioning), dual-era clients fall back to initialize when `server/discover` returns -32601. It implements the [2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) and [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports). It never writes, captures or uses the network. It reads only version 1 items sent to MCP in the last 24 hours. Invalid or unsafe files are skipped. Each response is limited to 10,000,000 bytes of base64 image payload; crops take priority and omitted images are identified by name and absolute path. Attachments must be named `frame-<digits>.png` or `mark-<digits>.png`, be regular PNG files owned by the current user with one link, and reside in a non-group/other-writable folder whose name matches the manifest UUID. Listing uses file metadata without reading image bytes.

The default outbox is `~/Library/Application Support/Pilcrow/Outbox`. Set `PILCROW_OUTBOX_DIR` in the server's environment to use a different directory.

Tools and JSON input schemas:

- `pilcrow_latest`: `{"type":"object","properties":{},"additionalProperties":false}`. Returns approved text followed by PNG image blocks, crops in mark order then frames.
- `pilcrow_list`: `{"type":"object","properties":{},"additionalProperties":false}`. Returns up to 20 recent items with id, creation time, mark count and available attachment names.
- `pilcrow_get`: `{"type":"object","properties":{"id":{"type":"string"},"mark":{"type":"integer"}},"required":["id"],"additionalProperties":false}`. Returns an item by id, or the fix-list line and available crop for the selected mark. Unknown ids or marks return a tool error.

When no captures are available, latest and list return a normal text result.

Setup (see the official [Claude Code MCP instructions](https://code.claude.com/docs/en/mcp#option-3-add-a-local-stdio-server) and [Codex MCP configuration](https://developers.openai.com/codex/mcp)):

```bash
claude mcp add --transport stdio pilcrow -- /Applications/Pilcrow.app/Contents/MacOS/pilcrow-mcp
```

```bash
codex mcp add pilcrow -- /Applications/Pilcrow.app/Contents/MacOS/pilcrow-mcp
```

Settings → Copy for Claude Code / Codex copies the command form above with the actual running bundle's `Contents/MacOS/pilcrow-mcp` path, shell-quoted even when the bundle name contains spaces or apostrophes. Copying does not execute the command or connect an agent.
