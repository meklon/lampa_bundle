#!/usr/bin/env bash
# Radarr: клиент загрузки, root folders, жёсткие ссылки, метаданные, имена.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${RADARR_API_KEY:?не задан RADARR_API_KEY}"
: "${MOVIES_PATH:?не задан MOVIES_PATH}"
: "${TEST_MOVIES_PATH:?не задан TEST_MOVIES_PATH}"

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
ensure_root "$MEDIA_MOVIES"
ensure_root "$MEDIA_TEST_MOVIES"

# ---------------------------------------------------------------------------
step "Radarr: жёсткие ссылки вместо копирования"
# ---------------------------------------------------------------------------
# Это ключевая настройка всего стека. Когда ссылка невозможна, Radarr МОЛЧА
# копирует — ошибки нет, узнаёшь через месяц по свободному месту.
# Проверяется отдельно: checks/04-hardlink.sh
MEDIAMGMT="$(arr_get "$RADARR" "$RADARR_API_KEY" v3 /config/mediamanagement)"
# enableMediaInfo задаётся явно, хотя и включён по умолчанию: от него зависят
# токены {Quality Full}, {Mediainfo AudioCodec} и прочие в схеме имён. Выключен
# — токены отрендерятся пустыми, и библиотека наполнится усечёнными именами.
PATCHED="$(echo "$MEDIAMGMT" | jq '
  .copyUsingHardlinks = true
  | .importExtraFiles = false
  | .enableMediaInfo  = true')"
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
  # Шаблон берётся из GET /api/v3/downloadclient/schema самого Radarr.
  # Правим только адрес, порт, учётные данные и категорию.
  #
  # Имя поля категории у Radarr и Sonarr РАЗНОЕ: здесь movieCategory,
  # у Sonarr tvCategory. Значение "radarr" — та же категория, что создана
  # в 10-qbittorrent.sh, она же определяет каталог загрузки.
  #
  # host — имя сервиса в compose-сети, порт 8081 из WEBUI_PORT. Значения по
  # умолчанию в схеме (localhost:8080) указывали бы на сам контейнер Radarr,
  # да ещё и на порт Kodi.
  : "${QBITTORRENT_USER:?не задан QBITTORRENT_USER}"
  : "${QBITTORRENT_PASSWORD:?не задан QBITTORRENT_PASSWORD}"

  OBJ="$(schema_object "$RADARR" "$RADARR_API_KEY" v3 /downloadclient/schema QBittorrent)"
  [ -n "$OBJ" ] || die "в /downloadclient/schema нет QBittorrent. Стоп-условие №1."

  OBJ="$(set_field "$OBJ" host          "$(jq -n --arg v "$QBT_INTERNAL_HOST" '$v')")"
  OBJ="$(set_field "$OBJ" port          "$(jq -n --argjson v "$QBT_INTERNAL_PORT" '$v')")"
  OBJ="$(set_field "$OBJ" username      "$(jq -n --arg v "$QBITTORRENT_USER" '$v')")"
  OBJ="$(set_field "$OBJ" password      "$(jq -n --arg v "$QBITTORRENT_PASSWORD" '$v')")"
  OBJ="$(set_field "$OBJ" movieCategory "$(jq -n '"radarr"')")"
  OBJ="$(echo "$OBJ" | jq '.name = "qBittorrent" | .enable = true')"

  log "создаю клиент загрузки qBittorrent, категория radarr"
  arr_post "$RADARR" "$RADARR_API_KEY" v3 /downloadclient "$OBJ" >/dev/null \
    || die "Radarr отказал при создании клиента загрузки"
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

# renameMovies по умолчанию false: без него схема не применяется вообще,
# файлы останутся под релизными именами, и это не будет ошибкой.
apply_naming Radarr "$RADARR" "$RADARR_API_KEY" v3 \
  standardMovieFormat movieFolderFormat renameMovies \
  replaceIllegalCharacters colonReplacementFormat

log "готово"
