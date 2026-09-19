#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
SOURCE_FILE="${SOURCE_FILE:-$ROOT/mirrors.txt}"
STABLE_FILE="${STABLE_FILE:-$ROOT/mirrors.txt}"
PREVIOUS_FILE="${PREVIOUS_FILE:-$ROOT/registry-v1.txt}"
LEGACY_PREVIOUS_FILE="${LEGACY_PREVIOUS_FILE:-$ROOT/registry.txt}"
OUTPUT_FILE="${OUTPUT_FILE:-$ROOT/registry-v1.txt}"
LEGACY_OUTPUT_FILE="${LEGACY_OUTPUT_FILE:-$ROOT/registry.txt}"
PROBE_URL="${PROBE_URL:-https://github.com/komari-monitor/komari/releases/download/1.5.0-fix1/komari-linux-amd64}"
PROBE_BYTES="${PROBE_BYTES:-32768}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"
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
PASS_DIR="$TMP/pass"
SOFT_DIR="$TMP/soft"
HARD_DIR="$TMP/hard"
LOGS="$TMP/logs"
OUT="$TMP/registry-v1.txt"
LEGACY_OUT="$TMP/registry.txt"
mkdir -p "$PASS_DIR" "$SOFT_DIR" "$HARD_DIR" "$LOGS"

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
  echo "registry-health: direct fixture failed; keeping existing registries" >&2
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
      if ($0 !~ /^https:\/\/[^[:space:]]+$/) next
      if (!seen[$0]++) print
    }
  ' "$SOURCE_FILE"
)

if (( ${#CANDIDATES[@]} > MAX_CANDIDATES )); then
  CANDIDATES=("${CANDIDATES[@]:0:MAX_CANDIDATES}")
  echo "registry-health: candidate list truncated to $MAX_CANDIDATES endpoints" >&2
fi

declare -A STABLE=()
declare -A PREVIOUS=()
declare -A LEGACY_PREVIOUS=()

if [[ -r "$STABLE_FILE" ]]; then
  while IFS= read -r mirror || [[ -n "$mirror" ]]; do
    mirror="${mirror//$'\r'/}"
    [[ "$mirror" == https://* ]] || continue
    STABLE["$mirror"]=1
  done <"$STABLE_FILE"
fi

if [[ -r "$PREVIOUS_FILE" ]]; then
  while IFS= read -r mirror || [[ -n "$mirror" ]]; do
    mirror="${mirror//$'\r'/}"
    [[ "$mirror" == https://* ]] || continue
    PREVIOUS["$mirror"]=1
  done <"$PREVIOUS_FILE"
fi

if [[ -r "$LEGACY_PREVIOUS_FILE" ]]; then
  while IFS= read -r mirror || [[ -n "$mirror" ]]; do
    mirror="${mirror//$'\r'/}"
    [[ "$mirror" == https://* ]] || continue
    LEGACY_PREVIOUS["$mirror"]=1
  done <"$LEGACY_PREVIOUS_FILE"
fi

probe_one() {
  local index="$1" mirror="$2" sample stats rc code ctype bytes speed sha

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

declare -A ELIGIBLE=()
declare -A SELECTED=()
declare -A LEGACY_OK=()
PASS_COUNT=0
SOFT_RETAINED=0
HARD_COUNT=0

for i in "${!CANDIDATES[@]}"; do
  mirror="${CANDIDATES[$i]}"

  if [[ -r "$PASS_DIR/$i" ]]; then
    ELIGIBLE["$mirror"]=1
    [[ -n "${STABLE[$mirror]:-}" ]] && LEGACY_OK["$mirror"]=1
    PASS_COUNT=$((PASS_COUNT + 1))
    continue
  fi

  if [[ -r "$HARD_DIR/$i" ]]; then
    HARD_COUNT=$((HARD_COUNT + 1))
    continue
  fi

  # A hosted runner is only one network viewpoint. Retain an endpoint across
  # transient reachability failure only if it was already published. Content
  # or protocol mismatches above are never retained.
  if [[ -r "$SOFT_DIR/$i" && -n "${PREVIOUS[$mirror]:-}" ]]; then
    ELIGIBLE["$mirror"]=1
    SOFT_RETAINED=$((SOFT_RETAINED + 1))
  fi
  if [[ -r "$SOFT_DIR/$i" && -n "${STABLE[$mirror]:-}" && -n "${LEGACY_PREVIOUS[$mirror]:-}" ]]; then
    LEGACY_OK["$mirror"]=1
  fi
done

printf '# ghlane-registry-v1\n' >"$OUT"
: >"$LEGACY_OUT"

STABLE_LIMIT=$STABLE_SLOTS
(( STABLE_LIMIT > MAX_MIRRORS )) && STABLE_LIMIT=$MAX_MIRRORS
PUBLISHED=0

# Preserve manually approved mirrors in stable slots when they are currently
# verified or only transiently unreachable.
if [[ -r "$STABLE_FILE" ]]; then
  while IFS= read -r mirror || [[ -n "$mirror" ]]; do
    mirror="${mirror//$'\r'/}"
    [[ "$mirror" == https://* ]] || continue
    [[ -n "${ELIGIBLE[$mirror]:-}" ]] || continue
    [[ -z "${SELECTED[$mirror]:-}" ]] || continue
    printf '%s\n' "$mirror" >>"$OUT"
    SELECTED["$mirror"]=1
    PUBLISHED=$((PUBLISHED + 1))
    (( PUBLISHED >= STABLE_LIMIT )) && break
  done <"$STABLE_FILE"
fi

# v1 clients verify every complete asset against GitHub's release digest, so
# healthy discovered endpoints may safely occupy bounded exploration slots.
EXPLORE="$TMP/explore"
WEEK=$(date -u +%G-%V)
: >"$EXPLORE"

for mirror in "${CANDIDATES[@]}"; do
  [[ -n "${ELIGIBLE[$mirror]:-}" ]] || continue
  [[ -z "${SELECTED[$mirror]:-}" ]] || continue
  key=$(printf '%s' "$WEEK|$mirror" | sha256sum | awk '{print $1}')
  printf '%s\t%s\n' "$key" "$mirror" >>"$EXPLORE"
done

while read -r _ mirror; do
  (( PUBLISHED >= MAX_MIRRORS )) && break
  [[ -n "$mirror" ]] || continue
  [[ -z "${SELECTED[$mirror]:-}" ]] || continue
  printf '%s\n' "$mirror" >>"$OUT"
  SELECTED["$mirror"]=1
  PUBLISHED=$((PUBLISHED + 1))
done < <(sort "$EXPLORE")

# Legacy 0.2.0 clients do not have end-to-end digest verification. Never expose
# auto-discovered endpoints to them; publish only manually approved mirrors.
if [[ -r "$STABLE_FILE" ]]; then
  while IFS= read -r mirror || [[ -n "$mirror" ]]; do
    mirror="${mirror//$'\r'/}"
    [[ "$mirror" == https://* ]] || continue
    [[ -n "${LEGACY_OK[$mirror]:-}" ]] || continue
    printf '%s\n' "$mirror" >>"$LEGACY_OUT"
  done <"$STABLE_FILE"
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
mv "$OUT" "$OUTPUT_FILE"

if [[ -n "$LEGACY_OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$LEGACY_OUTPUT_FILE")"
  mv "$LEGACY_OUT" "$LEGACY_OUTPUT_FILE"
fi

echo "candidates: ${#CANDIDATES[@]}"
echo "verified now: $PASS_COUNT"
echo "retained on runner-only failure: $SOFT_RETAINED"
echo "hard rejected: $HARD_COUNT"
echo "v1 published: $PUBLISHED"
echo "registry-v1: $OUTPUT_FILE"
echo "legacy registry: ${LEGACY_OUTPUT_FILE:-disabled}"
