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
    r = subprocess.run(["node", "--check", str(PLUGIN)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен node")
def test_plugin_harness():
    r = subprocess.run(["node", str(HARNESS)], capture_output=True, text=True)
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
