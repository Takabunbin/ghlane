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

run_uninstall() {
  bash "$TMP/uninstall.sh"
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
  test "$(ghlane version)" = "ghlane 0.2.2"
  test "$(readlink -f /usr/local/bin/curl)" = "/usr/local/libexec/ghlane"
  test ! -e /usr/local/bin/wget
}

case_fresh() {
  reset_system
  run_install >/dev/null
  test "$(ghlane version)" = "ghlane 0.2.2"
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
  test "$(ghlane version)" = "ghlane 0.2.2"
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
  test "$(ghlane version)" = "ghlane 0.2.2"
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

case_uninstall() {
  reset_system
  run_install >/dev/null
  mkdir -p "$HOME/.cache/ghlane"
  : >"$HOME/.cache/ghlane/best"

  run_uninstall >/dev/null

  test ! -e /usr/local/bin/curl
  test ! -e /usr/local/bin/wget
  test ! -e /usr/local/bin/ghlane
  test ! -e /usr/local/libexec/ghlane
  test ! -e /etc/ghlane.conf
  test ! -e /etc/ghlane/mirrors.txt
  test ! -e "$HOME/.cache/ghlane"
  test -x /usr/bin/curl
}

case_uninstall_idempotent() {
  reset_system
  run_install >/dev/null
  run_uninstall >/dev/null
  run_uninstall >/dev/null
  test ! -e /usr/local/libexec/ghlane
}

case_custom_survives_uninstall() {
  reset_system
  mkdir -p /usr/local/bin
  printf '#!/usr/bin/env bash\necho custom-curl\n' >/usr/local/bin/curl
  printf '#!/usr/bin/env bash\necho custom-wget\n' >/usr/local/bin/wget
  chmod 0755 /usr/local/bin/curl /usr/local/bin/wget

  local curl_before wget_before
  curl_before=$(sha256sum /usr/local/bin/curl)
  wget_before=$(sha256sum /usr/local/bin/wget)

  run_install >/dev/null 2>&1
  run_uninstall >/dev/null

  test "$curl_before" = "$(sha256sum /usr/local/bin/curl)"
  test "$wget_before" = "$(sha256sum /usr/local/bin/wget)"
  test ! -e /usr/local/libexec/ghlane
}

case_root_uninstall_does_not_follow_untrusted_cache_env() {
  reset_system
  run_install >/dev/null

  mkdir -p "$TMP/untrusted-cache/ghlane"
  printf 'keep\n' >"$TMP/untrusted-cache/ghlane/sentinel"
  XDG_CACHE_HOME="$TMP/untrusted-cache" run_uninstall >/dev/null 2>&1

  test -f "$TMP/untrusted-cache/ghlane/sentinel"
  test ! -e /usr/local/libexec/ghlane
}

case_reinstall_after_uninstall() {
  reset_system
  run_install >/dev/null
  run_uninstall >/dev/null
  run_install >/dev/null
  test "$(ghlane version)" = "ghlane 0.2.2"
  ghlane self-test >/dev/null
}

case_preserve_custom_config() {
  reset_system
  run_install >/dev/null

  cat >/etc/ghlane.conf <<'EOF'
REAL_CURL='/usr/bin/curl'
REAL_WGET='/usr/bin/wget'
MIRROR_FILE='/etc/ghlane/mirrors.txt'
BEST_TTL='777'
REGISTRY_URL=''
REGISTRY_TTL='12345'
REGISTRY_MAX='3'
REGISTRY_TIMEOUT='9'
EOF

  local before after
  before=$(sha256sum /etc/ghlane.conf)
  run_install >/dev/null
  after=$(sha256sum /etc/ghlane.conf)

  test "$before" = "$after"
  test "$(ghlane version)" = "ghlane 0.2.2"
}

case_repair_missing_backend_path() {
  reset_system
  run_install >/dev/null

  sed -i "s|^REAL_CURL=.*|REAL_CURL='/definitely/missing/curl'|" /etc/ghlane.conf
  sed -i "s|^REAL_WGET=.*|REAL_WGET='/definitely/missing/wget'|" /etc/ghlane.conf
  run_install >/dev/null

  grep -Fxq "REAL_CURL='/usr/bin/curl'" /etc/ghlane.conf
  grep -Eq "^REAL_WGET='/usr/bin/wget'$|^REAL_WGET='[^']*/wget'$" /etc/ghlane.conf
  ghlane self-test >/dev/null
}

case_migrate_default_registry_url() {
  reset_system
  run_install >/dev/null

  sed -i "s|registry-v1.txt|registry.txt|" /etc/ghlane.conf
  run_install >/dev/null

  grep -Fxq "REGISTRY_URL='https://cdn.jsdelivr.net/gh/Takabunbin/ghlane@main/registry-v1.txt'" /etc/ghlane.conf
}

case_interrupted_upgrade_keeps_old_core_working() {
  reset_system
  run_install >/dev/null

  local before interrupted
  before=$(sha256sum /usr/local/libexec/ghlane)

  interrupted="$TMP/interrupted-install.sh"
  cp "$TMP/install.sh" "$interrupted"
  sed -i '/install -m 0755 "\$tmp\/ghlane" "\$core_new"/i\false' "$interrupted"

  if bash "$interrupted" >/dev/null 2>&1; then
    return 1
  fi

  test "$before" = "$(sha256sum /usr/local/libexec/ghlane)"
  ghlane self-test >/dev/null
}

case_interrupted_upgrade_after_core_switch_keeps_old_config_compatible() {
  reset_system
  run_install >/dev/null

  sed -i "s|registry-v1.txt|registry.txt|" /etc/ghlane.conf
  local interrupted
  interrupted="$TMP/interrupted-after-core.sh"
  cp "$TMP/install.sh" "$interrupted"
  sed -i '/mv -f "\$conf_new" "\$CONF"/i\false' "$interrupted"

  if bash "$interrupted" >/dev/null 2>&1; then
    return 1
  fi

  test "$(ghlane version)" = "ghlane 0.2.2"
  grep -Fxq "REGISTRY_URL='https://cdn.jsdelivr.net/gh/Takabunbin/ghlane@main/registry.txt'" /etc/ghlane.conf
  ghlane self-test >/dev/null
}

case_unsafe_system_config_rejected() {
  reset_system
  run_install >/dev/null

  cp /etc/ghlane.conf "$TMP/safe-ghlane.conf"
  printf '\ntouch %q\n' "$TMP/config-executed" >>/etc/ghlane.conf
  chmod 0666 /etc/ghlane.conf

  test "$(ghlane version 2>/dev/null)" = "ghlane 0.2.2"
  test ! -e "$TMP/config-executed"

  if run_install >/dev/null 2>&1; then
    cp "$TMP/safe-ghlane.conf" /etc/ghlane.conf
    chmod 0644 /etc/ghlane.conf
    return 1
  fi

  cp "$TMP/safe-ghlane.conf" /etc/ghlane.conf
  chmod 0644 /etc/ghlane.conf
  ghlane self-test >/dev/null
}

case_nonroot_sudo() {
  reset_system
  id ghlane-test >/dev/null 2>&1 || useradd -m -s /bin/bash ghlane-test
  printf 'ghlane-test ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/ghlane-test
  chmod 0440 /etc/sudoers.d/ghlane-test

  sudo -u ghlane-test -H env PATH=/usr/local/bin:/usr/bin:/bin bash "$TMP/install.sh" >/dev/null
  test "$(ghlane version)" = "ghlane 0.2.2"
  ghlane self-test >/dev/null

  sudo -u ghlane-test -H env PATH=/usr/local/bin:/usr/bin:/bin bash "$TMP/uninstall.sh" >/dev/null
  test ! -e /usr/local/libexec/ghlane
  test -x /usr/bin/curl
}

printf '========================================\n'
printf ' ghlane installer lifecycle matrix\n'
printf '========================================\n'

make_source "$TMP/source"
make_installer "$TMP/source" "$TMP/install.sh"
cp "$ROOT/uninstall.sh" "$TMP/uninstall.sh"
chmod 0755 "$TMP/uninstall.sh"

run_case 'missing wget' case_missing_wget

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget >/dev/null

run_case 'fresh install' case_fresh
run_case 'repeat install is idempotent' case_reinstall
run_case 'custom /usr/local/bin/curl is preserved' case_custom_curl
run_case 'custom /usr/local/bin/wget is preserved' case_custom_wget
run_case 'bad upgrade leaves working install untouched' case_bad_upgrade
run_case 'reinstall preserves custom config' case_preserve_custom_config
run_case 'reinstall repairs vanished backend paths' case_repair_missing_backend_path
run_case 'old default registry URL migrates to registry-v1' case_migrate_default_registry_url
run_case 'unsafe system config is rejected before sourcing' case_unsafe_system_config_rejected
run_case 'interrupted upgrade before core switch keeps old core working' case_interrupted_upgrade_keeps_old_core_working
run_case 'interrupted upgrade after core switch keeps old config compatible' case_interrupted_upgrade_after_core_switch_keeps_old_config_compatible
run_case 'safe uninstall removes only ghlane files' case_uninstall
run_case 'root uninstall ignores untrusted cache environment' case_root_uninstall_does_not_follow_untrusted_cache_env
run_case 'repeat uninstall is idempotent' case_uninstall_idempotent
run_case 'custom curl/wget survive uninstall' case_custom_survives_uninstall
run_case 'reinstall after uninstall works' case_reinstall_after_uninstall
run_case 'non-root install and uninstall via sudo' case_nonroot_sudo

printf '========================================\n'
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"

exit "$(( FAIL > 0 ? 1 : 0 ))"
