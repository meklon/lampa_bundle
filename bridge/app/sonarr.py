"""Клиент Sonarr.

ИМЕНА ПОЛЕЙ БЕРУТСЯ ИЗ openapi/sonarr-v3-*.json, НЕ ИЗ ПАМЯТИ.

Два инварианта этого модуля:
  1. Добавление только по tvdbId. Добавление по tmdbId Sonarr не поддерживает.
     Поиск по названию через series/lookup?term= ЗАПРЕЩЁН: нечёткое
     совпадение притащит не тот сериал. Дополнительно, series/lookup
     возвращает недостоверные флаги monitored для не добавленных сериалов.
  2. monitorNewItems="none" на каждом добавляемом сериале. Без этого заказ
     одного сезона превращается в подписку на сериал. Глобальной настройки
     для поля не существует, задаётся только на сериал.
"""

import httpx

from .config import settings
from .errors import (
    ProfileNotFound,
    RootFolderNotFound,
    UpstreamAuth,
    UpstreamUnavailable,
)


class Sonarr:
    def __init__(self, client: httpx.AsyncClient) -> None:
        self._c = client
        self._s = settings()

    def _url(self, path: str) -> str:
        return f"{self._s.sonarr_url}/api/v3{path}"

    def _headers(self) -> dict[str, str]:
        return {
            "X-Api-Key": self._s.sonarr_api_key,
            "Content-Type": "application/json",
        }

    async def _request(self, method: str, path: str, json: dict | None = None) -> httpx.Response:
        try:
            r = await self._c.request(
                method, self._url(path), headers=self._headers(), json=json, timeout=30.0
            )
        except httpx.HTTPError as e:
            raise UpstreamUnavailable(f"Sonarr недоступен: {e}") from e
        if r.status_code in (401, 403):
            raise UpstreamAuth("Sonarr отверг API-ключ")
        return r

    # -- разрешение параметров ------------------------------------------------

    async def profile_id(self, name: str) -> int:
        r = await self._request("GET", "/qualityprofile")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /qualityprofile вернул {r.status_code}")
        for p in r.json():
            if p.get("name") == name:
                return int(p["id"])
        raise ProfileNotFound(f"профиль качества «{name}» в Sonarr не найден")

    async def root_folder(self, path: str) -> str:
        r = await self._request("GET", "/rootfolder")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /rootfolder вернул {r.status_code}")
        for f in r.json():
            if f.get("path") == path:
                return str(f["path"])
        raise RootFolderNotFound(f"корневой каталог «{path}» в Sonarr не настроен")

    async def find_by_tvdb(self, tvdb_id: int) -> dict | None:
        r = await self._request("GET", "/series")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /series вернул {r.status_code}")
        for s in r.json():
            if s.get("tvdbId") == tvdb_id:
                return s
        return None

    # -- добавление ----------------------------------------------------------

    def _build_add_payload(self, tvdb_id: int, profile_id: int, root: str) -> dict:
        """Тело запроса POST /api/v3/series.

        НЕ РЕАЛИЗОВАНО НАМЕРЕННО.

        Сверить со схемой `SeriesResource` / `AddSeriesOptions` в
        openapi/sonarr-v3-*.json.

        Ориентир по полям, ПОДЛЕЖАЩИЙ ПРОВЕРКЕ:
            tvdbId, qualityProfileId, rootFolderPath, monitored,
            seasonFolder=True, monitorNewItems="none",
            addOptions.monitor="none"

        Значения addOptions.monitor: all | future | missing | existing |
        pilot | firstSeason | latestSeason | none (плюс monitorSpecials /
        unmonitorSpecials). Нам нужен "none".

        monitorNewItems: значения all | none. Нам нужен "none" — ОБЯЗАТЕЛЬНО.

        ОТКРЫТЫЙ ВОПРОС №1: массив seasons формально входит в состав данных
        добавления, но addOptions.monitor может переопределить флаги в момент
        добавления. Поэтому принят двухшаговый путь: добавить с monitor="none",
        затем set_season_monitored(). Если проверка по схеме и логам Sonarr
        покажет, что одного POST достаточно — упростить и обновить SPEC.md.

        Если ожидаемого поля в схеме нет — СТОП-УСЛОВИЕ №1.
        """
        raise NotImplementedError(
            "заполнить по openapi/sonarr-v3-*.json, схема SeriesResource"
        )

    async def add_series(self, tvdb_id: int) -> dict:
        """Добавляет сериал БЕЗ мониторинга сезонов."""
        profile = await self.profile_id(self._s.sonarr_profile)
        root = await self.root_folder(self._s.sonarr_root)

        payload = self._build_add_payload(tvdb_id, profile, root)
        r = await self._request("POST", "/series", json=payload)
        if r.status_code >= 400:
            raise UpstreamUnavailable(
                f"Sonarr отказал при добавлении: {r.status_code} {r.text[:300]}"
            )
        return r.json()

    def _build_seasonpass_payload(self, series: dict, season: int) -> dict:
        """Тело запроса POST /api/v3/seasonpass.

        НЕ РЕАЛИЗОВАНО НАМЕРЕННО.

        Известная форма, ПОДЛЕЖАЩАЯ ПРОВЕРКЕ по схеме: объект с массивом
        `series` (каждый элемент — id, monitored и вложенный массив seasons
        из {seasonNumber, monitored}) плюс объект `monitoringOptions` с полем
        `monitor`.

        Целевой сезон monitored=True, все остальные False. Проверяется
        checks/06-bridge-season.sh: отслеживаемых сезонов обязано быть РОВНО
        ОДИН.

        Альтернатива — PUT /api/v3/series/{id} с изменённым массивом seasons.
        Выбрать по схеме, не по догадке.
        """
        raise NotImplementedError(
            "заполнить по openapi/sonarr-v3-*.json, схема SeasonPassResource"
        )

    async def set_season_monitored(self, series: dict, season: int) -> None:
        payload = self._build_seasonpass_payload(series, season)
        r = await self._request("POST", "/seasonpass", json=payload)
        if r.status_code >= 400:
            raise UpstreamUnavailable(
                f"Sonarr отказал при настройке сезона: {r.status_code} {r.text[:300]}"
            )

    async def search_season(self, series_id: int, season: int) -> None:
        """POST /api/v3/command, {"name": "SeasonSearch", ...}.

        Вызывается ТОЛЬКО когда settings().search_enabled. В dev-режиме
        поиск не запускается ни при каких входных данных.
        """
        if not self._s.search_enabled:
            return
        r = await self._request(
            "POST",
            "/command",
            json={"name": "SeasonSearch", "seriesId": series_id, "seasonNumber": season},
        )
        if r.status_code >= 400:
            raise UpstreamUnavailable(
                f"Sonarr отказал при запуске поиска: {r.status_code} {r.text[:300]}"
            )
