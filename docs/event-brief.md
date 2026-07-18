# Event brief alignment

## Verified source

The official document is [Welcome to Conversational Agents Hack
Day](https://docs.google.com/document/d/1pTJQYWhdue-fZryY4l_5x1wfFAKyAARaBs7oZFQ6DxU/edit?tab=t.0),
last checked July 18, 2026.

It defines the event stack as:

- conversational agents;
- Bright Data web infrastructure;
- data stored in Moss.dev;
- LiveKit for voice agents.

It names KOL-Copilot as an example integration, not a required project format.
It does not list judging criteria, prizes, or scoring weights in the current
document.

Bright Data event promo code:

```text
hackersquad100
```

## Why CHECKPOINT fits

| Brief requirement | CHECKPOINT proof in the demo |
| --- | --- |
| Conversational agent | One native conversation accepts ordinary typed and spoken requests |
| Moss.dev storage | Checkpoint and source chunks populate the active local Moss session and are retrieved after a fuzzy query |
| LiveKit voice | Microphone audio crosses a LiveKit room, becomes a final turn, and returns the same native result card as text |
| Bright Data infrastructure | One saved public URL is explicitly refreshed, compared with its saved baseline, cited, and retained locally |

SQLite is the crash-safe local durability journal because the current public
Python Moss API does not expose a stable disk-persistence contract. This does not
hide Moss: the active searchable memory is added to and queried from Moss, and a
restart rebuild visibly repopulates that session.

The optional hackathon worker uses LiveKit Inference for STT/LLM/TTS, while the
zero-key same-Mac path uses native on-device speech. OpenAI is an optional
planner and is not substituted for any event provider.

## Sponsor-visible demo details

Keep daily UI labels human:

```text
Local memory
Used cloud voice
Used cloud AI
Used live web
```

For judging, expand `Run details` so each decisive beat visibly names its
provider:

```text
Moss · local retrieval
LiveKit · voice turn
OpenAI · speech and planning
Bright Data · saved-page refresh
```

Narrate the stack once:

> Swift captures and safely reopens the workspace. Moss holds the active local
> memory. LiveKit carries the voice turn. Bright Data refreshes the one page I
> approved, and the useful comparison accrues back into local memory.

Do not bury provider proof in a terminal. The native result and comparison cards
should carry the semantic label, with exact provider and timing one disclosure
click away.

## Submission checklist

The official brief gives this sequence:

1. Open [HackerSquad.io](https://hackersquad.io/).
2. Enter the Builder Portal and join the event.
3. Create a team when applicable.
4. Make sure every teammate accepts the invite.
5. Complete and save the Project tab.
6. Create the demo video.
7. Submit the project.

Suggested project copy:

**Name:** CHECKPOINT

**Tagline:** Git stash for your brain.

**One-liner:** A local-first Mac agent that remembers an explicit work session,
finds it from a vague text or voice request, safely reopens it, and uses Bright
Data to keep one approved source current.

**Stack:** SwiftUI, LiveKit, Moss.dev, Bright Data, OpenAI, SQLite.

Verify the portal's current deadline and required media fields onsite; the brief
does not specify them.
