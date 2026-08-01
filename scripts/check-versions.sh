#!/usr/bin/env bash
# Сверка версии схемы в openapi/ с версией живого инстанса.
#
# Расхождение — СТОП-УСЛОВИЕ, не предупреждение. Схема из main-ветки и
# контейнер полугодовой давности — разные схемы, и расхождение молчаливое:
# агент возьмёт из схемы поле, которого в его версии ещё нет.
set -euo pipefail

cd "$(dirname "$0")/.."
# .env создаётся человеком и в git не попадает, поэтому статически его не
# прочитать. Директива стоит вплотную к самой команде подключения: применяется
# она к СЛЕДУЮЩЕЙ команде, а в строке "set -a; . …; set +a" следующей была бы
# "set -a" — предупреждение так и не гасилось.
set -a
# shellcheck source=/dev/null
. ./.env
set +a

FAIL=0

check() {
  local svc="$1" url="$2" key="$3" api="$4"

  local live
  live="$(curl -fsS -H "X-Api-Key: $key" "$url/api/$api/system/status" \
          | jq -r '.version' 2>/dev/null || echo "")"
  if [ -z "$live" ] || [ "$live" = "null" ]; then
    echo "[--] $svc: не удалось получить версию с $url"
    FAIL=1; return
  fi

  # Ищем схему, в имени которой встречается версия живого инстанса.
  local found="" have=""
  for f in "openapi/${svc}"-*.json; do
    [ -e "$f" ] || continue
    have="$have $f"
    case "$f" in *"$live"*) found="$f" ;; esac
  done

  if [ -n "$found" ]; then
    echo "[ok] $svc $live  <-  $found"
  else
    echo "[!!] $svc: живой инстанс $live, схемы под эту версию в openapi/ нет"
    echo "     есть:${have:- (ни одной)}"
    echo "     СТОП-УСЛОВИЕ №2. Скачай схему под $live через fetch-openapi.sh"
    FAIL=1
  fi
}

check radarr   "http://localhost:7878" "${RADARR_API_KEY:-}"   v3
check sonarr   "http://localhost:8989" "${SONARR_API_KEY:-}"   v3
check prowlarr "http://localhost:9696" "${PROWLARR_API_KEY:-}" v1

if [ ! -s openapi/SOURCES.md ]; then
  echo "[!!] openapi/SOURCES.md пуст — нет записей о происхождении схем"
  FAIL=1
fi

exit "$FAIL"
