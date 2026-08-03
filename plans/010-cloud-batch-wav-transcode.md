# Plan 010: Transcode cloud batch uploads to 16-bit WAV — the batch path has never worked

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/CloudTranscriber.swift Sources/Voice/AudioRecorder.swift Sources/Voice/HTTPClient.swift`
> On mismatch with "Current state" excerpts, STOP.

## Status

- **Priority**: P1 (live reliability bug in the daily driver's fallback chain)
- **Effort**: M
- **Risk**: MED (touches every cloud upload; mitigated by an empirical oracle)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Empirically verified 2026-07-09 with the user's real recordings and live API
keys: xAI's batch `POST /v1/stt` rejects the app's native CAF (PCM Float32)
upload with HTTP 400 "Could not detect audio format from file header" on
every file — and the same clip transcoded to 16-bit PCM WAV succeeds against
the identical endpoint. `history.json` shows **zero** transcripts have EVER
come from any cloud batch path (705 from `cloud:xai-streaming`, 69 from local
WhisperKit, none from `cloud:*` batch) — so every batch integration shipped
unexercised, and the xAI stream-truncation fallback
(`StreamingCoordinator.swift:123-135` → buffered-audio file path → broken
batch upload → HTTP 400 → local) silently degrades to local Whisper with a
wasted failed round-trip. Transcoding uploads to 16-bit/16kHz mono WAV fixes
the proven rejection and shrinks uploads ~12× (Float32 → 16-bit mono 16k),
which also cuts upload latency.

## Current state

- `Sources/Voice/CloudTranscriber.swift:85-91` — the format contract:

  ```swift
  /// The recorded audio is always written as CAF (Core Audio Format,
  /// PCM Float32 non-interleaved) by `AudioRecorder.writeToFile` via
  /// `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`. This is
  /// NOT WAV or m4a/AAC — the MIME type below reflects that container.
  static let mimeType = "audio/x-caf"
  static let fileExtension = "caf"
  ```

- All five services read `Data(contentsOf: audioURL)` and upload it directly
  (multipart for OpenAI/Groq/xAI/AssemblyAI-upload-step; raw body for
  Deepgram). Example, xAI (`CloudTranscriber.swift:300-318`): multipart with
  `fileName: "audio.caf"`, `mimeType: audio/x-caf`, fields
  `model=grok-stt, format=json, language=...`.
- Recordings are mono at the hardware sample rate, PCM Float32, written by
  `AudioRecorder.writeToFile` (`AudioRecorder.swift:394-405`).
- Working reference implementation of the fix (bake-off harness, verified
  200 + correct transcript): transcode with
  `afconvert -f WAVE -d LEI16@16000 -c 1 in.caf out.wav`, upload as
  `audio.wav` / `audio/wav`. In-app, do the equivalent with
  `AVAudioFile`/`AVAudioConverter` (or `ExtAudioFile`) — do NOT shell out to
  `afconvert` from the app.

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | `xcodegen generate` | Created project |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Live oracle (optional, needs xAI key in Keychain) | transcode one retained recording and POST it per the harness in `scratchpad/bakeoff/` | HTTP 200 with text |

## Scope

**In scope**:
- New `Sources/Voice/CloudAudioTranscoder.swift` — pure function: CAF URL →
  temp WAV URL (16-bit PCM, 16 kHz, mono) via AVFoundation; deletes are the
  caller's job.
- `Sources/Voice/CloudTranscriber.swift` — each service transcodes before
  upload (one call at the top of `transcribe`), uploads `audio.wav` /
  `audio/wav`, deletes the temp WAV in a `defer`. Update the
  `CloudAudioFormat` doc comment + constants.
- `Tests/VoiceTests/CloudAudioTranscoderTests.swift` (create).
- `plans/README.md` (status row).

**Out of scope**:
- `AudioRecorder.writeToFile` — keep recording CAF (retained recordings and
  the local engines consume it today); transcode at the upload boundary only.
- The xAI STREAMING path (sends PCM frames over WebSocket — unaffected).
- Retry/History plumbing.

## Git workflow

- Branch: `fix/cloud-batch-wav-transcode`; conventional commits; do NOT
  push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the transcoder

`CloudAudioTranscoder.transcodeToWAV16k(_ input: URL) throws -> URL`:
read via `AVAudioFile`, convert with `AVAudioConverter` to
`AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1,
interleaved: true)`, write with `AVAudioFile(forWriting:settings:)` using
WAVE-compatible settings (`AVFormatIDKey: kAudioFormatLinearPCM`,
`AVLinearPCMBitDepthKey: 16`, etc.) to a unique temp URL
(`FileManager.default.temporaryDirectory`, `.wav`).

**Verify**: build green.

### Step 2: Unit-test the transcoder

Generate a 1-second sine-wave CAF fixture in the test itself (AVAudioFile
write of a Float32 buffer — no bundled fixture needed), transcode, then
assert: output exists; `AVAudioFile(forReading:)` reports
`fileFormat.sampleRate == 16000`, `channelCount == 1`,
`commonFormat == .pcmFormatInt16`; RIFF header check (first 4 bytes "RIFF",
bytes 8-12 "WAVE").

**Verify**: test run → `** TEST SUCCEEDED **`, new tests pass.

### Step 3: Wire into all five services

In each `transcribe(audioURL:...)` in `CloudTranscriber.swift`: transcode
first, `defer { try? FileManager.default.removeItem(at: wavURL) }`, upload
the WAV bytes with `fileName: "audio.wav"`, `mimeType: "audio/wav"` (for
Deepgram's raw-body request set `Content-Type: audio/wav`). Replace
`CloudAudioFormat`'s constants/doc accordingly. On transcode failure, throw
a `CloudTranscriptionError` naming the transcode step (do not upload the raw
CAF as a fallback — that path is proven dead for xAI and unproven elsewhere;
fail loudly into the existing local-fallback chain instead).

**Verify**: build + full suite green; `grep -n "x-caf" Sources/` → no hits
outside comments/history.

### Step 4 (conditional live oracle): Prove one real upload

If an xAI key exists in the Keychain (`security find-generic-password -s
"com.matt.voice-dictation.apikeys" -a xai -w` — NEVER print the value), run
one live check: build the app? No — cheaper: replicate the upload with the
bake-off harness pattern against one retained recording transcoded by A
SWIFT SNIPPET calling your new transcoder (e.g. a temporary XCTest that
performs the transcode, then curl the output). Expect HTTP 200 + nonempty
text. If no key: mark this step "skipped — no key" in your report; the unit
tests remain the gate.

## Test plan

- `CloudAudioTranscoderTests`: format assertions + RIFF header (Step 2), plus
  an empty/too-short input case (expects a thrown error, not a crash).
- Existing suites: full green run (no behavior change outside cloud upload).

## Done criteria

- [ ] Transcoder produces 16-bit/16k/mono RIFF WAV from Float32 CAF (tests)
- [ ] All five cloud services upload WAV; no `audio/x-caf` uploads remain
- [ ] Temp WAVs deleted after upload (defer present in each service — grep)
- [ ] Build + full test suite green
- [ ] `plans/README.md` status row updated

## STOP conditions

- `AVAudioConverter` cannot be made to produce a WAV container in this repo's
  deployment target without ExtAudioFile — if you end up hand-writing RIFF
  headers, stop and report instead.
- Any existing test fails after Step 3.
- You are tempted to also change `AudioRecorder`'s recording format — out of
  scope, stop.

## Maintenance notes

- If a provider is later found to accept CAF natively, resist the urge to
  special-case it — one upload format for all five keeps the matrix testable.
- Reviewer focus: temp-file cleanup on ALL paths (success, HTTP error,
  transcode error), and that the AssemblyAI three-step flow transcodes once,
  not per step.
- Follow-up (not this plan): the 16k mono WAV is ~12× smaller than the
  Float32 CAF — worth re-measuring cloud latency after this lands (the
  bake-off harness in scratchpad is reusable).
