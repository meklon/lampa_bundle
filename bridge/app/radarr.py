"""Клиент Radarr.

ИМЕНА ПОЛЕЙ БЕРУТСЯ ИЗ openapi/radarr-v3-*.json, НЕ ИЗ ПАМЯТИ.
Схема не отдаётся живым инстансом по /api/v3/openapi.json — на
production-сборках этого пути нет. Схема лежит в исходниках проекта:
src/Radarr.Api.V3/openapi.json.
"""

import httpx

from .config import settings
from .errors import (
    ProfileNotFound,
    RootFolderNotFound,
    UpstreamAuth,
    UpstreamUnavailable,
)


class Radarr:
    def __init__(self, client: httpx.AsyncClient) -> None:
        self._c = client
        self._s = settings()

    def _url(self, path: str) -> str:
        return f"{self._s.radarr_url}/api/v3{path}"

    def _headers(self) -> dict[str, str]:
        return {
            "X-Api-Key": self._s.radarr_api_key,
            "Content-Type": "application/json",
        }

    async def _request(self, method: str, path: str, json: dict | None = None) -> httpx.Response:
        try:
            r = await self._c.request(
                method, self._url(path), headers=self._headers(), json=json, timeout=30.0
            )
        except httpx.HTTPError as e:
            raise UpstreamUnavailable(f"Radarr недоступен: {e}") from e
        if r.status_code in (401, 403):
            raise UpstreamAuth("Radarr отверг API-ключ")
        return r

    # -- разрешение параметров ------------------------------------------------

    async def profile_id(self, name: str) -> int:
        r = await self._request("GET", "/qualityprofile")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /qualityprofile вернул {r.status_code}")
        for p in r.json():
            if p.get("name") == name:
                return int(p["id"])
        raise ProfileNotFound(f"профиль качества «{name}» в Radarr не найден")

    async def root_folder(self, path: str) -> str:
        r = await self._request("GET", "/rootfolder")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /rootfolder вернул {r.status_code}")
        for f in r.json():
            if f.get("path") == path:
                return str(f["path"])
        raise RootFolderNotFound(f"корневой каталог «{path}» в Radarr не настроен")

    async def find_by_tmdb(self, tmdb_id: int) -> dict | None:
        r = await self._request("GET", "/movie")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /movie вернул {r.status_code}")
        for m in r.json():
            if m.get("tmdbId") == tmdb_id:
                return m
        return None

    # -- добавление ----------------------------------------------------------

    def _build_add_payload(
        self, tmdb_id: int, profile_id: int, root: str, search: bool
    ) -> dict:
        """Тело запроса POST /api/v3/movie.

        НЕ РЕАЛИЗОВАНО НАМЕРЕННО.

        Формально обязательным по схеме является только `title`; практически
        добавление требует tmdbId, qualityProfileId и rootFolderPath. Точный
        состав, типы и вложенность (в частности addOptions) сверить со схемой
        `MovieResource` / `AddMovieOptions` в openapi/radarr-v3-*.json.

        Ориентир по полям, ПОДЛЕЖАЩИЙ ПРОВЕРКЕ:
            tmdbId, qualityProfileId, rootFolderPath, monitored,
            minimumAvailability, addOptions.searchForMovie

        minimumAvailability берётся из настроек: announced | inCinemas |
        released | preDB. По умолчанию released. preDB сейчас идентичен
        released, использовать его смысла нет. Слишком строгое значение =>
        фильм добавлен, но поиск не стартует, и ошибки при этом нет.

        `search` обязан быть False, когда settings().is_dev.

        Если ожидаемого поля в схеме нет — СТОП-УСЛОВИЕ №1: остановиться и
        написать отчёт. НЕ подставлять имя «по смыслу».
        """
        raise NotImplementedError(
            "заполнить по openapi/radarr-v3-*.json, схема MovieResource"
        )

    async def add_movie(self, tmdb_id: int, search: bool) -> dict:
        profile = await self.profile_id(self._s.radarr_profile)
        root = await self.root_folder(self._s.radarr_root)

        # Страховка на случай, если вызывающий передал search=True в dev
        effective_search = search and self._s.search_enabled

        payload = self._build_add_payload(tmdb_id, profile, root, effective_search)
        r = await self._request("POST", "/movie", json=payload)

        if r.status_code >= 400:
            raise UpstreamUnavailable(
                f"Radarr отказал при добавлении: {r.status_code} {r.text[:300]}"
            )
        return r.json()
