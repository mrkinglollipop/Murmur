#!/usr/bin/env bash
# Offline oracle: IME dictation-start product check stays encoded, and the
# classifier does not treat "no take" as pass.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/oracle-dictation-start.sh"
FAIL=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=1; }

echo "==> bash -n oracle-dictation-start.sh"
if bash -n "$SCRIPT"; then
  pass "bash -n"
else
  fail "bash -n"
fi

echo "==> --selftest"
if bash "$SCRIPT" --selftest >/dev/null; then
  pass "--selftest exit 0"
else
  fail "--selftest"
fi

echo "==> README names the script"
if grep -q 'oracle-dictation-start.sh' "$ROOT/README.md"; then
  pass "README.md names oracle-dictation-start.sh"
else
  fail "$ROOT/README.md must name scripts/oracle-dictation-start.sh"
fi

if grep -q 'not a pass' "$ROOT/README.md"; then
  pass "README.md says exit 2 / no-take is not a pass"
else
  fail "README.md must say a missing take is not a pass"
fi

if grep -q 'ime.mic.start' "$ROOT/README.md"; then
  pass "README.md names IME pass needle ime.mic.start"
else
  fail "README.md must name ime.mic.start as an IME pass needle"
fi

echo "==> live dump is window-bounded"
if grep -q 'adb logcat -d -t' "$SCRIPT" && grep -q 'MINUTES' "$SCRIPT"; then
  pass "adb logcat uses -t cutoff from MINUTES"
else
  fail "live path must pass MINUTES into adb logcat -t"
fi

echo "==> classifier fixtures (skip live logcat)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oracle-dictation.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

run_fix() {
  local name="$1" expected="$2" body="$3"
  local file="$TMP/$name.txt"
  printf '%s\n' "$body" >"$file"
  set +e
  ORACLE_DICTATION_LOG_FILE="$file" ORACLE_DICTATION_NOW="${4:-}" \
    bash "$SCRIPT" 15m >/dev/null 2>&1
  local rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    pass "fixture $name → exit $expected"
  else
    fail "fixture $name expected $expected got $rc"
  fi
}

run_fix empty 2 ""
run_fix started 0 $'murmur: ime.mic.start\nmurmur: mic.capture.started'
run_fix fgs_started 0 $'murmur: fgs.start\nmurmur: mic.capture.started'
run_fix companion_only 2 "murmur: mic.capture.started"
run_fix failed 1 $'murmur: ime.mic.start\nmurmur: mic.capture.failed'
run_fix init 1 $'murmur: ime.mic.start\nmurmur: AudioRecord.init.failed'
run_fix fgs 1 "murmur: fgs.start.denied"
run_fix fatal_murmur 1 "Fatal signal 6 (SIGABRT) in tid 1 (com.matt.murmur.android)"
run_fix fatal_other 2 "Fatal signal 6 (SIGABRT) in tid 1 (com.android.chrome)"
run_fix fail_then_start 0 $'murmur: mic.capture.failed\nmurmur: ime.mic.start\nmurmur: mic.capture.started'
run_fix start_then_fail 1 $'murmur: ime.mic.start\nmurmur: mic.capture.started\nmurmur: mic.capture.failed'
run_fix start_then_denied 1 $'murmur: ime.mic.start\nmurmur: mic.capture.started\nmurmur: fgs.start.denied'

NOW="2026-01-01 00:20:00"
run_fix stale_outside_window 2 $'01-01 00:00:00.000 I murmur: ime.mic.start\n01-01 00:00:00.001 I murmur: mic.capture.started' "$NOW"
run_fix recent_inside_window 0 $'01-01 00:16:00.000 I murmur: ime.mic.start\n01-01 00:16:00.001 I murmur: mic.capture.started' "$NOW"

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "ORACLE FAILED"
  exit 1
fi
echo "ORACLE OK — dictation-start helpers"
