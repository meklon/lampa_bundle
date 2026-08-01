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

# ---------------------------------------------------------------------------
# Коммит, а не только тег
# ---------------------------------------------------------------------------
# docs/ACCEPTANCE.md требует записи «с версией И коммитом». Тег — подвижная
# ссылка: его можно передвинуть на другой коммит, и тогда файл в openapi/
# перестанет соответствовать тому, что написано в SOURCES.md, молча.
# Разрешаем тег в конкретный sha, а заодно считаем контрольную сумму файла.
#
# Владелец и репозиторий выводятся из самого URL, чтобы не заводить ещё один
# аргумент, который можно передать не тот.
COMMIT="?"
case "$URL" in
  https://raw.githubusercontent.com/*)
    REST="${URL#https://raw.githubusercontent.com/}"
    OWNER="${REST%%/*}"; REST="${REST#*/}"
    REPO="${REST%%/*}"
    COMMIT="$(curl -fsS "https://api.github.com/repos/$OWNER/$REPO/commits/$REF" \
                | jq -r '.sha // "?"' 2>/dev/null || echo "?")"
    ;;
esac
SHA256="$(sha256sum "$OUT" | cut -d' ' -f1)"

# Запись идемпотентна: повторный запуск заменяет прежний блок для этого файла,
# а не дописывает второй. Иначе SOURCES.md со временем превращается в журнал,
# в котором непонятно, какая запись действующая.
python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = sys.argv[1]
p = pathlib.Path("openapi/SOURCES.md")
text = p.read_text(encoding="utf-8")
name = out[len("openapi/"):]
# Блок начинается с "## " и содержит строку с этим именем файла.
blocks = re.split(r"(?m)^(?=## )", text)
kept = [b for b in blocks if f"`{name}`" not in b]
p.write_text("".join(kept).rstrip() + "\n", encoding="utf-8")
PY

{
  echo
  echo "## ${SERVICE} ${API}"
  echo
  echo "- файл: \`${OUT#openapi/}\`"
  echo "- версия: \`${REF}\`"
  echo "- коммит: \`${COMMIT}\`"
  echo "- sha256: \`${SHA256}\`"
  echo "- источник: ${URL}"
  echo "- скачано: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- путей в схеме: ${PATHS}"
} >> openapi/SOURCES.md

echo "==> SOURCES.md: версия ${REF}, коммит ${COMMIT:0:12}"
echo
echo "Следующий шаг: ./scripts/check-versions.sh — сверить с живым инстансом."
