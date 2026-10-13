# 033 — Mic health: warn before a hold is lost

**Status:** APPROVED 2026-10-10 (Matt). Decision: no-audio hint after 1.5 s of silence, hold not interrupted. Slices A+B in progress.
**Origin:** 030 peer comparison, gap 2 (Superwhisper, Wispr, Aqua). This is
Murmur's own most-recorded failure class: Continuity/Jump Desktop
fall-through, wedged input after an external voice app, zero-buffer taps.

## Goal

The user is told, before or during a hold, when Murmur is not actually
hearing them, and can choose which microphones Murmur may use.

## What exists

- Device picking in `AudioRecorder.swift` (`pickInputDevice`, last-resort
  set for Continuity `ccwl` and virtual `virt` transports, opt-in fallback).
- Zero-buffer watchdog (`zeroBufferWatchdogDelay`, ~line 737 and 1913):
  detects "engine started, no audio arrived" internally and rebuilds once.
- `onFailure(.micDeliveredNoAudio / .micStartFailed)` already reaches the
  HUD as an error pill after the fact.
- RMS is computed per buffer for the HUD level meter.

## Behaviour

1. **No-audio warning during a hold.** If RMS stays at silence for the
   first ~1.5 s of a hold while the engine reports running, the HUD switches
   to "No microphone audio" with the device name. The hold continues (the
   user may just be pausing); the warning clears on the first real buffer.
2. **Device choice in Settings.** A "Microphone" row: Automatic (today's
   behaviour), or a specific input device; plus an "Never use" list for
   devices the user wants excluded (Continuity iPhone, Jump Desktop virtual
   mic, a bad webcam). Excluded devices are removed from the candidate set,
   not just deprioritised.
3. **Lid-closed warning.** When the chosen/automatic device is the built-in
   MacBook mic and the lid is closed (clamshell: internal display inactive),
   the HUD warns "Built-in mic may be covered" at hold start.
4. **History evidence.** A hold that produced no audio is recorded with the
   device name so Insights can show "N holds with no audio this week".

## Non-goals

- Automatic switching mid-hold (route-change handling already exists and
  is fragile; do not touch `engine.start`, `prepare()`, or tap install).
- Audio processing (noise suppression, ducking other apps).

## Open decisions (yours)

- Warning after 1.5 s of silence may fire for people who think before they
  speak. Alternative: warn only after 3 s. (Recommendation: 1.5 s, since
  the hold is not interrupted; it is a hint, not an abort.)

## Verification

- Unit: candidate filtering with an exclusion list; the silence→warning
  decision as a pure function over RMS samples and elapsed time; lid-state
  decision.
- Product (this is an AudioRecorder change, so the CLAUDE.md product oracle
  applies): `install-local.sh`, a real hold, `oracle-dictation-start.sh`
  exit 0; mute the mic in System Settings and hold: the warning appears;
  exclude the Continuity device and confirm it never gets picked.

## Effort

M. Slices: (A) exclusion list + device row, (B) no-audio warning, (C) lid
warning + Insights count.

## Slice C — low delivered microphone level (2026-10-13)

After at least 2.0 seconds of delivered audio and 1.0 second of speech
frames, compare the speech frames' 90th-percentile RMS with -40 dBFS. Estimate
the room floor with the 10th percentile of all frames; only frames at least
6 dB above that floor establish speech. Uniform room noise shows no low-level
hint. Each tap buffer is one RMS frame weighted by its delivered duration
(nominally ~100 ms); sample sums are computed outside `levelLock`, and pure
functions evaluate percentiles off the audio thread.

The nonblocking hint says “Mic level is very low” / “Move closer or raise
input volume”, uses the no-audio presentation and accessibility path, and
leaves recording, stop, and transcription unchanged. The no-audio threshold
still owns holds whose maximum RMS stays below 0.007. Low-level hints cool
down for 10 minutes and never appear on consecutive holds.

Round 2 traced the 32,000 → 31,744 frame test failure to a partial
`AVAudioFile.read`: capture, combination, and the retained CAF all contain
32,000 frames. The synthetic engine now drains reads through the final
256-frame tail. A separate production retention-handoff test confirms the
complete file and tail; no production audio-loss change was needed.
