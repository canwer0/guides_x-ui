#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="$SCRIPT_DIR/assets"

# VLESS + XHTTP stream-one + VLESS Encryption + Vision behind nginx.
# Modes:
#   tls     nginx terminates HTTPS and proxies h2c to loopback Xray.
#   reality nginx stream routes by SNI to a loopback Xray REALITY inbound.
#   both    both inbounds share :443 via nginx stream/SNI; site TLS and REALITY
#           use distinct SNI names.

XUI_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
DB="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
PANEL="$XUI_DIR/x-ui"
XRAY_CONFIG="$XUI_DIR/bin/config.json"
MARKER="$XUI_DIR/.patch-xhttp-2811"
NGINX_CONF="/etc/nginx/nginx.conf"
RESULT_ROOT="/root/xhttp-stream-one"
BACKUP_ROOT="/root/xhttp-stream-one-backups"

log(){ printf '[stream-one] %s\n' "$*"; }
die(){ printf '[stream-one] ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
[[ $EUID -eq 0 ]] || die "Run as root."
for poster in poster-orbit.webp poster-noir.webp poster-summit.webp poster-afterglow.webp; do
  [[ -f "$ASSET_DIR/$poster" ]] || die "Bundled cover art missing: $ASSET_DIR/$poster (extract the full package, not only the .sh file)."
done
PACKAGES=()
command -v python3 >/dev/null 2>&1 || PACKAGES+=(python3)
command -v openssl >/dev/null 2>&1 || PACKAGES+=(openssl)
command -v nginx >/dev/null 2>&1 || PACKAGES+=(nginx)
command -v ip >/dev/null 2>&1 || PACKAGES+=(iproute2)
command -v curl >/dev/null 2>&1 || PACKAGES+=(curl)
command -v certbot >/dev/null 2>&1 || PACKAGES+=(certbot)
if ((${#PACKAGES[@]})); then
  command -v apt-get >/dev/null 2>&1 || die "Missing packages ${PACKAGES[*]}; automatic installation requires apt-get."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${PACKAGES[@]}"
fi
for c in python3 openssl nginx systemctl ss curl certbot sha256sum awk sed grep; do need "$c"; done
[[ -x "$PANEL" && -f "$DB" && -f "$XRAY_CONFIG" ]] || die "3x-ui/Xray files were not found under $XUI_DIR."
XRAY="$(find "$XUI_DIR/bin" -maxdepth 1 -type f -name 'xray-linux-*' -perm -111 -print -quit)"
[[ -n "$XRAY" ]] || die "Xray binary not found."

# Accept only the known v4 and v5 panel builds, and always validate their hash.
PATCH_ID="$(sed -n 's/^patch_id=//p' "$MARKER" 2>/dev/null | head -n1)"
case "$PATCH_ID" in
  xhttp-vlessenc-vision-2811-v4|xhttp-vlessenc-vision-outbound-2811-v5) ;;
  *) die "Unsupported patch marker '$PATCH_ID'. Install the XHTTP VLESSENC patch first." ;;
esac
MARKER_SHA="$(sed -n 's/^binary_sha256=//p' "$MARKER" | head -n1)"
[[ "$MARKER_SHA" =~ ^[[:xdigit:]]{64}$ ]] || die "Invalid panel checksum in marker."
[[ "$(sha256sum "$PANEL" | awk '{print $1}')" == "$MARKER_SHA" ]] || die "Panel checksum does not match its patch marker."
systemctl is-active --quiet x-ui || die "x-ui is not active."

XRAY_VERSION="$("$XRAY" version | head -n1)"
log "Using $XRAY_VERSION; panel patch $PATCH_ID"
VLESSENC_RAW="$("$XRAY" vlessenc 2>&1)" || die "Installed Xray has no working vlessenc generator."
readarray -t PAIR < <(printf '%s\n' "$VLESSENC_RAW" | python3 -c '
import re,sys
lines=sys.stdin.read().splitlines(); blocks=[]; b=None
for line in lines:
 m=re.search(r"Authentication:\s*(.+)",line)
 if m:
  if b: blocks.append(b)
  b={"label":m.group(1).strip(),"decryption":"","encryption":""}; continue
 if b:
  for k in ("decryption","encryption"):
   m=re.search(r"[\x22\x27]"+k+r"[\x22\x27]\s*:\s*[\x22\x27]([^\x22\x27]+)",line)
   if m:b[k]=m.group(1)
if b:blocks.append(b)
c=next((x for x in blocks if "ml-kem-768" in x["label"].lower() and "not post-quantum" not in x["label"].lower()),None)
if not c or not c["decryption"] or not c["encryption"]:sys.exit(2)
print(c["decryption"]);print(c["encryption"])
') || die "Could not get ML-KEM-768 VLESSENC parameters."
(("${#PAIR[@]}" == 2)) || die "Invalid VLESSENC output."
VLESS_DEC="${PAIR[0]}"; VLESS_ENC="${PAIR[1]}"

echo "Choose mode: tls / reality / both"
read -rp '> ' MODE
[[ "$MODE" == tls || "$MODE" == reality || "$MODE" == both ]] || die "Mode must be tls, reality, or both."
read -rp 'Origin/site domain (DNS A record must point here): ' DOMAIN
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[.]$//')"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$ ]] || die "Invalid domain."
REALITY_SNI=""
REALITY_TARGET=""
if [[ "$MODE" == reality || "$MODE" == both ]]; then
  REALITY_SNI="$DOMAIN"
  REALITY_TARGET="127.0.0.1:9443"
fi
read -rp 'Site title: ' SITE_NAME
[[ -n "$SITE_NAME" && ${#SITE_NAME} -le 80 ]] || die "Site title is required (max 80 chars)."
read -rsp '3x-ui password: ' XUI_PASS; printf '\n'
[[ -n "$XUI_PASS" ]] || die "Panel password is required."

BASE="$(python3 - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]);s=dict(c.execute("select key,value from settings"))
p=(s.get("webPort") or "2053").strip(); b=(s.get("webBasePath") or "/").strip()
if not b.startswith("/"):b="/"+b
b=b.rstrip("/")
print(("https" if s.get("webCertFile") and s.get("webKeyFile") else "http")+f"://127.0.0.1:{p}{b}")
PY
)"
XUI_USER="$(python3 - "$DB" <<'PY'
import sqlite3,sys
r=sqlite3.connect(sys.argv[1]).execute("select username from users order by id limit 1").fetchone()
if not r or not r[0]:sys.exit("3x-ui user not found")
print(r[0])
PY
)"
DEPLOY="$(openssl rand -hex 6)"
PATH_XHTTP="/x-$(openssl rand -hex 18)/"
ASSET_ROUTE="/catalog-$(openssl rand -hex 12)"
ORBIT_FILE="$(openssl rand -hex 8).webp"
NOIR_FILE="$(openssl rand -hex 8).webp"
SUMMIT_FILE="$(openssl rand -hex 8).webp"
AFTERGLOW_FILE="$(openssl rand -hex 8).webp"
SITE="/var/www/movie-$DEPLOY"
RESULT="$RESULT_ROOT-$DEPLOY"
BACKUP="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$DEPLOY"
VHOST="/etc/nginx/conf.d/stream-one-$DEPLOY.conf"
STREAM_CONF="/etc/nginx/streams-enabled/stream-one-$DEPLOY.conf"
HELPER="/tmp/xui-api-$DEPLOY.py"
AUTH="/tmp/xui-auth-$DEPLOY"
PAYLOAD_DIR="/tmp/xui-payload-$DEPLOY"
CREATED_IDS=()
COMMITTED=0
mkdir -m 700 -p "$BACKUP" "$RESULT" "$SITE" "$PAYLOAD_DIR"
cleanup(){
  rc=$?
  if (( rc != 0 && COMMITTED == 0 )); then
    for id in "${CREATED_IDS[@]:-}"; do
      [[ -n "$id" && -f "$HELPER" && -f "$AUTH" ]] && python3 "$HELPER" del "$BASE" "$id" "$AUTH" >/dev/null 2>&1 || true
    done
    if (("${#CREATED_IDS[@]}" > 0)) && [[ -f "$HELPER" && -f "$AUTH" ]]; then
      python3 "$HELPER" restart "$BASE" "$AUTH" >/dev/null 2>&1 || true
    fi
    rm -f "$VHOST" "$STREAM_CONF"
    [[ -f "$BACKUP/nginx.conf.before-stream" ]] && cp -a "$BACKUP/nginx.conf.before-stream" "$NGINX_CONF"
    rm -rf --one-file-system "$SITE"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  rm -f "$HELPER" "$AUTH" "$PAYLOAD_DIR"/* /tmp/xray-"$DEPLOY"-*.json
  unset XUI_PASS VLESS_DEC VLESS_ENC VLESSENC_RAW
}
trap cleanup EXIT
printf '%s\n%s\n' "$XUI_USER" "$XUI_PASS" > "$AUTH"; chmod 600 "$AUTH"
cp -a "$XRAY_CONFIG" "$BACKUP/config.json"
cp -a "$NGINX_CONF" "$BACKUP/nginx.conf"
python3 - "$DB" "$BACKUP/x-ui.db" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as a,sqlite3.connect(sys.argv[2]) as b:a.backup(b)
PY

install -m 700 /dev/stdin "$HELPER" <<'PY'
#!/usr/bin/env python3
import http.cookiejar,json,ssl,sys,urllib.parse,urllib.request
action,base=sys.argv[1],sys.argv[2].rstrip("/")
with open(sys.argv[-1]) as f:user,password=f.read().splitlines()[:2]
jar=http.cookiejar.CookieJar()
op=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),urllib.request.HTTPCookieProcessor(jar))
def call(path,data=None):
 d=None if data is None else urllib.parse.urlencode(data).encode()
 with op.open(urllib.request.Request(base+path,data=d),timeout=30) as r:o=json.load(r)
 if not o.get("success"):raise SystemExit(o.get("msg") or repr(o))
 return o.get("obj")
call("/login",{"username":user,"password":password})
if action=="add":
 p=json.load(open(sys.argv[3]));call("/panel/api/inbounds/add",p)
 items=call("/panel/api/inbounds/list") or []
 found=[x for x in items if int(x.get("port",-1))==int(p["port"])]
 if len(found)!=1:raise SystemExit("Inbound could not be uniquely verified")
 print(found[0]["id"])
elif action=="del":call("/panel/api/inbounds/del/"+sys.argv[3],{})
elif action=="restart":call("/panel/api/server/restartXrayService",{})
PY

freeport(){ local p; for _ in $(seq 1 200); do p=$((22000 + RANDOM % 20000)); if ! ss -H -ltn "sport = :$p" | grep -q .; then echo "$p"; return; fi; done; return 1; }
TLS_PORT=""; REALITY_PORT=""; TLS_ID=""; REALITY_ID=""
[[ "$MODE" == tls || "$MODE" == both ]] && TLS_PORT="$(freeport)" || true
[[ "$MODE" == reality || "$MODE" == both ]] && REALITY_PORT="$(freeport)" || true
TLS_UUID="$(cat /proc/sys/kernel/random/uuid)"
REALITY_UUID="$(cat /proc/sys/kernel/random/uuid)"
SID="$(openssl rand -hex 8)"
REALITY_KEYS=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
if [[ "$MODE" == reality || "$MODE" == both ]]; then
  REALITY_KEYS="$("$XRAY" x25519 2>&1)" || die "xray x25519 failed."
  readarray -t REALITY_KEYPAIR < <(printf '%s\n' "$REALITY_KEYS" | python3 -c '
import re,sys
d={}
for line in sys.stdin:
 m=re.match(r"\s*(private\s*key|public\s*key|password)\s*:\s*(\S+)\s*$",line,re.I)
 if m:d[m.group(1).lower().replace(" ","")]=m.group(2)
print(d.get("privatekey",""))
print(d.get("publickey",d.get("password","")))
')
  REALITY_PRIVATE="${REALITY_KEYPAIR[0]:-}"
  REALITY_PUBLIC="${REALITY_KEYPAIR[1]:-}"
  [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "Could not parse xray x25519 output."
fi

write_payload(){
  local mode="$1" port="$2" uuid="$3" outfile="$4"
  python3 - "$mode" "$port" "$uuid" "$outfile" "$DOMAIN" "$PATH_XHTTP" "$VLESS_DEC" "$VLESS_ENC" "$REALITY_SNI" "$REALITY_TARGET" "$REALITY_PRIVATE" "$REALITY_PUBLIC" "$SID" <<'PY'
import json,sys
m,port,uuid,out,domain,path,dec,enc,sni,target,priv,pub,sid=sys.argv[1:]
x={
 "path":path,"host":domain,"mode":"stream-one","xPaddingBytes":"128-1120",
 "xPaddingObfsMode":True,"xPaddingKey":"X-Amz-Meta-Trace",
 "xPaddingHeader":"X-Amz-Security-Token","xPaddingPlacement":"header","xPaddingMethod":"tokenish",
 "sessionIDPlacement":"header","sessionIDKey":"x-amz-cf-id","sessionIDTable":"Base62","sessionIDLength":"16-32",
 "seqPlacement":"header","seqKey":"x-amz-cf-pop","uplinkDataPlacement":"","uplinkDataKey":"",
 "scMaxEachPostBytes":"","noSSEHeader":False,"scMaxBufferedPosts":30,"scStreamUpServerSecs":"20-80",
 "serverMaxHeaderBytes":0,"uplinkHTTPMethod":"POST","headers":{},"scMinPostsIntervalMs":"",
 "uplinkChunkSize":0,"noGRPCHeader":False,"xmux":{"maxConcurrency":"0","maxConnections":"1-3",
 "cMaxReuseTimes":"300-600","hMaxRequestTimes":"1000-2000","hMaxReusableSecs":"1200-2400",
 "hKeepAlivePeriod":600},"enableXmux":True}
stream={"network":"xhttp","security":"none" if m=="tls" else "reality","xhttpSettings":x,
 "sockopt":{"tcpcongestion":"bbr","trustedXForwardedFor":["X-Real-IP"]}}
if m=="reality":stream["realitySettings"]={"show":False,"target":target,"serverNames":[sni],"privateKey":priv,"shortIds":[sid]}
settings={"clients":[{"id":uuid,"flow":"xtls-rprx-vision","email":m+"-"+domain}],"decryption":dec,"encryption":enc,"selectedAuth":"ML-KEM-768, Post-Quantum","testseed":[900,500,900,256]}
if m=="tls":stream["externalProxy"]=[{"forceTls":"tls","dest":domain,"port":443,"remark":"nginx:"+domain}]
payload={"up":0,"down":0,"total":0,"allTime":0,"remark":"stream-one "+m+" "+domain,"enable":True,
 "expiryTime":0,"listen":"127.0.0.1","port":int(port),"protocol":"vless",
 "settings":json.dumps(settings,separators=(",",":")),"streamSettings":json.dumps(stream,separators=(",",":")),
 "tag":"in-stream-one-"+m,"sniffing":json.dumps({"enabled":True,"destOverride":["http","tls","quic"],"routeOnly":True},separators=(",",":"))}
json.dump(payload,open(out,"w"))
PY
}
if [[ -n "$TLS_PORT" ]]; then write_payload tls "$TLS_PORT" "$TLS_UUID" "$PAYLOAD_DIR/tls.json"; fi
if [[ -n "$REALITY_PORT" ]]; then write_payload reality "$REALITY_PORT" "$REALITY_UUID" "$PAYLOAD_DIR/reality.json"; fi

# Create the polished static catalog and its local-only demo login flow.
mkdir -p "$SITE$ASSET_ROUTE"
cp "$ASSET_DIR/poster-orbit.webp" "$SITE$ASSET_ROUTE/$ORBIT_FILE"
cp "$ASSET_DIR/poster-noir.webp" "$SITE$ASSET_ROUTE/$NOIR_FILE"
cp "$ASSET_DIR/poster-summit.webp" "$SITE$ASSET_ROUTE/$SUMMIT_FILE"
cp "$ASSET_DIR/poster-afterglow.webp" "$SITE$ASSET_ROUTE/$AFTERGLOW_FILE"
chmod 644 "$SITE$ASSET_ROUTE"/*.webp
python3 - "$SITE/index.html" "$SITE_NAME" "$ASSET_ROUTE" "$ORBIT_FILE" "$NOIR_FILE" "$SUMMIT_FILE" "$AFTERGLOW_FILE" <<'PY'
import html,sys
brand=html.escape(sys.argv[2]); route=html.escape(sys.argv[3],quote=True)
orbit,noir,summit,afterglow=sys.argv[4:]
page=r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#101114"><title>BRAND — films for tonight</title>
<style>
:root{color-scheme:dark;font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;background:#101114;color:#f5f4f2}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(ellipse at 78% 0,#27201a 0,transparent 32%),#101114}
a{color:inherit;text-decoration:none}button,input{font:inherit}.topbar{height:74px;display:flex;align-items:center;gap:42px;padding:0 max(5vw,24px);border-bottom:1px solid #ffffff12;background:#101114e8;position:sticky;top:0;z-index:5;backdrop-filter:blur(18px)}
.brand{font-size:20px;font-weight:900;letter-spacing:.11em;white-space:nowrap}.brand span{color:#f1a65b}.nav{display:flex;gap:27px;color:#a8a7a4;font-size:13px}.nav a:hover{color:#fff}.actions{margin-left:auto;display:flex;align-items:center;gap:12px}.search{width:min(210px,22vw);background:#ffffff0b;border:1px solid #ffffff16;border-radius:999px;padding:10px 14px;color:white;outline:none}.login,.primary{border:0;border-radius:999px;background:#f1a65b;color:#171310;font-weight:750;padding:10px 18px;cursor:pointer}.login:hover,.primary:hover{background:#ffc17e}
main{width:min(1220px,calc(100% - 48px));margin:auto}.hero{margin:28px 0 46px;min-height:440px;border-radius:24px;overflow:hidden;position:relative;display:flex;align-items:end;padding:48px;background:linear-gradient(90deg,#111216f2 0%,#111216b0 40%,transparent 80%),linear-gradient(0deg,#111216d9,transparent 60%),url("ASSET_ROUTE/ORBIT_IMAGE") center 38%/cover;box-shadow:0 28px 90px #0008}.hero-copy{max-width:560px;position:relative}.eyebrow{text-transform:uppercase;letter-spacing:.19em;font-size:11px;font-weight:800;color:#f1a65b}.hero h1{font-size:clamp(38px,5vw,66px);letter-spacing:-.055em;line-height:.98;margin:14px 0}.hero p{color:#c0c0c2;line-height:1.65;max-width:480px}.hero-meta{font-size:12px;color:#aaa;margin:18px 0}.hero-meta b{color:#f1a65b;margin-right:9px}.section-head{display:flex;align-items:end;justify-content:space-between;margin:0 0 19px}.section-head h2{font-size:26px;letter-spacing:-.03em;margin:0}.section-head span{color:#888;font-size:12px}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:18px}.card{min-width:0}.poster{aspect-ratio:2/3;border-radius:15px;overflow:hidden;position:relative;background:#282624;box-shadow:0 15px 38px #0006;transition:transform .22s,box-shadow .22s}.poster:hover{transform:translateY(-5px);box-shadow:0 24px 46px #0009}.poster img{width:100%;height:100%;object-fit:cover;display:block}.poster:after{content:"";position:absolute;inset:35% 0 0;background:linear-gradient(transparent,#090a0dd9)}.badge{position:absolute;z-index:1;top:12px;left:12px;background:#121315c9;border:1px solid #ffffff25;border-radius:999px;padding:6px 9px;font-size:10px;letter-spacing:.07em;text-transform:uppercase}.play{position:absolute;z-index:1;right:13px;bottom:13px;width:38px;height:38px;border-radius:50%;background:#f1a65b;color:#16110c;display:grid;place-items:center;font-size:14px}.card-info{padding:12px 2px 0}.card-info h3{font-size:15px;margin:0 0 5px}.card-info p{margin:0;color:#898a8d;font-size:11px}.bottom{margin:54px 0 0;padding:24px 0 34px;border-top:1px solid #ffffff12;color:#747579;font-size:11px;display:flex;justify-content:space-between}
.overlay{position:fixed;inset:0;background:#000b;z-index:10;display:none;place-items:center;padding:20px;backdrop-filter:blur(9px)}.overlay.open{display:grid}.dialog{width:min(440px,100%);background:#191a1d;border:1px solid #ffffff19;border-radius:22px;padding:34px;position:relative;box-shadow:0 30px 100px #000}.close{position:absolute;right:18px;top:14px;border:0;background:none;color:#aaa;font-size:25px;cursor:pointer}.dialog .brand{font-size:15px}.dialog h2{font-size:28px;margin:27px 0 8px;letter-spacing:-.04em}.dialog p{color:#9b9ca1;font-size:13px;line-height:1.55;margin:0 0 20px}.dialog label{display:block;color:#c4c4c6;font-size:12px;margin:14px 0 7px}.dialog input{width:100%;border:1px solid #ffffff20;border-radius:11px;background:#101114;padding:13px;color:#fff;outline:none}.dialog input:focus{border-color:#f1a65b}.dialog .primary{width:100%;margin-top:15px}.demo-note{font-size:11px!important;color:#d0a26f!important;margin:12px 0 0!important}.hidden{display:none!important}.message{min-height:18px;color:#f1a65b;font-size:12px;margin-top:12px}
@media(max-width:850px){.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.nav{gap:14px}.search{display:none}.hero{min-height:390px;padding:32px}}@media(max-width:540px){.topbar{height:62px;padding:0 16px;gap:15px}.nav{display:none}.brand{font-size:16px}.login{padding:9px 14px}main{width:calc(100% - 30px)}.hero{min-height:370px;margin:18px 0 34px;padding:24px;border-radius:19px;background-position:56% center}.hero h1{font-size:42px}.grid{gap:10px}.card-info h3{font-size:13px}.poster{border-radius:11px}.section-head h2{font-size:22px}}
</style></head><body>
<header class="topbar"><a class="brand" href="#"><span>◈</span> BRAND</a><nav class="nav"><a href="#films">Films</a><a href="#films">Series</a><a href="#films">Collections</a></nav><div class="actions"><input class="search" id="search" placeholder="Search titles…" aria-label="Search titles"><button class="login" data-open>Sign in</button></div></header>
<main><section class="hero"><div class="hero-copy"><div class="eyebrow">Tonight's feature · New premiere</div><h1>Beyond<br>the Horizon</h1><div class="hero-meta"><b>★ 8.7</b> 2026 &nbsp;·&nbsp; Sci-fi adventure &nbsp;·&nbsp; 2h 08m</div><p>At the edge of a distant ocean, one quiet discovery changes everything the crew thought they knew about home.</p><button class="primary" data-open>▶ &nbsp; Explore film</button></div></section>
<section id="films"><div class="section-head"><h2>Stories worth staying in for</h2><span>Curated for your evening</span></div>
<div class="grid" id="catalog">
<article class="card" data-title="Beyond the Horizon"><a class="poster" href="#films"><img src="ASSET_ROUTE/ORBIT_IMAGE" alt="Astronaut facing an alien ocean beneath a ringed planet"><span class="badge">Premiere</span><span class="play">▶</span></a><div class="card-info"><h3>Beyond the Horizon</h3><p>Sci-fi · Adventure &nbsp; | &nbsp; 2026</p></div></article>
<article class="card" data-title="Midnight Signal"><a class="poster" href="#films"><img src="ASSET_ROUTE/NOIR_IMAGE" alt="Detective on a rain-soaked city street at night"><span class="badge">Thriller</span><span class="play">▶</span></a><div class="card-info"><h3>Midnight Signal</h3><p>Mystery · Crime &nbsp; | &nbsp; 2025</p></div></article>
<article class="card" data-title="The Long Road"><a class="poster" href="#films"><img src="ASSET_ROUTE/SUMMIT_IMAGE" alt="Travelers overlooking a sunlit mountain valley"><span class="badge">Editor's pick</span><span class="play">▶</span></a><div class="card-info"><h3>The Long Road</h3><p>Adventure · Drama &nbsp; | &nbsp; 2026</p></div></article>
<article class="card" data-title="After the Last Light"><a class="poster" href="#films"><img src="ASSET_ROUTE/AFTERGLOW_IMAGE" alt="Two people watching city lights from a rooftop at dusk"><span class="badge">New</span><span class="play">▶</span></a><div class="card-info"><h3>After the Last Light</h3><p>Romance · Drama &nbsp; | &nbsp; 2025</p></div></article>
</div></section>
<footer class="bottom"><span>BRAND · A little something for tonight.</span><span>Catalog information only</span></footer></main>
<div class="overlay" id="login"><section class="dialog" role="dialog" aria-modal="true" aria-labelledby="login-title"><button class="close" data-close aria-label="Close">×</button><div class="brand"><span>◈</span> BRAND</div><h2 id="login-title">A quiet moment before the show.</h2><p id="intro">Enter your email to continue to your personal film collection.</p>
<form id="email-form"><label for="email">Email address</label><input id="email" type="email" autocomplete="email" placeholder="you@example.com" required><button class="primary" type="submit">Continue</button></form>
<form id="code-form" class="hidden"><label for="code">Verification code</label><input id="code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" placeholder="6-digit code" required><p class="demo-note">Demo sign-in only: this page does not send email or deliver a code.</p><button class="primary" type="submit">Continue</button></form><div class="message" id="message" aria-live="polite"></div></section></div>
<script>
const modal=document.getElementById('login'),emailForm=document.getElementById('email-form'),codeForm=document.getElementById('code-form'),intro=document.getElementById('intro'),message=document.getElementById('message');
document.querySelectorAll('[data-open]').forEach(b=>b.addEventListener('click',()=>{modal.classList.add('open');document.getElementById('email').focus()}));
document.querySelectorAll('[data-close]').forEach(b=>b.addEventListener('click',()=>modal.classList.remove('open')));
modal.addEventListener('click',e=>{if(e.target===modal)modal.classList.remove('open')});
emailForm.addEventListener('submit',e=>{e.preventDefault();if(!emailForm.reportValidity())return;emailForm.classList.add('hidden');codeForm.classList.remove('hidden');intro.textContent='Email verification';message.textContent='A code would normally arrive by email. This demo does not send mail.';document.getElementById('code').focus()});
codeForm.addEventListener('submit',e=>{e.preventDefault();message.textContent='Demo only — no code was sent or checked.'});
document.getElementById('search').addEventListener('input',e=>{const q=e.target.value.toLowerCase();document.querySelectorAll('.card').forEach(c=>c.hidden=!c.dataset.title.toLowerCase().includes(q))});
</script></body></html>'''
page=page.replace("BRAND",brand).replace("ASSET_ROUTE",route).replace("ORBIT_IMAGE",orbit).replace("NOIR_IMAGE",noir).replace("SUMMIT_IMAGE",summit).replace("AFTERGLOW_IMAGE",afterglow)
open(sys.argv[1],"w",encoding="utf-8").write(page)
PY
chmod 644 "$SITE/index.html"

# Snapshot any nginx files this installer must touch, and install a restoration-based remover.
NGINX_ORIG_HASH="$(sha256sum "$NGINX_CONF" | awk '{print $1}')"
if [[ "$MODE" == reality || "$MODE" == both ]]; then
  if ! nginx -V 2>&1 | grep -Eq -- '--with-stream|stream=dynamic'; then
    command -v apt-get >/dev/null 2>&1 || die "nginx stream module is unavailable."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y libnginx-mod-stream
  fi
  if nginx -T 2>/dev/null | grep -Eq '^[[:space:]]*stream[[:space:]]*\{' \
      && ! grep -q 'streams-enabled/\*.conf' "$NGINX_CONF"; then
    die "nginx already has a stream{} block without the managed include; merge the stream include manually first."
  fi
fi

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
# Refuse to steal :443 from an existing nginx site: Reality mode needs nginx
# stream to own the public socket and pass ordinary HTTPS to its private origin port.
if nginx -T 2>/dev/null | grep -Eq '^[[:space:]]*listen[[:space:]]+([^;[:space:]]*:)?443([[:space:];]|$)'; then
  die "An nginx vhost already listens on :443. Back it up/move it first; Reality SNI routing needs exclusive ownership of this port."
fi
if nginx -T 2>/dev/null | grep -Eq "^[[:space:]]*server_name[[:space:]][^;]*([[:space:]])${DOMAIN//./\\.}([[:space:];])"; then
  die "An nginx vhost already claims $DOMAIN. Resolve that conflict before installing."
fi
if [[ ! -r "$CERT" || ! -r "$KEY" ]]; then
  read -rp 'Email for Let’s Encrypt: ' CERT_EMAIL
  [[ -n "$CERT_EMAIL" ]] || die "A valid TLS certificate is needed for the nginx-hosted site."
  # Temporary HTTP-only ACME vhost; replace it with the final TLS config below.
  cat > "$VHOST" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $SITE;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  nginx -t && systemctl reload nginx
  certbot certonly --webroot --webroot-path "$SITE" --non-interactive --agree-tos -m "$CERT_EMAIL" -d "$DOMAIN"
  [[ -r "$CERT" && -r "$KEY" ]] || die "Let's Encrypt did not create the expected certificate."
fi

# In Reality mode, nginx stream is the public :443 listener. It dispatches the
# this domain to Xray. Ordinary TLS is relayed by REALITY to the local HTTPS origin.
if [[ "$MODE" == reality || "$MODE" == both ]]; then
  mkdir -p /etc/nginx/streams-enabled
  if ! grep -q 'streams-enabled/\*.conf' "$NGINX_CONF"; then
    cp -a "$NGINX_CONF" "$BACKUP/nginx.conf.before-stream"
    sed -i '/^events[[:space:]]*{/i stream { include /etc/nginx/streams-enabled/*.conf; }' "$NGINX_CONF"
  fi
  cat > "$STREAM_CONF" <<EOF
map \$ssl_preread_server_name \$stream_one_upstream {
    $DOMAIN 127.0.0.1:$REALITY_PORT;
    default 127.0.0.1:9443;
}
server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
    proxy_pass \$stream_one_upstream;
}
EOF
  HTTPS_LISTEN="listen 9443 ssl http2;"
else
  HTTPS_LISTEN="listen 443 ssl http2;"
fi

cat > "$VHOST" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $SITE; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    $HTTPS_LISTEN
    server_name $DOMAIN;
    root $SITE;
    index index.html;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    location ^~ $PATH_XHTTP {
EOF
if [[ -n "$TLS_PORT" ]]; then
cat >> "$VHOST" <<EOF
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        client_body_timeout 1h;
        client_max_body_size 0;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_pass grpc://127.0.0.1:$TLS_PORT;
EOF
else
cat >> "$VHOST" <<EOF
        return 404;
EOF
fi
cat >> "$VHOST" <<'EOF'
    }
    location / { try_files $uri $uri/ =404; }
}
EOF

# Validate generated Xray objects before calling the panel.
for mode in tls reality; do
  [[ -f "$PAYLOAD_DIR/$mode.json" ]] || continue
  python3 - "$PAYLOAD_DIR/$mode.json" "/tmp/xray-$DEPLOY-$mode.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); s=json.loads(p["settings"]); t=json.loads(p["streamSettings"])
c={"log":{"loglevel":"warning"},"inbounds":[{"listen":p["listen"],"port":p["port"],"protocol":p["protocol"],
 "settings":{"clients":s["clients"],"decryption":s["decryption"],"testseed":s["testseed"]},
 "streamSettings":{k:v for k,v in t.items() if k!="externalProxy"}}],
 "outbounds":[{"protocol":"freedom","tag":"direct"}]}
json.dump(c,open(sys.argv[2],"w"))
PY
  "$XRAY" run -test -config "/tmp/xray-$DEPLOY-$mode.json" || die "Xray rejected $mode preflight config."
done
nginx -t

# Add and verify each selected inbound. Failure handler removes any created IDs.
nginx -t && systemctl reload nginx
for mode in tls reality; do
  [[ -f "$PAYLOAD_DIR/$mode.json" ]] || continue
  id="$(python3 "$HELPER" add "$BASE" "$PAYLOAD_DIR/$mode.json" "$AUTH")"
  [[ "$id" =~ ^[0-9]+$ ]] || die "Unexpected inbound ID."
  CREATED_IDS+=("$id")
  [[ "$mode" == tls ]] && TLS_ID="$id" || REALITY_ID="$id"
done
python3 "$HELPER" restart "$BASE" "$AUTH"
for port in "$TLS_PORT" "$REALITY_PORT"; do
  [[ -n "$port" ]] || continue
  for _ in $(seq 1 60); do ss -H -ltn "sport = :$port" | grep -q "127.0.0.1:$port" && break; sleep .5; done
  ss -H -ltn "sport = :$port" | grep -q "127.0.0.1:$port" || die "Xray did not listen on loopback port $port."
done
"$XRAY" run -test -config "$XRAY_CONFIG" >/dev/null || die "Panel's generated Xray config failed validation."
nginx -t && systemctl reload nginx

# Export client URI(s); secrets are stored in a root-only result directory.
python3 - "$RESULT" "$MODE" "$DOMAIN" "$PATH_XHTTP" "$ASSET_ROUTE" "$TLS_UUID" "$REALITY_UUID" "$TLS_PORT" "$REALITY_PORT" "$TLS_ID" "$REALITY_ID" "$VLESS_ENC" "$REALITY_SNI" "$REALITY_PUBLIC" "$SID" "$SITE_NAME" <<'PY'
import json,pathlib,sys,urllib.parse
o=pathlib.Path(sys.argv[1]);(mode,domain,path,asset_route,tu,ru,tp,rp,ti,ri,enc,sni,pub,sid,title)=sys.argv[2:]
def write(name,uuid,security,extra):
 q={"encryption":enc,"flow":"xtls-rprx-vision","security":security,"type":"xhttp","host":domain,"path":path,"mode":"stream-one","fp":"chrome","alpn":"h2"}
 if security=="tls":q["sni"]=domain
 else:q.update({"sni":sni,"pbk":pub,"sid":sid})
 q["extra"]=json.dumps(extra,separators=(",",":"))
 link=f"vless://{uuid}@{domain}:443?"+urllib.parse.urlencode(q,quote_via=urllib.parse.quote)+"#"+urllib.parse.quote(title+" stream-one "+security)
 (o/f"vless-{security}.txt").write_text(link+"\n")
settings={"mode":"stream-one","path":path,"host":domain,"xPaddingBytes":"128-1120","xPaddingObfsMode":True,"xPaddingKey":"X-Amz-Meta-Trace","xPaddingHeader":"X-Amz-Security-Token","xPaddingPlacement":"header","xPaddingMethod":"tokenish","sessionIDPlacement":"header","sessionIDKey":"x-amz-cf-id","sessionIDTable":"Base62","sessionIDLength":"16-32","seqPlacement":"header","seqKey":"x-amz-cf-pop","uplinkHTTPMethod":"POST","scMaxBufferedPosts":30,"scStreamUpServerSecs":"20-80","xmux":{"maxConcurrency":"0","maxConnections":"1-3","cMaxReuseTimes":"300-600","hMaxRequestTimes":"1000-2000","hMaxReusableSecs":"1200-2400","hKeepAlivePeriod":600},"enableXmux":True}
if mode in ("tls","both"):write("tls",tu,"tls",settings)
if mode in ("reality","both"):write("reality",ru,"reality",settings)
(o/"deployment.json").write_text(json.dumps({"mode":mode,"domain":domain,"xhttpPath":path,"catalogAssetPath":asset_route,"tlsInboundId":int(ti) if ti else None,"realityInboundId":int(ri) if ri else None,"realitySni":sni or None,"tlsPort":int(tp) if tp else None,"realityPort":int(rp) if rp else None,"panelPatch":"xhttp-vlessenc-vision-2811-v4/v5"},indent=2))
PY
chmod 600 "$RESULT"/*
cat > "$RESULT/remove.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
read -rp '3x-ui username: ' U
read -rsp '3x-ui password: ' P; printf '\\n'
printf '%s\\n%s\\n' "\$U" "\$P" > '$RESULT/auth'; chmod 600 '$RESULT/auth'
EOF
for id in "$TLS_ID" "$REALITY_ID"; do
  [[ -n "$id" ]] && printf "python3 '%s/xui-api.py' del '%s' '%s' '$RESULT/auth'\n" "$RESULT" "$BASE" "$id" >> "$RESULT/remove.sh"
done
# The remover owns only files created by this deployment; certbot material is retained.
cat >> "$RESULT/remove.sh" <<EOF
python3 '$RESULT/xui-api.py' restart '$BASE' '$RESULT/auth'
rm -f '$VHOST' '$STREAM_CONF'
if [[ -f '$BACKUP/nginx.conf.before-stream' ]]; then
  python3 - '$NGINX_CONF' <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); lines=p.read_text().splitlines(keepends=True)
for i,line in enumerate(lines):
    if line.strip() == 'stream { include /etc/nginx/streams-enabled/*.conf; }':
        del lines[i]
        break
p.write_text(''.join(lines))
PY
fi
rm -rf --one-file-system '$SITE'
nginx -t && systemctl reload nginx
rm -f '$RESULT/auth'
echo 'Selected inbounds, nginx routes and site removed; certificates and backups retained.'
EOF
cp "$HELPER" "$RESULT/xui-api.py"; chmod 700 "$RESULT/xui-api.py"; chmod 700 "$RESULT/remove.sh"
rm -f "$HELPER" "$AUTH" "$PAYLOAD_DIR"/* /tmp/xray-"$DEPLOY"-*.json
COMMITTED=1
trap - EXIT
log "Installed mode: $MODE"
log "Site: https://$DOMAIN/"
[[ -n "$TLS_PORT" ]] && log "TLS inbound: 127.0.0.1:$TLS_PORT, panel ID $TLS_ID; link: $RESULT/vless-tls.txt"
[[ -n "$REALITY_PORT" ]] && log "Reality inbound: 127.0.0.1:$REALITY_PORT, panel ID $REALITY_ID; SNI $REALITY_SNI; link: $RESULT/vless-reality.txt"
log "Random XHTTP path: $PATH_XHTTP; catalog art path: $ASSET_ROUTE/"
log "Remove script: $RESULT/remove.sh"
log "Backup: $BACKUP"
