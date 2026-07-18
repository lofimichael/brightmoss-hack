# How to build CHECKPOINT in four hours

This plan protects one coherent demo: explicit local work-session memory that
can be retrieved by text or voice, safely reopened, and refreshed from one saved
public page.

The implementation contract is in [architecture.md](architecture.md). If the
clock and that document disagree, cut surface area before weakening the privacy
or confirmation model.

## Definition of done

A complete build performs these five beats three times in a row:

1. Start `Remembering`, switch through at least two work artifacts, preview the
   captured set, and save it locally.
2. Restart the app and helper, then retrieve that checkpoint from a fuzzy phrase.
3. Preview and reopen at least one app plus one saved file or URL.
4. Speak the same retrieval request through LiveKit and receive the same card.
5. Explicitly refresh one URL saved in the checkpoint through Bright Data,
   compare it with the saved excerpt, and retain the useful result locally.

Everything else is a cut. In particular, do not build general Spotlight search,
background crawling, arbitrary Mac control, a provider picker, or a second UI.

## Runtime split

```text
SwiftUI app
  ├─ one conversation + composer
  ├─ explicit WorkspaceRecorder
  ├─ safe native open actions
  ├─ typed turns over loopback HTTP
  └─ microphone audio over LiveKit

Local Python helper
  ├─ SQLite canonical checkpoint store
  ├─ Moss derived retrieval index
  ├─ OpenAI planning + LiveKit speech pipeline
  ├─ one Bright Data saved-URL refresh
  └─ typed proposals and cards back to Swift
```

Text does not depend on LiveKit. Voice does. Both become the same final
`UserTurn` inside the helper and call the same retrieval and action-proposal
code. Human approval is a separate local request; no LiveKit RPC waits for a
person to click.

## Intended repository shape

```text
mac/                              SwiftUI application
agent/
  checkpoint_agent/
    server.py                     loopback-only typed control
    repository.py                 SQLite source of truth
    retrieval.py                  Moss rebuild/add/query/delete
    recorder_models.py            shared capture payloads
    freshness.py                  one saved-URL Bright Data flow
    agent.py                       LiveKit voice + shared turn handler
    schemas.py                     cards, proposals, and actions
scripts/                          bootstrap, seed, package if reusable
docs/                             product and build contract
.env.example                      variable names only
```

The exact filenames may change. Preserve the responsibility boundaries.

## 0:00–0:20 — provider preflight

Stop at twenty minutes. Do not discover missing credentials after the native UI
exists.

### Required environment

```text
MOSS_PROJECT_ID
MOSS_PROJECT_KEY
LIVEKIT_URL
LIVEKIT_API_KEY
LIVEKIT_API_SECRET
LIVEKIT_SANDBOX_ID
BRIGHT_DATA_API_KEY
BRIGHT_DATA_UNLOCKER_ZONE
```

`BRIGHT_DATA_SERP_ZONE` is stretch-only and must not block P0. Check presence
without printing values. Keep every value out of Swift source, resources, logs,
screenshots, and Git.

### Prove each dependency

1. Open a Moss session, add two tiny documents, and retrieve a paraphrase without
   calling `push_index()`.
2. Join a LiveKit room from the Swift starter using `SandboxTokenSource` and the
   sandbox ID. This token path is development-only.
3. Configure the voice agent with LiveKit Inference STT → LLM → TTS and complete
   one spoken turn. Separately verify native on-device speech without Cloud
   credentials on a supported Mac.
4. Make one Bright Data Web Unlocker request for a known public documentation
   URL using the configured zone.
5. If OpenAI is connected as the optional planner, make one structured/tool-
   capable response; this must not block the sponsor demo.

The Cloud worker uses model providers through LiveKit Inference, so it does not
need separate Deepgram, Cartesia, Google, or OpenAI credentials. LiveKit
Inference still requires full LiveKit Cloud worker credentials and cannot be
described as self-hosted.

If LiveKit voice is not healthy at 0:20, continue text-first and ask an organizer
for credential help in parallel. If Moss or Bright Data is unavailable, preserve
the interfaces and use deterministic fixtures until credentials arrive.

## 0:20–0:50 — local memory core

Build the smallest durable store:

- one `checkpoint` table with `id`, searchable title/summary, timestamps, and a
  versioned JSON payload containing artifacts and the saved source excerpt;
- one `source_version` table with URL, normalized text, hash, and fetch time;
- `save_checkpoint`, `get_checkpoint`, `search_checkpoints`, and local deletion;
- an in-memory Moss `SessionIndex` rebuilt from SQLite on helper startup;
- exact/substring SQLite fallback while Moss is unavailable or rebuilding.

Do not implement the fully normalized target schema during the hack. Stable IDs
inside the JSON payload are enough to migrate later.

Seed one deterministic checkpoint named `BrightMoss auth` whose note says JWT
token generation is blocking the Mac agent. Include an app, a local file, and a
saved LiveKit documentation URL with a short excerpt.

### Gate

- Stop and restart the helper.
- Search `resume the token problem`.
- `BrightMoss auth` is top-1 and contains the blocker and artifacts.
- Disable Moss and repeat; the result is degraded honestly, not lost.

## 0:50–1:25 — native shell and typed path

Strip the Swift starter to:

- compact local-memory header;
- one scrolling message/card area;
- one multiline composer;
- microphone and send buttons;
- no sidebar, mode switch, participant UI, provider chooser, or required hotkey.

Run the helper on `127.0.0.1` with an ephemeral port and random bearer token.
Write connection data to a user-only Application Support file and reject unknown
request/action enums. P0 needs only:

```text
GET  /health
POST /turn
POST /checkpoints
POST /proposals/{id}/decision
```

Render one plain message, one checkpoint card, and one confirmation card. Use a
plain status row for progress instead of building a general renderer framework.

### Gate

- Launch reaches an editable text field without asking for permission.
- `Find the token problem` returns the checkpoint card.
- Killing LiveKit does not break typed local retrieval.
- The normal UI says `Local memory`; expanded `Run details` may name Moss and
  OpenAI for the sponsor demo.

## 1:25–2:00 — explicit capture and restore

Implement exactly one capture state machine:

```text
idle → remembering → save preview → saved
```

While the visible `Remembering` pill is active, listen to
`NSWorkspace.didActivateApplicationNotification` and record unique bundle IDs.
When Accessibility is granted, add focused window titles and document paths or
URLs. When it is denied, app names and manual notes still work. Nothing is
recorded after Save or Cancel.

The save preview lists every item with a remove control and one optional
`Next step or blocker` field.

Restore with allowlisted Swift actions only:

- activate an installed app;
- open an existing saved file;
- reveal a file in Finder;
- open an `https` saved URL.

`NSWorkspace` restore does not require Accessibility. A multi-item restore first
returns a stable proposal ID and complete confirmation card. Confirming sends a
new local decision request; Swift validates targets and executes them.

### Gate

- Start remembering, visit two apps, and save one checkpoint.
- Rich capture denial offers `Save note only`.
- Cancel on restore opens nothing.
- Confirm opens one app and one file or URL.
- A missing file is reported without blocking valid targets.

No generated AppleScript, shell command, pointer coordinates, window
positioning, or generic Accessibility clicking enters P0.

## 2:00–2:25 — one Bright Data freshness loop

Implement one tool: `refresh_saved_url(checkpoint_id, url)`.

1. Require an explicit `current`, `latest`, `changed`, or `refresh` request.
2. Require that the exact canonical URL already belongs to the checkpoint.
3. After first-use disclosure, fetch exactly that page through the configured
   Bright Data Web Unlocker zone.
4. Strip boilerplate, normalize text, and compute a body hash.
5. On first refresh, compare with the checkpoint's saved excerpt and label the
   result `Compared with saved excerpt`.
6. On later refreshes, compare with the latest `source_version`.
7. Save only the useful summary/chunks and the cited local version; update Moss.

TTL may mark a source stale and show `Refresh`, but it never initiates network
work. A normal local miss remains local. General search, SERP discovery,
multi-page crawling, and autonomous accretion are stretch work.

### Gate

- The first request shows semantic status `Used live web` and a cited URL.
- Expanded `Run details` names Bright Data for the demo.
- Repeating a normal local query reads the saved version without fetching.
- An explicit second refresh fetches and compares again.
- Provider failure returns the saved excerpt with its real checked time.

## 2:25–2:45 — LiveKit voice input

Connect the already-proven voice pipeline to the shared turn handler:

1. Tap the mic and publish audio from Swift.
2. Let end-of-speech finalize the transcript.
3. Show the final transcript as a normal user message.
4. Route its text through the same retrieval/tools used by `/turn`.
5. Return the same checkpoint card; optionally speak the short response.

Do not build editable dictation. A voice turn has no additional authority: Save,
multi-item Restore, and Delegate still produce the native confirmation card.
Spoken response interruption is polish, not a release gate.

### Gate

- Say `Resume the thing where token auth blocked me`.
- The same checkpoint card appears as with typing.
- Deny microphone access; the composer remains fully usable.

## 2:45–3:05 — dummy-simple onboarding

Implement only what removes uncertainty:

1. One promise screen: `Your Mac can remember your work` → `Enable Memory`.
2. One `Connect services` step with collapsed Bright Data, Moss, LiveKit, and
   optional OpenAI cards, official links, Keychain storage, and `Continue in
   local mode`.
3. Ask for microphone only on first mic tap.
4. Ask for Accessibility only when Memory first starts.
5. Ask separately before automatic public enrichment.
6. Put provider names and timings under `Run details`; keep daily labels semantic.

Typing must work before any permission or provider connection. Keys are never
shown after save and never enter app cache, UserDefaults, plist, logs, or
SQLite. The authenticated loopback helper receives them from Keychain and holds
them only in memory. `.env` remains an automation fallback, not the product UX.

### Five-minute stranger test

Without explanation, someone can:

- find the composer;
- explain that capture runs only while Memory On is visible;
- enable and pause Memory;
- connect one provider or continue locally without confusion;
- retrieve the seeded checkpoint;
- distinguish local memory from a live-web refresh.

## 3:05–3:25 — integration and safety

- Add `.env`, SQLite files, Moss caches, helper connection state, and content
  logs to `.gitignore`.
- Add `.env.example` with names and placeholders only.
- Remove keys, selected text, prompts, raw audio, and interim transcripts from
  default logs.
- Treat OpenAI output as an untrusted proposal and Bright Data output as quoted
  evidence, never instructions.
- Permit only known action enums, existing saved paths, installed bundle IDs,
  and `https` URLs.
- Confirm local delete removes the canonical row and rebuilds the derived Moss
  index; describe it as best-effort local deletion, not forensic erasure.

### Fallback matrix

| Failure | Required behavior |
| --- | --- |
| Microphone, STT, or LiveKit | Typed local path remains usable |
| Accessibility | App-name capture, manual note, and normal restore remain |
| Moss | Exact/substring SQLite search with honest status |
| OpenAI | Preserve input; deterministic retrieve/open still works |
| Bright Data | Saved excerpt with honest last-checked time |
| Missing restore target | Open valid targets and report the missing item |
| Python helper | Preserve typed draft and offer `Restart helper` |

## 3:25–3:45 — rehearse and record

Run the full five-beat demo three times from the same seed. Record a 30–45 second
backup after the third clean run. Keep a single-page operator note containing:

- helper launch command;
- app launch command;
- expected seeded phrase;
- provider health checks;
- reset-to-seed command;
- fallback narration if one network provider fails.

Freeze features at 3:45. Fix only demo-breaking failures.

## 3:45–4:00 — submit first; package only if already solved

Save the project in the HackerSquad Builder Portal, attach the backup video, and
verify the project is submitted before release engineering. The official
brief's order is join the event, create and accept the team, fill project
details, save, create the video, and submit.

Then reuse Matcha's signing and DMG machinery only if it works with minimal
edits. A working submitted demo beats a broken installer.

Target assets:

```text
v0.1.0-hackathon
CHECKPOINT.dmg
CHECKPOINT.dmg.sha256
30–45 second backup demo
```

Verify the DMG, signature, and absence of `.env`, databases, caches, and logs.
State plainly that the hack DMG requires the separately launched local Python
helper. If submission is complete and packaging crosses the remaining time,
ship source and an app archive.

## Final acceptance checklist

### Surface and capture

- [ ] A useful text field appears without permission or setup.
- [ ] The main window has no sidebar, modes, slash commands, or provider picker.
- [ ] A visible pill bounds all workspace recording.
- [ ] The save preview can remove an accidentally captured item.

### Local memory and restore

- [ ] A checkpoint survives app and helper restart.
- [ ] A fuzzy paraphrase returns it top-1 through Moss.
- [ ] SQLite fallback works without pretending it is semantic search.
- [ ] Cancel changes nothing; Confirm opens the exact reviewed plan.

### Voice and web

- [ ] Keyboard and LiveKit microphone produce the same result card.
- [ ] Voice failure does not affect typed local retrieval.
- [ ] Bright Data fetches exactly one approved saved URL.
- [ ] The comparison cites the URL, baseline, and checked time.

### Truth and safety

- [ ] `Run details` visibly demonstrates Moss, LiveKit, OpenAI, and Bright Data.
- [ ] No shared key appears in Git, the bundle, UI, logs, or release assets.
- [ ] Model output cannot invoke an unknown native action.
- [ ] Web content cannot become a tool instruction.
- [ ] The demo says local-first, never air-gapped or universal Mac control.

## Cut order

If behind, cut in this order:

1. DMG/notarization work;
2. spoken assistant output and barge-in;
3. Ollama autodetection;
4. normalized database tables and polished progress cards;
5. multi-match retrieval and settings UI.

Never cut typed input, explicit capture, restart-safe retrieval, restore preview,
one LiveKit voice turn, or one Bright Data saved-page comparison. Those five
beats are the story.
