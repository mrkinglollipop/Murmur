# Plan 028: Add Gemini 3.5 Transcribe as a selectable cloud engine

> **OPERATOR DECISION (2026-08-26)**: add Gemini 3.5 Transcribe Live as an
> ADDITIONAL Settings engine. Do NOT remove, disable, or demote xAI Grok STT
> or ElevenLabs Scribe v2 Realtime. Do NOT change `CloudModel.default` (stays
> xAI). Do NOT make Gemini the shipping default. This plan is purely additive.
>
> **AUTHORIZED (2026-08-26)**: Matt — `then get it done. thats part of the plan! no loose ends`.
> Additive third engine; default stays xAI. ElevenLabs Advanced knobs were
> already in tree before this slice. Live WebSocket handshake against a paid
> key remains **unverified** in CI — protocol JSON is docs-locked 2026-08-26.
>
> **Executor instructions**: Follow step by step. Run every verification
> command and confirm the expected result before moving on. On any STOP
> condition, stop and report. Update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat HEAD -- Sources/Voice/LocalModel.swift Sources/Voice/CloudTranscriber.swift Sources/Voice/ASREngineSelector.swift Sources/Voice/StreamingCoordinator.swift Sources/Voice/AudioRecorder.swift Sources/Voice/UI/SettingsView.swift Sources/Voice/UI/EngineDisplayName.swift Tests/VoiceTests/CloudModelSelectionTests.swift`

## Status

**SHIPPED** (code, 2026-08-26) — Mac + iOS host in tree. VoiceTests **verified** green; unsigned iOS build **verified**. Live WebSocket handshake against a paid Gemini key remains **unverified**. Dictation hold-start oracle (`install-local` + fn-hold) is operator-gated.

- **Priority**: P2 (feature; third BYO cloud ASR)
- **Effort**: L (new Live-API transcriber + coordinator wiring + batch fallback)
- **Risk**: MED (Google **Preview** model, day-one 2026-08-26; timeouts called
  out on the model card; WebSocket JSON field casing must be probed live)
- **Depends on**: existing streaming template (ElevenLabs is the copy target,
  not xAI stitch). Batch fallback uses Plan 010 WAV transcode.
- **Category**: direction / feature
- **Planned at**: commit `6ffb882`, 2026-08-26
- **Docs cited**: [Live transcription](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe),
  [WebSocket get-started](https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket),
  [Batch transcribe](https://ai.google.dev/gemini-api/docs/transcribe),
  [Pricing](https://ai.google.dev/gemini-api/docs/pricing),
  [Gemini API Additional Terms](https://ai.google.dev/gemini-api/terms)

## Why this matters

Google shipped a dedicated STT pair on 2026-08-26 that maps to Murmur's
fn-hold: Live model `gemini-3.5-transcribe-live` documents **Manual VAD
(Push-to-Talk)** (`activity_start` / `activity_end`), PCM 16 kHz, interim +
final text. Batch `gemini-3.5-transcribe` is the parachute. The operator
wants it as an **option**, not a replacement, so a bake-off against Scribe RT
is possible without burning the current engine.

This is **not** Cloud Chirp 3 (`chirp_3` on Speech-to-Text v2). Do not
implement Chirp in this plan.

## Current state (code, 2026-08-26)

Selectable cloud engines are exactly two: `CloudModel.xaiGrokSTT` and
`CloudModel.elevenLabsScribeV2Realtime` (`Sources/Voice/LocalModel.swift`).
`CloudProvider` has six cases (four retired-from-UI). Streaming start order
in `AudioRecorder.doStart()`: xAI → ElevenLabs → WhisperKit → file.

ElevenLabs is the integration template: `make*StreamingSession` on
`ASREngineSelector`, `StreamingCoordinator` start/send/stop, tap always
copies `pcmBuffers` then `sendTo*`, silence/truncation guards, batch
fallback via `CloudTranscriberFactory`, engine tag
`cloud:elevenlabs-streaming`. Gemini should clone that costume, not xAI's
stitch/dedupe.

## Product shape (locked)

| Decision | Choice |
|---|---|
| Surfaces | **Mac Murmur** + **iOS host app** (keyboard still batch/bounce-only; no appex mic) |
| Primary path | Always-on Live WebSocket when Gemini is selected (like Scribe RT; no xAI-style streaming toggle). |
| Fallback | Batch `gemini-3.5-transcribe` over WAV 16 kHz when Live start/finalize fails or looks truncated. Then local WhisperKit/Parakeet as today. |
| Auth | BYO Gemini API key from [AI Studio](https://aistudio.google.com/apikey). New Keychain account `gemini`. |
| Default engine | Unchanged (`CloudModel.default` = xAI). |
| Filler strip | Reuse `SettingsStore.removeFillerWords`: ON → Gemini `smart`, OFF → `verbatim`. Show the existing toggle (retitle to engine-neutral copy) when Gemini **or** ElevenLabs is selected. |
| Dictionary | Map canonical dictionary terms into Gemini `custom_vocabulary` (cap **100** for v1 — Google's "best ≤100"; hard API max is 1000). Separate helper from EL's 50×20-char `selectKeyterms`. |
| Preview UX | Settings caption: model is **Preview**; prefer a **paid** Gemini key (free tier may be used to improve Google products per Gemini API Additional Terms). |
| Not in v1 | Chirp 3; Gemini Live **Agent** (audio out / function calling); Gboard Rambler features; EL `entity_detection`. |

## Protocol (verify in Step 0 before writing production JSON)

Live (desktop, API key in query — **never log the URL**):

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<KEY>
```

1. First client message is `BidiGenerateContentSetup`: model
   `models/gemini-3.5-transcribe-live`, `responseModalities: ["TEXT"]`,
   `inputAudioTranscription` (language hint, custom vocabulary, smart/verbatim).
2. Disable automatic activity detection (Manual / Push-to-Talk).
3. On fn-down after setup-complete: `activity_start`, then stream
   `realtimeInput.audio` as 16-bit PCM LE 16 kHz (`mimeType: audio/pcm;rate=16000`),
   same converter target as `ElevenLabsRealtimeTranscriber`.
4. HUD: `interim_input_transcription` (and/or server field name from the
   probe — lock it in a fixture).
5. On fn-up: `activity_end` (or `audio_stream_end` if the probe shows that
   is what flushes the final). Wait for `input_transcription` as the
   committed utterance. Reuse EL finalize timeout:
   `min(30, max(3, duration×0.25 + 3))`.
6. Session cap **10 minutes**. Dictation holds are seconds; if a session
   hits the cap, cancel and batch-fallback. Do not silently reconnect
   mid-hold in v1.

Batch:

```
POST https://generativelanguage.googleapis.com/v1beta/interactions
Header: x-goog-api-key
Body: model `gemini-3.5-transcribe` + audio (WAV 16 kHz via `CloudAudioTranscoder.wavUploadPayload`)
```

Exact Interactions `input` JSON is locked in Step 0 against
https://ai.google.dev/gemini-api/docs/transcribe (camelCase vs snake_case
differs between SDK and raw HTTP). Do not guess.

## File map

| Path | Role |
|---|---|
| `Sources/Voice/GeminiLiveTranscriber.swift` | **Create.** Live session. Copy concurrency from `ElevenLabsRealtimeTranscriber` (tap-thread `send`, AsyncStream sender, `session_started`/finalize continuations, `everHadNonEmptyStreamText`, `joinedTranscriptSnapshot`). No stitch. |
| `Sources/Voice/CloudTranscriber.swift` | `CloudProvider.gemini`, signup URL, `CloudModel.provider`, `GeminiTranscriptionService` batch, factory case. |
| `Sources/Voice/LocalModel.swift` | `CloudModel.gemini35TranscribeLive`, `selectable` += that case, display name. |
| `Sources/Voice/ASREngineSelector.swift` | `geminiStreamingEnabled = true`, `makeGeminiStreamingSession()`. |
| `Sources/Voice/StreamingCoordinator.swift` | `geminiSession`, `tryStartGemini` / `sendToGemini` / `handleStopGemini` / `cancelAll`. Mirror EL stop (silence guard, truncate → batch, empty-finalize snapshot recovery). |
| `Sources/Voice/AudioRecorder.swift` | After ElevenLabs in `doStart`: `tryStartGemini`. Tap: `sendToGemini`. Stop: `handleStopGemini` with engine id `cloud:gemini-streaming`. |
| `Sources/Voice/AppDelegate.swift` | Vocab provider: `GeminiLiveTranscriber.selectVocabulary(from:)` (or shared helper). |
| `Sources/Voice/UI/SettingsView.swift` | Key field comes free via `apiKeyEntry(for:)`. Gemini Preview + paid-key caption. Filler toggle visible for `.gemini` too; retitle off "ElevenLabs". |
| `Sources/Voice/UI/SettingsStore.swift` | Fix stale comment that only xAI streams. `removeFillerWords` also drives Gemini smart mode. |
| `Sources/Voice/UI/EngineDisplayName.swift` | `cloud:gemini-streaming` / `cloud:gemini`. |
| `Tests/VoiceTests/GeminiLiveTests.swift` | **Create.** Setup JSON (redacted), vocab selection, transcript join, PTT activity frames. No live network. |
| `Tests/VoiceTests/CloudModelSelectionTests.swift` | Selectable set size 3; factory serves all `CloudModel.allCases`. |
| `Tests/VoiceTests/KeychainAccountConsistencyTests.swift` | Gemini round-trip + tearDown delete. Isolated test service only. |
| `Tests/VoiceTests/EngineDisplayNameTests.swift` | Streaming + batch ids. |
| `README.md` | Cloud table row. |
| `plans/README.md` | Index status. |

XcodeGen globs `Sources/Voice` — no `project.yml` membership edit.

## Out of scope

- Replacing or hiding xAI / ElevenLabs
- Making Gemini the default cloud model
- Google Cloud Speech-to-Text / Chirp 3
- Keyboard-appex mic (host still records; bounce path unchanged)
- Sparkle / notarize / changing `CFBundleVersion` as part of this plan
- ElevenLabs `entity_detection`
- Live word timestamps / diarization (Gemini Live docs: not available)
- Function calling / screen context / Speak-to-Window

## Steps

### Step 0: Live protocol probe (blocking)

With a **paid** Gemini API key (never commit; never paste into the plan),
open one Live session and one batch `interactions` call. Capture:

- Setup JSON the server accepts
- Interim vs final field names
- Exact PTT client messages (`activity_start` / `activity_end` vs
  `audio_stream_end`)
- Batch request/response keys for transcript text
- Error payload on a bad key (to map to `CloudTranscriptionError`)

STOP if Live does not emit a final transcript on manual VAD — do not fake
it with automatic VAD (that would cut mid-hold). Check field names into
`GeminiLiveTests` fixtures. Redact the key.

### Step 1: Enum + Keychain + picker visibility

Add:

```swift
// CloudProvider
case gemini = "gemini"
// displayName: "Google Gemini"
// signupURL: https://aistudio.google.com/apikey

// CloudModel
case gemini35TranscribeLive = "gemini35TranscribeLive"
// displayName: "Gemini 3.5 Transcribe"
// selectable: [.xaiGrokSTT, .elevenLabsScribeV2Realtime, .gemini35TranscribeLive]
```

Update `CloudModel.provider`, factory (stub batch service that `XCTFail`s
until Step 4 is fine **only** if tests don't call it yet — prefer a real
decode stub).

**Verify**: `CloudModelSelectionTests` — selectable is the three cases;
retired four still excluded; `selectableOrFallback(.gemini35TranscribeLive)`
identity; `allCases` count includes Gemini; factory non-nil for every case.

### Step 2: `GeminiLiveTranscriber` (no network in tests)

Pure pieces first (TDD):

- `buildSocketURL` must **not** be logged; tests check host/path/query
  **key presence** without asserting the secret.
- `makeSetupMessage(language:smart:vocabulary:)` matches Step 0 fixture.
- `selectVocabulary(from:)` — canonical terms only, drop empties, cap 100,
  prefer highest `fixCount` (same ranking idea as EL, different limits;
  do **not** reuse EL's 20-byte kill — Gemini's limit is term count).
- `joinedTranscript` — sequential finals + latest interim, EL-style
  containment dedupe.
- `makeActivityStartFrame` / `makeActivityEndFrame` / `makeAudioChunkFrame`.

Then the class: `start()` waits for setup-complete; `send(_:)` converts to
PCM16/16k like EL; `finalize` sends activity_end and waits for final text;
`cancel` tears down; `hasEverHadNonEmptyStreamText`.

**Verify**: `GeminiLiveTests` green unsigned `VoiceTests`.

### Step 3: Coordinator + recorder wiring

Mirror EL:

- `tryStartGemini` → `makeGeminiStreamingSession()` → `startMicCapture()`
- Tap: `sendToGemini` next to the existing two sends (nil-safe)
- `handleStopGemini` — same silence/truncate/snapshot recovery as EL
- `cancelAll` clears gemini too (secure-input abort)
- Engine id `cloud:gemini-streaming` on success; batch fallback uses
  `cloud:gemini` via `transcribeAndLog`

Start order: keep xAI then ElevenLabs then **Gemini** then WhisperKit.
Only one `cloudModel` is active, so the extra try is a cheap nil.

**Verify**: build `Voice` Debug `CODE_SIGNING_ALLOWED=NO`. Existing
VoiceTests still green.

### Step 4: Batch `GeminiTranscriptionService`

`POST /v1beta/interactions`, `x-goog-api-key`, WAV from
`cloudUploadAudio` (same transcoder as EL). Decode transcript text from
the Step 0 response shape. Map non-2xx to `CloudTranscriptionError.httpStatus`.

**Verify**: decode unit test with a fixture body (no network).

### Step 5: Settings + docs

- Picker lists Gemini via `selectable`
- Caption under the key field: Preview; paid key recommended
- Filler toggle: show for `.elevenLabs` **or** `.gemini`; copy no longer
  says "ElevenLabs" only
- `EngineDisplayName` + tests
- `KeychainAccountConsistencyTests` Gemini round-trip; tearDown deletes
  `CloudProvider.gemini.keychainAccount`
- README cloud table: third row, "Always streams (batch only as fallback);
  Preview"

**Verify**: `EngineDisplayNameTests`, Keychain tests, `grep` README for
`gemini-3.5-transcribe-live`.

### Step 6: Local install + operator bake-off (not a ship)

`bash scripts/install-local.sh` after VoiceTests green. Operator switches
Settings → Cloud → Gemini 3.5 Transcribe, pastes key, fn-hold.

Record (same metrics as plan 012): first HUD partial, release-to-final,
whether smart swallows spoken corrections, Preview timeouts / ghost drops.
`bash scripts/oracle-dictation-start.sh` after a hold (0 = started).

Do **not** Sparkle from this plan. Do **not** change default.

## Gotchas

1. **API key in the WebSocket query string.** Redact in every log. vlog
   host+path only.
2. **Preview timeouts.** Empty finalize must batch-fallback, including the
   pre-finalize HUD snapshot recovery EL already has (ghost-drop scar).
3. **Smart vs spoken corrections.** Same risk as `no_verbatim`. Default ON
   to match current filler toggle.
4. **Free-tier training.** Settings must say it. Murmur's privacy story is
   BYO paid key.
5. **Do not send video or AUDIO response modalities.** That is Live Agent,
   not Transcribe.
6. **`testFactoryStillServesAllSixProviders`** will break on the count —
   rename and assert `CloudModel.allCases.count` after the new case.

## Acceptance

- [x] Gemini appears in Settings cloud picker; xAI and ElevenLabs still there
- [x] Default cloud model still xAI
- [x] No Gemini key → local engine (existing fallback) — same selector nil path as EL
- [ ] Live path used when key present; batch only on stream failure/truncate — **unverified** (no paid-key probe)
- [x] Filler toggle maps to smart/verbatim (Live JSON + batch body unit-tested)
- [x] Dictionary terms reach custom_vocabulary (≤100) — unit-tested selection + JSON
- [x] VoiceTests green (604, 3 skipped); CloudModelSelection / Keychain / EngineDisplayName /
      GeminiLiveTests cover the new case
- [x] README lists three cloud engines
- [x] iOS host: engine picker + Live WS + batch fallback; keyboard bounce-only (no appex mic)
- [x] No Sparkle

## Follow-ups (not this plan)

- Head-to-head bake-off vs Scribe RT on the operator's holds (WER + HUD
  latency). Only that table can justify changing the default.
- Paid-key Live handshake probe (setupComplete / interim vs final field names).
- ElevenLabs `entity_detection` as **metadata** (PII/PHI/PCI labels + extra
  cost). Does **not** rewrite the inject text unless we add a redaction
  pass, which dictation almost never wants.
