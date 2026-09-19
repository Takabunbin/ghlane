#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
SOURCE_FILE="${SOURCE_FILE:-$ROOT/mirrors.txt}"
PREVIOUS_FILE="${PREVIOUS_FILE:-$ROOT/registry-v1.txt}"
OUTPUT_FILE="${OUTPUT_FILE:-$ROOT/registry-v1.txt}"
LEGACY_OUTPUT_FILE="${LEGACY_OUTPUT_FILE:-}"
PROBE_URL="${PROBE_URL:-https://github.com/komari-monitor/komari/releases/download/1.5.0-fix1/komari-linux-amd64}"
PROBE_BYTES="${PROBE_BYTES:-32768}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"
MAX_MIRRORS="${MAX_MIRRORS:-8}"
MAX_CANDIDATES="${MAX_CANDIDATES:-64}"
PARALLEL="${PARALLEL:-8}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ghlane-registry-health.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

[[ -x "$CURL_BIN" ]] || { echo "registry-health: curl not found: $CURL_BIN" >&2; exit 2; }
[[ -r "$SOURCE_FILE" ]] || { echo "registry-health: source not readable: $SOURCE_FILE" >&2; exit 2; }
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "registry-health: invalid PARALLEL=$PARALLEL" >&2; exit 2; }

END=$((PROBE_BYTES - 1))
REF="$TMP/reference.bin"
PASS_DIR="$TMP/pass"
SOFT_DIR="$TMP/soft"
HARD_DIR="$TMP/hard"
LOGS="$TMP/logs"
OUT="$TMP/registry-v1.txt"
mkdir -p "$PASS_DIR" "$SOFT_DIR" "$HARD_DIR" "$LOGS"

echo "=== ghlane trusted registry health ==="
echo "fixture: $PROBE_URL"
echo "sample:  $PROBE_BYTES bytes"

if ! "$CURL_BIN" -q -fsSL \
  --connect-timeout 5 \
  --max-time 20 \
  --range "0-$END" \
  --max-filesize "$PROBE_BYTES" \
  -o "$REF" \
  "$PROBE_URL"
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

mapfile -t CANDIDATES < <(
  awk '
    {
      sub(/\r$/, "")
      if ($0 == "" || $0 ~ /^#/) next
      if (!seen[$0]++) print
    }
  ' "$SOURCE_FILE"
)

if (( ${#CANDIDATES[@]} > MAX_CANDIDATES )); then
  CANDIDATES=("${CANDIDATES[@]:0:MAX_CANDIDATES}")
  echo "registry-health: candidate list truncated to $MAX_CANDIDATES approved endpoints" >&2
fi

declare -A PREVIOUS=()
if [[ -r "$PREVIOUS_FILE" ]]; then
  while IFS= read -r mirror || [[ -n "$mirror" ]]; do
    mirror="${mirror//$'\r'/}"
    [[ "$mirror" == https://* ]] || continue
    PREVIOUS["$mirror"]=1
  done <"$PREVIOUS_FILE"
fi

probe_one() {
  local index="$1" mirror="$2" sample stats rc code ctype bytes speed sha

  if [[ "$mirror" != https://* || "$mirror" == *[[:space:]]* ]]; then
    printf '%s\n' "$mirror" >"$HARD_DIR/$index"
    printf 'HARD  %s  invalid approved endpoint\n' "$mirror" >"$LOGS/$index"
    return 0
  fi

  sample="$TMP/sample.$index"
  stats=$("$CURL_BIN" -q -fsSL \
    --connect-timeout 3 \
    --max-time "$PROBE_TIMEOUT" \
    --range "0-$END" \
    --max-filesize "$PROBE_BYTES" \
    -o "$sample" \
    -w '%{http_code}|%{content_type}|%{size_download}|%{speed_download}' \
    "${mirror%/}/$PROBE_URL" 2>/dev/null)
  rc=$?

  IFS='|' read -r code ctype bytes speed <<<"$stats"
  bytes="${bytes:-0}"
  speed="${speed:-0}"

  if [[ "$rc" -eq 0 && "$code" =~ ^20[06]$ && -f "$sample" ]]; then
    sha=$(sha256sum "$sample" | awk '{print $1}')
    if [[ "$bytes" -eq "$PROBE_BYTES" && "$sha" == "$REF_SHA" ]]; then
      printf '%s\n' "$mirror" >"$PASS_DIR/$index"
      printf 'PASS  %s  code=%s speed=%s\n' "$mirror" "$code" "$speed" >"$LOGS/$index"
      return 0
    fi

    printf '%s\n' "$mirror" >"$HARD_DIR/$index"
    printf 'HARD  %s  content/protocol mismatch code=%s bytes=%s type=%s\n' \
      "$mirror" "$code" "$bytes" "${ctype:-unknown}" >"$LOGS/$index"
    return 0
  fi

  printf '%s\n' "$mirror" >"$SOFT_DIR/$index"
  printf 'SOFT  %s  runner-unreachable rc=%s code=%s bytes=%s\n' \
    "$mirror" "$rc" "${code:-000}" "$bytes" >"$LOGS/$index"
}

running=0
for i in "${!CANDIDATES[@]}"; do
  probe_one "$i" "${CANDIDATES[$i]}" &
  running=$((running + 1))
  if (( running >= PARALLEL )); then
    wait -n || true
    running=$((running - 1))
  fi
done
wait || true

for i in "${!CANDIDATES[@]}"; do
  [[ -r "$LOGS/$i" ]] && cat "$LOGS/$i"
done

printf '# ghlane-registry-v1\n' >"$OUT"
PUBLISHED=0
PASSED=0
RETAINED=0
HARD_FAILED=0

for i in "${!CANDIDATES[@]}"; do
  mirror="${CANDIDATES[$i]}"

  if [[ -r "$PASS_DIR/$i" ]]; then
    if (( PUBLISHED < MAX_MIRRORS )); then
      printf '%s\n' "$mirror" >>"$OUT"
      PUBLISHED=$((PUBLISHED + 1))
      PASSED=$((PASSED + 1))
    fi
    continue
  fi

  if [[ -r "$HARD_DIR/$i" ]]; then
    HARD_FAILED=$((HARD_FAILED + 1))
    continue
  fi

  # ponytail: a GitHub-hosted runner is only one network viewpoint.
  # Preserve an already-published, manually approved endpoint on transient
  # reachability failure, but never preserve a content/protocol mismatch.
  if [[ -r "$SOFT_DIR/$i" && -n "${PREVIOUS[$mirror]:-}" && $PUBLISHED -lt $MAX_MIRRORS ]]; then
    printf '%s\n' "$mirror" >>"$OUT"
    PUBLISHED=$((PUBLISHED + 1))
    RETAINED=$((RETAINED + 1))
  fi
done

mkdir -p "$(dirname "$OUTPUT_FILE")"
mv "$OUT" "$OUTPUT_FILE"

if [[ -n "$LEGACY_OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$LEGACY_OUTPUT_FILE")"
  grep '^https://' "$OUTPUT_FILE" >"$LEGACY_OUTPUT_FILE" || : >"$LEGACY_OUTPUT_FILE"
fi

echo "approved candidates: ${#CANDIDATES[@]}"
echo "verified now: $PASSED"
echo "retained on runner-only failure: $RETAINED"
echo "hard rejected: $HARD_FAILED"
echo "published: $PUBLISHED"
echo "registry: $OUTPUT_FILE"
