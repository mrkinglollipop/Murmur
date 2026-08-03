# Plan 019: Make the docs tell the truth about what this app actually is

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5560a7b..HEAD -- README.md CLAUDE.md plans/README.md Sources/Voice/LocalModel.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `5560a7b`, 2026-07-27

## Why this matters

The README documents an app that no longer exists. It tells a reader to `cd`
into a directory that isn't there, lists five cloud transcription providers of
which four are hidden and one is missing, and says nothing at all about the
auto-update channel, the DMG build, or the release pipeline — all of which
shipped and are live. Stale docs are worse than absent ones: they send a
reader (or an agent) confidently down a dead path.

This is the cheapest high-value plan in the set. It is pure text; nothing
compiles differently afterward. The one thing it must get right is *accuracy* —
every claim it writes must be checked against the code, not against this plan's
prose.

## Current state

**Wrong repo path**, `README.md:71`:

```
cd "<stale-clone-path>"
```

The README should use a generic clone path or `cd` to the Murmur repo root — not a
private absolute path.

**Wrong cloud engine table**, `README.md:39-45`, which lists AssemblyAI,
Deepgram, OpenAI, Groq, and xAI. The truth is in
`Sources/Voice/LocalModel.swift:94-101`:

```swift
    /// Cloud models offered in the Settings picker. AssemblyAI, Deepgram,
    /// Groq, and OpenAI are excluded (see doc comments on each case above)
    /// but their service classes, `CloudProvider` cases, and
    /// `CloudTranscriberFactory` mapping stay compiled and working — this
    /// is a visibility change only (plan 013).
    static var selectable: [CloudModel] {
        [.xaiGrokSTT, .elevenLabsScribeV2Realtime]
    }
```

So: exactly two selectable cloud engines — **xAI Grok STT** and **ElevenLabs
Scribe v2 Realtime** — and the README omits ElevenLabs entirely while
advertising four retired ones.

**Missing entirely from the README**: Sparkle auto-update (configured in
`project.yml:78-81` with a live public appcast), `scripts/make-dmg.sh`,
`scripts/publish-sparkle.sh`, and the release flow generally.

**Stale test count**, `CLAUDE.md:26` claims "69 tests, 0 failures". The suite
run on 2026-07-27 reported **113 tests, 0 failures**.

**Stale plan statuses**, `plans/README.md` rows 24 and 25 mark plans 006 and
007 as TODO. Both partially shipped:

- 006 (WPM + latency insights): `Sources/Voice/UI/InsightsView.swift` exists
  and is wired into the app at `Sources/Voice/UI/RootView.swift:119`. Its own
  doc comment at `InsightsView.swift:6-8` explains that WPM is intentionally
  omitted because `HistoryEntry` has no duration field. So: the Insights
  surface shipped; the duration field and WPM did not.
- 007 (retry from history + engine picker): `Sources/Voice/UI/HistoryView.swift:226-239`
  ships a working Retry button, but only for entries where `entry.failed` is
  true and `entry.audioPath != nil`, and it reuses the currently-selected
  engine. So: retry shipped; the engine picker and retry-for-successful-entries
  did not.

**Undocumented script inventory**: `scripts/` contains `install-local.sh`,
`make-dmg.sh`, `publish-sparkle.sh`, `release.sh`, and
`test-publish-sparkle-helpers.sh`, with no index anywhere saying which is the
current release path. `release.sh` appears superseded by the
make-dmg → publish-sparkle flow but is not marked as such.

**Conventions to match:**

- The README uses `##` section headers, short intro sentences, and markdown
  tables for enumerable facts. Match that voice — plain and declarative.
- `CLAUDE.md` is terse, imperative, and organized under
  What-this-is / Setup / Verify / Conventions / Sharp edges. Keep it terse;
  it is loaded into every agent session, so every line costs context.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Verify the selectable engine list | `grep -A3 "static var selectable" Sources/Voice/LocalModel.swift` | shows `[.xaiGrokSTT, .elevenLabsScribeV2Realtime]` |
| Count tests | `grep -rn "func test" Tests/VoiceTests/*.swift \| wc -l` | a number — use whatever it prints |
| Run tests (to state the count truthfully) | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Confirm the appcast is live | `curl -sIL -o /dev/null -w "%{http_code}\n" "https://github.com/mrkinglollipop/Murmur-updates/releases/download/appcast/appcast.xml"` | `200` |

Run from the Murmur repo root.

## Scope

**In scope**:
- `README.md`
- `CLAUDE.md`
- `plans/README.md`
- `scripts/README.md` (create)

**Out of scope** (do NOT touch):
- Any file under `Sources/`, `Tests/`, or `scripts/*.sh`. This plan changes
  **no code and no scripts** — if you find yourself wanting to fix code
  because the docs were wrong about it, stop and report instead.
- `AGENTS.md` — it documents Cursor Cloud (Linux) setup, a separate concern.
- `project.yml`.
- Do not delete `scripts/release.sh`; only document its status.

## Git workflow

- Branch: `docs/truth-up`
- Conventional commits, e.g. `docs: correct README engine list and build path`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the README build section

Replace the wrong path at `README.md:71` with a generic clone path or repo-root
`cd` (no private absolute paths).
While there, confirm the build command block matches the one in `CLAUDE.md`
(`xcodegen generate` then `xcodebuild -scheme Voice …`) and reconcile them if
they differ — CLAUDE.md is the authority, since it is the one agents follow.
Also add the `cp Config/Team.xcconfig.example Config/Team.xcconfig` step that
CLAUDE.md documents as hard-required by xcodegen; the README omits it.

**Verify**: `grep -n "CURSOR/Code/voice-dictation" README.md` → no matches.

### Step 2: Rewrite the cloud engine table

Replace the five-row table at `README.md:39-45` with the two engines that are
actually selectable:

| Provider | Model | Notes |
|---|---|---|
| xAI | Grok STT (`grok-stt`) | Streaming over WebSocket |
| ElevenLabs | Scribe v2 Realtime | Streaming over WebSocket |

Add one sentence noting that AssemblyAI, Deepgram, OpenAI, and Groq remain
compiled as scaffolding but are deliberately hidden from the Settings picker.
Do **not** describe them as broken or removed — they are intentionally
retired-but-present.

Also check and correct the surrounding prose: `README.md:49` describes xAI
streaming as a special case and says "Other providers always use the batch
upload path," which is now misleading since both selectable engines stream.

**Verify**: `grep -n "AssemblyAI\|Deepgram" README.md` → matches only in the
new "retired scaffolding" sentence, not in the selectable table.

### Step 3: Document the release path

Add a `## Release` section to the README covering, in a few sentences each:

- `bash scripts/install-local.sh` — local Release install to `/Applications`.
- `bash scripts/make-dmg.sh` — one-command signed DMG; `NOTARIZE=1` opts into
  notarization.
- `bash scripts/publish-sparkle.sh` — publishes the signed update to the
  public `Murmur-updates` appcast.
- That the app auto-updates via Sparkle from that public feed, with the source
  repo staying private.

Read each script's header comment block before writing its description; do not
guess at flags or env vars. **Do not put any key material, key paths, or
credential locations in the README** — describe the step, not the secret.

**Verify**: `grep -n "make-dmg\|publish-sparkle\|Sparkle" README.md` → matches
in the new section.

### Step 4: Create a scripts index

Create `scripts/README.md`: a short table with one row per script — name,
what it does, when you'd run it — and an explicit line naming
make-dmg → publish-sparkle as the current release path, with `release.sh`
marked legacy. Again: read each script's header before describing it, and
include no secret paths.

**Verify**: `ls scripts/README.md` → exists; every `.sh` in `scripts/` has a row.

### Step 5: Fix the CLAUDE.md test count

Run the test suite, read the actual number it reports, and update
`CLAUDE.md:26`. Phrase it so it doesn't rot again — state the expectation as
"0 failures" being the gate and give the count as approximate/current, e.g.
`# -> ** TEST SUCCEEDED ** (113 tests at time of writing; the count grows —
0 failures is the gate)`.

**Verify**: `grep -n "69 tests" CLAUDE.md` → no matches.

**Post-batch note (execute plan):** After plans 016/017/018 add tests, the
count will drift again. Re-bump `CLAUDE.md` at end of 018 (or end of the
016–020 batch) to the live suite total — 019's bump from 69→~113 is not the
final word if later plans land in the same series.

### Step 6: Verify the plans index reconciliation

`plans/README.md` rows 006, 007, and 015 were already reconciled when this
plan was written (006 and 007 marked PARTIAL, 015 marked as feed-live). Your
job is to **confirm those claims are still true**, not to redo them:

- Confirm `Sources/Voice/UI/InsightsView.swift` exists and is referenced from
  `Sources/Voice/UI/RootView.swift`, and that `HistoryEntry` still has no
  duration field (`grep -n "duration" Sources/Voice/UI/HistoryStore.swift`).
- Confirm the Retry button at `Sources/Voice/UI/HistoryView.swift:226-239` is
  still gated on `entry.failed`.
- Run the `curl` liveness command from the Commands table. If it returns 200,
  row 015's "feed live" claim holds. If it returns anything else, correct the
  row and report the code.

Correct any row whose claim no longer matches, and report what you found.

**Verify**: `grep -n "PARTIAL" plans/README.md` → two matches (006, 007).

## Test plan

No new automated tests — this plan changes only markdown. The verification is
the grep/curl commands in each step plus one final consistency pass:

- Re-read the finished README end to end and confirm every factual claim about
  engines, paths, and commands matches something you actually verified with a
  command in this session. Any claim you cannot verify, cut rather than guess.
- Confirm the existing test suite still passes (it should be untouched):
  `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  → `** TEST SUCCEEDED **`.

## Done criteria

ALL must hold:

- [ ] `grep -n "CURSOR/Code/voice-dictation" README.md` → no matches
- [ ] `grep -n "69 tests" CLAUDE.md` → no matches
- [ ] README's cloud table lists exactly xAI Grok STT and ElevenLabs Scribe v2 Realtime
- [ ] README has a `## Release` section naming all three release scripts
- [ ] `scripts/README.md` exists with a row per `.sh` file
- [ ] `plans/README.md` rows 006 and 007 read `PARTIAL` with the specific gap noted; row 015 updated per the curl result
- [ ] `git status` shows only the four in-scope files modified/created — **zero** files under `Sources/`, `Tests/`, or `scripts/*.sh`
- [ ] `xcodebuild test …` → `** TEST SUCCEEDED **` (unchanged)
- [ ] `plans/README.md` status row for 019 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift) — most
  importantly, if `LocalModel.swift`'s `selectable` list is no longer
  `[.xaiGrokSTT, .elevenLabsScribeV2Realtime]`, document what it actually is
  and flag the discrepancy.
- The `curl` liveness check returns anything other than 200 — report the code;
  do not edit row 015 on a guess.
- You find a documented behavior that the code contradicts in a way that looks
  like a *code* bug rather than a doc error. Report it as a finding; do not
  fix code in this plan.
- You cannot determine from a script's header what it does. Say so rather than
  writing a plausible-sounding description.

## Maintenance notes

- The engine table will rot again the next time `CloudModel.selectable`
  changes. The durable fix is to stop enumerating engines in prose — a future
  cleanup could have the README point at the Settings picker instead of
  duplicating the list.
- `CloudModel.default` is currently `.assemblyAIUniversal3`
  (`LocalModel.swift:92`) — a *retired* engine as the default constant. It is
  sanitized at read time by `selectableOrFallback`, so it is not a live bug,
  but it is a trap for anyone who reads the constant and believes it. Noted
  here rather than fixed, because changing a default touches persisted
  settings behavior and deserves its own change.
- A reviewer should check the README's claims against the code, not against
  this plan — this plan is itself a snapshot and can go stale.
