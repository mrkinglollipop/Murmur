# 021 — FluidVoice-inspired improvements: scope

Status: DRAFT — awaiting operator approval. Written against `e9f1466` (0.1.12).

Origin: review of https://github.com/altic-dev/FluidVoice (GPLv3 since 2026-02).
**License boundary: ideas only, zero code.** GPLv3 code in this repo would
obligate releasing Murmur's full source under GPLv3 on distribution. Every item
below is an independent implementation of a concept.

Recon ground truth (2026-07-28, Cursor ask-mode over this repo):

- Corrections already exist and auto-learn: `DictionaryStore.correct(_:)`
  (`UI/DictionaryStore.swift:221-257`) — whole-word `\b…\b` regex, case-insensitive,
  replaces with canonical term casing; `learn(from:to:)` (`:259-319`) auto-learns
  from History edits at similarity ≥ 0.5. Pipeline order: cleanup → auto-transform
  (`TranscriptionPipeline.swift:201-214`) → dictionary (`:256-261`) → snippets → insert.
- Live preview already exists: both streaming engines emit partials mid-hold
  (`XAIStreamingTranscriber.swift:526-545`, `ElevenLabsRealtimeTranscriber.swift:468-474`)
  → `hud.showInterimText`. FluidVoice's "Live Preview" is not a gap; its polish is.
- HUD flicker has identified suspects: interim `resizePanel` races
  (`RecordingHUD.swift:131-138` vs `:261-273`), processing-expand vs interim-clear
  (`:120-126` vs `:143-149`), re-show during fade-out completion (`:233-241`),
  `hide` racing the 0.6 s success/clipboard timers, and — aggravating all of it —
  `TextInjector.insert()` blocking the MAIN thread up to ~1 s
  (`TranscriptionPipeline.swift:256-261` dispatches to main; `TextInjector.swift:154`
  sleeps 250 ms there) since the 0.1.12 delivery-verified injector.

## P1 — HUD de-flake (bug + polish) — the operator sees this today

1. Move the entire insert pipeline off the main thread: dispatch
   `TextInjector.insert` on a utility queue from `TranscriptionPipeline`;
   hop back to main only for the completion that drives
   `finishHUDAfterPipeline`. `HistoryView` insert buttons get the same
   treatment. (CGEventPost and NSPasteboard are safe off-main.)
2. Serialize HUD state transitions: single source of truth for
   pending-hide/flash timers (cancel outstanding timer on every transition),
   coalesce interim-text resizes (only animate growth, snap shrink at hide),
   and guard re-show during fade-out.
3. Verification: build + tests, then live dictation while watching the HUD —
   operator confirms no flicker; `inject-debug.log` still shows
   `paste confirmed` (no delivery regression from re-threading).

## P2 — Correction model, phonetic layer ("do better" on dictionary)

Today's regex only fires when the ASR output contains the dictionary term
verbatim. Dictation errors are phonetic ("Heiser" → "hyzer", "Groq" → "grok"),
so exact matching misses precisely the cases the dictionary exists for.

1. Add a phonetic index over dictionary terms (Double Metaphone or trigram
   similarity — pick in brief after a spike on transcript samples from History).
2. On each transcript, generate per-word candidates; replace when phonetic
   match ≥ threshold AND term is in the user dictionary. Never touch words
   the user hasn't listed.
3. Surface auto-learned entries in the Dictionary UI (they exist but are
   invisible today — `isAutoLearned` flag): review/approve/delete list.
4. **Visual layer (operator-requested 2026-07-28): corrections must be
   visible, not silent.**
   a. HUD: when corrections fire on a transcript, the success state shows a
      compact "N corrected" note (expandable detail deferred — HUD stays
      glanceable).
   b. Dictionary tab: a "Recent corrections" feed — timestamp, `heard → replaced`
      pair, source (dictionary | phonetic | auto-learned), with per-row actions
      "Revert" (undo this replacement pattern) and "Never" (blocklist the pair).
   c. Mock approval gate: HTML mock presented in-session; P2 brief does not
      dispatch until the operator approves the mock (planning-discipline rule).
5. Out of scope: LLM-based correction (Transforms already covers rewrite),
   per-app dictionaries (no demand yet).

## P3 — Audio history: budget + export (small) — DONE 2026-07-28

Retention exists (`RecordingRetention`); add a size budget (delete oldest
past N MB, setting in Storage UI) and a ZIP export of retained recordings +
transcripts. Mirrors FluidVoice's "budget controls and ZIP export".

Shipped: `recordingBudgetMB` (50–1000 MB picker), prune-by-bytes on retain +
budget change, Settings → Storage usage line + export ZIP
(`recordings/` + `transcripts/` + `manifest.json`).

## P4 — Dictation ergonomics (operator-requested 2026-07-28)

1. **Smart leading space.** Injected text after existing content currently
   glues to the previous sentence ("…message.Next"). Fix: before insertion,
   read the character left of the caret via AX (focused element value +
   selected range); prepend " " when it is a sentence-ender or alphanumeric.
   Electron targets commonly refuse caret AX reads — fallback heuristic:
   prepend a space when the transcript starts alphanumeric, behind a
   Settings toggle ("Smart leading space", default on). Never prepend when
   AX confirms start-of-field/line or preceding whitespace.
2. **Dot-compound number normalization.** ASR emits "flux.one" for
   "flux.1". Add a cleanup rule scoped to dot-compounds only:
   `word.numberword` → `word.digit` (zero–nine). Prose like "chapter one"
   is untouched. Specific named products remain Dictionary entries
   (exact replacement already works today).

## P5 — Voice enrollment + on-device speaker gating (SPIKE DONE 2026-07-28: GO on gating, NO on extraction — see plans/022)

Goal: dictation focuses on the enrolled operator's voice; nearby speakers are
attenuated before audio streams to the cloud engine (Personal-VAD style).
Spike first — numbers before feature:

1. Candidate models: speaker-embedding (ECAPA-TDNN class) runnable via
   CoreML/MLX on Apple Silicon; check existing Swift packages (e.g.
   FluidAudio SDK — verify license and that it is NOT GPL before any
   dependency decision) vs. converting a model directly.
2. Measure on this Mac: embedding extraction latency per 1s frame, added
   end-to-end dictation latency when gating runs in the AVAudioEngine tap,
   memory footprint. Go bar: < 20 ms per frame, no audible pipeline delay.
3. Gating design sketch: enrolled reference embedding (30 s read-aloud),
   cosine-similarity per frame, attenuate below threshold; fail-open
   (no gating) when confidence is low so dictation never breaks.
4. Also check: whether AVAudioEngine capture can opt into macOS Voice
   Isolation mic mode (cheap partial win, no enrollment).
5. Deliverable: go/no-go report with measurements in plans/ (no production
   code); if GO, a P5 build brief follows.

Build phasing (post-GO, dispatched 2026-07-28):
- **Session A (in flight)**: FluidAudio dependency (pinned release, Apache
  2.0), VoiceGate engine (enrollment computation, per-window gating,
  fail-open invariants), profile persistence, tap wiring behind
  `speakerGatingEnabled` (default OFF, no UI). Inert until enrollment.
- **Session B**: Settings UI — "Focus on my voice" toggle + sensitivity,
  guided ~30s enrollment flow, re-enroll/delete profile. PLUS an
  **Acknowledgements section** (Settings or About): WhisperKit (MIT),
  Sparkle (MIT), FluidAudio (Apache 2.0 + its NOTICE if present), full
  license texts. This is a pre-existing compliance gap — WhisperKit and
  Sparkle ship today with no in-app attribution — not just a FluidAudio
  requirement. Operator decision 2026-07-28: consume FluidAudio upstream
  pinned, no fork unless the project dies or drifts (Apache grant on the
  pinned version is the permanent escape hatch).

## Considered and rejected

- **Command Mode** (voice-driven app launching / Shortcuts / automation):
  different product with a real security surface; Murmur is a dictation tool.
  Revisit only as a deliberate product decision.
- **Notch-anchored overlay variant**: cosmetic alternative to the existing
  HUD; no functional gain until P1 lands. Re-evaluate after.
- **"Fluid Intelligence" local formatting model**: their model is private
  (not in the GPL repo anyway); Murmur's Transforms + auto-transform covers
  the use case via configured LLMs.

## Order and dependencies

P1 first (visible bug, small, de-risks everything HUD-adjacent). P2 and P3
independent of each other and of P1. One brief per P-item once approved.
