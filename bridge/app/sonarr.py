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

import asyncio
import time

import httpx

from .config import settings
from .errors import (
    ProfileNotFound,
    RootFolderNotFound,
    SeasonOutOfRange,
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

    async def tag_id(self, label: str) -> int:
        """Идентификатор тега по метке, с созданием при отсутствии."""
        r = await self._request("GET", "/tag")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /tag вернул {r.status_code}")
        for t in r.json():
            if t.get("label") == label:
                return int(t["id"])
        created = await self._request("POST", "/tag", json={"label": label})
        if created.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr отказал при создании тега: {created.status_code}")
        return int(created.json()["id"])

    async def lookup_title(self, tvdb_id: int) -> str:
        """Название по ТОЧНОМУ tvdbId из собственных метаданных Sonarr.

        Нужно по той же причине, что и у Radarr: путь папки строится в момент
        добавления по `seriesFolderFormat`, и без `title` Sonarr отвечает 500 с
        `ArgumentNullException` из регулярного выражения. См. docs/SPEC.md 2.5.

        `term=tvdb:<id>` — это поиск по идентификатору. Запрет из CLAUDE.md
        касается `term=<название>`: там нечёткое совпадение притащило бы не тот
        сериал. Здесь идентификатор уже получен от TMDB, и результат
        проверяется на единственность.
        """
        r = await self._request("GET", f"/series/lookup?term=tvdb:{tvdb_id}")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /series/lookup вернул {r.status_code}")
        found = r.json() or []
        if len(found) != 1:
            raise UpstreamUnavailable(
                f"lookup по tvdb:{tvdb_id} вернул кандидатов: {len(found)}, а нужен один"
            )
        title = found[0].get("title")
        if not title:
            raise UpstreamUnavailable(f"Sonarr не знает сериала с tvdbId={tvdb_id}")
        return str(title)

    def _build_add_payload(
        self,
        tvdb_id: int,
        title: str,
        profile_id: int,
        root: str,
        tags: list[int] | None = None,
    ) -> dict:
        """Тело запроса POST /api/v3/series.

        Имена полей сверены со схемой `SeriesResource` и `AddSeriesOptions` в
        `openapi/sonarr-v3-v4.0.19.2979.json`. Сверка автоматическая:
        tests/test_payloads.py проверяет каждый ключ против той же схемы.

        Два поля здесь важнее прочих, и у обоих вредное умолчание:

        `monitorNewItems="none"` — по умолчанию `"all"`. Без него заказ одного
        сезона превращается в подписку на сериал. Глобальной настройки для
        поля не существует, задаётся только на сериал.

        `seasonFolder=True` — по умолчанию `false`, а `docs/NAMING.md` требует
        папки сезонов.

        **Массив `seasons` здесь НЕ передаётся.** Проверено опытом на Sonarr
        4.0.19.2979: `addOptions.monitor` затирает флаги после добавления,
        причём ответ POST этого не показывает — возвращает `monitored: true`,
        тогда как в базе лежит `false`. Мониторинг нужного сезона включается
        вторым шагом. Подробности с таблицами — `docs/SPEC.md` 2.5.
        """
        payload: dict = {
            "tvdbId": tvdb_id,
            # title обязателен, хотя схема помечает его nullable: без него
            # Sonarr падает с 500 при построении пути папки.
            "title": title,
            "qualityProfileId": profile_id,
            "rootFolderPath": root,
            "monitored": True,
            "seasonFolder": True,
            "monitorNewItems": "none",
            "addOptions": {
                "monitor": "none",
                "searchForMissingEpisodes": False,
                "searchForCutoffUnmetEpisodes": False,
            },
        }
        if tags:
            payload["tags"] = tags
        return payload

    async def add_series(self, tvdb_id: int) -> dict:
        """Добавляет сериал БЕЗ мониторинга сезонов."""
        profile = await self.profile_id(self._s.sonarr_profile)
        # В dev — выбрасываемый тестовый каталог, а не настоящая библиотека.
        root = await self.root_folder(self._s.sonarr_root_effective)

        title = await self.lookup_title(tvdb_id)
        tags = [await self.tag_id(self._s.test_tag)] if self._s.is_dev else None
        payload = self._build_add_payload(tvdb_id, title, profile, root, tags)
        r = await self._request("POST", "/series", json=payload)
        if r.status_code >= 400:
            raise UpstreamUnavailable(
                f"Sonarr отказал при добавлении: {r.status_code} {r.text[:300]}"
            )
        return r.json()

    def _build_seasonpass_payload(self, series: dict, season: int) -> dict:
        """Тело запроса POST /api/v3/seasonpass.

        Форма сверена со схемами `SeasonPassResource` и
        `SeasonPassSeriesResource`.

        **`monitoringOptions` не передаётся.** Это пресет, и он затирает явный
        массив `seasons`. Проверено на живом Sonarr, сериал с шестью сезонами,
        просили один:

            monitoringOptions {"monitor": "none"}  -> отслеживается 0 сезонов
            monitoringOptions {"monitor": "skip"}  -> отслеживается 0 сезонов
            объект не передан                      -> отслеживается ровно 1

        Передаются ВСЕ сезоны, а не только целевой: непереданные сохранили бы
        прежние флаги, и «ровно один» не получилось бы при заказе второго
        сезона того же сериала.

        Проверяется checks/06-bridge-season.sh: отслеживаемых сезонов обязано
        быть ровно один, и это заказанный.
        """
        numbers = [s["seasonNumber"] for s in series.get("seasons", [])]
        if season not in numbers:
            raise SeasonOutOfRange(
                f"у сериала нет сезона {season}; есть: {', '.join(str(n) for n in sorted(numbers))}"
            )
        return {
            "series": [
                {
                    "id": int(series["id"]),
                    "monitored": True,
                    "seasons": [{"seasonNumber": n, "monitored": n == season} for n in numbers],
                }
            ]
        }

    async def _series_state(self, series_id: int) -> tuple[dict, str]:
        """Сериал и отпечаток его изменчивой части."""
        r = await self._request("GET", f"/series/{series_id}")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /series/{series_id} вернул {r.status_code}")
        data = r.json()
        seasons = [(s.get("seasonNumber"), s.get("monitored")) for s in data.get("seasons", [])]
        stats = (data.get("statistics") or {}).get("episodeCount")
        return data, repr((seasons, stats))

    async def wait_until_settled(self, series_id: int, timeout: float = 30.0) -> dict:
        """Ждёт, пока Sonarr перестанет менять состояние сериала.

        Добавление сериала запускает у Sonarr фоновую обработку: он
        перестраивает список сезонов и СБРАСЫВАЕТ флаги мониторинга. Отправить
        seasonpass, не дождавшись её, значит отдать результат на затирание.

        Так и было: между POST /series и POST /seasonpass проходило 18 мс, оба
        отвечали успехом (201 и 202), а в базе оставалось НОЛЬ отслеживаемых
        сезонов. Ни одного признака ошибки — ни в ответах, ни в логах.

        Дожидаться конкретной команды не выходит: RefreshSeries не появляется
        в /api/v3/command по seriesId, а statistics.episodeCount скачет.
        Поэтому признак — не событие, а ТИШИНА: состояние прочитано дважды
        подряд и совпало.

        Ожидание живёт внутри одного запроса и не делает bridge состоянием:
        ни очереди, ни фонового опроса, ни повторной доставки. Это доведение
        до конца работы, которую запрос уже начал.
        """
        deadline = time.monotonic() + timeout
        _, previous = await self._series_state(series_id)
        while time.monotonic() < deadline:
            await asyncio.sleep(1.0)
            data, current = await self._series_state(series_id)
            if current == previous:
                return data
            previous = current
        raise UpstreamUnavailable(
            "Sonarr не закончил обработку сериала за отведённое время — попробуй ещё раз"
        )

    async def set_season_monitored(self, series: dict, season: int) -> None:
        series_id = int(series["id"])

        # Дождаться тишины и взять СВЕЖИЙ объект: переданный — это ответ на
        # запись, а его список сезонов после фоновой обработки устаревает.
        series = await self.wait_until_settled(series_id)

        payload = self._build_seasonpass_payload(series, season)
        r = await self._request("POST", "/seasonpass", json=payload)
        if r.status_code >= 400:
            raise UpstreamUnavailable(
                f"Sonarr отказал при настройке сезона: {r.status_code} {r.text[:300]}"
            )

        # seasonpass отвечает 202 Accepted — «принято», а не «применено».
        # Поэтому результат читается отдельным GET, а не берётся из ответа на
        # запись. Молчаливое расхождение здесь уже случалось: см. SPEC.md 2.5,
        # где POST /series возвращал monitored=true при false в базе.
        await self._verify_season_monitored(series_id, season)

    async def _verify_season_monitored(self, series_id: int, season: int) -> None:
        r = await self._request("GET", f"/series/{series_id}")
        if r.status_code >= 400:
            raise UpstreamUnavailable(f"Sonarr /series/{series_id} вернул {r.status_code}")
        monitored = [s["seasonNumber"] for s in r.json().get("seasons", []) if s.get("monitored")]
        if monitored != [season]:
            raise UpstreamUnavailable(
                f"Sonarr не применил мониторинг сезона {season}: "
                f"сейчас отслеживаются {monitored or 'ни одного'}. Попробуй ещё раз"
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
