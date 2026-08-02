#!/usr/bin/env bash
# Категории qBittorrent. Категория = имя + путь сохранения; торрент,
# добавленный с category=radarr, сам ложится в нужный каталог.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "qBittorrent: вход"
qbt_login >/dev/null

step "qBittorrent: категории"
EXISTING="$(qbt_get /torrents/categories)"

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

ensure_category radarr "$TORRENTS_MOVIES"
ensure_category sonarr "$TORRENTS_TV"

step "qBittorrent: базовые настройки"
# Автоматический режим управления торрентами (ATM) ВКЛЮЧЁН, и это условие
# того, чтобы пути категорий вообще действовали.
#
# Здесь была ошибка ровно в обратном допущении: ATM выключался «чтобы пути
# задавались категориями». В qBittorrent зависимость противоположная — путь
# по категории берётся ТОЛЬКО при включённом ATM. При выключенном категория
# остаётся меткой без влияния на путь, и торрент уезжает в глобальный
# save_path, то есть в /config/Downloads из образа. Последствия молчаливые и
# тяжёлые: /config — собственный том qBittorrent, Radarr его не видит и
# импортировать не может; /config и /data — разные файловые системы, поэтому
# жёсткая ссылка исключена; скачанное наполняет системный диск.
#
# Глобальный save_path всё равно уводится под /data: он действует для
# торрентов без категории, а на конфигурационный том не должно попадать
# ничего ни при каких обстоятельствах. По той же причине переносится и
# temp_path — он сейчас выключен, но его умолчание тоже смотрит в /config.
qbt_post /app/setPreferences \
  --data-urlencode "json=$(jq -nc \
    --arg root "$TORRENTS_ROOT" \
    '{auto_tmm_enabled: true,
      category_changed_tmm_enabled: true,
      save_path_changed_tmm_enabled: true,
      save_path: $root,
      temp_path: ($root + "/.incomplete")}')" \
  >/dev/null

# Настройка «принята» и настройка «действует» — разные утверждения, и
# расхождение между ними уже стоило проекту двух молчаливых отказов
# (см. docs/SPEC.md 2.5). Поэтому читаем обратно.
PREFS="$(qbt_get /app/preferences)"
echo "$PREFS" | jq -e \
  --arg root "$TORRENTS_ROOT" \
  '.auto_tmm_enabled == true
   and .category_changed_tmm_enabled == true
   and .save_path == $root' >/dev/null \
  || die "qBittorrent не применил настройки путей: $(echo "$PREFS" |
       jq -c '{auto_tmm_enabled, category_changed_tmm_enabled, save_path}')"

log "готово"
