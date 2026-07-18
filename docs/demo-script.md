# CHECKPOINT two-minute hackathon demo

## Fastest judge path (45 seconds)

Run `./scripts/run-demo.sh` once. It starts the current authenticated helper,
records one production-shaped passive observation, derives the sanitized query
`LiveKit official documentation latest`, performs the real Bright Data lookup,
and opens CHECKPOINT only after the result is in the local graph.

1. Point to `Local graph → Moss recall → Fresh context` and `0 screenshots saved`.
2. Open **Memories → Expanded Knowledge**. Show the exact public query, its
   local origin, completion state, and both clickable sources/snippets.
3. Tap the microphone and ask: “What was I researching about realtime voice
   frameworks?” The transcript enters the same request path as typed input.
4. Point to `Moss · local` and `Bright Data · public context` on the answer.

That is the entire product loop: normal activity becomes compact private graph
evidence; a generic public entity is enriched; voice retrieves the combined
memory. No save, resume, provider panel, terminal explanation, or action
confirmation is required during this version of the demo.

## What the judge should remember

> CHECKPOINT turns normal Mac activity into private, searchable work memory, enriches only safe public topics, and lets you retrieve or resume the complete context by voice.

The default runnable demo proves three product/provider beats in one story, with a fourth optional enhancement:

- native macOS passive context and safe restore;
- Moss semantic retrieval over the local memory graph;
- Bright Data public enrichment with citations;
- native on-device voice entering the same request path as text;
- optional LiveKit realtime voice when a working LiveKit connection bundle is pasted before the demo.

## Pre-demo setup

Run these before judges arrive:

```bash
./scripts/check-env.sh
./scripts/run-demo.sh
```

`run-demo.sh` starts or reuses the current private helper, records one safe
passive LiveKit observation through the production endpoint, lets Bright Data
populate the Expanded Knowledge ledger, and then opens the app. A separate
helper terminal or well-timed app switch is not needed.

`check-env.sh --full-demo` and `run-voice.sh` are optional LiveKit rehearsal commands, not default startup. Run them only after a working LiveKit Cloud URL/key/secret plus a Mac-client Sandbox/token-server ID have been configured. The current Bright Data, Moss, and OpenAI credentials are enough for the default text, retrieval, enrichment, and on-device voice path.

Confirm without showing credentials:

- menu-bar icon is present;
- `Memory On` is visible;
- helper says `Memory ready`;
- `BrightMoss auth` appears under recent memory;
- the native microphone reaches `Listening…`;
- Bright Data returns a cited result once;
- Xcode is installed, or substitute an installed seeded app before the demo;
- `demo/token-notes.md` exists at the seeded path.

If onboarding appears, use the shortest path:

1. Enable `Add fresh public context`.
2. Choose `Start remembering`.
3. Grant Accessibility when asked.
4. Grant microphone access only when the voice beat begins.

Do not open the connections sheet during the main demo. The environment or Keychain should already supply operator services.

## Exact two-minute script

### 0:00–0:12: the problem

**Say:**

> Spotlight can find a file. It cannot recover why that file, a docs page, and an app belonged together. CHECKPOINT is git stash for your brain.

**Do:** Click the menu-bar icon. Keep the main app window closed for this beat.

**The screen should show:**

- `Memory is on`;
- a current line such as `Remembering Safari · LiveKit token auth`;
- `0 screenshots retained` in the main window when opened.

### 0:12–0:35: passive memory and private enrichment

**Do:** Move between the seeded project in Xcode, `token-notes.md`, and the LiveKit client-connect page in Safari. Open the menu-bar item again.

**Say:**

> I am just doing my work. CHECKPOINT reads bounded context locally and never keeps the pixels. When it recognizes a safe public topic, only one sanitized public query goes to Bright Data.

**The screen should move through:**

- `Remembering Safari · LiveKit token auth`;
- `Adding public context for LiveKit…`;
- `Added 2 public sources · stored locally`.

Open **Memories** briefly if the judges want the privacy proof: the remembered
moment shows its local extraction method, the exact outbound query, and the two
public sources as one provenance chain.

If enrichment finishes too quickly to show the middle state, point to the completed public-source row. Do not wait on a spinner.

### 0:35–1:06: retrieve by voice with Moss

**Do:** Choose `Open CHECKPOINT` from the menu-bar panel. Click the microphone and say clearly:

> Resume the thing where token auth was blocking me.

**The screen should show:**

1. the final transcript as a normal user turn;
2. the `BrightMoss auth` confirmation card;
3. `On this Mac`, `Moss`, and `Voice · On-device` provenance;
4. the blocker: `JWT generation was blocking the Mac agent`;
5. the exact Xcode, file, and URL restore targets.

**Say:**

> The voice turn is transcribed on this Mac. Moss finds the episode semantically, even though I did not use its title. Voice has no extra authority, so CHECKPOINT still previews the exact restore plan.

**Optional LiveKit variant:** If a working LiveKit bundle was pasted and `run-voice.sh` passed preflight, the active voice status and provenance may say `LiveKit voice`. Then replace the first sentence with: `LiveKit handles this explicit realtime voice turn.` Do not use that narration or label in the default local-voice run.

### 1:06–1:22: safe restore

**Do:** Click `Resume` once.

**The screen should show:** `Opened 3 saved items`, followed by Xcode, the notes file, and the LiveKit page opening.

**Say:**

> One confirmation reopens the working set. CHECKPOINT uses allowlisted native actions, not generated shell commands or arbitrary clicking.

If Xcode is not installed, seed an installed app before the demo. A partial-success message is truthful but weaker.

### 1:22–1:48: ask the enriched memory

**Do:** Return to CHECKPOINT and type:

> Has the current LiveKit token guidance changed?

**The screen should show:**

- a short answer comparing current guidance with the saved context;
- one or two clickable HTTPS sources;
- `Live web`, `Bright Data`, and `Saved to local memory`.

**Say:**

> Bright Data checks the current public source, and the cited result joins the local episode. The next question can retrieve that richer context through Moss without sending my screen history anywhere.

### 1:48–2:00: privacy close

**Do:** Click the menu-bar icon and choose `Pause Memory`. Point to `Erase Last 15 Minutes…` without erasing the seeded demo unless rehearsed.

**Say:**

> The user can always see when memory is on, pause it instantly, or erase recent observations. Private capture is local; public enrichment is selective and visible.

End on the paused menu-bar status or the cited answer card, whichever is visually stronger in the room.

## Short sponsor explanation if asked

### Moss

> Moss is the semantic retrieval layer over compact local episode and graph documents. SQLite is the canonical local journal, and cloud index sync is off. Moss credentials are still required to create the supported SDK session.

### Bright Data

> Bright Data receives only a policy-approved public subject or an explicitly saved public HTTPS page. It returns at most two sources, which are cited and attached to local memory.

### LiveKit

> The app includes an optional LiveKit realtime voice path. It becomes active only after a Cloud worker connection and Mac-client token-server ID are configured. Today’s zero-key path uses on-device speech; both paths produce the same text turn and neither bypasses native approval.

### Privacy

> CHECKPOINT stores meaning and provenance, not a screenshot archive. App/window extraction happens locally. The truthful claim is private capture with selective cloud enrichment, not an air-gapped system.

## Failure fallbacks

### Native voice fails

Type the exact same sentence:

> Resume the thing where token auth was blocking me.

Say:

> The typed path is intentionally independent from voice. It reaches the same Moss retrieval and native confirmation flow.

Do not spend demo time reconnecting audio.

### Moss is unavailable

Use the seeded title phrase:

> Find BrightMoss auth.

Say:

> The canonical local record remains available through exact local search. Moss normally adds the fuzzy semantic match you saw in the rehearsed path.

The UI must label the fallback `Local memory`, not `Moss`.

### Bright Data is slow or unavailable

Ask the current-guidance question once. If it returns the saved copy, say:

> Live web is unavailable, so CHECKPOINT falls back to the last cited copy instead of blocking local memory.

Do not retry repeatedly on stage. Keep a screenshot or 30-second backup video of the successful cited result.

### Accessibility is denied

Say:

> CHECKPOINT degrades to app-name-only memory and manual checkpoints. Search and restore still work.

Use the seeded checkpoint for the rest of the demo.

### Restore target is missing

If two of three items open, use the partial result as the safety proof:

> CHECKPOINT opens valid saved targets and reports the missing one. It never invents a replacement path.

## Rehearsal checklist

Run the script three times after feature freeze.

- [ ] The first visible state says `Memory On` and names the current app.
- [ ] Passive context updates within one app switch.
- [ ] The enrichment completion is visible without opening developer tools.
- [ ] The voice transcript is correct before the answer appears.
- [ ] The fuzzy voice phrase resolves to `BrightMoss auth`.
- [ ] The confirmation card lists exactly three restorable targets.
- [ ] `Resume` opens the expected targets with one click.
- [ ] The current-guidance request shows a citation and Bright Data provenance.
- [ ] Pause works immediately from the menu bar.
- [ ] No terminal, API key, JSON payload, graph table, or provider settings appears during the main demo.

## Thirty-second backup version

1. Show `Memory On · Remembering Safari` in the menu bar.
2. Open CHECKPOINT and say `Resume the thing where token auth was blocking me` using on-device voice.
3. Show the final transcript, Moss retrieval card, and exact restore confirmation.
4. Click `Resume`.
5. Show the cited Bright Data answer already in the timeline.
6. Pause memory from the menu bar.

Voiceover:

> CHECKPOINT privately turns normal Mac activity into searchable work memory. Moss retrieves the episode from a vague voice phrase, and Bright Data adds cited public context. Nothing reopens until I approve it, and I can pause or erase memory from the menu bar. LiveKit can replace the on-device voice transport when its Cloud bundle is connected.
