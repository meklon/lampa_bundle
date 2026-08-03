"""Логика plugin.js — через node-стенд, из-под одного тестового прогона.

Разделение честное: стенд проверяет РАЗБОР КАРТОЧКИ и ТЕЛО ЗАПРОСА, то есть
то, что можно проверить без Lampa. Что кнопка видна в интерфейсе, доступна
пультом и список сезонов выглядит как надо — проверяется руками,
docs/ACCEPTANCE.md, этап 6.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

HARNESS = Path(__file__).parent / "plugin_harness.js"
PLUGIN = Path(__file__).resolve().parents[1] / "static" / "plugin.js"


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_syntax_valid():
    # check=False явно: код возврата разбирается ниже, исключение помешало бы
    # показать stderr в сообщении об ошибке.
    r = subprocess.run(
        ["node", "--check", str(PLUGIN)], capture_output=True, text=True, check=False
    )
    assert r.returncode == 0, r.stderr


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_harness():
    r = subprocess.run(["node", str(HARNESS)], capture_output=True, text=True, check=False)
    assert r.returncode == 0, r.stdout + r.stderr


def test_plugin_has_no_arr_addresses():
    """В плагине нет ни ключей, ни адресов *arr — только адрес bridge,
    и тот выводится из адреса самого файла.

    Тот же grep делает приёмка этапа 6. Здесь он дешевле.
    """
    text = PLUGIN.read_text(encoding="utf-8")
    for forbidden in ("X-Api-Key", "api_key", "Bearer", ":7878", ":8989", ":9696"):
        assert forbidden not in text, f"в plugin.js есть «{forbidden}»"


def test_plugin_reacts_only_to_complite():
    """Идентификаторы разрешаются асинхронно: на 'build' читать карточку рано.

    Проверяется текстом, потому что это инвариант, который легко потерять при
    правке, а стенд поймает его только косвенно.
    """
    text = PLUGIN.read_text(encoding="utf-8")
    assert "'complite'" in text
    assert "e.type !== 'complite'" in text


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_requests_status_for_card():
    """Плагин обязан спросить состояние по tmdb_id и типу карточки."""
    r = subprocess.run(
        ["node", str(HARNESS), "status-request"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert r.returncode == 0, r.stderr
    assert "/status?tmdb_id=1083381&type=movie" in r.stdout


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_shows_label_instead_of_order():
    """can_order=false → на кнопке состояние, а не «Заказать»."""
    r = subprocess.run(
        ["node", str(HARNESS), "status-label"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert r.returncode == 0, r.stderr
    assert "Закачивается 44%" in r.stdout
    assert "Заказать" not in r.stdout


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_series_can_refresh_status():
    """У сериала «Обновить» обязано быть достижимо.

    can_order у сериала всегда true (другой сезон заказать можно в любой
    момент), поэтому экран подробностей, где живёт «Обновить», для ТВ-карточки
    не открывается никогда, а повторный вход в карточку состояние не
    перезапрашивает. Без пункта в списке сезонов обещанное спецификацией
    ручное обновление у сериала не работает вовсе.

    Проверяется и то, что обновление не превратилось в заказ: orders=0.
    """
    r = subprocess.run(
        ["node", str(HARNESS), "series-refresh"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert r.returncode == 0, r.stderr
    assert "refresh-items=1" in r.stdout, r.stdout
    assert "season-items=6" in r.stdout, r.stdout
    assert "status-requests=2" in r.stdout, r.stdout
    assert "orders=0" in r.stdout, r.stdout
    assert "button=Сезон 2: закачивается 44%" in r.stdout, r.stdout
    # Свежее состояние доехало и до подписей сезонов, а не только до кнопки.
    assert "season-2-label=Сезон 2 — закачивается 44%" in r.stdout, r.stdout


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_reopen_card_keeps_single_button_and_status_request():
    """'complite' приходит и при возврате в карточку — кнопка и запрос
    состояния не должны задвоиться (см. ранний return в addButton)."""
    r = subprocess.run(
        ["node", str(HARNESS), "reopen-card"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert r.returncode == 0, r.stderr
    assert "buttons=1" in r.stdout
    assert "status-requests=1" in r.stdout
