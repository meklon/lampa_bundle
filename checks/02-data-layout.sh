#!/usr/bin/env bash
# Этап 1. Главная инфраструктурная проверка.
#
# ВЫПОЛНЯЕТСЯ ВНУТРИ КОНТЕЙНЕРА. Граница монтирования существует именно там:
# на хосте пути могут лежать на одной ФС, а в контейнере оказаться разными
# монтированиями — и жёсткие ссылки сломаются молча.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

title "Каталоги существуют (внутри контейнера radarr)"
for d in "$C_TORRENTS/movies" "$C_TORRENTS/tv" "$C_MOVIES" "$C_TV"; do
  docker compose exec -T radarr test -d "$d" 2>/dev/null
  assert "есть $d" $?
done

title "Владелец соответствует PUID/PGID"
OWNER="$(docker compose exec -T radarr stat -c '%u:%g' "$C_MOVIES" 2>/dev/null | tr -d '\r')"
assert_eq "владелец $C_MOVIES" "${PUID}:${PGID}" "$OWNER"

title "торренты и библиотека на одной файловой системе (в контейнере)"
DEV_T="$(docker compose exec -T radarr stat -c %d "$C_TORRENTS" 2>/dev/null | tr -d '\r')"
DEV_M="$(docker compose exec -T radarr stat -c %d "$C_MOVIES" 2>/dev/null | tr -d '\r')"
info "устройство торрентов: $DEV_T, библиотеки: $DEV_M"
info "Совпадения номеров МАЛО: два bind-монтирования одного каталога дают"
info "одинаковый %d, а ln между ними возвращает EXDEV. Решает проба ниже."
if [ -n "$DEV_T" ] && [ "$DEV_T" = "$DEV_M" ]; then
  ok "одно устройство"
else
  bad "РАЗНЫЕ устройства — жёсткие ссылки невозможны"
  info "Причина почти всегда одна: раздельные монтирования в compose."
  info "Должно быть единственное \${DATA_ROOT}:/data. См. SPEC.md 1.6-1.7."
  info "СТОП-УСЛОВИЕ №4."
fi

title "Жёсткая ссылка реально создаётся (в контейнере)"
# Пути передаются аргументами, а не подстановкой: внутри одинарных кавычек
# переменные хоста не раскрываются, а двойные заставили бы экранировать всё
# остальное.
docker compose exec -T radarr sh -c '
  set -e
  T="$1/.hlprobe"
  M="$2/.hlprobe"
  rm -f "$T" "$M"
  echo probe > "$T"
  ln "$T" "$M"
  N=$(stat -c %h "$M")
  I1=$(stat -c %i "$T"); I2=$(stat -c %i "$M")
  rm -f "$T" "$M"
  [ "$N" -ge 2 ] && [ "$I1" = "$I2" ]
' _ "$C_TORRENTS" "$C_MOVIES" >/dev/null 2>&1
assert "ln между торрентами и библиотекой работает, иноды совпадают" $?

title "Тот же тест в контейнере sonarr"
docker compose exec -T sonarr sh -c '
  T="$1/.hlprobe2"; M="$2/.hlprobe2"
  rm -f "$T" "$M"; echo probe > "$T"
  ln "$T" "$M" && N=$(stat -c %h "$M") && rm -f "$T" "$M" && [ "$N" -ge 2 ]
' _ "$C_TORRENTS" "$C_TV" >/dev/null 2>&1
assert "sonarr: ln работает" $?

title "Тот же тест в контейнере qbittorrent"
docker compose exec -T qbittorrent sh -c '
  test -d "$1" && test -d "$2"
' _ "$C_TORRENTS" "$C_MOVIES" >/dev/null 2>&1
assert "qbittorrent видит оба каталога по /data" $?

finish
