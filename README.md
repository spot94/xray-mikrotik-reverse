# Xray-Core Bridge для Mikrotik

Контейнер с Xray-Core для Mikrotik RouterOS 7.x (arm64): проксирование локального трафика (TUN + опционально SOCKS5) и **reverse bridge** — публикация локальных сервисов наружу без проброса портов.

## Архитектура

Контейнер (**bridge**) решает две независимые задачи — можно использовать любую из них или обе.

**1. Forward proxy** — трафик локальной сети уходит в интернет через VPN. Источник — TUN/SOCKS5 (inbound'ы контейнера):

```
[устройства LAN] ─► Mikrotik ─► TUN / SOCKS5 ─────► proxy ─────► [Интернет]
                                (inbound)        VLESS → сервер SRV
```

**2. Reverse** — локальные сервисы доступны снаружи без проброса портов. Трафик идёт с портала В bridge и дальше В локальные сервисы:

```
[Интернет] ─► Portal (VPS) ══ reverse-туннель ══► bridge ─► [локальный сервис]
              вход, сервер RSRV                  (Mikrotik)   напр. 192.0.2.10:80
```

## Переменные окружения

| Переменная | Обязательная | Описание |
|------------|-------------|----------|
| `SUB` | SUB или SRV | Ссылка на подписку 3X-UI (base64-список `vless://`) |
| `SRV` | SUB или SRV | Одиночная ссылка `vless://...` |
| `SERVER_INDEX` | Нет | Индекс сервера из подписки (по умолчанию `0`) |
| `RSUB` | Нет | Подписка для reverse-туннеля |
| `RSRV` | Нет | Одиночная ссылка `vless://...` для reverse |
| `REVERSE_SERVICES` | Если reverse | Публикуемые сервисы. Три формы (см. ниже): `name:destPort:ip:port` — мультисервис; `name:ip:port` — один сервис; `name:cidr[:порты]` — подсеть с маршрутизацией на портале |
| `SOCKS_PORT` | Нет | Порт SOCKS5 (если не задан — SOCKS выключен) |
| `SOCKS_USER` | Нет | Пользователь SOCKS5 (только с SOCKS_PORT) |
| `SOCKS_PASSWORD` | Нет | Пароль SOCKS5 (только с SOCKS_PORT) |
| `LOG_LEVEL` | Нет | Уровень логов Xray: `debug`/`info`/`warning`/`error` (по умолчанию `warning`). Логи идут в stdout контейнера (на Mikrotik — `logging=yes`), файлов на флеше не создаётся |
| `ACCESS_LOG` | Нет | `1`/`true` — включить access-лог Xray (строка на каждое соединение, в stdout). По умолчанию выключен |
| `DNS_SERVERS` | Нет | DNS-серверы через запятую. Если не задан — используется DNS самого контейнера (системный резолвер `/etc/resolv.conf`, задаётся настройками контейнера). Плоские IP-серверы из этого списка резолвятся напрямую, минуя туннель |
| `EXCLUDE_ROUTES` | Нет | Доп. маршруты (IP/CIDR через запятую), которые нужно исключить из TUN-туннеля (split tunneling) — пойдут через физический шлюз, минуя прокси. Напр. `1.1.1.1,192.0.2.0/24`. Дополняет исключения по умолчанию (сервер, DNS, приватные диапазоны) |

## Формат REVERSE_SERVICES

Три формы записи (несколько записей — через запятую). `name` во всех формах — имя, из которого получается tag outbound'а `to-<name>`.

### 1. Мультисервис — по порту: `name:destPort:ip:port`

```bash
REVERSE_SERVICES="web:443:192.0.2.10:80,ssh:2222:192.0.2.10:22"
```

Bridge различает сервисы по `destPort` (порт, который закодировал портал в `tunnel`-инбаунде), freedom-outbound делает `redirect` на `ip:port`. **Единственная форма, которую можно комбинировать** (несколько записей через запятую).

### 2. Один сервис — без destPort: `name:ip:port`

```bash
REVERSE_SERVICES="web:192.0.2.10:80"
```

Весь reverse-трафик уходит в один сервис (catch-all, `redirect ip:port`). destPort не нужен. Только одна запись.

### 3. Подсеть — маршрутизация на портале: `name:cidr[:порты]`

```bash
REVERSE_SERVICES="lan:192.0.2.0/24"              # любые TCP-порты в подсети
REVERSE_SERVICES="lan:192.0.2.0/24:80;443;3000"  # только эти порты
REVERSE_SERVICES="lan:192.0.2.0/24:8000-9000"    # диапазон портов
```

Freedom-outbound **без `redirect`**: пересылает на адрес назначения, который задал портал (в `tunnel`-инбаунде через rewrite/portMap), а `finalRules` ограничивают выход подсетью и — опционально — портами. Конкретную per-сервис маршрутизацию делаешь на **портале**. Порты в списке разделяются `;` (запятая занята под разделитель записей), диапазон — через `-`. Только одна запись.

## Inbound'ы

- **TUN** — всегда включен. Mikrotik направляет нужный трафик в контейнер через VETH (см. пример mangle/route ниже), контейнер прозрачно заворачивает его в туннель.
- **SOCKS5** — опционально, если задан `SOCKS_PORT`. Поддерживает аутентификацию.

### Как работает TUN (прозрачный проксимаршрут)

При старте контейнер сам настраивает маршрутизацию, чтобы трафик реально попадал в `tun0`, **не зацикливая** собственный зашифрованный аплинк:

1. собственный трафик Xray не должен попасть в `tun0` — иначе он уйдёт туда снова и всё ляжет петлёй. Все сокеты Xray помечаются (`sockopt.mark` = 255), и правило `ip rule fwmark 255 → table 101` отправляет их через физический шлюз **при любом IP назначения** — смена IP сервера (DNS, CDN, round-robin) петлю не вызовет. Дополнительно (и как запасной вариант, если policy routing недоступен) IP сервера/портала и DNS-серверов — из `/etc/resolv.conf` и `DNS_SERVERS` — исключаются статически;
2. приватные диапазоны (`10/8`, `172.16/12`, `192.168/16`) тоже исключаются — иначе перехват «съедает» обратку к LAN-клиентам (ответ SOCKS/TUN) и доставку reverse в локальные сервисы; в туннель идёт только публичный трафик;
3. дополнительные маршруты из `EXCLUDE_ROUTES` (если задан) исключаются так же — удобно для split tunneling (например, отдать какой-то сервис в обход прокси);
4. остальное заворачивается в `tun0` через `0.0.0.0/1` + `128.0.0.0/1` (более специфичны, чем default — побеждают, не удаляя его).

Логика **всё-или-ничего**: при любой проблеме (нет `tun0`, не удалось включить `ip_forward`, не резолвится хост) маршруты **не трогаются вообще** — SOCKS5 и reverse продолжают работать, а TUN просто остаётся неактивным. В логе будет `TUN routing active ...` при успехе либо `TUN transparent proxy inactive` при деградации. В строке `TUN routing active` видно `xray fwmark bypass: on|off` — `off` значит, что policy routing недоступен и работает только статическое исключение IP.

> **Требование:** контейнеру нужен `ip_forward=1` (форвардит трафик LAN в `tun0`). Контейнер выставляет его сам; на Mikrotik с обычными правами контейнера это проходит. Если среда запрещает запись в `/proc/sys` и значение осталось `0` — TUN не активируется (SOCKS/reverse не затрагиваются).

## Сборка

```bash
# Для Mikrotik hAP ax²/ax³ (arm64)
docker buildx build --platform linux/arm64 -t xray-mikrotik:arm64 .

# Для 32-битных ARM (hAP ac², RB4011 и т.п.)
docker buildx build --platform linux/arm/v7 -t xray-mikrotik:armv7 .

# Экспорт для Mikrotik Container
docker save xray-mikrotik:arm64 > xray-mikrotik.tar
```

## Запуск на Mikrotik

```mikrotik
# Источник образа — выбери один (используется в блоке "Добавить контейнер" ниже):
#   A) GHCR (опционально): публичный пакет тянется без авторизации
/container/config/set registry-url=https://ghcr.io tmpdir=disk1/pull
#      для приватного пакета добавь: username=<github-логин> password=<PAT c read:packages>
#   B) локальный .tar: docker save xray-mikrotik:arm64 > xray-mikrotik.tar,
#      затем загрузи файл на роутер (например в disk1/)

# Создать VETH интерфейс
/interface/veth/add name=veth-xray address=172.17.0.2/24 gateway=172.17.0.1

# Настроить переменные окружения
/container/envs/add name=xray-env \
  key=SRV value="vless://uuid@example.com:443?type=xhttp&security=reality&..."
/container/envs/add name=xray-env \
  key=RSRV value="vless://uuid@portal.example.com:443?type=xhttp&security=reality&..."
/container/envs/add name=xray-env \
  key=REVERSE_SERVICES value="web:443:192.0.2.10:80,ssh:2222:192.0.2.10:22"
/container/envs/add name=xray-env key=SOCKS_PORT value="1080"

# Добавить контейнер — источник образа согласно выбору выше:
#   A) из GHCR (можно и :latest, и пин версии Xray, напр. :26.10.31):
/container/add \
  remote-image=<owner>/xray-mikrotik:latest \
  interface=veth-xray \
  root-dir=disk1/xray \
  envlist=xray-env \
  logging=yes
#   B) из локального .tar:
# /container/add \
#   file=disk1/xray-mikrotik.tar \
#   interface=veth-xray root-dir=disk1/xray envlist=xray-env logging=yes
# logging=yes выводит логи контейнера (entrypoint + Xray) в /log роутера

# Маршрутизация трафика в контейнер (пример)
/ip/route/add dst-address=0.0.0.0/0 gateway=172.17.0.2 routing-mark=via-xray
/ip/firewall/mangle/add chain=prerouting action=mark-routing new-routing-mark=via-xray \
  src-address=192.0.2.0/24
```

## Настройка Portal (VPS)

### 1. 3X-UI/Xray — VLESS inbound на 443

```json
{
  "inbounds": [
    {
      "tag": "vless-in",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "uuid-bridge",
            "reverse": { "tag": "to-bridge" }
          },
          {
            "id": "uuid-clients",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          { "dest": "127.0.0.1:8443" }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "127.0.0.1:8443",
          "serverNames": ["panel.example.com"],
          "privateKey": "...",
          "shortIds": ["1234"]
        }
      }
    }
  ]
}
```

### 2. Tunnel inbound для reverse-трафика

```json
{
  "inbounds": [
    {
      "tag": "tunnel-in",
      "listen": "127.0.0.1",
      "port": "10080,10081",
      "protocol": "tunnel",
      "settings": {
        "allowedNetwork": "tcp",
        "portMap": {
          "10080": "127.0.0.1:443",
          "10081": "127.0.0.1:2222"
        }
      }
    }
  ]
}
```

### 3. Routing на Portal

```json
{
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["tunnel-in"],
        "outboundTag": "to-bridge"
      }
    ]
  }
}
```

> **Важно:** `to-bridge` — это **виртуальный** outbound, который Xray создаёт автоматически из `reverse.tag` клиента (см. п.1). **Не объявляй его как `freedom`** — иначе трафик уйдёт в freedom вместо reverse-туннеля (портал будет писать `non existing outTag`, пока мост не подключится). Реальным должен остаться только `direct` как placeholder.

### 4. Traefik (TLS passthrough) — опционально

Нужен, только если хочешь мультиплексировать несколько доменов через один порт `443` на портале (SNI-роутинг). Если сервис отдаётся на отдельном порту (как `tunnel`-инбаунд выше) — Traefik не нужен.

```yaml
tcp:
  routers:
    reverse-https:
      rule: "HostSNI(`panel.example.com`)"
      service: xray-tunnel-443
      tls:
        passthrough: true
    
    reverse-ssh:
      rule: "HostSNI(`*`)"
      service: xray-tunnel-2222
      entryPoints:
        - "ssh"
  
  services:
    xray-tunnel-443:
      loadBalancer:
        servers:
          - address: "127.0.0.1:10080"
    
    xray-tunnel-2222:
      loadBalancer:
        servers:
          - address: "127.0.0.1:10081"
  
  entryPoints:
    ssh:
      address: ":2222"
```

## Bridge routing

Сгенерированный конфиг будет содержать:

```json
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["from-portal"],
        "port": "443",
        "outboundTag": "to-web"
      },
      {
        "type": "field",
        "inboundTag": ["from-portal"],
        "port": "2222",
        "outboundTag": "to-ssh"
      },
      {
        "type": "field",
        "inboundTag": ["socks-in", "tun-in"],
        "outboundTag": "proxy"
      }
    ]
  }
}
```

## Локальный тест

```bash
# Без reverse
docker run -d --name xray \
  -e SRV="vless://..." \
  -e SOCKS_PORT=1080 \
  xray-mikrotik

# С reverse
docker run -d --name xray \
  -e SRV="vless://..." \
  -e RSRV="vless://..." \
  -e REVERSE_SERVICES="web:443:192.0.2.10:80,ssh:2222:192.0.2.10:22" \
  -e SOCKS_PORT=1080 \
  -e SOCKS_USER=admin \
  -e SOCKS_PASSWORD=secret \
  xray-mikrotik
```

## Поддерживаемые параметры vless://

- `type` — `xhttp` (splithttp), `ws`, `grpc`, `tcp`
- `security` — `reality`, `tls`, `none`
- `sni` / `serverName` — SNI
- `pbk` / `publicKey` — публичный ключ Reality
- `sid` / `shortId` — short ID Reality
- `fp` / `fingerprint` — `chrome`, `firefox`, `safari`, `ios`, `edge`
- `path` — путь (xhttp, ws, grpc)
- `host` — хост-заголовок
- `flow` — `xtls-rprx-vision`
- `mode` — режим xhttp: `auto`, `packet-up`, `stream-up`
- `spx` / `spiderX` — spiderX для Reality
- `extra` — дополнительные настройки xhttp (URL-encoded JSON)
- `fm` / `finalmask` — маска обфускации Salamander/XICMP (URL-encoded JSON)
