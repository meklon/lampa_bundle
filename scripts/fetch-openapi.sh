#!/usr/bin/env bash
# Скачивание схем OpenAPI.
#
# ВАЖНО: схемы НЕ отдаются живым инстансом по /api/v3/openapi.json —
# на production-сборках этого пути нет, Swagger UI поднимается только
# в debug-режиме. Схемы лежат в исходниках проектов на GitHub.
#
# Скрипт записывает схему вместе с версией в имени файла и дописывает
# запись в openapi/SOURCES.md.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p openapi

usage() {
  cat >&2 <<'EOF'
Использование:
  fetch-openapi.sh <service> <ref> <raw-url>

  service   radarr | sonarr | prowlarr
  ref       тег или коммит, который скачиваем (для записи в SOURCES.md)
  raw-url   прямая ссылка на openapi.json в raw.githubusercontent.com

Путь к схеме в исходниках Radarr: src/Radarr.Api.V3/openapi.json
У Sonarr — аналогичный путь в его репозитории. Уточни фактический путь
для нужного тега, не угадывай.

Пример:
  ./scripts/fetch-openapi.sh radarr v5.x.y \
    https://raw.githubusercontent.com/Radarr/Radarr/v5.x.y/src/Radarr.Api.V3/openapi.json
EOF
  exit 1
}

[ $# -eq 3 ] || usage

SERVICE="$1"; REF="$2"; URL="$3"
case "$SERVICE" in
  radarr|sonarr) API="v3" ;;
  prowlarr)      API="v1" ;;
  *) echo "неизвестный сервис: $SERVICE" >&2; usage ;;
esac

OUT="openapi/${SERVICE}-${API}-${REF}.json"

echo "==> $URL"
curl -fsSL "$URL" -o "$OUT"

# Минимальная валидация: это должен быть JSON со схемой OpenAPI
if ! jq -e '.openapi // .swagger' "$OUT" >/dev/null 2>&1; then
  echo "ОТКАЗ: $OUT не похож на схему OpenAPI." >&2
  rm -f "$OUT"; exit 1
fi

PATHS="$(jq '.paths | length' "$OUT")"
echo "==> сохранено: $OUT (путей в схеме: $PATHS)"

{
  echo
  echo "## ${SERVICE} ${API}"
  echo
  echo "- файл: \`${OUT#openapi/}\`"
  echo "- ref: \`${REF}\`"
  echo "- источник: ${URL}"
  echo "- скачано: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- путей в схеме: ${PATHS}"
} >> openapi/SOURCES.md

echo "==> запись добавлена в openapi/SOURCES.md"
echo
echo "Следующий шаг: ./scripts/check-versions.sh — сверить с живым инстансом."
