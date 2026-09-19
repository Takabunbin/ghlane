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

# Remove only the invoking user's cache. Other users' caches are harmless and
# must not be guessed at or deleted recursively.
if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
  rm -rf "$XDG_CACHE_HOME/ghlane"
elif [[ -n "${HOME:-}" ]]; then
  rm -rf "$HOME/.cache/ghlane"
fi

printf 'ghlane uninstalled. System curl/wget backends were left untouched.\n'
