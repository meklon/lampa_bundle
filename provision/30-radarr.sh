#!/usr/bin/env bash
# Radarr: клиент загрузки, root folders, жёсткие ссылки, метаданные, имена.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${RADARR_API_KEY:?не задан RADARR_API_KEY}"
: "${RADARR_ROOT:?не задан RADARR_ROOT}"
: "${TEST_RADARR_ROOT:?не задан TEST_RADARR_ROOT}"

wait_api "$RADARR" "$RADARR_API_KEY" v3

# ---------------------------------------------------------------------------
step "Radarr: root folders"
# ---------------------------------------------------------------------------
FOLDERS="$(arr_get "$RADARR" "$RADARR_API_KEY" v3 /rootfolder)"
ensure_root() {
  local path="$1"
  if echo "$FOLDERS" | jq -e --arg p "$path" '.[] | select(.path==$p)' >/dev/null; then
    log "root folder $path уже есть"
  else
    log "создаю root folder $path"
    arr_post "$RADARR" "$RADARR_API_KEY" v3 /rootfolder \
      "$(jq -n --arg p "$path" '{path:$p}')" >/dev/null
  fi
}
ensure_root "$RADARR_ROOT"
ensure_root "$TEST_RADARR_ROOT"

# ---------------------------------------------------------------------------
step "Radarr: жёсткие ссылки вместо копирования"
# ---------------------------------------------------------------------------
# Это ключевая настройка всего стека. Когда ссылка невозможна, Radarr МОЛЧА
# копирует — ошибки нет, узнаёшь через месяц по свободному месту.
# Проверяется отдельно: checks/04-hardlink.sh
MEDIAMGMT="$(arr_get "$RADARR" "$RADARR_API_KEY" v3 /config/mediamanagement)"
PATCHED="$(echo "$MEDIAMGMT" | jq '.copyUsingHardlinks = true | .importExtraFiles = false')"
arr_put "$RADARR" "$RADARR_API_KEY" v3 \
  "/config/mediamanagement/$(echo "$MEDIAMGMT" | jq -r .id)" "$PATCHED" >/dev/null
log "copyUsingHardlinks = true"

# ---------------------------------------------------------------------------
step "Radarr: writer'ы метаданных выключены"
# ---------------------------------------------------------------------------
# NFO от *arr — известный способ испортить базу Kodi. Метаданные пишет
# только скрапер Kodi; имена файлов к моменту скрапинга уже каноничные.
arr_get "$RADARR" "$RADARR_API_KEY" v3 /metadata | jq -c '.[]' | while read -r m; do
  NAME="$(echo "$m" | jq -r .name)"
  if [ "$(echo "$m" | jq -r .enable)" = "true" ]; then
    log "выключаю $NAME"
    arr_put "$RADARR" "$RADARR_API_KEY" v3 \
      "/metadata/$(echo "$m" | jq -r .id)" \
      "$(echo "$m" | jq '.enable = false')" >/dev/null
  else
    log "$NAME уже выключен"
  fi
done

# ---------------------------------------------------------------------------
step "Radarr: клиент загрузки"
# ---------------------------------------------------------------------------
CLIENTS="$(arr_get "$RADARR" "$RADARR_API_KEY" v3 /downloadclient)"
if echo "$CLIENTS" | jq -e '.[] | select(.implementation=="QBittorrent")' >/dev/null; then
  log "qBittorrent уже настроен"
else
  # -------------------------------------------------------------------------
  # СТОП: точная форма DownloadClientResource не воспроизводится по памяти.
  # Объект содержит implementation, configContract и массив fields
  # (host, port, useSsl, username, password, movieCategory и др.),
  # состав которых менялся между версиями.
  #
  # Порядок: взять схему из openapi/radarr-v3-*.json (DownloadClientResource),
  # либо настроить клиент через веб-морду и забрать готовый объект через
  # GET /api/v3/downloadclient как шаблон.
  #
  # Категория обязана быть "radarr" — она же задана в 10-qbittorrent.sh.
  # Не подставлять имена полей «по смыслу» — стоп-условие №1.
  # -------------------------------------------------------------------------
  die "клиент загрузки не настроен и форма запроса не заполнена.
     См. комментарий выше. Стоп-условие №1."
fi

# ---------------------------------------------------------------------------
step "Radarr: схема переименования"
# ---------------------------------------------------------------------------
# Строки токенов берутся из docs/NAMING.md. По памяти они НЕ
# воспроизводятся: менялись между версиями, а ошибка тихо приводит к
# неправильным именам во всей библиотеке.
if ! grep -qE '^standardMovieFormat\s*=\s*\S' "$ROOT/docs/NAMING.md"; then
  die "docs/NAMING.md не заполнен: нет standardMovieFormat.
     Возьми рекомендованные строки из TRaSH Guides либо настрой схему
     в веб-морде и скопируй из GET /api/v3/config/naming."
fi
log "NAMING.md заполнен — применяю (реализовать чтение и PUT /config/naming)"

log "готово"
