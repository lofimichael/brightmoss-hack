# Ambient memory decision

## Recommendation

Build toward ambient memory, but do **not** build a miniature screen recorder.
The differentiated product is an automatic **work-state compiler**:

> **CHECKPOINT remembers the work, not the recording.**

While a visible `Memory on` control is enabled, CHECKPOINT should observe
meaningful foreground-app changes, extract structured text locally, group the
observations into task episodes, and discard transient images. The result is a
small set of searchable, restorable work capsules instead of a replayable
archive of a person's screen.

For the hackathon, keep the completed explicit checkpoint path as the reliable
substrate. Add ambient capture only after capture, retrieval, and restore work
three times in a row. The first ambient slice should use Accessibility text and
app/document metadata; screenshot OCR is an optional fallback after that slice
is stable.

## Why this is not “Screenpipe, but better”

Screenpipe is already a mature capture platform. Its current product uses
event-driven screen capture, Accessibility trees, conditional OCR, local
transcription, PII filters, encryption options, SQLite/FTS5, and agent APIs. It
reports more than 20,000 GitHub stars and joined Y Combinator's Summer 2026
batch. Rebuilding its capture engine in a few hours would create a weaker clone
with less trustworthy privacy controls.

The useful difference is the retained artifact and the job it performs:

| Product model | Retained artifact | Primary job |
| --- | --- | --- |
| Screen recorder / Screenpipe | frames, audio, transcripts, searchable events | Recall anything and supply broad agent context |
| CHECKPOINT | lossy task episode with evidence and restorable artifacts | Recover a train of thought and resume the work |

CHECKPOINT can be better for *task resumption* without claiming to be better at
general life recall, meetings, surveillance, or capture infrastructure.

The pitch is therefore:

> Screenpipe is a DVR for work. CHECKPOINT compiles work into save points.

## Product contract

### What “passive” means

Passive means the user does not manually add every app, page, or note. It does
not mean hidden or unconsented collection.

1. The user opts in once with a plain explanation.
2. A persistent menu-bar indicator says `Memory on` whenever observation is
   active.
3. Pause, `Pause for one hour`, and `Erase last 15 minutes` are always one click
   away.
4. No microphone, keyboard-event payloads, clipboard contents, browser history,
   or filesystem crawl enters ambient capture.
5. Cloud providers are not called from the capture pipeline.

### What it remembers

Each changed state may contribute:

- timestamp and idle duration;
- app name and bundle identifier;
- focused window title;
- active document path or public URL when the app exposes it;
- bounded text from the focused Accessibility tree;
- conditional OCR text when Accessibility is missing and visual fallback is on;
- a content hash for deduplication;
- the inferred task episode and its working set.

It should not promise “everything.” Visual-only content, protected media,
private app state, and apps with poor Accessibility support can be absent. That
honesty is part of the privacy model.

## Native capture architecture

```text
NSWorkspace app/window event ───────────────┐
AX focused-window snapshot ─────────────────┼─> sensitivity gate
idle / meaningful-change timer ─────────────┤      │
optional one-shot ScreenCaptureKit image ───┘      ▼
                                             extract locally
                                      AX text or Vision OCR
                                                   │
                                      release transient image
                                                   ▼
                                        redact + hash + dedupe
                                                   ▼
                                      local observation journal
                                                   ▼
                                          episode compiler
                                                   ▼
                                  SQLite canonical + Moss index
                                                   │
                           text composer or explicit LiveKit voice
                                                   ▼
                                     retrieve → cite → restore
                                                   │
                             explicit saved-URL freshness request
                                                   ▼
                                             Bright Data
```

### Capture order

1. Listen for `NSWorkspace.didActivateApplicationNotification` and bounded
   Accessibility notifications. Do not record keystrokes.
2. After a short debounce, inspect only the focused app/window. Walk the
   Accessibility tree with a node, character, and time budget. Skip secure text
   fields.
3. If the structured text is missing or thin, and the user enabled visual
   fallback, take a one-shot image of the frontmost window with
   ScreenCaptureKit and recognize text with Vision.
4. Run the exclusion and redaction policy before persistence.
5. Hash normalized content and skip repeats.
6. Do not intentionally write the image to application storage. Release its
   buffers after extraction. Phrase this as “raw screenshots are not retained,”
   not as a forensic guarantee about RAM, swap, crash dumps, or OS internals.

Accessibility-first capture has three advantages for P0: better text quality,
lower storage, and no need for Screen Recording permission. OCR remains valuable
for terminals, canvases, remote desktops, and apps whose Accessibility trees are
thin.

### Observation schema

```text
observation
  id
  captured_at
  app_bundle_id
  window_title
  document_resource       # path or public URL, optional
  extracted_text
  content_hash
  sensitivity_flags
  episode_id
  extraction_method       # metadata | accessibility | ocr
```

P0 can store this as versioned JSON beside the current checkpoint table. A
production build should normalize it and encrypt sensitive text fields with a
Keychain-held key.

### Episode compiler

An episode is the stable object users search and restore. Use deterministic
rules before adding a model:

- start a boundary after five minutes of idle time;
- start a boundary when the project/document fingerprint changes materially;
- merge nearby observations that share a project path, URL host, or strong title
  tokens;
- deduplicate repeated app/window states by hash;
- keep the first and latest useful evidence for each artifact;
- derive a title from the dominant project/document and app;
- derive the working set from unique apps, documents, and URLs.

For a stage demo, a shorter demo-only idle threshold is acceptable if disclosed.
Do not fabricate a blocker or next step. Only show one when the captured text or
user note supports it.

## High-retrieval design

“Local” alone does not make retrieval good. Search should combine four signals:

1. SQLite FTS/exact matches for filenames, error text, app names, URLs, and
   titles;
2. Moss semantic search over compact episode documents;
3. structured filters for time, app, project, and source type;
4. continuity and recency boosts at the episode level.

Index one compact document per episode plus a bounded number of evidence chunks.
Do not embed every near-identical frame. A result should cite its local evidence:

```text
LiveKit authentication
11:18–11:42 · Xcode, Terminal, Safari
“invalid JWT issuer” · TokenService.swift · docs.livekit.io
```

Useful queries then become self-evident:

- “What was I doing before lunch?”
- “Where did I see the invalid JWT issuer error?”
- “Resume the task where auth was blocking the Mac agent.”
- “Is the token guidance I used still current?”

The last query first retrieves the local episode, then explicitly refreshes its
already-saved public URL through Bright Data.

## Automatic knowledge accretion

The strongest version of CHECKPOINT goes beyond episode recall: it grows a
personal context graph from the subjects the user demonstrates interest in. The
privacy boundary must split private context from public enrichment.

```text
PRIVATE, LOCAL                                      PUBLIC NETWORK BOUNDARY

screen state                                        sanitized public subject
    ↓                                                       ↓
AX / local OCR                                     deterministic policy gate
    ↓                                                       ↓
on-device subject + intent extraction              Bright Data SERP / Unlocker
    ↓                                                       ↓
private episode graph  ←──── cited public claims + provenance
    ↓
Moss retrieval documents
```

A structured model response is not automatically anonymous. `Michael is
researching layoffs at Acme` is structured and still sensitive. The on-device
model therefore emits two distinct objects:

1. a full `Observation` that never leaves the Mac; and
2. a minimal `PublicEnrichmentCandidate` that must pass deterministic policy.

Example:

```json
{
  "privateObservation": {
    "likelyIntent": "debug token validation in private-project-x",
    "subjects": ["LiveKit", "JWT issuer"],
    "evidence": ["invalid JWT issuer", "TokenService.swift"]
  },
  "publicCandidate": {
    "entityType": "developer_technology",
    "canonicalName": "LiveKit access-token validation",
    "query": "site:docs.livekit.io access token issuer validation Swift"
  }
}
```

Bright Data receives only the public candidate. It never receives the private
project, path, raw screen text, person identity, or full inferred intent.

### Network policy gate

Do not trust the local model to certify its own output. A deterministic gateway
allows automatic enrichment only when all checks pass:

- the user separately enabled `Public enrichment` once;
- the entity type is allowlisted, initially technology, company, product,
  public documentation, or academic topic;
- the query has no email, local path, private hostname/IP, URL credentials,
  API-key shape, JWT, account identifier, personal name, or project codename;
- the query is short and contains only the canonical public subject plus generic
  research terms;
- the destination is a public HTTPS URL;
- the query hash has not been enriched within its TTL;
- the hourly request and byte budget is available.

The user can inspect the exact outbound query in `Run details`. A failed policy
check keeps the subject local without asking the user to service a queue of
prompts.

### Accretion budget

Automatic does not mean unlimited crawling. At episode close, enrich at most one
high-confidence public subject, fetch at most two sources, and prefer official
documentation. Deeper query expansion happens when the user asks a related
question. Cache by canonical subject and source hash, attach a TTL, and perform
work only while the public-enrichment status is visibly enabled.

Every imported statement is a `Claim` with a source URL, retrieved time, quoted
evidence span, content hash, and extraction confidence. Web claims never replace
locally observed evidence and never become tool instructions.

### Graph and Moss responsibilities

Moss is the semantic front door, not a graph database. Keep canonical nodes,
edges, evidence, and provenance in SQLite; serialize compact node and episode
neighborhoods into Moss documents for local hybrid retrieval.

```text
node(id, kind, canonical_key, label, properties, sensitivity)
edge(id, from_id, to_id, kind, confidence, provenance_id, observed_at)
evidence(id, source_kind, source_ref, excerpt, hash, captured_at)
enrichment_job(id, public_query, policy_result, status, checked_at)
```

Useful node kinds are `Episode`, `Intent`, `Entity`, `Artifact`, `Claim`, and
`WebSource`. Useful edges include `OBSERVED_IN`, `USED`, `ABOUT`, `SUPPORTS`,
`CONTRADICTS`, and `SUPERSEDES`.

The retrieval flow is:

1. locally parse the text or voice transcript into semantic terms, time/app
   filters, and a freshness need;
2. let Moss find the best node/episode candidates;
3. expand one or two hops in SQLite;
4. rerank using semantic score, exact evidence, edge confidence, and recency;
5. answer from a compact provenance-bearing graph packet;
6. perform another sanitized Bright Data query only when fresh public context is
   required and policy permits it.

This is accurately described as **Moss-powered graph retrieval**, not as a Moss
graph database.

### Local model choice

On supported Apple Intelligence Macs, Apple's Foundation Models framework is a
strong native default: it supports on-device language understanding and guided
generation into Swift structures. Define an extractor protocol and use
`SystemLanguageModel` only after checking availability. An Ollama-compatible
local extractor is the OSS fallback. Do not silently fall back to a cloud model
for ambient extraction.

## Provider boundaries

Each sponsor gets one legible job; none belongs in passive ingestion.

| Component | Allowed job | Never receives by default |
| --- | --- | --- |
| Native macOS | foreground observation, AX extraction, optional OCR, restore | n/a |
| SQLite | canonical local observations and episodes | provider credentials |
| Moss | local semantic index and fuzzy episode retrieval | a cloud-synced corpus |
| LiveKit | explicit voice query and spoken response | ambient room audio |
| OpenAI BYOK | optional query-time planning over selected snippets | continuous captures or the whole database |
| Bright Data | policy-gated enrichment of a sanitized public subject and explicit refresh | private intent, arbitrary browsing history, or screen contents |

Captured web text is evidence, never an instruction. A model can propose only
the existing typed, allowlisted actions; Swift still validates and confirms the
exact plan.

## Privacy and trust model

### Required controls

- One explicit opt-in and an always-visible recording/logging indicator.
- Default exclusions for password managers, Keychain/Passwords, authentication
  windows, and any app the user adds.
- A bounded capture tree that ignores secure text fields.
- Redaction before storage, not merely at query time. Regex redaction is useful
  but must not be marketed as complete PII or secret detection.
- No raw screenshot archive by default; optional user-pinned images are a
  separate, explicit feature.
- No passive audio, clipboard, keyboard payload, or background web crawling.
- A retention choice, local delete, `Erase last 15 minutes`, and a visible count
  of stored episodes.
- Network disclosures at query time and a local-only mode that still searches.
- A mode-`0700` data directory, mode-`0600` files, and encryption at rest before
  a broad public release.

### Threats that “local-first” does not solve

| Threat | Reality and mitigation |
| --- | --- |
| Sensitive text in SQLite | Plain local files are readable by the logged-in user and same-user malware. Encrypt fields/database and use FileVault; neither is a complete runtime defense. |
| Notifications and overlays | Sensitive content can appear over an allowed app. Prefer AX, filter known system overlays, redact, and do not retain pixels. |
| Browser private mode | Window-title heuristics are not a security boundary. Skip browser capture when a trustworthy URL/state cannot be established; offer browser/app exclusions. |
| Prompt injection | Screen text is untrusted quoted evidence. It never changes system instructions or tool authority. |
| Deletion | APFS snapshots, Time Machine, logs, and crash reports can retain copies. Promise application-level deletion, not forensic erasure. |
| Other people on screen | Messages and meetings can contain data from non-users. Exclude passive audio and meeting capture; provide pause and clear notice. |
| Cloud query leakage | Only selected snippets should cross the boundary after a visible disclosure. OpenAI API settings such as `store=false` do not turn a cloud call into local inference. |

Until encryption, redaction, retention, and exclusions are implemented and
tested, say “capture stays on-device in this demo” and “raw screenshots are not
retained.” Do not claim the product is categorically more private than a mature
competitor.

## Dummy-simple onboarding and daily UI

The user-facing surface remains two controls and one conversation.

### First launch

```text
Your Mac can remember what you were working on.

CHECKPOINT stores extracted work context on this Mac.
Raw screenshots are not kept. Pause or erase anytime.

[ Turn on memory ]   [ Not now ]
```

Only after `Turn on memory` should the app ask for Accessibility. Ask for Screen
Recording later, only if the user enables visual fallback. Ask for the microphone
only on first mic tap.

### Menu bar

```text
● Memory on
Pause for one hour
Erase last 15 minutes
Open CHECKPOINT…
```

The dot and `Memory on` label remain visible while logging activity. The main
window contains the same ChatGPT-like text/mic composer already specified. No
capture timeline, provider picker, rule builder, or hotkey tutorial is required.

## Hackathon scope

### Safe first extension: 45–75 minutes

1. Add a visible `Memory on` toggle around the existing workspace recorder.
2. Capture app activations and bounded AX window text after a debounce.
3. Hash and deduplicate observations locally.
4. Auto-save one episode after a short idle boundary or explicit `Compile now`.
5. Retrieve and restore through the already-built checkpoint path.
6. Show `0 screenshots retained · 0 cloud capture calls` in Run details.

This is enough to prove automatic ingestion without betting the demo on Screen
Recording permission.

### Sponsor-native graph slice: another 45–75 minutes

- use the on-device model to produce one typed subject/intent object per episode;
- persist a tiny set of nodes/edges/evidence in SQLite;
- index one flattened graph neighborhood in Moss;
- policy-check one generated public query;
- use Bright Data to fetch one or two cited public sources;
- attach those claims to the local subject and make them voice-retrievable.

If a Bright Data SERP zone is unavailable, enrich only an exact public URL that
the episode already observed. Do not route general search through a Web Unlocker
zone and pretend it is the same product capability.

### Stretch: another 60–90 minutes

- frontmost-window `SCScreenshotManager` capture;
- local Vision OCR when AX content is thin;
- in-memory image lifecycle and capture exclusions;
- automatic episode title and evidence snippet quality;
- `Erase last 15 minutes`.

### Kill list for today

- continuous video or frame storage;
- passive microphone/system-audio capture;
- keyboard or clipboard contents;
- full browser-history, filesystem, mail, or Obsidian ingestion;
- multi-day production retention and sync;
- universal private-window or secret-detection claims;
- arbitrary clicking, AppleScript generation, or shell execution;
- unbounded or policy-free Bright Data crawling;
- a second timeline-heavy UI;
- copying Screenpipe code under its current source-available commercial license.

## Ninety-second demo

1. Turn on `Memory on`; point out `screenshots retained: 0`.
2. Visit a LiveKit authentication page, `TokenService.swift`, and a Terminal
   window containing `invalid JWT issuer`.
3. Switch to unrelated work. CHECKPOINT automatically compiles one episode.
4. Type or say, “What was blocking the Mac agent?”
5. Show the episode, exact local evidence, apps/file/URL, and Moss local status.
6. Say, “Resume it.” Review one native confirmation and reopen the working set.
7. Ask, “Is that token guidance still current?” Bright Data refreshes the saved
   public page and returns a cited comparison.
8. Close with: “It remembers the work, not a recording of my life.”

## Decision gate

Do not replace the explicit checkpoint flow before the event. Ship the ambient
extension only when all of these are true:

- explicit capture/retrieve/restore passes three consecutive rehearsals;
- ambient mode has a conspicuous on/off indicator;
- turning it off stops observations immediately;
- at least one real AX-only episode can be found from captured text;
- no passive cloud call occurs;
- deleting the episode removes it from both SQLite search and the Moss index.

If any gate fails, demo explicit CHECKPOINT and describe ambient compilation as
the next step. That is a coherent product, while a flaky privacy demo is not.

## Primary references

- [Screenpipe on Y Combinator](https://www.ycombinator.com/companies/screenpipe)
- [Screenpipe security architecture](https://screenpipe.com/security/architecture)
- [Screenpipe source and current license description](https://github.com/screenpipe/screenpipe)
- [Screenpipe June 2026 license change](https://screenpipe.com/blog/screenpipe-v2-19-new-open-source-license-changelog)
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/recognizetextrequest)
- [Apple Accessibility element API](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [Apple App Review Guideline 2.5.14](https://developer.apple.com/app-store/review/guidelines/)
