# CLAUDE.md

Agent / maintainer notes for Murmur. Product docs for humans: [`README.md`](README.md).

## What this is

macOS 26+ menu-bar push-to-talk dictation. The product is `Murmur.app`; the
Swift module remains `Voice` — intentional post-rebrand residue. Do **not**
rename the module, bundle ID (`com.matt.voice-dictation`), Keychain service
(`com.matt.voice-dictation.apikeys`), or data directory
(`~/Library/Application Support/Voice/`). TCC grants, stored API keys, and
user data are keyed to these identifiers.

## Setup

```bash
cp Config/Team.xcconfig.example Config/Team.xcconfig   # XcodeGen requires this file
xcodegen generate
```

## Verify

```bash
xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO
# → ** BUILD SUCCEEDED **

xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
# → expect a green suite (method count drifts as tests are added)
```

Run generate + build + test after any change to `project.yml` — it regenerates
both the Xcode project and `Info.plist`.

## Install locally

`bash scripts/install-local.sh` — Release build, signed with the Developer ID
identity (certificate must be installed), installs to `/Applications/Murmur.app`.

## Conventions

- Branches: `feat/<slug>` / `fix/<slug>`. Conventional commits. Prefer GitHub
  PRs with merge commits.
- Tests accompany behavior changes.
- Stitch-pipeline changes: prefer a replay fixture once
  [`plans/002-stitch-fixture-harness.md`](plans/002-stitch-fixture-harness.md)
  lands (not yet done).

## Sharp edges

- Signing is Manual with a stable Developer ID (not ad-hoc) — TCC binds
  permission grants to the signing identity. Read the comment block above
  `CODE_SIGN_STYLE` in `project.yml` before changing signing settings.
- `project.yml` requires the naming trio together: `productName: Murmur`,
  `PRODUCT_NAME: Murmur`, `PRODUCT_MODULE_NAME: Voice`. Dropping any one
  breaks the product name or `@testable import Voice` in tests.
- `VOICE_DEBUG=1` enables debug logging to
  `NSTemporaryDirectory()/voice-debug.log` (owner-only `0o600`). On macOS that
  is typically under `$(getconf DARWIN_USER_TEMP_DIR)voice-debug.log`.
  Transcript text is never logged — only counts and timing.
- This repository intentionally has **no CI**. Local verification (above) is
  the gate — do not re-add a GitHub Actions workflow without an explicit
  maintainer decision.
