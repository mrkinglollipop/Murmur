# 024 — Repo audit: findings register

**Status:** audit complete against `6b299a5` (0.1.28 / build 29); **fix pass 1 landed** — steps 1-4 of the plan below.
**Oracle after fix pass:** `xcodebuild test -scheme VoiceTests` → **482 tests, 2 skipped, 0 failures** (baseline was 465).
**Shipped in:** PR #18 (`fix/audit-024-pass-1`), 10 commits, not yet merged.
**Local path verified end-to-end:** `LocalASRIntegrationTests` loads the real
large-v3-turbo model and transcribes `say`-synthesised speech — passed in 160 s.
Run it with `touch /tmp/.murmur-run-local-asr` (an env-var gate silently skips;
xcodebuild does not forward environment to the test runner).
**Baseline verified here:** `xcodebuild test -scheme VoiceTests` → **465 tests, 0 failures**.

## Provenance — read this first

The underlying audit was performed against **`Murmur-archive`** (0.1.20 / build 21),
which is eight releases behind this repo. That was a mistake in target selection,
not in method. Every finding below has been **mechanically re-validated against
this tree** before being carried over; anything that did not survive is struck
out with the reason.

What this means practically:

- **Findings**: re-verified here, line numbers below are this repo's.
- **Fixes**: the archive's fix diffs are **not portable** and are not being
  cherry-picked. `TextInjector`, `CaretContext`, `TranscriptionPipeline`,
  `AudioRecorder`, and `StreamingCoordinator` were all reworked in 0.1.27
  (`restore AX-blind space glue and PID handoff`) and 0.1.28 (`stop ghost
  streaming dictation discards`) — precisely the files most findings live in.
  Each fix must be re-derived against the current code.
- **Coverage**: the 8 live-only source files and every 0.1.21→0.1.28 diff have
  now been reviewed (see "Step-0 audit results" below). The register covers this
  tree.

Severity: **P1** user-facing defect · **P2** real gap · **P3** nit.

---

## Re-validated findings (present in this tree)

| ID | Sev | Location in this repo | Finding |
|---|---|---|---|
| F-01 | P1 | `TextInjector.swift:264,353` and `:114,322,341` | Two lanes make the HUD's clipboard flash a lie. (a) `insertViaPasteBlind` restores the prior clipboard on all three failure paths, then the pipeline maps `.failed` → `.injectionFailed` → clipboard flash — transcript not on clipboard. (b) Worse since 0.1.27: `.unverifiedFallback` correctly returns `.failed` for History, but `resolveOutcome` still reports `shouldReturnTrue: true` to the pasteboard-restore switch, so the old clipboard is restored — text may have actually landed via `postToPid` AND the HUD claims the transcript is on the clipboard while it is not. |
| F-02 | P1 | `TextInjector.swift` (`savedPasteboardString`, 10 refs) | Pasteboard snapshot reads `.string` only; restore does `clearContents()` + `setString`. Any copied image / file / RTF is destroyed by an ordinary dictation. |
| F-03 | P1 | `CloudTranscriber.swift` ×8, `TransformRunner.swift` ×1, `HTTPClient.swift:46` (`session: URLSession = .shared`) | No request/resource timeout anywhere. Defaults are 60 s / 7 days; a stalled provider pins the HUD in `.processing` with no cancel. |
| F-04 | P2 | `AppDelegate.swift:374` | Menu bar hardcodes `"Murmur v0.1"`. Actual version 0.1.28. |
| F-05 | P2 | `AppDelegate.swift:380-391` | Menu-bar menu is Open / Settings / Quit — no pause switch for an app that consumes the fn key globally, and no Check for Updates. |
| F-06 | P2 | `StreamingCoordinator.swift:339` + `ASREngineSelector.swift:268` | `handleStopWhisperKit` has no silence guard, unlike the xAI/EL stop paths. Unreachable today (`streamingEnabled = false`). **Refined here:** 0.1.28 added `shouldTakeSilenceCancel` + `StreamingSilenceBypassTests` for the ghost-dictation class; re-derive this finding against that work before acting — it may already be subsumed. |
| F-07 | P2 | `TranscriptionPipeline.swift:362` | `logStreamedTranscription` passes `audioPath: nil` and the streaming path never retains audio → History retry unavailable for the cloud default path. |
| F-13 | P2 | `RecordingRetention.swift:10` | `maxRetained = 5` count cap is what binds in normal use, while Settings presents an MB budget as the primary control. Wording problem, not a broken mechanism (a toggle-locked recording runs ~11 MB/min, so the size cap is a real long-tail guard). |
| F-14 | P2 | `HistoryStore.swift` (1 ref = declaration) | `markLastEntryNotInjected` is dead code, and matches rows by transcript text rather than `UUID`. |
| F-15b | P2 | `VoiceCommands.swift` (0 callers) | Entire file is dead. Its doc comment describes a pipeline position it does not occupy. |
| F-17 | P2 | `SettingsView.swift` (3 refs) | `hasAPIKey` / `hasCleanupKey` / `hasXAIKey` are synchronous Keychain reads called from `@ViewBuilder` bodies. |
| F-19 | P2 | `Theme.swift:106` | `reduceMotion` / `reduceTransparency` are plain computed statics — nothing observes `accessibilityDisplayOptionsDidChangeNotification`, so both need an app restart. |
| F-21 | P2 | `scripts/release.sh`, `Config/ExportOptions.plist` (absent) | `release.sh` passes `-exportOptionsPlist` for a file that does not exist, and its `CODE_SIGN_IDENTITY` guard is unreachable because the variable has a default. |
| F-22 | P2 | `scripts/make-dmg.sh` (4× `Versions/B`) | Sparkle's framework version letter is hardcoded; a minor Sparkle bump aborts the release under `set -e`. `Versions/Current` is stable. |
| F-23 | P3 | `scripts/install-local.sh` | Depends on `rg` (ripgrep) — not guaranteed on a contributor's Mac, now that the repo is public. |
| F-24 | P3 | `HistoryStore.swift:104` | Inner `catch`'s `error` shadows the `error:` parameter, so "original decode error" prints the move failure instead. |
| F-25 | P2 | `HotkeyController.swift` (3 refs) | ⌃⌥⌘T's only feedback is `NSUserNotification`, deprecated since macOS 11 against a macOS 26 target — and it shows nothing at all on failure. |
| F-26 | P2 | `HotkeyController.swift` | ⌃⌥⌘T is hardcoded, undocumented, and a `RegisterEventHotKey` failure is only logged. |
| F-27 | P2 | `TransformRunner.swift:24` | `run(prompt:over:openAIKey:)` tries on-device first unconditionally, ignoring the user's `CleanupBackend`; xAI is not a transform backend at all. |
| F-28 | P2 | `SparkleSupport.swift:25` | `static var status` runs two `SecStaticCodeCheckValidity` calls (one deep) and is read 4× on the launch path, uncached. |
| F-29 | P2 | `InsightsView.swift:31` | `dayStreak` anchors on `activeDays.max()`, so a long-dead streak still displays as live. |

Carried-over findings, now resolved by the step-0 diff review:

- **F-09/F-10** (per-injection observer tap; dedupe lock held across the whole
  insert) — confirmed present; `UnicodeDeliveryObserver.create()` per insert and
  the `dedupeLock` `defer` both survive in this tree.
- **F-11** (dark-only), **F-15** (History load stats every entry on main —
  `HistoryStore` is byte-identical to the audited version), **F-16** (no live
  permission status), **F-18** (no download-cancel button; `ModelManager.delete()`
  already cancels the task), **F-20** (no language auto-detect; Parakeet ignores
  language), **F-32** (untested pure seams), **F-33** (misc nits incl. Parakeet
  timer retention — `ParakeetEngine` byte-identical) — all confirmed present.

## Struck out — did not survive re-validation

- ~~**F-34** — "three docs wrongly claim `Voice.xcodeproj` is untracked"~~.
  **Archive-only artifact.** In this repo `git ls-files Voice.xcodeproj` returns
  nothing: the project is correctly gitignored and the docs are accurate. Acting
  on this finding here would have introduced the error it claimed to fix.
- ~~**F-08** — `postToPid` fallback reports unverified success to History~~.
  **Fixed upstream in 0.1.27.** `TextInjector.InsertResult` maps
  `.unverifiedFallback` to `.failed`, and `wasInjectedForHistory` is false for
  anything unconfirmed. (Its pasteboard-restore side effect is now part of
  F-01(b) above.) The related maintainer decision is closed.
- ~~**F-12** — secure-input race between check and injection~~. **Fixed upstream
  in 0.1.27.** `finishTranscription` now re-samples `IsSecureEventInputEnabled`
  at every TOCTOU point (pre-transform, inject gate, abort-leave, post-insert
  via `outcomeSecureAfterInsert`) with seam tests.

## Never audited — coverage gap in this repo

These exist only in this tree and have not been reviewed at all:

| File | Lines |
|---|---|
| `Sources/Voice/CorrectionWatcher.swift` | 291 |
| `Sources/Voice/LearnToastHUD.swift` | 311 |
| `Sources/Voice/SpokenCapitalization.swift` | 176 |
| `Sources/Voice/CorrectionWatcherLogic.swift` | 127 |
| `Sources/Voice/CorrectionExtractor.swift` | 99 |
| `Sources/Voice/LearnToastPresentation.swift` | 92 |
| `Sources/Voice/LearnEventsCoordinator.swift` | 76 |
| `Sources/Voice/LearnToastLayout.swift` | 20 |

Plus the diffs to 30 files changed across 0.1.21–0.1.28. An audit that claims
whole-repo coverage is not entitled to that claim until these are read.

## Step-0 audit results (2026-08-09)

**New files (8, ~1,192 lines) — read in full.** The correction-learning stack
(`CorrectionWatcher` + `Logic` + `Extractor`, `LearnEventsCoordinator`,
`LearnToastHUD` + `Presentation` + `Layout`) and `SpokenCapitalization` are
well-factored: pure logic separated from AX/CG effects, each with a dedicated
test file, no transcript text in logs, correct one-shot timer/teardown
discipline. Two findings:

- **N-01 — P3 — `CorrectionExtractor.locate` allocates per scan position.**
  `Array(fieldUTF16[start..<(start+needle.count)]) == needle` inside the scan
  loop builds a fresh array per candidate offset — O(field × needle) time *and*
  allocations, on a field capped at 32,768 UTF-16 units, on the main thread at
  `beginWatch`. A long dictation into a near-cap field can stall visibly.
  Compare slices directly (`fieldUTF16[start..<end].elementsEqual(needle)`) or
  memcmp.
- **N-02 — P3 — third CGEvent-tap pattern.** `CorrectionWatcher.installKeyTap`
  creates a listen-only session tap per watch, joining the activation tap and
  the per-insert `UnicodeDeliveryObserver` tap. Same lifecycle-cost pattern as
  F-09; if F-09 is fixed with a long-lived observer, fold this in.

**Diff review 0.1.20→0.1.28 — every changed file sized, all finding-relevant
hunks read.** Byte-identical (fix diffs port cleanly): `HotkeyController`,
`TransformRunner`, `SparkleSupport`, `ParakeetEngine`, `HTTPClient`,
`CloudTranscriber`, `HistoryStore`, `InsightsView`, `Theme`,
`MainWindowController`, `TransformsView`, and all three release scripts.
Reworked (fixes must be re-derived): `TranscriptionPipeline` (+542),
`AudioRecorder` (+550), `CaretContext` (+311), `DictionaryStore` (+203),
`DictionaryView` (+196), `StreamingCoordinator` (+97), `TextInjector` (+61),
plus small deltas in `AppDelegate`, `RecordingHUD`, `SettingsStore/View`,
`RootView`, `CorrectionsLog`, and the two streaming transcribers — all the
learn-toast / caret-snapshot / ghost-dictation work, coherent and test-backed.

## Fix pass 1 — landed 2026-08-09

Shipped: **F-01** (both lanes), **F-02**, **F-03**, **F-04**, **F-14**, **F-15b**,
**F-21**, **F-22**, **F-23**, **F-24**, **F-25/F-26 feedback**, **F-27**, **F-28**.
All re-derived against this tree — no archive diffs were transplanted.

Notes worth keeping:

- **F-01** needed two fixes, not one. The paste-blind lane now leaves the
  transcript on the clipboard on every failure path, and the pasteboard-restore
  decision is keyed on a new `InsertDeliveryPath.isConfirmedDelivery` rather than
  `resolveOutcome`'s `shouldReturnTrue` — those diverge exactly at
  `.unverifiedFallback`, which is the second lane that made the HUD lie.
- **F-25/F-26** route through `RecordingHUD` instead of `NSUserNotification`,
  which required `showClipboardFlashThenHide` to present from idle (it used to
  bail to `hide()` when no capture was in flight, making it a no-op for the
  hotkey). `RegisterEventHotKey` failure now surfaces too.
- **F-27** replaced the `openAIKeyProvider` closure with a `TransformCredentials`
  value across six wiring sites, so Transforms honor the configured
  `CleanupBackend` and xAI became usable for the first time.
- **Self-audit caught one regression of my own**: `savedPasteboardString` was
  left caller-less by F-02 — the same dead-code standard applied to F-14 — so it
  and its two tests were replaced with snapshot equivalents.

Not started: **step 5** (F-16 permission panel, F-05 pause switch). Both add new
UI surfaces and F-05 in particular needs a scope decision on what "paused" means.

## F-06 decision — KEEP the local streaming path (2026-08-09)

**Decision: do not delete.** Maintainer position: *local should be a complete
option for people, so I don't want to hinder that.*

### Why the path is disabled, verified against WhisperKit v0.18.0

The rationale in `ASREngineSelector.streamingEnabled` was written against a much
older WhisperKit. Re-checked against the resolved checkout (`v0.18.0`):

- `AudioStreamTranscriber.transcribeCurrentBuffer` still has
  `guard nextBufferSeconds > 1 else { … sleep 100ms }` (line 132). It refuses to
  decode until a full second of *new* audio has accrued.
- `stopStreamTranscription()` (line 89) only sets `isRecording = false` and stops
  the audio processor. **There is no final flush or tail re-decode.**

So the last sub-second of every utterance is never decoded. For push-to-talk,
where holds are routinely 2-5 s, that silently truncates the injected text.

### What this means for "local should be complete"

The distinction that matters, and it cuts the other way from how it sounds:

- **Local output quality is not degraded today.** The file-based path decodes the
  *complete* audio at release. It is the accurate path, and it is the one that
  runs.
- **Enabling the dead streaming path would make local worse**, not better — it
  would introduce the truncated tail into the text users actually receive.
- The real local-vs-cloud gap is **live interim text in the HUD while speaking**.
  xAI and ElevenLabs stream it; local shows none. That is a *preview* gap, not an
  accuracy gap.

### If live preview on local is wanted

Two routes, and the obvious one is a trap:

1. **Revive `AudioStreamTranscriber` for preview only** (what the original
   comment suggested). Blocked by mic ownership: `startStreamTranscription()`
   calls `audioProcessor.startRecordingLive` internally, so it becomes the sole
   mic owner and cannot run alongside `AudioRecorder`'s own tap — which the
   file-based decode needs.
2. **Periodically decode `AudioRecorder`'s existing buffers** for the preview,
   keeping the full decode at release as the authoritative text. Sidesteps both
   the 1-second guard and the mic conflict entirely, because we never hand the
   mic to WhisperKit. Cost is CPU: re-decoding a growing buffer every N seconds
   on large-v3-turbo is not free, and would likely want a smaller preview model.

Route 2 is the one worth scoping. Neither is in scope for pass 1.

## Maintainer feedback — the transform hotkey (2026-08-09)

⌃⌥⌘T is **not valued**: a four-key chord is more work than the task is worth,
so the feature goes unused in practice.

Consequences, recorded so this is not re-litigated:

- **F-26's "make it configurable" half is dropped.** Do not build a hotkey
  preference pane. If the chord is ever revisited, the useful direction is a
  *simpler trigger* (or removing the feature), not more configuration.
- The F-25 feedback fix in this pass still stands on its own merits — it removed
  a deprecated API (`NSUserNotification`, deprecated since macOS 11) and made a
  silent `RegisterEventHotKey` failure visible. That is worth keeping regardless
  of whether the hotkey itself survives.
- **The pill render stays unverified and probably always will**, because the
  only person who would press the chord has no reason to. Treat "⌃⌥⌘T shows a
  HUD pill" as code-correct and test-covered but never observed live.
- Open question for the maintainer, not for an agent to decide: keep the
  transform hotkey at all?

## Corrected order of work

0. ~~Audit the 8 unaudited files + the 0.1.21→0.1.28 diffs~~ — **done, above.**
1. **F-01, F-02** — re-derive against the current `TextInjector` +
   `TranscriptionPipeline`. The `InsertResult`/`leaveTranscriptOnClipboard`
   machinery added in 0.1.27 is the natural seam: route every `.failed` that
   reaches the clipboard-flash HUD through `leaveTranscriptOnClipboard`, and
   widen the snapshot to full pasteboard items.
2. **F-03** — ports nearly verbatim: `CloudTranscriber`, `HTTPClient`, and
   `TransformRunner` are byte-identical to the audited versions.
3. **F-04, F-24, F-14, F-15b, F-21, F-22, F-23** — small; all in byte-identical
   or trivially-drifted files.
4. **F-25/F-26 feedback, F-27, F-28** — the files are byte-identical, but the
   fixes touch callers that drifted (`AppDelegate`, `SettingsStore`,
   `RecordingHUD`) — re-wire, don't transplant.
5. **F-16, F-05** — the usability gaps.
6. Everything else (F-06 pending decision, F-07, F-09/F-10+N-02, F-11, F-13,
   F-15, F-17, F-18, F-19, F-20, F-29, F-32, F-33, N-01).

## Open decisions (maintainer)

1. ~~F-06~~ — decided: **keep**. See the F-06 section above; deleting it would
   foreclose the only route to local live-preview parity.
2. **F-11** — commit to dark-only in the README, or build light mode?
3. **F-13** — leave retention at 5 recordings, or make the MB budget govern
   (stores materially more voice audio on disk by default)?
4. ~~F-08~~ — closed: 0.1.27 already records unverified `postToPid` as
   not-injected.

## Verification pass 2 — "make sure everything works, local = cloud" (2026-08-09)

Maintainer reported unspecified issues and asked for a full works-check with
local given equal weight to cloud. Evidence gathered:

- **Cloud verified live:** last 50 history entries (through 13:03 today, on the
  0.1.28 (29) verification build) are all `cloud:elevenlabs-streaming`,
  `failed=false`, `injected=true`. One batch-fallback entry, also clean.
- **No live-app crashes.** The six 2026-08-05 `.ips` reports are XCTest *host*
  crashes (version 0.1.21, `libXCTestBundleInject` loaded) — an
  index-out-of-range in `LearnEventsCoordinatorTests` from a dev session, not
  the user's app. That test passes in the current suite.
- **App healthy:** idle CPU, ~100 MB RSS, no process holds secure input, no
  Murmur errors in 3 h of system logs. Sparkle appcast top is 0.1.28 (29) —
  identical to the install, so no surprise update will replace it.
- **Installed binary is current:** every commit after the install touched only
  docs/tests.
- **New coverage:** `testOtherDownloadedWhisperKitModelsTranscribeKnownSpeech`
  extends the local integration check to every *downloaded* model (base +
  turbo today), not just the default.

**New finding — F-35 (M): the cloud→local fallback branch is untested.**
`TranscriptionPipeline.transcribeAndLog` routes to `transcribeLocally` both
when no key is stored AND when cloud transcription *throws*
(`TranscriptionPipeline.swift:283-327`). Local is therefore the safety net for
every cloud dictation, not just the no-key install. No unit test pins either
branch, and there is no fake-engine seam to write one without a production
refactor (`ASREngineSelector.engineCache` is private, `CloudTranscriberFactory`
is static). Follow-up: add an engine seam, then a test that a failing cloud
service lands on the local engine.

## Live incident — the post-app-switch hang (2026-08-09, VOICE_DEBUG)

Maintainer repro: use another app's voice mode, return, dictate → hang.
Caught live with VOICE_DEBUG after one failed repro attempt. Two distinct
bugs, fixed in PRs #23 and #24:

1. **Mic wedge (PR #23):** a hold after the external voice session logged
   `engine.start()` success but `max RMS 0.0000 … buffers=0` — the
   long-lived AVAudioEngine held a stale device binding. Fixed with a
   config-change observer + dead-format probe + 400 ms zero-buffer
   watchdog. **Verified live**: the next occurrence logged
   `mic engine flagged stale — rebuilding before capture` and the
   dictation succeeded.
2. **Mid-hold device death + unbounded fallback load (PR #24):** the
   config change fired 2 s INTO a 33 s hold (31 s of speech lost to a
   dead device), the stream died, batch returned no transcript, and the
   cloud→local fallback parked forever inside the WhisperKit load — no
   error, no running thread, 632 MB resident, no history row. Fixed:
   mid-hold capture restart preserving captured buffers (shared
   once-per-hold budget with the watchdog), and a 120 s deadline on the
   model-load phase with vlog brackets so any future park names its
   frame. **Unverified live** — needs the next real occurrence.

Where the load parks remains unproven (tokenizer exists locally at the
default HubApi path; no open sockets at park time; no thread in WhisperKit
frames — signature of an unresumed continuation). The vlog brackets around
`WhisperKit(config)` will convict on the next occurrence.

3. **App-switch abort instrumentation (PR #25):** two long holds ended with
   `inject: left on clipboard for manual paste` — the frontmost-PID guard
   working as designed, but with no record of *which* app took focus. Both
   abort sites now log held vs. current bundle identifiers. Whether the guard
   needs a grace window is an open question pending those identities.

**Shipped as 0.1.30 (build 31)** on 2026-08-10 — published to the Sparkle feed
and verified from the published artifacts (downloaded DMG mounted: app version,
bundled release notes, Developer ID signature, notarization all confirmed; feed
head correct with 29 items, history intact).

### Inject target anchored at release (PR #27, shipped 0.1.31)

The instrumentation from PR #25 answered its own question on the next abort:

```
inject abort: frontmost changed mid-dictation —
  held=com.example.otherapp current=com.example.frontapp
```

No app self-activated. The maintainer starts a hold while switching away from
another app and continues dictating while moving across screens, so the app
frontmost at *hold start* was never the intended target — the app frontmost at
*hotkey release* is. 247 transcribed characters went to the clipboard because
the anchor was taken at the wrong moment.

`AudioRecorder.doStop` now re-anchors the session hold (PID **and** a
same-moment `CaretContext` snapshot, so caret transforms can never mix apps) to
the release-time frontmost app, behind the pure seam
`shouldRetargetSessionHoldAtRelease`. Same app at press and release, or an
unknown release identity, keeps the start-time hold — the long-verified path is
unchanged. The pre-insert TOCTOU guard is untouched and still diverts to the
clipboard when focus changes between release and insert, which is the genuine
stolen-focus case (cloud finalize stretched to 7.2 s in the logged incident).

**Shipped as 0.1.31 (build 32)** on 2026-08-10 — feed head verified with 30
items and history intact; downloaded DMG mounted and confirmed at 0.1.31 (32)
with matching bundled notes, `accepted / source=Notarized Developer ID`, and
the expected Developer ID authority. The roaming case itself is **unverified
live** — it needs a real multi-screen dictation, which logs
`inject target re-anchored at release` under `VOICE_DEBUG`.

## Process note

The archive checkout is named `Murmur`, its `CLAUDE.md` and `README` read as
current, and its git history looks active — nothing in the tree identifies it as
an archive. A one-line banner at the top of `Murmur-archive`'s `README.md` and
`CLAUDE.md` would prevent a repeat.
