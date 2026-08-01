#!/usr/bin/env bash
# Этап 3. ПРИЁМКА МИНИМАЛЬНОГО КОНВЕЙЕРА.
#
# Терминальный критерий проекта — именно этот файл, а не «появилось в Kodi».
# Kodi вне скоупа, и это делает проверку строже: «файл с правильным именем
# по правильному пути» — более сильное утверждение, чем «видно в интерфейсе».
#
# Сети не требует: торрент локальный, из fixtures/.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECTED_REL="${1:-}"
if [ -z "$EXPECTED_REL" ]; then
  echo "использование: $0 <ожидаемый-путь-относительно-/data/media>" >&2
  echo >&2
  echo "Ожидаемый путь берётся из docs/NAMING.md, таблица в конце файла." >&2
  echo "Пример: '_test_movies/Big Buck Bunny (2008)/Big Buck Bunny (2008) …mkv'" >&2
  exit 2
fi

title "Торрент в qBittorrent"
COOKIE="${TMPDIR:-/tmp}/qbt.pipe.cookie"
curl -fsS -c "$COOKIE" \
  --data-urlencode "username=${QBITTORRENT_USER:-}" \
  --data-urlencode "password=${QBITTORRENT_PASSWORD:-}" \
  "$QBT/api/v2/auth/login" >/dev/null 2>&1 || { bad "вход в qBittorrent не удался"; finish; }

TORRENTS="$(curl -fsS -b "$COOKIE" "$QBT/api/v2/torrents/info?category=radarr" 2>/dev/null)"
N="$(echo "$TORRENTS" | jq 'length' 2>/dev/null || echo 0)"
assert_ge "торрентов в категории radarr" 1 "$N"

if [ "${N:-0}" -ge 1 ]; then
  echo "$TORRENTS" | jq -r '.[] | "         \(.name)  progress=\(.progress)  state=\(.state)"'
  DONE="$(echo "$TORRENTS" | jq '[.[] | select(.progress==1)] | length')"
  assert_ge "завершённых торрентов" 1 "$DONE"
  info "Локальный торрент обязан быть 100% сразу: данные уже на месте."
fi

title "Файл лежит по ожидаемому пути"
if docker compose exec -T radarr test -f "/data/media/$EXPECTED_REL" 2>/dev/null; then
  ok "$EXPECTED_REL"
else
  bad "файла нет: /data/media/$EXPECTED_REL"
  info "Что фактически есть в /data/media:"
  docker compose exec -T radarr sh -c \
    'find /data/media -type f \( -name "*.mkv" -o -name "*.mp4" \) 2>/dev/null' \
    | tr -d '\r' | sed 's/^/         /'
  info
  info "Если путь отличается от ожидаемого — это расхождение СХЕМЫ ИМЕНОВАНИЯ."
  info "Исправлять надо схему в docs/NAMING.md и provision-скрипты,"
  info "а НЕ ожидание в этой проверке."
  finish
fi

title "Файл — жёсткая ссылка"
LINKS="$(docker compose exec -T radarr stat -c %h "/data/media/$EXPECTED_REL" 2>/dev/null | tr -d '\r')"
INODE="$(docker compose exec -T radarr stat -c %i "/data/media/$EXPECTED_REL" 2>/dev/null | tr -d '\r')"
assert_ge "количество жёстких ссылок" 2 "${LINKS:-1}"

TWIN="$(docker compose exec -T radarr sh -c \
  "find /data/torrents -inum ${INODE:-0} -type f 2>/dev/null | head -1" | tr -d '\r')"
if [ -n "$TWIN" ]; then
  ok "парная запись в торрент-каталоге: $TWIN"
else
  bad "парной записи под /data/torrents нет — файл скопирован, а не связан"
  info "СТОП-УСЛОВИЕ №3."
fi

title "Раздача не сломалась"
STILL="$(curl -fsS -b "$COOKIE" "$QBT/api/v2/torrents/info?category=radarr" \
  | jq '[.[] | select(.state|test("seed|upload|stalledUP"))] | length' 2>/dev/null)"
assert_ge "торрентов в состоянии раздачи" 1 "${STILL:-0}"
info "Смысл жёсткой ссылки: файл одновременно в библиотеке и в раздаче,"
info "и стоит это один раз по месту. mv или копия сломали бы одно из двух."

rm -f "$COOKIE"
finish
