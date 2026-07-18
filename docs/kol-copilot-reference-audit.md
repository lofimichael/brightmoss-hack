# Organizer KOL-Copilot reference audit

Reference inspected: [`itsajchan/KOL-Copilot`](https://github.com/itsajchan/KOL-Copilot)
at commit
[`970453c`](https://github.com/itsajchan/KOL-Copilot/commit/970453c7186fb385bf9277d888ccce91fb19f743).

## What it confirms

The organizer example corroborates CHECKPOINT's provider audit:

- its setup requires both `MOSS_PROJECT_ID` and `MOSS_PROJECT_KEY`;
- its LiveKit setup starts with `lk app env`, which writes a Cloud URL, API key,
  and API secret into both the worker and frontend;
- its STT, LLM, and TTS defaults use LiveKit Inference, not local models;
- its Bright Data direct-API path requires a token plus SERP and Unlocker zone
  names.

Relevant source:

- [root setup and prerequisites](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/README.md)
- [agent environment template](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/agent-py/.env.example)
- [LiveKit/Moss voice agent](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/agent-py/src/agent.py)

The example therefore is not a credential-free Moss or LiveKit Inference path.
It is a Cloud-backed sponsor integration with deterministic fallbacks.
It pins `moss==1.4.0`, so its call shapes are useful reference code but do not
supersede CHECKPOINT's controlled tests against Moss `1.7.1`.

## Patterns worth adopting

### Typed retrieval documents

Its Moss indexer converts each result into narrowly typed documents with stable
IDs and metadata such as asset type, object type, source URL, run ID, and
protocol ID. CHECKPOINT should keep the same discipline for episodes, entities,
intent, evidence, and enrichment provenance while retaining SQLite as the
canonical private graph.

- [structured Moss document builder](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/agent-py/src/kol_copilot/moss_indexer.py)

### Reliable structured LiveKit events

The voice worker publishes a short spoken answer and sends a separate reliable
data-channel event for evidence cards. This is an excellent demo pattern:
speech stays brief while the app can visibly show `Moss retrieved`, citations,
latency, and provider use. CHECKPOINT must apply its privacy boundary before
publishing: no local paths, raw screen text, or arbitrary artifact resources.

- [Moss context and result events](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/agent-py/src/agent.py)
- [frontend event consumer](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/frontend/hooks/useMossContextEvents.ts)

### Short-lived endpoint tokens

The frontend's server route keeps the LiveKit API secret server-side, mints a
15-minute participant JWT, grants only room join/publish/data/subscribe, and
attaches agent-dispatch metadata. This should replace CHECKPOINT's development
token-server ID before a public release. In CHECKPOINT, the equivalent endpoint
belongs on the authenticated loopback helper or an operator relay; the Mac app
should receive only connection details and a short-lived token.

- [LiveKit token endpoint](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/frontend/app/api/token/route.ts)
- [endpoint-versus-Sandbox client selection](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/frontend/components/app/app.tsx)

### Deterministic degraded mode

Its research runner returns typed deterministic demo data when OpenAI is absent
or the nested agent fails. That matches CHECKPOINT's rule that optional
providers add capability but never disable local retrieval.

- [fallback runner](https://github.com/itsajchan/KOL-Copilot/blob/970453c7186fb385bf9277d888ccce91fb19f743/agent-py/src/kol_copilot/runner.py)

### Fast retrieval, slow enrichment

Its default voice fast path bypasses the nested research agent and returns a
retrieval result quickly, while costly Bright Data/OpenAI research runs in the
dashboard pipeline. This is almost exactly CHECKPOINT's desired cadence:
immediate local recall first, then an optional background enrichment job whose
cited result joins the graph later.

## Patterns not to transplant unchanged

- **Cloud Moss indexes as source of truth.** The example calls
  `create_index`, `add_docs`, and `load_index` on named indexes. That is suited
  to public KOL evidence, not ambient private Mac state. CHECKPOINT keeps a
  fresh process session as an optional accelerator and SQLite as durability.
- **Raw durable user facts in a shared index.** The example scopes recall with
  a metadata filter but does not provide CHECKPOINT's retention/erase contract.
  Local ambient memory needs deletion at the canonical graph and derived-index
  layers.
- **Unauthenticated development token route.** The reference route explicitly
  throws outside development because it lacks application authentication.
  CHECKPOINT's loopback endpoint must require its random bearer token.
- **Verbose web request/error logging.** The Bright Data adapter logs queries
  and URLs and can include provider error bodies. CHECKPOINT should retain its
  sanitized errors, outbound policy gate, result cap, and private-field denylist.
- **Three-field Bright Data setup.** Direct SERP/Unlocker APIs need zone names;
  CHECKPOINT's hosted MCP route needs only `BRIGHT_DATA_API_KEY`, which is the
  better consumer default.
- **Cloud model claims.** “No provider API key required” in the worker means the
  model vendors are billed through LiveKit Inference; it does not mean local or
  account-free inference.
- **Full retrieval payloads over a Cloud room.** CHECKPOINT should send a
  compact, disclosure-safe card payload rather than raw Moss match text and
  metadata.

## Decision for CHECKPOINT

Use the reference repo for typed evidence envelopes, reliable LiveKit UI events,
short-lived token issuance, and deterministic fallback structure. Do not adopt
its Cloud Moss persistence model or developer-oriented environment surface.

For the hackathon, the existing LiveKit token-server ID remains the smallest
working Cloud frontend setup. For the public DMG, implement the endpoint-token
pattern so a user never receives or enters a LiveKit API secret. Same-Mac native
voice remains the zero-key default.
