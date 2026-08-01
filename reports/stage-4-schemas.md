# Этап 4: схемы API

**Статус:** завершён
**Ветка:** stage/4-schemas
**Дата:** 2026-08-01

---

## Что сделано

Схемы скачаны **из исходников проектов по тегам, соответствующим запущенным
контейнерам**, а не из main-ветки:

| Сервис | Тег | Коммит | Путей в схеме |
|---|---|---|---|
| Radarr v3 | `v6.3.0.10514` | `7827e5368947` | 164 |
| Sonarr v3 | `v4.0.19.2979` | `4ff1b780010d` | 162 |
| Prowlarr v1 | `v2.5.2.5491` | `c0f8c2c5bc0d` | 93 |

Пути к файлам в исходниках не угадывались, а найдены обходом дерева
репозитория на нужном теге через GitHub API:

```
src/Radarr.Api.V3/openapi.json
src/Sonarr.Api.V3/openapi.json
src/Prowlarr.Api.V1/openapi.json
```

Для Sonarr и Prowlarr путь оказался аналогичен радарровскому, но это
проверено, а не предположено — в `SOURCES.md` прямо стояло «уточнить, не
угадывать».

---

## Правка `scripts/fetch-openapi.sh`

`docs/ACCEPTANCE.md` требует записи в `SOURCES.md` «с версией **и коммитом**»,
а скрипт писал только тег. Тег — подвижная ссылка: его можно передвинуть на
другой коммит, и файл в `openapi/` молча перестанет соответствовать записи.

Добавлено:

- разрешение тега в конкретный `sha` через GitHub API (владелец и репозиторий
  выводятся из самого URL, чтобы не заводить ещё один аргумент, который можно
  передать не тот);
- `sha256` скачанного файла;
- **идемпотентность записи**: повторный запуск заменяет прежний блок для того
  же файла, а не дописывает второй. Иначе `SOURCES.md` со временем
  превращается в журнал, где непонятно, какая запись действующая. Проверено:
  после четырёх запусков в файле три блока.

---

## Проверки

| Проверка | Результат |
|---|---|
| `scripts/check-versions.sh` | прошёл, код 0 |
| `pre-commit run --all-files` | прошла |

```
[ok] radarr 6.3.0.10514  <-  openapi/radarr-v3-v6.3.0.10514.json
[ok] sonarr 4.0.19.2979  <-  openapi/sonarr-v3-v4.0.19.2979.json
[ok] prowlarr 2.5.2.5491 <-  openapi/prowlarr-v1-v2.5.2.5491.json
```

Стоп-условие №2 не наступило: версии схем совпадают с версиями живых
инстансов.

---

## Проверка полей, на которые рассчитывает этап 5

Отсутствие любого из них — стоп-условие №1, и узнать об этом лучше сейчас,
чем на середине этапа 5.

**Radarr, `MovieResource`** — все поля из `SPEC.md` 2.4 на месте:
`tmdbId` (integer), `qualityProfileId` (integer), `rootFolderPath` (string),
`monitored` (boolean), `minimumAvailability` (`MovieStatusType`),
`addOptions` (`AddMovieOptions`).

`AddMovieOptions`: `addMethod`, `ignoreEpisodesWithFiles`,
`ignoreEpisodesWithoutFiles`, `monitor`, `searchForMovie`.

**Sonarr, `SeriesResource`** — на месте `tvdbId`, `qualityProfileId`,
`rootFolderPath`, `monitored`, `seasonFolder`, `monitorNewItems`, `seasons`,
`addOptions`.

`monitorNewItems` допускает ровно `["all", "none"]` — то, что записано в
`SPEC.md`, подтверждено схемой.

**`POST /api/v3/seasonpass`** существует. Форма:

```
SeasonPassResource      { series: [SeasonPassSeriesResource], monitoringOptions: MonitoringOptions }
SeasonPassSeriesResource { id: int, monitored: bool, seasons: [SeasonResource] }
SeasonResource           { seasonNumber, monitored, images, statistics }
```

Совпадает с тем, что описано в `SPEC.md` 2.5.

---

## Гипотезы, которые подтвердились

**Открытый вопрос №3 закрыт.** Состав полей `POST /api/v3/movie` из `SPEC.md`
2.4 подтверждён схемой целиком. Перенесён в закрытые.

**`monitorNewItems` со значением `none` существует** и является полем
`SeriesResource`, а не глобальной настройкой.

---

## Гипотезы, которые НЕ подтвердились

### У Sonarr `colonReplacementFormat` не документирован enum'ом

На этапе 2 поле было намеренно не тронуто с формулировкой «расшифровка
числового enum'а появится в схеме на этапе 4». **Не появилась.**

```
Radarr: "$ref": "#/components/schemas/ColonReplacementFormat"
        enum: ["delete","dash","spaceDash","spaceDashSpace","smart"]
Sonarr: { "type": "integer", "format": "int32" }
        отдельной схемы ColonReplacementFormat нет
```

То есть схема — источник истины по **именам** полей, но по **значениям** этого
конкретного поля у Sonarr она молчит. Решение этапа 2 не трогать поле остаётся
в силе, теперь уже как окончательное, а не временное. Кому понадобится его
задать — придётся выставить через веб-морду и прочитать значение обратно.

Занесено в `docs/NAMING.md`.

### Список значений `addOptions.monitor` в комментарии к коду неполон

Докстрока в `bridge/app/sonarr.py` перечисляет:
`all | future | missing | existing | pilot | firstSeason | latestSeason | none`
плюс `monitorSpecials` / `unmonitorSpecials`.

Схема даёт 14 значений: `unknown`, `all`, `future`, `missing`, `existing`,
`firstSeason`, `lastSeason`, `latestSeason`, `pilot`, `recent`,
`monitorSpecials`, `unmonitorSpecials`, `none`, `skip`.

Отсутствовали `unknown`, `lastSeason`, `recent`, `skip`. На нас это не влияет
— нужен `none`, и он есть, — но докстрока как справочник неточна.

### Хук pre-commit молча портил вендоренные схемы

`end-of-file-fixer` дописал перевод строки во все три файла `openapi/`. После
этого `sha256`, записанный в `SOURCES.md`, перестал сходиться с содержимым —
у всех трёх:

```
prowlarr:  записано efe3dfb9a928658d…   файл 30409d74395727c9…
radarr:    записано 95ea9062485118d6…   файл 0d6a9caeb1d4e27f…
sonarr:    записано 3fd4c4f4385b1043…   файл 9c35a1c457f22c5a…
```

Смысл записи о происхождении в том и состоит, чтобы по ней можно было
убедиться: файл в репозитории тот же, что в исходниках проекта. Фиксер это
свойство ломает, и ломает молча — файл выглядит прежним.

Исправлено: `openapi/*.json` исключён из `end-of-file-fixer` и
`trailing-whitespace`. Схемы перекачаны, суммы сошлись у всех трёх.

Обнаружилось только потому, что `sha256` вообще записывается. Без него
расхождение осталось бы незамеченным.

### Команды не описаны схемой

`POST /api/v3/command` принимает `application/json` без описанной структуры
конкретных команд: отдельной схемы `SeasonSearch` в `components` нет. Значит
имя команды и её параметры схемой не подтверждаются, и на этапе 5 их
корректность проверится только фактическим вызовом.

---

## Стоп-условия

Не сработали.

---

## Открытые вопросы

**Открытый вопрос №1 схемой не решается.** Она подтверждает, что `seasons`
входит в `SeriesResource`, а `addOptions.monitor` существует, — но не
описывает, что произойдёт при передаче обоих одновременно: переопределит ли
`monitor` флаги в момент добавления. Это вопрос поведения, а не формы, и
закрывается только опытом на живом Sonarr. Остаётся открытым до этапа 5,
принятый путь прежний — два шага.
