# Plan 001: Stop capture, cloud transmission, and history logging when macOS Secure Input is active

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/TextInjector.swift Sources/Voice/TranscriptionPipeline.swift Sources/Voice/AudioRecorder.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Murmur is a push-to-talk dictation app. If the user holds the talk key while
focus is in a password/secure field (macOS "Secure Input" active), the app
currently records the audio, sends it to whatever cloud STT provider is
configured (AssemblyAI/Deepgram/OpenAI/Groq/xAI), optionally sends the text to
a cloud cleanup LLM, and permanently writes the plaintext transcript to
`~/Library/Application Support/Voice/history.json`. Only the very last step —
pasting — is suppressed. A dictated password can therefore end up on
third-party servers and in a local plaintext file. This plan moves the secure
input check to the start of the pipeline and suppresses history logging for
anything captured while secure input was active.

## Current state

- `Sources/Voice/TextInjector.swift` — the ONLY place secure input is checked
  today, at the very end of the pipeline (lines 41-49):

  ```swift
  func insert(_ text: String) -> Bool {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return false
      }

      if IsSecureEventInputEnabled() {
          vlog("injection blocked — secure event input enabled (password field)")
          return false
      }
  ```

- `Sources/Voice/TranscriptionPipeline.swift` lines 213-226 — history is
  logged (`onTranscriptionLogged`) unconditionally BEFORE the injection result
  is inspected; `.secureInputBlocked` failure surfacing already exists:

  ```swift
  DispatchQueue.main.async {
      let corrected = self.onTranscription?(trimmed, engineID) ?? trimmed
      let expanded = self.onSnippetExpand?(corrected) ?? corrected

      let injected = TextInjector().insert(expanded)
      self.onTranscriptionLogged?(expanded, engineID, injected, nil, false)

      if !injected {
          if IsSecureEventInputEnabled() {
              self.onFailure?(.secureInputBlocked)
          } else {
              self.onFailure?(.injectionFailed)
          }
      }
  ```

- `Sources/Voice/AudioRecorder.swift` lines 67-87 — `startRecording()` is the
  capture entry point; it already has a permission-denied early-exit pattern to
  copy (`.micStartFailed` surfaced via `asrSelector.onFailure` on the main
  queue):

  ```swift
  func startRecording() {
      wantsRecording = true
      vlog("AudioRecorder.startRecording — requesting mic permission")
      requestMicrophonePermissionIfNeeded { [weak self] granted in
          vlog("mic permission callback — granted=\(granted)")
          guard let self = self, granted else {
              self?.logger.error("Microphone permission denied.")
              DispatchQueue.main.async {
                  self?.asrSelector.onFailure?(.micStartFailed)
              }
              return
          }
  ```

- `IsSecureEventInputEnabled()` comes from Carbon/HIToolbox and is already in
  use in this codebase (see the two call sites above), so no new
  imports/entitlements are needed.
- Convention: user-visible failures go through the existing
  `onFailure` (`DictationFailure`) enum — `.secureInputBlocked` already exists.
  Find the enum with `grep -rn "secureInputBlocked" Sources/`.

## Commands you will need

| Purpose  | Command | Expected on success |
|----------|---------|---------------------|
| Generate | `xcodegen generate` | "Created project at .../Voice.xcodeproj" |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **`, 69+ tests |

Run from the repo root. `Config/Team.xcconfig` must exist (copy from
`Config/Team.xcconfig.example` if missing).

## Scope

**In scope** (the only files you should modify):
- `Sources/Voice/AudioRecorder.swift`
- `Sources/Voice/TranscriptionPipeline.swift`
- `Tests/VoiceTests/` (new test file allowed)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch, even though they look related):
- `Sources/Voice/TextInjector.swift` — its existing last-line-of-defense check
  stays exactly as is (defense in depth).
- `Sources/Voice/ActivationController.swift` — the key handling layer does not
  need to know about secure input.
- Any UI files; `.secureInputBlocked` surfacing already renders via the
  existing failure pathway.

## Git workflow

- Branch: `fix/secure-input-boundary` (repo convention: `fix/<slug>` branches,
  see `git log` — e.g. `fix/spoken-spaced-file-extension`)
- Conventional commit style, e.g. `fix: gate capture and history on secure input`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Gate capture at `startRecording()`

In `Sources/Voice/AudioRecorder.swift`, at the very top of
`startRecording()` (before `wantsRecording = true`), add:

```swift
if IsSecureEventInputEnabled() {
    logger.info("Secure input active — refusing to start capture.")
    DispatchQueue.main.async { [weak self] in
        self?.asrSelector.onFailure?(.secureInputBlocked)
    }
    return
}
```

If `IsSecureEventInputEnabled` is not visible in this file, add the same
import that `TextInjector.swift` uses (check its import list).

**Verify**: `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`

### Step 2: Suppress history logging when secure input is active at finish time

Secure input can also engage mid-hold (user focuses a password field while
speaking). In `Sources/Voice/TranscriptionPipeline.swift`, in the
`DispatchQueue.main.async` block shown above (lines 213-226), capture the
secure-input state BEFORE injecting, and skip the history log when it is set:

```swift
let secureInput = IsSecureEventInputEnabled()
let injected = secureInput ? false : TextInjector().insert(expanded)
if !secureInput {
    self.onTranscriptionLogged?(expanded, engineID, injected, nil, false)
}
if !injected {
    self.onFailure?(secureInput ? .secureInputBlocked : .injectionFailed)
}
```

Note the changed ordering: the log call now happens only when secure input is
off, and the failure branch reuses the captured `secureInput` instead of
re-querying.

**Verify**: build again → `** BUILD SUCCEEDED **`

### Step 3: Add regression tests

Create `Tests/VoiceTests/SecureInputTests.swift`. `IsSecureEventInputEnabled`
is a C function that cannot be forced on in a unit test, so test the seam:
extract the decision logic in Step 2 into a small internal pure function on
the pipeline type, e.g.

```swift
static func secureInputOutcome(secureInput: Bool, injected: Bool)
    -> (shouldLog: Bool, failure: DictationFailure?)
```

and assert: `(true, _)` → `shouldLog == false`, failure `.secureInputBlocked`;
`(false, false)` → `shouldLog == true`, failure `.injectionFailed`;
`(false, true)` → `shouldLog == true`, failure `nil`. Model the test file
structure on `Tests/VoiceTests/CleanupSanityTests.swift` (`@testable import Voice`).

**Verify**: `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, test count increased by 3+

## Test plan

- New: `SecureInputTests.swift` — the three outcome cases above.
- Manual (report as unverified if you cannot perform it): with the app built
  and running, focus a password field, hold the talk key — expect no HUD
  recording session or a `.secureInputBlocked` failure surface, and no new row
  in the History view.

## Done criteria

- [ ] `xcodebuild -scheme Voice ... build` exits with `** BUILD SUCCEEDED **`
- [ ] `xcodebuild test -scheme VoiceTests ...` exits with `** TEST SUCCEEDED **`; new SecureInput tests present and passing
- [ ] `grep -n "IsSecureEventInputEnabled" Sources/Voice/AudioRecorder.swift` returns at least one match inside `startRecording()`
- [ ] In `TranscriptionPipeline.swift`, `onTranscriptionLogged` on the success path is only reachable when secure input was false
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift).
- `.secureInputBlocked` does not exist in the `DictationFailure` enum — the
  failure pathway has been refactored; report what you find instead.
- Gating in Step 1 breaks the xAI streaming start path (build error or test
  failure referencing `StreamingCoordinator`) — the streaming path may need
  its own gate placement; report rather than moving the check.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- If a "history-only, no injection" mode is ever added, the Step 2 logic must
  distinguish "don't log because secure" from "don't inject by choice".
- Reviewer should scrutinize: the mid-hold case (secure input engaging between
  capture start and finish) — Step 2 covers it; Step 1 alone does not.
- Deferred: redacting the transcript from any in-memory clipboard fallback —
  TextInjector's clipboard-fallback behavior is unchanged by this plan.
