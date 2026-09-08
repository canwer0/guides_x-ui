#!/usr/bin/env bash
set -Eeuo pipefail

# Ограничивает доступ к порту панели 3x-ui одним доверенным IPv4.
# Для Debian/Ubuntu с systemd и iptables.

readonly CHAIN4="XUI_PANEL_GUARD"
readonly CHAIN6="XUI_PANEL_GUARD6"
readonly RULE_COMMENT="xui-panel-guard"
readonly STATE_DIR="/etc/x-ui"
readonly STATE_FILE="${STATE_DIR}/panel-firewall.env"

say() {
    printf '%s\n' "$*"
}

die() {
    printf 'ОШИБКА: %s\n' "$*" >&2
    exit 1
}

[[ ${EUID} -eq 0 ]] || die "запусти скрипт от root"
command -v iptables >/dev/null 2>&1 || die "iptables не установлен"

valid_ipv4() {
    local ip="$1" a b c d extra octet

    IFS=. read -r a b c d extra <<< "${ip}"

    [[ -z "${extra:-}" &&
       -n "${a:-}" &&
       -n "${b:-}" &&
       -n "${c:-}" &&
       -n "${d:-}" ]] || return 1

    for octet in "$a" "$b" "$c" "$d"; do
        [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#${octet} >= 0 && 10#${octet} <= 255 )) || return 1
    done
}

valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] &&
        (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

remove_input_jumps() {
    local tool="$1"
    local chain="$2"
    local number

    command -v "${tool}" >/dev/null 2>&1 || return 0

    while :; do
        number="$(
            "${tool}" -L INPUT --line-numbers -n 2>/dev/null |
                awk -v target="${chain}" '$2 == target {print $1; exit}'
        )"

        [[ -n "${number}" ]] || break
        "${tool}" -D INPUT "${number}"
    done
}

save_rules() {
    mkdir -p /etc/iptables

    iptables-save > /etc/iptables/rules.v4
    chmod 0600 /etc/iptables/rules.v4

    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6
        chmod 0600 /etc/iptables/rules.v6
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null
        systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    fi
}

remove_guard() {
    remove_input_jumps iptables "${CHAIN4}"

    if iptables -nL "${CHAIN4}" >/dev/null 2>&1; then
        iptables -F "${CHAIN4}"
        iptables -X "${CHAIN4}"
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        remove_input_jumps ip6tables "${CHAIN6}"

        if ip6tables -nL "${CHAIN6}" >/dev/null 2>&1; then
            ip6tables -F "${CHAIN6}"
            ip6tables -X "${CHAIN6}"
        fi
    fi
}

if [[ "${1:-}" == "--remove" ]]; then
    remove_guard
    rm -f "${STATE_FILE}"
    save_rules

    say "Ограничение доступа к панели удалено."
    exit 0
fi

detect_panel_port() {
    local binary output port

    for binary in /usr/local/x-ui/x-ui /usr/bin/x-ui; do
        [[ -x "${binary}" ]] || continue

        output="$("${binary}" setting -show 2>/dev/null || true)"

        port="$(
            awk -F': *' '
                /^[[:space:]]*port:/ {
                    gsub(/[[:space:]]/, "", $2)
                    print $2
                    exit
                }
            ' <<< "${output}"
        )"

        if valid_port "${port:-}"; then
            printf '%s' "${port}"
            return 0
        fi
    done

    return 1
}

panel_port="$(detect_panel_port || true)"

while ! valid_port "${panel_port:-}"; do
    read -r -p "Введи порт панели 3x-ui: " panel_port

    valid_port "${panel_port}" ||
        say "Некорректный порт. Допустимо от 1 до 65535."
done

ssh_ip=""
login_source=""

# Сначала пробуем получить адрес текущего SSH-подключения.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r ssh_ip _ <<< "${SSH_CONNECTION}"
elif [[ -n "${SSH_CLIENT:-}" ]]; then
    read -r ssh_ip _ <<< "${SSH_CLIENT}"
fi

# Резервный вариант для некоторых SSH-сеансов.
if ! valid_ipv4 "${ssh_ip:-}"; then
    login_source="$(
        who -m 2>/dev/null |
            awk '{print $NF}' |
            tr -d '()' ||
            true
    )"

    if valid_ipv4 "${login_source:-}"; then
        ssh_ip="${login_source}"
    fi
fi

# Если sudo или веб-консоль удалили SSH-переменные,
# берём IPv4 последнего записанного входа.
if ! valid_ipv4 "${ssh_ip:-}" &&
   command -v last >/dev/null 2>&1; then

    login_source="$(
        last -i -n 20 2>/dev/null |
            awk '
                $1 != "reboot" &&
                $1 != "wtmp" &&
                $3 != "0.0.0.0" &&
                $3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
                    print $3
                    exit
                }
            ' ||
            true
    )"

    if valid_ipv4 "${login_source:-}"; then
        ssh_ip="${login_source}"
    fi
fi

valid_ipv4 "${ssh_ip:-}" || ssh_ip=""

while :; do
    if [[ -n "${ssh_ip}" ]]; then
        read -r -p \
            "Разрешённый IPv4 [IP основного входа: ${ssh_ip}]: " \
            trusted_ip

        trusted_ip="${trusted_ip:-${ssh_ip}}"
    else
        read -r -p "Введи разрешённый публичный IPv4: " trusted_ip
    fi

    if ! valid_ipv4 "${trusted_ip}"; then
        say "Некорректный IPv4. Попробуй ещё раз."
        continue
    fi

    say ""
    say "Порт панели:       ${panel_port}/tcp"
    say "Разрешённый адрес: ${trusted_ip}/32"
    say "Остальные IPv4 и удалённые IPv6 будут заблокированы."
    say ""

    read -r -p "Всё правильно? [y/n]: " confirmation

    case "${confirmation}" in
        y|Y|yes|YES|Yes|д|Д|да|ДА)
            break
            ;;
        n|N|no|NO|No|н|Н|нет|НЕТ)
            say "Введи адрес повторно."
            ssh_ip=""
            ;;
        *)
            say "Ответь y или n."
            ;;
    esac
done

if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null | grep -q '^Status: active'; then
    say "ПРЕДУПРЕЖДЕНИЕ: UFW активен."
    say "Последующий ufw reload может заменить пользовательские правила."
fi

if ! command -v netfilter-persistent >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 ||
        die "установи iptables-persistent вручную"

    export DEBIAN_FRONTEND=noninteractive

    say "Устанавливаю сохранение правил после перезагрузки..."

    apt-get update
    apt-get install -y --no-install-recommends \
        iptables-persistent \
        netfilter-persistent
fi

# Удаляем правила предыдущего запуска.
remove_guard

# Правила IPv4.
iptables -N "${CHAIN4}"
iptables -A "${CHAIN4}" -s 127.0.0.0/8 -j ACCEPT
iptables -A "${CHAIN4}" -s "${trusted_ip}/32" -j ACCEPT
iptables -A "${CHAIN4}" -j DROP

iptables -I INPUT 1 \
    -p tcp \
    --dport "${panel_port}" \
    -m comment \
    --comment "${RULE_COMMENT}" \
    -j "${CHAIN4}"

# Запрещаем удалённый доступ к панели через IPv6.
# Локальный адрес ::1 остаётся доступен.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -N "${CHAIN6}"
    ip6tables -A "${CHAIN6}" -s ::1/128 -j ACCEPT
    ip6tables -A "${CHAIN6}" -j DROP

    ip6tables -I INPUT 1 \
        -p tcp \
        --dport "${panel_port}" \
        -m comment \
        --comment "${RULE_COMMENT}" \
        -j "${CHAIN6}"
fi

mkdir -p "${STATE_DIR}"

{
    printf 'PANEL_PORT=%q\n' "${panel_port}"
    printf 'TRUSTED_IPV4=%q\n' "${trusted_ip}"
} > "${STATE_FILE}"

chmod 0600 "${STATE_FILE}"

save_rules

say ""
say "Правило установлено и сохранено."
say "Панель на порту ${panel_port} доступна только с ${trusted_ip}."
say "SSH и остальные порты не изменялись."
say ""
say "Удаление ограничения:"
say "bash $0 --remove"
