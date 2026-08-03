# AGENTS.md

Primary developer docs live in `CLAUDE.md` (setup, verify, install, conventions, sharp
edges) and `README.md` (product + runtime behavior). Read those first. This file only adds
guidance specific to Cursor Cloud (Linux) agents.

## Cursor Cloud specific instructions

**This is a macOS-only app and cannot be built, run, tested, or lint-checked on the Linux
cloud VM.** `Murmur` targets macOS 26.0 and depends on macOS-exclusive toolchain and
frameworks:

- Build requires `xcodegen` + `xcodebuild` (Xcode), which are macOS-only and cannot be
  installed on Linux. There is no Swift toolchain or macOS SDK on the cloud VM.
- The app links AppKit, SwiftUI Liquid Glass (`.glassEffect`, macOS 26-only), CoreML via
  WhisperKit, CGEvent HID taps, Keychain, TCC/Accessibility — none available on Linux.
- Signing is Manual Developer ID bound to TCC grants (see `project.yml` / `CLAUDE.md`).
- The Parakeet sidecar (`Resources/parakeet_transcribe.py`) needs `parakeet-mlx`
  (Apple MLX / Metal), which is macOS-only.

Consequence for cloud agents: the real build/test/lint/run loop (`xcodegen generate`,
`xcodebuild build`, `xcodebuild test`, `scripts/install-local.sh`) can ONLY be executed on a
macOS host with Xcode. Use the exact commands in `CLAUDE.md` there; do not attempt them on
the Linux VM. Do not try to `apt install swift` or otherwise fake a build — the code will not
compile without the macOS SDK.

**What DOES run on the Linux cloud VM:** offline release-tooling oracles

```bash
bash scripts/test-publish-sparkle-helpers.sh   # expect: "ORACLE OK", exit 0
bash scripts/test-app-icon-helpers.sh          # partial on Linux (skips provenance/icns)
```

`test-publish-sparkle-helpers.sh` uses only `bash -n`, `grep`, and `python3` (no network, no
`gh`, no Xcode). `test-app-icon-helpers.sh` needs **Pillow** (`pip install pillow`) for
cross-platform source/iconset geometry checks; on Linux it **SKIP**s macOS provenance (regenerate
all ten members from pinned source + icns hash compare). Full icon verification requires macOS
(`sips` + `iconutil`). Icon generation (`scripts/generate-app-icon.sh`) is macOS-only.

**Config prerequisite:** `xcodegen` hard-requires `Config/Team.xcconfig` to exist. It is
gitignored; create it from the example when missing (the update script does this idempotently):

```bash
[ -f Config/Team.xcconfig ] || cp Config/Team.xcconfig.example Config/Team.xcconfig
```

**CI:** this repo intentionally has no CI (see `CLAUDE.md`). Local macOS verification is the
verification — do not add a workflow.
