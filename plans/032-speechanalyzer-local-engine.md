# 032 — Apple SpeechAnalyzer as the zero-setup local engine

**Status:** APPROVED 2026-10-10 (Matt). Decision: Apple is the default only for fresh installs with no cloud key; existing users keep their engine. Slice A in progress.
**Origin:** 030 peer comparison, gap 3 (VoiceInk and Yap ship it; every
commercial peer works on first launch, Murmur does not).

## Goal

A fresh install transcribes offline on first launch with no model download
and no Python. Apple's SpeechAnalyzer / SpeechTranscriber (macOS 26, the
app's floor) becomes a third local engine and the default for a user who has
chosen neither a cloud key nor a Whisper/Parakeet download.

## What exists

- `ASREngine` protocol (`ASREngine.swift`): `id`, `displayName`,
  `transcribe(audioURL:) async throws -> String`. WhisperKit and Parakeet
  implement it; the pipeline does not care which.
- `LocalModel` (`LocalModel.swift`) owns the picker rows and maps each to an
  `ASREngineID`; `ModelManager` owns download state.
- Nothing in `Sources/` imports `Speech` today.

## Behaviour

1. New `ASREngine` conformer `AppleSpeechEngine` using
   `SpeechAnalyzer` + `SpeechTranscriber` on the recorded file (batch, not
   streaming, in slice A). Language from the existing language setting.
2. New `LocalModel` case "Apple (built in)" with no download row; the
   picker shows it as ready. Assets are managed by the system
   (`AssetInventory`); if the locale's assets are not installed, request them
   through the system API and show the system's progress, never our own
   downloader.
3. First-run default: if no cloud key and no downloaded model, the engine is
   Apple. Existing users keep their current selection.
4. Insights/History record the engine as "Apple" like any other.

## Non-goals

- Streaming/live text with SpeechAnalyzer (slice B, later, if batch latency
  is acceptable).
- Replacing WhisperKit or Parakeet; they stay selectable.
- Speaker gating integration beyond what the pipeline already does per file.

## Open decisions (yours)

- Should Apple become the default for *everyone* with no cloud key, or only
  fresh installs? (Recommendation: fresh installs only; do not move a user's
  engine under them.)

## Risks

- Accuracy and punctuation differ from Whisper; the cleanup gate (030 R-04)
  and spoken-punctuation pass must be checked against its output.
- The local path is the least-exercised in real use (memory
  `murmur-local-path-is-unexercised`); this needs real holds, not just the
  suite.

## Verification

- Unit: `LocalModel` mapping, first-run default decision, engine id in
  History rows.
- Product: fresh user account or wiped `~/Library/Application Support/Voice`
  in a test profile, no keys, first hold transcribes; `oracle-dictation-start`
  passes; a 20-second hold round-trips.

## Effort

M. Slice A (engine + picker + default), slice B (streaming) optional.
