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
  https://good*.example/*)
    write_sample A
    (( write_stats )) && printf '206|application/octet-stream|32768|100000'
    exit 0
    ;;
  https://bad.example/*)
    write_sample B
    (( write_stats )) && printf '206|application/octet-stream|32768|900000'
    exit 0
    ;;
  https://dead.example/*|https://newdead.example/*)
    (( write_stats )) && printf '000||0|0'
    exit 7
    ;;
  *)
    exit 7
    ;;
esac
FAKE
chmod +x "$TMP/fake-curl"

printf '%s\n' \
  'https://good1.example' \
  'https://bad.example' \
  'https://dead.example' \
  'http://invalid.example' \
  'https://good2.example' >"$TMP/source.txt"

printf '%s\n' \
  '# ghlane-registry-v1' \
  'https://bad.example' \
  'https://dead.example' >"$TMP/previous.txt"

if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/source.txt" \
   PREVIOUS_FILE="$TMP/previous.txt" \
   OUTPUT_FILE="$TMP/registry-v1.txt" \
   LEGACY_OUTPUT_FILE="$TMP/registry.txt" \
   bash "$BUILDER" >/dev/null 2>&1
then
  expected=$'# ghlane-registry-v1\nhttps://good1.example\nhttps://dead.example\nhttps://good2.example'
  legacy=$'https://good1.example\nhttps://dead.example\nhttps://good2.example'
  if [[ "$(cat "$TMP/registry-v1.txt")" == "$expected" &&
        "$(cat "$TMP/registry.txt")" == "$legacy" ]]; then
    pass 'verified mirrors publish; runner-only failure may retain; mismatch/invalid are rejected'
  else
    fail 'verified mirrors publish; runner-only failure may retain; mismatch/invalid are rejected'
  fi
else
  fail 'verified mirrors publish; runner-only failure may retain; mismatch/invalid are rejected'
fi

printf 'https://newdead.example\n' >"$TMP/newdead.txt"
printf '# ghlane-registry-v1\n' >"$TMP/empty-previous.txt"
if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/newdead.txt" \
   PREVIOUS_FILE="$TMP/empty-previous.txt" \
   OUTPUT_FILE="$TMP/newdead-registry.txt" \
   bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(cat "$TMP/newdead-registry.txt")" == '# ghlane-registry-v1' ]]
then
  pass 'new runner-unreachable endpoint is not promoted'
else
  fail 'new runner-unreachable endpoint is not promoted'
fi

printf '%s\n' 'https://bad.example' >"$TMP/bad-only.txt"
if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/bad-only.txt" \
   PREVIOUS_FILE="$TMP/previous.txt" \
   OUTPUT_FILE="$TMP/bad-only-registry.txt" \
   bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(cat "$TMP/bad-only-registry.txt")" == '# ghlane-registry-v1' ]]
then
  pass 'content mismatch is never retained from previous registry'
else
  fail 'content mismatch is never retained from previous registry'
fi

printf '%s\n' 'https://good1.example' 'https://good2.example' >"$TMP/cap.txt"
if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/cap.txt" \
   PREVIOUS_FILE="$TMP/empty-previous.txt" \
   OUTPUT_FILE="$TMP/capped.txt" \
   MAX_MIRRORS=1 \
   bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(grep -c '^https://' "$TMP/capped.txt")" -eq 1 ]]
then
  pass 'production registry cap is enforced'
else
  fail 'production registry cap is enforced'
fi

printf '========================================\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
exit "$(( FAIL > 0 ? 1 : 0 ))"
