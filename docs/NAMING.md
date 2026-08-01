# NAMING.md

Схема именования файлов и каталогов. Источник истины для `provision/30-radarr.sh`
и `provision/40-sonarr.sh`, а также для ожидаемых путей в `checks/07-pipeline.sh`.

---

## Почему фиксируется сейчас

Kodi вне скоупа разработки. Но схема имён фиксируется **до** первого импорта,
потому что иначе агент выберет свою, библиотека наполнится, а при подключении
Kodi придётся переименовывать всё разом.

---

## Откуда взяты строки

Из машиночитаемого источника TRaSH Guides, не с отрендеренной страницы: в
markdown там только Jinja-подстановки вида
`{{ radarr['naming']['radarr-naming']['file']['standard'] }}`, самих строк нет.

| Файл | Коммит | Дата |
|---|---|---|
| `TRaSH-Guides/Guides:docs/json/radarr/naming/radarr-naming.json` | `29ab6e5ed003` | 2026-04-01 |
| `TRaSH-Guides/Guides:docs/json/sonarr/naming/sonarr-naming.json` | `a7e9914d454b` | 2026-06-06 |

Взяты варианты **Standard**, а не Plex, Emby или Jellyfin: те добавляют в имя
`{imdb-…}` или `[tmdbid-…]` для чужих скраперов, а у нас метаданные пишет
только Kodi.

Токен `{[Custom Formats]}` отрендерится пустым — custom formats не
настраиваются. Это безвредно и оставлено, чтобы строка совпадала с
рекомендованной посимвольно.

---

## Проверено на живых инстансах

Опрошены `GET /api/v3/config/naming` у Radarr 6.3.0.10514 и Sonarr
4.0.19.2979 (2026-08-01). Расхождения с тем, что можно было бы предположить:

**`colonReplacementFormat` у двух приложений разного типа.** Radarr отдаёт
строку `"smart"`, Sonarr — целое `4`, и у Sonarr есть дополнительное поле
`customColonReplacementFormat`. Одно имя поля, разные типы. Расшифровки
числового enum'а в ответе живого инстанса нет — она будет в схеме на этапе 4.

**Поэтому поле не трогаем.** Оба инстанса уже стоят на Smart Replace по
умолчанию, что совпадает с рекомендацией TRaSH. Подставлять числовое значение
по догадке — ровно то, от чего предостерегает `CLAUDE.md`.

**Обновление после этапа 4: расшифровка так и не нашлась.** Схема Sonarr
описывает поле как голый `{"type": "integer", "format": "int32"}`, отдельной
схемы `ColonReplacementFormat` в ней нет. У Radarr она есть и даёт
`["delete", "dash", "spaceDash", "spaceDashSpace", "smart"]`.

То есть по **именам** полей схема — источник истины, а по **значениям** этого
поля у Sonarr она молчит. Решение не трогать поле окончательное, а не
временное. Понадобится задать — выставить через веб-морду и прочитать
значение обратно через `GET /api/v3/config/naming`.

**У Sonarr есть поля, которых в этом файле раньше не было:**
`specialsFolderFormat` (по умолчанию `Specials`) и `multiEpisodeStyle`.
Оставлены по умолчанию.

**Переименование по умолчанию выключено** в обоих: `renameMovies: false`,
`renameEpisodes: false`. Без включения схема не применяется вообще — файлы
импортируются под релизными именами.

**`seasonFolderFormat` по умолчанию `Season {season}`, без ведущего нуля.**
Требуется `Season {season:00}`, то есть это поле обязательно меняем.

---

## Требуемая структура каталогов

### Фильмы

```
/data/media/movies/
└── <Название> (<Год>)/
    └── <Название> (<Год>) - <качество и прочее>.mkv
```

Отдельная папка на фильм, совпадающая с названием, — это то, на что
рассчитан скрапер Kodi при настройке «Фильмы находятся в отдельных папках,
совпадающих с названием».

### Сериалы

```
/data/media/tv/
└── <Название> (<Год>)/
    └── Season <NN>/
        └── <Название> (<Год>) - S<NN>E<MM> - <Название эпизода> <прочее>.mkv
```

Папки сезонов обязательны (`seasonFolder: true`), номер сезона с ведущим
нулём.

Год в имени папки сериала — осознанное решение: он снимает неоднозначность
при скрапинге, когда существуют ремейк и оригинал с одинаковым названием.
Раньше в этом файле было написано без года; изменено вместе с принятием
строк TRaSH.

---

## Строки конфигурации

### Radarr

```
standardMovieFormat  = {Movie CleanTitle} {(Release Year)} - {{Edition Tags}} {[MediaInfo 3D]}{[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}
movieFolderFormat    = {Movie CleanTitle} ({Release Year})
renameMovies         = true
replaceIllegalCharacters = true
colonReplacementFormat   = не трогаем, остаётся "smart"
```

### Sonarr

```
standardEpisodeFormat  = {Series CleanTitleWithoutYear} {(Series Year)} - S{season:00}E{episode:00} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}
dailyEpisodeFormat     = {Series CleanTitleWithoutYear} {(Series Year)} - {Air-Date} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}
animeEpisodeFormat     = {Series CleanTitleWithoutYear} {(Series Year)} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoCodec }{MediaInfo VideoBitDepth}bit]{-Release Group}
seriesFolderFormat     = {Series CleanTitleWithoutYear} {(Series Year)}
seasonFolderFormat     = Season {season:00}
renameEpisodes         = true
replaceIllegalCharacters = true
colonReplacementFormat   = не трогаем, остаётся 4
```

---

## Ожидаемые имена для тестового стенда

Используется в `fixtures/catalog.yml` и в `checks/07-pipeline.sh` как эталон.

Пути даны от `/data/media`, как их принимает `checks/07-pipeline.sh`.

| Материал | Ожидаемый путь после импорта |
|---|---|
| Big Buck Bunny (2008) | `_test_movies/Big Buck Bunny (2008)/Big Buck Bunny (2008) - [WEBDL-1080p][MP3 2.0][x264]-TEST.mp4` |
| Breaking Bad S01E01 | `_test_tv/Breaking Bad (2008)/Season 01/Breaking Bad (2008) - S01E01 - Pilot [WEBDL-1080p][MP3 2.0][x264]-TEST.mp4` |

Эпизодный путь подтверждает всю сериальную часть схемы разом: папка сериала с
годом, папка сезона с ведущим нулём, `S01E01`, название эпизода из метаданных
Sonarr (`Pilot`) — при том что содержимым файла остаётся короткометражка.
Sonarr сопоставляет по имени, а не по содержимому, поэтому проверка честная.

Заполнено 2026-08-01 из фактического импорта, а не предсказанием. Разбор
хвоста по токенам `standardMovieFormat`:

| Токен | Отрендерился в |
|---|---|
| `{{Edition Tags}}` | пусто — редакция у релиза не указана |
| `{[MediaInfo 3D]}` | пусто — не 3D |
| `{[Custom Formats]}` | пусто — custom formats не настраиваются |
| `{[Quality Full]}` | `[WEBDL-1080p]` |
| `{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}` | `[MP3 2.0]` |
| `{[MediaInfo VideoDynamicRangeType]}` | пусто — SDR |
| `{[Mediainfo VideoCodec]}` | `[x264]` |
| `{-Release Group}` | `-TEST` |

Пустые токены — норма, а не поломка: они схлопываются вместе с обрамляющими
скобками.

**Про `[MP3 2.0]`.** В файле две аудиодорожки: mp3 2.0 и ac3 5.1. Radarr взял
первую. Это свойство материала, а не схемы, и на настоящих релизах хвост будет
другим. Если брать другую короткометражку — эталон в этой таблице придётся
переснять.

Тестовый стенд лежит в `_test_movies`, а не в `movies`: `CLAUDE.md` требует,
чтобы тестовые заказы шли в отдельный root folder и помечались тегом из
`TEST_TAG`. Каталог выбрасывается целиком, настоящую библиотеку разбирать не
придётся.

Если фактический путь после импорта не совпал с ожидаемым — это расхождение
схемы, а не мелочь: исправлять надо схему, а не ожидание в тесте.
