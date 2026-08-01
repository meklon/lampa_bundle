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

    tmdb_token: str
    tmdb_base: str = "https://api.themoviedb.org/3"

    test_tag: str = "test"

    # Дополнительные разрешённые origin, через запятую. Обычно НЕ НУЖНЫ:
    # основной случай вычисляется сам, см. cors_allowed() в main.py.
    #
    # CORS нужен и в production, вопреки прежней записи в SPEC.md 2.8. Там
    # утверждалось: «плагин отдаётся с того же origin, что и API, поэтому CORS
    # не нужен». Это неверно. CORS определяется origin СТРАНИЦЫ, а не origin
    # скрипта: плагин исполняется внутри страницы Lampa (Lampac на :9118), и
    # его запрос к bridge (:8000) — кросс-доменный. Без заголовка браузер
    # даже не отправит POST: тело идёт как application/json, а такой запрос
    # предваряется preflight'ом.
    #
    # Заполнять, только если автоправила не хватает: Lampac на другой машине,
    # доступ по имени хоста к одному и по IP к другому, обратный прокси со
    # своим доменом, или приложение шлёт origin "null".
    cors_origins: str = ""

    @property
    def cors_origin_list(self) -> list[str]:
        values = [o.strip() for o in self.cors_origins.split(",") if o.strip()]
        # «*» пускает любую страницу интернета делать заказы на этом bridge.
        # Запрещено таблицей подмен в CLAUDE.md, и проверяется здесь, а не
        # в тесте: с неверной конфигурацией сервис не должен подниматься.
        if "*" in values:
            raise ValueError(
                'CORS_ORIGINS не может содержать "*": это разрешило бы заказы '
                "с любой страницы. Перечисли адреса явно либо оставь пусто — "
                "тогда действует правило «тот же хост, любой порт»."
            )
        return values

    @property
    def is_dev(self) -> bool:
        return self.bridge_env == "dev"

    @property
    def search_enabled(self) -> bool:
        """В dev-режиме поиск не запускается ни при каких входных данных."""
        return not self.is_dev


@lru_cache
def settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
