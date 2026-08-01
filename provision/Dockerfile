# Образ провижининга и подготовки.
#
# Существует ради дистрибуции: без него стек монтирует ВЕСЬ репозиторий
# (`.:/repo:ro`) и ставит bash, curl и jq при каждом старте — то есть требует
# и git на сервере, и сеть при каждом `up`.
#
# С ним человеку нужны два файла: docker-compose.yml и .env.
FROM alpine:3.20

# jq нужен провижинингу для разбора ответов API, curl — для самих запросов,
# python3 — для init.py (PBKDF2 для пароля qBittorrent).
RUN apk add --no-cache bash curl jq python3

WORKDIR /app

COPY provision/ /app/provision/
COPY scripts/init.py /app/scripts/init.py

# NAMING.md едет внутрь как источник УМОЛЧАНИЙ схемы имён. Переопределяется
# переменными окружения, см. naming_env_var в provision/lib.sh.
#
# Копия строк в скриптах не заводится намеренно: два места разъедутся.
COPY docs/NAMING.md /app/docs/NAMING.md

# Скрипты вычисляют корень относительно себя и подключают $ROOT/.env.
# В образе .env нет: значения приходят переменными окружения от compose.
# Пустой файл, чтобы `. "$ROOT/.env"` не падал.
RUN touch /app/.env && chmod +x /app/provision/*.sh

CMD ["bash", "/app/provision/provision.sh"]
