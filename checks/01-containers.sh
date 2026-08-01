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
V="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 /system/status | jq -r .version 2>/dev/null)"
[ -n "$V" ] && [ "$V" != null ] && ok "Radarr $V" || bad "Radarr не отвечает или ключ неверен"

V="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 /system/status | jq -r .version 2>/dev/null)"
[ -n "$V" ] && [ "$V" != null ] && ok "Sonarr $V" || bad "Sonarr не отвечает или ключ неверен"

V="$(arr_get "$PROWLARR" "${PROWLARR_API_KEY:-}" v1 /system/status | jq -r .version 2>/dev/null)"
[ -n "$V" ] && [ "$V" != null ] && ok "Prowlarr $V" || bad "Prowlarr не отвечает или ключ неверен"

title "qBittorrent"
COOKIE="${TMPDIR:-/tmp}/qbt.check.cookie"
if curl -fsS -c "$COOKIE" \
     --data-urlencode "username=${QBITTORRENT_USER:-}" \
     --data-urlencode "password=${QBITTORRENT_PASSWORD:-}" \
     "$QBT/api/v2/auth/login" >/dev/null 2>&1; then
  V="$(curl -fsS -b "$COOKIE" "$QBT/api/v2/app/version" 2>/dev/null)"
  [ -n "$V" ] && ok "qBittorrent $V" || bad "qBittorrent: версия не получена"
else
  bad "qBittorrent: вход не удался. Временный пароль первого запуска — в логе контейнера"
fi
rm -f "$COOKIE"

title "bridge"
curl -fsS "$BRIDGE/health" >/dev/null 2>&1
assert "bridge /health отвечает 200" $?

finish
