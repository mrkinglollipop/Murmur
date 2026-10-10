#!/usr/bin/env bash
# Offline guard oracle. Only sourced functions run; no publish/build entrypoint.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Serialize this oracle across worktrees, with a bounded wait on the shared lock.
if [[ "${1:-}" != --locked ]]; then
  exec python3 - "$0" <<'PY'
import fcntl, os, subprocess, sys, tempfile, time
with open(os.path.join(tempfile.gettempdir(), 'murmur-test-publish-guards.lock'), 'a') as lock:
    deadline = time.monotonic() + 60
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                sys.exit('ORACLE FAILED: shared lock timeout')
            time.sleep(0.2)
    try:
        sys.exit(subprocess.run(['bash', sys.argv[1], '--locked'], timeout=120).returncode)
    except subprocess.TimeoutExpired:
        sys.exit('ORACLE FAILED: 120s timeout')
PY
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/publish-guards.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fixture"
export FIXTURE="$TMP/fixture" SCRIPT="$ROOT/scripts/publish-sparkle.sh"
# All potentially external commands resolve to private stubs. Unknown calls fail.
cat > "$TMP/bin/stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >> "$FIXTURE/calls"
case "$name" in
  git)
    if [[ "$*" == 'status --porcelain' ]]; then
      printf '%s' "${STATUS_OUTPUT:-}"
      exit "${STATUS_RC:-0}"
    fi
    ;;
  hdiutil)
    if [[ "$1" == attach ]]; then
      [[ "${MOUNT_FAIL:-0}" == 0 ]] || exit 1
      while [[ "$1" != -mountpoint ]]; do shift; done
      cp -R "$FIXTURE/payload/Murmur.app" "$2/"
      exit 0
    elif [[ "$1" == detach ]]; then
      rm -rf "$2/Murmur.app"
      exit 0
    fi
    ;;
  codesign) exit "${CODESIGN_RC:-0}" ;;
  xcrun) exit "${STAPLER_RC:-0}" ;;
  gh)
    if [[ "$1 $2" == 'release view' ]]; then
      [[ "${GH_FAIL:-0}" == 0 ]] || exit 128
      if [[ "${GH_MISSING:-0}" == 1 ]]; then echo 'HTTP 404' >&2; exit 1; fi
      if [[ "$*" == *'--json assets'* ]]; then printf '%s\n' "${ASSET_NAMES-Murmur-1.0.dmg}"; fi
      exit 0
    elif [[ "$1 $2" == 'release upload' ]]; then
      # Model gh --clobber: deletion succeeds, replacement upload fails.
      if [[ "$*" == *--clobber* ]]; then rm -f "$FIXTURE/downloadable.dmg"; fi
      exit 1
    fi
    ;;
  curl)
    [[ -f "$FIXTURE/downloadable.dmg" ]] || exit 22
    cat "$FIXTURE/downloadable.dmg"
    exit 0
    ;;
esac
echo "unexpected stub call: $name $*" >&2
exit 97
STUB
chmod +x "$TMP/bin/stub"
for cmd in gh xcrun hdiutil codesign git curl; do ln -s stub "$TMP/bin/$cmd"; done
# Block other entrypoints too, even if a future refactor accidentally calls one.
for cmd in xcodebuild xcodegen security; do ln -s stub "$TMP/bin/$cmd"; done
export PATH="$TMP/bin:$PATH"
cat > "$TMP/case.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT"
ROOT="$FIXTURE"
DERIVED="$FIXTURE/DerivedData"
SHORT=1.0 BUILD=2 TAG=v1.0
NOTARIZE=1 UPDATES_REPO=fixture/updates
HAS_PRIOR=1 PREV_APPCAST="$FIXTURE/prior.xml"
ENCLOSURE_URL="https://github.com/$UPDATES_REPO/releases/download/$TAG/Murmur-$SHORT.dmg"
DMG="$FIXTURE/Murmur-$SHORT.dmg"
DMG_PATH="$DMG" SKIPPED_MAKE_DMG=0
WHATSNEW_NOTES=fixture
trap cleanup_dmg_mount EXIT
# Portable plist reader; real Pro classification still runs from release-lib.sh.
plist_get() {
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[2], 'rb') as f:
    print(plistlib.load(f)[sys.argv[1]])
PY
}
case "$1" in
  payload) validate_dmg_payload ;;
  collision) ALLOW_REPUBLISH_VERSION=1; guard_version_collision; upload_versioned_dmg ;;
  collision_guard) ALLOW_REPUBLISH_VERSION=1; guard_version_collision ;;
  asset_error) assets_include_dmg() { return 2; }; guard_version_collision ;;
  reuse) SKIP_MAKE_DMG=1; prepare_public_dmg; validate_dmg_payload ;;
  status) assert_clean_source; touch "$FIXTURE/artifact-work" ;;
  upload) upload_versioned_dmg ;;
  fresh) require_fresh_public_build ;;

  source) [[ ! -s "$FIXTURE/calls" ]]; exit ;;
esac
CASE
make_fixture() {
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE"
  python3 - "$FIXTURE" "${1:-standard}" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
info = dict(CFBundleShortVersionString='1.0', CFBundleVersion='2',
            SUFeedURL='https://fixture.invalid/appcast.xml', SUPublicEDKey='fixture-key')
for name in ['DerivedData/Build/Products/Release', 'payload']:
    path = root / name / 'Murmur.app/Contents/Info.plist'
    path.parent.mkdir(parents=True)
    data = info.copy()
    if name == 'payload' and sys.argv[2] == 'pro':
        data['CFBundleURLTypes'] = [dict(CFBundleURLName='com.matt.voice-dictation.auth')]
    path.write_bytes(plistlib.dumps(data))
(root / 'Murmur-1.0.dmg').write_text('same-version artifact from different, dirty source')
(root / 'downloadable.dmg').write_text('previous signed bytes')
(root / 'prior.xml').write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1</sparkle:version><enclosure url="https://github.com/fixture/updates/releases/download/v1.0/Murmur-1.0.dmg" /></item></channel></rss>''')
PY
}
TOTAL=0 FAILED=0
check() {
  TOTAL=$((TOTAL + 1))
  if "$@"; then echo "  PASS: $LABEL"; else echo "  FAIL: $LABEL"; FAILED=$((FAILED + 1)); fi
}
run_case() {
  RC=0
  bash "$TMP/case.sh" "$1" > "$TMP/output" 2>&1 || RC=$?
}
refused() {
  [[ "$RC" -ne 0 ]] && grep -q "$1" "$TMP/output"
}
status_refused() {
  refused 'git status failed' && [[ ! -e "$FIXTURE/artifact-work" ]]
}
enclosure_preserved() {
  refused 'already has a DMG asset' &&
    [[ "$(curl -sfL "$ENCLOSURE_TEST_URL")" == 'previous signed bytes' ]] &&
    ! grep -q 'gh release upload' "$FIXTURE/calls"
}
ENCLOSURE_TEST_URL='https://github.com/fixture/updates/releases/download/v1.0/Murmur-1.0.dmg'
LABEL='publish script parses'; check bash -n "$SCRIPT"
make_fixture
run_case source
LABEL='sourcing does not execute publish flow'; check test "$RC" -eq 0

# Regression cases follow audit severity/order. Failure requires the guard's
# own diagnosis, not an incidental command error, and no upload/build side effect.
make_fixture pro
run_case payload
LABEL='#1 actual Pro DMG refused despite matching standard DerivedData'
check refused 'refusing to publish a Pro build'

make_fixture
run_case collision
LABEL='#2 failed replacement cannot delete an advertised enclosure'
check enclosure_preserved

make_fixture
run_case reuse
LABEL='#3 same-version notarized reuse lacks committed-source provenance'
check refused 'SKIP_MAKE_DMG=1 is not permitted'

make_fixture
export STATUS_RC=128
run_case status
unset STATUS_RC
LABEL='#4 git status failure stops before artifact work'
check status_refused

# Boundary and success cases keep the new guards fail-closed without rejecting
# valid standard artifacts or clean source. No full publishing flow is invoked.
make_fixture
run_case payload
LABEL='standard mounted payload passes'; check test "$RC" -eq 0
LABEL='codesign inspects mounted payload, never DerivedData'
check grep -E -q 'codesign --verify --deep --strict .*/dmg-mount\.[^/]+/Murmur.app$' "$FIXTURE/calls"
LABEL='successful validation detaches the DMG'; check grep -q '^hdiutil detach ' "$FIXTURE/calls"

make_fixture
export MOUNT_FAIL=1
run_case payload
unset MOUNT_FAIL
LABEL='mount failure refuses payload'; check refused 'failed to mount DMG'

make_fixture
rm "$FIXTURE/payload/Murmur.app/Contents/Info.plist"
run_case payload
LABEL='missing payload plist refuses'; check test "$RC" -ne 0

make_fixture
printf 'not a plist' > "$FIXTURE/payload/Murmur.app/Contents/Info.plist"
run_case payload
LABEL='malformed payload plist refuses'; check test "$RC" -ne 0

make_fixture
python3 - "$FIXTURE" <<'PY'
import pathlib, plistlib, sys
p = pathlib.Path(sys.argv[1]) / 'payload/Murmur.app/Contents/Info.plist'
d = plistlib.loads(p.read_bytes()); d['CFBundleVersion'] = '1'; p.write_bytes(plistlib.dumps(d))
PY
run_case payload
LABEL='payload version mismatch refuses despite matching DerivedData'; check refused '!= project.yml'

make_fixture
python3 - "$FIXTURE" <<'PY'
import pathlib, plistlib, sys
p = pathlib.Path(sys.argv[1]) / 'payload/Murmur.app/Contents/Info.plist'
d = plistlib.loads(p.read_bytes()); d['CFBundleURLTypes'] = 'malformed'; p.write_bytes(plistlib.dumps(d))
PY
run_case payload
LABEL='indeterminate Pro identity refuses'; check refused 'cannot determine whether'

make_fixture
export STAPLER_RC=1
run_case payload
unset STAPLER_RC
LABEL='invalid notarization refuses'; check refused 'no valid notarization ticket'

make_fixture
export CODESIGN_RC=1
run_case payload
unset CODESIGN_RC
LABEL='invalid app signature refuses'; check refused 'fails codesign'

make_fixture
export GH_FAIL=1
run_case collision_guard
unset GH_FAIL
LABEL='release lookup failure refuses'; check refused 'gh release view'

make_fixture
run_case asset_error
LABEL='asset inspection error refuses'; check refused 'cannot inspect release assets'

make_fixture
export ASSET_NAMES='notes.txt'
run_case collision_guard
unset ASSET_NAMES
LABEL='existing release without DMG passes preflight'; check test "$RC" -eq 0

make_fixture
export GH_MISSING=1
run_case collision_guard
unset GH_MISSING
LABEL='confirmed missing release passes preflight'; check test "$RC" -eq 0

make_fixture
run_case upload
LABEL='failed upload cannot delete an asset appearing after preflight'
check test "$(curl -sfL "$ENCLOSURE_TEST_URL")" = 'previous signed bytes'
LABEL='versioned upload has no clobber option'
check bash -c '! grep "gh release upload.*--clobber" "$FIXTURE/calls"'

make_fixture
run_case fresh
LABEL='fresh public build mode accepted'; check test "$RC" -eq 0

make_fixture
export STATUS_OUTPUT=' M source.swift'
run_case status
unset STATUS_OUTPUT
LABEL='dirty source refuses before artifact work'; check refused 'working tree is dirty'

make_fixture
run_case status
LABEL='clean source accepted'; check test "$RC" -eq 0

make_fixture
export STATUS_RC=128 STATUS_OUTPUT='partial output'
run_case status
unset STATUS_RC STATUS_OUTPUT
LABEL='Git error with partial stdout also refuses'; check status_refused

LABEL='public flow invokes guards before artifact and upload work'
check python3 - "$SCRIPT" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
main = s.split('publish_main() {', 1)[1]
assert main.index('assert_clean_source || exit 1') < main.index('bash "$ROOT/scripts/test-app-icon-helpers.sh"')
assert main.index('require_fresh_public_build || exit 1') < main.index('if fetch_prior_appcast')
assert main.index('guard_version_collision || exit 1') < main.index('xcodegen generate')
assert main.index('prepare_public_dmg || exit 1') < main.index('validate_dmg_payload || exit 1') < main.index('upload_versioned_dmg || exit 1')
PY

printf '\nTests: %s, failures: %s\n' "$TOTAL" "$FAILED"
if [[ "$FAILED" != 0 ]]; then echo 'ORACLE FAILED'; exit 1; fi
echo 'ORACLE OK — publish guards'
