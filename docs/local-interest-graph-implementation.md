# Local Interest Graph: implementation contract

Status: P0 implementation plan for the hackathon build

## Product promise

CHECKPOINT quietly turns normal Mac activity into a private, searchable interest graph. It reads bounded visible context locally, infers subjects and intent locally, stores the private graph on the Mac, and lets the user ask for a memory by text or voice. When the user explicitly enables public enrichment, CHECKPOINT may send one sanitized public subject query to Bright Data and attach the returned public sources to that private subject. Raw screen content, window titles, file paths, private intent, and pixels never cross that boundary.

The interaction surface stays small:

1. Toggle **Memory**.
2. Optionally toggle **Visual fallback** after reading the one-sentence privacy explanation.
3. Type or talk in the existing composer.
4. Open **Memories** to inspect or delete what CHECKPOINT retained.

## Data flow and privacy boundary

```text
foreground app/window event
        |
        v
sensitive-context policy --------------------------> skip with local reason
        |
        v
bounded Accessibility text
        |
        +-- too thin + explicit visual opt-in --> one-shot front-window capture
                                                --> local Vision OCR
                                                --> discard pixels immediately
        |
        v
local structured extraction
  intent + subjects(kind, keywords, confidence)
        |
        v
authenticated loopback helper
  SQLite observations + private graph + Moss index
        |
        +--------------------> local text/voice retrieval
        |
        v
server consent + privacy + novelty + hourly-budget gate
        |
        v
one generic public query --> Bright Data --> <= 2 public sources
        |
        v
SUPPORTED_BY edges on the private subject
```

### Pixel boundary

- Screen capture is off by default and is never needed when Accessibility provides enough text.
- Enabling it is a deliberate user action and is the only action that may prompt for Screen Recording permission.
- Only the focused/frontmost window is captured, at a bounded resolution, for one OCR pass.
- No image path, encoded image, thumbnail, video, or pixel buffer is written to disk or sent over the network.
- The retained result is bounded OCR text, a content hash, structured subjects, intent, and provenance describing the local extraction method.

### Sensitive-context policy

Capture must fail closed for CHECKPOINT itself, password managers, authentication utilities, banking/payment contexts, private/incognito browser windows, and private messaging apps. Accessibility traversal must omit secure text fields and values from password-like elements. Policy decisions are pure and unit-tested so adding a block rule does not require screen access.

## Local observation contract

`POST /observations` accepts the existing observation fields plus:

```json
{
  "extracted_text": "bounded local text",
  "extraction_method": "accessibility|ocr|metadata",
  "subjects": [
    {
      "canonical_name": "ScreenCaptureKit",
      "kind": "technology",
      "keywords": ["macOS screen capture", "SCStream"],
      "confidence": 0.92
    }
  ],
  "allow_public_enrichment": false
}
```

Every subject is stored in the private graph. Enrichment is a separate privilege, not an implication of capture.

## Consumer memory API

- `GET /memory/items?limit=<1...100>&before=<ISO-8601>` returns a newest-first timeline and total count.
- `GET /memory/subjects?limit=<1...100>` returns subject aggregates with kind, bounded keywords, occurrence count, first/last seen, related apps, and attached source count.
- `GET /memory/stats` returns counts needed by the main window and menu bar.
- `GET /memory/enrichments?limit=<1...100>&before=<ISO-8601>&before_id=<job-id>`
  returns the complete Expanded Knowledge ledger. Each row contains the exact
  sanitized query, subject, status/policy, result sources, and display-safe
  origin metadata. A compound timestamp/ID cursor prevents tied timestamps from
  disappearing between pages.
- `DELETE /memory/items/{observation_id}` removes the observation and its evidence/edges, prunes orphan graph nodes, removes an empty ambient checkpoint, and refreshes the local Moss documents.

Memory responses expose display-safe document labels rather than unnecessary full local paths. A memory item contains local provenance plus any public sources, enrichment status, and the exact outbound query.

Rejected or failed attempts remain visible in Expanded Knowledge so “nothing
was added” is distinguishable from a missing record. Rejected values are
redacted as `[rejected]`; private rejected input is never echoed back or stored.

## Bright Data expansion policy

An observation may schedule at most one candidate. A candidate must:

- come from a locally extracted subject with adequate confidence;
- use an allowlisted public kind: technology, product, company, public documentation, or academic topic;
- be novel outside the 24-hour subject/query cache;
- fit within a rolling six-job-per-hour budget;
- pass server validation for paths, emails, IP addresses, credentials, private hosts, raw URLs, and subject/query mismatch;
- omit extracted text, titles, paths, intent, and unrelated private keywords.

Queries use deterministic kind-specific templates. Examples:

- technology: `<subject> official documentation latest`
- product: `<subject> official product information latest`
- company: `<subject> official company information latest`
- academic topic: `<subject> recent academic research overview`
- public documentation: `<subject> official documentation latest`

The helper remains authoritative: both passive observations and chat-triggered refreshes must honor `allow_public_enrichment`. The UI toggle cannot be bypassed by phrasing a request as “latest” or “refresh.”

## Failure behavior

| Failure | Stored result | User experience |
|---|---|---|
| Accessibility not granted | app metadata only | Memory continues; onboarding explains richer local context permission |
| Sensitive context detected | nothing | capture silently skips; status can explain the local reason |
| Screen Recording denied | AX/metadata only | visual fallback shows unavailable and a Settings link |
| OCR/model unavailable | deterministic metadata extraction | memory continues with lower-detail provenance |
| Helper temporarily unavailable | bounded in-process retry | typed draft is restored; memory status shows not ready |
| Moss unavailable | SQLite literal retrieval | local memories remain usable |
| Bright Data missing/offline | private graph only | local capture/retrieval continues; source status is visible |
| Bright Data budget/cache hit | no network request | item records cached/rate-limited status without blocking memory |
| Delete partially fails | transaction rolls back | item remains and UI offers retry |

## Test coverage map

```text
CAPTURE
  sensitive app/window -------- block [unit]
  AX secure element ----------- omit [unit]
  AX bounds/depth ------------- truncate [unit]
  same-app unchanged ---------- dedupe [unit]
  AX rich --------------------- no screenshot [unit]
  AX thin + visual off -------- metadata [unit]
  AX thin + visual on --------- mocked capture/OCR; pixels not retained [unit]
  permission denied ----------- recoverable state [unit]

LOCAL GRAPH
  observation ---------------- persist typed subjects/keywords [integration]
  list/paginate -------------- stable newest-first DTO [integration]
  aggregate ------------------ counts/dates/apps/sources [integration]
  delete --------------------- transaction + orphan cleanup + index refresh [integration]
  restart -------------------- remembered count from SQLite [integration]

PUBLIC ENRICHMENT
  consent off ---------------- zero provider calls [regression, critical]
  unsafe kind/value ---------- reject [unit]
  safe subject --------------- exact deterministic query [unit]
  24h duplicate -------------- cache [integration]
  seventh hourly job --------- rate limited [integration]
  provider error ------------- private memory preserved [integration]
  successful result ---------- <=2 sources + provenance edges [integration]

USER FLOWS
  enable Memory -------------- immediate local observation [model test]
  enable visual fallback ----- permission only on explicit action [model test]
  open Memories -------------- loading/empty/error/data states [model test]
  delete memory -------------- confirmation, optimistic guard, refresh [model test]
  type/talk retrieval -------- local-first answer and source chips [existing + regression]
```

An actual capture of the developer's current desktop is not part of automated QA. Screen APIs are verified by compile-time integration and injected synthetic/mock frames; a human can complete the final permission smoke test in a controlled window.

## Explicitly not in P0

- Continuous video/audio recording or screenshot archives.
- Obsidian/full-disk ingestion.
- Autonomous mouse/keyboard control of arbitrary apps.
- SQLite encryption or multi-device sync.
- A graph-canvas visualization.
- Automated DMG notarization and GitHub Release publishing.

These do not block the hackathon promise: passive private memory, local retrieval, voice/text interaction, and opt-in public knowledge expansion.
