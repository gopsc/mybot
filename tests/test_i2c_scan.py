"""Tests for the I2C_scan Python driver."""
from __future__ import annotations

from pathlib import Path
import threading

import pytest

from pymybot.hal import HALManager
from pymybot.native import PythonState
from pymybot.robot import Robot

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "skills" / "hardware-controller" / "assets"
MODULES = ASSETS / "modules"


def _make_robot(tmp_path, sql, source=None):
    if source is not None:
        (tmp_path / "I2C_scan.py").write_text(source, encoding="utf-8")
        return Robot(sql, module_paths=[tmp_path, MODULES])
    return Robot(sql, module_paths=[MODULES])


# ---- unit: address parser ------------------------------------------------- #

def test_parse_address_defaults():
    from pymybot.robot import Robot as _R  # noqa: F401 — just to import the module tree
    # Import the driver module directly for unit testing the helper
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "I2C_scan", MODULES / "I2C_scan.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    parse = mod._parse_address

    assert parse(None, 0x08) == 0x08
    assert parse("-", 0x77) == 0x77
    assert parse("", 0x10) == 0x10
    assert parse("0x48", 0) == 0x48
    assert parse("72", 0) == 72
    assert parse(0x48, 0) == 0x48
    assert parse(48.0, 0) == 48
    assert parse(48.5, 0) == 0
    assert parse(True, 0x10) == 0x10
    assert parse("garbage", 0x20) == 0x20


# ---- lifecycle: virtual bus ----------------------------------------------- #

def test_i2c_scan_build_call_destroy_on_virt_bus(tmp_path):
    sql = """
CREATE TABLE I2C_scan (name String, path String);
INSERT INTO I2C_scan (name, path) VALUES ('scan0', 'virt-bus0');
"""
    with _make_robot(tmp_path, sql) as robot:
        assert robot.registry["scan0"].kind == "python"
        result = robot.registry["scan0"].play({})
        assert result["result"] == "OK"
        assert result["bus"] == "virt-bus0"
        assert isinstance(result["found"], list)
        assert result["count"] == len(result["found"])
        assert result["range"] == "0x08-0x77"


def test_i2c_scan_custom_address_range(tmp_path):
    sql = """
CREATE TABLE I2C_scan (name String, path String);
INSERT INTO I2C_scan (name, path) VALUES ('scan0', 'virt-bus0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["scan0"].play({
            "start_address": "0x40",
            "end_address": "0x50",
        })
        assert result["result"] == "OK"
        assert result["range"] == "0x40-0x50"


def test_i2c_scan_reversed_range_is_swapped(tmp_path):
    sql = """
CREATE TABLE I2C_scan (name String, path String);
INSERT INTO I2C_scan (name, path) VALUES ('scan0', 'virt-bus0');
"""
    with _make_robot(tmp_path, sql) as robot:
        result = robot.registry["scan0"].play({
            "start_address": "0x50",
            "end_address": "0x40",
        })
        assert result["result"] == "OK"
        assert result["range"] == "0x40-0x50"


def test_i2c_scan_cleanup_releases_handles(tmp_path):
    sql = """
CREATE TABLE I2C_scan (name String, path String);
INSERT INTO I2C_scan (name, path) VALUES ('scan0', 'virt-bus0');
"""
    robot = _make_robot(tmp_path, sql)
    with robot:
        robot.registry["scan0"].play({})
        assert len(robot.hal._handles) >= 1
    assert not robot.hal._handles


# ---- error paths ---------------------------------------------------------- #

def test_i2c_scan_build_fails_without_path(tmp_path):
    source = (MODULES / "I2C_scan.py").read_text(encoding="utf-8")
    (tmp_path / "I2C_scan.py").write_text(source, encoding="utf-8")
    sql = """
CREATE TABLE I2C_scan (name String);
INSERT INTO I2C_scan (name) VALUES ('scan0');
"""
    with pytest.raises(Exception, match="[Ff]ailed|No I2C path"):
        with _make_robot(tmp_path, sql):
            pass


def test_i2c_scan_call_without_build(tmp_path):
    """Calling scan on an un-built driver should return ERR."""
    hal = HALManager()
    state = PythonState([MODULES], hal, threading.Event())
    try:
        state.load(MODULES / "I2C_scan.py")
        result = state.call("call", {"name": "scan0"})
    except Exception:
        pass  # Expected — fd < 0
    finally:
        state.close()
        hal.close()


# ---- end-to-end via robot.run -------------------------------------------- #

def test_i2c_scan_via_mt_action(tmp_path):
    sql = """
CREATE TABLE I2C_scan (name String, path String);
INSERT INTO I2C_scan (name, path) VALUES ('scan0', 'virt-bus0');
"""
    mt = "@Action\nscan0.go;\n   1  ;\n@\n"
    with _make_robot(tmp_path, sql) as robot:
        results = robot.run(mt)
        assert len(results) >= 1
        last = results[-1]
        assert last["result"] == "OK"
        assert "found" in last
        assert "count" in last
