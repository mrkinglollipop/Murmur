# Plan 008 (spike): Extend StyleStore's proven per-app pattern to Snippets, Dictionary, and auto-run Transforms

> **Executor instructions**: Design-and-build spike — Step 1 decides how far
> to go this pass (the recommendation is to ship per-app for ONE store first).
> Honor STOP conditions. Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/UI/StyleStore.swift Sources/Voice/UI/TransformsStore.swift Sources/Voice/UI/SnippetsStore.swift Sources/Voice/UI/DictionaryStore.swift`

## Status

- **Priority**: P3
- **Effort**: M (per store; this plan ships one store + the shared resolver)
- **Risk**: MED (touches the live dictation pipeline's text passes)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Per-app behavior already exists and works for Styles: a bundle-ID-keyed map
consulted at dictation time. The identical mechanism would let snippets,
dictionary corrections, and the auto-run transform vary by target app — e.g.
code-flavored snippets only in the editor, an auto-run "tighten prose"
transform only in Mail. The architecture is proven; the other stores are
global-only, and `TransformsView.swift:12` still carries a comment calling
focused-app selection "a future stretch."

## Current state

- The proven pattern, `Sources/Voice/UI/StyleStore.swift` (read the whole
  file — ~90 lines):

  ```swift
  private enum Keys {
      static let selectedStyle = "voice.settings.selectedStyle"
      static let appProfileMap = "voice.settings.appStyleProfiles"
  }
  /// bundleID → StyleProfile raw value
  @Published private(set) var appProfileMap: [String: StyleProfile] = [:]
  ...
  /// Reads the frontmost app's bundle ID and applies a matching per-app
  /// style instruction when one exists; otherwise falls back to global.
  func applyStyleForFrontmostApp() {
      guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
          applyGlobalStyle()
          return
      }
      if let profile = appProfileMap[bundleID] { ... } else { applyGlobalStyle() }
  }
  ```

- `Sources/Voice/UI/TransformsStore.swift:26-36` — single global
  `autoRunTransformID` in UserDefaults.
- `SnippetsStore` / `DictionaryStore` — global JSON-backed stores applied as
  pipeline passes (`onSnippetExpand` / `onTranscription` hooks in
  `TranscriptionPipeline.swift:214-215`).
- Where/when Styles resolves the frontmost app: find the call site of
  `applyStyleForFrontmostApp()` (`grep -rn "applyStyleForFrontmostApp" Sources/`)
  — the same trigger point serves the other stores. IMPORTANT timing note:
  the frontmost app must be sampled at INJECTION TARGET time; verify when
  Styles samples it and reuse that exact timing.

## Commands you will need

| Purpose  | Command | Expected |
|----------|---------|----------|
| Generate | `xcodegen generate` | success |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED |

## Scope

**In scope**: ONE store this pass (Step 1 picks; recommendation below), a
small shared `FrontmostAppResolver` helper if extraction is trivial, that
store's settings UI surface, tests, `plans/README.md`.

**Out of scope**: shipping all three stores in one PR (each is its own
follow-up using this plan as the template); per-app ENGINE selection;
changing how the pipeline hooks are wired.

## Git workflow

- Branch: `feat/per-app-<store>`; conventional commits; no push/PR without
  operator instruction.

## Steps

### Step 1 (decide): Which store first

Recommendation: **auto-run Transforms** — it is the smallest surface (one
optional UUID instead of a whole entry list), the value is obvious
(per-app auto-rewrite), and it cannot corrupt learned data. Dictionary is the
riskiest (auto-learned corrections applied text-wide). If the operator left a
preference in `plans/README.md`, honor it.

### Step 2: Extract the resolver

Pull `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` sampling into
a tiny shared helper (or protocol with a live + test fake) so per-app maps are
testable. StyleStore may adopt it too ONLY if the diff stays mechanical.

### Step 3: Add the per-app map to the chosen store

Mirror StyleStore literally: a `[String: UUID]` (for transforms) persisted
under a `voice.settings.appAutoRunTransforms`-style key, `resolve(for
bundleID:)` falling back to the global value, applied at the same pipeline
moment the global one is today (`pushAutoRunTransform` — trace with
`grep -n "pushAutoRunTransform\|autoRunTransform" Sources/`).

**Verify**: build + tests green.

### Step 4: Settings UI

Copy whatever UI StyleStore's per-app assignment uses (find it:
`grep -rn "appProfileMap\|assignProfile" Sources/Voice/UI/`) — same
interaction, same wording, swap the noun.

**Verify**: build green; UI unverified-manual unless the app can be run.

### Step 5: Tests

Unit-test the resolver fallback logic (per-app hit, per-app miss → global,
nil bundle ID → global) with a fake resolver. Model on existing store tests.

## Done criteria

- [ ] One store resolves per-app with global fallback, same timing as Styles
- [ ] Resolver logic unit-tested (3 cases minimum)
- [ ] Build + suite green; `plans/README.md` updated (and a follow-up row
      added for the remaining stores, status TODO)

## STOP conditions

- The frontmost-app sample timing for Styles turns out to happen at recording
  START rather than injection time — that is a pre-existing design question;
  report it before propagating the pattern.
- The chosen store's pipeline hook is not cleanly reachable from where the
  bundle ID is known.

## Maintenance notes

- Each remaining store repeats Steps 3-5 of this plan; keep the resolver
  shared.
- Reviewer focus: per-app map persistence must not double-write the global
  value; UserDefaults keys must be new, never reuse the global key.
