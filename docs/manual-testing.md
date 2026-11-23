# Manual testing on a Mac

Use a signed build from [Building Pilcrow](building.md). Prepare a disposable document with distinct landmarks and readable labels. Use non-sensitive content on every display and in narration. Run the sections affected by your change.

## Permissions and recovery

- [ ] Reset Pilcrow's permissions. Start with ⌥D and from the ¶ menu while Screen Recording is off. Expect Settings with the Screen Recording action and a usable desktop. The canvas and permission prompt should stay closed.
- [ ] Use the Screen Recording action, deny access, then grant it in System Settings. Check that the permission status refreshes. If Pilcrow offers **Quit & Reopen**, use it. After reopening, Start should show the canvas once the capture probe succeeds.
- [ ] With Screen Recording granted, start again while Microphone is off. Expect drawing and Finish to work without a microphone or speech permission prompt.
- [ ] If Esc or the Start shortcut is unavailable, check the session warning and finish via the pill or ¶ menu. With those shortcuts available, check that each closes the overlay.

## Drawing and passes

- [ ] Click and type beneath the canvas with ⇧ released, then hold ⇧ alone and drag. Expect the editor to keep keyboard focus and the canvas to draw. Release ⇧ during the drag and move before mouse-up. The stroke should continue to mouse-up. With another modifier held before clicking, expect click-through.
- [ ] Hold ⇧ alone without clicking, then release. Expect the ring to appear after about 200 ms and disappear on release. A quick ⇧ tap and typing capital letters should leave the ring hidden. ⇧-clicks should add pins without activating the control underneath. Also try a ⇧-click within the first instant of pressing ⇧ over a harmless button, and note whether the button reacts.
- [ ] Draw twice on one display, typing between strokes. Both marks should stay on the same pass. Scroll or click through, then draw again. The earlier marks should leave the canvas. Finish and check that each pass has its own frame and matching crops.
- [ ] Draw two marks, undo the second, then draw a replacement. Expect a higher badge number and no undone mark in the message or images. After undoing the last completed mark in a pass, ⌘Z should reach the editor. During a drag, undo should leave the current stroke intact.
- [ ] Interrupt a drag with Mission Control and release the mouse and ⇧ while away. On return, check that the editor receives clicks and a fresh ⇧-drag works. Note whether the log shows recovery without mouse-up.

## Shapes, arrows and heads

- [ ] Draw a rough closed box, an oval, a lopsided closed area, a ⇧-click and an underline. Expect fitted boxes and ovals, preserved ink for the irregular area and underline, and a numbered pin.
- [ ] Draw a straight shaft from a numbered area or pin toward another mark. Check the head direction, the link or links in the fix line and the badge's clearance from the target. Add an area around the tip of an existing arrow and check that its badge tries a spot clear of the head.
- [ ] Add a hook in the shaft's stroke, then try a separate V on another shaft. Try a V or paired barbs at the shaft's start. Expect a clean head, reversed direction for a head at the start, and no extra visible number for an absorbed gesture.
- [ ] Undo a separate head that changed the shaft. Expect the previous shape and direction to return. If the head left the shaft looking the same, expect undo to remove the shaft as well. Redraw the head on a restored shaft within three seconds. Expect it to attach again.
- [ ] Draw near a frame edge, then inspect the exported crop. Check that the relevant mark, including its arrowhead and badge where applicable, is readable. If recognition misses, save `strokes.json`.

## Multiple displays and Spaces

- [ ] Start with the pointer on a secondary display. The pill should appear there. On mixed-scale displays with one above or left of the primary, mark opposite corners on both in one pass. Expect one frame per marked display, correct alignment and upright badges.
- [ ] Start in a native full-screen Space. Check drawing, click-through and Finish without a jump to another Space. Check that the HUD stays on the display and Space where you finish.
- [ ] Change the Dock position with a session open. Expect the pill to follow the visible area. Disconnect a marked display and check that the session ends, available frames export and the log reports display change. Reconnect and start again.

## Finish, clipboard, HUD and Review

- [ ] Finish marked sessions with Esc, the toggle shortcut, the pill and the ¶ menu. Expect the overlay to close and the HUD to report **Copied · ⌘V** after a successful copy. Finish an empty session and expect no HUD or new outbox item.
- [ ] Paste into a target that accepts text and image files. Check the numbered fix list, absolute image paths, frame images and crops. Paste into an image-only target after a spoken mark. Its crop should carry the instruction under the matching badge.
- [ ] Click the HUD and then reopen Review from the menu. Compare the crops and spoken words with the files under **Show in Finder**. Check that exported images omit the pill and drawing hint. Inspect at actual size. PNGs must fit within 1,600 px per edge and 1.56 MP and badges must be at least 24 px tall.
- [ ] Leave a receipt alone and then hover over a new one. Expect it to disappear after about five seconds when the pointer is away. Check that Review remains available from the menu.
- [ ] With a supported CLI installed, send from Review to a disposable project. First use should ask for a folder. Later sends should reuse it until **Change project…**. Check that Terminal opens the command in that project with the saved message.
- [ ] Copy unrelated text after Finish, then Discard from Review. The capture should disappear from Review and the outbox. The newer clipboard contents should survive.

## Voice

- [ ] With microphone permission unset, choose the Microphone action in Settings and deny access. Expect a denied state and no model download. Grant access, return to Settings and complete speech setup when offered. Expect progress for a download and no separate Speech Recognition prompt.
- [ ] With the model ready, speak while drawing marks on “heading” in “Move the heading down” and “footer” in “Align the footer left.” The mic dot should respond to speech. Press Esc at the end of the second sentence. Expect the last word once in the transcript and each instruction with its intended mark.
- [ ] Speak a short instruction, finish without drawing and paste into an editor. Expect a words-only receipt and transcript without images. With the model installed, repeat offline.
- [ ] Switch the default microphone during a session and keep speaking while marking. Look for a new first-buffer anchor in the log. Check that the transcript stays in order without repeated words at the join. If the input cannot recover, expect a voice warning and working drawing and Finish.
- [ ] Narrate a mark, undo it and redraw in silence. Expect the replacement to inherit the instruction. Repeat with new words between undo and redraw. The replacement should use those words and the paragraph should retain the original instruction.

## Settings and colour

- [ ] Open Settings twice. Expect one window. Record a valid Start shortcut, relaunch and check that it works. Try a chord another app already uses: the reason should show and the previous shortcut should keep working. Try a reserved chord such as ⌘C: the reason should show and the recorder should stay active until you cancel or choose a valid chord. Cancel with Esc and reset with unmodified Delete.
- [ ] Change the keyboard layout. Default shortcuts should follow their letters and a recorded custom chord should keep its physical key. A chord that becomes reserved should show as unavailable until a compatible layout returns or the chord is changed.
- [ ] Pick a new colour and check light and dark appearance. Verify readable Settings numerals and the chosen colour on the pointer ring, canvas marks and exported badges. Turn on Reduce Transparency and check that the Settings groups use opaque fills. Relaunch and check that the colour persists.
- [ ] Use **Show** to reveal the outbox, then **Clear** with disposable captures present. Eligible captures should disappear and stale Review or HUD UI should close. The clipboard should stay unchanged.

## Window context and visible text

- [ ] Draw around a legible “Save changes” label while speaking. The message should name the app and available window title once for that frame. The fix line should keep the instruction and add `on "Save changes"`. The image caption should contain only the spoken instruction.
- [ ] Mark different windows in separate passes and on separate displays. Each frame should use the window under its first mark. On a blank part of the desktop, expect the frontmost normal window on that display, or omitted context if none is available.
- [ ] Box text beside another label, point an arrow at text, pin a label and underline another. Areas should select whole words inside the shape. Pins and arrow tips should choose at most one nearby clear label. Underlines should follow the ink. Blank space and unreliable recognition should leave the visible-text field out.

## MCP from a fresh agent session

- [ ] Copy the setup command for your agent from Settings and run it in Terminal. Open a fresh agent session in a different project. Finish a marked capture without opening Review, then call `pilcrow_latest`. Expect the new fix list with PNGs.
- [ ] Call `pilcrow_list`, then `pilcrow_get` with the capture ID and one mark number. Expect the matching fix line, crop and frame header when available. Diagnostic JSON should stay out of the result.
- [ ] Discard the test capture in Review and call the tools again. It should disappear from latest and list, and a get by its old ID should fail. Repeat with Settings → Clear for another disposable capture.

## Collect evidence

In Review, choose **Show in Finder**. Normal captures live in
`~/Library/Application Support/Pilcrow/Outbox/<capture UUID>/`. Copy evidence
before the outbox prunes expired captures. Attach `strokes.json` for a recognizer
miss or `debug/voice.json` for alignment after checking what it contains.
See [reporting guidance](../CONTRIBUTING.md#report-a-recognizer-or-voice-problem).

Collect recent app logs with this command.

```sh
log show --last 15m --info --debug --predicate 'subsystem == "org.pilcrow.app"'
```

Include the macOS and Pilcrow versions, steps, expected and actual results, and
display arrangement and scales or microphone route where relevant.
