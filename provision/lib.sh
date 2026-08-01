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

# ---------------------------------------------------------------------------
# Внутренние адреса
# ---------------------------------------------------------------------------
# Адреса выше (RADARR, SONARR, …) — для нас, снаружи. В КОНФИГУРАЦИЮ сервисов
# идут эти: сервисы обращаются друг к другу внутри compose-сети, и localhost
# там указывает на сам контейнер. Prowlarr с baseUrl=http://localhost:7878
# стучался бы в самого себя.
RADARR_INTERNAL="http://radarr:7878"
SONARR_INTERNAL="http://sonarr:8989"
PROWLARR_INTERNAL="http://prowlarr:9696"
QBT_INTERNAL_HOST="qbittorrent"
QBT_INTERNAL_PORT=8081

# ---------------------------------------------------------------------------
# Работа со схемами живых инстансов
# ---------------------------------------------------------------------------
# Имена полей у *arr не воспроизводятся по памяти и менялись между версиями.
# Эндпоинты /schema отдаёт сам работающий инстанс, поэтому расхождение версий
# здесь невозможно по построению — в отличие от схемы, скачанной из main-ветки
# проекта. Это тот же путь, что описан в комментариях скриптов («забрать
# готовый объект через GET …»), только без ручной настройки через веб-морду.

# schema_object <base> <key> <api> <путь> <implementation>
schema_object() {
  arr_get "$1" "$2" "$3" "$4" | jq --arg i "$5" '.[] | select(.implementation==$i)' \
    || die "не удалось получить схему $5 с $1$4"
}

# set_field <json> <имя-поля> <значение-как-json>
# Правит значение внутри массива fields, не трогая остальное.
set_field() {
  echo "$1" | jq --arg n "$2" --argjson v "$3" \
    'if any(.fields[]; .name==$n) then (.fields[] | select(.name==$n) | .value) = $v
     else error("нет поля \($n) в схеме — СТОП-УСЛОВИЕ №1") end'
}

# ---------------------------------------------------------------------------
# Схема имён
# ---------------------------------------------------------------------------
# naming_value <Radarr|Sonarr> <ключ> — достаёт строку из блока
# «Строки конфигурации» в docs/NAMING.md. Единственный источник: держать копию
# строк ещё и в скриптах значит завести второе место, которое разъедется.
naming_value() {
  awk -v app="$1" -v key="$2" '
    /^## / { in_cfg = ($0 ~ /Строки конфигурации/); next }
    !in_cfg { next }
    /^### / { cur = $2; next }
    cur != app { next }
    match($0, /^[ \t]*[A-Za-z]+[ \t]*=/) {
      k = $0; sub(/[ \t]*=.*$/, "", k); gsub(/[ \t]/, "", k)
      if (k == key) { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }
    }
  ' "$ROOT/docs/NAMING.md"
}

# apply_naming <Radarr|Sonarr> <base> <key> <api> <поле> [<поле> …]
# Читает значения из NAMING.md, накладывает на текущий объект /config/naming
# и записывает обратно. GET-правка-PUT, а не сборка объекта с нуля: так
# незатронутые поля остаются такими, какими их поставила эта версия.
apply_naming() {
  local app="$1" base="$2" key="$3" api="$4"; shift 4
  local cur patched k v
  cur="$(arr_get "$base" "$key" "$api" /config/naming)" \
    || die "$app: не удалось прочитать /config/naming"
  patched="$cur"

  for k in "$@"; do
    v="$(naming_value "$app" "$k")"
    [ -n "$v" ] || die "в docs/NAMING.md нет значения для $k ($app)"

    # Строки вида «не трогаем, остаётся …» — осознанное решение оставить
    # значение по умолчанию, а не пропущенная строка.
    case "$v" in
      "не трогаем"*) log "$k — оставлено по умолчанию, так записано в NAMING.md"; continue ;;
    esac

    echo "$cur" | jq -e --arg k "$k" 'has($k)' >/dev/null \
      || die "$app: поля $k нет в /config/naming этой версии. СТОП-УСЛОВИЕ №1."

    case "$v" in
      true|false) patched="$(echo "$patched" | jq --arg k "$k" --argjson v "$v" '.[$k] = $v')" ;;
      *)          patched="$(echo "$patched" | jq --arg k "$k" --arg  v "$v" '.[$k] = $v')" ;;
    esac
    log "$k = $v"
  done

  arr_put "$base" "$key" "$api" \
    "/config/naming/$(echo "$cur" | jq -r .id)" "$patched" >/dev/null \
    || die "$app отказал при записи схемы имён"
}
