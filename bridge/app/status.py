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

# TrackedDownloadState enum из openapi/radarr-v3-v6.3.0.10514.json:
# downloading, importBlocked, importPending, importing, imported, failedPending, failed, ignored
_IMPORT_BLOCKED = {"importBlocked"}
_IMPORT_ACTIVE = {"importPending", "importing"}


def _can_order(state: str) -> bool:
    """Можно ли заказать при данном состоянии."""
    return state not in _BUSY


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
    Команда считается активной в статусах queued и started.
    """
    for c in commands:
        if c.get("status") not in ("started", "queued"):
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


def movie_status(movie: dict | None, queue: list[dict], commands: list[dict]) -> ItemStatus:
    """Состояние фильма. Порядок проверок обязателен, см. спецификацию."""
    if movie is None:
        state = "not_ordered"
        return ItemStatus(state=state, label="Заказать", can_order=_can_order(state))

    movie_id = movie.get("id")

    if _running_search(commands, "movieIds", movie_id):
        state = "searching"
        return ItemStatus(state=state, label="Ищется релиз…", can_order=_can_order(state))

    mine = [r for r in queue if r.get("movieId") == movie_id]
    for record in mine:
        if _is_stuck(record):
            state = "stuck"
            return ItemStatus(
                state=state,
                label="Загрузка застряла",
                detail=_stuck_detail(record),
                can_order=_can_order(state),
            )
    for record in mine:
        download_state = str(record.get("trackedDownloadState", ""))
        if download_state in _IMPORT_BLOCKED:
            state = "stuck"
            return ItemStatus(
                state=state,
                label="Импорт заблокирован",
                detail="Файл не может быть импортирован",
                can_order=_can_order(state),
            )
        if download_state in _IMPORT_ACTIVE:
            state = "importing"
            return ItemStatus(state=state, label="Импортируется", can_order=_can_order(state))
    for record in mine:
        pct = _percent(record.get("size") or 0, record.get("sizeleft") or 0)
        parts = []
        left = record.get("timeleft")
        if left:
            parts.append(f"осталось {left}")
        title = record.get("title", "")
        if title:
            parts.append(title)
        detail = " · ".join(parts) if parts else None
        state = "downloading"
        return ItemStatus(
            state=state,
            label=f"Закачивается {pct}%",
            detail=detail,
            can_order=_can_order(state),
        )

    if movie.get("hasFile"):
        quality = _quality_name(movie)
        size = human_size(movie.get("sizeOnDisk"))
        label = "В библиотеке"
        if quality:
            label += f" · {quality}"
        state = "in_library"
        return ItemStatus(state=state, label=f"{label} · {size}", can_order=_can_order(state))

    if not movie.get("monitored"):
        state = "unmonitored"
        return ItemStatus(
            state=state,
            label="Снят с наблюдения",
            detail="Radarr не будет его искать",
            can_order=_can_order(state),
        )

    last = movie.get("lastSearchTime")
    if last:
        state = "not_found"
        return ItemStatus(
            state=state,
            label=f"При поиске в {search_time(last)} подходящих релизов не нашлось",
            detail="Можно заказать снова или изменить профиль качества",
            can_order=_can_order(state),
        )

    state = "waiting"
    return ItemStatus(
        state=state,
        label="Заказан, поиск ещё не запускался",
        can_order=_can_order(state),
    )


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
        c.get("status") in ("started", "queued")
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
        download_state = str(record.get("trackedDownloadState", ""))
        if download_state in _IMPORT_BLOCKED:
            return done("stuck", "импорт заблокирован — файл не может быть импортирован")
        if download_state in _IMPORT_ACTIVE:
            return done("importing", "импортируется")
    if mine_q:
        size = sum(r.get("size") or 0 for r in mine_q)
        left = sum(r.get("sizeleft") or 0 for r in mine_q)
        return done(
            "downloading", f"закачивается {_percent(size, left)}% · {files} из {total} серий"
        )

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
