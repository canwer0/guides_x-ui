cat >/root/install-xui-zabbix-monitor.sh <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail

DB="/etc/x-ui/x-ui.db"
XRAY_CONFIG="/usr/local/x-ui/bin/config.json"

SECRET_DIR="/etc/xui-zabbix"
CACHE_DIR="/var/lib/xui-zabbix"
PASSWORD_FILE="$SECRET_DIR/password"

COLLECTOR="/usr/local/bin/xui-outbound-collector"
READER="/usr/local/bin/xui-zabbix-reader"

AGENT_DIR="/etc/zabbix/zabbix_agentd.d"
USERPARAM_FILE="$AGENT_DIR/xui-outbound.conf"

[[ $EUID -eq 0 ]] || {
    echo "ERROR: нужен root"
    exit 1
}

[[ -f "$DB" ]] || {
    echo "ERROR: не найдена $DB"
    exit 1
}

[[ -f "$XRAY_CONFIG" ]] || {
    echo "ERROR: не найден $XRAY_CONFIG"
    exit 1
}

command -v zabbix_agentd >/dev/null 2>&1 || {
    echo "ERROR: zabbix-agent не установлен"
    exit 1
}

echo "=========================================="
echo " 3x-ui -> Zabbix Outbound Monitor"
echo " Интервал: 120 секунд"
echo "=========================================="

echo
echo "[1/8] Зависимости..."

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3 curl jq

mkdir -p "$SECRET_DIR" "$CACHE_DIR" "$AGENT_DIR"
chmod 700 "$SECRET_DIR"
chmod 755 "$CACHE_DIR"

echo
echo "[2/8] Пароль 3x-ui..."

read -rsp "Введите актуальный пароль 3x-ui: " XUI_PASSWORD
echo

[[ -n "$XUI_PASSWORD" ]] || {
    echo "ERROR: пустой пароль"
    exit 1
}

printf '%s' "$XUI_PASSWORD" > "$PASSWORD_FILE"
unset XUI_PASSWORD

chown root:root "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

echo
echo "[3/8] Разрешаем localhost в iptables..."

iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \
iptables -I INPUT 1 -i lo -j ACCEPT

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null || true
fi

echo
echo "[4/8] Collector..."

cat >"$COLLECTOR" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

DB="/etc/x-ui/x-ui.db"
XRAY_CONFIG="/usr/local/x-ui/bin/config.json"
PASSWORD_FILE="/etc/xui-zabbix/password"

CACHE_DIR="/var/lib/xui-zabbix"
CACHE_FILE="$CACHE_DIR/results.json"
TMP_FILE="$CACHE_DIR/results.json.tmp.$$"

NOW="$(date +%s)"

mkdir -p "$CACHE_DIR"
chmod 755 "$CACHE_DIR"

FILES=()

cleanup() {
    local f
    for f in "${FILES[@]:-}"; do
        rm -f "$f"
    done
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

OLD_OUTBOUNDS='[]'
OLD_LAST_SUCCESS=0

if [[ -f "$CACHE_FILE" ]] && jq -e . "$CACHE_FILE" >/dev/null 2>&1; then
    OLD_OUTBOUNDS="$(jq -c '.outbounds // []' "$CACHE_FILE" 2>/dev/null || echo '[]')"
    OLD_LAST_SUCCESS="$(jq -r '.last_success // 0' "$CACHE_FILE" 2>/dev/null || echo 0)"
fi

write_result() {
    chmod 644 "$TMP_FILE"
    chown root:root "$TMP_FILE"
    mv -f "$TMP_FILE" "$CACHE_FILE"
}

fatal_result() {
    local MSG="$1"

    jq -n \
        --argjson ts "$NOW" \
        --argjson last "$OLD_LAST_SUCCESS" \
        --arg error "$MSG" \
        --argjson outbounds "$OLD_OUTBOUNDS" \
        '{
            timestamp:$ts,
            last_success:$last,
            collector_success:false,
            collector_error:$error,
            outbounds:$outbounds
        }' > "$TMP_FILE"

    write_result
    exit 1
}

[[ -f "$DB" ]] || fatal_result "x-ui database not found"
[[ -f "$XRAY_CONFIG" ]] || fatal_result "Xray config not found"
[[ -f "$PASSWORD_FILE" ]] || fatal_result "x-ui password file not found"

db_setting() {
    sqlite3 "$DB" \
        "SELECT value FROM settings WHERE key='$1' LIMIT 1;" \
        2>/dev/null || true
}

WEB_PORT="$(db_setting webPort)"
WEB_PATH="$(db_setting webBasePath)"
WEB_CERT="$(db_setting webCertFile)"
WEB_KEY="$(db_setting webKeyFile)"

USERNAME="$(
    sqlite3 "$DB" \
        "SELECT username FROM users ORDER BY id LIMIT 1;" \
        2>/dev/null || true
)"

[[ -n "$WEB_PORT" ]] || WEB_PORT="2053"
[[ -n "$WEB_PATH" ]] || WEB_PATH="/"
[[ -n "$USERNAME" ]] || fatal_result "Cannot read x-ui username"

[[ "$WEB_PATH" == /* ]] || WEB_PATH="/$WEB_PATH"
[[ "$WEB_PATH" == */ ]] || WEB_PATH="$WEB_PATH/"

if [[ -n "$WEB_CERT" && -n "$WEB_KEY" ]]; then
    SCHEME="https"
    CURL_TLS=(-k)
else
    SCHEME="http"
    CURL_TLS=()
fi

BASE_URL="${SCHEME}://127.0.0.1:${WEB_PORT}${WEB_PATH%/}"

PASSWORD="$(cat "$PASSWORD_FILE")"

COOKIE="$(mktemp)"
FILES+=("$COOKIE")

LOGIN_RESPONSE="$(
    curl "${CURL_TLS[@]}" \
        -sS \
        --connect-timeout 5 \
        --max-time 15 \
        -c "$COOKIE" \
        -X POST \
        "${BASE_URL}/login" \
        --data-urlencode "username=${USERNAME}" \
        --data-urlencode "password=${PASSWORD}" \
        2>/dev/null
)"
LOGIN_RC=$?

unset PASSWORD

[[ $LOGIN_RC -eq 0 ]] || fatal_result "Cannot connect to x-ui"

LOGIN_OK="$(
    printf '%s' "$LOGIN_RESPONSE" |
    jq -r '.success // false' 2>/dev/null || echo false
)"

[[ "$LOGIN_OK" == "true" ]] || fatal_result "x-ui login failed"

ALL_OUTBOUNDS="$(
    jq -c '.outbounds // []' "$XRAY_CONFIG" 2>/dev/null
)"

[[ -n "$ALL_OUTBOUNDS" ]] || fatal_result "Cannot read outbounds"

ALL_FILE="$(mktemp)"
FILES+=("$ALL_FILE")
printf '%s' "$ALL_OUTBOUNDS" > "$ALL_FILE"

RESULTS='[]'

while IFS= read -r OUTBOUND; do

    TAG="$(printf '%s' "$OUTBOUND" | jq -r '.tag // empty')"
    PROTOCOL="$(printf '%s' "$OUTBOUND" | jq -r '.protocol // empty')"

    [[ -n "$TAG" ]] || continue

    if [[ "$PROTOCOL" == "blackhole" || "$TAG" == "blocked" ]]; then
        continue
    fi

    OUT_FILE="$(mktemp)"
    ERR_FILE="$(mktemp)"
    FILES+=("$OUT_FILE" "$ERR_FILE")

    printf '%s' "$OUTBOUND" > "$OUT_FILE"

    RESPONSE="$(
        curl "${CURL_TLS[@]}" \
            -sS \
            --connect-timeout 5 \
            --max-time 30 \
            -b "$COOKIE" \
            -X POST \
            "${BASE_URL}/panel/xray/testOutbound" \
            --data-urlencode "outbound@${OUT_FILE}" \
            --data-urlencode "allOutbounds@${ALL_FILE}" \
            2>"$ERR_FILE"
    )"
    CURL_RC=$?

    if [[ $CURL_RC -ne 0 || -z "$RESPONSE" ]]; then

        ERROR="$(tr '\n' ' ' < "$ERR_FILE" 2>/dev/null || true)"
        [[ -n "$ERROR" ]] || ERROR="testOutbound request failed"

        RESULTS="$(
            jq -c \
                --arg tag "$TAG" \
                --arg protocol "$PROTOCOL" \
                --arg error "$ERROR" \
                '. + [{
                    tag:$tag,
                    protocol:$protocol,
                    success:false,
                    delay:0,
                    http_code:0,
                    error:$error
                }]' <<<"$RESULTS"
        )"

        continue
    fi

    OBJ="$(
        printf '%s' "$RESPONSE" |
        jq -c '
            if (.obj | type) == "string" then
                (.obj | fromjson? // {})
            else
                (.obj // {})
            end
        ' 2>/dev/null || echo '{}'
    )"

    TEST_OK="$(jq -r '.success // false' <<<"$OBJ")"
    DELAY="$(jq -r '.delay // 0' <<<"$OBJ")"
    HTTP_CODE="$(jq -r '.statusCode // 0' <<<"$OBJ")"
    ERROR="$(jq -r '.error // ""' <<<"$OBJ")"

    [[ "$DELAY" =~ ^[0-9]+$ ]] || DELAY=0
    [[ "$HTTP_CODE" =~ ^[0-9]+$ ]] || HTTP_CODE=0

    if [[ "$TEST_OK" == "true" ]]; then
        SUCCESS=true
    else
        SUCCESS=false
    fi

    RESULTS="$(
        jq -c \
            --arg tag "$TAG" \
            --arg protocol "$PROTOCOL" \
            --argjson success "$SUCCESS" \
            --argjson delay "$DELAY" \
            --argjson http "$HTTP_CODE" \
            --arg error "$ERROR" \
            '. + [{
                tag:$tag,
                protocol:$protocol,
                success:$success,
                delay:$delay,
                http_code:$http,
                error:$error
            }]' <<<"$RESULTS"
    )"

done < <(printf '%s' "$ALL_OUTBOUNDS" | jq -c '.[]')

jq -n \
    --argjson ts "$NOW" \
    --argjson results "$RESULTS" \
    '{
        timestamp:$ts,
        last_success:$ts,
        collector_success:true,
        collector_error:"",
        outbounds:$results
    }' > "$TMP_FILE"

write_result
EOF

chmod 700 "$COLLECTOR"
chown root:root "$COLLECTOR"

echo
echo "[5/8] Reader..."

cat >"$READER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CACHE="/var/lib/xui-zabbix/results.json"
ACTION="${1:-}"

if [[ ! -r "$CACHE" ]]; then
    case "$ACTION" in
        discovery) echo '{"data":[]}' ;;
        error|collector_error) echo "cache not available" ;;
        *) echo "0" ;;
    esac
    exit 0
fi

case "$ACTION" in

    discovery)
        jq -c '{
            data:[
                .outbounds[] |
                {
                    "{#OUTBOUND}":.tag,
                    "{#PROTOCOL}":.protocol
                }
            ]
        }' "$CACHE"
        ;;

    latency)
        TAG="${2:-}"
        jq -r --arg tag "$TAG" \
            '(.outbounds[] | select(.tag==$tag) | .delay) // 0' \
            "$CACHE"
        ;;

    status)
        TAG="${2:-}"
        jq -r --arg tag "$TAG" \
            '(.outbounds[] | select(.tag==$tag) |
            if .success then 1 else 0 end) // 0' \
            "$CACHE"
        ;;

    http)
        TAG="${2:-}"
        jq -r --arg tag "$TAG" \
            '(.outbounds[] | select(.tag==$tag) | .http_code) // 0' \
            "$CACHE"
        ;;

    error)
        TAG="${2:-}"
        jq -r --arg tag "$TAG" \
            '(.outbounds[] | select(.tag==$tag) | .error) // ""' \
            "$CACHE"
        ;;

    collector)
        jq -r 'if .collector_success then 1 else 0 end' "$CACHE"
        ;;

    collector_error)
        jq -r '.collector_error // ""' "$CACHE"
        ;;

    age)
        LAST="$(jq -r '.last_success // 0' "$CACHE")"
        NOW="$(date +%s)"

        if [[ "$LAST" =~ ^[0-9]+$ ]] && (( LAST > 0 )); then
            echo $((NOW - LAST))
        else
            echo 999999
        fi
        ;;

    raw)
        cat "$CACHE"
        ;;

    *)
        echo 0
        ;;

esac
EOF

chmod 755 "$READER"
chown root:root "$READER"

echo
echo "[6/8] systemd timer..."

cat >/etc/systemd/system/xui-outbound-monitor.service <<'EOF'
[Unit]
Description=3x-ui outbound collector for Zabbix
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/bin/xui-outbound-collector
TimeoutStartSec=5min
EOF

cat >/etc/systemd/system/xui-outbound-monitor.timer <<'EOF'
[Unit]
Description=Run 3x-ui outbound collector every 120 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=120s
AccuracySec=2s
Unit=xui-outbound-monitor.service

[Install]
WantedBy=timers.target
EOF

echo
echo "[7/8] Zabbix UserParameters..."

cat >"$USERPARAM_FILE" <<'EOF'
UserParameter=xui.outbound.discovery,/usr/local/bin/xui-zabbix-reader discovery
UserParameter=xui.outbound.latency[*],/usr/local/bin/xui-zabbix-reader latency "$1"
UserParameter=xui.outbound.status[*],/usr/local/bin/xui-zabbix-reader status "$1"
UserParameter=xui.outbound.http[*],/usr/local/bin/xui-zabbix-reader http "$1"
UserParameter=xui.outbound.error[*],/usr/local/bin/xui-zabbix-reader error "$1"

UserParameter=xui.outbound.collector.status,/usr/local/bin/xui-zabbix-reader collector
UserParameter=xui.outbound.collector.error,/usr/local/bin/xui-zabbix-reader collector_error
UserParameter=xui.outbound.cache.age,/usr/local/bin/xui-zabbix-reader age
UserParameter=xui.outbound.raw,/usr/local/bin/xui-zabbix-reader raw
EOF

systemctl daemon-reload

echo
echo "[8/8] Первый тест и запуск..."

systemctl start xui-outbound-monitor.service
systemctl enable --now xui-outbound-monitor.timer
systemctl restart zabbix-agent

echo
echo "=========================================="
echo " RESULTS"
echo "=========================================="

jq . /var/lib/xui-zabbix/results.json

echo
echo "=== DISCOVERY ==="
sudo -u zabbix /usr/local/bin/xui-zabbix-reader discovery

echo
echo "=== TIMER ==="
systemctl list-timers xui-outbound-monitor.timer --all --no-pager

echo
echo "=== AGENT ==="
systemctl is-active zabbix-agent

echo
echo "=========================================="
echo " ГОТОВО"
echo "=========================================="
INSTALLER

chmod 700 /root/install-xui-zabbix-monitor.sh
/root/install-xui-zabbix-monitor.sh
