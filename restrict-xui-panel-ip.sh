#!/usr/bin/env bash
set -Eeuo pipefail

# Restrict the 3x-ui panel TCP port to one trusted public IPv4 address.
# Supported target: Debian/Ubuntu with systemd and iptables.

readonly CHAIN4="XUI_PANEL_GUARD"
readonly CHAIN6="XUI_PANEL_GUARD6"
readonly RULE_COMMENT="xui-panel-guard"
readonly STATE_DIR="/etc/x-ui"
readonly STATE_FILE="${STATE_DIR}/panel-firewall.env"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run this script as root"
command -v iptables >/dev/null 2>&1 || die "iptables is not installed"

valid_ipv4() {
    local ip="$1" a b c d extra octet
    IFS=. read -r a b c d extra <<< "${ip}"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#${octet} >= 0 && 10#${octet} <= 255 )) || return 1
    done
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

remove_input_jumps() {
    local tool="$1" chain="$2" number
    command -v "${tool}" >/dev/null 2>&1 || return 0
    while :; do
        number="$(${tool} -L INPUT --line-numbers -n 2>/dev/null | awk -v target="${chain}" '$2 == target {print $1; exit}')"
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
    say "3x-ui panel restriction removed."
    exit 0
fi

detect_panel_port() {
    local binary output port
    for binary in /usr/local/x-ui/x-ui /usr/bin/x-ui; do
        [[ -x "${binary}" ]] || continue
        output="$(${binary} setting -show 2>/dev/null || true)"
        port="$(awk -F': *' '/^[[:space:]]*port:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "${output}")"
        if valid_port "${port:-}"; then
            printf '%s' "${port}"
            return 0
        fi
    done
    return 1
}

panel_port="$(detect_panel_port || true)"
while ! valid_port "${panel_port:-}"; do
    read -r -p "Enter the 3x-ui panel port: " panel_port
    valid_port "${panel_port}" || say "Invalid port. Enter a number from 1 to 65535."
done

ssh_ip="${SSH_CONNECTION%% *}"
ssh_ip=""

# Prefer the public source address of the current SSH session. Some hosting
# consoles do not export SSH_CONNECTION, so try the other standard sources.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r ssh_ip _ <<< "${SSH_CONNECTION}"
elif [[ -n "${SSH_CLIENT:-}" ]]; then
    read -r ssh_ip _ <<< "${SSH_CLIENT}"
else
    login_source="$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()' || true)"
    if valid_ipv4 "${login_source:-}"; then
        ssh_ip="${login_source}"
    fi
fi

valid_ipv4 "${ssh_ip:-}" || ssh_ip=""

while :; do
    if [[ -n "${ssh_ip}" ]]; then
        read -r -p "Enter trusted public IPv4 [current SSH IP: ${ssh_ip}]: " trusted_ip
        trusted_ip="${trusted_ip:-${ssh_ip}}"
    else
        read -r -p "Enter trusted public IPv4: " trusted_ip
    fi

    if ! valid_ipv4 "${trusted_ip}"; then
        say "Invalid IPv4 address. Try again."
        continue
    fi

    say ""
    say "3x-ui panel port : ${panel_port}/tcp"
    say "Allowed IPv4     : ${trusted_ip}/32"
    say "All other IPv4 and all remote IPv6 connections to this port will be dropped."
    read -r -p "Is this correct? [y/n]: " confirmation
    case "${confirmation}" in
        y|Y|yes|YES|Yes) break ;;
        n|N|no|NO|No) say "Enter the address again." ;;
        *) say "Please answer y or n." ;;
    esac
done

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    say "WARNING: UFW is active. A future 'ufw reload' may replace custom iptables rules."
fi

if ! command -v netfilter-persistent >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "install iptables-persistent manually, then rerun"
    export DEBIAN_FRONTEND=noninteractive
    say "Installing rule persistence support"
    apt-get update
    apt-get install -y --no-install-recommends iptables-persistent netfilter-persistent
fi

# Remove any rules created by an earlier run, irrespective of the old port.
remove_guard

iptables -N "${CHAIN4}"
iptables -A "${CHAIN4}" -s 127.0.0.0/8 -j ACCEPT
iptables -A "${CHAIN4}" -s "${trusted_ip}/32" -j ACCEPT
iptables -A "${CHAIN4}" -j DROP
iptables -I INPUT 1 -p tcp --dport "${panel_port}" \
    -m comment --comment "${RULE_COMMENT}" -j "${CHAIN4}"

# The trusted address is IPv4, so prevent the same panel port from remaining
# reachable over public IPv6. Local ::1 access remains available.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -N "${CHAIN6}"
    ip6tables -A "${CHAIN6}" -s ::1/128 -j ACCEPT
    ip6tables -A "${CHAIN6}" -j DROP
    ip6tables -I INPUT 1 -p tcp --dport "${panel_port}" \
        -m comment --comment "${RULE_COMMENT}" -j "${CHAIN6}"
fi

mkdir -p "${STATE_DIR}"
{
    printf 'PANEL_PORT=%q\n' "${panel_port}"
    printf 'TRUSTED_IPV4=%q\n' "${trusted_ip}"
} > "${STATE_FILE}"
chmod 0600 "${STATE_FILE}"

save_rules

say ""
say "Firewall rule installed and saved."
say "Only ${trusted_ip} can reach the 3x-ui panel on TCP port ${panel_port}."
say "Existing SSH rules and other service ports were not changed."
say ""
say "Remove the restriction with: sudo bash $0 --remove"
