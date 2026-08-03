#!/usr/bin/env bash
# Прослеживаемость: /status обязан совпадать с действительностью.
#
# Утверждения формулируются о РЕЗУЛЬТАТЕ, а не о коде ответа. Эндпоинт,
# отвечающий 200 и врущий про состояние, хуже отсутствующего: на него
# полагаются.
#
# Главная часть — воспроизведение отказа восьмого этапа. Мониторинг эпизодов
# снимается принудительно, и стек обязан это ПОКАЗАТЬ, а не промолчать.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

status_of() {  # status_of <tmdb_id> <movie|tv> [поле]
  curl -fsS "$BRIDGE/status?tmdb_id=$1&type=$2" 2>/dev/null | jq -r ".${3:-state}"
}

title "Фильм из библиотеки виден как in_library"
MOVIE="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 /movie \
  | jq -r 'map(select(.hasFile))|.[0].tmdbId // empty')"
if [ -z "$MOVIE" ]; then
  skip "в Radarr нет ни одного скачанного фильма — сначала checks/07"
else
  assert_eq "состояние фильма $MOVIE" in_library "$(status_of "$MOVIE" movie)"
fi

title "Фильма нет в Radarr — not_ordered"
# 1 — идентификатор, которого заведомо нет в библиотеке стенда.
assert_eq "состояние незаказанного" not_ordered "$(status_of 1 movie)"

title "Сериал: сломанный мониторинг становится ВИДЕН"
SID="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 /series | jq -r '.[0].id // empty')"
TMDB_TV=""
if [ -n "$SID" ]; then
  TMDB_TV="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/series/$SID" | jq -r '.tmdbId // empty')"
fi

if [ -z "$SID" ] || [ -z "$TMDB_TV" ] || [ "$TMDB_TV" = "0" ]; then
  skip "в Sonarr нет сериала с известным tmdbId — сначала checks/06"
else
  SEASON="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/series/$SID" \
    | jq -r '[.seasons[]|select(.monitored)|.seasonNumber]|first // empty')"
  if [ -z "$SEASON" ]; then
    skip "у сериала нет отслеживаемого сезона"
  else
    EPS="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/episode?seriesId=$SID")"
    IDS="$(echo "$EPS" | jq -c --argjson s "$SEASON" '[.[]|select(.seasonNumber==$s)|.id]')"
    BEFORE="$(curl -fsS "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
      | jq -r --argjson s "$SEASON" '.seasons[]|select(.season==$s)|.state')"
    info "состояние сезона $SEASON до вмешательства: $BEFORE"

    curl -fsS -X PUT -H "X-Api-Key: ${SONARR_API_KEY:-}" -H 'Content-Type: application/json' \
      "$SONARR/api/v3/episode/monitor" \
      -d "{\"episodeIds\":$IDS,\"monitored\":false}" >/dev/null 2>&1
    sleep 3

    GOT="$(curl -fsS "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
      | jq -r --argjson s "$SEASON" '.seasons[]|select(.season==$s)|.state')"
    assert_eq "сломанный мониторинг показан" monitoring_broken "$GOT"
    if [ "$GOT" != monitoring_broken ]; then
      info "Это отказ восьмого этапа: сезон отслеживается, эпизоды нет,"
      info "поиск находит релизы и не берёт ни одного. Он обязан быть видимым."
    fi

    curl -fsS -X PUT -H "X-Api-Key: ${SONARR_API_KEY:-}" -H 'Content-Type: application/json' \
      "$SONARR/api/v3/episode/monitor" \
      -d "{\"episodeIds\":$IDS,\"monitored\":true}" >/dev/null 2>&1
    sleep 3
    RESTORED="$(curl -fsS "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
      | jq -r --argjson s "$SEASON" '.seasons[]|select(.season==$s)|.state')"
    assert_eq "состояние восстановлено" "$BEFORE" "$RESTORED"
  fi
fi

title "/status не обращается к трекерам"
# Эндпоинт обязан оставаться читающим. Считаем поисковые записи в логе
# Prowlarr до и после вызова.
COUNT_BEFORE="$(docker compose logs prowlarr 2>/dev/null | grep -c 'ReleaseSearchService' || true)"
curl -fsS "$BRIDGE/status?tmdb_id=1083381&type=movie" >/dev/null 2>&1
sleep 2
COUNT_AFTER="$(docker compose logs prowlarr 2>/dev/null | grep -c 'ReleaseSearchService' || true)"
assert_eq "поисковых запросов к трекерам не прибавилось" "$COUNT_BEFORE" "$COUNT_AFTER"

finish
