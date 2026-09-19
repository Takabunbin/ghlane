#!/usr/bin/env bash
set -euo pipefail

REPO="Takabunbin/ghlane"
REF="${GHLANE_REF:-main}"
BASE="${GHLANE_BASE:-}"
PREFIX="/usr/local"
LIBEXEC="$PREFIX/libexec"
BIN="$PREFIX/bin"
ETC="/etc/ghlane"
CONF="/etc/ghlane.conf"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || { echo 'ghlane: sudo is required' >&2; exit 1; }
  SUDO=(sudo)
fi

old_real_curl=""
old_real_wget=""
if [[ -r "$CONF" ]]; then
  conf_owner=$(stat -c '%u' "$CONF" 2>/dev/null || printf 'unsafe')
  conf_mode=$(stat -c '%a' "$CONF" 2>/dev/null || printf '777')
  if [[ "$conf_owner" != 0 || ! "$conf_mode" =~ ^[0-7]+$ ]] || (( (8#$conf_mode & 022) != 0 )); then
    echo "ghlane: refusing unsafe $CONF (must be root-owned and not group/world writable)" >&2
    exit 1
  fi

  REAL_CURL=""
  REAL_WGET=""
  # shellcheck disable=SC1090
  . "$CONF"
  old_real_curl="${REAL_CURL:-}"
  old_real_wget="${REAL_WGET:-}"
fi

if [[ -n "$old_real_curl" && -x "$old_real_curl" && "$old_real_curl" != "$LIBEXEC/ghlane" ]]; then
  real_curl="$old_real_curl"
else
  real_curl=$(PATH=/usr/bin:/bin command -v curl || true)
  [[ -n "$real_curl" ]] || real_curl=$(command -v curl || true)
fi

if [[ -n "$old_real_wget" && -x "$old_real_wget" && "$old_real_wget" != "$LIBEXEC/ghlane" ]]; then
  real_wget="$old_real_wget"
else
  real_wget=$(PATH=/usr/bin:/bin command -v wget || true)
  [[ -n "$real_wget" ]] || real_wget=$(command -v wget || true)
fi

[[ -n "$real_curl" && -x "$real_curl" ]] || { echo 'ghlane: curl is required for installation' >&2; exit 1; }
real_curl=$(readlink -f "$real_curl")
[[ -z "$real_wget" ]] || real_wget=$(readlink -f "$real_wget")

# Resolve mutable main to one immutable commit before downloading the payload.
if [[ -z "$BASE" ]]; then
  if [[ "$REF" == main ]]; then
    resolved=$("$real_curl" -q -fsSL --connect-timeout 5 --max-time 15 \
      "https://api.github.com/repos/$REPO/commits/main" 2>/dev/null | \
      grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | head -n1 | grep -oE '[0-9a-f]{40}' || true)
    [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || {
      echo 'ghlane: could not resolve main to an immutable commit; set GHLANE_REF to a 40-char commit SHA' >&2
      exit 1
    }
    REF="$resolved"
    printf 'ghlane: resolved main -> %s\n' "$REF" >&2
  fi
  BASE="https://cdn.jsdelivr.net/gh/${REPO}@${REF}"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$real_curl" -q -fsSL --connect-timeout 5 --max-time 30 "$BASE/ghlane" -o "$tmp/ghlane"
"$real_curl" -q -fsSL --connect-timeout 5 --max-time 30 "$BASE/mirrors.txt" -o "$tmp/mirrors.txt"

bash -n "$tmp/ghlane"
awk '
  {
    sub(/\r$/, "")
    if ($0 == "" || $0 ~ /^#/) next
    if ($0 !~ /^https:\/\/[^[:space:]]+$/) exit 1
    count++
  }
  END { if (count == 0) exit 1 }
' "$tmp/mirrors.txt"

if [[ -r "$CONF" ]]; then
  cp "$CONF" "$tmp/ghlane.conf"
  sed -i \
    "s|REGISTRY_URL='https://cdn.jsdelivr.net/gh/Takabunbin/ghlane@main/registry.txt'|REGISTRY_URL='https://cdn.jsdelivr.net/gh/Takabunbin/ghlane@main/registry-v1.txt'|" \
    "$tmp/ghlane.conf"

  set_assignment() {
    local key="$1" value="$2" file="$3"
    if grep -Eq "^${key}=" "$file"; then
      sed -i "s|^${key}=.*|${key}='${value//|/\\|}'|" "$file"
    else
      printf "%s='%s'\n" "$key" "$value" >>"$file"
    fi
  }

  # Preserve user tuning, but repair backend paths if an old backend vanished.
  set_assignment REAL_CURL "$real_curl" "$tmp/ghlane.conf"
  set_assignment REAL_WGET "${real_wget:-/usr/bin/wget}" "$tmp/ghlane.conf"
else
  cat >"$tmp/ghlane.conf" <<CONF
REAL_CURL='$real_curl'
REAL_WGET='${real_wget:-/usr/bin/wget}'
MIRROR_FILE='$ETC/mirrors.txt'
BEST_TTL='3600'
REGISTRY_URL='https://cdn.jsdelivr.net/gh/Takabunbin/ghlane@main/registry-v1.txt'
REGISTRY_TTL='86400'
REGISTRY_MAX='8'
REGISTRY_TIMEOUT='5'
DIGEST_TTL='0'
CONF
fi

"${SUDO[@]}" mkdir -p "$LIBEXEC" "$BIN" "$ETC"

# Each replacement is staged in its target filesystem, then atomically moved.
# The commit order below preserves a safe old/new compatibility boundary.
core_new="$LIBEXEC/.ghlane.new.$$"
mirrors_new="$ETC/.mirrors.new.$$"
conf_new="/etc/.ghlane.conf.new.$$"

cleanup_targets() {
  "${SUDO[@]}" rm -f "$core_new" "$mirrors_new" "$conf_new" 2>/dev/null || true
}
trap 'cleanup_targets; rm -rf "$tmp"' EXIT

# Stage every replacement before committing any of them. Commit order is
# mirrors -> core -> config: the new core safely tolerates the old 0.2.0
# registry config, while the old core must never be left pointing at dynamic v1.
"${SUDO[@]}" install -m 0644 "$tmp/mirrors.txt" "$mirrors_new"
"${SUDO[@]}" install -m 0644 "$tmp/ghlane.conf" "$conf_new"
"${SUDO[@]}" install -m 0755 "$tmp/ghlane" "$core_new"

"${SUDO[@]}" mv -f "$mirrors_new" "$ETC/mirrors.txt"
"${SUDO[@]}" mv -f "$core_new" "$LIBEXEC/ghlane"
"${SUDO[@]}" mv -f "$conf_new" "$CONF"

"${SUDO[@]}" ln -sfn "$LIBEXEC/ghlane" "$BIN/ghlane"

install_wrapper() {
  local name="$1"
  local backend="$2"
  local dst="$BIN/$name"
  local target=""
  [[ -n "$backend" && -x "$backend" ]] || return 0

  if [[ -e "$dst" || -L "$dst" ]]; then
    [[ -L "$dst" ]] && target=$(readlink -f "$dst" 2>/dev/null || true)
    if [[ "$target" != "$LIBEXEC/ghlane" ]]; then
      echo "ghlane: leaving existing $dst untouched" >&2
      return 0
    fi
  fi

  "${SUDO[@]}" ln -sfn "$LIBEXEC/ghlane" "$dst"
}

install_wrapper curl "$real_curl"
install_wrapper wget "$real_wget"

"$BIN/ghlane" self-test
printf 'ghlane installed. Run: ghlane status\n'
