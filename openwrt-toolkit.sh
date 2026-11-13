#!/bin/sh
# Install Packets Script — interactive OpenWrt installer toolkit.
# Runs under BusyBox ash. Third-party installers execute as root; audit before use.
set -u

VERSION="2.0.5"
umask 077
set -f
TMP_DIR="$(mktemp -d /tmp/install-packets.XXXXXX)" || exit 1
cleanup() {
  rm -rf "$TMP_DIR"
  printf '\n%s========== КОНЕЦ · INSTALL PACKETS %s ==========%s\n' "$C_MAGENTA" "$VERSION" "$C_RESET"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_MAGENTA=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="$(printf '\033[0m')"
  C_CYAN="$(printf '\033[1;96m')"     # яркий неоновый бирюзовый — информация
  C_GREEN="$(printf '\033[1;92m')"    # яркий неоновый зелёный — успех и список пакетов
  C_YELLOW="$(printf '\033[93m')"     # яркий жёлтый — предупреждения
  C_RED="$(printf '\033[91m')"        # неоновый красный — ошибки
  C_BOLD="$(printf '\033[95m')"       # пурпурный — этапы
  C_MAGENTA="$(printf '\033[95m')"    # пурпурный — баннер
fi
info() { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err() { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step() { printf '\n%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }

printf '%s========== НАЧАЛО · INSTALL PACKETS %s ==========%s\n' "$C_MAGENTA" "$VERSION" "$C_RESET"
[ "$(id -u)" = 0 ] || { err "Запустите скрипт от root."; exit 1; }
[ -r /etc/openwrt_release ] || { err "Этот скрипт предназначен для OpenWrt."; exit 1; }
command -v uci >/dev/null 2>&1 || { err "Не найдена команда uci."; exit 1; }
if command -v apk >/dev/null 2>&1; then PM=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg
else err "Не найден пакетный менеджер apk/opkg."; exit 1
fi

RELEASE="$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'.*/\1/p" /etc/openwrt_release | head -n 1)"
VERSION_MAJOR="$(printf '%s' "$RELEASE" | cut -d. -f1)"
if [ "$PM" = opkg ]; then
  PKG_ARCH="$(opkg print-architecture 2>/dev/null | awk '$1 == "arch" && $2 != "all" { a=$2 } END { print a }')"
else
  PKG_ARCH="$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.arch' 2>/dev/null || true)"
  [ -n "$PKG_ARCH" ] || PKG_ARCH="$(apk --print-arch 2>/dev/null || true)"
fi
MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || printf 'неизвестна')"

fetch() {
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$out"
  elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -O "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$out" "$url"
  else err "Нужен curl, uclient-fetch или wget."; return 127; fi
}
pkg_installed() {
  package="$1"
  if [ "$PM" = apk ]; then apk info -e "$package" >/dev/null 2>&1
  else opkg list-installed 2>/dev/null | grep -q "^$package "; fi
}
pkg_update() { if [ "$PM" = apk ]; then apk update; else opkg update; fi; }
validate_shell() {
  [ -s "$1" ] && head -n 1 "$1" | grep -q '^#!' && sh -n "$1"
}


install_ttyd() {
  for tty_pkg in ttyd luci-app-ttyd; do
    pkg_add "$tty_pkg" || return 1
  done
  component_installed ttyd
}

ensure_ip_full() {
  # ip-tiny and ip-full provide the same ip package and cannot coexist.
  # Never force removal of dependent networking packages.
  if pkg_installed ip-tiny; then
    info 'Замена ip-tiny на ip-full...'
    if [ "$PM" = apk ]; then
      apk del ip-tiny || return 1
    else
      opkg remove ip-tiny || return 1
    fi
  fi
  pkg_add ip-full || return 1
  pkg_installed ip-full || return 1
  ok 'ip-full установлен.'
}

install_luci_ru() {
  if ! version_supported; then
    info "Русская локализация LuCI: поддерживаются только OpenWrt 24.x/25.x; пропуск."
    return 0
  fi
  info "Установка/обновление русской локализации LuCI в тихом режиме..."
  pkg_add luci-i18n-base-ru >/dev/null 2>&1
  if pkg_installed luci-i18n-base-ru; then
    ok "Русская локализация LuCI установлена."
    return 0
  fi
  warn "Не удалось установить luci-i18n-base-ru; проверьте репозитории пакетов."
  return 1
}

component_installed() {
  case "$1" in
    podkop) pkg_installed podkop && [ -x /etc/init.d/podkop ] ;;
    forkop) pkg_installed forkop && [ -x /etc/init.d/forkop ] ;;
    awg)
      pkg_installed kmod-amneziawg && command -v awg >/dev/null 2>&1 ;;
    zapret-manager) zapret_manager_ready ;;
    zapret2-classic)
      [ -x /opt/zapret2/install_easy.sh ] || [ -x /opt/zapret2/init.d/openwrt/zapret2 ] ||
        [ -x /etc/init.d/zapret2 ] || [ -d /opt/zapret2/common ] ;;
    vpn-failover)
      [ -x /usr/bin/podkop-vpn-failover ] || [ -x /usr/bin/podkop-vpn-failover-control ] ||
        [ -x /etc/init.d/podkop-vpn-failover ] || [ -x /usr/bin/awg-test ] || [ -x /etc/init.d/awg-test ] ;;
    site-checker) site_checker_ready ;;
    watchdog) watchdog_ready ;;
    themes) theme_ready ;;
    ttyd) pkg_installed ttyd && pkg_installed luci-app-ttyd && command -v ttyd >/dev/null 2>&1 ;;
    sftp-server) sftp_ready ;;
    luci-ru) pkg_installed luci-i18n-base-ru ;;
    usb-modules)
      pkg_installed kmod-usb-core && pkg_installed kmod-usb-storage &&
        { pkg_installed kmod-usb3 || pkg_installed kmod-usb2 || pkg_installed kmod-usb-xhci-hcd || pkg_installed kmod-usb-xhci-mtk || pkg_installed kmod-usb-dwc3; } ;;
    *) return 1 ;;
  esac
}
version_supported() { case "$RELEASE/$PM" in 24.10.*/opkg|25.12.*/apk) return 0 ;; *) return 1 ;; esac; }
compatibility_check() {
  component="$1"
  if ! version_supported; then warn "$component: OpenWrt '${RELEASE:-неизвестна}' вне заявленного диапазона (24.x/25.x)."; return 1; fi
  [ -n "$PKG_ARCH" ] || { warn 'Архитектура не определена.'; return 1; }
  case "$component" in
    vpn-failover)
      if { [ "$PM" = apk ] && [ "$VERSION_MAJOR" != 25 ]; } || { [ "$PM" = opkg ] && [ "$VERSION_MAJOR" != 24 ]; }; then
        warn "$component: требуется OpenWrt 24.10/opkg или 25.12/apk."; return 1
      fi ;;
  esac
  return 0
}

stage_remote_installer() {
  label="$1"; url="$2"; shift 2
  case "$url" in
    https://raw.githubusercontent.com/*) ;;
    *) err 'Источник не разрешён.'; return 1 ;;
  esac
  file="$TMP_DIR/installer-$(printf '%s' "$label" | tr ' /' '__').sh"
  step "$label: загрузка установщика"
  if ! fetch "$url" "$file"; then err "Не удалось скачать установщик $label."; return 1; fi
  if ! validate_shell "$file"; then err "Установщик $label не прошёл проверку shell-синтаксиса."; return 1; fi
}
run_remote_installer() {
  stage_remote_installer "$1" "$2" || return 1
  shift 2
  sh "$file" "$@"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "$label: установщик завершился."; else err "$label: код завершения $rc."; fi
  return "$rc"
}

patch_podkop_russian_prompt() {
  file="$1"
  patched="$file.patched"
  awk '
    index($0, "Русский язык интерфейса ставим? y/n") {
      found=1
      skip=1
      print "            msg '\''Автоматически выбираем русский язык интерфейса.'\''"
      print "            pkg_remove luci-i18n-podkop*"
      print "            pkg_install \"$DOWNLOAD_DIR/$ru\""
      next
    }
    skip {
      if ($0 ~ /^[[:space:]]*done[[:space:]]*$/) skip=0
      next
    }
    { print }
    END { if (!found || skip) exit 2 }
  ' "$file" > "$patched" || {
    rm -f "$patched"
    err 'Не удалось автоматически настроить выбор русского языка в установщике Podkop.'
    return 1
  }
  mv "$patched" "$file" || { rm -f "$patched"; err 'Не удалось подготовить установщик Podkop.'; return 1; }
}
install_podkop() {
  compatibility_check podkop || return 1
  file="$TMP_DIR/podkop-install.sh"
  fetch 'https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh' "$file" || { err 'Не удалось скачать установщик Podkop.'; return 1; }
  validate_shell "$file" || { err 'Установщик Podkop не прошёл проверку синтаксиса.'; return 1; }
  patch_podkop_russian_prompt "$file" || return 1
  sh -n "$file" || { err 'Изменённый установщик Podkop не прошёл проверку синтаксиса.'; return 1; }
  sh "$file"
}
install_forkop() {
  compatibility_check forkop || return 1
  file="$TMP_DIR/forkop-install.sh"
  fetch 'https://raw.githubusercontent.com/ushan0v/forkop/main/install.sh' "$file" || { err 'Не удалось скачать установщик Forkop.'; return 1; }
  validate_shell "$file" || { err 'Установщик Forkop не прошёл проверку синтаксиса.'; return 1; }
  ensure_ip_full || { err 'Не удалось подготовить ip-full для Forkop.'; return 1; }
  sh "$file"
}
install_awg() {
  compatibility_check awg || return 1
  if run_remote_installer 'AmneziaWG Feed' 'https://raw.githubusercontent.com/2Grey/awg-openwrt/refs/heads/master/amneziawg-feed-install.sh'; then
    component_installed awg || return 1
    return 0
  else
    return 1
  fi
}
check_ip_full_installable() {
  info 'Проверка возможности установки ip-full без изменения пакетов...'
  if [ "$PM" = apk ]; then
    if pkg_installed ip-tiny; then
      # Simulate replacement without removing the installed ip-tiny first.
      apk add --simulate ip-full '!ip-tiny'
    else
      apk add --simulate ip-full
    fi
  else
    opkg --noaction install ip-full
  fi
}
prepare_zapret_manager_ip_full() {
  if pkg_installed ip-full; then
    pkg_add ip-full || warn 'Не удалось обновить ip-full; продолжаем установку Zapret Manager.'
  elif check_ip_full_installable; then
    ensure_ip_full || warn 'Не удалось установить ip-full; продолжаем установку Zapret Manager.'
  else
    warn 'Проверка установки ip-full не пройдена (несовместимость или недоступность пакетов); ip-full пропущен. Продолжаем установку Zapret Manager.'
  fi
}

zapret_manager_files_ready() {
  # The upstream panel is installed as files, independently of the Zapret
  # engine and without an opkg/apk package named zapret-manager.
  [ -s /opt/zapret-manager-luci/backend.sh ] && [ -x /opt/zapret-manager-luci/backend.sh ] &&
    [ -s /usr/libexec/rpcd/zapret-manager ] && [ -x /usr/libexec/rpcd/zapret-manager ] &&
    [ -s /usr/share/luci/menu.d/luci-app-zapret-manager.json ] &&
    [ -s /usr/share/rpcd/acl.d/luci-app-zapret-manager.json ] &&
    [ -s /www/luci-static/resources/zapret-manager/common.js ] &&
    [ -s /www/luci-static/resources/view/zapret-manager/dashboard.js ]
}
zapret_manager_ready() {
  zapret_manager_files_ready &&
    ubus -S list zapret-manager 2>/dev/null | grep -qx zapret-manager || return 1
  [ -s /www/zm-webui.html ] && [ -s /www/zm/app.js ] && [ -s /www/zm/app.css ] &&
    [ -e /usr/lib/uhttpd_ubus.so ] &&
    [ "$(uci -q get uhttpd.zmweb 2>/dev/null)" = uhttpd ] &&
    [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd running >/dev/null 2>&1
}
zapret_manager_result() {
  if ! zapret_manager_files_ready; then
    err 'Установка панели Zapret Manager неполная: отсутствуют её обязательные файлы.'
    return 1
  fi
  if ! zapret_manager_ready; then
    warn 'Панель Zapret Manager установлена. RPC или отдельный Web UI пока не готовы; проверьте их в LuCI.'
    NEEDS_SETUP=1
  fi
}
install_zapret_manager() {
  compatibility_check zapret-manager || return 1
  prepare_zapret_manager_ip_full
  run_remote_installer 'Zapret Manager' 'https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/ZapretManager_LuCI.sh' || return 1
  zapret_manager_result
}
vpn_failover_ready() {
  [ -x /usr/bin/podkop-vpn-failover ] &&
    [ -x /usr/bin/podkop-vpn-failover-control ] &&
    [ -x /etc/init.d/podkop-vpn-failover ] &&
    ubus -S list vpn-failover 2>/dev/null | grep -qx vpn-failover
}
install_vpn_failover() {
  compatibility_check vpn-failover || return 1
  run_remote_installer 'AWG Test / Podkop VPN Failover: установка/обновление' 'https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main/install.sh' || return 1
  vpn_failover_ready || { err 'VPN Failover не прошёл проверку после установки/обновления.'; return 1; }
  installed_version=$(/usr/bin/podkop-vpn-failover version 2>/dev/null | sed -n '1p')
  info "VPN Failover ${installed_version:-версия не определена}: установлен/обновлён."
}
install_usb_modules() {
  for usb_pkg in \
    kmod-usb-core kmod-usb-storage block-mount usbutils \
    kmod-usb-common kmod-usb-storage-uas kmod-fs-vfat kmod-fs-ext4 \
    kmod-fs-exfat kmod-fs-ntfs3 kmod-nls-base kmod-nls-cp437 \
    kmod-nls-iso8859-1 kmod-nls-utf8 libusb-1.0-0 \
    kmod-usb-xhci-hcd kmod-usb-xhci-mtk kmod-usb3 kmod-usb-xhci-pci \
    kmod-usb2 kmod-usb-dwc3; do
    pkg_installed "$usb_pkg" || continue
    pkg_add "$usb_pkg" || { err "Не удалось обновить USB-пакет $usb_pkg."; return 1; }
  done
  run_remote_installer 'Установка USB-модулей' 'https://raw.githubusercontent.com/TMN88/install_USB_owrt/main/usb-setup-universal.sh'
}

# Backup only explicit application paths. Archives persist outside the temporary
# directory and are private: they may contain registration/configuration data.
backup_configs() {
  backup_label=$1; shift
  BACKUP_DIR=${BACKUP_DIR:-}
  if [ -z "$BACKUP_DIR" ]; then
    mkdir -p /etc/install-packets-backups || return 1
    chmod 700 /etc/install-packets-backups || return 1
    BACKUP_DIR=$(mktemp -d /etc/install-packets-backups/run.XXXXXX) || return 1
  fi
  set -- "$@"
  backup_list="$TMP_DIR/backup-list"
  : > "$backup_list"
  for backup_path do
    [ ! -e "/$backup_path" ] || printf '%s\n' "$backup_path" >> "$backup_list"
  done
  if [ -s "$backup_list" ]; then
    tar -czf "$BACKUP_DIR/$backup_label.tgz" -C / -T "$backup_list" || return 1
    info "Резервная копия: $BACKUP_DIR/$backup_label.tgz"
  fi
}
pkg_add() {
  for package do
    info "Установка/обновление пакета $package..."
    if [ "$PM" = apk ]; then
      # OpenWrt APK uses a named add with --upgrade/--latest to update only
      # this package, including packages pinned by a local APK install.
      apk add --upgrade --latest "$package" || return 1
    elif pkg_installed "$package"; then
      opkg upgrade "$package" || return 1
    else
      opkg install "$package" || return 1
    fi
  done
}
sftp_binary() {
  for sftp_path in /usr/libexec/sftp-server /usr/lib/sftp-server /usr/lib/openssh/sftp-server; do
    if [ -x "$sftp_path" ]; then printf '%s\n' "$sftp_path"; return 0; fi
  done
  return 1
}
ssh_kind() {
  if pidof dropbear >/dev/null 2>&1; then printf dropbear
  elif pidof sshd >/dev/null 2>&1; then printf openssh
  else return 1; fi
}
sftp_ready() {
  pkg_installed openssh-sftp-server && sftp_binary >/dev/null || return 1
  case "$(ssh_kind)" in
    dropbear) [ -x /usr/libexec/sftp-server ] ;;
    openssh)
      # sshd -T reads effective configuration (including Include directives).
      sftp_subsystem=$(sshd -T 2>/dev/null | awk '$1=="subsystem" && $2=="sftp" {print $3; exit}')
      [ "$sftp_subsystem" = internal-sftp ] || [ -x "$sftp_subsystem" ] ;;
    *) return 1 ;;
  esac
}
install_sftp_server() {
  pkg_add openssh-sftp-server || return 1
  sftp_binary >/dev/null || return 1
  # Stock OpenWrt Dropbear uses this path. Never replace an existing file.
  if [ "$(ssh_kind)" = dropbear ] && [ ! -e /usr/libexec/sftp-server ] && [ ! -L /usr/libexec/sftp-server ]; then
    sftp_target=$(sftp_binary) || return 1
    mkdir -p /usr/libexec && ln -s "$sftp_target" /usr/libexec/sftp-server || return 1
  fi
  if ! sftp_ready; then
    warn 'SFTP subsystem установлен; проверьте действующий SSH-сервер и его Subsystem sftp. Настройки SSH сохранены.'
    NEEDS_SETUP=1
  fi
  info 'Termius / WinSCP: протокол SFTP, адрес и порт текущего SSH, ваши прежние учётные данные. Подключение с клиента ещё не проверено.'
}
site_checker_version() {
  [ -r /usr/share/site-checker2/VERSION ] && cat /usr/share/site-checker2/VERSION
}
site_checker_ready() {
  case "$(site_checker_version)" in 2.*) ;; *) return 1 ;; esac
  [ -x /usr/libexec/site-checker2 ] && [ -x /usr/libexec/rpcd/site-checker2 ] &&
    [ -s /www/luci-static/resources/view/site-checker2/overview.js ] &&
    [ -s /usr/share/luci/menu.d/luci-app-site-checker2.json ] &&
    ubus -S list site-checker2 2>/dev/null | grep -qx site-checker2 || return 1
  /usr/libexec/site-checker2 get_config 2>/dev/null | jsonfilter -e '@.ok' | grep -qx true
}
install_site_checker() {
  if [ -e /etc/config/sitecheck ] || [ -e /etc/config/site_checker ] || pkg_installed luci-app-sitecheck || pkg_installed luci-app-site-checker; then
    warn 'Обнаружен Site Checker 1.x: штатный установщик 2.0 удалит старую версию и её конфигурацию. Сохраняем копию.'
  fi
  backup_configs site-checker etc/config/sitecheck etc/config/sitecheck-opkg etc/config/sitecheck.opkg-save etc/config/sitecheck.opkg-old etc/config/sitecheck.opkg-dist etc/config/sitecheck.apk-new etc/config/sitecheck.apk-old etc/config/site_checker etc/sitecheck etc/site-checker etc/site-checker2 || return 1
  run_remote_installer 'Site Checker 2.0' 'https://raw.githubusercontent.com/TMN88/Site_Checker_2/main/install.sh'
}
watchdog_files_ready() {
  [ -x /etc/init.d/youtube-watchdog ] && [ -x /usr/bin/youtube-watchdog ] &&
    grep -q '^VERSION=[0-9]' /usr/bin/youtube-watchdog &&
    [ -x /usr/libexec/youtube-watchdog-probe ] &&
    [ -s /www/luci-static/resources/view/youtube-watchdog/overview.js ] &&
    [ -s /usr/share/luci/menu.d/luci-app-youtube-watchdog.json ]
}
watchdog_ready() {
  watchdog_files_ready &&
    /etc/init.d/youtube-watchdog enabled && /etc/init.d/youtube-watchdog running &&
    ubus -S list youtube-watchdog 2>/dev/null | grep -qx youtube-watchdog
}
install_watchdog() {
  [ -x /etc/init.d/zapret2 ] || [ -x /etc/init.d/zapret ] || warn 'Zapret/Zapret2 отсутствуют. Движок автоматически не устанавливается.'
  backup_configs watchdog etc/config/youtube-watchdog || return 1
  watchdog_had_config=0
  watchdog_had_service=0 watchdog_was_enabled=0 watchdog_was_running=0
  if [ -x /etc/init.d/youtube-watchdog ]; then
    watchdog_had_service=1
    /etc/init.d/youtube-watchdog enabled && watchdog_was_enabled=1
    /etc/init.d/youtube-watchdog running && watchdog_was_running=1
  fi
  if [ -f /etc/config/youtube-watchdog ]; then
    cp -p /etc/config/youtube-watchdog "$TMP_DIR/watchdog.config" || return 1
    watchdog_had_config=1
  fi
  run_remote_installer 'YouTube Watchdog: установка/обновление' 'https://raw.githubusercontent.com/TMN88/youtube-watchdog/main/update.sh'
  watchdog_rc=$?
  # Upstream may migrate the former safe default. This toolkit preserves all
  # existing options, including disabled services, on repair/reinstallation.
  if [ "$watchdog_had_config" = 1 ] && ! cmp -s "$TMP_DIR/watchdog.config" /etc/config/youtube-watchdog; then
    cp -p "$TMP_DIR/watchdog.config" /etc/config/youtube-watchdog || return 1
    if [ "$watchdog_was_running" = 1 ]; then /etc/init.d/youtube-watchdog restart || return 1; fi
  fi
  if [ "$watchdog_had_service" = 1 ]; then
    [ "$watchdog_was_enabled" = 1 ] || /etc/init.d/youtube-watchdog disable || return 1
    [ "$watchdog_was_running" = 1 ] || /etc/init.d/youtube-watchdog stop || return 1
    if [ "$watchdog_was_enabled$watchdog_was_running" != 11 ]; then NEEDS_SETUP=1; fi
  fi
  return "$watchdog_rc"
}
theme_ready() {
  active_theme=$(uci -q get luci.main.mediaurlbase) || return 1
  case "$active_theme" in /luci-static/footstrap|/luci-static/argon|/luci-static/aurora) ;; *) return 1 ;; esac
  pkg_installed "luci-theme-${active_theme##*/}" && [ -d "/www$active_theme" ]
}
install_themes() {
  backup_configs luci etc/config/luci || return 1
  cp -p /etc/config/luci "$TMP_DIR/luci.before" || return 1
  stage_remote_installer 'Темы LuCI' 'https://raw.githubusercontent.com/TMN88/install_openwrt_themes/main/install.sh' || return 1
  # Let the original installer display its own menu. Relay exactly one input
  # line and remember cancellation without logging arbitrary terminal input.
  {
    IFS= read -r theme_choice || theme_choice=0
    case "$theme_choice" in 0) : > "$TMP_DIR/theme-cancelled" ;; esac
    printf '%s\n' "$theme_choice"
  } | sh "$file"
  theme_rc=$?
  if [ "$theme_rc" != 0 ]; then
    cp -p "$TMP_DIR/luci.before" /etc/config/luci || return 1
    uci -q revert luci
    return "$theme_rc"
  fi
  if [ -f "$TMP_DIR/theme-cancelled" ]; then SKIPPED=1; fi
  if theme_ready; then RESULT_LABEL="LuCI ${active_theme##*/}"; fi
}

# All functions above are also exercised in an isolated filesystem by tests.
SELECTED=''
FAILS=0
RESULTS_FILE="$TMP_DIR/results.tsv"
: > "$RESULTS_FILE"
record_result() { printf '%s\t%s\n' "$1" "$2" >> "$RESULTS_FILE"; }
select_components() {
  selection=$(printf '%s' "$1" | tr '[:lower:],' '[:upper:] ')
  case "$selection" in
    Q) return 2 ;;
    A) SELECTED='3 6 7 8'; return 0 ;;
  esac
  SELECTED=''
  for number in $selection; do
    case "$number" in 1|2|3|4|5|6|7|8|9|10|11) ;; *) return 1 ;; esac
    case " $SELECTED " in *" $number "*) ;; *) SELECTED="${SELECTED:+$SELECTED }$number" ;; esac
  done
  [ -n "$SELECTED" ]
}
component_meta() {
  case "$1" in
    1) LABEL=Podkop; FUNC=install_podkop; DETECT=podkop ;;
    2) LABEL=Forkop; FUNC=install_forkop; DETECT=forkop ;;
    3) LABEL=AmneziaWG; FUNC=install_awg; DETECT=awg ;;
    4) LABEL='Zapret Manager'; FUNC=install_zapret_manager; DETECT=zapret-manager ;;
    5) LABEL='AWG Test / VPN Failover'; FUNC=install_vpn_failover; DETECT=vpn-failover ;;
    6) LABEL='Site Checker 2.0'; FUNC=install_site_checker; DETECT=site-checker ;;
    7) LABEL='USB Modules'; FUNC=install_usb_modules; DETECT=usb-modules ;;
    8) LABEL='YouTube Watchdog'; FUNC=install_watchdog; DETECT=watchdog ;;
    9) LABEL='SFTP Server'; FUNC=install_sftp_server; DETECT=sftp-server ;;
    10) LABEL='Темы LuCI'; FUNC=install_themes; DETECT=themes ;;
    11) LABEL='Терминал ttyd (LuCI)'; FUNC=install_ttyd; DETECT=ttyd ;;
  esac
}
conflict_check() {
  case "$1" in
    podkop)
      pkg_installed forkop && return 1
      [ ! -x /etc/init.d/forkop ] || return 1
      [ ! -f /etc/config/forkop ] || return 1 ;;
    forkop)
      pkg_installed podkop && return 1
      [ ! -x /etc/init.d/podkop ] || return 1
      [ ! -f /etc/config/podkop ] || return 1 ;;
    zapret-manager)
      # Conflict evidence is intentionally broader than installation readiness:
      # do not layer another implementation over a partial/broken installation.
      pkg_installed zapret2 && return 1
      pkg_installed luci-app-zapret2 && return 1
      [ ! -f /etc/config/zapret2 ] || return 1
      [ ! -x /etc/init.d/zapret2 ] || return 1
      [ ! -d /opt/zapret2 ] || return 1
      component_installed zapret2-classic && return 1 ;;
  esac
  return 0
}
run_component() {
  # Run each component in its own subshell: installer helper variables cannot
  # overwrite the outer component identity or another component's result.
  (
    RESULT_LABEL=$1; run_func=$2; run_detection=$3
    NEEDS_SETUP=0 SKIPPED=0
    step "$RESULT_LABEL"
    if ! compatibility_check "$run_detection"; then
      record_result "$RESULT_LABEL" 'НЕ ПОДДЕРЖИВАЕТСЯ'; exit 0
    fi
    if ! conflict_check "$run_detection"; then
      warn 'Конфликт компонентов: установка пропущена.'
      record_result "$RESULT_LABEL" 'ПРОПУЩЕНО'; exit 0
    fi
    case "$run_detection" in
      podkop|forkop|awg|zapret-manager|vpn-failover)
        backup_configs "$run_detection" etc/config/podkop etc/config/forkop etc/config/network etc/config/firewall etc/config/dhcp etc/config/zapret etc/config/zapret2 etc/config/podkop-vpn-failover || {
          record_result "$RESULT_LABEL" 'ОШИБКА'; exit 0
        } ;;
    esac
    if "$run_func"; then
      if [ "$SKIPPED" = 1 ]; then status='ПРОПУЩЕНО'
      elif [ "$NEEDS_SETUP" = 1 ]; then status='ТРЕБУЕТ НАСТРОЙКИ'
      elif component_installed "$run_detection"; then
        status='УСПЕШНО'
        if [ "$run_detection" = awg ]; then : > "$TMP_DIR/awg-installed-now"; fi
      else status='ОШИБКА'; fi
    else status='ОШИБКА'; fi
    record_result "$RESULT_LABEL" "$status"
  )
}
show_results() {
  printf '\n%s========== ИТОГИ УСТАНОВКИ ==========%s\n' "$C_CYAN" "$C_RESET"
  while IFS="$(printf '\t')" read -r result_name result_status; do
    printf '%s — %s\n' "$result_name" "$result_status"
  done < "$RESULTS_FILE"
  awk -F '\t' '
    {count[$2]++}
    END {
      printf "Успешно: %d\nУже установлено: %d\nТребует настройки: %d\nОшибки: %d\nНе поддерживается: %d\nПропущено: %d\n",
        count["УСПЕШНО"],count["УСТАНОВЛЕН РАНЕЕ"],count["ТРЕБУЕТ НАСТРОЙКИ"],count["ОШИБКА"],count["НЕ ПОДДЕРЖИВАЕТСЯ"],count["ПРОПУЩЕНО"]
    }' "$RESULTS_FILE"
}
main() {
  printf '%s\n' "${C_MAGENTA}╔══════════════════════════════════════════╗" \
    '║          INSTALL PACKETS 2.0             ║' \
    "║       UNIVERSAL OPENWRT TOOLKIT          ║" "╚══════════════════════════════════════════╝${C_RESET}"
  printf 'Роутер: %s\nOpenWrt: %s\nМенеджер пакетов: %s\nАрхитектура: %s\n' "$MODEL" "$RELEASE" "$PM" "$PKG_ARCH"
  printf '%s' "$C_GREEN"
  for menu_id in 1 2 3 4 5 6 7 8 9 10 11; do
    component_meta "$menu_id"
    printf '%2s. %s\n' "$menu_id" "$LABEL"
  done
  printf ' A. Все совместимые независимые: AmneziaWG, Site Checker 2.0, USB, Watchdog\n Q. Выход\n'
  printf '%s' "$C_RESET"
  while :; do
    printf '%sВыбор (номера через пробел или запятую): %s' "$C_CYAN" "$C_RESET"
    IFS= read -r choice || return 0
    select_components "$choice"; select_rc=$?
    [ "$select_rc" != 2 ] || return 0
    [ "$select_rc" != 0 ] || break
    warn 'Некорректный выбор. Введите номер пункта меню, A или Q.'
  done
  step 'План установки'
  for selected_id in $SELECTED; do component_meta "$selected_id"; printf ' - %s\n' "$LABEL"; done
  pkg_update || warn 'Индексы не обновлены; продолжаем с доступными пакетами.'
  run_component 'Русская локализация LuCI' install_luci_ru luci-ru
  for selected_id in $SELECTED; do
    component_meta "$selected_id"
    run_component "$LABEL" "$FUNC" "$DETECT"
  done
  show_results
  if [ -f "$TMP_DIR/awg-installed-now" ]; then
    info 'AmneziaWG установлен в этом запуске. Если модуль требует перезагрузки, выполните её вручную в удобное время.'
  fi
  FAILS=$(awk -F '\t' '$2=="ОШИБКА" {n++} END {print n+0}' "$RESULTS_FILE")
  [ "$FAILS" = 0 ]
}
main


