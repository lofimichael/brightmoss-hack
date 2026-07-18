# CHECKPOINT setup contract

## Consumer experience

The product setup is intentionally not a provider debugging console.

1. Open CHECKPOINT.
2. Choose `Enable Memory` after reading what remains local.
3. On `Connect services`, either connect provider credentials or choose
   `Continue in local mode`. Provider cards link directly to the relevant
   account pages. Each provider uses one paste field rather than exposing its
   underlying implementation fields.
4. Optionally enable `Public enrichment`, which sends only sanitized public
   topics and URLs—not private screen contents.
5. Grant Accessibility when Memory first starts.
6. Optionally turn on `Visual fallback`; only that explicit action may request
   Screen Recording permission. Pixels are used for one local OCR pass and are
   never saved.
7. Grant microphone access only when the microphone is first used.

Connections are one consumer-shaped onboarding step. There are no model, index,
zone, room, or port fields. The everyday surface remains one `Memory On /
Paused` status and one text-and-voice composer. Typing and the local graph remain
usable when every cloud integration is unavailable.

## Credential storage

Provider secrets are stored as generic-password items in macOS Keychain. They
must never enter UserDefaults, plist files, app caches, SQLite, logs, crash
metadata, or the checked-in repository. Existing secrets display as
`Connected`, never as their saved value. Replacing or removing a connection is
explicit.

After the app authenticates to the loopback helper, it sends current Keychain
values to a typed provider-configuration endpoint. The helper holds them only in
process memory and returns semantic capability status—not secret values. A
helper restart requires provisioning again; the app detects the helper's new
loopback token and automatically restores the Keychain snapshot before use.

| Provider | What the single paste accepts | Official account page |
| --- | --- | --- |
| Bright Data | API key | [API keys](https://brightdata.com/cp/setting/users) |
| Moss | The two-line ID/key block or Moss CLI profile JSON | [Moss portal](https://portal.usemoss.dev) |
| LiveKit | Development token-server ID, or exported URL/key/secret block | [LiveKit Cloud](https://cloud.livekit.io) |
| OpenAI | API key, optional for cloud planning | [API keys](https://platform.openai.com/api-keys) |

Moss still requires two underlying values. Its supported SDK validates both the
project ID and project key when opening a session, even when cloud index loading
is disabled. The app parses a single copied bundle and stores the values as
separate Keychain items; it never guesses an ID from a key.

A same-Mac voice turn uses native on-device speech and asks for no provider
configuration. LiveKit Cloud is an optional remote/demo path. Its frontend token
server is development-only, while a Cloud worker needs URL, API key, and API
secret. Those can be pasted as one exported block but must never be embedded in
a production client.

## What runs locally

- foreground-app and focused-window observation, including bounded same-app
  context changes;
- bounded Accessibility-tree text extraction with secure-field and
  sensitive-context exclusion;
- opt-in one-shot ScreenCaptureKit capture and local Vision OCR fallback;
- Apple Foundation Models structured subject/intent extraction when available;
- deterministic extraction fallback when the system model is unavailable;
- native Speech recognition with on-device recognition required, when the Mac
  and locale support it;
- canonical SQLite nodes, edges, evidence, retention, and deletion;
- Moss session mutations and queries after credentials are validated;
- safe native restore validation and execution.

Raw screen images are not retained, uploaded, or written to disk. Ambient
extraction never silently falls back to OpenAI or another cloud model.

## What can cross the network

- A separately consented, sanitized public topic or public HTTPS URL may go to
  Bright Data. Private intent, raw OCR, paths, messages, and account data do not.
- Audio and selected result context cross the network only when the user
  explicitly chooses LiveKit Cloud voice. The current worker uses metered
  LiveKit Inference; native voice does not use that worker.
- A request and selected retrieval context may cross OpenAI only when the user
  has explicitly connected OpenAI as the optional planner.
- Moss validates the configured project credentials when opening its local
  session. CHECKPOINT never calls `push_index()` in local-only mode.

The truthful product description is `private capture, selective cloud
enrichment`, not `air-gapped` or `nothing leaves this Mac`.

## Hackathon operator build

The checked-in `.env.example` remains an automation fallback for operators and
OSS contributors. Interactive use can enter the same values through onboarding.
For this workspace, `.env` is gitignored and mode `0600`.

The smallest useful capability matrix is:

| Capability | Operator configuration | Local-only user enters |
| --- | --- | --- |
| Local memory and typed retrieval | none | nothing |
| Apple local extraction | supported Apple Intelligence Mac | nothing |
| Bright Data enrichment | API key in Keychain or environment | nothing when skipped |
| Moss local retrieval | Project ID/Key in Keychain or environment | nothing when skipped |
| Native same-Mac voice | none; on-device availability is checked at runtime | nothing |
| LiveKit Mac client | development token-server ID | nothing when skipped |
| LiveKit Inference worker | LiveKit Cloud URL/key/secret | nothing when skipped |
| Optional OpenAI planner | API key | nothing when skipped |

Run `./scripts/check-env.sh` for a nonblocking capability report. Run
`./scripts/check-env.sh --full-demo` only when rehearsing every sponsor beat.
Neither command prints credential values.

## Public release

Do not embed Bright Data, LiveKit API secrets, Moss project keys, or OpenAI keys
in a distributable DMG. User-supplied BYOK values may remain in that user's
Keychain, but shared operator credentials need a service boundary.

A consumer release should provide:

- a zero-account local mode;
- app-issued ephemeral LiveKit participant tokens;
- a rate-limited relay for sanitized Bright Data requests;
- device/account activation for any provider credential that cannot safely ship
  in the app;
- optional BYOK only under Advanced settings, stored in Keychain, never as an
  onboarding requirement.

The provider relay must never receive ambient observations. It accepts only the
already-policy-approved public query/URL, returns untrusted cited evidence, and
does not become the canonical memory store.

## Current limitations

- Bright Data and LiveKit Cloud are network services; they cannot truthfully be
  called local inference.
- The Moss SDK currently requires project credentials even for a fresh local
  session.
- LiveKit's sandbox token source is for development. A signed release needs a
  production token endpoint.
- LiveKit Server can be self-hosted without a vendor account, but it still uses
  operator-generated API credentials and participant JWTs. LiveKit Inference is
  not included in self-hosting.
- Native on-device speech availability varies by Mac, OS version, language, and
  installed assets; CHECKPOINT fails closed instead of silently using cloud
  recognition.
- Screen Recording permission is optional. If it is denied or unavailable,
  CHECKPOINT continues with Accessibility text or app metadata.

The full evidence, including controlled zero-credential Python, Swift, and
isolated-network LiveKit tests, is in
[the provider locality audit](provider-locality-research.md).
