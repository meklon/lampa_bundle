# Прослеживаемость заказа — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** показать в карточке Lampa, что происходит с заказом, читая текущее состояние у Radarr и Sonarr.

**Architecture:** новый эндпоинт `GET /status` в bridge. Чистая машина состояний в `app/status.py` без ввода-вывода; клиенты *arr отдают ей сырые ответы; FastAPI собирает и возвращает готовый текст. Плагин рисует то, что пришло. Bridge ничего не запоминает — только читает.

**Tech Stack:** Python 3.12, FastAPI, httpx, pydantic, pytest; plugin.js — ES5 без сборки; checks — bash + curl + jq.

## Global Constraints

- **bridge без состояния.** Ни кэша, ни фонового опроса, ни памяти о заказах. Инвариант `CLAUDE.md`, не пересматривается.
- **Имена полей — из `openapi/`,** не из памяти. Схемы: `openapi/radarr-v3-v6.3.0.10514.json`, `openapi/sonarr-v3-v4.0.19.2979.json`.
- **Плагин остаётся тонким.** Ни логики состояний, ни разбора, ни формулировок в JavaScript.
- **`/status` не обращается к трекерам.** Только `/movie`, `/queue`, `/command`, `/series`, `/episode` у *arr.
- **Отказ upstream → ошибка, а не состояние.** `not_ordered` никогда не выводится из недоступности Radarr.
- **Тексты на русском,** без точки в конце, как в существующих `OrderResponse.detail`.
- **ruff:** длина строки как в `bridge/pyproject.toml`; форматирование `ruff format`.
- Спецификация: `docs/superpowers/specs/2026-08-03-order-traceability-design.md`.

## Файловая структура

| Файл | Ответственность |
|---|---|
| `bridge/app/status.py` | **создать.** Машина состояний и формулировки. Чистые функции, без сети |
| `bridge/app/radarr.py` | добавить `queue()`, `commands()` |
| `bridge/app/sonarr.py` | добавить `queue()`, `commands()` (`episodes()` уже есть) |
| `bridge/app/models.py` | добавить `SeasonStatus`, `StatusResponse` |
| `bridge/app/main.py` | добавить `GET /status` |
| `bridge/static/plugin.js` | состояние на кнопке, «Обновить», состояния в списке сезонов |
| `bridge/tests/test_status.py` | **создать.** Таблица состояний |
| `bridge/tests/recorded/*.json` | записанные ответы (часть уже добавлена) |
| `checks/09-status.sh` | **создать.** Проверка против живого стека |
| `docs/`, `CLAUDE.md` | контракт, критерии приёмки, инварианты |

`status.py` отделён от клиентов намеренно: машина состояний — самое ветвистое место фичи, и она обязана проверяться без сети и без моков HTTP.

---

### Task 1: Машина состояний фильма

**Files:**
- Create: `bridge/app/status.py`
- Test: `bridge/tests/test_status.py`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `ItemStatus(state: str, label: str, detail: str | None, can_order: bool, seasons: list[SeasonStatus] | None)` — frozen dataclass
  - `SeasonStatus(season: int, state: str, label: str)` — frozen dataclass
  - `movie_status(movie: dict | None, queue: list[dict], commands: list[dict]) -> ItemStatus`

- [ ] **Step 1: Написать падающие тесты**

Создать `bridge/tests/test_status.py`:

```python
"""Машина состояний заказа.

Проверяется таблицей, а не отдельными случаями: состояний девять у фильма и
десять у сезона, и почти все различаются одним полем. Формы ответов взяты из
recorded/, записанных с живого стека.
"""

from app.status import ItemStatus, movie_status


def _movie(**over) -> dict:
    """Фильм в Radarr. Поля — из MovieResource, значения по умолчанию: заказан,
    отслеживается, файла нет, не искали."""
    base = {
        "id": 5,
        "tmdbId": 1083381,
        "title": "Backrooms",
        "year": 2026,
        "hasFile": False,
        "monitored": True,
        "lastSearchTime": None,
        "sizeOnDisk": 0,
        "movieFile": None,
    }
    base.update(over)
    return base


def _queue_record(**over) -> dict:
    """Запись очереди Radarr. Поля — из QueueResource."""
    base = {
        "movieId": 5,
        "title": "Zakulise.realnosti.2026.AMZN.WEB-DLRip.AVC",
        "size": 2430336359,
        "sizeleft": 1215168179,
        "timeleft": "00:03:12",
        "status": "downloading",
        "trackedDownloadState": "downloading",
        "trackedDownloadStatus": "ok",
        "errorMessage": None,
        "statusMessages": [],
    }
    base.update(over)
    return base


def _search_command(movie_ids, status="started") -> dict:
    return {"name": "MoviesSearch", "status": status, "body": {"movieIds": movie_ids}}


def test_not_ordered_when_absent_from_radarr():
    s = movie_status(None, [], [])
    assert s.state == "not_ordered"
    assert s.can_order is True


def test_in_library_when_has_file():
    movie = _movie(hasFile=True, sizeOnDisk=2430336359,
                   movieFile={"quality": {"quality": {"name": "Bluray-576p"}}})
    s = movie_status(movie, [], [])
    assert s.state == "in_library"
    assert "Bluray-576p" in s.label
    assert s.can_order is False


def test_searching_when_command_running():
    s = movie_status(_movie(), [], [_search_command([5])])
    assert s.state == "searching"


def test_search_command_for_another_movie_is_ignored():
    s = movie_status(_movie(), [], [_search_command([999])])
    assert s.state == "waiting"


def test_completed_search_command_is_not_searching():
    s = movie_status(_movie(), [], [_search_command([5], status="completed")])
    assert s.state == "waiting"


def test_downloading_shows_percent():
    s = movie_status(_movie(), [_queue_record()], [])
    assert s.state == "downloading"
    assert "50%" in s.label


def test_importing():
    s = movie_status(_movie(), [_queue_record(trackedDownloadState="importPending")], [])
    assert s.state == "importing"


def test_stuck_wins_over_downloading():
    """Порядок проверок. Показать «Закачивается 44%» там, где загрузка встала,
    значит соврать — тот же класс, что и вся восьмая ветка проекта."""
    rec = _queue_record(errorMessage="No files found are eligible for import")
    s = movie_status(_movie(), [rec], [])
    assert s.state == "stuck"
    assert "eligible for import" in (s.detail or "")


def test_stuck_from_status_messages():
    rec = _queue_record(statusMessages=[{"title": "x", "messages": ["Not an upgrade"]}])
    s = movie_status(_movie(), [rec], [])
    assert s.state == "stuck"


def test_unmonitored_beats_not_found():
    s = movie_status(_movie(monitored=False, lastSearchTime="2026-08-02T13:39:54Z"), [], [])
    assert s.state == "unmonitored"


def test_not_found_when_searched_and_nothing_came():
    s = movie_status(_movie(lastSearchTime="2026-08-02T13:39:54Z"), [], [])
    assert s.state == "not_found"
    assert "13:39" in s.label


def test_waiting_when_never_searched():
    s = movie_status(_movie(), [], [])
    assert s.state == "waiting"


def test_queue_of_another_movie_is_ignored():
    s = movie_status(_movie(), [_queue_record(movieId=999)], [])
    assert s.state == "waiting"


def test_can_order_only_when_nothing_in_flight():
    assert movie_status(None, [], []).can_order is True
    assert movie_status(_movie(), [_queue_record()], []).can_order is False
    assert movie_status(_movie(lastSearchTime="2026-08-02T13:39:54Z"), [], []).can_order is True


def test_item_status_is_frozen():
    s = movie_status(None, [], [])
    assert isinstance(s, ItemStatus)
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_status.py -q`
Expected: FAIL, `ModuleNotFoundError: No module named 'app.status'`

- [ ] **Step 3: Реализовать**

Создать `bridge/app/status.py`:

```python
"""Состояние заказа: что с ним происходит прямо сейчас.

Чистые функции без ввода-вывода. Ответы *arr передаются сюда как есть, наружу
уходит готовый к показу текст.

Почему формулировки здесь, а не в plugin.js: инвариант «плагин остаётся
тонким», и практическая причина — на Python-текст можно написать тест, на
строку внутри JavaScript в браузере телевизора нельзя.

Почему это не трекинг статусов, запрещённый в CLAUDE.md: модуль ничего не
запоминает. Он получает срез, отданный Radarr и Sonarr в момент запроса, и
описывает его словами.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class SeasonStatus:
    season: int
    state: str
    label: str


@dataclass(frozen=True)
class ItemStatus:
    state: str
    label: str
    detail: str | None = None
    can_order: bool = True
    seasons: list[SeasonStatus] | None = None


# Состояния, при которых заказ уже в работе и повторять его незачем.
_BUSY = {"searching", "stuck", "importing", "downloading", "in_library"}


def _percent(size: int, sizeleft: int) -> int:
    if not size:
        return 0
    done = max(0, size - sizeleft)
    return int(done * 100 / size)


def human_size(num: int | None) -> str:
    """Размер по-человечески. Байты в интерфейсе не читаются."""
    if not num:
        return "—"
    value = float(num)
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if value < 1024 or unit == "ТБ":
            return f"{value:.0f} {unit}" if unit in ("Б", "КБ") else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} ТБ"


def search_time(raw: str | None) -> str:
    """Время последнего поиска в виде ЧЧ:ММ.

    Строка ISO приходит от Radarr; разбирается срезом, а не парсером даты:
    смещение и точность у *arr менялись между версиями, а нам нужны часы и
    минуты.
    """
    if not raw or len(raw) < 16:
        return "?"
    return raw[11:16]


def _running_search(commands: list[dict], key: str, value: object) -> bool:
    """Идёт ли прямо сейчас поиск, относящийся к нашему объекту.

    Это ФАКТ, прочитанный у Radarr, а не вывод по косвенным признакам:
    /api/v3/command отдаёт body.movieIds и status. Проверено на живом стенде.
    """
    for c in commands:
        if c.get("status") != "started":
            continue
        body = c.get("body") or {}
        found = body.get(key)
        if isinstance(found, list) and value in found:
            return True
        if found == value:
            return True
    return False


def _is_stuck(record: dict) -> bool:
    if record.get("errorMessage"):
        return True
    return bool(record.get("statusMessages"))


def _stuck_detail(record: dict) -> str:
    if record.get("errorMessage"):
        return str(record["errorMessage"])
    for block in record.get("statusMessages") or []:
        for message in block.get("messages") or []:
            return str(message)
    return "причина не указана"


def _quality_name(movie: dict) -> str | None:
    file = movie.get("movieFile") or {}
    quality = ((file.get("quality") or {}).get("quality") or {}).get("name")
    return str(quality) if quality else None


def movie_status(movie: dict | None, queue: list[dict], commands: list[dict]) -> ItemStatus:
    """Состояние фильма. Порядок проверок обязателен, см. спецификацию."""
    if movie is None:
        return ItemStatus(state="not_ordered", label="Заказать", can_order=True)

    movie_id = movie.get("id")

    if _running_search(commands, "movieIds", movie_id):
        return ItemStatus(state="searching", label="Ищется релиз…", can_order=False)

    mine = [r for r in queue if r.get("movieId") == movie_id]
    for record in mine:
        if _is_stuck(record):
            return ItemStatus(
                state="stuck",
                label="Загрузка застряла",
                detail=_stuck_detail(record),
                can_order=False,
            )
    for record in mine:
        if str(record.get("trackedDownloadState", "")).startswith("import"):
            return ItemStatus(state="importing", label="Импортируется", can_order=False)
    for record in mine:
        pct = _percent(record.get("size") or 0, record.get("sizeleft") or 0)
        left = record.get("timeleft")
        detail = f"осталось {left} · {record.get('title', '')}".strip(" ·")
        return ItemStatus(
            state="downloading",
            label=f"Закачивается {pct}%",
            detail=detail or None,
            can_order=False,
        )

    if movie.get("hasFile"):
        quality = _quality_name(movie)
        size = human_size(movie.get("sizeOnDisk"))
        label = "В библиотеке"
        if quality:
            label += f" · {quality}"
        return ItemStatus(state="in_library", label=f"{label} · {size}", can_order=False)

    if not movie.get("monitored"):
        return ItemStatus(
            state="unmonitored",
            label="Снят с наблюдения",
            detail="Radarr не будет его искать",
            can_order=True,
        )

    last = movie.get("lastSearchTime")
    if last:
        return ItemStatus(
            state="not_found",
            label=f"При поиске в {search_time(last)} подходящих релизов не нашлось",
            detail="Можно заказать снова или изменить профиль качества",
            can_order=True,
        )

    return ItemStatus(
        state="waiting",
        label="Заказан, поиск ещё не запускался",
        can_order=True,
    )
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_status.py -q`
Expected: PASS, 15 тестов

- [ ] **Step 5: Линтеры**

Run: `cd bridge && .venv/bin/python -m ruff format app tests && .venv/bin/python -m ruff check app tests`
Expected: чисто

- [ ] **Step 6: Commit**

```bash
git add bridge/app/status.py bridge/tests/test_status.py
git commit -m "Машина состояний заказа для фильма

Состояния читаются, а не запоминаются: bridge получает срез от Radarr и
описывает его. Порядок проверок закреплён тестом — затык обязан
побеждать прогресс, иначе интерфейс покажет бодрые проценты там, где
загрузка встала."
```

---

### Task 2: Машина состояний сезона и сериала

**Files:**
- Modify: `bridge/app/status.py`
- Modify: `bridge/tests/test_status.py`

**Interfaces:**
- Consumes: `ItemStatus`, `SeasonStatus`, `_running_search`, `_is_stuck`, `_stuck_detail`, `_percent`, `search_time` из Task 1
- Produces:
  - `series_status(series: dict | None, episodes: list[dict], queue: list[dict], commands: list[dict]) -> ItemStatus`

- [ ] **Step 1: Написать падающие тесты**

Дописать в `bridge/tests/test_status.py`:

```python
from app.status import series_status


def _series(seasons=None, **over) -> dict:
    """Сериал в Sonarr. Форма seasons[].statistics записана с живого стенда:
    episodeFileCount, episodeCount, totalEpisodeCount."""
    base = {
        "id": 1,
        "title": "Silo",
        "seasons": seasons
        if seasons is not None
        else [
            {
                "seasonNumber": 2,
                "monitored": True,
                "statistics": {
                    "episodeFileCount": 0,
                    "episodeCount": 10,
                    "totalEpisodeCount": 10,
                },
            }
        ],
    }
    base.update(over)
    return base


def _episodes(season=2, count=10, monitored=True, with_file=0) -> list[dict]:
    out = []
    for i in range(1, count + 1):
        out.append(
            {
                "id": 100 + i,
                "seriesId": 1,
                "seasonNumber": season,
                "episodeNumber": i,
                "monitored": monitored,
                "hasFile": i <= with_file,
                "lastSearchTime": None,
            }
        )
    return out


def _tv_queue(**over) -> dict:
    base = {
        "seriesId": 1,
        "seasonNumber": 2,
        "title": "Silo.S02E01",
        "size": 1000,
        "sizeleft": 400,
        "timeleft": "00:02:00",
        "trackedDownloadState": "downloading",
        "errorMessage": None,
        "statusMessages": [],
    }
    base.update(over)
    return base


def test_series_not_ordered_when_absent():
    s = series_status(None, [], [], [])
    assert s.state == "not_ordered"
    assert s.can_order is True


def test_series_can_order_is_always_true():
    """Другой сезон заказать можно в любой момент."""
    s = series_status(_series(), _episodes(), [_tv_queue()], [])
    assert s.can_order is True


def test_monitoring_broken_is_detected():
    """Отказ восьмого этапа: сезон отслеживается, эпизоды нет.

    Заказ проходит, поиск находит релизы и не берёт ни одного. Ни ошибки, ни
    записи в истории. Здесь он обязан стать видимым."""
    s = series_status(_series(), _episodes(monitored=False), [], [])
    assert s.seasons[0].state == "monitoring_broken"
    assert s.state == "monitoring_broken"
    assert "не отслеж" in s.seasons[0].label


def test_monitoring_broken_beats_partial():
    """Сломанный мониторинг показывается, даже если часть серий уже скачана."""
    series = _series(
        seasons=[
            {
                "seasonNumber": 2,
                "monitored": True,
                "statistics": {"episodeFileCount": 3, "episodeCount": 0, "totalEpisodeCount": 10},
            }
        ]
    )
    s = series_status(series, _episodes(monitored=False, with_file=3), [], [])
    assert s.seasons[0].state == "monitoring_broken"


def test_season_in_library_when_all_files_present():
    series = _series(
        seasons=[
            {
                "seasonNumber": 2,
                "monitored": True,
                "statistics": {"episodeFileCount": 10, "episodeCount": 10, "totalEpisodeCount": 10},
            }
        ]
    )
    s = series_status(series, _episodes(with_file=10), [], [])
    assert s.seasons[0].state == "in_library"
    assert "10 из 10" in s.seasons[0].label


def test_season_partial():
    series = _series(
        seasons=[
            {
                "seasonNumber": 2,
                "monitored": True,
                "statistics": {"episodeFileCount": 3, "episodeCount": 10, "totalEpisodeCount": 10},
            }
        ]
    )
    s = series_status(series, _episodes(with_file=3), [], [])
    assert s.seasons[0].state == "partial"
    assert "3 из 10" in s.seasons[0].label


def test_season_downloading():
    s = series_status(_series(), _episodes(), [_tv_queue()], [])
    assert s.seasons[0].state == "downloading"
    assert s.state == "downloading"
    assert "Сезон 2" in s.label


def test_season_stuck_wins():
    s = series_status(_series(), _episodes(), [_tv_queue(errorMessage="disk full")], [])
    assert s.seasons[0].state == "stuck"


def test_season_searching():
    cmd = {"name": "SeasonSearch", "status": "started",
           "body": {"seriesId": 1, "seasonNumber": 2}}
    s = series_status(_series(), _episodes(), [], [cmd])
    assert s.seasons[0].state == "searching"


def test_season_search_of_another_season_ignored():
    cmd = {"name": "SeasonSearch", "status": "started",
           "body": {"seriesId": 1, "seasonNumber": 5}}
    s = series_status(_series(), _episodes(), [], [cmd])
    assert s.seasons[0].state == "waiting"


def test_season_not_ordered_when_unmonitored_and_empty():
    series = _series(
        seasons=[
            {
                "seasonNumber": 2,
                "monitored": False,
                "statistics": {"episodeFileCount": 0, "episodeCount": 0, "totalEpisodeCount": 10},
            }
        ]
    )
    s = series_status(series, _episodes(monitored=False), [], [])
    assert s.seasons[0].state == "not_ordered"


def test_season_not_found_uses_episode_search_time():
    eps = _episodes()
    eps[0]["lastSearchTime"] = "2026-08-02T13:39:54Z"
    s = series_status(_series(), eps, [], [])
    assert s.seasons[0].state == "not_found"


def test_series_state_takes_most_urgent_season():
    """Приоритет сведения: затык важнее скачанного сезона."""
    series = _series(
        seasons=[
            {
                "seasonNumber": 1,
                "monitored": True,
                "statistics": {"episodeFileCount": 10, "episodeCount": 10, "totalEpisodeCount": 10},
            },
            {
                "seasonNumber": 2,
                "monitored": True,
                "statistics": {"episodeFileCount": 0, "episodeCount": 10, "totalEpisodeCount": 10},
            },
        ]
    )
    eps = _episodes(season=1, with_file=10) + _episodes(season=2)
    s = series_status(series, eps, [_tv_queue(errorMessage="disk full")], [])
    assert s.state == "stuck"
    assert "Сезон 2" in s.label


def test_specials_season_zero_is_included():
    series = _series(
        seasons=[
            {
                "seasonNumber": 0,
                "monitored": False,
                "statistics": {"episodeFileCount": 0, "episodeCount": 0, "totalEpisodeCount": 4},
            }
        ]
    )
    s = series_status(series, _episodes(season=0, count=4, monitored=False), [], [])
    assert s.seasons[0].season == 0
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_status.py -q`
Expected: FAIL, `ImportError: cannot import name 'series_status'`

- [ ] **Step 3: Реализовать**

Дописать в `bridge/app/status.py`:

```python
# Приоритет сведения сезонов в состояние сериала: что показать в карточке,
# когда сезоны в разных состояниях. Отличается от порядка проверок внутри
# сезона: там важно не перепутать причину, здесь — показать самое требующее
# внимания.
_SERIES_PRIORITY = [
    "stuck",
    "monitoring_broken",
    "downloading",
    "importing",
    "searching",
    "partial",
    "in_library",
    "not_found",
    "waiting",
    "not_ordered",
]


def _season_status(
    season: dict,
    episodes: list[dict],
    queue: list[dict],
    commands: list[dict],
    series_id: int,
) -> SeasonStatus:
    number = int(season.get("seasonNumber", 0))
    stats = season.get("statistics") or {}
    total = int(stats.get("totalEpisodeCount") or 0)
    files = int(stats.get("episodeFileCount") or 0)
    mine_eps = [e for e in episodes if e.get("seasonNumber") == number]
    monitored_eps = [e for e in mine_eps if e.get("monitored")]

    def done(state: str, label: str) -> SeasonStatus:
        return SeasonStatus(season=number, state=state, label=label)

    if not season.get("monitored") and files == 0:
        return done("not_ordered", "не заказан")

    searching = any(
        c.get("status") == "started"
        and c.get("name") == "SeasonSearch"
        and (c.get("body") or {}).get("seriesId") == series_id
        and (c.get("body") or {}).get("seasonNumber") == number
        for c in commands
    )
    if searching:
        return done("searching", "ищется релиз…")

    # Раньше очереди и статистики намеренно: сломанный мониторинг надо
    # показать, даже если часть серий скачана прошлым заказом.
    if season.get("monitored") and mine_eps and not monitored_eps:
        return done(
            "monitoring_broken",
            "мониторинг сломан — серии не отслеживаются, загрузка не начнётся",
        )

    mine_q = [
        r for r in queue if r.get("seriesId") == series_id and r.get("seasonNumber") == number
    ]
    for record in mine_q:
        if _is_stuck(record):
            return done("stuck", f"загрузка застряла: {_stuck_detail(record)}")
    for record in mine_q:
        if str(record.get("trackedDownloadState", "")).startswith("import"):
            return done("importing", "импортируется")
    if mine_q:
        size = sum(r.get("size") or 0 for r in mine_q)
        left = sum(r.get("sizeleft") or 0 for r in mine_q)
        return done("downloading", f"закачивается {_percent(size, left)}% · {files} из {total} серий")

    if total and files >= total:
        return done("in_library", f"в библиотеке · {files} из {total}")
    if files:
        return done("partial", f"{files} из {total} серий")

    last = next((e.get("lastSearchTime") for e in mine_eps if e.get("lastSearchTime")), None)
    if last:
        return done("not_found", f"при поиске в {search_time(last)} релизов не нашлось")
    return done("waiting", "заказан, поиск ещё не запускался")


def series_status(
    series: dict | None,
    episodes: list[dict],
    queue: list[dict],
    commands: list[dict],
) -> ItemStatus:
    """Состояние сериала: сводка плюс разбивка по сезонам.

    can_order всегда True: другой сезон заказать можно в любой момент.
    """
    if series is None:
        return ItemStatus(state="not_ordered", label="Заказать", can_order=True, seasons=[])

    series_id = int(series.get("id", 0))
    seasons = [
        _season_status(s, episodes, queue, commands, series_id)
        for s in sorted(series.get("seasons") or [], key=lambda s: s.get("seasonNumber", 0))
    ]
    if not seasons:
        return ItemStatus(state="not_ordered", label="Заказать", can_order=True, seasons=[])

    order = {name: i for i, name in enumerate(_SERIES_PRIORITY)}
    top = min(seasons, key=lambda s: order.get(s.state, len(order)))
    if top.state == "not_ordered":
        return ItemStatus(state="not_ordered", label="Заказать", can_order=True, seasons=seasons)

    name = "Спецвыпуски" if top.season == 0 else f"Сезон {top.season}"
    return ItemStatus(
        state=top.state,
        label=f"{name}: {top.label}",
        can_order=True,
        seasons=seasons,
    )
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_status.py -q`
Expected: PASS, 29 тестов

- [ ] **Step 5: Линтеры**

Run: `cd bridge && .venv/bin/python -m ruff format app tests && .venv/bin/python -m ruff check app tests`

- [ ] **Step 6: Commit**

```bash
git add bridge/app/status.py bridge/tests/test_status.py
git commit -m "Состояния сезона и сведение к состоянию сериала

Отдельным состоянием — monitoring_broken: сезон отслеживается, эпизоды
нет. Это отказ восьмого этапа, который приёмка пропускала и который в
интерфейсе не проявлялся никак. Проверяется раньше очереди и статистики,
чтобы показываться даже на частично скачанном сезоне."
```

---

### Task 3: Чтение очереди и команд у *arr

**Files:**
- Modify: `bridge/app/radarr.py`
- Modify: `bridge/app/sonarr.py`
- Test: `bridge/tests/test_status_client.py` (создать)

**Interfaces:**
- Consumes: `Radarr._request`, `Sonarr._request` (существуют), `UpstreamUnavailable`
- Produces:
  - `Radarr.queue() -> list[dict]`
  - `Radarr.commands() -> list[dict]`
  - `Sonarr.queue() -> list[dict]`
  - `Sonarr.commands() -> list[dict]`

Важно: `GET /api/v3/queue` возвращает **страницу**, объект с ключами `page`, `pageSize`, `records`, `totalRecords` — не массив. Проверено на живом стенде, форма записана в `bridge/tests/recorded/radarr-queue.json`. Методы обязаны возвращать `records`.

- [ ] **Step 1: Написать падающие тесты**

Создать `bridge/tests/test_status_client.py`:

```python
"""Чтение очереди и команд.

Проверяется главная ловушка: /queue отдаёт страницу, а не массив. Ошибка
здесь дала бы пустую очередь при непустой очереди — молчаливо."""

import httpx
import pytest

from app.errors import UpstreamUnavailable
from app.radarr import Radarr
from app.sonarr import Sonarr

PAGE = {
    "page": 1,
    "pageSize": 20,
    "sortKey": "timeleft",
    "sortDirection": "ascending",
    "totalRecords": 1,
    "records": [{"movieId": 5, "title": "x"}],
}


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@pytest.mark.asyncio
async def test_radarr_queue_unwraps_page():
    async with _client(lambda r: httpx.Response(200, json=PAGE)) as c:
        assert await Radarr(c).queue() == PAGE["records"]


@pytest.mark.asyncio
async def test_sonarr_queue_unwraps_page():
    async with _client(lambda r: httpx.Response(200, json=PAGE)) as c:
        assert await Sonarr(c).queue() == PAGE["records"]


@pytest.mark.asyncio
async def test_commands_returns_list():
    data = [{"name": "MoviesSearch", "status": "started", "body": {"movieIds": [5]}}]
    async with _client(lambda r: httpx.Response(200, json=data)) as c:
        assert await Radarr(c).commands() == data


@pytest.mark.asyncio
async def test_queue_failure_raises_not_empty_list():
    """Отказ обязан стать исключением. Пустой список означал бы «ничего не
    качается» — выдуманное состояние вместо честной ошибки."""
    async with _client(lambda r: httpx.Response(500, text="boom")) as c:
        with pytest.raises(UpstreamUnavailable):
            await Radarr(c).queue()
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_status_client.py -q`
Expected: FAIL, `AttributeError: 'Radarr' object has no attribute 'queue'`

- [ ] **Step 3: Реализовать**

В `bridge/app/radarr.py` дописать в класс `Radarr`:

```python
    # -- чтение текущего состояния -------------------------------------------

    async def queue(self) -> list[dict]:
        """Записи очереди загрузки.

        `/api/v3/queue` отдаёт СТРАНИЦУ, а не массив: объект с page, pageSize,
        totalRecords и records. Вернуть его как есть значило бы получить
        пустую очередь при непустой — молча.
        """
        r = await self._request("GET", "/queue?pageSize=200")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /queue вернул {r.status_code}")
        data = r.json() or {}
        return list(data.get("records") or [])

    async def commands(self) -> list[dict]:
        """Команды Radarr. Нужны, чтобы отличить «идёт поиск» от «искали и не
        нашли»: body.movieIds и status — факт, а не вывод по косвенным
        признакам."""
        r = await self._request("GET", "/command")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /command вернул {r.status_code}")
        return list(r.json() or [])
```

В `bridge/app/sonarr.py` дописать в класс `Sonarr` тот же блок, заменив в
сообщениях «Radarr» на «Sonarr»:

```python
    # -- чтение текущего состояния -------------------------------------------

    async def queue(self) -> list[dict]:
        """Записи очереди загрузки. См. Radarr.queue: /queue отдаёт страницу."""
        r = await self._request("GET", "/queue?pageSize=200&includeEpisode=true")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /queue вернул {r.status_code}")
        data = r.json() or {}
        return list(data.get("records") or [])

    async def commands(self) -> list[dict]:
        """Команды Sonarr: нужны для состояния «идёт поиск сезона»."""
        r = await self._request("GET", "/command")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /command вернул {r.status_code}")
        return list(r.json() or [])
```

Если `pytest-asyncio` не настроен на `asyncio_mode = auto`, тесты помечены
`@pytest.mark.asyncio` — проверить, что маркер работает; `bridge/pyproject.toml`
уже содержит `asyncio_mode`.

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_status_client.py -q`
Expected: PASS, 4 теста

- [ ] **Step 5: Commit**

```bash
git add bridge/app/radarr.py bridge/app/sonarr.py bridge/tests/test_status_client.py
git commit -m "Чтение очереди и команд у Radarr и Sonarr

/queue отдаёт страницу, а не массив — вернуть её как есть значило бы
получить пустую очередь при непустой, и молча. Отказ upstream остаётся
исключением: пустой список означал бы «ничего не качается»."
```

---

### Task 4: Эндпоинт `GET /status`

**Files:**
- Modify: `bridge/app/models.py`
- Modify: `bridge/app/main.py`
- Test: `bridge/tests/test_status_endpoint.py` (создать)

**Interfaces:**
- Consumes: `movie_status`, `series_status`, `ItemStatus`, `SeasonStatus` (Task 1–2); `Radarr.find_by_tmdb`, `Radarr.queue`, `Radarr.commands`, `Sonarr.find_by_tvdb`, `Sonarr.episodes`, `Sonarr.queue`, `Sonarr.commands`; `Tmdb.tvdb_id`
- Produces: HTTP `GET /status`, модели `SeasonStatusModel`, `StatusResponse`

- [ ] **Step 1: Написать падающие тесты**

Создать `bridge/tests/test_status_endpoint.py`:

```python
"""Контракт GET /status."""

from fastapi.testclient import TestClient

from app.main import app


def test_status_requires_known_type():
    with TestClient(app) as client:
        r = client.get("/status", params={"tmdb_id": 1, "type": "book"})
    assert r.status_code == 422


def test_status_requires_positive_id():
    with TestClient(app) as client:
        r = client.get("/status", params={"tmdb_id": 0, "type": "movie"})
    assert r.status_code == 422


def test_status_works_in_dev_mode(monkeypatch):
    """В dev эндпоинт РАБОТАЕТ: он не трогает трекеры, а только читает *arr.

    Запрет BRIDGE_ENV=dev касается поиска. Отличие от заказа принципиальное и
    должно быть закреплено тестом, иначе кто-нибудь «на всякий случай»
    выключит эндпоинт в dev — там, где он полезнее всего."""
    from app.config import settings
    from app.radarr import Radarr

    assert settings().is_dev

    async def no_movie(self, tmdb_id):
        return None

    async def empty(self):
        return []

    monkeypatch.setattr(Radarr, "find_by_tmdb", no_movie)
    monkeypatch.setattr(Radarr, "queue", empty)
    monkeypatch.setattr(Radarr, "commands", empty)
    with TestClient(app) as client:
        r = client.get("/status", params={"tmdb_id": 1083381, "type": "movie"})
    assert r.status_code == 200
    assert r.json()["state"] == "not_ordered"


def test_upstream_failure_is_error_not_state(monkeypatch):
    """Radarr недоступен → ошибка, а не not_ordered.

    Выдуманное not_ordered подтолкнуло бы заказать то, что уже качается."""
    from app.errors import UpstreamUnavailable
    from app.radarr import Radarr

    async def boom(self):
        raise UpstreamUnavailable("Radarr недоступен")

    monkeypatch.setattr(Radarr, "queue", boom)
    with TestClient(app) as client:
        r = client.get("/status", params={"tmdb_id": 1083381, "type": "movie"})
    assert r.status_code >= 500
    assert "not_ordered" not in r.text
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_status_endpoint.py -q`
Expected: FAIL, 404 вместо 422

- [ ] **Step 3: Реализовать**

В `bridge/app/models.py` дописать:

```python
class SeasonStatusModel(BaseModel):
    """Состояние одного сезона для списка выбора в плагине."""

    season: int
    state: str
    label: str


class StatusResponse(BaseModel):
    """Текущее состояние заказа.

    `state` — машинное, для единственного решения плагина: рисовать «Заказать»
    или нет. `label` и `detail` — готовый текст: формулировки живут в Python,
    потому что там на них есть тест.
    """

    state: str
    label: str
    detail: str | None = None
    can_order: bool = True
    seasons: list[SeasonStatusModel] | None = None
```

В `bridge/app/main.py` добавить импорты `StatusResponse`, `SeasonStatusModel`,
`movie_status`, `series_status`, и эндпоинт:

```python
@app.get("/status", response_model=StatusResponse)
async def status(
    request: Request,
    tmdb_id: int = Query(gt=0),
    type: Literal["movie", "tv"] = Query(),
) -> StatusResponse:
    """Что происходит с заказом прямо сейчас.

    Bridge ничего не помнит: он спрашивает у Radarr и Sonarr срез текущего
    состояния и описывает его словами. Это чтение, а не трекинг статусов —
    инвариант «bridge без состояния» остаётся в силе.

    Трекеры НЕ опрашиваются: только /movie, /queue, /command, /series,
    /episode. Поэтому эндпоинт работает и в dev-режиме, в отличие от заказа
    с поиском.
    """
    client: httpx.AsyncClient = request.app.state.http

    if type == "movie":
        radarr = Radarr(client)
        movie = await radarr.find_by_tmdb(tmdb_id)
        queue = await radarr.queue()
        commands = await radarr.commands()
        result = movie_status(movie, queue, commands)
    else:
        sonarr = Sonarr(client)
        tvdb_id = await Tmdb(client).tvdb_id(tmdb_id)
        series = await sonarr.find_by_tvdb(tvdb_id)
        episodes = await sonarr.episodes(int(series["id"])) if series else []
        queue = await sonarr.queue()
        commands = await sonarr.commands()
        result = series_status(series, episodes, queue, commands)

    return StatusResponse(
        state=result.state,
        label=result.label,
        detail=result.detail,
        can_order=result.can_order,
        seasons=(
            [SeasonStatusModel(season=s.season, state=s.state, label=s.label) for s in result.seasons]
            if result.seasons is not None
            else None
        ),
    )
```

Проверить, что `Query` и `Literal` импортированы в `main.py`; `Literal` — из
`typing`, `Query` — из `fastapi`.

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `cd bridge && .venv/bin/python -m pytest tests/ -q`
Expected: PASS, все тесты

- [ ] **Step 5: Линтеры**

Run: `cd bridge && .venv/bin/python -m ruff format app tests && .venv/bin/python -m ruff check app tests`

- [ ] **Step 6: Commit**

```bash
git add bridge/app/main.py bridge/app/models.py bridge/tests/test_status_endpoint.py
git commit -m "Эндпоинт GET /status

Работает и в dev: трекеры не опрашиваются, читаются только *arr. Отказ
upstream отдаётся ошибкой, а не состоянием not_ordered — иначе интерфейс
предложил бы заказать то, что уже качается."
```

---

### Task 5: Состояние в плагине

**Files:**
- Modify: `bridge/static/plugin.js`
- Modify: `bridge/tests/plugin_harness.js`
- Modify: `bridge/tests/test_plugin.py`

**Interfaces:**
- Consumes: `GET /status?tmdb_id=&type=` (Task 4)
- Produces: изменения только в интерфейсе; тело `POST /order` не меняется

- [ ] **Step 1: Прочитать текущий стенд**

Открыть `bridge/tests/plugin_harness.js` и `bridge/tests/test_plugin.py`.
Стенд подгружает `plugin.js` в node с заглушкой `Lampa`. Новые проверки
пишутся тем же способом.

- [ ] **Step 2: Написать падающий тест**

Дописать в `bridge/tests/test_plugin.py`:

```python
@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_requests_status_for_card():
    """Плагин обязан спросить состояние по tmdb_id и типу карточки."""
    r = subprocess.run(
        ["node", str(HARNESS), "status-request"],
        capture_output=True, text=True, check=False,
    )
    assert r.returncode == 0, r.stderr
    assert "/status?tmdb_id=1083381&type=movie" in r.stdout


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_shows_label_instead_of_order():
    """can_order=false → на кнопке состояние, а не «Заказать»."""
    r = subprocess.run(
        ["node", str(HARNESS), "status-label"],
        capture_output=True, text=True, check=False,
    )
    assert r.returncode == 0, r.stderr
    assert "Закачивается 44%" in r.stdout
    assert "Заказать" not in r.stdout
```

- [ ] **Step 3: Расширить стенд**

В `bridge/tests/plugin_harness.js` добавить сценарии `status-request` и
`status-label`: заглушка `fetch`, возвращающая для `/status` объект
`{state:'downloading', label:'Закачивается 44%', detail:null, can_order:false}`,
и печать в stdout запрошенного URL и текста кнопки. Форма заглушки повторяет
существующие сценарии файла.

- [ ] **Step 4: Убедиться, что тесты падают**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_plugin.py -q`
Expected: FAIL

- [ ] **Step 5: Реализовать в `plugin.js`**

Добавить рядом с `PROFILES_PATH`:

```javascript
  var STATUS_PATH = '/status';
```

Добавить функцию:

```javascript
  /**
   * Текущее состояние заказа. Логики здесь нет: bridge присылает готовый
   * текст, плагин его показывает. Инвариант «плагин остаётся тонким».
   */
  function fetchStatus(card, callback) {
    fetch(BRIDGE + STATUS_PATH + '?tmdb_id=' + encodeURIComponent(card.tmdb_id) +
          '&type=' + encodeURIComponent(card.type))
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (s) { callback(s && s.state ? s : null); })
      .catch(function () {
        // Не ответил — значит не знаем. Показываем карточку как раньше,
        // выдуманных состояний быть не должно.
        callback(null);
      });
  }
```

В `addButton` после вставки кнопки:

```javascript
    // Состояние подгружается отдельно: карточка не должна ждать сеть.
    fetchStatus(card, function (status) {
      if (!status) return;
      btn.data('status', status);
      btn.find('span').text(status.label);
    });
```

Существующая сигнатура — `handleOrder(card)`. Расширить до
`handleOrder(card, status)` и поправить единственное место вызова внутри
`btn.on('hover:enter', …)`, где состояние берётся с элемента:

```javascript
    btn.on('hover:enter', function () {
      handleOrder(card, btn.data('status') || null);
    });
```

В начало `handleOrder`:

```javascript
  function handleOrder(card, status) {
    // Заказ уже в работе — показываем что происходит, а не заказываем снова.
    if (status && status.can_order === false) {
      showStatus(card, status);
      return;
    }
```

Внутри ветки для сериала передать состояния сезонов в `pickSeason`:

```javascript
      pickSeason(card, status, function (season) {
```

Соответственно `pickSeason(card, callback)` становится
`pickSeason(card, status, callback)`.

Новые функции:

```javascript
  function showStatus(card, status) {
    var back = Lampa.Controller.enabled().name;
    var items = [{ title: status.label, action: 'none' }];
    if (status.detail) items.push({ title: status.detail, action: 'none' });
    items.push({ title: 'Обновить', action: 'refresh' });

    Lampa.Select.show({
      title: card.title,
      items: items,
      onSelect: function (item) {
        Lampa.Controller.toggle(back);
        if (item.action === 'refresh') refresh(card);
      },
      onBack: function () { Lampa.Controller.toggle(back); }
    });
  }
```

Обновление перечитывает состояние и переписывает текст кнопки. Кнопку надо
найти в текущей активности — ссылки на неё из `showStatus` нет:

```javascript
  function refresh(card) {
    var btn = $('.view--order');
    fetchStatus(card, function (status) {
      if (!status) {
        notify('Состояние получить не удалось');
        return;
      }
      btn.data('status', status);
      btn.find('span').text(status.label);
      notify(status.label);
    });
  }
```

В `pickSeason` к заголовку пункта добавлять состояние сезона, если оно
пришло:

```javascript
    var byNumber = {};
    if (status && status.seasons) {
      for (var j = 0; j < status.seasons.length; j++) {
        byNumber[status.seasons[j].season] = status.seasons[j].label;
      }
    }
    var items = card.seasons.map(function (n) {
      var title = n === 0 ? 'Спецвыпуски' : 'Сезон ' + n;
      if (byNumber[n]) title += ' — ' + byNumber[n];
      return { title: title, season: n };
    });
```

- [ ] **Step 6: Убедиться, что тесты проходят**

Run: `cd bridge && .venv/bin/python -m pytest tests/test_plugin.py -q`
Expected: PASS

- [ ] **Step 7: Проверить, что секретов не прибавилось**

Run: `! grep -nE 'X-Api-Key|api_key|Bearer|:7878|:8989|:9696' bridge/static/plugin.js`
Expected: ничего не найдено

- [ ] **Step 8: Commit**

```bash
git add bridge/static/plugin.js bridge/tests/plugin_harness.js bridge/tests/test_plugin.py
git commit -m "Состояние заказа в карточке и в списке сезонов

Плагин остаётся отрисовщиком: весь текст приходит от bridge. Не ответил —
карточка выглядит как раньше, выдуманных состояний нет."
```

---

### Task 6: Проверка приёмки `checks/09-status.sh`

**Files:**
- Create: `checks/09-status.sh`
- Modify: `checks/run-all.sh`

**Interfaces:**
- Consumes: `checks/lib.sh` (`BRIDGE`, `RADARR`, `SONARR`, `arr_get`, `assert_eq`, `ok`, `bad`, `info`, `skip`, `title`, `finish`)
- Produces: аргументов не требует, входит в `run-all.sh`

- [ ] **Step 1: Написать проверку**

Создать `checks/09-status.sh`:

```bash
#!/usr/bin/env bash
# Прослеживаемость: /status обязан совпадать с действительностью.
#
# Утверждения формулируются о РЕЗУЛЬТАТЕ, а не о коде ответа. Эндпоинт,
# отвечающий 200 и врущий про состояние, хуже отсутствующего: на него
# полагаются.
#
# Главная часть — воспроизведение отказа восьмого этапа. Мониторинг эпизодов
# снимается принудительно, и стек обязан это ПОКАЗАТЬ, а не промолчать.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

status_of() {  # status_of <tmdb_id> <movie|tv> [поле]
  curl -fsS "$BRIDGE/status?tmdb_id=$1&type=$2" 2>/dev/null | jq -r ".${3:-state}"
}

title "Фильм из библиотеки виден как in_library"
MOVIE="$(arr_get "$RADARR" "${RADARR_API_KEY:-}" v3 /movie \
  | jq -r 'map(select(.hasFile))|.[0].tmdbId // empty')"
if [ -z "$MOVIE" ]; then
  skip "в Radarr нет ни одного скачанного фильма — сначала checks/07"
else
  assert_eq "состояние фильма $MOVIE" in_library "$(status_of "$MOVIE" movie)"
fi

title "Фильма нет в Radarr — not_ordered"
# 1 — идентификатор, которого заведомо нет в библиотеке стенда.
assert_eq "состояние незаказанного" not_ordered "$(status_of 1 movie)"

title "Сериал: сломанный мониторинг становится ВИДЕН"
SID="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 /series | jq -r '.[0].id // empty')"
TMDB_TV=""
if [ -n "$SID" ]; then
  TMDB_TV="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/series/$SID" | jq -r '.tmdbId // empty')"
fi

if [ -z "$SID" ] || [ -z "$TMDB_TV" ] || [ "$TMDB_TV" = "0" ]; then
  skip "в Sonarr нет сериала с известным tmdbId — сначала checks/06"
else
  SEASON="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/series/$SID" \
    | jq -r '[.seasons[]|select(.monitored)|.seasonNumber]|first // empty')"
  if [ -z "$SEASON" ]; then
    skip "у сериала нет отслеживаемого сезона"
  else
    EPS="$(arr_get "$SONARR" "${SONARR_API_KEY:-}" v3 "/episode?seriesId=$SID")"
    IDS="$(echo "$EPS" | jq -c --argjson s "$SEASON" '[.[]|select(.seasonNumber==$s)|.id]')"
    BEFORE="$(curl -fsS "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
      | jq -r --argjson s "$SEASON" '.seasons[]|select(.season==$s)|.state')"
    info "состояние сезона $SEASON до вмешательства: $BEFORE"

    curl -fsS -X PUT -H "X-Api-Key: ${SONARR_API_KEY:-}" -H 'Content-Type: application/json' \
      "$SONARR/api/v3/episode/monitor" \
      -d "{\"episodeIds\":$IDS,\"monitored\":false}" >/dev/null 2>&1
    sleep 3

    GOT="$(curl -fsS "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
      | jq -r --argjson s "$SEASON" '.seasons[]|select(.season==$s)|.state')"
    assert_eq "сломанный мониторинг показан" monitoring_broken "$GOT"
    if [ "$GOT" != monitoring_broken ]; then
      info "Это отказ восьмого этапа: сезон отслеживается, эпизоды нет,"
      info "поиск находит релизы и не берёт ни одного. Он обязан быть видимым."
    fi

    curl -fsS -X PUT -H "X-Api-Key: ${SONARR_API_KEY:-}" -H 'Content-Type: application/json' \
      "$SONARR/api/v3/episode/monitor" \
      -d "{\"episodeIds\":$IDS,\"monitored\":true}" >/dev/null 2>&1
    sleep 3
    RESTORED="$(curl -fsS "$BRIDGE/status?tmdb_id=$TMDB_TV&type=tv" \
      | jq -r --argjson s "$SEASON" '.seasons[]|select(.season==$s)|.state')"
    assert_eq "состояние восстановлено" "$BEFORE" "$RESTORED"
  fi
fi

title "/status не обращается к трекерам"
# Эндпоинт обязан оставаться читающим. Считаем поисковые записи в логе
# Prowlarr до и после вызова.
COUNT_BEFORE="$(docker compose logs prowlarr 2>/dev/null | grep -c 'ReleaseSearchService' || true)"
curl -fsS "$BRIDGE/status?tmdb_id=1083381&type=movie" >/dev/null 2>&1
sleep 2
COUNT_AFTER="$(docker compose logs prowlarr 2>/dev/null | grep -c 'ReleaseSearchService' || true)"
assert_eq "поисковых запросов к трекерам не прибавилось" "$COUNT_BEFORE" "$COUNT_AFTER"

finish
```

- [ ] **Step 2: Включить в run-all.sh**

В `checks/run-all.sh` в список аргументless-проверок добавить
`09-status.sh` после `08-qbt-savepath.sh`.

- [ ] **Step 3: shellcheck**

Run: `shellcheck checks/*.sh`
Expected: чисто

- [ ] **Step 4: Прогнать против живого стека**

Run: `cd /opt/media-stack && bash /home/meklon/lampa_bundle/checks/09-status.sh`
Expected: ИТОГ: прошло

- [ ] **Step 5: Commit**

```bash
git add checks/09-status.sh checks/run-all.sh
git commit -m "Проверка приёмки: состояние заказа совпадает с действительностью

Главная часть — воспроизведение отказа восьмого этапа: мониторинг
эпизодов снимается принудительно, и стек обязан это показать. Плюс
утверждение, что /status остаётся читающим и трекеры не трогает."
```

---

### Task 7: Документация и инварианты

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/SPEC.md`
- Modify: `docs/ACCEPTANCE.md`
- Modify: `docs/CHECKLIST.md`
- Modify: `docs/OPEN-QUESTIONS.md`
- Modify: `README.md`
- Create: `reports/stage-9-traceability.md`

**Interfaces:**
- Consumes: реализованный контракт из Task 4, состояния из Task 1–2, проверка из Task 6
- Produces: только документация

- [ ] **Step 1: `CLAUDE.md`**

В разделе «Решения, которые не пересматриваются» дополнить пункт про тонкий
плагин: после «показал уведомление» добавить «показал состояние, полученное
от bridge». Явно оговорить, что логики состояний в плагине нет.

В таблице ролей у **bridge** дописать «текущее состояние заказа» к списку
задач.

Ничего больше не менять: «bridge без состояния» остаётся как есть, новых
стрелок между компонентами не появилось.

- [ ] **Step 2: `docs/SPEC.md`**

В раздел 2 добавить подраздел `### GET /status` рядом с `GET /profiles`:
контракт запроса и ответа, обе таблицы состояний (фильм и сезон), приоритет
сведения сезонов, объяснение, почему `not_found` — вывод, а не факт, и почему
эндпоинт работает в dev в отличие от заказа с поиском.

- [ ] **Step 3: `docs/ACCEPTANCE.md`**

Добавить `### checks/09-status.sh` с критериями: `in_library` для скачанного
фильма, `not_ordered` для отсутствующего, воспроизведение и восстановление
`monitoring_broken`, отсутствие обращений к трекерам.

- [ ] **Step 4: `docs/CHECKLIST.md`**

Добавить раздел «Этап 9 — прослеживаемость» с отметками о сделанном и о том,
чем доказано.

- [ ] **Step 5: `docs/OPEN-QUESTIONS.md`**

Два пункта:
1. **Аутентификации у bridge нет.** С `/status` любой, кто дотянулся до порта
   8000, узнает, что заказывали и что в библиотеке. CORS от этого не
   защищает: он ограничивает браузер, а не `curl`. В домашней сети,
   вероятно, приемлемо; решение осознанное.
2. **Как часто срабатывает `monitoring_broken` в жизни** — наблюдать.

- [ ] **Step 6: `README.md`**

В разделе про подключение с телефона — одна фраза о том, что в карточке
видно состояние заказа и есть «Обновить».

- [ ] **Step 7: `reports/stage-9-traceability.md`**

Отчёт по форме из `docs/PROCESS.md`: что сделано, таблица проверок,
подтвердившиеся и не подтвердившиеся гипотезы, что осталось.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md docs/ README.md reports/stage-9-traceability.md
git commit -m "Документация этапа 9: прослеживаемость заказа"
```

---

## Финальная проверка

- [ ] `cd bridge && .venv/bin/python -m pytest tests/ -q` — все тесты
- [ ] `cd bridge && .venv/bin/python -m ruff check app tests && .venv/bin/python -m ruff format --check app tests`
- [ ] `shellcheck checks/*.sh provision/*.sh scripts/*.sh fixtures/*.sh deploy.sh`
- [ ] Пересобрать bridge и поднять стенд:
      `cd /opt/media-stack && docker compose up -d` с локально собранным образом,
      либо `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build` из репозитория
- [ ] `bash checks/09-status.sh` против живого стека — прошла
- [ ] Живая проверка `/status` на всех доступных состояниях стенда
- [ ] `git push -u origin stage/9-traceability` и pull request
- [ ] CI зелёный
