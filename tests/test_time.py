"""Tests for the pure-software Time driver (host clock, no hardware)."""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path
import time

import pytest

from pymybot.errors import DriverError
from pymybot.robot import Robot

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "skills" / "hardware-controller" / "assets"
MODULES = ASSETS / "modules"
SQL = "CREATE TABLE Time (name String); INSERT INTO Time (name) VALUES ('clock');"


def _robot(sql=SQL):
    return Robot(sql, module_paths=[MODULES])


def test_time_now_returns_snapshot_without_format():
    with _robot() as robot:
        out = robot.run("@Action\nclock.now;\n1;\n@", timeout=10)[0]

    assert out["result"] == "OK"
    assert "formatted" not in out


def test_time_snapshot_fields_and_format():
    before = time.time_ns() // 1_000_000
    with _robot() as robot:
        out = robot.run('@Action\nclock.format;\n$("%Y-%m-%dT%H:%M:%S");\n@', timeout=10)[0]
    after = time.time_ns() // 1_000_000

    assert out["result"] == "OK"
    assert before <= out["epoch_ms"] <= after
    assert out["epoch"] == out["epoch_ms"] // 1000
    assert out["utc"].endswith("Z")

    utc = datetime.fromisoformat(out["utc"].replace("Z", "+00:00"))
    local = datetime.fromisoformat(out["local"])
    assert utc.utcoffset() == timedelta(0)
    assert int(utc.timestamp()) == out["epoch"]
    assert local.tzinfo is not None

    assert out["year"] == local.year
    assert out["month"] == local.month
    assert out["day"] == local.day
    assert out["hour"] == local.hour
    assert out["minute"] == local.minute
    assert out["second"] == local.second
    assert out["microsecond"] == local.microsecond
    assert out["weekday"] == local.isoweekday()
    assert out["yday"] == local.timetuple().tm_yday
    assert out["isdst"] == int(bool(local.dst()))
    assert out["formatted"] == local.strftime("%Y-%m-%dT%H:%M:%S")


def test_time_format_utc_override():
    with _robot() as robot:
        rows = robot.run(
            "@Action\nclock.format clock.utc;\n"
            '$("%H:%M:%S") 1;\n'
            '$("%H:%M:%S") 0;\n@',
            timeout=10,
        )

    utc_row, local_row = rows
    assert utc_row["formatted"] == utc_row["utc"][11:19]
    assert local_row["formatted"] == local_row["local"][11:19]


@pytest.mark.parametrize("fmt", ["%Q", "abc%", "%", "%s", "%G", "%Z", "%a"])
def test_time_rejects_invalid_format(fmt):
    with _robot() as robot:
        with pytest.raises(DriverError, match="Invalid Arguments: format"):
            robot.run(f'@Action\nclock.format;\n$("{fmt}");\n@', timeout=10)


def test_time_format_literal_percent():
    with _robot() as robot:
        out = robot.run('@Action\nclock.format;\n$("100%%");\n@', timeout=10)[0]

    assert out["formatted"] == "100%"


def test_time_format_with_spaces_via_struct():
    script = '''@Struct(fmt)
{
  "stamp": "%Y-%m-%d %H:%M:%S"
}
@
@Action
clock.format;
$(fmt.stamp);
@
'''
    with _robot() as robot:
        out = robot.run(script, timeout=10)[0]

    assert out["formatted"] == out["local"][:10] + " " + out["local"][11:19]


def test_time_read_returns_current_snapshot():
    with _robot() as robot:
        first = robot.registry["clock"].read()
        second = robot.registry["clock"].read()

    assert first["result"] == "OK" and second["result"] == "OK"
    assert second["epoch"] >= first["epoch"]


def test_time_example_files_run():
    with Robot.from_file(ASSETS / "robots" / "time.sql", module_paths=[MODULES]) as robot:
        script = (ASSETS / "scripts" / "time.mt").read_text(encoding="utf-8")
        outputs = robot.run(script, timeout=20)

    assert outputs and all(out["result"] == "OK" for out in outputs)
