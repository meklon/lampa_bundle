#!/usr/bin/env bash
# Разовая подготовка перед первым `docker compose up`.
#
# Существует ради одной вещи: убрать курицу с яйцом. Раньше ключи API
# генерировались при первом старте *arr, поэтому заполнить их в .env заранее
# было нельзя, и установка требовала двух запусков стека с ручным выдёргиванием
# ключей посередине.
#
# Проверено опытом: Radarr принимает ЗАРАНЕЕ заданный <ApiKey> в config.xml и
# сохраняет его. Значит ключи можно сгенерировать самим до первого старта.
#
# После этого скрипта установка сводится к `docker compose up -d`.
#
# ИДЕМПОТЕНТЕН: уже заданные значения не перезаписывает. Повторный запуск
# безопасен и ничего не ломает.
set -euo pipefail

cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "нужна утилита $1" >&2; exit 1; }; }
need docker; need curl; need openssl

log()  { printf '     %s\n' "$*"; }
step() { printf '==>  %s\n' "$*"; }
die()  { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }

[ -f .env ] || die "нет .env. Скопируй .env.example и заполни пути, теги и TMDB_TOKEN."

# shellcheck disable=SC1091
set -a; . ./.env; set +a

# ---------------------------------------------------------------------------
step "проверка обязательного"
# ---------------------------------------------------------------------------
# Эти значения человек обязан задать сам: угадать их нельзя.
for v in DATA_ROOT TORRENTS_PATH MOVIES_PATH TV_PATH \
         QBITTORRENT_TAG PROWLARR_TAG RADARR_TAG SONARR_TAG LAMPAC_TAG; do
  [ -n "${!v:-}" ] || die "в .env не задан $v"
done

case "${TMDB_TOKEN:-}" in
  "") die "в .env не задан TMDB_TOKEN. Нужен Bearer-токен v4 (Read Access Token)." ;;
  eyJ*) log "TMDB_TOKEN похож на v4 — годится" ;;
  *) die "TMDB_TOKEN не похож на v4: он должен начинаться с eyJ.
     32 символа hex — это ключ v3, он передаётся иначе и работать не будет." ;;
esac

case "${CORS_ORIGINS:-}" in
  *ЗАПОЛНИТЬ*|"") die "в .env не задан CORS_ORIGINS. Это адрес СТРАНИЦЫ Lampa
     (обычно Lampac на :9118), а не адрес bridge. Без него браузер заблокирует
     заказ, и в интерфейсе это будет выглядеть как «bridge недоступен»." ;;
esac
log "обязательное на месте"

# ---------------------------------------------------------------------------
step "ключи API для *arr"
# ---------------------------------------------------------------------------
# set_env <ИМЯ> <значение> — вписывает значение в .env, если оно пустое.
set_env() {
  local name="$1" value="$2"
  if grep -qE "^${name}=.+" .env; then
    log "$name уже задан — не трогаю"
    return 0
  fi
  if grep -qE "^${name}=" .env; then
    # Значение подставляется через python: sed сломался бы на слэшах и
    # спецсимволах, которых в ключах и паролях хватает.
    python3 - "$name" "$value" <<'PY'
import pathlib, sys
name, value = sys.argv[1], sys.argv[2]
p = pathlib.Path('.env')
lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
out = []
for line in lines:
    if line.startswith(f'{name}='):
        out.append(f'{name}={value}\n')
    else:
        out.append(line)
p.write_text(''.join(out), encoding='utf-8')
PY
  else
    printf '%s=%s\n' "$name" "$value" >> .env
  fi
  log "$name записан"
}

# seed_arr <service> <port> <env-name>
# Кладёт config.xml с готовым ключом ДО первого старта. Если конфиг уже есть,
# ключ берётся из него: перезаписывать работающую установку нельзя.
seed_arr() {
  local svc="$1" port="$2" env_name="$3" key cfg="config/$1/config.xml"

  if [ -f "$cfg" ]; then
    key="$(grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" || true)"
    [ -n "$key" ] || die "$cfg есть, но ключа в нём нет — разберись руками"
    log "$svc: конфиг уже есть, беру ключ из него"
  else
    key="$(openssl rand -hex 16)"
    mkdir -p "config/$svc"
    cat > "$cfg" <<XML
<Config>
  <ApiKey>$key</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Port>$port</Port>
  <UrlBase></UrlBase>
  <InstanceName>$svc</InstanceName>
  <LogLevel>info</LogLevel>
</Config>
XML
    chown -R "${PUID}:${PGID}" "config/$svc" 2>/dev/null || true
    log "$svc: сгенерирован ключ и создан config.xml"
  fi
  set_env "$env_name" "$key"
}

seed_arr radarr   7878 RADARR_API_KEY
seed_arr sonarr   8989 SONARR_API_KEY
seed_arr prowlarr 9696 PROWLARR_API_KEY

# ---------------------------------------------------------------------------
step "раскладка каталогов"
# ---------------------------------------------------------------------------
./scripts/init-data.sh

# ---------------------------------------------------------------------------
step "пароль qBittorrent"
# ---------------------------------------------------------------------------
# Единственное, что нельзя подготовить заранее: qBittorrent хранит пароль
# хешем PBKDF2 в своём конфиге, а временный пароль генерируется при первом
# старте и МЕНЯЕТСЯ при каждом перезапуске, пока не задан постоянный.
#
# Поэтому здесь он поднимается один, у него забирается временный пароль и
# ставится постоянный. Дальше стек можно поднимать целиком сколько угодно раз.
if grep -qE '^QBITTORRENT_PASSWORD=.+' .env; then
  log "пароль уже задан — не трогаю"
else
  log "поднимаю qBittorrent, чтобы забрать временный пароль"
  docker compose up -d qbittorrent >/dev/null

  QBT="http://localhost:8081"
  TMP_PW=""
  for _ in $(seq 1 30); do
    TMP_PW="$(docker compose logs qbittorrent 2>&1 \
      | grep -oP '(?<=temporary password is provided for this session: )\S+' | tail -1)"
    [ -n "$TMP_PW" ] && break
    sleep 2
  done
  [ -n "$TMP_PW" ] || die "не дождался временного пароля в логах qBittorrent"

  NEW_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  COOKIE="$(mktemp)"
  # Referer обязателен: WebUI qBittorrent 5.x без него отвечает 403 на любой
  # вызов, включая логин.
  code="$(curl -sS -o /dev/null -w '%{http_code}' -c "$COOKIE" -H "Referer: $QBT" \
    --data-urlencode "username=${QBITTORRENT_USER:-admin}" \
    --data-urlencode "password=$TMP_PW" "$QBT/api/v2/auth/login")"
  case "$code" in
    200|204) : ;;
    *) rm -f "$COOKIE"; die "вход по временному паролю не удался: HTTP $code" ;;
  esac

  curl -fsS -b "$COOKIE" -H "Referer: $QBT" -X POST "$QBT/api/v2/app/setPreferences" \
    --data-urlencode "json={\"web_ui_password\":\"$NEW_PW\"}" >/dev/null \
    || { rm -f "$COOKIE"; die "не удалось задать постоянный пароль"; }
  rm -f "$COOKIE"

  set_env QBITTORRENT_USER "${QBITTORRENT_USER:-admin}"
  set_env QBITTORRENT_PASSWORD "$NEW_PW"
fi

# ---------------------------------------------------------------------------
cat <<'EOF'

Готово. Дальше:

  docker compose up -d

Стек поднимется целиком и сам себя настроит: сервис provision дождётся
готовности остальных и приведёт конфигурацию к описанной в репозитории.
Он идемпотентен, поэтому запускается при каждом up и заодно чинит ручные
правки, сделанные через веб-морды.

Потом:

  ./checks/01-containers.sh
  ./checks/02-data-layout.sh

И установка плагина на телефон — см. README.md, раздел «Подключение с телефона».
EOF
