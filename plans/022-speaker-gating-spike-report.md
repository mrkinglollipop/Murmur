# 022 — Speaker-gating feasibility spike (P5 answer)

Spike only. No production code changed. Answers plans/021 §P5.

## Verdict: GO (gating), with caveats. Extraction: NOT viable off-the-shelf today.

Per-frame speaker-embedding gating clears the <20ms/frame bar with large
margin even on an unoptimized CPU-only Python path. A permissively-licensed
Swift/CoreML SDK (FluidAudio) already exists and removes most of the
"convert a model myself" risk. Full target-speaker *extraction* (separating
overlapping speech, not just attenuating non-matching frames) has no
permissively-licensed, weights-available, streaming implementation — that
capability stays out of scope; the P5 build brief should be gating-only.

## 1. Candidate models

| Model / SDK | License | Diarization/embedding on CoreML? | Streaming? | Notes |
|---|---|---|---|---|
| **FluidAudio SDK** (github.com/FluidInference/FluidAudio) | **Apache 2.0** | Yes — native Swift, CoreML, ANE-targeted | Yes (LS-EEND: 100ms frame updates, up to 10 speakers; Streaming Pyannote) | Ships pre-converted CoreML models on HuggingFace (FluidInference/speaker-diarization-coreml). WeSpeaker embeddings extracted as part of pipeline. Claims ~190x real-time on M4 Pro for full ASR pipeline (not the embedding step alone — not directly comparable to our ms/frame bar). Builds on sherpa-onnx techniques. Best production candidate: no conversion work needed. |
| **speechbrain/spkrec-ecapa-voxceleb** (ECAPA-TDNN) | **Apache 2.0** | No — PyTorch checkpoint only; CoreML conversion not done by us in this spike | No (single-frame embedding, not inherently streaming, but frame-by-frame call pattern works fine for our gating use case) | Used for the measured prototype below. 192-dim embedding, ~85MB checkpoint, trained on VoxCeleb1+2. |
| WeSpeaker (standalone) | Apache 2.0 | Available as ONNX exports; CoreML conversion not verified in this spike | Frame-callable | Same embedding family FluidAudio already consumes; redundant with FluidAudio as an SDK choice. |
| Third-party fork `ngoldbla/fluidaudio` | Inherits Apache 2.0 (fork) | Same | Same | Just a fork of FluidInference/FluidAudio; use upstream. |

No GPL/AGPL candidates were seriously considered — everything above is
Apache-2.0. No candidate required auth or exceeded ~2GB (largest download
this spike made was ~85MB).

## 2. Measured prototype (Python, CPU-only, upper-bound)

Ran `speechbrain/spkrec-ecapa-voxceleb` (Apache 2.0) in a scratch venv,
PyTorch CPU backend (**no MPS/ANE acceleration** — this is a pessimistic
upper bound, not the CoreML number), on this machine (Apple **M5 Max**).
Fifty synthetic 1s/16kHz random-noise frames, 5-frame warmup excluded.

- **ms/frame: mean 11.61, median 11.52, p90 12.06, min 10.78, max 13.64**
  — clears the <20ms bar with ~40% margin, on CPU eager-mode PyTorch, with
  zero ANE/CoreML optimization. A CoreML/ANE path (FluidAudio's actual
  deployment target) should do meaningfully better, not worse.
- **Model size on disk:** ~85MB total download (embedding checkpoint itself
  ~79MB), well under the 2GB spike ceiling, no auth required.
- **Peak process RSS: ~401MB** — this is Python+PyTorch process overhead,
  not representative of a lean Swift/CoreML runtime; treat as noise, not a
  memory-footprint estimate for the real integration.
- **Sanity check:** cosine(same frame, itself) = 1.000; cosine(frame A,
  independent-random frame B) = 0.935. Random-noise inputs are a poor
  discriminability test (no real speaker structure) — this only confirms
  the embedding call path and cosine-similarity plumbing work, it says
  nothing about real-world enrolled-vs-imposter separation, which needs a
  follow-up with actual recorded speech before any build.
- **Conversion effort (not measured, estimated):** if going the "convert
  ECAPA-TDNN to CoreML myself" route, effort is small-to-moderate
  (`coremltools` conversion of a standard TDNN+SE+attentive-pooling stack,
  known-working conversions exist in the wild per web research). This
  route is very likely unnecessary — see FluidAudio above, which ships
  the conversion already done and licensed compatibly.

Caveat stated per instructions: Python timing is an upper bound. Real
integration should re-measure the actual FluidAudio CoreML path on-device
before committing to numbers in a build brief.

## 3. macOS Voice Isolation desk-check

- API: `AVCaptureDevice.MicrophoneMode.voiceIsolation` (AVFoundation).
  Also present: `.standard`, `.wideSpectrum`.
- **User-controlled, not app-settable.** Per Apple's own developer forum
  guidance: "Users are always in control; your app can't set the Mic Mode
  directly." An app can read `preferredMicrophoneMode` /
  `activeMicrophoneMode`, and can *prompt* the system picker via
  `AVCaptureDevice.showSystemUserInterface(.microphoneModes)`, but the
  user makes the final choice (Control Center or the prompted sheet) —
  Murmur cannot force it on silently.
- **Suppresses noise, not other speakers.** Apple's description: Voice
  Isolation "enhances speech and removes unwanted background noise such as
  typing on keyboards, mouse clicks, or leaf blowers." Nothing in Apple's
  docs claims suppression of *other human voices/speakers* specifically —
  it's a noise-suppression mode, not a speaker-identity gate. It does not
  substitute for enrolled-speaker gating; at best it's a free, cheap,
  complementary layer (reduces ambient noise before our gate runs), not a
  replacement for it.
- Related: `AUVoiceIO`'s `kAUVoiceIOProperty_BypassVoiceProcessing` does
  not escape the Control-Center-selected mic mode — confirms this is
  fully user-owned, system-level behavior, not something we integrate
  against programmatically beyond the read-only observation + prompt APIs
  above.

**Sources:** github.com/FluidInference/FluidAudio (README, Apache 2.0);
huggingface.co/speechbrain/spkrec-ecapa-voxceleb (Apache 2.0, VoxCeleb1+2);
developer.apple.com/documentation/avfoundation/avcapturedevice/microphonemode/voiceisolation;
developer.apple.com/documentation/avfoundation/avcapturedevice/preferredmicrophonemode;
Apple Support HT213683 (Voice Isolation description); Apple developer
forum thread 728370 (AUVoiceIO bypass behavior).

## 4. Risks

- **Overlapping speech is not separated.** Gating only attenuates frames
  whose *whole-frame* embedding doesn't match the enrolled speaker — two
  people talking over each other in the same 1s window will not be
  cleanly split. This is a hard limitation of the gating approach (vs.
  full extraction, see §Phase-2), and should be stated plainly in any
  user-facing description ("reduces cross-talk," not "removes other
  people's voices").
- **Enrollment UX.** 30s read-aloud enrollment is a real new onboarding
  step; needs a clear script, re-enrollment path (voice changes: cold,
  mic swap), and a way to disable/redo it without support intervention.
- **Threshold tuning.** Cosine-similarity threshold is a single global
  knob with no ground truth in this spike (only tested on random noise,
  not real enrolled-vs-imposter speech) — real threshold selection needs a
  small real-speech dataset before ship, not just this spike's numbers.
- **Fail-open is load-bearing.** Per §P5, gating must never break
  dictation. Any embedding-extraction failure, low-confidence frame, or
  missing enrollment must default to "pass audio through ungated" — this
  needs to be a hard invariant in the eventual implementation, tested
  explicitly, not an assumption.
- **FluidAudio dependency risk.** It's a young, fast-moving SDK (frequent
  API changes typical of this class of project) — pin a version, don't
  track `main`, and re-verify the license file at integration time (not
  just at spike time).

## 5. Recommended architecture sketch (IF go)

- Gate sits **inside the existing `AVAudioEngine` input tap**, after
  whatever pre-processing already runs (e.g. any existing noise handling)
  and *before* frames are handed to the cloud-ASR streaming path — same
  insertion point where audio currently leaves the tap callback.
- Per ~1s (or smaller, e.g. 200-300ms, if FluidAudio's frame-update cadence
  makes that the natural unit — LS-EEND updates at 100ms) buffered chunk:
  extract embedding → cosine-similarity vs. the stored enrolled-reference
  embedding → below threshold: attenuate (not hard-mute — soft
  attenuation avoids clipped-word artifacts at speaker-switch boundaries)
  → above threshold or **extraction/embedding failure of any kind**:
  pass through unmodified (fail-open, per §P5 and the risk above).
  Chunking granularity is only a probable landing point (the spike didn't
  test AVAudioEngine tap integration), so `plans/022`, not
  `plans/022-final`.
- Enrollment: one-time 30s read-aloud captured through the same tap,
  averaged/pooled into a single reference embedding, stored locally
  (Keychain or the existing app-support data dir — never sent to any
  cloud service; this is an on-device-only feature).
- No change to the cloud ASR boundary itself — gating produces the same
  audio format/rate it already streams, just attenuated for
  non-matching frames.

## Phase-2: full target-speaker extraction (desk research only, not benchmarked)

Operator asked, separately from the gating spike, whether full extraction
(actually separating overlapping speech, not just attenuating
non-matching frames) is realistically available off-the-shelf. Desk
research only — nothing below was run or measured.

| Candidate | License | Weights published? | Causal/streaming? | Real-time claim |
|---|---|---|---|---|
| **VoiceFilter-Lite** (Google, Interspeech 2020) — the model explicitly designed for this: streaming, on-device, quantizable to int8 | N/A | **No** — Google-internal, no official code or weights released | Yes, by design (paper claims) | Paper claims real-time on-device, but unverifiable — no public implementation exists |
| Unofficial **VoiceFilter** re-implementations (`maum-ai/voicefilter`, others) | Apache 2.0 | Partial — a pretrained *d-vector speaker-embedding* model is provided; the separation model itself must be trained from scratch on LibriSpeech by the user | **No** — original offline VoiceFilter, not the Lite/streaming variant; author's own README calls it unreliable ("obvious mistakes") | None credible |
| **Personalized PercepNet** (Amazon Science / Interspeech 2021) | N/A | **No** public code or weights found | Yes, by design (10ms frames, paper reports 4.7-17.2% of one mobile x86 core) | Real, but paper-only — nothing to run |
| **ClearerVoice-Studio** (Alibaba/ModelScope) — includes an audio-only target-speaker-extraction task conditioned on reference speech | **Apache 2.0** | **Yes** — ships pretrained models via HuggingFace/ModelScope | **Unconfirmed** — architecture (MossFormer2-class) reads as offline/batch in the docs pulled; streaming/causal support not verified in this desk pass | Not established for CPU/Apple Silicon in materials reviewed |
| 2025-2026 research (StarTSE, DSINet, SpeakerBeam-SS, REAL-TSE challenge systems) | Mostly unstated / research-only | **No** public weights found | Yes, several are explicitly causal | RTF reported on GPU (RTX 4090, V100, L40S) — none benchmarked on CPU or Apple Silicon in materials reviewed |

**Phase-2 verdict: No.** No permissively-licensed, weights-available,
confirmed-streaming target-speaker-extraction implementation exists today
that we could pick up and run. The one model purpose-built for this
(VoiceFilter-Lite) was never open-sourced by Google. The one
permissively-licensed option with real published weights
(ClearerVoice-Studio, Apache 2.0) has unconfirmed streaming support and
would need its own from-scratch feasibility spike (latency + causality
verification) before it could even be considered — it is not a drop-in.
Everything else is either paper-only, GPL-adjacent-unclear, or requires
training a model from scratch on a dataset we'd have to assemble.
**Recommendation: do not scope extraction into any near-term build brief.**
Gating (attenuation of non-matching frames, this spike's primary
deliverable) is the viable near-term feature; full overlapping-speech
separation is a distinct, much larger R&D effort with no existing
off-the-shelf answer, and should be revisited only if a
permissively-licensed streaming TSE model with public weights and
verified Apple Silicon performance appears later.
