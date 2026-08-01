"""bridge — мост Lampa -> Radarr/Sonarr.

БЕЗ СОСТОЯНИЯ. Ни базы, ни очереди, ни повторов, ни фонового опроса статусов.
Принял -> транслировал -> переслал -> ответил. Не получилось — вернул ошибку,
человек нажмёт ещё раз.

Обоснование: надёжная доставка уже реализована в Radarr и Sonarr.
Дублирование превращает мост во второй Radarr, который придётся поддерживать.
"""

import json
import logging
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response

from .config import settings
from .errors import BridgeError, SeasonOutOfRange
from .models import OrderRequest, OrderResponse
from .radarr import Radarr
from .sonarr import Sonarr
from .tmdb import Tmdb

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("bridge")

STATIC = Path(__file__).parent.parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    s = settings()
    log.info(
        "bridge стартует, BRIDGE_ENV=%s, поиск %s",
        s.bridge_env,
        "включён" if s.search_enabled else "ВЫКЛЮЧЕН",
    )
    async with httpx.AsyncClient() as client:
        app.state.http = client
        yield


app = FastAPI(title="bridge", lifespan=lifespan)

# CORS нужен ВСЕГДА, а не только в dev.
#
# Прежде здесь стояло `if settings().is_dev` с обоснованием «плагин отдаётся с
# того же origin, что и API». Обоснование неверно: CORS определяется origin
# СТРАНИЦЫ, а не origin скрипта. Плагин исполняется внутри страницы Lampa
# (Lampac на :9118), и его запрос к bridge (:8000) — кросс-доменный, сколько
# бы файл плагина ни отдавался с bridge. В production заголовка не получал
# никто, и каждый заказ падал бы с «bridge недоступен».
#
# Список явный, из CORS_ORIGINS. НИКОГДА "*" — запрещённая подмена.
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings().cors_origin_list,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    """Каждый входящий запрос пишется целиком.

    Это основной инструмент отладки плагина: тыкаешь в интерфейсе Lampa,
    смотришь логи bridge, видишь, что реально пришло. Быстрее любых тестов
    на JS — тем более что API плагинов Lampa не документирован формально,
    а идентификаторы в карточке разрешаются асинхронно.
    """
    body = b""
    if request.method == "POST":
        body = await request.body()

    # Origin логируется намеренно: приложение Lampa на телефоне может слать
    # что угодно, вплоть до "null" (упакованный вебвью с file://), а список
    # разрешённых origin задаётся вручную. Без этой строки выяснять, что
    # именно пришло, пришлось бы вслепую.
    origin = request.headers.get("origin", "-")
    log.info(
        "-> %s %s origin=%s body=%s",
        request.method,
        request.url.path,
        origin,
        body.decode() or "-",
    )
    response = await call_next(request)
    log.info("<- %s %s", request.url.path, response.status_code)
    return response


@app.exception_handler(BridgeError)
async def bridge_error_handler(_: Request, exc: BridgeError) -> JSONResponse:
    log.warning("BridgeError %s: %s", exc.status_code, exc.message)
    return JSONResponse(
        status_code=exc.status_code,
        content=OrderResponse(status="error", detail=exc.message).model_dump(),
    )


@app.get("/health")
async def health() -> Response:
    return Response(status_code=200)


@app.get("/plugin.js")
async def plugin_js() -> Response:
    """Отдаёт плагин с того же origin, что и API — этим CORS и снимается.

    Cache-Control: no-store в dev, потому что Lampa кеширует файлы плагинов,
    и без этого при разработке будет исполняться старая версия. Типовая
    потеря времени.
    """
    path = STATIC / "plugin.js"
    if not path.exists():
        return Response(status_code=404)
    headers = {"Cache-Control": "no-store"} if settings().is_dev else {}
    return Response(
        content=path.read_text(encoding="utf-8"),
        media_type="application/javascript",
        headers=headers,
    )


@app.post("/order", response_model=OrderResponse)
async def order(req: OrderRequest, request: Request) -> OrderResponse:
    client: httpx.AsyncClient = request.app.state.http
    s = settings()
    tmdb = Tmdb(client)

    if req.type == "movie":
        return await _order_movie(client, tmdb, req.tmdb_id, s.search_enabled)

    assert req.season is not None  # обеспечено валидатором модели
    return await _order_season(client, tmdb, req.tmdb_id, req.season)


async def _order_movie(
    client: httpx.AsyncClient, tmdb: Tmdb, tmdb_id: int, search: bool
) -> OrderResponse:
    radarr = Radarr(client)

    existing = await radarr.find_by_tmdb(tmdb_id)
    if existing:
        # «Уже в библиотеке» — это УСПЕХ, не отказ. Код ответа 200.
        return OrderResponse(
            status="exists", title=existing.get("title"), detail="уже в библиотеке"
        )

    title = await tmdb.movie_title(tmdb_id)
    await radarr.add_movie(tmdb_id, search=search)
    detail = None if search else "добавлено без поиска (dev-режим)"
    return OrderResponse(status="queued", title=title, detail=detail)


async def _order_season(
    client: httpx.AsyncClient, tmdb: Tmdb, tmdb_id: int, season: int
) -> OrderResponse:
    sonarr = Sonarr(client)

    # Валидация сезона до обращения к Sonarr: дешевле и сообщение понятнее.
    numbers = await tmdb.tv_season_numbers(tmdb_id)
    if numbers and season not in numbers:
        raise SeasonOutOfRange(
            f"у сериала нет сезона {season}; есть: " f"{', '.join(str(n) for n in sorted(numbers))}"
        )

    # Обязательный шаг: Sonarr не принимает tmdbId.
    tvdb_id = await tmdb.tvdb_id(tmdb_id)
    title = await tmdb.tv_title(tmdb_id)

    series = await sonarr.find_by_tvdb(tvdb_id)
    created = False
    if series is None:
        series = await sonarr.add_series(tvdb_id)
        created = True

    # Ровно один сезон под мониторингом. Проверяется checks/06.
    await sonarr.set_season_monitored(series, season)
    await sonarr.search_season(int(series["id"]), season)

    if not created:
        return OrderResponse(
            status="exists", title=title, detail=f"сериал уже был, сезон {season} добавлен"
        )
    detail = None if settings().search_enabled else "добавлено без поиска (dev-режим)"
    return OrderResponse(status="queued", title=title, detail=detail)


# Явная сериализация для логов: помогает при отладке плагина
def _dump(obj: object) -> str:
    return json.dumps(obj, ensure_ascii=False, default=str)
