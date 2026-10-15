#!/usr/bin/env bash
# Restrict new inbound connections to SSH/HTTP/HTTPS, a trusted-IP 3X-UI panel,
# and the Zabbix agent from its monitoring server.
# Also blocks outgoing SMTP and common BitTorrent ports/signatures.
# BitTorrent filtering is best effort: encrypted/obfuscated traffic can bypass it.
# For Ubuntu/Debian. Prompts for server-specific ports and addresses.
set -Eeuo pipefail

CHAIN4='VPS_WEB_ONLY'
CHAIN6='VPS_WEB_ONLY6'
EGRESS4='VPS_ABUSE_OUT'
EGRESS6='VPS_ABUSE_OUT6'
BACKUP_ROOT='/root/firewall-backups'
SMTP_PORTS='25,465,587,2525'
TORRENT_PORTS='6881:6889,6969,51413'

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
restore_backup() {
  local dir="$1"
  [[ -f "$dir/ipv4.rules" && -f "$dir/ipv6.rules" ]] || die "Backup not found in $dir"
  iptables-restore -w < "$dir/ipv4.rules"
  ip6tables-restore -w < "$dir/ipv6.rules"
  say "Restored IPv4 and IPv6 firewall from $dir"
}

[[ "$EUID" -eq 0 ]] || die 'Run as root (sudo bash ...).'
for program in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore systemd-run systemctl; do
  command -v "$program" >/dev/null 2>&1 || die "Missing command: $program"
done

remove_managed_chain() {
  local tool="$1" chain="$2" hook number
  "$tool" -w -nL "$chain" >/dev/null 2>&1 || return 0
  for hook in INPUT OUTPUT FORWARD; do
    while :; do
      number="$("$tool" -w -L "$hook" --line-numbers -n | awk -v target="$chain" '$2 == target {print $1; exit}')"
      [[ -n "$number" ]] || break
      "$tool" -w -D "$hook" "$number"
    done
  done
  "$tool" -w -F "$chain"
  "$tool" -w -X "$chain"
}
if [[ "${1:-}" == '--remove' ]]; then
  [[ $# -eq 1 ]] || die 'Usage: bash restrict-xui-panel-ip.sh --remove'
  # Remove only this combined script's rules and the original panel guard.
  for chain in "$CHAIN4" "$EGRESS4" XUI_PANEL_GUARD; do
    remove_managed_chain iptables "$chain"
  done
  for chain in "$CHAIN6" "$EGRESS6" XUI_PANEL_GUARD6; do
    remove_managed_chain ip6tables "$chain"
  done
  rm -f /etc/x-ui/panel-firewall.env
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    chmod 0600 /etc/iptables/rules.v4 /etc/iptables/rules.v6
  fi
  say 'Ограничения панели и правила этого скрипта удалены. Остальные правила сохранены.'
  exit 0
fi

if [[ "${1:-}" == '--rollback' ]]; then
  [[ $# -eq 2 ]] || die 'Usage: script --rollback /root/firewall-backups/DIR'
  restore_backup "$2"
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || say 'WARNING: Could not persist restored rules.'
  fi
  exit 0
fi
[[ $# -eq 0 ]] || die 'Usage: sudo bash restrict-xui-panel-ip.sh [--remove]'
PANEL_PORT="${PANEL_PORT:-}"
TRUSTED_IPV4="${TRUSTED_IPV4:-}"
# Rollback above never prompts or depends on the current panel settings.
if [[ -r /etc/x-ui/panel-firewall.env ]]; then
  # Root-owned settings produced by restrict-xui-panel-ip.sh.
  saved_panel="$(source /etc/x-ui/panel-firewall.env; printf '%s' "${PANEL_PORT:-}")"
  saved_trusted="$(source /etc/x-ui/panel-firewall.env; printf '%s' "${TRUSTED_IPV4:-}")"
  PANEL_PORT="${PANEL_PORT:-${saved_panel}}"
  TRUSTED_IPV4="${TRUSTED_IPV4:-${saved_trusted}}"
fi
if [[ -z "${PANEL_PORT:-}" ]]; then
  for binary in /usr/local/x-ui/x-ui /usr/bin/x-ui; do
    [[ -x "$binary" ]] || continue
    PANEL_PORT="$("$binary" setting -show 2>/dev/null | awk -F': *' '/^[[:space:]]*port:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' || true)"
    [[ -z "$PANEL_PORT" ]] || break
  done
fi
if [[ -z "${PANEL_PORT:-}" ]]; then
  read -r -p 'Порт панели 3X-UI: ' PANEL_PORT || die 'Не удалось прочитать порт панели'
fi
if [[ -z "${TRUSTED_IPV4//[[:space:]]/}" ]]; then
  ssh_connection="${SSH_CONNECTION:-${SSH_CLIENT:-}}"
  TRUSTED_IPV4="${ssh_connection%% *}"
fi
read -r -p "Разрешённые IPv4 через пробел [${TRUSTED_IPV4:-нет}]: " trusted_input || die 'Не удалось прочитать IP'
if [[ -n "${trusted_input//[[:space:]]/}" ]]; then
  TRUSTED_IPV4="$trusted_input"
fi
TRUSTED_IPS=()
read -r -a TRUSTED_IPS <<< "$TRUSTED_IPV4"
if [[ -z "${SSH_PORTS:-}" ]]; then
  detected_ssh_port=22
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    detected_ssh_port="${SSH_CONNECTION##* }"
  fi
  read -r -p "Порты SSH через запятую [${detected_ssh_port}]: " SSH_PORTS || die 'Не удалось прочитать порты SSH'
  SSH_PORTS="${SSH_PORTS:-${detected_ssh_port}}"
fi
if [[ ! -v ZABBIX_IP ]]; then
  read -r -p 'IPv4 сервера Zabbix (Enter — не открывать порт агента): ' ZABBIX_IP || die 'Не удалось прочитать IP Zabbix'
fi
say "Панель: ${PANEL_PORT}; разрешённые IPv4: ${TRUSTED_IPS[*]}"
say "SSH: ${SSH_PORTS}; Zabbix: ${ZABBIX_IP:-выключен}"
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && ((PANEL_PORT >= 1 && PANEL_PORT <= 65535)) || die 'Invalid PANEL_PORT'
[[ "${#TRUSTED_IPS[@]}" -gt 0 ]] || die 'No trusted IPv4 sources configured'
command -v python3 >/dev/null 2>&1 || die 'Missing command: python3'
python3 - "$PANEL_PORT" "$ZABBIX_IP" "$SSH_PORTS" "${TRUSTED_IPS[@]}" <<'PY'
import ipaddress, sys
panel, zabbix, ssh, *trusted = sys.argv[1:]
for value in ([zabbix] if zabbix else []) + trusted:
    ipaddress.IPv4Address(value)
ports = ssh.split(',')
if not ports or len(ports) > 13 or any(not p.isascii() or not p.isdecimal() or not 1 <= int(p) <= 65535 for p in ports):
    raise SystemExit('SSH_PORTS must contain 1 to 13 TCP ports separated by commas')
if int(panel) in {80, 443, *map(int, ports)}:
    raise SystemExit('Panel port must differ from public SSH/HTTP/HTTPS ports')
PY

mkdir -p "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"
BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 0700 "$BACKUP_DIR"
iptables-save > "$BACKUP_DIR/ipv4.rules"
ip6tables-save > "$BACKUP_DIR/ipv6.rules"
chmod 0600 "$BACKUP_DIR"/*.rules

# Keep an immutable copy for rollback even if the uploaded script is replaced.
cp -- "$(readlink -f "${BASH_SOURCE[0]}")" "$BACKUP_DIR/rollback.sh"
chmod 0700 "$BACKUP_DIR/rollback.sh"
SCRIPT_PATH="$BACKUP_DIR/rollback.sh"
UNIT="vps-webfw-rollback-$(date +%s)-$$"
say "Original firewall backed up to: $BACKUP_DIR"
say 'Scheduling automatic rollback in 3 minutes, unless rules are confirmed.'
systemd-run --quiet --unit="$UNIT" --on-active=180s \
  /bin/bash "$SCRIPT_PATH" --rollback "$BACKUP_DIR"

restore_if_error() {
  local rc=$?
  trap - ERR
  say 'Failed to apply new firewall. Restoring backup...' >&2
  restore_backup "$BACKUP_DIR" || true
  systemctl stop "$UNIT.timer" >/dev/null 2>&1 || true
  exit "$rc"
}
trap restore_if_error ERR

# Filter both local applications (including Xray) and forwarded traffic.
# RETURN preserves any existing OUTPUT/FORWARD restrictions for other traffic.
# No ESTABLISHED bypass here: existing SMTP sessions are blocked as well.
configure_egress() {
  local tool="$1" chain="$2" hook
  "$tool" -w -N "$chain" 2>/dev/null || "$tool" -w -nL "$chain" >/dev/null
  "$tool" -w -F "$chain"
  "$tool" -w -A "$chain" -o lo -j RETURN
  "$tool" -w -A "$chain" -p tcp -m multiport --dports "$SMTP_PORTS" -j REJECT
  for protocol in tcp udp; do
    "$tool" -w -A "$chain" -p "$protocol" -m multiport --dports "$TORRENT_PORTS" -j REJECT
    "$tool" -w -A "$chain" -p "$protocol" -m string --algo kmp --string 'BitTorrent protocol' -j DROP
  done
  # Common unencrypted DHT messages; not a complete DHT detector.
  "$tool" -w -A "$chain" -p udp -m string --algo kmp --string 'd1:ad2:id20:' -j DROP
  "$tool" -w -A "$chain" -p udp -m string --algo kmp --string 'd1:rd2:id20:' -j DROP
  # UDP tracker protocol connection identifier (BEP 15).
  "$tool" -w -A "$chain" -p udp -m string --algo kmp --hex-string '|0000041727101980|' -j DROP
  "$tool" -w -A "$chain" -j RETURN
  for hook in OUTPUT FORWARD; do
    while "$tool" -w -D "$hook" -j "$chain" >/dev/null 2>&1; do :; done
    "$tool" -w -I "$hook" 1 -j "$chain"
  done
}
configure_egress iptables "$EGRESS4"
configure_egress ip6tables "$EGRESS6"

# These chains are placed BEFORE ISPmanager, UFW and the old XUI_PANEL_GUARD.
# The old chains are kept untouched, so rollback restores the exact old rules.
iptables -N "$CHAIN4" 2>/dev/null || true
iptables -F "$CHAIN4"
iptables -A "$CHAIN4" -i lo -j ACCEPT
iptables -A "$CHAIN4" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "$CHAIN4" -m conntrack --ctstate INVALID -j DROP
iptables -A "$CHAIN4" -p icmp -j ACCEPT
iptables -A "$CHAIN4" -p tcp -m multiport --dports "$SSH_PORTS,80,443" -j ACCEPT
for ip in "${TRUSTED_IPS[@]}"; do
  iptables -A "$CHAIN4" -p tcp -s "$ip/32" --dport "$PANEL_PORT" -j ACCEPT
done
if [[ -n "$ZABBIX_IP" ]]; then
  iptables -A "$CHAIN4" -p tcp -s "$ZABBIX_IP/32" --dport 10050 -j ACCEPT
fi
iptables -A "$CHAIN4" -j DROP
while iptables -D INPUT -j "$CHAIN4" >/dev/null 2>&1; do :; done
iptables -I INPUT 1 -j "$CHAIN4"

ip6tables -N "$CHAIN6" 2>/dev/null || true
ip6tables -F "$CHAIN6"
ip6tables -A "$CHAIN6" -i lo -j ACCEPT
ip6tables -A "$CHAIN6" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# ICMPv6 is required for IPv6 neighbor discovery, PMTU, etc.
ip6tables -A "$CHAIN6" -p ipv6-icmp -j ACCEPT
ip6tables -A "$CHAIN6" -m conntrack --ctstate INVALID -j DROP
ip6tables -A "$CHAIN6" -p tcp -m multiport --dports "$SSH_PORTS,80,443" -j ACCEPT
ip6tables -A "$CHAIN6" -j DROP
while ip6tables -D INPUT -j "$CHAIN6" >/dev/null 2>&1; do :; done
ip6tables -I INPUT 1 -j "$CHAIN6"

say ''
say 'IPv4 INPUT firewall:'
iptables -L "$CHAIN4" -n --line-numbers
say ''
say 'IPv6 INPUT firewall:'
ip6tables -L "$CHAIN6" -n --line-numbers
say 'IPv4 anti-abuse firewall (OUTPUT and FORWARD):'
iptables -L "$EGRESS4" -n -v --line-numbers
say 'IPv6 anti-abuse firewall (OUTPUT and FORWARD):'
ip6tables -L "$EGRESS6" -n -v --line-numbers
say "Outgoing SMTP blocked on TCP: $SMTP_PORTS (for the whole VPS)."
say "Common BitTorrent TCP/UDP destination ports blocked: $TORRENT_PORTS."
say 'BitTorrent signature filtering is best effort; encrypted traffic can bypass it.'
say 'SMTP carried inside WARP or another encrypted outbound tunnel can bypass local filtering.'
say ''
say 'Important: test a NEW SSH connection, your website, the panel and Zabbix.'
say "If you lose SSH, rollback will run automatically. Backup: $BACKUP_DIR"
say 'Type YES to keep these rules (within 150 seconds); anything else rolls back.'
confirm=''
if read -r -t 150 -p 'Keep rules? [YES/no]: ' confirm && [[ "$confirm" == 'YES' ]] && systemctl -q is-active "$UNIT.timer"; then
  systemctl stop "$UNIT.timer"
  mkdir -p /etc/x-ui
  {
    printf 'PANEL_PORT=%q\n' "$PANEL_PORT"
    printf 'TRUSTED_IPV4=%q\n' "${TRUSTED_IPS[*]}"
  } > /etc/x-ui/panel-firewall.env
  chmod 0600 /etc/x-ui/panel-firewall.env
  trap - ERR
  if command -v netfilter-persistent >/dev/null 2>&1; then
    if netfilter-persistent save; then
      say 'Saved with netfilter-persistent for reboot persistence.'
    else
      say 'WARNING: Rules are live, but persistence failed. Fix before reboot.'
    fi
  else
    say 'WARNING: netfilter-persistent not found. Rules are live but may not persist across reboot.'
    say 'Install iptables-persistent AFTER testing and save using netfilter-persistent save.'
  fi
  say "Done. Manual restore: sudo bash '$SCRIPT_PATH' --rollback '$BACKUP_DIR'"
  say 'Удалить правила: sudo bash restrict-xui-panel-ip.sh --remove'
else
  trap - ERR
  systemctl stop "$UNIT.timer" >/dev/null 2>&1 || true
  restore_backup "$BACKUP_DIR"
  say 'User did not confirm; original firewall restored.'
fi
