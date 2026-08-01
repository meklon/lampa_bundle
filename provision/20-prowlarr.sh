#!/usr/bin/env bash
# Prowlarr: регистрация приложений (Radarr, Sonarr).
#
# НАПРАВЛЕНИЕ ВАЖНО: Prowlarr сам ПИШЕТ индексаторы в Radarr и Sonarr.
# Обратное — создание индексаторов вручную в Radarr — запрещено, см.
# таблицу запрещённых подмен в CLAUDE.md.
#
# ИНДЕКСАТОРЫ ЭТИМ СКРИПТОМ НЕ ДОБАВЛЯЮТСЯ. Их добавляет человек, вручную,
# на последнем этапе. Причина: раздача — самое недетерминированное звено
# цепочки, а приватные трекеры банят за поток запросов из отладочного цикла.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${PROWLARR_API_KEY:?не задан PROWLARR_API_KEY}"
: "${RADARR_API_KEY:?не задан RADARR_API_KEY}"
: "${SONARR_API_KEY:?не задан SONARR_API_KEY}"

wait_api "$PROWLARR" "$PROWLARR_API_KEY" v1

step "Prowlarr: список зарегистрированных приложений"
APPS="$(arr_get "$PROWLARR" "$PROWLARR_API_KEY" v1 /applications)"
echo "$APPS" | jq -r '.[] | "     есть: \(.name) (\(.implementation))"'

# ---------------------------------------------------------------------------
# Форма объекта берётся из GET /api/v1/applications/schema самого Prowlarr:
# оттуда приходит готовый шаблон с implementation, configContract, syncLevel
# и полным массивом fields. Правим в нём только адреса и ключ, остального не
# касаемся — состав полей и категории синхронизации остаются такими, какими их
# считает правильными эта версия Prowlarr.
#
# Адреса — внутренние, по именам сервисов compose-сети. Значения по умолчанию
# в схеме указывают на localhost, а внутри контейнера Prowlarr это он сам.
# ---------------------------------------------------------------------------

# ensure_app <имя> <внутренний-адрес> <ключ-api>
ensure_app() {
  local name="$1" base="$2" key="$3" obj
  if echo "$APPS" | jq -e --arg n "$name" '.[] | select(.name==$n)' >/dev/null; then
    log "$name уже зарегистрирован — пропускаю"
    return 0
  fi

  obj="$(schema_object "$PROWLARR" "$PROWLARR_API_KEY" v1 /applications/schema "$name")"
  [ -n "$obj" ] || die "в /applications/schema нет реализации $name. Стоп-условие №1."

  obj="$(set_field "$obj" prowlarrUrl "$(jq -n --arg v "$PROWLARR_INTERNAL" '$v')")"
  obj="$(set_field "$obj" baseUrl     "$(jq -n --arg v "$base" '$v')")"
  obj="$(set_field "$obj" apiKey      "$(jq -n --arg v "$key"  '$v')")"
  obj="$(echo "$obj" | jq --arg n "$name" '.name = $n')"

  log "регистрирую $name -> $base"
  arr_post "$PROWLARR" "$PROWLARR_API_KEY" v1 /applications "$obj" >/dev/null \
    || die "Prowlarr отказал при регистрации $name"
}

step "Prowlarr: Radarr"
ensure_app "Radarr" "$RADARR_INTERNAL" "$RADARR_API_KEY"

step "Prowlarr: Sonarr"
ensure_app "Sonarr" "$SONARR_INTERNAL" "$SONARR_API_KEY"

step "Prowlarr: проверка соединений"
if arr_post "$PROWLARR" "$PROWLARR_API_KEY" v1 /applications/testall '{}' >/dev/null; then
  log "testall прошёл"
else
  die "testall не прошёл"
fi

log "готово. Индексаторы добавляет человек, вручную, на последнем этапе."
