"""Подготовка перед стартом сервисов. Запускается сервисом init в compose.

Заменяет прежний bootstrap.sh: теперь установка — это ровно `docker compose up`.

Делает три вещи, и все три нельзя выразить одними переменными окружения:

  1. создаёт каталоги данных;
  2. ПРОВЕРЯЕТ, что жёсткая ссылка между торрентами и библиотекой реально
     создаётся, и валит развёртывание, если нет;
  3. кладёт пароль qBittorrent в его конфиг;
  4. пишет конфигурацию Lampac — без неё он вяжется на 127.0.0.1 внутри
     контейнера и снаружи недоступен, при этом выглядит здоровым.

Ключи API сюда не попали намеренно: *arr принимают их переменными
RADARR__AUTH__APIKEY и аналогами — проверено, работает даже без config.xml.

Идемпотентен: существующий конфиг qBittorrent не трогает.
"""

import base64
import hashlib
import os
import sys
from pathlib import Path

DATA = Path("/data")
QBT_CONF = Path("/qbt-config/qBittorrent/qBittorrent.conf")
LAMPAC_CONF = Path("/lampac-config/init.conf")


def fail(message: str) -> None:
    print(f"ОТКАЗ: {message}", file=sys.stderr)
    sys.exit(1)


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        fail(f"не задана переменная {name}")
    return value


def make_dirs() -> list[Path]:
    torrents = env("TORRENTS_PATH")
    paths = [
        DATA / torrents / "movies",
        DATA / torrents / "tv",
        DATA / env("MOVIES_PATH"),
        DATA / env("TV_PATH"),
    ]
    for p in paths:
        p.mkdir(parents=True, exist_ok=True)
        print(f"     {p}")
    return paths


def check_hardlink(torrents: Path, media: Path) -> None:
    """Проба настоящей ссылкой, а не сравнение номеров устройств.

    Сравнения `stat -c %d` НЕДОСТАТОЧНО: два bind-монтирования одного каталога
    дают одинаковый номер устройства, а link() между ними возвращает EXDEV —
    ядро сверяет точку монтирования, а не суперблок. Проверено опытом.

    Ошибиться здесь дорого: когда ссылка невозможна, *arr МОЛЧА копируют.
    Ошибки нет, место уходит вдвое, и узнаёшь об этом через месяц.
    """
    src = torrents / ".hlprobe"
    dst = media / ".hlprobe"
    for p in (src, dst):
        p.unlink(missing_ok=True)
    src.write_text("probe", encoding="utf-8")
    try:
        os.link(src, dst)
    except OSError as e:
        src.unlink(missing_ok=True)
        fail(
            f"жёсткая ссылка между {torrents} и {media} не создаётся: {e}.\n"
            "     Причина почти всегда одна: пути оказались на разных файловых\n"
            "     системах либо смонтированы раздельно. Оба должны лежать\n"
            "     внутри DATA_ROOT. См. docs/SPEC.md 1.6."
        )
    links = dst.stat().st_nlink
    same_inode = src.stat().st_ino == dst.stat().st_ino
    for p in (src, dst):
        p.unlink(missing_ok=True)
    if links < 2 or not same_inode:
        fail(
            f"ссылка создалась, но выглядит неправильно: ссылок={links}, инод совпал={same_inode}"
        )
    print(f"     жёсткая ссылка работает (ссылок={links}, инод общий)")


def seed_qbittorrent() -> None:
    """Пароль qBittorrent в его конфиг.

    Единственное, что нельзя задать переменной окружения: QBT_WEBUI_PASSWORD
    образом не поддерживается — проверено, вход после него даёт 401.

    qBittorrent хранит пароль как PBKDF2-HMAC-SHA512, 100 000 итераций,
    соль 16 байт, ключ 64 байта; соль и ключ в base64 через двоеточие.
    Параметры не угаданы: они восстановлены сверкой с хешем, который
    qBittorrent записал сам, и подтверждены входом с заранее посчитанным
    значением.
    """
    if QBT_CONF.exists() and "Password_PBKDF2" in QBT_CONF.read_text(encoding="utf-8"):
        print("     конфиг qBittorrent уже есть — не трогаю")
        return

    user = os.environ.get("QBITTORRENT_USER", "admin")
    password = env("QBITTORRENT_PASSWORD")

    salt = os.urandom(16)
    key = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100_000, dklen=64)
    value = base64.b64encode(salt).decode() + ":" + base64.b64encode(key).decode()

    QBT_CONF.parent.mkdir(parents=True, exist_ok=True)
    QBT_CONF.write_text(
        "[LegalNotice]\n"
        "Accepted=true\n"
        "\n"
        "[Preferences]\n"
        f"WebUI\\Username={user}\n"
        f'WebUI\\Password_PBKDF2="@ByteArray({value})"\n',
        encoding="utf-8",
    )
    print("     пароль qBittorrent записан")


def seed_lampac() -> None:
    """Конфигурация Lampac.

    Без неё берётся base.conf из образа, где у listen НЕ ЗАДАН ip: сервис
    вяжется на 127.0.0.1 внутри контейнера, проброс порта ведёт в никуда, а
    healthcheck образа (pgrep dotnet) при этом рапортует healthy.

    Пишется здесь, а не монтируется из репозитория: тогда для запуска нужен
    был бы сам репозиторий, а это ровно то, от чего уходим.
    """
    if LAMPAC_CONF.exists():
        print("     конфиг Lampac уже есть — не трогаю")
        return
    LAMPAC_CONF.parent.mkdir(parents=True, exist_ok=True)
    LAMPAC_CONF.write_text(
        "{\n"
        '  "listen": {\n'
        '    "ip": "0.0.0.0",\n'
        '    "port": 9118,\n'
        '    "scheme": "http"\n'
        "  },\n"
        '  "openstat": {\n'
        '    "enable": false\n'
        "  }\n"
        "}\n",
        encoding="utf-8",
    )
    print("     конфиг Lampac записан")


def fix_owner(paths: list[Path]) -> None:
    """Владелец каталогов должен совпадать с PUID/PGID сервисов.

    Расхождение проявляется как молчаливые ошибки импорта: qBittorrent пишет
    от одного uid, *arr не может тронуть файл.
    """
    uid, gid = int(env("PUID")), int(env("PGID"))
    for p in [*paths, QBT_CONF.parent, QBT_CONF, LAMPAC_CONF]:
        if p.exists():
            try:
                os.chown(p, uid, gid)
            except PermissionError:
                pass


def main() -> None:
    print("==>  каталоги данных")
    paths = make_dirs()

    print("==>  проба жёсткой ссылки")
    check_hardlink(DATA / env("TORRENTS_PATH"), DATA / env("MOVIES_PATH"))

    print("==>  пароль qBittorrent")
    seed_qbittorrent()

    print("==>  конфигурация Lampac")
    seed_lampac()

    fix_owner(paths)
    print("==>  готово")


if __name__ == "__main__":
    main()
