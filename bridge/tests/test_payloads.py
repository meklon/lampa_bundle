"""Состав тел запросов к Radarr и Sonarr.

Имена полей проверяются ПРОТИВ СХЕМЫ из `openapi/`, а не против списка,
записанного здесь по памяти. Иначе тест закрепил бы те же представления,
из которых написан код, и ошибка в имени поля прошла бы через оба.

Схема выбирается по версии живого инстанса — файл в openapi/ ровно один на
сервис, его версия сверена `scripts/check-versions.sh` (стоп-условие №2).
"""

import json
from pathlib import Path

import pytest

from app.radarr import Radarr
from app.sonarr import Sonarr

OPENAPI = Path(__file__).resolve().parents[2] / "openapi"


def _schema(prefix: str) -> dict:
    files = sorted(OPENAPI.glob(f"{prefix}-*.json"))
    if not files:
        pytest.skip(f"нет схемы {prefix}-*.json в openapi/ — сначала этап 4")
    if len(files) > 1:
        pytest.fail(
            f"в openapi/ несколько схем {prefix}: {[f.name for f in files]}. "
            "Неясно, какая действующая — оставить схему запущенной версии"
        )
    return json.loads(files[0].read_text(encoding="utf-8"))


def properties(schema: dict, name: str) -> dict:
    node = schema["components"]["schemas"].get(name)
    assert node is not None, f"в схеме нет {name}"
    return node.get("properties", {})


def enum_values(schema: dict, name: str) -> list:
    node = schema["components"]["schemas"].get(name)
    assert node is not None, f"в схеме нет {name}"
    return node.get("enum", [])


@pytest.fixture(scope="module")
def radarr_schema() -> dict:
    return _schema("radarr-v3")


@pytest.fixture(scope="module")
def sonarr_schema() -> dict:
    return _schema("sonarr-v3")


def _radarr() -> Radarr:
    return Radarr(client=None)  # type: ignore[arg-type]


def _sonarr() -> Sonarr:
    return Sonarr(client=None)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# Radarr: POST /api/v3/movie
# ---------------------------------------------------------------------------


def test_movie_payload_fields_exist_in_schema(radarr_schema):
    """Каждое поле тела обязано существовать в MovieResource.

    Поля нет в схеме — стоп-условие №1, а не повод подставить имя «по смыслу».
    """
    body = _radarr()._build_add_payload(
        tmdb_id=10378, title="Big Buck Bunny", profile_id=4, root="/data/media/movies", search=False
    )
    allowed = properties(radarr_schema, "MovieResource")
    unknown = [k for k in body if k not in allowed]
    assert not unknown, f"полей нет в MovieResource: {unknown}"


def test_movie_payload_addoptions_fields_exist(radarr_schema):
    body = _radarr()._build_add_payload(
        tmdb_id=10378, title="Big Buck Bunny", profile_id=4, root="/data/media/movies", search=False
    )
    allowed = properties(radarr_schema, "AddMovieOptions")
    unknown = [k for k in body.get("addOptions", {}) if k not in allowed]
    assert not unknown, f"полей нет в AddMovieOptions: {unknown}"


def test_movie_payload_carries_required_values():
    body = _radarr()._build_add_payload(
        tmdb_id=10378, title="Big Buck Bunny", profile_id=4, root="/data/media/movies", search=False
    )
    assert body["tmdbId"] == 10378
    assert body["qualityProfileId"] == 4
    assert body["rootFolderPath"] == "/data/media/movies"
    assert body["monitored"] is True


def test_movie_payload_includes_title():
    """title обязателен, хотя схема утверждает обратное.

    В MovieResource у title стоит "nullable": true, а списка required у схемы
    нет вовсе. На практике Radarr 6.3.0.10514 без него отвечает 500:
    NullReferenceException в FileNameBuilder.CleanTitle — путь папки строится
    при добавлении по movieFolderFormat, где стоит {Movie CleanTitle}.

    Тест существует, чтобы поле не «оптимизировали» обратно, поверив схеме.
    """
    body = _radarr()._build_add_payload(
        tmdb_id=10378, title="Big Buck Bunny", profile_id=4, root="/x", search=False
    )
    assert body["title"] == "Big Buck Bunny"


def test_movie_minimum_availability_is_valid_enum(radarr_schema):
    """Слишком строгое значение даёт «добавилось, но не ищет» БЕЗ ошибки."""
    body = _radarr()._build_add_payload(
        tmdb_id=10378, title="Big Buck Bunny", profile_id=4, root="/data/media/movies", search=False
    )
    allowed = enum_values(radarr_schema, "MovieStatusType")
    assert (
        body["minimumAvailability"] in allowed
    ), f"minimumAvailability={body['minimumAvailability']!r} нет в {allowed}"


@pytest.mark.parametrize("search", [False, True])
def test_movie_search_flag_is_passed_through(search):
    """Флаг поиска берётся из аргумента, а не из фантазии.

    Решение «искать или нет» принимает вызывающий код по settings().
    """
    body = _radarr()._build_add_payload(
        tmdb_id=10378, title="Big Buck Bunny", profile_id=4, root="/x", search=search
    )
    assert body["addOptions"]["searchForMovie"] is search


# ---------------------------------------------------------------------------
# Sonarr: POST /api/v3/series
# ---------------------------------------------------------------------------


def test_series_payload_fields_exist_in_schema(sonarr_schema):
    body = _sonarr()._build_add_payload(
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/tv"
    )
    allowed = properties(sonarr_schema, "SeriesResource")
    unknown = [k for k in body if k not in allowed]
    assert not unknown, f"полей нет в SeriesResource: {unknown}"


def test_series_payload_addoptions_fields_exist(sonarr_schema):
    body = _sonarr()._build_add_payload(
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/tv"
    )
    allowed = properties(sonarr_schema, "AddSeriesOptions")
    unknown = [k for k in body.get("addOptions", {}) if k not in allowed]
    assert not unknown, f"полей нет в AddSeriesOptions: {unknown}"


def test_series_monitor_new_items_is_none(sonarr_schema):
    """Главный инвариант сериальной части.

    Без monitorNewItems="none" заказ одного сезона превращается в подписку
    на сериал: Sonarr начнёт мониторить будущие сезоны.
    """
    body = _sonarr()._build_add_payload(
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/tv"
    )
    assert body["monitorNewItems"] == "none"
    assert "none" in enum_values(sonarr_schema, "NewItemMonitorTypes")


def test_series_add_options_monitor_is_none(sonarr_schema):
    """Добавляем БЕЗ мониторинга сезонов, нужный включается вторым шагом."""
    body = _sonarr()._build_add_payload(
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/tv"
    )
    assert body["addOptions"]["monitor"] == "none"
    assert "none" in enum_values(sonarr_schema, "MonitorTypes")


def test_series_payload_has_no_seasons_array():
    """Массив seasons в POST /series НЕ передаётся.

    Проверено опытом на Sonarr 4.0.19.2979: addOptions.monitor затирает флаги
    после добавления, причём ответ POST этого не показывает — возвращает
    monitored=true, тогда как в базе false. См. docs/SPEC.md 2.5.
    """
    body = _sonarr()._build_add_payload(
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/tv"
    )
    assert "seasons" not in body


def test_series_season_folder_enabled():
    """docs/NAMING.md требует папки сезонов; по умолчанию seasonFolder=false."""
    body = _sonarr()._build_add_payload(
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/tv"
    )
    assert body["seasonFolder"] is True


def test_series_payload_carries_required_values():
    body = _sonarr()._build_add_payload(
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/tv"
    )
    assert body["tvdbId"] == 81189
    assert body["qualityProfileId"] == 4
    assert body["rootFolderPath"] == "/data/media/tv"


# ---------------------------------------------------------------------------
# Sonarr: POST /api/v3/seasonpass
# ---------------------------------------------------------------------------


def _series_stub() -> dict:
    return {
        "id": 7,
        "title": "Breaking Bad",
        "tvdbId": 81189,
        "seasons": [
            {"seasonNumber": 0, "monitored": True},
            {"seasonNumber": 1, "monitored": True},
            {"seasonNumber": 2, "monitored": True},
            {"seasonNumber": 3, "monitored": True},
        ],
    }


def test_seasonpass_fields_exist_in_schema(sonarr_schema):
    body = _sonarr()._build_seasonpass_payload(_series_stub(), season=2)
    allowed = properties(sonarr_schema, "SeasonPassResource")
    unknown = [k for k in body if k not in allowed]
    assert not unknown, f"полей нет в SeasonPassResource: {unknown}"

    series_allowed = properties(sonarr_schema, "SeasonPassSeriesResource")
    for item in body["series"]:
        unknown = [k for k in item if k not in series_allowed]
        assert not unknown, f"полей нет в SeasonPassSeriesResource: {unknown}"


def test_seasonpass_omits_monitoring_options():
    """monitoringOptions — пресет, затирающий явный массив seasons.

    Проверено на живом Sonarr: и "none", и "skip" снимают мониторинг со ВСЕХ
    сезонов, включая запрошенный. Работает только полное отсутствие объекта.
    См. docs/SPEC.md 2.5.
    """
    body = _sonarr()._build_seasonpass_payload(_series_stub(), season=2)
    assert "monitoringOptions" not in body


def test_seasonpass_monitors_exactly_one_season():
    """Ровно один сезон под мониторингом — это же проверяет checks/06."""
    body = _sonarr()._build_seasonpass_payload(_series_stub(), season=2)
    seasons = body["series"][0]["seasons"]
    monitored = [s["seasonNumber"] for s in seasons if s["monitored"]]
    assert monitored == [2]


def test_seasonpass_keeps_all_seasons_in_array():
    """Остальные сезоны передаются с monitored=false, а не выбрасываются.

    Иначе непереданные сезоны сохранят прежние флаги, и «ровно один» не
    получится при повторном заказе другого сезона.
    """
    body = _sonarr()._build_seasonpass_payload(_series_stub(), season=2)
    numbers = sorted(s["seasonNumber"] for s in body["series"][0]["seasons"])
    assert numbers == [0, 1, 2, 3]


def test_seasonpass_targets_correct_series_id():
    body = _sonarr()._build_seasonpass_payload(_series_stub(), season=2)
    assert body["series"][0]["id"] == 7


def test_seasonpass_rejects_unknown_season():
    """Сезона нет у сериала — это ошибка, а не молчаливый пропуск."""
    from app.errors import SeasonOutOfRange

    with pytest.raises(SeasonOutOfRange):
        _sonarr()._build_seasonpass_payload(_series_stub(), season=99)
