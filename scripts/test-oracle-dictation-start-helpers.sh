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
  local image="${4-/Applications/Murmur.app/Contents/MacOS/Murmur}"
  local timestamp="${5-2026-10-11 07:44:00.000000-0400}" pid="${6:-1234}"
  local file="$TMP/$name.json"
  python3 - "$body" "$image" "$timestamp" "$pid" >"$file" <<'PY'
import json
import sys
body, image, timestamp, pid = sys.argv[1:]
print(json.dumps([
    {"eventMessage": message, "processImagePath": image, "processID": int(pid),
     "timestamp": timestamp, "subsystem": "com.matt.voice-dictation", "category": "audio"}
    for message in body.splitlines()
], ensure_ascii=False))
PY
  set +e
  ORACLE_DICTATION_SKIP_IPS=1 ORACLE_DICTATION_LOG_FILE="$file" \
    ORACLE_DICTATION_PID=1234 ORACLE_DICTATION_LAUNCH_TIME='2026-10-11T07:43:38-04:00' \
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
run_fix test_host_only 2 'AVAudioEngine started — recording' \
  '/tmp/DerivedData/Build/Products/Debug/Murmur.app/Contents/MacOS/Murmur' \
  '2026-10-11 07:41:00.000000-0400' 5678
run_fix test_host_after_launch 2 'AVAudioEngine started — recording' \
  '/tmp/DerivedData/Build/Products/Debug/Murmur.app/Contents/MacOS/Murmur'
run_fix installed_before_launch 2 'AVAudioEngine started — recording' \
  '/Applications/Murmur.app/Contents/MacOS/Murmur' '2026-10-11 07:41:00.000000-0400'
run_fix installed_other_pid 2 'AVAudioEngine started — recording' \
  '/Applications/Murmur.app/Contents/MacOS/Murmur' '2026-10-11 07:44:00.000000-0400' 5678
run_fix missing_identity 2 'AVAudioEngine started — recording' '' ''
run_fix invalid_timestamp 2 'AVAudioEngine started — recording' \
  '/Applications/Murmur.app/Contents/MacOS/Murmur' 'not-a-timestamp'

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "ORACLE FAILED"
  exit 1
fi
echo "ORACLE OK — dictation-start helpers"
