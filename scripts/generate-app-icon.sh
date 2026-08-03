#!/usr/bin/env bash
# Regenerate AppIcon.iconset PNGs and Resources/AppIcon.icns from AppIcon.source.png.
# Requires macOS sips + iconutil. Builds in a temp dir and atomically replaces outputs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SOURCE="$ROOT/AppIcon.source.png"
ICONSET="$ROOT/AppIcon.iconset"
ICNS="$ROOT/Resources/AppIcon.icns"

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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: generate-app-icon.sh requires macOS (sips + iconutil)" >&2
  exit 1
fi

for tool in sips iconutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: missing required tool: $tool" >&2
    exit 1
  fi
done

if [[ ! -f "$SOURCE" ]]; then
  echo "error: missing source artwork: $SOURCE" >&2
  exit 1
fi

width="$(sips -g pixelWidth "$SOURCE" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
height="$(sips -g pixelHeight "$SOURCE" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
has_alpha="$(sips -g hasAlpha "$SOURCE" 2>/dev/null | awk '/hasAlpha:/ {print $2}')"

if [[ -z "$width" || -z "$height" ]]; then
  echo "error: could not read dimensions for $SOURCE" >&2
  exit 1
fi

if [[ "$width" != "$height" ]]; then
  echo "error: source must be square (got ${width}x${height})" >&2
  exit 1
fi

if [[ "$width" != "1024" ]]; then
  echo "error: source must be 1024x1024 (got ${width}x${height})" >&2
  exit 1
fi

if [[ "$has_alpha" != "yes" ]]; then
  echo "error: source must have an alpha channel (hasAlpha=$has_alpha)" >&2
  exit 1
fi

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

iconutil -c icns "$TMP_ICONSET" -o "$TMP_ICNS"

mkdir -p "$ICONSET" "$(dirname "$ICNS")"
rm -f "$ICONSET"/*.png
cp "$TMP_ICONSET"/*.png "$ICONSET"/
cp "$TMP_ICNS" "$ICNS"

echo "Generated:"
echo "  $ICONSET/*.png"
echo "  $ICNS"
