# Plan 016: Stop capture and cloud streaming when secure input turns on *during* a hold

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5560a7b..HEAD -- Sources/Voice/AudioRecorder.swift Sources/Voice/StreamingCoordinator.swift Sources/Voice/TranscriptionPipeline.swift Tests/VoiceTests/SecureInputTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `5560a7b`, 2026-07-27

## Why this matters

Murmur promises that dictation stops in secure input fields (password fields,
credential prompts, `sudo` in a terminal) — plan 001 shipped that boundary.
But the guarantee is only enforced at two instants: **before** capture starts
and **after** transcription finishes. Nothing checks during the hold.

So if the user holds the push-to-talk key, starts talking, and focus moves to
a secure field mid-utterance (a credential prompt steals focus, the user tabs
into a password box while still holding), the microphone keeps recording and —
on the streaming cloud engines, which are the two selectable ones — keeps
transmitting live audio to a third-party ASR endpoint for the rest of the hold.
The finish-time check then suppresses the paste and the history row, so the
user sees the protection working, while the audio has already left the machine.
Suppressing the paste cannot un-send the audio.

After this plan, secure input detected at any point during a hold aborts the
capture immediately, tears down any streaming session, and discards buffered
audio rather than transcribing it.

## Current state

Relevant files:

- `Sources/Voice/AudioRecorder.swift` — owns the `AVAudioEngine` mic tap, the
  buffer accumulation, and the file write. Contains the *only* start-time
  secure-input check.
- `Sources/Voice/StreamingCoordinator.swift` — holds the live xAI /
  ElevenLabs streaming sessions and forwards each captured buffer to them.
- `Sources/Voice/TranscriptionPipeline.swift` — contains the finish-time
  check and the pure `secureInputOutcome` decision seam that tests exercise.
- `Tests/VoiceTests/SecureInputTests.swift` — existing tests for the pure
  finish-time seam.

There are exactly three `IsSecureEventInputEnabled()` call sites in the whole
module (verified by grep):

```
Sources/Voice/AudioRecorder.swift:69          — start-time gate
Sources/Voice/TranscriptionPipeline.swift:217 — finish-time gate
Sources/Voice/TextInjector.swift:46           — injection-time gate
```

Start-time gate, `Sources/Voice/AudioRecorder.swift:68-75`:

```swift
    func startRecording() {
        if IsSecureEventInputEnabled() {
            logger.info("Secure input active — refusing to start capture.")
            DispatchQueue.main.async { [weak self] in
                self?.asrSelector.onFailure?(.secureInputBlocked)
            }
            return
        }
```

The mic tap callback, `Sources/Voice/AudioRecorder.swift:202-214` — runs on the
realtime audio thread for every buffer, with **no** secure-input check:

```swift
                    self.pcmBuffersLock.lock()
                    self.pcmBuffers.append(copy)
                    self.pcmBuffersLock.unlock()
                }

                // Streaming mode: ALSO convert + stream this buffer to the
                // socket (the session consumes it synchronously). Only one of
                // xAI/ElevenLabs is ever active (both gated on the same
                // single-value `cloudModel` selection), so both sends are
                // safe no-ops when their session is nil.
                self.streamingCoordinator.sendToXAI(buffer)
                self.streamingCoordinator.sendToElevenLabs(buffer)
            }
```

Finish-time gate, `Sources/Voice/TranscriptionPipeline.swift:217-225`:

```swift
            let secureInput = IsSecureEventInputEnabled()
            let injected = secureInput ? false : TextInjector().insert(expanded)
            let outcome = Self.secureInputOutcome(secureInput: secureInput, injected: injected)
            if outcome.shouldLog {
                self.onTranscriptionLogged?(expanded, engineID, injected, nil, false)
            }
            if let failure = outcome.failure {
                self.onFailure?(failure)
            }
```

**Conventions to match:**

- Failure signalling is always `asrSelector.onFailure?(<DictationFailure case>)`
  dispatched on main — see `AudioRecorder.swift:71-73` above. The case you want
  already exists: `.secureInputBlocked` in `Sources/Voice/DictationFailure.swift`.
- Testability convention: because `IsSecureEventInputEnabled` is a Carbon
  function that cannot be forced on in a unit test, this repo extracts the
  *decision* into a pure static function and tests that. See the exemplar at
  `Sources/Voice/TranscriptionPipeline.swift:231-234`:

```swift
    /// Pure decision seam for the secure-input / history-logging outcome at
    /// finish time — extracted so it can be exercised in unit tests, since
    /// `IsSecureEventInputEnabled` (Carbon) cannot be forced on in a test.
```

  Follow exactly this pattern: the new abort logic goes in a pure static
  function that takes the secure-input boolean as a parameter, and the
  impure call site just feeds it the real value.
- Comments explain *why* (constraints), not what the code does. Match the
  density of the excerpts above.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Regenerate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **`, 0 failures |

Run from the Murmur repo root. You only need
`xcodegen generate` if you add or remove a **file**; editing existing files
does not require it. Note the test suite currently contains 113 tests — expect
that number to grow by the tests you add, and never to shrink.

## Scope

**In scope**:
- `Sources/Voice/AudioRecorder.swift`
- `Sources/Voice/StreamingCoordinator.swift`
- `Tests/VoiceTests/SecureInputTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- `Sources/Voice/TextInjector.swift` — its injection-time gate is correct and
  is defense in depth; leave it.
- `Sources/Voice/TranscriptionPipeline.swift` — the finish-time gate stays
  exactly as it is. This plan *adds* a mid-hold gate; it does not replace or
  relocate the existing ones.
- `Sources/Voice/XAIStreamingTranscriber.swift` and
  `Sources/Voice/ElevenLabsRealtimeTranscriber.swift` — their internal
  teardown is being changed by plan 017. Call their existing public
  `cancel()`; do not edit their internals here.
- Anything to do with the activation key or `ActivationController`.

## Git workflow

- Branch: `fix/secure-input-mid-hold`
- Conventional commits, matching this repo's log — e.g.
  `fix: abort capture when secure input activates mid-hold`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a pure decision seam for the mid-hold check

In `Sources/Voice/AudioRecorder.swift`, add a static function next to the
existing recording helpers:

```swift
    /// Pure decision seam for the mid-hold secure-input abort — extracted so
    /// it can be exercised in unit tests, since `IsSecureEventInputEnabled`
    /// (Carbon) cannot be forced on in a test.
    ///
    /// Returns true when an in-flight capture must be aborted: secure input
    /// became active while we were already recording.
    static func shouldAbortForSecureInput(secureInput: Bool, isRecording: Bool) -> Bool {
        secureInput && isRecording
    }
```

**Verify**: `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO`
→ `** BUILD SUCCEEDED **`

### Step 2: Add an abort path that tears down capture and streaming

Still in `AudioRecorder.swift`, add a private method that performs the abort.
It must, in this order:

1. Stop the audio engine and remove the tap (reuse whatever the existing stop
   path uses to tear the engine down — find it by reading the existing
   `doStop()` / `stopFileBasedCapture()` implementations in this file and
   reuse those helpers rather than duplicating engine teardown).
2. Discard accumulated audio: clear `pcmBuffers` under `pcmBuffersLock`.
3. Cancel any live streaming session via the coordinator (Step 3 adds that
   method).
4. Hide the HUD (`hud.hide()`) and report `asrSelector.onFailure?(.secureInputBlocked)`
   on main, matching the pattern at `AudioRecorder.swift:71-73`.

It must **not** call `writeToFile`, must **not** call
`asrSelector.transcribeAndLog`, and must **not** retain the recording via
`RecordingRetention` — the whole point is that this audio goes nowhere.

**Verify**: build succeeds, and
`grep -n "writeToFile\|transcribeAndLog\|RecordingRetention" Sources/Voice/AudioRecorder.swift`
shows none of those called from inside your new abort method.

### Step 3: Give StreamingCoordinator a cancel-all entry point

In `Sources/Voice/StreamingCoordinator.swift`, add a method that cancels and
clears whichever session is live. The existing session properties are:

```swift
    private(set) var xaiSession: XAIStreamingTranscriber?
    private(set) var elevenLabsSession: ElevenLabsRealtimeTranscriber?
```

(`StreamingCoordinator.swift:17` and `:23`.) Add:

```swift
    /// Aborts any in-flight streaming session and drops the reference without
    /// waiting for a final transcript — used when the capture is abandoned
    /// (secure input activated mid-hold) and the audio must not be used.
    func cancelAll() {
        xaiSession?.cancel()
        xaiSession = nil
        elevenLabsSession?.cancel()
        elevenLabsSession = nil
    }
```

Both transcriber types already expose `cancel()`. Do not change their
internals. Set the properties to `nil` on main (this method is called from
main via Step 4's dispatch).

**Verify**: build succeeds.

### Step 4: Wire the check into the capture path

Call the check periodically while recording. Do **not** call
`IsSecureEventInputEnabled()` inside the audio-tap callback itself — that
callback runs on the realtime audio thread where a Carbon call is not
appropriate.

Instead, start a repeating timer when capture starts and invalidate it when
capture stops. A `DispatchSourceTimer` on main (or a `Timer` scheduled on the
main run loop) firing every **0.25 s** is the target: fast enough that at most
a quarter second of audio can escape, cheap enough to be invisible.

On each fire:

```swift
if Self.shouldAbortForSecureInput(
    secureInput: IsSecureEventInputEnabled(),
    isRecording: <the recorder's in-flight flag>
) {
    <call the Step 2 abort method>
}
```

Use the existing recording-state flag in this file (read the file to find it
by symbol — e.g. `wantsRecording` / `isStopping`; **do not trust stale line
numbers** from the `5560a7b` excerpts above). Confirm which flag reflects
"engine is actually running" and use that one.

**Timer invalidation (HARD — `isStopping` SSOT):** invalidate the mid-hold
timer on **every** stop/abort path, including paths that set or clear
`isStopping` (inject-branch abort/stop), not only the happy `doStop` path —
so the timer never outlives a capture or fires after abort has begun.

**Verify**: build succeeds; `xcodebuild test …` → `** TEST SUCCEEDED **`, 0
failures, and no test count regression.

### Step 5: Manual smoke test (report the result; do not skip)

This one cannot be unit-tested, because secure input cannot be forced on from
a test process. Run the app with debug logging:

```bash
VOICE_DEBUG=1 /Applications/Murmur.app/Contents/MacOS/Murmur
```

(If `/Applications/Murmur.app` is not installed, build and run the Debug
product instead — see CLAUDE.md.) Then:

1. Open Terminal and run a command that prompts for a password (`sudo -v`) so
   secure input is active. Confirm holding the push-to-talk key does nothing
   and the failure is reported — this is the pre-existing start-time gate.
2. Start a dictation in a normal text field, and **while still holding**,
   click into the password prompt. Expected: recording stops within ~0.25 s,
   the HUD disappears, and no text is injected or logged.
3. Grep the abort in the **current** debug log path from `CLAUDE.md` /
   `NSTemporaryDirectory()` (after plan 020: typically
   `$(getconf DARWIN_USER_TEMP_DIR)voice-debug.log`):
   `grep -i secure "$(getconf DARWIN_USER_TEMP_DIR)voice-debug.log"`

Report what you observed. If step 2 does not abort, that is a STOP condition.

## Test plan

New tests in `Tests/VoiceTests/SecureInputTests.swift` (model them on the
existing tests in that file, which exercise
`TranscriptionPipeline.secureInputOutcome` the same way):

- `testShouldAbortWhenSecureInputActivatesWhileRecording` — `(secureInput: true,
  isRecording: true)` → `true`.
- `testShouldNotAbortWhenNotRecording` — `(true, false)` → `false` (a secure
  field focused while idle must not fire a spurious failure).
- `testShouldNotAbortWhenSecureInputInactive` — `(false, true)` → `false`.

Verification: `xcodebuild test -scheme VoiceTests -destination 'platform=macOS'
CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, 3 new tests passing,
total count ≥ 116.

## Done criteria

ALL must hold:

- [ ] `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, 0 failures, total ≥ 116
- [ ] `grep -c "IsSecureEventInputEnabled" Sources/Voice/*.swift` shows a new call site in `AudioRecorder.swift` (4 total across the module, up from 3)
- [ ] `StreamingCoordinator.cancelAll()` exists and is called from the abort path
- [ ] Step 5 manual smoke test performed and its result reported
- [ ] `git status` shows only the three in-scope files modified
- [ ] `plans/README.md` status row for 016 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift).
- The 0.25 s timer causes any audible glitch, dropout, or HUD flicker in the
  manual smoke test — the fix must be invisible during normal dictation.
- Aborting mid-stream causes a hang or crash in the transcriber teardown —
  that is plan 017's territory; report it rather than editing the transcribers.
- You conclude the check must live inside the audio-tap callback to be
  correct. Report that finding instead of doing it; a Carbon call on the
  realtime audio thread needs a human decision.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- There are now three secure-input gates (start, mid-hold, finish) plus the
  injection-time one in `TextInjector`. They are deliberately redundant; a
  future refactor that "consolidates" them into one check will reopen this
  hole. Any such consolidation must preserve a check that runs *during* the
  capture window.
- The 0.25 s interval is a latency/cost tradeoff. If it ever shows up in
  profiling, the alternative is subscribing to a focus-change notification
  rather than polling — more precise, but secure-input transitions do not map
  cleanly onto a public notification, which is why polling was chosen.
- A reviewer should scrutinize: that the timer is invalidated on every
  stop/abort path **including `isStopping` paths** (leak/spurious-fire risk),
  and that the abort path really does discard buffers rather than falling
  through to the file-write path. Re-find stop helpers by symbol after the
  inject branch lands — line refs in this plan may be stale.
- Deferred out of scope: the same mid-hold class of check for the *local*
  engines (WhisperKit/Parakeet). Local transcription never leaves the machine,
  so the leak is far less severe, but the paste-suppression story is identical.
