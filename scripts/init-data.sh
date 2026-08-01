#!/usr/bin/env bash
# Раскладка каталогов данных и права.
#
# Ключевое требование: torrents/ и media/ на ОДНОЙ файловой системе,
# иначе жёсткие ссылки невозможны и *arr будет молча копировать.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${DATA_ROOT:?не задан DATA_ROOT в .env}"
: "${PUID:?не задан PUID}"
: "${PGID:?не задан PGID}"

echo "==> DATA_ROOT=$DATA_ROOT"

# DATA_ROOT не должен лежать внутри репозитория: иначе он окажется на той же
# ФС, что и всё остальное, и проверка жёстких ссылок станет бессмысленной.
REPO="$(pwd -P)"
CANON="$(readlink -f "$DATA_ROOT" 2>/dev/null || echo "$DATA_ROOT")"
case "$CANON" in
  "$REPO"|"$REPO"/*)
    echo "ОТКАЗ: DATA_ROOT внутри репозитория ($CANON)." >&2
    echo "Вынеси данные на отдельное монтирование." >&2
    exit 1
    ;;
esac

for d in torrents/movies torrents/tv media/movies media/tv \
         media/_test_movies media/_test_tv; do
  mkdir -p "$DATA_ROOT/$d"
done

chown -R "$PUID:$PGID" "$DATA_ROOT"
# 775 на каталоги, чтобы группа могла писать — нужно для совместной работы
# qBittorrent и *arr над одними файлами.
find "$DATA_ROOT" -type d -exec chmod 775 {} +

echo "==> проверка: torrents и media на одной файловой системе"
DEV_T="$(stat -c %d "$DATA_ROOT/torrents")"
DEV_M="$(stat -c %d "$DATA_ROOT/media")"
if [ "$DEV_T" != "$DEV_M" ]; then
  echo "ОТКАЗ: torrents ($DEV_T) и media ($DEV_M) на разных ФС." >&2
  echo "Жёсткие ссылки работать не будут. Смотри SPEC.md, раздел 1.7." >&2
  exit 1
fi

echo "==> проверка: жёсткая ссылка реально создаётся"
T="$DATA_ROOT/torrents/.hltest"
M="$DATA_ROOT/media/.hltest"
rm -f "$T" "$M"
echo probe > "$T"
if ! ln "$T" "$M" 2>/dev/null; then
  echo "ОТКАЗ: ln между torrents и media не сработал." >&2
  echo "Возможная причина: разные сабволюмы btrfs." >&2
  rm -f "$T"; exit 1
fi
LINKS="$(stat -c %h "$M")"
rm -f "$T" "$M"
if [ "$LINKS" -lt 2 ]; then
  echo "ОТКАЗ: счётчик ссылок $LINKS, ожидалось >= 2." >&2
  exit 1
fi

echo
echo "Готово. Раскладка создана, жёсткие ссылки работают."
echo "Напоминание: та же проверка внутри контейнера — checks/02-data-layout.sh."
