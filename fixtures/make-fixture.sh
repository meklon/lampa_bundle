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
: "${RADARR_API_KEY:?не задан RADARR_API_KEY}"
: "${TEST_RADARR_ROOT:?не задан TEST_RADARR_ROOT}"
: "${RADARR_PROFILE:?не задан RADARR_PROFILE}"

RADARR="http://localhost:7878"
r_get()  { curl -fsS -H "X-Api-Key: $RADARR_API_KEY" "$RADARR/api/v3$1" "${@:2}"; }
r_post() { curl -fsS -X POST -H "X-Api-Key: $RADARR_API_KEY" \
             -H 'Content-Type: application/json' -d "$2" "$RADARR/api/v3$1"; }

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

# ===========================================================================
# Сериальная ветка: ./fixtures/make-fixture.sh series
# ===========================================================================
# Сериалов с открытой лицензией и записью в TVDB практически нет, поэтому
# берётся tvdb_id настоящего сериала, а файлом кладётся та же короткометражка
# под именем SxxEyy. Sonarr сопоставляет по имени, а не по содержимому,
# так что импорт проверяется честно.
#
# Живёт ТОЛЬКО в выбрасываемом TEST_SONARR_ROOT.
if [ "$WHICH" = series ]; then
  : "${SONARR_API_KEY:?не задан SONARR_API_KEY}"
  : "${TEST_SONARR_ROOT:?не задан TEST_SONARR_ROOT}"
  : "${SONARR_PROFILE:?не задан SONARR_PROFILE}"
  : "${TMDB_TOKEN:?нужен TMDB_TOKEN: Sonarr работает по TVDB, а перевод
     TMDB->TVDB делается только через TMDB. Лукап Radarr тут не заменяет}"

  SONARR="http://localhost:8989"
  s_get()  { curl -fsS -H "X-Api-Key: $SONARR_API_KEY" "$SONARR/api/v3$1" "${@:2}"; }
  s_post() { curl -fsS -X POST -H "X-Api-Key: $SONARR_API_KEY" \
               -H 'Content-Type: application/json' -d "$2" "$SONARR/api/v3$1"; }

  q() { yq -r ".series[0].$1" fixtures/catalog.yml; }
  S_TMDB="$(q tmdb_id)"; S_TITLE="$(q title)"; S_SEASON="$(q season)"
  S_EPISODE="$(q episode)"; S_SRC="$(q source_file)"; S_REL="$(q release_name)"

  for v in S_TMDB S_TITLE S_SEASON S_EPISODE S_SRC S_REL; do
    case "${!v}" in ""|null)
      echo "ОТКАЗ: в catalog.yml не заполнено series[0].$v" >&2; exit 1 ;;
    esac
  done

  # -------------------------------------------------------------------------
  echo "==> перевожу tmdb_id -> tvdb_id через TMDB"
  # -------------------------------------------------------------------------
  # Ровно то, чем занимается bridge. Идентификатор перезапрашивается, а не
  # берётся из catalog.yml: там он только справочный.
  EXT_IDS="$(curl -fsS -H "Authorization: Bearer $TMDB_TOKEN" \
    "https://api.themoviedb.org/3/tv/$S_TMDB/external_ids")"
  S_TVDB="$(echo "$EXT_IDS" | jq -r '.tvdb_id // empty')"
  if [ -z "$S_TVDB" ] || [ "$S_TVDB" = null ]; then
    echo "ОТКАЗ: у tmdb_id=$S_TMDB нет tvdb_id в TMDB." >&2
    echo "Возьми другой сериал: Sonarr без tvdb_id добавить нельзя." >&2
    exit 1
  fi
  echo "    $S_TITLE: tmdb_id=$S_TMDB -> tvdb_id=$S_TVDB"

  # -------------------------------------------------------------------------
  echo "==> готовлю файл эпизода"
  # -------------------------------------------------------------------------
  SRC_REL="$(yq -r ".movies[] | select(.title==\"$S_SRC\") | .release_name" fixtures/catalog.yml)"
  SRC_FILE="$(find fixtures/data -maxdepth 1 -type f -name "$SRC_REL.*" | head -1)"
  if [ -z "$SRC_FILE" ]; then
    echo "ОТКАЗ: нет исходника «$S_SRC» в fixtures/data/." >&2
    echo "Сначала собери фильмовую фикстуру: ./fixtures/make-fixture.sh" >&2
    exit 1
  fi
  S_EXT="${SRC_FILE##*.}"
  S_DEST="$DATA_ROOT/torrents/tv/$S_REL"
  mkdir -p "$S_DEST"
  cp --update=none "$SRC_FILE" "$S_DEST/${S_REL}.${S_EXT}"
  chown -R "${PUID}:${PGID}" "$S_DEST"
  echo "    $S_DEST/${S_REL}.${S_EXT}"

  # -------------------------------------------------------------------------
  echo "==> добавляю сериал в Sonarr"
  # -------------------------------------------------------------------------
  if s_get /series | jq -e --argjson id "$S_TVDB" 'any(.[]; .tvdbId==$id)' >/dev/null; then
    echo "    уже в библиотеке Sonarr"
  else
    S_PROFILE="$(s_get /qualityprofile | jq -r --arg n "$SONARR_PROFILE" \
      '.[] | select(.name==$n) | .id')"
    [ -n "$S_PROFILE" ] || { echo "ОТКАЗ: профиль «$SONARR_PROFILE» не найден" >&2; exit 1; }

    S_TAG="$(s_get /tag | jq -r --arg l "${TEST_TAG:-test}" '.[] | select(.label==$l) | .id')"
    if [ -z "$S_TAG" ]; then
      S_TAG="$(s_post /tag "$(jq -n --arg l "${TEST_TAG:-test}" '{label:$l}')" | jq -r .id)"
    fi

    # Шаблон — от самого Sonarr, по ТОЧНОМУ tvdb-идентификатору.
    # Это не запрещённый поиск по названию: tvdb_id уже получен от TMDB,
    # lookup здесь только отдаёт форму объекта.
    TPL="$(s_get /series/lookup --get --data-urlencode "term=tvdb:$S_TVDB")"
    [ "$(echo "$TPL" | jq 'length')" = 1 ] \
      || { echo "ОТКАЗ: lookup по tvdb:$S_TVDB вернул не одного кандидата" >&2; exit 1; }

    # monitorNewItems="none" обязателен: по умолчанию "all", и тогда заказ
    # одного сезона превращается в подписку на сериал. seasonFolder по
    # умолчанию false, а docs/NAMING.md требует папки сезонов.
    S_BODY="$(echo "$TPL" | jq --argjson p "$S_PROFILE" --arg root "$TEST_SONARR_ROOT" \
      --argjson tag "$S_TAG" '.[0] + {
        qualityProfileId: $p,
        rootFolderPath:   $root,
        monitored:        true,
        seasonFolder:     true,
        monitorNewItems:  "none",
        tags:             [$tag],
        addOptions: { searchForMissingEpisodes: false, searchForCutoffUnmetEpisodes: false }
      }')"
    s_post /series "$S_BODY" >/dev/null
    echo "    добавлен в $TEST_SONARR_ROOT, monitorNewItems=none, seasonFolder=true"
  fi

  # -------------------------------------------------------------------------
  echo "==> создаю .torrent и добавляю в qBittorrent"
  # -------------------------------------------------------------------------
  S_TFILE="fixtures/${S_REL}.torrent"
  rm -f "$S_TFILE"
  if [ "$TORRENT_TOOL" = mktorrent ]; then
    mktorrent -p -a "http://localhost:6969/announce" -o "$S_TFILE" "$S_DEST"
  else
    transmission-create -p -t "http://localhost:6969/announce" -o "$S_TFILE" "$S_DEST"
  fi

  QBT="http://localhost:8081"
  S_COOKIE="${TMPDIR:-/tmp}/qbt.fixture.tv.cookie"
  curl -fsS -c "$S_COOKIE" -H "Referer: $QBT" \
    --data-urlencode "username=${QBITTORRENT_USER}" \
    --data-urlencode "password=${QBITTORRENT_PASSWORD}" \
    "$QBT/api/v2/auth/login" >/dev/null
  curl -fsS -b "$S_COOKIE" -H "Referer: $QBT" -X POST "$QBT/api/v2/torrents/add" \
    -F "torrents=@${S_TFILE}" \
    -F "category=sonarr" \
    -F "savepath=/data/torrents/tv" \
    -F "skip_checking=false" >/dev/null
  rm -f "$S_COOKIE"

  cat <<EOF

Готово.

  сериал:    $S_TITLE  S$(printf '%02d' "$S_SEASON")E$(printf '%02d' "$S_EPISODE")
  tmdb_id:   $S_TMDB  ->  tvdb_id: $S_TVDB
  релиз:     $S_REL
  данные:    $S_DEST

Дальше:
  ./checks/04-hardlink.sh
  ./checks/06-bridge-season.sh $S_TMDB $S_SEASON     (после этапа 5)
EOF
  exit 0
fi

TITLE="$(yq -r ".movies[] | select(.title==\"$WHICH\") | .title" fixtures/catalog.yml)"
YEAR="$(yq  -r ".movies[] | select(.title==\"$WHICH\") | .year"  fixtures/catalog.yml)"
URL="$(yq   -r ".movies[] | select(.title==\"$WHICH\") | .url"   fixtures/catalog.yml)"
RELNAME="$(yq -r ".movies[] | select(.title==\"$WHICH\") | .release_name" fixtures/catalog.yml)"

if [ -z "$TITLE" ] || [ "$TITLE" = null ]; then
  echo "нет записи «$WHICH» в catalog.yml" >&2
  exit 1
fi
if [ -z "$URL" ] || [ "$URL" = null ]; then
  echo "ОТКАЗ: в catalog.yml не заполнен url для «$TITLE»." >&2
  echo "Заполни прямой ссылкой на видеофайл и проверь, что она рабочая." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "==> разрешаю tmdb_id"
# ---------------------------------------------------------------------------
# Идентификатор именно разрешается, а не берётся из головы: неверный tmdb_id
# приведёт к тому, что тест проверит не тот фильм.
#
# Основной путь — TMDB. Запасной, когда токена ещё нет, — собственный лукап
# Radarr: он ходит в метаданные сам, нашего токена не требует.
#
# ВАЖНО про запасной путь. Он допустим ТОЛЬКО здесь, для стенда, и ТОЛЬКО с
# точным совпадением названия И года И единственным кандидатом. В bridge
# поиск по названию запрещён (см. таблицу подмен в CLAUDE.md): там нечёткое
# совпадение притащило бы не тот тайтл, и никто бы этого не заметил. Здесь
# результат сверяется с catalog.yml по двум полям и при неоднозначности
# скрипт отказывается работать, а не берёт первый попавшийся.
if [ -n "${TMDB_TOKEN:-}" ]; then
  echo "    источник: TMDB API"
  TMDB_JSON="$(curl -fsS -H "Authorization: Bearer $TMDB_TOKEN" \
    --get "https://api.themoviedb.org/3/search/movie" \
    --data-urlencode "query=$TITLE" \
    --data-urlencode "year=$YEAR")"
  MATCHES="$(echo "$TMDB_JSON" | jq --arg t "$TITLE" --argjson y "$YEAR" \
    '[.results[] | select(.title==$t and (.release_date // "" | startswith($y|tostring)))]')"
  ID_FIELD=id
else
  echo "    источник: лукап Radarr (TMDB_TOKEN не задан)"
  LOOKUP="$(r_get "/movie/lookup" --get --data-urlencode "term=$TITLE")"
  MATCHES="$(echo "$LOOKUP" | jq --arg t "$TITLE" --argjson y "$YEAR" \
    '[.[] | select(.title==$t and .year==$y)]')"
  ID_FIELD=tmdbId
fi

N="$(echo "$MATCHES" | jq 'length')"
if [ "$N" != 1 ]; then
  echo "ОТКАЗ: по «$TITLE» ($YEAR) найдено кандидатов: $N, а нужен ровно один." >&2
  echo "$MATCHES" | jq -r ".[] | \"     \(.$ID_FIELD)  \(.title)\"" >&2
  echo "Неоднозначность здесь означает, что стенд проверял бы не тот фильм." >&2
  exit 1
fi
TMDB_ID="$(echo "$MATCHES" | jq -r ".[0].$ID_FIELD")"
FOUND="$(echo "$MATCHES" | jq -r '.[0].title')"
echo "    tmdb_id=$TMDB_ID  ($FOUND, $YEAR)"

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
echo "==> добавляю фильм в Radarr"
# ---------------------------------------------------------------------------
# Без этого шага импортировать не во что: Radarr сопоставляет завершённую
# загрузку с фильмом из своей библиотеки, а не заводит его сам.
#
# Стенд идёт в ОТДЕЛЬНЫЙ тестовый root folder и помечается тегом из TEST_TAG,
# чтобы потом отличить и снести целиком, не разбирая настоящую библиотеку.
if r_get /movie | jq -e --argjson id "$TMDB_ID" 'any(.[]; .tmdbId==$id)' >/dev/null; then
  echo "    уже в библиотеке Radarr"
else
  PROFILE_ID="$(r_get /qualityprofile | jq -r --arg n "$RADARR_PROFILE" \
    '.[] | select(.name==$n) | .id')"
  [ -n "$PROFILE_ID" ] || { echo "ОТКАЗ: профиль «$RADARR_PROFILE» не найден" >&2; exit 1; }

  TAG_ID="$(r_get /tag | jq -r --arg l "${TEST_TAG:-test}" '.[] | select(.label==$l) | .id')"
  if [ -z "$TAG_ID" ]; then
    TAG_ID="$(r_post /tag "$(jq -n --arg l "${TEST_TAG:-test}" '{label:$l}')" | jq -r .id)"
  fi

  # Шаблон — объект от самого Radarr, а не собранный руками: состав полей
  # MovieResource по памяти не воспроизводится.
  BODY="$(r_get "/movie/lookup/tmdb?tmdbId=$TMDB_ID" | jq \
    --argjson p "$PROFILE_ID" --arg root "$TEST_RADARR_ROOT" \
    --argjson tag "$TAG_ID" --arg ma "${RADARR_MIN_AVAILABILITY:-released}" '
      . + { qualityProfileId: $p,
            rootFolderPath:   $root,
            minimumAvailability: $ma,
            monitored: true,
            tags: [$tag],
            # Поиск не запускается: релиз уже лежит локально, индексаторов
            # нет, а в dev-режиме реальная загрузка не вызывается вообще.
            addOptions: { searchForMovie: false } }')"

  r_post /movie "$BODY" >/dev/null
  echo "    добавлен в $TEST_RADARR_ROOT, профиль $RADARR_PROFILE, тег ${TEST_TAG:-test}"
fi

# ---------------------------------------------------------------------------
echo "==> добавляю в qBittorrent"
# ---------------------------------------------------------------------------
COOKIE="${TMPDIR:-/tmp}/qbt.fixture.cookie"
QBT="http://localhost:8081"
# Referer обязателен: WebUI qBittorrent 5.x без него отвечает 403 на любой
# вызов, включая логин. Проверено на 5.2.3.
curl -fsS -c "$COOKIE" -H "Referer: $QBT" \
  --data-urlencode "username=${QBITTORRENT_USER}" \
  --data-urlencode "password=${QBITTORRENT_PASSWORD}" \
  "$QBT/api/v2/auth/login" >/dev/null

curl -fsS -b "$COOKIE" -H "Referer: $QBT" -X POST "$QBT/api/v2/torrents/add" \
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
