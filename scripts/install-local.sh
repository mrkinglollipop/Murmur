#!/usr/bin/env bash
# Fast local install: Release build + Developer ID sign + copy to /Applications.
# Avoids xcodebuild archive (slow) and ad-hoc signing (breaks Sparkle + TCC grants).
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
DEST="/Applications/Murmur.app"
STAGING="/Applications/Murmur.app.installing"

echo "==> Building Release (signed, arm64-only)"
# ARCHS must be on the xcodebuild line — SPM package targets (FluidAudio) ignore
# project.yml ARCHS and otherwise still compile x86_64 (Float16 unavailable).
/usr/bin/time -p xcodebuild -scheme Voice -configuration Release build \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64 \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  | (command -v xcpretty >/dev/null && xcpretty || cat)

if [[ ! -d "$PRODUCT" ]]; then
  echo "error: build product missing: $PRODUCT" >&2
  exit 1
fi

echo "==> Verifying build product signature"
codesign --verify --deep --strict "$PRODUCT"

echo "==> Installing to $DEST"
# Soft quit first; then hard-kill any leftover. A hung/orphan Murmur (PPID 1)
# blocks the next open with SIGABRT in HIServices RegisterApplication.
osascript -e 'tell application "Murmur" to quit' 2>/dev/null || true
sleep 1
if pgrep -x Murmur >/dev/null 2>&1; then
  echo "==> Murmur still running after quit — killall -9"
  killall -9 Murmur 2>/dev/null || true
  sleep 1
fi

# Atomic replace: never ditto-merge into a live bundle. Leftover orphan files
# (e.g. *.bak) break sealed resources → Sparkle greyed out + injection dies.
rm -rf "$STAGING"
ditto "$PRODUCT" "$STAGING"
if ! codesign --verify --deep --strict "$STAGING"; then
  echo "error: staged Murmur.app failed codesign --verify" >&2
  rm -rf "$STAGING"
  exit 1
fi
rm -rf "$DEST"
mv "$STAGING" "$DEST"

open -a "$DEST"
codesign -dv "$DEST" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" || true
echo "==> Done (codesign verified)"
