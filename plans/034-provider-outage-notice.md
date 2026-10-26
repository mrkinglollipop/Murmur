# 034 — Tell the user when a cloud provider refuses, and stop paying for it

**Status:** DRAFT 2026-10-26, waiting for Matt's OK on this doc and the mock
(`plans/034-provider-outage-mock.html`).
**Origin:** 2026-10-26 00:43Z. The ElevenLabs subscription had a failed payment
and every request came back `401 payment_required`. Three holds (83 s, 35 s and
10 s) each tried the stream, then batch, then ran WhisperKit on the Mac. The only
thing the user saw was a long "Transcribing". Nothing said ElevenLabs was down.

## Goal

When a cloud speech provider refuses Murmur for a reason that will not fix
itself on the next try (billing, a bad or under-permissioned key, quota), the
user finds out within one hold, sees what to do, and no further hold pays for
cloud attempts that are bound to fail.

## What exists (map: survey 2026-10-26)

- Batch errors keep the status and a redacted body, but only as a message
  string: `CloudTranscriptionError.httpStatus` (`CloudTranscriber.swift:376`,
  `:297`; `CloudProvider.swift:54-85`).
- On realtime, the handshake status is logged only
  (`ElevenLabsRealtimeTranscriber.swift:1025-1056`,
  `XAIStreamingTranscriber.swift:634-657`). Server `error` events are log-only
  (`:1217`, `:780`). The coordinator swallows the start failure and keeps
  buffering (`StreamingCoordinator.swift:484-493`).
- The fallback happens in `TranscriptionPipeline.transcribeAndLog`: the cloud
  branch is chosen at `:522`, the error is caught at `:552`, and
  `transcribeLocally` runs at `:574`. A failure is shown only when local also
  fails (`:742`).
- HUD amber warnings `.microphoneNoAudio` / `.microphoneLowLevel`
  (`RecordingHUD.swift:303-340`, `:820-843`). The menu-bar error badge comes
  from `AppDelegate.handleDictationFailure` (`:562-585`) and expires on a timer.
- Settings shows only whether a key exists: "Key saved" / "No key"
  (`SettingsView.swift:1029-1040`, `SettingsStore.apiKeyPresence`).

## Behaviour

1. **Classify.** Cloud failures get a kind:
   - `billing`: HTTP 402, or a body naming payment, subscription or quota
     (ElevenLabs `payment_issue`, `quota_exceeded`)
   - `auth`: 401/403 for an invalid key, revoked key or missing permission
   - `rateLimited`: 429
   - `transient`: everything else, including network errors and 5xx

   The kind and HTTP status are structured fields on the error, not text to
   be parsed later. Realtime handshake 401/402/403 counts as provisional
   `auth`, and the batch attempt on the same hold (which has the body) makes
   the call final.
2. **Provider health.** One in-memory record per provider: state (`ok`,
   `refusing(kind, since)`, `rateLimited(until)`) and the time of the last
   rejection. Never the key, never the transcript.
   - `billing` / `auth` → `refusing`.
   - `rateLimited` → skip that provider for 60 s.
   - `transient` → no change. Today's fallback behaviour is unchanged.
3. **Skip what will fail.** While a provider is `refusing`, a hold with that
   provider selected goes straight to the local engine: no stream, no batch.
   A retry fires on the first hold more than 5 minutes after the last
   rejection. It also fires on relaunch, or when the key is saved again in
   Settings. A success sets the provider back to `ok` and clears every
   notice.
4. **HUD.** While a provider is refusing, the hold shows an amber notice in
   the same style as the mic warnings:
   - title: "ElevenLabs: payment needed" (or "key rejected", "rate limited")
   - subtitle: "Using on-device · may be slower"

   It appears at hold start and stays through processing. It never blocks or
   cancels the hold. The dictation still injects normally.
5. **Menu bar.** The error badge stays on, with no expiry, while any
   selected provider is refusing. The menu gains one item at the top:
   "ElevenLabs: payment needed — Open billing…" (the provider's billing or
   key page).
6. **Settings.** Under the provider's key row, the amber line reads:
   "Rejected 8:43 PM: payment needed. Dictation is using on-device."

   It has two buttons:
   - **Check now**: sends a 1 s silent clip to the provider's batch endpoint.
   - **Open billing**: opens the provider's billing or key page.

   "Key saved" returns once a request succeeds.
7. **xAI too.** The same classifier and health record apply to xAI, using its
   status codes and body keywords. Gemini, Groq and Muse get the classifier
   for free if they throw `httpStatus`, but none of them is required to.

## Non-goals

- Silently switching to a different cloud provider.
- macOS notifications, email, or polling a provider's billing API.
- Persisting provider health across launches. A relaunch retries.
- Changing the transient-failure path or the stream-coverage logic.

## Slices

- **A (one session): engine.** Classifier, structured error fields, the
  realtime handshake status, the provider-health store, the pipeline skip,
  and the retry window.
  - Tests: classifier fixtures, including the real ElevenLabs
    `payment_issue` body from 2026-10-26; the health state machine (refuse,
    expiry, success clears, key save clears); and the pipeline skipping
    cloud while refusing, with the local engine called once.
- **B (same or next session): surfaces.** HUD notice, menu badge and item,
  Settings status line with Check now and Open billing, built from the
  approved mock.

## Verification

- Build plus the `VoiceTests` suite (local oracle, at most 3 runs).
- The HUD and Settings rendered at real size from the app and compared to
  the mock. The surfaces are checked through the accessibility tree.
- Real app: `install-local.sh`, one fn-hold, then
  `oracle-dictation-start.sh` must exit 0, so normal dictation is unchanged.
  - A real refusal can't be staged without touching the live key. The
    refusing path is proven by the unit and pipeline tests.
  - **Check now** gets one real run against the live key, which should
    report OK.

## Open questions for Matt

- Is a 5-minute retry window right? A shorter one costs a stream attempt
  per hold while the account is down.
- Should the provider's billing page open from the HUD itself, or only from
  the menu bar and Settings? Recommended: menu bar and Settings only,
  because the HUD is not clickable today.
