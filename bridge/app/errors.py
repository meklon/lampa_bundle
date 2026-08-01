"""Ошибки. Текст detail попадает прямо в интерфейс Lampa."""


class BridgeError(Exception):
    """Базовая. status_code уходит в HTTP-ответ, message — пользователю."""

    status_code: int = 500
    message: str = "внутренняя ошибка"

    def __init__(self, message: str | None = None) -> None:
        if message:
            self.message = message
        super().__init__(self.message)


class ValidationError(BridgeError):
    status_code = 400


class NoTvdbId(BridgeError):
    """У части регионального и малоизвестного контента tvdb_id в TMDB нет.

    Sonarr работает только по TVDB, добавление по tmdbId не поддерживается.
    Это НЕ 500: запрос корректен, просто такой сериал добавить нельзя.

    ЗАПРЕЩЕНО обходить поиском по названию через series/lookup?term= —
    нечёткое совпадение притащит не тот сериал. См. таблицу запрещённых
    подмен в CLAUDE.md.
    """

    status_code = 422
    message = "у этого сериала нет tvdb_id в TMDB — добавить в Sonarr нельзя"


class SeasonOutOfRange(BridgeError):
    status_code = 422
    message = "такого сезона у сериала нет"


class NotFoundInTmdb(BridgeError):
    status_code = 404
    message = "в TMDB такого идентификатора нет"


class UpstreamUnavailable(BridgeError):
    status_code = 502
    message = "сервис недоступен, попробуй позже"


class UpstreamAuth(BridgeError):
    status_code = 502
    message = "ошибка авторизации в сервисе — проверь API-ключ"


class ProfileNotFound(BridgeError):
    """Профиля из ОКРУЖЕНИЯ нет в *arr — это ошибка настройки, отсюда 500."""

    status_code = 500
    message = "профиль качества с таким именем не найден"


class ProfileNotAllowed(BridgeError):
    """Профиля из ЗАПРОСА нет в *arr.

    Это пользовательский ввод, а не поломка настройки: запрос корректен по
    форме, но просит несуществующее. Отсюда 422, а не 500 — иначе человек
    увидит «внутренняя ошибка» там, где достаточно выбрать другое.
    """

    status_code = 422
    message = "такого профиля качества нет"


class RootFolderNotFound(BridgeError):
    status_code = 500
    message = "корневой каталог не настроен"
