# Obsidian Cloud · nginx + XHTTP + TCP REALITY

Установщик сайта в стиле бесплатного хранилища для синхронизации заметок Obsidian и двух VLESS inbound на общем внешнем **TCP 443**.

## Настройки по умолчанию

| Inbound | Имя в панели | VLESS Encryption | Транспорт |
| --- | --- | --- | --- |
| XHTTP | `xhttp stream-one Vlessenc` | ML-KEM-768, Post-Quantum | `stream-one`, TLS на nginx, ALPN `h2`, пустой flow |
| TCP | `tcp reality` | ML-KEM-768, Post-Quantum | REALITY, `xtls-rprx-vision`, uTLS **Firefox** |

При установке генерируются отдельные пары `decryption`/`encryption` для каждого inbound командой `xray vlessenc`. В панели сразу выбрано `ML-KEM-768, Post-Quantum`. Публичные ссылки содержат соответствующий клиентский ключ; серверные ключи остаются на VPS. Поля XHTTP записываются непосредственно в `xhttpSettings`, чтобы панель могла редактировать и экспортировать их.

XHTTP использует параметры из [stream-one-tls-reality](https://github.com/canwer0/guides_x-ui/tree/main/xhttp/stream-one-tls-reality): padding `128-1120`, `tokenish`, заголовки `X-Amz-Meta-Trace` / `X-Amz-Security-Token`, сессия `x-amz-cf-id` с Base62 и длиной `16-32`, seq `x-amz-cf-pop`, метод `POST`. Здесь дополнительно включён VLESS Encryption по ML-KEM-768.

## Требования

- Ubuntu/Debian с systemd, доступ root.
- Установленная **3X-UI 2.8.11 с патчем XHTTP/VLESSENC v5** из [guides_x-ui](https://github.com/canwer0/guides_x-ui/tree/main/xhttp) и совместимое ядро Xray. Проверено на Xray **26.7.11** с параметрами `tokenish` и заголовками сессии из этого проекта.
- Домен с A-записью на сервер; при наличии AAAA IPv6 тоже должен вести на него. Доступные TCP 80 и 443.
- Совместимый клиент с поддержкой ML-KEM-768 VLESS Encryption и этих параметров XHTTP.

Установщик использует существующую панель. Недостающие nginx, модуль stream, certbot и системные зависимости устанавливаются через apt. Посторонний сайт или процесс, занявший 443, вызывает остановку установки с сообщением.

## Установка

Распакуйте архив на VPS и выполните:

```bash
sudo bash install.sh
```

Скрипт запросит **домен** и **название проекта**. Название появится на сайте, в форме входа и в заголовках. Если сертификат ещё не выпущен, потребуется email для Let's Encrypt. Аргументы позволяют пропустить первые два запроса:

```bash
sudo bash install.sh notes.example.org "Мой проект"
```

`install.sh` содержит HTML и Python внутри: для запуска достаточно одного этого файла. Все приватные результаты установки находятся только на VPS, в `/root/obsidian-cloud-<идентификатор>/`:

- `vless-xhttp-tls.txt` и `vless-tcp-reality.txt` — ссылки на внешний 443;
- `client-xhttp.json` и `client-reality.json` — клиентские JSON Xray с локальным SOCKS `127.0.0.1:10808`;
- `deployment.json` — состояние установки и результаты проверок.

Можно копировать публичные конфигурации прямо из панели: External Proxy задаёт домен и 443; экспорт включает ML-KEM, XHTTP extra и Firefox для REALITY. После изменения ключей импортируйте ссылки заново. Для одновременного запуска двух JSON измените локальный SOCKS-порт одного из них.

## Обновление существующего проекта

```bash
sudo bash update-config.sh notes.example.org
```

Или запустите без аргумента, чтобы ввести домен. Обновление включает ML-KEM для обоих inbound, Firefox у REALITY и короткие имена. Оно сохраняет сайт, UUID, локальные порты, путь XHTTP и ключ REALITY. **Пары ключей VLESS Encryption создаются заново**, поэтому старые ссылки перестают подходить: скопируйте новые из панели или файлов результатов.

Обновление рассчитано на существующий проект, созданный этим установщиком. Полный повторный запуск `install.sh` перестраивает управляемое развёртывание и создаёт новые клиентские параметры.

## Маршрут на одном порту

```text
Внешний TCP 443 → nginx stream → TCP REALITY на localhost
                                ├─ авторизованный REALITY/VLESS → интернет
                                └─ обычный TLS → nginx HTTPS на localhost
                                                ├─ / → сайт
                                                └─ скрытый путь → XHTTP stream-one на localhost
```

Для сайта и XHTTP TLS завершает nginx. REALITY использует локальный HTTPS nginx как `target`; обычный браузер получает страницу сайта. Оба inbound слушают только `127.0.0.1`. Порт 80 обслуживает ACME и перенаправление на HTTPS. Certbot продлевает сертификат автоматически.

## Проверка и восстановление

Перед переключением создаются резервные копии SQLite и изменяемых файлов. Панель останавливается на время транзакции и затем запускается. Скрипт проверяет синтаксис nginx, конфигурацию Xray, HTTPS с проверкой сертификата и реальную передачу 128 КиБ через **каждый профиль на 443**. При ошибке восстанавливается предыдущая конфигурация. Резервные копии остаются в `/root/obsidian-cloud-backups/`.

На время перезапуска панели прокси могут быть недоступны несколько секунд. Импорт ссылки должен сохранять параметры VLESS Encryption и XHTTP extra; при ограничениях клиента используйте полный JSON с совместимым ядром.

## Страница сайта

Адаптивный статический макет сервиса: тариф, пример кабинета, инструкция подключения, FAQ и форма входа по email. Реального хранилища и отправки писем нет. Форма показывает ввод кода, но не отправляет и не сохраняет email или код и не открывает кабинет. Проект не является официальным сервисом Obsidian.

## Файлы репозитория

```text
install.sh          самостоятельный установщик
update-config.sh    обновление параметров существующего проекта
build.py            сборка shell-скриптов из src/
src/                HTML, Python и Bash исходники
preview.html        статический пример страницы VaultSpace
SHA256SUMS          контрольные суммы файлов
CHANGELOG.md        изменения настроек
```

После изменения исходников пересоберите артефакты и контрольные суммы:

```bash
python3 build.py
bash -n install.sh
bash -n update-config.sh
sha256sum -c SHA256SUMS
```

В архиве нет адреса VPS, паролей, выданных клиентских профилей, базы панели или ключей. Каждый запуск создаёт параметры на целевом сервере.

Справка: [генератор VLESS Encryption в Xray](https://github.com/XTLS/Xray-core/blob/main/main/commands/all/vlessenc.go), [REALITY target](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transports/reality.md), [nginx stream](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html).
