# 🛠 guides_x-ui

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

Устанавливает XHTTP patch для **3X-UI 2.8.11**.

```bash
curl -fsSL \
  'https://raw.githubusercontent.com/canwer0/guides_x-ui/main/xhttp/patch-xhttp-2.8.11.sh?v=2' \
  -o /tmp/patch-xhttp-2.8.11.sh

sudo bash /tmp/patch-xhttp-2.8.11.sh
```

---

> Скрипты предназначены для быстрого развёртывания и настройки компонентов 3X-UI.
