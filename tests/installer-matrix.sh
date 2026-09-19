#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d)
chmod 0755 "$TMP"
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

reset_system() {
  rm -f /usr/local/bin/ghlane /usr/local/bin/curl /usr/local/bin/wget
  rm -f /usr/local/libexec/ghlane /etc/ghlane.conf
  rm -rf /etc/ghlane
}

make_source() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$ROOT/ghlane" "$dir/ghlane"
  cp "$ROOT/mirrors.txt" "$dir/mirrors.txt"
  chmod 0644 "$dir/ghlane" "$dir/mirrors.txt"
}

make_installer() {
  local source="$1" out="$2"
  cp "$ROOT/install.sh" "$out"
  sed -i "s|^BASE=.*|BASE='file://$source'|" "$out"
  chmod 0755 "$out"
}

run_install() {
  bash "$TMP/install.sh"
}

run_case() {
  local name="$1" fn="$2"
  if ( set -e; "$fn" ); then
    pass "$name"
  else
    fail "$name"
  fi
}

case_missing_wget() {
  reset_system
  apt-get purge -y wget >/dev/null 2>&1 || true
  run_install >/dev/null
  test "$(ghlane version)" = "ghlane 0.1.10"
  test "$(readlink -f /usr/local/bin/curl)" = "/usr/local/libexec/ghlane"
  test ! -e /usr/local/bin/wget
}

case_fresh() {
  reset_system
  run_install >/dev/null
  test "$(ghlane version)" = "ghlane 0.1.10"
  test "$(readlink -f /usr/local/bin/curl)" = "/usr/local/libexec/ghlane"
  test "$(readlink -f /usr/local/bin/wget)" = "/usr/local/libexec/ghlane"
  test "$(readlink -f /usr/local/bin/ghlane)" = "/usr/local/libexec/ghlane"
  ghlane self-test >/dev/null
}

case_reinstall() {
  reset_system
  run_install >/dev/null
  local before after
  before=$(sha256sum /usr/local/libexec/ghlane /etc/ghlane.conf /etc/ghlane/mirrors.txt)
  run_install >/dev/null
  after=$(sha256sum /usr/local/libexec/ghlane /etc/ghlane.conf /etc/ghlane/mirrors.txt)
  test "$before" = "$after"
  test "$(readlink -f /usr/local/bin/curl)" = "/usr/local/libexec/ghlane"
  test "$(readlink -f /usr/local/bin/wget)" = "/usr/local/libexec/ghlane"
}

case_custom_curl() {
  reset_system
  mkdir -p /usr/local/bin
  printf '#!/usr/bin/env bash\necho custom-curl\n' >/usr/local/bin/curl
  chmod 0755 /usr/local/bin/curl
  local before
  before=$(sha256sum /usr/local/bin/curl)
  run_install >/dev/null 2>&1
  test "$before" = "$(sha256sum /usr/local/bin/curl)"
  test ! -L /usr/local/bin/curl
  test "$(ghlane version)" = "ghlane 0.1.10"
}

case_custom_wget() {
  reset_system
  mkdir -p /usr/local/bin
  printf '#!/usr/bin/env bash\necho custom-wget\n' >/usr/local/bin/wget
  chmod 0755 /usr/local/bin/wget
  local before
  before=$(sha256sum /usr/local/bin/wget)
  run_install >/dev/null 2>&1
  test "$before" = "$(sha256sum /usr/local/bin/wget)"
  test ! -L /usr/local/bin/wget
  test "$(ghlane version)" = "ghlane 0.1.10"
}

case_bad_upgrade() {
  reset_system
  run_install >/dev/null
  local before after broken
  before=$(sha256sum /usr/local/libexec/ghlane /etc/ghlane.conf /etc/ghlane/mirrors.txt)

  broken="$TMP/broken"
  make_source "$broken"
  printf '#!/usr/bin/env bash\nthis is not valid bash (\n' >"$broken/ghlane"
  make_installer "$broken" "$TMP/bad-install.sh"

  if bash "$TMP/bad-install.sh" >/dev/null 2>&1; then
    return 1
  fi

  after=$(sha256sum /usr/local/libexec/ghlane /etc/ghlane.conf /etc/ghlane/mirrors.txt)
  test "$before" = "$after"
  ghlane self-test >/dev/null
}

case_nonroot_sudo() {
  reset_system
  id ghlane-test >/dev/null 2>&1 || useradd -m -s /bin/bash ghlane-test
  printf 'ghlane-test ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/ghlane-test
  chmod 0440 /etc/sudoers.d/ghlane-test
  sudo -u ghlane-test -H env PATH=/usr/local/bin:/usr/bin:/bin bash "$TMP/install.sh" >/dev/null
  test "$(ghlane version)" = "ghlane 0.1.10"
  ghlane self-test >/dev/null
}

printf '========================================\n'
printf ' ghlane installer matrix\n'
printf '========================================\n'

make_source "$TMP/source"
make_installer "$TMP/source" "$TMP/install.sh"

run_case 'missing wget' case_missing_wget

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget >/dev/null

run_case 'fresh install' case_fresh
run_case 'repeat install is idempotent' case_reinstall
run_case 'custom /usr/local/bin/curl is preserved' case_custom_curl
run_case 'custom /usr/local/bin/wget is preserved' case_custom_wget
run_case 'bad upgrade leaves working install untouched' case_bad_upgrade
run_case 'non-root install via sudo' case_nonroot_sudo

printf '========================================\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"

exit "$(( FAIL > 0 ? 1 : 0 ))"
