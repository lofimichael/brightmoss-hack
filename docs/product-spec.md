# CHECKPOINT product specification

## Product in one sentence

CHECKPOINT lets someone save the context of an active work session, retrieve it
later by describing what they remember, and reopen the exact working set.

## Positioning

> **Git stash for your brain.**

> **Spotlight finds files. CHECKPOINT restores your train of thought.**

The product is not a generic local file search and not a universal Siri
replacement. Spotlight, Raycast, Alfred, and Moss's own Picklight example already
cover file retrieval. Apple Voice Control and dictation products already cover
literal voice commands. CHECKPOINT owns the layer between them: explicit,
deletable episodic memory that explains *why* several artifacts belonged together
and safely restores them.

## The problem

People rarely lose the file itself. They lose the surrounding state:

- which apps and pages were open;
- why those artifacts mattered together;
- the decision, blocker, or next step they were holding in working memory;
- whether a saved external fact is still current.

Traditional search returns isolated items. Continuous desktop-memory products
capture too much and create a trust problem. CHECKPOINT records only an explicit
session and turns it into a retrievable, restorable unit.

## The promise

A user should understand the complete product without a tutorial:

1. Open CHECKPOINT.
2. Type or say what they want.
3. Inspect one result or one action preview.
4. Confirm only when CHECKPOINT will save, restore, delegate, or write.

The user never needs to know which provider, tool, index, or intent handled the
request.

## The four invisible capabilities

These capabilities exist in the system but are not presented as modes or tabs.

### Capture

Example requests:

- “Checkpoint this.”
- “Save where I am.”
- “Remember this as BrightMoss auth.”

CHECKPOINT gathers the active app, window title, document path or URL when
available, selected text when explicitly included, and an optional note or next
step. It previews the record before saving it.

### Retrieve

Example requests:

- “Find the thing where LiveKit auth blocked me.”
- “What was I doing yesterday afternoon?”
- “What did I learn about Moss sessions?”

CHECKPOINT returns the single strongest match. It offers at most two additional
matches when confidence is ambiguous. It does not dump a ranked search page.

### Resume

Example requests:

- “Resume BrightMoss auth.”
- “Open the work from yesterday about local speech.”

CHECKPOINT summarizes the checkpoint and previews the apps, files, and URLs it
can reopen. One approval covers that exact restore plan.

### Delegate

Example requests:

- “Check whether LiveKit’s token guidance changed.”
- “Compare this with the current docs and save what matters.”
- “Research this and add the useful part to BrightMoss auth.”

Delegation is a bounded tool plan inside the same conversation, not a separate
agent workspace. The hackathon build allows no more than three tool steps and no
unattended background task.

## Product principles

### One surface

There is one compact conversation window. No sidebar, command palette, session
tree, tool browser, agent selector, or separate voice screen appears in v0.

### One request path

Keyboard input and final LiveKit voice transcripts both become the same
`UserTurn` before retrieval or planning. Typed text is editable before send.
Conversational voice submits when the speaker finishes; the final transcript
appears in the same timeline. Neither input method receives extra action
authority.

### Progressive disclosure

The product asks for microphone access only when the user taps the microphone,
Accessibility access only when the user first enables Memory, and public-web
consent only when enrichment is enabled. One optional `Connect services` step
stores BYOK/operator credentials in Keychain and can be skipped for local mode.

### Visible opt-in ambient capture

CHECKPOINT observes bounded foreground work state only after the user enables
Memory. It does not retain continuous video, microphone, clipboard, keyboard, or
browser-history streams. A persistent status pill appears for the entire period
in which work state is observed. Explicit checkpoints remain available as a
manual pin and privacy-friendly fallback.

### Minimum necessary context

Raw screenshots are never retained by default. Accessibility/OCR text becomes a
bounded local observation; Apple Foundation Models produces typed subjects and
likely intent locally when available. Bright Data receives only a separately
sanitized public subject or URL. Remote voice receives only the explicit turn
and the minimum selected result context, never the graph or checkpoint database.

### One confirmation

A confirmation card describes the complete bounded plan. CHECKPOINT does not
stack repeated permission prompts. If the plan changes, it asks again.

### Useful failure

Text input always remains available. If voice, local search, live web, or the
model fails, the app explains what still works and preserves the user's request.

## v0 scope

### Must ship

- Native SwiftUI menu-bar/Dock app with one compact conversation window.
- Text composer with send and multiline editing.
- LiveKit conversational voice whose final transcript appears in the same
  timeline and reaches the same tools as typed text.
- Visible `Memory On / Paused` observation with app/window metadata,
  Accessibility-first text, deterministic episode boundaries, and explicit
  checkpoint pinning as a fallback.
- Apple Foundation Models typed subject extraction with a deterministic local
  fallback and no silent cloud extraction.
- Local SQLite graph/evidence persistence with a rebuildable Moss semantic index.
- Natural-language retrieval with one best result.
- Restore preview and native opening of applications, files, and URLs.
- Policy-gated Bright Data enrichment of one public subject/URL, with sources,
  provenance, and change summary.
- A consumer-shaped provider connection step backed by macOS Keychain, with
  official links and `Continue in local mode`.
- Apple's local model as the default ambient planner; cloud models are optional.
- Clear semantic status such as `Local memory`, `Used cloud AI`, and `Used live
  web`, with provider names available under `Run details`.

### Nice to have

- Local Ollama provider detected automatically.
- LiveKit spoken response and barge-in.
- `findTextInFrontmostApp` for a known, accessible app.
- Two likely checkpoint matches when retrieval confidence is close.
- A local WhisperKit transcription adapter.

### Explicitly out of scope

- Continuous pixel/video, microphone, clipboard, keyboard, browser-history, or
  filesystem recording.
- Whole-disk semantic indexing.
- Arbitrary clicking, pixel-coordinate control, or generated shell commands.
- Sending messages, submitting forms, purchases, deletion of external resources,
  or account changes. Deleting CHECKPOINT's own local records remains supported.
- Restoring exact window size and position.
- More than one active capture session.
- Accounts, team sync, mobile companion, browser extension, and cloud history.
- A provider marketplace or per-request model selector.
- Fully self-contained bundling of Python, LiveKit Server, Ollama, and model
  weights inside the first DMG.

## Success criteria

The build succeeds when a first-time judge can complete the following without
verbal instruction:

1. Launch the app and understand its purpose within five seconds.
2. Type a checkpoint request without learning syntax.
3. Save a checkpoint after one preview.
4. Retrieve it from a fuzzy phrase in under one perceived second after submit,
   excluding remote model latency.
5. Preview and restore at least one app, one file, and one URL.
6. Enter the same resume request by voice and see the final transcript in the
   same timeline.
7. Ask whether a saved public page changed and receive a cited Bright Data result.
8. See which content stayed local and which network provider ran.
9. Cancel any proposed action before it changes external state.

## Demo truthfulness

The demo may say:

- “Checkpoint content is stored locally.”
- “Moss embeds and queries the session in-process.”
- “Cloud sync is disabled; we do not call `push_index()`.”
- “Bright Data runs only for live-web requests and the retrieved copy joins the
  local checkpoint.”
- “OpenAI is the configured reasoning provider; Ollama is supported as a local
  alternative.”

The demo must not say:

- “The app is air-gapped.”
- “Nothing ever leaves this Mac.”
- “CHECKPOINT controls every Mac application.”
- “The DMG contains a completely local voice and model stack.”

## Primary references

- [Moss sessions](https://docs.moss.dev/docs/integrate/sessions)
- [Moss Picklight macOS example](https://github.com/usemoss/moss/tree/main/examples/moss-pikachu)
- [LiveKit Agents](https://docs.livekit.io/agents/)
- [Bright Data and LiveKit integration](https://brightdata.com/blog/ai/voice-agents-with-livekit-and-bright-data)
- [OpenAI developer quickstart](https://platform.openai.com/docs/quickstart/make-your-first-api-request)
- [Apple Accessibility action API](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)
