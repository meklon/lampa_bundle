#!/usr/bin/env bash
# Прослеживаемость: /status обязан совпадать с действительностью.
#
# Утверждения формулируются о РЕЗУЛЬТАТЕ, а не о коде ответа. Эндпоинт,
# отвечающий 200 и врущий про состояние, хуже отсутствующего: на него
# полагаются.
#
# Главная часть — воспроизведение отказа восьмого этапа. Мониторинг эпизодов
# снимается принудительно, и стек обязан это ПОКАЗАТЬ, а не промолчать.
#
# ВНИМАНИЕ: проверка ВРЕМЕННО МУТИРУЕТ Sonarr — снимает мониторинг с эпизодов
# одного сезона и возвращает его обратно. Если восстановить не удалось, она
# кричит об этом и печатает команду для ручной починки.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

status_of() {  # status_of <tmdb_id> <movie|tv> [поле]
  curl -fsS "$BRIDGE/status?tmdb_id=$1&type=$2" 2>/dev/null | jq -r ".${3:-state}"
}

title "Фильм из библиотеки виден как in_library"
# Фильм берётся скачанный и БЕЗ записи в очереди. Не придирка: по фильму с
# hasFile может идти апгрейд, и тогда /status по своему порядку проверок
# честно ответит downloading — очередь важнее файла на диске. Требовать от
# такого фильма in_library значит завалить проверку на исправном стеке.
QUEUE_IDS="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 "/queue?pageSize=200" \
  | jq -c '[.records[].movieId]')"
[ -n "$QUEUE_IDS" ] || QUEUE_IDS='[]'
MOVIE="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 /movie \
  | jq -r --argjson q "$QUEUE_IDS" \
    'map(select(.hasFile and ((.id) as $i | ($q | index($i)) == null)))|.[0].tmdbId // empty')"
if [ -z "$MOVIE" ]; then
  skip "в Radarr нет скачанного фильма вне очереди — сначала checks/07"
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
    # Восстанавливать нужно РОВНО те эпизоды, что были отслеживаемыми: если в
    # сезоне уже были законно немониторимые эпизоды, слепой monitored:true
    # для всех IDS расширил бы вмешательство шире, чем проверка снимала —
    # молча включил бы то, что человек выключил намеренно.
    MONITORED_IDS="$(echo "$EPS" | jq -c --argjson s "$SEASON" \
      '[.[]|select(.seasonNumber==$s and .monitored)|.id]')"

    # PUT /episode/monitor отвечает 202 Accepted — «принято», а не
    # «применено»: применение идёт фоном. Сам bridge поэтому опрашивает
    # результат до 20 секунд (bridge/app/sonarr.py::_verify_episodes_monitored),
    # а проверка ждала фиксированные три секунды и сразу утверждала — отсюда
    # ложные провалы на нагруженном Sonarr. Ждём тем же способом: опросом.
    wait_state() {  # wait_state <сезон> <ожидаемое> [секунд]
      local deadline got
      deadline=$(( SECONDS + ${3:-20} ))
      while :; do
        got="$(curl -fsS --max-time 10 "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
          | jq -r --argjson s "$1" '.seasons[]|select(.season==$s)|.state')"
        [ "$got" = "$2" ] && break
        [ "$SECONDS" -ge "$deadline" ] && break
        sleep 1
      done
      printf '%s' "$got"
    }

    set_monitoring() {  # set_monitoring <json-массив-id> <true|false> -> код HTTP
      curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -X PUT -H "X-Api-Key: ${SONARR_API_KEY:-}" \
        -H 'Content-Type: application/json' \
        "$SONARR/api/v3/episode/monitor" \
        -d "{\"episodeIds\":$1,\"monitored\":$2}" 2>/dev/null
    }

    MANUAL_FIX="curl -X PUT -H \"X-Api-Key: \$SONARR_API_KEY\" -H 'Content-Type: application/json' \\
             $SONARR/api/v3/episode/monitor \\
             -d '{\"episodeIds\":$MONITORED_IDS,\"monitored\":true}'"

    # Код возврата разбирается, а не выбрасывается в /dev/null: раньше
    # единственным признаком неудачи было расхождение BEFORE/RESTORED, из
    # которого не следовало, что чинить и чем. Молчаливо оставить стенд
    # сломанным — худшее, что может сделать проверка.
    restore_monitoring() {
      local code
      [ "$MONITORED_IDS" = "[]" ] && return 0
      code="$(set_monitoring "$MONITORED_IDS" true)"
      case "$code" in
        2*) return 0 ;;
      esac
      printf '\n  [FAIL] МОНИТОРИНГ ЭПИЗОДОВ НЕ ВОССТАНОВЛЕН (Sonarr ответил %s).\n' "$code"
      printf '         Сезон %s сериала %s остался с погашенными эпизодами:\n' "$SEASON" "$SID"
      printf '         заказ по нему пройдёт, а качать Sonarr ничего не станет.\n'
      printf '         Починить руками:\n\n'
      printf '           %s\n\n' "$MANUAL_FIX"
      return 1
    }
    # trap ставится СРАЗУ, как вычислен список идентификаторов: если процесс
    # убьют в окне между снятием мониторинга и его возвратом (Ctrl-C,
    # таймаут, обрыв сессии), сезон не должен остаться с погашенными
    # эпизодами навсегда — именно этот отказ проверка обязана ЛОВИТЬ, а не
    # наносить сама. Снимается ниже, только после УСПЕШНОГО восстановления.
    trap restore_monitoring EXIT

    BEFORE="$(curl -fsS --max-time 10 "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
      | jq -r --argjson s "$SEASON" '.seasons[]|select(.season==$s)|.state')"
    info "состояние сезона $SEASON до вмешательства: $BEFORE"

    if [ -z "$BEFORE" ]; then
      # Пустой BEFORE — это отказ первичного запроса (bridge недоступен,
      # Sonarr не ответил), а не «состояние совпало». wait_state "$SEASON" ""
      # вернулась бы немедленно, а assert_eq "" "" напечатал бы [ok], молча
      # соврав об успешном восстановлении — того самого класса враньё,
      # против которого написана вся проверка. Мутировать стенд, не зная
      # исходного состояния, тоже нельзя: не с чем будет сверить восстановление.
      bad "не удалось получить состояние сезона $SEASON до вмешательства — мутация Sonarr пропущена"
      trap - EXIT
    else
      BREAK_CODE="$(set_monitoring "$IDS" false)"
      case "$BREAK_CODE" in
        2*) ;;
        *) info "Sonarr ответил $BREAK_CODE на снятие мониторинга" ;;
      esac

      GOT="$(wait_state "$SEASON" monitoring_broken)"
      assert_eq "сломанный мониторинг показан" monitoring_broken "$GOT"
      if [ "$GOT" != monitoring_broken ]; then
        info "Это отказ восьмого этапа: сезон отслеживается, эпизоды нет,"
        info "поиск находит релизы и не берёт ни одного. Он обязан быть видимым."
      fi

      if restore_monitoring; then
        trap - EXIT
        RESTORED="$(wait_state "$SEASON" "$BEFORE")"
        assert_eq "состояние восстановлено" "$BEFORE" "$RESTORED"
      else
        # trap НЕ снимается: при выходе будет ещё одна попытка вернуть
        # мониторинг. Проверка при этом провалена — стенд трогать без
        # восстановления нельзя.
        bad "мониторинг эпизодов не восстановлен, см. команду выше"
      fi
    fi
  fi
fi

title "/status не обращается к трекерам"
# Эндпоинт обязан оставаться читающим. Считаем поисковые записи в логе
# Prowlarr до и после вызова. Пустой лог — НЕ "ноль запросов": это признак,
# что docker compose разрешил не тот проект (например, каталог checks/ в
# репозитории держит собственный docker-compose.yml, который перекрывает
# развёрнутый стенд, если запускать не из его каталога). Сравнивать 0 с 0 в
# этом случае — ложноположительное утверждение, поэтому такой случай skip,
# а не молчаливое совпадение.
#
# Спрашивается состояние фильма, который в Radarr ЕСТЬ ($MOVIE, вычислен
# выше). С отсутствующим фильмом утверждение было почти пустым: /status
# отвечает not_ordered, не запрашивая ни очередь, ни команды, — считался
# самый короткий путь, на котором обращаться к трекерам и так неоткуда.
LOG_BEFORE="$(docker compose logs prowlarr 2>/dev/null)"
if [ -z "$MOVIE" ]; then
  skip "нет фильма, заведомо присутствующего в Radarr — проверять нечего"
elif [ -z "$LOG_BEFORE" ]; then
  skip "лог prowlarr пуст — docker compose не резолвит стенд из текущего каталога"
else
  COUNT_BEFORE="$(printf '%s\n' "$LOG_BEFORE" | grep -c 'ReleaseSearchService' || true)"
  curl -fsS --max-time 10 "$BRIDGE/status?tmdb_id=$MOVIE&type=movie" >/dev/null 2>&1
  sleep 2
  LOG_AFTER="$(docker compose logs prowlarr 2>/dev/null)"
  COUNT_AFTER="$(printf '%s\n' "$LOG_AFTER" | grep -c 'ReleaseSearchService' || true)"
  assert_eq "поисковых запросов к трекерам не прибавилось" "$COUNT_BEFORE" "$COUNT_AFTER"
fi

finish
