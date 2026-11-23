# Privacy

Pilcrow runs on your Mac. It has no servers, accounts, analytics or crash reporting, and makes no network requests of its own. When you turn voice on, macOS may download Apple's on-device speech model.

## Permissions

| Permission | Needed for | When it's used |
|---|---|---|
| Screen Recording | Required | A still screenshot of a display when you start your first mark on it, and again after you click or scroll the app underneath. Each Start also captures a 16 × 16 pt corner of the main display to confirm access, then discards it. |
| Microphone | Optional, for voice | Only during a session, plus about a quarter second after Finish to catch your last word |

Pilcrow does not need Accessibility or Input Monitoring. It registers its Start shortcut with the system. It watches ⇧, the mouse and its other shortcuts only while a session is open.

## What a capture contains

- **Screenshots of each marked display.** A screenshot shows the whole display, including unrelated windows and notifications, not just the area you marked. Pilcrow leaves its own windows out. Each mark also gets a close-up crop.
- **Your words.** Speech is transcribed on your Mac by Apple's SpeechAnalyzer. Audio is never saved. The full transcript is kept, including words spoken for a mark you later undid.
- **App and window names.** Each screenshot is labelled with the app name and window title under its first mark, or the frontmost window on that display if there is none. The capture's manifest also stores the app's bundle ID. Pilcrow doesn't ask browsers for URLs, but a URL visible on screen or in a window title ends up in the capture.
- **On-screen text** under each mark, recognized on your Mac with Apple's Vision framework.
- **Local diagnostics, never sent to an agent.** `strokes.json` holds your mark shapes and timing. `debug/voice.json` holds the recognized words and their timings.

Window titles and on-screen text can contain private information, such as document names or email subjects. They travel with the screenshot.

## Where it's stored

Captures are saved in `~/Library/Application Support/Pilcrow/Outbox`, in folders only you can read. Pilcrow deletes captures older than 24 hours when it launches, when you finish a capture, and before a Review send. Nothing runs on a timer, so while Pilcrow is quit or idle, older captures stay on disk until the next cleanup. The MCP server never serves a capture older than 24 hours. **Settings → Clear** deletes all captures now, and **Discard** in Review deletes one.

If saving to the outbox fails, Pilcrow keeps a recovery copy in a private temporary folder named `pilcrow-recovery-<id>`, so the capture isn't lost. Clear doesn't remove recovery copies, and after Pilcrow restarts nothing in the app points to them. macOS clears temporary folders eventually ([#6](https://github.com/umarali/pilcrow/issues/6)).

Review also remembers the project folder you chose for each agent.

## What leaves your Mac

- **Clipboard.** Finish puts the message, with image paths, and the image files on the clipboard. Anything that reads the clipboard can see them, including clipboard managers and Universal Clipboard on your other Apple devices. Pilcrow marks the items transient (`org.nspasteboard.TransientType`), which asks clipboard managers not to keep them, but not all honour it.
- **Paste.** The message and images go wherever you paste them.
- **Review → Claude Code / Codex.** The capture goes to that agent, which sends it to its model provider.
- **MCP.** A connected agent can fetch any capture from the last 24 hours, from any project, without a paste or a click. Connect only agents you're happy to give that access.

Once a capture has been pasted, sent or fetched, Clear and Discard can't recall those copies. Your agent's provider handles them under its own terms.

Pilcrow also writes the clipboard when you press **Copy** in Review, and when you copy a setup command in Settings. Discard clears the clipboard if it still holds that capture. Pilcrow never reads the clipboard.

## Logs

Pilcrow logs to the macOS unified log under the subsystem `org.pilcrow.app`. The logs record events and outcomes: session triggers, display IDs, timings, word counts and delivery results. They don't include your words, on-screen text or file paths.
