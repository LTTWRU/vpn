# VPN Service — VLESS Reality + 3x-ui + Dynamic Subscriptions

Сервис масштабируется до 1000+ пользователей. Каждый пользователь получает личную ссылку-подписку, которая автоматически обновляется при смене IP сервера.

## Архитектура

```
Пользователь
  │
  ├─ VPN-трафик ──► порт 443 (VLESS Reality, напрямую в 3x-ui)
  │
  └─ Подписка ─────► порт 80 (Nginx) ──► Subscription Service (8000)
                                                  │
                                                  └──► 3x-ui API (2053, внутренняя сеть)

Администратор
  └─ SSH-туннель ──► порт 2053 (панель 3x-ui, только localhost)
                     порт 8000 (admin API,   только localhost)
```

| Контейнер      | Образ                          | Назначение                       |
|----------------|--------------------------------|----------------------------------|
| `3xui`         | ghcr.io/mhsanaei/3x-ui:latest  | Xray-ядро + веб-панель           |
| `subscription` | (собственный, FastAPI)         | Выдача динамических подписок     |
| `nginx`        | nginx:alpine                   | Публичный прокси для подписок    |

---

## Быстрый старт

### 1. Клонировать репозиторий на VPS

```bash
git clone https://github.com/lttwru/vpn.git
cd vpn
```

### 2. Установка (нужен root)

```bash
sudo bash scripts/install.sh
```

Первый запуск создаёт `.env` с рандомными паролями и просит задать `SERVER_DOMAIN`:

```bash
nano .env            # Установить SERVER_DOMAIN=ВАШ_IP_ИЛИ_ДОМЕН
sudo bash scripts/install.sh   # Запустить второй раз
```

### 3. Сгенерировать ключи Reality

```bash
bash scripts/generate-keys.sh
```

Сохраните **Private Key** и **Public Key** — они нужны при создании inbound.

### 4. Создать inbound в 3x-ui

Открыть панель через SSH-туннель:

```bash
ssh -L 2053:127.0.0.1:2053 user@YOUR_SERVER
# В браузере: http://127.0.0.1:2053
# Логин / пароль — из .env (XUI_USERNAME / XUI_PASSWORD)
```

В панели: **Inbounds → Add Inbound**

| Поле              | Значение                          |
|-------------------|-----------------------------------|
| Protocol          | VLESS                             |
| Port              | 443                               |
| Network           | TCP                               |
| Security          | Reality                           |
| Dest (SNI target) | `apple.com:443`                   |
| Server Names      | `apple.com`, `www.apple.com`      |
| Private Key       | из `generate-keys.sh`             |
| Short ID          | любая hex-строка 8–16 символов    |
| Client Flow       | `xtls-rprx-vision`                |

> ID inbound'а (обычно `1`) должен совпадать с `INBOUND_ID` в `.env`.

---

## Управление пользователями

### Добавить пользователя

```bash
bash scripts/add-user.sh ivan@example.com
```

Вывод:
```
========================================
  User added successfully
  Email        : ivan@example.com
  UUID         : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  Subscription : http://YOUR_SERVER/sub/abc123...
========================================
```

Ссылку-подписку нужно передать пользователю. Он добавляет её в VPN-клиент.

### Список пользователей

```bash
bash scripts/list-users.sh
```

### Удалить / заблокировать пользователя

```bash
bash scripts/remove-user.sh ivan@example.com
```

---

## Смена IP / домена сервера

```bash
bash scripts/update-server.sh NEW_IP_OR_DOMAIN
```

Пользователям ничего делать не нужно — при следующем автообновлении подписки их клиенты получат новый адрес.

---

## Рекомендуемые VPN-клиенты (для пользователей)

| Платформа | Клиент |
|-----------|--------|
| Windows   | [v2rayN](https://github.com/2dust/v2rayN) |
| Android   | [v2rayNG](https://github.com/2dust/v2rayNG) / [Hiddify](https://hiddify.com) |
| iOS / macOS | [Streisand](https://apps.apple.com/app/streisand/id6450534064) / [Sing-Box](https://apps.apple.com/app/sing-box/id6451272673) |
| Linux     | [Nekoray](https://github.com/MatsuriDayo/nekoray) |

В клиенте: добавить подписку → вставить ссылку → обновить.

---

## Масштабирование (до 1000 пользователей)

- 3x-ui + Xray легко держат 1000 одновременных подключений на VPS с **2 vCPU / 4 GB RAM**.
- Subscription service и SQLite без проблем работают с 1000+ пользователями.
- Для роста свыше 1000: добавьте несколько VPS с 3x-ui и зарегистрируйте оба inbound'а под одним email — subscription service вернёт все ссылки в одной подписке.

---

## Ограничение 1 устройство

Параметр `limitIp: 1` в 3x-ui ограничивает одновременное использование одним IP. Пользователь может переключаться между устройствами, но не пользоваться двумя одновременно.

---

## Порты

| Порт | Доступность   | Назначение                  |
|------|---------------|-----------------------------||
| 443  | Публичный     | VLESS Reality трафик        |
| 80   | Публичный     | Nginx → подписки            |
| 2053 | Только localhost | 3x-ui панель              |
| 8000 | Только localhost | Subscription admin API    |

---

## Структура проекта

```
vpn/
├── docker-compose.yml
├── .env.example
├── nginx/
│   └── nginx.conf
├── subscription/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── main.py
└── scripts/
    ├── install.sh
    ├── generate-keys.sh
    ├── add-user.sh
    ├── remove-user.sh
    ├── update-server.sh
    └── list-users.sh
```
