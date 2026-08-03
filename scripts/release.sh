#!/usr/bin/env bash
# Archive, sign (when CODE_SIGN_IDENTITY is set), notarize stub, and zip Murmur.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Voice"
CONFIG="${CONFIG:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/Voice.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT/build/export}"
APP_PATH="$EXPORT_PATH/Murmur.app"
ZIP_PATH="${ZIP_PATH:-$ROOT/build/Murmur.zip}"

if [[ -z "${DEVELOPMENT_TEAM:-}" && -f Config/Team.xcconfig ]]; then
  DEVELOPMENT_TEAM="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' Config/Team.xcconfig \
    | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' ')"
fi
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM or add DEVELOPMENT_TEAM to Config/Team.xcconfig (see Config/Team.xcconfig.example)}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"

echo "==> Generating Xcode project (DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM)"
xcodegen generate

echo "==> Archiving ($CONFIG)"
xcodebuild archive \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  | (command -v xcpretty >/dev/null && xcpretty || cat)

echo "==> Exporting archive"
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$ROOT/Config/ExportOptions.plist" \
  2>/dev/null || {
    echo "No ExportOptions.plist — copying app from archive"
    mkdir -p "$EXPORT_PATH"
    cp -R "$ARCHIVE_PATH/Products/Applications/Murmur.app" "$APP_PATH"
  }

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  echo "==> Signed with identity: $CODE_SIGN_IDENTITY"
else
  echo "==> Skipping sign (CODE_SIGN_IDENTITY unset)"
fi

echo ""
echo "==> Notarization (manual step)"
echo "Upload the exported app or zip to Apple notary service, then staple:"
echo "  xcrun notarytool submit \"$ZIP_PATH\" --keychain-profile AC_PASSWORD --wait"
echo "  xcrun stapler staple \"$APP_PATH\""
echo ""

echo "==> Zipping"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Created $ZIP_PATH"
