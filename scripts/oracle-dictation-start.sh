#!/usr/bin/env bash
# Product oracle: did a recent dictation hold actually start the mic engine?
#
# VoiceTests green is NOT this check. 2026-08-17 the suite passed while
# every hold SIGABRT'd (prepare() before CurrentDevice), then passed again
# while the HUD said microphone unavailable (0-ch graph bound Continuity).
#
# Usage:
#   bash scripts/oracle-dictation-start.sh              # last 15m
#   bash scripts/oracle-dictation-start.sh 30m
#   bash scripts/oracle-dictation-start.sh --selftest
#
# Fixtures (helpers oracle; skip live log/IPS):
#   ORACLE_DICTATION_LOG_FILE=/path/to/log.txt
#   ORACLE_DICTATION_SKIP_IPS=1
#
# Exit:
#   0  PASS — last audio event in window is "AVAudioEngine started — recording"
#             and no Murmur IPS mtime in the window
#   1  FAIL — last event is mic-start failure / NSException bind, or a fresh IPS
#   2  NO HOLD — no Murmur audio logs in the window (not a pass; do not Sparkle)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--selftest" ]]; then
  command -v python3 >/dev/null
  [[ -x /usr/bin/log ]]
  echo "ORACLE OK — dictation-start selftest (live log/IPS check not run)"
  exit 0
fi

WINDOW="${1:-15m}"
if [[ ! "$WINDOW" =~ ^[0-9]+m$ ]]; then
  echo "usage: $0 [NNm|--selftest]" >&2
  echo "  NNm = log/IPS window (default 15m)" >&2
  exit 2
fi
MINUTES="${WINDOW%m}"

classify_audio_log() {
  # stdin = log text. Do not use a heredoc here — it steals stdin from the pipe.
  python3 -c '
import sys
text = sys.stdin.read()
pass_needle = "AVAudioEngine started — recording"
fail_needles = (
    "mic start failed",
    "AVAudioEngine start timed out",
    "bindInputNode: NSException",
    "NSException",
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

IPS_HITS=""
if [[ "${ORACLE_DICTATION_SKIP_IPS:-0}" != "1" ]]; then
  IPS_HITS="$(
    find "$HOME/Library/Logs/DiagnosticReports" \
      "$HOME/Library/Logs/DiagnosticReports/Retired" \
      -name 'Murmur-*.ips' -mmin -"$MINUTES" 2>/dev/null || true
  )"
fi

if [[ -n "${ORACLE_DICTATION_LOG_FILE:-}" ]]; then
  if [[ ! -f "$ORACLE_DICTATION_LOG_FILE" ]]; then
    echo "FAIL: ORACLE_DICTATION_LOG_FILE missing: $ORACLE_DICTATION_LOG_FILE" >&2
    exit 1
  fi
  LOG_TEXT="$(cat "$ORACLE_DICTATION_LOG_FILE")"
else
  if ! LOG_TEXT="$(
    /usr/bin/log show --style compact --last "$WINDOW" \
      --predicate 'subsystem == "com.matt.voice-dictation" AND category == "audio"'
  )"; then
    echo "FAIL: /usr/bin/log show failed" >&2
    exit 1
  fi
fi

set +e
printf '%s' "$LOG_TEXT" | classify_audio_log
CLASSIFY_RC=$?
set -e

if [[ -n "$IPS_HITS" ]]; then
  echo "FAIL: Murmur IPS in last ${MINUTES}m (SIGABRT / crash in window):" >&2
  echo "$IPS_HITS" >&2
  exit 1
fi

case "$CLASSIFY_RC" in
  0)
    echo "PASS: AVAudioEngine started — recording (last audio event in ${WINDOW})"
    exit 0
    ;;
  1)
    echo "FAIL: last audio event in ${WINDOW} is mic-start failure / NSException (not a later start)" >&2
    echo "$LOG_TEXT" | tail -n 40 >&2
    exit 1
    ;;
  2)
    echo "NO HOLD: no Murmur audio logs in last ${WINDOW} — not a pass. Hold fn, then re-run." >&2
    exit 2
    ;;
  *)
    echo "FAIL: classifier exit $CLASSIFY_RC" >&2
    exit 1
    ;;
esac
