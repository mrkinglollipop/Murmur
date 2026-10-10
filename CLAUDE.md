# CLAUDE.md

Agent / maintainer notes for Murmur. Product docs for humans: [`README.md`](README.md).

## What this is

macOS 26+ menu-bar push-to-talk dictation. The product is `Murmur.app`; the
Swift module remains `Voice` — intentional post-rebrand residue. Do **not**
rename the module, bundle ID (`com.matt.voice-dictation`), Keychain service
(`com.matt.voice-dictation.apikeys`), or data directory
(`~/Library/Application Support/Voice/`). TCC grants, stored API keys, and
user data are keyed to these identifiers.

## iOS keyboard

Separate XcodeGen project under [`ios/`](ios/README.md). Do **not** add those
targets to the Mac `project.yml`. Spike shipped in PR #35; that README is the
in-repo worksheet. Linux cloud agents cannot build or device-test it.

## Clipboard manager — PRO ONLY, must not reach `main`

The clipboard manager (`ClipboardCrypto`, `ClipboardStore`, `ClipboardWatcher`,
`ClipboardView`, and the `RootTab.clipboard` case) is a **paid Pro feature**.

- **Never merge it into `main`.** Its merge target is the `pro` branch, and
  only once a Pro entitlement check exists to gate it. Shipping it on `main`
  gives a paid feature away to every free user, and it cannot be clawed back.
- It is being built on a branch cut from `main` purely because it has zero
  dependency on the Supabase auth plumbing that lives on `pro` — not because
  `main` is the destination.
- Before opening a PR for any branch touching these files, check the base
  branch. `gh pr create --base main` is the mistake this note exists to stop.
- Sole exception: the additive `accessibility:` parameter on
  `KeychainStore.setKey` is generic infrastructure and is safe on `main`.

## Setup

```bash
cp Config/Team.xcconfig.example Config/Team.xcconfig   # XcodeGen requires this file
xcodegen generate
```

## Verify

Build + unit suite (necessary; **not** a dictation product pass):

```bash
xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO
# → ** BUILD SUCCEEDED **

xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
# → expect a green suite (method count drifts as tests are added)
```

**Product oracle (AudioRecorder / HAL / `engine.start` / `bindInputNode`):**
VoiceTests went green twice on 2026-08-17 while every dictation hold either
SIGABRT'd (`prepare()` before CurrentDevice) or HUD-failed (0-ch graph bound
Continuity iPhone). After those files change: `install-local.sh`, one fn-hold,
then:

```bash
bash scripts/oracle-dictation-start.sh
# 0 = engine started this window
# 1 = crash or mic start failed
# 2 = no hold in the window — not a pass; do not Sparkle
```

Offline encode check (Linux-safe):
`bash scripts/test-oracle-dictation-start-helpers.sh` → `ORACLE OK`.

Do not cut Sparkle on VoiceTests-only after those changes. Public feed ≠
`/Applications` after `install-local.sh`.

Run generate + build + test after any change to `project.yml` — it regenerates
both the Xcode project and `Info.plist`.

## Install locally

`bash scripts/install-local.sh` — Release build, signed with the Developer ID
identity (certificate must be installed), installs to `/Applications/Murmur.app`.
After AudioRecorder / HAL / engine.start / bind changes, a green install is
still not a product pass until `oracle-dictation-start.sh` exits 0.

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
  For Finder- or Sparkle-launched builds, run `launchctl setenv VOICE_DEBUG 1` before launching Murmur.
- This repository intentionally has **no CI**. Local verification (above) is
  the gate — do not re-add a GitHub Actions workflow without an explicit
  maintainer decision.
- `engine.prepare()` before `AudioUnitSetProperty(CurrentDevice)` raises an
  ObjC `NSException`; Swift `try` does not catch it (Sparkle 0.1.36 SIGABRT on
  every hold). Set the device first; `prepare()` inside `ObjCExceptionCatcher`.
- Skipping `prepare()` leaves `inputNode` at 0 ch; the picker falls through to
  Continuity (`ccwl`) / Jump Desktop (`virt`). Those transports are last-resort
  only when they are the Sound Input default.
- `engine.start()` posts `AVAudioEngineConfigurationChange`. Do not fail-closed
  on that notification while start is in-flight.
