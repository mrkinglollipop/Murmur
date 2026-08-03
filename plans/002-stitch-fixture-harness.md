# Plan 002: Build a fixture-driven replay harness that tests the real xAI ingestion path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- Sources/Voice/XAIStreamingTranscriber.swift Tests/VoiceTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (additive test infrastructure; one visibility change in prod code)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Five consecutive fix-PRs (#14–#19 in `git log`) each patched a new xAI
stitch/dedupe bug that the existing test suites did not catch — and the reason
is structural, not bad luck. The existing "golden" tests call the pure helper
`mergeSegmentIntoConfirmed` directly with hand-typed strings and always-empty
`incomingWords`, so the real entry point `ingestFinalSegment` — with its
speechFinal containment shortcut, word-timestamp handling, interim clearing,
and post-merge `dedupeStitchArtifacts` pass — is never executed by any test.
Every production bug arrives through that unexercised path. This plan builds a
fixture-replay harness driving `ingestFinalSegment` with recorded event
sequences, so future stitch regressions are caught before they ship.

## Current state

- `Tests/VoiceTests/GoldenTranscriptTests.swift` (86 lines, 5 tests) — folds
  hand-typed chunks through the helper, bypassing ingestion (lines 9-27):

  ```swift
  private func stitchSequence(_ chunks: [String]) -> String {
      guard let first = chunks.first else { return "" }
      var accumulated = first
      var committedWords: [TranscriptWord] = []
      var lastEnd: Double = 0
      for chunk in chunks.dropFirst() {
          let merged = XAIStreamingTranscriber.mergeSegmentIntoConfirmed(
              confirmed: accumulated,
              text: chunk,
              incomingWords: [],   // <- real events carry word timestamps
              ...
  ```

- `Sources/Voice/XAIStreamingTranscriber.swift:586-624` — the real ingestion
  logic that no test currently reaches. Note it is `private` and must be made
  `internal` for `@testable` access (see Step 1):

  ```swift
  /// Incorporates a chunk- or utterance-final partial. Must be called with `stateLock` held.
  private func ingestFinalSegment(text: String, words: [TranscriptWord], speechFinal: Bool) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      ...
      if speechFinal, !confirmedText.isEmpty {
          let confirmedLower = confirmedText.lowercased()
          let incomingLower = trimmed.lowercased()
          if incomingLower.contains(confirmedLower), trimmed.count >= confirmedText.count {
              confirmedText = trimmed
              ...
              return
          }
      }
      let merged = Self.mergeSegmentIntoConfirmed(...)
      ...
      confirmedText = Self.dedupeStitchArtifacts(confirmedText)
      if speechFinal {
          latestInterim = ""
      }
  }
  ```

- `Tests/VoiceTests/StitchDedupeTests.swift` (357 lines, 32 tests) — contains
  ad-hoc `testMatt*Golden`-style regression cases from PRs #14–#19, also via
  static helpers only. These cases are the seed corpus for fixtures.
- The pure stitch helpers live at `XAIStreamingTranscriber.swift:626-1108`
  under the marker `// MARK: - Stitch / dedupe (static, @testable)`.
- Convention: tests use XCTest with `@testable import Voice` (module is named
  `Voice` even though the product is Murmur.app — intentional, do not rename).

## Commands you will need

| Purpose  | Command | Expected on success |
|----------|---------|---------------------|
| Generate | `xcodegen generate` | "Created project at .../Voice.xcodeproj" |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |

`Config/Team.xcconfig` must exist (copy from `Config/Team.xcconfig.example`
if missing). New test files under `Tests/VoiceTests/` are picked up by
xcodegen automatically — re-run `xcodegen generate` after adding files.

## Scope

**In scope**:
- `Sources/Voice/XAIStreamingTranscriber.swift` — ONLY the two visibility
  keywords in Step 1 and (if needed) a test-only state-reset helper in Step 2.
  No logic changes.
- `Tests/VoiceTests/StitchReplayTests.swift` (create)
- `Tests/VoiceTests/Fixtures/` (create; JSON fixture files)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- Any stitch/dedupe algorithm change — this plan characterizes current
  behavior; if replay reveals a live bug, record it as a failing-but-skipped
  test (`XCTSkip` with a comment) and report it, do not fix it here.
- `GoldenTranscriptTests.swift` and `StitchDedupeTests.swift` — leave existing
  suites untouched; they still cover the pure helpers.
- The WebSocket/transport code (lines 59-625) beyond the visibility keywords.

## Git workflow

- Branch: `feat/stitch-replay-harness`
- Conventional commits, e.g. `test: add fixture-driven stitch replay harness`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make the ingestion seam testable

In `Sources/Voice/XAIStreamingTranscriber.swift`, change `private func
ingestFinalSegment` (line 586) to `func ingestFinalSegment` (internal), and
locate the property/accessor the class uses to read the current stitched
transcript under `stateLock` (`mergeConfirmedWithInterim()` — find with
`grep -n "func mergeConfirmedWithInterim" Sources/Voice/XAIStreamingTranscriber.swift`);
make it `internal` too if it is `private`. Add a doc comment on each noting
"internal (not private) for @testable replay tests — see Plan 002".

**Verify**: build → `** BUILD SUCCEEDED **`

### Step 2: Define the fixture format and add the first fixtures

Create `Tests/VoiceTests/Fixtures/` with JSON files, one per recorded
scenario, in this shape:

```json
{
  "name": "pr17-cursor-from-it-near-dup",
  "events": [
    {"type": "final", "text": "move the cursor", "speechFinal": false,
     "words": [{"text": "move", "start": 0.0, "end": 0.3}, ...]},
    {"type": "final", "text": "cursor from it", "speechFinal": true, "words": []}
  ],
  "expected": "move the cursor from it"
}
```

Seed the corpus by translating the regression cases embedded in
`StitchDedupeTests.swift` (the `testMatt*` cases from PRs #14–#19 — each test
body documents its chunk sequence and expected output; port at least 5). Where
a case has no word timestamps, use an empty `words` array — that is faithful
to what production saw in those bugs.

**Verify**: `ls Tests/VoiceTests/Fixtures/*.json | wc -l` → 5 or more

### Step 3: Write the replay harness

Create `Tests/VoiceTests/StitchReplayTests.swift`:

- Decode every JSON file in `Fixtures/` (locate via `Bundle(for:)` resource
  lookup; add the fixtures dir to the test target's resources — with xcodegen
  this means the files just need to live under `Tests/VoiceTests`, which
  `project.yml` already includes as the test-target source path; if resources
  don't resolve, embed the JSON as Swift string literals instead — that is an
  acceptable fallback, note it in the commit message).
- For each fixture: instantiate `XAIStreamingTranscriber` (find its
  designated init with `grep -n "init(" Sources/Voice/XAIStreamingTranscriber.swift`
  — if the init requires live network/session objects that cannot be
  constructed in tests, STOP per conditions below), feed each event through
  `ingestFinalSegment(text:words:speechFinal:)`, then read the final merged
  transcript and `XCTAssertEqual` against `expected`.
- One `func testReplayAllFixtures()` iterating the corpus with
  `XCTContext.runActivity(named: fixture.name)` per fixture, so failures name
  the fixture.

**Verify**: full test run → `** TEST SUCCEEDED **`, test count increased

### Step 4: Document how to capture new fixtures

Append a short section to `Tests/VoiceTests/Fixtures/README.md` (create):
when a stitch bug is found in production, run the app with `VOICE_DEBUG=1`,
reproduce, and convert the logged `xai-stream:` event lines into a fixture
JSON; add the fixture BEFORE fixing the bug so the fix is regression-locked.

**Verify**: file exists; `wc -l` > 5

## Test plan

The harness IS the test plan. Coverage targets: chunk-overlap merge, the
speechFinal containment shortcut (line 596-608), interim clearing on
speechFinal, near-dup tail dedupe, and at least one fixture with real word
timestamps (nonempty `words`) since the current suites never exercise that.

## Done criteria

- [ ] `xcodebuild test ...` → `** TEST SUCCEEDED **`
- [ ] `grep -n "func ingestFinalSegment" Sources/Voice/XAIStreamingTranscriber.swift` shows no `private` on that line
- [ ] 5+ fixture JSONs exist and are each asserted (test log names them)
- [ ] At least one fixture has nonempty `words`
- [ ] No algorithm changes: `git diff Sources/Voice/XAIStreamingTranscriber.swift` shows only visibility keywords/doc comments (and optional test-only reset helper)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `XAIStreamingTranscriber`'s initializer requires live WebSocket/session
  dependencies that cannot be constructed in a unit test — report the init
  signature; the fallback design (extracting a `StitchState` struct) is a
  bigger refactor that needs operator sign-off.
- Replaying a fixture derived from an already-fixed PR case FAILS — that means
  helper-level tests and ingestion-level behavior disagree today (a live bug):
  mark it `XCTSkip`, report it, continue with the rest.
- The excerpts in "Current state" don't match the live code.

## Maintenance notes

- Every future stitch bug fix should land with a fixture, not (only) a
  helper-level test — reviewers should reject stitch PRs without one.
- If Plan `009`-era work or any refactor extracts the stitch logic into its
  own type (see audit finding #9), this harness migrates with it — the
  fixtures are the durable asset.
