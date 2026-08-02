#!/usr/bin/env bash
# Куда qBittorrent КЛАДЁТ файлы. Не «какие категории заведены».
#
# Проверка появилась после отказа на живом стенде: категории были заведены
# верно, провижининг проходил, а торренты уезжали в /config/Downloads —
# собственный том qBittorrent на системном диске. Причина: путь по категории
# действует ТОЛЬКО при включённом ATM (auto_tmm_enabled), а он выключался
# намеренно, из противоположного допущения.
#
# Три последствия, и все молчаливые:
#   1. Radarr и Sonarr не видят /config чужого контейнера — импорт невозможен;
#   2. /config и /data — разные файловые системы, жёсткая ссылка исключена;
#   3. скачанное наполняет системный диск.
#
# Ни одна прежняя проверка этого не ловила: 02 и 04 проверяют связывание
# ВНУТРИ /data, а куда сохраняет клиент — не спрашивал никто.
# Отчёт: reports/stage-8-monitoring-and-paths.md.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COOKIE="${TMPDIR:-/tmp}/qbt.savepath.cookie"
trap 'rm -f "$COOKIE"' EXIT

# Referer обязателен: WebUI qBittorrent 5.x без него отвечает 403 на любой
# вызов, включая логин. Проверено на 5.2.3.
qbt() { curl -fsS -b "$COOKIE" -H "Referer: $QBT" "$@"; }

curl -fsS -c "$COOKIE" -H "Referer: $QBT" \
  --data-urlencode "username=${QBITTORRENT_USER:-}" \
  --data-urlencode "password=${QBITTORRENT_PASSWORD:-}" \
  "$QBT/api/v2/auth/login" >/dev/null 2>&1 \
  || { bad "вход в qBittorrent не удался"; finish; }

title "Автоматическое управление путями включено"
PREFS="$(qbt "$QBT/api/v2/app/preferences")"
assert_eq "auto_tmm_enabled" true \
  "$(echo "$PREFS" | jq -r .auto_tmm_enabled)"
assert_eq "category_changed_tmm_enabled" true \
  "$(echo "$PREFS" | jq -r .category_changed_tmm_enabled)"
if [ "$(echo "$PREFS" | jq -r .auto_tmm_enabled)" != true ]; then
  info "При выключенном ATM категория остаётся МЕТКОЙ и на путь не влияет."
  info "Торренты уедут в глобальный save_path, то есть в /config из образа."
fi

title "Глобальный save_path и temp_path не смотрят в /config"
for field in save_path temp_path; do
  P="$(echo "$PREFS" | jq -r ".$field")"
  case "$P" in
    "$C_TORRENTS"*) ok "$field=$P" ;;
    *) bad "$field=$P — вне $C_TORRENTS"
       info "Торрент без категории уехал бы на конфигурационный том." ;;
  esac
done

title "Пути категорий"
CATS="$(qbt "$QBT/api/v2/torrents/categories")"
assert_eq "radarr" "$C_TORRENTS/movies" "$(echo "$CATS" | jq -r '.radarr.savePath // "<нет категории>"')"
assert_eq "sonarr" "$C_TORRENTS/tv" "$(echo "$CATS" | jq -r '.sonarr.savePath // "<нет категории>"')"

title "Торрент с category=radarr ФАКТИЧЕСКИ ложится в каталог категории"
FIXTURE="$ROOT/fixtures/Big.Buck.Bunny.2008.1080p.WEB-DL.x264-TEST.torrent"
if [ ! -f "$FIXTURE" ]; then
  skip "нет $FIXTURE — сначала fixtures/make-fixture.sh"
  finish
fi

# Имя торрента совпадает с именем файла без расширения: make-fixture.sh
# называет и то и другое по release_name из fixtures/catalog.yml. Этого
# достаточно, чтобы найти торрент, не разбирая bencode ради инфохеша.
NAME="$(basename "$FIXTURE" .torrent)"
by_name() { qbt "$QBT/api/v2/torrents/info" | jq -r --arg n "$NAME" ".[] | select(.name==\$n) | .$1"; }

ADDED=0
if [ -n "$(by_name hash)" ]; then
  info "торрент уже в клиенте — проверяю его, добавлять не нужно"
else
  qbt -F "torrents=@$FIXTURE" -F "category=radarr" "$QBT/api/v2/torrents/add" >/dev/null 2>&1 \
    || { bad "добавить торрент не удалось"; finish; }
  ADDED=1
  for _ in $(seq 1 15); do
    [ -n "$(by_name hash)" ] && break
    sleep 1
  done
fi

HASH="$(by_name hash)"
if [ -z "$HASH" ]; then
  bad "торрент «$NAME» в клиенте не появился"
  finish
fi

SAVE="$(by_name save_path)"
CONTENT="$(by_name content_path)"
CAT="$(by_name category)"

assert_eq "категория торрента" radarr "$CAT"
assert_eq "save_path торрента" "$C_TORRENTS/movies" "$SAVE"
info "content_path: ${CONTENT:-<пусто>}"

title "Radarr видит этот путь у себя"
# Вторая половина отказа была именно в этом: путь существовал, но в томе
# ЧУЖОГО контейнера. Импортировать оттуда Radarr не может по построению, и
# ошибки при этом нет — торрент просто «скачался и не импортировался».
docker compose exec -T radarr test -d "$SAVE" >/dev/null 2>&1
assert "в контейнере radarr существует каталог $SAVE" $?

PROGRESS="$(by_name progress)"
if [ -n "$CONTENT" ] && [ "${PROGRESS%%.*}" = 1 ]; then
  docker compose exec -T radarr test -e "$CONTENT" >/dev/null 2>&1
  assert "и сам файл: $CONTENT" $?
else
  skip "торрент без данных (progress=${PROGRESS:-?}) — файл проверять нечем"
  info "Данные фикстуры восстанавливаются fixtures/make-fixture.sh."
fi

# Убираем ТОЛЬКО за собой и НЕ трогая файлы: данные фикстуры лежат в раздаче
# и нужны проверке 07.
if [ "$ADDED" = 1 ]; then
  qbt --data-urlencode "hashes=$HASH" --data 'deleteFiles=false' \
    "$QBT/api/v2/torrents/delete" >/dev/null 2>&1
fi

finish
