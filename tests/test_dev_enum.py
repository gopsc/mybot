"""Tests for the Dev_enum Python driver."""
from __future__ import annotations

from pathlib import Path
import sys

import pytest

from pymybot.robot import Robot

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "skills" / "hardware-controller" / "assets"
MODULES = ASSETS / "modules"


def _make_robot(tmp_path, sql):
    return Robot(sql, module_paths=[MODULES])


# ---- lifecycle ------------------------------------------------------------ #

def test_dev_enum_build_and_call(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        assert robot.registry["enum0"].kind == "python"
        result = robot.registry["enum0"].play({})
        assert result["result"] == "OK"
        assert result["platform"] in ("linux", "macos", "windows")
        assert set(result["buses"]) == {"i2c", "spi", "uart"}


def test_dev_enum_returns_all_three_bus_sections(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({})
        assert "i2c" in result
        assert "spi" in result
        assert "uart" in result


# ---- bus filtering -------------------------------------------------------- #

def test_dev_enum_filter_single_bus(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "i2c"})
        assert result["buses"] == ["i2c"]
        assert "i2c" in result
        assert "spi" not in result
        assert "uart" not in result


def test_dev_enum_filter_multiple_buses(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "i2c,uart"})
        assert set(result["buses"]) == {"i2c", "uart"}
        assert "i2c" in result
        assert "uart" in result
        assert "spi" not in result


def test_dev_enum_all_keyword(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "all"})
        assert set(result["buses"]) == {"i2c", "spi", "uart"}


def test_dev_enum_invalid_bus_tokens_filtered(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "i2c,camera,uart"})
        assert set(result["buses"]) == {"i2c", "uart"}


# ---- I2C section ---------------------------------------------------------- #

@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="Linux-only")
def test_dev_enum_i2c_section_on_linux(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "i2c"})
        i2c = result["i2c"]
        assert i2c["supported"] is True
        assert isinstance(i2c["adapters"], list)
        assert isinstance(i2c["clients"], list)


@pytest.mark.skipif(sys.platform.startswith("linux"), reason="non-Linux")
def test_dev_enum_i2c_section_non_linux(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "i2c"})
        i2c = result["i2c"]
        assert i2c["supported"] is False
        assert len(i2c["notes"]) > 0


# ---- SPI section ---------------------------------------------------------- #

@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="Linux-only")
def test_dev_enum_spi_section_on_linux(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "spi"})
        spi = result["spi"]
        assert spi["supported"] is True
        assert isinstance(spi["controllers"], list)
        assert isinstance(spi["devices"], list)


# ---- UART section --------------------------------------------------------- #

def test_dev_enum_uart_section(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["enum0"].play({"buses": "uart"})
        uart = result["uart"]
        assert uart["supported"] is True
        assert isinstance(uart["ports"], list)
        assert uart["backend"] in ("pyserial", "os")


# ---- end-to-end via MT --------------------------------------------------- #

def test_dev_enum_via_mt_action(tmp_path):
    sql = """
CREATE TABLE Dev_enum (name String);
INSERT INTO Dev_enum (name) VALUES ('enum0');
"""
    mt = "@Action\nenum0.go;\n   1  ;\n@\n"
    with _make_robot(tmp_path, sql) as robot:
        results = robot.run(mt)
        assert len(results) >= 1
        last = results[-1]
        assert last["result"] == "OK"
        assert "platform" in last
        assert "buses" in last


# ---- unit: bus parser ----------------------------------------------------- #

def test_parse_buses():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "Dev_enum", MODULES / "Dev_enum.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    parse = mod._parse_buses

    assert parse(None) == ("i2c", "spi", "uart")
    assert parse("all") == ("i2c", "spi", "uart")
    assert parse("i2c") == ("i2c",)
    assert parse("spi,uart") == ("spi", "uart")
    assert parse("i2c,spi,uart") == ("i2c", "spi", "uart")
    assert parse("camera") == ()
    assert parse("i2c,camera,uart") == ("i2c", "uart")
    assert parse(42) == ("i2c", "spi", "uart")
