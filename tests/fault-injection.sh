#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)
CORE="${CORE:-${ROOT}/ghlane}"
[[ -x "$CORE" ]] || CORE="${CORE_FALLBACK:-/usr/local/libexec/ghlane}"

if [[ ! -x "$CORE" ]]; then
  echo "fault-injection: ghlane core not found (set CORE=/path/to/ghlane)" >&2
  exit 2
fi

PASS=0
FAIL=0
GAP=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ghlane-fault.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
gap()  { GAP=$((GAP + 1));  printf 'GAP   %s\n' "$1"; }

mkdir -p "$TMP/bin" "$TMP/cache"
ln -s "$CORE" "$TMP/bin/curl"
ln -s "$CORE" "$TMP/bin/wget"

LOG="$TMP/backend.log"
MIRRORS="$TMP/mirrors.txt"
CONF="$TMP/ghlane.conf"

cat >"$TMP/fake-curl" <<'FAKECURL'
#!/usr/bin/env bash
set -u

: "${FAKE_LOG:?}"

probe=0
target=""
out=""
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
    --url=*) target="${arg#--url=}" ;;
    http://*|https://*) target="$arg" ;;
  esac
done

printf '%s\t%s\t%s\n' "$$" "$probe" "$target" >>"$FAKE_LOG"

if (( probe )); then
  speed=0
  ctype='application/octet-stream'
  code=206
  bytes=1048576
  rc=0

  case "$target" in
    https://fast.example/*) speed=5000000 ;;
    https://good.example/*) speed=1000000 ;;
    https://slow.example/*) speed=300000 ;;
    https://html.example/*) speed=9000000; ctype='text/html' ;;
    https://octet-html.example/*) speed=9000000 ;;
    https://zero.example/*) speed=9000000; bytes=0 ;;
    https://403.example/*) speed=9000000; code=403; rc=22 ;;
    https://404.example/*) speed=9000000; code=404; rc=22 ;;
    https://429.example/*) speed=9000000; code=429; rc=22 ;;
    https://500.example/*) speed=9000000; code=500; rc=22 ;;
    https://502.example/*) speed=9000000; code=502; rc=22 ;;
    https://503.example/*) speed=9000000; code=503; rc=22 ;;
    https://dns.example/*) speed=9000000; rc=6 ;;
    https://refused.example/*) speed=9000000; rc=7 ;;
    https://partial.example/*) speed=9000000; bytes=500000; rc=18 ;;
    https://timeout.example/*) speed=250000; bytes=500000; rc=28 ;;
    https://toolarge.example/*) speed=99999999; bytes=1048577; rc=63 ;;
    https://badbin.example/*) speed=99999999 ;;
    https://github.com/*)
      if [[ "${DIRECT_PROBE_FAIL:-0}" == 1 ]]; then
        speed=0
        rc=28
      else
        speed=100000
      fi
      ;;
    *) speed=0; rc=7 ;;
  esac

  printf '%s|%s|%s|%s' "$speed" "$ctype" "$code" "$bytes"
  exit "$rc"
fi

host="${target#https://}"
host="${host%%/*}"

if [[ -n "${FINAL_FAIL_HOST:-}" && "$host" == "$FINAL_FAIL_HOST" ]]; then
  if [[ "${FINAL_PARTIAL:-0}" == 1 && -n "$out" ]]; then
    printf 'PARTIAL' >"$out"
  fi
  exit "${FINAL_FAIL_CODE:-22}"
fi

if [[ -n "$out" && "$out" != /dev/null ]]; then
  printf 'OK' >"$out"
else
  printf 'OK'
fi
FAKECURL
chmod +x "$TMP/fake-curl"

cat >"$TMP/fake-wget" <<'FAKEWGET'
#!/usr/bin/env bash
set -u
: "${FAKE_LOG:?}"

target=""
out=""
next_out=0
for arg in "$@"; do
  if (( next_out )); then
    out="$arg"
    next_out=0
    continue
  fi
  case "$arg" in
    -O|--output-document) next_out=1 ;;
    --output-document=*) out="${arg#--output-document=}" ;;
    http://*|https://*) target="$arg" ;;
  esac
done

printf 'WGET\t%s\t%s\n' "$$" "$target" >>"$FAKE_LOG"

host="${target#https://}"
host="${host%%/*}"
if [[ -n "${FINAL_FAIL_HOST:-}" && "$host" == "$FINAL_FAIL_HOST" ]]; then
  [[ "${FINAL_PARTIAL:-0}" == 1 && -n "$out" ]] && printf 'PARTIAL' >"$out"
  exit "${FINAL_FAIL_CODE:-8}"
fi

[[ -n "$out" ]] && printf 'OK' >"$out" || printf 'OK'
FAKEWGET
chmod +x "$TMP/fake-wget"

write_conf() {
  cat >"$CONF" <<EOF
REAL_CURL='$TMP/fake-curl'
REAL_WGET='$TMP/fake-wget'
MIRROR_FILE='$MIRRORS'
BEST_TTL='3600'
SAMPLE_BYTES='262143'
RACE_TIMEOUT='2'
EOF
}

reset() {
  : >"$LOG"
  rm -rf "$TMP/cache"
  mkdir -p "$TMP/cache"
  write_conf
  unset DIRECT_PROBE_FAIL FINAL_FAIL_HOST FINAL_FAIL_CODE FINAL_PARTIAL
}

run_curl() {
  env     GHLANE_CONFIG="$CONF"     GHLANE_CACHE_DIR="$TMP/cache"     FAKE_LOG="$LOG"     DIRECT_PROBE_FAIL="${DIRECT_PROBE_FAIL:-0}"     FINAL_FAIL_HOST="${FINAL_FAIL_HOST:-}"     FINAL_FAIL_CODE="${FINAL_FAIL_CODE:-22}"     FINAL_PARTIAL="${FINAL_PARTIAL:-0}"     "$TMP/bin/curl" "$@"
}

run_wget() {
  env     GHLANE_CONFIG="$CONF"     GHLANE_CACHE_DIR="$TMP/cache"     FAKE_LOG="$LOG"     FINAL_FAIL_HOST="${FINAL_FAIL_HOST:-}"     FINAL_FAIL_CODE="${FINAL_FAIL_CODE:-8}"     FINAL_PARTIAL="${FINAL_PARTIAL:-0}"     "$TMP/bin/wget" "$@"
}

URL='https://github.com/o/r/releases/download/v1/app.bin'

cached_route() {
  awk '{print $2}' "$TMP/cache/best" 2>/dev/null || true
}

expect_route() {
  local name="$1" expected="$2"
  if [[ "$(cached_route)" == "$expected" ]]; then pass "$name"; else fail "$name"; fi
}

expect_probe_rejected() {
  local name="$1" bad="$2"
  reset
  printf '%s\n%s\n' "$bad" 'https://good.example' >"$MIRRORS"
  run_curl -fsSL "$URL" -o "$TMP/out" >/dev/null 2>&1 || true
  expect_route "$name" 'https://good.example'
}

printf '========================================\n'
printf ' ghlane reliability / fault injection\n'
printf ' core: %s\n' "$("$CORE" version 2>/dev/null || printf unknown)"
printf '========================================\n'

printf '\n--- A. probe failure rejection ---\n'
expect_probe_rejected 'HTTP 403 probe rejected' 'https://403.example'
expect_probe_rejected 'HTTP 404 probe rejected' 'https://404.example'
expect_probe_rejected 'HTTP 429 probe rejected' 'https://429.example'
expect_probe_rejected 'HTTP 500 probe rejected' 'https://500.example'
expect_probe_rejected 'HTTP 502 probe rejected' 'https://502.example'
expect_probe_rejected 'HTTP 503 probe rejected' 'https://503.example'
expect_probe_rejected 'DNS failure (curl 6) rejected' 'https://dns.example'
expect_probe_rejected 'connection refused (curl 7) rejected' 'https://refused.example'
expect_probe_rejected 'partial transfer (curl 18) rejected' 'https://partial.example'
expect_probe_rejected 'timed partial sample cannot beat a faster completed probe' 'https://timeout.example'
expect_probe_rejected 'oversized/range-ignored probe rejected' 'https://toolarge.example'
expect_probe_rejected 'HTML 200 probe rejected' 'https://html.example'
expect_probe_rejected 'zero-byte probe rejected' 'https://zero.example'

printf '\n--- B. selection / fallback ---\n'
reset
printf '%s\n%s\n' 'https://slow.example' 'https://fast.example' >"$MIRRORS"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
expect_route 'fastest completed probe wins' 'https://fast.example'

reset
: >"$MIRRORS"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
expect_route 'empty mirror list still allows DIRECT' 'DIRECT'

reset
printf '%s\n' 'https://timeout.example' >"$MIRRORS"
DIRECT_PROBE_FAIL=1
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1 || true
expect_route 'timed partial sample is usable when faster routes are unavailable' 'https://timeout.example'

reset
printf '%s\n' 'https://dns.example' >"$MIRRORS"
DIRECT_PROBE_FAIL=1
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1 || true
expect_route 'all real probe failures -> DIRECT fallback' 'DIRECT'

reset
printf '\n# comment\nhttp://insecure.example\nnot-a-url\nhttps://good.example\n' >"$MIRRORS"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
expect_route 'blank/comment/non-HTTPS entries do not break selection' 'https://good.example'

reset
printf '%s\n%s\n' 'https://fast.example' 'https://fast.example' >"$MIRRORS"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
expect_route 'duplicate mirror entries do not break selection' 'https://fast.example'

printf '\n--- C. cache corruption / persistence ---\n'
reset
printf '%s\n' 'https://good.example' >"$MIRRORS"
: >"$TMP/cache/best"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
expect_route 'empty cache file is recovered' 'https://good.example'

reset
printf '%s\n' 'https://good.example' >"$MIRRORS"
printf 'garbage https://good.example\n' >"$TMP/cache/best"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>"$TMP/err"
rc=$?
if [[ $rc -eq 0 && "$(cached_route)" == 'https://good.example' ]]; then
  pass 'malformed cache timestamp is recovered'
else
  fail 'malformed cache timestamp is recovered'
fi

reset
printf '%s\n' 'https://good.example' >"$MIRRORS"
printf '%s %s\n' "$(( $(date +%s) - 7200 ))" 'https://slow.example' >"$TMP/cache/best"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
expect_route 'expired cache is ignored' 'https://good.example'

reset
printf '%s\n' 'https://good.example' >"$MIRRORS"
printf '%s %s\n' "$(date +%s)" 'https://removed.example' >"$TMP/cache/best"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
expect_route 'cached mirror removed from registry is ignored' 'https://good.example'

reset
printf '%s\n%s\n' 'https://good.example' 'https://slow.example' >"$MIRRORS"
future=$(( $(date +%s) + 86400 ))
printf '%s %s\n' "$future" 'https://slow.example' >"$TMP/cache/best"
run_curl "$URL" -o "$TMP/out" >/dev/null 2>&1
if [[ "$(cached_route)" == 'https://slow.example' ]]; then
  fail 'future cache timestamp is rejected'
else
  pass 'future cache timestamp is rejected'
fi

printf '\n--- D. final-transfer failures ---\n'
reset
printf '%s\n%s\n' 'https://fast.example' 'https://good.example' >"$MIRRORS"
printf '%s %s\n' "$(date +%s)" 'https://fast.example' >"$TMP/cache/best"
FINAL_FAIL_HOST='fast.example'
FINAL_FAIL_CODE=22
set +e
run_curl "$URL" -o "$TMP/final-403" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 22 && ! -e "$TMP/cache/best" ]]; then
  pass 'cached mirror HTTP failure clears route cache'
else
  fail 'cached mirror HTTP failure clears route cache'
fi
if [[ $rc -ne 0 ]]; then
  gap 'same request is not automatically retried on another route'
else
  pass 'same-request failover succeeds'
fi

reset
printf '%s\n' 'https://fast.example' >"$MIRRORS"
printf '%s %s\n' "$(date +%s)" 'https://fast.example' >"$TMP/cache/best"
FINAL_FAIL_HOST='fast.example'
FINAL_FAIL_CODE=28
set +e
run_curl "$URL" -o "$TMP/final-timeout" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 28 && ! -e "$TMP/cache/best" ]]; then
  pass 'final timeout clears route cache'
else
  fail 'final timeout clears route cache'
fi

reset
printf '%s\n' 'https://fast.example' >"$MIRRORS"
printf '%s %s\n' "$(date +%s)" 'https://fast.example' >"$TMP/cache/best"
FINAL_FAIL_HOST='fast.example'
FINAL_FAIL_CODE=18
FINAL_PARTIAL=1
set +e
run_curl "$URL" -o "$TMP/partial.out" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 18 && -s "$TMP/partial.out" && ! -e "$TMP/cache/best" ]]; then
  pass 'mid-stream failure returns error and clears cache'
else
  fail 'mid-stream failure returns error and clears cache'
fi
gap 'mid-stream transparent failover is unsafe without buffering/resume semantics'

printf '\n--- E. cache/TMP degradation ---\n'
reset
printf '%s\n' 'https://good.example' >"$MIRRORS"
set +e
env   GHLANE_CONFIG="$CONF"   GHLANE_CACHE_DIR="/proc/ghlane-cache-$$"   FAKE_LOG="$LOG"   "$TMP/bin/curl" "$URL" -o "$TMP/no-cache.out" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then pass 'unwritable cache directory does not block download'; else fail 'unwritable cache directory does not block download'; fi

reset
printf '%s\n' 'https://good.example' >"$MIRRORS"
set +e
env   TMPDIR="/proc/ghlane-tmp-$$"   GHLANE_CONFIG="$CONF"   GHLANE_CACHE_DIR="$TMP/cache"   FAKE_LOG="$LOG"   "$TMP/bin/curl" "$URL" -o "$TMP/no-tmp.out" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 && "$(cached_route)" == 'DIRECT' ]]; then
  pass 'unusable TMPDIR safely falls back to DIRECT'
else
  fail 'unusable TMPDIR safely falls back to DIRECT'
fi

reset
printf '%s\n' 'https://good.example' >"$MIRRORS"
mkdir -p "$TMP/nohome"
set +e
env -u HOME -u XDG_CACHE_HOME -u GHLANE_CACHE_DIR   TMPDIR="$TMP/nohome"   GHLANE_CONFIG="$CONF"   FAKE_LOG="$LOG"   "$TMP/bin/curl" "$URL" -o "$TMP/nohome.out" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then pass 'HOME/XDG cache variables may be absent'; else fail 'HOME/XDG cache variables may be absent'; fi

printf '\n--- F. argument preservation ---\n'
arg_test() {
  local name="$1"
  shift
  reset
  printf '%s\n' 'https://fast.example' >"$MIRRORS"
  run_curl "$@" >/dev/null 2>&1
  if grep -Fq 'https://fast.example/https://github.com/o/r/releases/download/' "$LOG"; then
    pass "$name"
  else
    fail "$name"
  fi
}

arg_test 'curl --retry preserved' --retry 3 "$URL" -o "$TMP/a"
arg_test 'curl resume (-C -) preserved' -C - "$URL" -o "$TMP/a"
arg_test 'curl remote-name (-O) preserved' -O "$URL"
arg_test 'curl remote-header-name (-OJ) preserved' -OJ "$URL"
ENCODED='https://github.com/o/r/releases/download/v1/file%20name.bin'
arg_test 'percent-encoded Release URL preserved' "$ENCODED" -o "$TMP/a"

reset
printf '%s\n' 'https://fast.example' >"$MIRRORS"
out=$(run_curl "$URL" 2>/dev/null)
if [[ "$out" == 'OK' ]]; then pass 'stdout download remains usable'; else fail 'stdout download remains usable'; fi

printf '\n--- G. bundled short-option safety ---\n'
bundled_bypass() {
  local name="$1"
  shift
  reset
  printf '%s\n' 'https://fast.example' >"$MIRRORS"
  run_curl "$@" "$URL" -o "$TMP/a" >/dev/null 2>&1 || true
  probes=$(awk -F '\t' '$2=="1"{n++} END{print n+0}' "$LOG")
  if (( probes == 0 )); then
    pass "$name"
  else
    fail "$name"
  fi
}
bundled_bypass 'bundled curl -u auth bypasses routing' -fsSLuuser:pass
bundled_bypass 'bundled curl -b cookie bypasses routing' -fsSLbcookie=secret
bundled_bypass 'bundled curl -k TLS override bypasses routing' -fsSLk

printf '\n--- H. transport-option semantics ---\n'
transport_gap() {
  local name="$1"
  shift
  reset
  printf '%s\n' 'https://fast.example' >"$MIRRORS"
  run_curl "$@" "$URL" -o "$TMP/a" >/dev/null 2>&1 || true
  probes=$(awk -F '\t' '$2=="1"{n++} END{print n+0}' "$LOG")
  if (( probes > 0 )); then
    gap "$name affects final curl but is not applied to race probes"
  else
    pass "$name bypasses or is applied consistently"
  fi
}
transport_gap 'curl -4' -4
transport_gap 'curl -6' -6
transport_gap 'curl --proxy' --proxy http://proxy.invalid:8080
transport_gap 'curl --resolve' --resolve github.com:443:127.0.0.1
transport_gap 'curl --connect-to' --connect-to github.com:443:127.0.0.1:443
transport_gap 'curl --interface' --interface lo
transport_gap 'curl --insecure' --insecure
transport_gap 'curl --cacert' --cacert /tmp/nonexistent-ca

printf '\n--- I. implicit config-file safety ---\n'
reset
printf '%s\n' 'https://fast.example' >"$MIRRORS"
mkdir -p "$TMP/curlhome"
printf 'header = "Authorization: Bearer secret-from-curlrc"\n' >"$TMP/curlhome/.curlrc"
CURL_HOME="$TMP/curlhome" run_curl "$URL" -o "$TMP/a" >/dev/null 2>&1 || true
probes=$(awk -F '\t' '$2=="1"{n++} END{print n+0}' "$LOG")
if (( probes > 0 )); then
  gap 'implicit .curlrc is not inspected; real curl could add sensitive headers after routing'
else
  pass 'implicit .curlrc causes safe bypass'
fi

reset
printf '%s\n' 'https://fast.example' >"$MIRRORS"
printf 'header = Authorization: Bearer secret-from-wgetrc\n' >"$TMP/wgetrc"
WGETRC="$TMP/wgetrc" run_wget "$URL" -O "$TMP/w" >/dev/null 2>&1 || true
if grep -Fq 'https://fast.example/' "$LOG"; then
  gap 'WGETRC is not inspected before mirror routing'
else
  pass 'WGETRC causes safe bypass'
fi

printf '\n--- J. mirror trust / content correctness ---\n'
reset
printf '%s\n%s\n' 'https://badbin.example' 'https://good.example' >"$MIRRORS"
run_curl "$URL" -o "$TMP/badbin.out" >/dev/null 2>&1
if [[ "$(cached_route)" == 'https://badbin.example' ]]; then
  gap 'binary-looking wrong content can win; no end-to-end digest validation yet'
else
  pass 'wrong binary content is rejected'
fi

reset
printf '%s\r\n' 'https://fast.example' >"$MIRRORS"
run_curl "$URL" -o "$TMP/crlf.out" >/dev/null 2>&1
if [[ "$(cached_route)" == 'DIRECT' ]]; then
  gap 'CRLF mirror registry lines are not normalized'
else
  pass 'CRLF mirror registry is normalized'
fi

printf '\n--- K. concurrency ---\n'
reset
printf '%s\n%s\n' 'https://slow.example' 'https://fast.example' >"$MIRRORS"
pids=()
for i in $(seq 1 20); do
  run_curl "$URL" -o "$TMP/cold-$i" >/dev/null 2>&1 &
  pids+=("$!")
done
concurrent_ok=1
for p in "${pids[@]}"; do wait "$p" || concurrent_ok=0; done
if [[ $concurrent_ok -eq 1 && "$(cached_route)" == 'https://fast.example' ]]; then
  pass '20 concurrent cold starts leave a valid cache'
else
  fail '20 concurrent cold starts leave a valid cache'
fi
probe_count=$(awk -F '\t' '$2=="1"{n++} END{print n+0}' "$LOG")
if (( probe_count > 3 )); then
  gap 'cold-start stampede: concurrent processes independently race mirrors'
else
  pass 'cold-start race is coalesced'
fi

: >"$LOG"
pids=()
for i in $(seq 1 20); do
  run_curl "$URL" -o "$TMP/warm-$i" >/dev/null 2>&1 &
  pids+=("$!")
done
warm_ok=1
for p in "${pids[@]}"; do wait "$p" || warm_ok=0; done
probe_count=$(awk -F '\t' '$2=="1"{n++} END{print n+0}' "$LOG")
if [[ $warm_ok -eq 1 && $probe_count -eq 0 ]]; then
  pass '20 concurrent warm-cache downloads avoid re-racing'
else
  fail '20 concurrent warm-cache downloads avoid re-racing'
fi

printf '\n--- L. wget final failure ---\n'
reset
printf '%s\n' 'https://fast.example' >"$MIRRORS"
printf '%s %s\n' "$(date +%s)" 'https://fast.example' >"$TMP/cache/best"
FINAL_FAIL_HOST='fast.example'
FINAL_FAIL_CODE=8
set +e
run_wget "$URL" -O "$TMP/wget-fail" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 8 && ! -e "$TMP/cache/best" ]]; then
  pass 'wget failure clears route cache'
else
  fail 'wget failure clears route cache'
fi
gap 'wget same-request failover is not implemented'

printf '\n========================================\n'
printf ' summary\n'
printf '========================================\n'
printf 'PASS=%d  FAIL=%d  GAP=%d\n' "$PASS" "$FAIL" "$GAP"
printf 'GAP = known hardening/feature gap, not a regression in the current V0.1 contract.\n'

exit "$(( FAIL > 0 ? 1 : 0 ))"
