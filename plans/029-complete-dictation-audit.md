# Complete Murmur audit — September 8, 2026

## Authorized scope

Audit the entire Murmur product codebase and related local configuration after
repeated failures in transcription, corrections, punctuation, and Safari/X
insertion. Repair confirmed defects, verify locally and in the installed Pro
app, preserve private Pro/public release separation. User operates the screen;
computer automation remains off. Use only explicitly approved recordings for provider replay; never disclose secrets.

Scope includes macOS source/tests, bundled iOS source/tests, private Pro source,
sidecars, dependency configuration, persistence, and release/install tooling.
Other harness controls and generated/binary artwork are outside functional code
review. Dependencies are checked at their integration boundaries, not certified
as fully audited third-party projects. iOS source review is distinct from a
physical-device acceptance test.

## Evidence and coverage ledger

Working evidence: `/tmp/murmur-x-insertion-20260908/`.
`tracked-files.txt` freezes the inventory at the start of this audit.

| Domain | State | Evidence / remaining gate |
|---|---|---|
| Safari insertion / event confirmation | Fixed; unit and user-operated Safari/X checks passed | Two fresh drafts were correct with final periods. One omitted an internal comma. `safari-repair.md`. |
| Dictionary, corrections, phonetic matching | Source/data audit complete | `autocorrect-audit.md`; nonsensical historical rows predate current guards. No user rules deleted. |
| Hesitation and sound-caption cleanup | Fixed; regression tests passed | Conservative local um/uh removal; preserve quoted/code content and real bracketed or emphasized words. |
| Terminal punctuation / caret context | Diagnostics improved; Safari final periods verified | Prior skips were insertion-context decisions. New metadata explains future skips without logging field contents; internal comma quality remains recognizer-dependent. |
| Missing-clause incident | Provider filter isolated by repeated replay | Original audio contains omitted clause. ElevenLabs background filtering lost it 2/2; disabled filtering preserved it 2/2; batch preserved it. User's filter disabled. `filter-replay-verdict.json`. |
| Audio, activation, streaming and batch providers | Source audit complete; deadline repairs passed tests | Noncooperative sender drain now shares finalization budget for xAI/Gemini/Muse. Additional live provider coverage recorded separately. |
| Local ASR, sidecar, enrollment | Confirmed lifecycle and persistence repairs passed tests | Real deadlines, serialized WhisperKit load, owned Parakeet termination/reaping, embedding-model retry, atomic profile replacement. `audio-provider-audit.md`, `parakeet-repair.md`. |
| Persistence, history, export/import, preferences | Confirmed repairs passed tests | Retry saves to History without reinsertion; failed retry preserves prior success; failed export preserves prior ZIP; active transform refreshes after edits. |
| Pro authentication, entitlements, clipboard | Private source coverage complete; final repairs pending | All 18 private production/config paths accounted. Session generations, capture flush, fingerprint and corruption preservation tested. Stale deep-link binding and visible corruption state under repair. `private-pro-coverage.md`. |
| Application lifecycle, settings and UI actions | Source audit complete | `remaining-product-audit.md`, `source-coverage.json`; 98 shared source paths accounted with active repairs covered by integration review. No visual drive under user's no-computer-use constraint. |
| iOS keyboard, dictation handoff and shared stores | Source audit complete; device behavior unverified | No confirmed defect after rechecking LiveActivityIntent execution semantics. `ios-audit.md`. |
| Build/install/Sparkle tooling and configuration | Public Release build and helper oracle passed | Installer protects private Pro, verifies staged signatures and retains rollback. Final Pro signing/install and post-install microphone check remain. |

## Verification record

Integrated Pro VoiceTests: 853 passed, 17 optional live checks skipped, zero
failures (`pro-verification/test-audit2.json`). Standard Release build passed
(`public-build-audit1.json`). Independent source review found no introduced
confirmed defects in the reviewed candidate (`integration-review.md`). Later
private-only repairs require a fresh integrated gate before installation.

## Residual risks and boundaries

- Long recordings and slow sender queues still retain unbounded audio in memory;
  bounding the finalization wait does not cap capture memory.
- Parakeet still acquires an absent model through its vendor's cache download;
  process lifetime is now bounded, but managed model-download UI is not added.
- Voice-gate cross-queue flags, vendor cancellation during model deletion, and
  reentrant enrollment remain stress-test risks, not reproduced user failures.
- Several stores suppress persistence errors; their atomic writes protect prior
  files, but write-failure UI is not comprehensive.
- iOS hardware behavior, every provider's live contract, and arbitrary third-party
  editor acceptance are not certified by source or unit coverage.

## Acceptance

Each finding needs a source pointer and a reproducible trace/test; distinguish
confirmed bugs, plausible risks, and inaccessible/live-only checks. Root owns
the direct Xcode test/build gate, at most three runs per changed candidate.
Source tests do not prove browser editor acceptance. The Safari repair requires
fresh user-operated X drafts compared against saved History. Keep build,
installed, live and published states separate. Public release follows verified
acceptance, not merely a green test suite.
