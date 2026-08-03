"""Форма рукописных фикстур — против настоящих ответов *arr.

Тесты состояний (test_status.py) написаны на словарях, собранных руками: так
видно, чем один случай отличается от другого. Плата за это выяснилась на
финальном ревью — рукописные фикстуры не показали, что

* `body.movieIds` несёт не только `MoviesSearch`, но и `RefreshMovie`,
  который Radarr ставит сразу после добавления фильма («Ищется релиз…» на
  ровном месте);
* `TrackedDownloadStatusMessage` бывает и с пустым `messages`, когда весь
  текст лежит в `title` («причина не указана» при указанной причине).

Оба дефекта — расхождение представлений автора с действительностью, и
поймать их можно только сверкой с действительностью. Здесь она и делается,
по двум источникам:

1. `recorded/` — ответы, снятые с живых Radarr и Sonarr;
2. `openapi/` — схемы, объявленный источник истины по именам полей
   (CLAUDE.md, «Источник истины по API»).

Тест намеренно узкий: он проверяет ФОРМУ (какие ключи и какие значения
перечислений вообще бывают), а не поведение. Поведение — в test_status.py.
"""

import json
from pathlib import Path

import pytest

from app.status import _IMPORT_ACTIVE, _IMPORT_BLOCKED, _MOVIE_SEARCH, movie_status
from tests.test_payloads import _schema, enum_values, properties
from tests.test_status import (
    _episodes,
    _movie,
    _queue_record,
    _search_command,
    _series,
    _tv_queue,
)

RECORDED = Path(__file__).parent / "recorded"


def recorded(name: str):
    path = RECORDED / f"{name}.json"
    if not path.exists():
        pytest.skip(f"нет записанного ответа {path.name} — см. bridge/tests/README.md")
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def radarr_schema() -> dict:
    return _schema("radarr-v3")


@pytest.fixture(scope="module")
def sonarr_schema() -> dict:
    return _schema("sonarr-v3")


def _extra(fixture: dict, allowed) -> set[str]:
    return set(fixture) - set(allowed)


# --- рукописное против схемы ------------------------------------------------


def test_movie_fixture_has_no_invented_fields(radarr_schema):
    """Каждый ключ рукописного фильма есть в MovieResource."""
    assert _extra(_movie(), properties(radarr_schema, "MovieResource")) == set()


def test_queue_fixtures_have_no_invented_fields(radarr_schema, sonarr_schema):
    """То же для очереди. Ключи разные у Radarr и Sonarr (movieId против
    seriesId + seasonNumber), поэтому сверяются со своей схемой."""
    assert _extra(_queue_record(), properties(radarr_schema, "QueueResource")) == set()
    assert _extra(_tv_queue(), properties(sonarr_schema, "QueueResource")) == set()


def test_command_fixture_has_no_invented_fields(radarr_schema):
    assert _extra(_search_command([5]), properties(radarr_schema, "CommandResource")) == set()


def test_episode_fixture_has_no_invented_fields(sonarr_schema):
    assert _extra(_episodes()[0], properties(sonarr_schema, "EpisodeResource")) == set()


def test_fixture_enum_values_are_real(radarr_schema):
    """Значения перечислений в фикстурах и в коде — из схемы, а не по смыслу."""
    states = enum_values(radarr_schema, "TrackedDownloadState")
    statuses = enum_values(radarr_schema, "TrackedDownloadStatus")
    assert _queue_record()["trackedDownloadState"] in states
    assert _queue_record()["trackedDownloadStatus"] in statuses
    assert _IMPORT_ACTIVE | _IMPORT_BLOCKED <= set(states)
    # На этом значении держится решение «ok глушит statusMessages».
    assert "ok" in statuses


def test_status_message_may_carry_text_in_title(radarr_schema, sonarr_schema):
    """Схема разрешает запись без messages — значит, читать только messages
    нельзя. Ровно этот пропуск и дал «причина не указана»."""
    for schema in (radarr_schema, sonarr_schema):
        message = properties(schema, "TrackedDownloadStatusMessage")
        assert "title" in message
        assert message["messages"].get("nullable") is True


# --- рукописное против записанного ------------------------------------------


def test_hand_written_season_matches_recorded_season():
    """Сезон и его статистика — те же ключи, что отдаёт живой Sonarr."""
    real = {s["seasonNumber"]: s for s in recorded("sonarr-series-one")["seasons"]}
    assert real, "в записанном сериале нет сезонов"
    sample = real[next(iter(sorted(real)))]
    mine = _series()["seasons"][0]
    assert _extra(mine, sample) == set()
    assert _extra(mine["statistics"], sample["statistics"]) == set()


def test_hand_written_episode_matches_recorded_episode(sonarr_schema):
    """Эпизод — те же ключи, что у живого Sonarr.

    Исключение ровно одно и объяснимое: `lastSearchTime` в записанном ответе
    отсутствует. Он есть в EpisodeResource и приходит только у эпизодов, по
    которым поиск запускался, — поэтому код читает его через .get(), а не по
    ключу. Проверяем оба утверждения, чтобы исключение не превратилось в
    дыру.
    """
    sample = recorded("sonarr-episode")[0]
    assert _extra(_episodes()[0], sample) == {"lastSearchTime"}
    assert "lastSearchTime" in properties(sonarr_schema, "EpisodeResource")


def test_recorded_commands_carry_keys_the_code_reads():
    for name in ("radarr-command", "sonarr-command"):
        for command in recorded(name):
            assert {"name", "status", "body"} <= set(command), command


def test_recorded_queue_is_a_page_not_a_list():
    """Ловушка /queue: страница, а не массив. Radarr.queue разворачивает её."""
    for name in ("radarr-queue", "sonarr-queue"):
        page = recorded(name)
        assert isinstance(page, dict)
        assert {"records", "totalRecords"} <= set(page)


def test_movie_ids_alone_do_not_mean_search():
    """Обоснование фильтра по имени команды — записанным ответом.

    RefreshMovie снят с живого Radarr: он активен (queued) и несёт
    body.movieIds. Фильтр по одному только movieIds объявил бы поиск.
    """
    refresh = recorded("radarr-command-refresh")
    assert refresh["name"] not in _MOVIE_SEARCH
    assert refresh["status"] in ("queued", "started")
    assert refresh["body"]["movieIds"], refresh["body"]

    movie = _movie(id=refresh["body"]["movieIds"][0])
    assert movie_status(movie, [], [refresh]).state != "searching"


def test_movies_search_command_name_matches_recorded():
    """Всё состояние `searching` держится на точном совпадении строки
    `MoviesSearch` в `_MOVIE_SEARCH`. Опечатка в ней дала бы ложноотрицательный
    результат молча — состояние не показалось бы никогда, и ни один
    рукописный тест (пишущий то же предположение об имени, что и код) этого
    не поймает. Ответ записан с живого Radarr: `POST /api/v3/command`
    `{"name":"MoviesSearch","movieIds":[3]}` на «Piper» (tmdbId=399106,
    короткометражка Pixar без единого релиза на подключённом трекере) —
    завершился как «Completed search for 1 movies. 0 reports downloaded.»,
    очередь Radarr осталась пустой.
    """
    search = recorded("radarr-command-search")
    assert search["name"] in _MOVIE_SEARCH
    assert search["status"] in ("queued", "started")
    assert search["body"]["movieIds"], search["body"]

    movie = _movie(id=search["body"]["movieIds"][0])
    assert movie_status(movie, [], [search]).state == "searching"
