# Contributing to Murmur

Thanks for contributing. Murmur is licensed under the **GNU Affero General
Public License v3.0** (see [`LICENSE`](LICENSE)). Copyright is held by
**Matthew Schwartz** (d/b/a King Lollipop Studios). Dual-licensing remains
available only if contributors assign copyright via a CLA — a DCO alone is
not sufficient.

## Contributor License Agreement (CLA)

By opening a pull request, you agree that:

1. You are authorized to contribute the submitted material.
2. You assign copyright in your contribution to **Matthew Schwartz**, so it can
   be licensed under AGPL-3.0 and optionally dual-licensed.
3. Your contribution is provided under AGPL-3.0 terms unless otherwise stated.

If you cannot assign copyright (for example, employer ownership), say so in the
PR before merge. We will not land the change until that is resolved.

## Build and test

This repository has **no CI by design**. Verification is local on macOS with
Xcode.

```bash
cp Config/Team.xcconfig.example Config/Team.xcconfig   # required by XcodeGen
# Optional: set DEVELOPMENT_TEAM in that file for signed builds
xcodegen generate
xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

`Voice.xcodeproj` is generated and not tracked — run `xcodegen generate` after
clone or any `project.yml` change.

Unsigned contributor builds should use `CODE_SIGNING_ALLOWED=NO`. Release and
install scripts need a stable Developer ID — see the signing comments in
[`project.yml`](project.yml) and [`scripts/README.md`](scripts/README.md).

When shipping a version, bump [`Resources/WhatsNew/releases.json`](Resources/WhatsNew/releases.json)
with a newest-first entry (`version`, `build`, `title`, bullet `items`) so the
in-app What's New sheet and Settings section stay current.

### X promo draft (studio)

Publishing a **GitHub Release** can auto-create an X post **draft** in
[King-Lollipop-Studio](https://github.com/mrkinglollipop/King-Lollipop-Studio)
via [`.github/workflows/x-social-draft.yml`](.github/workflows/x-social-draft.yml).
Add repository secret **`STUDIO_PUSH_TOKEN`**: a PAT with `contents:write` on
that studio repo. The workflow never uses X API keys; Matt approves and publishes
from `social/x/` locally. Details: studio [`social/x/README.md`](https://github.com/mrkinglollipop/King-Lollipop-Studio/blob/main/social/x/README.md).

## Copyright headers

Murmur source files intentionally omit per-file copyright headers. Do not
mass-insert them. Project copyright lives in [`LICENSE`](LICENSE).

## Pull requests

- Branches: `feat/<slug>` / `fix/<slug>`
- Conventional commits
- Prefer a focused PR with build and test evidence in the description
- Do not commit `Config/Team.xcconfig`, Sparkle private keys, or API keys
