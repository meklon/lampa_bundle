#!/usr/bin/env bash
# Этап 1. Не «контейнер поднялся», а «сервис работает с нашим ключом».
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

title "Состояние контейнеров"
for c in qbittorrent prowlarr radarr sonarr bridge; do
  STATE="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  assert_eq "контейнер $c" running "$STATE"
done

title "API отвечает с ключом из .env"
# Версия пригодится на этапе 4: она сверяется со схемой в openapi/,
# расхождение там — стоп-условие №2.
check_arr() {
  local name="$1" base="$2" key="$3" api="$4" v
  v="$(arr_get "$base" "$key" "$api" /system/status | jq -r .version 2>/dev/null)"
  if [ -n "$v" ] && [ "$v" != null ]; then
    ok "$name $v"
  else
    bad "$name не отвечает или ключ неверен"
  fi
}

check_arr Radarr   "$RADARR"   "${RADARR_API_KEY:-}"   v3
check_arr Sonarr   "$SONARR"   "${SONARR_API_KEY:-}"   v3
check_arr Prowlarr "$PROWLARR" "${PROWLARR_API_KEY:-}" v1

title "qBittorrent"
COOKIE="${TMPDIR:-/tmp}/qbt.check.cookie"
# Referer обязателен: WebUI qBittorrent 5.x без него отвечает 403 на любой
# вызов, включая логин. Проверено на 5.2.3.
if curl -fsS -c "$COOKIE" -H "Referer: $QBT" \
     --data-urlencode "username=${QBITTORRENT_USER:-}" \
     --data-urlencode "password=${QBITTORRENT_PASSWORD:-}" \
     "$QBT/api/v2/auth/login" >/dev/null 2>&1; then
  V="$(curl -fsS -b "$COOKIE" -H "Referer: $QBT" "$QBT/api/v2/app/version" 2>/dev/null)"
  if [ -n "$V" ]; then
    ok "qBittorrent $V"
  else
    bad "qBittorrent: версия не получена"
  fi
else
  bad "qBittorrent: вход не удался. Временный пароль первого запуска — в логе контейнера"
fi
rm -f "$COOKIE"

title "bridge"
curl -fsS "$BRIDGE/health" >/dev/null 2>&1
assert "bridge /health отвечает 200" $?

finish
