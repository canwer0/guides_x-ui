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

cat > "$WORK/site.html" <<'CLOUD_SITE_HTML'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#f7f6fc"><meta name="description" content="__SITE_NAME__ — бесплатное облачное хранилище для синхронизации Obsidian. Заметки, вложения и история изменений на ваших устройствах.">
<title>__SITE_NAME__ — бесплатное облако для Obsidian</title>
<style>
:root{--ink:#252238;--muted:#79758e;--line:#e8e5f0;--purple:#7350d7;--purple-dark:#5837b8;--paper:#f7f6fc;--green:#268965;font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;font-synthesis:none;color:var(--ink);background:var(--paper)}*{box-sizing:border-box}body{margin:0;min-width:320px}html{scroll-behavior:smooth}button,input{font:inherit}a{color:inherit;text-decoration:none}button{cursor:pointer}button:disabled{cursor:wait;opacity:.6}button:focus-visible,a:focus-visible,summary:focus-visible{outline:3px solid #bda9f7;outline-offset:4px}button{border:0}svg{vertical-align:middle}.container{width:min(1160px,calc(100% - 48px));margin:auto}.nav{height:90px;display:flex;align-items:center;gap:38px}.brand{display:inline-flex;gap:10px;align-items:center;font-weight:760;font-size:19px;letter-spacing:-.6px;white-space:nowrap}.brand svg{width:31px;height:34px;flex:none}.nav-links{display:flex;gap:28px;margin-left:32px;color:#706b83;font-size:13px}.nav-links a:hover{color:var(--purple)}.nav-actions{display:flex;gap:15px;margin-left:auto;align-items:center}.button{display:inline-flex;align-items:center;justify-content:center;gap:10px;border-radius:10px;padding:13px 21px;background:var(--purple);color:white;font-weight:650;font-size:13px;transition:background .15s,transform .15s}.button:hover{background:var(--purple-dark);transform:translateY(-1px)}.button.large{padding:16px 25px;font-size:14px}.button.secondary{background:white;color:var(--ink);border:1px solid var(--line)}.button.secondary:hover{border-color:#bca9e9}.link-button{padding:9px 0;background:none;color:#5d566f;font-size:13px;font-weight:600}.link-button:hover{color:var(--purple)}
.hero{position:relative;padding:59px 0 90px;display:grid;grid-template-columns:1fr 1.06fr;gap:43px;align-items:center}.hero:before{content:"";position:absolute;z-index:-1;right:-50px;top:0;width:550px;height:540px;background:radial-gradient(ellipse,#e5dcfc,transparent 68%)}.tag{display:inline-flex;align-items:center;gap:8px;border:1px solid #e4ddf7;border-radius:100px;padding:7px 11px;color:#7957c9;background:#f0ebfc;font-size:11px;font-weight:650;letter-spacing:.015em}.tag .dot{width:6px;height:6px;border-radius:50%;background:#9370df}.hero h1{font-size:clamp(40px,4.65vw,61px);line-height:1.08;letter-spacing:-2.8px;margin:24px 0 22px;font-weight:760}.hero h1 span{color:var(--purple)}.hero-copy>p{color:var(--muted);font-size:16px;line-height:1.8;max-width:440px;margin:0 0 28px}.hero-actions{display:flex;gap:11px;align-items:center}.fine{display:flex;gap:16px;flex-wrap:wrap;font-size:11px;color:#928b9f;margin-top:19px}.fine span:before{content:"✓";margin-right:5px;color:#9a88c6}.preview{border:1px solid #ded7ed;border-radius:16px;background:white;box-shadow:0 22px 70px #4e367818,0 2px 4px #51417a08;overflow:hidden;min-width:0}.preview-bar{height:43px;background:#fcfbff;border-bottom:1px solid var(--line);display:flex;align-items:center;padding:0 16px;gap:6px}.window-dot{width:7px;height:7px;border-radius:50%;background:#ded9e8}.preview-address{font-size:9px;color:#aaa1b6;margin:auto}.preview-body{display:grid;grid-template-columns:132px 1fr;min-height:348px}.preview-sidebar{border-right:1px solid var(--line);background:#fbfaff;padding:18px 11px;display:flex;flex-direction:column}.preview-brand{font-size:9px;font-weight:750;display:flex;align-items:center;gap:6px;padding:0 5px 20px}.preview-brand svg{width:15px;height:18px}.preview-label{font-size:8px;letter-spacing:1px;color:#a59bac;padding:0 7px;margin-bottom:8px}.preview-item{font-size:9px;padding:9px 8px;margin-bottom:3px;color:#9b90a9;border-radius:6px}.preview-item.active{background:#eee8fb;color:#8460cf;font-weight:600}.preview-item b{margin-right:7px;font-weight:400}.quota{margin-top:auto;padding:16px 5px 0}.quota>div{display:flex;justify-content:space-between;font-size:8px;color:#8e829f}.track{height:4px;background:#ece6f3;border-radius:10px;margin:8px 0}.track>i{display:block;width:32%;height:100%;background:#9975db;border-radius:10px}.quota small{color:#afa2bd;font-size:7px}.preview-main{padding:21px 22px 13px;min-width:0}.preview-top{display:flex;align-items:center;justify-content:space-between;margin-bottom:21px}.preview-top strong{font-size:14px;letter-spacing:-.5px}.avatar{width:23px;height:23px;background:#e9e1f8;border-radius:50%;color:#9371c7;display:grid;place-items:center;font-size:8px}.vault{border:1px solid #e9e1f1;border-radius:8px;padding:12px;background:linear-gradient(115deg,#f9f5ff,#fff)}.vault-heading{display:flex;align-items:center;gap:10px}.folder-icon{width:28px;height:28px;background:#eadefb;border-radius:7px;color:#8d64d0;display:grid;place-items:center}.vault-heading strong{display:block;font-size:11px;margin-bottom:3px}.vault-heading small{font-size:8px;color:#a496b0}.status{margin-left:auto;display:flex;align-items:center;gap:4px;color:#6eaa88;font-size:7px;white-space:nowrap}.status:before{content:"";height:4px;width:4px;border-radius:50%;background:#8aba9c}.files-head{display:flex;align-items:center;justify-content:space-between;margin:20px 0 9px;font-size:9px;color:#84738e}.files-head span{font-size:7px;color:#aa9eb4}.file-row{display:flex;align-items:center;gap:8px;padding:9px 0;border-bottom:1px solid #f2eef6;font-size:8px;color:#92859d}.file-row:last-child{border:0}.file-type{font-size:6px;color:#a48ec0;background:#f0eafb;padding:4px;border-radius:3px;min-width:21px;text-align:center}.file-row time{margin-left:auto;color:#b6a9bf;font-size:7px;white-space:nowrap}.device-bar{display:flex;align-items:center;gap:6px;margin-top:14px;padding-top:12px;border-top:1px solid #eee7f4;font-size:7px;color:#a08fae}.device-bar>span:last-child{margin-left:auto;color:#75a78b}.floating-note{border:1px solid #e4dfec;border-radius:10px;background:white;padding:13px 17px;display:flex;align-items:center;gap:10px;margin:15px 0 0 110px;box-shadow:0 8px 25px #4e367809;font-size:11px}.floating-note .check{width:25px;height:25px;display:grid;place-items:center;border-radius:50%;color:#53a281;background:#edf7f1}.floating-note strong{font-size:10px;display:block;margin-bottom:3px}.floating-note small{font-size:9px;color:#a198ac}.preview-caption{text-align:center;color:#b3a8c1;font-size:9px;margin-top:11px}
.platforms{display:flex;align-items:center;justify-content:center;gap:33px;padding:25px 0 34px;border-bottom:1px solid var(--line);color:#92899e;font-size:12px}.platforms>span:first-child{color:#b1a7ba;font-size:11px;margin-right:7px}.platforms strong{font-weight:600;color:#83778e}.section{padding:80px 0}.section-title{text-align:center;max-width:570px;margin:0 auto 35px}.section-title .overline{font-size:10px;text-transform:uppercase;letter-spacing:1.7px;color:#a088c4;font-weight:650}.section-title h2{font-size:33px;line-height:1.25;letter-spacing:-1.15px;margin:13px 0}.section-title p{font-size:14px;color:var(--muted);line-height:1.7;margin:0}.features{display:grid;grid-template-columns:repeat(3,1fr);gap:19px}.feature{background:white;border:1px solid var(--line);border-radius:12px;padding:25px}.feature-icon{height:36px;width:36px;display:grid;place-items:center;background:#f0ebfa;border-radius:10px;color:#9b7acb;margin-bottom:18px}.feature-icon svg{width:18px;height:18px}.feature h3{font-size:15px;letter-spacing:-.3px;margin:0 0 9px}.feature p{font-size:12px;color:var(--muted);line-height:1.8;margin:0}.steps-section{background:#f0edf7;border-top:1px solid #e8e2f1;border-bottom:1px solid #e8e2f1}.steps{display:grid;grid-template-columns:repeat(3,1fr);gap:55px}.step-number{font-size:10px;color:#997bc2;display:inline-grid;place-items:center;height:26px;width:26px;border:1px solid #d7cae9;border-radius:50%;margin-bottom:14px}.step h3{font-size:14px;margin:0 0 8px}.step p{font-size:12px;line-height:1.8;color:#918398;margin:0}.pricing{display:grid;grid-template-columns:1fr 1fr;gap:70px;align-items:center;padding:0 90px}.pricing-copy h2{font-size:35px;line-height:1.2;letter-spacing:-1.2px;margin:15px 0}.pricing-copy p{font-size:14px;color:var(--muted);line-height:1.8}.pricing-copy small{font-size:11px;color:#a28cba}.price-card{border:1px solid #dacfef;background:white;border-radius:14px;padding:29px;box-shadow:0 8px 35px #5d407009}.price-top{display:flex;justify-content:space-between;align-items:center;font-size:14px;font-weight:700}.free-badge{padding:5px 9px;background:#f0e9fb;color:#9573c6;border-radius:100px;font-size:9px;font-weight:600}.price{font-size:47px;letter-spacing:-2px;margin:21px 0 3px;font-weight:750}.price span{font-size:12px;color:#a69ab2;font-weight:400;letter-spacing:0}.price-card>p{font-size:11px;color:#a298ac;margin:0 0 22px}.price-card ul{padding:17px 0 0;margin:0 0 25px;list-style:none;border-top:1px solid #eee8f4}.price-card li{font-size:12px;color:#93829d;margin:13px 0}.price-card li:before{content:"✓";color:#a082ce;margin-right:10px}.price-card .button{width:100%}.faq{max-width:720px;margin:auto}.faq details{border-bottom:1px solid var(--line);padding:18px 0}.faq summary{font-size:13px;font-weight:550;cursor:pointer;list-style:none;display:flex;justify-content:space-between;gap:15px}.faq summary:after{content:"+";font-weight:400;color:#aa98c0;font-size:17px}.faq details[open] summary:after{content:"−"}.faq details p{font-size:12px;line-height:1.85;color:var(--muted);margin:13px 25px 0 0}.closing{display:flex;align-items:center;justify-content:space-between;background:#eae3f7;border:1px solid #e0d5f1;border-radius:15px;padding:35px 42px;margin:0 0 65px}.closing h2{font-size:24px;letter-spacing:-.8px;margin:0 0 8px}.closing p{font-size:12px;color:#9b88b1;margin:0}.footer{border-top:1px solid var(--line);padding:30px 0 34px}.footer-main{display:flex;justify-content:space-between;align-items:center}.footer .brand{font-size:15px;color:#94839f}.footer .brand svg{width:21px;height:25px;opacity:.65}.footer-links{display:flex;gap:22px;color:#a395ae;font-size:11px}.footer-links button{padding:0;background:none;color:inherit;font-size:inherit}.footer-meta{display:flex;justify-content:space-between;margin-top:20px;color:#b1a5ba;font-size:10px}.footer-meta span:last-child{display:flex;align-items:center;gap:6px}.footer-meta i{height:4px;width:4px;background:#83b192;border-radius:50%}
.modal{display:none;position:fixed;inset:0;background:#211a3880;backdrop-filter:blur(6px);z-index:30;align-items:center;justify-content:center;padding:22px}.modal.open{display:flex}.dialog{width:min(420px,100%);background:white;border:1px solid #eee7f6;border-radius:18px;padding:32px;box-shadow:0 35px 100px #1d133f33;position:relative}.close{position:absolute;top:14px;right:15px;width:29px;height:29px;border-radius:50%;background:#f7f3fb;color:#a08aac;font-size:20px}.dialog-logo{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:700;color:#9a80b7;margin-bottom:25px}.dialog-logo svg{width:23px;height:27px}.dialog h2{font-size:23px;line-height:1.3;letter-spacing:-.65px;margin:0 0 10px}.dialog p{font-size:12px;line-height:1.8;color:#a091ad;margin:0 0 22px}.dialog label{font-size:11px;display:block;margin:0 0 8px;color:#8e759e}.dialog input{display:block;width:100%;border:1px solid #e0d5ea;border-radius:9px;padding:13px;font-size:13px;background:#fcfaff;color:#756184;outline:none;margin-bottom:15px}.dialog input:focus{border-color:#ac8ed8;box-shadow:0 0 0 3px #f3ebff}.dialog input.code{font-size:23px;text-align:center;letter-spacing:10px;font-variant-numeric:tabular-nums}.dialog .button{width:100%}.dialog .terms{font-size:10px;line-height:1.7;color:#b6a7c1;margin-top:18px;text-align:center}.terms button{padding:0;background:none;color:#a486c5;text-decoration:underline;font-size:inherit}.dialog .back{background:none;font-size:10px;color:#aa8dc3;margin:0 0 18px;padding:0}.dialog .error{min-height:18px;font-size:11px;color:#c087a6;margin:11px 0}.dialog .resend{display:block;text-align:center;margin:14px auto 0;font-size:10px;color:#a687c6;background:none}.dialog .resend:disabled{color:#bfb0ce;cursor:default;opacity:1}.dialog .mail{font-weight:600;color:#9375aa;overflow-wrap:anywhere}.hidden{display:none!important}.policy-dialog{width:min(560px,100%);max-height:85vh;overflow:auto}.policy-dialog p{color:#9480a1}.policy-dialog h3{font-size:13px;margin:20px 0 8px}
@media(max-width:1050px){.nav-links{margin-left:0;gap:18px}.hero{gap:25px}.hero h1{font-size:48px}.hero-actions{flex-wrap:wrap}.preview-body{grid-template-columns:112px 1fr}.preview-main{padding:19px 16px}.pricing{padding:0 30px;gap:45px}.nav{gap:20px}.brand{max-width:280px;overflow:hidden;text-overflow:ellipsis}}
@media(max-width:780px){.nav-links{display:none}.nav{height:77px}.nav-actions .button{display:none}.hero{grid-template-columns:1fr;padding:35px 0 45px;gap:35px}.hero-copy{text-align:center}.hero h1{font-size:52px;letter-spacing:-2px}.hero-copy>p{margin-left:auto;margin-right:auto}.hero-actions,.fine{justify-content:center}.hero-visual{max-width:560px;width:100%;margin:auto}.hero:before{right:0;top:200px;width:100%}.platforms{flex-wrap:wrap;gap:18px}.platforms>span:first-child{width:100%;text-align:center}.section{padding:55px 0}.section-title h2{font-size:29px}.features{grid-template-columns:1fr}.feature{padding:21px;display:grid;grid-template-columns:38px 1fr;gap:0 16px}.feature-icon{grid-row:1/3;margin:0}.steps{gap:25px}.pricing{grid-template-columns:1fr;padding:0;gap:22px}.pricing-copy{text-align:center}.price-card{max-width:420px;width:100%;margin:auto}.closing{padding:28px;gap:22px;margin-bottom:45px}.closing h2{font-size:20px}.closing .button{flex:none}.footer-meta{flex-direction:column;gap:10px}.footer-links{gap:12px}}
@media(max-width:460px){.container{width:calc(100% - 32px)}.brand{font-size:16px;max-width:245px}.brand svg{width:25px}.nav-actions{gap:0}.hero h1{font-size:42px}.hero-copy>p{font-size:14px}.hero-actions .button{padding:14px 18px;font-size:12px}.preview-body{grid-template-columns:100px 1fr;min-height:324px}.preview-main{padding:16px 11px}.preview-sidebar{padding:17px 6px}.preview-top strong{font-size:12px}.status{display:none}.file-row{font-size:7px;gap:5px}.floating-note{margin-left:45px}.platforms{font-size:10px;gap:20px}.steps{grid-template-columns:1fr;gap:22px}.step{display:grid;grid-template-columns:27px 1fr;column-gap:15px}.step-number{grid-row:1/3}.closing{display:block;text-align:center}.closing .button{margin-top:22px}.footer-main{align-items:flex-start;gap:20px}.footer-links{flex-direction:column;align-items:flex-end}.dialog{padding:29px 24px}}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{transition:none!important}}
</style>
</head>
<body data-cloud-site="v2">
<svg aria-hidden="true" style="position:absolute;width:0;height:0;overflow:hidden"><symbol id="crystal" viewBox="0 0 30 36"><path fill="#ad92e6" d="m16 1 11 9 2 17-12 8L3 27 1 11Z"/><path fill="#7951c7" d="m16 1-4 15 5 19 12-8-2-17Z"/><path fill="#9672d8" d="m1 11 11 5 5 19L3 27Z"/><path fill="#bea6ee" d="m16 1 11 9-15 6L1 11Z"/></symbol></svg>
<header class="container nav"><a class="brand" href="#top"><svg aria-hidden="true"><use href="#crystal"/></svg><span>__SITE_NAME__</span></a><nav class="nav-links" aria-label="Основная навигация"><a href="#features">Возможности</a><a href="#how">Как подключить</a><a href="#pricing">Бесплатный тариф</a></nav><div class="nav-actions"><button class="link-button" data-login>Войти</button><button class="button" data-login>Создать хранилище <span aria-hidden="true">↗</span></button></div></header>
<main id="top">
<section class="container hero"><div class="hero-copy"><div class="tag"><span class="dot"></span>Сделано для ваших заметок в Obsidian</div><h1>Ваш Obsidian.<br>На всех устройствах.<br><span>Без подписки.</span></h1><p>Бесплатное облачное хранилище для ваших vault: заметок, вложений и истории изменений. Работайте локально, синхронизируйте, когда удобно.</p><div class="hero-actions"><button class="button large" data-login>Начать бесплатно <span aria-hidden="true">→</span></button><a class="button secondary large" href="#how">Как это работает</a></div><div class="fine"><span>5 ГБ бесплатно</span><span>Без банковской карты</span><span>Ваши файлы — ваши</span></div></div>
<div class="hero-visual"><div class="preview" aria-label="Пример личного кабинета"><div class="preview-bar"><i class="window-dot"></i><i class="window-dot"></i><i class="window-dot"></i><span class="preview-address">⌑ &nbsp; Личный кабинет / Хранилища</span></div><div class="preview-body"><aside class="preview-sidebar"><div class="preview-brand"><svg aria-hidden="true"><use href="#crystal"/></svg>Моё облако</div><div class="preview-label">ПРОСТРАНСТВО</div><div class="preview-item active"><b>▱</b>Хранилища</div><div class="preview-item"><b>↻</b>История версий</div><div class="preview-item"><b>▧</b>Устройства</div><div class="preview-item"><b>⚙</b>Настройки</div><div class="quota"><div><span>Использовано</span><span>1,6 / 5 ГБ</span></div><div class="track"><i></i></div><small>Тариф Free · навсегда</small></div></aside><div class="preview-main"><div class="preview-top"><strong>Мои хранилища</strong><span class="avatar">АК</span></div><div class="vault"><div class="vault-heading"><div class="folder-icon">▱</div><div><strong>Личное пространство</strong><small>248 файлов · 3 устройства</small></div><span class="status">Синхронизировано</span></div></div><div class="files-head">Последние изменения<span>Все файлы ↗</span></div><div class="file-row"><span class="file-type">MD</span>Заметки / Идеи на неделю.md<time>сейчас</time></div><div class="file-row"><span class="file-type">MD</span>Проекты / Новый проект.md<time>2 мин</time></div><div class="file-row"><span class="file-type">PDF</span>Вложения / Материалы.pdf<time>8 мин</time></div><div class="file-row"><span class="file-type">MD</span>Дневник / Сегодня.md<time>12 мин</time></div><div class="device-bar"><span>▧</span>MacBook · iPhone · Рабочий ПК<span>● Онлайн</span></div></div></div></div><div class="floating-note"><div class="check">✓</div><div><strong>Изменения сохранены в облаке</strong><small>Личное пространство · только что</small></div></div><div class="preview-caption">Так выглядит ваше пространство после подключения</div></div></section>
<div class="container platforms"><span>Там, где вы пользуетесь Obsidian</span><strong>Windows</strong><strong>macOS</strong><strong>Linux</strong><strong>iOS</strong><strong>Android</strong></div>
<section class="container section" id="features"><div class="section-title"><span class="overline">Привычный Obsidian. Больше свободы.</span><h2>Облако, которое не мешает думать</h2><p>Не меняйте привычный способ вести заметки. Добавьте к нему место, где ваши файлы всегда под рукой.</p></div><div class="features"><article class="feature"><div class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M4 9a8 8 0 0 1 13-5l3 3M20 3v4h-4M20 15a8 8 0 0 1-13 5l-3-3M4 21v-4h4"/></svg></div><h3>Один vault на всех устройствах</h3><p>Продолжайте заметку с телефона, а затем возвращайтесь к ней на компьютере. Папки и вложения остаются рядом.</p></article><article class="feature"><div class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M4 12a8 8 0 1 0 3-6M4 4v5h5M12 7v5l3 2"/></svg></div><h3>История на случай «ой»</h3><p>Возвращайтесь к предыдущим версиям и находите удачные формулировки. История изменений хранится 30 дней.</p></article><article class="feature"><div class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M14 3H6v18h12V7Zm0 0v5h5M9 12l-2 2 2 2M15 12l2 2-2 2"/></svg></div><h3>Обычные файлы Markdown</h3><p>Заметки не привязаны к закрытому формату. Вы можете хранить локальную копию и забрать свои файлы в любой момент.</p></article></div></section>
<section class="steps-section" id="how"><div class="container section"><div class="section-title"><span class="overline">Подключение</span><h2>От заметки до облака — три шага</h2></div><div class="steps"><article class="step"><div class="step-number">01</div><h3>Войдите по электронной почте</h3><p>Создайте аккаунт с помощью одноразового кода. Пароль придумывать и запоминать не понадобится.</p></article><article class="step"><div class="step-number">02</div><h3>Создайте облачное хранилище</h3><p>Дайте вашему vault название и получите параметры подключения в личном кабинете.</p></article><article class="step"><div class="step-number">03</div><h3>Подключите Obsidian</h3><p>Добавьте параметры в совместимый плагин синхронизации и выберите локальную папку с заметками.</p></article></div></div></section>
<section class="container section" id="pricing"><div class="pricing"><div class="pricing-copy"><div class="tag">Бесплатный тариф</div><h2>Хорошим идеям<br>нужно место.<br>А не ещё одна подписка.</h2><p>Хранилище для ежедневных заметок, рабочих проектов и личной базы знаний. Начните с того, что уже есть в вашем Obsidian.</p><small>Для подключения потребуется войти в аккаунт.</small></div><div class="price-card"><div class="price-top">Free<span class="free-badge">Без срока действия</span></div><div class="price">0 ₽ <span>/ месяц</span></div><p>Карта и платёжные данные не нужны</p><ul><li>5 ГБ для заметок и вложений</li><li>Подключение ваших устройств</li><li>История изменений за 30 дней</li><li>Сохранение структуры папок</li><li>Передача данных по HTTPS</li></ul><button class="button" data-login>Создать бесплатное хранилище →</button></div></div></section>
<section class="container section" id="help" style="padding-top:0"><div class="section-title"><span class="overline">Вопросы и ответы</span><h2>Перед тем как начать</h2></div><div class="faq"><details><summary>Это официальный Obsidian Sync?</summary><p>__SITE_NAME__ — независимый сервис хранения. Он предназначен для файлов из Obsidian и подключения через совместимый плагин синхронизации. Сервис не связан с командой Obsidian.</p></details><details><summary>Нужно ли переносить заметки из Obsidian?</summary><p>Ваш vault остаётся локальной папкой. Для подключения облачного хранилища войдите в аккаунт и следуйте инструкции в личном кабинете.</p></details><details><summary>Можно ли работать без интернета?</summary><p>Локальные заметки доступны в Obsidian без интернета. Синхронизация изменений требует подключения к сети.</p></details><details><summary>Что занимает место в хранилище?</summary><p>Заметки Markdown и вложения: изображения, документы и другие файлы вашего vault. Объём доступен в настройках хранилища.</p></details><details><summary>Как получить доступ к хранилищу?</summary><p>Нажмите «Начать бесплатно» и укажите электронную почту. Для входа используется шестизначный код. Создание и подключение хранилища доступны после авторизации.</p></details></div></section>
<div class="container"><section class="closing"><div><h2>Пусть ваши заметки будут рядом.</h2><p>Создайте пространство для своего Obsidian.</p></div><button class="button large" data-login>Начать бесплатно →</button></section></div>
</main>
<footer class="footer"><div class="container"><div class="footer-main"><a class="brand" href="#top"><svg aria-hidden="true"><use href="#crystal"/></svg><span>__SITE_NAME__</span></a><div class="footer-links"><a href="#help">Помощь</a><button data-policy="privacy">Конфиденциальность</button><button data-policy="terms">Условия использования</button></div></div><div class="footer-meta"><span>© <span id="year">2026</span> __SITE_NAME__. Независимый проект для пользователей Obsidian.</span><span><i></i>Соединение защищено HTTPS</span></div></div></footer>
<div class="modal" id="auth-modal" role="dialog" aria-modal="true" aria-labelledby="auth-title"><div class="dialog"><button class="close" aria-label="Закрыть окно" data-close>×</button><div class="dialog-logo"><svg aria-hidden="true"><use href="#crystal"/></svg>__SITE_NAME__</div><div id="email-step"><h2 id="auth-title">Ваше облако начинается здесь</h2><p>Войдите или создайте аккаунт, чтобы подключить хранилище к Obsidian.</p><form id="email-form"><label for="email">Электронная почта</label><input id="email" type="email" autocomplete="email" required maxlength="254" placeholder="you@example.com"><button class="button" id="send-code" type="submit">Продолжить по почте →</button></form><div class="terms">Продолжая, вы принимаете <button data-policy="terms">условия сервиса</button><br>и <button data-policy="privacy">политику конфиденциальности</button>.</div></div><div class="hidden" id="code-step"><button class="back" id="change-email">← Указать другую почту</button><h2 id="code-title">Проверьте почту</h2><p>Код для входа отправлен на<br><span class="mail" id="email-display"></span></p><form id="code-form"><label for="code">Шестизначный код</label><input class="code" id="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required placeholder="······"><button class="button" type="submit">Открыть хранилище →</button></form><div class="error" id="code-error" role="status" aria-live="polite"></div><button class="resend" id="resend" disabled>Отправить код повторно через 60 с</button><div class="terms">Письмо может занять несколько минут.<br>Проверьте папки «Спам» и «Промоакции».</div></div></div></div>
<div class="modal" id="policy-modal" role="dialog" aria-modal="true" aria-labelledby="policy-title"><div class="dialog policy-dialog"><button class="close" aria-label="Закрыть окно" data-close>×</button><h2 id="policy-title"></h2><div id="policy-content"></div></div></div>
<script>
(()=>{'use strict';const $=id=>document.getElementById(id),auth=$('auth-modal'),policy=$('policy-modal');let lastFocus=null,countdown=null,busy=false;
const policies={privacy:{title:'Конфиденциальность',body:'<h3>Данные для входа</h3><p>Электронная почта используется в форме входа. Эта страница не запрашивает пароль от Obsidian, доступ к почтовому ящику или платёжные данные.</p><h3>Локальная копия</h3><p>Файлы вашего Obsidian остаются на ваших устройствах. Перед подключением любого сервиса синхронизации сохраняйте резервную копию.</p><h3>Хранение данных на странице</h3><p>Форма не записывает email и код в cookies или локальное хранилище браузера. После закрытия окна введённые значения очищаются.</p>'},terms:{title:'Условия использования',body:'<h3>Независимый проект</h3><p>Сервис предназначен для работы с файлами Obsidian и не является продуктом команды Obsidian.</p><h3>Доступ к хранилищу</h3><p>Создание хранилища и параметры подключения доступны после авторизации. Указывайте адрес электронной почты, к которому у вас есть доступ.</p><h3>Ваши файлы</h3><p>Права на заметки и вложения принадлежат их владельцам. Храните локальную копию вашего vault и внимательно проверяйте параметры синхронизации.</p>'}};
function close(modal){modal.classList.remove('open');if(modal===auth){busy=false;clearInterval(countdown);$('email-form').reset();$('code-form').reset();$('email-step').classList.remove('hidden');$('code-step').classList.add('hidden');auth.setAttribute('aria-labelledby','auth-title');$('send-code').disabled=false;$('send-code').textContent='Продолжить по почте →';$('email-display').textContent='';$('code-error').textContent='';}if(!document.querySelector('.modal.open')){document.body.style.overflow='';lastFocus?.focus();}}
function show(modal){lastFocus=document.activeElement;modal.classList.add('open');document.body.style.overflow='hidden';setTimeout(()=>modal.querySelector('input,button')?.focus(),20);}
function timer(){clearInterval(countdown);let remaining=60;const b=$('resend');b.disabled=true;b.textContent=`Отправить код повторно через ${remaining} с`;countdown=setInterval(()=>{remaining--;b.textContent=remaining?`Отправить код повторно через ${remaining} с`:'Отправить код повторно';if(!remaining){clearInterval(countdown);b.disabled=false;}},1000);}
document.querySelectorAll('[data-login]').forEach(b=>b.addEventListener('click',()=>{show(auth);$('email').focus();}));document.querySelectorAll('[data-close]').forEach(b=>b.addEventListener('click',()=>close(b.closest('.modal'))));document.querySelectorAll('[data-policy]').forEach(b=>b.addEventListener('click',()=>{$('policy-title').textContent=policies[b.dataset.policy].title;$('policy-content').innerHTML=policies[b.dataset.policy].body;show(policy);}));[auth,policy].forEach(m=>m.addEventListener('click',e=>{if(e.target===m)close(m);}));
$('email-form').addEventListener('submit',e=>{e.preventDefault();if(busy)return;busy=true;const b=$('send-code');b.disabled=true;b.textContent='Подготовка входа…';setTimeout(()=>{if(!auth.classList.contains('open'))return;busy=false;b.disabled=false;b.textContent='Продолжить по почте →';$('email-display').textContent=$('email').value;$('email-step').classList.add('hidden');$('code-step').classList.remove('hidden');auth.setAttribute('aria-labelledby','code-title');$('code').focus();timer();},650);});
$('change-email').addEventListener('click',()=>{clearInterval(countdown);$('code-step').classList.add('hidden');$('email-step').classList.remove('hidden');auth.setAttribute('aria-labelledby','auth-title');$('code').value='';$('code-error').textContent='';$('email').focus();});$('code').addEventListener('input',e=>{e.target.value=e.target.value.replace(/\D/g,'');$('code-error').textContent='';});$('code-form').addEventListener('submit',e=>{e.preventDefault();$('code-error').textContent='Код не подтверждён. Проверьте письмо и попробуйте ещё раз.';$('code').value='';$('code').focus();});$('resend').addEventListener('click',()=>{$('code-error').textContent='Запрос на повторную отправку принят.';timer();});
document.addEventListener('keydown',e=>{const modal=policy.classList.contains('open')?policy:auth.classList.contains('open')?auth:null;if(!modal)return;if(e.key==='Escape'){close(modal);return;}if(e.key==='Tab'){const nodes=[...modal.querySelectorAll('button:not(:disabled),input,a[href]')].filter(n=>n.offsetParent!==null),first=nodes[0],last=nodes.at(-1);if(e.shiftKey&&document.activeElement===first){last.focus();e.preventDefault();}else if(!e.shiftKey&&document.activeElement===last){first.focus();e.preventDefault();}}});$('year').textContent=new Date().getFullYear();})();
</script>
</body></html>

CLOUD_SITE_HTML

cat > "$WORK/deploy.py" <<'CLOUD_DEPLOY_PY'
import contextlib,copy,hashlib,html,json,os,pathlib,re,secrets,shutil,socket,sqlite3,subprocess,sys,time,uuid
from urllib.parse import quote,urlencode

P=pathlib.Path
def log(message): print('[cloud] '+message,flush=True)
def run(args,check=True,**kw):
    result=subprocess.run(args,capture_output=True,text=True,**kw)
    if check and result.returncode:
        raise RuntimeError('Command failed: '+str(args[0])+' '+str(args[1])+'; '+result.stderr[-300:])
    return result
def write(path,data,mode=0o600):
    path=P(path);path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(data,encoding='utf-8');path.chmod(mode)
def compact(value): return json.dumps(value,separators=(',',':'),ensure_ascii=False)
def dump(path,value): write(path,json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def port_open(port):
    with socket.socket() as sock:
        sock.settimeout(.3);return sock.connect_ex(('127.0.0.1',port))==0
def free_port(excluded):
    for _ in range(200):
        port=secrets.randbelow(30000)+22000
        if port not in excluded and not port_open(port): excluded.add(port);return port
    raise RuntimeError('No free local port')
def wait_for_port(port,timeout=25):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        if port_open(port):return
        time.sleep(.3)
    raise RuntimeError('Listener did not start: '+str(port))
def mask_nginx(text):
    result=list(text);comment=False;string=None;escape=False
    for i,c in enumerate(text):
        if comment:
            if c=='\n':comment=False
            else:result[i]=' '
        elif string:
            result[i]=' '
            if escape:escape=False
            elif c=='\\':escape=True
            elif c==string:string=None
        elif c in ('"',"'"):string=c;result[i]=' '
        elif c=='#':comment=True;result[i]=' '
    return ''.join(result)
def blocks(text):
    masked=mask_nginx(text);stack=[];start=0;found=[]
    for i,c in enumerate(masked):
        if c=='{':
            head=masked[start:i].strip();kind=head.split()[0] if head else ''
            stack.append((kind,i,tuple(x[0] for x in stack)));start=i+1
        elif c=='}':
            if not stack:raise RuntimeError('Unbalanced Nginx configuration')
            kind,begin,parents=stack.pop();found.append((kind,begin,i,parents));start=i+1
        elif c==';':start=i+1
    if stack:raise RuntimeError('Unbalanced Nginx configuration')
    return found

# Match canwer0/guides_x-ui/xhttp/stream-one-tls-reality. The patched
# panel edits server fields directly; client imports use the extra object.
EXTRA={'mode':'stream-one','xPaddingBytes':'128-1120','xPaddingObfsMode':True,'xPaddingKey':'X-Amz-Meta-Trace','xPaddingHeader':'X-Amz-Security-Token','xPaddingPlacement':'header','xPaddingMethod':'tokenish','sessionIDPlacement':'header','sessionIDKey':'x-amz-cf-id','sessionIDTable':'Base62','sessionIDLength':'16-32','seqPlacement':'header','seqKey':'x-amz-cf-pop','uplinkHTTPMethod':'POST'}
VLESS_AUTH='ML-KEM-768, Post-Quantum'
INBOUND_NAMES={'xhttp':'xhttp stream-one Vlessenc','reality':'tcp reality'}

def generate_vlessenc(xray):
    raw=run([str(xray),'vlessenc']).stdout
    profiles=[];profile=None
    for line in raw.splitlines():
        match=re.search(r'Authentication:\s*(.+)',line)
        if match:
            profile={'label':match[1].strip()};profiles.append(profile)
        elif profile is not None:
            match=re.search(r'"(decryption|encryption)"\s*:\s*"([^"]+)"',line)
            if match:profile[match[1]]=match[2]
    pair=next((p for p in profiles if p['label']==VLESS_AUTH),None)
    if not pair or any(not pair.get(k,'').startswith('mlkem768x25519plus.native.') for k in ('decryption','encryption')):
        raise RuntimeError('Xray must support xray vlessenc with ML-KEM-768 authentication')
    return {k:pair[k] for k in ('decryption','encryption')}

def make_inbounds(domain,name,xport,rport,tlsport,xuid,ruid,private,public,sid,path,key,pairs):
    client=lambda uid,flow,email:{'id':uid,'flow':flow,'email':email,'enable':True,'limitIp':0,'totalGB':0,'expiryTime':0,'subId':secrets.token_hex(8),'reset':0,'created_at':int(time.time()*1000),'updated_at':int(time.time()*1000)}
    common={'user_id':0,'up':0,'down':0,'total':0,'all_time':0,'enable':1,'expiry_time':0,'traffic_reset':'never','last_traffic_reset_time':0,'listen':'127.0.0.1','protocol':'vless','sniffing':compact({'enabled':True,'destOverride':['http','tls'],'routeOnly':True})}
    xsettings={'clients':[client(xuid,'','cloud-xhttp-'+key)],**pairs['xhttp'],'selectedAuth':VLESS_AUTH}
    rsettings={'clients':[client(ruid,'xtls-rprx-vision','cloud-reality-'+key)],**pairs['reality'],'selectedAuth':VLESS_AUTH,'testseed':[900,500,900,256]}
    xstream={'network':'xhttp','security':'none','xhttpSettings':{'host':domain,'path':path,**EXTRA},'externalProxy':[{'forceTls':'tls','dest':domain,'port':443,'remark':'bot:'+compact({'path':path,'host':domain})}]}
    rstream={'network':'tcp','security':'reality','realitySettings':{'show':False,'target':'127.0.0.1:'+str(tlsport),'xver':0,'serverNames':[domain],'privateKey':private,'shortIds':[sid],'settings':{'publicKey':public,'fingerprint':'firefox','serverName':domain,'spiderX':'/'}},'externalProxy':[{'forceTls':'same','dest':domain,'port':443,'remark':INBOUND_NAMES['reality']}]}
    x={**common,'port':xport,'remark':INBOUND_NAMES['xhttp'],'settings':compact(xsettings),'stream_settings':compact(xstream),'tag':'inbound-127.0.0.1:'+str(xport)}
    r={**common,'port':rport,'remark':INBOUND_NAMES['reality'],'settings':compact(rsettings),'stream_settings':compact(rstream),'tag':'inbound-127.0.0.1:'+str(rport)}
    return x,r
def core_inbound(row):
    stream=json.loads(row['stream_settings']);stream.pop('externalProxy',None)
    if stream.get('realitySettings'):stream['realitySettings'].pop('settings',None)
    settings=json.loads(row['settings'])
    settings['clients']=[{k:v for k,v in c.items() if k in ('id','email','flow')} for c in settings['clients']]
    return {'listen':row['listen'],'port':row['port'],'protocol':row['protocol'],'tag':row['tag'],'settings':settings,'streamSettings':stream,'sniffing':json.loads(row['sniffing'])}
def client_config(kind,domain,address,edge,socks_port,xuid,ruid,public,sid,path,encryption):
    stream={'network':'tcp','security':'reality','realitySettings':{'fingerprint':'firefox','serverName':domain,'password':public,'shortId':sid,'spiderX':'/'}} if kind=='reality' else {'network':'xhttp','security':'tls','tlsSettings':{'serverName':domain,'alpn':['h2'],'fingerprint':'chrome','allowInsecure':False},'xhttpSettings':{'host':domain,'path':path,'mode':'stream-one','extra':EXTRA}}
    user={'id':ruid if kind=='reality' else xuid,'encryption':encryption,'flow':'xtls-rprx-vision' if kind=='reality' else ''}
    if kind=='reality':user['testseed']=[900,500,900,256]
    return {'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':socks_port,'protocol':'socks','settings':{'auth':'noauth','udp':False}}],'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':address,'port':edge,'users':[user]}]},'streamSettings':stream}]}

class Deployment:
    def __init__(self,options,work):
        self.options=options;self.work=P(work);self.domain=options['domain'];self.name=options['siteName']
        self.key=hashlib.sha256(self.domain.encode()).hexdigest()[:12]
        self.result=P('/root/obsidian-cloud-'+self.key);self.state=self.result/'deployment.json'
        self.backup=P('/root/obsidian-cloud-backups')/(time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+secrets.token_hex(4))
        self.backup.mkdir(parents=True,mode=0o700);self.backup.parent.chmod(0o700)
        self.files={};self.db=P(os.environ.get('XUI_DB_PATH','/etc/x-ui/x-ui.db'))
        self.xui=P(os.environ.get('XUI_MAIN_FOLDER','/usr/local/x-ui'))
        self.runtime=self.xui/'bin/config.json'
        self.xray=next((p for p in (self.xui/'bin').glob('xray-linux-*') if p.is_file() and os.access(p,os.X_OK)),None)
        if not self.xray or not self.db.exists():raise RuntimeError('Install 3X-UI/Xray before running this script')
        self.db_saved=False;self.stopped=False;self.committed=False
        self.http=P('/etc/nginx/conf.d/obsidian-cloud-'+self.key+'.conf')
        self.stream=P('/etc/nginx/obsidian-cloud-stream/'+self.key+'.conf')
        self.web=P('/var/www/obsidian-cloud-'+self.key+'-'+secrets.token_hex(4))
        self.oldfiles=set();self.ids={};self.excluded=set()
    def save(self,path):
        path=P(path)
        if str(path) in self.files:return
        entry={'exists':path.exists(),'mode':0o600}
        if path.exists():
            entry['mode']=path.stat().st_mode&0o777;entry['snapshot']=str(len(self.files))+'.original'
            shutil.copyfile(path,self.backup/entry['snapshot']);(self.backup/entry['snapshot']).chmod(0o600)
        self.files[str(path)]=entry;dump(self.backup/'files.json',self.files)
    def preflight(self):
        if run(['systemctl','is-active','x-ui'],check=False).returncode:raise RuntimeError('3X-UI must be running')
        run(['nginx','-t'])
        self.loaded={}
        data=run(['nginx','-T']).stdout
        for path in re.findall(r'^# configuration file (.+):\s*$',data,re.M):
            resolved=P(path).resolve()
            if resolved.is_file():self.loaded[str(resolved)]=resolved.read_text()
        if self.state.exists():
            old=json.loads(self.state.read_text())
            if old.get('domain')!=self.domain:raise RuntimeError('Deployment state domain mismatch')
            self.ids={k:old[k]['id'] for k in ('xhttp','reality')}
            self.oldfiles.update([self.http,self.stream])
        else:
            candidates=[]
            for p in P('/root').glob('luma-notes-*/deployment.json'):
                with contextlib.suppress(OSError,ValueError,KeyError):
                    value=json.loads(p.read_text())
                    if value['domain']==self.domain:candidates.append((p,value))
            if len(candidates)>1:raise RuntimeError('Multiple older deployments; select the active one before installing')
            if candidates:
                p,old=candidates[0];suffix=p.parent.name.removeprefix('luma-notes-')
                if not re.fullmatch('[a-f0-9]{12}',suffix):raise RuntimeError('Unexpected older deployment path')
                self.ids={k:old[k]['id'] for k in ('xhttp','reality')}
                self.oldfiles.update([P('/etc/nginx/conf.d/luma-notes-'+suffix+'.conf'),P('/etc/nginx/luma-stream/'+suffix+'.conf')])
        conn=sqlite3.connect(self.db);conn.row_factory=sqlite3.Row
        self.oldrows={}
        self.users=conn.execute('select id from users order by id limit 1').fetchone()
        if not self.users:raise RuntimeError('No panel user found')
        for kind,ident in list(self.ids.items()):
            row=conn.execute('select * from inbounds where id=?',(ident,)).fetchone()
            if not row:
                log('Previously managed '+kind+' inbound was removed; creating a replacement')
                del self.ids[kind]
                continue
            row=dict(row);stream=json.loads(row['stream_settings'])
            expected=stream.get('security')=='reality' if kind=='reality' else stream.get('network')=='xhttp'
            if old.get('schema')==2:
                domain_matches=self.domain in stream.get('realitySettings',{}).get('serverNames',[]) if kind=='reality' else stream.get('xhttpSettings',{}).get('host')==self.domain
                owned_row=(row['listen']==old[kind]['listen'] and row['port']==old[kind]['internalPort'] and domain_matches)
            else:owned_row=self.domain in row['remark']
            if not expected or not owned_row:raise RuntimeError('Stored inbound ID belongs to a different configuration: '+str(ident))
            self.oldrows[kind]=row
        self.excluded.update(r[0] for r in conn.execute('select port from inbounds'));conn.close()
        owned={str(p.resolve()) for p in self.oldfiles}|{str(self.http),str(self.stream)}
        for path,text in self.loaded.items():
            if path in owned:continue
            clean=mask_nginx(text)
            if re.search(r'(?m)^\s*listen\s+[^;]*\b443\b',clean):raise RuntimeError('Another Nginx config owns 443: '+path)
            if re.search(r'(?m)^\s*server_name\s+[^;]*\b'+re.escape(self.domain)+r'(?=[;\s])',clean):raise RuntimeError('Domain already belongs to another Nginx config: '+path)
        listener=run(['ss','-H','-ltnp','sport = :443']).stdout
        if listener and 'nginx' not in listener:
            allowed=any(row['port']==443 for row in self.oldrows.values())
            if not allowed or 'xray' not in listener:raise RuntimeError('Another service owns TCP 443')
        streams=[(P(path),begin,end) for path,text in self.loaded.items() for kind,begin,end,parents in blocks(text) if kind=='stream' and not parents]
        if len(streams)>1:raise RuntimeError('Multiple Nginx stream blocks')
        if streams:self.stream_owner,self.stream_begin,self.stream_end=streams[0]
        else:self.stream_owner=P('/etc/nginx/nginx.conf');self.stream_begin=self.stream_end=None
        for p in {*self.oldfiles,self.http,self.stream,self.stream_owner,self.state,self.result/'vless-tcp-reality.txt',self.result/'vless-xhttp-tls.txt',self.result/'client-reality.json',self.result/'client-xhttp.json'}:self.save(p)
        self.tlsport=free_port(self.excluded);self.xport=free_port(self.excluded);self.rport=free_port(self.excluded)
        self.cert=P('/etc/letsencrypt/live')/self.domain/'fullchain.pem';self.certkey=self.cert.with_name('privkey.pem')
    def apply_nginx(self):
        run(['nginx','-t'])
        if run(['systemctl','is-active','nginx'],check=False).returncode:run(['systemctl','start','nginx'])
        else:run(['systemctl','reload','nginx'])
    def provision_certificate(self):
        self.web.mkdir(parents=True,mode=0o755);self.web.chmod(0o755)
        acme=self.web/'.well-known/acme-challenge';acme.mkdir(parents=True,mode=0o755);acme.parent.chmod(0o755);acme.chmod(0o755)
        page=(self.work/'site.html').read_text().replace('__SITE_NAME__',html.escape(self.name,quote=True))
        write(self.web/'index.html',page,0o644)
        write(self.web/'robots.txt','User-agent: *\nDisallow: /account\n',0o644)
        if not (self.cert.exists() and self.certkey.exists()):
            if not self.options.get('certEmail'):raise RuntimeError('Certificate email is required')
            for p in self.oldfiles:
                if p.exists():p.unlink()
            write(self.http,f'server {{ listen 80; server_name {self.domain}; root {self.web}; location ^~ /.well-known/acme-challenge/ {{ try_files $uri =404; }} location / {{ return 404; }} }}\n',0o644)
            self.apply_nginx()
            run(['certbot','certonly','--webroot','-w',str(self.web),'--non-interactive','--agree-tos','-m',self.options['certEmail'],'-d',self.domain])
        run(['openssl','x509','-in',str(self.cert),'-noout','-checkhost',self.domain])
        run(['openssl','x509','-in',str(self.cert),'-noout','-checkend','0'])
        # Keep the renewal webroot stable across subsequent installations.
        for path in self.cert.parent.parent.parent.joinpath('renewal').glob(self.domain+'.conf'):
            self.save(path);text=path.read_text()
            text=re.sub(r'(?m)^(webroot_path\s*=\s*).+$',lambda m:m.group(1)+str(self.web)+',',text)
            text=re.sub(r'(?m)^('+re.escape(self.domain)+r'\s*=\s*).+$',lambda m:m.group(1)+str(self.web),text)
            write(path,text,0o600)
    def prepare(self):
        log('Generating independent ML-KEM-768 VLESS Encryption keys for both inbounds')
        self.encpairs={kind:generate_vlessenc(self.xray) for kind in ('xhttp','reality')}
        pair=run([str(self.xray),'x25519']).stdout
        keys={}
        for line in pair.splitlines():
            match=re.match(r'\s*(Private\s*Key|Public\s*Key|Password(?:\s*\(Public\s*Key\))?)\s*:\s*(\S+)',line,re.I)
            if match:keys['private' if re.sub(r'\s+','',match[1]).lower()=='privatekey' else 'public']=match[2]
        if 'private' not in keys or 'public' not in keys:raise RuntimeError('Cannot parse Xray x25519 output')
        self.private=keys['private'];self.public=keys['public'];self.sid=secrets.token_hex(8)
        self.xuid=str(uuid.uuid4());self.ruid=str(uuid.uuid4());self.path='/sync/'+secrets.token_hex(18)+'/'
        self.rows=dict(zip(('xhttp','reality'),make_inbounds(self.domain,self.name,self.xport,self.rport,self.tlsport,self.xuid,self.ruid,self.private,self.public,self.sid,self.path,self.key,self.encpairs)))
        test={'log':{'loglevel':'warning'},'inbounds':[core_inbound(row) for row in self.rows.values()],'outbounds':[{'protocol':'freedom','tag':'direct'}]}
        dump(self.work/'server-test.json',test);run([str(self.xray),'run','-test','-config',str(self.work/'server-test.json')])
    def configure_database(self):
        log('Backing up 3X-UI and configuring two loopback inbounds')
        run(['systemctl','stop','x-ui']);self.stopped=True
        connection=sqlite3.connect(self.db)
        with sqlite3.connect(self.backup/'x-ui.db') as backup:connection.backup(backup)
        (self.backup/'x-ui.db').chmod(0o600);self.db_saved=True
        try:
            with connection:
                for kind,row in self.rows.items():
                    row['user_id']=self.users[0]
                    if kind in self.ids:
                        ident=self.ids[kind]
                        connection.execute('update inbounds set '+','.join(k+'=?' for k in row)+' where id=?',[*row.values(),ident])
                        connection.execute('delete from client_traffics where inbound_id=?',(ident,))
                    else:
                        cursor=connection.execute('insert into inbounds ('+','.join(row)+') values ('+','.join('?' for _ in row)+')',list(row.values()));ident=cursor.lastrowid;self.ids[kind]=ident
                    email=json.loads(row['settings'])['clients'][0]['email']
                    connection.execute('insert into client_traffics (inbound_id,enable,email,up,down,all_time,expiry_time,total,reset,last_online) values (?,1,?,0,0,0,0,0,0,0)',(ident,email))
        finally:connection.close()
    def configure_nginx(self):
        log('Configuring Nginx TCP 443, local HTTPS and XHTTP gRPC route')
        for path in self.oldfiles:
            if path.exists():path.unlink()
        self.http.parent.mkdir(parents=True,exist_ok=True);self.stream.parent.mkdir(parents=True,exist_ok=True)
        version=run(['nginx','-v'],check=False).stderr;match=re.search(r'nginx/(\d+)\.(\d+)\.(\d+)',version)
        modern=match and tuple(map(int,match.groups()))>=(1,25,1)
        listen=f'listen 127.0.0.1:{self.tlsport} ssl'+(';' if modern else ' http2;')
        http2='http2 on;' if modern else ''
        ipv6='listen [::]:80;' if P('/proc/net/if_inet6').exists() else ''
        config=f'''server {{
    listen 80; {ipv6}
    server_name {self.domain};
    root {self.web};
    location ^~ /.well-known/acme-challenge/ {{ try_files $uri =404; }}
    location / {{ return 301 https://{self.domain}$request_uri; }}
}}
server {{
    {listen}
    {http2}
    server_name {self.domain};
    root {self.web}; index index.html;
    ssl_certificate {self.cert};
    ssl_certificate_key {self.certkey};
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    location ^~ {self.path} {{
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_connect_timeout 10s;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;
        grpc_set_header Host $host;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_pass grpc://127.0.0.1:{self.xport};
        access_log off;
    }}
    location ^~ /.well-known/acme-challenge/ {{ try_files $uri =404; }}
    location / {{ try_files $uri $uri/ =404; }}
}}
'''
        write(self.http,config,0o644)
        edge_v6='listen [::]:443 ipv6only=on;' if P('/proc/net/if_inet6').exists() else ''
        write(self.stream,f'''server {{
    listen 443; {edge_v6}
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
    proxy_socket_keepalive on;
    proxy_half_close on;
    proxy_pass 127.0.0.1:{self.rport};
}}
''',0o644)
        include='include '+str(self.stream)+';'
        text=self.stream_owner.read_text()
        if include not in text:
            if self.stream_end is None:text+='\n# Obsidian cloud TCP frontend\nstream { '+include+' }\n'
            else:text=text[:self.stream_end]+'\n    '+include+'\n'+text[self.stream_end:]
            write(self.stream_owner,text,0o644)
        self.apply_nginx()
        run(['systemctl','start','x-ui']);self.stopped=False
        wait_for_port(self.xport);wait_for_port(self.rport);wait_for_port(443)
        run([str(self.xray),'run','-test','-config',str(self.runtime)])
        current=json.loads(self.runtime.read_text())
        for kind,row in self.rows.items():
            found=[i for i in current.get('inbounds',[]) if i.get('tag')==row['tag']]
            if len(found)!=1 or not found[0].get('settings',{}).get('clients'):raise RuntimeError('Panel generated an inbound without an enabled client: '+kind)
    def verify(self):
        log('Testing HTTPS and real data transfer through both client profiles on 443')
        site=self.work/'https.html'
        run(['curl','--noproxy','*','-fsS','--max-time','20','--resolve',self.domain+':443:127.0.0.1','-o',str(site),'https://'+self.domain+'/'])
        if 'data-cloud-site="v2"' not in site.read_text():raise RuntimeError('Public HTTPS site is unexpected')
        probe='test-'+secrets.token_hex(12);data=secrets.token_hex(65536).encode()
        target=self.web/'.well-known/acme-challenge'/probe;target.write_bytes(data);target.chmod(0o644)
        self.results={}
        try:
            for kind in ('reality','xhttp'):
                port=free_port(self.excluded)
                client=client_config(kind,self.domain,'127.0.0.1',443,port,self.xuid,self.ruid,self.public,self.sid,self.path,self.encpairs[kind]['encryption'])
                cfg=self.work/('test-'+kind+'.json');dump(cfg,client)
                logfile=self.work/('test-'+kind+'.log')
                with logfile.open('w') as out:
                    process=subprocess.Popen([str(self.xray),'run','-config',str(cfg)],stdout=out,stderr=out,cwd=self.xui/'bin')
                    try:
                        wait_for_port(port,10)
                        result=run(['curl','--noproxy','','--socks5-hostname','127.0.0.1:'+str(port),'-fsS','--connect-timeout','15','--max-time','45','-o',str(self.work/('result-'+kind)), 'https://'+self.domain+'/.well-known/acme-challenge/'+probe],check=False)
                        if result.returncode or (self.work/('result-'+kind)).read_bytes()!=data:
                            shutil.copyfile(logfile,self.backup/('failed-'+kind+'.log'))
                            raise RuntimeError(kind+' failed actual transfer test: '+result.stderr[-200:]+'; diagnostics: '+str(self.backup))
                        self.results[kind]={'bytes':len(data),'passed':True};log(kind+' OK: '+str(len(data))+' bytes through public TCP 443')
                    finally:
                        process.terminate()
                        try:process.wait(timeout=5)
                        except subprocess.TimeoutExpired:process.kill();process.wait()
        finally:target.unlink(missing_ok=True)
    def write_profiles(self):
        self.result.mkdir(parents=True,exist_ok=True,mode=0o700);self.result.chmod(0o700)
        query={'type':'xhttp','encryption':self.encpairs['xhttp']['encryption'],'security':'tls','sni':self.domain,'host':self.domain,'path':self.path,'mode':'stream-one','alpn':'h2','fp':'chrome','extra':compact(EXTRA)}
        reality={'type':'tcp','encryption':self.encpairs['reality']['encryption'],'security':'reality','sni':self.domain,'fp':'firefox','pbk':self.public,'sid':self.sid,'spx':'/','flow':'xtls-rprx-vision'}
        for kind,uid,q in [('xhttp',self.xuid,query),('reality',self.ruid,reality)]:
            filename='vless-xhttp-tls.txt' if kind=='xhttp' else 'vless-tcp-reality.txt'
            link=f'vless://{uid}@{self.domain}:443?'+urlencode(q,quote_via=quote)+'#'+quote(INBOUND_NAMES[kind])+'\n'
            write(self.result/filename,link)
            dump(self.result/('client-'+kind+'.json'),client_config(kind,self.domain,self.domain,443,10808,self.xuid,self.ruid,self.public,self.sid,self.path,self.encpairs[kind]['encryption']))
    def finish(self):
        self.write_profiles()
        state={'schema':2,'domain':self.domain,'siteName':self.name,'webroot':str(self.web),'nginxHttpConfig':str(self.http),'nginxStreamConfig':str(self.stream),'nginxTlsListen':'127.0.0.1:'+str(self.tlsport),'xhttp':{'id':self.ids['xhttp'],'listen':'127.0.0.1','internalPort':self.xport,'publicPort':443,'path':self.path,'mode':'stream-one'},'reality':{'id':self.ids['reality'],'listen':'127.0.0.1','internalPort':self.rport,'publicPort':443,'serverName':self.domain,'target':'127.0.0.1:'+str(self.tlsport)},'tests':self.results,'backup':str(self.backup)}
        state['authentication']=VLESS_AUTH;state['reality']['fingerprint']='firefox'
        dump(self.state,state);self.committed=True
        log('Installed https://'+self.domain+'/');log('Client links and full Xray client JSON: '+str(self.result));log('Backup: '+str(self.backup))
    def rollback(self):
        log('Installation failed; restoring previous Nginx and 3X-UI configuration')
        errors=[]
        if self.db_saved:
            run(['systemctl','stop','x-ui'],check=False)
            try:
                with sqlite3.connect(self.backup/'x-ui.db') as src,sqlite3.connect(self.db) as dest:src.backup(dest)
            except Exception as error:errors.append(str(error))
        for path,entry in self.files.items():
            try:
                if entry['exists']:
                    shutil.copyfile(self.backup/entry['snapshot'],path);P(path).chmod(entry['mode'])
                else:P(path).unlink(missing_ok=True)
            except Exception as error:errors.append(str(error))
        try:self.apply_nginx()
        except Exception as error:errors.append(str(error))
        if self.db_saved or self.stopped:
            if run(['systemctl','start','x-ui'],check=False).returncode:errors.append('Could not restart x-ui')
        if errors:log('Rollback needs attention: '+'; '.join(errors))
        else:log('Previous configuration restored')
        log('Backup: '+str(self.backup))

def main():
    options=json.loads(P(sys.argv[1]).read_text());work=P(sys.argv[2])
    if os.geteuid()!=0:raise SystemExit('Run as root')
    if not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}',options['domain']):raise SystemExit('Invalid domain')
    if not 2<=len(options['siteName'])<=64 or any(ord(c)<32 for c in options['siteName']):raise SystemExit('Site name must be 2–64 characters')
    deploy=Deployment(options,work)
    try:
        deploy.preflight();deploy.provision_certificate();deploy.prepare();deploy.configure_database();deploy.configure_nginx();deploy.verify();deploy.finish()
    except BaseException as error:
        if not deploy.committed:deploy.rollback()
        raise SystemExit('ERROR: '+str(error)) from None
if __name__=='__main__':main()

CLOUD_DEPLOY_PY

python3 "$WORK/deploy.py" "$WORK/options.json" "$WORK"
