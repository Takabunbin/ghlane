#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CORE="${CORE:-$ROOT/ghlane}"
PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ghlane-registry.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

mkdir -p "$TMP/bin" "$TMP/cache"
ln -s "$CORE" "$TMP/bin/curl"

LOG="$TMP/backend.log"
STATIC="$TMP/static.txt"
CONF="$TMP/ghlane.conf"
URL='https://github.com/o/r/releases/download/v1/app.bin'

cat >"$TMP/fake-curl" <<'FAKE'
#!/usr/bin/env bash
set -u

: "${FAKE_LOG:?}"
target=""
out=""
probe=0
next_out=0

for arg in "$@"; do
  [[ "$arg" == *'%{speed_download}'* ]] && probe=1
  if (( next_out )); then
    out="$arg"
    next_out=0
    continue
  fi
  case "$arg" in
    -o|--output) next_out=1 ;;
    --output=*) out="${arg#--output=}" ;;
    http://*|https://*) target="$arg" ;;
  esac
done

printf '%s\t%s\n' "$probe" "$target" >>"$FAKE_LOG"

if [[ "$target" == 'https://registry.example/mirrors.txt' ]]; then
  case "${REGISTRY_MODE:-good}" in
    good) printf 'https://fast.example\n' >"$out"; exit 0 ;;
    invalid) printf 'http://insecure.example\n' >"$out"; exit 0 ;;
    too-many)
      for i in $(seq 1 9); do printf 'https://m%s.example\n' "$i"; done >"$out"
      exit 0
      ;;
    fail) exit 28 ;;
  esac
fi

if (( probe )); then
  speed=0
  case "$target" in
    https://fast.example/*) speed=5000000 ;;
    https://slow.example/*) speed=300000 ;;
    https://github.com/*) speed=100000 ;;
    *) exit 7 ;;
  esac
  printf '%s|application/octet-stream|206|262144' "$speed"
  exit 0
fi

host="${target#https://}"
host="${host%%/*}"
if [[ -n "${FINAL_FAIL_HOST:-}" && "$host" == "$FINAL_FAIL_HOST" ]]; then
  exit 22
fi

[[ -n "$out" ]] && printf 'OK' >"$out" || printf 'OK'
FAKE
chmod +x "$TMP/fake-curl"

cat >"$CONF" <<EOF
REAL_CURL='$TMP/fake-curl'
REAL_WGET='/usr/bin/wget'
MIRROR_FILE='$STATIC'
BEST_TTL='3600'
SAMPLE_BYTES='262143'
RACE_TIMEOUT='2'
REGISTRY_URL='https://registry.example/mirrors.txt'
REGISTRY_TTL='86400'
REGISTRY_MAX='8'
REGISTRY_TIMEOUT='5'
EOF

run_curl() {
  env GHLANE_CONFIG="$CONF" GHLANE_CACHE_DIR="$TMP/cache" \
    FAKE_LOG="$LOG" REGISTRY_MODE="${REGISTRY_MODE:-good}" \
    FINAL_FAIL_HOST="${FINAL_FAIL_HOST:-}" \
    "$TMP/bin/curl" "$@"
}

reset() {
  : >"$LOG"
  rm -rf "$TMP/cache"
  mkdir -p "$TMP/cache"
  printf 'https://slow.example\n' >"$STATIC"
  unset REGISTRY_MODE FINAL_FAIL_HOST
}

route() {
  awk '{print $2}' "$TMP/cache/best" 2>/dev/null || true
}

printf '========================================\n'
printf ' ghlane remote registry\n'
printf '========================================\n'

reset
REGISTRY_MODE=good
run_curl "$URL" -o "$TMP/a" >/dev/null 2>&1
if [[ "$(route)" == 'https://fast.example' &&
      "$(cat "$TMP/cache/registry" 2>/dev/null)" == 'https://fast.example' &&
      -s "$TMP/cache/registry.stamp" ]]; then
  pass 'cold start fetches registry and selects remote mirror'
else
  fail 'cold start fetches registry and selects remote mirror'
fi

reset
REGISTRY_MODE=fail
run_curl "$URL" -o "$TMP/b" >/dev/null 2>&1
if [[ "$(route)" == 'https://slow.example' ]]; then
  pass 'registry fetch failure falls back to installed mirrors'
else
  fail 'registry fetch failure falls back to installed mirrors'
fi

reset
REGISTRY_MODE=invalid
run_curl "$URL" -o "$TMP/c" >/dev/null 2>&1
if [[ "$(route)" == 'https://slow.example' && ! -e "$TMP/cache/registry" ]]; then
  pass 'invalid registry is rejected'
else
  fail 'invalid registry is rejected'
fi

reset
REGISTRY_MODE=too-many
run_curl "$URL" -o "$TMP/d" >/dev/null 2>&1
if [[ "$(route)" == 'https://slow.example' && ! -e "$TMP/cache/registry" ]]; then
  pass 'oversized mirror set is rejected'
else
  fail 'oversized mirror set is rejected'
fi

reset
printf 'https://fast.example\n' >"$TMP/cache/registry"
printf '%s\n' "$(date +%s)" >"$TMP/cache/registry.stamp"
REGISTRY_MODE=fail
run_curl "$URL" -o "$TMP/e" >/dev/null 2>&1
registry_calls=$(awk -F '\t' '$2=="https://registry.example/mirrors.txt"{n++} END{print n+0}' "$LOG")
if [[ "$(route)" == 'https://fast.example' && "$registry_calls" -eq 0 ]]; then
  pass 'fresh registry cache avoids network refresh'
else
  fail 'fresh registry cache avoids network refresh'
fi

reset
printf 'https://slow.example\n' >"$TMP/cache/registry"
printf '%s\n' "$(( $(date +%s) - 90000 ))" >"$TMP/cache/registry.stamp"
REGISTRY_MODE=good
run_curl "$URL" -o "$TMP/f" >/dev/null 2>&1
if [[ "$(route)" == 'https://fast.example' ]]; then
  pass 'stale registry refreshes before racing'
else
  fail 'stale registry refreshes before racing'
fi

reset
REGISTRY_MODE=good
env GHLANE_CONFIG="$CONF" GHLANE_CACHE_DIR="$TMP/cache" \
  FAKE_LOG="$LOG" REGISTRY_MODE=good "$CORE" refresh >/dev/null 2>&1
if [[ "$(cat "$TMP/cache/registry" 2>/dev/null)" == 'https://fast.example' &&
      -s "$TMP/cache/registry.stamp" ]]; then
  pass 'manual refresh updates registry'
else
  fail 'manual refresh updates registry'
fi

reset
printf 'https://fast.example\n' >"$TMP/cache/registry"
printf '%s\n' "$(date +%s)" >"$TMP/cache/registry.stamp"
printf '%s %s\n' "$(date +%s)" 'https://fast.example' >"$TMP/cache/best"
FINAL_FAIL_HOST=fast.example
set +e
run_curl "$URL" -o "$TMP/g" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 22 && ! -e "$TMP/cache/best" && ! -e "$TMP/cache/registry.stamp" &&
      -e "$TMP/cache/registry" ]]; then
  pass 'route failure schedules registry refresh without deleting stale fallback'
else
  fail 'route failure schedules registry refresh without deleting stale fallback'
fi

printf '========================================\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
exit "$(( FAIL > 0 ? 1 : 0 ))"
