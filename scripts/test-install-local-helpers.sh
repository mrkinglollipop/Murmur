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
if grep -nE 'codesign -d .*\|' "$MAKE_DMG"; then
  fail "make-dmg.sh pipes codesign -d (pipefail + SIGPIPE can bypass the check)"
elif grep -q 'ENTITLEMENTS_OUT="\$(codesign -d --entitlements' "$MAKE_DMG" \
  && grep -q 'grep -q get-task-allow <<<"\$ENTITLEMENTS_OUT"' "$MAKE_DMG"; then
  pass "entitlements captured, codesign failure fatal, variable tested"
else
  fail "make-dmg.sh get-task-allow gate not in capture-then-test form"
fi

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
