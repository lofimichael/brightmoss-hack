# CHECKPOINT

**Git stash for your brain.**

CHECKPOINT is a local-first macOS assistant that saves an explicit or ambient
work session, finds it later from a vague description, and reopens the relevant
apps, files, and pages. With separate consent, it can enrich one safe public
subject through Bright Data and add the cited result back to local memory.

The product direction extends that reliable substrate into an ambient,
self-building context graph: while `Memory On` is visibly enabled, the Mac
extracts compact structured work context locally, retains meaning and provenance
instead of footage, and selectively enriches only policy-approved public topics.

The interface is deliberately small: one conversation, one text-and-voice
composer, and confirmation cards only when an action needs approval. Users do
not learn commands, modes, or mandatory hotkeys.

> “Checkpoint this.” Later: “Resume the LiveKit auth thing.”

## Status

The P0 is a native SwiftUI client plus an authenticated loopback-only Python
helper: bounded local screen-context extraction, a browsable SQLite memory
ledger and interest graph, optional local Moss retrieval, policy-gated Bright
Data query expansion, native on-device speech, an optional LiveKit Inference
voice worker, and strict native restore validation. Capture, typed retrieval,
and restore work with no provider account; every cloud capability is optional.

## Consumer setup

Open the app, enable Memory, and optionally connect providers through one
Keychain-backed onboarding step. Accessibility supplies bounded visible text;
an explicitly enabled visual fallback can use one in-memory screenshot for
local OCR when Accessibility is thin. Local-only users can skip every provider;
operator/BYOK users get simple provider cards and official account links instead
of editing an environment file.

See [the setup contract](docs/setup.md) for the precise local/network boundary
and the separate operator configuration used for the hackathon build.

## Run the operator build

Requirements: macOS 14+, Swift 6, Python 3.12, `uv`, `jq`, and provider
credentials for the full sponsor demo.

```bash
# Only contributors/operators create .env; consumers do not.
cp .env.example .env
./scripts/check-env.sh

# Judge-facing one-command launch: helper + real enrichment seed + native app.
./scripts/run-demo.sh

# Normal consumer/development launch (no demo data is added).
# ./scripts/run-mac.sh

# Optional, in another terminal: LiveKit Cloud voice worker
./scripts/run-voice.sh
```

`run-mac.sh` reuses a healthy local helper or starts one, waits until its
authenticated loopback endpoint is ready, and only then opens CHECKPOINT. If it
started the helper, quitting the app stops that helper too. The connection
descriptor stays mode-`0600`; custom `CHECKPOINT_DATA_DIR` launches are passed to
the Swift client without exposing the connection token in command arguments.

## Product contract

- **One surface:** a compact native SwiftUI conversation window.
- **One input:** type or tap the microphone; both enter the same request path.
- **One mental model:** ask, remember, resume, or delegate in plain language.
- **Opt-in ambient memory:** CHECKPOINT observes chosen work apps only while the
  persistent `Memory On` indicator is visible; explicit checkpoints remain a
  manual pin and fallback.
- **Inspectable memory:** one Memories sheet lists retained moments, evolving
  subjects, extraction provenance, exact outbound public queries, and deletion.
- **Ephemeral visual fallback:** optional one-shot window pixels exist only for
  local OCR and are discarded; screenshots are never archived or transmitted.
- **Previewed actions:** local reads run immediately; writes and multi-step work
  receive one clear confirmation.
- **Local source of truth:** checkpoint records live on the Mac. Moss is the
  fast semantic index, and cloud sync is disabled for the local-only mode.

## Ninety-second demo

For the shortest fire-and-forget version, run `./scripts/run-demo.sh`, open
**Memories → Expanded Knowledge**, then ask by voice: “What was I researching
about realtime voice frameworks?” The seed uses the production observation API
and real configured providers; it does not inject a fabricated web result.

1. Turn on Memory and visit Xcode, Terminal, and a LiveKit documentation page.
2. CHECKPOINT extracts subjects and evidence locally, discards transient pixels,
   and automatically compiles a `BrightMoss auth` episode.
3. Its policy gate sends only the public subject to Bright Data and attaches
   cited public context to the local graph.
4. Close the working set without pressing Save.
5. Type or say: “Resume the thing where token auth was blocking me.”
6. Moss finds the local episode; CHECKPOINT summarizes the blocker and previews the
   apps, file, and URLs it will restore.
7. Confirm once and reopen them.
8. Ask: “Does LiveKit's current token guidance still match the excerpt I saved?”
9. Bright Data refreshes the official page, CHECKPOINT shows a cited comparison,
   and the useful update joins the local checkpoint.

## Provider roles

| Provider | Job in the product |
| --- | --- |
| Moss | Active local session memory and semantic checkpoint retrieval |
| LiveKit | Optional realtime voice transport, turn handling, interruption, and RPC |
| Bright Data | One sanitized public-subject query, at most two cited sources, and explicit saved-page refresh |
| OpenAI | Optional cloud intent planner and answer model |
| Ollama | Optional local, OpenAI-compatible reasoning provider |
| Swift/macOS | Context capture, local speech, permissions, UI, and allowlisted native actions |

This maps directly to the official event brief: a conversational agent using
Bright Data web infrastructure, Moss memory, and LiveKit voice. SQLite is a
local durability journal because the current Python Moss API does not expose a
public disk-persistence contract; the active searchable corpus still lives in
the Moss session during use.

## Documentation

- [Product specification](docs/product-spec.md): promise, scope, principles,
  non-goals, and demo success criteria.
- [Interaction design](docs/interaction-design.md): onboarding, the unified
  text-and-voice composer, flows, cards, confirmations, and exact copy.
- [Architecture](docs/architecture.md): components, command flow, local
  persistence, data model, provider boundaries, privacy, and action safety.
- [Four-hour build plan](docs/build-plan.md): implementation order, acceptance
  tests, fallbacks, demo rehearsal, and release checklist.
- [Event brief alignment](docs/event-brief.md): verified sponsor requirements,
  demo callouts, promo code, and HackerSquad submission steps.
- [Ambient memory decision](docs/ambient-memory-decision.md): the differentiated
  state-compiler architecture, privacy model, scoped implementation, and demo.
- [Local Interest Graph implementation](docs/local-interest-graph-implementation.md):
  capture boundary, memory APIs, query policy, failure behavior, and test map.
- [Consumer setup contract](docs/setup.md): zero-key onboarding, local/network
  boundaries, operator-only credentials, and the public-release path.
- [Provider locality audit](docs/provider-locality-research.md): credential
  boundaries, self-hosting verdicts, controlled tests, and primary sources.
- [Organizer reference audit](docs/kol-copilot-reference-audit.md): reusable
  KOL-Copilot patterns, credential cross-checks, and privacy caveats.

## Guardrails

CHECKPOINT does not promise continuous desktop surveillance or universal GUI
automation. The hackathon build supports opening apps, files, and URLs and
revealing files. Destructive or externally consequential operations are out of
scope.

“Local-first” describes the zero-account canonical memory, typed retrieval, and
native voice path. Optional Moss still authenticates at session creation, and
cloud model or voice providers receive only the data needed for the current
request. The UI must show when live web or a remote model is in use.
