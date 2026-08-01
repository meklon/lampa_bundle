# Этап 1: инфраструктура

**Статус:** завершён
**Ветка:** stage/1-infra
**Дата:** 2026-08-01

---

## Что сделано

**Раскладка репозитория.** Материалы лежали плоской пачкой в корне плюс
`media-stack.zip`. Содержимое архива побайтно совпало с плоскими копиями
(сверено `diff` по 13 файлам), поэтому за истину взято дерево из архива,
дубликаты и архив удалены. До этого ни одна ссылка вида `docs/SPEC.md` не
разрешалась, а `checks/lib.sh` и `scripts/init-data.sh` вычисляют корень
репозитория относительно своего каталога и в плоской раскладке не работали бы.

**Среда.** Ubuntu 26.04, ядро 7.0.0-22, Docker 29.6.0, Compose v5.1.4.
Доставлены `mktorrent`, `unzip`, `ffmpeg`, `shellcheck`, `yq`, `pre-commit`.

**Файлы:**

- `.env` — теги, `DATA_ROOT`, `PUID`/`PGID`, `UMASK`, ключи API, пароль
  qBittorrent. В git не попадает
- `.shellcheckrc` — `external-sources=true`, `source-path=SCRIPTDIR`
- `docs/CHECKLIST.md` — состояние работ, привязка пунктов к проверкам
- `checks/01-containers.sh`, `checks/07-pipeline.sh`, `checks/lib.sh`,
  `checks/run-all.sh`, `provision/lib.sh`, `provision/10-qbittorrent.sh`,
  `provision/20-prowlarr.sh`, `scripts/check-versions.sh`,
  `fixtures/make-fixture.sh` — правки, описанные ниже

**Теги образов зафиксированы** (проверено `docker manifest inspect`,
стабильный канал, не nightly и не develop):

| Сервис | Тег | Версия приложения |
|---|---|---|
| Radarr | `6.3.0.10514-ls312` | 6.3.0.10514 |
| Sonarr | `4.0.19.2979-ls320` | 4.0.19.2979 |
| Prowlarr | `2.5.2.5491-ls155` | 2.5.2.5491 |
| qBittorrent | `5.2.3_v2.0.13-ls469` | 5.2.3, libtorrent v2.0.13 |

**`DATA_ROOT=/mnt/ssd_storage/video`**, вне репозитория. `scripts/init-data.sh`
создал `torrents/{movies,tv}` и `media/{movies,tv,_test_movies,_test_tv}`,
владелец `1000:1000`, каталоги `775`.

---

## Проверки

| Проверка | Результат |
|---|---|
| `checks/01-containers.sh` | прошла, код 0 |
| `checks/02-data-layout.sh` | прошла, код 0 |
| `pre-commit run --all-files` | прошла, код 0, все 10 хуков |

Вывод `01-containers.sh`: пять контейнеров `running`; Radarr 6.3.0.10514,
Sonarr 4.0.19.2979, Prowlarr 2.5.2.5491 отвечают на `/system/status` с ключом
из `.env`; qBittorrent v5.2.3 после логина; bridge отдаёт 200 на `/health`.

Вывод `02-data-layout.sh`: внутри контейнера Radarr
`stat -c %d /data/torrents` и `stat -c %d /data/media` дают **64770** оба;
`ln` между каталогами отработал, иноды совпали. То же в Sonarr, qBittorrent
видит оба каталога по `/data`.

Версии живых инстансов совпадают с зафиксированными тегами — на этапе 4 схемы
надо качать именно под них.

---

## Гипотезы, которые подтвердились

**Единственное монтирование `/data` даёт работающие жёсткие ссылки.**
`torrents` и `media` внутри контейнера — устройство 64770, `ln` создаёт вторую
ссылку, иноды совпадают. ФС ext4 на одном разделе `/dev/vda2`, не btrfs.

**Ключи API можно забрать без веб-морды.** Генерируются при первом старте и
лежат в `config/<service>/config.xml` в элементе `<ApiKey>`. Инвариант «ключи
только в `.env`» не нарушен: в код не попало ничего.

---

## Гипотезы, которые НЕ подтвердились

### WebUI qBittorrent 5.x требует заголовок `Referer`

Скрипты в `checks/` и `provision/` ходили в API qBittorrent без него.
Молчаливо не сработало бы всё, что связано с торрент-клиентом.

Точный запрос без заголовка:

```
curl -s -i --data-urlencode "username=admin" --data-urlencode "password=<временный из лога>" \
  http://localhost:8081/api/v2/auth/login
```

Ответ:

```
HTTP/1.1 401 Unauthorized
```

Тот же запрос с `-H "Referer: http://localhost:8081"`:

```
HTTP/1.1 204 OK
set-cookie: QBT_SID_8081=<кука сессии>; HttpOnly; SameSite=Lax
```

Требование распространяется и на GET: `GET /api/v2/app/version` с валидной
кукой, но без `Referer` отвечает `403`.

Второе наблюдение: успешный логин возвращает **204 с пустым телом**, а не
строку `Ok.`. Код, который проверяет вход по содержимому ответа, посчитает
успешный вход неудачей.

Исправлено в `provision/lib.sh` (`qbt_login`, новый `qbt_get`, `qbt_post`),
`provision/10-qbittorrent.sh`, `checks/01-containers.sh`,
`checks/07-pipeline.sh`, `fixtures/make-fixture.sh`. Перенесено в `SPEC.md`
раздел 4.3.

### Хуки pre-commit не проходили на исходном состоянии

Заявленные ворота качества не работали. `ruff-format` переформатировал четыре
модуля bridge. `shellcheck` нашёл: проверку `$?` вместо прямой в
`07-pipeline.sh`, `cd` без `|| exit` в `run-all.sh`, неэкранированный глоб и
`ls` в подстановке в `check-versions.sh`, четыре конструкции `A && B || C` в
`01-containers.sh`, по одной в `20-prowlarr.sh` и `make-fixture.sh`.

`.shellcheckrc` понадобился, потому что скрипты подключают `lib.sh` своего
каталога: без `external-sources` и `source-path=SCRIPTDIR` shellcheck
библиотеку не находит и выдаёт SC1091 плюс ложные SC2034 на её переменных.

---

## Стоп-условия

Не сработали.

---

## Открытые вопросы

**Пустой пароль qBittorrent при первом запуске.** Временный пароль пишется в
лог и **меняется при каждом перезапуске контейнера**, пока не задан
постоянный. Задан постоянный через `POST /api/v2/app/setPreferences` с
`{"web_ui_password": ...}`, значение в `.env`. Без этого `checks/01` проходила
бы ровно до первого `docker compose restart`.

**Содержимое `DATA_ROOT`.** В `/mnt/ssd_storage/video` уже лежали пустые
`Movies/` и `TV shows/`. Не тронуты, новая раскладка создана рядом. Если на
целевом узле это настоящая библиотека, а не пустышки, раскладку нужно
пересогласовать **до первого импорта**: иначе в одном каталоге окажутся две
библиотеки с разными схемами имён.

**Порты опубликованы на `0.0.0.0`** по явному решению человека. Веб-морды
видны из сети ВМ. Зафиксировано как осознанный выбор, не как недосмотр.
