# Plan 005: Docs & dependencies batch — fix README setup, WhisperKit manifest, deprecated notification API, parakeet pin

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 223d130..HEAD -- README.md project.yml Sources/Voice/HotkeyController.swift Resources/parakeet_transcribe.py`
> On drift, compare excerpts before proceeding; mismatch = STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (one MED item: WhisperKit floor bump — see Step 2)
- **Depends on**: none
- **Category**: docs + migration
- **Planned at**: commit `223d130`, 2026-07-09

## Why this matters

Four cheap time bombs: the README's build section starts from a directory
that does not exist and omits a hard-required setup step, so following the
docs verbatim fails; the WhisperKit manifest URL now 301-redirects (repo
moved to a monorepo) and its `from: "0.9.0"` floor is 9 pre-1.0 minors behind
the resolved 0.18.0, so a future resolve could jump versions with no review;
the app's only notification call uses `NSUserNotification`, deprecated since
macOS 10.14; and the Parakeet sidecar's install instruction is unpinned
against an actively-changing pip package.

## Current state

- `README.md:68-76` (verified at `223d130`):

  ```markdown
  ## Build

  ```bash
  cd <path-to-your-clone>
  xcodegen generate
  ...
  ```

  The example used a stale absolute clone path (wrong volume or folder name) —
  and there is no mention that `Config/Team.xcconfig` must be created from
  `Config/Team.xcconfig.example` before `xcodegen generate` will succeed.
  The Features section (README top) also omits shipped features: voice
  commands ("scratch that"), history export (JSON/Markdown), toggle-lock
  recording (double-tap), dictation-language picker.

- `project.yml:9-12`:

  ```yaml
  packages:
    WhisperKit:
      url: https://github.com/argmaxinc/WhisperKit
      from: "0.9.0"
  ```

  Web-verified 2026-07-09: that URL 301-redirects; canonical repo is now
  `argmaxinc/argmax-oss-swift`. `Package.resolved` (untracked build artifact)
  resolves 0.18.0 today.

- `Sources/Voice/HotkeyController.swift:104-109`:

  ```swift
  private func notify(title: String, body: String) {
      let notification = NSUserNotification()
      notification.title = title
      notification.informativeText = body
      NSUserNotificationCenter.default.deliver(notification)
  }
  ```

  Only call sites: transform success/failure notifications in this file
  (`grep -n "notify(title:" Sources/` to confirm the full set).

- `Resources/parakeet_transcribe.py` — header says install via bare
  `pip install parakeet-mlx` (line ~16, after Plan 004 removes line 2 the
  numbering shifts by one); a comment notes "API verified 2026-07-02" but
  nothing pins or checks the version.

## Commands you will need

| Purpose  | Command | Expected on success |
|----------|---------|---------------------|
| Generate | `xcodegen generate` | Created project |
| Build    | `xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests    | `xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Resolve check | `grep -A2 "argmax" Voice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null \|\| find . -name Package.resolved -not -path "./.git/*" -exec grep -l whisperkit {} \;` | shows resolved WhisperKit pin |

## Scope

**In scope**: `README.md`; `project.yml` (packages block ONLY);
`Sources/Voice/HotkeyController.swift` (the `notify` function ONLY);
`Resources/parakeet_transcribe.py` (header comment ONLY); `plans/README.md`.

**Out of scope**: everything else — especially the rest of `project.yml`
(naming/signing settings are load-bearing; see comments in that file) and
`ParakeetEngine.swift`.

## Git workflow

- Branch: `chore/docs-deps-batch`
- One commit per step, conventional style.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix README

1. Replace any hardcoded absolute `cd` line with `cd <path-to-your-clone>` (generic — the hardcoded absolute path is
   the bug).
2. Add, immediately before `xcodegen generate` in the Build section:
   `cp Config/Team.xcconfig.example Config/Team.xcconfig  # once, before first generate`.
3. Append to the Features list (match existing bullet style): voice commands
   ("scratch that" / "delete last sentence"), history export (JSON/Markdown)
   + re-inject, toggle-lock recording (double-tap the activation key),
   dictation language picker.

**Verify**: `grep -n "CURSOR" README.md` → no hits; `grep -n "Team.xcconfig.example" README.md` → 1+ hit.

### Step 2: Update the WhisperKit package reference

In `project.yml`, change the WhisperKit URL to
`https://github.com/argmaxinc/argmax-oss-swift` and raise the floor to the
CURRENTLY RESOLVED version (read it from `Package.resolved` via the resolve
check command — expected 0.18.0, but trust the file). Keep the `from:` form.
Then regenerate and do a FULL clean verification — a pre-1.0 floor bump can
surface API changes:

**Verify**: `xcodegen generate` → success; `rm -rf build && xcodebuild -scheme Voice -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`; full test run → green. If the monorepo URL changes the product/package name and generation or resolution fails, STOP (see conditions).

### Step 3: Swap NSUserNotification → UserNotifications

Replace the body of `notify(title:body:)` in `HotkeyController.swift` with
`UNUserNotificationCenter`:

```swift
import UserNotifications   // add to the file's imports

private func notify(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert]) { granted, _ in
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
```

Note: `UNUserNotificationCenter.current()` requires a real app bundle at
runtime — fine here (called only from the running app), but do NOT unit-test
it directly.

**Verify**: build green; `grep -rn "NSUserNotification" Sources/` → no hits.

### Step 4: Pin the parakeet-mlx instruction

In `Resources/parakeet_transcribe.py`'s header, change the install line to
`pip install "parakeet-mlx==<version>"` where `<version>` is the currently
verified one — determine it by running
`pip3 show parakeet-mlx 2>/dev/null | head -2` on this machine; if the
package is not installed locally, use `0.5.2` (PyPI latest as of 2026-07-09,
noted in the audit) and say so in the commit message. Add one sentence: "If
the pinned version mismatches, transcription fails with invalid-JSON errors —
check the version first."

**Verify**: `grep -n "parakeet-mlx==" Resources/parakeet_transcribe.py` → 1 hit.

## Test plan

No new tests. The full existing suite runs after Step 2 (the only step that
can change behavior) and Step 3 (build-level verification; notification
behavior is runtime-only — report it as unverified-manual).

## Done criteria

- [ ] README has no stale path, documents the xcconfig step, lists the four missing features
- [ ] `project.yml` points at the canonical WhisperKit repo with a current floor; clean build + tests green
- [ ] `grep -rn "NSUserNotification" Sources/` → no hits; build green
- [ ] parakeet install instruction pinned
- [ ] Only in-scope files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Step 2: the new URL fails to resolve, or the package/product name differs in
  the monorepo (xcodegen or SPM errors) — report the exact error; do not
  guess at product-name remapping.
- Step 2: any test failure after the floor bump — a pre-1.0 breaking change;
  revert the `from:` bump (keep the URL fix if it resolves cleanly) and report.
- Step 3: the notification swap requires Info.plist or entitlement changes to
  build — report; `project.yml` is out of scope beyond the packages block.

## Maintenance notes

- WhisperKit is pre-1.0: future bumps should always pin-then-test, never
  float. Consider `exactVersion` if churn continues.
- The UN-framework authorization prompt fires on first transform
  notification — a one-time UX blip worth mentioning in release notes.
