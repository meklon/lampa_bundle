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
# СТОП: точная форма полезной нагрузки для POST /api/v1/applications
# не воспроизводится по памяти.
#
# Структура включает implementation, configContract и массив fields
# (baseUrl, apiKey, prowlarrUrl, syncLevel и др.), имена и состав которых
# менялись между версиями Prowlarr.
#
# Порядок действий:
#   1. Взять схему из openapi/prowlarr-v1-*.json, объект ApplicationResource
#   2. Либо: настроить одно приложение через веб-морду, затем забрать
#      готовый объект через GET /api/v1/applications и использовать как шаблон
#   3. Заполнить функцию ensure_app ниже и убрать этот блок
#
# Не подставлять имена полей «по смыслу» — стоп-условие №1.
# ---------------------------------------------------------------------------

ensure_app() {
  local name="$1"
  if echo "$APPS" | jq -e --arg n "$name" '.[] | select(.name==$n)' >/dev/null; then
    log "$name уже зарегистрирован — пропускаю"
    return 0
  fi
  die "ensure_app не реализован для $name. См. комментарий выше: возьми
     форму объекта из openapi/prowlarr-v1-*.json или из GET /applications
     после ручной настройки одного приложения. Стоп-условие №1."
}

step "Prowlarr: Radarr"
ensure_app "Radarr"

step "Prowlarr: Sonarr"
ensure_app "Sonarr"

step "Prowlarr: проверка соединений"
if arr_post "$PROWLARR" "$PROWLARR_API_KEY" v1 /applications/testall '{}' >/dev/null; then
  log "testall прошёл"
else
  die "testall не прошёл"
fi

log "готово. Индексаторы добавляет человек, вручную, на последнем этапе."
