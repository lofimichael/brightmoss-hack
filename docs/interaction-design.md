# CHECKPOINT interaction design

## Interaction contract

**One window. One conversation. One input.**

Users click CHECKPOINT in the Dock or menu bar, then type or speak naturally.
There are no commands to memorize, no modes to select, and no mandatory hotkey.
An optional global shortcut can live in Settings, but onboarding never depends on
it.

The complete daily-use surface contains:

- a compact header with capture and checkpoint-storage status;
- a conversation and result area;
- one text composer;
- one microphone button;
- one send button;
- contextual result or confirmation cards.

The design is chat-shaped but native SwiftUI. ChatKit or a web view is not a v0
dependency.

## Main window

```text
┌────────────────────────────────────────────────────────┐
│ CHECKPOINT               Checkpoints on this Mac ●  ⚙︎ │
│                                                        │
│  You                                                   │
│  Resume the thing where token auth blocked me.         │
│                                                        │
│  ┌ BrightMoss auth ─────────────────────────────────┐  │
│  │ Yesterday, 3:42 PM                              │  │
│  │ JWT generation was blocking the Mac agent.      │  │
│  │ Xcode · Terminal · Safari ×2                    │  │
│  │                                                 │  │
│  │                         [Just show it] [Resume]  │  │
│  └─────────────────────────────────────────────────┘  │
│                                                        │
│  ┌──────────────────────────────────────────────┐      │
│  │ Ask, remember, or resume…               🎙  ➤ │      │
│  └──────────────────────────────────────────────┘      │
└────────────────────────────────────────────────────────┘
```

Recommended size is approximately 520 by 620 points. The window may float above
the current workspace while active, but it must behave like a normal app window:
it can be moved, closed, reached from the Dock, and used without a shortcut.

## Empty state

Headline:

> **What do you want to pick up?**

Show three temporary suggestion chips:

- `Checkpoint this work`
- `Resume something`
- `Ask about my work`

Selecting a chip inserts editable text into the composer. These chips are
examples, not permanent navigation.

Once a checkpoint exists, replace the suggestion chips with no more than three
recent checkpoint rows. Never show both groups. Search remains the primary
history interface; there is no sidebar.

## First-run onboarding

Onboarding has one required screen and one conditional provider screen. System
permissions appear progressively when the user first needs them.

### Screen 1: promise

> **Pick up where you left off.**
>
> CHECKPOINT saves a work session, finds it later, and reopens it. Nothing is
> captured until you ask.

Primary action: `Get started`

Secondary action: `How privacy works`

Privacy detail:

> Checkpoints are stored on this Mac. CHECKPOINT reads the active workspace only
> when you ask it to save or act. Live web refresh is optional.

### Screen 2: thinking provider

Skip this screen when the packaged demo agent already has a working provider.
Show it in the open-source build only when no provider is configured.

> **Choose how CHECKPOINT thinks**

Primary action: `Use OpenAI`

Secondary action: `Use Ollama on this Mac`

If Ollama is reachable at its local endpoint, show `Ollama detected` and make it
one click. Otherwise the OpenAI path shows:

> **Paste an OpenAI API key**
>
> Stored in your Mac Keychain and used only by CHECKPOINT's local helper to call
> OpenAI.

Placeholder: `sk-…`

Primary action: `Connect OpenAI`

Failure:

> That key didn't work. Check it and try again.

Moss, LiveKit, and Bright Data operator credentials do not belong in everyday
onboarding. The hackathon build receives them from the local agent environment.
The public release can place advanced service configuration in Settings or a
setup helper without exposing shared secrets in the DMG.

## Progressive permissions

### Accessibility

Ask on the first rich capture attempt, not at app launch. Restoring saved apps,
files, and URLs through `NSWorkspace` does not require Accessibility.

> **Let CHECKPOINT see what you're saving**
>
> It can read the active app, window title, document, and selected text only when
> you ask. It never captures continuously.

Primary action: `Allow access`

Secondary action: `Save a note only`

### Microphone

Ask when the microphone button is first pressed.

> **Talk to CHECKPOINT**
>
> Microphone access turns speech into a CHECKPOINT request. Typing always works.

Primary action: `Allow microphone`

Secondary action: `Keep typing`

Failure:

> Microphone access is off. You can keep typing or enable it in System Settings.

Actions: `Open Settings`, `Keep typing`

### Live web

A request containing an explicit freshness cue such as “current,” “latest,” or
“changed” may invoke Bright Data after first-use disclosure. TTL is advisory: an
old saved source shows a `Refresh` action but never starts a network request by
itself. A normal local miss remains local in v0.

> **Refresh this saved page?**
>
> CHECKPOINT will fetch the current public page and compare it with your saved
> excerpt. The useful result will be stored on this Mac.

Actions: `Refresh page`, `Use saved copy`

## Unified text and voice input

Typed text and final voice transcripts produce the same `UserTurn` and enter the
same retrieval, planning, and confirmation pipeline. Voice is conversational,
not a separate dictation-to-composer implementation.

### Keyboard

- `Return` submits a single-line request.
- `Shift-Return` inserts a newline.
- `Escape` cancels an active recording, dismisses a card, or closes the panel in
  that order.
- Pasted text remains visible and editable before submission.

### Voice

1. Tap the microphone.
2. A live transcript appears in the normal timeline/composer region.
3. End-of-speech or tapping `Done` finalizes and submits the voice turn.
4. The final transcript appears as a normal user message.

Conversational voice may submit automatically, but it cannot execute a native
action automatically. Any save, multi-item restore, or delegated task still
produces the same confirmation card as typed input.

States:

- `Listening…`
- `Finishing transcript…`
- `Couldn't hear that. Try again or type instead.`

If spoken output and barge-in are enabled, tapping the microphone while
CHECKPOINT speaks interrupts playback and begins a new turn. This is demo polish,
not a v0 acceptance gate.

## Explicit current context

Ordinary questions do not capture or attach desktop context. Swift requests a
snapshot only when:

- the user starts or saves a checkpoint;
- an active checkpoint is visibly remembering app changes;
- the user explicitly says `this`, `current app`, or `current page`;
- the user explicitly includes selected text.

Captured context appears inside the save or action preview, where each item can
be removed before persistence or model use. There are no persistent composer
chips in v0. Supported context types are:

- active application and window title;
- document path or browser URL when Accessibility exposes it;
- selected text captured by an explicit user action;
- the checkpoint currently being discussed.

## Capture flow

Example requests:

- “Checkpoint this.”
- “Save where I am.”
- “Remember this as BrightMoss auth.”

Every capture intent follows one state machine:

```text
idle → remembering → save preview → saved
```

While remembering, a visible header pill records frontmost application changes.
When Accessibility is available, it also snapshots the focused window and
document path or URL. Selected text is included only after an explicit request.

Starting copy:

> **Remembering this work**
>
> Switch between the apps and pages that belong together. Save when you're done.

Header pill:

```text
Remembering: BrightMoss auth · 4 items       [Save] [Cancel]
```

Selecting `Save` shows one preview:

> **Save this checkpoint?**
>
> **BrightMoss auth**<br>
> 3 apps · 2 pages · 1 selected note

Optional field:

> **What should Future You know?**

Placeholder:

> Next step or blocker

The title, note, and item list are editable inline.

Actions: `Save checkpoint`, `Cancel`

Success:

> Saved locally. Ask for “BrightMoss auth” whenever you're ready.

If rich context is unavailable:

> I can save your note, but I can't see the active app or selected text yet.

Actions: `Allow access`, `Save note only`

No capture continues after the pill disappears. `Checkpoint this` while idle
starts remembering the current item; saving immediately creates a one-item
checkpoint. There is no separate “quick” and “extended” capture mode.

## Retrieve flow

Example requests:

- “Find the thing where LiveKit auth blocked me.”
- “What was I doing yesterday?”
- “What did I learn about Moss sessions?”

Return one best match:

> **BrightMoss auth**<br>
> Yesterday at 3:42 PM<br>
> JWT generation was blocking the Mac agent.<br>
> Xcode · Terminal · Safari ×2

Actions: `Resume`, `Open checkpoint`

Tertiary link: `Show 2 more matches`

No match:

> I couldn't find a checkpoint matching that.

Actions: `Show recent`, `Try another phrase`

Ambiguous result:

> I found two likely checkpoints. Which one did you mean?

Show no more than two cards.

## Resume flow

After an exact checkpoint is selected:

> **Resume “BrightMoss auth”?**
>
> Open Xcode, Terminal, and 2 Safari pages.

Actions: `Resume`, `Just show it`, `Cancel`

Success:

> **BrightMoss auth is open.**<br>
> Next step: implement the JWT token endpoint.

Partial success:

> Restored 4 of 5 items. `token-notes.md` has moved.

Actions: `Find file`, `Dismiss`

The supported restore verbs are open app, open file, open URL, and reveal in
Finder. The interface never promises arbitrary application control.

## Delegate flow

The P0 delegated task is deliberately narrow:

- “Does LiveKit's current token guidance still match the excerpt I saved?”
- “Refresh the saved LiveKit page and add what changed to BrightMoss auth.”

General web research, arbitrary search, and unattended background delegation are
stretch work.

Show the entire bounded plan:

> **Run this task?**
>
> Refresh the saved LiveKit page, compare it with the saved excerpt in
> “BrightMoss auth,” and save the finding locally.
>
> Uses live web and your configured cloud model.

Actions: `Run task`, `Edit`, `Cancel`

Progress is plain-language status, not tool logs:

- `Refreshing the saved page…`
- `Comparing with your checkpoint…`
- `Saving the useful parts locally…`

Completion:

> **Done. The guidance changed in 2 places.**

Show one source card and actions `View comparison` and `Resume checkpoint`.

If live web is unavailable:

> I can search what's already on this Mac, but live web refresh is unavailable.

Actions: `Search local`, `Try again`

## Confirmation policy

| Operation | Behavior |
| --- | --- |
| Search local checkpoints | Run immediately |
| Answer from saved local content | Run immediately |
| Open one item explicitly requested by name | Run immediately |
| Save a checkpoint | Confirm once with preview |
| Restore multiple apps/files/URLs | Confirm once with full list |
| Refresh a saved public page | Disclose on first use; explicit freshness request authorizes later refreshes |
| Multi-step delegated task | Confirm one bounded plan |
| Write or externally visible action | Confirm exact content and destination |
| Delete a CHECKPOINT local record | Destructive confirmation with exact local scope |
| Delete an external file, purchase, send, submit, or modify accounts | Unsupported in v0 |

Cancellation copy:

> Stopped. Nothing else was changed.

## Renderable outcomes

Every assistant turn resolves to one of four UI primitives:

```text
Message
ResultCard
ConfirmationCard
ProgressCard
```

Tools return structured data and never invent bespoke UI. This keeps the surface
small even as the internal capability set grows.

### Message

Short conversational response with optional source footer. Maximum two compact
paragraphs before a card or disclosure.

### ResultCard

Displays a checkpoint, cited comparison, or source. It has one primary action,
one secondary action, and at most one tertiary text link.

### ConfirmationCard

Displays the exact plan, affected items, provider disclosure, and primary
approval. It cannot be hidden behind a generic “Are you sure?” alert.

### ProgressCard

Displays the current human-readable step, cancel control, and eventual result.
It does not expose chain-of-thought, raw tool calls, tokens, or provider logs.

## Resilience copy

Moss or index unavailable:

> Local search is rebuilding. Your checkpoints are safe.

Offline:

> You're offline. Local search and typing still work. Voice, cloud AI, and live
> web need a connection.

OpenAI unavailable:

> The model didn't respond. Your request and checkpoints are still local.

Local helper disconnected:

> CHECKPOINT's local helper isn't running.

Actions: `Restart helper`, `View setup`

Generic safe failure:

> Something went wrong before anything changed.

Actions: `Try again`, `Copy details`

## Settings

Settings are not part of the main window. v0 contains only:

- `Open CHECKPOINT at login`
- optional global shortcut, disabled or configurable without onboarding
- model provider status: OpenAI or Ollama
- `Refresh a saved page when I explicitly ask`
- `Manage permissions`
- `Delete all local checkpoints`
- `Advanced setup` for operator/service configuration

There is no prompt library, voice gallery, personality selector, model-per-turn
picker, or tool-management screen.

### Local deletion copy

Delete one:

> **Delete “BrightMoss auth” from this Mac?**
>
> This removes its notes, saved source copies, and search index entries. It does
> not delete the original files or web pages.

Actions: `Delete checkpoint`, `Cancel`

Delete all:

> **Delete all CHECKPOINT memory from this Mac?**
>
> This removes every checkpoint and rebuilds an empty local search index. This
> cannot be undone.

Actions: `Delete all local memory`, `Cancel`
