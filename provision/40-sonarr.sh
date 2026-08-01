#!/usr/bin/env bash
# Sonarr: клиент загрузки, root folders, жёсткие ссылки, метаданные, имена.
#
# Отличие от Radarr: папки сезонов обязательны, и на каждом ДОБАВЛЯЕМОМ
# сериале bridge выставляет monitorNewItems="none". Последнее делается
# не здесь, а в bridge — глобальной настройки для этого поля не существует.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${SONARR_API_KEY:?не задан SONARR_API_KEY}"
: "${SONARR_ROOT:?не задан SONARR_ROOT}"
: "${TEST_SONARR_ROOT:?не задан TEST_SONARR_ROOT}"

wait_api "$SONARR" "$SONARR_API_KEY" v3

# ---------------------------------------------------------------------------
step "Sonarr: root folders"
# ---------------------------------------------------------------------------
FOLDERS="$(arr_get "$SONARR" "$SONARR_API_KEY" v3 /rootfolder)"
ensure_root() {
  local path="$1"
  if echo "$FOLDERS" | jq -e --arg p "$path" '.[] | select(.path==$p)' >/dev/null; then
    log "root folder $path уже есть"
  else
    log "создаю root folder $path"
    arr_post "$SONARR" "$SONARR_API_KEY" v3 /rootfolder \
      "$(jq -n --arg p "$path" '{path:$p}')" >/dev/null
  fi
}
ensure_root "$SONARR_ROOT"
ensure_root "$TEST_SONARR_ROOT"

# ---------------------------------------------------------------------------
step "Sonarr: жёсткие ссылки и папки сезонов"
# ---------------------------------------------------------------------------
MEDIAMGMT="$(arr_get "$SONARR" "$SONARR_API_KEY" v3 /config/mediamanagement)"
PATCHED="$(echo "$MEDIAMGMT" | jq '.copyUsingHardlinks = true')"
arr_put "$SONARR" "$SONARR_API_KEY" v3 \
  "/config/mediamanagement/$(echo "$MEDIAMGMT" | jq -r .id)" "$PATCHED" >/dev/null
log "copyUsingHardlinks = true"

# ---------------------------------------------------------------------------
step "Sonarr: writer'ы метаданных выключены"
# ---------------------------------------------------------------------------
# NFO от Sonarr особенно проблемны для Kodi: v19+ опирается на элемент
# episodeguide, который Sonarr не пишет. Метаданные — только скрапер Kodi.
arr_get "$SONARR" "$SONARR_API_KEY" v3 /metadata | jq -c '.[]' | while read -r m; do
  NAME="$(echo "$m" | jq -r .name)"
  if [ "$(echo "$m" | jq -r .enable)" = "true" ]; then
    log "выключаю $NAME"
    arr_put "$SONARR" "$SONARR_API_KEY" v3 \
      "/metadata/$(echo "$m" | jq -r .id)" \
      "$(echo "$m" | jq '.enable = false')" >/dev/null
  else
    log "$NAME уже выключен"
  fi
done

# ---------------------------------------------------------------------------
step "Sonarr: клиент загрузки"
# ---------------------------------------------------------------------------
CLIENTS="$(arr_get "$SONARR" "$SONARR_API_KEY" v3 /downloadclient)"
if echo "$CLIENTS" | jq -e '.[] | select(.implementation=="QBittorrent")' >/dev/null; then
  log "qBittorrent уже настроен"
else
  # -------------------------------------------------------------------------
  # СТОП: см. аналогичный блок в 30-radarr.sh. Форма DownloadClientResource
  # берётся из openapi/sonarr-v3-*.json либо из GET /api/v3/downloadclient
  # после ручной настройки. Категория обязана быть "sonarr".
  # Стоп-условие №1.
  # -------------------------------------------------------------------------
  die "клиент загрузки не настроен и форма запроса не заполнена.
     См. комментарий выше. Стоп-условие №1."
fi

# ---------------------------------------------------------------------------
step "Sonarr: схема переименования"
# ---------------------------------------------------------------------------
if ! grep -qE '^standardEpisodeFormat\s*=\s*\S' "$ROOT/docs/NAMING.md"; then
  die "docs/NAMING.md не заполнен: нет standardEpisodeFormat.
     Возьми рекомендованные строки из TRaSH Guides либо настрой схему
     в веб-морде и скопируй из GET /api/v3/config/naming."
fi
log "NAMING.md заполнен — применяю (реализовать чтение и PUT /config/naming)"

log "готово"
