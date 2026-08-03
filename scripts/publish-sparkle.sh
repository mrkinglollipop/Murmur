#!/usr/bin/env bash
# Publish a Murmur DMG + Sparkle appcast to the public Murmur-updates repo.
# Prefer notarized publishes (NOTARIZE=1). ALLOW_UNNOTARIZED=1 is for local /
# Gatekeeper-prompt publishes only — other Macs need right-click → Open.
# Does NOT extend make-dmg.sh — calls it, then signs/merges/uploads.
#
# Required:
#   NOTARIZE=1   (or ALLOW_UNNOTARIZED=1)
#   SPARKLE_PRIVATE_KEY=/path/to/sparkle_ed25519  (or Keychain via --account)
#   Notarization credentials when NOTARIZE=1 (NOTARY_PROFILE / notarytool store)
#
# Optional:
#   NOTARY_PROFILE=AC_PASSWORD (default; same as make-dmg.sh)
#   SPARKLE_BIN=/path/to/Sparkle/bin  (else search DerivedData SourcePackages)
#   UPDATES_REPO=mrkinglollipop/Murmur-updates
#   SKIP_VERSION_BUMP=1  (use versions already in project.yml)
#
# Flow matches plans/015: bump → xcodegen → DMG (notarized when NOTARIZE=1) →
# sign_update + --verify → prepend-only appcast merge → asserts BEFORE appcast
# --clobber → curl -sfL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${NOTARIZE:-0}" != "1" && "${ALLOW_UNNOTARIZED:-0}" != "1" ]]; then
  echo "error: NOTARIZE=1 is required (or ALLOW_UNNOTARIZED=1 for local/Gatekeeper-prompt publishes)." >&2
  echo "  Notarization needs a configured notarytool profile (default NOTARY_PROFILE=AC_PASSWORD)." >&2
  echo "  Without credentials, do not invent them — configure notarytool store-credentials, then re-run." >&2
  exit 1
fi
if [[ "${ALLOW_UNNOTARIZED:-0}" == "1" && "${NOTARIZE:-0}" != "1" ]]; then
  echo "warning: ALLOW_UNNOTARIZED=1 — DMG will not be notarized; other Macs need right-click → Open." >&2
fi
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  echo "==> Notarization required (NOTARY_PROFILE=${NOTARY_PROFILE:-AC_PASSWORD}). If notarytool fails, fix credentials — do not set ALLOW_UNNOTARIZED for peer installs." >&2
fi

UPDATES_REPO="${UPDATES_REPO:-mrkinglollipop/Murmur-updates}"
FEED_URL="https://github.com/${UPDATES_REPO}/releases/download/appcast/appcast.xml"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
DERIVED="${DERIVED:-$ROOT/build/DerivedData}"
STAGE_APPCAST="$ROOT/build/appcast.xml"
PREV_APPCAST="$ROOT/build/appcast.prev.xml"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-murmur}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"

if [[ -z "${SPARKLE_PRIVATE_KEY}" ]]; then
  echo "error: SPARKLE_PRIVATE_KEY is unset. Set it to your EdDSA private key file, or use Keychain via SPARKLE_ACCOUNT / generate_keys --account." >&2
  exit 1
fi
if [[ ! -f "${SPARKLE_PRIVATE_KEY}" ]]; then
  echo "error: SPARKLE_PRIVATE_KEY does not point to a readable file." >&2
  exit 1
fi

resolve_sparkle_bin() {
  if [[ -n "${SPARKLE_BIN:-}" && -x "${SPARKLE_BIN}/sign_update" ]]; then
    echo "$SPARKLE_BIN"
    return 0
  fi
  local search_paths=("$DERIVED/SourcePackages")
  # Optional machine-local Xcode DerivedData (no hardcoded username path).
  if [[ -d "${HOME}/Library/Developer/Xcode/DerivedData" ]]; then
    search_paths+=("${HOME}/Library/Developer/Xcode/DerivedData")
  fi
  local found
  found="$(find "${search_paths[@]}" \
    -path '*/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$found" ]]; then
    dirname "$found"
    return 0
  fi
  echo "error: Sparkle CLI not found. Set SPARKLE_BIN to …/Sparkle/bin (sign_update + generate_keys)." >&2
  exit 1
}

SPARKLE_BIN="$(resolve_sparkle_bin)"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
echo "==> Sparkle CLI: $SPARKLE_BIN"

# --- helpers ---
plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null
}

yaml_get_voice_version() {
  # Read CFBundle* from the Voice application target only (stops at VoiceTests).
  python3 - <<'PY'
import re, sys
text = open("project.yml").read()
# First "  Voice:" under targets:; stop at sibling "  VoiceTests:" (not schemes).
m = re.search(r'(?ms)^  Voice:\n(.*?)(?=^  VoiceTests:)', text)
if not m:
    sys.exit("could not find Voice: target block in project.yml")
block = m.group(0)
if "type: application" not in block:
    sys.exit("Voice block is not the application target")
m_ver = re.search(r'CFBundleVersion:\s*"([^"]+)"', block)
m_short = re.search(r'CFBundleShortVersionString:\s*"([^"]+)"', block)
if not m_ver or not m_short:
    sys.exit("could not parse versions from Voice target in project.yml")
print(m_short.group(1))
print(m_ver.group(1))
PY
}

# True only when the release is confirmed present. On CLI/auth/network failure:
# exit 1 (fail closed) — never treat a gh outage as "missing → create/upload."
# Usage: gh_release_exists <tag> [context-label]
#   return 0 = present; return 1 = confirmed missing; exit 1 = other error.
gh_release_exists() {
  local tag="$1"
  local ctx="${2:-release check}"
  local err ec
  err="$(mktemp "${TMPDIR:-/tmp}/gh-release.XXXXXX")"
  set +e
  gh release view "$tag" --repo "$UPDATES_REPO" >/dev/null 2>"$err"
  ec=$?
  set -e
  if [[ $ec -eq 0 ]]; then
    rm -f "$err"
    return 0
  fi
  # Confirmed absence only (gh 404 / release not found). Anything else → abort.
  if grep -qiE 'HTTP 404|Not Found|could not find|release not found|no releases? found' "$err"; then
    rm -f "$err"
    return 1
  fi
  echo "error: gh release view ${tag} failed (exit $ec); refusing ${ctx}." >&2
  echo "  (CLI/auth/network failure is not 'missing release' — fix gh and re-run.)" >&2
  sed 's/^/  /' "$err" >&2 || true
  rm -f "$err"
  exit 1
}

appcast_release_exists() {
  gh_release_exists appcast bootstrap
}

# Load versioned tagNames into GH_VERSIONED_TAGS. Call directly (not in a
# pipeline / $()) so exit 1 fail-closes the main shell — bash runs those in
# subshells where exit would not abort publish.
# --limit 100: paginate enough that older v* tags still trip the secondary guard.
GH_VERSIONED_TAGS=""
load_gh_versioned_release_tags() {
  local err ec out
  err="$(mktemp "${TMPDIR:-/tmp}/gh-tags.XXXXXX")"
  set +e
  out="$(gh release list --repo "$UPDATES_REPO" --limit 100 --json tagName \
    --jq '.[].tagName' 2>"$err")"
  ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    echo "error: gh release list failed (exit $ec); refusing bootstrap." >&2
    echo "  (CLI/auth/network failure is not 'no versioned releases' — fix gh and re-run.)" >&2
    sed 's/^/  /' "$err" >&2 || true
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  GH_VERSIONED_TAGS="$out"
}

fetch_prior_appcast() {
  # GitHub release asset URLs often 404 on HEAD; use GET -L like Sparkle does.
  if curl -sfL "$FEED_URL" -o "$PREV_APPCAST" 2>/dev/null; then
    echo "$PREV_APPCAST"
    return 0
  fi
  return 1
}

# Mask XML comments/CDATA with same-length spaces (shared with prepend merge +
# pre-clobber asserts) so commented/CDATA sparkle:version cannot under/overstate.
# item_sparkle_version: per-item prefer element else attribute; strip; whitespace-
# only / empty → None (unparseable). Callers must fail closed on newest=None.
# NOTE: this bash single-quoted blob must not contain unescaped ASCII apostrophes.
mask_xml_noise_py='
def mask_xml_noise(text):
    import re
    masked = re.sub(r"<!--.*?-->", lambda m: " " * len(m.group(0)), text, flags=re.DOTALL)
    masked = re.sub(r"<!\[CDATA\[.*?\]\]>", lambda m: " " * len(m.group(0)), masked, flags=re.DOTALL)
    return masked

def item_sparkle_version(block):
    """Prefer element, else attribute. Strip; whitespace-only is unparseable."""
    import re
    m = re.search(r"<sparkle:version>([^<]+)</sparkle:version>", block)
    if m:
        v = m.group(1).strip()
        return v if v else None
    m = re.search(r"sparkle:version=\"([^\"]+)\"", block)
    if m:
        v = m.group(1).strip()
        return v if v else None
    return None
'

prior_sparkle_version() {
  local file="$1"
  python3 - "$file" <<PY
import re, sys
${mask_xml_noise_py}
text = open(sys.argv[1]).read()
masked = mask_xml_noise(text)
# Newest-first feed: only the first <item>. Prefer element, else attribute
# (same as pre-clobber). Whitespace-only / missing on newest → "" (fail closed);
# never scan older items for a fallback version.
for item_m in re.finditer(r"<item\b[^>]*>.*?</item>", masked, flags=re.DOTALL | re.IGNORECASE):
    v = item_sparkle_version(item_m.group(0))
    print(v if v else "")
    raise SystemExit(0)
print("")
PY
}

# GET -L with limited retries (GitHub asset URLs can 404 briefly after upload).
curl_assert_url() {
  local label="$1" url="$2"
  local attempt=1 max=3
  local code
  while true; do
    code="$(curl -sfL -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      echo "  ${label}: ${code}"
      return 0
    fi
    if (( attempt >= max )); then
      echo "error: ${label} URL assert failed after ${max} attempts (last HTTP ${code:-none}): $url" >&2
      return 1
    fi
    echo "  ${label}: attempt ${attempt}/${max} failed (HTTP ${code:-none}); retrying…" >&2
    sleep 2
    attempt=$((attempt + 1))
  done
}

# Mount a DMG read-only; set DMG_MOUNT + DMG_APP. Detach via cleanup_dmg_mount.
DMG_MOUNT=""
DMG_APP=""
cleanup_dmg_mount() {
  if [[ -n "${DMG_MOUNT:-}" ]]; then
    hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || hdiutil detach "$DMG_MOUNT" -force -quiet 2>/dev/null || true
    rmdir "$DMG_MOUNT" 2>/dev/null || true
    DMG_MOUNT=""
  fi
}
trap cleanup_dmg_mount EXIT

mount_dmg_app() {
  local dmg="$1"
  cleanup_dmg_mount
  mkdir -p "$ROOT/build"
  DMG_MOUNT="$(mktemp -d "$ROOT/build/dmg-mount.XXXXXX")"
  if ! hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$DMG_MOUNT" >/dev/null; then
    echo "error: failed to mount DMG: $dmg" >&2
    rmdir "$DMG_MOUNT" 2>/dev/null || true
    DMG_MOUNT=""
    exit 1
  fi
  if [[ -d "$DMG_MOUNT/Murmur.app" ]]; then
    DMG_APP="$DMG_MOUNT/Murmur.app"
  else
    DMG_APP="$(find "$DMG_MOUNT" -maxdepth 2 -name 'Murmur.app' -type d 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$DMG_APP" || ! -d "$DMG_APP" ]]; then
    echo "error: Murmur.app not found inside DMG: $dmg" >&2
    exit 1
  fi
}

version_greater() {
  python3 - "$1" "$2" <<'PY'
import sys
a, b = sys.argv[1], sys.argv[2]
def parts(s):
    return [int(x) if x.isdigit() else x for x in s.replace("-", ".").split(".")]
pa, pb = parts(a), parts(b)
# pad
n = max(len(pa), len(pb))
pa += [0] * (n - len(pa))
pb += [0] * (n - len(pb))
print("yes" if pa > pb else "no")
PY
}

# Public key that matches the private key used for sign_update (Keychain or file).
expected_public_ed_key() {
  local raw pub
  if [[ -x "$GENERATE_KEYS" ]]; then
    raw="$("$GENERATE_KEYS" -p --account "$SPARKLE_ACCOUNT" 2>/dev/null || true)"
    # generate_keys -p may print prose; take last base64-looking token
    pub="$(echo "$raw" | python3 -c 'import re,sys; t=sys.stdin.read(); ms=re.findall(r"[A-Za-z0-9+/]{40,}={0,2}", t); print(ms[-1] if ms else "")')"
    if [[ -n "$pub" ]]; then
      echo "$pub"
      return 0
    fi
  fi
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" && -f "${SPARKLE_PRIVATE_KEY}" ]]; then
    python3 - "$SPARKLE_PRIVATE_KEY" <<'PY'
import base64, sys
seed = base64.b64decode(open(sys.argv[1]).read().strip())
if len(seed) != 32:
    raise SystemExit(f"expected 32-byte Sparkle seed, got {len(seed)}")
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    pk = Ed25519PrivateKey.from_private_bytes(seed)
    pub = pk.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
except Exception:
    try:
        from nacl.signing import SigningKey
        pub = bytes(SigningKey(seed).verify_key)
    except Exception as e:
        raise SystemExit(
            "cannot derive SUPublicEDKey from private key file "
            f"(install cryptography or PyNaCl): {e}"
        )
print(base64.b64encode(pub).decode())
PY
    return 0
  fi
  return 1
}

# --- 1) Load / bump versions ---
SHORT="$(yaml_get_voice_version | sed -n '1p')"
BUILD="$(yaml_get_voice_version | sed -n '2p')"
if [[ -z "$SHORT" || -z "$BUILD" ]]; then
  echo "error: could not read versions from project.yml" >&2
  exit 1
fi

HAS_PRIOR=0
if fetch_prior_appcast; then
  HAS_PRIOR=1
  PRIOR_BUILD="$(prior_sparkle_version "$PREV_APPCAST")"
  echo "==> Prior appcast sparkle:version=$PRIOR_BUILD"
else
  # GET failed — only bootstrap when the appcast release/tag is truly missing.
  # If the release exists (or a versioned release was already published) but the
  # asset URL failed, abort so we never wipe history with a fresh feed.
  if appcast_release_exists; then
    echo "error: failed to download prior appcast from $FEED_URL," >&2
    echo "  but gh release 'appcast' exists on $UPDATES_REPO." >&2
    echo "  Refusing to bootstrap (would drop feed history). Fix network/URL and re-run." >&2
    exit 1
  fi
  # Also refuse bootstrap if any versioned Murmur release already exists —
  # that implies we are past first publish even if the appcast tag is missing.
  # Match on tagName JSON only (gh list default rows are title-first).
  # load_gh_versioned_release_tags fail-closes on CLI/auth/network errors
  # (must be a direct call — not piped / $() — so exit reaches this shell).
  load_gh_versioned_release_tags
  if printf '%s\n' "$GH_VERSIONED_TAGS" | grep -E '^v[0-9]' >/dev/null 2>&1; then
    echo "error: failed to download prior appcast from $FEED_URL," >&2
    echo "  and versioned releases already exist on $UPDATES_REPO, but no appcast release." >&2
    echo "  Refusing to bootstrap. Create/fix the appcast release asset, then re-run." >&2
    exit 1
  fi
  echo "==> No prior appcast at $FEED_URL and no appcast release (bootstrap)"
  rm -f "$PREV_APPCAST"
  PRIOR_BUILD=""
fi

# Fail closed: prior feed present but sparkle:version missing/unparseable must not
# skip the bump gate (empty PRIOR_BUILD used to fall through as "OK").
if [[ "$HAS_PRIOR" == "1" && -z "$PRIOR_BUILD" ]]; then
  echo "error: prior appcast downloaded but sparkle:version is missing/unparseable." >&2
  echo "  Refusing to publish (bump gate cannot run). Fix the live appcast and re-run." >&2
  exit 1
fi

if [[ "${SKIP_VERSION_BUMP:-0}" != "1" && "$HAS_PRIOR" == "1" ]]; then
  if [[ "$(version_greater "$BUILD" "$PRIOR_BUILD")" != "yes" ]]; then
    echo "error: CFBundleVersion ($BUILD) must be strictly greater than prior sparkle:version ($PRIOR_BUILD)." >&2
    echo "  Bump CFBundleVersion (and usually CFBundleShortVersionString) in project.yml, then re-run." >&2
    exit 1
  fi
fi

echo "==> Publishing Murmur $SHORT (build $BUILD) → $UPDATES_REPO"

echo "==> App icon oracle (test-app-icon-helpers.sh)"
bash "$ROOT/scripts/test-app-icon-helpers.sh"

echo "==> xcodegen generate"
xcodegen generate

# --- 2) Notarized DMG (or signed-only when ALLOW_UNNOTARIZED=1) ---
SKIPPED_MAKE_DMG=0
if [[ "${SKIP_MAKE_DMG:-0}" == "1" && -f "${DMG_PATH:-}" ]]; then
  DMG="$DMG_PATH"
  SKIPPED_MAKE_DMG=1
  echo "==> Reusing DMG: $DMG"
elif [[ "${SKIP_MAKE_DMG:-0}" == "1" ]]; then
  DMG="$ROOT/build/Murmur-$SHORT.dmg"
  if [[ ! -f "$DMG" ]]; then
    echo "error: SKIP_MAKE_DMG=1 but no DMG at $DMG (set DMG_PATH=…)" >&2
    exit 1
  fi
  SKIPPED_MAKE_DMG=1
  echo "==> Reusing DMG: $DMG"
else
  echo "==> make-dmg.sh (NOTARIZE=${NOTARIZE:-0})"
  NOTARIZE="${NOTARIZE:-0}" NOTARY_PROFILE="$NOTARY_PROFILE" bash "$ROOT/scripts/make-dmg.sh"
  DMG="$ROOT/build/Murmur-$SHORT.dmg"
fi
if [[ ! -f "$DMG" ]]; then
  echo "error: expected DMG at $DMG" >&2
  exit 1
fi

# Confirm app plist. SKIP_MAKE_DMG must validate the DMG payload (not stale
# DerivedData) against project.yml — fail closed on mismatch.
if [[ "$SKIPPED_MAKE_DMG" == "1" ]]; then
  echo "==> Mounting reused DMG to verify Murmur.app versions"
  mount_dmg_app "$DMG"
  APP="$DMG_APP"
else
  APP="$DERIVED/Build/Products/Release/Murmur.app"
fi
APP_SHORT="$(plist_get CFBundleShortVersionString "$APP/Contents/Info.plist")"
APP_BUILD="$(plist_get CFBundleVersion "$APP/Contents/Info.plist")"
APP_FEED="$(plist_get SUFeedURL "$APP/Contents/Info.plist")"
APP_PUBKEY="$(plist_get SUPublicEDKey "$APP/Contents/Info.plist")"
if [[ -z "$APP_PUBKEY" ]]; then
  echo "error: Release app missing SUPublicEDKey" >&2
  exit 1
fi
if [[ "$APP_FEED" == *example.com* ]]; then
  echo "error: Release app still has placeholder SUFeedURL: $APP_FEED" >&2
  exit 1
fi
if [[ "$APP_SHORT" != "$SHORT" || "$APP_BUILD" != "$BUILD" ]]; then
  if [[ "$SKIPPED_MAKE_DMG" == "1" ]]; then
    echo "error: DMG Murmur.app version $APP_SHORT/$APP_BUILD != project.yml $SHORT/$BUILD." >&2
    echo "  Refusing SKIP_MAKE_DMG (stale or wrong DMG). Rebuild with make-dmg.sh or fix versions." >&2
  else
    echo "error: built app version $APP_SHORT/$APP_BUILD != project.yml $SHORT/$BUILD (did xcodegen run?)" >&2
  fi
  exit 1
fi
if [[ "$SKIPPED_MAKE_DMG" == "1" ]]; then
  echo "==> DMG payload versions match project.yml ($APP_SHORT / $APP_BUILD)"
  cleanup_dmg_mount
fi

EXPECTED_PUB="$(expected_public_ed_key || true)"
if [[ -z "$EXPECTED_PUB" ]]; then
  echo "error: could not resolve expected public EdDSA key (generate_keys -p --account $SPARKLE_ACCOUNT or derive from SPARKLE_PRIVATE_KEY)." >&2
  exit 1
fi
if [[ "$APP_PUBKEY" != "$EXPECTED_PUB" ]]; then
  echo "error: app SUPublicEDKey does not match murmur signing key public half." >&2
  echo "  app:      $APP_PUBKEY" >&2
  echo "  expected: $EXPECTED_PUB" >&2
  exit 1
fi
echo "==> SUPublicEDKey matches signing key"

# --- 3) sign_update ---
echo "==> sign_update"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" && -f "${SPARKLE_PRIVATE_KEY}" ]]; then
  SIGN_OUT="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY" "$DMG")"
else
  SIGN_OUT="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG")"
fi
echo "  $SIGN_OUT"
# Expected: sparkle:edSignature="…" length="…"
ED_SIG="$(echo "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIGN_OUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [[ -z "$ED_SIG" || -z "$LENGTH" ]]; then
  echo "error: could not parse edSignature/length from sign_update output" >&2
  exit 1
fi

echo "==> sign_update --verify"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" && -f "${SPARKLE_PRIVATE_KEY}" ]]; then
  "$SIGN_UPDATE" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY" "$DMG" "$ED_SIG"
else
  "$SIGN_UPDATE" --verify --account "$SPARKLE_ACCOUNT" "$DMG" "$ED_SIG"
fi
echo "  signature verified against murmur key"

ENCLOSURE_URL="https://github.com/${UPDATES_REPO}/releases/download/v${SHORT}/Murmur-${SHORT}.dmg"
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
NEW_ITEM_FILE="$ROOT/build/appcast-new-item.xml"
RELEASES_JSON="$ROOT/Resources/WhatsNew/releases.json"

if [[ ! -f "$RELEASES_JSON" ]]; then
  echo "error: missing bundled What's New catalog: $RELEASES_JSON" >&2
  echo "  Add a release entry for $SHORT (build $BUILD) before publishing." >&2
  exit 1
fi

DESCRIPTION_XML="$(
  python3 - "$RELEASES_JSON" "$SHORT" "$BUILD" <<'PY'
import html
import json
import sys

path, short, build = sys.argv[1:4]
try:
    releases = json.load(open(path, encoding="utf-8"))
except (OSError, json.JSONDecodeError) as e:
    print(f"error: could not read What's New catalog {path}: {e}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(releases, list):
    print(f"error: {path} must be a JSON array of releases", file=sys.stderr)
    raise SystemExit(1)

match = None
for release in releases:
    if str(release.get("build", "")) == build:
        match = release
        break
if match is None:
    for release in releases:
        if release.get("version") == short:
            match = release
            break

if match is None:
    print(
        f"error: no What's New entry in {path} for build {build} / version {short}",
        file=sys.stderr,
    )
    print(
        "  Prepend a release to Resources/WhatsNew/releases.json before publishing.",
        file=sys.stderr,
    )
    raise SystemExit(1)

items = match.get("items") or []
if not items:
    print(
        f"error: What's New entry for {short} (build {build}) has no items",
        file=sys.stderr,
    )
    raise SystemExit(1)

def cdata_safe(text: str) -> str:
    return text.replace("]]>", "]]]]><![CDATA[>")

lis = "".join(f"<li>{html.escape(str(item), quote=False)}</li>" for item in items)
inner = cdata_safe(f"<ul>{lis}</ul>")
print(f"<description><![CDATA[\n{inner}\n]]></description>")
PY
)" || exit 1

if [[ -z "$DESCRIPTION_XML" ]]; then
  echo "error: empty release-notes description for $SHORT (build $BUILD)" >&2
  exit 1
fi

cat > "$NEW_ITEM_FILE" <<EOF
    <item>
      <title>Murmur ${SHORT}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT}</sparkle:shortVersionString>
      ${DESCRIPTION_XML}
      <enclosure
        url="${ENCLOSURE_URL}"
        sparkle:version="${BUILD}"
        sparkle:shortVersionString="${SHORT}"
        sparkle:edSignature="${ED_SIG}"
        length="${LENGTH}"
        type="application/octet-stream" />
    </item>
EOF

# --- 4) Build staged appcast (prepend-only) ---
mkdir -p "$ROOT/build"
if [[ "$HAS_PRIOR" == "1" && -f "$PREV_APPCAST" ]]; then
  python3 - "$PREV_APPCAST" "$STAGE_APPCAST" "$NEW_ITEM_FILE" <<PY
import re, sys
${mask_xml_noise_py}
prior = open(sys.argv[1]).read()
new_item = open(sys.argv[3]).read().rstrip() + "\n"
if not re.search(r'<channel[^>]*>', prior, re.I):
    raise SystemExit("prior appcast missing <channel>")
# Mask comments/CDATA with same-length spaces so <item> inside them is ignored
# while indices still map into the original prior text.
masked = mask_xml_noise(prior)
im = re.search(r'<item[\s>]', masked, re.I)
if im:
    out = prior[:im.start()] + new_item + prior[im.start():]
else:
    cm = re.search(r'</channel>', masked, re.I)
    if not cm:
        raise SystemExit("prior appcast missing </channel>")
    out = prior[:cm.start()] + new_item + prior[cm.start():]
open(sys.argv[2], "w").write(out)
PY
else
  {
    cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Murmur</title>
    <link>${FEED_URL}</link>
    <description>Murmur Mac updates</description>
    <language>en</language>
EOF
    cat "$NEW_ITEM_FILE"
    cat <<'EOF'
  </channel>
</rss>
EOF
  } > "$STAGE_APPCAST"
fi

# --- 5) Pre-clobber asserts ---
echo "==> Pre-clobber asserts"
python3 - "$STAGE_APPCAST" "$BUILD" "$HAS_PRIOR" <<PY
import re, sys
${mask_xml_noise_py}
path, build, has_prior = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
text = open(path).read()
if "<enclosure" not in text or "sparkle:edSignature" not in text:
    raise SystemExit("staged appcast missing enclosure/edSignature")
# Same comment/CDATA mask + item_sparkle_version as prior_sparkle_version —
# do not let commented versions poison versions[0]/versions[1], and do not
# fall through to an older item when newest is missing/whitespace-only.
masked = mask_xml_noise(text)
# Per <item>: prefer element form, else attribute — strip; whitespace-only
# unparseable. Newest item must parse or fail closed (no older-item fallback).
versions = []
for item_m in re.finditer(r"<item\b[^>]*>.*?</item>", masked, flags=re.DOTALL | re.IGNORECASE):
    v = item_sparkle_version(item_m.group(0))
    if v is None:
        if not versions:
            raise SystemExit(
                "newest item has no parseable sparkle:version "
                "(missing/whitespace-only; refusing older-item fallback)"
            )
        continue
    versions.append(v)
if not versions:
    raise SystemExit("staged appcast has no sparkle:version")
# newest-first: first version must equal this build
first = versions[0]
if first != build:
    raise SystemExit(f"newest sparkle:version {first!r} != this build {build!r}")
if has_prior:
    if len(versions) < 2:
        raise SystemExit(
            "has_prior but staged appcast has no prior sparkle:version "
            "(attribute-only priors must still be collected)"
        )
    prior = versions[1]
    def parts(s):
        out = []
        for x in s.replace("-", ".").split("."):
            out.append(int(x) if x.isdigit() else x)
        return out
    pa, pb = parts(build), parts(prior)
    n = max(len(pa), len(pb))
    pa += [0] * (n - len(pa))
    pb += [0] * (n - len(pb))
    if not (pa > pb):
        raise SystemExit(f"build {build} not strictly greater than prior {prior}")
print("  staged appcast OK (newest=", first, ")")
PY

# --- 6) Upload DMG release ---
TAG="v${SHORT}"
echo "==> GitHub release $TAG on $UPDATES_REPO"
if gh_release_exists "$TAG" "DMG upload"; then
  gh release upload "$TAG" "$DMG" --repo "$UPDATES_REPO" --clobber
else
  gh release create "$TAG" "$DMG" --repo "$UPDATES_REPO" --title "Murmur $SHORT" --notes "Murmur $SHORT (build $BUILD)"
fi

# --- 7) Appcast release (only after asserts) ---
if gh_release_exists appcast "appcast upload"; then
  :
else
  echo "==> Creating appcast release"
  gh release create appcast --repo "$UPDATES_REPO" --title "Appcast" --notes "Stable Sparkle appcast feed (asset overwritten each publish)." --latest=false
fi

echo "==> Uploading appcast.xml (--clobber)"
gh release upload appcast "$STAGE_APPCAST" --repo "$UPDATES_REPO" --clobber

# --- 8) Live URL asserts (GET -L; HEAD often 404s on GitHub XML assets) ---
echo "==> curl -sfL live URLs (up to 3 attempts each)"
curl_assert_url "feed" "$FEED_URL"
curl_assert_url "dmg" "$ENCLOSURE_URL"
echo ""
echo "==> Done"
echo "  Feed: $FEED_URL"
echo "  DMG:  $ENCLOSURE_URL"
echo "  App:  $SHORT ($BUILD) pubkey present"
