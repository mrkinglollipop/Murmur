#!/usr/bin/env bash
# Shared pure helpers for the release scripts (make-dmg.sh, install-local.sh,
# publish-sparkle.sh, recover-appcast.sh). SOURCE this file; it defines
# functions only and has no side effects, so scripts/test-*-helpers.sh can
# exercise every check offline (no network, no gh, no signing).
#
# Conventions: functions that decide pass/fail return 0/non-zero and explain
# failures on stderr; functions that compute a value print it on stdout.

# --- Apple team id ---------------------------------------------------------

# True only for a real 10-char Apple team id. The example file's YOUR_TEAM_ID
# (and lowercase / short / padded values) must fail.
is_valid_team_id() {
  [[ "${1:-}" =~ ^[A-Z0-9]{10}$ ]]
}

# Read DEVELOPMENT_TEAM from an xcconfig: last assignment wins, trailing
# `// comment` and whitespace stripped. Prints nothing when unset/missing.
read_team_from_xcconfig() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  { grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' "$file" || true; } \
    | tail -1 | sed -E 's/^[^=]*=//; s#//.*$##' | tr -d '[:space:]'
}

# Resolve + validate the team id (env DEVELOPMENT_TEAM, else the xcconfig).
# Prints it on success; on failure explains and returns 1 — call as
#   TEAM="$(resolve_development_team "$ROOT/Config/Team.xcconfig")" || exit 1
resolve_development_team() {
  local file="${1:-Config/Team.xcconfig}"
  local team="${DEVELOPMENT_TEAM:-}"
  if [[ -z "$team" ]]; then
    team="$(read_team_from_xcconfig "$file")"
  fi
  if [[ -z "$team" ]]; then
    echo "error: no DEVELOPMENT_TEAM. Set the env var, or copy Config/Team.xcconfig.example to Config/Team.xcconfig and put your real 10-character Apple team id in it." >&2
    return 1
  fi
  if ! is_valid_team_id "$team"; then
    echo "error: DEVELOPMENT_TEAM '$team' is not a valid Apple team id (expected 10 characters, A-Z and 0-9)." >&2
    echo "  Copy Config/Team.xcconfig.example to Config/Team.xcconfig and replace the placeholder with your real team id." >&2
    return 1
  fi
  printf '%s\n' "$team"
}

# Return 0 only when candidate resolves to the public stable alias. Path.resolve
# covers a direct path, a symlink, and an alias through a symlinked parent.
is_stable_dmg_path() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

try:
    candidate = Path(sys.argv[1]).expanduser().resolve(strict=False)
    stable = Path(sys.argv[2]).expanduser().resolve(strict=False)
except OSError as error:
    print(f"error: cannot resolve DMG path: {error}", file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(0 if candidate == stable else 1)
PY
}

# A Developer-ID release must never carry the debug entitlement. Capture the
# command output before inspecting it so a codesign failure cannot be masked by
# a pipeline.
assert_no_get_task_allow() {
  local app="$1" entitlements
  if ! entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"; then
    echo "error: could not read entitlements from $app" >&2
    return 1
  fi
  if [[ -z "$entitlements" ]]; then
    echo "error: app reports no entitlements: $app" >&2
    return 1
  fi
  if grep -q get-task-allow <<<"$entitlements"; then
    echo "error: get-task-allow is present: $app" >&2
    return 1
  fi
}

# --- Sparkle EdDSA keys ----------------------------------------------------

# Public half (base64) of a Sparkle EdDSA seed file. Needs `cryptography` or
# PyNaCl; returns non-zero (with a reason on stderr) otherwise.
sparkle_public_key_from_seed_file() {
  python3 - "$1" <<'PY'
import base64, sys
try:
    seed = base64.b64decode(open(sys.argv[1]).read().strip())
except Exception as e:
    raise SystemExit(f"cannot read Sparkle seed file: {e}")
if len(seed) != 32:
    raise SystemExit(f"expected 32-byte Sparkle seed, got {len(seed)}")
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    pk = Ed25519PrivateKey.from_private_bytes(seed)
    pub = pk.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
except Exception:
    try:
        from nacl.signing import SigningKey
        pub = bytes(SigningKey(seed).verify_key)
    except Exception as e:
        raise SystemExit(
            "cannot derive SUPublicEDKey from private key file "
            f"(install cryptography or PyNaCl): {e}"
        )
print(base64.b64encode(pub).decode())
PY
}

# Public key held in the login Keychain under a Sparkle account. Prints it, or
# nothing when generate_keys is absent / the account has no key / it is
# unreadable. "generate_keys -p" may print prose; take the last base64 token.
sparkle_keychain_public_key() {
  local generate_keys="$1" account="$2" raw
  [[ -x "$generate_keys" ]] || return 0
  raw="$("$generate_keys" -p --account "$account" 2>/dev/null || true)"
  printf '%s' "$raw" | python3 -c 'import re,sys; t=sys.stdin.read(); ms=re.findall(r"[A-Za-z0-9+/]{40,}={0,2}", t); print(ms[-1] if ms else "")'
}

# Signing uses the seed FILE, so that file's public key is the source of truth.
#   <app_pub>       SUPublicEDKey baked into the app being shipped
#   <file_pub>      public half of SPARKLE_PRIVATE_KEY (the key that signs)
#   [keychain_pub]  Keychain key when readable; empty = not readable, skipped
# Any mismatch means the appcast would be signed with a key installed apps do
# not trust. Returns 0 only when everything present agrees.
check_sparkle_keys() {
  local app_pub="${1:-}" file_pub="${2:-}" keychain_pub="${3:-}"
  if [[ -z "$file_pub" ]]; then
    echo "error: could not derive the public key from SPARKLE_PRIVATE_KEY." >&2
    return 1
  fi
  if [[ -z "$app_pub" ]]; then
    echo "error: app has no SUPublicEDKey." >&2
    return 1
  fi
  if [[ "$app_pub" != "$file_pub" ]]; then
    echo "error: app SUPublicEDKey does not match the SPARKLE_PRIVATE_KEY file that signs the update." >&2
    echo "  app:  $app_pub" >&2
    echo "  file: $file_pub" >&2
    return 1
  fi
  if [[ -n "$keychain_pub" && "$keychain_pub" != "$file_pub" ]]; then
    echo "error: Keychain Sparkle key differs from the SPARKLE_PRIVATE_KEY file." >&2
    echo "  file:     $file_pub" >&2
    echo "  keychain: $keychain_pub" >&2
    echo "  Refusing to publish: fix whichever is stale so both name the same key." >&2
    return 1
  fi
  return 0
}

# --- Appcast backups -------------------------------------------------------

# Newest timestamped backup in <dir> (appcast.backup.<UTC-stamp>.xml sorts
# lexically == chronologically). Prints the path; returns 1 when none.
newest_appcast_backup() {
  local dir="$1" newest=""
  [[ -d "$dir" ]] || return 1
  newest="$(ls -1 "$dir" 2>/dev/null | grep -E '^appcast\.backup\.[0-9]{8}T[0-9]{6}Z\.xml$' | sort | tail -1 || true)"
  [[ -n "$newest" ]] || return 1
  printf '%s/%s\n' "$dir" "$newest"
}

# --- Release assets --------------------------------------------------------

# The URL curl_fresh actually requests: cache-busting nonce appended, respecting
# an existing query string.
cache_busted_url() {
  local url="$1" nonce="$2" sep="?"
  [[ "$url" == *\?* ]] && sep="&"
  printf '%s%scb=%s\n' "$url" "$sep" "$nonce"
}

# Fresh GET -L of a URL with cache busting (query nonce + no-cache) into <out>.
# Retries: a just-uploaded GitHub asset can 404 or serve stale bytes briefly.
# Usage: curl_fresh <label> <url> <out>; return 1 after 5 failed attempts.
curl_fresh() {
  local label="$1" url="$2" out="$3"
  local attempt=1 max=5
  while true; do
    if curl -sfL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        -o "$out" "$(cache_busted_url "$url" "$(date +%s)-${attempt}")" 2>/dev/null; then
      return 0
    fi
    if (( attempt >= max )); then
      echo "error: could not download ${label} after ${max} attempts: $url" >&2
      return 1
    fi
    echo "  ${label}: download attempt ${attempt}/${max} failed; retrying…" >&2
    sleep 3
    attempt=$((attempt + 1))
  done
}

# Reads asset names (one per line) on stdin. Returns 0 when any is a .dmg.
assets_include_dmg() {
  grep -qiE '\.dmg$'
}

# --- Process shutdown (install-local.sh) -----------------------------------

# True while <pid> exists and is not a zombie (a killed-but-unreaped child
# still answers kill -0).
pid_alive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$st" && "$st" != Z* ]]
}

# Poll a captured PID (never a `pgrep -f` loop — that matches its own command
# line and never drains). 0 = gone within <ticks> x 0.1s, 1 = still alive.
wait_for_pid_exit() {
  local pid="$1" ticks="${2:-50}" i
  for ((i = 0; i < ticks; i++)); do
    pid_alive "$pid" || return 0
    sleep 0.1
  done
  ! pid_alive "$pid"
}

# SIGTERM a captured PID and wait for it. 0 = exited, 1 = survived SIGTERM.
sigterm_and_wait() {
  local pid="$1" ticks="${2:-50}"
  pid_alive "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_pid_exit "$pid" "$ticks"
}
