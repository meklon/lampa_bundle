"""Конфигурация. Только из окружения, ни одного значения в коде."""

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore")

    # dev — поиск НИКОГДА не запускается, plugin.js отдаётся с no-store.
    # Это защита от того, что отладочный цикл наделает десятки настоящих
    # загрузок: addOptions.searchForMovie=true вызывает реальный поиск.
    bridge_env: Literal["dev", "prod"] = "dev"

    radarr_url: str
    radarr_api_key: str
    radarr_root: str
    radarr_profile: str
    # announced | inCinemas | released | preDB
    # released — рекомендуемое. preDB сейчас идентичен released
    # (predb.me блокирует Radarr), смысла в нём нет.
    # Слишком строгое значение => фильм добавлен, но поиск не стартует,
    # и ошибки при этом нет.
    radarr_min_availability: str = "released"

    sonarr_url: str
    sonarr_api_key: str
    sonarr_root: str
    sonarr_profile: str

    # Тестовые root folder. CLAUDE.md: «Тестовые заказы идут в отдельный root
    # folder и помечаются тегом из TEST_TAG». В dev-режиме заказы обязаны
    # попадать сюда, а не в настоящую библиотеку — иначе отладочный цикл
    # засоряет её, и разбирать потом руками.
    # Это же проверяет checks/05-bridge-movie.sh: он сверяет rootFolderPath
    # фильма именно с TEST_RADARR_ROOT.
    test_radarr_root: str = "/data/media/_test_movies"
    test_sonarr_root: str = "/data/media/_test_tv"

    tmdb_token: str
    tmdb_base: str = "https://api.themoviedb.org/3"

    test_tag: str = "test"

    # Разрешённые origin для CORS. Никогда "*" — это запрещённая подмена.
    #
    # Нужен и в production, вопреки прежней записи в SPEC.md 2.8. Там
    # утверждалось: «плагин отдаётся с того же origin, что и API, поэтому CORS
    # не нужен». Это неверно. CORS определяется origin СТРАНИЦЫ, а не origin
    # скрипта: плагин исполняется внутри страницы Lampa (Lampac на :9118), и
    # его запрос к bridge (:8000) — кросс-доменный. Без заголовка браузер
    # заблокирует ответ, а пользователь увидит «bridge недоступен».
    #
    # Задаётся строкой через запятую в CORS_ORIGINS.
    cors_origins: str = "http://localhost:3000"

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def is_dev(self) -> bool:
        return self.bridge_env == "dev"

    @property
    def search_enabled(self) -> bool:
        """В dev-режиме поиск не запускается ни при каких входных данных."""
        return not self.is_dev

    @property
    def radarr_root_effective(self) -> str:
        """Куда реально добавлять фильм: в dev — в выбрасываемый каталог."""
        return self.test_radarr_root if self.is_dev else self.radarr_root

    @property
    def sonarr_root_effective(self) -> str:
        return self.test_sonarr_root if self.is_dev else self.sonarr_root


@lru_cache
def settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
