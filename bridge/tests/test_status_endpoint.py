"""Контракт GET /status."""

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    """Любой невыдуманный запрос наружу — ошибка ТЕСТА, а не проверка.

    Ловушка, из-за которой один из тестов ниже проходил не по той причине:
    он подменял Radarr.queue и утверждал «отказ очереди → ошибка», но до
    очереди дело не доходило — первым шёл непатченный find_by_tmdb и падал
    на резолве имени `radarr`. Вне compose-сети имя не резолвится и тест
    зеленел; внутри неё оно резолвится, find_by_tmdb возвращает None, ответ
    становится 200 not_ordered — и тест падает при неизменном коде.

    Здесь сеть закрыта целиком: тест, забывший подменить обращение к *arr,
    получает внятное «ушёл в сеть», а не случайный зелёный или красный.
    """

    async def refuse(self, method, url, *args, **kwargs):
        raise AssertionError(
            f"тест ушёл в настоящую сеть: {method} {url}. Подмени обращение к *arr или TMDB явно."
        )

    monkeypatch.setattr(httpx.AsyncClient, "request", refuse)


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


def test_status_tv_without_tvdb_id_is_error(monkeypatch):
    """Сериал есть в TMDB, но у него нет tvdb_id → ошибка, а не 500 и не
    выдуманное состояние.

    Sonarr работает только по TVDB; NoTvdbId обязан всплыть раньше, чем
    эндпоинт вообще узнает, есть ли сериал в Sonarr."""
    from app.errors import NoTvdbId
    from app.tmdb import Tmdb

    async def no_tvdb(self, tmdb_id):
        raise NoTvdbId()

    monkeypatch.setattr(Tmdb, "tvdb_id", no_tvdb)
    with TestClient(app) as client:
        r = client.get("/status", params={"tmdb_id": 1, "type": "tv"})
    assert r.status_code == 422
    assert "not_ordered" not in r.text


def test_status_tv_not_in_sonarr(monkeypatch):
    """Сериала нет в Sonarr → not_ordered, без падения на series["id"]."""
    from app.sonarr import Sonarr
    from app.tmdb import Tmdb

    async def tvdb_id(self, tmdb_id):
        return 12345

    async def no_series(self, tvdb_id):
        return None

    monkeypatch.setattr(Tmdb, "tvdb_id", tvdb_id)
    monkeypatch.setattr(Sonarr, "find_by_tvdb", no_series)
    with TestClient(app) as client:
        r = client.get("/status", params={"tmdb_id": 1, "type": "tv"})
    assert r.status_code == 200
    assert r.json()["state"] == "not_ordered"


def test_upstream_failure_is_error_not_state(monkeypatch):
    """Фильм в Radarr есть, но /queue отказал → ошибка, а не not_ordered.

    Выдуманное not_ordered подтолкнуло бы заказать то, что уже качается.

    Подменяются ОБА обращения, и порядок вызовов проверяется явно: иначе
    тест утверждает про очередь, а проверяет что-то другое — ровно так он и
    жил до этой правки (см. фикстуру no_network)."""
    from app.errors import UpstreamUnavailable
    from app.radarr import Radarr

    calls = []

    async def found(self, tmdb_id):
        calls.append("find_by_tmdb")
        return {"id": 5, "tmdbId": tmdb_id, "title": "Backrooms", "hasFile": False}

    async def boom(self):
        calls.append("queue")
        raise UpstreamUnavailable("Radarr недоступен")

    monkeypatch.setattr(Radarr, "find_by_tmdb", found)
    monkeypatch.setattr(Radarr, "queue", boom)
    with TestClient(app) as client:
        r = client.get("/status", params={"tmdb_id": 1083381, "type": "movie"})
    assert calls == ["find_by_tmdb", "queue"], calls
    assert r.status_code >= 500
    assert "not_ordered" not in r.text
