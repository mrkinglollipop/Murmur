# Plan 011: Fix AssemblyAI's deprecated `speech_model` parameter (hard 400 on every request)

> **Executor instructions**: Follow step by step. Run every verification
> command and confirm the expected result before moving on. On any STOP
> condition, stop and report. Update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/CloudTranscriber.swift`

## Status

- **Priority**: P1 (integration is 100% broken against the live API)
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (compose with 010 — both touch `CloudTranscriber.swift`)
- **Category**: bug
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Empirically verified 2026-07-09 against the live API with a valid key: every
AssemblyAI transcript-create request returns HTTP 400 —
`"The speech_model parameter is deprecated. Use speech_models: [...]"`. The
app's AssemblyAI path cannot succeed for any input. It went unnoticed because
`history.json` shows zero dictations have ever used a cloud batch engine.
Switching to the array-form parameter fixed it in the bake-off harness
(`speech_models: ["universal-3-5-pro"]` returned HTTP 200, mean WER 0.024 —
tied best-in-test for accuracy).

## Current state

`Sources/Voice/CloudTranscriber.swift:249-253` — the transcript-create body:

```swift
let body: [String: Any] = [
    "audio_url": audioURL,
    "speech_model": "universal",
    "language_code": language
]
```

The three-step flow (upload → create → poll) is otherwise sound; only the
create body's model parameter is wrong. `universal-3-5-pro` is the model id
that the live API accepted during the bake-off (verified 2026-07-09).

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | `xcodegen generate` | Created project |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |

## Scope

**In scope**: `Sources/Voice/CloudTranscriber.swift` (AssemblyAI create body
+ its doc comment only); `plans/README.md`.

**Out of scope**: the upload/poll steps; other providers; the WAV transcode
(Plan 010 owns that — if 010 has landed, keep its transcode call intact).

## Git workflow

- Branch: `fix/assemblyai-speech-models`; conventional commit
  (`fix(assemblyai): migrate to speech_models array parameter`); no push/PR
  unless instructed.

## Steps

### Step 1: Switch to the array parameter

Replace `"speech_model": "universal"` with
`"speech_models": ["universal-3-5-pro"]`. Add a one-line comment stating the
scalar form is deprecated and rejected with 400 (constraint the code can't
show).

**Verify**: build → `** BUILD SUCCEEDED **`; full test suite green;
`grep -n '"speech_model"' Sources/` → no hits.

### Step 2 (conditional live oracle): Prove one real request

The operator's AssemblyAI key lives in the operator's local AssemblyAI key file
(never commit keys). Read it into
memory only — NEVER print, log, or write the value anywhere. Run one
upload→create→poll cycle against a retained recording
(`~/Library/Application Support/Voice/Recordings/*.caf`, transcoded to WAV
per Plan 010's settings, or with `afconvert -f WAVE -d LEI16@16000 -c 1`).

**Verify**: create returns HTTP 200 (not 400) and polling reaches
`status: completed` with nonempty text. If the key file is absent, mark this
step "skipped — no key" and rely on Step 1's grep + build.

## Test plan

No unit test is meaningful for a request-body constant without an HTTP seam
(see audit finding #13 — a `CleanupService`/`CloudTranscriber` test seam is a
separate, unplanned item). The live oracle in Step 2 is the real gate.

## Done criteria

- [ ] `grep -rn '"speech_model"' Sources/` → no hits; `"speech_models"` present
- [ ] Build + full test suite green
- [ ] Step 2 run and reported (HTTP 200 + completed transcript), or explicitly marked skipped
- [ ] Only in-scope files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The live API rejects `universal-3-5-pro` — the model id has moved again.
  Report the exact error body (truncate to 200 chars; never include the key).
  Do NOT guess at another id: check AssemblyAI's docs and report what you find.
- The create step returns 401 — the key is dead; report, do not work around.

## Maintenance notes

- Model ids are versioned product names and WILL churn. If this breaks a
  third time, put the model id behind a Settings field rather than a
  constant.
- Reviewer focus: `speech_models` is an ARRAY. A scalar string will 400.
