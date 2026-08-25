#!/usr/bin/env bash
# Offline oracle: dictation hold-start product check stays encoded, and the
# classifier does not treat "no hold" as pass (2026-08-17 VoiceTests-green miss).
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

echo "==> CLAUDE.md / AGENTS.md / 01-verify-oracle.mdc name the script"
for f in \
  "$ROOT/CLAUDE.md" \
  "$ROOT/AGENTS.md" \
  "$ROOT/.cursor/rules/01-verify-oracle.mdc"
do
  if grep -q 'oracle-dictation-start.sh' "$f"; then
    pass "$(basename "$f") names oracle-dictation-start.sh"
  else
    fail "$f must name scripts/oracle-dictation-start.sh"
  fi
done

if grep -q 'not a pass' "$ROOT/CLAUDE.md"; then
  pass "CLAUDE.md says exit 2 / no-hold is not a pass"
else
  fail "CLAUDE.md must say a missing hold is not a pass"
fi

echo "==> classifier fixtures (skip live log/IPS)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oracle-dictation.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

run_fix() {
  local name="$1" expected="$2" body="$3"
  local file="$TMP/$name.txt"
  printf '%s\n' "$body" >"$file"
  set +e
  ORACLE_DICTATION_SKIP_IPS=1 ORACLE_DICTATION_LOG_FILE="$file" \
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
run_fix started 0 "AVAudioEngine started — recording"
run_fix failed 1 "mic start failed: input format 0 ch"
run_fix timeout 1 "AVAudioEngine start timed out after 2.0s"
run_fix nsexc 1 "bindInputNode: NSException AVAudioEngineGraph::Initialize"
run_fix fail_then_start 0 $'mic start failed\nAVAudioEngine started — recording'
run_fix start_then_fail 1 $'AVAudioEngine started — recording\nmic start failed'

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "ORACLE FAILED"
  exit 1
fi
echo "ORACLE OK — dictation-start helpers"
