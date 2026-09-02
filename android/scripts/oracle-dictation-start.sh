#!/usr/bin/env bash
# Product oracle: did a recent IME dictation take actually start the mic?
#
# VoiceTests / Gradle green is NOT this check. Analog of scripts/oracle-dictation-start.sh.
#
# Usage:
#   bash android/scripts/oracle-dictation-start.sh              # last 15m
#   bash android/scripts/oracle-dictation-start.sh 30m
#   bash android/scripts/oracle-dictation-start.sh --selftest
#
# Fixtures (helpers oracle; skip live logcat):
#   ORACLE_DICTATION_LOG_FILE=/path/to/log.txt
#
# Exit:
#   0  PASS — last murmur audio event in window is "mic.capture.started"
#   1  FAIL — last event is capture/FGS failure, or a Fatal signal
#   2  NO HOLD — no murmur audio logs in the window (not a pass)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--selftest" ]]; then
  command -v python3 >/dev/null
  echo "ORACLE OK — dictation-start selftest (live logcat not run)"
  exit 0
fi

WINDOW="${1:-15m}"
if [[ ! "$WINDOW" =~ ^[0-9]+m$ ]]; then
  echo "usage: $0 [NNm|--selftest]" >&2
  echo "  NNm = log window (default 15m)" >&2
  exit 2
fi
MINUTES="${WINDOW%m}"

classify_audio_log() {
  python3 -c '
import sys
text = sys.stdin.read()
pass_needle = "mic.capture.started"
fail_needles = (
    "mic.capture.failed",
    "AudioRecord.init.failed",
    "fgs.start.denied",
    "Fatal signal",
)
last = None
for line in text.splitlines():
    if pass_needle in line:
        last = "pass"
    elif any(n in line for n in fail_needles):
        last = "fail"
if last is None:
    sys.exit(2)
sys.exit(0 if last == "pass" else 1)
'
}

if [[ -n "${ORACLE_DICTATION_LOG_FILE:-}" ]]; then
  if [[ ! -f "$ORACLE_DICTATION_LOG_FILE" ]]; then
    echo "FAIL: ORACLE_DICTATION_LOG_FILE missing: $ORACLE_DICTATION_LOG_FILE" >&2
    exit 1
  fi
  LOG_TEXT="$(cat "$ORACLE_DICTATION_LOG_FILE")"
elif command -v adb >/dev/null 2>&1; then
  if ! LOG_TEXT="$(adb logcat -d 2>/dev/null | grep -E "murmur|Fatal signal" || true)"; then
    echo "FAIL: adb logcat failed" >&2
    exit 1
  fi
else
  echo "NO HOLD: no log file and no adb — not a pass. Take on device, then re-run." >&2
  exit 2
fi

set +e
printf '%s' "$LOG_TEXT" | classify_audio_log
CLASSIFY_RC=$?
set -e

case "$CLASSIFY_RC" in
  0)
    echo "PASS: mic.capture.started (last audio event in ${WINDOW})"
    exit 0
    ;;
  1)
    echo "FAIL: last audio event in ${WINDOW} is capture/FGS failure / Fatal signal" >&2
    echo "$LOG_TEXT" | tail -n 40 >&2
    exit 1
    ;;
  2)
    echo "NO HOLD: no murmur audio logs in last ${WINDOW} — not a pass. Tap mic, then re-run." >&2
    exit 2
    ;;
  *)
    echo "FAIL: classifier exit $CLASSIFY_RC" >&2
    exit 1
    ;;
esac
