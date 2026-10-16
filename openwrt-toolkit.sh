#!/bin/sh
# Install Packets Script — interactive OpenWrt installer toolkit.
# Runs under BusyBox ash. Third-party installers execute as root; audit before use.
set -u

VERSION="1.4"
TMP_DIR="/tmp/install-packets-$$"
mkdir -p "$TMP_DIR" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="$(printf '\033[0m')"; C_CYAN="$(printf '\033[36m')"
  C_GREEN="$(printf '\033[32m')"; C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"; C_BOLD="$(printf '\033[1m')"
fi
info() { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err() { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step() { printf '\n%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }

[ "$(id -u)" = 0 ] || { err "Запустите скрипт от root."; exit 1; }
[ -r /etc/openwrt_release ] || { err "Этот скрипт предназначен для OpenWrt."; exit 1; }
command -v uci >/dev/null 2>&1 || { err "Не найдена команда uci."; exit 1; }
if command -v apk >/dev/null 2>&1; then PM=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg
else err "Не найден пакетный менеджер apk/opkg."; exit 1
fi

RELEASE="$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'.*/\1/p" /etc/openwrt_release | head -n 1)"
VERSION_MAJOR="$(printf '%s' "$RELEASE" | cut -d. -f1)"
TARGET="$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' 2>/dev/null || true)"
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

component_installed() {
  case "$1" in
    podkop) pkg_installed podkop || [ -x /etc/init.d/podkop ] || [ -f /etc/config/podkop ] ;;
    awg)
      pkg_installed amneziawg-tools || pkg_installed kmod-amneziawg || pkg_installed amneziawg ||
        command -v awg >/dev/null 2>&1 || [ -x /etc/init.d/amneziawg ] ;;
    zapret-manager)
      pkg_installed luci-app-zapret || pkg_installed zapret || pkg_installed zapret-manager ||
        [ -f /etc/config/zapret ] || [ -x /etc/init.d/zapret ] ;;
    zapret2-routerich)
      pkg_installed zapret2 || pkg_installed luci-app-zapret2 ||
        [ -f /etc/config/zapret2 ] || [ -x /etc/init.d/zapret2 ] ;;
    zapret2-classic)
      [ -x /opt/zapret2/install_easy.sh ] || [ -x /opt/zapret2/init.d/openwrt/zapret2 ] ||
        [ -x /etc/init.d/zapret2 ] || [ -d /opt/zapret2/common ] ;;
    vpn-failover)
      [ -x /usr/bin/podkop-vpn-failover ] || [ -x /usr/bin/podkop-vpn-failover-control ] ||
        [ -x /etc/init.d/podkop-vpn-failover ] || [ -x /usr/bin/awg-test ] || [ -x /etc/init.d/awg-test ] ;;
    site-checker)
      [ -f /usr/lib/lua/luci/controller/sitecheck.lua ] ||
        [ -f /usr/lib/lua/luci/controller/site_checker.lua ] ||
        [ -f /usr/libexec/sitecheck-check ] || pkg_installed luci-app-site-checker ;;
    *) return 1 ;;
  esac
}
version_supported() { case "$VERSION_MAJOR" in 24|25) return 0 ;; *) return 1 ;; esac; }
compatibility_check() {
  component="$1"
  if ! version_supported; then warn "$component: OpenWrt '${RELEASE:-неизвестна}' вне заявленного диапазона (24.x/25.x)."; return 1; fi
  case "$component" in
    zapret2-routerich|vpn-failover)
      if { [ "$PM" = apk ] && [ "$VERSION_MAJOR" != 25 ]; } || { [ "$PM" = opkg ] && [ "$VERSION_MAJOR" != 24 ]; }; then
        warn "$component: требуется OpenWrt 24.10/opkg или 25.12/apk."; return 1
      fi ;;
  esac
  return 0
}

run_remote_installer() {
  label="$1"; url="$2"; shift 2
  file="$TMP_DIR/installer-$(printf '%s' "$label" | tr ' /' '__').sh"
  step "$label: загрузка установщика"
  if ! fetch "$url" "$file"; then err "Не удалось скачать установщик $label."; return 1; fi
  if ! head -n 1 "$file" | grep -q '^#!' || ! sh -n "$file"; then err "Установщик $label не прошёл проверку shell-синтаксиса."; return 1; fi
  sh "$file" "$@"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "$label: установщик завершился."; else err "$label: код завершения $rc."; fi
  return "$rc"
}

install_podkop() {
  if component_installed podkop; then ok 'Podkop уже установлен; пропуск.'; return 0; fi
  compatibility_check podkop || return 1
  file="$TMP_DIR/podkop-install.sh"
  fetch 'https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh' "$file" || { err 'Не удалось скачать установщик Podkop.'; return 1; }
  sh -n "$file" || { err 'Установщик Podkop не прошёл проверку синтаксиса.'; return 1; }
  sh "$file"
}
install_awg() {
  if component_installed awg; then ok 'AmneziaWG уже обнаружен; пропуск.'; return 0; fi
  compatibility_check awg || return 1
  file="$TMP_DIR/amneziawg-install.sh"
  fetch 'https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/master/amneziawg-install.sh' "$file" || { err 'Не удалось скачать установщик AmneziaWG.'; return 1; }
  sh -n "$file" || { err 'Установщик AmneziaWG не прошёл проверку синтаксиса.'; return 1; }
  sh "$file" -n
}
install_zapret_manager() {
  if component_installed zapret-manager; then ok 'Zapret Manager уже обнаружен; пропуск.'; return 0; fi
  compatibility_check zapret-manager || return 1
  run_remote_installer 'Zapret Manager' 'https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/ZapretManager_LuCI.sh'
}
zapret_conflict_check() {
  if [ -x /etc/init.d/zapret ] || pkg_installed zapret || [ -f /etc/config/zapret ]; then
    err 'Обнаружен классический Zapret. Не устанавливайте Zapret2 поверх него: сначала вручную разберите конфликт и конфигурацию.'
    return 1
  fi
  if pkg_installed zapret2 || pkg_installed luci-app-zapret2 || [ -f /etc/config/zapret2 ] || [ -x /etc/init.d/zapret2 ] || [ -d /opt/zapret2 ]; then
    err 'Обнаружен другой вариант Zapret2. Routerich и классический Zapret2 не должны устанавливаться поверх друг друга.'
    return 1
  fi
  return 0
}
install_zapret2_routerich() {
  if component_installed zapret2-routerich; then ok 'Zapret2 уже обнаружен; пропуск.'; return 0; fi
  compatibility_check zapret2-routerich || return 1
  step 'Zapret2 от Routerich'
  zapret_conflict_check || return 1
  case "$TARGET|$PKG_ARCH" in
    'mediatek/filogic|aarch64_cortex-a53'|'mediatek/filogic|aarch64_cortex-a53'* ) ;;
    *) err "Routerich Zapret2 ограничен target mediatek/filogic и arch aarch64_cortex-a53; обнаружено: $TARGET / $PKG_ARCH. Выберите классический Zapret2."; return 1 ;;
  esac
  if [ "$VERSION_MAJOR" = 25 ] && [ "$PM" = apk ]; then Z2_BASE='https://packages.routerich.ru/25.12/mediatek/filogic/routerich'; Z2_KIND=apk
  elif [ "$VERSION_MAJOR" = 24 ] && [ "$PM" = opkg ]; then Z2_BASE='https://packages.routerich.ru/24.10/mediatek/filogic/routerich'; Z2_KIND=ipk
  else err 'Routerich Zapret2 поддерживается только на OpenWrt 24.10/opkg или 25.12/apk.'; return 1; fi
  index="$TMP_DIR/routerich-index.html"
  fetch "$Z2_BASE/" "$index" || { err 'Не удалось получить каталог пакетов Routerich.'; return 1; }
  if [ "$Z2_KIND" = apk ]; then
    MAIN_PKG="$(grep -oE 'zapret2-[0-9][^" <]*\.apk' "$index" | grep -v '^luci-' | head -n 1)"
    LUCI_PKG="$(grep -oE 'luci-app-zapret2-[0-9][^" <]*\.apk' "$index" | head -n 1)"
    RU_PKG="$(grep -oE 'luci-i18n-zapret2-ru-[0-9][^" <]*\.apk' "$index" | head -n 1)"
  else
    MAIN_PKG="$(grep -oE 'zapret2_[0-9][^" <]*_aarch64_cortex-a53\.ipk' "$index" | grep -v '^luci-' | head -n 1)"
    LUCI_PKG="$(grep -oE 'luci-app-zapret2_[0-9][^" <]*_all\.ipk' "$index" | head -n 1)"
    RU_PKG="$(grep -oE 'luci-i18n-zapret2-ru_[0-9][^" <]*_all\.ipk' "$index" | head -n 1)"
  fi
  [ -n "$MAIN_PKG" ] || { err 'Не найден основной пакет Zapret2 в каталоге Routerich.'; return 1; }
  download_ok=1
  for pkg in "$MAIN_PKG" "$LUCI_PKG" "$RU_PKG"; do
    [ -n "$pkg" ] || continue
    fetch "$Z2_BASE/$pkg" "$TMP_DIR/$pkg" || { err "Не удалось скачать $pkg."; download_ok=0; }
  done
  [ "$download_ok" = 1 ] || return 1
  if [ "$PM" = apk ]; then
    apk add --allow-untrusted "$TMP_DIR/$MAIN_PKG" || return 1
    [ -z "$LUCI_PKG" ] || apk add --allow-untrusted "$TMP_DIR/$LUCI_PKG" || warn 'Не удалось установить LuCI-пакет Zapret2.'
    [ -z "$RU_PKG" ] || apk add --allow-untrusted "$TMP_DIR/$RU_PKG" || warn 'Не удалось установить перевод Zapret2.'
  else
    opkg install "$TMP_DIR/$MAIN_PKG" || return 1
    [ -z "$LUCI_PKG" ] || opkg install "$TMP_DIR/$LUCI_PKG" || warn 'Не удалось установить LuCI-пакет Zapret2.'
    [ -z "$RU_PKG" ] || opkg install "$TMP_DIR/$RU_PKG" || warn 'Не удалось установить перевод Zapret2.'
  fi
  ok 'Пакеты Routerich установлены. Параметры запуска/конфиг следует проверить в документации пакета.'
}

install_zapret2_classic() {
  if component_installed zapret2-classic; then ok 'Классический Zapret2 уже обнаружен; пропуск.'; return 0; fi
  compatibility_check zapret2-classic || return 1
  step 'Классический Zapret2 (bol-van)'
  zapret_conflict_check || return 1
  if ! command -v tar >/dev/null 2>&1; then err 'Не найдена команда tar.'; return 1; fi
  if ! command -v gzip >/dev/null 2>&1; then warn 'Не найдена gzip; проверю доступность tar.gz архиватора.'; fi

  # Релизный easy-install bundle содержит подготовленные для OpenWrt файлы; исходный
  # git checkout нельзя просто распаковать и запустить без архитектурных бинарников.
  API="$TMP_DIR/zapret2-release.json"
  fetch 'https://api.github.com/repos/bol-van/zapret2/releases/latest' "$API" || {
    err 'Не удалось получить информацию о релизе bol-van/zapret2.'; return 1;
  }
  ASSET_URL="$(grep -o '"browser_download_url": "[^"]*"' "$API" | sed 's/^"browser_download_url": "//; s/"$//' | grep -E 'openwrt-embedded\.tar\.gz$' | head -n 1)"
  if [ -z "$ASSET_URL" ]; then
    err 'В последнем релизе не найден tar.gz/tgz bundle. Автоматическая установка остановлена: для OpenWrt нужны совместимые бинарники из релиза либо сборка SDK.'; 
    printf 'Официальная инструкция: https://github.com/bol-van/zapret2/blob/master/docs/compile/build_howto_openwrt.txt\n'
    return 1
  fi
  ARCHIVE="$TMP_DIR/zapret2-release.tar.gz"
  fetch "$ASSET_URL" "$ARCHIVE" || { err 'Не удалось скачать архив релиза.'; return 1; }
  LIST="$TMP_DIR/zapret2-archive.list"
  tar -tzf "$ARCHIVE" > "$LIST" 2>/dev/null || { err 'Архив релиза не удалось прочитать.'; return 1; }
  if ! grep -q 'install_easy.sh' "$LIST" || ! grep -q 'init.d/openwrt/zapret2' "$LIST" || ! grep -q 'binaries/.*nfqws2' "$LIST"; then
    err 'Архив не похож на подготовленный bundle Zapret2 для OpenWrt; установка отменена.'
    return 1
  fi
  EXTRACT="$TMP_DIR/zapret2-extract"
  mkdir -p "$EXTRACT" || return 1
  tar -xzf "$ARCHIVE" -C "$EXTRACT" || { err 'Не удалось распаковать релиз.'; return 1; }
  EASY="$(find "$EXTRACT" -type f -name install_easy.sh 2>/dev/null | head -n 1)"
  [ -n "$EASY" ] || { err 'В архиве не найден install_easy.sh.'; return 1; }
  BASE="$(dirname "$EASY")"
  if [ ! -d "$BASE/binaries" ] || [ ! -d "$BASE/init.d/openwrt" ] || [ ! -d "$BASE/common" ]; then
    err 'В архиве отсутствуют бинарники или файлы OpenWrt. Установка отменена.'
    return 1
  fi
  # Verify installer syntax before invocation. The upstream installer is interactive
  # and will configure firewall rules, queues and service startup.
  sh -n "$EASY" || { err 'install_easy.sh не прошёл проверку синтаксиса.'; return 1; }
  info "Найден подходящий официальный OpenWrt release bundle."
  warn 'Сейчас запустится интерактивный установщик автора. Он меняет firewall/автозапуск; внимательно проверяйте вопросы.'
  sh "$EASY"
}

install_vpn_failover() {
  if component_installed vpn-failover; then ok 'AWG Test / Podkop VPN Failover уже обнаружен; пропуск.'; return 0; fi
  compatibility_check vpn-failover || return 1
  run_remote_installer 'AWG Test / Podkop VPN Failover' 'https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main/install.sh'
}
install_site_checker() {
  if component_installed site-checker; then ok 'Site Checker уже обнаружен; пропуск.'; return 0; fi
  compatibility_check site-checker || return 1
  run_remote_installer 'Site Checker' 'https://cdn.jsdelivr.net/gh/TMN88/Site_Checker@a8a70be57225827740996d41b540b8a4b7ac20b0/install.sh'
}

PODKOP=0 AWG=0 ZM=0 ZR=0 ZC=0 PVF=0 SITE=0
clear 2>/dev/null || true
cat <<'BANNER'
╔════════════════════════════════════════════════════╗
║                INSTALL PACKETS                    ║
║      Интерактивная установка для OpenWrt           ║
╚════════════════════════════════════════════════════╝
BANNER
printf 'Роутер: %s\nOpenWrt: %s (target: %s)\nМенеджер пакетов: %s\nАрхитектура пакетов: %s\n\n' "$MODEL" "${RELEASE:-неизвестно}" "${TARGET:-неизвестно}" "$PM" "${PKG_ARCH:-неизвестна}"
cat <<'MENU'
Выберите компоненты (номера через пробел или запятую):
  1) Podkop
  2) AmneziaWG — пакеты без создания туннеля
  3) Zapret Manager (LuCI/Web UI)
  4) Zapret2 от Routerich (mediatek/filogic, aarch64_cortex-a53)
  5) Классический Zapret2 от bol-van (официальный release bundle)
  6) AWG Test / Podkop VPN Failover
  7) Site Checker (LuCI)
  A) Все компоненты (несовместимые будут пропущены)
  Q) Выход
MENU
printf '\nВаш выбор: '
read -r CHOICE || exit 0
case "$(printf '%s' "$CHOICE" | tr '[:lower:]' '[:upper:]')" in
  Q|QUIT|EXIT) exit 0 ;;
  A|ALL) PODKOP=1 AWG=1 ZM=1 ZR=1 ZC=1 PVF=1 SITE=1 ;;
  *)
    TOKENS="$(printf '%s' "$CHOICE" | tr ',' ' ')"
    for token in $TOKENS; do
      case "$token" in
        1) PODKOP=1 ;; 2) AWG=1 ;; 3) ZM=1 ;; 4) ZR=1 ;; 5) ZC=1 ;;
        6) PVF=1 ;; 7) SITE=1 ;;
        '') ;; *) warn "Неизвестный пункт: $token" ;;
      esac
    done ;;
esac
[ "$PODKOP$AWG$ZM$ZR$ZC$PVF$SITE" != 0000000 ] || { info 'Ничего не выбрано.'; exit 0; }
printf '\nБудут установлены:\n'
[ "$PODKOP" = 1 ] && printf ' - Podkop\n'
[ "$AWG" = 1 ] && printf ' - AmneziaWG (без настройки туннеля)\n'
[ "$ZM" = 1 ] && printf ' - Zapret Manager\n'
[ "$ZR" = 1 ] && printf ' - Zapret2 от Routerich\n'
[ "$ZC" = 1 ] && printf ' - Классический Zapret2 от bol-van\n'
[ "$PVF" = 1 ] && printf ' - AWG Test / Podkop VPN Failover\n'
[ "$SITE" = 1 ] && printf ' - Site Checker\n'
printf '\nУстановка изменяет системные пакеты и может повлиять на сеть. Продолжить? [y/N]: '
read -r CONFIRM || exit 0
case "$CONFIRM" in y|Y|yes|YES|д|Д|да|ДА) ;; *) info 'Отменено.'; exit 0 ;; esac

step "Обновление индексов пакетов ($PM)"
pkg_update || warn 'Обновление индексов завершилось с ошибками; некоторые установщики могут не сработать.'
FAILS=0
run_component() {
  label="$1"; function="$2"
  step "$label"
  "$function" || { err "$label: установка не завершена."; FAILS=$((FAILS + 1)); }
}
[ "$PODKOP" != 1 ] || run_component Podkop install_podkop
[ "$AWG" != 1 ] || run_component AmneziaWG install_awg
[ "$ZM" != 1 ] || run_component 'Zapret Manager' install_zapret_manager
[ "$ZR" != 1 ] || run_component 'Zapret2 Routerich' install_zapret2_routerich
[ "$ZC" != 1 ] || run_component 'Классический Zapret2' install_zapret2_classic
[ "$PVF" != 1 ] || run_component 'AWG Test / Podkop VPN Failover' install_vpn_failover
[ "$SITE" != 1 ] || run_component 'Site Checker' install_site_checker

printf '\n========================================\n'
if [ "$FAILS" -eq 0 ]; then ok 'Операции завершены без зарегистрированных ошибок.'
else warn "Завершено с ошибками: $FAILS."; fi
printf 'Перед установкой сделайте резервную копию конфигурации роутера.\n'
printf 'Сторонние установщики запускаются с правами root; внимательно читайте их сообщения.\n'
exit "$FAILS"
  ASSET_NAME="$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$API" | head -n 1)"
  if [ -z "$ASSET_URL" ]; then
    err 'В последнем релизе не найден tar.gz/tgz bundle. Автоматическая установка остановлена: для OpenWrt нужны совместимые бинарники из релиза либо сборка SDK.'; 
    printf 'Официальная инструкция: https://github.com/bol-van/zapret2/blob/master/docs/compile/build_howto_openwrt.txt\n'
    return 1
  fi
  ARCHIVE="$TMP_DIR/zapret2-release.tar.gz"
  fetch "$ASSET_URL" "$ARCHIVE" || { err 'Не удалось скачать архив релиза.'; return 1; }
  LIST="$TMP_DIR/zapret2-archive.list"
  tar -tzf "$ARCHIVE" > "$LIST" 2>/dev/null || { err 'Архив релиза не удалось прочитать.'; return 1; }
  if ! grep -q 'install_easy.sh' "$LIST" || ! grep -q 'init.d/openwrt/zapret2' "$LIST"; then
    err 'Архив не похож на подготовленный bundle Zapret2 для OpenWrt; установка отменена.'
    return 1
  fi
  EXTRACT="$TMP_DIR/zapret2-extract"
  mkdir -p "$EXTRACT" || return 1
  tar -xzf "$ARCHIVE" -C "$EXTRACT" || { err 'Не удалось распаковать релиз.'; return 1; }
  EASY="$(find "$EXTRACT" -type f -name install_easy.sh 2>/dev/null | head -n 1)"
  [ -n "$EASY" ] || { err 'В архиве не найден install_easy.sh.'; return 1; }
  BASE="$(dirname "$EASY")"
  if [ ! -d "$BASE/binaries" ] || [ ! -d "$BASE/init.d/openwrt" ]; then
    err 'В архиве отсутствуют бинарники или файлы OpenWrt. Установка отменена.'
    return 1
  fi
  # Verify installer syntax before invocation. The upstream installer is interactive
  # and will configure firewall rules, queues and service startup.
  sh -n "$EASY" || { err 'install_easy.sh не прошёл проверку синтаксиса.'; return 1; }
  info "Найден релиз: ${ASSET_NAME:-latest}"
  warn 'Сейчас запустится интерактивный установщик автора. Он меняет firewall/автозапуск; внимательно проверяйте вопросы.'
  sh "$EASY"
}

install_vpn_failover() {
  if component_installed vpn-failover; then ok 'AWG Test / Podkop VPN Failover уже обнаружен; пропуск.'; return 0; fi
  compatibility_check vpn-failover || return 1
  run_remote_installer 'AWG Test / Podkop VPN Failover' 'https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main/install.sh'
}
install_site_checker() {
  if component_installed site-checker; then ok 'Site Checker уже обнаружен; пропуск.'; return 0; fi
  compatibility_check site-checker || return 1
  run_remote_installer 'Site Checker' 'https://cdn.jsdelivr.net/gh/TMN88/Site_Checker@a8a70be57225827740996d41b540b8a4b7ac20b0/install.sh'
}

PODKOP=0 AWG=0 ZM=0 ZR=0 ZC=0 PVF=0 SITE=0
clear 2>/dev/null || true
cat <<'BANNER'
╔════════════════════════════════════════════════════╗
║                INSTALL PACKETS                    ║
║      Интерактивная установка для OpenWrt           ║
╚════════════════════════════════════════════════════╝
BANNER
printf 'Роутер: %s\nOpenWrt: %s (target: %s)\nМенеджер пакетов: %s\nАрхитектура пакетов: %s\n\n' "$MODEL" "${RELEASE:-неизвестно}" "${TARGET:-неизвестно}" "$PM" "${PKG_ARCH:-неизвестна}"
cat <<'MENU'
Выберите компоненты (номера через пробел или запятую):
  1) Podkop
  2) AmneziaWG — пакеты без создания туннеля
  3) Zapret Manager (LuCI/Web UI)
  4) Zapret2 от Routerich (mediatek/filogic, aarch64_cortex-a53)
  5) Классический Zapret2 от bol-van (официальный release bundle)
  6) AWG Test / Podkop VPN Failover
  7) Site Checker (LuCI)
  A) Все компоненты (несовместимые будут пропущены)
  Q) Выход
MENU
printf '\nВаш выбор: '
read -r CHOICE || exit 0
case "$(printf '%s' "$CHOICE" | tr '[:lower:]' '[:upper:]')" in
  Q|QUIT|EXIT) exit 0 ;;
  A|ALL) PODKOP=1 AWG=1 ZM=1 ZR=1 ZC=1 PVF=1 SITE=1 ;;
  *)
    TOKENS="$(printf '%s' "$CHOICE" | tr ',' ' ')"
    for token in $TOKENS; do
      case "$token" in
        1) PODKOP=1 ;; 2) AWG=1 ;; 3) ZM=1 ;; 4) ZR=1 ;; 5) ZC=1 ;;
        6) PVF=1 ;; 7) SITE=1 ;;
        '') ;; *) warn "Неизвестный пункт: $token" ;;
      esac
    done ;;
esac
[ "$PODKOP$AWG$ZM$ZR$ZC$PVF$SITE" != 0000000 ] || { info 'Ничего не выбрано.'; exit 0; }
printf '\nБудут установлены:\n'
[ "$PODKOP" = 1 ] && printf ' - Podkop\n'
[ "$AWG" = 1 ] && printf ' - AmneziaWG (без настройки туннеля)\n'
[ "$ZM" = 1 ] && printf ' - Zapret Manager\n'
[ "$ZR" = 1 ] && printf ' - Zapret2 от Routerich\n'
[ "$ZC" = 1 ] && printf ' - Классический Zapret2 от bol-van\n'
[ "$PVF" = 1 ] && printf ' - AWG Test / Podkop VPN Failover\n'
[ "$SITE" = 1 ] && printf ' - Site Checker\n'
printf '\nУстановка изменяет системные пакеты и может повлиять на сеть. Продолжить? [y/N]: '
read -r CONFIRM || exit 0
case "$CONFIRM" in y|Y|yes|YES|д|Д|да|ДА) ;; *) info 'Отменено.'; exit 0 ;; esac

step "Обновление индексов пакетов ($PM)"
pkg_update || warn 'Обновление индексов завершилось с ошибками; некоторые установщики могут не сработать.'
FAILS=0
run_component() {
  label="$1"; function="$2"
  step "$label"
  "$function" || { err "$label: установка не завершена."; FAILS=$((FAILS + 1)); }
}
[ "$PODKOP" != 1 ] || run_component Podkop install_podkop
[ "$AWG" != 1 ] || run_component AmneziaWG install_awg
[ "$ZM" != 1 ] || run_component 'Zapret Manager' install_zapret_manager
[ "$ZR" != 1 ] || run_component 'Zapret2 Routerich' install_zapret2_routerich
[ "$ZC" != 1 ] || run_component 'Классический Zapret2' install_zapret2_classic
[ "$PVF" != 1 ] || run_component 'AWG Test / Podkop VPN Failover' install_vpn_failover
[ "$SITE" != 1 ] || run_component 'Site Checker' install_site_checker

printf '\n========================================\n'
if [ "$FAILS" -eq 0 ]; then ok 'Операции завершены без зарегистрированных ошибок.'
else warn "Завершено с ошибками: $FAILS."; fi
printf 'Перед установкой сделайте резервную копию конфигурации роутера.\n'
printf 'Сторонние установщики запускаются с правами root; внимательно читайте их сообщения.\n'
exit "$FAILS"
