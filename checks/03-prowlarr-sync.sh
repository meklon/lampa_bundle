#!/usr/bin/env bash
# Этап 2. Проверяется НАПРАВЛЕНИЕ синхронизации: индексаторы появились
# в Radarr и Sonarr, хотя туда их никто не заводил.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

title "Приложения зарегистрированы в Prowlarr"
APPS="$(arr_get "$PROWLARR" "${PROWLARR_API_KEY:-}" v1 /applications 2>/dev/null)"
if [ -z "$APPS" ] || [ "$APPS" = "[]" ]; then
  bad "в Prowlarr нет зарегистрированных приложений"
  info "Ожидались Radarr и Sonarr. См. provision/20-prowlarr.sh"
  finish
fi
echo "$APPS" | jq -r '.[] | "         \(.name) (\(.implementation))"'

for want in Radarr Sonarr; do
  echo "$APPS" | jq -e --arg n "$want" '.[] | select(.name==$n)' >/dev/null 2>&1
  assert "$want зарегистрирован" $?
done

title "Индексаторы в Prowlarr"
IDX="$(arr_get "$PROWLARR" "${PROWLARR_API_KEY:-}" v1 /indexer 2>/dev/null)"
N_IDX="$(echo "$IDX" | jq 'length' 2>/dev/null || echo 0)"
if [ "$N_IDX" -eq 0 ]; then
  skip "индексаторов нет — проверка синхронизации невозможна"
  info "Это ожидаемо на этапах 1-5: индексаторы добавляет человек, вручную,"
  info "на последнем этапе. Проверка НЕ считается пройденной."
  info "См. CLAUDE.md, раздел про безопасность при разработке."
  exit 0
fi
info "индексаторов в Prowlarr: $N_IDX"

title "Индексаторы доехали до Radarr и Sonarr"
R_IDX="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 /indexer | jq 'length' 2>/dev/null || echo 0)"
S_IDX="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 /indexer | jq 'length' 2>/dev/null || echo 0)"
assert_ge "индексаторов в Radarr" 1 "$R_IDX"
assert_ge "индексаторов в Sonarr" 1 "$S_IDX"
info "Индексаторы синхронизируются по поддерживаемым категориям:"
info "TV-индексаторы уходят только в Sonarr, и наоборот. Расхождение чисел — норма."

finish
