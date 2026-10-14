#!/bin/sh
# OpenWrt Toolkit — interactive installer for selected networking components.
# Intended for BusyBox ash on OpenWrt. Review upstream installers before use.
set -u

VERSION="1.2"
TMP_DIR="/tmp/install-packets-$$"
mkdir -p "$TMP_DIR" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="$(printf '\033[0m')"; C_CYAN="$(printf '\033[36m')"
  C_GREEN="$(printf '\033[32m')"; C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"; C_BOLD="$(printf '\033[1m')"
fi
info(){ printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok(){ printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err(){ printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step(){ printf '\n%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }

[ "$(id -u)" = 0 ] || { err "Запустите скрипт от root."; exit 1; }
[ -r /etc/openwrt_release ] || { err "Этот скрипт предназначен для OpenWrt."; exit 1; }
command -v uci >/dev/null 2>&1 || { err "Не найдена команда uci."; exit 1; }
if command -v apk >/dev/null 2>&1; then PM=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg
else err "Не найден пакетный менеджер apk/opkg."; exit 1
fi

RELEASE="$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'.*/\1/p" /etc/openwrt_release | head -n1)"
VERSION_MAJOR="$(printf '%s' "$RELEASE" | cut -d. -f1)"
TARGET="$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' 2>/dev/null || true)"
if [ "$PM" = opkg ]; then
  PKG_ARCH="$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" {a=$2} END{print a}')"
else
  PKG_ARCH="$(apk --print-arch 2>/dev/null || true)"
  [ -n "$PKG_ARCH" ] || PKG_ARCH="$(. /etc/apk/arch 2>/dev/null; printf '%s' "${APK_ARCH:-}")"
fi
MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || printf 'неизвестна')"

fetch(){
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$out"
  elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -O "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$out" "$url"
  else err "Нужен curl, uclient-fetch или wget."; return 127; fi
}
pkg_installed(){
  if [ "$PM" = apk ]; then apk info -e "$1" >/dev/null 2>&1
  else opkg status "$1" 2>/dev/null | grep -q '^Status: install .* installed$'; fi
}
pkg_update(){ if [ "$PM" = apk ]; then apk update; else opkg update; fi; }
component_installed(){
  case "$1" in
    podkop) pkg_installed podkop || [ -x /etc/init.d/podkop ] || [ -f /etc/config/podkop ] ;;
    awg) pkg_installed amneziawg-tools || pkg_installed kmod-amneziawg || pkg_installed amneziawg || [ -x /etc/init.d/amneziawg ] ;;
    zapret-manager) pkg_installed luci-app-zapret || pkg_installed zapret || [ -f /etc/config/zapret ] || [ -x /etc/init.d/zapret ] ;;
    zapret2) pkg_installed zapret2 || pkg_installed luci-app-zapret2 || [ -f /etc/config/zapret2 ] || [ -x /etc/init.d/zapret2 ] ;;
    vpn-failover) pkg_installed podkop-vpn-failover || pkg_installed awg-test || [ -f /etc/config/podkop-vpn-failover ] || [ -x /etc/init.d/podkop-vpn-failover ] ;;
    site-checker) pkg_installed luci-app-site-checker || [ -f /etc/config/site_checker ] || [ -x /etc/init.d/site_checker ] ;;
    *) return 1 ;;
  esac
}
show_component_status(){ label="$1"; key="$2"; if component_installed "$key"; then printf '  %-23s %s\\n' "$label" 'УЖЕ УСТАНОВЛЕН'; else printf '  %-23s %s\\n' "$label" 'не обнаружен'; fi; }
version_supported(){ case "$VERSION_MAJOR" in 23|24|25) return 0 ;; *) return 1 ;; esac; }
compatibility_check(){
  key="$1"
  if ! version_supported; then warn "$key: OpenWrt ${RELEASE:-неизвестна} вне диапазона 23.x–25.x."; return 1; fi
  case "$key" in
    vpn-failover) if [ "$PM" != opkg ] || [ "$VERSION_MAJOR" -ge 25 ]; then warn "AWG Test / Podkop VPN Failover не поддерживает текущее сочетание OpenWrt $RELEASE / $PM по ограничениям оригинального установщика."; return 1; fi ;;
    zapret2) if { [ "$PM" = apk ] && [ "$VERSION_MAJOR" != 25 ]; } || { [ "$PM" = opkg ] && [ "$VERSION_MAJOR" != 24 ]; }; then warn 'Zapret2 поддерживается скриптом только на OpenWrt 24.10/opkg или 25.12/apk.'; return 1; fi ;;
  esac
  return 0
}

install_translation(){
  for package in "$@"; do
    if pkg_installed "$package"; then return 0; fi
    if [ "$PM" = apk ]; then apk add "$package" >/dev/null 2>&1 && { ok "Русский перевод: $package"; return 0; }
    else opkg install "$package" >/dev/null 2>&1 && { ok "Русский перевод: $package"; return 0; }; fi
  done
  warn "Пакет русского перевода не найден в подключённых feeds."
  return 0
}
run_remote_installer(){
  label="$1"; url="$2"; shift 2
  file="$TMP_DIR/installer-$(printf '%s' "$label" | tr ' /' '__').sh"
  step "$label: загрузка официального установщика"
  if ! fetch "$url" "$file"; then err "Не удалось скачать установщик $label."; return 1; fi
  if ! head -n 1 "$file" | grep -q '^#!' || ! sh -n "$file"; then
    err "Файл установщика $label не прошёл проверку shell-синтаксиса."; return 1
  fi
  sh "$file" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then ok "$label: установщик завершился."; else err "$label: код завершения $rc."; fi
  return "$rc"
}

PODKOP=0 AWG=0 ZM=0 Z2=0 PVF=0 SITE=0
clear 2>/dev/null || true
cat <<'BANNER'
╔════════════════════════════════════════════════════╗
║                INSTALL PACKETS                    ║
║      Интерактивная установка для OpenWrt           ║
╚════════════════════════════════════════════════════╝
BANNER
printf 'Роутер: %s\nOpenWrt: %s (target: %s)\nМенеджер пакетов: %s\nАрхитектура пакетов: %s\n\n' "$MODEL" "${RELEASE:-неизвестно}" "${TARGET:-неизвестно}" "$PM" "${PKG_ARCH:-неизвестно}"
cat <<'MENU'
Выберите компоненты (номера через пробел или запятую):
  1) Podkop
  2) AmneziaWG — пакеты без создания туннеля
  3) Zapret Manager (LuCI/Web UI)
  4) Zapret2 от Routerich (только поддерживаемая платформа)
  5) AWG Test / Podkop VPN Failover
  6) Site Checker (LuCI)
  A) Все компоненты (несовместимые будут пропущены)
  Q) Выход
MENU
printf '\nВаш выбор: '
read -r CHOICE || exit 0
case "$(printf '%s' "$CHOICE" | tr '[:lower:]' '[:upper:]')" in
  Q|QUIT|EXIT) exit 0 ;;
  A|ALL) PODKOP=1 AWG=1 ZM=1 Z2=1 PVF=1 SITE=1 ;;
  *)
    TOKENS="$(printf '%s' "$CHOICE" | tr ',' ' ')"
    for token in $TOKENS; do
      case "$token" in
        1) PODKOP=1 ;; 2) AWG=1 ;; 3) ZM=1 ;; 4) Z2=1 ;; 5) PVF=1 ;; 6) SITE=1 ;;
        '') ;; *) warn "Неизвестный пункт: $token" ;;
      esac
    done ;;
esac
[ "$PODKOP$AWG$ZM$Z2$PVF$SITE" != "000000" ] || { info "Ничего не выбрано."; exit 0; }
printf '\nБудут установлены:\n'
[ "$PODKOP" = 1 ] && printf ' - Podkop\n'
[ "$AWG" = 1 ] && printf ' - AmneziaWG (без настройки туннеля)\n'
[ "$ZM" = 1 ] && printf ' - Zapret Manager\n'
[ "$Z2" = 1 ] && printf ' - Zapret2 от Routerich\n'
[ "$PVF" = 1 ] && printf ' - AWG Test / Podkop VPN Failover\n'
[ "$SITE" = 1 ] && printf ' - Site Checker\n'
printf '\nУстановка изменяет систему и может повлиять на сеть. Продолжить? [y/N]: '
read -r CONFIRM || exit 0
case "$CONFIRM" in y|Y|yes|YES|д|Д|да|ДА) ;; *) info "Отменено."; exit 0 ;; esac

step "Обновление списка пакетов ($PM)"
pkg_update || warn "Обновление списка пакетов не удалось; установщики могут повторить попытку."
FAILS=0

if [ "$PODKOP" = 1 ]; then
  if component_installed 'podkop'; then
    ok 'Podkop: уже установлен, повторная установка пропущена.'
  elif ! compatibility_check 'podkop'; then
    FAILS=$((FAILS+1))
  else
  step "Podkop"
  FILE="$TMP_DIR/podkop-install.sh"
  if fetch "https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh" "$FILE" && sh -n "$FILE"; then
    # Do not auto-approve configuration migration or package removal.
    # Leave the official installer interactive, including language choice.
    sh "$FILE" || FAILS=$((FAILS+1))
  else err "Не удалось скачать или проверить установщик Podkop."; FAILS=$((FAILS+1)); fi
fi

  fi
if [ "$AWG" = 1 ]; then
  if component_installed 'awg'; then
    ok 'AmneziaWG: уже установлен, повторная установка пропущена.'
  elif ! compatibility_check 'awg'; then
    FAILS=$((FAILS+1))
  else
  FILE="$TMP_DIR/amneziawg-install.sh"
  if fetch "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh" "$FILE" && sh -n "$FILE"; then
    # Official options: -n skips tunnel setup; script prompts remain visible to the user.
    sh "$FILE" -n || FAILS=$((FAILS+1))
  else err "Не удалось скачать или проверить установщик AmneziaWG."; FAILS=$((FAILS+1)); fi
fi

  fi
if [ "$ZM" = 1 ]; then
  if component_installed 'zapret-manager'; then
    ok 'Zapret Manager: уже установлен, повторная установка пропущена.'
  elif ! compatibility_check 'zapret-manager'; then
    FAILS=$((FAILS+1))
  else
  run_remote_installer "Zapret Manager" "https://raw.githubusercontent.com/StressOzz/Zapret-Manager/refs/heads/main/ZapretManager_LuCI.sh" || FAILS=$((FAILS+1))
fi

  fi
if [ "$Z2" = 1 ]; then
  if component_installed 'zapret2'; then
    ok 'Zapret2: уже установлен, повторная установка пропущена.'
  elif ! compatibility_check 'zapret2'; then
    FAILS=$((FAILS+1))
  else
  step "Zapret2 от Routerich"
  if [ -f /etc/init.d/zapret ] || pkg_installed zapret; then
    err "Обнаружен обычный Zapret. Удалите его вручную перед установкой Zapret2."; FAILS=$((FAILS+1))
  elif [ "$PKG_ARCH" != "aarch64_cortex-a53" ] || [ "$TARGET" != "mediatek/filogic" ]; then
    err "Zapret2 от Routerich предназначен для aarch64_cortex-a53 / mediatek/filogic; обнаружено: $PKG_ARCH / $TARGET"; FAILS=$((FAILS+1))
  else
    Z2_BASE=""
    if [ "$VERSION_MAJOR" = 25 ] && [ "$PM" = apk ]; then Z2_BASE="https://packages.routerich.ru/25.12/mediatek/filogic/routerich"; Z2_KIND=apk
    elif [ "$VERSION_MAJOR" = 24 ] && [ "$PM" = opkg ]; then Z2_BASE="https://packages.routerich.ru/24.10/mediatek/filogic/routerich"; Z2_KIND=ipk
    else err "Для Zapret2 поддерживаются OpenWrt 24.10 (opkg) и 25.12 (apk)."; FAILS=$((FAILS+1)); fi
    if [ -n "$Z2_BASE" ]; then
      INDEX="$TMP_DIR/routerich-index.html"
      if fetch "$Z2_BASE/" "$INDEX"; then
        if [ "$Z2_KIND" = apk ]; then
          MAIN_PKG="$(grep -oE 'zapret2-[0-9][^" ]*\.apk' "$INDEX" | head -n1)"
          LUCI_PKG="$(grep -oE 'luci-app-zapret2-[0-9][^" ]*\.apk' "$INDEX" | head -n1)"
          RU_PKG="$(grep -oE 'luci-i18n-zapret2-ru-[0-9][^" ]*\.apk' "$INDEX" | head -n1)"
        else
          MAIN_PKG="$(grep -oE 'zapret2_[0-9][^" ]*_aarch64_cortex-a53\.ipk' "$INDEX" | head -n1)"
          LUCI_PKG="$(grep -oE 'luci-app-zapret2_[0-9][^" ]*_all\.ipk' "$INDEX" | head -n1)"
          RU_PKG="$(grep -oE 'luci-i18n-zapret2-ru_[0-9][^" ]*_all\.ipk' "$INDEX" | head -n1)"
        fi
        if [ -z "$MAIN_PKG" ]; then
          err "В каталоге Routerich не найден пакет zapret2."; FAILS=$((FAILS+1))
        else
          DOWNLOAD_OK=1
          for fn in "$MAIN_PKG" "$LUCI_PKG" "$RU_PKG"; do
            [ -n "$fn" ] || continue
            fetch "$Z2_BASE/$fn" "$TMP_DIR/$fn" || { err "Не удалось скачать $fn."; DOWNLOAD_OK=0; }
          done
          if [ "$DOWNLOAD_OK" = 1 ]; then
            if [ "$PM" = opkg ]; then
              opkg install "$TMP_DIR/$MAIN_PKG" || { err "Не удалось установить Zapret2."; FAILS=$((FAILS+1)); }
              [ -z "$LUCI_PKG" ] || opkg install "$TMP_DIR/$LUCI_PKG" || warn "Не удалось установить LuCI-панель Zapret2."
              if [ -n "$RU_PKG" ]; then opkg install "$TMP_DIR/$RU_PKG" || install_translation luci-i18n-zapret2-ru; fi
            else
              apk add --allow-untrusted "$TMP_DIR/$MAIN_PKG" || { err "Не удалось установить Zapret2."; FAILS=$((FAILS+1)); }
              [ -z "$LUCI_PKG" ] || apk add --allow-untrusted "$TMP_DIR/$LUCI_PKG" || warn "Не удалось установить LuCI-панель Zapret2."
              if [ -n "$RU_PKG" ]; then apk add --allow-untrusted "$TMP_DIR/$RU_PKG" || install_translation luci-i18n-zapret2-ru; fi
            fi
            # These strategy/helper files are taken from the Zapret-Manager project.
            mkdir -p /opt/zapret2/ipset /opt/zapret2/init.d/openwrt/custom.d
            fetch "https://raw.githubusercontent.com/StressOzz/Zapret-Manager/refs/heads/main/files/Zapret2/zapret2" "$TMP_DIR/zapret2-config" || warn "Не удалось скачать базовый конфиг Zapret2."
            fetch "https://raw.githubusercontent.com/StressOzz/Zapret-Manager/refs/heads/main/files/Zapret2/zapret_hosts_discord.txt" "$TMP_DIR/zapret_hosts_discord.txt" || true
            fetch "https://raw.githubusercontent.com/StressOzz/Zapret-Manager/refs/heads/main/files/Zapret2/50-discord_media.sh" "$TMP_DIR/50-discord_media.sh" || true
            if [ -f "$TMP_DIR/zapret2-config" ]; then
              [ ! -f /etc/config/zapret2 ] || cp /etc/config/zapret2 "/etc/config/zapret2.bak.$(date +%Y%m%d%H%M%S)" || warn "Не удалось сохранить старый конфиг."
              cp "$TMP_DIR/zapret2-config" /etc/config/zapret2 || warn "Не удалось установить конфиг Zapret2."
            fi
            [ ! -f "$TMP_DIR/zapret_hosts_discord.txt" ] || cp "$TMP_DIR/zapret_hosts_discord.txt" /opt/zapret2/ipset/zapret_hosts_discord.txt
            if [ -f "$TMP_DIR/50-discord_media.sh" ]; then cp "$TMP_DIR/50-discord_media.sh" /opt/zapret2/init.d/openwrt/custom.d/50-discord_media.sh && chmod 755 /opt/zapret2/init.d/openwrt/custom.d/50-discord_media.sh; fi
            if [ -x /etc/init.d/zapret2 ]; then
              /etc/init.d/zapret2 enable && /etc/init.d/zapret2 restart && ok "Zapret2 запущен." || { err "Zapret2 установлен, но не запустился."; FAILS=$((FAILS+1)); }
            else err "Не найден сервис /etc/init.d/zapret2 после установки."; FAILS=$((FAILS+1)); fi
          else FAILS=$((FAILS+1)); fi
        fi
      else err "Не удалось получить список пакетов Routerich."; FAILS=$((FAILS+1)); fi
    fi
  fi
fi

  fi
if [ "$PVF" = 1 ]; then
  if component_installed 'vpn-failover'; then
    ok 'AWG Test / Podkop VPN Failover: уже установлен, повторная установка пропущена.'
  elif ! compatibility_check 'vpn-failover'; then
    FAILS=$((FAILS+1))
  else
  if [ "$PM" != opkg ] || [ "$VERSION_MAJOR" -ge 25 ]; then
    warn "AWG Test / Podkop VPN Failover пропущен: оригинальный установщик требует совместимую систему с opkg."
  else
    run_remote_installer "AWG Test / Podkop VPN Failover" "https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh" || FAILS=$((FAILS+1))
  fi
fi

  fi
if [ "$SITE" = 1 ]; then
  if component_installed 'site-checker'; then
    ok 'Site Checker: уже установлен, повторная установка пропущена.'
  elif ! compatibility_check 'site-checker'; then
    FAILS=$((FAILS+1))
  else
  run_remote_installer "Site Checker" "https://cdn.jsdelivr.net/gh/TMN88/Site_Checker@a8a70be57225827740996d41b540b8a4b7ac20b0/install.sh" || FAILS=$((FAILS+1))
fi

printf '\n========================================\n'
  fi
if [ "$FAILS" -eq 0 ]; then ok "Готово. Проверьте состояние компонентов в LuCI."
else warn "Завершено с ошибками/пропусками: $FAILS."; fi
printf 'Перед установкой рекомендуется сделать резервную копию конфигурации роутера.\n'
printf 'Сторонние установщики запускаются с правами root; читайте их вопросы и сообщения.\n'
exit "$FAILS"
