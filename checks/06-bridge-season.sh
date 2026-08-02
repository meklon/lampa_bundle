#!/usr/bin/env bash
# Этап 5. Заказ сезона сериала через bridge.
#
# Три ключевых утверждения:
#   - отслеживается РОВНО ОДИН сезон
#   - и РОВНО ЕГО ЭПИЗОДЫ
#   - monitorNewItems == "none"
# Без третьего заказ одного сезона превращается в подписку на сериал —
# ровно то, чего пользователь не просил.
#
# Второе появилось после отказа на живом стенде: проверка утверждала только
# уровень сезонов, и заказ, не приводящий ни к одной загрузке, проходил её
# насквозь. Урок общий и записан в CLAUDE.md: утверждать наблюдаемый
# результат, а не принятую настройку.
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

title "Эпизоды заказанного сезона отслеживаются, прочие — нет"
# Флага сезона НЕДОСТАТОЧНО: загрузку Sonarr планирует по эпизодам. Раньше
# эта проверка заканчивалась на уровне сезонов и пропускала отказ насквозь —
# сезон monitored=true, эпизоды все false, поиск находит релизы и не забирает
# ни одного. См. reports/stage-8-monitoring-and-paths.md.
EPISODES="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/episode?seriesId=$SID")"
echo "$EPISODES" | jq -r --argjson s "$SEASON" '
  group_by(.seasonNumber)[]
  | "         S\(.[0].seasonNumber): всего \(length), отслеживается \([.[]|select(.monitored)]|length)"'

TOTAL_IN="$(echo "$EPISODES" | jq --argjson s "$SEASON" '[.[]|select(.seasonNumber==$s)]|length')"
MON_IN="$(echo "$EPISODES" | jq --argjson s "$SEASON" \
  '[.[]|select(.seasonNumber==$s and .monitored)]|length')"
MON_OUT="$(echo "$EPISODES" | jq --argjson s "$SEASON" \
  '[.[]|select(.seasonNumber!=$s and .monitored)]|length')"

assert_ge "эпизодов в сезоне $SEASON" 1 "${TOTAL_IN:-0}"
assert_eq "отслеживаемых эпизодов в сезоне $SEASON" "${TOTAL_IN:-0}" "${MON_IN:-0}"
assert_eq "отслеживаемых эпизодов вне сезона $SEASON" 0 "${MON_OUT:-0}"
if [ "${MON_IN:-0}" != "${TOTAL_IN:-0}" ]; then
  info "Sonarr забирает релиз только под ОТСЛЕЖИВАЕМЫЙ ЭПИЗОД."
  info "Заказ при этом выглядит успешным, поиск отрабатывает, и не"
  info "скачивается ничего — ни ошибки, ни записи в истории."
  info "Чинить в bridge/app/sonarr.py: set_episodes_monitored."
fi

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

# Заказ ДРУГОГО сезона того же сериала — единственное место, где видно, гасятся
# ли эпизоды предыдущего. Инвариант «ровно один сезон» на уровне сезонов
# соблюдался бы и без этого, а фактически качались бы два.
OTHER="$(echo "$SERIES" | jq --argjson s "$SEASON" \
  '[.seasons[] | select(.seasonNumber != $s and .seasonNumber > 0) | .seasonNumber] | first // empty')"
if [ -z "$OTHER" ]; then
  title "Заказ второго сезона"
  skip "у сериала один сезон — переключение проверить не на чем"
else
  title "Заказ второго сезона ($OTHER) переключает мониторинг, а не добавляет"
  curl -fsS -X POST "$BRIDGE/order" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --argjson id "$TMDB_ID" --argjson s "$OTHER" \
          '{tmdb_id:$id, type:"tv", season:$s}')" >/dev/null 2>&1
  assert "заказ сезона $OTHER принят" $?

  SEASONS2="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/series/$SID" \
    | jq -r '[.seasons[] | select(.monitored) | .seasonNumber] | join(",")')"
  assert_eq "отслеживаемые сезоны" "$OTHER" "$SEASONS2"

  EP2="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/episode?seriesId=$SID")"
  TOTAL2="$(echo "$EP2" | jq --argjson s "$OTHER" '[.[]|select(.seasonNumber==$s)]|length')"
  IN2="$(echo "$EP2" | jq --argjson s "$OTHER" \
    '[.[]|select(.seasonNumber==$s and .monitored)]|length')"
  OUT2="$(echo "$EP2" | jq --argjson s "$OTHER" \
    '[.[]|select(.seasonNumber!=$s and .monitored)]|length')"
  assert_eq "отслеживаемых эпизодов в сезоне $OTHER" "${TOTAL2:-0}" "${IN2:-0}"
  assert_eq "эпизоды сезона $SEASON погашены" 0 "${OUT2:-0}"
fi

finish
