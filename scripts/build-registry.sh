#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
SOURCE_FILE="${SOURCE_FILE:-$ROOT/mirrors.txt}"
STABLE_FILE="${STABLE_FILE:-$ROOT/mirrors.txt}"
OUTPUT_FILE="${OUTPUT_FILE:-$ROOT/registry.txt}"
PROBE_URL="${PROBE_URL:-https://github.com/komari-monitor/komari/releases/download/1.5.0-fix1/komari-linux-amd64}"
PROBE_BYTES="${PROBE_BYTES:-32768}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"
MIN_HEALTHY="${MIN_HEALTHY:-2}"
MAX_MIRRORS="${MAX_MIRRORS:-8}"
STABLE_SLOTS="${STABLE_SLOTS:-5}"
MAX_CANDIDATES="${MAX_CANDIDATES:-128}"
PARALLEL="${PARALLEL:-8}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ghlane-registry-health.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

[[ -x "$CURL_BIN" ]] || { echo "registry-health: curl not found: $CURL_BIN" >&2; exit 2; }
[[ -r "$SOURCE_FILE" ]] || { echo "registry-health: source not readable: $SOURCE_FILE" >&2; exit 2; }
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "registry-health: invalid PARALLEL=$PARALLEL" >&2; exit 2; }

END=$((PROBE_BYTES - 1))
REF="$TMP/reference.bin"
HEALTHY="$TMP/healthy"
LOGS="$TMP/logs"
OUT="$TMP/registry.txt"
mkdir -p "$HEALTHY" "$LOGS"

echo "=== ghlane registry health ==="
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
  echo "registry-health: ${#CANDIDATES[@]} candidates exceeds cap $MAX_CANDIDATES" >&2
  exit 2
fi

probe_one() {
  local index="$1" mirror="$2" sample stats rc code ctype bytes speed sha

  if [[ "$mirror" != https://* || "$mirror" == *[[:space:]]* ]]; then
    printf 'SKIP  %s  invalid\n' "$mirror" >"$LOGS/$index"
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

  if [[ "$rc" -eq 0 && "$code" =~ ^20[06]$ && "$bytes" -eq "$PROBE_BYTES" && -f "$sample" ]]; then
    sha=$(sha256sum "$sample" | awk '{print $1}')
    if [[ "$sha" == "$REF_SHA" ]]; then
      printf '%s\n' "$mirror" >"$HEALTHY/$index"
      printf 'PASS  %s  code=%s speed=%s\n' "$mirror" "$code" "$speed" >"$LOGS/$index"
      return 0
    fi
  fi

  printf 'FAIL  %s  rc=%s code=%s bytes=%s type=%s\n' \
    "$mirror" "$rc" "${code:-000}" "$bytes" "${ctype:-unknown}" >"$LOGS/$index"
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

declare -A IS_HEALTHY=()
declare -A SELECTED=()
HEALTHY_LIST=()

for i in "${!CANDIDATES[@]}"; do
  if [[ -r "$HEALTHY/$i" ]]; then
    mirror=$(cat "$HEALTHY/$i")
    IS_HEALTHY["$mirror"]=1
    HEALTHY_LIST+=("$mirror")
  fi
done

TOTAL_HEALTHY=${#HEALTHY_LIST[@]}
if (( TOTAL_HEALTHY < MIN_HEALTHY )); then
  echo "registry-health: only $TOTAL_HEALTHY healthy mirror(s); minimum is $MIN_HEALTHY; keeping existing registry" >&2
  exit 1
fi

STABLE_LIMIT=$STABLE_SLOTS
(( STABLE_LIMIT > MAX_MIRRORS )) && STABLE_LIMIT=$MAX_MIRRORS
PUBLISHED=0

if [[ -r "$STABLE_FILE" ]]; then
  while IFS= read -r mirror || [[ -n "$mirror" ]]; do
    mirror="${mirror//$'\r'/}"
    [[ -z "$mirror" || "$mirror" == \#* ]] && continue
    [[ -n "${IS_HEALTHY[$mirror]:-}" ]] || continue
    [[ -z "${SELECTED[$mirror]:-}" ]] || continue
    printf '%s\n' "$mirror" >>"$OUT"
    SELECTED["$mirror"]=1
    PUBLISHED=$((PUBLISHED + 1))
    (( PUBLISHED >= STABLE_LIMIT )) && break
  done <"$STABLE_FILE"
fi

# ponytail: five stable slots plus weekly rotating exploration slots avoid
# persistent health-history state while ensuring new mirrors are not starved.
# If the pool routinely exceeds 128 or rotation churn becomes harmful, add
# capped reliability history instead of increasing client probe fan-out.
EXPLORE="$TMP/explore"
WEEK=$(date -u +%G-%V)
: >"$EXPLORE"

for mirror in "${HEALTHY_LIST[@]}"; do
  [[ -z "${SELECTED[$mirror]:-}" ]] || continue
  key=$(printf '%s' "$WEEK|$mirror" | sha256sum | awk '{print $1}')
  printf '%s\t%s\n' "$key" "$mirror" >>"$EXPLORE"
done

while IFS=
  printf '%s\n' "$mirror" >>"$OUT"
  SELECTED["$mirror"]=1
  PUBLISHED=$((PUBLISHED + 1))
  (( PUBLISHED >= MAX_MIRRORS )) && break
done < <(sort "$EXPLORE")

if (( PUBLISHED < MIN_HEALTHY )); then
  echo "registry-health: only $PUBLISHED publishable mirror(s); keeping existing registry" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
mv "$OUT" "$OUTPUT_FILE"

echo "healthy candidates: $TOTAL_HEALTHY"
echo "published: $PUBLISHED (stable<=${STABLE_LIMIT}, exploration=$((PUBLISHED > STABLE_LIMIT ? PUBLISHED - STABLE_LIMIT : 0)))"
echo "registry: $OUTPUT_FILE"
\t' read -r _ mirror; do
  (( PUBLISHED >= MAX_MIRRORS )) && break
  [[ -n "$mirror" ]] || continue
  [[ -z "${SELECTED[$mirror]:-}" ]] || continue
  printf '%s\n' "$mirror" >>"$OUT"
  SELECTED["$mirror"]=1
  PUBLISHED=$((PUBLISHED + 1))
  (( PUBLISHED >= MAX_MIRRORS )) && break
done < <(sort "$EXPLORE")

if (( PUBLISHED < MIN_HEALTHY )); then
  echo "registry-health: only $PUBLISHED publishable mirror(s); keeping existing registry" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
mv "$OUT" "$OUTPUT_FILE"

echo "healthy candidates: $TOTAL_HEALTHY"
echo "published: $PUBLISHED (stable<=${STABLE_LIMIT}, exploration=$((PUBLISHED > STABLE_LIMIT ? PUBLISHED - STABLE_LIMIT : 0)))"
echo "registry: $OUTPUT_FILE"
