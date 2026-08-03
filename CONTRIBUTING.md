# Contributing to Murmur

Thanks for contributing. Murmur is licensed under the **GNU Affero General
Public License v3.0** (see [`LICENSE`](LICENSE)). Copyright is held by
**Matthew Schwartz** (d/b/a King Lollipop Studios). Dual-licensing remains
available only if contributors assign copyright via a CLA — a DCO is not
enough for that.

## Contributor License Agreement (CLA)

By opening a pull request, you agree that:

1. You are authorized to contribute the submitted material.
2. You assign copyright in your contribution to **Matthew Schwartz**, so it can
   be licensed under AGPL-3.0 and optionally dual-licensed.
3. Your contribution is provided under AGPL-3.0 terms unless otherwise stated.

If you cannot assign copyright (e.g. employer ownership), say so in the PR
before merge; we will not land the change until that is resolved.

## Build and test (local only — no CI by design)

This repository intentionally has **no CI**. Local verification on macOS with
Xcode is the gate.

```bash
cp Config/Team.xcconfig.example Config/Team.xcconfig   # required by xcodegen
# Set DEVELOPMENT_TEAM in Config/Team.xcconfig for signed builds, or export it.
xcodegen generate
xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Contributor builds that skip codesigning should use `CODE_SIGNING_ALLOWED=NO`.
Release / install scripts need a stable Developer ID — see the comment above
`CODE_SIGN_STYLE` in [`project.yml`](project.yml) and
[`scripts/README.md`](scripts/README.md) (`DEVELOPMENT_TEAM` env override).

After cloning a tree that does not track `Voice.xcodeproj`, run
`xcodegen generate` before opening the project in Xcode.

When shipping a version, bump `Resources/WhatsNew/releases.json` with a
newest-first entry (version, build, title, bullet items) so the in-app
What's New sheet and Settings section stay current.

## Copyright file headers

**Intentional omission:** Murmur source files do not carry per-file copyright
headers. A repo-wide grep for Murmur/program copyright headers found none
outside license/font third-party notices and this plan/docs set. Do not
mass-insert headers. The project copyright line lives in [`LICENSE`](LICENSE).

## Pull requests

- Branches: `feat/<slug>` / `fix/<slug>`. Conventional commits.
- Prefer a focused PR with build + test evidence in the description.
- Do not commit `Config/Team.xcconfig`, Sparkle private keys, or API keys.
