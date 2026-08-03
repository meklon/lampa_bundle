"""Машина состояний заказа.

Проверяется таблицей, а не отдельными случаями: состояний девять у фильма и
десять у сезона, и почти все различаются одним полем. Структуры полей взяты из
openapi-схем Radarr и Sonarr, конкретные значения подставлены в фикстурах теста.
"""

from app.status import ItemStatus, movie_status, series_status


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


def test_import_pending_shows_as_importing():
    """importPending из TrackedDownloadState enum."""
    s = movie_status(_movie(), [_queue_record(trackedDownloadState="importPending")], [])
    assert s.state == "importing"


def test_import_active_shows_as_importing():
    """importing из TrackedDownloadState enum."""
    s = movie_status(_movie(), [_queue_record(trackedDownloadState="importing")], [])
    assert s.state == "importing"
    assert s.label == "Импортируется"


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


def test_import_blocked_shows_as_stuck():
    """importBlocked — это заблокированный импорт, состояние stuck."""
    s = movie_status(_movie(), [_queue_record(trackedDownloadState="importBlocked")], [])
    assert s.state == "stuck"
    assert "заблокирован" in s.label.lower()
    assert s.can_order is False


def test_imported_shows_as_downloading():
    """imported — файл уже завершил импорт, но не переместился в место назначения.
    Обычно это should быть перехвачено hasFile, но на промежуточном этапе показываем
    как downloading, пока не обновится статус фильма."""
    s = movie_status(_movie(), [_queue_record(trackedDownloadState="imported")], [])
    # imported не совпадает с _IMPORT_ACTIVE и _IMPORT_BLOCKED, поэтому проваливается в downloading
    assert s.state == "downloading"


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
    cmd = {"name": "SeasonSearch", "status": "started", "body": {"seriesId": 1, "seasonNumber": 2}}
    s = series_status(_series(), _episodes(), [], [cmd])
    assert s.seasons[0].state == "searching"


def test_season_search_of_another_season_ignored():
    cmd = {"name": "SeasonSearch", "status": "started", "body": {"seriesId": 1, "seasonNumber": 5}}
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
