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
