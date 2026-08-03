"""Машина состояний заказа.

Проверяется таблицей, а не отдельными случаями: состояний девять у фильма и
десять у сезона, и почти все различаются одним полем. Структуры полей взяты из
openapi-схем Radarr и Sonarr, конкретные значения подставлены в фикстурах теста.
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
    movie = _movie(
        hasFile=True,
        sizeOnDisk=2430336359,
        movieFile={"quality": {"quality": {"name": "Bluray-576p"}}},
    )
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


def test_downloading_without_timeleft():
    """timeleft может быть None, это штатный случай. Не писать None в интерфейс."""
    s = movie_status(_movie(), [_queue_record(timeleft=None)], [])
    assert s.state == "downloading"
    assert "None" not in (s.label or "")
    assert "None" not in (s.detail or "")


def test_downloading_with_only_time_left():
    """Если timeleft есть, а title нет, писать только остаток времени."""
    s = movie_status(_movie(), [_queue_record(timeleft="00:10:00", title="")], [])
    assert s.state == "downloading"
    assert "осталось 00:10:00" in (s.detail or "")
    assert "·" not in (s.detail or "")


def test_can_order_respects_busy_states():
    """can_order = False только для состояний из _BUSY."""
    # Состояния из _BUSY должны иметь can_order=False
    assert movie_status(_movie(), [], [_search_command([5])]).can_order is False  # searching
    assert movie_status(_movie(), [_queue_record()], []).can_order is False  # downloading
    assert (
        movie_status(_movie(), [_queue_record(trackedDownloadState="importPending")], []).can_order
        is False
    )  # importing
    assert (
        movie_status(_movie(), [_queue_record(errorMessage="error")], []).can_order is False
    )  # stuck
    assert (
        movie_status(
            _movie(hasFile=True, movieFile={"quality": {"quality": {"name": "HD"}}}), [], []
        ).can_order
        is False
    )  # in_library

    # Остальные состояния должны иметь can_order=True
    assert movie_status(None, [], []).can_order is True  # not_ordered
    assert movie_status(_movie(monitored=False), [], []).can_order is True  # unmonitored
    assert (
        movie_status(_movie(lastSearchTime="2026-08-02T13:39:54Z"), [], []).can_order is True
    )  # not_found
    assert movie_status(_movie(), [], []).can_order is True  # waiting


def test_queued_search_command_counts_as_searching():
    """Команда в статусе queued считается активной поиской, как и started."""
    s = movie_status(_movie(), [], [_search_command([5], status="queued")])
    assert s.state == "searching"
    assert s.can_order is False


def test_import_pending_shows_as_importing():
    """importPending — это идущий импорт."""
    s = movie_status(_movie(), [_queue_record(trackedDownloadState="importPending")], [])
    assert s.state == "importing"
    assert s.label == "Импортируется"


def test_import_blocked_shows_as_stuck():
    """importBlocked — это заблокированный импорт, состояние stuck."""
    s = movie_status(_movie(), [_queue_record(trackedDownloadState="importBlocked")], [])
    assert s.state == "stuck"
    assert "заблокирован" in s.label.lower()
    assert s.can_order is False
