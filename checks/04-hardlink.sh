#!/usr/bin/env bash
# Этап 3. Единственная настоящая проверка главной инфраструктурной ошибки.
#
# Настройка называется «Use Hardlinks instead of Copy», и когда ссылка
# невозможна, *arr МОЛЧА копирует. Ошибки нет. Узнаёшь через месяц по
# свободному месту. Поэтому stat -c %h, а не «файл появился».
#
# Напоминание: du посчитает такие данные дважды, потому что видит их в обоих
# деревьях. Правду говорит df.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

title "Настройка включена в Radarr и Sonarr"
for pair in "radarr:$RADARR:${RADARR_API_KEY:-}" "sonarr:$SONARR:${SONARR_API_KEY:-}"; do
  NAME="${pair%%:*}"; REST="${pair#*:}"; URL="${REST%:*}"; KEY="${REST##*:}"
  HL="$(arr_get "$URL" "$KEY" v3 /config/mediamanagement | jq -r .copyUsingHardlinks 2>/dev/null)"
  assert_eq "$NAME copyUsingHardlinks" true "$HL"
done

title "Импортированные файлы — жёсткие ссылки"
FILES="$(docker compose exec -T radarr sh -c \
  'find /data/media -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" \) 2>/dev/null' \
  | tr -d '\r')"

if [ -z "$FILES" ]; then
  bad "в /data/media нет медиафайлов — импорт не выполнялся"
  info "Сначала прогони этап 3: fixtures/make-fixture.sh и checks/07-pipeline.sh"
  finish
fi

TOTAL="$(printf '%s\n' "$FILES" | grep -c .)"
info "медиафайлов найдено: $TOTAL"

# Два обязательных момента в этом цикле.
#
# 1. Ввод подаётся здесь-строкой, а не конвейером: конвейер уводит тело цикла
#    в подоболочку, и присвоение FAILED из неё не возвращается наружу.
# 2. Каждому docker compose exec подставляется </dev/null. Без этого exec
#    читает stdin цикла и съедает оставшиеся строки: проверенным оказывается
#    ровно ОДИН файл из скольких угодно, а остальные молча пропускаются —
#    ровно тот сорт тихой поломки, ради которого эта проверка написана.
CHECKED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  CHECKED=$((CHECKED + 1))
  LINKS="$(docker compose exec -T radarr stat -c %h "$f" 2>/dev/null </dev/null | tr -d '\r')"
  INODE="$(docker compose exec -T radarr stat -c %i "$f" 2>/dev/null </dev/null | tr -d '\r')"

  if [ "${LINKS:-1}" -ge 2 ] 2>/dev/null; then
    # Ссылка есть — убедимся, что вторая копия действительно в torrents
    TWIN="$(docker compose exec -T radarr sh -c \
      "find /data/torrents -inum $INODE -type f 2>/dev/null | head -1" </dev/null | tr -d '\r')"
    if [ -n "$TWIN" ]; then
      printf '  [ok]   %s\n' "$(basename "$f") (ссылок: $LINKS)"
      printf '         парная запись: %s\n' "$TWIN"
    else
      printf '  [FAIL] %s: ссылок %s, но парной записи в /data/torrents нет\n' \
        "$(basename "$f")" "$LINKS"
      FAILED=1
    fi
  else
    printf '  [FAIL] %s: ссылок %s — это КОПИЯ, а не жёсткая ссылка\n' \
      "$(basename "$f")" "${LINKS:-?}"
    FAILED=1
  fi
done <<EOF
$FILES
EOF

# Страховка от повторения той же ошибки: если проверено не столько файлов,
# сколько найдено, проверка обязана упасть, а не отчитаться зелёным.
if [ "$CHECKED" != "$TOTAL" ]; then
  bad "проверено $CHECKED файлов из $TOTAL — часть пропущена"
fi

if [ "$FAILED" -ne 0 ]; then
  echo
  info "СТОП-УСЛОВИЕ №3."
  info "Причина почти всегда в раздельных монтированиях — см. checks/02."
  info "НЕ обходить копированием или mv: см. таблицу запрещённых подмен."
fi

finish
