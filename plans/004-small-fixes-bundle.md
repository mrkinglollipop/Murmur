# Plan 004: Small-fixes bundle — tornDown race (xAI + ElevenLabs), orphaned temp audio, debug-log redaction, stray tooling comment

> **Scope extension (item E, added during execution)**: a fresh audit finding
> in `ElevenLabsRealtimeTranscriber.swift` — the same unsynchronized
> `tornDown` test-and-set as item A, but worse: `cancel()` discarded a
> pending `doneContinuation` without resuming it, permanently hanging
> `finalize()` past its own bounded timeout. Fixed with the same
> lock-the-test-and-set pattern as item A, plus resuming any pending
> continuation in `cancel()` instead of dropping it. Not part of the
> original 223d130 audit.

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/XAIStreamingTranscriber.swift Sources/Voice/AudioRecorder.swift Sources/Voice/CloudTranscriber.swift Resources/parakeet_transcribe.py`
> On any in-scope drift, compare the excerpts below to live code first; mismatch = STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug + security
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Four independent, small, verified defects: (A) an unsynchronized test-and-set
on `tornDown` lets `finalize()` and `cancel()` race into double teardown —
occasionally dropping or duplicating a dictation on the app's highest-churn
path; (B) a failed recording-retention branch strands a raw recording of the
user's voice in `/tmp` forever; (C) cloud-provider HTTP error bodies (which
can echo API-key material on 401s) flow verbatim into the predictable
world-readable file `/tmp/voice-debug.log` when `VOICE_DEBUG=1`; (D) a stray
AI-tooling routing comment sits in a shipped resource file. All are S-effort
with existing patterns to copy.

## Current state

**(A)** `Sources/Voice/XAIStreamingTranscriber.swift` — `tornDown` is checked
and set WITHOUT the lock in both places, unlike the class's other flags which
use `stateLock`:

```swift
// line 267-274 (finalize)
func finalize(recordingDuration: TimeInterval = 0) async -> String {
    guard !tornDown else {
        stateLock.lock()
        let text = Self.postProcessTranscript(mergeConfirmedWithInterim())
        stateLock.unlock()
        return text
    }
    tornDown = true

// line 370-374 (cancel)
/// Hard stop, no read-back. Cancels the socket and sender.
func cancel() {
    guard !tornDown else { return }
    tornDown = true
```

`cancel()` can be called from `StreamingCoordinator`'s start-failure path
while `finalize()` runs from the key-release path — both can pass the guard.

**(B)** `Sources/Voice/AudioRecorder.swift:412-419` — early return without
deleting `tmpURL`; the only delete is in the success-path completion (:423):

```swift
guard let retainedURL = RecordingRetention.retain(from: tmpURL) else {
    logger.error("Failed to retain recording for transcription.")
    DispatchQueue.main.async { [weak self] in
        self?.asrSelector.onFailure?(.audioWriteFailed)
        self?.hud.hide()
    }
    return
}
...
self.asrSelector.transcribeAndLog(audioURL: retainedURL) { [weak self] in
    try? FileManager.default.removeItem(at: tmpURL)
```

**(C)** `Sources/Voice/CloudTranscriber.swift:67-70` — raw body into the error
message:

```swift
static func httpStatus(_ status: Int, provider: CloudProvider, body: String? = nil) -> CloudTranscriptionError {
    let suffix = body.map { " — \($0.prefix(300))" } ?? ""
    return CloudTranscriptionError(provider: provider, message: "HTTP \(status)\(suffix)")
}
```

These messages reach `vlog(...)` (via `error.localizedDescription` in
`TranscriptionPipeline.swift`), and `vlog` (`ActivationController.swift:16-30`)
appends to the fixed path `/tmp/voice-debug.log`. `vlog`'s own doc comment
states the privacy posture to honor: "Never pass user-dictated transcript
text to this function — content stays private."

**(D)** `Resources/parakeet_transcribe.py:2` — stray line
`# --bypass-harness (sonnet lane)`: residue from the workspace's agent
code-routing tooling (introduced by commit `8ef794f`). Not malicious; just
does not belong in a shipped resource.

## Commands you will need

| Purpose  | Command | Expected on success |
|----------|---------|---------------------|
| Generate | `xcodegen generate` | Created project |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |

`Config/Team.xcconfig` must exist (copy from `Config/Team.xcconfig.example`).

## Scope

**In scope**:
- `Sources/Voice/XAIStreamingTranscriber.swift` (fix A only — the two guard
  sites; no stitch-logic changes)
- `Sources/Voice/AudioRecorder.swift` (fix B only)
- `Sources/Voice/CloudTranscriber.swift` (fix C only)
- `Resources/parakeet_transcribe.py` (fix D — delete line 2 only)
- `Sources/Voice/ElevenLabsRealtimeTranscriber.swift` (fix E — same lock
  pattern as A, plus resume the leaked `doneContinuation` in `cancel()`)
- `Tests/VoiceTests/` (new tests for C's redaction helper and E's concurrency)
- `plans/README.md` (status row)

**Out of scope**: everything else in those files; the `vlog` function itself
(its gating and path are by design); `RecordingRetention.swift`.

## Git workflow

- Branch: `fix/small-fixes-audit-004`
- One commit per lettered fix (A/B/C/D), conventional style.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1 (A): Make `tornDown` test-and-set atomic under `stateLock`

In both `finalize()` and `cancel()`, replace the unlocked pattern with a
locked test-and-set. Shape for `cancel()`:

```swift
func cancel() {
    stateLock.lock()
    if tornDown { stateLock.unlock(); return }
    tornDown = true
    stateLock.unlock()
    ...
```

For `finalize()`, the early-return branch already takes `stateLock` to read
the transcript — restructure so the `tornDown` check happens inside that same
lock acquisition, and `tornDown = true` is set before unlocking. Preserve the
existing early-return behavior (return merged transcript) exactly.
Check whether `tornDown` is read anywhere else
(`grep -n "tornDown" Sources/Voice/XAIStreamingTranscriber.swift`) and put any
other read under the lock too.

**Verify**: build + full test suite → both green (stitch tests prove no
behavior change).

### Step 2 (B): Delete the temp file on the retention-failure branch

Inside the `guard let retainedURL ... else` block, before `return`, add:

```swift
try? FileManager.default.removeItem(at: tmpURL)
```

**Verify**: build → `** BUILD SUCCEEDED **`; `grep -n "removeItem(at: tmpURL)" Sources/Voice/AudioRecorder.swift` → 2 matches.

### Step 3 (C): Redact bodies before they enter error messages

In `CloudTranscriber.swift`, add a small static helper next to `httpStatus`:

```swift
/// Strips anything key-shaped before a body fragment can reach logs:
/// long unbroken token runs (20+ chars of [A-Za-z0-9_-]) are replaced
/// with "…". Keeps enough context to diagnose HTTP errors.
static func redactedBodyFragment(_ body: String, max: Int = 300) -> String
```

Implement with a single `NSRegularExpression` (`[A-Za-z0-9_\-]{20,}` → `…`),
then take `.prefix(max)`. Use it in `httpStatus` in place of the raw
`$0.prefix(300)`.

**Verify**: build green; new unit tests below pass.

### Step 4 (C tests): Unit-test the redaction helper

Add `Tests/VoiceTests/RedactionTests.swift` (`@testable import Voice`,
modeled on `CleanupSanityTests.swift`): a body containing a 40-char
token-like run comes back without it; a normal JSON error message (short
words, punctuation) survives readably; output never exceeds 300 chars + the
ellipses.

**Verify**: test run → `** TEST SUCCEEDED **`, new tests listed.

### Step 5 (D): Remove the stray comment

Delete line 2 of `Resources/parakeet_transcribe.py`
(`# --bypass-harness (sonnet lane)`). Nothing else in the file changes.

**Verify**: `sed -n '1,4p' Resources/parakeet_transcribe.py` → shebang, then the docstring opens; `grep -rn "bypass-harness" .` (excluding `.git` and `plans/`) → no hits.

## Test plan

- New: `RedactionTests.swift` (3 cases, Step 4).
- Existing `StitchDedupeTests` + `GoldenTranscriptTests` serve as the
  regression net for Step 1 (no stitch behavior change expected).
- Fix B has no test seam worth building (FileManager side effect in a
  failure branch); verified by grep + review.

## Done criteria

- [ ] Build and full test suite green
- [ ] `tornDown` has zero unlocked read/write sites (inspect every `grep -n "tornDown"` hit)
- [ ] `removeItem(at: tmpURL)` present in both success completion and retention-failure branch
- [ ] `httpStatus` no longer embeds a raw body; redaction helper used and tested
- [ ] `grep -rn "bypass-harness" Resources/` → no hits
- [ ] Only in-scope files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `finalize()`'s control flow around the lock doesn't match the excerpt
  (drift) — report before restructuring.
- Any stitch/dedupe test fails after Step 1 — you changed behavior, not just
  synchronization; revert and report.
- You find additional unlocked shared state while doing Step 1 and feel
  tempted to fix it — don't; note it in your report instead (AudioRecorder
  concurrency work is explicitly parked by the audit).

## Maintenance notes

- Step 3's redaction is defense-in-depth for logs only; the error's
  user-facing message also benefits. If a future "show provider error detail"
  UI is added, it should show the redacted form.
- Reviewer focus: Step 1's lock ordering (no `await` while holding
  `stateLock` — the lock must be released before any suspension point).
