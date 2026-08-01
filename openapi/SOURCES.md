# SOURCES.md

Происхождение схем в этом каталоге. Записи дописываются автоматически
скриптом `scripts/fetch-openapi.sh`.

**Схемы не отдаются живым инстансом** по `/api/v3/openapi.json` — на
production-сборках этого пути нет, Swagger UI поднимается только в
debug-режиме. Схемы берутся из исходников проектов на GitHub.

Путь в исходниках Radarr: `src/Radarr.Api.V3/openapi.json`.
У Sonarr — аналогичный путь в его репозитории; фактический путь для нужного
тега уточнить, не угадывать.

**Версия схемы обязана соответствовать версии запущенного контейнера.**
Сверяется `scripts/check-versions.sh`, расхождение — стоп-условие №2.

---

## radarr v3

- файл: `radarr-v3-v6.3.0.10514.json`
- версия: `v6.3.0.10514`
- коммит: `7827e5368947f158ad06f757334f5cde6c406411`
- sha256: `95ea9062485118d6a8abed8250b9bfbf94e4de0f55e9c5611da6805864f9a26e`
- источник: https://raw.githubusercontent.com/Radarr/Radarr/v6.3.0.10514/src/Radarr.Api.V3/openapi.json
- скачано: 2026-08-01T10:41:19Z
- путей в схеме: 164

## sonarr v3

- файл: `sonarr-v3-v4.0.19.2979.json`
- версия: `v4.0.19.2979`
- коммит: `4ff1b780010d3d9ec76a4864dce96b6494e9caea`
- sha256: `3fd4c4f4385b1043c3568bd3b37fa6c3c0161135072962dffb611f4ff270e2b7`
- источник: https://raw.githubusercontent.com/Sonarr/Sonarr/v4.0.19.2979/src/Sonarr.Api.V3/openapi.json
- скачано: 2026-08-01T10:41:20Z
- путей в схеме: 162

## prowlarr v1

- файл: `prowlarr-v1-v2.5.2.5491.json`
- версия: `v2.5.2.5491`
- коммит: `c0f8c2c5bc0d7906e8d97e30a9bb7616f37d7090`
- sha256: `efe3dfb9a928658d8a1f2f307a965fb1275bad2853012a2f9bdc2404215d0fbb`
- источник: https://raw.githubusercontent.com/Prowlarr/Prowlarr/v2.5.2.5491/src/Prowlarr.Api.V1/openapi.json
- скачано: 2026-08-01T10:41:20Z
- путей в схеме: 93
