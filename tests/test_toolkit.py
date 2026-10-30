"""Execute real shell functions against private fixtures; never run upstream code.

Absolute application paths are rewritten ONLY in this test copy. Production has
no test-root override. Package managers, network, UCI and services are mocks.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tarfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'openwrt-toolkit.sh').read_text(encoding='utf-8')
SH = os.environ.get('TEST_SH', shutil.which('sh') or 'sh')


def shell_path(path):
    value = str(path).replace('\\', '/')
    if re.match(r'^[A-Za-z]:', value):
        value = '/' + value[0].lower() + value[2:]
    return value


class Toolkit(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='toolkit-test-', dir=Path.cwd())
        self.root = Path(self.temp.name)
        self.r = './' + self.root.name
        for d in ('tmp', 'bin', 'etc/config', 'payloads', 'proc'):
            (self.root / d).mkdir(parents=True, exist_ok=True)
        self.write('etc/openwrt_release', "DISTRIB_RELEASE='24.10.5'\n")
        self.write('packages', 'luci-i18n-base-ru\n')
        self.mock('opkg', '''echo "opkg $*" >> "$ROOT/calls"
case "$1" in
 list-installed) sed 's/$/ - 1.0/' "$ROOT/packages" ;;
 print-architecture) echo 'arch aarch64_cortex-a53 10' ;;
 install) [ "${PM_FAIL:-0}" = 0 ] || exit 1; shift; printf '%s\\n' "$@" >> "$ROOT/packages" ;;
 --noaction) exit "${SIM_FAIL:-0}" ;;
 remove) exit "${REMOVE_FAIL:-0}" ;;
esac''')
        self.mock('uci', '''echo "uci $*" >> "$ROOT/calls"
case "$*" in
 *get*luci.main.mediaurlbase*) cat "$ROOT/etc/config/luci" 2>/dev/null ;;
 *get*uhttpd.zmweb*) echo uhttpd ;;
esac''')
        self.mock('id', "echo 0")
        if os.name == 'nt':
            # Windows has no POSIX file modes; Linux CI checks real permissions.
            self.mock('chmod', 'exit 0')
            self.mock('tar', 'exec /c/Windows/System32/tar.exe "$@"')
        self.mock('ubus', '''case "$*" in
 *system*board*) echo '{}' ;;
 *list*) [ "${RPC_FAIL:-0}" = 0 ] || exit 1; printf '%s\\n' "${3:-}" ;;
esac''')
        self.mock('jsonfilter', '''case "$*" in
 *release.target*) echo mediatek/filogic ;;
 *release.arch*) echo aarch64 ;;
 *BackendState*) echo "${TS_STATE:-Running}" ;;
 *ControlURL*) echo "${MOCK_TS_CONTROL:-https://controlplane.tailscale.com}" ;;
 *CorpDNS*|*RouteAll*) echo false ;;
 *NetfilterMode*) echo 0 ;;
 *@.ok*) cat >/dev/null; echo true ;;
esac''')
        self.mock('pidof', '''case "$1" in
 dropbear) [ "${SSH_KIND:-dropbear}" = dropbear ] ;;
 sshd) [ "${SSH_KIND:-dropbear}" = openssh ] ;;
 tailscaled) [ "${TS_SERVICE:-1}" = 1 ] && echo 42 ;;
 *) exit 1 ;;
esac''')
        self.mock('curl', '''echo "curl $*" >> "$ROOT/calls"
[ "${NET_FAIL:-0}" = 0 ] || exit 1
while [ "$#" -gt 0 ]; do
 case "$1" in https:*) url=$1 ;; -o) shift; out=$1 ;; esac
 shift
done
cp "$ROOT/payloads/default" "$out"''')
        self.payload('exit 0')
        rewritten = re.sub(r'/(?=(?:etc|usr|www|tmp|opt|var|proc|sbin)/)', self.r + '/', SOURCE)
        rewritten = rewritten.replace('-C / -T', '-C "$ROOT" -T')
        rewritten = rewritten.replace('"/$backup_path"', '"$ROOT/$backup_path"')
        rewritten = rewritten.replace('"/www$active_theme"', '"$ROOT/www$active_theme"')
        self.full = rewritten
        self.lib = rewritten[rewritten.index('fetch() {'):].rsplit('\nmain\n', 1)[0]

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, content, executable=False):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding='utf-8', newline='\n')
        if executable:
            p.chmod(0o755)
        return p

    def mock(self, name, body):
        self.write('bin/' + name, '#!/bin/sh\n' + body + '\n', True)

    def payload(self, body):
        self.write('payloads/default', '#!/bin/sh\n' + body + '\n')

    def apk(self):
        self.mock('apk', '''echo "apk $*" >> "$ROOT/calls"
case "$1" in
 info) grep -qx "$3" "$ROOT/packages" ;;
 add) [ "${PM_FAIL:-0}" = 0 ] || exit 1
   case "$*" in *--simulate*) exit "${SIM_FAIL:-0}" ;; esac
   shift; printf '%s\\n' "$@" >> "$ROOT/packages" ;;
 --print-arch) echo aarch64 ;;
 del) exit "${REMOVE_FAIL:-0}" ;;
esac''')

    def run_shell(self, body='', full=False, stdin='', **env):
        settings = dict(os.environ, ROOT=self.r, NO_COLOR='1')
        settings['PATH'] = str(self.root / 'bin') + os.pathsep + settings['PATH']
        if 'TS_CONTROL' in env:
            env['MOCK_TS_CONTROL'] = env.pop('TS_CONTROL')
        settings.update(env)
        pre = '''set -u
PM=${TEST_PM:-opkg}; RELEASE=${TEST_RELEASE:-24.10.5}; VERSION_MAJOR=${RELEASE%%.*}
TARGET=mediatek/filogic; PKG_ARCH=${TEST_ARCH:-aarch64_cortex-a53}; MODEL=Mock
C_CYAN= C_GREEN= C_YELLOW= C_RED= C_BOLD= C_RESET= C_MAGENTA=
TMP_DIR="$ROOT/tmp/run"; mkdir -p "$TMP_DIR"
info() { echo "INFO $*"; }; warn() { echo "WARN $*"; }; err() { echo "ERR $*" >&2; }; ok() { echo "OK $*"; }; step() { echo "STEP $*"; }
'''
        path = self.write('case.sh', 'PATH="$ROOT/bin:/usr/bin:/bin"; export PATH\n' + (self.full if full else pre + self.lib + '\n' + body))
        r = subprocess.run([SH, shell_path(path)], input=stdin.encode('utf-8'),
                           capture_output=True, env=settings, timeout=20)
        r.stdout = r.stdout.decode('utf-8', errors='replace')
        r.stderr = r.stderr.decode('utf-8', errors='replace')
        return r

    def check(self, body, **env):
        r = self.run_shell(body, **env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def calls(self):
        p = self.root / 'calls'
        return p.read_text(encoding='utf-8') if p.exists() else ''

    def test_package_managers(self):
        for pm, release in [('opkg', '24.10.5'), ('apk', '25.12.1')]:
            with self.subTest(pm=pm):
                if pm == 'apk': self.apk()
                self.check('compatibility_check ttyd; pkg_add demo; pkg_installed demo', TEST_PM=pm, TEST_RELEASE=release)

    def test_version_manager_mismatch(self):
        self.check('! compatibility_check watchdog', TEST_PM='apk')

    def test_unsupported_version(self):
        self.check('! compatibility_check watchdog', TEST_RELEASE='23.05.5')

    def test_unsupported_routerich_architecture(self):
        self.check('! compatibility_check zapret2-routerich', TEST_ARCH='mips_24kc')
        self.assertNotIn('curl', self.calls())

    def test_unknown_architecture(self):
        self.check("PKG_ARCH=''; ! compatibility_check watchdog")

    def test_selection_deduplicates(self):
        self.check('select_components "13,10 13 9"; [ "$SELECTED" = "13 10 9" ]')

    def test_selection_rejects_invalid(self):
        self.check('! select_components "1 99"; ! select_components ""')

    def test_all_policy(self):
        self.check('select_components A; [ "$SELECTED" = "3 7 8 9" ]')

    def test_main_quit_no_install(self):
        r = self.run_shell(full=True, stdin='Q\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('install ', self.calls())
        self.assertIn('НАЧАЛО', r.stdout)
        self.assertIn('КОНЕЦ', r.stdout)
        self.assertNotIn('\x1b', r.stdout)

    def test_main_multiple_no_forced_sftp_ttyd(self):
        r = self.run_shell(full=True, stdin='7,9 7\n', NET_FAIL='1')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertNotIn('install openssh', self.calls())
        self.assertNotIn('install ttyd', self.calls())
        self.assertEqual(r.stdout.count('STEP Site Checker'), 0)  # normal presentation
        self.assertIn('Ошибки: 2', r.stdout)

    def test_network_failure(self):
        self.check("! run_remote_installer demo 'https://raw.githubusercontent.com/TMN88/x/main/install.sh'", NET_FAIL='1')

    def test_empty_installer(self):
        self.write('payloads/default', '')
        self.check("! run_remote_installer demo 'https://raw.githubusercontent.com/TMN88/x/main/install.sh'")

    def test_invalid_installer(self):
        self.payload('if then')
        self.check("! run_remote_installer demo 'https://raw.githubusercontent.com/TMN88/x/main/install.sh'")

    def test_reject_unknown_source(self):
        self.check("! run_remote_installer demo 'https://example.com/install.sh'")
        self.assertNotIn('curl', self.calls())

    def test_ttyd_pm_error(self):
        self.check('! install_ttyd', PM_FAIL='1')

    def test_ttyd_installed_skip(self):
        self.write('packages', 'ttyd\nluci-app-ttyd\n')
        self.mock('ttyd', 'exit 0')
        self.check('run_component ttyd install_ttyd ttyd; grep -q "УСТАНОВЛЕН РАНЕЕ" "$RESULTS_FILE"')
        self.assertNotIn('install ', self.calls())

    def test_partial_failure_continues(self):
        self.check('run_component ttyd install_ttyd ttyd; run_component RU install_luci_ru luci-ru; show_results; grep -q "RU.*УСТАНОВЛЕН РАНЕЕ" "$RESULTS_FILE"', PM_FAIL='1')

    def test_false_zero_not_success(self):
        self.check('run_component USB install_usb_modules usb-modules; grep -q "ОШИБКА" "$RESULTS_FILE"')

    def test_ip_full_optional_simulation(self):
        self.zm_payload()
        self.check('install_zapret_manager', SIM_FAIL='1')
        self.assertIn('StressOzz/Zapret-Manager', self.calls())
        self.assertNotIn('remove ip-tiny', self.calls())

    def test_ip_full_optional_real_failure(self):
        self.zm_payload()
        self.check('install_zapret_manager', PM_FAIL='1')
        self.assertIn('StressOzz/Zapret-Manager', self.calls())

    def test_ip_full_optional_apk(self):
        self.zm_payload()
        self.apk()
        self.check('install_zapret_manager', TEST_PM='apk', TEST_RELEASE='25.12.1', PM_FAIL='1')
        self.assertIn('StressOzz/Zapret-Manager', self.calls())

    def test_forkop_ip_full_remains_required(self):
        self.check('! install_forkop', PM_FAIL='1')
        self.assertNotIn('УСПЕШНО', self.calls())

    def test_podkop_forkop_conflicts(self):
        self.write('etc/config/forkop', 'keep')
        self.check('! conflict_check podkop')
        self.write('etc/config/podkop', 'keep')
        self.check('! conflict_check forkop')
        self.write('packages', 'podkop\nforkop\n')
        self.check('! conflict_check podkop && ! conflict_check forkop')

    def test_zapret_conflicts(self):
        self.write('etc/init.d/zapret2', '#!/bin/sh\nexit 0\n', True)
        self.check('! conflict_check zapret-manager')
        self.write('etc/config/zapret', 'keep')
        self.check('! conflict_check zapret2-routerich')

    def site_fixture(self):
        self.write('usr/share/site-checker2/VERSION', '2.0.0-local.4\n')
        for p in ('usr/libexec/site-checker2', 'usr/libexec/rpcd/site-checker2'):
            self.write(p, '#!/bin/sh\necho \'{"ok":true}\'\n', True)
        for p in ('www/luci-static/resources/view/site-checker2/overview.js', 'usr/share/luci/menu.d/luci-app-site-checker2.json'):
            self.write(p, '{}')

    def test_site_v2_skip(self):
        self.site_fixture()
        self.write('etc/site-checker2/config.json', 'CUSTOM')
        self.check('run_component site install_site_checker site-checker; grep -q "УСТАНОВЛЕН РАНЕЕ" "$RESULTS_FILE"')
        self.assertEqual((self.root / 'etc/site-checker2/config.json').read_text(), 'CUSTOM')
        self.assertNotIn('curl', self.calls())

    def test_site_requires_rpc(self):
        self.site_fixture()
        self.check('! site_checker_ready', RPC_FAIL='1')

    def test_site_legacy_not_v2(self):
        self.write('etc/config/sitecheck', 'CUSTOM LEGACY')
        self.check('! site_checker_ready; install_site_checker')
        self.assertTrue(list((self.root / 'etc/install-packets-backups').rglob('site-checker.tgz')))
        self.assertIn('TMN88/Site_Checker_2/main/install.sh', self.calls())

    def test_site_migration_backup_before_child(self):
        self.write('etc/config/sitecheck', 'CUSTOM LEGACY')
        self.payload('test -n "$(find "$ROOT/etc/install-packets-backups" -name site-checker.tgz)" || exit 1\nrm "$ROOT/etc/config/sitecheck"')
        self.check('install_site_checker')
        self.assertFalse((self.root / 'etc/config/sitecheck').exists())

    def test_watchdog_without_zapret(self):
        out = self.check('install_watchdog')
        self.assertIn('Zapret2 отсутствует', out)
        self.assertNotIn('packages.routerich.ru', self.calls())

    def test_watchdog_with_zapret(self):
        self.write('etc/init.d/zapret2', '#!/bin/sh\nexit 0\n', True)
        self.assertNotIn('Zapret2 отсутствует', self.check('install_watchdog'))

    def test_watchdog_preserves_config(self):
        self.write('etc/config/youtube-watchdog', 'mode safe\ninterval 180')
        self.write('etc/init.d/youtube-watchdog', '#!/bin/sh\nexit 0\n', True)
        self.payload('echo CHANGED > "$ROOT/etc/config/youtube-watchdog"')
        self.check('install_watchdog')
        self.assertEqual((self.root / 'etc/config/youtube-watchdog').read_text(), 'mode safe\ninterval 180')

    def test_sftp_preserves_ssh(self):
        self.write('usr/libexec/sftp-server', '#!/bin/sh\nexit 0\n', True)
        self.write('etc/config/dropbear', 'port 2222\nKEY')
        self.check('install_sftp_server; sftp_ready')
        self.assertEqual((self.root / 'etc/config/dropbear').read_text(), 'port 2222\nKEY')
        self.assertNotIn('openssh-server', self.calls())

    def test_sftp_missing_binary_is_failure(self):
        self.check('! install_sftp_server')

    def test_sftp_unknown_ssh_needs_setup(self):
        self.write('usr/libexec/sftp-server', '#!/bin/sh\nexit 0\n', True)
        self.check('install_sftp_server; [ "$NEEDS_SETUP" = 1 ]', SSH_KIND='unknown')

    def test_tailscale_cancel_menu(self):
        r = self.run_shell(full=True, stdin='11\n0\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('curl', self.calls())
        self.assertIn('ПРОПУЩЕНО', r.stdout)

    def test_tailscale_foreign_registration_preserved(self):
        self.mock('tailscale', 'echo TS')
        self.write('etc/tailscale/tailscaled.state', 'PRIVATE IDENTITY')
        self.check('TS_MODE=mini; install_tailscale; [ "$SKIPPED" = 1 ]', TS_CONTROL='https://rc.routerich.ru')
        self.assertNotIn('curl', self.calls())
        self.assertEqual((self.root / 'etc/tailscale/tailscaled.state').read_text(), 'PRIVATE IDENTITY')

    def test_mini_blocks_foreign_even_after_confirmation(self):
        self.mock('tailscale', 'echo TS')
        r = self.run_shell('TS_MODE=mini; install_tailscale; [ "$NEEDS_SETUP" = 1 ]', stdin='y\n', TS_CONTROL='https://rc.routerich.ru')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn('curl', self.calls())

    def test_routerich_uses_original_no_key_arguments(self):
        self.check('TS_MODE=routerich; install_tailscale')
        self.assertIn('tailscale-router-rr.sh', self.calls())
        self.assertNotIn('--auth-key', self.calls())

    def test_tailscale_auth_incomplete(self):
        self.payload('exit 2')
        self.check('TS_MODE=routerich; install_tailscale; [ "$NEEDS_SETUP" = 1 ]')

    def test_theme_cancel(self):
        self.write('etc/config/luci', '/luci-static/bootstrap')
        self.payload('read -r choice\n[ "$choice" = 0 ]')
        r = self.run_shell('install_themes; [ "$SKIPPED" = 1 ]', stdin='0\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_theme_error_restores_configuration(self):
        self.write('etc/config/luci', '/luci-static/bootstrap')
        self.payload('read -r choice\necho BROKEN > "$ROOT/etc/config/luci"\nexit 1')
        r = self.run_shell('! install_themes', stdin='2\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.root / 'etc/config/luci').read_text(), '/luci-static/bootstrap')

    def test_repeated_no_forced_reinstall(self):
        self.write('packages', 'ttyd\nluci-app-ttyd\n')
        self.mock('ttyd', 'exit 0')
        self.check('run_component ttyd install_ttyd ttyd; run_component ttyd install_ttyd ttyd; [ "$(wc -l < "$RESULTS_FILE")" -eq 2 ]')
        self.assertNotIn('install ttyd', self.calls())

    def test_main_all_no_conflicting_or_nested_installers(self):
        r = self.run_shell(full=True, stdin='A\n', NET_FAIL='1')
        self.assertEqual(r.returncode, 1, r.stderr)
        for forbidden in ('openssh-sftp-server', 'install ttyd', 'tailscale-router-', 'install_openwrt_themes', 'Zapret-Manager', 'itdoginfo', 'ushan0v'):
            self.assertNotIn(forbidden, self.calls())
        self.assertIn('Ошибки: 4', r.stdout)

    def test_main_apk_multiple(self):
        self.apk()
        self.write('etc/openwrt_release', "DISTRIB_RELEASE='25.12.1'\n")
        r = self.run_shell(full=True, stdin='7,9\n', NET_FAIL='1')
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn('Менеджер пакетов: apk', r.stdout)
        self.assertIn('Ошибки: 2', r.stdout)

    def test_existing_config_alone_not_installed(self):
        for path in ('etc/config/podkop', 'etc/config/forkop', 'etc/config/zapret', 'etc/config/zapret2'):
            self.write(path, 'OLD')
        self.check('! component_installed podkop && ! component_installed forkop && ! component_installed zapret-manager && ! component_installed zapret2-routerich')
        self.check('! conflict_check zapret-manager')

    def test_legacy_backup_contains_original_settings(self):
        self.write('etc/config/sitecheck', 'PRIVATE LEGACY SETTINGS')
        self.write('etc/config/sitecheck.apk-old', 'OLD SETTINGS')
        self.check('install_site_checker')
        archive = next((self.root / 'etc/install-packets-backups').rglob('site-checker.tgz'))
        with tarfile.open(archive) as t:
            self.assertEqual(t.extractfile('etc/config/sitecheck').read(), b'PRIVATE LEGACY SETTINGS')
            self.assertEqual(t.extractfile('etc/config/sitecheck.apk-old').read(), b'OLD SETTINGS')

    def watchdog_fixture(self, enabled=True):
        self.write('etc/init.d/youtube-watchdog', '#!/bin/sh\nexit ' + ('0' if enabled else '1') + '\n', True)
        self.write('usr/bin/youtube-watchdog', '#!/bin/sh\nVERSION=1.3.1\n', True)
        self.write('usr/libexec/youtube-watchdog-probe', '#!/bin/sh\nexit 0\n', True)
        self.write('www/luci-static/resources/view/youtube-watchdog/overview.js', '{}')
        self.write('usr/share/luci/menu.d/luci-app-youtube-watchdog.json', '{}')

    def test_watchdog_existing_working_skipped(self):
        self.watchdog_fixture()
        self.check('run_component watchdog install_watchdog watchdog; grep -q "УСТАНОВЛЕН РАНЕЕ" "$RESULTS_FILE"')
        self.assertNotIn('curl', self.calls())

    def test_watchdog_disabled_preserved(self):
        self.watchdog_fixture(False)
        self.check('run_component watchdog install_watchdog watchdog; grep -q "ТРЕБУЕТ НАСТРОЙКИ" "$RESULTS_FILE"')
        self.assertNotIn('curl', self.calls())

    def test_openssh_internal_sftp(self):
        self.write('usr/libexec/sftp-server', '#!/bin/sh\nexit 0\n', True)
        self.mock('sshd', 'echo "subsystem sftp internal-sftp"')
        self.check('install_sftp_server; sftp_ready', SSH_KIND='openssh')

    def test_theme_activation_reports_selected_theme(self):
        self.write('etc/config/luci', '/luci-static/bootstrap')
        self.write('packages', 'luci-theme-argon\n')
        (self.root / 'www/luci-static/argon').mkdir(parents=True)
        self.payload('read -r choice\necho /luci-static/argon > "$ROOT/etc/config/luci"')
        r = self.run_shell('run_component themes install_themes themes; cat "$RESULTS_FILE"', stdin='2\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('LuCI argon\tУСПЕШНО', r.stdout)

    def test_tailscale_ready_checks_userspace_and_socks(self):
        self.mock('tailscale', 'echo TS')
        self.mock('tailscaled', 'exit 0')
        self.write('etc/init.d/tailscale', '#!/bin/sh\nexit 0\n', True)
        self.write('etc/tailscale/tailscaled.state', 'IDENTITY')
        self.write('proc/42/cmdline', 'tailscaled\0--tun=userspace-networking\0--socks5-server=0.0.0.0:1055\0')
        self.check('TS_MODE=mini; tailscale_ready')
        self.write('proc/42/cmdline', 'tailscaled\0--tun=tailscale0\0')
        self.check('TS_MODE=mini; ! tailscale_ready')

    def test_routerich_existing_cancel_preserves_registration(self):
        self.mock('tailscale', 'echo TS')
        self.write('etc/tailscale/tailscaled.state', 'IDENTITY')
        self.check('TS_MODE=routerich; install_tailscale; [ "$SKIPPED" = 1 ]')
        self.assertNotIn('curl', self.calls())
        self.assertEqual((self.root / 'etc/tailscale/tailscaled.state').read_text(), 'IDENTITY')

    def test_auto_uses_pinned_original_without_key_arguments(self):
        self.check('TS_MODE=auto; install_tailscale')
        self.assertIn('58fb27565f3d1dcbf2d8fb6ce73ad16afbea29c2/TS_client_install_auto.sh', self.calls())
        self.assertNotIn('--auth-key', self.calls())

    def test_auto_blocks_foreign_and_unknown_before_child(self):
        self.mock('tailscale', 'echo TS')
        self.write('etc/tailscale/tailscaled.state', 'IDENTITY')
        for server in ('https://rc.routerich.ru', 'unknown'):
            with self.subTest(server=server):
                self.check('TS_MODE=auto; install_tailscale; [ "$NEEDS_SETUP" = 1 ]', TS_CONTROL=server)
        self.assertNotIn('curl', self.calls())
        self.assertEqual((self.root / 'etc/tailscale/tailscaled.state').read_text(), 'IDENTITY')

    def test_auto_existing_cancel(self):
        self.mock('tailscale', 'echo TS')
        self.check('TS_MODE=auto; install_tailscale; [ "$SKIPPED" = 1 ]')
        self.assertNotIn('curl', self.calls())

    def test_auto_existing_confirm(self):
        self.mock('tailscale', 'echo TS')
        r = self.run_shell('TS_MODE=auto; install_tailscale', stdin='y\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('TS_client_install_auto.sh', self.calls())

    def test_auto_child_failure_is_reported(self):
        self.payload('exit 1')
        self.check('TS_MODE=auto; run_component "TS AUTO" install_tailscale tailscale; grep -q "TS AUTO.*ОШИБКА" "$RESULTS_FILE"')

    def test_auto_main_third_option(self):
        r = self.run_shell(full=True, stdin='11\n3\n', NET_FAIL='1')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('3. TS AUTO', r.stdout)
        self.assertIn('TS AUTO — ОШИБКА', r.stdout)
        self.assertIn('58fb27565f3d1dcbf2d8fb6ce73ad16afbea29c2/TS_client_install_auto.sh', self.calls())

    def zm_fixture(self, web=True):
        self.write('opt/zapret-manager-luci/backend.sh', '#!/bin/sh\nexit 0\n', True)
        self.write('usr/libexec/rpcd/zapret-manager', '#!/bin/sh\nexit 0\n', True)
        for p in ('usr/share/luci/menu.d/luci-app-zapret-manager.json',
                  'usr/share/rpcd/acl.d/luci-app-zapret-manager.json',
                  'www/luci-static/resources/zapret-manager/common.js',
                  'www/luci-static/resources/view/zapret-manager/dashboard.js'):
            self.write(p, '{}')
        if web:
            for p in ('www/zm-webui.html', 'www/zm/app.js', 'www/zm/app.css', 'usr/lib/uhttpd_ubus.so'):
                self.write(p, 'fixture')
            self.write('etc/init.d/uhttpd', '#!/bin/sh\nexit 0\n', True)

    def zm_payload(self, rc=0):
        # Prepare the installer-owned payload away from live fixture paths.
        self.zm_fixture()
        for d in ('opt', 'usr', 'www', 'etc/init.d'):
            p = self.root / d
            if p.exists():
                destination = self.root / 'expected' / d
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(p), str(destination))
        self.payload('cp -R "$ROOT/expected/opt" "$ROOT/expected/usr" "$ROOT/expected/www" "$ROOT/"\n'
                     'mkdir -p "$ROOT/etc/init.d"\ncp "$ROOT/expected/etc/init.d/uhttpd" "$ROOT/etc/init.d/uhttpd"\n'
                     f'exit {rc}')

    def test_zm_new_panel_success_without_engine_or_package(self):
        self.zm_payload()
        self.check('run_component "Zapret Manager" install_zapret_manager zapret-manager; grep -q "Zapret Manager.*УСПЕШНО" "$RESULTS_FILE"')
        self.assertFalse((self.root / 'etc/init.d/zapret').exists())

    def test_zm_existing_panel_skipped(self):
        self.zm_fixture()
        self.check('run_component "Zapret Manager" install_zapret_manager zapret-manager; grep -q "УСТАНОВЛЕН РАНЕЕ" "$RESULTS_FILE"')
        self.assertNotIn('curl', self.calls())

    def test_zm_luci_only_needs_setup_without_reinstall(self):
        self.zm_fixture(web=False)
        self.check('run_component "Zapret Manager" install_zapret_manager zapret-manager; grep -q "ТРЕБУЕТ НАСТРОЙКИ" "$RESULTS_FILE"')
        self.assertNotIn('curl', self.calls())

    def test_zm_missing_rpc_needs_setup(self):
        self.zm_fixture()
        self.check('run_component "Zapret Manager" install_zapret_manager zapret-manager; grep -q "ТРЕБУЕТ НАСТРОЙКИ" "$RESULTS_FILE"', RPC_FAIL='1')

    def test_zm_engine_alone_not_panel(self):
        self.write('packages', 'zapret\n')
        self.write('etc/init.d/zapret', '#!/bin/sh\nexit 0\n', True)
        self.check('! component_installed zapret-manager')

    def test_zm_zero_exit_with_missing_files_is_error(self):
        self.check('run_component "Zapret Manager" install_zapret_manager zapret-manager; grep -q "ОШИБКА" "$RESULTS_FILE"')

    def test_zm_failed_child_even_with_files_is_error(self):
        self.zm_payload(rc=1)
        self.check('run_component "Zapret Manager" install_zapret_manager zapret-manager; grep -q "ОШИБКА" "$RESULTS_FILE"')


if __name__ == '__main__':
    unittest.main(verbosity=2)
