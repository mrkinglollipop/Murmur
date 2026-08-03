# AGENTS.md

Primary developer docs: [`CLAUDE.md`](CLAUDE.md) (setup, verify, conventions)
and [`README.md`](README.md) (product overview). This file adds guidance for
**Cursor Cloud (Linux)** agents only.

## Cursor Cloud

**Murmur is macOS-only.** It cannot be built, run, tested, or lint-checked on
the Linux cloud VM. It targets macOS 26.0 and depends on macOS-exclusive
tooling and frameworks:

- `xcodegen` + `xcodebuild` (Xcode) — not available on Linux
- AppKit, SwiftUI Liquid Glass, WhisperKit / CoreML, CGEvent HID taps, Keychain,
  TCC / Accessibility
- Parakeet sidecar (`Resources/parakeet_transcribe.py`) via `parakeet-mlx`
  (Apple MLX / Metal)

On a Linux cloud agent: do **not** attempt to install a Swift toolchain or fake
a build. Use the commands in [`CLAUDE.md`](CLAUDE.md) on a Mac with Xcode.

**What does run on Linux:** offline release-tooling oracles

```bash
bash scripts/test-publish-sparkle-helpers.sh   # expect: "ORACLE OK", exit 0
bash scripts/test-app-icon-helpers.sh          # partial (skips provenance / icns)
```

`test-app-icon-helpers.sh` needs Pillow (`pip install pillow`) for geometry
checks. Full icon verification requires macOS (`sips` + `iconutil`).

**Config prerequisite:**

```bash
[ -f Config/Team.xcconfig ] || cp Config/Team.xcconfig.example Config/Team.xcconfig
```

**CI:** this repository has no CI by design. Local macOS verification is the
gate — do not add a workflow from a cloud session.
