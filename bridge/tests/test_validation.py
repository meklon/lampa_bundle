"""Валидация контракта. Единственный файл тестов, не требующий записанных
ответов API — поэтому его можно запустить сразу, до этапа 4.

Остальные тесты писать по bridge/tests/README.md, на записанных ответах.
"""

import pytest
from pydantic import ValidationError as PydanticValidationError

from app.models import OrderRequest


def test_movie_without_season_ok():
    r = OrderRequest(tmdb_id=550, type="movie")
    assert r.season is None


def test_tv_requires_season():
    with pytest.raises(PydanticValidationError):
        OrderRequest(tmdb_id=1399, type="tv")


def test_movie_rejects_season():
    with pytest.raises(PydanticValidationError):
        OrderRequest(tmdb_id=550, type="movie", season=1)


def test_tv_with_season_ok():
    r = OrderRequest(tmdb_id=1399, type="tv", season=2)
    assert r.season == 2


def test_season_zero_allowed():
    """Сезон 0 — спецэпизоды. Валидный номер."""
    r = OrderRequest(tmdb_id=1399, type="tv", season=0)
    assert r.season == 0


def test_tmdb_id_must_be_positive():
    with pytest.raises(PydanticValidationError):
        OrderRequest(tmdb_id=0, type="movie")


def test_unknown_type_rejected():
    with pytest.raises(PydanticValidationError):
        OrderRequest(tmdb_id=550, type="anime")  # type: ignore[arg-type]


def test_dev_disables_search():
    """Главный инвариант безопасности разработки.

    addOptions.searchForMovie=true вызывает РЕАЛЬНУЮ загрузку. Отладочный цикл
    легко наделает десятки. В dev-режиме поиск не запускается ни при каких
    входных данных.
    """
    from app.config import settings

    s = settings()
    assert s.is_dev is True
    assert s.search_enabled is False


def test_cors_never_wildcard():
    """«*» — запрещённая подмена из CLAUDE.md, список origin всегда явный."""
    from app.config import settings

    origins = settings().cors_origin_list
    assert origins, "список origin пуст — заказ не уйдёт ни с какой страницы"
    assert "*" not in origins
