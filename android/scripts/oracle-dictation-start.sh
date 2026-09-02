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
#   ORACLE_DICTATION_NOW='YYYY-MM-DD HH:MM:SS'  # optional; timestamps in the file are filtered
#
# Exit:
#   0  PASS — window has an IME start (ime.mic.start or fgs.start) and the last
#             murmur audio event is mic.capture.started
#   1  FAIL — last event is capture/FGS failure, or a Murmur Fatal signal
#   2  NO HOLD — no IME take in the window (not a pass). Companion-only
#             mic.capture.started is exit 2.
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
export ORACLE_WINDOW_MINUTES="$MINUTES"

classify_audio_log() {
  # stdin = log text. Do not use a heredoc here — it steals stdin from the pipe.
  python3 -c '
import os, re, sys
from datetime import datetime, timedelta

text = sys.stdin.read()
minutes = int(os.environ.get("ORACLE_WINDOW_MINUTES", "15"))
now_s = os.environ.get("ORACLE_DICTATION_NOW", "").strip()

def parse_now(s):
    if not s:
        return datetime.now()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    return datetime.now()

now = parse_now(now_s)
cutoff = now - timedelta(minutes=minutes)
year = now.year
ts_re = re.compile(r"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)")

def line_time(line):
    m = ts_re.match(line)
    if not m:
        return None
    raw = m.group(1)
    for fmt in ("%m-%d %H:%M:%S.%f", "%m-%d %H:%M:%S"):
        try:
            dt = datetime.strptime(raw, fmt).replace(year=year)
            if dt > now + timedelta(minutes=1):
                dt = dt.replace(year=year - 1)
            return dt
        except ValueError:
            continue
    return None

def in_window(line):
    t = line_time(line)
    if t is None:
        return True
    return t >= cutoff

lines = [ln for ln in text.splitlines() if in_window(ln)]

def is_murmur_fatal(idx):
    line = lines[idx]
    if "Fatal signal" not in line:
        return False
    lo = max(0, idx - 3)
    hi = min(len(lines), idx + 4)
    blob = "\n".join(lines[lo:hi]).lower()
    return "murmur" in blob or "com.matt.murmur.android" in blob

def is_ime_start(line):
    if "ime.mic.start" in line:
        return True
    return "fgs.start" in line and "denied" not in line

saw_ime = False
last = None
for i, line in enumerate(lines):
    if is_ime_start(line):
        saw_ime = True
    if "fgs.start.denied" in line:
        last = "fail"
    elif "mic.capture.failed" in line or "AudioRecord.init.failed" in line:
        last = "fail"
    elif is_murmur_fatal(i):
        last = "fail"
    elif "mic.capture.started" in line:
        last = "pass"

if last is None:
    sys.exit(2)
if last == "pass" and not saw_ime:
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
  CUTOFF="$(
    python3 -c "
from datetime import datetime, timedelta
print((datetime.now() - timedelta(minutes=int('$MINUTES'))).strftime('%m-%d %H:%M:%S.000'))
"
  )"
  if ! LOG_TEXT="$(adb logcat -d -t "$CUTOFF" 2>/dev/null)"; then
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
    echo "PASS: IME mic.capture.started (last audio event in ${WINDOW})"
    exit 0
    ;;
  1)
    echo "FAIL: last audio event in ${WINDOW} is capture/FGS failure / Murmur Fatal signal" >&2
    echo "$LOG_TEXT" | tail -n 40 >&2
    exit 1
    ;;
  2)
    echo "NO HOLD: no IME take in last ${WINDOW} — not a pass. Tap mic, then re-run." >&2
    exit 2
    ;;
  *)
    echo "FAIL: classifier exit $CLASSIFY_RC" >&2
    exit 1
    ;;
esac
