#!/usr/bin/env bash
# Общие функции проверок.
#
# checks/ — это ВОРОТА, а не тесты. Они трогают Docker и файловую систему,
# запускаются между этапами и возвращают код != 0 при провале.
# Тесты bridge — отдельно, в bridge/tests/, на записанных ответах, без сети.
#
# Файл только подключается, сам не запускается: адреса и функции ниже
# потребляются скриптами проверок.
# shellcheck disable=SC2034

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# .env создаётся человеком и в git не попадает, поэтому статически его не
# прочитать. Директива стоит вплотную к самой команде подключения: применяется
# она к СЛЕДУЮЩЕЙ команде, а в строке "set -a; . …; set +a" следующей была бы
# "set -a" — предупреждение так и не гасилось.
set -a
# shellcheck source=/dev/null
. "$ROOT/.env"
set +a

RADARR="http://localhost:7878"
SONARR="http://localhost:8989"
PROWLARR="http://localhost:9696"
QBT="http://localhost:8081"
BRIDGE="http://localhost:8000"

# Пути ВНУТРИ контейнеров. Единственное монтирование ${DATA_ROOT}:/data,
# остальное — относительные пути из .env.
C_TORRENTS="/data/${TORRENTS_PATH}"
C_MOVIES="/data/${MOVIES_PATH}"
C_TV="/data/${TV_PATH}"

FAILED=0

ok()   { printf '  [ok]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILED=1; }
skip() { printf '  [skip] %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }

title() { printf '\n== %s\n' "$*"; }

# assert <условие-как-строка-описания> <код-выхода-предыдущей-команды>
assert() {
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

# assert_eq <описание> <ожидаемое> <фактическое>
assert_eq() {
  if [ "$2" = "$3" ]; then
    ok "$1 ($3)"
  else
    bad "$1: ожидалось '$2', получено '$3'"
  fi
}

# assert_ge <описание> <минимум> <фактическое>
assert_ge() {
  if [ "$3" -ge "$2" ] 2>/dev/null; then
    ok "$1 ($3 >= $2)"
  else
    bad "$1: ожидалось >= $2, получено '$3'"
  fi
}

arr_get() { curl -fsS -H "X-Api-Key: $2" "$1/api/$3$4"; }

finish() {
  echo
  if [ "$FAILED" -eq 0 ]; then
    echo "ИТОГ: прошло"
  else
    echo "ИТОГ: НЕ ПРОШЛО"
    echo
    echo "Не обходить. Две неудачные попытки исправления — стоп-условие №10,"
    echo "отчёт в reports/ по форме из docs/PROCESS.md."
  fi
  exit "$FAILED"
}
