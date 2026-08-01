#!/usr/bin/env bash
# Категории qBittorrent. Категория = имя + путь сохранения; торрент,
# добавленный с category=radarr, сам ложится в нужный каталог.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "qBittorrent: вход"
qbt_login >/dev/null

step "qBittorrent: категории"
EXISTING="$(curl -fsS -b "$QBT_COOKIE" "$QBT/api/v2/torrents/categories")"

ensure_category() {
  local name="$1" path="$2"
  if echo "$EXISTING" | jq -e --arg n "$name" 'has($n)' >/dev/null; then
    log "категория $name уже есть — обновляю путь"
    qbt_post /torrents/editCategory \
      --data-urlencode "category=$name" \
      --data-urlencode "savePath=$path" >/dev/null
  else
    log "создаю категорию $name -> $path"
    qbt_post /torrents/createCategory \
      --data-urlencode "category=$name" \
      --data-urlencode "savePath=$path" >/dev/null
  fi
}

ensure_category radarr /data/torrents/movies
ensure_category sonarr /data/torrents/tv

step "qBittorrent: базовые настройки"
# Автоматический режим управления торрентами выключен: пути задаются
# категориями, а не эвристикой клиента.
qbt_post /app/setPreferences \
  --data-urlencode 'json={"auto_tmm_enabled":false,"category_changed_tmm_enabled":false}' \
  >/dev/null

log "готово"
