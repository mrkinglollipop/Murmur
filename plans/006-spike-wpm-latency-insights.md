# Plan 006 (spike): Thread recording duration into HistoryEntry and add WPM + latency tiles to Insights

> **Executor instructions**: This is a design-and-build spike, not a pure
> build plan — Steps 1-2 are investigation whose findings may legitimately
> alter Steps 3-5; record what you find in the PR/commit description. Honor
> STOP conditions. Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/AudioRecorder.swift Sources/Voice/UI/HistoryStore.swift Sources/Voice/UI/InsightsView.swift`

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED (persisted-schema change with live decoder)
- **Depends on**: none (cleaner after 004/010-class work, but independent)
- **Category**: direction
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Murmur's value proposition is speed, but Insights shows only word counts and
streaks. The two speed metrics that matter — words per minute, and
hold-release-to-text-injected latency — are blocked on one missing field. The
code already computes recording duration and throws it away, and the Insights
view literally documents the gap:

- `Sources/Voice/AudioRecorder.swift:287-288`:

  ```swift
  let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
  logger.info("Recording stopped — duration \(String(format: "%.2f", elapsed))s, ...")
  ```

- `Sources/Voice/UI/InsightsView.swift:6-8`:

  ```swift
  /// WPM is intentionally NOT shown: `HistoryEntry` has no duration field, so a
  /// words-per-minute figure would have to be fabricated. Omit rather than fake
  /// it — see `HistoryStore.swift`.
  ```

## Current state

- `HistoryEntry` (`Sources/Voice/UI/HistoryStore.swift:5-46`) is
  `Codable` with a custom `init(from:)` that already uses
  `decodeIfPresent` for later-added fields (`audioPath`, `failed`) — the
  exact pattern a new optional field must follow so existing `history.json`
  files keep decoding:

  ```swift
  audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
  failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
  ```

- The logging call chain that must carry duration:
  `AudioRecorder` (computes `elapsed`, line 287) →
  `asrSelector.transcribeAndLog(audioURL:)` →
  `TranscriptionPipeline` → `onTranscriptionLogged?(text, engineID, injected, audioPath, failed)`
  → `AppDelegate` wiring → `HistoryStore.append(text:engine:injected:audioPath:failed:)`
  (`HistoryStore.swift:101-107`). Trace the exact signatures with
  `grep -rn "onTranscriptionLogged" Sources/`.
- Injection latency (release → injected) is NOT currently measured anywhere;
  the natural anchor points are `stopRecording()` (`AudioRecorder.swift:89`)
  and the `TextInjector().insert` call (`TranscriptionPipeline.swift:217`).
- Insights tiles pattern: `InsightsView.swift` computes stats as private
  computed vars over `historyStore.entries` (e.g. `totalWords`, lines 13-15).

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | `xcodegen generate` | success |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED |

## Scope

**In scope**: `AudioRecorder.swift` (thread duration out),
`ASREngineSelector.swift` + `TranscriptionPipeline.swift` (carry the value),
`AppDelegate.swift` (wiring), `HistoryStore.swift` (schema + append),
`InsightsView.swift` (tiles), `Tests/VoiceTests/` (new decode tests),
`plans/README.md`.

**Out of scope**: HistoryView row UI (unless a one-line duration label is
trivial); any change to how history is persisted (file format stays JSON);
streaming-internal timing.

## Git workflow

- Branch: `feat/wpm-latency-insights`; conventional commits; no push/PR
  without operator instruction.

## Steps

### Step 1 (investigate): Map the logging call chain

Trace `elapsed` → `HistoryStore.append` end to end; write down every
signature that must gain a parameter. If the chain has more than ~4 hops or
fans out (e.g. retry path in `HistoryStore.retryTranscription` also calls
`transcribeAndLog`), decide and document whether retries carry the ORIGINAL
duration (they should — the audio file length is unchanged).

### Step 2 (investigate): Decide the latency metric definition

Recommended: `releaseToInjected` = wall time from `stopRecording()` to just
after `TextInjector().insert` returns. Confirm both anchors are reachable by
the value you thread; if the streaming path makes "release" ambiguous, define
it as "the moment `doStop`/`handleStopXAI` begins" and document it.

### Step 3: Schema — add optional fields to HistoryEntry

`var durationSeconds: Double?` and `var latencySeconds: Double?`, decoded with
`decodeIfPresent` exactly like `audioPath`. Bump nothing else — old files must
load unchanged.

**Verify**: new unit test decoding a LEGACY JSON blob (without the new keys)
and a NEW blob (with them) both succeed — model on however
`HistoryStore` is currently tested, or add `HistoryEntryDecodeTests.swift`.

### Step 4: Thread the values through and persist

Extend the chain mapped in Step 1. Keep parameters optional end-to-end so
non-audio paths (if any) pass `nil`.

**Verify**: build + full tests green; manual dictation (if you can run the
app) shows the new fields in `~/Library/Application Support/Voice/history.json` — otherwise report unverified-manual.

### Step 5: Insights tiles

Add two tiles following the existing computed-var pattern: **Average WPM**
(total words ÷ total duration minutes, over entries that HAVE duration; show
"—" when none do) and **Median injection latency** (same guard). Explicitly
skip entries with nil fields — no fabrication, matching the view's stated
philosophy.

**Verify**: build green; tiles render with "—" on a history file lacking the
fields (report unverified-manual if the app can't be run).

## Done criteria

- [ ] Legacy + new history JSON both decode (tests prove it)
- [ ] Duration and latency persisted on new dictations
- [ ] Two new tiles, nil-safe, no fabricated numbers
- [ ] Full build + test suite green
- [ ] `plans/README.md` updated

## STOP conditions

- The logging chain requires touching the streaming coordinator's internals
  beyond adding a passthrough parameter — report the shape you found.
- Legacy history decode breaks in any way — this is user data; stop.

## Maintenance notes

- Future per-engine latency comparisons (local vs cloud) fall out of these
  fields for free — note as follow-up, don't build now.
- Reviewer focus: retry path double-counting (a retried entry must not get a
  new duration from a fresh clock).
