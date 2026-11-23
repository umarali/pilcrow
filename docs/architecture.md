# Architecture

[Package.swift](../Package.swift) defines three production targets and their test targets.

- **PilcrowCore** holds the session model, shape recognition, timing, geometry and message assembly.
  It imports only Foundation and works with values, so tests can exercise these rules without windows, capture, audio or permissions.
- **PilcrowApp** builds the macOS app executable, `Pilcrow`. It owns AppKit and SwiftUI,
  OS permissions, screen capture, speech, image rendering and delivery. It depends on Core.
- **PilcrowMCP** builds `pilcrow-mcp`, a read-only server over stdio.
  It depends on Core for the manifest schema and runs independently of the app.

## Start, draw and finish

1. **Start.** The default ⌥D shortcut or the ¶ menu asks `AppDelegate` to start.
   `Permissions` checks Screen Recording access and probes capture before opening the session.
   `AnnotationSession` puts a canvas on each display, puts the Finish pill on the pointer's display
   and starts voice if it is ready.
2. **Draw.** Holding ⇧ alone gives the canvas mouse input on the pointer's display.
   An active drag continues until mouse-up or until the app detects that the button was released.
   On the first mark on each display in a pass, the app registers a pending Core frame and starts
   a ScreenCaptureKit still capture that excludes Pilcrow. Drawing can continue while capture is pending.
   A click or scroll through the canvas after drawing starts a new pass on the next mark.
   Earlier passes stay in the session.
3. **Record marks.** The app converts global screen points to top-left frame fractions.
   `Session` assigns the number on pen-down, stores the points and classifies the gesture in frame points
   on pen-up. It handles arrow links to areas and pins, can absorb drawn heads into the shaft,
   and undoes gestures in the current pass.
4. **Record words.** `VoiceNarration` feeds microphone audio to `SpeechAnalyzer` using
   `SpeechTranscriber` or `DictationTranscriber`. The app turns result ranges into estimated word
   times on the same uptime clock used for pen events. Overlapping hypotheses are reconciled
   before the words reach Core.
5. **Finish.** The shortcut, Esc, pill, menu or display reconfiguration closes the overlay.
   Finish waits for bounded speech and capture outcomes, then seals the session. Sealing freezes
   the session and turns any pending frames into failures. An empty message produces no capture.
6. **Build and export.** `FixList` pairs marks with words and plans crops. `MessageBuilder` formats
   the transcript and fix lines and plans the attachments. The app collects bounded OCR from original
   screenshots and rebuilds the message with available text. Export writes annotated frames and crops,
   adding captions where marks have words. It also writes local diagnostics, including `strokes.json`.
   Missing images leave their fix lines intact.

## Where the rules live

- **Shapes and arrows.** `ShapeRecognizer.swift` classifies pins, areas, arrows and plain ink. `Session.swift` applies classification, head absorption, links and undo.
- **Words.** `Aligner.swift` places inline `[n]` at pen-down and assigns nearby clauses to marks. `TranscriptCleanup.swift` removes supported fillers and stutters from fix lines. The paragraph retains the recognizer's wording. See the [words rule](core.md#words-rule-d-27) for timing, redraw and shared instructions.
- **Crops.** `FixList.swift` pads each mark's fitted bounds or rendered ink and expands the crop to at least 320 × 200 points where the display allows. It clamps the rectangle to the frame, converts it to source pixels and fits the output to Core's image limits. See the [crop rule](core.md#crop-rule).
- **Badges.** `Mark.swift` renders the canvas and export ink. It places badges in mark order using candidate positions for each shape, avoiding other marks' arrowheads and earlier badges where possible.
- **Window context.** `WindowContext.swift` picks the normal window under a frame's first mark, falling back to the frontmost normal window on that display. It excludes Pilcrow. Core formats the available app name and title as a frame header.
- **Visible text.** `MarkTextRecognition.swift` uses on-device Vision on the original pixels. Areas select whole words inside the shape, pins and arrow tips select one clear nearby label, and plain marks follow the ink. The 600 ms budget includes queue time. OCR text goes in fix lines. Image captions use spoken words.

See [Core](core.md) for the exact contract and [the decision log](decisions.md) for the rationale.

## Delivery

Export writes directly into an outbox item under `~/Library/Application Support/Pilcrow/Outbox/`. The app locks the item during export, writes `message-for-agent.md` and publishes the v1 manifest atomically as the last step.

```text
Outbox/
└── <capture UUID>/       private item directory (0700)
    ├── frame-N.png      annotated screenshot for a display and pass, if available
    ├── mark-N.png       crop for a live mark, if available
    ├── message.md       exported transcript and fix list
    ├── strokes.json     optional local gesture data
    ├── debug/
    │   └── voice.json   optional local transcript and timing trace
    ├── send.command     added for a Terminal send
    ├── message-for-agent.md
    └── manifest.json    item ID, time, destination, text and saved attachments
```

- **Clipboard and HUD.** On Finish the app copies text with absolute image paths and image file URLs. The HUD reports the copy result. If publication fails, the app keeps available files for Copy and Show in Finder from Review, using a temporary recovery folder when possible.
- **Review.** Open it from the HUD or ¶ menu. It shows the saved crops and words and offers Copy, Claude Code, Codex, Show in Finder and Discard. Terminal sends use the chosen project folder and reuse the capture. A successful handoff means Terminal accepted the command file.
- **MCP.** A configured client can fetch any valid published capture from the last 24 hours, regardless of the manifest destination. The server reads safe image attachments and message text through `pilcrow_latest`, `pilcrow_list` and `pilcrow_get`. Diagnostic JSON stays out of the manifest and handoff. The app prunes expired items on launch, after Finish and around secondary sends.

## Replay a recognizer miss

1. In Review, choose **Show in Finder** and save `strokes.json`. The file records frame sizes, gesture points in top-left frame points, timing and classification. Check `recognizerVersion` before comparing results.
2. In a Core test, decode the file with `JSONDecoder().decode(StrokeRecording.self, from: data)`. Call `record.replay(existingMarks:)` to classify one gesture without renormalizing its points. For arrow context, supply the earlier same-frame marks as they stood at pen-up.
3. For drawn heads and links added by later marks, replay the records in drawing order through `Session`. Register a frame from each record's frame ID and size as needed, divide the points by its size, then use the recorded times for pen-down and pen-up. See [the replay tests](../Tests/PilcrowCoreTests/Round3ReplayTests.swift).
4. Compare shape, fitted bounds and links against the expected result. Deleted gestures are omitted from the recording. A decimated record gives an approximate replay.

## Finding your way

Files are named after what they do. These are the entry points:

- **Session flow:** `PilcrowApp/AppDelegate.swift` owns the menu and starts sessions. `AnnotationSession.swift` runs a session from first stroke to Finish. `Overlay.swift` hosts the canvas and its mouse events, and `Toolbar.swift` shows the pill.
- **Capture and context:** `Capture.swift` covers ScreenCaptureKit stills and permission probes. `WindowContext.swift` finds the window under the first mark. `MarkTextRecognition.swift` runs Vision OCR.
- **Voice:** `VoiceNarration.swift` handles the microphone and analyzer segments. `VoiceSegment.swift` reconciles results, and `VoiceTiming.swift` maps them onto the session clock.
- **Export and delivery:** `Export.swift` and `ExportCaptions.swift` write the PNGs and messages. `OutboxStore.swift` publishes and prunes captures. `FinishHUD.swift` handles the clipboard and receipt, `ApprovalPreview.swift` is Review, and `DeliveryText.swift` builds Terminal send scripts.
- **Settings:** `SettingsView.swift`, `SettingsWindow.swift`, `ShortcutSettings.swift`, `PilcrowColour.swift` and `Permissions.swift`.
- **Core rules:** `Session.swift`, `ShapeRecognizer.swift`, `Aligner.swift`, `FixList.swift`, `MessageBuilder.swift` and `Geometry.swift`. See [Where the rules live](#where-the-rules-live).
- **MCP:** `PilcrowMCP/Server.swift` handles JSON-RPC and file validation. `main.swift` runs the stdio loop.
