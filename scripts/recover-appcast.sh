#!/usr/bin/env bash
# Recovery path for: "the live Sparkle feed is MISSING but release 'appcast'
# still exists on the updates repo" — e.g. `gh release upload appcast … --clobber`
# removed the old appcast.xml and then failed. publish-sparkle.sh refuses to
# bootstrap in that state (it would drop the feed history), so restore instead.
#
# Restores the newest build/appcast.backup.<UTC>.xml that publish-sparkle.sh
# wrote before it clobbered the feed (or APPCAST_BACKUP=/path/to/file.xml),
# uploads it as appcast.xml, then confirms the live bytes equal the backup.
#
# Safety:
#   - Refuses when the live feed still downloads (a working feed is never
#     overwritten with an older backup) unless FORCE_RECOVER=1.
#   - Refuses when release 'appcast' is missing or gh cannot tell.
#   - DRY_RUN=1 prints the plan (backup, validation, feed state) and uploads nothing.
#
# Optional: UPDATES_REPO=mrkinglollipop/Murmur-updates
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"

UPDATES_REPO="${UPDATES_REPO:-mrkinglollipop/Murmur-updates}"
FEED_URL="https://github.com/${UPDATES_REPO}/releases/download/appcast/appcast.xml"

BACKUP="${APPCAST_BACKUP:-}"
if [[ -z "$BACKUP" ]]; then
  BACKUP="$(newest_appcast_backup "$ROOT/build")" || {
    echo "error: no build/appcast.backup.*.xml found and APPCAST_BACKUP is unset." >&2
    echo "  Nothing to restore from. Rebuild the feed by hand from the v* release notes," >&2
    echo "  or copy a known-good appcast.xml and re-run with APPCAST_BACKUP=<file>." >&2
    exit 1
  }
fi
if [[ ! -s "$BACKUP" ]]; then
  echo "error: backup is missing or empty: $BACKUP" >&2
  exit 1
fi
echo "==> Backup: $BACKUP"

# A backup that is not a plausible appcast must never become the live feed.
python3 - "$BACKUP" <<'PY' || { echo "error: backup is not a usable appcast: $BACKUP" >&2; exit 1; }
import re, sys
text = open(sys.argv[1]).read()
if not re.search(r"<channel[^>]*>", text, re.I) or "</channel>" not in text:
    raise SystemExit("missing <channel>")
if not re.search(r"<item\b", text, re.I):
    raise SystemExit("no <item>")
if "<enclosure" not in text or "sparkle:edSignature" not in text:
    raise SystemExit("no enclosure/edSignature")
PY
echo "  backup looks like a complete appcast"

# The release must exist (confirmed), else this is not the recover case.
ERR="$(mktemp "${TMPDIR:-/tmp}/recover-appcast.XXXXXX")"
trap 'rm -f "$ERR"' EXIT
if ! gh release view appcast --repo "$UPDATES_REPO" >/dev/null 2>"$ERR"; then
  echo "error: release 'appcast' on $UPDATES_REPO not confirmed present:" >&2
  sed 's/^/  /' "$ERR" >&2 || true
  echo "  If it is truly gone, recreate it (gh release create appcast --latest=false) and re-run." >&2
  exit 1
fi

# Is the feed actually missing? Never replace a live feed with an older copy.
mkdir -p "$ROOT/build"
LIVE="$ROOT/build/appcast.live-check.xml"
rm -f "$LIVE"
CODE="$(curl -sL -H 'Cache-Control: no-cache' -o "$LIVE" -w '%{http_code}' \
  "$(cache_busted_url "$FEED_URL" "$(date +%s)")" 2>/dev/null || true)"
case "$CODE" in
  200)
    if [[ "${FORCE_RECOVER:-0}" != "1" ]]; then
      echo "error: the live feed is present ($FEED_URL); nothing to recover." >&2
      echo "  Downloaded copy: $LIVE. Set FORCE_RECOVER=1 to overwrite it with the backup anyway." >&2
      exit 1
    fi
    echo "warning: FORCE_RECOVER=1 — overwriting a live feed with the backup." >&2
    ;;
  404)
    echo "==> Live feed is missing (HTTP 404, as expected)"
    ;;
  *)
    # A network blip must not read as "feed missing" and clobber a live feed.
    echo "error: could not tell whether the feed is missing (HTTP ${CODE:-none}); refusing to upload." >&2
    exit 1
    ;;
esac

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "==> DRY_RUN=1: would upload $BACKUP as appcast.xml to release 'appcast' on $UPDATES_REPO."
  exit 0
fi

# gh names the asset after the file, so stage the backup as appcast.xml.
STAGE="$(mktemp -d "$ROOT/build/appcast-recover.XXXXXX")"
trap 'rm -f "$ERR"; rm -rf "$STAGE"' EXIT
cp "$BACKUP" "$STAGE/appcast.xml"
echo "==> Uploading restored appcast.xml (--clobber)"
gh release upload appcast "$STAGE/appcast.xml" --repo "$UPDATES_REPO" --clobber

echo "==> Confirming the live feed equals the backup"
ok=0
for attempt in 1 2 3 4; do
  rm -f "$LIVE"
  if curl_fresh "live feed" "$FEED_URL" "$LIVE" && cmp -s "$LIVE" "$BACKUP"; then
    ok=1
    break
  fi
  echo "  live feed not yet equal to backup (attempt ${attempt}/4); retrying…" >&2
  sleep 3
done
if [[ "$ok" != "1" ]]; then
  echo "error: uploaded, but the live feed does not (yet) match the backup: $FEED_URL" >&2
  exit 1
fi
echo "==> Recovered: $FEED_URL now serves $BACKUP"
