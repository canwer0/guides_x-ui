🛠 guides_x-ui

Набор скриптов и быстрых команд для настройки и обслуживания **3X-UI / Xray**.

---

## ☁️ Cloudflare WARP

Устанавливает Cloudflare WARP, поднимает локальный SOCKS5-прокси на `127.0.0.1:40000` и добавляет его как outbound `warp` в 3X-UI.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/canwer0/guides_x-ui/main/warp/install.sh)
```

---

---
## 🚨 Zabbix-agent

Устанавливает zabbix-agent для мониторинга.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/canwer0/guides_x-ui/main/zabbix/install-agent.sh)
```

---

## 📊 Мониторинг outbound'ов в Zabbix

Устанавливает мониторинг outbound'ов 3X-UI для Zabbix.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/canwer0/guides_x-ui/main/zabbix/x-ui-monitor.sh)
```

---
## 🔄 Автоматический перезапуск Xray Core

Устанавливает автоматический перезапуск Xray Core каждые 70 минут без перезапуска панели 3X-UI.

```bash
curl -fsSL https://raw.githubusercontent.com/canwer0/guides_x-ui/main/cron-scripts/x-ray-restart.sh | sudo bash
```

---
## 🚀 XHTTP patch для 3X-UI 2.8.11

Шаг1. Устанавливает XHTTP patch для **3X-UI 2.8.11**.

```bash
curl -fsSL \
  "https://raw.githubusercontent.com/canwer0/guides_x-ui/main/xhttp/patch-xhttp-2.8.11.sh?v=$(date +%s)" \
  -o /tmp/patch-xhttp-2.8.11.sh

bash -n /tmp/patch-xhttp-2.8.11.sh &&
sudo bash /tmp/patch-xhttp-2.8.11.sh
```
Шаг2. Разворачивает фейк сайт и настраивает nginx
```bash
curl -fsSL \
"https://raw.githubusercontent.com/canwer0/guides_x-ui/main/xhttp/next_installation_step.sh?v=$(date +%s)" \
-o /tmp/next_installation_step.sh

bash -n /tmp/next_installation_step.sh &&
sudo bash /tmp/next_installation_step.sh
```
---

## 🔒 Доступ к панели только со своего IP

Ограничивает доступ к порту панели одним IPv4 и сохраняет правила firewall после перезагрузки.

```bash
sudo apt-get update && sudo apt-get install -y iptables
curl -fsSL https://raw.githubusercontent.com/canwer0/guides_x-ui/main/restrict-xui-panel-ip.sh -o /tmp/restrict-xui-panel-ip.sh
sudo bash /tmp/restrict-xui-panel-ip.sh
```

---

## 🌐 TCP REALITY + XHTTP TLS VLESSENC

Разворачивает сайт и два VLESS-подключения на общем порту **443**.

Нужны домен, открытые TCP **80/443**, **3X-UI 2.8.11 с патчем v5** и совместимый Xray — проверено на **26.7.11**.

```bash
curl -fsSL \
  "https://raw.githubusercontent.com/canwer0/guides_x-ui/main/xhttp/tcp%20reality%20-%20xhttp%20tls%20vlessenc/install.sh" \
  -o /tmp/install-xhttp-reality.sh

bash -n /tmp/install-xhttp-reality.sh &&
sudo bash /tmp/install-xhttp-reality.sh
```
