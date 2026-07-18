# Provider locality and credential audit

Date verified: 2026-07-18

This note answers three different questions that are often collapsed into the
word **local**:

1. Does the product require an account with the vendor?
2. Can it operate with no external network at runtime?
3. Does the person using the Mac have to type or paste credentials?

Those are independent properties. A query can execute on-device while the SDK
still requires a vendor token to create the local runtime. A self-hosted server
can require JWTs while needing no vendor account at all.

## Executive verdict

| Path | No vendor account | No external runtime network | No user-entered credentials |
| --- | ---: | ---: | ---: |
| SQLite/FTS canonical CHECKPOINT memory | Yes | Yes | Yes |
| Moss supported Python or Swift session | **No** | **No at cold session open** | Only if the app/operator provisions Moss credentials |
| Moss add/query after an authenticated session is open | No | Yes for the operation itself | Yes after provisioning |
| Self-hosted LiveKit + local speech/models | **Yes** | **Yes** | **Yes**; app can mint its own internal credentials |
| Self-hosted LiveKit + LiveKit Inference | No | No | No, unless an operator backend absorbs the Cloud account |
| LiveKit Cloud + LiveKit Inference | No | No | Only if an operator backend provisions it |
| LiveKit Cloud token server / former Sandbox | No | No | One non-secret token-server ID in the frontend, plus Cloud credentials for the worker |

The correct product statement is:

> CHECKPOINT's canonical memory and ambient understanding work locally with no
> account. Moss accelerates semantic retrieval locally after a credentialed
> session is opened. LiveKit can be genuinely self-hosted, but LiveKit
> Inference is a Cloud service.

## Moss

### What is genuinely local

Moss's documentation says that an opened `SessionIndex` is an in-process index.
`add_docs`, `delete_docs`, `get_docs`, and `query` operate in memory; built-in
embedding also runs in the native runtime. There is no per-operation cloud
round trip. Pushing a session to Moss Cloud is optional.

The Swift SDK adds local disk persistence through `save(toCachePath:)` and
`loadFromDisk(cachePath:)`. Its `autoLoadOnInit: false` option skips the
creation-time cloud *index load*. This is useful and meaningfully local, but it
does not remove the SDK's authentication boundary.

Official references:

- [Moss authentication](https://docs.moss.dev/docs/integrate/authentication)
- [Python sessions](https://docs.moss.dev/docs/reference/python/sessions)
- [Real-time local indexing](https://docs.moss.dev/docs/build/real-time-local-indexing)
- [Swift `MossClient`](https://docs.moss.dev/docs/reference/swift/classes/MossClient)
- [Swift `MossSession`](https://docs.moss.dev/docs/reference/swift/classes/MossSession)
- [Moss repository architecture](https://github.com/usemoss/moss#architecture)

### Why credentials are still required

The public authentication guide requires both `MOSS_PROJECT_ID` and
`MOSS_PROJECT_KEY` and explicitly says project credentials are validated when
a session is opened. The Python session guide repeats that invalid credentials
make `session()` raise.

This is a control-plane/data-plane split:

```text
Moss control plane                            Moss local data plane

project ID + project key                      documents and vectors in process
        |                                                |
        +-- authenticate / authorize model --------------+
                                                         |
                                           add / delete / query locally
```

The repository's own architecture section is equally explicit: Moss Cloud
stores and distributes indexes, while the embedded runtime pulls an index and
then serves queries locally. “No network hop on the hot path” does not mean
“no credentialed control plane.”

### Controlled Python proof

Tested package versions:

- `moss==1.7.1`
- `inferedge-moss-core==0.20.1`
- Python 3.12 on Apple Silicon macOS

The native constructor signature is:

```text
SessionIndex(name, model_id, project_id, project_key, client_id=None)
```

The following cases were tested with telemetry disabled:

| Attempt | Result |
| --- | --- |
| Blank project ID and blank key | HTTP 400: both fields must not be empty |
| Dummy project ID and dummy key | Authentication failed: invalid credentials |
| A `moss_...`-shaped key but blank project ID | HTTP 400: project ID must not be empty |
| Project ID but blank key | HTTP 400: project key must not be empty |
| `model_id="custom"` with auth URL redirected to dead loopback | Constructor still attempted the auth request and failed |

`custom` embeddings therefore avoid Moss's model forward pass and model
download, but do **not** bypass credential validation in the supported Python
session API.

### Controlled Swift proof

Tested:

- official Moss Swift package `0.6.2`
- official `Moss.xcframework` release binary
- iPhone 17 Pro simulator, iOS 26.5

The test redirected `MOSS_AUTH_URL` to an unreachable loopback port, disabled
telemetry, and attempted these local-only sessions:

```swift
let client = try MossClient(projectId: projectID, projectKey: projectKey)
let session = try await client.session(
    "credential-proof",
    options: SessionOptions(modelId: "custom", autoLoadOnInit: false)
)
```

Results:

```text
blank + custom + local-only  -> auth HTTP request attempted; session failed
dummy + custom + local-only  -> auth HTTP request attempted; session failed
blank + built-in + local-only -> auth HTTP request attempted; session failed
```

This proves `autoLoadOnInit: false` skips cloud index hydration, not session
authentication. The test passed as a harness test because these failures were
captured and asserted as observations; no credential value was used.

### Can Moss be self-hosted?

The public SDK repository is BSD-2-Clause, but the supported runtime is still
designed around Moss's credential and model-access services. Moss's public
pricing page lists VPC/on-premises deployment as an add-on. That is not the
same as a documented, freely self-hostable, credential-free control plane.

For this hackathon and the public SDKs tested here, the defensible answer is:

> There is no documented, supported, credential-free Moss session path.

An enterprise on-prem arrangement may change where authentication is hosted,
but it is not a basis for claiming that this OSS DMG is standalone.

### Persistence and privacy implication

SQLite remains CHECKPOINT's canonical local database. Moss receives only
compact retrieval documents and is an optional semantic index. This prevents a
missing credential or network outage from making local memory unavailable.

Moss's local query path does not send each query to a remote vector database.
However, session initialization authenticates, built-in model files may need a
first-use download, and the installed SDK includes background session-usage
telemetry. CHECKPOINT sets `MOSS_DISABLE_TELEMETRY=1`. We should still avoid
marketing the third-party runtime as categorically air-gapped.

## LiveKit

### What is genuinely local

LiveKit Server is open source under Apache-2.0 and officially supports local
self-hosting. LiveKit Agents can connect to a self-hosted LiveKit server and run
on infrastructure the operator controls.

LiveKit clients always connect with a signed participant JWT. A worker also
uses an API key and secret to register with a server. In a self-hosted setup,
these are locally chosen protocol credentials, not LiveKit Cloud credentials.
The app can generate them on first launch, store the secret in Keychain, and
mint short-lived participant tokens through its authenticated loopback helper.
The user needs to see zero fields.

Official references:

- [Self-hosting overview and feature comparison](https://docs.livekit.io/transport/self-hosting/)
- [Run LiveKit locally](https://docs.livekit.io/transport/self-hosting/local/)
- [JWT tokens and grants](https://docs.livekit.io/home/server/generating-tokens)
- [LiveKit Server repository](https://github.com/livekit/livekit)
- [LiveKit Agents repository](https://github.com/livekit/agents)

### Controlled isolated-network proof

The official `livekit/livekit-server:v1.13.3` and
`livekit/livekit-cli:v2.17.0` images were acquired, then run on a Docker
`--internal` network with no route to the internet. The server ran in dev mode;
the CLI created a room, joined, and published its embedded demo track.

Observed result:

```text
connected to room
published simulcast track
local-user (ACTIVE) tracks: 1
network_internal=true
```

No LiveKit account or vendor-issued credential was involved. Temporary
containers and networks were removed after the test.

### What is not local

LiveKit Inference is a metered LiveKit Cloud model gateway. The self-hosting
comparison explicitly lists built-in inference as unavailable for self-hosted
deployments. The current Agents implementation targets
`agent-gateway.livekit.cloud` and requires a LiveKit API key and secret. With
credentials unset, constructing the current Inference path failed immediately
with `ValueError: api_key is required`.

Official references:

- [LiveKit Inference](https://docs.livekit.io/agents/models/inference/)
- [Official Inference authentication source](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/inference/_utils.py)
- [Self-hosted feature comparison](https://docs.livekit.io/transport/self-hosting/)

The Cloud token server, formerly exposed as Sandbox, is also hosted. LiveKit
documents it as development-only and says Sandbox is deprecated. A sandbox or
token-server ID can let a frontend obtain a participant token; it does not give
the Python worker credentials and does not authorize LiveKit Inference.

- [LiveKit token server / Sandbox documentation](https://docs.livekit.io/frontends/build/authentication/sandbox-token-server/)

### Fully local voice still needs local models

Self-hosting LiveKit solves real-time media transport and agent dispatch. It
does not supply local STT, LLM, or TTS models. A genuinely offline voice stack
must plug in local implementations, for example:

- Apple/native on-device speech recognition where availability is verified;
- Apple Foundation Models or Ollama for reasoning;
- AVSpeechSynthesizer or another local TTS engine.

LiveKit officially documents Ollama for local LLM use, but does not offer a
turnkey, first-party fully local STT+TTS pair:

- [LiveKit Ollama integration](https://docs.livekit.io/agents/models/llm/ollama/)

For a voice query originating and terminating in the same Mac app, native
speech is the simpler P0. Self-hosted LiveKit becomes valuable when another
device, browser, remote participant, or separately scaled agent must join.

## Simplest honest configuration

### Consumer default

The first-launch path asks for no service credentials:

```text
Turn on private memory -> grant Accessibility when useful -> type or speak
```

- SQLite/FTS is always available.
- Apple local extraction is always the first choice.
- Bright Data enrichment is separately consented and optional.
- Moss is an optional semantic accelerator.
- Local/native voice is the zero-key default.
- LiveKit Cloud voice is an optional demo/remote mode.

### Why “one Moss key” is not technically valid

The current auth API validates two independent values: a project UUID and a
project key (the latter commonly starts with `moss_`). The project ID is not
documented as derivable from the key, and a key-only controlled request was
rejected specifically because `projectId` was empty.

We should not label a raw Moss project key as sufficient. There are two honest
ways to deliver a one-action setup:

1. **Operator project:** compile/provision a non-secret project ID for this
   deployment and ask the user only for the matching project key.
2. **Credential bundle:** expose one “Paste Moss connection” control that
   accepts the two lines copied from setup in a single bundle, parses them, and
   stores the values separately in Keychain.

The second is the correct BYOK/OSS default. Supported one-paste formats should
include:

```text
MOSS_PROJECT_ID=<uuid>
MOSS_PROJECT_KEY=moss_<secret>
```

The same field may also accept the JSON profile produced by the official Moss
CLI. CHECKPOINT should not invent a new colon-delimited credential format: the
paste should be recognizable source material copied from Moss, and malformed or
key-only input must fail closed. A bare project key can replace a saved key only
when the matching project ID is already present in Keychain.

Existing saved secrets are never redisplayed.

### Why “one LiveKit key” is not technically valid for Cloud

A Cloud worker needs a server URL, API key, and API secret. These are separate
values. A frontend token-server/Sandbox ID is not a substitute. The honest
one-action UX is “Paste LiveKit connection,” accepting the environment block
exported by LiveKit's tooling. For the old hackathon Sandbox frontend path, the
consumer app can ask for just the token-server ID and default the agent name to
`checkpoint`, while clearly labeling it development-only.

For a production consumer app, an operator backend should own Cloud
credentials and issue narrow, short-lived participant tokens. A distributable
DMG must never contain a LiveKit API secret.

### Configuration surface

| Capability | Local default | Optional one-paste connection |
| --- | --- | --- |
| Private memory | No configuration | n/a |
| Local text reasoning | No configuration | OpenAI key only under Advanced |
| Public enrichment | Off until consent | Bright Data API key |
| Semantic retrieval | SQLite/FTS | Moss credential bundle (ID + key) |
| Same-Mac voice | Native local voice | n/a |
| Remote/demo voice | Off | LiveKit connection bundle, or dev token-server ID |

All user-provided secrets are stored in macOS Keychain with a device-only
accessibility class. The helper receives them over its authenticated loopback
endpoint and keeps them in process memory. They are never written to its SQLite
database, returned by status endpoints, or logged.

## Organizer reference cross-check

The organizer-provided
[`KOL-Copilot`](https://github.com/itsajchan/KOL-Copilot) example independently
uses both Moss project values, full LiveKit Cloud worker credentials, and
LiveKit Inference for its voice models. It does not expose a hidden
credential-free Moss or Inference path. Its useful implementation patterns and
privacy caveats are captured in the
[reference audit](kol-copilot-reference-audit.md).

## Product decision

For the hackathon, use Moss because it is a required sponsor technology and its
local query path is valuable. Describe it precisely:

> Moss performs the semantic embedding and search inside the app's runtime;
> credentials authorize the runtime and optional sync. CHECKPOINT keeps the
> canonical private graph in local SQLite and does not push it to Moss Cloud.

Use LiveKit Cloud only for the explicit voice demo if time demands it. Do not
call that path offline. The zero-key product path should remain text plus native
on-device voice; a self-hosted LiveKit distribution can be a later remote-device
mode.
