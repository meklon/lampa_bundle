"""Фикстуры. Ответы API берутся из recorded/, а не пишутся из головы.

Мок, написанный по памяти, отражает представления автора, а не реальный API —
и тогда тесты фиксируют неправильную схему.
"""

import json
from pathlib import Path

import pytest

RECORDED = Path(__file__).parent / "recorded"


@pytest.fixture(autouse=True)
def env(monkeypatch):
    """Окружение для Settings. dev-режим: поиск не запускается."""
    values = {
        "BRIDGE_ENV": "dev",
        "RADARR_URL": "http://radarr:7878",
        "RADARR_API_KEY": "test-radarr-key",
        "RADARR_ROOT": "/data/media/movies",
        "RADARR_PROFILE": "HD-1080p",
        "RADARR_MIN_AVAILABILITY": "released",
        "SONARR_URL": "http://sonarr:8989",
        "SONARR_API_KEY": "test-sonarr-key",
        "SONARR_ROOT": "/data/media/tv",
        "SONARR_PROFILE": "HD-1080p",
        "TMDB_TOKEN": "test-tmdb-token",
        "TEST_TAG": "test",
        "CORS_ORIGINS": "http://192.168.200.251:9118,http://localhost:3000",
    }
    for k, v in values.items():
        monkeypatch.setenv(k, v)

    from app.config import settings

    settings.cache_clear()
    yield
    settings.cache_clear()


def load(name: str):
    """Записанный ответ API.

    Снять с живого инстанса:
      curl -s -H "X-Api-Key: $KEY" http://localhost:7878/api/v3/<path> \
        > bridge/tests/recorded/<name>.json
    Ключи из ответа вычистить перед коммитом.
    """
    path = RECORDED / f"{name}.json"
    if not path.exists():
        pytest.skip(
            f"нет записанного ответа {path.name} — снять с живого инстанса, "
            "см. bridge/tests/README.md"
        )
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture
def recorded():
    return load
