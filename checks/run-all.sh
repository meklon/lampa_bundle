#!/usr/bin/env bash
# Прогон всех проверок, не требующих аргументов.
#
# 05, 06 и 07 требуют аргументов (tmdb_id, номер сезона, ожидаемый путь)
# и запускаются отдельно. См. docs/ACCEPTANCE.md.
set -uo pipefail

cd "$(dirname "$0")" || exit 1
RC=0

# 08 идёт последним по номеру, но аргументов не требует и потому здесь:
# нумерация файлов следует за этапами, а этот список — за наличием аргументов.
for c in 01-containers.sh 02-data-layout.sh 03-prowlarr-sync.sh 04-hardlink.sh \
         08-qbt-savepath.sh; do
  echo
  echo "############ $c"
  bash "./$c" || RC=1
done

echo
echo "############ Требуют аргументов, запускать вручную:"
echo "  ./05-bridge-movie.sh  <tmdb_id>"
echo "  ./06-bridge-season.sh <tmdb_id> <season>"
echo "  ./07-pipeline.sh      <ожидаемый-путь-от-/data/media>"

exit "$RC"
