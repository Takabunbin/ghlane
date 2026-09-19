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

if [[ "$target" == 'https://api.github.com/repos/o/r/releases/tags/v1' ]]; then
  cat >"$out" <<'JSON'
{"assets":[{"name":"app.bin","browser_download_url":"https://github.com/o/r/releases/download/v1/app.bin","size":2,"digest":"sha256:565339bc4d33d72817b583024112eb7f5cdf3e5eef0252d6ec1b9c9a94e12bb3"}]}
JSON
  exit 0
fi

if [[ "$target" == 'https://registry.example/registry-v1.txt' ]]; then
  case "${REGISTRY_MODE:-good}" in
    good)
      printf '# ghlane-registry-v1\nhttps://fast.example\n' >"$out"
      exit 0
      ;;
    empty)
      printf '# ghlane-registry-v1\n' >"$out"
      exit 0
      ;;
    bad-header)
      printf 'https://fast.example\n' >"$out"
      exit 0
      ;;
    invalid)
      printf '# ghlane-registry-v1\nhttp://insecure.example\n' >"$out"
      exit 0
      ;;
    too-many)
      printf '# ghlane-registry-v1\n' >"$out"
      for i in $(seq 1 9); do printf 'https://m%s.example\n' "$i"; done >>"$out"
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
  exit "${FINAL_FAIL_CODE:-22}"
fi

[[ -n "$out" ]] && printf 'OK' >"$out" || printf 'OK'
FAKE
chmod +x "$TMP/fake-curl"

write_conf() {
  local registry="${1-https://registry.example/registry-v1.txt}"
  cat >"$CONF" <<EOF
REAL_CURL='$TMP/fake-curl'
REAL_WGET='/usr/bin/wget'
MIRROR_FILE='$STATIC'
BEST_TTL='3600'
SAMPLE_BYTES='262143'
RACE_TIMEOUT='2'
REGISTRY_URL='$registry'
REGISTRY_TTL='86400'
REGISTRY_MAX='8'
REGISTRY_TIMEOUT='5'
EOF
}

run_curl() {
  env GHLANE_CONFIG="$CONF" GHLANE_CACHE_DIR="$TMP/cache" \
    FAKE_LOG="$LOG" REGISTRY_MODE="${REGISTRY_MODE:-good}" \
    FINAL_FAIL_HOST="${FINAL_FAIL_HOST:-}" FINAL_FAIL_CODE="${FINAL_FAIL_CODE:-22}" \
    "$TMP/bin/curl" "$@"
}

reset() {
  : >"$LOG"
  rm -rf "$TMP/cache"
  mkdir -p "$TMP/cache"
  printf 'https://slow.example\n' >"$STATIC"
  write_conf
  unset REGISTRY_MODE FINAL_FAIL_HOST FINAL_FAIL_CODE
}

route() {
  awk '{print $2}' "$TMP/cache/best" 2>/dev/null || true
}

printf '========================================\n'
printf ' ghlane registry-v1 lifecycle\n'
printf '========================================\n'

reset
REGISTRY_MODE=good
run_curl "$URL" -o "$TMP/a" >/dev/null 2>&1
if [[ "$(route)" == 'https://fast.example' &&
      "$(grep '^https://' "$TMP/cache/registry")" == 'https://fast.example' &&
      -s "$TMP/cache/registry.stamp" ]]; then
  pass 'cold start fetches versioned registry and selects remote mirror'
else
  fail 'cold start fetches versioned registry and selects remote mirror'
fi

reset
REGISTRY_MODE=fail
run_curl "$URL" -o "$TMP/b" >/dev/null 2>&1
[[ "$(route)" == 'https://slow.example' ]] &&
  pass 'registry fetch failure falls back to installed mirrors' ||
  fail 'registry fetch failure falls back to installed mirrors'

for mode in bad-header invalid too-many; do
  reset
  REGISTRY_MODE="$mode"
  run_curl "$URL" -o "$TMP/$mode" >/dev/null 2>&1
  if [[ "$(route)" == 'https://slow.example' && ! -e "$TMP/cache/registry" ]]; then
    pass "$mode registry is rejected"
  else
    fail "$mode registry is rejected"
  fi
done

reset
REGISTRY_MODE=empty
run_curl "$URL" -o "$TMP/empty" >/dev/null 2>&1
if [[ "$(route)" == 'DIRECT' && -s "$TMP/cache/registry" ]]; then
  pass 'valid empty registry means DIRECT-only, not installed fallback'
else
  fail 'valid empty registry means DIRECT-only, not installed fallback'
fi

reset
printf '# ghlane-registry-v1\nhttps://fast.example\n' >"$TMP/cache/registry"
printf '%s\n' "$(date +%s)" >"$TMP/cache/registry.stamp"
REGISTRY_MODE=fail
run_curl "$URL" -o "$TMP/fresh" >/dev/null 2>&1
registry_calls=$(awk -F '\t' '$2=="https://registry.example/registry-v1.txt"{n++} END{print n+0}' "$LOG")
if [[ "$(route)" == 'https://fast.example' && "$registry_calls" -eq 0 ]]; then
  pass 'fresh registry cache avoids network refresh'
else
  fail 'fresh registry cache avoids network refresh'
fi

reset
printf '# ghlane-registry-v1\nhttps://slow.example\n' >"$TMP/cache/registry"
printf '%s\n' "$(( $(date +%s) - 90000 ))" >"$TMP/cache/registry.stamp"
REGISTRY_MODE=good
run_curl "$URL" -o "$TMP/stale" >/dev/null 2>&1
[[ "$(route)" == 'https://fast.example' ]] &&
  pass 'stale registry refreshes before racing' ||
  fail 'stale registry refreshes before racing'

reset
REGISTRY_MODE=good
env GHLANE_CONFIG="$CONF" GHLANE_CACHE_DIR="$TMP/cache" \
  FAKE_LOG="$LOG" REGISTRY_MODE=good "$CORE" refresh >/dev/null 2>&1
if [[ "$(grep '^https://' "$TMP/cache/registry")" == 'https://fast.example' &&
      -s "$TMP/cache/registry.stamp" ]]; then
  pass 'manual refresh updates versioned registry'
else
  fail 'manual refresh updates versioned registry'
fi

reset
write_conf ''
run_curl "$URL" -o "$TMP/disabled" >/dev/null 2>&1
registry_calls=$(awk -F '\t' '$2=="https://registry.example/registry-v1.txt"{n++} END{print n+0}' "$LOG")
if [[ "$(route)" == 'https://slow.example' && "$registry_calls" -eq 0 ]]; then
  pass 'explicit empty REGISTRY_URL disables remote registry'
else
  fail 'explicit empty REGISTRY_URL disables remote registry'
fi

reset
printf '# ghlane-registry-v1\nhttps://fast.example\n' >"$TMP/cache/registry"
printf '%s\n' "$(date +%s)" >"$TMP/cache/registry.stamp"
printf '%s %s\n' "$(date +%s)" 'https://fast.example' >"$TMP/cache/best"
FINAL_FAIL_HOST=fast.example
FINAL_FAIL_CODE=22
set +e
run_curl "$URL" -o "$TMP/http-fail" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 && "$(cat "$TMP/http-fail" 2>/dev/null)" == 'OK' &&
      ! -e "$TMP/cache/best" && ! -e "$TMP/cache/registry.stamp" &&
      -e "$TMP/cache/registry" ]]; then
  pass 'mirror HTTP failure retries DIRECT and schedules registry refresh'
else
  fail 'mirror HTTP failure retries DIRECT and schedules registry refresh'
fi

printf '========================================\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
exit "$(( FAIL > 0 ? 1 : 0 ))"
