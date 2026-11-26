"""Smoke tests for the chip drivers migrated into the Python implementation.

Each fixture pair under tests/fixtures/virt/ was lifted from an earlier
repository layout (robots/test/<name>_virt.sql + scripts/test/<name>_virt.mt): the
device or Daemon row declares proto=virt, so the driver's embedded <NAME>_VIRT
model answers bus traffic in memory. The real driver build/call/destroy run
unmodified through the same Robot path as physical hardware — no device is
opened, which the default (no --allow-hardware) HAL gating enforces anyway.

Drivers without an embedded virt model have no fixture; for those only the
module contract (require_driver defines build/call/destroy) is checked.
"""

import threading
from pathlib import Path

import pytest

from pymybot.daemon import DaemonVariable
from pymybot.hal import HALManager
from pymybot.robot import Robot
from pymybot.runtime import LuaState

ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "modules"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "virt"
VIRT_SQL = sorted(FIXTURES.glob("*_virt.sql"))
# Migrated drivers whose file carries no <NAME>_VIRT model (AD9833, H03ARR,
# LCD1206, Servo, TPL0501); they are real-hardware-only in the old repo too.
CONTRACT_ONLY = ["AD9833", "H03ARR", "LCD1206", "Servo", "TPL0501"]


@pytest.mark.parametrize("sql_path", VIRT_SQL, ids=lambda path: path.stem)
def test_migrated_driver_end_to_end_on_virtual_bus(sql_path):
    action = (FIXTURES / (sql_path.stem + ".mt")).read_text(encoding="utf-8")
    with Robot(sql_path.read_text(encoding="utf-8"), module_paths=[MODULES]) as robot:
        daemons = [v for v in robot.registry.values() if isinstance(v, DaemonVariable)]
        for daemon in daemons:
            sample = daemon.wait_for_sample(timeout=10)
            assert sample["result"] == "OK" and sample["count"] >= 1
        outputs = robot.run(action, timeout=60)
        assert outputs, "action script produced no output rows"
        bad = [out for out in outputs
               if not (isinstance(out, dict) and out.get("result") == "OK")]
        assert not bad, f"non-OK rows: {bad!r}"
        for daemon in daemons:
            assert daemon.slot.snapshot()["count"] >= 1
    assert robot.state == "Inactive"


@pytest.mark.parametrize("name", CONTRACT_ONLY)
def test_migrated_driver_module_defines_contract(name):
    hal = HALManager()
    state = LuaState([MODULES], hal, threading.Event())
    try:
        state.load(MODULES / f"{name}.lua")
        for entry in ("build", "call", "destroy"):
            assert state.has_function(entry), f"{name}.lua did not define {entry}"
    finally:
        state.close()
        hal.close()
