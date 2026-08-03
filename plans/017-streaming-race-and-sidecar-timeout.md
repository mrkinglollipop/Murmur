# Plan 017: Close the streaming-continuation data race and bound the Parakeet sidecar

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5560a7b..HEAD -- Sources/Voice/XAIStreamingTranscriber.swift Sources/Voice/ElevenLabsRealtimeTranscriber.swift Sources/Voice/ParakeetEngine.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `5560a7b`, 2026-07-27

## Why this matters

Two independent defects, bundled because both are "a dictation silently
disappears" bugs on the transcription path.

**A — the streaming continuation race.** Both cloud streaming transcribers
guard their shared state with an `NSLock` (`stateLock`) — except
`frameContinuation`, which is read from the realtime audio thread on every
captured buffer and finished-and-nilled from `finalize()`/`cancel()` with no
lock at all. At the exact moment the user releases the push-to-talk key, the
last in-flight buffer can read a continuation that is concurrently being
finished. That drops the final chunk of audio — the precise tail truncation
the surrounding code's own comments say the `await senderTask?.value` dance
exists to prevent. It is also a genuine Swift data race (unsynchronized
read/write of a non-atomic property across threads), so it can misbehave in
ways worse than a dropped buffer under a future compiler or runtime.

**B — the unbounded Parakeet sidecar.** The Python sidecar is bridged into a
`CheckedContinuation` that is resumed only from `terminationHandler`. If the
sidecar hangs — bad Python env, a stalled model-cache fetch, an MLX hang —
the continuation never resumes: the dictation's `Task` suspends forever, the
HUD stays on "processing," and no failure is ever reported. The user's only
recovery is force-quitting the app. Every other async transcription path in
this module already races against a timeout; this one does not.

After this plan, the last buffer of every streaming dictation is delivered
under a lock, and a hung sidecar fails cleanly with a reported error instead of
wedging the app.

## Current state

Relevant files:

- `Sources/Voice/XAIStreamingTranscriber.swift` (1171 lines) — xAI Grok
  streaming WebSocket transcriber.
- `Sources/Voice/ElevenLabsRealtimeTranscriber.swift` (656 lines) — ElevenLabs
  Scribe v2 Realtime WebSocket transcriber. Structurally parallel to the xAI
  one; the same fix applies to both.
- `Sources/Voice/ParakeetEngine.swift` — spawns the bundled
  `parakeet_transcribe.py` sidecar via `Process`.

**The unlocked read**, `XAIStreamingTranscriber.swift:250-261` — note the
doc comment already asserts the safety property that the code does not
actually enforce:

```swift
    /// Converts one captured buffer to 16kHz mono PCM16 and enqueues it for
    /// sending. Called from the realtime audio-tap thread — returns quickly
    /// and never blocks on the network. No-op until started and before
    /// finalize/cancel (frameContinuation is nil/finished in those states).
    func send(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = frameContinuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            vlog("xai-stream: send — conversion produced no data, dropping buffer")
            return
        }
        continuation.yield(pcmData)
    }
```

The ElevenLabs twin, `ElevenLabsRealtimeTranscriber.swift:211-218`, is the
same shape:

```swift
    func send(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = frameContinuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            vlog("elevenlabs-stream: send — conversion produced no data, dropping buffer")
            return
        }
        continuation.yield(Self.makeInputAudioChunkFrame(pcmData: pcmData, commit: false))
    }
```

**The unlocked write**, `XAIStreamingTranscriber.swift:267-285` — observe that
`stateLock` is taken for `tornDown` and released at `:275`, and then
`frameContinuation` is mutated at `:282-283` *outside* it:

```swift
    func finalize(recordingDuration: TimeInterval = 0) async -> String {
        stateLock.lock()
        if tornDown {
            let text = Self.postProcessTranscript(mergeConfirmedWithInterim())
            stateLock.unlock()
            return text
        }
        tornDown = true
        stateLock.unlock()
        let finalizeStart = Date()

        // Stop accepting new frames, then WAIT for the sender to flush every
        // already-captured frame before signalling end-of-audio — otherwise
        // `audio.done` (sent directly on the task) could overtake the last
        // buffered audio frames and truncate the tail of the utterance.
        frameContinuation?.finish()
        frameContinuation = nil
        await senderTask?.value
        senderTask = nil
```

`ElevenLabsRealtimeTranscriber.swift:224-241` is the same pattern. Each class
also has a `cancel()` that mutates `frameContinuation` the same way — find it
by reading each file; both must be fixed too.

**The `tornDown` flag is the exemplar to copy.** It was made race-safe by an
earlier plan and is correct today: test-and-set under `stateLock`, seen at
`XAIStreamingTranscriber.swift:268-275` above. Match that discipline.

**The unbounded sidecar**, `ParakeetEngine.swift:46-49` and `:89` — the
continuation has exactly one resume path (plus the `process.run()` throw):

```swift
    private func runSidecar(scriptURL: URL, audioURL: URL) async throws -> String {
        logger.info("Parakeet: launching sidecar \(scriptURL.lastPathComponent) for \(audioURL.lastPathComponent)")

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            …
            process.terminationHandler = { proc in
```

Note the existing comments in that file (`:59-65`, `:85-88`) document two
hazards already handled — pipe-buffer deadlock and a weak-self non-resume.
Your timeout must not reintroduce either, and must not double-resume the
checked continuation (that traps at runtime).

**Conventions to match:**

- Shared mutable state in the transcribers is guarded by `stateLock` with
  explicit `lock()`/`unlock()` pairs, never `objc_sync` or a queue. Keep
  critical sections tiny — take the lock, read/swap the value, unlock, and do
  the work (like `yield`) outside it.
- Timeouts elsewhere in this module use `withThrowingTaskGroup` racing the
  real work against `Task.sleep`. Read how `finalize()` in either transcriber
  bounds its wait for the final transcript and mirror that shape.
- Errors surface as thrown Swift errors from the engine layer; the pipeline
  turns them into a `DictationFailure`. Do not invent a new failure
  presentation.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **`, 0 failures |
| Regenerate project (only if adding/removing files) | `xcodegen generate` | exit 0 |

Run from the Murmur repo root. The suite is 113 tests at plan
time; it must never shrink.

## Scope

**In scope**:
- `Sources/Voice/XAIStreamingTranscriber.swift` — only `send`, `finalize`,
  `cancel`, and the `frameContinuation` declaration.
- `Sources/Voice/ElevenLabsRealtimeTranscriber.swift` — same four places.
- `Sources/Voice/ParakeetEngine.swift`
- `Tests/VoiceTests/ElevenLabsRealtimeTests.swift` (add tests)

**Out of scope** (do NOT touch, even though they look related):
- The stitch/dedupe/post-processing block in `XAIStreamingTranscriber.swift`
  (roughly lines 653–1171). Extracting it is separately planned and depends on
  the fixture harness in `plans/002-stitch-fixture-harness.md`. Touching it
  here risks the transcript-quality logic with no fixture net.
- `Sources/Voice/StreamingCoordinator.swift` — its session properties are
  also read from the audio thread, but plan 016 is editing that file. Leave it;
  a follow-up is noted in Maintenance notes.
- `Sources/Voice/AudioRecorder.swift` — the tap callback stays as it is.
- Any change to the WebSocket protocol, endpoints, model names, or params.

## Git workflow

- Branch: `fix/streaming-continuation-race`
- Conventional commits, e.g. `fix: guard frameContinuation under stateLock`
  and `fix: bound Parakeet sidecar with a timeout`. One commit per part is
  fine; keep A and B in separate commits.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Guard `frameContinuation` in the xAI transcriber

In `XAIStreamingTranscriber.swift`:

- In `send(_:)`, take `stateLock` to read `frameContinuation` into a local,
  unlock, then `yield` **outside** the lock. The `convertToPCM16` call must
  also stay outside the lock — it is the expensive part and must not block
  teardown. Target shape:

```swift
    func send(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let continuation = frameContinuation
        stateLock.unlock()
        guard let continuation else { return }
        guard let pcmData = convertToPCM16(buffer) else {
            vlog("xai-stream: send — conversion produced no data, dropping buffer")
            return
        }
        continuation.yield(pcmData)
    }
```

- In `finalize(recordingDuration:)`, replace the unlocked
  `frameContinuation?.finish(); frameContinuation = nil` pair with a
  take-under-lock-then-finish-outside sequence: lock, copy the continuation to
  a local and set the property to `nil`, unlock, then call `finish()` on the
  local. Keep the existing `await senderTask?.value` ordering exactly as it is —
  that ordering is what prevents tail truncation and must not change.
- Do the same in `cancel()`.

Yielding to an already-finished continuation is safe (it is a no-op), so a
buffer that wins the race harmlessly does nothing instead of racing a
half-nilled property.

**Verify**: `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO`
→ `** BUILD SUCCEEDED **`, then
`xcodebuild test …` → `** TEST SUCCEEDED **` (the existing
`StitchDedupeTests` / `GoldenTranscriptTests` are your regression net here).

### Step 2: Apply the identical fix to the ElevenLabs transcriber

Repeat Step 1 in `ElevenLabsRealtimeTranscriber.swift` for `send(_:)`,
`finalize(recordingDuration:)`, and `cancel()`. The only difference is that
`send` yields `Self.makeInputAudioChunkFrame(pcmData: pcmData, commit: false)`
rather than raw `pcmData` — keep that call outside the lock too.

**Verify**: build + tests as above.

### Step 3: Confirm no unlocked access remains

**Verify**: `grep -n "frameContinuation" Sources/Voice/XAIStreamingTranscriber.swift Sources/Voice/ElevenLabsRealtimeTranscriber.swift`
→ every read/write site is immediately adjacent to a `stateLock.lock()` /
`stateLock.unlock()` pair. Read the output and confirm site by site; there
should be no bare `frameContinuation` access outside a critical section other
than the local variable you introduced.

### Step 4: Bound the Parakeet sidecar with a timeout

In `ParakeetEngine.swift`, wrap `runSidecar` so it races against a timeout.
Requirements:

- Timeout of **120 seconds** (generous: it must never fire for a legitimate
  long dictation on a cold model cache — this is a wedge-breaker, not a
  latency guard).
- On timeout: call `process.terminate()`, tear down both `readabilityHandler`s,
  and fail with a thrown error. Reuse the existing error type this function
  already throws — read the file and use the same one rather than adding a case.
- The checked continuation must be resumed **exactly once**. Guard the resume
  with a flag under the existing `bufferLock` (or a dedicated `NSLock`) so the
  timeout path and `terminationHandler` cannot both resume. A double resume
  traps at runtime — this is the single highest-risk part of this plan.
- Do not reintroduce the pipe-buffer deadlock: the incremental
  `readabilityHandler` draining at `ParakeetEngine.swift:70-83` must remain.

**Verify**: build succeeds; `xcodebuild test …` → `** TEST SUCCEEDED **`.

### Step 5: Manual sanity check of the sidecar path (report the result)

Only if `parakeet-mlx` is installed on this machine (check with
`python3 -c "import parakeet_mlx"`). If it is not installed, skip this step and
say so in your report — do not install anything.

If it is available: select the Parakeet local model in Settings, do one short
dictation, and confirm it still transcribes normally (i.e. the timeout wrapper
did not break the happy path). Report what you observed.

## Test plan

The continuation race cannot be deterministically unit-tested (it needs two
real threads hitting a microsecond window), so the tests here assert the
*invariants* the fix creates rather than the race itself.

New tests in `Tests/VoiceTests/ElevenLabsRealtimeTests.swift` — model them on
the existing tests in that file:

- `testSendAfterCancelIsSafeNoOp` — construct a transcriber, `cancel()` it,
  then call `send(_:)` with a small synthetic `AVAudioPCMBuffer`. Assert it
  returns without crashing and without yielding. (Build the buffer the way the
  existing tests in this file build their fixtures; if none does, allocate a
  1-frame `AVAudioPCMBuffer` with a standard 16 kHz mono format.)
- `testRepeatedFinalizeIsIdempotent` — call `finalize()` twice, assert the
  second returns the same text and does not trap.

Also fix the existing assertion-free test while you are in this file:
`testRepeatedCancelIsIdempotent` at `ElevenLabsRealtimeTests.swift:137-144`
currently calls `cancel()` three times with zero `XCTAssert` calls ("reaching
here is the assertion"). Give it a real assertion on observable post-cancel
state, or — if no state is observable without widening the type's API —
rename it to `testRepeatedCancelDoesNotCrash` so its smoke-test nature is
honest. Do not widen the public API just to satisfy this.

Verification: `xcodebuild test -scheme VoiceTests -destination 'platform=macOS'
CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, ≥ 2 new tests.

**Cumulative floor (HARD):** if plan 016 has already landed (≥116), Done
requires total ≥ **118** (prior+2). Do **not** use ≥115 after 016 — that
false-passes. If 017 somehow lands before 016, ≥115 is the absolute floor
only until 016 merges; after 016+017 the suite must be ≥118.

## Done criteria

ALL must hold:

- [ ] `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, 0 failures, total ≥ **118** when after 016 (cumulative; not ≥115)
- [ ] Every `frameContinuation` access in both transcribers is inside a `stateLock` critical section (Step 3 grep, reviewed site by site)
- [ ] `runSidecar` in `ParakeetEngine.swift` cannot suspend forever: a timeout path exists, terminates the process, and resumes the continuation exactly once (guarded by a flag)
- [ ] `ElevenLabsRealtimeTests.swift:137-144` no longer has an assertion-free test named as if it asserts something
- [ ] `git status` shows only the four in-scope files modified
- [ ] `plans/README.md` status row for 017 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift).
- Any existing test in `StitchDedupeTests` or `GoldenTranscriptTests` starts
  failing — that means the locking change altered transcript assembly, which
  it must not.
- You hit a `CheckedContinuation` double-resume trap at runtime during Step 4.
  Report it; do not paper over it by switching to `UnsafeContinuation`.
- Taking `stateLock` in `send(_:)` appears to introduce audible glitching or
  measurable latency on the realtime audio thread. Report it — the fallback
  design (an atomic or a lock-free handoff) is a decision for a human.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- `StreamingCoordinator.xaiSession` / `.elevenLabsSession` are still plain
  `var`s read from the audio-tap thread and written on main — the same class
  of race one level up, deliberately left out of scope here because plan 016
  is editing that file. Once both land, that coordinator-level race is the
  obvious follow-up.
- Anyone adding a third streaming provider must copy the locked
  `send`/`finalize`/`cancel` shape. The two transcribers are near-identical
  twins; if a third arrives, extracting a shared base becomes worth doing.
- The 120 s sidecar timeout is deliberately loose. If Parakeet is ever
  promoted from "sidecar experiment" to a first-class engine, that number
  should be revisited against real cold-start timings rather than kept as a
  round guess.
- A reviewer should scrutinize: the exactly-once resume guard in Step 4, and
  that `await senderTask?.value` still happens *after* the continuation is
  finished (reordering it silently reintroduces tail truncation).
