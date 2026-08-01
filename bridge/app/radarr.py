"""Клиент Radarr.

ИМЕНА ПОЛЕЙ БЕРУТСЯ ИЗ openapi/radarr-v3-*.json, НЕ ИЗ ПАМЯТИ.
Схема не отдаётся живым инстансом по /api/v3/openapi.json — на
production-сборках этого пути нет. Схема лежит в исходниках проекта:
src/Radarr.Api.V3/openapi.json.
"""

import httpx

from .config import settings
from .errors import (
    ProfileNotAllowed,
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

    async def profiles(self) -> list[str]:
        """Имена профилей качества — для выбора в плагине.

        Список берётся у самого Radarr, а не задаётся в коде: профили может
        добавить и переименовать человек, и захардкоженный перечень разъехался
        бы с действительностью молча.
        """
        r = await self._request("GET", "/qualityprofile")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /qualityprofile вернул {r.status_code}")
        return [str(p["name"]) for p in r.json()]

    async def resolve_profile(self, requested: str | None) -> str:
        """Имя профиля для заказа: из запроса, иначе умолчание из окружения.

        Профиль из запроса — пользовательский ввод, поэтому проверяется по
        списку и при промахе даёт 422, а не 500.
        """
        if requested is None:
            return self._s.radarr_profile
        available = await self.profiles()
        if requested not in available:
            raise ProfileNotAllowed(
                f"профиля «{requested}» нет в Radarr; есть: {', '.join(available)}"
            )
        return requested

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

    async def tag_id(self, label: str) -> int:
        """Идентификатор тега по метке, с созданием при отсутствии.

        Тег нужен, чтобы тестовые заказы можно было потом отличить и снести
        не глядя. Требование CLAUDE.md.
        """
        r = await self._request("GET", "/tag")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /tag вернул {r.status_code}")
        for t in r.json():
            if t.get("label") == label:
                return int(t["id"])
        created = await self._request("POST", "/tag", json={"label": label})
        if created.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr отказал при создании тега: {created.status_code}")
        return int(created.json()["id"])

    async def lookup_title(self, tmdb_id: int) -> str:
        """Название по ТОЧНОМУ tmdbId из собственных метаданных Radarr.

        Нужно потому, что Radarr строит путь папки в момент добавления по
        `movieFolderFormat`, где стоит `{Movie CleanTitle}`. Без `title` в теле
        запроса он падает с 500 и NullReferenceException в
        FileNameBuilder.CleanTitle — см. docs/SPEC.md 2.4.

        Название берётся у Radarr, а не у TMDB: именно его Radarr подставит в
        имя папки, и для переводных тайтлов эти строки расходятся. Разошлись бы
        — папка создалась бы под одним именем, а канонической считалась бы
        другая.

        Это поиск по идентификатору, не по названию. Запрет из CLAUDE.md
        касается `term=<название>` с нечётким совпадением.
        """
        r = await self._request("GET", f"/movie/lookup/tmdb?tmdbId={tmdb_id}")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Radarr /movie/lookup/tmdb вернул {r.status_code}")
        title = (r.json() or {}).get("title")
        if not title:
            raise UpstreamUnavailable(f"Radarr не знает фильма с tmdbId={tmdb_id}")
        return str(title)

    def _build_add_payload(
        self,
        tmdb_id: int,
        title: str,
        profile_id: int,
        root: str,
        search: bool,
        tags: list[int] | None = None,
    ) -> dict:
        """Тело запроса POST /api/v3/movie.

        Имена полей сверены со схемой `MovieResource` и `AddMovieOptions` в
        `openapi/radarr-v3-v6.3.0.10514.json`. Сверка автоматическая:
        tests/test_payloads.py проверяет каждый ключ против той же схемы, а не
        против списка, записанного здесь по памяти.

        `minimumAvailability` — из окружения, значение обязано принадлежать
        `MovieStatusType`. Слишком строгое даёт «добавлено, но не ищет»: Radarr
        считает, что фильм ещё не вышел, добавление проходит, поиск не
        стартует, и ошибки при этом нет.

        **`title` обязателен, хотя схема утверждает обратное.** В
        `MovieResource` у него `"nullable": true`, а списка `required` у схемы
        нет вовсе. На практике Radarr 6.3.0.10514 отвечает 500 с
        `NullReferenceException at FileNameBuilder.CleanTitle`: путь папки
        строится в момент добавления по `movieFolderFormat`, где стоит
        `{Movie CleanTitle}`. Название берётся у самого Radarr, см.
        `lookup_title`.
        """
        payload: dict = {
            "tmdbId": tmdb_id,
            "title": title,
            "qualityProfileId": profile_id,
            "rootFolderPath": root,
            "monitored": True,
            "minimumAvailability": self._s.radarr_min_availability,
            "addOptions": {"searchForMovie": search},
        }
        if tags:
            payload["tags"] = tags
        return payload

    async def add_movie(self, tmdb_id: int, search: bool, profile_name: str | None = None) -> dict:
        profile = await self.profile_id(profile_name or self._s.radarr_profile)
        root = await self.root_folder(self._s.radarr_root)

        # Страховка на случай, если вызывающий передал search=True в dev
        effective_search = search and self._s.search_enabled

        title = await self.lookup_title(tmdb_id)
        tags = [await self.tag_id(self._s.test_tag)] if self._s.is_dev else None
        payload = self._build_add_payload(tmdb_id, title, profile, root, effective_search, tags)
        r = await self._request("POST", "/movie", json=payload)

        if r.status_code >= 400:
            raise UpstreamUnavailable(
                f"Radarr отказал при добавлении: {r.status_code} {r.text[:300]}"
            )
        return r.json()
