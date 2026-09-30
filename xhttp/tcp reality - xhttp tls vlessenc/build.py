from pathlib import Path
import hashlib

root=Path(__file__).resolve().parent
src=root/'src'
deploy=(src/'deploy.py').read_text(encoding='utf-8')
site=(src/'site.html').read_text(encoding='utf-8')
bootstrap=(src/'bootstrap.sh').read_text(encoding='utf-8')
install=bootstrap+'\ncat > "$WORK/site.html" <<\'CLOUD_SITE_HTML\'\n'+site+'\nCLOUD_SITE_HTML\n\ncat > "$WORK/deploy.py" <<\'CLOUD_DEPLOY_PY\'\n'+deploy+'\nCLOUD_DEPLOY_PY\n\npython3 "$WORK/deploy.py" "$WORK/options.json" "$WORK"\n'
update_header="""#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ $# -le 1 ]] || { echo 'Usage: bash update-config.sh [domain]' >&2; exit 1; }
DOMAIN="${1:-}"
if [[ -z $DOMAIN ]]; then read -rp 'Домен существующего проекта: ' DOMAIN; fi
DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN%.}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$ ]] || { echo 'Invalid domain' >&2; exit 1; }
exec 9>/run/obsidian-cloud-install.lock
flock -n 9 || { echo 'Another cloud installation is running' >&2; exit 1; }
WORK="$(mktemp -d /var/tmp/cloud-config-update.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
"""
update=update_header+'\ncat > "$WORK/deploy.py" <<\'CLOUD_DEPLOY_PY\'\n'+deploy+'\nCLOUD_DEPLOY_PY\n'
update+='\ncat > "$WORK/update.py" <<\'CLOUD_UPDATE_PY\'\n'+(src/'update-config.py').read_text(encoding='utf-8')+'\nCLOUD_UPDATE_PY\n'
update+='\npython3 "$WORK/update.py" "$DOMAIN" "$WORK"\n'
for name,data in [('install.sh',install),('update-config.sh',update),('preview.html',site.replace('__SITE_NAME__','VaultSpace'))]:
    (root/name).write_text(data,encoding='utf-8',newline='\n')
    if name.endswith('.sh'):(root/name).chmod(0o755)
paths=[p for p in root.rglob('*') if p.is_file() and p.name!='SHA256SUMS' and '__pycache__' not in p.parts and '.git' not in p.parts]
(root/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(root).as_posix()+'\n' for p in sorted(paths)),encoding='utf-8',newline='\n')
print('Built install.sh, update-config.sh, preview.html and SHA256SUMS')
