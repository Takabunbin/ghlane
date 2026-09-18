#!/usr/bin/env bash
set -euo pipefail

REPO="Takabunbin/ghlane"
BASE="https://cdn.jsdelivr.net/gh/${REPO}@main"
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

real_curl=$(command -v curl || true)
real_wget=$(command -v wget || true)
[[ -n "$real_curl" ]] || { echo 'ghlane: curl is required for installation' >&2; exit 1; }
real_curl=$(readlink -f "$real_curl")
[[ -z "$real_wget" ]] || real_wget=$(readlink -f "$real_wget")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$real_curl" -fsSL --connect-timeout 5 --max-time 30 "$BASE/ghlane" -o "$tmp/ghlane"
"$real_curl" -fsSL --connect-timeout 5 --max-time 30 "$BASE/mirrors.txt" -o "$tmp/mirrors.txt"
bash -n "$tmp/ghlane"
grep -q '^https://' "$tmp/mirrors.txt"

"${SUDO[@]}" mkdir -p "$LIBEXEC" "$BIN" "$ETC"
"${SUDO[@]}" install -m 0755 "$tmp/ghlane" "$LIBEXEC/ghlane"
"${SUDO[@]}" install -m 0644 "$tmp/mirrors.txt" "$ETC/mirrors.txt"

cat > "$tmp/ghlane.conf" <<CONF
REAL_CURL='$real_curl'
REAL_WGET='${real_wget:-/usr/bin/wget}'
MIRROR_FILE='$ETC/mirrors.txt'
BEST_TTL='3600'
CONF
"${SUDO[@]}" install -m 0644 "$tmp/ghlane.conf" "$CONF"
"${SUDO[@]}" ln -sfn "$LIBEXEC/ghlane" "$BIN/ghlane"

install_wrapper() {
  local name="$1" backend="$2" dst="$BIN/$name"
  [[ -n "$backend" && -x "$backend" ]] || return 0
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    echo "ghlane: leaving existing $dst untouched" >&2
    return 0
  fi
  "${SUDO[@]}" ln -sfn "$LIBEXEC/ghlane" "$dst"
}

install_wrapper curl "$real_curl"
install_wrapper wget "$real_wget"

"$BIN/ghlane" self-test
printf 'ghlane installed. Run: ghlane status\n'
