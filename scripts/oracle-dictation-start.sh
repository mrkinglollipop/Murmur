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
#   ORACLE_DICTATION_LOG_FILE=/path/to/log.json  # /usr/bin/log --style json array
#   ORACLE_DICTATION_PID=1234
#   ORACLE_DICTATION_LAUNCH_TIME=2026-10-11T07:43:38-04:00
#   ORACLE_DICTATION_SKIP_IPS=1
#
# Exit:
#   0  PASS — last installed-process audio event since launch and in the window
#             is "AVAudioEngine started — recording"
#             and no Murmur IPS mtime in the window
#   1  FAIL — last event is mic-start failure / NSException bind, or a fresh IPS
#   2  NO HOLD — no qualifying installed-process event (not a pass; do not Sparkle)
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
INSTALLED_IMAGE='/Applications/Murmur.app/Contents/MacOS/Murmur'

classify_audio_log() {
  # stdin = log JSON. Identity and timestamps are checked in fixture mode too.
  python3 -c '
import datetime
import json
import sys
pid, launch, image = sys.argv[1:]
if not pid.isdecimal() or int(pid) <= 0 or not launch:
    sys.exit(2)
try:
    launched_at = datetime.datetime.fromisoformat(launch)
    if launched_at.tzinfo is None:
        raise ValueError("launch time requires a timezone")
    events = json.load(sys.stdin)
    if not isinstance(events, list):
        raise ValueError("log JSON must be an array")
except (ValueError, TypeError) as error:
    print(f"FAIL: invalid oracle metadata/log JSON: {error}", file=sys.stderr)
    sys.exit(1)
pass_needle = "AVAudioEngine started — recording"
fail_needles = (
    "mic start failed",
    "AVAudioEngine start timed out",
    "bindInputNode: NSException",
    "NSException",
)
last = None
for event in events:
    if not isinstance(event, dict):
        continue
    if (event.get("processID") != int(pid)
            or event.get("processImagePath") != image
            or event.get("subsystem") != "com.matt.voice-dictation"
            or event.get("category") != "audio"):
        continue
    try:
        timestamp = datetime.datetime.fromisoformat(event["timestamp"])
        if timestamp.tzinfo is None or timestamp < launched_at:
            continue
    except (KeyError, ValueError, TypeError):
        continue
    message = event.get("eventMessage", "")
    if not isinstance(message, str):
        continue
    if pass_needle in message:
        last = "pass"
    elif any(n in message for n in fail_needles):
        last = "fail"
if last is None:
    sys.exit(2)
sys.exit(0 if last == "pass" else 1)
' "$PROCESS_PID" "$PROCESS_LAUNCH" "$INSTALLED_IMAGE"
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
  PROCESS_PID="${ORACLE_DICTATION_PID:-}"
  PROCESS_LAUNCH="${ORACLE_DICTATION_LAUNCH_TIME:-}"
  LOG_TEXT="$(cat "$ORACLE_DICTATION_LOG_FILE")"
else
  # ps inspects the running image without opening or launching the app.
  if ! PROCESS_INFO="$(python3 - "$INSTALLED_IMAGE" <<'PY'
import datetime
import os
import subprocess
import sys

rows = subprocess.check_output(
    ["/bin/ps", "-axww", "-o", "pid=,lstart=,comm="],
    text=True, env={**os.environ, "LC_ALL": "C"},
)
processes = []
for row in rows.splitlines():
    fields = row.split(None, 6)
    if len(fields) != 7 or fields[6] != sys.argv[1]:
        continue
    launch = datetime.datetime.strptime(" ".join(fields[1:6]), "%a %b %d %H:%M:%S %Y")
    processes.append((launch.astimezone(), fields[0]))
if processes:
    launch, pid = max(processes)
    print(pid, launch.isoformat())
PY
  )"; then
    echo "FAIL: could not inspect installed Murmur process" >&2
    exit 1
  fi
  PROCESS_PID="" PROCESS_LAUNCH=""
  read -r PROCESS_PID PROCESS_LAUNCH <<<"$PROCESS_INFO" || true
  LOG_TEXT='[]'
  if [[ -n "$PROCESS_PID" ]]; then
    if ! LOG_TEXT="$(
      /usr/bin/log show --style json --last "$WINDOW" \
        --predicate "subsystem == \"com.matt.voice-dictation\" AND category == \"audio\" AND processIdentifier == $PROCESS_PID AND processImagePath == \"$INSTALLED_IMAGE\""
    )"; then
      echo "FAIL: /usr/bin/log show failed" >&2
      exit 1
    fi
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
    echo "PASS: AVAudioEngine started — recording (installed Murmur PID $PROCESS_PID, since launch, last audio event in ${WINDOW})"
    exit 0
    ;;
  1)
    echo "FAIL: last installed Murmur audio event since launch in ${WINDOW} is mic-start failure / NSException (not a later start)" >&2
    echo "$LOG_TEXT" | tail -n 40 >&2
    exit 1
    ;;
  2)
    echo "NO HOLD: no installed Murmur audio events since launch in last ${WINDOW} — not a pass. Hold fn, then re-run." >&2
    exit 2
    ;;
  *)
    echo "FAIL: classifier exit $CLASSIFY_RC" >&2
    exit 1
    ;;
esac
