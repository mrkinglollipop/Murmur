# Plan 020: Polish bundle — regex precompilation, log redaction, debug-log location, signing-key default

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. Each step is independent: if one must be
> abandoned, revert **only that step** and continue with the rest. When done,
> update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 5560a7b..HEAD -- Sources/Voice/SpokenPunctuation.swift Sources/Voice/ActivationController.swift Sources/Voice/XAIStreamingTranscriber.swift Sources/Voice/ElevenLabsRealtimeTranscriber.swift scripts/publish-sparkle.sh`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none. **Coordinate with plan 017** — it also edits the two
  streaming transcribers. If 017 is in flight, run this plan after it lands.
- **Category**: perf + security
- **Planned at**: commit `5560a7b`, 2026-07-27

## Why this matters

Four small, independent improvements, bundled because each is a handful of
lines and none justifies its own branch:

1. **Regex recompilation on the latency path.** Roughly 75 fixed regex
   patterns are compiled from string literals *on every call* during
   code-aware dictation, and the entry point is called twice per dictation.
   None of the patterns depend on the input. This is pure waste sitting
   directly between "user stops speaking" and "text appears."
2. **Redaction gap on the streaming path.** Every REST provider's error body
   goes through a redaction helper before being logged. The two WebSocket
   transcribers — the only two selectable engines — interpolate the
   server-supplied error string into the debug log raw.
3. **Debug log in a shared location.** The log is written to a fixed path in
   `/tmp`, which is world-readable and shared by every account on the machine.
4. **Signing-key path disclosed in the repo.** The publish script hardcodes
   the maintainer's on-disk location of the Sparkle EdDSA private key as a
   default. The key itself never leaks — it is passed by file path, never as
   an argument value — but publishing the location is free information for
   anyone who gets repo or local access, and it buys nothing.

## Current state

**1 — Regex recompiled per call**, `Sources/Voice/SpokenPunctuation.swift:204-244`.
Both helpers build a fresh `NSRegularExpression` inside the loop:

```swift
    private static func applyWordJoiners(_ text: String) -> String {
        var result = text
        for joiner in wordJoiners {
            let word = joiner.minWordLength <= 1 ? #"\w+"# : #"\w{\#(joiner.minWordLength),}"#
            let pattern = "(\(word))\\s+(?:\(joiner.spokenPattern))\\s+(\(word))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
```

```swift
    private static func applyPhraseReplacements(_ text: String, phrases: [(String, String)]) -> String {
        var result = text
        for (spoken, symbol) in phrases {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
```

`SpokenPunctuation.apply(_:)` (around `:127-141`) calls
`applyPhraseReplacements` twice and `applyWordJoiners` once;
`TranscriptionPipeline.swift:130` and `:152` each call `apply`.

**2 — Unredacted streaming error logs.** `ElevenLabsRealtimeTranscriber.swift:482`:

```swift
            let message = (json["error"] as? String) ?? "unknown"
            vlog("elevenlabs-stream: server error event [\(messageType)]: \(message)")
```

`XAIStreamingTranscriber.swift:551`:

```swift
            let message = (json["message"] as? String) ?? "unknown"
            vlog("xai-stream: server error event: \(message)")
```

The helper they should be using already exists —
`Sources/Voice/CloudTranscriber.swift:79`:

```swift
    static func redactedBodyFragment(_ body: String, max: Int = 300) -> String {
```

used at `CloudTranscriber.swift:72`. It has test coverage in
`Tests/VoiceTests/RedactionTests.swift`.

**3 — Debug log path**, `Sources/Voice/ActivationController.swift:8` and `:21`:

```swift
/// Appends a line to /tmp/voice-debug.log via FileHandle (written immediately,
…
    let path = "/tmp/voice-debug.log"
```

**4 — Signing-key default path**, `scripts/publish-sparkle.sh:46` — a shell
parameter default pointing at an absolute path on the maintainer's disk under
an `API Keys` directory. (Do not reproduce that path anywhere in your commits,
comments, or report; refer to it as "the hardcoded default at
`publish-sparkle.sh:46`".)

**Conventions to match:**

- `vlog` is the debug-only logging function; it is a no-op unless
  `VOICE_DEBUG=1`. Transcript text is never logged — only counts and timing.
  Preserve that property.
- Shell scripts in `scripts/` fail closed with a clear message and a non-zero
  exit when a prerequisite is missing. Read the existing "Sparkle CLI not
  found" style message in `publish-sparkle.sh` and match its tone and format.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **`, 0 failures |
| Shell helper oracle | `bash scripts/test-publish-sparkle-helpers.sh` | exit 0 |

Run from the Murmur repo root. Suite is 113 tests at plan time.

## Scope

**In scope**:
- `Sources/Voice/SpokenPunctuation.swift`
- `Sources/Voice/XAIStreamingTranscriber.swift` — the one `vlog` line at `:551` only
- `Sources/Voice/ElevenLabsRealtimeTranscriber.swift` — the one `vlog` line at `:482` only
- `Sources/Voice/ActivationController.swift` — the `vlog` implementation only
- `scripts/publish-sparkle.sh` — the default at `:46` only
- `Tests/VoiceTests/SpokenPunctuationTests.swift` (existing; may gain tests)

**Out of scope** (do NOT touch, even though they look related):
- The phrase/joiner **tables** themselves in `SpokenPunctuation.swift` — this
  is a caching change with zero behavior change. If a table entry looks wrong,
  report it; do not edit it.
- Any other `vlog` call site. Only the two named error lines change.
- The activation/hotkey logic in `ActivationController.swift` — you are
  editing only the file-writing helper at the top of that file.
- `Sources/Voice/CloudTranscriber.swift` — you are *calling* its helper, not
  changing it.
- Anything in `publish-sparkle.sh` beyond the one default assignment. Do not
  touch the signing, upload, or appcast-generation logic.
- `#available(macOS 26.0, *)` cleanup — see Maintenance notes; deliberately
  excluded.

## Git workflow

- Branch: `chore/polish-bundle`
- Conventional commits, one per step:
  `perf: precompile spoken-punctuation regexes`,
  `fix: redact streaming server error text in debug log`,
  `fix: write debug log to a per-user path`,
  `chore: drop hardcoded signing-key default path`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Precompile the spoken-punctuation regexes

Hoist pattern compilation out of the per-call loops into `static let` storage
compiled once. Suggested shape: two static stored properties holding
precompiled pairs, built once at first use —

```swift
    /// Precompiled once: the joiner/phrase patterns are fixed at compile time
    /// and independent of input, but `apply(_:)` runs on the dictation latency
    /// path several times per utterance.
    private static let compiledWordJoiners: [(NSRegularExpression, String)] = …
    private static let compiledPhrasePatterns: [String: NSRegularExpression] = …
```

— then have `applyWordJoiners` / `applyPhraseReplacements` consume those
instead of compiling.

Note `applyPhraseReplacements` takes its `phrases` list as a **parameter**
(it's called with different tables), so key your cache by the spoken string
rather than assuming a single table, or precompile per-table — whichever is
simpler to read. Patterns that fail to compile must still be skipped, exactly
as the current `guard let … else { continue }` does.

Behavior must be **identical**. This is the step most likely to change output
by accident; the existing `SpokenPunctuationTests` suite is your net.

**Verify**: `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
→ `** TEST SUCCEEDED **`, 0 failures, and **every** existing
`SpokenPunctuationTests` case still passes unmodified. If you had to change an
existing test's expectations, you changed behavior — that is a STOP condition.

### Step 2: Redact streaming server error text

At `ElevenLabsRealtimeTranscriber.swift:482` and
`XAIStreamingTranscriber.swift:551`, pass `message` through
`CloudTranscriptionError.redactedBodyFragment(...)` before interpolating it
into the `vlog` call. Change nothing else about those lines — the log prefix
and the surrounding control flow stay as they are.

**Verify**: build succeeds;
`grep -n "server error event" Sources/Voice/XAIStreamingTranscriber.swift Sources/Voice/ElevenLabsRealtimeTranscriber.swift`
→ both lines now route through the redaction helper.

### Step 3: Move the debug log to a per-user path with tight permissions

In `ActivationController.swift`, change the `vlog` implementation to write
into `NSTemporaryDirectory()` (per-user on macOS) instead of the literal
`/tmp`, and create the file with POSIX permissions `0o600` so only the owner
can read it. Update the doc comment at `:8` to name the new location.

**This changes a documented path.** `CLAUDE.md` and `README.md` (and plan
016's smoke grep) may still say `/tmp/voice-debug.log`.

**Done (HARD) after this step:** Prefer option (b) whenever 019 has already
landed (recommended order puts 019 before 020): patch `README.md`,
`CLAUDE.md`, and any remaining `/tmp/voice-debug.log` smoke notes (including
016's Step 5 path) to the new per-user location. If 019 has **not** landed
yet, either (a) note the discrepancy for 019 **and** still patch the two
doc references in a follow-on commit before marking 020 DONE, or (b) patch
them now. **Do not** mark 020 DONE while docs still point at `/tmp/voice-debug.log`.

**Verify**: build succeeds. Then run the app with `VOICE_DEBUG=1`, do one
dictation, and confirm the log appears at the new location with the right
permissions:
`ls -l "$(getconf DARWIN_USER_TEMP_DIR)voice-debug.log"` → shows `-rw-------`.
Report the actual path and permission bits you observed.

### Step 4: Remove the hardcoded signing-key default

In `scripts/publish-sparkle.sh:46`, drop the hardcoded absolute path default.
The variable must come from the environment (or the existing Keychain
`--account` path). When neither is provided, the script must **fail closed**
with a clear message telling the operator to set the environment variable —
matching the existing failure-message style in that script.

Do not print, echo, or log the resolved path. Do not put the old path in the
commit message.

**Verify**: `bash scripts/test-publish-sparkle-helpers.sh` → exit 0. Then
confirm the fail-closed path works with the variable unset — run the script
with no environment configured and confirm it exits non-zero with the new
message rather than silently proceeding. Do **not** run a real publish.

## Test plan

- Steps 1 and 2 are covered by the existing suites (`SpokenPunctuationTests`,
  `RedactionTests`) — the requirement is that they pass **unmodified**.
- Optionally add one `SpokenPunctuationTests` case asserting that calling
  `apply(_:)` twice on the same input yields the same result (guards against a
  cache that accidentally accumulates state). Model it on the existing cases
  in that file.
- Step 3 has no unit test (it writes to a real path); the `ls -l` check is the
  verification.
- Step 4 is covered by `scripts/test-publish-sparkle-helpers.sh` plus the
  manual fail-closed check.

Verification: `xcodebuild test …` → `** TEST SUCCEEDED **`, total ≥ **prior
cumulative** from the execute-plan floors table (after 016+017 ≥118; after 018 ≥126).
Do **not** use absolute ≥113 — that false-passes after earlier plans in this batch.
Optional +1 if you add the idempotence case.

## Done criteria

ALL must hold:

- [ ] `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → `** TEST SUCCEEDED **`, 0 failures, no existing test's expectations modified; total ≥ **prior cumulative** (not absolute ≥113)
- [ ] `grep -n "NSRegularExpression(pattern:" Sources/Voice/SpokenPunctuation.swift` → no matches inside a `for` loop body
- [ ] Both streaming `server error event` log lines route through `redactedBodyFragment`
- [ ] `grep -n '"/tmp/voice-debug.log"' Sources/Voice/ActivationController.swift` → no matches
- [ ] `README.md` / `CLAUDE.md` (and 016 smoke path) no longer document `/tmp/voice-debug.log` as the live debug log location
- [ ] The debug log file is created with `-rw-------` (Step 3 `ls -l` output reported)
- [ ] `grep -n "API Keys" scripts/publish-sparkle.sh` → no matches
- [ ] `bash scripts/test-publish-sparkle-helpers.sh` → exit 0, and the unset-variable case fails closed
- [ ] `git status` shows only in-scope files modified
- [ ] `plans/README.md` status row for 020 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift).
- Step 1 requires changing any existing `SpokenPunctuationTests` expectation —
  that means behavior changed and the cache is wrong. Revert step 1 and report.
- Plan 017 is mid-flight and has uncommitted changes in the two streaming
  transcribers — coordinate rather than editing the same lines concurrently.
- Step 4's fail-closed change would break a working publish flow in a way you
  cannot verify offline. The publish pipeline is live and signs real updates;
  when in doubt, report rather than guess.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- Deliberately **not** included here: removing the now-vestigial
  `#available(macOS 26.0, *)` wrappers at `TransformRunner.swift:28`,
  `CleanupService.swift:278`, `UI/TransformsView.swift:52`, and
  `UI/SettingsStore.swift:409`. The deployment target is 26.0 so the false
  branch is unreachable, but the compiler may still require the annotation for
  the `FoundationModels` API surface, making this a compile-and-see change with
  near-zero payoff. If someone does it later: keep the inner
  `SystemLanguageModel.default.availability` runtime check — only the OS-version
  wrapper is vestigial.
- The `redactedBodyFragment` helper now serves both the REST and WebSocket
  paths but still lives on `CloudTranscriptionError` in `CloudTranscriber.swift`.
  If a third consumer appears, move it somewhere neutral.
- A reviewer should scrutinize: step 1's cache keying (a stale or mis-keyed
  cache silently corrupts dictation output — the highest-consequence part of
  an otherwise trivial plan), and step 4's fail-closed branch.
