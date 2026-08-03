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
