# Murmur — open-source readiness plan

> **Wrapper defaults supersede Claude’s blocked / Matt-call section.**
> Locked by Cursor wrapper (`open-source_readiness_0be2a008`): SECURITY.md → GitHub private vulnerability reporting (no personal email); Copyright → `Copyright (C) 2026 Matthew Schwartz d/b/a King Lollipop Studios`; public `Voice.xcodeproj` → gitignore + `xcodegen generate` required setup. CLA counterparty = Matthew Schwartz until LLC assignment.
>
> Status: **SHIPPED** (Phases 1–4 complete green in the archive). Phase 5 orphan cut `d371e03` exists on private `mrkinglollipop/Murmur`; **publish / re-publicize paused for Matt audit**. Local SSOT = `Murmur-archive` @ Phases 1–4.
>
> Historical Claude brief: local Claude plan archive on the operator machine (not in-repo; 2026-08-03, `4a1cd49`). This file is the in-repo SSOT after port-023 HARD transforms.

## Context

Murmur is going public. A full code + visual audit (2026-08-03) found the app itself in
good shape — build clean with zero warnings, **310** tests passing (was 293 at plan
time / briefly 299 / 304 / 306 / 307; CLAUDE.md kept in sync), no TODOs, one required `fatalError` stub.
The defects below are the ones that only matter, or only get scrutinised, once the repo
stops being private.

Outcome this plan produces: a new public repo holding a corrected, scrubbed, AGPL-3.0
Murmur, with the existing private repo frozen intact as an archive.

### Baseline verified at plan time (re-run before starting; these should still hold)

```
xcodegen generate                                                    -> Created project
xcodebuild -scheme Voice -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO                                            -> ** BUILD SUCCEEDED **
xcodebuild test -scheme VoiceTests -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO                                            -> 310 tests, 0 failures
```

> Historical counts: plan-time 293; F15 stale “118”; interim 299 / 304 / 306 / 307. Current suite **310**
> (CLAUDE.md updated). Re-count with `rg -c 'func test' Tests/VoiceTests` before claiming.

At plan-authoring time the tree was clean and `xcodegen generate` reproduced
`Voice.xcodeproj` byte-identically. After Phases 1–4 + audit fixes, expect a
dirty/regenerated project until those commits land — re-run generate after
adding tests; do not treat this historical baseline line as live status.

### Decisions already made — do not re-litigate

| Decision | Choice |
|---|---|
| License | **AGPL-3.0.** Real open source; strongest copyleft; dual-licensing stays available because Matt is sole copyright holder |
| History | **Fresh repo, squashed history.** No `filter-repo`, no force-push |
| Existing repo | **Frozen private archive. Delete nothing from it** |
| Future development | **Happens in the new public repo** |
| `.cursor/` | **Dropped** from the public tree (stays in the archive) |
| `plans/` | **Kept, scrubbed** |

### Resolved decisions (wrapper SSOT — was Blocked on Matt)

1. **SECURITY.md** — GitHub private vulnerability reporting (no personal email).
2. **Copyright line** — `Copyright (C) 2026 Matthew Schwartz d/b/a King Lollipop Studios` (LICENSE + file headers: grep existing headers; apply locked line if any; if none, document intentional omission — do not mass-insert).
3. **Public Voice.xcodeproj** — gitignore + document `xcodegen generate` as required setup. Phase 2 prepares ignore path only; do **not** regenerate/commit `Voice.xcodeproj` as an alternate path.


---

## The findings this plan fixes

Self-contained so a fresh agent can verify each independently.

| # | Finding | Evidence |
|---|---|---|
| F1 | No LICENSE — repo is legally unusable | `gh repo view --json licenseInfo` → `null` |
| F2 | A proprietary stock-screening skill is tracked in git | `.cursor/skills/fortress-compounder-screener/` — 1,642 LOC; `git rev-list --all --objects \| grep -ic fortress` → 13 |
| F3 | 3.1 GB model cache written into `~/Documents`, which iCloud syncs | **Fixed** — `ModelManager.downloadBase` → `Application Support/Voice/Models` via `VoicePaths`; migrates only `models/argmaxinc/whisperkit-coreml` |
| F4 | Injection debug log writes unconditionally, no rotation, no cap | `TextInjector.swift:549`; zero `VOICE_DEBUG` refs in that file; 109 KB accrued in ~1 week |
| F5 | Insights stats are silently window-scoped and now frozen | `HistoryStore.swift:59` — `private let maxEntries = 1000` (instance property, not a static); live `history.json` holds exactly 1000 |
| F6 | Force-casts on Accessibility results can trap | `CaretContext.swift:32` `as! AXUIElement`, `:52` `as! AXValue` — and `:53` type-checks *after* the cast |
| F7 | Word counts break on newlines | `InsightsView.wordCount` splits on the literal `" "` |
| F8 | Parakeet sidecar unfindable for most users | `ParakeetEngine` spawns `/usr/bin/env python3`; a Finder-launched app inherits launchd's minimal PATH |
| F9 | Almost no VoiceOver support | 3 `accessibilityLabel` calls app-wide; every view but `SettingsView` has zero; AX dump returns `missing value` |
| F10 | Settings renders system blue against the coral brand | 9 `Toggle` + 8 `Picker` in `SettingsView`, none tinted; the 5 `.tint` calls there are all on Buttons/ProgressView |
| F11 | Raw internal engine IDs shown to users | **Fixed** — `HistoryView` uses `EngineDisplayName.displayName(for:)` |
| F12 | Destructive actions under-signalled | History trash (`HistoryView.swift:327`) is `Theme.textSecondary`, identical to edit/copy/re-inject. "Delete profile" (`SettingsView.swift:466`) is `Theme.amberText` — a *warning* tone, distinct from Re-enroll's `Theme.primary` (`:459`) but not destructive. `Theme.recordRed` exists and is unused here |
| F13 | Permissive file modes (defense-in-depth only) | `history.json`, `Recordings/*.caf`, `inject-debug.log` are 0644. **Not** a live exposure — `~/Library`, `~/Library/Application Support`, `~/Documents`, `$TMPDIR` are all 0700 |
| F14 | Team ID hardcoded in 7 places across 6 files | see §2.1 |
| F15 | Docs drift | **Fixed in Phase 4** — CLAUDE.md test count synced (now 310); README model path + “can stay private” removed |
| F16 | Bundled fonts absent from Acknowledgements UI | **Fixed** — EB Garamond + Figtree in `Acknowledgements.all` |

---

## Sequencing

**Fix first, split last.** Phases 1–4 commit into the current private repo as normal
development, so the archive holds the complete real history including the fixes. The
public repo is cut from the finished tree in Phase 5.

**Within Phase 1, §1.0 runs first.** It creates the `VoicePaths` helper that §1.1 must
consume. Doing §1.1 first adds an eleventh independent path derivation that §1.0 then
has to rip out.

---

## Phase 1 — Correctness

Inspect each file before editing. Several carry load-bearing comment blocks
(`KeychainStore`, the `CODE_SIGN_STYLE` rationale in `project.yml`, `ActivationController`'s
fn-consumption notes) that record non-obvious constraints. Do not "tidy" those away.

### 1.0 (prerequisite) — `VoicePaths`, one owner for the Application Support directory

Nine files independently derive the path via
`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]`
(`VoiceProfileStore:19`, `RecordingRetention:26`, `ScratchpadStore:41`, `CorrectionsLog:53`,
`SnippetsStore:43`, `DictionaryStore:117` and `:124`, `HistoryStore:74`, `TransformsStore:61`),
and `TextInjector:551` uses a **different** derivation via `homeDirectoryForCurrentUser`
that breaks under a redirected home. **Thirteen** `createDirectory` calls across those files
pass no permission attributes (`RecordingRetention` ×4, `DictionaryStore` ×2, one each in
`HistoryStore`, `CorrectionsLog`, `VoiceProfileStore`, `TransformsStore`, `SnippetsStore`,
`ScratchpadStore`, `TextInjector`).

- Add a `VoicePaths` helper owning the directory URL and its creation. **`ModelManager` is
  a consumer too** (§1.1) — list it.
- **`createDirectory(attributes:)` is a no-op on an existing directory.** Every current
  install already has `Voice/` at 0755, so attributes alone would silently not apply.
  The helper must **also `chmod` the directory to 0700 when it already exists**, once per
  launch. Without this the fix does nothing and the verification below fails.
- Follow `VoiceProfileStore.save` (`:41`) — the one file on disk that is correctly 0600.
- This is the mechanism for F13, not a drive-by refactor: without it the same fix has to be
  applied and maintained in ten places.

> **Unverified assumption — check before relying on it.** Whether
> `Data.write(options: .atomic)` preserves a `chmod`ed *file* mode across rewrites was not
> established. Test it: write, `chmod 600`, write again, `ls -l`. The 0700 **directory** is
> the primary control precisely because it does not depend on the answer.

### 1.1 Move the model cache out of `~/Documents` (F3) — **SHIPPED**

`ModelManager.downloadBase` now resolves under `Application Support/Voice/Models`
(via `VoicePaths`). Historical baseline before Phase 1 was
`.documentDirectory/huggingface`.

- Repointed to `Application Support/Voice/Models` via `VoicePaths`. Single-point change:
  `WhisperKitEngine` reads the path through `ModelManager.modelFolderURL(for:)`, so
  reader and writer move together.
- **Do not use `~/Library/Caches`** — the OS purges it under disk pressure and these are
  multi-GB artefacts the user explicitly manages in Settings.
- **Migrate only `models/argmaxinc/whisperkit-coreml`.** That parent directory is
  swift-transformers' shared default and legitimately holds other apps' data — verified:
  `~/Documents/huggingface/models/` currently contains an `openai/` sibling that is not
  Murmur's. Never move or delete the parent.
- Failure states, all three of which must be defined:
  - move throws → log, leave old files alone, fall through to normal re-download;
  - partial move (both paths populated) → the **new** path wins; log the orphan and leave it
    for the user rather than deleting;
  - never let a failed migration block launch.
- iCloud-evicted dataless placeholders will materialise on move. Acceptable; the throw path
  above covers failure.

### 1.2 Gate the injection debug log (F4)

- Route `TextInjector.log` (`:549`) through the existing `vlog` (`ActivationController:17`),
  which is already env-gated, already 0600, already writes to `TMPDIR`. `vlog` is a
  module-internal free function, so this introduces no new coupling.
- Delete the legacy `inject-debug.log` once on launch.
- Content stays counts-only. Transcript text must never reach either sink.

### 1.3 Stop force-casting Accessibility results (F6)

- `CaretContext.swift:32` and `:52` become `as?` with the existing `return .unknown` fallback.
- Add a `CaretContextTests` case for the non-`AXValue` path.

### 1.4 Fix word counting (F7)

- Split on `.whitespacesAndNewlines`, dropping empties. Add a multi-line test.

### 1.5 Make Insights stats honest (F5)

- **Required:** relabel so the retained-window scope is visible on the cards. No new
  persistence, no migration risk. This is user-visible copy — verify against the **rendered
  result** per the Phase 3 capture rule, not just the build.
- **Optional, list only, do not build unless asked:** monotonic lifetime counters incremented
  on append and never decremented by pruning (~30 LOC + a migration that seeds from current
  history and therefore undercounts everything already pruned — which is exactly why
  relabelling is the honest minimum).

### 1.6 Make the Parakeet sidecar findable (F8)

- Probe in order: `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, then pyenv's shim
  resolved via `homeDirectoryForCurrentUser` (a literal `~` will not expand in a `Process`
  executable path). Fall back to today's `env python3`.
- Name the resolved interpreter in `ParakeetError.sidecarNotFound` so the failure
  self-diagnoses.

---

## Phase 2 — Contributor readiness

### 2.1 Signing config (F14)

```
Config/Team.xcconfig.example:10        DEVELOPMENT_TEAM = YOUR_TEAM_ID
scripts/install-local.sh:9             TEAM="${DEVELOPMENT_TEAM:-YOUR_TEAM_ID}"
scripts/make-dmg.sh:18                 TEAM="${DEVELOPMENT_TEAM:-YOUR_TEAM_ID}"
scripts/release.sh:15                  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-YOUR_TEAM_ID}"
README.md:87                           prose: "...signing with team YOUR_TEAM_ID"
Voice.xcodeproj/project.pbxproj:515    DevelopmentTeam = YOUR_TEAM_ID;
Voice.xcodeproj/project.pbxproj:519    DevelopmentTeam = YOUR_TEAM_ID;
```

- `Team.xcconfig.example` gets a placeholder.
- **`Voice.xcodeproj` is tracked** today and carries the baked team ID in two places.
  **Locked default:** prepare ignore path only for the public cut — gitignore
  `Voice.xcodeproj` and document `xcodegen generate` as a required setup step.
  Do **not** regenerate/commit `Voice.xcodeproj` as an alternate path.
- The three scripts already honour a `DEVELOPMENT_TEAM` env override — say so in
  `scripts/README.md` instead of leaving it to be discovered.
- **README carve-out (Phase 2 only):** drop the prose team ID; document
  `CODE_SIGNING_ALLOWED=NO` as the contributor build path; explain why *release* builds
  need a stable Developer ID by linking the rationale block above `CODE_SIGN_STYLE` in
  `project.yml` — do not restate it. All other README truth-up stays Phase 4.

---

**Oracle after Phase 2 (concrete checks):**

- `Config/Team.xcconfig.example` has a placeholder team ID (not a live operator team ID)
- `scripts/README.md` documents `DEVELOPMENT_TEAM` env
- README no longer hardcodes a live team ID (signing carve-out only)
- Public-cut gitignore entry for `Voice.xcodeproj` is documented/prepared

---

## Phase 3 — UI and accessibility

Judged against the **rendered result**, not the build. Capture with window-ID-scoped
`screencapture -x -o -l<id>`; get the ID from `CGWindowListCopyWindowInfo` filtered to
owner `Murmur`. A full-screen or region capture on this Mac picks up other apps' windows —
this happened during the audit.

### 3.1 VoiceOver labels (F9) — largest gap

- Label every icon-only control: `HistoryView` row actions (edit / copy / re-inject /
  delete), `SidebarNav`, `DictionaryView`, `SnippetsView`, `TransformsView`,
  `ScratchpadView`, `SearchBar`.
- **Acceptance:** AX dump returns real names in place of `missing value`. Address the window
  by its CGWindowID, not `window 1` — the index is not stable.

### 3.2 Settings accent (F10)

- **Do not assume container-level tint works.** Every existing `.tint(Theme.lavender)` in
  this codebase sits directly on a `.buttonStyle(.glassProminent)` Button; there is no
  in-repo precedent for propagation to a `Toggle` or `Picker`. Test **one** control first
  and look at the rendered result.
- If it works, scope it to the `SettingsView` root, **not** the app root — an app-wide tint
  would also reach untinted `.glassProminent` buttons and the sidebar selection.
- `.pickerStyle(.segmented)` on macOS has historically honoured the system accent rather
  than `.tint`. If Low/Medium/High stays blue, that is why. **Accepting that is a valid
  outcome** — the acceptance criterion is "toggles and menu pickers are coral", not "zero
  blue pixels anywhere". Replacing the segmented control is out of scope.

### 3.3 Engine names (F11)

Stored IDs are inconsistent — **six** writers, three formats live in current history:

| Stored ID | Live count | Written by |
|---|---|---|
| `cloud:elevenlabs-streaming` | 981 | hardcoded, `AudioRecorder.swift:527` |
| `cloud:elevenLabs` | 18 | `"cloud:\(provider.rawValue)"`, `TranscriptionPipeline.swift:68` |
| `whisperKit:openai_whisper-large-v3_turbo` | 1 | batch local path, `engine.id` |
| `cloud:xai-streaming` | 0 | hardcoded, `AudioRecorder.swift:503` |
| `whisperKit:streaming` | 0 | hardcoded, `AudioRecorder.swift:545` |
| bare `parakeet` | 0 | `ParakeetEngine.id` (`:17`) via `TranscriptionPipeline` |

- Enumerate the writers from source rather than from live data — three of the six have zero
  rows today and would be missed by sampling `history.json` alone.
- Map all of them, with a graceful fallback for unknown strings — never render a raw ID,
  never silently drop an unrecognised one.
- `CloudProvider.displayName` (declared `CloudTranscriber.swift:20`) covers only the
  `rawValue` variants; it is a component, not the whole fix.
- **Acceptance:** no history row shows a string containing `:`.
- **Flag, do not fix here:** the ID inconsistency is itself a latent bug — streaming and
  batch ElevenLabs are one engine under two names, so anything grouping history by engine
  double-counts. Unifying the written IDs needs a migration over existing history and
  belongs in its own change.

### 3.4 Destructive affordances (F12)

Read F12 above before editing — an earlier draft of this plan wrongly claimed "Delete
profile" and "Re-enroll" share one accent. They do not (`Theme.amberText` vs
`Theme.primary`). The actual gap is narrower:

- History row trash (`HistoryView.swift:327`) is `Theme.textSecondary`, indistinguishable
  from edit / copy / re-inject. This is the real problem.
- "Delete profile" is amber — a warning tone, already distinct from Re-enroll, but not a
  destructive one. `Theme.recordRed` exists and is unused for either.
- Confirm dialogs already use `role: .destructive` correctly. Only the affordances that
  *open* them need to signal.

**Acceptance:** screenshots of History and Settings → Voice; delete controls read as
destructive and are distinguishable from neighbouring benign actions.

---

## Phase 4 — Docs and community health

All README edits **except** the Phase 2 signing/team-ID carve-out land **here**, so no
intermediate commit ships a half-updated README beyond that carve-out.

- **LICENSE** — AGPL-3.0 full text (F1) with `Copyright (C) 2026 Matthew Schwartz d/b/a King Lollipop Studios`.
- **Copyright file headers** — grep for existing headers; apply locked line if any; if none,
  document intentional omission (do not mass-insert).
- **CONTRIBUTING.md** — build/test commands, the no-CI-by-design note, and **a CLA, not a
  DCO**. This is load-bearing and not interchangeable: a DCO only certifies provenance and
  leaves contributors holding their copyright, which permanently forecloses the dual-licensing
  that is the entire reason AGPL was chosen. A CLA (or copyright assignment) is what preserves it.
- **SECURITY.md** — GitHub private vulnerability reporting (no personal email).
- **README truth-up** (F15) — correct the model-cache path; remove the "source repo can stay
  private" line; remove any hardcoded absolute `cd` to a private clone; correct the
  Parakeet setup constraint; drop `inject-debug.log` from the data-locations table entirely
  (§1.2 removes it — do not document a file that no longer exists).
- **CLAUDE.md** — test count was 118 then drifted; **now 310** (kept in sync).
- **Acknowledgements** (F16) — add EB Garamond and Figtree to `Acknowledgements.all`. The
  OFL files already ship in `Resources/Fonts/` and are already copied into the bundle, so
  this is discoverability, not compliance.
- **`.github/`** — issue + PR templates.
- **Optional, list only:** the four retired ASR providers (AssemblyAI, Deepgram, OpenAI,
  Groq) are dead weight in a public repo. Keep the Keychain account constants for key
  migration; the transcription implementations could go.

---

**Oracle after Phase 4 (concrete checks):**

- `LICENSE` present with AGPL + locked copyright line
- `CONTRIBUTING.md` present with CLA (not DCO)
- `SECURITY.md` points at GitHub private vulnerability reporting
- `.github/` issue + PR templates exist
- Acknowledgements include EB Garamond + Figtree
- Copyright header policy executed (grep result documented)
- This file Status: **SHIPPED**

---

## Phase 5 — The repo split

### Current state (honesty — 2026-08-03 audit)

Phases 1–4 landed in the archive. Dual-repo reality until Matt decides:

| Repo | Role | Visibility |
|---|---|---|
| `mrkinglollipop/Murmur-archive` | Local / archive SSOT @ Phases 1–4 (`b7b3d1f` and successors) | **private** |
| `mrkinglollipop/Murmur` | Orphan cut **`d371e03`** (“Initial public release of Murmur (AGPL-3.0)”) | **private** — cut exists; **not** public |

**Publish / re-publicize is paused for Matt audit.** Do **not** claim Phase 5 is
“unfinished as if no cut exists.” The cut exists; making `Murmur` public (or
re-publicizing after a private flip) is a separate Matt gate — no
`gh repo edit --visibility public` until authorized.

### Planned steps (reference — already partially executed)

1. Rename archive lineage → `mrkinglollipop/Murmur-archive`, still private.
   Phases 1–4 commit here *before* the rename, so the archive holds the complete real
   history including the fixes; it is frozen from the rename onward. Nothing is ever deleted
   from it — `.cursor/` and the screener stay there forever, they simply never get copied out.
2. Cut the public tree: drop `.cursor/` entirely; scrub `plans/` by redacting operator
   absolute paths (home directories and external volume mounts) and credential-store file
   paths. **Keep** scrubbed `plans/023-open-source-readiness.md`
   in the public tree unless scrub finds irrecoverable secrets — then drop that file and
   **stop**. **Scrub by search, not by a fixed list** — grep the whole cut tree for
   operator absolute paths and credential-file-shaped references, and resolve every hit.
   **Oracle:** no home-directory or volume-mount path literals remain under `plans/`.
3. Orphan commit → push to `mrkinglollipop/Murmur` (done as `d371e03`); gitignore
   `Voice.xcodeproj`. **Visibility remains private until Matt audits and authorizes public.**
   **Acceptance:** `git ls-files Voice.xcodeproj` empty + `xcodegen generate` works.
4. `Murmur-updates` and `SUFeedURL` are untouched. The Sparkle EdDSA private key is already
   ignored (`*.ed25519`, `sparkle_private*`) and no secret pattern appears in any tracked
   file — re-confirm on the final tree before any visibility change.
5. **Version continuity:** tree targets `CFBundleVersion 21` /
   `CFBundleShortVersionString 0.1.20` (Sparkle appcast release notes + What's New; prior tips were
   0.1.19 / build 20 and 0.1.18 / build 19). The first public release must continue that series — a
   lower number is a Sparkle regression
   and existing installs will not update.

**Stop-condition:** if the pre-push secret scan or the `fortress` grep returns anything,
stop and report. Do not push and clean up afterwards. Do not re-publicize without Matt.

---

## Verification

Local oracles only — this repo has **no CI by design**; do not add one or "fix" its absence.

| Check | Command | Expected |
|---|---|---|
| Regenerate | `xcodegen generate` | `Created project` |
| Build | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **`, no new warnings |
| Tests | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | ≥310 passing, 0 failures |
| Models moved | `ls ~/Library/Application\ Support/Voice/Models/models/argmaxinc/` | variant folders present |
| Models migrated safely | `ls ~/Documents/huggingface/models/` | `argmaxinc/` gone; **any other vendor dir untouched** |
| Dir mode | `ls -ld ~/Library/Application\ Support/Voice` | `drwx------` — on a pre-existing dir, not just a fresh one |
| Log gated | launch without `VOICE_DEBUG`, dictate once | `inject-debug.log` absent and not recreated |
| Insights honest | screenshot Insights | card labels state the retained-window scope |
| Parakeet | trigger with a Homebrew-only `parakeet-mlx` install | transcribes, or errors naming the interpreter it tried |
| VoiceOver | AX dump by CGWindowID | real names, no `missing value` |
| Engine names | screenshot History | no row shows a string containing `:` |
| Destructive | screenshot History + Settings → Voice | delete affordances read as destructive |
| Settings accent | screenshot Settings | toggles and menu pickers coral (segmented may stay system — see §3.2) |
| No secrets | `git ls-files -z \| xargs -0 grep -InE '\bsk-[A-Za-z0-9_-]{16,}\|\bxai-[A-Za-z0-9]{16,}\|AKIA[0-9A-Z]{16}\|BEGIN [A-Z ]*PRIVATE KEY'` | empty |
| Screener gone | `git rev-list --all --objects \| grep -ic fortress` | `0` **in the new repo** (current repo returns 13) |

> The secret-scan regex **must** stay length-anchored. A bare `sk-` matches ordinary prose
> ("ask-first", "risk-premium") and returns 5 false positives on the current tree — a check
> that cries wolf gets ignored, which is worse than no check.

**Caps.** Three oracle runs per change, then stop and report with the last log. Three visual
passes per surface, then ship a screenshot rather than iterating blind. Two failed root-cause
guesses on one defect → stop and escalate.

**Run the app after Phases 1 and 3** — hold the activation key, dictate, confirm injection
lands and history records. Every Phase 1 fix touches that path.

---

## Verification status of this plan

Audited 2026-08-03. Path oracle: every file this plan cites exists; LICENSE, CONTRIBUTING.md,
SECURITY.md and `.github/` are absent as claimed. All `file:line` references resolve.

**Corrected during audit — six defects in earlier drafts of this plan.** Kept as a record so
they are not reintroduced:

1. The file-mode finding was originally rated a live cross-user exposure. It is not — every
   ancestor directory is 0700. Demoted to F13 hardening.
2. `createDirectory(attributes:)` is a no-op on an existing directory, so the 0700 fix would
   have silently not applied to any current install. §1.0 now requires an explicit `chmod`.
3. The model migration originally targeted `~/Documents/huggingface` wholesale, and its
   acceptance criterion said that directory should end up "gone or empty" — which would
   destroy a sibling app's models. Now scoped to `models/argmaxinc/whisperkit-coreml`.
4. The engine-name fix was written as a one-table lookup; live history holds three formats
   from four writers.
5. The team ID was in five files, not one.
6. The plan's own secret-scan command produced five false positives on the current tree.

**Still assumptions — verify during implementation:** that `.tint` propagates from a
container to `Toggle`/`Picker` (§3.2); that atomic writes preserve a `chmod`ed file mode
(§1.0); that AGPL-3.0 rules out App Store distribution (well established for the GPL family,
but a licensing conclusion, not something checked here — moot unless the App Store is ever
considered, since Murmur ships via DMG and Sparkle).

**Round 2 — all three audit lanes returned and are reflected above.** Two `composer-2.5`
critics (bug-hunt + stale-claim) plus a `grok-4.5` cross-family confirm pass. Grok confirmed
findings 1, 3, 4 and 5 as HIGH/MEDIUM and rejected one: it read the segmented-`Picker`
contradiction as resolvable by building a custom control. This plan resolves it the other
way — accepting a system-accent segmented control and putting a replacement out of scope —
which removes the contradiction at lower cost. Either resolution is valid; §3.2 states the
chosen one.

**Four further defects the stale-claim pass caught, all verified against the repo and fixed:**

7. The team ID is in **seven** places across six files, not five — `Voice.xcodeproj/project.pbxproj`
   is tracked and carries it twice.
8. §3.3 undercounted engine-ID writers: **six**, not four. Three have zero rows in live
   history and would be missed by sampling the data instead of reading the source.
9. **A false claim:** §3.4 said "Delete profile" and "Re-enroll" share one accent. They do not —
   `Theme.amberText` vs `Theme.primary`. F12 and §3.4 are rewritten around the real gap.
10. Thirteen attribute-less `createDirectory` calls, not ten.

Two low-severity precision nits also folded in: `maxEntries` is a private instance property,
not a static symbol; `CloudProvider.displayName` is declared at `CloudTranscriber.swift:20`
(line 22 is its first `switch` case). `MurmurCore/` was independently confirmed ignored via
`git status --porcelain --ignored`, so the out-of-scope note stands.

---

## Out of scope

Sparkle/appcast changes beyond version continuity; App Store distribution; the `MurmurCore/`
stray directory (untracked, so it is simply not copied); Swift 6 strict-concurrency migration;
adding CI; unifying the engine-ID formats in stored history.
