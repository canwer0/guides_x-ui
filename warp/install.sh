#!/usr/bin/env bash

# ============================================================
# Cloudflare WARP SOCKS5 for original MHSanaei 3X-UI v2.8.11
#
# Installs/configures:
#   WARP Local Proxy : 127.0.0.1:40000
#
# Automatically creates/updates Xray outbound:
#   tag      : warp
#   protocol : socks
#   address  : 127.0.0.1
#   port     : 40000
#
# Does NOT modify routing rules.
# ============================================================


# ------------------------------------------------------------
# Protect against "source install.sh"
# ------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "[ERROR] Do not run this script with source or '.'"
    echo "Run it with:"
    echo "bash <(curl -fsSL URL)"
    return 1
fi


set -uo pipefail


# ============================================================
# Configuration
# ============================================================

WARP_ADDR="127.0.0.1"
WARP_PORT="40000"

XUI_DB="/etc/x-ui/x-ui.db"

# Original MHSanaei 3X-UI v2.8.11 default Xray template
DEFAULT_XRAY_CONFIG_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/v2.8.11/web/service/config.json"


GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PLAIN='\033[0m'


# ============================================================
# Helpers
# ============================================================

info() {
    echo -e "${GREEN}[+]${PLAIN} $*"
}

warn() {
    echo -e "${YELLOW}[!]${PLAIN} $*"
}

error() {
    echo -e "${RED}[ERROR]${PLAIN} $*" >&2
}

die() {
    error "$*"
    exit 1
}


# ============================================================
# Basic checks
# ============================================================

[[ $EUID -eq 0 ]] || die "Run this script as root."

[[ -f "$XUI_DB" ]] || die "3X-UI database not found: $XUI_DB"

command -v systemctl >/dev/null 2>&1 \
    || die "systemd is required."

[[ -f /etc/os-release ]] \
    || die "/etc/os-release not found."

source /etc/os-release


case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        die "Supported OS: Ubuntu / Debian"
        ;;
esac


info "Detected OS: ${PRETTY_NAME:-$ID}"


# ============================================================
# Required packages
# ============================================================

export DEBIAN_FRONTEND=noninteractive


info "Installing required packages..."

if ! apt-get update -qq; then
    die "apt-get update failed."
fi


if ! apt-get install -y -qq --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    python3 \
    iproute2; then

    die "Failed to install required packages."
fi


# ============================================================
# Install Cloudflare WARP
# ============================================================

if ! command -v warp-cli >/dev/null 2>&1; then

    info "Cloudflare WARP is not installed."
    info "Adding official Cloudflare repository..."


    install -d -m 0755 /usr/share/keyrings


    if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor \
        --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; then

        die "Failed to install Cloudflare repository key."
    fi


    CODENAME="$(lsb_release -cs 2>/dev/null || true)"

    [[ -n "$CODENAME" ]] \
        || die "Could not determine distribution codename."


    echo \
"deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list


    info "Updating package list..."

    if ! apt-get update -qq; then
        die "Could not update Cloudflare repository."
    fi


    info "Installing cloudflare-warp..."

    if ! apt-get install -y -qq --no-install-recommends cloudflare-warp; then
        die "Failed to install cloudflare-warp."
    fi

else

    info "Cloudflare WARP already installed."

fi


command -v warp-cli >/dev/null 2>&1 \
    || die "warp-cli is unavailable after installation."


# ============================================================
# Start warp-svc
# ============================================================

info "Starting warp-svc..."


systemctl enable warp-svc >/dev/null 2>&1 || true


if ! systemctl restart warp-svc; then
    die "Failed to start warp-svc."
fi


sleep 2


if ! systemctl is-active --quiet warp-svc; then

    error "warp-svc is not active."

    systemctl status warp-svc --no-pager || true

    exit 1
fi


# ============================================================
# WARP registration
# ============================================================

info "Checking WARP registration..."


REGISTRATION="$(
    warp-cli --accept-tos registration show 2>&1 || true
)"


if echo "$REGISTRATION" \
    | grep -qiE "Missing registration|not registered|registration.*missing"; then

    info "Registering WARP..."


    if ! warp-cli --accept-tos registration new; then
        die "WARP registration failed."
    fi

else

    info "WARP is already registered."

fi


# ============================================================
# Configure Local Proxy
# ============================================================

info "Configuring WARP SOCKS5 proxy on ${WARP_ADDR}:${WARP_PORT}..."


warp-cli --accept-tos disconnect >/dev/null 2>&1 || true


# Current WARP Proxy Mode requires MASQUE.
if ! warp-cli --accept-tos tunnel protocol set MASQUE; then
    warn "Could not explicitly set MASQUE."
fi


if ! warp-cli --accept-tos mode proxy; then
    die "Could not enable WARP proxy mode."
fi


if ! warp-cli --accept-tos proxy port "$WARP_PORT"; then
    die "Could not configure WARP proxy port."
fi


if ! warp-cli --accept-tos connect; then
    die "Could not connect WARP."
fi


# ============================================================
# Wait for WARP
# ============================================================

info "Waiting for WARP SOCKS proxy..."


WARP_OK=0


for i in $(seq 1 30); do

    TRACE="$(
        curl -fsS \
            --max-time 8 \
            --socks5-hostname "${WARP_ADDR}:${WARP_PORT}" \
            https://www.cloudflare.com/cdn-cgi/trace \
            2>/dev/null || true
    )"


    if echo "$TRACE" | grep -qE '^warp=(on|plus)$'; then
        WARP_OK=1
        break
    fi


    sleep 2

done


if [[ "$WARP_OK" != "1" ]]; then

    error "WARP SOCKS proxy test failed."

    echo
    echo "warp-cli status:"
    warp-cli --accept-tos status || true

    echo
    echo "Port check:"
    ss -lntp | grep ":${WARP_PORT}" || true

    exit 1
fi


info "WARP SOCKS is working."


# ============================================================
# Verify local listener
# ============================================================

if ss -lntp 2>/dev/null \
    | grep -qE "127\.0\.0\.1:${WARP_PORT}\b"; then

    info "Listener confirmed: ${WARP_ADDR}:${WARP_PORT}"

else

    warn "Could not confirm listener with ss."
    warn "SOCKS request worked, so continuing."

fi


# ============================================================
# Download original 3X-UI v2.8.11 default config
# ============================================================

TMP_DEFAULT="$(mktemp)"


cleanup() {
    rm -f "$TMP_DEFAULT"
}

trap cleanup EXIT


info "Loading original 3X-UI v2.8.11 Xray template..."


if ! curl -fsSL \
    "$DEFAULT_XRAY_CONFIG_URL" \
    -o "$TMP_DEFAULT"; then

    die "Could not download original 3X-UI v2.8.11 config.json."
fi


# ============================================================
# Database backup
# ============================================================

BACKUP="${XUI_DB}.warp-backup-$(date +%Y%m%d-%H%M%S)"


info "Creating 3X-UI database backup..."
info "Backup: $BACKUP"


# ============================================================
# Create / update WARP outbound
# ============================================================

info "Creating WARP outbound in 3X-UI..."


if ! XUI_DB="$XUI_DB" \
    BACKUP_DB="$BACKUP" \
    DEFAULT_JSON="$TMP_DEFAULT" \
    WARP_ADDR="$WARP_ADDR" \
    WARP_PORT="$WARP_PORT" \
    python3 <<'PY'
import json
import os
import sqlite3
import sys


DB_PATH = os.environ["XUI_DB"]
BACKUP_PATH = os.environ["BACKUP_DB"]
DEFAULT_JSON_PATH = os.environ["DEFAULT_JSON"]

WARP_ADDR = os.environ["WARP_ADDR"]
WARP_PORT = int(os.environ["WARP_PORT"])


WARP_OUTBOUND = {
    "tag": "warp",
    "protocol": "socks",
    "settings": {
        "servers": [
            {
                "address": WARP_ADDR,
                "port": WARP_PORT,
                "users": []
            }
        ]
    }
}


conn = sqlite3.connect(DB_PATH, timeout=30)


try:

    # --------------------------------------------------------
    # Check 3X-UI settings table
    # --------------------------------------------------------

    table = conn.execute(
        """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name = 'settings'
        """
    ).fetchone()


    if not table:
        raise RuntimeError(
            "settings table not found; this does not look like 3X-UI database"
        )


    # --------------------------------------------------------
    # SQLite-safe backup
    # --------------------------------------------------------

    backup_conn = sqlite3.connect(BACKUP_PATH)

    try:
        conn.backup(backup_conn)
    finally:
        backup_conn.close()


    # --------------------------------------------------------
    # Read current xrayTemplateConfig
    # --------------------------------------------------------

    row = conn.execute(
        """
        SELECT value
        FROM settings
        WHERE key = ?
        """,
        ("xrayTemplateConfig",)
    ).fetchone()


    if row and row[0] and row[0].strip():

        raw_config = row[0]
        config_source = "database"

    else:

        # Fresh original 3X-UI v2.8.11 may not yet have
        # xrayTemplateConfig stored in SQLite.
        #
        # In that case 3X-UI itself uses the embedded
        # web/service/config.json default.
        #
        # We use that exact original v2.8.11 config here.

        with open(
            DEFAULT_JSON_PATH,
            "r",
            encoding="utf-8"
        ) as f:
            raw_config = f.read()

        config_source = "original v2.8.11 default"


    # --------------------------------------------------------
    # Parse Xray configuration
    # --------------------------------------------------------

    try:
        config = json.loads(raw_config)

    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"xrayTemplateConfig contains invalid JSON: {exc}"
        )


    if not isinstance(config, dict):
        raise RuntimeError(
            "Xray configuration root is not an object"
        )


    # --------------------------------------------------------
    # Outbounds
    # --------------------------------------------------------

    outbounds = config.setdefault("outbounds", [])


    if not isinstance(outbounds, list):
        raise RuntimeError(
            "Xray outbounds field is not an array"
        )


    warp_indexes = []


    for index, outbound in enumerate(outbounds):

        if (
            isinstance(outbound, dict)
            and outbound.get("tag") == "warp"
        ):
            warp_indexes.append(index)


    if warp_indexes:

        # Replace first existing warp outbound
        first_index = warp_indexes[0]

        outbounds[first_index] = WARP_OUTBOUND


        # Remove accidental duplicates
        for index in reversed(warp_indexes[1:]):
            del outbounds[index]


        action = "updated"

    else:

        outbounds.append(WARP_OUTBOUND)

        action = "created"


    # --------------------------------------------------------
    # Serialize
    # --------------------------------------------------------

    new_config = json.dumps(
        config,
        ensure_ascii=False,
        separators=(",", ":")
    )


    # --------------------------------------------------------
    # Save
    # --------------------------------------------------------

    if row:

        conn.execute(
            """
            UPDATE settings
            SET value = ?
            WHERE key = ?
            """,
            (
                new_config,
                "xrayTemplateConfig"
            )
        )

    else:

        conn.execute(
            """
            INSERT INTO settings (
                key,
                value
            )
            VALUES (?, ?)
            """,
            (
                "xrayTemplateConfig",
                new_config
            )
        )


    conn.commit()


    print()
    print("[+] 3X-UI Xray configuration saved")
    print(f"[+] Config source: {config_source}")
    print(f"[+] WARP outbound: {action}")
    print()
    print("    tag:      warp")
    print("    protocol: socks")
    print(f"    address:  {WARP_ADDR}")
    print(f"    port:     {WARP_PORT}")
    print()


except Exception as exc:

    try:
        conn.rollback()
    except Exception:
        pass


    print(
        f"[ERROR] Failed to modify 3X-UI database: {exc}",
        file=sys.stderr
    )

    sys.exit(1)


finally:

    conn.close()

PY
then

    error "Failed to add WARP outbound."
    warn "3X-UI database was not modified successfully."

    exit 1

fi


# ============================================================
# Restart 3X-UI
# ============================================================

info "Restarting 3X-UI..."


systemctl daemon-reload >/dev/null 2>&1 || true


if ! systemctl restart x-ui; then

    error "Failed to restart x-ui."
    warn "Restoring database backup..."


    systemctl stop x-ui >/dev/null 2>&1 || true


    if cp -a "$BACKUP" "$XUI_DB"; then
        warn "Database restored from backup."
    else
        error "Could not restore database automatically."
    fi


    systemctl start x-ui >/dev/null 2>&1 || true


    exit 1
fi


sleep 3


if ! systemctl is-active --quiet x-ui; then

    error "x-ui is not running after restart."
    warn "Restoring database backup..."


    systemctl stop x-ui >/dev/null 2>&1 || true


    if cp -a "$BACKUP" "$XUI_DB"; then
        warn "Database restored from backup."
    else
        error "Could not restore database automatically."
    fi


    systemctl start x-ui >/dev/null 2>&1 || true


    exit 1
fi


info "3X-UI restarted successfully."


# ============================================================
# Verify saved outbound
# ============================================================

info "Verifying WARP outbound..."


if ! XUI_DB="$XUI_DB" python3 <<'PY'
import json
import os
import sqlite3
import sys


db = sqlite3.connect(
    os.environ["XUI_DB"],
    timeout=10
)


try:

    row = db.execute(
        """
        SELECT value
        FROM settings
        WHERE key = 'xrayTemplateConfig'
        """
    ).fetchone()


    if not row or not row[0]:
        raise RuntimeError(
            "xrayTemplateConfig is missing"
        )


    config = json.loads(row[0])


    warp = None


    for outbound in config.get("outbounds", []):

        if (
            isinstance(outbound, dict)
            and outbound.get("tag") == "warp"
        ):

            warp = outbound
            break


    if warp is None:
        raise RuntimeError(
            "warp outbound not found"
        )


    server = (
        warp
        .get("settings", {})
        .get("servers", [{}])[0]
    )


    if warp.get("protocol") != "socks":
        raise RuntimeError(
            "warp outbound protocol is not socks"
        )


    if server.get("address") != "127.0.0.1":
        raise RuntimeError(
            "warp outbound address is incorrect"
        )


    if server.get("port") != 40000:
        raise RuntimeError(
            "warp outbound port is incorrect"
        )


    print()
    print("[+] Saved outbound:")
    print(
        json.dumps(
            warp,
            indent=2,
            ensure_ascii=False
        )
    )
    print()


except Exception as exc:

    print(
        f"[ERROR] {exc}",
        file=sys.stderr
    )

    sys.exit(1)


finally:

    db.close()

PY
then

    error "Saved WARP outbound verification failed."

    exit 1

fi


# ============================================================
# Final WARP test
# ============================================================

TRACE="$(
    curl -fsS \
        --max-time 10 \
        --socks5-hostname "${WARP_ADDR}:${WARP_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace \
        2>/dev/null || true
)"


# ============================================================
# Result
# ============================================================

echo
echo "============================================================"
echo "               WARP INSTALLATION COMPLETE"
echo "============================================================"
echo


echo -e "${BLUE}WARP status:${PLAIN}"

warp-cli --accept-tos status || true


echo
echo -e "${BLUE}SOCKS listener:${PLAIN}"

ss -lntp | grep ":${WARP_PORT}" || true


echo
echo -e "${BLUE}Cloudflare trace:${PLAIN}"

echo "$TRACE" \
    | grep -E '^(ip|colo|warp)=' \
    || true


echo
echo -e "${GREEN}3X-UI outbound:${PLAIN}"
echo
echo "  tag:      warp"
echo "  protocol: socks"
echo "  address:  ${WARP_ADDR}"
echo "  port:     ${WARP_PORT}"


echo
echo -e "${BLUE}Database backup:${PLAIN}"
echo
echo "  ${BACKUP}"


echo
echo "Refresh the 3X-UI page."
echo
echo -e "${GREEN}Done.${PLAIN}"
echo
