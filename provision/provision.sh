#!/usr/bin/env bash
# Приведение стека в известное состояние.
#
# ИДЕМПОТЕНТЕН: повторный запуск на уже настроенном стеке не создаёт
# дубликатов и не падает. Это требование, а не пожелание — скрипт
# запускается и на чистой ВМ, и на работающем сервере.
#
# Индексаторы НЕ добавляются: их добавляет человек, вручную, на последнем
# этапе. См. CLAUDE.md, раздел про безопасность при разработке.
set -euo pipefail

cd "$(dirname "$0")"

for s in 10-qbittorrent.sh 20-prowlarr.sh 30-radarr.sh 40-sonarr.sh; do
  echo
  echo "############ $s"
  bash "./$s"
done

echo
echo "############ готово"
echo
echo "Дальше по docs/ACCEPTANCE.md:"
echo "  ./checks/01-containers.sh"
echo "  ./checks/02-data-layout.sh"
echo "  ./checks/03-prowlarr-sync.sh   (после добавления индексатора человеком)"
