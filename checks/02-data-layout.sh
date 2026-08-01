#!/usr/bin/env bash
# Этап 1. Главная инфраструктурная проверка.
#
# ВЫПОЛНЯЕТСЯ ВНУТРИ КОНТЕЙНЕРА. Граница монтирования существует именно там:
# на хосте пути могут лежать на одной ФС, а в контейнере оказаться разными
# монтированиями — и жёсткие ссылки сломаются молча.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

title "Каталоги существуют (внутри контейнера radarr)"
for d in /data/torrents/movies /data/torrents/tv /data/media/movies /data/media/tv; do
  docker compose exec -T radarr test -d "$d" 2>/dev/null
  assert "есть $d" $?
done

title "Владелец соответствует PUID/PGID"
OWNER="$(docker compose exec -T radarr stat -c '%u:%g' /data/media 2>/dev/null | tr -d '\r')"
assert_eq "владелец /data/media" "${PUID}:${PGID}" "$OWNER"

title "torrents и media на одной файловой системе (в контейнере)"
DEV_T="$(docker compose exec -T radarr stat -c %d /data/torrents 2>/dev/null | tr -d '\r')"
DEV_M="$(docker compose exec -T radarr stat -c %d /data/media 2>/dev/null | tr -d '\r')"
info "устройство torrents: $DEV_T, media: $DEV_M"
if [ -n "$DEV_T" ] && [ "$DEV_T" = "$DEV_M" ]; then
  ok "одно устройство"
else
  bad "РАЗНЫЕ устройства — жёсткие ссылки невозможны"
  info "Причина почти всегда одна: раздельные монтирования в compose."
  info "Должно быть единственное \${DATA_ROOT}:/data. См. SPEC.md 1.6-1.7."
  info "СТОП-УСЛОВИЕ №4."
fi

title "Жёсткая ссылка реально создаётся (в контейнере)"
docker compose exec -T radarr sh -c '
  set -e
  T=/data/torrents/.hlprobe
  M=/data/media/.hlprobe
  rm -f "$T" "$M"
  echo probe > "$T"
  ln "$T" "$M"
  N=$(stat -c %h "$M")
  I1=$(stat -c %i "$T"); I2=$(stat -c %i "$M")
  rm -f "$T" "$M"
  [ "$N" -ge 2 ] && [ "$I1" = "$I2" ]
' >/dev/null 2>&1
assert "ln между torrents и media работает, иноды совпадают" $?

title "Тот же тест в контейнере sonarr"
docker compose exec -T sonarr sh -c '
  T=/data/torrents/.hlprobe2; M=/data/media/.hlprobe2
  rm -f "$T" "$M"; echo probe > "$T"
  ln "$T" "$M" && N=$(stat -c %h "$M") && rm -f "$T" "$M" && [ "$N" -ge 2 ]
' >/dev/null 2>&1
assert "sonarr: ln работает" $?

title "Тот же тест в контейнере qbittorrent"
docker compose exec -T qbittorrent sh -c '
  test -d /data/torrents && test -d /data/media
' >/dev/null 2>&1
assert "qbittorrent видит оба каталога по /data" $?

finish
