#!/usr/bin/env bash
# Этап 5. Заказ фильма через bridge.
#
# Ключевой пункт: в dev-режиме поиск НЕ должен запускаться. Проверяется
# отдельно, потому что «вернул 200» и «не начал качать» — разные утверждения.
#
# Использование: 05-bridge-movie.sh <tmdb_id>
# tmdb_id берётся из fixtures/catalog.yml
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMDB_ID="${1:-}"
if [ -z "$TMDB_ID" ]; then
  echo "использование: $0 <tmdb_id>" >&2
  echo "значение возьми из fixtures/catalog.yml" >&2
  exit 2
fi

title "Режим bridge"
if [ "${BRIDGE_ENV:-}" != "dev" ]; then
  bad "BRIDGE_ENV=${BRIDGE_ENV:-<пусто>}, ожидался dev"
  info "В prod-режиме эта проверка вызовет реальную загрузку. Прекращаю."
  exit 1
fi
ok "BRIDGE_ENV=dev"

title "Первый заказ"
RESP="$(curl -fsS -X POST "$BRIDGE/order" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson id "$TMDB_ID" '{tmdb_id:$id, type:"movie", season:null}')" \
  2>/dev/null)"
info "ответ: $RESP"
assert_eq "status" queued "$(echo "$RESP" | jq -r .status 2>/dev/null)"

title "Фильм появился в Radarr"
MOVIE="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 /movie \
  | jq --argjson id "$TMDB_ID" '.[] | select(.tmdbId==$id)' 2>/dev/null)"
if [ -z "$MOVIE" ]; then
  bad "фильма с tmdbId=$TMDB_ID в Radarr нет"
  finish
fi
ok "найден: $(echo "$MOVIE" | jq -r .title)"

title "Параметры выставлены как ожидалось"
assert_eq "rootFolderPath"      "$C_MOVIES"                       "$(echo "$MOVIE" | jq -r .rootFolderPath)"
assert_eq "minimumAvailability" "${RADARR_MIN_AVAILABILITY:-released}" "$(echo "$MOVIE" | jq -r .minimumAvailability)"
assert_eq "monitored"           true                              "$(echo "$MOVIE" | jq -r .monitored)"

title "В dev-режиме поиск НЕ запущен"
Q="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 /queue | jq '.totalRecords // (.records|length) // 0' 2>/dev/null)"
assert_eq "очередь Radarr пуста" 0 "${Q:-0}"

MID="$(echo "$MOVIE" | jq -r .id)"
H="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 "/history/movie?movieId=$MID" | jq 'length' 2>/dev/null)"
assert_eq "история по фильму пуста" 0 "${H:-0}"

title "Идемпотентность: повторный заказ"
RESP2="$(curl -fsS -X POST "$BRIDGE/order" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson id "$TMDB_ID" '{tmdb_id:$id, type:"movie", season:null}')" \
  2>/dev/null)"
info "ответ: $RESP2"
assert_eq "status" exists "$(echo "$RESP2" | jq -r .status 2>/dev/null)"
info "«уже в библиотеке» — это УСПЕХ, не отказ. Код ответа обязан быть 200."

finish
