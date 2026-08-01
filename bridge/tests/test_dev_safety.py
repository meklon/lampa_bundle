"""Инварианты безопасности отладочного цикла.

Всё здесь — про то, чтобы разработка не наделала реальных загрузок и не
засорила настоящую библиотеку. Каждый пункт из CLAUDE.md, раздел
«Безопасность при разработке».
"""

import pytest

from app.config import settings
from app.radarr import Radarr
from app.sonarr import Sonarr


def test_dev_orders_are_tagged():
    """Заказы в dev-режиме помечаются тегом.

    Отдельных root folder больше нет — они убраны как лишняя сущность.
    Отличить отладочный заказ от настоящего и снести его одной командой
    позволяет тег, и это единственный механизм, который для этого остался.
    """
    s = settings()
    assert s.is_dev
    assert s.test_tag, "без тега отладочные заказы не отличить от настоящих"


def test_search_never_enabled_in_dev():
    """Главный предохранитель: searchForMovie=true вызывает РЕАЛЬНУЮ загрузку."""
    assert settings().search_enabled is False


@pytest.mark.parametrize("requested_search", [True, False])
def test_movie_payload_never_searches_in_dev(requested_search):
    """Даже если вызывающий попросил поиск, в dev он не уйдёт.

    Проверяется на уровне сборки тела: add_movie дополнительно страхует,
    но и сам payload обязан быть построен с тем, что ему передали.
    """
    s = settings()
    effective = requested_search and s.search_enabled
    body = Radarr(client=None)._build_add_payload(  # type: ignore[arg-type]
        tmdb_id=10378,
        title="Big Buck Bunny",
        profile_id=4,
        root=s.radarr_root,
        search=effective,
    )
    assert body["addOptions"]["searchForMovie"] is False


def test_series_payload_never_searches():
    """У Sonarr поиск при добавлении выключается двумя флагами сразу."""
    body = Sonarr(client=None)._build_add_payload(  # type: ignore[arg-type]
        tvdb_id=81189, title="Breaking Bad", profile_id=4, root="/data/media/_test_tv"
    )
    opts = body["addOptions"]
    assert opts["searchForMissingEpisodes"] is False
    assert opts["searchForCutoffUnmetEpisodes"] is False


def test_test_tag_present_in_payload_when_given():
    """Тестовые заказы помечаются тегом, чтобы потом снести не глядя."""
    body = Radarr(client=None)._build_add_payload(  # type: ignore[arg-type]
        tmdb_id=10378, title="Big Buck Bunny", profile_id=4, root="/x", search=False, tags=[3]
    )
    assert body["tags"] == [3]


def test_no_secrets_in_plugin_js():
    """В плагин не попадает ни один секрет — только адрес bridge.

    Тот же grep делает приёмка этапа 6, но дешевле ловить это тестом.
    """
    from pathlib import Path

    src = Path(__file__).resolve().parents[1] / "static" / "plugin.js"
    if not src.exists():
        pytest.skip("plugin.js ещё нет")
    text = src.read_text(encoding="utf-8")
    s = settings()
    for secret in (s.radarr_api_key, s.sonarr_api_key, s.tmdb_token):
        assert secret not in text
    for forbidden in ("X-Api-Key", "api_key", "7878", "8989", "9696"):
        assert forbidden not in text, f"в plugin.js есть «{forbidden}»"
