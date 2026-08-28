#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# 3x-ui 2.8.11 — Xray Core automatic restart every 70 minutes
# ============================================================

INSTALL_SCRIPT="/usr/local/sbin/restart-xray-70m.sh"
STATE_DIR="/var/lib/xray-auto-restart"
STATE_FILE="${STATE_DIR}/last_restart"
CRON_FILE="/etc/cron.d/xray-auto-restart"
TIMEZONE="Europe/Moscow"

# ------------------------------------------------------------
# Проверка root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this installer as root."
    echo
    echo "Example:"
    echo "  sudo bash x-ray-restart.sh"
    exit 1
fi

echo "=========================================="
echo " Xray Core auto-restart installer"
echo " 3x-ui: 2.8.11"
echo " Interval: 70 minutes"
echo "=========================================="
echo

# ------------------------------------------------------------
# Проверяем наличие x-ui
# ------------------------------------------------------------

if ! systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
    echo "ERROR: x-ui.service was not found."
    exit 1
fi

# ------------------------------------------------------------
# Московское время
# ------------------------------------------------------------

CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || true)

if [[ "$CURRENT_TZ" != "$TIMEZONE" ]]; then
    echo "[+] Setting timezone: $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE"
else
    echo "[OK] Timezone already set: $TIMEZONE"
fi

# ------------------------------------------------------------
# Проверяем необходимые команды
# ------------------------------------------------------------

for CMD in flock pgrep logger systemctl timedatectl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $CMD"
        exit 1
    fi
done

# ------------------------------------------------------------
# Создаём основной скрипт
# ------------------------------------------------------------

echo "[+] Installing: $INSTALL_SCRIPT"

cat > "$INSTALL_SCRIPT" <<'XRAY_SCRIPT'
#!/usr/bin/env bash

set -u

INTERVAL=4200

STATE_DIR="/var/lib/xray-auto-restart"
STATE_FILE="${STATE_DIR}/last_restart"
LOCK_FILE="/run/xray-auto-restart.lock"
TAG="xray-auto-restart"
TIMEZONE="Europe/Moscow"

# ------------------------------------------------------------
# Московское время
# ------------------------------------------------------------

CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || true)

if [[ "$CURRENT_TZ" != "$TIMEZONE" ]]; then
    timedatectl set-timezone "$TIMEZONE" || {
        logger -t "$TAG" "WARNING: failed to set timezone to $TIMEZONE"
    }
fi

# ------------------------------------------------------------
# State directory
# ------------------------------------------------------------

mkdir -p "$STATE_DIR"

# ------------------------------------------------------------
# Lock
# Не даём двум копиям скрипта работать одновременно
# ------------------------------------------------------------

exec 9>"$LOCK_FILE"

flock -n 9 || exit 0

# ------------------------------------------------------------
# Проверяем время последнего рестарта
# ------------------------------------------------------------

NOW=$(date +%s)
LAST=0

if [[ -r "$STATE_FILE" ]]; then
    LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
    LAST=0
fi

# 4200 секунд = 70 минут
if (( NOW - LAST < INTERVAL )); then
    exit 0
fi

# ------------------------------------------------------------
# Проверяем x-ui
# ------------------------------------------------------------

if ! systemctl is-active --quiet x-ui; then
    logger -t "$TAG" "ERROR: x-ui service is not active"
    exit 1
fi

MAIN_PID=$(systemctl show x-ui -p MainPID --value 2>/dev/null || true)

if [[ -z "$MAIN_PID" || "$MAIN_PID" == "0" ]]; then
    logger -t "$TAG" "ERROR: cannot determine x-ui MainPID"
    exit 1
fi

# ------------------------------------------------------------
# Поиск процесса Xray
#
# Обычно на 3x-ui 2.8.11:
# bin/xray-linux-amd64 -c bin/config.json
# ------------------------------------------------------------

find_xray_pid() {
    pgrep -f '(^|/)xray-linux-[^[:space:]]+' | head -n1 || true
}

OLD_XRAY_PID=$(find_xray_pid)

logger -t "$TAG" \
    "Restarting Xray Core via SIGUSR1 (x-ui PID=$MAIN_PID, old Xray PID=${OLD_XRAY_PID:-unknown})"

# ------------------------------------------------------------
# 3x-ui 2.8.11:
# SIGUSR1 -> restart Xray Core
# Панель x-ui при этом не рестартует
# ------------------------------------------------------------

if ! kill -USR1 "$MAIN_PID"; then
    logger -t "$TAG" \
        "ERROR: failed to send SIGUSR1 to x-ui PID=$MAIN_PID"
    exit 1
fi

# ------------------------------------------------------------
# Сразу записываем время отправки сигнала.
#
# Это важно:
# если проверка PID ниже когда-либо сломается,
# cron НЕ начнёт перезапускать Xray каждую минуту.
# ------------------------------------------------------------

date +%s > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"

# ------------------------------------------------------------
# Ждём до 15 секунд запуска нового Xray
# ------------------------------------------------------------

NEW_XRAY_PID=""

for _ in $(seq 1 15); do
    sleep 1

    CURRENT_XRAY_PID=$(find_xray_pid)

    if [[ -z "$CURRENT_XRAY_PID" ]]; then
        continue
    fi

    if ! kill -0 "$CURRENT_XRAY_PID" 2>/dev/null; then
        continue
    fi

    # Если старый PID был известен — ждём именно новый процесс.
    if [[ -n "$OLD_XRAY_PID" ]]; then
        if [[ "$CURRENT_XRAY_PID" != "$OLD_XRAY_PID" ]]; then
            NEW_XRAY_PID="$CURRENT_XRAY_PID"
            break
        fi
    else
        NEW_XRAY_PID="$CURRENT_XRAY_PID"
        break
    fi
done

# ------------------------------------------------------------
# Результат
# ------------------------------------------------------------

if [[ -n "$NEW_XRAY_PID" ]] && kill -0 "$NEW_XRAY_PID" 2>/dev/null; then
    logger -t "$TAG" \
        "OK: Xray Core restarted successfully (old PID=${OLD_XRAY_PID:-unknown}, new PID=$NEW_XRAY_PID)"
    exit 0
fi

# Возможно Xray уже работает, но PID по какой-либо причине
# не удалось корректно сопоставить.
CURRENT_XRAY_PID=$(find_xray_pid)

if [[ -n "$CURRENT_XRAY_PID" ]] && kill -0 "$CURRENT_XRAY_PID" 2>/dev/null; then
    logger -t "$TAG" \
        "WARNING: Xray is running with PID=$CURRENT_XRAY_PID, but restart PID change could not be confirmed"
    exit 0
fi

logger -t "$TAG" \
    "ERROR: SIGUSR1 was sent, but Xray process was not detected after 15 seconds"

exit 1
XRAY_SCRIPT

chmod 750 "$INSTALL_SCRIPT"

echo "[OK] Main script installed"

# ------------------------------------------------------------
# State-файл
#
# При первой установке отсчёт начинается сейчас.
# При повторной установке существующий таймер НЕ сбрасываем.
# ------------------------------------------------------------

mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
    date +%s > "$STATE_FILE"
    chmod 644 "$STATE_FILE"
    echo "[+] 70-minute timer started"
else
    echo "[OK] Existing restart timer preserved"
fi

# ------------------------------------------------------------
# Проверяем cron
# ------------------------------------------------------------

if ! command -v cron >/dev/null 2>&1 && \
   ! command -v crond >/dev/null 2>&1; then

    echo "[+] cron is not installed"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y cron
    else
        echo "ERROR: cron is not installed and apt-get is unavailable."
        exit 1
    fi
fi

# ------------------------------------------------------------
# Cron
#
# Запускаем проверку каждую минуту.
# Сам Xray рестартует только когда прошло >= 4200 секунд.
# ------------------------------------------------------------

echo "[+] Installing cron job: $CRON_FILE"

cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

* * * * * root $INSTALL_SCRIPT
EOF

chmod 644 "$CRON_FILE"

# ------------------------------------------------------------
# Включаем cron
# ------------------------------------------------------------

if systemctl list-unit-files cron.service >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null
elif systemctl list-unit-files crond.service >/dev/null 2>&1; then
    systemctl enable --now crond >/dev/null
fi

# ------------------------------------------------------------
# Вывод информации
# ------------------------------------------------------------

LAST_RESTART=$(cat "$STATE_FILE")
NEXT_RESTART=$((LAST_RESTART + 4200))

echo
echo "=========================================="
echo " Installation completed"
echo "=========================================="
echo
echo "Timezone:"
echo "  $(timedatectl show -p Timezone --value)"
echo
echo "Main script:"
echo "  $INSTALL_SCRIPT"
echo
echo "Cron:"
echo "  $CRON_FILE"
echo
echo "Interval:"
echo "  70 minutes"
echo
echo "Next restart:"
date -d "@$NEXT_RESTART" '+  %Y-%m-%d %H:%M:%S %Z'
echo
echo "Logs:"
echo "  journalctl -t xray-auto-restart -n 30 --no-pager"
echo
echo "Cron config:"
echo "  cat $CRON_FILE"
echo
echo "Current Xray:"
echo "  pgrep -af 'xray-linux'"
echo
echo "=========================================="
