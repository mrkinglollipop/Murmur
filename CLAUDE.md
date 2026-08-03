# CLAUDE.md

## What this is

macOS 26+ menu-bar push-to-talk dictation app. Product is `Murmur.app`; the
Swift module is `Voice` — intentional, post-rebrand residue. Never "fix" the
module name, bundle ID (`com.matt.voice-dictation`), Keychain service
(`com.matt.voice-dictation.apikeys`), or the data dir
(`~/Library/Application Support/Voice/`) — TCC grants, stored API keys, and
user data are keyed to these and would be lost on rename.

## Setup

```
cp Config/Team.xcconfig.example Config/Team.xcconfig   # xcodegen hard-requires this file to exist
xcodegen generate
```

## Verify

```
xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO
# -> ** BUILD SUCCEEDED **

xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
# -> 318 test methods, 0 failures (count drifts as tests are added)
```

Run all three (generate + build + test) after ANY change to `project.yml` —
it regenerates both the Xcode project and `Info.plist`.

## Install locally

`bash scripts/install-local.sh` — Release build, signed with the Developer ID
identity (needs the cert installed), installs to `/Applications/Murmur.app`.

## Conventions

- Branches: `feat/<slug>` / `fix/<slug>`. Commits: conventional commits.
  Merged via GitHub PR with merge commits.
- Tests accompany behavior changes.
- Stitch-pipeline changes: prefer adding a replay fixture once the fixture
  harness lands (plan `plans/002-stitch-fixture-harness.md` — not yet done;
  until then there's no fixtures dir to add to).

## Sharp edges

- Signing is Manual with a stable Developer ID (not ad-hoc) — TCC binds
  permission grants to the signing identity. Rationale is documented in the
  comment block above `CODE_SIGN_STYLE` in `project.yml`; don't restate it,
  read it before touching signing settings.
- `project.yml` requires the naming trio together: `productName: Murmur`,
  `PRODUCT_NAME: Murmur`, `PRODUCT_MODULE_NAME: Voice`. Dropping any one
  breaks either the built product name or `@testable import Voice` in tests.
- `VOICE_DEBUG=1` enables debug logging to `NSTemporaryDirectory()/voice-debug.log`
  (owner-only `0o600`). On macOS that is typically under
  `$(getconf DARWIN_USER_TEMP_DIR)voice-debug.log`.
- This repo intentionally has NO CI. The operator turned GitHub Actions off
  (2026-07-07) and the workflow file was removed 2026-07-10 to stop the
  failed-run noise. Local verification (above) IS the verification — do not
  re-add a workflow or suggest "fixing" CI.
