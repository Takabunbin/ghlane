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
  'https://dead.example' \
  'https://bad.example' >"$TMP/stable.txt"

printf '%s\n' \
  'https://good1.example' \
  'https://dead.example' \
  'https://bad.example' \
  'https://good2.example' \
  'https://good3.example' \
  'https://good4.example' \
  'https://good5.example' >"$TMP/source.txt"

printf '%s\n' \
  '# ghlane-registry-v1' \
  'https://good1.example' \
  'https://dead.example' \
  'https://good3.example' >"$TMP/previous-v1.txt"

printf '%s\n' \
  'https://good1.example' \
  'https://dead.example' >"$TMP/previous-legacy.txt"

if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/source.txt" \
   STABLE_FILE="$TMP/stable.txt" \
   PREVIOUS_FILE="$TMP/previous-v1.txt" \
   LEGACY_PREVIOUS_FILE="$TMP/previous-legacy.txt" \
   OUTPUT_FILE="$TMP/registry-v1.txt" \
   LEGACY_OUTPUT_FILE="$TMP/registry.txt" \
   MAX_MIRRORS=5 \
   STABLE_SLOTS=2 \
   bash "$BUILDER" >/dev/null 2>&1
then
  v1_count=$(grep -c '^https://' "$TMP/registry-v1.txt" || true)
  if grep -Fxq '# ghlane-registry-v1' "$TMP/registry-v1.txt" &&
     grep -Fxq 'https://good1.example' "$TMP/registry-v1.txt" &&
     grep -Fxq 'https://dead.example' "$TMP/registry-v1.txt" &&
     grep -Eq '^https://good[2345]\.example$' "$TMP/registry-v1.txt" &&
     ! grep -Fxq 'https://bad.example' "$TMP/registry-v1.txt" &&
     [[ "$v1_count" -eq 5 ]] &&
     [[ "$(cat "$TMP/registry.txt")" == $'https://good1.example\nhttps://dead.example' ]]
  then
    pass 'v1 admits verified discoveries while legacy stays manual-only'
  else
    fail 'v1 admits verified discoveries while legacy stays manual-only'
  fi
else
  fail 'v1 admits verified discoveries while legacy stays manual-only'
fi

printf '%s\n' 'https://newdead.example' >"$TMP/newdead-source.txt"
: >"$TMP/no-stable.txt"
printf '# ghlane-registry-v1\n' >"$TMP/empty-v1.txt"
: >"$TMP/empty-legacy.txt"

if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/newdead-source.txt" \
   STABLE_FILE="$TMP/no-stable.txt" \
   PREVIOUS_FILE="$TMP/empty-v1.txt" \
   LEGACY_PREVIOUS_FILE="$TMP/empty-legacy.txt" \
   OUTPUT_FILE="$TMP/newdead-v1.txt" \
   LEGACY_OUTPUT_FILE="$TMP/newdead-legacy.txt" \
   bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(cat "$TMP/newdead-v1.txt")" == '# ghlane-registry-v1' ]] &&
   [[ ! -s "$TMP/newdead-legacy.txt" ]]
then
  pass 'new runner-unreachable discovery is not promoted'
else
  fail 'new runner-unreachable discovery is not promoted'
fi

printf 'https://bad.example\n' >"$TMP/bad-source.txt"
printf 'https://bad.example\n' >"$TMP/bad-stable.txt"
printf '# ghlane-registry-v1\nhttps://bad.example\n' >"$TMP/bad-previous-v1.txt"
printf 'https://bad.example\n' >"$TMP/bad-previous-legacy.txt"

if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/bad-source.txt" \
   STABLE_FILE="$TMP/bad-stable.txt" \
   PREVIOUS_FILE="$TMP/bad-previous-v1.txt" \
   LEGACY_PREVIOUS_FILE="$TMP/bad-previous-legacy.txt" \
   OUTPUT_FILE="$TMP/bad-v1.txt" \
   LEGACY_OUTPUT_FILE="$TMP/bad-legacy.txt" \
   bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(cat "$TMP/bad-v1.txt")" == '# ghlane-registry-v1' ]] &&
   [[ ! -s "$TMP/bad-legacy.txt" ]]
then
  pass 'content mismatch is hard-rejected from both registries'
else
  fail 'content mismatch is hard-rejected from both registries'
fi

printf '%s\n' 'https://good1.example' 'https://good2.example' >"$TMP/cap-source.txt"
printf 'https://good1.example\n' >"$TMP/cap-stable.txt"

if CURL_BIN="$TMP/fake-curl" \
   SOURCE_FILE="$TMP/cap-source.txt" \
   STABLE_FILE="$TMP/cap-stable.txt" \
   PREVIOUS_FILE="$TMP/empty-v1.txt" \
   LEGACY_PREVIOUS_FILE="$TMP/empty-legacy.txt" \
   OUTPUT_FILE="$TMP/capped-v1.txt" \
   LEGACY_OUTPUT_FILE="$TMP/capped-legacy.txt" \
   MAX_MIRRORS=1 \
   STABLE_SLOTS=1 \
   bash "$BUILDER" >/dev/null 2>&1 &&
   [[ "$(grep -c '^https://' "$TMP/capped-v1.txt")" -eq 1 ]] &&
   [[ "$(cat "$TMP/capped-legacy.txt")" == 'https://good1.example' ]]
then
  pass 'v1 and legacy publication caps are enforced'
else
  fail 'v1 and legacy publication caps are enforced'
fi

printf '========================================\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
exit "$(( FAIL > 0 ? 1 : 0 ))"
