# Plan 014: Use Scribe RT's native polish (`no_verbatim` + `keyterms`) and retire the LLM cleanup round-trip

> **Executor instructions**: Follow step by step. Run every verification
> command and confirm the expected result before moving on. On any STOP
> condition, stop and report — do not improvise. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 2e7e6e9..HEAD -- Sources/Voice/ElevenLabsRealtimeTranscriber.swift Sources/Voice/UI/DictionaryStore.swift Sources/Voice/UI/SettingsView.swift`

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (changes transcript content; `no_verbatim` can swallow spoken corrections)
- **Depends on**: none (Scribe RT engine is on `main` and working in production)
- **Category**: direction / perf
- **Planned at**: commit `2e7e6e9`, 2026-07-10

## Why this matters

Murmur currently transcribes with ElevenLabs Scribe v2 Realtime, then sends
the text on a SECOND network round-trip to xAI Grok's chat model for cleanup
(punctuation/style polish), then applies `DictionaryStore` corrections to fix
misheard jargon after the fact. Scribe RT can do both jobs itself, at
transcription time, for free:

- **`no_verbatim`** removes filler words, false starts, repeated phrases and
  stuttering inside the ASR model — the polish the cleanup LLM is doing.
- **`keyterms`** biases the model toward a supplied vocabulary — meaning the
  user's auto-learned dictionary terms (code identifiers, jargon) can be
  transcribed CORRECTLY THE FIRST TIME instead of patched afterwards.

Payoff: one fewer network hop per dictation (cleanup is a full LLM call after
the transcript already exists), no xAI dependency on the ElevenLabs path, and
the learned dictionary starts working proactively rather than reactively.

Evidence the cleanup pass is low-value on this engine: the 2026-07-09
bake-off measured Scribe RT's RAW output at 0.024 mean WER against the final
text the user actually accepted (5 real dictations, 25 attempts, deterministic
output) — the raw transcript is already nearly identical to the kept text.

## Current state

- **Verified against the live docs 2026-07-09**
  (`https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime`):
  both parameters are QUERY-STRING parameters on the realtime WebSocket URL,
  not config-message fields:

  | Param | Type | Default | Doc text |
  |---|---|---|---|
  | `no_verbatim` | boolean | `false` | "Whether filler words and disfluencies are removed" |
  | `keyterms` | array of strings | — | "List of keyterms the model is biased towards" |

  Others already in use or available: `model_id`, `audio_format`
  (`pcm_16000`), `language_code`, `commit_strategy` (`manual` | `vad`),
  `include_timestamps`, `filter_background_audio`, VAD tuning params.

- `Sources/Voice/ElevenLabsRealtimeTranscriber.swift` builds the socket URL.
  Find it with `grep -n "speech-to-text/realtime" Sources/Voice/ElevenLabsRealtimeTranscriber.swift`
  — it currently passes only `model_id` and `audio_format` (plus whatever else
  is there; read it, do not assume).
- `Sources/Voice/UI/DictionaryStore.swift` holds the correction entries. Each
  entry has a canonical `term` and a list of misheard `variants`, and an
  `isAutoLearned` flag (`grep -n "struct DictionaryEntry" -A 12 Sources/Voice/UI/DictionaryStore.swift`).
  Only the `term` side belongs in `keyterms` — never the variants (those are
  the WRONG spellings; biasing toward them would be counterproductive).
- Cleanup lives in `Sources/Voice/CleanupService.swift` (backends: `onDevice`,
  `cloud`, `xaiGrok`) and is toggled by `SettingsStore.cleanupEnabled` /
  `cleanupBackend` (UserDefaults keys `voice.settings.cleanupEnabled`,
  `voice.settings.cleanupBackend`).

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | From repo root: `cp -n Config/Team.xcconfig.example Config/Team.xcconfig 2>/dev/null; xcodegen generate` | Created project |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` (98 baseline + yours) |
| Install  | `bash scripts/install-local.sh` | fresh `/Applications/Murmur.app` |

Hard cap: 3 oracle runs per change. Adding a test FILE requires re-running
`xcodegen generate` before the test oracle. Never edit a file to reset a guard.

## Scope

**In scope**: `ElevenLabsRealtimeTranscriber.swift` (URL building), a small
keyterms-supply seam (see Step 2), `SettingsView.swift` (one toggle),
`SettingsStore.swift` (one persisted key), `Tests/VoiceTests/`,
`plans/README.md`.

**Out of scope**:
- Deleting or rewiring `CleanupService` — the user turns cleanup off in
  Settings themselves; this plan does NOT remove the cleanup subsystem, which
  is still used by the xAI/local engines.
- The xAI streaming path.
- `DictionaryStore`'s correction pass — it stays as the safety net; keyterms
  is a *prophylactic*, not a replacement.

## Git workflow

- Branch: `feat/elevenlabs-native-polish` off main. Isolated `git worktree` if
  the shared checkout is dirty (prior agents did this successfully).
- Conventional commits; `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Do NOT push, do NOT open a PR.

## Steps

### Step 1: Add `no_verbatim` behind a Setting

Add `SettingsStore.removeFillerWords` (Bool, default **false** — opt-in; see
STOP/maintenance notes on why this is not defaulted on), persisted under
`voice.settings.removeFillerWords`. Thread it into the socket URL as
`no_verbatim=true|false`. Add a Settings toggle labeled something like
"Remove filler words (ElevenLabs)" shown ONLY when the selected cloud model's
provider is `.elevenLabs` — copy the visibility pattern used for the xAI
"Live streaming" toggle (`grep -n "provider == .xai" Sources/Voice/UI/SettingsView.swift`).

**Verify**: build green; `grep -n "no_verbatim" Sources/` → 1 hit in the URL builder.

### Step 2: Feed the learned dictionary into `keyterms`

Add a supply seam so the transcriber does not import the UI store directly —
e.g. a `keytermsProvider: () -> [String]` closure on the transcriber (or on
`ASREngineSelector`, matching however `apiKeyProvider` is already wired —
`grep -n "apiKeyProvider" Sources/`). Wire it in `AppDelegate` to return the
dictionary's canonical terms.

Selection rules (implement as a pure, testable function):
- Canonical `term` values ONLY. Never `variants`.
- De-duplicate, drop empties, drop single-character terms.
- **Server-enforced limits (probed live 2026-07-09 — NOT the values first
  assumed here): at most 50 keyterms per session, each at most 20 characters.**
  Exceeding either returns `invalid_request` and kills the whole handshake, so
  drop over-long terms and cap at 50, preferring highest `fixCount`,
  tie-broken by most-recently-added.
- The param is an ARRAY sent as **repeated** `keyterms=a&keyterms=b` (probed
  live: comma-joined is parsed as one over-long keyterm and rejected).

**Verify**: unit tests below.

**RESOLVED at implementation (2026-07-09):** the assumptions above were
corrected against the live socket. Cap is 50 (not 100), per-term length limit
is 20 chars (was unstated), encoding is repeated params. See `maxKeyterms`,
`maxKeytermLength`, and the `buildSocketURL` doc comment in the code.

### Step 3: Tests

Add `Tests/VoiceTests/ElevenLabsKeytermsTests.swift` (`@testable import Voice`,
model on an existing test file):
- The selection function returns canonical terms only, never variants.
- De-dup, empty, and single-char cases.
- Cap enforced at 100; ordering rule honored.
- URL builder includes `no_verbatim` reflecting the setting, and includes the
  keyterms in whichever encoding Step 4 confirms.

**Verify**: `xcodebuild test ...` → `** TEST SUCCEEDED **`, count increased.

### Step 4 (live oracle, REQUIRED): prove the wire format

The operator's key is in the operator's local ElevenLabs key file (never commit keys).
Read into memory only — NEVER print, log, or persist the value. Write a
THROWAWAY script in the scratchpad (not the repo) that opens the realtime
socket with `no_verbatim=true` and a couple of `keyterms`, streams one
retained recording (`~/Library/Application Support/Voice/Recordings/*.caf`,
transcode with `afconvert -f WAVE -d LEI16@16000 -c 1`, strip the 44-byte
header, ~100ms chunks), and confirms: (a) the socket ACCEPTS the params (no
4xx close, `session_started` arrives), (b) a `committed_transcript` still
returns. Try the repeated-param form first; if rejected, try comma-joined.
Report which form the server accepted.

If the socket rejects both forms, STOP — do not ship a guess.

## Test plan

Unit tests in Step 3 (pure selection + URL building). The live oracle in
Step 4 is the wire-format gate. No new integration test — the existing engine
tests cover the socket lifecycle.

## Done criteria

- [ ] `no_verbatim` sent, driven by a Setting that is visible only for ElevenLabs
- [ ] `keyterms` sent, sourced from `DictionaryStore` canonical terms, capped and de-duped
- [ ] Live oracle confirms the server accepts the params and still returns a transcript; the accepted encoding is documented in a code comment
- [ ] Build + full suite green
- [ ] `CleanupService` untouched (`git diff --name-only` shows no changes to it)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The realtime socket rejects both keyterms encodings → report; do not guess.
- The keyterms query string pushes the URL past a length the server or
  `URLComponents` rejects → report the observed limit; reduce the cap rather
  than switching to a config message without confirming the API supports one.
- `no_verbatim` visibly mangles a test transcript (e.g. eats a spoken
  correction) → still ship it, but default OFF and say so in the report.
- Any temptation to delete or rewire `CleanupService` → out of scope, stop.

## Maintenance notes

- **Why `no_verbatim` defaults OFF**: dictation often contains deliberate
  disfluency-shaped speech ("um, actually, no —") used as a spoken correction.
  Filler removal may swallow it. The user should A/B this for a day before it
  becomes a default. Revisit the default after real use.
- **keyterms is a prophylactic, not a replacement**: keep the `DictionaryStore`
  correction pass. If keyterms proves excellent, a future plan may reduce the
  post-hoc corrections — but only with evidence from history entries.
- Keyterm prompting was advertised as a small priced add-on (~$0.05/hr) at
  planning time. Negligible at this user's ~15 min/day volume, but non-zero;
  do not enable it for other providers by analogy without checking their
  pricing.
- If cleanup is later turned off by default for the ElevenLabs engine, do it
  as a separate change with its own before/after transcript comparison.
