#!/usr/bin/env bash
# Offline oracle: install-local.sh must replace /Applications, never merge;
# team-id validation (shared with make-dmg.sh / publish-sparkle.sh) fails closed;
# the quit fallback is a captured-PID SIGTERM wait, never a pgrep -f loop.
# No network / signing / installed-app access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/install-local.sh"
MAKE_DMG="$ROOT/scripts/make-dmg.sh"
LIB="$ROOT/scripts/release-lib.sh"
FAIL=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=1; }

echo "==> bash -n"
for f in "$SCRIPT" "$MAKE_DMG" "$LIB"; do
  if bash -n "$f"; then pass "bash -n $(basename "$f")"; else fail "bash -n $(basename "$f")"; fi
done

echo "==> atomic replace contract (stage → verify → mv, with rollback)"
# Staging path + verify before mv; never ditto-merge into a live bundle.
if grep -q '\.Murmur-install\.' "$SCRIPT" \
  && grep -q 'codesign --verify --deep --strict "\$STAGING"' "$SCRIPT" \
  && grep -q 'mv "\$DEST" "\$ROLLBACK"' "$SCRIPT" \
  && grep -q 'mv "\$STAGING" "\$DEST"' "$SCRIPT"; then
  pass "stage + verify + rollback + mv"
else
  fail "install-local.sh lost the stage/verify/rollback/mv contract"
fi
if grep -E 'ditto.*"\$PRODUCT".*/Applications/Murmur\.app"' "$SCRIPT"; then
  fail "ditto merges into /Applications/Murmur.app"
else
  pass "no ditto into /Applications/Murmur.app"
fi

echo "==> quit fallback is captured-PID SIGTERM (no self-matching pgrep -f)"
if grep -q 'pgrep -f' "$SCRIPT"; then
  fail "install-local.sh uses pgrep -f (matches its own command line)"
elif grep -q 'sigterm_and_wait' "$SCRIPT"; then
  pass "sigterm_and_wait on captured PIDs"
else
  fail "install-local.sh has no SIGTERM fallback for an app that ignores quit"
fi

# shellcheck source=release-lib.sh
source "$LIB"

echo "==> team-id validation"
for good in ABCDE12345 0123456789 ZZZZZZZZZZ; do
  if is_valid_team_id "$good"; then pass "accepts $good"; else fail "rejects valid team id $good"; fi
done
for bad in "" YOUR_TEAM_ID abcde12345 ABCDE1234 ABCDE123456 "ABCDE 12345" "ABCDE-12345" $'ABCDE12345\n'; do
  if is_valid_team_id "$bad"; then fail "accepts invalid team id [$bad]"; else pass "rejects [$bad]"; fi
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/release-lib-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> team id from xcconfig"
printf '// c\n\nDEVELOPMENT_TEAM = ABCDE12345 // trailing\n' > "$TMP/good.xcconfig"
got="$(DEVELOPMENT_TEAM= resolve_development_team "$TMP/good.xcconfig" 2>/dev/null || true)"
if [[ "$got" == "ABCDE12345" ]]; then pass "reads + strips comment"; else fail "good xcconfig resolved to [$got]"; fi

# The shipped example file (placeholder) must fail immediately, with guidance.
if err="$(DEVELOPMENT_TEAM= resolve_development_team "$ROOT/Config/Team.xcconfig.example" 2>&1 >/dev/null)"; then
  fail "Team.xcconfig.example (YOUR_TEAM_ID) was accepted"
elif [[ "$err" == *"Team.xcconfig.example"* && "$err" == *"real"* ]]; then
  pass "example placeholder rejected with copy-the-real-file guidance"
else
  fail "example placeholder rejected without guidance: $err"
fi

# Env override wins over the file, and is validated too.
if DEVELOPMENT_TEAM=BADVALUE resolve_development_team "$TMP/good.xcconfig" >/dev/null 2>&1; then
  fail "invalid DEVELOPMENT_TEAM env accepted"
else
  pass "invalid env override rejected (no silent fallback to file)"
fi
got="$(DEVELOPMENT_TEAM=ENVTEAM123 resolve_development_team "$TMP/none.xcconfig" 2>/dev/null || true)"
if [[ "$got" == "ENVTEAM123" ]]; then pass "valid env override, no file needed"; else fail "env override resolved to [$got]"; fi
if DEVELOPMENT_TEAM= resolve_development_team "$TMP/none.xcconfig" >/dev/null 2>&1; then
  fail "missing team accepted"
else
  pass "missing team rejected"
fi

for f in "$SCRIPT" "$MAKE_DMG"; do
  if grep -q 'resolve_development_team' "$f"; then
    pass "$(basename "$f") validates the team id"
  else
    fail "$(basename "$f") does not call resolve_development_team"
  fi
done

echo "==> make-dmg.sh get-task-allow gate is not a pipeline (SIGPIPE / codesign-failure bypass)"
if grep -nE 'codesign -d .*\|' "$LIB"; then
  fail "release-lib.sh pipes codesign -d (pipefail + SIGPIPE can bypass the check)"
elif grep -q 'assert_no_get_task_allow' "$MAKE_DMG" \
  && grep -q 'assert_no_get_task_allow' "$SCRIPT" \
  && grep -q 'grep -q get-task-allow <<<"\$entitlements"' "$LIB"; then
  pass "shared entitlements gate used by package and install scripts"
else
  fail "package/install get-task-allow gate is incomplete"
fi

echo "==> install release signing matches DMG release hardening"
if grep -q 'xcodegen generate' "$SCRIPT" \
  && grep -q 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO' "$SCRIPT" \
  && grep -q 'Deep-signing Sparkle nested binaries' "$SCRIPT" \
  && grep -q -- '--entitlements "\$ENTITLEMENTS"' "$SCRIPT"; then
  pass "install regenerates and explicit Developer-ID re-signs without injected entitlements"
else
  fail "install-local.sh lost regeneration, hardened signing, or explicit re-sign"
fi

echo "==> Pro bundle detection fails closed"
mkdir -p "$TMP/free.app/Contents" "$TMP/pro.app/Contents" "$TMP/malformed.app/Contents" "$TMP/non-dict.app/Contents"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleURLTypes</key><array/></dict></plist>' > "$TMP/free.app/Contents/Info.plist"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.matt.voice-dictation.auth</string></dict></array></dict></plist>' > "$TMP/pro.app/Contents/Info.plist"
printf '%s\n' 'not a plist' > "$TMP/malformed.app/Contents/Info.plist"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><array><string>not a dictionary</string></array></plist>' > "$TMP/non-dict.app/Contents/Info.plist"
if is_pro_app_bundle "$TMP/free.app"; then
  fail "standard bundle identified as Pro"
else
  case $? in 1) pass "standard bundle allowed" ;; *) fail "standard bundle probe did not return standard" ;; esac
fi
if is_pro_app_bundle "$TMP/pro.app"; then
  pass "Pro OAuth URL bundle blocked"
else
  fail "Pro OAuth URL bundle was not identified"
fi
for bad_bundle in "$TMP/malformed.app" "$TMP/non-dict.app" "$TMP/missing.app"; do
  if is_pro_app_bundle "$bad_bundle"; then
    fail "bad bundle unexpectedly identified as Pro"
  else
    case $? in 2) pass "$(basename "$bad_bundle") fails closed" ;; *) fail "$(basename "$bad_bundle") did not fail closed" ;; esac
  fi
done

echo "==> stable DMG aliases resolve before local-only output"
mkdir -p "$TMP/stable"
: > "$TMP/stable/Murmur.dmg"
ln -s "$TMP/stable" "$TMP/stable-link"
if is_stable_dmg_path "$TMP/stable-link/Murmur.dmg" "$TMP/stable/Murmur.dmg"; then
  pass "symlinked stable alias rejected"
else
  fail "symlinked stable alias was not recognized"
fi
if is_stable_dmg_path "$TMP/other.dmg" "$TMP/stable/Murmur.dmg"; then
  fail "distinct local DMG path was treated as stable alias"
else
  case $? in 1) pass "distinct local DMG path allowed" ;; *) fail "distinct local DMG path resolution failed" ;; esac
fi

echo "==> get-task-allow false still rejects"
codesign() { printf '%s\n' "${FAKE_ENTITLEMENTS:-}"; }
FAKE_ENTITLEMENTS='<plist><dict><key>get-task-allow</key><false/></dict></plist>'
if assert_no_get_task_allow "$TMP/free.app"; then
  fail "get-task-allow=false was accepted"
else
  pass "get-task-allow presence rejected regardless of value"
fi
unset -f codesign

echo "==> SIGTERM fallback helpers (real processes)"
sleep 30 &
victim=$!
if pid_alive "$victim" && sigterm_and_wait "$victim" 30; then
  pass "SIGTERM stops a cooperative process"
else
  fail "cooperative process survived sigterm_and_wait"
fi
wait "$victim" 2>/dev/null || true

# Ignores SIGTERM: sigterm_and_wait must report failure (install then aborts).
bash -c 'trap "" TERM; while :; do sleep 0.2; done' &
stubborn=$!
sleep 0.3
if sigterm_and_wait "$stubborn" 5; then
  fail "SIGTERM-ignoring process reported as exited"
else
  pass "SIGTERM-ignoring process reported as survivor"
fi
kill -KILL "$stubborn" 2>/dev/null || true
wait "$stubborn" 2>/dev/null || true

if sigterm_and_wait 99999999 3; then pass "already-gone pid is success"; else fail "gone pid reported alive"; fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "ORACLE FAILED"
  exit 1
fi
echo "ORACLE OK — install-local replace+verify+team-id+quit-fallback contract"
