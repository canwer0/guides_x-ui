#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Historical filename retained for bootstrap compatibility. This installer
# creates ONLY VLESS/XHTTP stream-one with TLS at Nginx: no VLESSENC or REALITY.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="$SCRIPT_DIR/assets"
XUI_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
DB="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
XRAY_CONFIG="$XUI_DIR/bin/config.json"
MARKER="$XUI_DIR/.patch-xhttp-2811"
RESULT_ROOT="/root/xhttp-stream-one-tls"
BACKUP_ROOT="/root/xhttp-stream-one-tls-backups"

log(){ printf '[stream-one-tls] %s\n' "$*"; }
die(){ printf '[stream-one-tls] ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
nginx_apply(){ nginx -t && { systemctl reload nginx || systemctl start nginx; }; }
[[ $EUID -eq 0 ]] || die 'Run as root.'

packages=()
for item in python3 openssl nginx curl; do command -v "$item" >/dev/null 2>&1 || packages+=("$item"); done
command -v ss >/dev/null 2>&1 || packages+=(iproute2)
if ((${#packages[@]})); then
  need apt-get
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${packages[@]}"
fi
for item in python3 openssl nginx curl ss sha256sum systemctl; do need "$item"; done
[[ -x "$XUI_DIR/x-ui" && -f "$DB" && -f "$XRAY_CONFIG" ]] || die '3X-UI is not installed in the expected location.'
XRAY="$(find "$XUI_DIR/bin" -maxdepth 1 -type f -name 'xray-linux-*' -perm -111 -print -quit)"
[[ -n "$XRAY" ]] || die 'Xray binary not found.'
systemctl is-active --quiet x-ui || die '3X-UI service is not running.'

# The patched 2.8.11 panel exposes the required XHTTP options and External Proxy.
patch_id="$(sed -n 's/^patch_id=//p' "$MARKER" 2>/dev/null | head -n1)"
case "$patch_id" in
  xhttp-vlessenc-vision-2811-v4|xhttp-vlessenc-vision-outbound-2811-v5) ;;
  *) die "Unsupported 3X-UI patch: $patch_id" ;;
esac
marker_sha="$(sed -n 's/^binary_sha256=//p' "$MARKER" | head -n1)"
[[ "$marker_sha" =~ ^[[:xdigit:]]{64}$ ]] || die 'Invalid panel patch marker.'
[[ "$(sha256sum "$XUI_DIR/x-ui" | awk '{print $1}')" == "$marker_sha" ]] || die 'Panel binary does not match the patch marker.'

read -rp 'Site domain (DNS A record must point to this server): ' DOMAIN
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[.]$//')"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$ ]] || die 'Invalid domain.'
read -rsp '3X-UI password: ' XUI_PASS; printf '\n'
[[ -n "$XUI_PASS" ]] || die 'Panel password is required.'

readarray -t panel_info < <(python3 - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); settings=dict(c.execute('select key,value from settings'))
u=c.execute('select username from users order by id limit 1').fetchone()
if not u or not u[0]: raise SystemExit('3X-UI username not found')
port=(settings.get('webPort') or '2053').strip()
base=(settings.get('webBasePath') or '/').strip()
if not base.startswith('/'): base='/'+base
scheme='https' if settings.get('webCertFile') and settings.get('webKeyFile') else 'http'
print(f'{scheme}://127.0.0.1:{port}{base.rstrip("/")}')
print(u[0])
PY
)
BASE="${panel_info[0]}"
XUI_USER="${panel_info[1]}"
DEPLOY="$(openssl rand -hex 6)"
XHTTP_PATH="/x-$(openssl rand -hex 18)/"
RESULT="$RESULT_ROOT-$DEPLOY"
BACKUP="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$DEPLOY"
SITE="/var/www/stream-one-$DEPLOY"
LOCATION_DIR=/etc/nginx/stream-one-locations
LOCATION_CONF="$LOCATION_DIR/$DEPLOY.conf"
LOCATION_INCLUDE="include $LOCATION_CONF;"
VHOST=""
NEW_SITE=0
INBOUND_ID=""
COMMITTED=0
WORK="$(mktemp -d -t stream-one-tls.XXXXXX)"
mkdir -m 700 -p "$RESULT" "$BACKUP"

cleanup(){
  local rc=$?
  if ((rc != 0 && COMMITTED == 0)); then
    if [[ -n "$INBOUND_ID" ]]; then
      python3 "$WORK/panel.py" del "$BASE" "$INBOUND_ID" "$WORK/auth" >/dev/null 2>&1 || true
      python3 "$WORK/panel.py" restart "$BASE" "$WORK/auth" >/dev/null 2>&1 || true
    fi
    rm -f -- "$LOCATION_CONF"
    if [[ -n "$VHOST" && -f "$VHOST" ]]; then
      python3 "$WORK/vhost.py" remove "$VHOST" "$LOCATION_INCLUDE" >/dev/null 2>&1 || true
      if ((NEW_SITE)); then rm -f -- "$VHOST"; fi
    fi
    if ((NEW_SITE)) && [[ -d "$SITE" ]]; then rm -rf --one-file-system -- "$SITE"; fi
    nginx_apply >/dev/null 2>&1 || true
    rm -rf --one-file-system -- "$RESULT"
  fi
  rm -rf --one-file-system -- "$WORK"
  unset XUI_PASS
}
trap cleanup EXIT
printf '%s\n%s\n' "$XUI_USER" "$XUI_PASS" > "$WORK/auth"
chmod 600 "$WORK/auth"

cat > "$WORK/panel.py" <<'PY'
import http.cookiejar,json,ssl,sys,urllib.parse,urllib.request
action,base=sys.argv[1],sys.argv[2].rstrip('/')
user,password=open(sys.argv[-1]).read().splitlines()[:2]
jar=http.cookiejar.CookieJar()
op=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),urllib.request.HTTPCookieProcessor(jar))
def call(path,data=None):
    body=None if data is None else urllib.parse.urlencode(data).encode()
    with op.open(urllib.request.Request(base+path,data=body),timeout=30) as r: result=json.load(r)
    if not result.get('success'): raise SystemExit(result.get('msg') or repr(result))
    return result.get('obj')
call('/login',{'username':user,'password':password})
if action=='add':
    payload=json.load(open(sys.argv[3]))
    call('/panel/api/inbounds/add',payload)
    found=[i for i in (call('/panel/api/inbounds/list') or []) if int(i.get('port',-1))==int(payload['port'])]
    if len(found)!=1: raise SystemExit('Could not verify the new inbound')
    print(found[0]['id'])
elif action=='del': call('/panel/api/inbounds/del/'+sys.argv[3],{})
elif action=='restart': call('/panel/api/server/restartXrayService',{})
else: raise SystemExit('Unknown action')
PY

cat > "$WORK/vhost.py" <<'PY'
import os,re,stat,subprocess,sys,tempfile
from pathlib import Path
def blocks(text):
    # Mask strings/comments while preserving offsets, then match complete blocks.
    masked=list(text); quote=None; comment=False; escape=False
    for i,c in enumerate(text):
        if comment:
            if c=='\n': comment=False
            else: masked[i]=' '
        elif quote:
            masked[i]=' '
            if escape: escape=False
            elif c=='\\': escape=True
            elif c==quote: quote=None
        elif c in ('"',"'"): quote=c; masked[i]=' '
        elif c=='#': comment=True; masked[i]=' '
    masked=''.join(masked)
    for m in re.finditer(r'\bserver\s*\{',masked):
        depth=0
        for end in range(masked.find('{',m.start()),len(masked)):
            if masked[end]=='{': depth+=1
            elif masked[end]=='}':
                depth-=1
                if depth==0:
                    yield m.start(),end,masked[m.start():end+1]
                    break
def targets(path,domain):
    text=Path(path).read_text(errors='replace')
    for start,end,block in blocks(text):
        names=re.findall(r'(?m)^\s*server_name\s+([^;]+);',block)
        listens=re.findall(r'(?m)^\s*listen\s+([^;]+);',block)
        name_ok=any(domain in item.split() for item in names)
        tls_ok=any('ssl' in item.split()[1:] and item.split()[0].rsplit(':',1)[-1] in ('443','9443') for item in listens if item.split())
        if name_ok and tls_ok: yield start,end,block
def write(path,text):
    p=Path(path); s=p.stat(); fd,tmp=tempfile.mkstemp(dir=p.parent,prefix=p.name+'.')
    try:
        with os.fdopen(fd,'w') as f: f.write(text); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp,stat.S_IMODE(s.st_mode)); os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
action=sys.argv[1]
if action=='find':
    domain=sys.argv[2]
    dump=subprocess.run(['nginx','-T'],capture_output=True,text=True)
    if dump.returncode: raise SystemExit('nginx -T failed')
    files=dict.fromkeys(re.findall(r'^# configuration file (.+):\s*$',dump.stdout,re.M))
    matches=[str(Path(p).resolve()) for p in files if Path(p).is_file() for _ in targets(p,domain)]
    if len(matches)>1: raise SystemExit('Ambiguous HTTPS vhost for '+domain)
    print(matches[0] if matches else '__NONE__')
elif action=='claimed':
    domain=sys.argv[2]
    dump=subprocess.run(['nginx','-T'],capture_output=True,text=True)
    if dump.returncode: raise SystemExit('nginx -T failed')
    files=dict.fromkeys(re.findall(r'^# configuration file (.+):\s*$',dump.stdout,re.M))
    found=any(domain in name.split() for p in files if Path(p).is_file() for _,_,block in blocks(Path(p).read_text(errors='replace')) for name in re.findall(r'(?m)^\s*server_name\s+([^;]+);',block))
    print('yes' if found else 'no')
elif action=='dir':
    text=Path('/etc/nginx/nginx.conf').read_text()
    for candidate in ('/etc/nginx/conf.d','/etc/nginx/sites-enabled'):
        if Path(candidate).is_dir() and candidate+'/' in text: print(candidate);break
    else: raise SystemExit('No supported Nginx vhost directory')
elif action=='http2':
    path,domain=sys.argv[2:]; found=list(targets(path,domain))
    if len(found)!=1: raise SystemExit('HTTPS vhost is missing or ambiguous')
    block=found[0][2]
    listens=re.findall(r'(?m)^\s*listen\s+([^;]+);',block)
    if not any('ssl' in v.split()[1:] and 'http2' in v.split()[1:] for v in listens) and not re.search(r'(?m)^\s*http2\s+on\s*;',block):
        raise SystemExit('HTTPS vhost must support HTTP/2')
elif action=='add':
    path,domain,include=sys.argv[2:]; text=Path(path).read_text(); found=list(targets(path,domain))
    if len(found)!=1 or include in text: raise SystemExit('Cannot safely add the XHTTP route')
    end=found[0][1]; write(path,text[:end]+'\n    '+include+'\n'+text[end:])
elif action=='remove':
    path,include=sys.argv[2:]; text=Path(path).read_text()
    write(path,''.join(line for line in text.splitlines(keepends=True) if line.strip()!=include))
else: raise SystemExit('Unknown action')
PY

VHOST="$(python3 "$WORK/vhost.py" find "$DOMAIN")" || die 'Could not inspect the existing site.'
if [[ "$VHOST" == '__NONE__' ]]; then
  [[ "$(python3 "$WORK/vhost.py" claimed "$DOMAIN")" == no ]] || die 'Domain has a non-HTTPS vhost; refusing to overwrite it.'
  for edge in 80 443; do
    listeners="$(ss -H -ltnp "sport = :$edge")"
    [[ -z "$listeners" || "$listeners" == *'users:(("nginx"'* ]] || die "Port $edge is owned by another service."
  done
  # An existing TCP stream frontend on 443 cannot be used for a brand-new site.
  nginx -T 2>/dev/null | grep -Eq '^\s*stream\s*\{' &&
    nginx -T 2>/dev/null | grep -Eq '^\s*proxy_pass\s+127\.0\.0\.1:[0-9]+;' &&
    die 'Public 443 uses an existing TCP frontend; create the HTTPS site there first.'
  NEW_SITE=1
  VHOST_DIR="$(python3 "$WORK/vhost.py" dir)" || die 'No Nginx vhost directory.'
  VHOST="$VHOST_DIR/stream-one-$DEPLOY.conf"
  [[ ! -e "$VHOST" && ! -e "$SITE" ]] || die 'Generated file path is already occupied.'
  for image in poster-orbit.webp poster-noir.webp poster-summit.webp poster-afterglow.webp; do
    [[ -r "$ASSET_DIR/$image" ]] || die "Missing artwork: $image"
  done
  read -rp 'New site title [Film collection]: ' SITE_NAME
  SITE_NAME="${SITE_NAME:-Film collection}"
  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  mkdir -p "$SITE/posters"
  # Nginx runs as an unprivileged user; umask 077 must not hide the webroot.
  chmod 755 "$SITE" "$SITE/posters"
  for image in poster-orbit.webp poster-noir.webp poster-summit.webp poster-afterglow.webp; do cp "$ASSET_DIR/$image" "$SITE/posters/$image"; done
  chmod 644 "$SITE/posters/"*.webp
  python3 - "$SITE/index.html" "$SITE_NAME" <<'PY'
import html,sys
title=html.escape(sys.argv[2])
page='''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>__TITLE__</title><style>
:root{font-family:system-ui,sans-serif;color:#f6f3ee;background:#101114}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 75% 0,#30251f,#101114 45%)}header{padding:22px 5vw;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #ffffff20}.brand{font-size:22px;font-weight:900;letter-spacing:.08em;color:#f1a65b}button{cursor:pointer;border:0;border-radius:99px;background:#f1a65b;color:#171310;padding:11px 20px;font-weight:700}main{max-width:1200px;margin:auto;padding:30px 22px}.hero{min-height:370px;border-radius:22px;padding:35px;display:flex;align-items:end;background:linear-gradient(90deg,#111e,transparent),url('/posters/poster-orbit.webp') center/cover}.hero h1{font-size:clamp(38px,7vw,68px);margin:0}.hero p{max-width:500px;line-height:1.6}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:18px;margin:25px 0 60px}.card img{width:100%;aspect-ratio:2/3;object-fit:cover;border-radius:15px}.card h3{margin:10px 0 2px}.card p{color:#aaa;margin:0}.modal{position:fixed;inset:0;background:#000c;display:none;place-items:center;padding:20px}.modal.open{display:grid}.dialog{background:#202126;border:1px solid #ffffff25;border-radius:20px;padding:32px;width:min(430px,100%)}.dialog input{width:100%;padding:13px;background:#111;color:white;border:1px solid #777;border-radius:8px;margin:12px 0}.dialog p{color:#bbb}.hidden{display:none}@media(max-width:700px){.grid{grid-template-columns:repeat(2,1fr)}}
</style></head><body><header><div class="brand">__TITLE__</div><button onclick="showLogin()">Sign in</button></header><main><section class="hero"><div><h1>Beyond the Horizon</h1><p>Discover a hand-picked world of films and stories for tonight.</p><button onclick="showLogin()">Explore films</button></div></section><h2>Featured films</h2><div class="grid">
<article class="card"><img src="/posters/poster-orbit.webp" alt="Beyond the Horizon poster"><h3>Beyond the Horizon</h3><p>Sci-fi · 2026</p></article><article class="card"><img src="/posters/poster-noir.webp" alt="Midnight Signal poster"><h3>Midnight Signal</h3><p>Thriller · 2025</p></article><article class="card"><img src="/posters/poster-summit.webp" alt="The Long Road poster"><h3>The Long Road</h3><p>Adventure · 2026</p></article><article class="card"><img src="/posters/poster-afterglow.webp" alt="After the Last Light poster"><h3>After the Last Light</h3><p>Drama · 2025</p></article></div></main>
<div class="modal" id="modal"><div class="dialog"><button onclick="closeLogin()" aria-label="Close">×</button><h2>Sign in</h2><form id="emailForm"><p>Enter your email to continue.</p><input type="email" placeholder="you@example.com" required><button type="submit">Continue</button></form><form id="codeForm" class="hidden"><p>Enter the code from your email.</p><input inputmode="numeric" pattern="[0-9]{6}" maxlength="6" placeholder="6-digit code" required><button type="submit">Continue</button><p>Demo only: no email or code is sent.</p></form><p id="notice"></p></div></div><script>
function showLogin(){document.getElementById('modal').classList.add('open')}function closeLogin(){document.getElementById('modal').classList.remove('open')}document.getElementById('emailForm').onsubmit=e=>{e.preventDefault();document.getElementById('emailForm').classList.add('hidden');document.getElementById('codeForm').classList.remove('hidden');document.getElementById('notice').textContent='A code would normally arrive by email; this demo does not send one.'};document.getElementById('codeForm').onsubmit=e=>{e.preventDefault();document.getElementById('notice').textContent='Demo only — no code was checked.'};
</script></body></html>'''
open(sys.argv[1],'w').write(page.replace('__TITLE__',title))
PY
  chmod 644 "$SITE/index.html"
  if [[ ! -r "$CERT" || ! -r "$KEY" ]]; then
    [[ ! -e "$CERT" && ! -e "$KEY" ]] || die 'A partial certificate already exists.'
    command -v certbot >/dev/null 2>&1 || { need apt-get; apt-get update; apt-get install -y --no-install-recommends certbot; }
    read -rp 'Email for the HTTPS certificate: ' CERT_EMAIL
    [[ -n "$CERT_EMAIL" ]] || die 'Certificate email is required.'
    cat > "$VHOST" <<EOF
server { listen 80; server_name $DOMAIN; root $SITE; location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; } location / { try_files \$uri \$uri/ =404; } }
EOF
    nginx_apply || die 'Nginx rejected the temporary certificate vhost.'
    mkdir -p "$SITE/.well-known/acme-challenge"
    chmod 755 "$SITE/.well-known" "$SITE/.well-known/acme-challenge"
    probe="acme-probe-$(openssl rand -hex 8)"
    printf '%s\n' "$probe" > "$SITE/.well-known/acme-challenge/$probe"
    chmod 644 "$SITE/.well-known/acme-challenge/$probe"
    curl --noproxy '*' -fsS --resolve "$DOMAIN:80:127.0.0.1" \
      "http://$DOMAIN/.well-known/acme-challenge/$probe" | grep -Fxq "$probe" \
      || die 'Nginx cannot serve ACME challenge files from the new site.'
    rm -f -- "$SITE/.well-known/acme-challenge/$probe"
    (umask 022; certbot certonly --webroot --webroot-path "$SITE" --non-interactive --agree-tos -m "$CERT_EMAIL" -d "$DOMAIN")
    [[ -r "$CERT" && -r "$KEY" ]] || die 'Certificate issuance failed.'
  fi
  openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || die 'Certificate does not cover the site domain.'
  openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1 || die 'Certificate is expired.'
  cat > "$VHOST" <<EOF
server { listen 80; server_name $DOMAIN; root $SITE; location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; } location / { return 301 https://\$host\$request_uri; } }
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root $SITE;
    index index.html;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  log "Created a new HTTPS catalog at https://$DOMAIN/"
else
  log "Using the existing HTTPS site for $DOMAIN; its files are preserved."
fi

python3 "$WORK/vhost.py" http2 "$VHOST" "$DOMAIN" || die 'The site must offer HTTP/2.'
cp -a "$XRAY_CONFIG" "$BACKUP/config.json"
cp -a /etc/nginx/nginx.conf "$BACKUP/nginx.conf"
[[ ! -f "$VHOST" ]] || cp -a "$VHOST" "$BACKUP/site-vhost.conf"
python3 - "$DB" "$BACKUP/x-ui.db" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as source,sqlite3.connect(sys.argv[2]) as backup: source.backup(backup)
PY

port=''
for _ in $(seq 1 200); do
  candidate=$((22000 + RANDOM % 20000))
  if [[ -z "$(ss -H -ltn "sport = :$candidate")" ]]; then port="$candidate"; break; fi
done
[[ -n "$port" ]] || die 'No unused local port found.'
UUID="$(cat /proc/sys/kernel/random/uuid)"
mkdir -p "$LOCATION_DIR"
cat > "$LOCATION_CONF" <<EOF
location ^~ $XHTTP_PATH {
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
    client_body_timeout 1h;
    client_max_body_size 0;
    grpc_set_header Host \$host;
    grpc_set_header X-Real-IP \$remote_addr;
    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    grpc_pass grpc://127.0.0.1:$port;
}
EOF
python3 "$WORK/vhost.py" add "$VHOST" "$DOMAIN" "$LOCATION_INCLUDE" || die 'Could not safely add the XHTTP location.'
nginx -t || die 'Nginx rejected the new route.'

python3 - "$WORK/inbound.json" "$port" "$UUID" "$DOMAIN" "$XHTTP_PATH" <<'PY'
import json,sys
out,port,uuid,domain,path=sys.argv[1:]
x={'path':path,'host':domain,'mode':'stream-one','xPaddingBytes':'128-1120','xPaddingObfsMode':True,'xPaddingKey':'X-Amz-Meta-Trace','xPaddingHeader':'X-Amz-Security-Token','xPaddingPlacement':'header','xPaddingMethod':'tokenish','sessionIDPlacement':'header','sessionIDKey':'x-amz-cf-id','sessionIDTable':'Base62','sessionIDLength':'16-32','seqPlacement':'header','seqKey':'x-amz-cf-pop','uplinkHTTPMethod':'POST'}
bot='bot:'+json.dumps({'path':path,'host':domain},separators=(',',':'))
stream={'network':'xhttp','security':'none','xhttpSettings':x,'externalProxy':[{'forceTls':'tls','dest':domain,'port':443,'remark':bot}]}
settings={'clients':[{'id':uuid,'flow':'','email':'tls-'+domain+'-'+uuid[:8]}],'decryption':'none','encryption':'none'}
payload={'up':0,'down':0,'total':0,'allTime':0,'remark':'stream-one tls '+domain,'enable':True,'expiryTime':0,'listen':'127.0.0.1','port':int(port),'protocol':'vless','settings':json.dumps(settings,separators=(',',':')),'streamSettings':json.dumps(stream,separators=(',',':')),'tag':'in-stream-one-tls-'+uuid[:8],'sniffing':json.dumps({'enabled':True,'destOverride':['http','tls','quic'],'routeOnly':True},separators=(',',':'))}
json.dump(payload,open(out,'w'))
PY
python3 - "$WORK/inbound.json" "$WORK/xray-test.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); s=json.loads(p['settings']); t=json.loads(p['streamSettings']);t.pop('externalProxy',None)
json.dump({'log':{'loglevel':'warning'},'inbounds':[{'listen':p['listen'],'port':p['port'],'protocol':'vless','settings':s,'streamSettings':t}],'outbounds':[{'protocol':'freedom','tag':'direct'}]},open(sys.argv[2],'w'))
PY
"$XRAY" run -test -config "$WORK/xray-test.json" || die 'Xray rejected the inbound.'
nginx_apply || die 'Nginx could not reload.'
INBOUND_ID="$(python3 "$WORK/panel.py" add "$BASE" "$WORK/inbound.json" "$WORK/auth")"
[[ "$INBOUND_ID" =~ ^[0-9]+$ ]] || die 'Panel returned an invalid inbound ID.'
python3 "$WORK/panel.py" restart "$BASE" "$WORK/auth"
for _ in $(seq 1 60); do
  ss -H -ltn "sport = :$port" | grep -q "127.0.0.1:$port" && break
  sleep .5
done
ss -H -ltn "sport = :$port" | grep -q "127.0.0.1:$port" || die 'Xray did not listen on the new port.'
"$XRAY" run -test -config "$XRAY_CONFIG" >/dev/null || die 'Generated panel configuration failed validation.'

python3 - "$RESULT" "$DOMAIN" "$XHTTP_PATH" "$UUID" "$port" "$INBOUND_ID" "$NEW_SITE" <<'PY'
import json,pathlib,sys,urllib.parse
result=pathlib.Path(sys.argv[1]);domain,path,uuid,port,inbound_id,new_site=sys.argv[2:]
extra={'mode':'stream-one','xPaddingBytes':'128-1120','xPaddingObfsMode':True,'xPaddingKey':'X-Amz-Meta-Trace','xPaddingHeader':'X-Amz-Security-Token','xPaddingPlacement':'header','xPaddingMethod':'tokenish','uplinkHTTPMethod':'POST','sessionIDPlacement':'header','sessionIDKey':'x-amz-cf-id','sessionIDTable':'Base62','sessionIDLength':'16-32','seqPlacement':'header','seqKey':'x-amz-cf-pop'}
q={'type':'xhttp','encryption':'none','path':path,'host':domain,'mode':'stream-one','extra':json.dumps(extra,separators=(',',':')),'security':'tls','sni':domain,'fp':'chrome','alpn':'h2'}
link=f'vless://{uuid}@{domain}:443?'+urllib.parse.urlencode(q,quote_via=urllib.parse.quote)+'#'+urllib.parse.quote('stream-one tls '+domain)
(result/'vless-tls.txt').write_text(link+'\n')
(result/'deployment.json').write_text(json.dumps({'domain':domain,'siteMode':'new' if new_site=='1' else 'existing','inboundId':int(inbound_id),'internalPort':int(port),'publicPort':443,'path':path,'externalProxyRemark':'bot:'+json.dumps({'path':path,'host':domain},separators=(',',':'))},indent=2))
PY
cp "$WORK/panel.py" "$RESULT/panel.py"
cp "$WORK/vhost.py" "$RESULT/vhost.py"
cat > "$RESULT/remove.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
read -rp '3X-UI username: ' user
read -rsp '3X-UI password: ' password; printf '\n'
auth="\$(mktemp -t stream-one-remove.XXXXXX)"
trap 'rm -f -- "\$auth"' EXIT
printf '%s\n%s\n' "\$user" "\$password" > "\$auth"
python3 '$RESULT/panel.py' del '$BASE' '$INBOUND_ID' "\$auth"
python3 '$RESULT/panel.py' restart '$BASE' "\$auth"
rm -f -- '$LOCATION_CONF'
python3 '$RESULT/vhost.py' remove '$VHOST' '$LOCATION_INCLUDE'
EOF
if ((NEW_SITE)); then
  cat >> "$RESULT/remove.sh" <<EOF
rm -f -- '$VHOST'
rm -rf --one-file-system -- '$SITE'
EOF
fi
cat >> "$RESULT/remove.sh" <<'EOF'
nginx -t && { systemctl reload nginx || systemctl start nginx; }
echo 'Only this deployment was removed; other sites and inbounds were preserved.'
EOF
chmod 700 "$RESULT/remove.sh" "$RESULT/panel.py" "$RESULT/vhost.py"
chmod 600 "$RESULT/vless-tls.txt" "$RESULT/deployment.json"
COMMITTED=1
log "Installed TLS-only XHTTP stream-one inbound (panel ID $INBOUND_ID)."
log "Site: https://$DOMAIN/; client link: $RESULT/vless-tls.txt"
log "External Proxy remark: bot:{\"path\":\"$XHTTP_PATH\",\"host\":\"$DOMAIN\"}"
log "Backup: $BACKUP; remover: $RESULT/remove.sh"
