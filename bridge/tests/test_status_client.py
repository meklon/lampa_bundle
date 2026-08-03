"""Чтение очереди и команд.

Проверяется главная ловушка: /queue отдаёт страницу, а не массив. Ошибка
здесь дала бы пустую очередь при непустой очереди — молчаливо."""

import httpx
import pytest

from app.errors import UpstreamUnavailable
from app.radarr import Radarr
from app.sonarr import Sonarr

PAGE = {
    "page": 1,
    "pageSize": 20,
    "sortKey": "timeleft",
    "sortDirection": "ascending",
    "totalRecords": 1,
    "records": [{"movieId": 5, "title": "x"}],
}


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@pytest.mark.asyncio
async def test_radarr_queue_unwraps_page():
    async with _client(lambda r: httpx.Response(200, json=PAGE)) as c:
        assert await Radarr(c).queue() == PAGE["records"]


@pytest.mark.asyncio
async def test_sonarr_queue_unwraps_page():
    async with _client(lambda r: httpx.Response(200, json=PAGE)) as c:
        assert await Sonarr(c).queue() == PAGE["records"]


@pytest.mark.asyncio
async def test_commands_returns_list():
    data = [{"name": "MoviesSearch", "status": "started", "body": {"movieIds": [5]}}]
    async with _client(lambda r: httpx.Response(200, json=data)) as c:
        assert await Radarr(c).commands() == data


@pytest.mark.asyncio
async def test_queue_failure_raises_not_empty_list():
    """Отказ обязан стать исключением. Пустой список означал бы «ничего не
    качается» — выдуманное состояние вместо честной ошибки."""
    async with _client(lambda r: httpx.Response(500, text="boom")) as c:
        with pytest.raises(UpstreamUnavailable):
            await Radarr(c).queue()
