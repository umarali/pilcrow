# Core

`PilcrowCore` owns identity, timing, geometry, transcript alignment, export names and per-mark fix lists. It imports Foundation only. The App owns capture, audio, image rendering, files and delivery. Core and its test target compile in Swift 6 language mode; the App and package default are unchanged.

Times are seconds on one monotonic session clock whose origin `t0` is when the session opens. The App uses the same uptime time base as `NSEvent.timestamp` and `ProcessInfo.systemUptime`.

## Model and capture lifecycle

`MarkID` is a stable integer. A session issues `1` first and never reuses deleted numbers. `Frame` and `Stroke` conform to `Identifiable`. Frame references use `Frame.ID`, an alias for `UUID`; stroke IDs use `MarkID`.

`NormalizedPoint` has a top-left origin, x rightward and y downward. Its coordinates are fractions of the frame, normally `0...1`; storage does not clamp them. `Point` and `Size` express raw coordinates and dimensions in the units named by their caller.

A `Frame` registers one capture's identity and coordinate space:

- `id`, `displayID: UInt32` and `boundsInPoints: Size` identify its display and size in AppKit points. The App retains the screen origin separately.
- `boundsInPoints` must have finite positive width and height, including while pending.
- `capturedAt: Double?` and `pixelSize: Size?` are both nil while pending. `captureFailed` starts false. A complete frame has a finite capture time and finite positive pixel dimensions, with `captureFailed == false`. `isComplete` checks those capture fields. Session validation requires integer pixel dimensions and also requires the pixel aspect divided by the point aspect to be within `0.99...1.01`, inclusive. The logarithmic comparison allows `1e-12` rounding tolerance at the boundaries.
- Core metadata does not prove an image file was written; the App must report completion only after capture succeeds.

Register before pen-down, then complete after asynchronous capture succeeds:

```swift
var session = Session() // Non-throwing empty initializer.
let frame = Frame(id: Frame.ID(), displayID: 1,
                  boundsInPoints: Size(width: 800, height: 600))
try session.addFrame(frame)
let mark = try session.beginStroke(at: 1, frame: frame.id,
                                   firstPoint: NormalizedPoint(x: 0.4, y: 0.5))
// Drawing can continue while capture is pending.
try session.completeFrame(id: frame.id,
                          pixelSize: Size(width: 1600, height: 1200), capturedAt: 1.1)
```

`updateFrame(_:)` can replace metadata using the same ID. It cannot change the display or point bounds because stored normalized strokes refer to that coordinate space. A complete frame cannot become pending or failed. Complete-to-complete metadata replacement remains allowed if the geometry validates. A complete `Frame(id:capturedAt:displayID:boundsInPoints:pixelSize:)` may also be registered directly.

Call `failFrame(id:)` when capture reports an actual failure. It sets `captureFailed` without removing the pending frame or its strokes. Repeated failure is harmless. Pending frames appear in `OutgoingMessage.pendingImages` and failed frames in `failedImages`; fix items distinguish `pendingFrame` from `failedFrame`. Before sealing, a failed frame can complete on retry, which clears `captureFailed`, or explicitly return to pending through `updateFrame` with nil capture fields and `captureFailed == false`. Neither changes mark IDs or timing. Unknown frame IDs are rejected; strokes cannot reference an unregistered capture.

Frame Codable accepts older complete-frame JSON with numeric `capturedAt` and `pixelSize`, and pending metadata omitted or null. Missing `captureFailed` defaults to false. Session decoding validates point bounds, capture metadata, aspect ratio and frame references. Unsealed pending and failed sessions round-trip and can complete after reload.

`Stroke` stores `id`, `frameID`, `downTime`, optional `upTime`, normalized `points`, `badgeAnchor` and `isDeleted`. The first point becomes the badge anchor; subsequent samples do not move it. An open stroke has nil `upTime` and remains live.

`TranscriptWord` stores `text`, `start`, `end`, `isFinal` and `isEstimated`. Word timings are estimates, including SpeechTranscriber per-run timing distributed into words. `isEstimated` defaults to true in the initializer and when decoding older JSON without the key. Producers may explicitly set false when they have measured word timings.

## Session operations and errors

`Session()` is non-throwing. The initializer accepting stored state validates it and throws. `strokes`, `frames` and `nextMarkNumber` are read-only externally; `words` may be replaced as recognition changes before sealing.

`Session.ValidationError` has these cases:

- `duplicateStrokeID`: stored strokes repeat a mark ID.
- `duplicateFrameID`: stored frames repeat an ID, or `addFrame` repeats one.
- `unknownFrameID`: stored strokes, `beginStroke`, `updateFrame`, `completeFrame` or `failFrame` reference an unregistered ID.
- `exhaustedMarkIDs`: stored ID `Int.max` prevents advancing the counter, or `beginStroke` cannot issue a new ID.
- `nonFiniteTime`: `beginStroke` receives NaN or either infinity.
- `nonFinitePoint`: either coordinate passed to `beginStroke` is NaN or infinite.
- `invalidFrameBounds`: registered or decoded point bounds are non-finite or non-positive.
- `invalidFrameCapture`: only one capture metadata field is supplied, or capture time/dimensions are invalid, including fractional pixel dimensions.
- `frameGeometryMismatch`: `updateFrame` changes the registered display or point bounds, or any complete frame has more than 1% relative aspect mismatch.
- `sealedSession`: any throwing mutation is attempted after sealing. This is checked before other errors.
- `invalidFrameTransition`: a complete frame becomes incomplete, or a failed frame supplies capture metadata.

Mutating operations validate before writing. `addFrame`, `updateFrame`, `completeFrame` and `failFrame` throw. `beginStroke(at:frame:firstPoint:)` throws with the reason instead of returning nil, and its result must be used or explicitly ignored. Before sealing, it checks non-finite time, unknown frame, exhausted IDs and non-finite first point in that order. These errors leave the session unchanged.

`append(point:to:)` ignores non-finite points and missing, ended or deleted strokes; each is a documented no-op. Finite out-of-frame coordinates remain valid and are not clamped. Stored strokes supplied to the state initializer retain their coordinates, so malformed legacy geometry can still produce an `invalidGeometry` crop reason. `endStroke(id:at:)` ignores missing, deleted or ended strokes, non-finite times, and times before pen-down. `deleteMark(id:)` hides a mark without removing its stored ID; a missing ID does nothing.

`seal()` is non-throwing and idempotent. It converts every still-pending capture to failed, retains complete captures, and sets read-only `isSealed`. All frame mutations and `beginStroke` then throw `sealedSession`; `append`, `endStroke`, `deleteMark` and writes to `words` become no-ops. This also blocks late speech recognition. Sealing does not invent pen-up times for open strokes. A sealed session round-trips through Codable and remains sealed; older JSON defaults to open. Decoding sealed JSON with pending frames finalizes them as failures. Retries are allowed only before sealing.

`liveMarks` is non-deleted strokes in stored session order, also called mark order. `framesWithMarks` contains only frames with live marks, ordered by each frame's first stored stroke, including deleted strokes on frames that still have another live mark. This is drawing order rather than capture-array or timestamp order. A frame whose every mark is deleted is omitted.

The counter is the maximum of 1, the supplied or decoded counter, and one past the highest stored ID, including deleted marks. Older JSON without a counter is accepted. Validation failures surface as `ValidationError`; malformed JSON may produce standard decoding errors.

## Alignment and transcript rendering

`Aligner.place(words:strokes:onlyFinal:)` drops deleted strokes and words with non-finite start or end times. `onlyFinal: true` also drops non-final words before placement. The default includes provisional words. Words sort by start, then end, then original order.

A finite stroke's slot is the count of words whose start is at or before pen-down. A mark at a word's start follows that word. In gaps it follows the last word started; before all words it leads. All overlapping words already started precede the mark. Finite marks in a slot sort by down time, then ID. Non-finite stored pen-down times trail all words and finite marks, in ID order. With no words, finite marks precede non-finite marks. Pen-up time does not affect placement.

`TranscriptRenderer.render(tokens:)` splits each word on Swift `Character.isWhitespace`, then joins nonempty parts and `[n]` tokens with single spaces. CRLF and mixed newline runs collapse once. It does not trim Unicode scalars: whitespace and its combining mark are removed as a whole grapheme, so the accent cannot become attached to the following letter. Punctuation stays inside words. There is no trailing newline.

## Image naming and outgoing messages

`MessageBuilder.filenames(for:)` assigns `frame-1.png` through `frame-N.png` to `framesWithMarks` in first-stroke order, including pending frames. Names are consecutive among currently marked frames, so removing every mark from a frame may renumber the remaining frames. Completing a pending frame does not change names. The public builder accepts no caller-supplied filenames; generated names have no path separators or line breaks and cannot collide.

`MessageBuilder.build(session:destinationHint:onlyFinal:)` is the single public outgoing-message builder. Its text contains the transcript with inline `[n]`, a blank line, then one quoted fix-list entry per live mark in stored mark order. The former frame-only legend is removed. The fix-list Markdown renderer is internal.

```text
sign out [17] over here

- [17] "sign out over here" → mark-17.png (in frame-1.png)
```

`attachments` contains complete marked frame names in first-stroke order, followed by available crop names in live-mark order. Each frame appears once; each available mark crop appears once. Pending or failed captures have neither frame nor crop attachments. Invalid stored stroke geometry can omit a crop while retaining its complete frame attachment. `pendingImages` and `failedImages` contain the corresponding marked frame IDs, each in first-stroke order. A sealed session has no pending images or pending-capture phrases. The read-only compatibility view `missingImages` concatenates pending then failed IDs; new code should use the separate arrays.

`cropPlans` contains one `CropPlan` per attached crop, in the same crop order. Each plan has `sourceFrameID`, `sourceFrameName`, `sourcePixelRect`, `outputSize` and `cropName`. Its rectangle refers to the **original captured image**, with top-left origin, before whole-frame export downscaling. The App must keep that original image, render its annotations, crop the source rectangle, resize the crop to `outputSize`, and write `cropName`. `framePlans` contains one `FramePlan` per complete marked frame, in attachment order, with `frameID`, `outputName` and integer `outputSize` after `Geometry.fitPixels` with `ImageLimits`. Look up original images by these IDs rather than inverting filenames. Do not crop from an already resized frame attachment.

The App must write files **only from the final build** after edits, deletion and capture outcomes settle. Deleting every mark from a frame can renumber later frame filenames; an earlier plan must not be reused. Core plans files but does not write them. The App must surface export failures separately and attach only files it has successfully produced.

There is no trailing newline. Empty sections omit the blank separator. `destinationHint` stays separate from text. `isEmpty` considers text and attachments only. Older `OutgoingMessage` JSON without outcome arrays, `cropPlans` or `framePlans` defaults them to empty. Legacy `missingImages` decodes into `failedImages`: a saved message cannot promise that its missing capture is still in progress. New encoding also emits the combined legacy key for older readers. A legacy crop plan without `sourceFrameID` decodes with nil identity; newly built plans always have an ID. Rebuild legacy plans from the session before exporting, since their frame identity cannot be recovered safely from a filename alone.

## Per-mark fix list

`FixList.build(session:onlyFinal:)` creates one `FixItem` per live mark in mark order, with the full aligned transcript stored separately. Each item has `mark`, `frameID`, `imageName` from the same filename helper, `cropName` such as `mark-3.png`, `cropRect`, `outputSize`, `unavailableReason` and `words`. Building a plan does not render or write images.

### Crop rule

1. Find the bounding box of all stored stroke points **and the badge anchor**, in the frame's top-left **AppKit points** by multiplying normalized x/y by `boundsInPoints`. An empty point array uses the anchor alone. Negative and out-of-frame points participate in the box.
2. Pad every side by `max(48 pt, 0.25 × max(box width, box height))`, measured in points.
3. Expand to at least **320 × 200 pt**, preserving the box's center. Shift inside the point bounds and clamp each dimension to the frame dimension. A smaller display can produce a smaller source crop.
4. Convert the point rectangle to original captured pixels independently per axis, using `pixelSize.width / boundsInPoints.width` and `pixelSize.height / boundsInPoints.height`. Round the pixel origin down and far edges up, staying within the source image. `cropRect` is this source rectangle, **before downscaling**, with `origin: Point` and `size: Size` in pixels.
5. Apply `Geometry.fitPixels` with `ImageLimits` to obtain `outputSize: PixelSize`, whose width and height are integer pixels. Output may be smaller than the minimum source crop.

For a centered dot on a 1000 × 500 pt display captured at 2000 × 1000 px, the source rectangle is x=680, y=300, width=640, height=400 px. A dot at its top-left shifts to x=0, y=0 with the same size. A point-space box from x=300 to 700 and y=200 to 300 pads by 100 pt and becomes 600 × 300 pt at x=200, y=100, or 1200 × 600 px at x=400, y=200. At 1× scale the same point-space crops have half as many pixels. Slight per-axis scale differences within the 1% aspect tolerance use the actual scales.

Huge finite coordinates can overflow intermediate spans; these request full frame dimensions and remain bounded. Non-finite points or anchors produce nil rectangle and output size with `invalidGeometry`. Pending frames use `pendingFrame`; failed captures use `failedFrame`. A defensive `missingFrame` reason exists, although Session validation rejects unregistered references. No live mark is omitted for missing pixels. Badge **anchor** coverage is guaranteed; the App chooses the badge's rendered footprint and must honor its minimum exported height.

### Words rule

Context uses the same aligned token sequence as the full transcript, after `onlyFinal` and invalid-time filtering. For context only, split recognition runs into whitespace-separated words after alignment, retaining the run's timed mark slot after all its words. Context has no inline mark tokens and joins words with one space.

Select the sentence containing the word immediately before the mark's slot. At slot zero use the first word. A slot just after sentence-ending punctuation belongs to that preceding sentence. A word ending in `?`, `!` or `…` always ends a sentence. A final `.` ends a sentence only when the next word starts with an uppercase character or digit, or there is no next word. Thus `e.g. this`, `i.e. that` and `etc. here` remain in one sentence. This is a heuristic, not an abbreviation dictionary; punctuation followed by a closing quote is not recognized.

Let S be that sentence, from after the preceding terminator through the next terminator inclusive, or the unterminated tail. Use all of S if it has **at most 25 words** and contains no other mark at a **different slot**. Assign marks to sentences by the same preceding-word rule. Marks sharing the current slot do not disqualify the sentence or bound one another.

Otherwise use the half-open word window `[left, right)`, where `left = max(S.start, slot - 12, P)` and `right = min(S.end, slot + 6, N)`. P is the closest other-mark slot strictly less than this slot, or negative infinity; N is the closest strictly greater slot, or positive infinity. This keeps context inside the sentence and limits it to 12 preceding plus 6 following words. When the transcript has words, this window is never empty: `left <= slot - 1 < slot <= right`. With no words every mark remains listed with empty context.

Examples, with word numbers starting at one and slots counting preceding words:

- Forty unpunctuated words, one mark at slot 20: context is words 9 through 26.
- A 30-word sentence between `Before.` and `After.`, with one mark inside: context stays in the 30-word sentence and contains at most 18 words.
- `Make these bigger. [1] [2] Then align the footer.`: both contexts are `Make these bigger.`.
- One hundred short sentences followed by `Make [1] a b [2] c d.`: mark 1 gets `Make a b`; mark 2 gets `a b c d.`. Earlier sentences do not leak into the window.
- `Please fix [1] this. Then stop! [2]`: contexts stay `Please fix this.` and `Then stop!`.
- `a [1] b c [2] d e [3] f.`: contexts stay `a b c`, `b c d e`, `d e f.`.
- `First. [1] Next sentence.` and `[1] First.` both give mark 1 `First.`.
- `a b c d e f g h [1] [2] [3]`: all three share the full short sentence because their slots are equal.

### Markdown rendering

`MessageBuilder.build(...).text` contains the full transcript first, then a blank line and one line per fix item:

```text
sign out [3] over here

- [3] "sign out over here" → mark-3.png (in frame-1.png)
```

Inside quoted words, `TextSanitizer` collapses newline runs and escapes only `"` and `\`. Markdown characters such as `#`, `_` and `!` remain untouched. Transcript words retain the renderer's whitespace rules. At the start of each transcript line, after indentation, it escapes only real block openers: a digit run followed by `.` or `)` and then whitespace or end of line; `-`, `+` or `*` followed by whitespace, or three or more consecutive copies of one of those characters; one to six `#` followed by whitespace or end of line; three or more backticks, tildes or underscores; any `>`; and `<` followed by a letter, `/`, `!` or `?`. The ordered-list delimiter is escaped, for example `1\. item` and `1\) item`. This prevents a transcript fence or HTML block from swallowing the fix list without changing ordinary text such as `3.5` or `-5`. The raw `FixList.transcript` and `TranscriptRenderer` output stay plain text.

Unavailable crops keep their planned names and append human phrases: `(screenshot pending)`, `(screenshot not available)` for failed or missing frames, or `(crop not available: invalid geometry)`. These names do not claim a file exists. Empty lists omit the blank separator; an empty session renders an empty string. There is no trailing newline. The result is deterministic for a given session.

## Geometry and legibility

The App must call `Geometry.normalizedPoint(screenPoint:frameOrigin:frame:)` for pen input, including before capture finishes. Pass the mouse location in **AppKit global screen coordinates**, measured in points with bottom-left origin; pass the selected frame display's **bottom-left global screen origin**, such as `NSScreen.frame.origin`, as `frameOrigin`. Register that display's `NSScreen.frame.size` as `boundsInPoints`. Do not pass overlay-local coordinates, a top-left origin or backing pixels, and do not pre-flip or pre-scale the point. Core computes `x = (screenPoint.x - frameOrigin.x) / width` and `y = 1 - (screenPoint.y - frameOrigin.y) / height`. Negative screen origins work, no pixels are needed, and out-of-frame fractions are preserved. Non-finite inputs, non-positive or non-finite bounds, and non-finite conversion results return nil; the App must skip that sample.

`Geometry.pixelPoint` performs the same conversion then multiplies by original captured pixels. `normalize` divides top-left source pixels by `pixelSize`; `denormalize` multiplies frame fractions by it. All three pixel helpers return nil for pending or failed frames, invalid pixel metadata or non-finite input/results. They never substitute zero dimensions for missing captures.

`ImageLimits.maxLongEdge = 1600`, `maxPixels = 1_560_000` and `minBadgeHeightPixels = 24` implement D-17.5. `Geometry.suggestedMaxLongEdge` and `suggestedMaxPixels` alias the corresponding limits. Both fitting functions require explicit caps.

`fit(size:maxLongEdge:maxPixels:)` preserves aspect ratio without upscaling and returns floating-point dimensions. Non-finite or non-positive dimensions or caps return zero dimensions. Floating-point multiplication can exceed the pixel cap by a few ULPs; callers testing it must allow that tolerance.

`fitPixels(width:height:maxLongEdge:maxPixels:)` floors scaled dimensions, with a one-pixel minimum per axis. It does not upscale except for that minimum: `0.5 × 0.5` returns `1 × 1`. Integer outputs honor both caps, including very thin inputs whose other side must shrink to allow the one-pixel minimum. Values stay within representable `Int` bounds. Non-finite or non-positive inputs and caps below one return nil. Both functions compute area scale as `sqrt(maxPixels) / sqrt(width) / sqrt(height)` to avoid intermediate overflow or underflow for huge finite dimensions.

## App wiring contract

Serialize session mutations on one App-owned executor. Retain original captures keyed by frame ID and retain each display's global bottom-left origin separately. Use one clock: let `t0` be the uptime when the session opens, using the time base shared by `NSEvent.timestamp` and `ProcessInfo.systemUptime`. For each pen event use `event.timestamp - t0`. Recognizer times are relative to the audio stream start, so set each word's `start` and `end` to `recognizerTime + (audioStartUptime - t0)`, where `audioStartUptime` is the host time of the first audio buffer, converted with `AVAudioTime.seconds(forHostTime: firstBufferTime.hostTime)` (taking `systemUptime` inside the tap callback runs about one buffer late and places marks too early). Re-anchor `audioStartUptime` whenever the audio engine restarts. Set `capturedAt` to the uptime when capture completed minus `t0`.

1. Open a non-throwing `Session()` and record monotonic clock origin `t0` as described above. On every recognizer update, set `session.words` to all words finalised so far plus the current provisional tail (not only the latest result, which would drop earlier finalised words), carrying each word's `isFinal` and `isEstimated` values. Update words only before `seal()`; writes after sealing are ignored. Pass `onlyFinal: false` to `MessageBuilder.build` so the last partial words are retained, unless the recognizer has finalised everything.
2. On the first stroke of a capture pass on a display, create a pending `Frame` with that display's point bounds, `try addFrame`, then start capture keyed by its ID. Reuse that ID for subsequent strokes in the same pass on that display. A new pass after an underlying click or scroll needs a new frame. If registration throws, surface the error and do not start capture or a stroke on that ID.
3. At pen-down, call `Geometry.normalizedPoint(screenPoint:frameOrigin:frame:)` with global AppKit points and the display's bottom-left origin. If it returns nil, skip the whole stroke and do not call `beginStroke`. Otherwise call `try beginStroke(at:frame:firstPoint:)` and retain the returned mark ID. On an error, surface it and do not append to a nonexistent stroke.
4. During drag, normalize each sample the same way and call non-throwing `append(point:to:)` for valid samples; skip only a nil sample. At pen-up call non-throwing `endStroke(id:at:)`. Undo deletes the most recent live mark of the current pass, in stored order, by calling `deleteMark(id:)`; there is no redo because deletion is permanent. Clearing deletes the relevant live IDs. Undoing the pass's last mark removes its frame from the build, so later `frame-N` names can renumber; write files only from the final sealed build.
5. On capture success, call `try completeFrame` first with integer source dimensions and the capture completion time. Store the captured pixels under the frame ID only if completion succeeds. If it throws `frameGeometryMismatch` for a pending frame, call `try failFrame(id:)` and surface the validation failure. Ignore a second completion for a frame already complete; the App must not call `completeFrame` again. Failure, timeout, permission refusal or cancellation calls `try failFrame` directly, but only while the frame is not complete; a late timeout or failure for a frame that already completed is ignored, not surfaced. Unknown IDs or invalid transitions are integration errors; surface them. After sealing, discard late results on `sealedSession` and leave the approved snapshot untouched. A canceled/timed-out task must not later replace a failed outcome unless an explicit retry is still desired before sealing. Exclude Pilcrow's own overlay windows from captures so their ink is not drawn twice.
6. Finish stops accepting new input, ends any open stroke if a valid pen-up time is available, and awaits bounded capture and recognition outcomes. Resolve timeout/cancel outcomes with `failFrame`, then call non-throwing `seal()`. Outstanding pending frames become failed. Call non-throwing `MessageBuilder.build` on that sealed value.
7. Write whole frames from `framePlans` and crops from `cropPlans`, looking up **ORIGINAL captured images by ID**. Burn in the sealed snapshot's live marks and badges in original coordinates before cropping/resizing; honor the 24 px minimum exported badge height. Whole-frame and crop output sizes come directly from their respective plans. Never crop a downscaled frame attachment. A nil legacy crop source ID requires rebuilding from the session before export.
8. Attach only files actually written successfully. Surface export failures in the preview and finalize its attachment list before approval. If `OutgoingMessage.isEmpty` is true (no words and no live marks), do not preview or send it; show `Nothing to send`. A session with speech but no marks is previewed and sent as transcript only. Preview the sealed message and those actual files. On approval, send that same sealed snapshot, text and attachment list. Do not rebuild from a still-changing session or replace image bytes after approval. Cancel sends nothing. Export, preview and delivery are App responsibilities; Core metadata alone does not establish their success.
