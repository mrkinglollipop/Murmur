#!/usr/bin/env bash
# Lightweight offline oracle for publish-sparkle.sh helpers.
# Covers: bash -n, no hardcoded user DerivedData path, XML mask, pre-clobber
# version collection (element + attribute, no double-count, attribute-only prior),
# prior_sparkle_version bump-gate (per-item prefer-element-else-attribute),
# whitespace-only / versionless-newest fail-closed (no older-item fall-through).
# No network / gh required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/publish-sparkle.sh"
FAIL=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=1; }

echo "==> bash -n publish-sparkle.sh"
if bash -n "$SCRIPT"; then
  pass "bash -n"
else
  fail "bash -n"
fi

echo "==> no hardcoded username DerivedData path"
if grep -nE '/Users/[^/]+/Library/Developer/Xcode/DerivedData' "$SCRIPT"; then
  fail "hardcoded DerivedData path still present"
else
  pass "SPARKLE_BIN / \$HOME DerivedData only"
fi

echo "==> gh_release_exists used for upload-phase checks"
if grep -q 'gh_release_exists "\$TAG"' "$SCRIPT" \
  && grep -q 'gh_release_exists appcast "appcast upload"' "$SCRIPT"; then
  pass "upload-phase fail-closed helpers"
else
  fail "upload phase still uses bare gh release view"
fi

echo "==> local unnotarized path never reaches public release state"
if grep -q 'git status --porcelain' "$SCRIPT" \
  && grep -q 'if \[\[ "\${ALLOW_UNNOTARIZED:-0}" == "1" \]\]; then' "$SCRIPT" \
  && grep -q 'is_stable_dmg_path "\$DMG" "\$ROOT/build/Murmur.dmg"' "$SCRIPT" \
  && grep -q 'is_pro_app_bundle "\$APP"' "$SCRIPT" \
  && grep -q 'Local-only artifact' "$SCRIPT" \
  && grep -q 'Built from commit' "$SCRIPT"; then
  pass "dirty tree, stable alias, Pro bundle, and commit-SHA gates are present"
else
  fail "publish-sparkle.sh lost a release safety gate"
fi
LOCAL_EXIT_LINE="$(grep -n 'Local-only artifact' "$SCRIPT" | head -1 | cut -d: -f1 || true)"
PUBLIC_FLOW_LINE="$(grep -n '^HAS_PRIOR=0' "$SCRIPT" | head -1 | cut -d: -f1 || true)"
if [[ -n "$LOCAL_EXIT_LINE" && -n "$PUBLIC_FLOW_LINE" ]] && (( LOCAL_EXIT_LINE < PUBLIC_FLOW_LINE )); then
  pass "local-only exit precedes the public publish flow"
else
  fail "could not prove local-only exit precedes the public publish flow"
fi

echo "==> What's New release notes wired into appcast item"
if grep -q 'Resources/WhatsNew/releases\.json' "$SCRIPT" \
  && grep -q 'WhatsNew' "$SCRIPT" \
  && grep -q '<description><!\[CDATA\[' "$SCRIPT" \
  && ! grep -q 'release_sha' "$SCRIPT" \
  && grep -q 'gh release edit "\$TAG" --repo "\$UPDATES_REPO" --notes "\$WHATSNEW_NOTES"' "$SCRIPT"; then
  pass "releases.json and CDATA description in publish-sparkle.sh; no commit SHA in public notes"
else
  fail "publish-sparkle.sh must update every release's notes from Resources/WhatsNew/releases.json and keep the commit SHA out of them"
fi

echo "==> appcast description builder (python)"
ROOT="$ROOT" python3 - <<'PY'
import html
import json
import os
import sys
import tempfile

ROOT = os.environ["ROOT"]
RELEASES_JSON = os.path.join(ROOT, "Resources/WhatsNew/releases.json")


def build_description_xml(path: str, short: str, build: str) -> str:
    releases = json.load(open(path, encoding="utf-8"))
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
        raise SystemExit(f"no match for {short}/{build}")
    items = match.get("items") or []
    if not items:
        raise SystemExit("empty items")

    def cdata_safe(text: str) -> str:
        return text.replace("]]>", "]]]]><![CDATA[>")

    lis = "".join(f"<li>{html.escape(str(item), quote=False)}</li>" for item in items)
    inner = cdata_safe(f"<ul>{lis}</ul>")
    return f"<description><![CDATA[\n{inner}\n]]></description>"


errors = []

if not os.path.isfile(RELEASES_JSON):
    errors.append(f"missing catalog: {RELEASES_JSON}")
else:
  try:
    xml = build_description_xml(RELEASES_JSON, "0.1.20", "21")
    if "<description><![CDATA[" not in xml or "]]></description>" not in xml:
        errors.append("description wrapper missing")
    if "<ul>" not in xml or "<li>" not in xml:
        errors.append("expected ul/li HTML in description")
    if "Sparkle update dialog" not in xml:
        errors.append("expected 0.1.20 bullet text in description")
    if "]]>" in xml.split("<![CDATA[", 1)[1].rsplit("]]>", 1)[0]:
        errors.append("raw ]]> must not appear inside CDATA payload")
  except SystemExit as e:
    errors.append(f"build_description_xml catalog: {e}")

with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
    json.dump(
        [
            {
                "version": "9.9.9",
                "build": "42",
                "title": "T",
                "items": ["A & B", "C < D", "E ]]> F"],
            }
        ],
        tf,
    )
    tf.flush()
    try:
        xml = build_description_xml(tf.name, "9.9.9", "42")
        if "&amp;" not in xml or "&lt;" not in xml:
            errors.append("HTML escape expected for & and <")
        if "]]>" in xml.split("<![CDATA[", 1)[1].rsplit("]]>", 1)[0]:
            errors.append("CDATA splitter failed for ]]> in item text")
    except SystemExit as e:
        errors.append(f"build_description_xml fixture: {e}")
    finally:
        os.unlink(tf.name)

if errors:
    for e in errors:
        print("  FAIL:", e, file=sys.stderr)
    sys.exit(1)
print("  PASS: appcast description builder (match, escape, CDATA-safe)")
PY

echo "==> icon oracle before xcodegen / make-dmg / upload"
ICON_ORACLE_PATTERN='^[[:space:]]*bash "\$ROOT/scripts/test-app-icon-helpers\.sh"[[:space:]]*$'
ICON_ORACLE_MATCHES="$(grep -En "$ICON_ORACLE_PATTERN" "$SCRIPT" || true)"
if [[ -n "$ICON_ORACLE_MATCHES" ]]; then
  ICON_ORACLE_COUNT="$(printf '%s\n' "$ICON_ORACLE_MATCHES" | wc -l | tr -d ' ')"
  ICON_ORACLE_LINE="$(printf '%s\n' "$ICON_ORACLE_MATCHES" | head -1 | cut -d: -f1)"
else
  ICON_ORACLE_COUNT=0
  ICON_ORACLE_LINE=""
fi
XCODEGEN_LINE="$(grep -n '^xcodegen generate' "$SCRIPT" | head -1 | cut -d: -f1 || true)"
MAKE_DMG_LINE="$(grep -n 'bash "\$ROOT/scripts/make-dmg\.sh"' "$SCRIPT" | head -1 | cut -d: -f1 || true)"
DMG_UPLOAD_LINE="$(grep -n 'gh release upload "\$TAG"' "$SCRIPT" | head -1 | cut -d: -f1 || true)"
if [[ "$ICON_ORACLE_COUNT" -ne 1 ]]; then
  fail "publish-sparkle.sh must invoke test-app-icon-helpers.sh exactly once (found $ICON_ORACLE_COUNT unconditional bash lines)"
elif [[ -z "$XCODEGEN_LINE" || -z "$MAKE_DMG_LINE" || -z "$DMG_UPLOAD_LINE" ]]; then
  fail "could not locate xcodegen / make-dmg / DMG upload anchors in publish-sparkle.sh"
elif (( ICON_ORACLE_LINE >= XCODEGEN_LINE )); then
  fail "icon oracle must run before xcodegen generate (oracle=$ICON_ORACLE_LINE, xcodegen=$XCODEGEN_LINE)"
elif (( ICON_ORACLE_LINE >= MAKE_DMG_LINE )); then
  fail "icon oracle must run before make-dmg.sh (oracle=$ICON_ORACLE_LINE, make-dmg=$MAKE_DMG_LINE)"
elif (( ICON_ORACLE_LINE >= DMG_UPLOAD_LINE )); then
  fail "icon oracle must run before DMG upload (oracle=$ICON_ORACLE_LINE, upload=$DMG_UPLOAD_LINE)"
else
  pass "exactly one unconditional test-app-icon-helpers.sh before xcodegen ($XCODEGEN_LINE), make-dmg ($MAKE_DMG_LINE), upload ($DMG_UPLOAD_LINE)"
fi

echo "==> mask + pre-clobber version collection (python)"
SCRIPT="$SCRIPT" python3 - <<'PY'
import re, sys, os

SCRIPT = os.environ["SCRIPT"]

def mask_xml_noise(text):
    masked = re.sub(r"<!--.*?-->", lambda m: " " * len(m.group(0)), text, flags=re.DOTALL)
    masked = re.sub(r"<!\[CDATA\[.*?\]\]>", lambda m: " " * len(m.group(0)), masked, flags=re.DOTALL)
    return masked

def collect_versions(text):
    """Mirror publish-sparkle pre-clobber collect (raise on newest unparseable)."""
    masked = mask_xml_noise(text)
    versions = []
    for item_m in re.finditer(r"<item\b[^>]*>.*?</item>", masked, flags=re.DOTALL | re.IGNORECASE):
        v = item_sparkle_version(item_m.group(0))
        if v is None:
            if not versions:
                raise ValueError(
                    "newest item has no parseable sparkle:version"
                )
            continue
        versions.append(v)
    return versions

def prior_sparkle_version(text):
    """Bump-gate parse: newest item only; "" if missing/whitespace-only."""
    masked = mask_xml_noise(text)
    for item_m in re.finditer(r"<item\b[^>]*>.*?</item>", masked, flags=re.DOTALL | re.IGNORECASE):
        v = item_sparkle_version(item_m.group(0))
        return v if v else ""
    return ""

def prior_sparkle_version_scan_all(text):
    """Old buggy bump-gate: first parseable version across any item (fall-through)."""
    masked = mask_xml_noise(text)
    for item_m in re.finditer(r"<item\b[^>]*>.*?</item>", masked, flags=re.DOTALL | re.IGNORECASE):
        v = item_sparkle_version(item_m.group(0))
        if v:
            return v
    return ""

def prior_sparkle_version_global_element_first(text):
    """Old buggy bump-gate parse (document-global element, then attribute)."""
    masked = mask_xml_noise(text)
    m = re.search(r"<sparkle:version>([^<]+)</sparkle:version>", masked)
    if not m:
        m = re.search(r'sparkle:version="([^"]+)"', masked)
    if not m:
        return ""
    v = m.group(1).strip()
    return v if v else ""

def item_sparkle_version(block):
    """Prefer element, else attribute. Strip; whitespace-only is unparseable."""
    m = re.search(r"<sparkle:version>([^<]+)</sparkle:version>", block)
    if m:
        v = m.group(1).strip()
        return v if v else None
    m = re.search(r'sparkle:version="([^"]+)"', block)
    if m:
        v = m.group(1).strip()
        return v if v else None
    return None

def assert_strict_greater(build, prior):
    def parts(s):
        out = []
        for x in s.replace("-", ".").split("."):
            out.append(int(x) if x.isdigit() else x)
        return out
    pa, pb = parts(build), parts(prior)
    n = max(len(pa), len(pb))
    pa += [0] * (n - len(pa))
    pb += [0] * (n - len(pb))
    return pa > pb

errors = []

# 1) Mask: commented version must not appear
sample = """<?xml version="1.0"?>
<rss><channel>
  <!-- <item><sparkle:version>99</sparkle:version></item> -->
  <item>
    <sparkle:version>3</sparkle:version>
    <enclosure sparkle:version="3" sparkle:edSignature="x" />
  </item>
</channel></rss>"""
masked = mask_xml_noise(sample)
if "99" in masked.replace(" ", ""):
    # spaces replace comment; digits may remain as spaces-length — check versions only
    pass
vs = collect_versions(sample)
if vs != ["3"]:
    errors.append(f"mask/dedupe expected ['3'], got {vs!r}")

# 2) Dual form on one item → single version (no double-count)
dual = """<rss><channel>
  <item>
    <sparkle:version>5</sparkle:version>
    <enclosure url="u" sparkle:version="5" sparkle:edSignature="sig" />
  </item>
</channel></rss>"""
vs = collect_versions(dual)
if vs != ["5"]:
    errors.append(f"dual-form double-count: expected ['5'], got {vs!r}")

# 3) Attribute-only prior + element newest — has_prior must see both
attr_prior = """<rss><channel>
  <item>
    <title>new</title>
    <sparkle:version>4</sparkle:version>
    <enclosure sparkle:version="4" sparkle:edSignature="a" />
  </item>
  <item>
    <title>old</title>
    <enclosure url="u" sparkle:version="2" sparkle:edSignature="b" />
  </item>
</channel></rss>"""
vs = collect_versions(attr_prior)
if vs != ["4", "2"]:
    errors.append(f"attribute-only prior: expected ['4','2'], got {vs!r}")
if not assert_strict_greater("4", "2"):
    errors.append("strict-greater 4>2 failed")
# Simulate old bug: element-only findall would skip prior
old = re.findall(r"<sparkle:version>([^<]+)</sparkle:version>", mask_xml_noise(attr_prior))
if old == ["4"] and len(old) < 2:
    pass  # documents why has_prior must not skip
else:
    # If both forms somehow appear as elements, still ok — regression is about attr-only
    pass
if len(vs) < 2:
    errors.append("has_prior path would skip strict-greater (need >=2 versions)")

# 4) CDATA noise inside newest item must not override real version
#    (leading CDATA-only <item> is versionless-newest — covered in fixture 9)
cdata = """<rss><channel>
  <item>
    <description><![CDATA[<sparkle:version>88</sparkle:version>]]></description>
    <sparkle:version>1</sparkle:version>
    <enclosure sparkle:version="1" sparkle:edSignature="z" />
  </item>
</channel></rss>"""
vs = collect_versions(cdata)
if vs != ["1"]:
    errors.append(f"CDATA mask: expected ['1'], got {vs!r}")
if prior_sparkle_version(cdata) != "1":
    errors.append("CDATA mask: prior_sparkle_version should still be 1")

# 5) prior_sparkle_version / bump-gate: attribute-only newest + element older
#    must return 5 (newest item), not 3 (first document-global element).
attr_newest = """<rss><channel>
  <item>
    <title>newest</title>
    <enclosure url="u" sparkle:version="5" sparkle:edSignature="a" />
  </item>
  <item>
    <title>older</title>
    <sparkle:version>3</sparkle:version>
    <enclosure sparkle:version="3" sparkle:edSignature="b" />
  </item>
</channel></rss>"""
got = prior_sparkle_version(attr_newest)
if got != "5":
    errors.append(f"prior_sparkle_version attr-newest: expected '5', got {got!r}")
buggy = prior_sparkle_version_global_element_first(attr_newest)
if buggy != "3":
    errors.append(
        f"regression fixture broken: global element-first expected '3', got {buggy!r}"
    )
if got == buggy:
    errors.append(
        "prior_sparkle_version still matches global element-first "
        f"(both returned {got!r}; want 5 not 3)"
    )
# collect_versions newest must agree with bump-gate prior
vs = collect_versions(attr_newest)
if vs != ["5", "3"]:
    errors.append(f"attr-newest collect: expected ['5','3'], got {vs!r}")
if vs and vs[0] != got:
    errors.append(f"bump-gate prior {got!r} != collect newest {vs[0]!r}")

# 6) prior_sparkle_version: element newest (normal dual-form) still works
got = prior_sparkle_version(attr_prior)
if got != "4":
    errors.append(f"prior_sparkle_version element-newest: expected '4', got {got!r}")

# 8) Whitespace-only sparkle:version on newest → unparseable (""), not TypeError fodder
ws_newest = """<rss><channel>
  <item>
    <title>newest</title>
    <sparkle:version>   </sparkle:version>
    <enclosure url="u" sparkle:edSignature="a" />
  </item>
  <item>
    <title>older</title>
    <sparkle:version>3</sparkle:version>
    <enclosure sparkle:version="3" sparkle:edSignature="b" />
  </item>
</channel></rss>"""
got = prior_sparkle_version(ws_newest)
if got != "":
    errors.append(
        f"whitespace-only newest prior_sparkle_version: expected '', got {got!r}"
    )
# Old fall-through would return older item's 3
fall = prior_sparkle_version_scan_all(ws_newest)
if fall != "3":
    errors.append(
        f"regression fixture broken: scan-all expected '3', got {fall!r}"
    )
if got == fall:
    errors.append(
        "prior_sparkle_version still falls through past whitespace-only newest "
        f"(both returned {got!r})"
    )
try:
    collect_versions(ws_newest)
    errors.append(
        "collect_versions whitespace-only newest: expected raise, got success"
    )
except ValueError as e:
    if "newest item" not in str(e):
        errors.append(f"collect_versions ws-newest wrong error: {e!r}")
# Attribute-only whitespace
ws_attr = """<rss><channel>
  <item>
    <enclosure url="u" sparkle:version="  \t  " sparkle:edSignature="a" />
  </item>
</channel></rss>"""
got = prior_sparkle_version(ws_attr)
if got != "":
    errors.append(
        f"whitespace-only attribute prior_sparkle_version: expected '', got {got!r}"
    )
try:
    collect_versions(ws_attr)
    errors.append(
        "collect_versions whitespace-only attr: expected raise, got success"
    )
except ValueError as e:
    if "newest item" not in str(e):
        errors.append(f"collect_versions ws-attr wrong error: {e!r}")

# 9) Versionless newest <item> → fail closed; do not use older item's version
no_ver_newest = """<rss><channel>
  <item>
    <title>newest</title>
    <enclosure url="u" sparkle:edSignature="a" />
  </item>
  <item>
    <title>older</title>
    <sparkle:version>3</sparkle:version>
    <enclosure sparkle:version="3" sparkle:edSignature="b" />
  </item>
</channel></rss>"""
got = prior_sparkle_version(no_ver_newest)
if got != "":
    errors.append(
        f"versionless newest prior_sparkle_version: expected '', got {got!r}"
    )
fall = prior_sparkle_version_scan_all(no_ver_newest)
if fall != "3":
    errors.append(
        f"regression fixture broken: versionless scan-all expected '3', got {fall!r}"
    )
if got == fall:
    errors.append(
        "prior_sparkle_version still falls through past versionless newest "
        f"(both returned {got!r}; want '' not 3)"
    )
try:
    collect_versions(no_ver_newest)
    errors.append(
        "collect_versions versionless newest: expected raise, got success"
    )
except ValueError as e:
    if "newest item" not in str(e):
        errors.append(f"collect_versions versionless wrong error: {e!r}")

# 7) Script must use per-item collection (has_prior without len>1 skip)
#    and prior_sparkle_version must iterate items (not global element-first).
#    Also: fail-closed helpers (item_sparkle_version + no older-item fall-through).
script = open(SCRIPT).read()
if "if has_prior and len(versions) > 1:" in script:
    errors.append("pre-clobber still skips strict-greater when len(versions)==1")
if "<item\\b" not in script:
    errors.append("pre-clobber missing per-item version collection")
if "if has_prior:" not in script:
    errors.append("pre-clobber missing unconditional has_prior strict-greater")
if "def item_sparkle_version" not in script:
    errors.append("publish-sparkle.sh missing shared item_sparkle_version helper")
if "refusing older-item fallback" not in script:
    errors.append("pre-clobber missing fail-closed newest-unparseable message")
# prior_sparkle_version body: must finditer items; must not use global
# element-then-attribute on the whole masked document.
fn_m = re.search(
    r"prior_sparkle_version\(\) \{.*?^}",
    script,
    flags=re.MULTILINE | re.DOTALL,
)
if not fn_m:
    errors.append("could not locate prior_sparkle_version() in publish-sparkle.sh")
else:
    body = fn_m.group(0)
    if "finditer" not in body or r"<item\b" not in body:
        errors.append(
            "prior_sparkle_version missing per-item finditer "
            "(still document-global?)"
        )
    if "item_sparkle_version" not in body:
        errors.append("prior_sparkle_version does not call item_sparkle_version")
    # Must not scan all items for first non-empty (fall-through bug)
    if re.search(
        r"if v:\s*\n\s*print\(v\)\s*\n\s*raise SystemExit",
        body,
    ):
        errors.append(
            "prior_sparkle_version still falls through to older items "
            "(if v: print — skips versionless newest)"
        )
    # Old bug: search element on full masked, then attribute on full masked
    if re.search(
        r"re\.search\(r'<sparkle:version>.*?</sparkle:version>',\s*masked\)\s*\n"
        r"if not m:\s*\n\s*m = re\.search\(r'sparkle:version=",
        body,
    ):
        errors.append(
            "prior_sparkle_version still uses document-global element-then-attribute"
        )

if errors:
    for e in errors:
        print("  FAIL:", e, file=sys.stderr)
    sys.exit(1)
print("  PASS: mask + attribute-only prior + prior_sparkle_version bump-gate")
print("  PASS: whitespace-only + versionless-newest fail-closed")
PY

echo "==> dictation product oracle reminder (VoiceTests ≠ hold)"
if grep -q 'oracle-dictation-start.sh' "$SCRIPT"; then
  pass "publish-sparkle names dictation start oracle"
else
  fail "publish-sparkle.sh must mention scripts/oracle-dictation-start.sh"
fi

echo "==> prior-appcast fetch survives a fresh checkout (build/ missing)"
if grep -q 'mkdir -p "$(dirname "$PREV_APPCAST")"' "$SCRIPT"; then
  pass "mkdir -p before prior-appcast curl"
else
  fail "fetch_prior_appcast curls into build/ before it exists (curl 56 read as network failure)"
fi

echo "==> prior-appcast fetch failure surfaces curl exit code"
if grep -q 'FETCH_PRIOR_CURL_STATUS' "$SCRIPT" \
  && grep -q 'curl exit \$FETCH_PRIOR_CURL_STATUS' "$SCRIPT"; then
  pass "curl exit code in the failed-download error"
else
  fail "failed-download error hides curl's exit code"
fi

LIB="$ROOT/scripts/release-lib.sh"
RECOVER="$ROOT/scripts/recover-appcast.sh"
# shellcheck source=release-lib.sh
source "$LIB"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/publish-sparkle-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> bash -n release-lib.sh / recover-appcast.sh"
if bash -n "$LIB" && bash -n "$RECOVER"; then pass "bash -n lib + recover"; else fail "bash -n lib/recover"; fi

echo "==> Sparkle key check: file key is the source of truth (item: Keychain/file split)"
# RFC 8032 test vector 1: seed -> public key. Proves the derivation, not just the compare.
SEED_B64="$(python3 -c 'import base64;print(base64.b64encode(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode())')"
PUB_B64="$(python3 -c 'import base64;print(base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode())')"
OTHER_PUB="$(python3 -c 'import base64;print(base64.b64encode(bytes(range(32))).decode())')"
printf '%s\n' "$SEED_B64" > "$TMP/seed"
if got="$(sparkle_public_key_from_seed_file "$TMP/seed" 2>"$TMP/derive.err")"; then
  if [[ "$got" == "$PUB_B64" ]]; then pass "seed file -> RFC 8032 public key"; else fail "derived [$got] != [$PUB_B64]"; fi
elif grep -q 'install cryptography or PyNaCl' "$TMP/derive.err"; then
  pass "SKIP derivation (no cryptography/PyNaCl here); compare logic still tested below"
else
  fail "seed derivation failed: $(cat "$TMP/derive.err")"
fi
printf 'AAAA\n' > "$TMP/short"
if sparkle_public_key_from_seed_file "$TMP/short" >/dev/null 2>&1; then fail "short seed accepted"; else pass "wrong-length seed rejected"; fi

if check_sparkle_keys "$PUB_B64" "$PUB_B64" "" 2>/dev/null; then pass "app == file, no keychain key"; else fail "app==file, no keychain rejected"; fi
if check_sparkle_keys "$PUB_B64" "$PUB_B64" "$PUB_B64" 2>/dev/null; then pass "app == file == keychain"; else fail "all-equal rejected"; fi
if check_sparkle_keys "$OTHER_PUB" "$PUB_B64" "$PUB_B64" 2>/dev/null; then fail "app != file accepted"; else pass "app != file rejected"; fi
# The historical bug: keychain agrees with the app, the signing file does not.
if check_sparkle_keys "$OTHER_PUB" "$PUB_B64" "$OTHER_PUB" 2>/dev/null; then fail "keychain==app but file differs accepted (old bug)"; else pass "keychain==app but signing file differs rejected"; fi
# Signing file agrees with the app but a readable Keychain key differs.
if check_sparkle_keys "$PUB_B64" "$PUB_B64" "$OTHER_PUB" 2>/dev/null; then fail "keychain mismatch accepted"; else pass "readable keychain mismatch rejected"; fi
if check_sparkle_keys "$PUB_B64" "" "" 2>/dev/null; then fail "empty file key accepted"; else pass "underivable file key rejected"; fi
if check_sparkle_keys "" "$PUB_B64" "" 2>/dev/null; then fail "empty app key accepted"; else pass "missing app key rejected"; fi

echo "==> key gate wired into publish-sparkle.sh"
if grep -q 'expected_public_ed_key' "$SCRIPT"; then
  fail "expected_public_ed_key (Keychain-preferring) still present"
elif grep -q 'sparkle_public_key_from_seed_file "\$SPARKLE_PRIVATE_KEY"' "$SCRIPT" \
  && grep -q 'check_sparkle_keys "\$APP_PUBKEY" "\$FILE_PUB" "\$KEYCHAIN_PUB"' "$SCRIPT"; then
  pass "app key checked against the signing file (+ Keychain when readable)"
else
  fail "publish-sparkle.sh does not check the signing file's public key"
fi

echo "==> newest appcast backup selection"
mkdir -p "$TMP/bk"
if newest_appcast_backup "$TMP/bk" >/dev/null 2>&1; then fail "empty dir returned a backup"; else pass "no backups -> non-zero"; fi
if newest_appcast_backup "$TMP/nope" >/dev/null 2>&1; then fail "missing dir returned a backup"; else pass "missing dir -> non-zero"; fi
for n in appcast.backup.20260101T000000Z.xml appcast.backup.20260929T101500Z.xml \
         appcast.backup.20260315T235959Z.xml appcast.prev.xml appcast.xml \
         appcast.backup.99999999T999999Z.xml.bak appcast.backup.bad.xml; do
  : > "$TMP/bk/$n"
done
got="$(newest_appcast_backup "$TMP/bk")"
if [[ "$got" == "$TMP/bk/appcast.backup.20260929T101500Z.xml" ]]; then
  pass "newest by timestamp; decoys ignored"
else
  fail "picked [$got]"
fi

echo "==> version-collision refusal (release already has a DMG)"
if printf 'Murmur-0.1.52.dmg\n' | assets_include_dmg; then pass "DMG asset detected"; else fail "DMG asset missed"; fi
if printf 'notes.txt\nMurmur.DMG\n' | assets_include_dmg; then pass "case-insensitive .dmg among others"; else fail ".DMG missed"; fi
if printf '' | assets_include_dmg; then fail "empty asset list read as DMG"; else pass "no assets -> allowed"; fi
if printf 'notes.txt\nappcast.xml\nMurmur.dmg.sig\n' | assets_include_dmg; then fail "non-dmg names matched"; else pass "non-dmg assets -> allowed"; fi
if grep -q 'ALLOW_REPUBLISH_VERSION' "$SCRIPT" \
  && grep -q 'load_gh_release_asset_names "v\${SHORT}"' "$SCRIPT"; then
  pass "collision gate + explicit override wired"
else
  fail "publish-sparkle.sh lacks the v\$SHORT DMG-asset gate"
fi

echo "==> live-feed fingerprint (real function extracted from publish-sparkle.sh)"
eval "$(sed -n "/^mask_xml_noise_py='/,/^'\$/p" "$SCRIPT")"
eval "$(sed -n '/^appcast_newest_fingerprint() {/,/^}/p' "$SCRIPT")"
cat > "$TMP/staged.xml" <<'XML'
<rss><channel>
  <item>
    <sparkle:version>53</sparkle:version>
    <enclosure url="u" sparkle:version="53" sparkle:edSignature="NEWSIG" length="9" />
  </item>
  <item>
    <sparkle:version>52</sparkle:version>
    <enclosure url="u" sparkle:version="52" sparkle:edSignature="OLDSIG" length="8" />
  </item>
</channel></rss>
XML
# CDN still serving the pre-publish feed.
cat > "$TMP/stale.xml" <<'XML'
<rss><channel>
  <item>
    <sparkle:version>52</sparkle:version>
    <enclosure url="u" sparkle:version="52" sparkle:edSignature="OLDSIG" length="8" />
  </item>
</channel></rss>
XML
cat > "$TMP/wrongsig.xml" <<'XML'
<rss><channel>
  <item>
    <sparkle:version>53</sparkle:version>
    <enclosure url="u" sparkle:version="53" sparkle:edSignature="OTHERSIG" length="9" />
  </item>
</channel></rss>
XML
cat > "$TMP/commented.xml" <<'XML'
<rss><channel>
  <!-- <item><sparkle:version>99</sparkle:version><enclosure sparkle:edSignature="GHOST" /></item> -->
  <item>
    <sparkle:version>53</sparkle:version>
    <enclosure url="u" sparkle:version="53" sparkle:edSignature="NEWSIG" length="9" />
  </item>
</channel></rss>
XML
printf '<rss><channel><item><sparkle:version>53</sparkle:version></item></channel></rss>' > "$TMP/nosig.xml"
printf '<rss><channel></channel></rss>' > "$TMP/noitem.xml"
STAGED_FP="$(appcast_newest_fingerprint "$TMP/staged.xml")"
[[ "$STAGED_FP" == "53|NEWSIG" ]] && pass "staged fingerprint 53|NEWSIG" || fail "staged fp [$STAGED_FP]"
[[ "$(appcast_newest_fingerprint "$TMP/commented.xml")" == "$STAGED_FP" ]] \
  && pass "commented item ignored; identical newest item matches" || fail "comment masking"
[[ "$(appcast_newest_fingerprint "$TMP/stale.xml")" != "$STAGED_FP" ]] \
  && pass "stale feed (old newest) differs" || fail "stale feed matched"
[[ "$(appcast_newest_fingerprint "$TMP/wrongsig.xml")" != "$STAGED_FP" ]] \
  && pass "same version, different signature differs" || fail "signature ignored"
[[ -z "$(appcast_newest_fingerprint "$TMP/nosig.xml")" ]] \
  && pass "newest item without edSignature -> empty (fail closed)" || fail "nosig produced fp"
[[ -z "$(appcast_newest_fingerprint "$TMP/noitem.xml")" ]] \
  && pass "no <item> -> empty (fail closed)" || fail "noitem produced fp"

echo "==> cache-busted URL"
[[ "$(cache_busted_url 'https://h/p/appcast.xml' 7)" == 'https://h/p/appcast.xml?cb=7' ]] \
  && pass "nonce appended with ?" || fail "plain url"
[[ "$(cache_busted_url 'https://h/p?a=1' 7)" == 'https://h/p?a=1&cb=7' ]] \
  && pass "nonce appended with & to an existing query" || fail "query url"

echo "==> publish-sparkle.sh release-safety wiring"
ln_of() { grep -n -m1 -- "$1" "$SCRIPT" | cut -d: -f1; }
TEAM_LINE="$(ln_of '^resolve_development_team ')"
FETCH_LINE="$(ln_of '^if fetch_prior_appcast')"
if [[ -n "$TEAM_LINE" && -n "$FETCH_LINE" ]] && (( TEAM_LINE < FETCH_LINE )); then
  pass "team-id preflight ($TEAM_LINE) precedes the first network call ($FETCH_LINE)"
else
  fail "team-id preflight missing or after fetch_prior_appcast (team=$TEAM_LINE fetch=$FETCH_LINE)"
fi
if grep -q 'env -u DMG_PATH' "$SCRIPT"; then pass "DMG_PATH unset for make-dmg.sh"; else fail "make-dmg.sh still inherits DMG_PATH"; fi
if grep -q 'xcrun stapler validate "\$DMG"' "$SCRIPT" \
  && grep -q 'codesign --verify --deep --strict "\$APP"' "$SCRIPT"; then
  pass "SKIP_MAKE_DMG + NOTARIZE=1 runs stapler + codesign --strict"
else
  fail "SKIP_MAKE_DMG reuse lacks stapler/codesign checks"
fi
VERIFY_LINE="$(ln_of 'sign_update.*--verify.*VERIFY_DMG\|--verify --ed-key-file "\$SPARKLE_PRIVATE_KEY" "\$VERIFY_DMG"')"
BACKUP_LINE="$(ln_of 'appcast.backup.\$(date')"
UPLOAD_LINE="$(ln_of '^if ! gh release upload appcast "\$STAGE_APPCAST"')"
DMGUP_LINE="$(ln_of 'gh release upload "\$TAG"')"
if [[ -n "$VERIFY_LINE" && -n "$BACKUP_LINE" && -n "$UPLOAD_LINE" && -n "$DMGUP_LINE" ]] \
  && (( DMGUP_LINE < VERIFY_LINE && VERIFY_LINE < BACKUP_LINE && BACKUP_LINE < UPLOAD_LINE )); then
  pass "order: DMG upload ($DMGUP_LINE) → verify download ($VERIFY_LINE) → backup ($BACKUP_LINE) → appcast upload ($UPLOAD_LINE)"
else
  fail "release order wrong/missing (dmgup=$DMGUP_LINE verify=$VERIFY_LINE backup=$BACKUP_LINE upload=$UPLOAD_LINE)"
fi
if grep -q 'restore_appcast_backup "\$APPCAST_BACKUP"' "$SCRIPT"; then pass "failed appcast upload restores the backup"; else fail "no restore on failed appcast upload"; fi
if grep -q 'gh release upload appcast "\$STAGE_APPCAST" --repo "\$UPDATES_REPO" --clobber$' "$SCRIPT"; then
  fail "bare appcast --clobber (no failure handling) still present"
else
  pass "no unguarded appcast --clobber"
fi
if grep -q 'appcast_newest_fingerprint "\$LIVE_APPCAST"' "$SCRIPT" && grep -q 'curl_fresh "live feed"' "$SCRIPT"; then
  pass "live feed compared to staged after upload"
else
  fail "no post-upload live-feed comparison"
fi

echo "==> restore_appcast_backup (real function extracted; gh stubbed)"
eval "$(sed -n '/^restore_appcast_backup() {/,/^}/p' "$SCRIPT")"
mkdir -p "$TMP/build"
GH_LOG="$TMP/gh.log"
gh() { echo "$*" >> "$GH_LOG"; [[ "$4" == *appcast.xml ]] && cp "$4" "$TMP/uploaded.xml"; [[ -z "${GH_FAIL:-}" ]]; }
UPDATES_REPO="o/r"
BK="$TMP/bk/appcast.backup.20260929T101500Z.xml"
printf 'PRIOR-FEED-BYTES\n' > "$BK"
: > "$GH_LOG"; rm -f "$TMP/uploaded.xml"
if ROOT="$TMP" restore_appcast_backup "$BK" 2>/dev/null \
  && grep -q '^release upload appcast .*/appcast.xml --repo o/r --clobber$' "$GH_LOG" \
  && [[ "$(cat "$TMP/uploaded.xml")" == "PRIOR-FEED-BYTES" ]]; then
  pass "restore re-uploads the backup bytes as appcast.xml"
else
  fail "restore did not upload backup as appcast.xml ($(cat "$GH_LOG"))"
fi
if GH_FAIL=1 ROOT="$TMP" restore_appcast_backup "$BK" 2>/dev/null; then
  fail "failed restore reported success"
else
  pass "failed restore returns non-zero (caller still exits 1)"
fi
if ROOT="$TMP" restore_appcast_backup "" 2>/dev/null; then
  fail "restore with no backup (bootstrap) reported success"
else
  pass "no backup (bootstrap) -> non-zero, no upload attempted"
fi
[[ -z "$(ls -A "$TMP/build")" ]] && pass "restore temp dirs cleaned up" || fail "restore left temp dirs: $(ls "$TMP/build")"
unset -f gh

echo "==> recover-appcast.sh guards"
if grep -q 'newest_appcast_backup' "$RECOVER" \
  && grep -q 'FORCE_RECOVER' "$RECOVER" \
  && grep -q 'gh release view appcast' "$RECOVER" \
  && grep -q 'DRY_RUN' "$RECOVER"; then
  pass "recovers newest backup; refuses a live feed / unconfirmed release; dry-run"
else
  fail "recover-appcast.sh missing a guard"
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "ORACLE FAILED"
  exit 1
fi
echo "ORACLE OK"
