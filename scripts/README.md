# Scripts

| Script | What it does | When to run |
|--------|--------------|-------------|
| `install-local.sh` | Release build + Developer ID sign + install to `/Applications/Murmur.app` | Dogfood a local build |
| `make-dmg.sh` | Signed DMG (opt-in `NOTARIZE=1`) | Package a distributable |
| `publish-sparkle.sh` | Calls `make-dmg.sh`, Sparkle-signs, publishes DMG + appcast to `Murmur-updates` | Ship an in-app update |
| `release.sh` | Legacy archive/export/zip path | Prefer `make-dmg` + `publish-sparkle` instead |
| `test-publish-sparkle-helpers.sh` | Offline oracle for publish-sparkle helper logic | After editing `publish-sparkle.sh` |
| `generate-app-icon.sh` | Regenerate `AppIcon.iconset` + `Resources/AppIcon.icns` from `AppIcon.source.png` (macOS `sips` + `iconutil`) | After changing committed icon artwork |
| `test-app-icon-helpers.sh` | Offline oracle for icon source geometry, iconset members, and icns drift | After editing icon assets or `generate-app-icon.sh` |

**Current release path:** `make-dmg.sh` → `publish-sparkle.sh`. `release.sh` is legacy.

## Signing (`DEVELOPMENT_TEAM`)

Signed scripts (`install-local.sh`, `make-dmg.sh`, `release.sh`) need an Apple
Developer team ID. Each script honours a `DEVELOPMENT_TEAM` environment override;
if unset, they read `DEVELOPMENT_TEAM` from `Config/Team.xcconfig` (copy from
`Config/Team.xcconfig.example`). If both are missing, the script fails with a clear
error. Unsigned contributor builds use `CODE_SIGNING_ALLOWED=NO` on `xcodebuild`
(see README Build section).

## Public repo cut (Phase 5)

`scripts/public-cut.gitignore` lists paths to merge into `.gitignore` when cutting
the public tree — notably `Voice.xcodeproj`, which contributors generate via
`xcodegen generate`. Do not add those lines to the private repo `.gitignore` until
Phase 5.
