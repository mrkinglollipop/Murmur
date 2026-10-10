#!/usr/bin/env bash
# Fast local install: Release build + Developer ID sign + copy to /Applications.
# Avoids xcodebuild archive (slow) and ad-hoc signing (breaks Sparkle + TCC grants).
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
DEST="/Applications/Murmur.app"
INSTALL_ROOT=""
cleanup_install() {
  if [[ -n "$INSTALL_ROOT" && -d "$INSTALL_ROOT" ]]; then
    rmdir "$INSTALL_ROOT" 2>/dev/null || true
  fi
}
trap cleanup_install EXIT

echo "==> xcodegen generate"
xcodegen generate

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
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  | (command -v xcpretty >/dev/null && xcpretty || cat)

if [[ ! -d "$PRODUCT" ]]; then
  echo "error: build product missing: $PRODUCT" >&2
  exit 1
fi

echo "==> Verifying build product signature"
codesign --verify --deep --strict "$PRODUCT"
assert_no_get_task_allow "$PRODUCT" || exit 1

# A standard checkout must not silently replace the owner's private Pro app.
if [[ -e "$DEST" ]]; then
  set +e
  is_pro_app_bundle "$DEST"
  dest_is_pro=$?
  is_pro_app_bundle "$PRODUCT"
  product_is_pro=$?
  set -e
  if [[ "$dest_is_pro" -eq 2 || "$product_is_pro" -eq 2 ]]; then
    echo "error: cannot determine whether the installed or built app is Pro; refusing replacement." >&2
    exit 1
  fi
  if [[ "$dest_is_pro" -eq 0 && "$product_is_pro" -ne 0 ]]; then
    echo "error: refusing to replace the installed Pro app with a standard build. Build from the private Pro checkout." >&2
    exit 1
  fi
fi

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
  # Ignored the quit request. Fall back to SIGTERM (still runs
  # applicationWillTerminate via the default handler) on the captured PIDs of
  # the INSTALLED copy only — never another build that happens to be running.
  echo "==> Murmur ignored the quit request; sending SIGTERM to the installed copy"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
      "$DEST"/*) sigterm_and_wait "$pid" 50 || true ;;
    esac
  done < <(pgrep -x Murmur 2>/dev/null || true)
fi
if pgrep -x Murmur >/dev/null 2>&1; then
  echo "error: Murmur did not quit (survived SIGTERM, or is not the installed copy). The installed app is unchanged; staged build: $STAGING" >&2
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
