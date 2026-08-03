# Plan 018: Get disk I/O off the main thread on the dictation hot path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5560a7b..HEAD -- Sources/Voice/AudioRecorder.swift Sources/Voice/RecordingRetention.swift Sources/Voice/UI/HistoryStore.swift Sources/Voice/UI/DictionaryStore.swift Sources/Voice/UI/SnippetsStore.swift Sources/Voice/UI/TransformsStore.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (but see the note about plan 016 under Scope)
- **Category**: perf
- **Planned at**: commit `5560a7b`, 2026-07-27

## Why this matters

Every time the user releases the push-to-talk key, Murmur does synchronous
disk work on the main thread: it concatenates every captured audio buffer,
writes a `.caf` file, then copies that file into Application Support and
lists+sorts the retention directory to prune it. Only after all of that does
transcription start.

This is the worst possible thread for it. `ActivationController` registers its
CGEvent tap source on the **main** run loop, so a slow disk does not merely
add latency to the dictation — it stalls delivery of the push-to-talk key
events themselves, and the controller already has to handle macOS disabling
the tap on timeout (`tapDisabledByTimeout`). On a spinning disk, a network
volume, or under memory pressure, this is a self-inflicted input-latency
spike at the exact moment the user expects instant text.

The same pattern repeats one layer up: four persistence stores rewrite their
entire JSON file synchronously on the main thread on *every* mutation. The
dictionary store does it on every auto-learned correction, i.e. during active
dictation.

After this plan, the audio write and the retention copy happen off-main, and
the sibling stores debounce their writes the way `ScratchpadStore` already
does.

## Current state

Relevant files:

- `Sources/Voice/AudioRecorder.swift` — `writeToFile(duration:buffers:)` at
  lines 405–476 does the concatenation, the file write, and the retention call.
- `Sources/Voice/RecordingRetention.swift` — `retain(from:)` and
  `pruneOldRecordings()`, both synchronous `FileManager` work.
- `Sources/Voice/UI/HistoryStore.swift` — `save()` at lines 90–95.
- `Sources/Voice/UI/ScratchpadStore.swift` — **the exemplar**: the one store
  that already debounces.
- `Sources/Voice/UI/DictionaryStore.swift`, `SnippetsStore.swift`,
  `TransformsStore.swift` — undebounced siblings.

`writeToFile` today, `AudioRecorder.swift:436-468` (abridged — read the whole
function before editing):

```swift
        // Write to /tmp
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).caf")

        do {
            let file = try AVAudioFile(
                forWriting: tmpURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: combined)
            …
            // Copy into Application Support before transcription so failure
            // history rows and retry always reference a stable path — the
            // ephemeral /tmp file is removed in the completion handler.
            guard let retainedURL = RecordingRetention.retain(from: tmpURL) else {
                logger.error("Failed to retain recording for transcription.")
                try? FileManager.default.removeItem(at: tmpURL)
                DispatchQueue.main.async { [weak self] in
                    self?.asrSelector.onFailure?(.audioWriteFailed)
                    self?.hud.hide()
                }
                return
            }
            self.asrSelector.setLastRetainedRecordingURL(retainedURL)

            self.asrSelector.transcribeAndLog(audioURL: retainedURL) { [weak self] in
                try? FileManager.default.removeItem(at: tmpURL)
                self?.hud.hide()
            }
        } catch {
```

**The ordering in that excerpt is load-bearing and must be preserved**: the
retained URL is set *before* `transcribeAndLog` is called, because failure
history rows and the History view's Retry button reference that stable path;
and the `/tmp` file is removed only in the completion handler, after
transcription has consumed it.

`HistoryStore.save()`, `Sources/Voice/UI/HistoryStore.swift:90-95`:

```swift
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
```

**The debounce exemplar to copy**, `Sources/Voice/UI/ScratchpadStore.swift:93-100`:

```swift
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
```

And the main-thread-hop idiom used throughout the stores, e.g.
`ScratchpadStore.swift:90`:

```swift
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
```

**Conventions to match:**

- `@Published`/observable state mutation stays on main — SwiftUI requires it.
  Only the *file write* moves off main. Do not move the `entries` mutation.
- Writes use `options: .atomic` — keep that; it is what makes a crash mid-write
  non-corrupting.
- Failure signalling is `asrSelector.onFailure?(<case>)` dispatched on main.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **`, 0 failures |
| Regenerate project (only if adding/removing files) | `xcodegen generate` | exit 0 |

Run from the Murmur repo root. Suite is 113 tests at plan time.

## Scope

**In scope**:
- `Sources/Voice/AudioRecorder.swift` — `writeToFile` only
- `Sources/Voice/UI/HistoryStore.swift`
- `Sources/Voice/UI/DictionaryStore.swift`
- `Sources/Voice/UI/SnippetsStore.swift`
- `Sources/Voice/UI/TransformsStore.swift`
- `Tests/VoiceTests/` — new store round-trip tests (new file allowed; if you
  add one, run `xcodegen generate`)

**Out of scope** (do NOT touch, even though they look related):
- `Sources/Voice/RecordingRetention.swift` itself — call it from a background
  context; do not restructure it.
- `Sources/Voice/UI/ScratchpadStore.swift` — it is already correct and is your
  reference. Leave it alone.
- The mic tap callback and `doStop()`/`stopFileBasedCapture()` control flow in
  `AudioRecorder.swift`. **If plan 016 has already landed, it added an abort
  path and a timer to this file — do not disturb them.**
- `Sources/Voice/UI/SettingsStore.swift` — settings writes are rare and
  user-initiated; debouncing them adds risk (a settings change lost on quit)
  for no measurable gain.
- Any change to the on-disk JSON schemas.

## Git workflow

- Branch: `perf/main-thread-io`
- Conventional commits, e.g. `perf: move audio write and retention off main`.
  Keep the `writeToFile` change and the store-debounce change in separate
  commits.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Move the audio write and retention copy off main

Restructure `writeToFile(duration:buffers:)` so that the buffer
concatenation, the `AVAudioFile` write, and the `RecordingRetention.retain`
call all run on a background queue (a `DispatchQueue(label:qos: .userInitiated)`
owned by `AudioRecorder`, or `Task.detached` — either is fine; pick one and be
consistent), then hop back to main for everything that touches app state.

Everything below must still happen on **main**, in this order:

1. `asrSelector.setLastRetainedRecordingURL(retainedURL)`
2. `asrSelector.transcribeAndLog(audioURL: retainedURL) { … }`
3. inside the completion handler: remove the `/tmp` file, `hud.hide()`

The failure branches (`nil` from `retain`, and the `catch`) must also hop to
main before calling `onFailure?` / `hud.hide()`, exactly as they do today.

Use `.userInitiated` QoS — this is on the user-visible latency path, not
background housekeeping.

**Verify**: `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO`
→ `** BUILD SUCCEEDED **`; `xcodebuild test …` → `** TEST SUCCEEDED **`.

### Step 2: Manual smoke test of the dictation path (report the result)

A green build does not prove the ordering survived. Run the app:

```bash
VOICE_DEBUG=1 /Applications/Murmur.app/Contents/MacOS/Murmur
```

(Or the Debug build product — see CLAUDE.md.) Then do **three** dictations:
one short (~2 s), one longer (~15 s), and one where you release and
immediately start another. Confirm for each: text is injected, a history row
appears, and no duplicate or missing entries. Then confirm retention still
works — `ls ~/Library/Application\ Support/Voice/Recordings/` shows at most
5 `.caf` files and includes the newest dictation.

Report what you observed. Missing history rows or a retention directory that
grows past 5 is a STOP condition.

### Step 3: Debounce the sibling stores

Give `HistoryStore`, `DictionaryStore`, `SnippetsStore`, and `TransformsStore`
the same debounced-save treatment `ScratchpadStore` has: add a
`saveWorkItem: DispatchWorkItem?` property and a `scheduleSave()` method
copied from the exemplar at `ScratchpadStore.swift:93-100`, and replace the
direct `save()` calls in mutation methods with `scheduleSave()`.

Two hard requirements:

- **A pending save must be flushed on app termination**, or the user loses the
  last second of changes on quit. Add a public `flush()` to each store that
  cancels the pending work item and calls `save()` synchronously, and call it
  from the app-termination hook in `Sources/Voice/AppDelegate.swift`
  (`applicationWillTerminate` — read the file to find or add it). **Note: this
  is the one edit outside the in-scope list that this plan authorizes, and it
  is limited to adding flush calls.**
- **`HistoryStore.append` keeps its immediate `save()`** — history rows are the
  record of a completed dictation and a 1 s window where a crash loses the
  entry the user just spoke is a worse trade than the write cost. Debounce
  only `updateText`, `delete`, and `markLastEntryNotInjected`.

**Verify**: build + tests green;
`grep -n "scheduleSave\|func flush" Sources/Voice/UI/*Store.swift` shows the
new methods on all four stores plus the pre-existing `ScratchpadStore` one.

### Step 4: Confirm the debounce didn't break persistence

**Verify** via the new tests from the Test plan below, then manually: make a
dictionary correction in the app, quit via Cmd-Q, relaunch, and confirm the
correction survived. Report the result.

## Test plan

New tests — create `Tests/VoiceTests/StorePersistenceTests.swift`. Model it on
`Tests/VoiceTests/DictionaryLearnTests.swift`, which is the existing exemplar
for store testing: it injects a temp-directory `fileURL:` so the test never
touches the real store.

> **Repo rule, non-negotiable**: a test must NEVER construct a store with its
> default (production) `fileURL`, and never use the production Keychain
> service. `~/Library/Application Support/Voice/` is live user data. A test
> suite in this repo once destroyed the user's real API key by using a
> production service name. Always inject a
> `FileManager.default.temporaryDirectory` path and clean up in `tearDown`.

Cases, for each of `HistoryStore`, `SnippetsStore`, `TransformsStore`,
`DictionaryStore`:

- Round trip: mutate, `flush()`, construct a second store on the same temp
  file, assert the data is there.
- Debounce actually defers: mutate, assert the file does not yet exist (or is
  unchanged), then `flush()` and assert it does.
- Corrupt file: write garbage bytes to the temp path, construct the store,
  assert it loads empty rather than crashing.
- `HistoryStore` only: the 1000-entry cap holds after appending 1001 entries.

Verification: `xcodebuild test -scheme VoiceTests -destination 'platform=macOS'
CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, total ≥ 126.

## Done criteria

ALL must hold:

- [ ] `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, 0 failures, total ≥ 126
- [ ] `AVAudioFile(forWriting:)`, `file.write(from:)`, and `RecordingRetention.retain` no longer execute on the main thread (confirm by reading the restructured `writeToFile`)
- [ ] `asrSelector.setLastRetainedRecordingURL` still precedes `transcribeAndLog`, and `/tmp` cleanup still happens in the completion handler
- [ ] All four stores have `scheduleSave()` + `flush()`, and `flush()` is called on app termination
- [ ] `HistoryStore.append` still saves immediately
- [ ] Steps 2 and 4 manual checks performed and reported
- [ ] `git status` shows only in-scope files plus `AppDelegate.swift` (flush calls only)
- [ ] `plans/README.md` status row for 018 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift).
- Any dictation in Step 2 produces no text, no history row, or a duplicate row.
- The retention directory grows past 5 files, or the History Retry button
  stops finding its audio (that means the retained-URL ordering broke).
- You find that `transcribeAndLog` or `setLastRetainedRecordingURL` is not
  main-thread-safe to call the way this plan assumes — report it rather than
  redesigning the threading of `ASREngineSelector`.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- The debounce interval (1 s, copied from `ScratchpadStore`) is now a
  repeated magic number across five stores. If a sixth store appears, extract
  a shared `DebouncedFileStore` base or protocol rather than copying it a
  sixth time — the duplication is tolerable at five, not at six.
- The `Thread.isMainThread ? mutate() : DispatchQueue.main.async(...)` idiom is
  copy-pasted roughly 15 times across the stores. Consolidating it is a
  separate, purely mechanical cleanup; deliberately not bundled here to keep
  this diff reviewable.
- A reviewer should scrutinize: the ordering guarantees in `writeToFile`
  (retained URL before transcription, `/tmp` cleanup after), and that no
  `@Published` mutation moved off main.
- Deferred: `SettingsStore` debouncing (out of scope above), and moving the
  *transcription* dispatch itself off main, which is a bigger architectural
  question.
