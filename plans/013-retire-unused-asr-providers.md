# Plan 013: Retire Groq / Deepgram / AssemblyAI / OpenAI as selectable ASR engines (keep the scaffolding)

> **Executor instructions**: Follow step by step. Run every verification
> command and confirm the expected result before moving on. On any STOP
> condition, stop and report — do not improvise. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat aef0c93..HEAD -- Sources/Voice/CloudTranscriber.swift Sources/Voice/UI/SettingsView.swift Sources/Voice/UI/SettingsStore.swift`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED (a persisted setting can point at a now-hidden engine — see Step 3)
- **Depends on**: none (main already has plan 012's ElevenLabs engine merged)
- **Category**: tech-debt
- **Planned at**: commit `aef0c93`, 2026-07-09

## Why this matters

Verified from the user's own `history.json` (772 entries): **721 dictations
used `cloud:xai-streaming`, 69 used local WhisperKit, and ZERO have ever used
any cloud batch provider.** Meanwhile those unused providers are actively
harmful as *options*:

- **AssemblyAI** returns HTTP 400 on every request (deprecated `speech_model`
  parameter, confirmed against the live API 2026-07-09).
- **Groq**'s stored key is dead (401 at credential level).
- **OpenAI**'s ASR path uploads CAF, which is untested — xAI rejects CAF,
  ElevenLabs accepts it, so OpenAI is an unflipped coin.
- **Deepgram** scored least-accurate in the bake-off and produced its only
  meaning-changing error.

A user-selectable engine that fails the moment it is selected is worse than no
option at all. **Operator decision (2026-07-09): remove them from the app's
selectable engine list, but LEAVE THE SCAFFOLDING in place** — the service
classes, `CloudProvider` cases, and `CloudTranscriberFactory` mapping all stay
compiled and working, so re-enabling any of them later is a one-line change.

The engines that remain selectable: **xAI grok-stt (streaming, default)** and
**ElevenLabs Scribe v2 Realtime** for cloud; **WhisperKit** and **Parakeet**
for local.

## Current state

- `CloudProvider` (`Sources/Voice/CloudTranscriber.swift:10-15`) has cases
  `assemblyAI, deepgram, openAI, groq, xai` plus `elevenLabs` (added by plan
  012). `CloudTranscriberFactory.service(for:)` switches exhaustively over it.
- `CloudModel` is the user-facing model list. **Find its definition and every
  place it is enumerated** — start with
  `grep -rn "CloudModel" Sources/` and
  `grep -rn "allCases" Sources/Voice/UI/SettingsView.swift`. The Settings
  picker enumerates all cases today; that is what must change.
- The user's persisted selection lives in UserDefaults under
  `voice.settings.selectedCloudModel` (current value: `xaiGrokSTT`). Confirm
  the exact key with `grep -rn "selectedCloudModel" Sources/`.
- **OpenAI is NOT only an ASR provider.** `CleanupService.swift:130` and
  `TransformRunner.swift:47` both hardcode `https://api.openai.com/v1/chat/completions`
  and read the OpenAI key from the Keychain. The Settings **OpenAI API-key
  field must remain** — only the OpenAI *transcription engine option* goes
  away. Deleting that key field breaks cleanup and transforms.

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | From repo root: `cp -n Config/Team.xcconfig.example Config/Team.xcconfig 2>/dev/null; xcodegen generate` | Created project |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` (83 baseline + yours) |

Hard cap: 3 oracle runs per change. Not green after 3 → STOP and report with
the last error. Do NOT edit unrelated files to reset a guard's counter.

## Scope

**In scope**: `Sources/Voice/CloudTranscriber.swift` (add a selectability
predicate + doc comments; do NOT delete services), wherever `CloudModel` is
defined, `Sources/Voice/UI/SettingsView.swift` (picker source), whatever
performs the stored-selection load (`SettingsStore`), `Tests/VoiceTests/`,
`plans/README.md`.

**Out of scope — do NOT touch**:
- Any provider's `transcribe(...)` implementation, `CloudProvider` enum cases,
  or the factory switch. The scaffolding stays and must keep compiling.
- The OpenAI API-key field in Settings, `CleanupService.swift`,
  `TransformRunner.swift`, `KeychainStore.swift`.
- The xAI streaming path, the ElevenLabs realtime path, local engines.
- The default engine (xAI stays default).

## Git workflow

- Branch: `chore/retire-unused-asr-providers` off `main` (currently `aef0c93`).
- If the shared working directory is dirty or on another branch, create an
  isolated `git worktree` rather than checking out in place.
- Conventional commits; `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Do NOT push, do NOT open a PR.

## Steps

### Step 1: Add a selectability predicate

On `CloudModel`, add `static var selectable: [CloudModel]` returning only the
xAI and ElevenLabs models. Add a doc comment on the excluded ones stating
plainly: retained as scaffolding, not user-selectable, with the one-line
reason each (AssemblyAI: deprecated param → 400; Groq: unused; Deepgram:
unused; OpenAI: untested CAF upload — its key is still used by cleanup and
transforms). Keep `allCases` intact — other code and tests may rely on it.

**Verify**: build → `** BUILD SUCCEEDED **`

### Step 2: Point the Settings picker at `selectable`

Change the picker's `ForEach` source from all cases to `CloudModel.selectable`.
Do not otherwise restyle the view.

**Verify**: build green; `grep -n "selectable" Sources/Voice/UI/SettingsView.swift` → 1+ hit.

### Step 3: Make a stale persisted selection safe (the real risk)

If UserDefaults holds a now-unselectable model (e.g. a user who once chose
Deepgram), the app must not present or use it. On load, if the stored model is
not in `CloudModel.selectable`, fall back to the xAI model and persist that
correction. Put this in whatever loads `selectedCloudModel`.

**Verify**: unit test below.

### Step 4: Tests

Add `Tests/VoiceTests/CloudModelSelectionTests.swift` (`@testable import Voice`,
model on `Tests/VoiceTests/CleanupSanityTests.swift`):
- `selectable` contains exactly the xAI and ElevenLabs models.
- `selectable` excludes assemblyAI/deepgram/openAI/groq models.
- The fallback logic maps a retired model → the xAI model, and leaves a valid
  selection untouched.
- `CloudTranscriberFactory.service(for:)` still returns a service for a
  retired model (scaffolding intact — this is the regression guard for the
  "leave the scaffolding" requirement).

**Verify**: `xcodebuild test ...` → `** TEST SUCCEEDED **`, count increased by 4+.

## Done criteria

- [ ] Settings picker shows exactly: xAI grok-stt, ElevenLabs Scribe v2 Realtime
- [ ] `CloudTranscriberFactory.service(for:)` still compiles and returns services for all six providers (test proves it)
- [ ] OpenAI API-key field still present in Settings; `CleanupService`/`TransformRunner` untouched (`git diff` shows no changes to those files)
- [ ] A stored retired selection falls back to xAI (test proves it)
- [ ] Build + full suite green
- [ ] Only in-scope files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `CloudModel` turns out to be defined such that filtering breaks the Settings
  picker's `Identifiable`/`Hashable` conformance in a way that needs a redesign
  — report the shape you found.
- You find any code path that selects a cloud model WITHOUT going through the
  stored setting (i.e. a hardcoded Deepgram/Groq call site) — report it.
- Removing the OpenAI *engine* appears to break cleanup or transforms — STOP,
  that means the key field and the engine are entangled; report before cutting.

## Maintenance notes

- Re-enabling a provider later = add it back to `selectable` (one line) and
  verify its upload format first (xAI rejects CAF; ElevenLabs accepts it —
  see plan 010).
- This plan makes plan 011 (AssemblyAI param fix) optional: the broken engine
  is now unreachable from the UI. Do not delete plan 011; mark it deferred.
- Plan 010's WAV transcode now only needs to cover the reachable batch paths
  (xAI, ElevenLabs) — but leaving the scaffolding means the other services
  still upload CAF; that is acceptable because nothing can select them.
