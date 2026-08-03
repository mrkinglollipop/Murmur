#!/usr/bin/env bash
# Offline oracle: install-local.sh must replace /Applications, never merge.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/install-local.sh"

bash -n "$SCRIPT"

# Staging path + verify before mv (atomic replace contract).
grep -q 'Murmur.app.installing' "$SCRIPT"
grep -q 'codesign --verify --deep --strict' "$SCRIPT"
grep -q 'rm -rf "$DEST"' "$SCRIPT"
grep -q 'mv "$STAGING" "$DEST"' "$SCRIPT"

# Must not ditto straight onto /Applications/Murmur.app (merge hazard).
if grep -E 'ditto.*"\$PRODUCT".*/Applications/Murmur\.app"' "$SCRIPT"; then
  echo "FAIL: ditto merges into /Applications/Murmur.app" >&2
  exit 1
fi

echo "ORACLE OK — install-local replace+verify contract"
