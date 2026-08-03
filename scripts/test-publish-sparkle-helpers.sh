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

echo "==> What's New release notes wired into appcast item"
if grep -q 'Resources/WhatsNew/releases\.json' "$SCRIPT" \
  && grep -q 'WhatsNew' "$SCRIPT" \
  && grep -q '<description><!\[CDATA\[' "$SCRIPT"; then
  pass "releases.json + CDATA description in publish-sparkle.sh"
else
  fail "publish-sparkle.sh must build <description> from Resources/WhatsNew/releases.json"
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

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "ORACLE FAILED"
  exit 1
fi
echo "ORACLE OK"
