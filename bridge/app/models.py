"""Контракт /order. Полное описание — в docs/SPEC.md, раздел 2.3."""

from typing import Literal, Self

from pydantic import BaseModel, Field, model_validator


class OrderRequest(BaseModel):
    tmdb_id: int = Field(gt=0, description="Идентификатор TMDB из карточки Lampa")
    type: Literal["movie", "tv"]
    season: int | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def check_season(self) -> Self:
        if self.type == "tv" and self.season is None:
            raise ValueError("для type=tv требуется номер сезона")
        if self.type == "movie" and self.season is not None:
            raise ValueError("для type=movie сезон не указывается")
        return self


class OrderResponse(BaseModel):
    # queued — принято и отправлено
    # exists — уже в библиотеке; это УСПЕХ, код ответа 200
    # error  — не получилось
    status: Literal["queued", "exists", "error"]
    title: str | None = None
    # Показывается пользователю в интерфейсе Lampa КАК ЕСТЬ.
    # Человекочитаемо, по-русски.
    detail: str | None = None
