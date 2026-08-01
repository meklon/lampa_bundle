"""Клиент TMDB. Единственная задача — трансляция идентификаторов.

Sonarr работает по TVDB и не принимает tmdbId. Карточка Lampa даёт TMDB.
Отсюда обязательный шаг трансляции через /tv/{id}/external_ids.
"""

import httpx

from .config import settings
from .errors import NoTvdbId, NotFoundInTmdb, UpstreamUnavailable


class Tmdb:
    def __init__(self, client: httpx.AsyncClient) -> None:
        self._c = client
        self._s = settings()

    def _headers(self) -> dict[str, str]:
        # Bearer-токен v4 (Read Access Token), не api_key v3
        return {"Authorization": f"Bearer {self._s.tmdb_token}"}

    async def _get(self, path: str) -> dict:
        try:
            r = await self._c.get(
                f"{self._s.tmdb_base}{path}", headers=self._headers(), timeout=15.0
            )
        except httpx.HTTPError as e:
            raise UpstreamUnavailable(f"TMDB недоступен: {e}") from e
        if r.status_code == 404:
            raise NotFoundInTmdb
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"TMDB вернул {r.status_code}")
        return r.json()

    async def movie_title(self, tmdb_id: int) -> str:
        data = await self._get(f"/movie/{tmdb_id}")
        return data.get("title") or data.get("original_title") or str(tmdb_id)

    async def tv_title(self, tmdb_id: int) -> str:
        data = await self._get(f"/tv/{tmdb_id}")
        return data.get("name") or data.get("original_name") or str(tmdb_id)

    async def tv_season_numbers(self, tmdb_id: int) -> list[int]:
        """Номера сезонов — для валидации запрошенного до обращения к Sonarr."""
        data = await self._get(f"/tv/{tmdb_id}")
        return [s["season_number"] for s in data.get("seasons", [])]

    async def tvdb_id(self, tmdb_id: int) -> int:
        """TMDB -> TVDB.

        Отсутствие tvdb_id — легитимный исход, не сбой: у части регионального
        контента его действительно нет. Возвращаем понятную ошибку (422),
        а не 500, и НЕ пытаемся искать по названию.
        """
        data = await self._get(f"/tv/{tmdb_id}/external_ids")
        value = data.get("tvdb_id")
        if not value:
            raise NoTvdbId
        return int(value)
