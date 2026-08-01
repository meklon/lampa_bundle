#!/usr/bin/env bash
# Общие функции для provision-скриптов.
#
# Все provision-скрипты обязаны быть ИДЕМПОТЕНТНЫМИ: повторный запуск на уже
# настроенном стеке не создаёт дубликатов и не падает.
#
# Причина существования этих скриптов: конфигурация *arr живёт в SQLite
# внутри config/-томов, который в git не попадает. Настроенное руками через
# веб-морду не видно в PR, стирается откатом снапшота ВМ и не воспроизводится
# на сервере.
#
# Файл только подключается, сам не запускается: адреса и функции ниже
# потребляются provision-скриптами.
# shellcheck disable=SC2034

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

RADARR="http://localhost:7878"
SONARR="http://localhost:8989"
PROWLARR="http://localhost:9696"
QBT="http://localhost:8081"

log()  { printf '     %s\n' "$*"; }
step() { printf '==>  %s\n' "$*"; }
die()  { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "нужна утилита $1"
}
need curl
need jq

# arr_get <base> <key> <api> <path>
arr_get() {
  curl -fsS -H "X-Api-Key: $2" "$1/api/$3$4"
}

# arr_post <base> <key> <api> <path> <json>
arr_post() {
  curl -fsS -X POST -H "X-Api-Key: $2" -H 'Content-Type: application/json' \
    -d "$5" "$1/api/$3$4"
}

# arr_put <base> <key> <api> <path> <json>
arr_put() {
  curl -fsS -X PUT -H "X-Api-Key: $2" -H 'Content-Type: application/json' \
    -d "$5" "$1/api/$3$4"
}

# wait_api <base> <key> <api> — ждём готовности сервиса
wait_api() {
  local base="$1" key="$2" api="$3"
  for _ in $(seq 1 60); do
    if curl -fsS -H "X-Api-Key: $key" "$base/api/$api/system/status" \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "$base не отвечает после 120 с"
}

# qbt_login — печатает путь к cookie-файлу
QBT_COOKIE="${TMPDIR:-/tmp}/qbt.cookie"

# WebUI qBittorrent 5.x отбивает запросы без Referer, совпадающего с адресом
# интерфейса: 403 на любой вызов, включая GET и сам логин. Проверено на
# 5.2.3: без заголовка — 403, с ним — 204 на /auth/login. Поэтому Referer
# идёт в каждый вызов, а не только в POST.
qbt_login() {
  : "${QBITTORRENT_USER:?не задан QBITTORRENT_USER}"
  : "${QBITTORRENT_PASSWORD:?не задан QBITTORRENT_PASSWORD}"
  curl -fsS -c "$QBT_COOKIE" -H "Referer: $QBT" \
    --data-urlencode "username=$QBITTORRENT_USER" \
    --data-urlencode "password=$QBITTORRENT_PASSWORD" \
    "$QBT/api/v2/auth/login" >/dev/null \
    || die "не удалось войти в qBittorrent. Временный пароль первого запуска: docker compose logs qbittorrent"
  echo "$QBT_COOKIE"
}

qbt_get() {
  curl -fsS -b "$QBT_COOKIE" -H "Referer: $QBT" "$QBT/api/v2$1" "${@:2}"
}

qbt_post() {
  curl -fsS -b "$QBT_COOKIE" -H "Referer: $QBT" -X POST "$QBT/api/v2$1" "${@:2}"
}
