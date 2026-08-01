#!/usr/bin/env bash
# Развёртывание на реальном сервере. Только main.
#
# Прямого пути от агента до продакшена быть не должно: агент пушит в
# stage/*-ветки, человек мержит в main, main разворачивается здесь.
set -euo pipefail

cd "$(dirname "$0")"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "ОТКАЗ: deploy.sh запускается только из main, текущая ветка: $BRANCH" >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo "ОТКАЗ: нет .env. Скопируй .env.example и заполни." >&2
  exit 1
fi

echo "==> git pull"
git pull --ff-only

echo "==> проверка соответствия схем версиям инстансов"
./scripts/check-versions.sh

echo "==> сборка и запуск"
docker compose up -d --build

echo "==> проверка живости"
./checks/01-containers.sh

echo
echo "Готово. Напоминание: перед обновлением версий *arr сделай снапшот —"
echo "миграции БД односторонние."
