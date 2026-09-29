#!/usr/bin/env bash
# Build a signed, distributable DMG of Murmur.app with the standard
# drag-to-Applications layout. Release build + Developer ID sign + hdiutil
# UDZO + sign the image. Uses built-in hdiutil (no create-dmg dependency).
#
# Notarization is opt-in (NOTARIZE=1), off by default. A signed-but-
# unnotarized DMG opens on this Mac but triggers a
# Gatekeeper prompt (right-click > Open) on other machines.
#
# Assumes the Xcode project is generated (run `xcodegen generate` first if you
# changed project.yml) — matches install-local.sh, which also builds the
# committed project rather than regenerating.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"
# Validates the id (^[A-Z0-9]{10}$) — the example file's YOUR_TEAM_ID fails here.
TEAM="$(resolve_development_team "$ROOT/Config/Team.xcconfig")" || exit 1
IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
DERIVED="$ROOT/build/DerivedData"
PRODUCT="$DERIVED/Build/Products/Release/Murmur.app"
STAGE="$ROOT/build/dmg-stage"

ENTITLEMENTS="$ROOT/Sources/Voice/Voice.entitlements"

echo "==> Building Release (signed, arm64-only)"
# Secure timestamp + no injected get-task-allow — required for Apple notarization.
# ARCHS on the xcodebuild line so SPM packages (FluidAudio) skip x86_64.
xcodebuild -scheme Voice -configuration Release build \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64 \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  | (command -v xcpretty >/dev/null && xcpretty || cat)

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$PRODUCT/Contents/Info.plist" 2>/dev/null || echo dev)"
DMG="${DMG_PATH:-$ROOT/build/Murmur-$VERSION.dmg}"

# Sparkle ships nested helpers that SPM leaves unsigned / non–Developer-ID.
# Notary rejects those unless we deep-sign inside-out with our Developer ID.
echo "==> Deep-signing Sparkle nested binaries + Murmur.app (Developer ID + timestamp)"
SPARKLE="$PRODUCT/Contents/Frameworks/Sparkle.framework"
# Sign through Versions/Current, not a hardcoded version letter: Sparkle picks
# the letter, and a minor bump that changes it makes these paths vanish — under
# `set -e` that aborts the release rather than degrading.
SPARKLE_CURRENT="$SPARKLE/Versions/Current"
sign_nested() {
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
}
for nested in Autoupdate Updater.app XPCServices/Downloader.xpc XPCServices/Installer.xpc; do
  if [[ ! -e "$SPARKLE_CURRENT/$nested" ]]; then
    echo "error: expected Sparkle nested binary missing: $SPARKLE_CURRENT/$nested" >&2
    exit 1
  fi
  sign_nested "$SPARKLE_CURRENT/$nested"
done
sign_nested "$SPARKLE"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$PRODUCT"
codesign --verify --deep --strict "$PRODUCT"
# Capture first, then test: in a `codesign | grep -q … && … || true` pipeline
# under pipefail, SIGPIPE (141) or a codesign failure silently skipped the check.
if ! ENTITLEMENTS_OUT="$(codesign -d --entitlements :- "$PRODUCT" 2>/dev/null)"; then
  echo "error: could not read entitlements from re-signed $PRODUCT" >&2
  exit 1
fi
if [[ -z "$ENTITLEMENTS_OUT" ]]; then
  echo "error: re-signed app reports no entitlements (expected Voice.entitlements)" >&2
  exit 1
fi
if grep -q get-task-allow <<<"$ENTITLEMENTS_OUT"; then
  echo "error: get-task-allow still present after re-sign" >&2
  exit 1
fi

echo "==> Staging (Murmur.app + /Applications symlink)"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$PRODUCT" "$STAGE/Murmur.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG (UDZO)"
hdiutil create -volname "Murmur $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Signing DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Verifying"
hdiutil verify "$DMG" >/dev/null && echo "  image checksum OK"
codesign --verify "$DMG" && echo "  signature OK"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
  echo "==> Notarizing (keychain profile: $PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo ""
  echo "==> Signed, NOT notarized. Opens on this Mac; other Macs get a"
  echo "    Gatekeeper prompt (right-click > Open). To notarize:"
  echo "      NOTARIZE=1 NOTARY_PROFILE=<profile> bash scripts/make-dmg.sh"
  echo "    (one-time: xcrun notarytool store-credentials <profile> \\"
  echo "       --apple-id <id> --team-id $TEAM --password <app-specific-pw>)"
fi

echo ""
echo "==> Done: $DMG"
