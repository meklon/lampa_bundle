#!/usr/bin/env bash
# Этап 5. Заказ сезона сериала через bridge.
#
# Два ключевых утверждения:
#   - отслеживается РОВНО ОДИН сезон
#   - monitorNewItems == "none"
# Без второго заказ одного сезона превращается в подписку на сериал —
# ровно то, чего пользователь не просил.
#
# Использование: 06-bridge-season.sh <tmdb_id> <season>
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMDB_ID="${1:-}"; SEASON="${2:-}"
if [ -z "$TMDB_ID" ] || [ -z "$SEASON" ]; then
  echo "использование: $0 <tmdb_id> <season>" >&2
  exit 2
fi

title "Режим bridge"
if [ "${BRIDGE_ENV:-}" != "dev" ]; then
  bad "BRIDGE_ENV=${BRIDGE_ENV:-<пусто>}, ожидался dev"
  exit 1
fi
ok "BRIDGE_ENV=dev"

title "Заказ сезона $SEASON"
RESP="$(curl -fsS -X POST "$BRIDGE/order" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson id "$TMDB_ID" --argjson s "$SEASON" \
        '{tmdb_id:$id, type:"tv", season:$s}')" 2>/dev/null)"
info "ответ: $RESP"
assert_eq "status" queued "$(echo "$RESP" | jq -r .status 2>/dev/null)"

title "Сериал появился в Sonarr"
# Ищем по названию из ответа: tvdbId нам напрямую неизвестен, его разрешал bridge
TITLE="$(echo "$RESP" | jq -r .title 2>/dev/null)"
SERIES="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 /series \
  | jq --arg t "$TITLE" '.[] | select(.title==$t)' 2>/dev/null)"
if [ -z "$SERIES" ]; then
  bad "сериала «$TITLE» в Sonarr нет"
  finish
fi
SID="$(echo "$SERIES" | jq -r .id)"
ok "найден: $TITLE (id=$SID, tvdbId=$(echo "$SERIES" | jq -r .tvdbId))"

title "monitorNewItems"
MNI="$(echo "$SERIES" | jq -r '.monitorNewItems // "<нет поля>"')"
assert_eq "monitorNewItems" none "$MNI"
if [ "$MNI" != none ]; then
  info "Без этого Sonarr начнёт мониторить будущие сезоны."
  info "Глобальной настройки для поля нет — задаётся только на сериал."
  info "СТОП-УСЛОВИЕ №6. Не обходить мониторингом сериала целиком."
fi

title "Отслеживается ровно один сезон, и это заказанный"
MON="$(echo "$SERIES" | jq -r '[.seasons[] | select(.monitored==true) | .seasonNumber] | @csv')"
CNT="$(echo "$SERIES" | jq '[.seasons[] | select(.monitored==true)] | length')"
info "отслеживаемые сезоны: ${MON:-нет}"
assert_eq "количество отслеживаемых сезонов" 1 "$CNT"
assert_eq "номер отслеживаемого сезона" "$SEASON" "$(echo "$MON" | tr -d '"')"

title "В dev-режиме поиск НЕ запущен"
Q="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 /queue | jq '.totalRecords // (.records|length) // 0' 2>/dev/null)"
assert_eq "очередь Sonarr пуста" 0 "${Q:-0}"

title "Идемпотентность: повторный заказ того же сезона"
RESP2="$(curl -fsS -X POST "$BRIDGE/order" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson id "$TMDB_ID" --argjson s "$SEASON" \
        '{tmdb_id:$id, type:"tv", season:$s}')" 2>/dev/null)"
info "ответ: $RESP2"
S2="$(echo "$RESP2" | jq -r .status 2>/dev/null)"
if [ "$S2" = exists ] || [ "$S2" = queued ]; then
  ok "повторный заказ обработан ($S2)"
else
  bad "повторный заказ вернул '$S2'"
fi
CNT2="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 /series \
  | jq --arg t "$TITLE" '[.[] | select(.title==$t)] | length')"
assert_eq "сериал не задублировался" 1 "$CNT2"

finish
