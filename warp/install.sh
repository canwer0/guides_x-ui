#!/usr/bin/env bash
set -Eeuo pipefail

WARP_ADDR="127.0.0.1"
WARP_PORT="40000"

XUI_DB="/etc/x-ui/x-ui.db"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
PLAIN='\033[0m'

info() {
    echo -e "${GREEN}[+]${PLAIN} $*"
}

warn() {
    echo -e "${YELLOW}[!]${PLAIN} $*"
}

die() {
    echo -e "${RED}[ERROR]${PLAIN} $*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "Run as root."

[[ -f "$XUI_DB" ]] || die "3X-UI database not found: $XUI_DB"

source /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        die "Supported OS: Ubuntu / Debian"
        ;;
esac


# ============================================================
# Required packages
# ============================================================

export DEBIAN_FRONTEND=noninteractive

info "Installing required packages..."

apt-get update -qq

apt-get install -y -qq --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    python3 \
    iproute2


# ============================================================
# Install Cloudflare WARP
# ============================================================

if ! command -v warp-cli >/dev/null 2>&1; then

    info "Installing Cloudflare WARP..."

    install -d -m 0755 /usr/share/keyrings

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor \
        -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    CODENAME="${VERSION_CODENAME:-}"

    [[ -n "$CODENAME" ]] || die "Could not determine OS codename."

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update -qq

    apt-get install -y -qq --no-install-recommends cloudflare-warp

else
    info "Cloudflare WARP already installed."
fi


# ============================================================
# Start service
# ============================================================

info "Starting warp-svc..."

systemctl enable --now warp-svc >/dev/null 2>&1 || true

sleep 2

systemctl is-active --quiet warp-svc \
    || die "warp-svc failed to start."


# ============================================================
# Registration
# ============================================================

info "Checking WARP registration..."

REGISTRATION="$(
    warp-cli --accept-tos registration show 2>&1 || true
)"

if echo "$REGISTRATION" | grep -qiE \
    "Missing registration|not registered|registration.*missing"; then

    info "Registering WARP..."

    warp-cli --accept-tos registration new \
        || die "WARP registration failed."

else
    info "WARP is already registered."
fi


# ============================================================
# Configure SOCKS proxy
# ============================================================

info "Configuring SOCKS5 proxy on ${WARP_ADDR}:${WARP_PORT}..."

warp-cli --accept-tos disconnect >/dev/null 2>&1 || true

warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 || true

warp-cli --accept-tos mode proxy \
    || die "Could not enable proxy mode."

warp-cli --accept-tos proxy port "$WARP_PORT" \
    || die "Could not set proxy port."

warp-cli --accept-tos connect \
    || die "Could not connect WARP."


# ============================================================
# Check WARP
# ============================================================

info "Waiting for WARP..."

WARP_OK=0

for i in $(seq 1 30); do

    TRACE="$(
        curl -fsS \
            --max-time 8 \
            --socks5-hostname "${WARP_ADDR}:${WARP_PORT}" \
            https://www.cloudflare.com/cdn-cgi/trace \
            2>/dev/null || true
    )"

    if echo "$TRACE" | grep -q '^warp=on$'; then
        WARP_OK=1
        break
    fi

    sleep 2
done

[[ "$WARP_OK" == "1" ]] \
    || die "WARP SOCKS proxy is not working."

info "WARP SOCKS is working."


# ============================================================
# Backup 3X-UI database
# ============================================================

BACKUP="${XUI_DB}.warp-backup-$(date +%Y%m%d-%H%M%S)"

info "Creating database backup..."
info "$BACKUP"


# ============================================================
# Add WARP outbound
# ============================================================

XUI_DB="$XUI_DB" \
BACKUP="$BACKUP" \
WARP_ADDR="$WARP_ADDR" \
WARP_PORT="$WARP_PORT" \
python3 <<'PY'

import json
import os
import sqlite3
import sys


db_path = os.environ["XUI_DB"]
backup_path = os.environ["BACKUP"]

warp_addr = os.environ["WARP_ADDR"]
warp_port = int(os.environ["WARP_PORT"])


warp_outbound = {
    "tag": "warp",
    "protocol": "socks",
    "settings": {
        "servers": [
            {
                "address": warp_addr,
                "port": warp_port,
                "users": []
            }
        ]
    }
}


conn = sqlite3.connect(db_path, timeout=30)


try:

    table = conn.execute(
        """
        SELECT name
        FROM sqlite_master
        WHERE type='table'
        AND name='settings'
        """
    ).fetchone()

    if not table:
        raise RuntimeError("settings table not found")


    # SQLite-safe backup
    backup_conn = sqlite3.connect(backup_path)

    try:
        conn.backup(backup_conn)
    finally:
        backup_conn.close()


    row = conn.execute(
        """
        SELECT value
        FROM settings
        WHERE key=?
        """,
        ("xrayTemplateConfig",)
    ).fetchone()


    if not row or not row[0]:
        raise RuntimeError(
            "xrayTemplateConfig not found in database"
        )


    config = json.loads(row[0])

    outbounds = config.setdefault("outbounds", [])

    if not isinstance(outbounds, list):
        raise RuntimeError("outbounds is not an array")


    indexes = []

    for i, outbound in enumerate(outbounds):

        if (
            isinstance(outbound, dict)
            and outbound.get("tag") == "warp"
        ):
            indexes.append(i)


    if indexes:

        outbounds[indexes[0]] = warp_outbound

        for i in reversed(indexes[1:]):
            del outbounds[i]

        action = "updated"

    else:

        outbounds.append(warp_outbound)

        action = "created"


    new_config = json.dumps(
        config,
        ensure_ascii=False,
        separators=(",", ":")
    )


    conn.execute(
        """
        UPDATE settings
        SET value=?
        WHERE key=?
        """,
        (
            new_config,
            "xrayTemplateConfig"
        )
    )


    conn.commit()


    print()
    print(f"[+] WARP outbound {action}")
    print("[+] tag: warp")
    print("[+] protocol: socks")
    print(f"[+] address: {warp_addr}")
    print(f"[+] port: {warp_port}")
    print()


except Exception as exc:

    conn.rollback()

    print(
        f"[ERROR] {exc}",
        file=sys.stderr
    )

    sys.exit(1)


finally:

    conn.close()

PY


# ============================================================
# Restart x-ui
# ============================================================

info "Restarting 3X-UI..."

systemctl daemon-reload >/dev/null 2>&1 || true

systemctl restart x-ui \
    || die "Failed to restart x-ui."

sleep 3

systemctl is-active --quiet x-ui \
    || die "x-ui is not running."


# ============================================================
# Final output
# ============================================================

echo
echo "=================================================="
echo " WARP successfully configured"
echo "=================================================="
echo

echo "WARP:"
warp-cli --accept-tos status || true

echo
echo "SOCKS:"
ss -lntp | grep ":${WARP_PORT}" || true

echo
echo "Cloudflare trace:"

curl -fsS \
    --socks5-hostname "${WARP_ADDR}:${WARP_PORT}" \
    https://www.cloudflare.com/cdn-cgi/trace \
    | grep -E '^(ip|colo|warp)=' \
    || true

echo
echo "3X-UI outbound:"
echo
echo "  tag:      warp"
echo "  protocol: socks"
echo "  address:  ${WARP_ADDR}"
echo "  port:     ${WARP_PORT}"
echo
echo "Database backup:"
echo
echo "  ${BACKUP}"
echo
echo "Done."
