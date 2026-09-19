#!/usr/bin/env bash
set -euo pipefail

PREFIX="/usr/local"
LIBEXEC="$PREFIX/libexec"
BIN="$PREFIX/bin"
ETC="/etc/ghlane"
CONF="/etc/ghlane.conf"
CORE="$LIBEXEC/ghlane"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || { echo 'ghlane: sudo is required' >&2; exit 1; }
  SUDO=(sudo)
fi

remove_wrapper() {
  local dst="$BIN/$1" target=""
  [[ -L "$dst" ]] || return 0
  target=$(readlink -f "$dst" 2>/dev/null || true)
  [[ "$target" == "$CORE" ]] || return 0
  "${SUDO[@]}" rm -f "$dst"
}

remove_wrapper curl
remove_wrapper wget
remove_wrapper ghlane

"${SUDO[@]}" rm -f "$CORE" "$CONF" "$ETC/mirrors.txt"
"${SUDO[@]}" rmdir "$ETC" 2>/dev/null || true

# Remove only a cache path that is safe for the current privilege level.
# In particular, a root uninstall must not turn attacker-controlled HOME/XDG
# environment variables into an arbitrary recursive deletion primitive.
cache=""
if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
  cache="$XDG_CACHE_HOME/ghlane"
elif [[ -n "${HOME:-}" ]]; then
  cache="$HOME/.cache/ghlane"
fi

if [[ -n "$cache" ]]; then
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    root_home=$(getent passwd 0 2>/dev/null | awk -F: 'NR==1 {print $6}')
    case "$cache" in
      "$root_home"/*) rm -rf -- "$cache" ;;
      *) echo "ghlane: leaving cache outside root home untouched: $cache" >&2 ;;
    esac
  else
    rm -rf -- "$cache"
  fi
fi

printf 'ghlane uninstalled. System curl/wget backends were left untouched.\n'
