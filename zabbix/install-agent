#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Zabbix Agent installer
# Ubuntu + Zabbix 7.0
#
# - asks for Zabbix Server IPv4
# - installs Zabbix Agent
# - configures Server / ServerActive / Hostname
# - allows TCP/10050 only from Zabbix Server
# - saves iptables rules
# ============================================================


# ------------------------------------------------------------
# Do not run with source
# ------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "ERROR: не запускай скрипт через source или '.'"
    echo "Используй: bash <(curl -fsSL URL)"
    return 1
fi


# ============================================================
# Helpers
# ============================================================

info() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}


valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a parts

    read -r -a parts <<< "$ip"

    [[ ${#parts[@]} -eq 4 ]] || return 1

    local part

    for part in "${parts[@]}"; do

        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1

        (( 10#$part >= 0 && 10#$part <= 255 )) || return 1

    done
}


# ============================================================
# Root check
# ============================================================

[[ $EUID -eq 0 ]] || die "нужен root"


# ============================================================
# Ask for Zabbix Server
# ============================================================

echo
echo "=========================================="
echo "        ZABBIX AGENT INSTALLER"
echo "=========================================="
echo


while true; do

    if ! read -r -p "Введите IPv4 Zabbix Server: " ZABBIX_SERVER; then
        echo
        die "ввод отменён"
    fi

    ZABBIX_SERVER="${ZABBIX_SERVER//[[:space:]]/}"

    if valid_ipv4 "$ZABBIX_SERVER"; then
        break
    fi

    echo
    echo "Некорректный IPv4."
    echo "Пример: 2.26.90.148"
    echo

done


ZABBIX_HOSTNAME="$(hostname -f 2>/dev/null || true)"

if [[ -z "$ZABBIX_HOSTNAME" ]]; then
    ZABBIX_HOSTNAME="$(hostname)"
fi


CONF="/etc/zabbix/zabbix_agentd.conf"


echo
echo "Zabbix Server: $ZABBIX_SERVER"
echo "Hostname:      $ZABBIX_HOSTNAME"
echo


# ============================================================
# 1. Detect OS
# ============================================================

echo "[1/8] Определяем ОС..."


[[ -f /etc/os-release ]] || \
    die "/etc/os-release не найден"


. /etc/os-release


[[ "${ID:-}" == "ubuntu" ]] || {
    die "поддерживается только Ubuntu"
}


UBUNTU_VERSION="${VERSION_ID:-}"


case "$UBUNTU_VERSION" in

    20.04|22.04|24.04|26.04)
        ;;

    *)
        die "версия Ubuntu пока не поддержана скриптом: $UBUNTU_VERSION"
        ;;

esac


echo "Обнаружено: $PRETTY_NAME"


ZABBIX_REPO_URL="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu${UBUNTU_VERSION}_all.deb"


# ============================================================
# 2. Zabbix repository
# ============================================================

echo
echo "[2/8] Подключаем Zabbix 7.0 repository..."
echo "$ZABBIX_REPO_URL"


export DEBIAN_FRONTEND=noninteractive


apt-get update


apt-get install -y \
    wget \
    ca-certificates \
    iptables


if ! wget -q \
    "$ZABBIX_REPO_URL" \
    -O /tmp/zabbix-release.deb; then

    rm -f /tmp/zabbix-release.deb

    die "не удалось скачать Zabbix repository package"
fi


dpkg -i /tmp/zabbix-release.deb

rm -f /tmp/zabbix-release.deb


apt-get update


# ============================================================
# 3. Install agent
# ============================================================

echo
echo "[3/8] Устанавливаем Zabbix Agent..."


DEBIAN_FRONTEND=noninteractive \
    apt-get install -y zabbix-agent


[[ -f "$CONF" ]] || {
    die "не найден $CONF"
}


# ============================================================
# 4. Configure agent
# ============================================================

echo
echo "[4/8] Настраиваем Agent..."


BACKUP="${CONF}.backup.$(date +%Y%m%d-%H%M%S)"

cp -a "$CONF" "$BACKUP"


sed -i \
    -e "s|^[#[:space:]]*Server=.*|Server=${ZABBIX_SERVER}|" \
    -e "s|^[#[:space:]]*ServerActive=.*|ServerActive=${ZABBIX_SERVER}|" \
    -e "s|^[#[:space:]]*Hostname=.*|Hostname=${ZABBIX_HOSTNAME}|" \
    "$CONF"


grep -q '^Server=' "$CONF" || \
    echo "Server=${ZABBIX_SERVER}" >> "$CONF"


grep -q '^ServerActive=' "$CONF" || \
    echo "ServerActive=${ZABBIX_SERVER}" >> "$CONF"


grep -q '^Hostname=' "$CONF" || \
    echo "Hostname=${ZABBIX_HOSTNAME}" >> "$CONF"


# ============================================================
# 5. Start agent
# ============================================================

echo
echo "[5/8] Запускаем Agent..."


systemctl enable zabbix-agent

systemctl restart zabbix-agent


sleep 2


if ! systemctl is-active --quiet zabbix-agent; then

    echo
    echo "ERROR: zabbix-agent не запустился"
    echo

    systemctl status \
        zabbix-agent \
        --no-pager \
        -l || true

    exit 1

fi


# ============================================================
# 6. Firewall
# ============================================================

echo
echo "[6/8] Настраиваем iptables..."


# Allow TCP/10050 only from specified Zabbix Server
if ! iptables -C INPUT \
    -p tcp \
    -s "$ZABBIX_SERVER" \
    --dport 10050 \
    -j ACCEPT \
    2>/dev/null; then

    iptables -I INPUT 1 \
        -p tcp \
        -s "$ZABBIX_SERVER" \
        --dport 10050 \
        -j ACCEPT

fi


# Drop TCP/10050 from everyone else
if ! iptables -C INPUT \
    -p tcp \
    --dport 10050 \
    -j DROP \
    2>/dev/null; then

    iptables -I INPUT 2 \
        -p tcp \
        --dport 10050 \
        -j DROP

fi


# ============================================================
# 7. Save firewall
# ============================================================

echo
echo "[7/8] Сохраняем firewall..."


DEBIAN_FRONTEND=noninteractive \
    apt-get install -y iptables-persistent


mkdir -p /etc/iptables


iptables-save > /etc/iptables/rules.v4


systemctl enable netfilter-persistent >/dev/null 2>&1 || true

netfilter-persistent save


# ============================================================
# 8. Checks
# ============================================================

echo
echo "[8/8] Проверяем..."


echo
echo "===== ZABBIX AGENT ====="

systemctl status \
    zabbix-agent \
    --no-pager \
    -l \
    | head -25 || true


echo
echo "===== PORT 10050 ====="

ss -lntp | grep ':10050' || true


echo
echo "===== IPTABLES ====="

iptables \
    -L INPUT \
    -n \
    -v \
    --line-numbers \
    | grep 10050 || true


echo
echo "===== CONFIG ====="

grep -E \
    '^(Server|ServerActive|Hostname)=' \
    "$CONF"


# ============================================================
# Result
# ============================================================

echo
echo "=========================================="
echo "                 ГОТОВО"
echo "=========================================="
echo
echo "OS:       $PRETTY_NAME"
echo "Hostname: $ZABBIX_HOSTNAME"
echo "Server:   $ZABBIX_SERVER"
echo "Port:     10050"
echo
echo "Config backup:"
echo "$BACKUP"
echo
echo "TCP/10050 разрешён только для:"
echo "$ZABBIX_SERVER"
echo
