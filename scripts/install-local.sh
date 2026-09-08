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
INSTALL_ROOT=""
cleanup_install() {
  if [[ -n "$INSTALL_ROOT" && -d "$INSTALL_ROOT" ]]; then
    rmdir "$INSTALL_ROOT" 2>/dev/null || true
  fi
}
trap cleanup_install EXIT

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

# A standard checkout must not silently replace the owner's private Pro app.
python3 - "$PRODUCT" "$DEST" <<'PY'
import pathlib, plistlib, sys
def is_pro(path):
    plist = pathlib.Path(path) / 'Contents/Info.plist'
    if not plist.exists():
        return False
    info = plistlib.loads(plist.read_bytes())
    return any(item.get('CFBundleURLName') == 'com.matt.voice-dictation.auth'
               or 'murmur' in item.get('CFBundleURLSchemes', [])
               for item in info.get('CFBundleURLTypes', []))
if is_pro(sys.argv[2]) and not is_pro(sys.argv[1]):
    sys.exit('error: refusing to replace the installed Pro app with a standard build. Build from the private Pro checkout.')
PY

INSTALL_ROOT="$(mktemp -d /Applications/.Murmur-install.XXXXXX)"
STAGING="$INSTALL_ROOT/Murmur.app"
ditto "$PRODUCT" "$STAGING"
codesign --verify --deep --strict "$STAGING"

echo "==> Installing to $DEST"
# Let applicationWillTerminate flush stores. A process that refuses to quit
# is a failed install, not permission to destroy its unsaved state.
osascript -e 'tell application "Murmur" to quit' 2>/dev/null || true
for attempt in {1..100}; do
  if ! pgrep -x Murmur >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if pgrep -x Murmur >/dev/null 2>&1; then
  echo "error: Murmur did not quit. The installed app is unchanged; staged build: $STAGING" >&2
  exit 1
fi

# Atomic replace: never ditto-merge into a live bundle. Leftover orphan files
# (e.g. *.bak) break sealed resources → Sparkle greyed out + injection dies.
ROLLBACK="$INSTALL_ROOT/Previous-Murmur.app"
if [[ -e "$DEST" ]]; then mv "$DEST" "$ROLLBACK"; fi
if ! mv "$STAGING" "$DEST"; then
  if [[ -d "$ROLLBACK" ]]; then mv "$ROLLBACK" "$DEST"; fi
  echo "error: replacement failed; previous app restored." >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$DEST"; then
  mv "$DEST" "$STAGING"
  if [[ -d "$ROLLBACK" ]]; then mv "$ROLLBACK" "$DEST"; fi
  echo "error: installed signature failed; previous app restored." >&2
  exit 1
fi

open -a "$DEST"
codesign -dv "$DEST" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" || true
echo "==> Done (codesign verified)"
if [[ -d "$ROLLBACK" ]]; then echo "==> Previous app retained at $ROLLBACK"; fi
