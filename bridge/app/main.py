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
from typing import Literal
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

from .config import settings
from .errors import BridgeError, SeasonOutOfRange
from .models import OrderRequest, OrderResponse, Profile
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


def _host_of(value: str) -> str:
    """Хост без порта. Понимает IPv6 в скобках: [::1]:8000."""
    value = value.strip()
    if value.startswith("["):
        end = value.find("]")
        return value[: end + 1] if end != -1 else value
    return value.rsplit(":", 1)[0] if ":" in value else value


def cors_allowed(origin: str, host_header: str) -> bool:
    """Можно ли этой странице делать запросы к bridge.

    Два правила.

    1. Явный список из CORS_ORIGINS — для случаев, которые автоматикой не
       покрыть: Lampac на другой машине, обратный прокси со своим доменом,
       упакованный вебвью с origin "null".

    2. Тот же хост, любой порт — вычисляется само. Обычная установка: страницу
       Lampa отдаёт Lampac с того же адреса, что и bridge, только порт другой.

    Почему второе правило безопасно: чтобы под него попасть, страница должна
    отдаваться ТОЙ ЖЕ машиной, что и bridge. Чужой сайт из интернета под него
    не подпадает — origin проставляет браузер, подделать его страница не может.
    Это принципиально не то же, что "*", который пускает вообще всех.

    Почему нельзя вычислить адрес заранее: bridge живёт в контейнере и знает
    только свой адрес в сети compose (172.18.x.x). По какому адресу человек
    откроет Lampa — IP, имя хоста, localhost, домен за прокси — известно лишь
    из заголовка Host конкретного запроса.
    """
    if not origin:
        return False
    if origin in settings().cors_origin_list:
        return True
    if not host_header:
        return False

    parsed = urlsplit(origin)
    if not parsed.hostname:
        # origin вроде "null" — хоста нет, сравнивать не с чем. Разрешается
        # только явным перечислением выше.
        return False
    return parsed.hostname == _host_of(host_header).strip("[]")


@app.middleware("http")
async def cors(request: Request, call_next):
    """CORS своими руками: штатный middleware не умеет решать по запросу.

    Ему нужен статический список origin, а наше правило зависит от заголовка
    Host — то есть от того, по какому адресу обратились именно сейчас.

    Заголовок отдаётся с КОНКРЕТНЫМ origin, никогда со "*".
    """
    origin = request.headers.get("origin", "")
    allowed = cors_allowed(origin, request.headers.get("host", ""))

    if request.method == "OPTIONS" and request.headers.get("access-control-request-method"):
        # Preflight. Без разрешения браузер не отправит настоящий запрос —
        # именно этим CORS и защищает: чужая страница не сможет сделать заказ.
        response = Response(status_code=200 if allowed else 403)
    else:
        response = await call_next(request)

    if allowed:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type"
        response.headers["Access-Control-Max-Age"] = "600"
    # Ответ зависит от origin, поэтому кеши обязаны это учитывать.
    response.headers["Vary"] = "Origin"
    return response


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


@app.get("/profiles", response_model=list[Profile])
async def profiles(type: Literal["movie", "tv"], request: Request) -> list[Profile]:
    """Профили качества для выбора в плагине.

    Список берётся у самих Radarr и Sonarr, а не задаётся в коде: профили
    заводит и переименовывает человек, и захардкоженный перечень разъехался бы
    с действительностью молча.

    Разрешение здесь не параметр загрузки: в *arr оно часть профиля, который
    заодно определяет, до чего файл потом апгрейдится.
    """
    client: httpx.AsyncClient = request.app.state.http
    s = settings()
    if type == "movie":
        names = await Radarr(client).profiles()
        default = s.radarr_profile
    else:
        names = await Sonarr(client).profiles()
        default = s.sonarr_profile
    return [Profile(name=n, default=(n == default)) for n in names]


@app.post("/order", response_model=OrderResponse)
async def order(req: OrderRequest, request: Request) -> OrderResponse:
    client: httpx.AsyncClient = request.app.state.http
    s = settings()
    tmdb = Tmdb(client)

    if req.type == "movie":
        return await _order_movie(client, tmdb, req.tmdb_id, s.search_enabled, req.profile)

    assert req.season is not None  # обеспечено валидатором модели
    return await _order_season(client, tmdb, req.tmdb_id, req.season, req.profile)


async def _order_movie(
    client: httpx.AsyncClient,
    tmdb: Tmdb,
    tmdb_id: int,
    search: bool,
    profile: str | None = None,
) -> OrderResponse:
    radarr = Radarr(client)

    # Профиль проверяется ДО обращения к библиотеке: если запрошен
    # несуществующий, честнее сказать об этом сразу, чем после добавления.
    profile_name = await radarr.resolve_profile(profile)

    existing = await radarr.find_by_tmdb(tmdb_id)
    if existing:
        # «Уже в библиотеке» — это УСПЕХ, не отказ. Код ответа 200.
        return OrderResponse(
            status="exists", title=existing.get("title"), detail="уже в библиотеке"
        )

    title = await tmdb.movie_title(tmdb_id)
    await radarr.add_movie(tmdb_id, search=search, profile_name=profile_name)
    detail = f"качество: {profile_name}"
    if not search:
        detail += ", без поиска (dev-режим)"
    return OrderResponse(status="queued", title=title, detail=detail)


async def _order_season(
    client: httpx.AsyncClient,
    tmdb: Tmdb,
    tmdb_id: int,
    season: int,
    profile: str | None = None,
) -> OrderResponse:
    sonarr = Sonarr(client)

    profile_name = await sonarr.resolve_profile(profile)

    # Валидация сезона до обращения к Sonarr: дешевле и сообщение понятнее.
    numbers = await tmdb.tv_season_numbers(tmdb_id)
    if numbers and season not in numbers:
        raise SeasonOutOfRange(
            f"у сериала нет сезона {season}; есть: {', '.join(str(n) for n in sorted(numbers))}"
        )

    # Обязательный шаг: Sonarr не принимает tmdbId.
    tvdb_id = await tmdb.tvdb_id(tmdb_id)
    title = await tmdb.tv_title(tmdb_id)

    series = await sonarr.find_by_tvdb(tvdb_id)
    created = False
    if series is None:
        series = await sonarr.add_series(tvdb_id, profile_name=profile_name)
        created = True

    # Ровно один сезон под мониторингом. Проверяется checks/06.
    await sonarr.set_season_monitored(series, season)
    await sonarr.search_season(int(series["id"]), season)

    if not created:
        # Профиль у существующего сериала НЕ меняется: заказ второго сезона не
        # повод переписывать качество для уже скачанного.
        return OrderResponse(
            status="exists", title=title, detail=f"сериал уже был, сезон {season} добавлен"
        )
    detail = f"сезон {season}, качество: {profile_name}"
    if not settings().search_enabled:
        detail += ", без поиска (dev-режим)"
    return OrderResponse(status="queued", title=title, detail=detail)


# Явная сериализация для логов: помогает при отладке плагина
def _dump(obj: object) -> str:
    return json.dumps(obj, ensure_ascii=False, default=str)
