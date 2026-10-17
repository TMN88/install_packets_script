#!/bin/sh
# Install Packets Script — interactive OpenWrt installer toolkit.
# Runs under BusyBox ash. Third-party installers execute as root; audit before use.
set -u

VERSION="1.12"
TMP_DIR="/tmp/install-packets-$$"
mkdir -p "$TMP_DIR" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_MAGENTA='' C_MAIN=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="$(printf '\033[0m')"
  C_CYAN="$(printf '\033[96m')"       # неоновый голубой — информация
  C_GREEN="$(printf '\033[92m')"      # неоновый зелёный — успех
  C_YELLOW="$(printf '\033[93m')"     # яркий жёлтый — предупреждения
  C_RED="$(printf '\033[91m')"        # неоновый красный — ошибки
  C_BOLD="$(printf '\033[95m')"       # пурпурный — этапы
  C_MAGENTA="$(printf '\033[95m')"    # пурпурный — баннер
  C_MAIN="$(printf '\033[96m')"       # основной текст интерфейса
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

install_luci_ru() {
  if ! version_supported; then
    info "Русская локализация LuCI: поддерживаются только OpenWrt 24.x/25.x; пропуск."
    return 0
  fi
  if pkg_installed luci-i18n-base-ru; then
    ok "Русская локализация LuCI уже установлена; пропуск."
    return 0
  fi
  info "Установка русской локализации LuCI в тихом режиме..."
  if [ "$PM" = apk ]; then
    apk add --no-progress luci-i18n-base-ru >/dev/null 2>&1
  else
    opkg install luci-i18n-base-ru >/dev/null 2>&1
  fi
  if pkg_installed luci-i18n-base-ru; then
    ok "Русская локализация LuCI установлена."
    return 0
  fi
  warn "Не удалось установить luci-i18n-base-ru; проверьте репозитории пакетов."
  return 1
}

component_installed() {
  case "$1" in
    podkop|forkop) pkg_installed podkop || pkg_installed forkop || [ -x /etc/init.d/podkop ] || [ -f /etc/config/podkop ] || [ -f /etc/config/forkop ] ;;
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
      pkg_installed luci-app-site-checker ||
        [ -f /usr/lib/lua/luci/controller/sitecheck.lua ] ||
        [ -f /usr/lib/lua/luci/controller/site_checker.lua ] ||
        [ -f /usr/lib/lua/luci/view/sitecheck/index.htm ] ||
        [ -f /usr/libexec/sitecheck-check ] ||
        [ -f /usr/libexec/sitecheck-check-zapret ] ||
        [ -f /usr/libexec/sitecheck-system-sites ] ||
        [ -f /usr/share/luci/menu.d/luci-app-site-checker.json ] ||
        { [ -f /etc/config/sitecheck ] && [ -f /usr/lib/lua/luci/view/sitecheck/index.htm ]; } ;;
    luci-ru) pkg_installed luci-i18n-base-ru ;;
    usb-modules)
      pkg_installed kmod-usb-core && pkg_installed kmod-usb-storage &&
        { pkg_installed kmod-usb3 || pkg_installed kmod-usb2 || pkg_installed kmod-usb-xhci-hcd || pkg_installed kmod-usb-xhci-mtk || pkg_installed kmod-usb-dwc3; } ;;
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
  if component_installed podkop; then ok 'Podkop уже установлен; пропуск.'; return 0; fi
  compatibility_check podkop || return 1
  file="$TMP_DIR/podkop-install.sh"
  fetch 'https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh' "$file" || { err 'Не удалось скачать установщик Podkop.'; return 1; }
  sh -n "$file" || { err 'Установщик Podkop не прошёл проверку синтаксиса.'; return 1; }
  patch_podkop_russian_prompt "$file" || return 1
  sh -n "$file" || { err 'Изменённый установщик Podkop не прошёл проверку синтаксиса.'; return 1; }
  sh "$file"
}
install_forkop() {
  if component_installed forkop; then ok 'Forkop уже обнаружен; пропуск.'; return 0; fi
  compatibility_check forkop || return 1
  file="$TMP_DIR/forkop-install.sh"
  fetch 'https://raw.githubusercontent.com/ushan0v/forkop/main/install.sh' "$file" || { err 'Не удалось скачать установщик Forkop.'; return 1; }
  sh -n "$file" || { err 'Установщик Forkop не прошёл проверку синтаксиса.'; return 1; }
  sh "$file"
}
AWG_INSTALLED_NOW=0
install_awg() {
  if component_installed awg; then ok 'AmneziaWG уже обнаружен; пропуск.'; return 0; fi
  compatibility_check awg || return 1
  if run_remote_installer 'AmneziaWG Feed' 'https://raw.githubusercontent.com/2Grey/awg-openwrt/refs/heads/master/amneziawg-feed-install.sh'; then
    AWG_INSTALLED_NOW=1
    return 0
  else
    return 1
  fi
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
routerich_abort() { err "$1"; return 1; }
install_zapret2_routerich() {
  if component_installed zapret2-routerich; then ok 'Zapret2 уже обнаружен; пропуск.'; return 0; fi
  step 'Zapret2 от Routerich'
  compatibility_check zapret2-routerich || {
    routerich_abort 'Routerich Zapret2 не поддерживается этой версией OpenWrt. Классический Zapret2 автоматически не устанавливается.'
    return $?
  }
  zapret_conflict_check || return 1
  # OpenWrt 25.12 с apk часто сообщает общую архитектуру "aarch64",
  # хотя сам роутер относится к платформе Filogic (Cortex-A53).
  # Для OpenWrt 24.10/opkg архитектура обычно указывается как aarch64_cortex-a53.
  case "$TARGET|$PKG_ARCH" in
    'mediatek/filogic|aarch64_cortex-a53'|'mediatek/filogic|aarch64_cortex-a53'*|'mediatek/filogic|aarch64'|'mediatek/filogic|aarch64'* ) ;;
    *)
      routerich_abort "Routerich Zapret2 не подходит для target/архитектуры $TARGET / $PKG_ARCH. Ожидается mediatek/filogic с архитектурой aarch64 или aarch64_cortex-a53."
      return $? ;;
  esac
  if [ "$VERSION_MAJOR" = 25 ] && [ "$PM" = apk ]; then Z2_BASE='https://packages.routerich.ru/25.12/mediatek/filogic/routerich'; Z2_KIND=apk
  elif [ "$VERSION_MAJOR" = 24 ] && [ "$PM" = opkg ]; then Z2_BASE='https://packages.routerich.ru/24.10/mediatek/filogic/routerich'; Z2_KIND=ipk
  else
    routerich_abort 'Routerich Zapret2 поддерживается только на OpenWrt 24.10/opkg или 25.12/apk. Классический Zapret2 автоматически не устанавливается.'
    return $?
  fi
  index="$TMP_DIR/routerich-index.html"
  if ! fetch "$Z2_BASE/" "$index"; then
    routerich_abort 'Не удалось получить каталог пакетов Routerich. Установка остановлена; классический Zapret2 автоматически не устанавливается.'
    return $?
  fi
  if [ "$Z2_KIND" = apk ]; then
    MAIN_PKG="$(grep -oE 'zapret2-[0-9][^" <]*\.apk' "$index" | grep -v '^luci-' | head -n 1)"
    LUCI_PKG="$(grep -oE 'luci-app-zapret2-[0-9][^" <]*\.apk' "$index" | head -n 1)"
    RU_PKG="$(grep -oE 'luci-i18n-zapret2-ru-[0-9][^" <]*\.apk' "$index" | head -n 1)"
  else
    MAIN_PKG="$(grep -oE 'zapret2_[0-9][^" <]*_aarch64_cortex-a53\.ipk' "$index" | grep -v '^luci-' | head -n 1)"
    LUCI_PKG="$(grep -oE 'luci-app-zapret2_[0-9][^" <]*_all\.ipk' "$index" | head -n 1)"
    RU_PKG="$(grep -oE 'luci-i18n-zapret2-ru_[0-9][^" <]*_all\.ipk' "$index" | head -n 1)"
  fi
  if [ -z "$MAIN_PKG" ]; then
    routerich_abort 'Не найден основной пакет Zapret2 в каталоге Routerich. Классический Zapret2 автоматически не устанавливается.'
    return $?
  fi
  download_ok=1
  for pkg in "$MAIN_PKG" "$LUCI_PKG" "$RU_PKG"; do
    [ -n "$pkg" ] || continue
    fetch "$Z2_BASE/$pkg" "$TMP_DIR/$pkg" || { err "Не удалось скачать $pkg."; download_ok=0; }
  done
  if [ "$download_ok" != 1 ]; then
    routerich_abort 'Не удалось скачать все необходимые пакеты Routerich. Классический Zapret2 автоматически не устанавливается.'
    return $?
  fi
  if [ "$PM" = apk ]; then
    apk add --allow-untrusted "$TMP_DIR/$MAIN_PKG" || {
      routerich_abort 'Не удалось установить основной пакет Routerich Zapret2. Классический Zapret2 автоматически не устанавливается.'
      return $?
    }
    [ -z "$LUCI_PKG" ] || apk add --allow-untrusted "$TMP_DIR/$LUCI_PKG" || warn 'Не удалось установить LuCI-пакет Zapret2.'
    [ -z "$RU_PKG" ] || apk add --allow-untrusted "$TMP_DIR/$RU_PKG" || warn 'Не удалось установить перевод Zapret2.'
  else
    opkg install "$TMP_DIR/$MAIN_PKG" || {
      routerich_abort 'Не удалось установить основной пакет Routerich Zapret2. Классический Zapret2 автоматически не устанавливается.'
      return $?
    }
    [ -z "$LUCI_PKG" ] || opkg install "$TMP_DIR/$LUCI_PKG" || warn 'Не удалось установить LuCI-пакет Zapret2.'
    [ -z "$RU_PKG" ] || opkg install "$TMP_DIR/$RU_PKG" || warn 'Не удалось установить перевод Zapret2.'
  fi
  ok 'Пакеты Routerich установлены. Параметры запуска/конфиг следует проверить в документации пакета.'
}

install_vpn_failover() {
  if component_installed vpn-failover; then ok 'AWG Test / Podkop VPN Failover уже обнаружен; пропуск.'; return 0; fi
  compatibility_check vpn-failover || return 1
  run_remote_installer 'AWG Test / Podkop VPN Failover' 'https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main/install.sh'
}
install_site_checker() {
  if component_installed site-checker; then ok 'Site Checker уже обнаружен; пропуск.'; return 0; fi
  compatibility_check site-checker || return 1
  run_remote_installer 'Site Checker' 'https://cdn.jsdelivr.net/gh/TMN88/Site_Checker@ed1e31ac4e5e8fa662532b58bf7fb6dbf89375b7/install.sh'
}
install_usb_modules() {
  run_remote_installer 'Установка USB-модулей' 'https://raw.githubusercontent.com/TMN88/install_USB_owrt/main/usb-setup-universal.sh'
}

PODKOP=0 FORKOP=0 AWG=0 ZM=0 ZR=0 PVF=0 SITE=0 USB=0
clear 2>/dev/null || true
# ASCII-рамка фиксированной ширины для ровного отображения в терминалах.
printf '%s' "$C_MAGENTA"
cat <<'BANNER'
+----------------------------------------------------+
|                  INSTALL PACKETS                   |
|        Интерактивная установка для OpenWrt         |
+----------------------------------------------------+
BANNER
printf '%s' "$C_RESET"
printf '%s' "$C_MAIN"
printf 'Роутер: %s\nOpenWrt: %s (target: %s)\nМенеджер пакетов: %s\nАрхитектура пакетов: %s\n\n' "$MODEL" "${RELEASE:-неизвестно}" "${TARGET:-неизвестно}" "$PM" "${PKG_ARCH:-неизвестна}"
cat <<'MENU'
Выберите компоненты (номера через пробел или запятую):
  1) Podkop
  2) Forkop
  3) AmneziaWG
  4) Zapret Manager (LuCI/Web UI)
  5) Zapret2 Routerich (только cortex_a53)
  6) AWG Test
  7) Site Checker
  8) Установка модулей для USB
  A) Все компоненты (Podkop, Forkop и USB выбираются отдельно)
  Q) Выход
MENU
printf '%s' "$C_RESET"
while :; do
  printf '\nВаш выбор (1-8, номера через пробел/запятую, A — все, Q — выход): '
  if ! IFS= read -r CHOICE; then
    info 'Ввод завершён. Выход без изменений.'
    exit 0
  fi
  CHOICE="$(printf '%s' "$CHOICE" | tr '[:lower:]' '[:upper:]')"
  case "$CHOICE" in
    Q|QUIT|EXIT) exit 0 ;;
    A|ALL) PODKOP=1 FORKOP=1 AWG=1 ZM=1 ZR=1 PVF=1 SITE=1 USB=1; break ;;
  esac

  TOKENS="$(printf '%s' "$CHOICE" | tr ',' ' ')"
  VALID=1
  SEEN=0
  for token in $TOKENS; do
    SEEN=1
    case "$token" in
      1|2|3|4|5|6|7|8) ;;
      *) VALID=0; break ;;
    esac
  done
  if [ "$SEEN" != 1 ] || [ "$VALID" != 1 ]; then
    warn 'Некорректный выбор. Введите номера от 1 до 8, A для всех компонентов или Q для выхода.'
    continue
  fi

  for token in $TOKENS; do
    case "$token" in
      1) PODKOP=1 ;; 2) FORKOP=1 ;; 3) AWG=1 ;; 4) ZM=1 ;; 5) ZR=1 ;;
      6) PVF=1 ;; 7) SITE=1 ;; 8) USB=1 ;;
    esac
  done
  break
done
[ "${PODKOP}${FORKOP}${AWG}${ZM}${ZR}${PVF}${SITE}${USB}" != 00000000 ] || { info 'Ничего не выбрано.'; exit 0; }
[ "$PODKOP" = 1 ] && printf ' - Podkop\n'
[ "$FORKOP" = 1 ] && printf ' - Forkop (Podkop Plus)\n'
[ "$AWG" = 1 ] && printf ' - AmneziaWG (без настройки туннеля)\n'
[ "$ZM" = 1 ] && printf ' - Zapret Manager\n'
[ "$ZR" = 1 ] && printf ' - Zapret2 от Routerich\n'
[ "$PVF" = 1 ] && printf ' - AWG Test / Podkop VPN Failover\n'
[ "$SITE" = 1 ] && printf ' - Site Checker\n'
[ "$USB" = 1 ] && printf ' - Модули USB\n'
CONFIRM=Y
case "$CONFIRM" in y|Y|yes|YES|д|Д|да|ДА) ;; *) info 'Отменено.'; exit 0 ;; esac

step "Обновление индексов пакетов ($PM)"
pkg_update || warn 'Обновление индексов завершилось с ошибками; некоторые установщики могут не сработать.'
FAILS=0
RESULTS_FILE="$TMP_DIR/results.tsv"
: > "$RESULTS_FILE"
record_result() { printf '%s\t%s\n' "$1" "$2" >> "$RESULTS_FILE"; }
run_component() {
  label="$1"; function="$2"; detection="$3"
  step "$label"
  if component_installed "$detection"; then
    record_result "$label" "УСТАНОВЛЕН РАНЕЕ"
    info "$label уже установлен; повторная установка пропущена."
    return 0
  fi
  if "$function"; then
    record_result "$label" "УСПЕШНО"
  else
    err "$label: установка не завершена."
    record_result "$label" "ОШИБКА / НЕ ЗАВЕРШЕНО"
    FAILS=$((FAILS + 1))
  fi
}
if version_supported; then
  run_component "Русская локализация LuCI" install_luci_ru luci-ru
fi
[ "$PODKOP" != 1 ] || run_component Podkop install_podkop podkop
[ "$FORKOP" != 1 ] || run_component Forkop install_forkop forkop
[ "$AWG" != 1 ] || run_component AmneziaWG install_awg awg
[ "$ZM" != 1 ] || run_component 'Zapret Manager' install_zapret_manager zapret-manager
[ "$ZR" != 1 ] || run_component 'Zapret2 Routerich' install_zapret2_routerich zapret2-routerich
[ "$PVF" != 1 ] || run_component 'AWG Test / Podkop VPN Failover' install_vpn_failover vpn-failover
[ "$SITE" != 1 ] || run_component 'Site Checker' install_site_checker site-checker
[ "$USB" != 1 ] || run_component 'Модули USB' install_usb_modules usb-modules

printf '\n%s========================================%s\n' "$C_CYAN" "$C_RESET"
printf '%sИТОГИ УСТАНОВКИ%s\n' "$C_CYAN" "$C_RESET"
printf '%s----------------------------------------%s\n' "$C_CYAN" "$C_RESET"
if [ ! -s "$RESULTS_FILE" ]; then
  printf '%sКомпоненты не были обработаны.%s\n' "$C_CYAN" "$C_RESET"
else
  while IFS="$(printf '\t')" read -r result_name result_status; do
    [ -n "$result_name" ] || continue
    printf '%s[ %s ] %s — %s%s\n' "$C_CYAN" "$result_status" "$result_name" "$result_status" "$C_RESET"
  done < "$RESULTS_FILE"
fi
if [ "$FAILS" -eq 0 ]; then
  printf '%sОперации завершены без зарегистрированных ошибок.%s\n' "$C_CYAN" "$C_RESET"
else
  printf '%sЗавершено с ошибками: %s.%s\n' "$C_CYAN" "$FAILS" "$C_RESET"
fi

step 'Очистка временных файлов'
if [ -d "$TMP_DIR" ]; then
  rm -rf "$TMP_DIR" && ok 'Временные файлы текущего запуска удалены.' || warn 'Не удалось полностью удалить временные файлы текущего запуска.'
fi
for old_tmp in /tmp/install-packets-*; do
  [ -d "$old_tmp" ] || continue
  [ "$old_tmp" = "$TMP_DIR" ] && continue
  old_name="${old_tmp##*/}"
  old_pid="${old_name#install-packets-}"
  case "$old_pid" in
    ''|*[!0-9]*) continue ;;
  esac
  if kill -0 "$old_pid" 2>/dev/null; then
    continue
  fi
  if rm -rf "$old_tmp"; then
    ok "Удалён старый временный каталог: $old_name"
  else
    warn "Не удалось удалить временный каталог: $old_name"
  fi
done
if [ "$AWG_INSTALLED_NOW" -eq 1 ]; then
  printf '\nТребуется перезагрузить роутер, чтобы применить изменения AmneziaWG.\n'
  printf 'Перезагрузить роутер сейчас? [y/N]: '
  read -r REBOOT_CHOICE || REBOOT_CHOICE=''
  case "$REBOOT_CHOICE" in
    y|Y|yes|YES|д|Д|да|ДА)
      warn 'Роутер будет перезагружен. Текущее SSH-соединение отключится.'
      sync
      reboot
      ;;
    *) info 'Перезагрузка пропущена. Выполните её позднее командой: reboot' ;;
  esac
fi
exit "$FAILS"

