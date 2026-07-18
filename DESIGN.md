# CHECKPOINT design system and two-hour UX blueprint

## Product context

- **What this is:** A local-first macOS memory layer that notices bounded work context, turns it into retrievable episodes, selectively adds public context, and helps someone resume the work later.
- **Who it is for:** People who lose the thread between apps, pages, files, decisions, and blockers. The hackathon judge should understand it without a tutorial.
- **Project type:** Native SwiftUI menu-bar and Dock app with one compact conversation window and a lightweight menu-bar quick-entry panel.
- **Positioning:** Spotlight finds a file. CHECKPOINT restores the train of thought around it.
- **Five-second promise:** **Your Mac remembers what you were doing, without keeping your screen.**
- **Memorable thing:** The menu bar quietly changes from `Memory On` to `Remembering Safari · LiveKit docs`, then a vague voice request retrieves the complete context later.

## Product posture

### Aesthetic direction

- **Direction:** Quiet instrumentation.
- **Decoration:** Minimal and intentional. Native materials, fine borders, restrained green, and no ornamental illustration after onboarding.
- **Mood:** Calm, private, capable, and already part of macOS. It should feel closer to a trusted system utility than a chatbot product.
- **Layout:** One disciplined column. No sidebar, provider tabs, graph canvas, command palette, or full-screen voice mode.
- **Color:** Restrained. Moss green means memory is on or a local action succeeded. Blue means a link or live-web source. Amber means attention without danger. Red is reserved for recording and destructive actions.
- **Motion:** Minimal-functional. State changes crossfade or slide by a few points. Nothing continuously pulses while passive memory is on.

### What is deliberately familiar

- Native SwiftUI controls, semantic type styles, system permission prompts, and standard macOS menu behavior.
- One chat-like transcript, one composer, and one approval card for a bounded native action.
- A normal movable window that can close while the menu-bar process keeps running.

### What gives CHECKPOINT its own face

- The primary status is a plain-language account of what the app is doing, such as `Remembering Safari · LiveKit token auth`, instead of an abstract online dot.
- Assistant answers do not use bot avatars or decorative chat bubbles. They read like concise memory records with evidence.
- The product proves privacy in the interface with `On this Mac` and `0 screenshots saved`, not with a long privacy policy.
- Provider capabilities appear as provenance on useful results. They never become daily navigation.

## Interaction contract

The user has one mental model and one request path:

1. Leave `Memory On` while working.
2. Type a quick request in the menu-bar panel, or open the main window to type or speak.
3. See every submitted request and result in the same main conversation.
4. Confirm only when CHECKPOINT will reopen something.

Every feature must fit one of four verbs: **remember, ask, resume, or pause**. Provider setup, graph storage, extraction, policy checks, and indexing remain implementation details.

## Screen hierarchy

```text
CHECKPOINT process
├── Menu-bar status panel, 340 pt
│   ├── current memory state and pause/resume
│   ├── latest local/public-context activity
│   ├── shared quick text field
│   ├── Open CHECKPOINT
│   ├── Fresh public context toggle
│   └── erase, connections, and quit controls
├── Main window
│   ├── compact brand and memory header
│   ├── one-line live activity strip
│   ├── conversation / empty-state briefing
│   └── one text-and-voice composer
├── Action confirmation sheet/card
├── Capture review sheet, explicit checkpoint only
└── Privacy & Connections sheet, setup and troubleshooting only
```

There is no always-visible navigation. Submitting from the menu-bar field opens the main window and places the turn in the same conversation. Opening CHECKPOINT directly returns focus to the main composer.

## Menu-bar experience

The menu bar is CHECKPOINT's persistent trust surface. Its compact window-style panel must say whether observation is on even when the main window is closed, while allowing a fast typed request without becoming a second conversation UI.

### Label

- Memory on: `brain.head.profile.fill`, rendered in the normal menu-bar foreground. Accessibility label: `CHECKPOINT, Memory On`.
- Memory paused: `pause.circle`, not a red warning. Accessibility label: `CHECKPOINT, Memory Paused`.
- Active enrichment does not replace the memory icon. A transient `globe` appears inside the opened menu only.
- Do not use a permanently pulsing or red recording icon. CHECKPOINT is not retaining video or audio.

### Exact panel hierarchy

```text
┌────────────────────────────────────────┐
│ CHECKPOINT          ● Memory is on     │
│                               [Pause]  │
├────────────────────────────────────────┤
│ ✦ Working in Safari on LiveKit auth    │
│   Added public context · 4 remembered  │
│                                        │
│ [ Ask your memory…                 ↑ ] │
│                                        │
│ Open CHECKPOINT                      ↗ │
├────────────────────────────────────────┤
│ Fresh public context              [●] │
│                                        │
│ Erase 15 min   Connections          ⏻ │
└────────────────────────────────────────┘
```

When paused, replace the context block with:

```text
Ⅱ Nothing new is being remembered
  Your existing memory is still searchable.
```

When no Accessibility permission is available, use `Remembering Safari · app name only`. Do not imply the window title was captured.

### Menu-bar behaviors

- The quick field and main composer share the same draft and submit path. Submitting from the panel opens or raises the main window before sending.
- The menu-bar field is text-only. Voice remains in the main composer so recording state and the final transcript stay visible.
- `Open CHECKPOINT` opens or raises the existing main window and places keyboard focus in the composer.
- `Pause Memory` stops new workspace observations immediately. Search and restore remain available.
- `Erase Last 15 Minutes…` describes application-level deletion and reports the result in the main conversation if it is open.
- `Fresh public context` controls only new policy-approved Bright Data work. Turning it off does not disable local capture or Moss retrieval.
- Provider names are absent from the top-level menu. They belong in provenance and the connections sheet.

## Main window

### Geometry

- Ideal size: **600 × 700 pt**.
- Minimum size: **520 × 620 pt**.
- The timeline grows; the header and composer remain pinned.
- The window is a normal app window, not a transient popover. Closing it leaves the menu-bar process running.

### Layout

```text
┌──────────────────────────────────────────────────────┐
│ ● CHECKPOINT                            Memory On  ···│  46 pt
│ ✦ Remembering · Safari / LiveKit auth                 │  32 pt
│                         On this Mac · 0 screenshots   │
├──────────────────────────────────────────────────────┤
│                                                      │
│  Empty briefing or conversation                      │  flexible
│                                                      │
│  Result / confirmation / source cards                │
│                                                      │
│ ┌──────────────────────────────────────────────────┐ │
│ │ Ask what you were doing…                🎙   ↑   │ │  54–104 pt
│ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

### Header

First row:

- Leading: green brain symbol and `CHECKPOINT` wordmark.
- Trailing: one `Memory On` / `Paused` pill and one overflow menu.
- The pill itself toggles memory. It has a dot plus text so state never depends on color alone.

Second row, the single activity strip:

- Default on: `Remembering · Safari / LiveKit token auth`.
- No rich metadata: `Remembering · Safari, app name only`.
- Waiting for first observation: `Memory ready · Keep working normally`.
- Local extraction: `Understanding · On this Mac`.
- Policy check: `Privacy check · Public topic only`.
- Bright Data active: `Enriching · Adding public context for LiveKit…`.
- Complete: `Remembered · 2 public sources stored locally`.
- Rejected by privacy policy: `Kept local · This context was not sent`.
- Paused: `Memory paused · Existing context stays searchable`.
- Helper starting: `Memory is starting… · Your draft is safe`.

The trailing end of this same strip always shows `On this Mac` and `0 screenshots`. It is one component, not a stack of pipeline rows.

Only the newest meaningful sentence is visible. Do not create a scrolling console in the header.

## Empty state and ambient briefing

The empty state must explain the product and prove it is already useful before the first message.

### With no observations

Headline: **Ask your work, not your folders.**

Body:

> Your context is already taking shape. Ask naturally whenever you need it.

Suggestion actions, no more than three:

- `What was I just doing?`
- `Find that page`
- `Catch me up`

Clicking a suggestion inserts editable text into the composer. It does not submit automatically.

### With passive observations

Show one compact card below suggestions:

```text
JUST REMEMBERED                                      now
Safari icon  Working in Safari on LiveKit token auth
             Safari · Remembered locally
[LiveKit] [token auth]
[On this Mac] [Moss] [Bright Data]   No screenshot kept
```

If enrichment completed, the activity title and Bright Data provenance in the same card become active:

```text
🌐 Added 2 public sources about LiveKit tokens
   Bright Data · saved to local memory
```

Under the card, a compact read-only path may show `Local context → Moss recall → Fresh context`. This is sponsor legibility, not navigation. This is not a chronological feed. Show the latest local context and latest successful enrichment only. The full graph stays behind search.

### With recent checkpoints

Replace suggestions with up to three recent rows. Each row contains title, one-line summary, relative time, and a trailing resume arrow. Keep the composer visually dominant.

## Conversation and answer design

### User turns

- Right-aligned compact bubble in a 14% tint of the accent.
- Maximum width: 78% of the timeline.
- Voice turns use the same bubble with a small `waveform` accessibility label, not a different conversation type.
- Final voice text must appear before the result.

### Assistant turns

- Left-aligned, no avatar, maximum width 430 pt.
- Plain answers render as selectable body text.
- Structured answers render in a card only when there is something to inspect, cite, or approve.
- Lead with the answer. Provider details stay in the footer.

### Retrieval result card

```text
Found the work where token auth blocked you.

BrightMoss auth
JWT generation was blocking the Mac agent.
Next: Implement and verify the LiveKit token endpoint.
Xcode · token-notes.md · LiveKit token authentication

[On this Mac] [Moss]                              [Resume]
```

The title and blocker carry more weight than the provider label. Do not dump ranked search scores or graph nodes.

### Restore confirmation card

```text
Resume “BrightMoss auth”?

Open 3 saved items:
  Xcode
  token-notes.md
  LiveKit token authentication

[On this Mac] [Moss]                 [Cancel] [Resume]
```

`Resume` is the only prominent action. One approval covers the exact listed plan. After a decision, replace buttons with `Opened 3 items` or `Cancelled · nothing opened`.

### Bright Data answer card

```text
The current LiveKit guidance still requires a participant token
issued by a trusted token server.

Sources
  LiveKit: Connecting to a room                      ↗
  LiveKit: Tokens and grants                         ↗

[Live web] [Bright Data] [Saved to local memory]
```

- Show one or two cited HTTPS sources.
- `Saved to local memory` tells the user that this enrichment is now retrievable.
- The source title is the link. Do not display a raw tracking URL.
- If the answer compares an older saved excerpt, say `Compared with your saved copy from <date>`.

## Provenance language

Provider disclosure should answer two user questions: where did the information come from, and did anything leave the Mac?

| Backend disclosure | Primary UI label | Expanded detail |
| --- | --- | --- |
| `Local memory` | `On this Mac` | `SQLite record on this Mac` |
| `Moss · local` | `On this Mac` + `Moss` | `Semantic retrieval ran in the local Moss session` |
| `Bright Data · live web` | `Live web` + `Bright Data` | `A policy-approved public topic or saved HTTPS page was fetched` |
| `OpenAI · cloud AI` | `Cloud reasoning` + `OpenAI` | `Only this request and selected memory snippets were sent` |
| LiveKit voice | `Voice` + `LiveKit` | `Microphone audio was used for this explicit voice turn` |
| Native voice | `Voice` + `On-device` | `Speech recognition stayed on this Mac` |

These labels appear as small icon-and-text tokens, never color-only dots. Provider names may be directly visible in the hackathon build. A later consumer build can place the exact request details under `Run details`.

## Passive capture and enrichment activity

The product must communicate a simple causal chain without exposing pipeline jargon:

```text
User works normally
  → CHECKPOINT remembers app/window meaning locally
  → a public topic passes the privacy gate
  → Bright Data adds one or two cited public sources
  → the enriched episode becomes searchable with Moss
```

### Activity state model

| Internal state | Visible sentence | Icon | Persistence |
| --- | --- | --- | --- |
| Waiting | `Memory is on · keep working normally` | `brain.head.profile` | Until first event |
| Captured | `Remembering Safari · LiveKit token auth` | app icon or `macwindow` | Until next event |
| Extracting | `Understanding this context on your Mac…` | `sparkles` | Transient |
| Private-only | `Kept this context local` | `lock.shield` | 4 seconds, then captured state |
| Enriching | `Adding public context for LiveKit…` | `globe` + spinner | Until result |
| Enriched | `Added 2 public sources · stored locally` | `checkmark.circle` | Until next event |
| Cached | `Public context is already fresh` | `checkmark.circle` | 4 seconds |
| Provider unavailable | `Public context is unavailable · local memory still works` | `exclamationmark.circle` | Until dismissed/new event |
| Failed | `Couldn’t add public context · local memory still works` | `exclamationmark.circle` | Until dismissed/new event |

Do not show rejected query text. It may itself contain private material. The detailed policy reason belongs only in sanitized diagnostics, not the daily UI.

### Enrichment behavior

- Public enrichment is a single consented preference.
- A local structured subject is sent only after the privacy policy allows it.
- Successful enrichment shows the public subject, source count, and local destination.
- Network failure never blocks local observation, chat, or retrieval.
- Avoid automatic toast spam. Update the header, the menu, and the `RIGHT NOW` card in place.

## Composer and voice

The composer is the only daily input surface.

- Placeholder: `Ask what you were doing…`
- `Return`: submit.
- `Shift-Return`: newline.
- Text remains editable before sending.
- Send button uses `arrow.up.circle.fill` and is disabled for empty input or while sending.
- Microphone button uses `mic.fill`, then `stop.circle.fill` while listening.
- Voice status appears directly above the composer, never as a modal.

Exact voice states:

- `Connecting voice…`
- `Listening… tap stop when finished`
- `Finishing transcript…`
- `I couldn’t hear that. Try again or type instead.`
- `Voice isn’t available. Typing still works.`

If LiveKit is configured, show `LiveKit voice` in the active status. Otherwise show `On-device voice`. Voice does not gain authority to reopen apps without confirmation.

## Onboarding

Onboarding is one consumer screen with one required action and one optional consent. It must never block local use because a provider is missing.

Symbol: `brain.head.profile.fill`

Headline: **Never lose the thread.**

Body:

> CHECKPOINT quietly remembers the context around your work, then lets you ask for it in plain English.

Three trust rows:

- `Understands locally` / `App, page, and document context is structured on this Mac.`
- `No screenshot archive` / `CHECKPOINT keeps useful context, not a recording of your screen.`
- `You're always in control` / `Pause from the menu bar or erase the last 15 minutes anytime.`

One optional toggle, off by default:

```text
[ ] Add fresh public context
    Bright Data may enrich approved public topics, never screenshots or local files.
```

Primary action: `Start remembering`

Secondary action:

- No configured providers: `Optional connections`
- Operator environment or Keychain detected: `<count> connections ready`

The secondary action opens the connections sheet and returns to this same screen. Never show blank API-key fields during the normal path. Each optional provider editor accepts one pasted bundle, stores it in Keychain, and links to the official provider page.

### Progressive permissions

- Ask for Accessibility when Memory first needs rich app context. If denied, continue with app-name-only memory.
- Ask for microphone and speech permission only after the microphone is tapped.
- Public-context consent is separate from both system permissions.
- Never request all permissions at launch.

## Privacy & Connections sheet

This is a setup and troubleshooting surface, not a daily provider dashboard.

Hierarchy:

1. `Privacy` section: `Memory On`, `Fresh public context`, `Erase last 15 minutes`.
2. `Connections` section: four collapsed rows, each `Connected` / `Not connected`.
3. One selected provider editor with a single secure paste field and an official account link.

Exact connection labels:

- `Bright Data · public context`
- `Moss · semantic memory`
- `LiveKit · realtime voice`
- `OpenAI · optional cloud reasoning`

Footer: `Connections are stored in your Mac’s Keychain.`

Never display a saved credential value. `Replace` and `Remove` are explicit actions.

## Empty, loading, and error states

Every failure explains what still works.

| Situation | User-facing copy | Recovery |
| --- | --- | --- |
| Helper not ready | `Local memory is starting… Your draft is safe.` | Retry automatically; keep composer text |
| No checkpoint match | `I couldn’t find that in your memory.` | `Try another phrase` and `Show recent` |
| Accessibility denied | `Remembering app names only. Allow app context for titles and documents.` | `Allow App Context` |
| Moss unavailable | `Semantic search is unavailable. I searched your local records instead.` | No blocking action; connections link in details |
| Bright Data unavailable | `Public context is unavailable. Your local memory still works.` | `Try again` or connections link |
| Enrichment rejected | `Kept this context local.` | No action required |
| Enrichment has no result | `No useful public context was added.` | Keep local memory unchanged |
| Voice unavailable | `Voice isn’t available. Typing still works.` | Keep composer focused |
| Empty voice transcript | `I couldn’t hear that. Try again or type instead.` | Mic remains available |
| Restore target moved | `Opened 2 of 3 items. token-notes.md has moved.` | `Reveal available items` or dismiss |
| Provider connection invalid | `That connection couldn’t be read. Copy the full connection block and try again.` | Preserve no plaintext after dismissal |

Use inline states and result cards. Reserve modal alerts for destructive deletion and macOS permission handoff.

## Visual tokens for SwiftUI

### Typography

Use native semantic text styles so the app respects macOS accessibility settings and feels at home on the platform.

| Role | SwiftUI style | Notes |
| --- | --- | --- |
| Wordmark | `.headline`, rounded, semibold, tracking `0.6` | Brand only |
| Onboarding title | `.system(size: 29, weight: .semibold, design: .rounded)` | One line where possible |
| Screen / sheet title | `.title2.weight(.semibold)` | No oversized hero text |
| Card title | `.headline` | Checkpoint title |
| Body | `.body` | Answers and core copy |
| Secondary | `.callout` | Summary and activity |
| Metadata | `.caption` | Times and provenance |
| Eyebrow | `.caption2.weight(.semibold)` | Uppercase, tracking `0.8` |

### Color

| Token | Light | Dark | Usage |
| --- | --- | --- | --- |
| `accent` | `#3D7A57` | `#68A77E` | Memory on, primary action, success |
| `accentSurface` | accent at 8–14% | accent at 14–18% | Nudge, user turn, selected state |
| `window` | `NSColor.windowBackgroundColor` | semantic | Main background |
| `surface` | `NSColor.controlBackgroundColor` | semantic | Cards and grouped rows |
| `border` | primary at 8–10% | primary at 14–16% | One-pixel card outline |
| `link` | semantic `Color.accentColor` or system blue | semantic | HTTPS sources |
| `attention` | `#A86612` | `#E3A44D` | Recoverable attention |
| `destructive` | semantic `Color.red` | semantic | Erase and live microphone only |

Never use a purple AI gradient. Do not use provider brand colors as structural UI colors.

### Spacing

- Base unit: **4 pt**.
- Scale: 4, 8, 12, 16, 20, 24, 32.
- Window horizontal padding: 16–18 pt.
- Header vertical padding: 10–12 pt.
- Timeline item gap: 14 pt.
- Card padding: 14 pt.
- Composer inset: 12 pt; outer margin: 14 pt.

### Shape and depth

- Small control radius: 8 pt.
- Row radius: 10–12 pt.
- Result card and composer radius: 14 pt.
- Capsules only for statuses and compact provenance tokens.
- Use a one-pixel low-opacity border. Avoid drop shadows inside the window.
- Use material only for the pinned composer and action cards. Do not stack several translucent layers.

### Motion

- State crossfade: 150 ms ease-out.
- New result: 180 ms opacity plus 4 pt upward movement.
- Menu status and privacy labels: no looping animation.
- Enrichment spinner: system `ProgressView`, only while a network request is active.
- Respect Reduce Motion by dropping translation and keeping the crossfade.

### Accessibility

- Every status combines icon and text; never rely on green, amber, or red alone.
- Minimum control hit target: 28 × 28 pt on macOS, preferably 32 pt for icon-only controls.
- Add help text and accessibility labels to the memory pill, microphone, send button, menu-bar item, and source links.
- Keep primary text selectable.
- Truncate window/document titles to one line visually while retaining the full title in help text.
- Voice and enrichment progress must be readable without animation.

## Two-hour implementation order

### P0, must work in the live demo

1. **Menu-bar trust surface, 20 minutes**
   - Show memory state, latest activity, shared quick text field, pause, erase, and privacy/connections.
   - Opening the app focuses the composer.
2. **Main-window hierarchy, 25 minutes**
   - Polish header, live activity strip, empty briefing, composer, and provenance tokens.
   - Remove provider-management language from the daily surface.
3. **Passive pipeline feedback, 35 minutes**
   - Send local observations to the helper.
   - Publish one UI activity state through local extraction, privacy policy, Bright Data enrichment, and Moss indexing.
   - Update existing UI in place rather than appending chat messages for each event.
4. **Truthful result cards, 20 minutes**
   - Retrieval shows `On this Mac` and `Moss`.
   - Live public context shows Bright Data, citations, and `Saved to local memory`.
   - Restore still requires one approval.
5. **Rehearse and freeze, 20 minutes**
   - Seed deterministic data.
   - Run the two-minute script three times.
   - Keep a typed fallback for voice and a saved-copy fallback for Bright Data.

### Cut for this hackathon

- Graph visualization or node browser.
- Screenshot gallery, screen timeline, or continuous OCR viewer.
- Provider dashboard or per-request model picker.
- History sidebar, folders, tags, and manual knowledge-base organization.
- Global hotkeys, command grammar, or slash commands.
- Animated waveform, spoken assistant response, or perfect barge-in.
- Automated clicking, arbitrary app control, or unreviewed external actions.
- Rich settings architecture, custom font bundling, or a multi-window redesign.

## File-level implementation map

| File | UX responsibility |
| --- | --- |
| `mac/Sources/CheckpointApp/CheckpointApp.swift` | Menu-bar status, open/focus behavior, app lifecycle |
| `mac/Sources/CheckpointApp/ContentView.swift` | Header, activity sentence, ambient briefing, cards, composer, onboarding |
| `mac/Sources/CheckpointApp/AppModel.swift` | One published activity state, provider provenance, latest observation, UI-safe errors |
| `mac/Sources/CheckpointApp/WorkspaceRecorder.swift` | Bounded observation events and memory-state truth |
| `mac/Sources/CheckpointApp/AgentClient.swift` | Observation, enrichment, provider-status, and erase calls |
| `mac/Sources/CheckpointApp/Models.swift` | Typed activity, enrichment, and provenance models |

## Acceptance checklist

- [ ] A stranger understands `Memory On` and can pause it from the menu bar.
- [ ] The menu says what CHECKPOINT most recently remembered without opening the app.
- [ ] The main window has one obvious text field and one obvious microphone button.
- [ ] App/window meaning is shown as local, and the UI states `0 screenshots saved`.
- [ ] A successful public enrichment identifies Bright Data, cites sources, and says it joined local memory.
- [ ] A fuzzy retrieval identifies Moss without exposing search scores or graph internals.
- [ ] Voice and typed turns enter the same timeline and approval flow.
- [ ] A restore opens nothing until the exact plan is approved.
- [ ] Provider failure leaves local capture, search, and typed input usable.
- [ ] Provider credentials never appear in the daily UI or after save.

## Decisions log

| Date | Decision | Rationale |
| --- | --- | --- |
| 2026-07-18 | Quiet native instrumentation | Trust and comprehension matter more than an AI-branded visual layer |
| 2026-07-18 | Menu bar plus one normal window | Passive state stays visible while retrieval remains a focused conversation |
| 2026-07-18 | One live activity sentence | Makes the pipeline legible without creating a logs or provider dashboard |
| 2026-07-18 | Provenance on answers | Users and judges see when Moss, Bright Data, LiveKit, or a cloud model actually ran |
| 2026-07-18 | No graph UI in P0 | The graph is retrieval infrastructure, not the consumer mental model |
