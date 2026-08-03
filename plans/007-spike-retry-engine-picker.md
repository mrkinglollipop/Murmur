# Plan 007 (spike): Let retry-from-history run a different engine than the one that failed

> **Executor instructions**: Design-and-build spike. Steps 1-2 are
> investigation; record findings in the commit/PR description. Honor STOP
> conditions. Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/UI/HistoryStore.swift Sources/Voice/UI/HistoryView.swift Sources/Voice/ASREngineSelector.swift`

## Status

- **Priority**: P3
- **Effort**: S-M
- **Risk**: LOW-MED
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Failed dictations keep their audio precisely so they can be retried
(`RecordingRetention`, "Phase 1" design). But retry re-runs whatever engine is
CURRENTLY selected — which, in the common failure case (the configured cloud
provider is down or the key is bad), is the exact engine that just failed.
One-click retry is useless for provider outages unless the user first walks
into Settings, switches engines, retries, and switches back. An engine
override on the retry action makes the retained audio actually valuable.

## Current state

- `Sources/Voice/UI/HistoryStore.swift:146-170` — retry uses the ambient
  engine selection:

  ```swift
  /// Re-transcribes a failed entry's retained audio via `asrSelector`.
  /// On success, updates the existing row; on failure, leaves `failed = true`.
  func retryTranscription(id: UUID, asrSelector: ASREngineSelector, completion: (() -> Void)? = nil) {
      func start() {
          guard let entry = self.entries.first(where: { $0.id == id }),
                entry.failed,
                let path = entry.audioPath,
                FileManager.default.fileExists(atPath: path) else { ... }
          self.pendingRetryEntryID = id
          let url = URL(fileURLWithPath: path)
          asrSelector.transcribeAndLog(audioURL: url) { completion?() }
  ```

- The retry UI lives in `Sources/Voice/UI/HistoryView.swift` (find with
  `grep -n "Retry" Sources/Voice/UI/HistoryView.swift`).
- Engine selection machinery lives in `Sources/Voice/ASREngineSelector.swift`
  (`selectedModel`, `cloudModel` — see `streamingEligible` at lines 192-194
  for how engine identity is read). `HistoryEntry.engine` already records
  which engine produced each entry (`HistoryStore.swift:9`).

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | `xcodegen generate` | success |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED |

## Scope

**In scope**: `HistoryStore.swift` (retry signature), `HistoryView.swift`
(retry menu), `ASREngineSelector.swift` (an override-capable transcribe
entry point ONLY if Step 1 shows one is needed), `Tests/VoiceTests/`,
`plans/README.md`.

**Out of scope**: Settings UI; adding/removing engines; automatic fallback
chains on live dictation (that is a bigger design conversation — this plan is
retry-only); any streaming code.

## Git workflow

- Branch: `feat/retry-engine-picker`; conventional commits; no push/PR
  without operator instruction.

## Steps

### Step 1 (investigate): Find the cheapest engine-override seam

Read `ASREngineSelector.transcribeAndLog` and the engine-resolution code it
calls. Two candidate designs — pick the one that avoids mutating global
state:

- (a) `transcribeAndLog(audioURL:engineOverride:completion:)` — an optional
  override parameter threaded to engine resolution. Preferred if resolution
  happens in one place.
- (b) Temporarily set-and-restore the selected engine around the retry —
  REJECT this if at all avoidable (races with a concurrent live dictation).

Document the choice and why in the commit message.

### Step 2 (investigate): Enumerate offerable engines

Determine how to list "engines the user could retry with" — local models that
are downloaded, plus cloud providers that HAVE a stored key
(`KeychainStore`). Find the existing source of that information (SettingsView
builds such lists — `grep -n "cloudModel\|LocalModel" Sources/Voice/UI/SettingsView.swift`).
Reuse, don't duplicate.

### Step 3: Implement the override path

Per Step 1(a): add the optional override, default `nil` (existing behavior
unchanged). Retry entries pass the user's pick.

**Verify**: build + tests green; existing retry behavior (no pick) unchanged.

### Step 4: UI — retry menu

In `HistoryView`'s failed-entry actions, replace the single "Retry
transcription" action with a submenu: "Retry (current engine)" plus one item
per offerable engine from Step 2 (labeled like Settings labels them). Keep it
a plain `Menu` — no new view files.

**Verify**: build green. UI behavior: report unverified-manual unless you can
run the app and see the submenu on a failed entry.

### Step 5: Test the seam

Unit-test whatever pure logic Step 2/3 produced (e.g. "offerable engines
given a set of downloaded models and stored-key providers"). Model on existing
store tests; keychain access must be behind the existing store abstraction —
do not hit the real keychain in tests.

## Done criteria

- [ ] Retry works with an explicit engine that differs from the current selection (unit-level proof at the seam; manual run if possible)
- [ ] No global engine state mutated by a retry
- [ ] Build + full suite green; `plans/README.md` updated

## STOP conditions

- Engine resolution is smeared across multiple sites such that design (a)
  requires touching >3 files — report the map you built instead of forcing it.
- Anything requires writing to the real Keychain in tests.

## Maintenance notes

- This creates the natural seam for a future automatic fallback chain on live
  dictation failures — deliberately out of scope here; note it, don't build it.
