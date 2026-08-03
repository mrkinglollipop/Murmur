# Plan 012: Add ElevenLabs Scribe as a cloud provider — the bake-off winner

> **OPERATOR DECISION (2026-07-09)**: add Scribe v2 Realtime as an ADDITIONAL
> engine option. Do NOT remove, disable, or demote the xAI grok streaming
> engine — it stays exactly as it is, and remains the default until the
> operator switches it in Settings. This plan is purely additive.
>
> **SUPERSEDED IN PART (2026-07-09, round 4)**: a later streaming shoot-out
> showed **`scribe_v2_realtime` (WebSocket) beats `scribe_v2` batch on the
> metric that matters** — 148ms median release-to-final vs 860ms — at
> identical accuracy (0.024 WER) and $1.30 vs $0.733 per 1,000 dictations.
> If you are executing this plan, prefer implementing the REALTIME model
> (`wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_16000`,
> `xi-api-key` header, JSON `input_audio_chunk` with base64 `audio_base_64`,
> final chunk `commit:true`, await `committed_transcript`) and treat the batch
> service below as the simpler fallback lane. Batch still needs Plan 010's
> WAV transcode; the realtime path sends PCM16 frames and does not.
> Known tradeoff: Scribe RT's first PARTIAL arrived ~2.2s into the hold in
> testing (vs xAI streaming's ~300ms), so the live HUD preview would feel
> sluggish — verify this against ElevenLabs' VAD/commit settings before
> retiring the xAI streaming preview layer.

> **Executor instructions**: Follow step by step. Run every verification
> command and confirm the expected result before moving on. On any STOP
> condition, stop and report. Update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/CloudTranscriber.swift Sources/Voice/ASREngineSelector.swift Sources/Voice/KeychainStore.swift Sources/Voice/UI/SettingsView.swift`

## Status

- **Priority**: P2 (feature; unlocks the measured accuracy + reliability win)
- **Effort**: M
- **Risk**: LOW (additive provider; existing engines untouched)
- **Depends on**: **Plan 010** (WAV transcode — Scribe was scored on WAV; do
  not add a sixth provider that uploads the rejected CAF container).
  Strongly prefer also landing audit finding #8 (response-handling dedupe)
  first so this doesn't become the 8th copy-paste — but that is not blocking.
- **Category**: direction / feature
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

A 100-attempt head-to-head on the user's own dictations (2026-07-09, all on
16 kHz mono WAV) produced this leaderboard:

| Config | Failure rate | Deterministic | Median latency | Mean WER |
|---|---|---|---|---|
| **elevenlabs/scribe_v2** | 0% | yes | 842ms | **0.024** |
| assemblyai/universal-3-5-pro | 0% | yes | 3,520ms | 0.024 |
| xai/grok-stt | 0% | yes | **507ms** | 0.050 |
| deepgram/nova-3 | 0% | yes | 667ms | 0.100 |

Scribe v2 ties for best accuracy with effectively zero semantic errors, at
sub-second latency — versus AssemblyAI's structurally slow 3.5s async flow.
It is the best fit for interactive dictation and the app does not support it
at all today. Adding it as a BATCH provider also sidesteps the streaming
stitch/dedupe code where every recent regression has lived.

## Current state

- Provider enum, `Sources/Voice/CloudTranscriber.swift:10-15`:

  ```swift
  enum CloudProvider: String, CaseIterable, Identifiable {
      case assemblyAI = "assemblyAI"
      case deepgram   = "deepgram"
      case openAI     = "openAI"
      case groq       = "groq"
      case xai        = "xai"
  ```

- Each provider implements `CloudTranscriptionService.transcribe(audioURL:apiKey:model:language:)`.
  The simplest exemplar to copy is `GroqTranscriptionService`
  (`CloudTranscriber.swift:132-163`): multipart POST, bearer auth, `.text`
  response. Scribe differs only in auth header and field names.
- `CloudTranscriberFactory.service(for:)` (`:334-343`) switches over the enum
  — a new case must be added there or it won't compile (good: the compiler
  enumerates the work).
- Keys are stored per-provider in the Keychain under service
  `com.matt.voice-dictation.apikeys`, account = the provider raw value
  (`KeychainStore.swift`). A new provider needs its Settings key field.
- `CloudModel` (the user-facing model list) and the Settings picker
  (`SettingsView.swift`) both enumerate provider/model pairs — find every
  site with `grep -rn "CloudModel" Sources/`.

- **Verified request shape** (bake-off harness, HTTP 200 on all 25 attempts):
  `POST https://api.elevenlabs.io/v1/speech-to-text`, header
  `xi-api-key: <key>` (NOT bearer), multipart/form-data with the audio file
  and field `model_id=scribe_v2`. Response JSON contains the transcript
  `text`. Confirm the exact response key against a live call in Step 4 before
  trusting a decoder.

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | `xcodegen generate` | Created project |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |

## Scope

**In scope**: `CloudTranscriber.swift` (enum case, service, factory),
`CloudModel` definition + wherever models are listed, `SettingsView.swift`
(API-key field + model row), `Tests/VoiceTests/` (response-decode test),
`plans/README.md`.

**Out of scope**: making Scribe the DEFAULT engine (a user decision — leave
the default as-is; the operator will flip it in Settings); ElevenLabs'
streaming/realtime endpoint; removing any existing provider.

## Git workflow

- Branch: `feat/elevenlabs-scribe`; conventional commits; no push/PR unless
  instructed.

## Steps

### Step 1: Add the provider case and model

Add `case elevenLabs = "elevenLabs"` to `CloudProvider` with a display name
matching the existing style, and a corresponding `CloudModel` entry (label
e.g. "ElevenLabs Scribe v2"). Build — the compiler will list every switch
that needs the new case. Fix each.

**Verify**: build → `** BUILD SUCCEEDED **`

### Step 2: Implement `ElevenLabsTranscriptionService`

Copy `GroqTranscriptionService`'s structure. Differences: URL
`https://api.elevenlabs.io/v1/speech-to-text`; header `xi-api-key` (no
`Bearer` prefix); multipart field `model_id=scribe_v2`; keep using the shared
`HTTPClient.multipartBody`. If Plan 010 has landed, the WAV transcode call at
the top of `transcribe` comes with the copied structure — keep it; if 010 has
NOT landed, STOP (see conditions).

Decode `{"text": ...}` — but verify the real key name in Step 4 before
finalizing; if the payload nests it, adjust the `Decodable` accordingly.

**Verify**: build green; register in `CloudTranscriberFactory`.

### Step 3: Settings — key field and model row

Add the API-key field and model entry alongside the other providers in
`SettingsView.swift`, matching the surrounding code exactly (same Keychain
account convention: raw value `elevenLabs`).

**Verify**: build green.

### Step 4 (live oracle, required): One real transcription

The operator's key is in the operator's local ElevenLabs key file (never commit keys).
Read it into memory only — NEVER print, log, or persist the value. Transcode
one retained recording to WAV and POST it exactly as the new service does.

**Verify**: HTTP 200 and a nonempty transcript; confirm the JSON key your
decoder expects actually exists in the response. Record the response's
top-level keys (names only) in your report.

### Step 5: Decode test

Add a fixture-based test (static JSON string → `Decodable` → expected text),
following whatever pattern exists in `Tests/VoiceTests/`. This is also the
seed for audit finding #13 (provider-parser fixtures for all providers).

**Verify**: `xcodebuild test ...` → `** TEST SUCCEEDED **`, new test passes.

## Done criteria

- [ ] `elevenLabs` provider selectable in Settings with its own Keychain key field
- [ ] Live oracle (Step 4) returned HTTP 200 + transcript; response shape confirmed
- [ ] Decode test present and passing
- [ ] Build + full suite green; no existing provider modified
- [ ] `plans/README.md` status row updated

## STOP conditions

- Plan 010 has not landed (the app still uploads CAF) — STOP: Scribe was
  scored on WAV, and shipping a sixth CAF uploader repeats the xAI bug.
- The live call returns 401 (key dead) or the response shape differs from
  `{"text": ...}` in a way that needs guessing — report the top-level key
  names (never the key/values of credentials) and stop.
- Adding the case requires touching more than ~5 files — report the map.

## Maintenance notes

- Consider making Scribe the default cloud engine AFTER the operator trials
  it; the bake-off supports it (best accuracy, sub-second, zero failures) but
  the default is the operator's call.
- Batch Scribe has no stitch/dedupe path — if it proves good in daily use, it
  is the strongest candidate for retiring the xAI streaming path and its
  entire class of regressions. Measure perceived latency before deciding.
- Model ids churn (`scribe_v2` today). If a third model-id break occurs
  across any provider, move ids into Settings.
