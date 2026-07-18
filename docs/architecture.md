# CHECKPOINT architecture

## System goal

CHECKPOINT presents one native conversation while separating four concerns:

1. macOS context and actions remain in the signed Swift application;
2. durable checkpoint data remains in a local canonical store;
3. Moss accelerates fuzzy retrieval without becoming the source of truth;
4. network providers receive only the minimum data required for the current
   voice, reasoning, or freshness request.

The architecture optimizes for a working four-hour demo and leaves a credible
path to an open-source DMG. It does not pretend the first DMG contains every
runtime dependency.

## Runtime overview

```text
┌────────────────────────── macOS app ──────────────────────────┐
│ SwiftUI conversation                                         │
│   ├─ text composer + LiveKit Swift voice participant          │
│   ├─ structured result and confirmation cards                 │
│   └─ visible local/network/provider state                     │
│                                                               │
│ WorkspaceRecorder    PermissionCoordinator   SafeActionExecutor│
│   AX/NSWorkspace          Mic/Accessibility     Open/activate  │
└───────────────────────────┬───────────────────────────────────┘
              ┌─────────────┴─────────────────────┐
              │ local loopback control            │ LiveKit voice/RPC
┌───────────────────────────▼───────────────────────────────────┐
│ Local Python agent                                            │
│   ├─ LiveKit AgentSession                                     │
│   ├─ RequestOrchestrator + typed tools                         │
│   ├─ CheckpointRepository (SQLite, canonical)                  │
│   ├─ Moss SessionIndex (active local memory, rebuildable)      │
│   ├─ BrightDataClient (explicit saved-URL refresh)             │
│   └─ ModelRouter (OpenAI default, Ollama optional)             │
└───────────────┬───────────────────────┬───────────────────────┘
                │                       │
        local filesystem          network providers
        SQLite + Moss cache       LiveKit / OpenAI / Bright Data
```

For the hackathon, run the Python process separately with the official agent
tooling. Do not spend contest time bundling a Python runtime. A later release can
manage the helper with an XPC service or signed bundled executable.

## Responsibilities

### Swift macOS application

The native app owns everything that requires user trust or macOS permission:

- render the unified text-and-voice conversation;
- connect as the user participant in a LiveKit room;
- send typed requests over the local control transport;
- collect app/document changes only while a visible checkpoint is remembering;
- capture current context only after an explicit capture, `this`, or `current`
  request;
- request microphone and Accessibility permissions progressively;
- show result, progress, and confirmation cards;
- validate and execute allowlisted app/file/URL actions;
- store a user-supplied OpenAI key in Keychain in the public BYOK flow;
- disclose when remote voice, model, or web providers are active.

The Python process must not access macOS Accessibility directly. Otherwise the
judge grants permission to Terminal or Python rather than the signed DMG, and the
released app cannot inherit that trust.

#### Explicit workspace recorder

Multi-item capture uses one state machine:

```text
idle → remembering → save preview → saved
```

Only while `remembering` is visibly active, Swift listens to
`NSWorkspace.didActivateApplicationNotification`. It records each unique bundle
identifier and snapshots the focused window and `kAXDocumentAttribute` when
Accessibility exposes them. A user can say `add this` to force another snapshot
inside the same app. The save preview allows removing any captured item.

No app activation is persisted outside that state. When Accessibility is denied,
the recorder still knows frontmost application names through `NSWorkspace` and
accepts a manual note, but it cannot promise window titles, selected text, or
document URLs.

### Local Python agent

The agent owns orchestration and data:

- normalize typed and transcribed input into one `UserTurn`;
- query exact local records and Moss before calling a reasoning model;
- expose typed tools for capture, retrieval, refresh, and restore proposals;
- stream short answers and structured card payloads;
- call Bright Data only under the freshness policy;
- persist final transcripts, checkpoints, artifacts, and sources;
- rebuild the Moss index from SQLite at startup;
- never call Moss `push_index()` in local-only mode.

### Local control transport

Typed requests, checkpoint CRUD, card payloads, confirmations, and helper health
use a loopback-only local transport. This keeps text and local search available
when cloud voice is unavailable and avoids using a short LiveKit RPC as a
human-approval channel.

The hack implementation may use HTTP bound to `127.0.0.1` with a random bearer
token. The helper writes its ephemeral port and token to a user-only file under
Application Support; Swift reads it and deletes stale connection files. A later
release can replace this with XPC or a Unix-domain socket.

The transport exposes no arbitrary command endpoint. Requests and responses use
the same typed schemas as cards and tools.

### LiveKit

Native macOS speech is the zero-key, same-Mac voice layer. Recognition is
requested only after the user taps the microphone and requires on-device
recognition; unsupported locales or missing assets produce an honest
unavailable state rather than a silent cloud fallback.

LiveKit is the optional realtime session layer:

- Swift publishes microphone audio;
- the agent publishes transcripts and spoken output;
- barge-in may interrupt spoken output when enabled;
- compact RPC calls may request current context during a voice turn or execute
  an action that has already been approved locally.

Voice and text produce the same final text turn inside the orchestrator and use
the same tools. A voice request has no extra authority. Normal LiveKit voice
finalizes the turn at end-of-speech; it does not promise editable dictation before
submission.

The hackathon worker uses LiveKit Inference for STT, LLM, and TTS. This requires
LiveKit Cloud URL/key/secret but no separate model-provider credential. It is a
metered Cloud path, not local inference. LiveKit Server and Agents can instead
run entirely self-hosted with operator-generated credentials, but a fully local
deployment must separately supply local STT, LLM, and TTS implementations.

### Moss

Moss holds the active local searchable memory and provides fast hybrid and
semantic retrieval over it. `SessionIndex` mutations and queries run in-process.
Cloud persistence is optional and disabled for this product mode.

SQLite is the local durability journal, not a competing retrieval engine. The
app can reconstruct the complete Moss session from that journal after an SDK
upgrade, cache failure, or process restart. This avoids depending on Python's
current non-public session-cache implementation while keeping the active corpus
stored and queried in Moss during use.

Opening a Moss session still requires credentials and can involve service
validation or telemetry. The product claim is “indexed content stays local
unless sync is enabled,” not “air-gapped.”

### Bright Data

Bright Data is an explicit freshness service, not an autonomous crawler. P0 runs
it only when:

- the user explicitly asks for current, latest, changed, or refreshed data;
- the target is a URL already saved in the selected checkpoint;
- first-use live-web disclosure has been accepted.

TTL never starts a request; it only marks a saved copy stale and offers
`Refresh`. The P0 client fetches one saved page, strips boilerplate, hashes
normalized content, and saves only useful chunks. SERP-based discovery and
general research are stretch work.
Scraped content is untrusted data and never becomes an instruction or action.

### OpenAI and Ollama

OpenAI is the default hackathon reasoning provider because an API key is
available. Configure the model through `OPENAI_MODEL`; use a fast, tool-capable
model such as `gpt-5.4-mini` for the demo instead of hard-coding model behavior in
the UI. The agent sends only the current request, compact current context, and
top-ranked local snippets.

Ollama implements the same planner interface through its OpenAI-compatible local
endpoint. The provider is selected in setup or Settings, never per message.

The model is an untrusted planner. It cannot execute native actions, write files,
or generate shell commands.

## Unified request flow

```text
Typed text -> local control ──────┐
                                 ├─> final text -> UserTurn
Microphone -> LiveKit -> STT ─────┘
                                          │
                    context only for an explicit capture/current intent
                                          │
                                 exact SQLite lookup
                                          │
                                  Moss fuzzy lookup
                                          │
                              explicit refresh requested?
                              │ no                 │ yes
                              │                    ▼
                              │          Bright Data fetch/diff
                              │                    │
                              └──────────┬─────────┘
                                         ▼
                             minimal context to planner
                                         │
                          message, card, or typed action plan
                                         │
                         Swift validates / previews / executes
```

### Request steps

1. Swift sends typed input over local control. Voice travels as LiveKit audio and
   becomes a final transcript.
2. Ordinary questions carry no desktop snapshot.
3. For a capture or explicit current-context intent, the orchestrator requests a
   `ContextSnapshot`; Swift shows every item in the save or action preview.
4. The agent persists the final user turn locally.
5. The repository performs exact title, URL, path, and text matching.
6. Moss retrieves fuzzy checkpoint and knowledge matches.
7. The freshness policy decides whether Bright Data is allowed or required.
8. The planner receives only the best snippets plus source metadata.
9. The agent returns one of four renderable outcomes over local control. A voice
   answer may also be spoken through LiveKit.
10. Any native action becomes a typed proposal. Swift rejects unknown actions,
    previews the plan when needed, executes it, and returns a structured result.

## Render protocol

Every assistant turn emits one primary outcome:

```text
message
result_card
confirmation_card
progress_card
```

Suggested envelope:

```json
{
  "requestId": "uuid",
  "kind": "result_card",
  "message": "I found the checkpoint where token auth blocked you.",
  "checkpoint": {
    "id": "uuid",
    "title": "BrightMoss auth",
    "summary": "JWT generation was blocking the Mac agent.",
    "nextStep": "Implement the token endpoint."
  },
  "sources": [],
  "proposedActions": [],
  "providerDisclosure": ["Moss · local"]
}
```

This is an illustrative transport contract, not a committed language-level type.
The implementation should define matching Swift and Python schemas and reject
unknown enum values. A confirmation card carries a stable proposal ID and returns
immediately. Approval or cancellation is a separate local-control request; no RPC
blocks while waiting for a person.

## Safe action model

The v0 action registry is closed:

```text
getCurrentContext
openURL
openFile
revealInFinder
activateApp
restoreCheckpoint
findTextInFrontmostApp     # stretch, known accessible apps only
```

### Execution rules

- Swift resolves every target and owns every macOS call.
- One explicitly named, read-only open action may run immediately.
- A multi-item restore receives one confirmation containing the complete list.
- A path must exist and be a saved artifact or exact user-selected target.
- A URL must use `https` or be a known local file URL.
- An application target resolves to an installed bundle identifier.
- Cap a confirmed plan at three steps.
- Reject shell, generated AppleScript, arbitrary keyboard/mouse coordinates,
  destructive actions, purchases, form submission, and external messaging.

App-specific AppleScript, Shortcuts, or Accessibility adapters can be added later
as reviewed action implementations. They do not expand model authority.

## Local data model

The Python agent is the single SQLite writer. Swift reads data through local
control, avoiding cross-process locking and duplicate business logic.

The normalized tables below are the target architecture. To fit the hack clock,
v0 may begin with one `checkpoint` table containing a versioned JSON payload and
one `source_version` table, then migrate after the demo. Recommended location:

```text
~/Library/Application Support/Checkpoint/checkpoint.sqlite
```

Recommended adjacent state:

```text
~/Library/Application Support/Checkpoint/
├── checkpoint.sqlite
├── moss-session-cache/       # optional accelerator, never canonical
└── logs/                     # sanitized; no keys, prompts, or content by default
```

### `checkpoint`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID string | Stable primary key |
| `title` | text | User title or short generated title |
| `summary` | text | Short retrieval and resume summary |
| `next_step` | text nullable | The blocker or next action |
| `status` | enum | `active`, `saved`, or `deleted` |
| `created_at` | ISO-8601 | Local record creation |
| `saved_at` | ISO-8601 nullable | Final capture time |

### `artifact`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID string | Stable primary key |
| `checkpoint_id` | UUID string | Owning checkpoint |
| `kind` | enum | `app`, `file`, `url`, `selection`, `note` |
| `display_name` | text | User-facing title |
| `bundle_id` | text nullable | Application identifier |
| `resource` | text nullable | File path or canonical URL |
| `captured_text` | text nullable | Explicit selection or note |
| `content_hash` | text nullable | Deduplication hash |
| `captured_at` | ISO-8601 | Capture time |

### `source`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID string | Stable primary key |
| `checkpoint_id` | UUID string nullable | Optional checkpoint owner |
| `canonical_url` | text | Deduplication key |
| `title` | text | Source title |
| `body_hash` | text | Normalized content hash |
| `fetched_at` | ISO-8601 | Bright Data fetch time |
| `expires_at` | ISO-8601 | Freshness deadline |
| `provider` | text | `bright_data` |

### `source_version`

Fetched versions provide an honest comparison baseline:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID string | Stable primary key |
| `source_id` | UUID string | Parent source |
| `fetched_at` | ISO-8601 | Fetch time |
| `body_hash` | text | Normalized content hash |
| `normalized_text` | text | Local comparison baseline |
| `is_current` | boolean | Current version marker |

### `chunk`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | text | Stable Moss document ID |
| `owner_type` | enum | `checkpoint`, `artifact`, or `source_version` |
| `owner_id` | UUID string | Parent record |
| `ordinal` | integer | Chunk order |
| `text` | text | Searchable content |
| `content_hash` | text | Rebuild and dedupe key |

### `message`

Store only messages explicitly attached to a checkpoint. Ordinary conversation
is runtime-only and clears on restart. Never store raw audio or interim speech
recognition:

- message ID and local conversation ID;
- role;
- modality: `typed`, `voice`, or `system`;
- final text;
- timestamp;
- related checkpoint ID when applicable.

## Moss indexing

Use stable document IDs:

```text
checkpoint:<checkpoint-id>:summary:<hash>
artifact:<artifact-id>:chunk:<ordinal>:<hash>
source-version:<source-version-id>:chunk:<ordinal>:<hash>
```

Startup sequence:

1. Open and migrate SQLite.
2. Open an empty Moss session using the configured project credentials.
3. Read all non-deleted chunks from SQLite.
4. Add them in batches to `SessionIndex`.
5. Mark local search ready.

During rebuild, literal SQLite search remains available and the UI says:

> Local search is rebuilding. Your checkpoints are safe.

Deletion removes SQLite rows and corresponding session documents. `push_index()`
is never called in local-only mode.

`Delete all local memory` closes the database and session, removes the Moss cache
and SQLite WAL/SHM files, recreates an empty database, and rebuilds an empty
session. Deleting one checkpoint removes its rows, versions, chunks, and live
session documents; a later maintenance pass may `VACUUM` SQLite. Describe this as
best-effort local deletion, not forensic secure erasure.

## Bright Data accretion policy

### P0 fetch limits

- exactly one saved URL per refresh request;
- no autonomous schedule, cache-miss expansion, SERP search, or broad crawl;
- normalize URLs before deduplication;
- strip navigation, ads, scripts, and repeated boilerplate;
- reject non-text downloads unless the request explicitly supports them.

### Suggested TTLs

| Source | TTL |
| --- | --- |
| Pricing, status, or availability | 1 day |
| Product and API documentation | 7 days |
| General reference article | 30 days |
| Local file | Until modification time changes |
| User note or decision | Never stale automatically |

TTL is display metadata only; it never authorizes a network request. If no prior
full-page version exists, compare the fresh page with the excerpt stored in the
checkpoint and label the result `Compared with saved excerpt`. Otherwise compare
the two latest `source_version` records. If the body hash is unchanged, update
freshness metadata without duplicating chunks. If changed, add a new version,
mark it current, and retain the previous version for the cited comparison.

## Network and privacy boundaries

| Component | Receives | Does not receive by default |
| --- | --- | --- |
| SQLite | Full local checkpoint records | API keys and raw audio |
| Moss SessionIndex | Searchable checkpoint/source chunks | Cloud push in local-only mode |
| Native speech | Microphone audio stays in the on-device recognizer | Provider network traffic |
| LiveKit Cloud/Inference | Explicit voice audio, selected context, transcripts, realtime metadata | Ambient observations and entire checkpoint database |
| OpenAI, when connected | Current request and top retrieved snippets | Unretrieved local corpus |
| Bright Data | One approved URL saved in the selected checkpoint | Local files and unrelated checkpoints |
| Ollama | Current request and retrieved snippets locally | Network traffic from the model call |

Remote provider use must appear in the UI. Recommended header and card labels:

```text
Checkpoints stored on this Mac
Used cloud voice
Used cloud AI
Used live web
```

Provider names and timing live under an expandable `Run details` footer. A demo
mode may expand it to show `Moss`, `LiveKit`, and `Bright Data` by name, plus
`OpenAI` only when it was actually selected.

OpenAI API requests should disable optional response storage when the chosen API
path supports it. This does not justify a zero-retention claim; the product must
link to the provider's current data controls.

## Credentials

### Hackathon build

The local agent loads ignored environment variables for operator automation:

```text
MOSS_PROJECT_ID
MOSS_PROJECT_KEY
LIVEKIT_URL
LIVEKIT_API_KEY
LIVEKIT_API_SECRET
LIVEKIT_SANDBOX_ID
BRIGHT_DATA_API_KEY
BRIGHT_DATA_UNLOCKER_ZONE
# BRIGHT_DATA_SERP_ZONE is stretch-only
OPENAI_API_KEY
OPENAI_MODEL
```

No secret value appears in Swift source, application resources, logs,
screenshots, or the Git repository. The consumer UI accepts one secure paste
per optional provider and stores parsed values in Keychain. Moss still has two
underlying credentials. The hack Swift app can use LiveKit's development-only
token server with the sandbox ID; the worker's LiveKit API secret remains
operator-side.

### Public developer preview

- Store every user-supplied secret in Keychain.
- Give the local helper configured values in process memory over its
  authenticated loopback channel, never as command-line arguments.
- Keep zero-provider SQLite/FTS retrieval and native voice fully usable.
- Accept a single copied bundle for Moss (ID + key) or LiveKit Cloud
  (URL + key + secret) instead of presenting protocol fields individually.
- Mint frontend LiveKit tokens through a production endpoint or a local trusted
  helper that uses the developer's own LiveKit project.
- Never ship the LiveKit API secret, shared Bright Data key, or Moss project key
  inside the DMG.
- Never claim a raw Moss key is sufficient: the supported SDK requires its
  separate project ID at session creation.
- Place advanced operator connections outside the daily interaction surface once
  a working connection profile exists.

## Failure and fallback ladder

| Failure | Fallback |
| --- | --- |
| Microphone denied or STT unavailable | Keep the text composer fully functional |
| Accessibility denied | Save manual notes; restore saved apps/files/URLs normally |
| Moss unavailable or rebuilding | Exact/substring SQLite search |
| OpenAI unavailable | Preserve request; permit deterministic local open/search |
| Bright Data unavailable | Return cached source with honest last-checked time |
| LiveKit room, STT, or TTS unavailable | Text and local search continue over loopback control |
| One restore item missing | Open remaining items and identify the missing artifact |
| Local Python helper disconnected | Offer `Restart helper` and retain typed text |

## Deployment shapes

### Hackathon

```text
Native signed app + separately launched local Python agent + LiveKit Cloud
```

This is the lowest-risk shape and keeps Moss and optional Ollama on the Mac.
Use App Sandbox off, Hardened Runtime on, Developer ID signing, and notarization.
`NSWorkspace` path restoration is therefore viable for the hack. A future
sandboxed/Mac App Store build must store security-scoped bookmarks instead of
assuming raw paths remain accessible.

### Open-source v0.1 developer preview

```text
Native DMG + source for mac/ and agent/ + one bootstrap command
```

The README must state that the DMG is the native client and the local agent is a
separate requirement.

## Open questions to resolve with Moss

- Confirm that hackathon credentials enable `SessionIndex`.
- Confirm the service plan under which open-source developer-preview users may
  open local sessions; the current pricing page lists Sessions separately from
  unlimited local queries.
- Confirm a supported Python or macOS disk-persistence path. CHECKPOINT does not
  depend on private cache APIs because it rebuilds from SQLite.

### Later standalone release

Bundle and sign a managed helper, replace unstable local-cache dependencies with
public persistence APIs, provide a production LiveKit token endpoint, and add a
local speech adapter. These are release engineering tasks, not demo blockers.

## Primary references

- [Moss sessions](https://docs.moss.dev/docs/integrate/sessions)
- [Moss Picklight example](https://github.com/usemoss/moss/tree/main/examples/moss-pikachu)
- [LiveKit Swift starter](https://github.com/livekit-examples/agent-starter-swift)
- [LiveKit text input](https://docs.livekit.io/agents/multimodality/text/)
- [LiveKit frontend RPC](https://docs.livekit.io/agents/logic/tools/forwarding/)
- [Bright Data LiveKit integration](https://brightdata.com/blog/ai/voice-agents-with-livekit-and-bright-data)
- [OpenAI API quickstart](https://platform.openai.com/docs/quickstart/make-your-first-api-request)
- [OpenAI data controls](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint)
- [Apple `NSWorkspace`](https://developer.apple.com/documentation/appkit/nsworkspace)
- [Apple `AXUIElement`](https://developer.apple.com/documentation/applicationservices/axuielement_h)
