# Проверка Install Packets 2.0

Дата: 30 октября 2026.

Локально (Windows, Git sh):

- `sh -n openwrt-toolkit.sh`: код 0.
- ShellCheck 0.11.0, `--severity=style --shell=sh`: код 0, замечаний нет. Официальный архив проверен по SHA256 из API релиза: `8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e`.
- `python -m unittest discover -s tests -v`: 52 теста, OK. На Windows chmod имитируется; архивы создаёт системный tar.
- `git diff --check`: код 0.

Linux CI: `sh -n`, `busybox ash -n` и ShellCheck прошли; 52/52 mock-теста под dash и 52/52 под BusyBox ash — OK. Актуальный запуск доступен в проверках PR.

Сценарии включают OpenWrt 24.10/opkg и 25.12/apk, пакеты установлены/отсутствуют, остаточные конфигурации, несовместимые версии/архитектуры, отказ GitHub и менеджера пакетов, ip-full simulation/install failure, несколько компонентов и повторный запуск, A, отмену подменю, миграцию Site Checker с проверкой содержимого архива, обязательный RPC, Watchdog с/без Zapret2 и сохранение настроек, SFTP/Dropbear/OpenSSH, регистрацию Tailscale и параметры процесса, активацию/отмену/откат темы, частичные ошибки и ложный нулевой код дочернего скрипта.

Реальные внешние установщики в тестах не выполняются. Реальные роутеры, SFTP-подключения, SSH по Tailscale, восстановление YouTube и загрузка модулей ядра не проверялись.
