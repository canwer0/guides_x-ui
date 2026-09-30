#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
# One-file Ubuntu/Debian installer. Requires an existing 3X-UI + Xray installation.
# Usage: bash install.sh [domain] [project-name]
die(){ printf '[cloud] ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ $# -le 2 ]] || die 'Usage: bash install.sh [domain] [project-name]'
DOMAIN="${1:-}"
if [[ -z $DOMAIN ]]; then read -rp 'Домен сайта (DNS должен указывать на сервер): ' DOMAIN; fi
DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN%.}"
[[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$ ]] || die 'Invalid domain.'
SITE_NAME="${2:-}"
if [[ -z $SITE_NAME ]]; then
    read -rp 'Название проекта (будет показано на сайте): ' SITE_NAME
    [[ -n $SITE_NAME ]] || die 'Введите название проекта.'
fi
XUI_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
DB="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
[[ -x $XUI_DIR/x-ui && -f $DB ]] || die '3X-UI is required; its login and settings will be preserved.'
packages=()
for cmd in python3 nginx openssl curl certbot ss; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        [[ $cmd == ss ]] && packages+=(iproute2) || packages+=("$cmd")
    fi
done
if [[ ! -f /etc/nginx/modules-enabled/50-mod-stream.conf ]]; then
    if ! nginx -V 2>&1 | grep -q -- '--with-stream '; then packages+=(libnginx-mod-stream); fi
fi
if ((${#packages[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${packages[@]}"
fi
for cmd in python3 nginx openssl curl certbot ss systemctl flock; do command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"; done
exec 9>/run/obsidian-cloud-install.lock
flock -n 9 || die 'Another cloud installation is running.'
CERT_EMAIL=''
if [[ ! -r /etc/letsencrypt/live/$DOMAIN/fullchain.pem || ! -r /etc/letsencrypt/live/$DOMAIN/privkey.pem ]]; then
    read -rp 'Email для сертификата Let’s Encrypt: ' CERT_EMAIL
    [[ $CERT_EMAIL == *@*.* ]] || die 'A certificate email is required.'
fi
WORK="$(mktemp -d /var/tmp/obsidian-cloud.XXXXXX)"
trap 'rm -rf --one-file-system -- "$WORK"' EXIT
python3 - "$WORK/options.json" "$DOMAIN" "$SITE_NAME" "$CERT_EMAIL" <<'OPTIONS'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'domain':sys.argv[2],'siteName':sys.argv[3],'certEmail':sys.argv[4]},ensure_ascii=False),encoding='utf-8')
OPTIONS
