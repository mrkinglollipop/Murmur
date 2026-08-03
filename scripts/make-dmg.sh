#!/usr/bin/env bash
# Build a signed, distributable DMG of Murmur.app with the standard
# drag-to-Applications layout. Release build + Developer ID sign + hdiutil
# UDZO + sign the image. Uses built-in hdiutil (no create-dmg dependency).
#
# Notarization is opt-in (NOTARIZE=1), off by default — same stance as
# release.sh. A signed-but-unnotarized DMG opens on this Mac but triggers a
# Gatekeeper prompt (right-click > Open) on other machines.
#
# Assumes the Xcode project is generated (run `xcodegen generate` first if you
# changed project.yml) — matches install-local.sh, which also builds the
# committed project rather than regenerating.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPMENT_TEAM:-}" && -f Config/Team.xcconfig ]]; then
  DEVELOPMENT_TEAM="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' Config/Team.xcconfig \
    | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' ')"
fi
TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM or add DEVELOPMENT_TEAM to Config/Team.xcconfig (see Config/Team.xcconfig.example)}"
IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
DERIVED="$ROOT/build/DerivedData"
PRODUCT="$DERIVED/Build/Products/Release/Murmur.app"
STAGE="$ROOT/build/dmg-stage"

ENTITLEMENTS="$ROOT/Sources/Voice/Voice.entitlements"

echo "==> Building Release (signed)"
# Secure timestamp + no injected get-task-allow — required for Apple notarization.
xcodebuild -scheme Voice -configuration Release build \
  -derivedDataPath "$DERIVED" \
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
sign_nested() {
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
}
sign_nested "$SPARKLE/Versions/B/Autoupdate"
sign_nested "$SPARKLE/Versions/B/Updater.app"
sign_nested "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign_nested "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign_nested "$SPARKLE"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$PRODUCT"
codesign --verify --deep --strict "$PRODUCT"
codesign -d --entitlements :- "$PRODUCT" 2>/dev/null | grep -q get-task-allow \
  && { echo "error: get-task-allow still present after re-sign" >&2; exit 1; } || true

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
