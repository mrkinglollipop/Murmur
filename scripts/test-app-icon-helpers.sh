#!/usr/bin/env bash
# Offline oracle: committed Murmur app icon matches AppIcon.source.png and
# cannot silently regress. Geometry checks use python3 + Pillow (all platforms).
# Full provenance (regenerate + hash compare + icns) requires macOS sips/iconutil.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SOURCE="$ROOT/AppIcon.source.png"
ICONSET="$ROOT/AppIcon.iconset"
ICNS="$ROOT/Resources/AppIcon.icns"
GENERATE="$ROOT/scripts/generate-app-icon.sh"
FAIL=0

# Normalized A-glass-v2 source (1024, inset ~0.86, v09-derived rounded alpha).
EXPECTED_SOURCE_SHA256="cf9514a97a0f9ebb4b63bb10311e6d14d4f3e9481a1211df62d58d6cdbb30eac"

declare -a SIZES=(
  16:icon_16x16.png
  32:icon_16x16@2x.png
  32:icon_32x32.png
  64:icon_32x32@2x.png
  128:icon_128x128.png
  256:icon_128x128@2x.png
  256:icon_256x256.png
  512:icon_256x256@2x.png
  512:icon_512x512.png
  1024:icon_512x512@2x.png
)

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=1; }
skip() { echo "  SKIP: $*"; }

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

is_macos_icon_tools() {
  [[ "$(uname -s)" == "Darwin" ]] \
    && command -v sips >/dev/null 2>&1 \
    && command -v iconutil >/dev/null 2>&1
}

require_pillow() {
  python3 - <<'PY'
import sys
try:
    from PIL import Image  # noqa: F401
except ImportError:
    sys.exit(1)
PY
}

echo "==> bash -n generate-app-icon.sh"
if bash -n "$GENERATE"; then
  pass "bash -n"
else
  fail "bash -n"
fi

echo "==> source artwork pinned"
if [[ ! -f "$SOURCE" ]]; then
  fail "missing $SOURCE"
else
  actual="$(sha256_file "$SOURCE")"
  if [[ "$actual" == "$EXPECTED_SOURCE_SHA256" ]]; then
    pass "AppIcon.source.png sha256"
  else
    fail "AppIcon.source.png sha256 (expected $EXPECTED_SOURCE_SHA256, got $actual)"
  fi
fi

echo "==> source geometry (1024, alpha, transparent corners, inset bounds)"
if ! require_pillow; then
  fail "Pillow required for geometry checks (pip install pillow)"
elif ! SOURCE="$SOURCE" python3 - <<'PY'
import os, sys
from PIL import Image

source = os.environ["SOURCE"]
failures = []

def fail(msg):
    failures.append(msg)

im = Image.open(source).convert("RGBA")
w, h = im.size
alpha = im.split()[3]
px = alpha.load()

if (w, h) != (1024, 1024):
    fail(f"source dimensions {w}x{h}, expected 1024x1024")

for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
    if px[corner] != 0:
        fail(f"corner {corner} alpha={px[corner]}, expected 0")

xs, ys, xe, ye = w, h, -1, -1
for y in range(h):
    for x in range(w):
        if px[x, y] > 0:
            xs = min(xs, x)
            ys = min(ys, y)
            xe = max(xe, x)
            ye = max(ye, y)

expected = (72, 76, 951, 951)
tol = 2
for label, got, want in zip("xyxy", (xs, ys, xe, ye), expected):
    if abs(got - want) > tol:
        fail(f"alpha bbox {label}: got {got}, expected {want}±{tol} (full bbox=({xs},{ys},{xe},{ye}))")

body = xe - xs + 1
ratio = body / w
if not (0.855 <= ratio <= 0.875):
    fail(f"body ratio {ratio:.4f} outside 0.855–0.875 (~0.86)")

if failures:
    for f in failures:
        print(f"  FAIL: {f}", file=sys.stderr)
    sys.exit(1)

print("  PASS: source 1024x1024 RGBA with transparent corners and inset alpha bounds")
PY
then
  FAIL=1
fi

echo "==> iconset member dimensions and alpha corners (committed)"
if ! require_pillow; then
  fail "Pillow required for geometry checks (pip install pillow)"
elif ! ICONSET="$ICONSET" python3 - <<'PY'
import os, sys
from PIL import Image

iconset = os.environ["ICONSET"]
expected = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
failures = []
for name, size in expected.items():
    path = os.path.join(iconset, name)
    if not os.path.isfile(path):
        failures.append(f"missing {path}")
        continue
    im = Image.open(path).convert("RGBA")
    if im.size != (size, size):
        failures.append(f"{name}: size {im.size}, expected {size}x{size}")
    alpha = im.split()[3]
    for corner in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)]:
        if alpha.getpixel(corner) != 0:
            failures.append(f"{name}: corner {corner} not transparent")
            break

if failures:
    for f in failures:
        print(f"  FAIL: {f}", file=sys.stderr)
    sys.exit(1)
print(f"  PASS: all {len(expected)} iconset members sized with transparent corners")
PY
then
  FAIL=1
fi

echo "==> provenance: regenerate iconset + icns from pinned source"
if is_macos_icon_tools; then
  TMP="$(mktemp -d)"
  TMP_ICONSET="$TMP/AppIcon.iconset"
  TMP_ICNS="$TMP/AppIcon.icns"
  cleanup() {
    rm -rf "$TMP"
  }
  trap cleanup EXIT

  mkdir -p "$TMP_ICONSET"

  for entry in "${SIZES[@]}"; do
    size="${entry%%:*}"
    name="${entry##*:}"
    dest="$TMP_ICONSET/$name"
    if [[ "$size" == "1024" ]]; then
      cp "$SOURCE" "$dest"
    else
      sips -z "$size" "$size" "$SOURCE" --out "$dest" >/dev/null
    fi
  done

  member_fail=0
  for entry in "${SIZES[@]}"; do
    name="${entry##*:}"
    committed="$ICONSET/$name"
    generated="$TMP_ICONSET/$name"
    if [[ ! -f "$committed" ]]; then
      fail "missing committed member $committed"
      member_fail=1
      continue
    fi
    committed_sha="$(sha256_file "$committed")"
    generated_sha="$(sha256_file "$generated")"
    if [[ "$committed_sha" == "$generated_sha" ]]; then
      pass "$name matches source regeneration"
    else
      fail "$name hash mismatch (committed $committed_sha, regenerated $generated_sha)"
      member_fail=1
    fi
  done

  if [[ "$member_fail" -eq 0 ]]; then
    pass "all ${#SIZES[@]} iconset members match source regeneration"
  fi

  if [[ ! -f "$ICNS" ]]; then
    fail "missing $ICNS"
  else
    iconutil -c icns "$TMP_ICONSET" -o "$TMP_ICNS"
    fresh_sha="$(sha256_file "$TMP_ICNS")"
    committed_sha="$(sha256_file "$ICNS")"
    if [[ "$fresh_sha" == "$committed_sha" ]]; then
      pass "Resources/AppIcon.icns matches iconset regeneration (sha256 $committed_sha)"
    else
      fail "Resources/AppIcon.icns stale — run scripts/generate-app-icon.sh (committed $committed_sha, expected $fresh_sha)"
    fi
  fi
else
  skip "provenance/icns checks require macOS sips + iconutil (geometry-only on this host)"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ORACLE OK"
  exit 0
fi

echo "ORACLE FAIL" >&2
exit 1
