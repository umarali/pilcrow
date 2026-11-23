# Roadmap

Pilcrow is **redline review, not recording** (D-16): mark up a live app with numbered red marks while you talk, approve exactly what is sent, and hand the agent a fix list.

## Wave 1 — foundation (in progress)
- App: no overlay until Screen Recording is granted; permissions window; click-through overlay, hold ⇧ to draw; session-scoped Esc and ⌘Z; new screenshot after you interact with the app underneath (D-17).
- Packaging: signed `Pilcrow.app` with a stable identity (D-17.2).
- Core: per-mark fix list (each `[n]` with its crop and words), Core API cleanups from [backlog-m2.md](backlog-m2.md), legible-image limits (D-17.5).

## Wave 2 — the review loop, first half
- Wire the App to Core.
- Approval preview: the exact words, crops and destination; nothing is sent until you approve.
- Direct delivery: Codex CLI (`-i` images), Claude Code (image paths), a `pilcrow` command and an agent skill; MCP later.
- Speech: on-device SpeechAnalyzer with word timing (D-17.6), `[n]` placement from Core's aligner.

## Not planned
- Screen video recording, keyframe selection and auto-crop: [Scrawl](https://github.com/kitlangton/scrawl) does these well.
- Verifying fixes (re-capturing each marked region and ticking off `[n]`): the agent does this with its own tools. Pilcrow's job ends when the agent has the marks and words (D-34).
