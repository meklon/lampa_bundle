#!/usr/bin/env bash
# Сборка локального тестового торрента.
#
# Зачем не реальный трекер: раздача — самое недетерминированное звено
# цепочки (есть ли она сегодня, сколько сидов, какая скорость), а приватные
# трекеры банят за поток запросов из отладочного цикла. Бан и рейтинг
# необратимы.
#
# Локальный торрент: данные уже на месте, поэтому 100% сразу, сеть не нужна,
# результат воспроизводим.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${DATA_ROOT:?не задан DATA_ROOT}"
: "${TMDB_TOKEN:?не задан TMDB_TOKEN}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "нужна утилита $1" >&2; exit 1; }; }
need curl; need jq; need yq
# Создание .torrent: подойдёт mktorrent или transmission-create
TORRENT_TOOL=""
command -v mktorrent >/dev/null 2>&1 && TORRENT_TOOL=mktorrent
[ -z "$TORRENT_TOOL" ] && command -v transmission-create >/dev/null 2>&1 \
  && TORRENT_TOOL=transmission-create
[ -n "$TORRENT_TOOL" ] || { echo "нужен mktorrent или transmission-create" >&2; exit 1; }

WHICH="${1:-Big Buck Bunny}"
mkdir -p fixtures/data

TITLE="$(yq -r ".movies[] | select(.title==\"$WHICH\") | .title" fixtures/catalog.yml)"
YEAR="$(yq  -r ".movies[] | select(.title==\"$WHICH\") | .year"  fixtures/catalog.yml)"
URL="$(yq   -r ".movies[] | select(.title==\"$WHICH\") | .url"   fixtures/catalog.yml)"
RELNAME="$(yq -r ".movies[] | select(.title==\"$WHICH\") | .release_name" fixtures/catalog.yml)"

[ -n "$TITLE" ] && [ "$TITLE" != null ] || { echo "нет записи «$WHICH» в catalog.yml" >&2; exit 1; }
if [ -z "$URL" ] || [ "$URL" = null ]; then
  echo "ОТКАЗ: в catalog.yml не заполнен url для «$TITLE»." >&2
  echo "Заполни прямой ссылкой на видеофайл и проверь, что она рабочая." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "==> разрешаю tmdb_id через TMDB API"
# ---------------------------------------------------------------------------
# Идентификатор именно разрешается, а не берётся из головы: неверный tmdb_id
# приведёт к тому, что тест проверит не тот фильм.
TMDB_JSON="$(curl -fsS -H "Authorization: Bearer $TMDB_TOKEN" \
  --get "https://api.themoviedb.org/3/search/movie" \
  --data-urlencode "query=$TITLE" \
  --data-urlencode "year=$YEAR")"

TMDB_ID="$(echo "$TMDB_JSON" | jq -r '.results[0].id // empty')"
FOUND="$(echo "$TMDB_JSON" | jq -r '.results[0].title // empty')"
[ -n "$TMDB_ID" ] || { echo "ОТКАЗ: «$TITLE» ($YEAR) не найден в TMDB." >&2; exit 1; }
echo "    tmdb_id=$TMDB_ID  ($FOUND)"

# ---------------------------------------------------------------------------
echo "==> скачиваю материал"
# ---------------------------------------------------------------------------
EXT="${URL##*.}"
case "$EXT" in mkv|mp4|avi) : ;; *) EXT=mp4 ;; esac
SRC="fixtures/data/${RELNAME}.${EXT}"
if [ -f "$SRC" ]; then
  echo "    уже скачано: $SRC"
else
  curl -fL --progress-bar "$URL" -o "$SRC"
fi

SIZE_MB=$(( $(stat -c %s "$SRC") / 1024 / 1024 ))
echo "    размер: ${SIZE_MB} МБ"
if [ "$SIZE_MB" -lt 50 ]; then
  echo "ПРЕДУПРЕЖДЕНИЕ: файл мал (${SIZE_MB} МБ)." >&2
  echo "*arr могут отбросить его как sample. Возьми полноразмерную версию." >&2
fi

# ---------------------------------------------------------------------------
echo "==> раскладываю в торрент-каталог"
# ---------------------------------------------------------------------------
# Данные ложатся туда, куда указывает категория qBittorrent «radarr»,
# поэтому торрент проверится как завершённый сразу.
DEST_DIR="$DATA_ROOT/torrents/movies/$RELNAME"
mkdir -p "$DEST_DIR"
cp -n "$SRC" "$DEST_DIR/${RELNAME}.${EXT}"
chown -R "${PUID}:${PGID}" "$DEST_DIR"

# ---------------------------------------------------------------------------
echo "==> создаю .torrent"
# ---------------------------------------------------------------------------
TFILE="fixtures/${RELNAME}.torrent"
rm -f "$TFILE"
if [ "$TORRENT_TOOL" = mktorrent ]; then
  # Приватный флаг и фиктивный анонс: торрент никуда не объявляется
  mktorrent -p -a "http://localhost:6969/announce" -o "$TFILE" "$DEST_DIR"
else
  transmission-create -p -t "http://localhost:6969/announce" -o "$TFILE" "$DEST_DIR"
fi
echo "    $TFILE"

# ---------------------------------------------------------------------------
echo "==> добавляю в qBittorrent"
# ---------------------------------------------------------------------------
COOKIE="${TMPDIR:-/tmp}/qbt.fixture.cookie"
curl -fsS -c "$COOKIE" \
  --data-urlencode "username=${QBITTORRENT_USER}" \
  --data-urlencode "password=${QBITTORRENT_PASSWORD}" \
  "http://localhost:8081/api/v2/auth/login" >/dev/null

curl -fsS -b "$COOKIE" -X POST "http://localhost:8081/api/v2/torrents/add" \
  -F "torrents=@${TFILE}" \
  -F "category=radarr" \
  -F "savepath=/data/torrents/movies" \
  -F "skip_checking=false" >/dev/null
rm -f "$COOKIE"

cat <<EOF

Готово.

  фильм:     $FOUND ($YEAR)
  tmdb_id:   $TMDB_ID
  релиз:     $RELNAME
  данные:    $DEST_DIR

Дальше:
  1. Дождись, пока qBittorrent проверит данные и покажет 100%
  2. Впиши ожидаемый путь после импорта в docs/NAMING.md
  3. ./checks/07-pipeline.sh '<ожидаемый-путь-от-/data/media>'
  4. ./checks/04-hardlink.sh

Для проверки bridge:
  ./checks/05-bridge-movie.sh $TMDB_ID
EOF
