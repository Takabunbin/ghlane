#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILDER="$ROOT/scripts/build-registry.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ghlane-health-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

cat >"$TMP/fake-curl" <<'FAKE'
#!/usr/bin/env bash
set -u

out=""
write_stats=0
target=""
next_out=0

for arg in "$@"; do
  if (( next_out )); then
    out="$arg"
    next_out=0
    continue
  fi
  case "$arg" in
    -o|--output) next_out=1 ;;
    --output=*) out="${arg#--output=}" ;;
    -w|--write-out) write_stats=1 ;;
    http://*|https://*) target="$arg" ;;
  esac
done

write_sample() {
  local ch="$1"
  yes "$ch" | tr -d '\n' | head -c 32768 >"$out"
}

case "$target" in
  https://github.com/*)
    write_sample A
    exit 0
    ;;
  https://good1.example/*|https://good2.example/*)
    write_sample A
    (( write_stats )) && printf '206|application/octet-stream|32768|100000'
    exit 0
    ;;
  https://bad.example/*)
    write_sample B
    (( write_stats )) && printf '206|application/octet-stream|32768|900000'
    exit 0
    ;;
  https://dead.example/*)
    (( write_stats )) && printf '000||0|0'
    exit 7
    ;;
  *)
    exit 7
    ;;
esac
FAKE
chmod +x "$TMP/fake-curl"

printf '%s\n'   'https://good1.example'   'https://bad.example'   'http://invalid.example'   'https://dead.example'   'https://good2.example' >"$TMP/source.txt"

if CURL_BIN="$TMP/fake-curl"    SOURCE_FILE="$TMP/source.txt"    OUTPUT_FILE="$TMP/registry.txt"    MIN_HEALTHY=2    bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(cat "$TMP/registry.txt")" == $'https://good1.example\nhttps://good2.example' ]]
then
  pass 'healthy mirrors kept in source order; bad content/dead/invalid rejected'
else
  fail 'healthy mirrors kept in source order; bad content/dead/invalid rejected'
fi

printf 'https://good1.example\n' >"$TMP/too-few.txt"
printf 'https://old.example\n' >"$TMP/existing.txt"

set +e
CURL_BIN="$TMP/fake-curl" SOURCE_FILE="$TMP/too-few.txt" OUTPUT_FILE="$TMP/existing.txt" MIN_HEALTHY=2 bash "$BUILDER" >/dev/null 2>&1
rc=$?
set -e

if [[ "$rc" -ne 0 && "$(cat "$TMP/existing.txt")" == 'https://old.example' ]]; then
  pass 'health-floor failure keeps existing registry untouched'
else
  fail 'health-floor failure keeps existing registry untouched'
fi

printf '%s\n'   'https://good1.example'   'https://good2.example' >"$TMP/cap.txt"

if CURL_BIN="$TMP/fake-curl"    SOURCE_FILE="$TMP/cap.txt"    OUTPUT_FILE="$TMP/capped.txt"    MIN_HEALTHY=1    MAX_MIRRORS=1    bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(cat "$TMP/capped.txt")" == 'https://good1.example' ]]
then
  pass 'registry size cap is enforced'
else
  fail 'registry size cap is enforced'
fi

printf '========================================\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
exit "$(( FAIL > 0 ? 1 : 0 ))"
