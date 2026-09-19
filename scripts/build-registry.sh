#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
SOURCE_FILE="${SOURCE_FILE:-$ROOT/mirrors.txt}"
OUTPUT_FILE="${OUTPUT_FILE:-$ROOT/registry.txt}"
PROBE_URL="${PROBE_URL:-https://github.com/komari-monitor/komari/releases/download/1.5.0-fix1/komari-linux-amd64}"
PROBE_BYTES="${PROBE_BYTES:-32768}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"
MIN_HEALTHY="${MIN_HEALTHY:-2}"
MAX_MIRRORS="${MAX_MIRRORS:-8}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ghlane-registry-health.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

[[ -x "$CURL_BIN" ]] || { echo "registry-health: curl not found: $CURL_BIN" >&2; exit 2; }
[[ -r "$SOURCE_FILE" ]] || { echo "registry-health: source not readable: $SOURCE_FILE" >&2; exit 2; }

END=$((PROBE_BYTES - 1))
REF="$TMP/reference.bin"
OUT="$TMP/registry.txt"
COUNT=0

echo "=== ghlane registry health ==="
echo "fixture: $PROBE_URL"
echo "sample:  $PROBE_BYTES bytes"

if ! "$CURL_BIN" -q -fsSL   --connect-timeout 5   --max-time 20   --range "0-$END"   --max-filesize "$PROBE_BYTES"   -o "$REF"   "$PROBE_URL"
then
  echo "registry-health: direct fixture failed; keeping existing registry" >&2
  exit 2
fi

REF_SIZE=$(wc -c <"$REF")
[[ "$REF_SIZE" -eq "$PROBE_BYTES" ]] || {
  echo "registry-health: direct fixture returned $REF_SIZE bytes, expected $PROBE_BYTES" >&2
  exit 2
}
REF_SHA=$(sha256sum "$REF" | awk '{print $1}')

while IFS= read -r mirror || [[ -n "$mirror" ]]; do
  mirror="${mirror//$'\r'/}"
  [[ -z "$mirror" || "$mirror" == #* ]] && continue

  if [[ "$mirror" != https://* || "$mirror" == *[[:space:]]* ]]; then
    echo "SKIP  $mirror  invalid"
    continue
  fi

  sample="$TMP/sample.$COUNT"
  stats=$("$CURL_BIN" -q -fsSL     --connect-timeout 3     --max-time "$PROBE_TIMEOUT"     --range "0-$END"     --max-filesize "$PROBE_BYTES"     -o "$sample"     -w '%{http_code}|%{content_type}|%{size_download}|%{speed_download}'     "${mirror%/}/$PROBE_URL" 2>/dev/null)
  rc=$?

  IFS='|' read -r code ctype bytes speed <<<"$stats"
  bytes="${bytes:-0}"
  speed="${speed:-0}"

  if [[ "$rc" -eq 0 && "$code" =~ ^20[06]$ && "$bytes" -eq "$PROBE_BYTES" && -f "$sample" ]]; then
    sha=$(sha256sum "$sample" | awk '{print $1}')
    if [[ "$sha" == "$REF_SHA" ]]; then
      printf '%s\n' "$mirror" >>"$OUT"
      COUNT=$((COUNT + 1))
      echo "PASS  $mirror  code=$code speed=$speed"
      (( COUNT >= MAX_MIRRORS )) && break
      continue
    fi
  fi

  echo "FAIL  $mirror  rc=$rc code=${code:-000} bytes=$bytes type=${ctype:-unknown}"
done <"$SOURCE_FILE"

if (( COUNT < MIN_HEALTHY )); then
  echo "registry-health: only $COUNT healthy mirror(s); minimum is $MIN_HEALTHY; keeping existing registry" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
mv "$OUT" "$OUTPUT_FILE"

echo "healthy: $COUNT"
echo "registry: $OUTPUT_FILE"
