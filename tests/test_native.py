from pathlib import Path
import sys
import threading
import time

import pytest

from conftest import usable_symlink
from pymybot.errors import BudgetExceeded, DriverError, ScriptError
from pymybot.hal import HALManager
from pymybot.native import PythonState
from pymybot.robot import Robot


ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "modules"
SQL = "CREATE TABLE Probe(name String); INSERT INTO Probe(name) VALUES('dev');"
PROBE = '''
from dataclasses import dataclass

count = 0

@dataclass
class State:
    value: int = 0

class Driver:
    def __init__(self, context):
        self.context = context
        self.state = State()

    def build(self, data):
        global count
        count += 1
        self.state.value = int(data.get("initial", 0))
        return {"result": "OK"}

    def call(self, data):
        self.state.value += int(data.get("value", 1))
        return {"result": "OK", "value": self.state.value, "mode": data["mode"]}

    def read(self, data):
        return {"result": "OK", "value": self.state.value, "instances": count}

    def destroy(self, data):
        self.state.value = -1
        return {"result": "OK"}
'''


def make_robot(tmp_path, source=PROBE, sql=SQL, **kwargs):
    (tmp_path / "Probe.py").write_text(source, encoding="utf-8")
    return Robot(sql, module_paths=[tmp_path, MODULES], **kwargs)


def test_sql_python_instances_snapshots_and_module_cleanup(tmp_path):
    robot = make_robot(tmp_path, sql=SQL + "INSERT INTO Probe(name) VALUES('second');")
    with robot:
        first = robot.registry["dev"].runtime
        second = robot.registry["second"].runtime
        module_names = [first.module.__name__, second.module.__name__]
        assert first.driver is not second.driver
        assert first.module is not second.module
        assert all(name in sys.modules for name in module_names)
        assert robot.registry["dev"].kind == "python"
        assert robot.run("@Action\ndev.value;\n4;\n@")[-1]["value"] == 4
        assert robot.registry["dev"].read()["value"] == 4
        assert robot.registry["second"].read() == {"result": "OK", "value": 0, "instances": 1}
        driver = first.driver
    assert driver.state.value == -1
    assert all(name not in sys.modules for name in module_names)
    with pytest.raises(DriverError, match="closed"):
        first.context.call("uart_open", "loop://", 9600)
    robot.active()
    assert robot.registry["dev"].read()["value"] == 0
    robot.deactivate()


def test_static_validation_does_not_execute_or_import_driver(tmp_path):
    marker = tmp_path / "executed"
    source = f"from pathlib import Path\nPath({str(marker)!r}).touch()\nraise RuntimeError('executed')\n"
    robot = make_robot(tmp_path, source)
    robot._validate(robot.tables)
    assert not marker.exists()
    assert robot.state == "Loaded"
    with pytest.raises(DriverError, match="executed"):
        robot.active()
    assert marker.exists()


def test_static_check_rejects_syntax_errors(tmp_path):
    robot = make_robot(tmp_path, "class Driver(:\n")
    with pytest.raises(ScriptError, match="Invalid Python driver"):
        robot._validate(robot.tables)
    assert robot.state == "Loaded"


def test_native_source_size_limit(tmp_path):
    robot = make_robot(tmp_path, "#" + "x" * (8 * 1024 * 1024))
    with pytest.raises(ScriptError, match="8 MiB"):
        robot._validate(robot.tables)


def test_native_symlinks_rejected(tmp_path):
    target = tmp_path / "actual.py"
    target.write_text(PROBE)
    if not usable_symlink(tmp_path / "Probe.py", target):
        pytest.skip("Platform cannot create usable symbolic links")
    robot = Robot(SQL, module_paths=[tmp_path, MODULES])
    with pytest.raises(ScriptError, match="Symlink"):
        robot._validate(robot.tables)


def test_module_root_precedence_then_python_preference(tmp_path):
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    upper.mkdir()
    lower.mkdir()
    (upper / "Probe.lua").write_text('function build(d) return {result="OK"} end\n'
                                     'function call(d) return {result="OK", value=99} end')
    (lower / "Probe.py").write_text(PROBE)
    with Robot(SQL, module_paths=[upper, lower]) as robot:
        assert robot.registry["dev"].kind == "lua"
        assert robot.registry["dev"].read()["value"] == 99
    (upper / "Probe.py").write_text(PROBE)
    with Robot(SQL, module_paths=[upper, lower]) as robot:
        assert robot.registry["dev"].kind == "python"


@pytest.mark.parametrize("source, message", [
    ("Driver = 1", "Driver class"),
    ("class Driver:\n    def __init__(self, context): pass", "build"),
    ("class Driver:\n    def __init__(self, context): pass\n    def build(self, data): return {'result': 'OK'}", "call"),
])
def test_bad_native_contract_fails_activation(tmp_path, source, message):
    robot = make_robot(tmp_path, source)
    before = set(sys.modules)
    with pytest.raises(DriverError, match=message):
        robot.active()
    assert robot.state == "Inactive"
    assert not [name for name in set(sys.modules) - before if name.startswith("_pymybot_driver_")]


def test_optional_read_and_destroy(tmp_path):
    source = '''
class Driver:
    def __init__(self, context): pass
    def build(self, data): return {"result": "OK"}
    def call(self, data): return {"result": "OK", "mode": data["mode"]}
'''
    with make_robot(tmp_path, source) as robot:
        assert robot.registry["dev"].read() == {"result": "OK", "mode": "call"}


@pytest.mark.parametrize("value, message", [
    ("None", "dictionary"), ("{}", "non-empty"),
    ("{'result': 'ERR', 'message': 'broken'}", "broken"),
    ("{'result': 'maybe'}", "status"),
    ("{'value': object()}", "Unsupported"),
    ("{'value': float('nan')}", "Unsupported"),
    ("{1: 'bad'}", "keys must be strings"),
])
def test_native_result_contract(tmp_path, value, message):
    source = f'''
class Driver:
    def __init__(self, context): pass
    def build(self, data): return {{"result": "OK"}}
    def call(self, data): return {value}
'''
    with make_robot(tmp_path, source) as robot:
        with pytest.raises(DriverError, match=message):
            robot.registry["dev"].play({})


def test_native_print_does_not_corrupt_stdout(tmp_path, capsys):
    source = "print('loading native')\n" + PROBE.replace(
        "self.state.value += int(data.get(\"value\", 1))",
        "print('native call')\n        self.state.value += int(data.get(\"value\", 1))")
    with make_robot(tmp_path, source) as robot:
        robot.registry["dev"].play({})
    output = capsys.readouterr()
    assert output.out == ""
    assert "loading native" in output.err and "native call" in output.err


@pytest.mark.parametrize("operation,args", [
    ("i2c_open", ["/dev/i2c-1"]),
    ("spi_open", ["/dev/spidev0.0"]),
    ("uart_open", ["COM3", 9600]),
    ("http_open", ["https://example.com", 1000]),
    ("shell_open", [1000]),
    ("camera_capture", [1, {}]),
])
def test_native_context_keeps_hardware_permission_gate(tmp_path, operation, args):
    hal = HALManager()
    state = PythonState([tmp_path], hal, threading.Event())
    try:
        with pytest.raises(DriverError, match="allow-hardware"):
            state.context.call(operation, *args)
        assert not hal._handles
    finally:
        state.close()
        hal.close()


@pytest.mark.parametrize("stage", ["init", "build", "call", "destroy"])
def test_native_failed_lifecycle_reclaims_handles(tmp_path, stage):
    source = f'''
class Driver:
    def __init__(self, context):
        self.context = context
        self.fd = context.call("uart_open", "loop://", 9600)
        if {stage!r} == "init": raise RuntimeError("init failed")
    def build(self, data):
        if {stage!r} == "build": raise RuntimeError("build failed")
        return {{"result": "OK"}}
    def call(self, data):
        if {stage!r} == "call": raise RuntimeError("call failed")
        return {{"result": "OK"}}
    def destroy(self, data):
        if {stage!r} == "destroy": raise RuntimeError("destroy failed")
        return {{"result": "OK"}}
'''
    robot = make_robot(tmp_path, source)
    if stage in {"init", "build"}:
        with pytest.raises(DriverError, match="failed"):
            robot.active()
    else:
        with robot:
            if stage == "call":
                with pytest.raises(DriverError, match="call failed"):
                    robot.registry["dev"].play({})
    assert not robot.hal._handles and not robot.hal._buses


def test_native_action_budget_and_cleanup_after_cancel(tmp_path):
    source = '''
class Driver:
    def __init__(self, context): self.context = context
    def build(self, data): return {"result": "OK"}
    def call(self, data):
        self.context.call("sleep_ms", 10000)
        return {"result": "OK"}
    def destroy(self, data):
        self.context.call("sleep_ms", 1)
        return {"result": "OK"}
'''
    with make_robot(tmp_path, source) as robot:
        started = time.monotonic()
        with pytest.raises(BudgetExceeded):
            robot.run("@Action\ndev.tick;\n1;\n@", timeout=.02)
        assert time.monotonic() - started < 1
        assert robot.registry["dev"].budget is None
        robot.stop_event.set()


def test_native_cooperative_budget(tmp_path):
    source = '''
class Driver:
    def __init__(self, context): self.context = context
    def build(self, data): return {"result": "OK"}
    def call(self, data):
        while True: self.context.check()
'''
    with make_robot(tmp_path, source) as robot:
        with pytest.raises(BudgetExceeded):
            robot.run("@Action\ndev.tick;\n1;\n@", timeout=.02)


def test_python_metadata_and_lua_controller_trigger_interoperate(tmp_path):
    (tmp_path / "LuaProbe.lua").write_text('''
function build(d) return {result="OK"} end
function call(d) return {result="OK", value=tonumber(d.value or 7)*2} end
''')
    source = PROBE.replace('self.state.value += int(data.get("value", 1))',
                           'self.state.value += int(data["initial"]) + int(data["triggered"]["value"])')
    sql = '''
CREATE TABLE Vars(name String, value Number);
INSERT INTO Vars(name, value) VALUES('start', 3);
CREATE TABLE LuaProbe(name String);
INSERT INTO LuaProbe(name) VALUES('triggered');
INSERT INTO LuaProbe(name) VALUES('controlled');
CREATE TABLE Probe(name String, initial String, trigger String, controller String);
INSERT INTO Probe(name, initial, trigger, controller) VALUES('dev', '$start', 'triggered', 'controlled');
'''
    with make_robot(tmp_path, source, sql) as robot:
        result = robot.run("@Action\ndev.tick;\n1;\n@")[-1]
        assert result["value"] == 40
        with pytest.raises(ScriptError, match="reserved metadata"):
            robot.registry["dev"].play({"initial": 99})


def test_native_hot_sql_lifecycle_and_flow_refs(tmp_path):
    sql = '''
CREATE TABLE Probe(name String, initial Number, controller String);
INSERT INTO Probe(name, initial, controller) VALUES('dev', 2, '-');
'''
    with make_robot(tmp_path, sql=sql) as robot:
        old = robot.registry["dev"].runtime.driver
        robot.apply_sql("UPDATE Probe SET initial=5 WHERE name='dev';")
        assert old.state.value == -1
        assert robot.registry["dev"].read()["value"] == 5
        robot.apply_sql("INSERT INTO Probe(name, initial, controller) VALUES('second', 1, 'dev');")
        assert robot.registry.flow_refs == {"dev"}
        with pytest.raises(ScriptError, match="defined before"):
            robot.apply_sql("DELETE FROM Probe WHERE name='dev';")
        robot.apply_sql("DELETE FROM Probe WHERE name='second';")
        assert robot.registry.flow_refs == set()
        robot.apply_sql("DROP TABLE Probe;")
        assert not list(robot.registry)


def test_native_uart_example_and_borrowed_handle():
    with Robot.from_file(ROOT / "robots" / "uart-loopback.sql") as robot:
        assert {var.kind for var in robot.registry.values()} == {"python"}
        assert robot.registry["bus"].runtime._virtual is None
        action = (ROOT / "scripts" / "uart-loopback.mt").read_text()
        assert [item["rx"] for item in robot.run(action)] == [0, 127, 255]
        assert len(robot.hal._handles) == 1
    assert not robot.hal._handles


def test_executor_can_sample_and_run_native_drivers():
    import asyncio
    from pymybot.agent_executor import RobotExecutor

    async def scenario():
        executor = RobotExecutor(ROOT / "robots" / "uart-loopback.sql",
                                 scripts_dir=ROOT / "scripts", read_vars=("echo",))
        try:
            await executor.start()
            sampled = await executor.call("read_variables", {"names": ["echo"]})
            assert sampled["ok"], sampled
            assert sampled["data"]["echo"]["rx"] == 0
            action = await executor.call("run_action_script", {"script": "uart-loopback.mt"})
            assert action["ok"], action
        finally:
            await executor.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("config", [
    "chunk String, driver String, fields String); INSERT INTO Daemon(name,chunk,driver,fields) "
    "VALUES('worker','lib/sensor_daemon.lua','Probe','value');",
    "chunk String, devices String); INSERT INTO Daemon(name,chunk,devices) "
    "VALUES('worker','lib/sensor_daemon_multi.lua','Probe@0x40@value');",
])
def test_lua_daemon_rejects_selected_python_driver(tmp_path, config):
    robot = make_robot(tmp_path, sql="CREATE TABLE Daemon(name String," + config)
    (tmp_path / "Probe.lua").write_text('error("must not fall back")')
    with pytest.raises(ScriptError, match="Lua daemon requires a Lua driver"):
        robot._validate(robot.tables)


def test_native_input_and_result_are_detached(tmp_path):
    source = '''
class Driver:
    def __init__(self, context): self.value = {"items": [1]}
    def build(self, data): return {"result": "OK"}
    def call(self, data):
        data["payload"]["items"].append(9)
        return {"result": "OK", "value": self.value}
'''
    with make_robot(tmp_path, source) as robot:
        params = {"payload": {"items": [3]}}
        value = robot.registry["dev"].play(params)
        assert params == {"payload": {"items": [3]}}
        value["value"]["items"].append(99)
        assert robot.registry["dev"].runtime.driver.value == {"items": [1]}


def test_python_inventory_and_preview_are_nonexecuting(tmp_path):
    from pymybot.agent_context import ProjectContext
    from pymybot.gui.resources import ResourceIndex

    marker = tmp_path / "executed"
    path = tmp_path / "Probe.py"
    path.write_text(f"from pathlib import Path\nPath({str(marker)!r}).touch()")
    (tmp_path / "Other.lua").write_text('error("must not execute")')
    index = ResourceIndex(None, docs_root=tmp_path, module_paths=[tmp_path])
    entries = {item.name: item for item in index.refresh()}
    assert entries["Probe.py"].language == "python"
    assert entries["Other.lua"].language == "lua"
    assert index.read(entries["Probe.py"]) == path.read_bytes().decode("utf-8")
    context = ProjectContext(module_paths=[tmp_path]).render().text
    assert "Probe.py" in context and "Other.lua" in context
    assert not marker.exists()


def test_native_resource_panel_preview_and_filter(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("PySide6")
    from PySide6.QtCore import Qt
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QApplication
    from pymybot.gui.dialogs import ResourcePanel
    from pymybot.gui.highlight import COLORS

    app = QApplication.instance() or QApplication([])
    panel = ResourcePanel()
    panel.resize(1100, 700)
    panel.set_roots(ROOT / "scripts", robots_root=ROOT / "robots", module_paths=[MODULES])
    panel.show()
    panel.ensure_loaded()
    QTest.qWait(100)
    try:
        items = [panel.tree.topLevelItem(i).child(j)
                 for i in range(panel.tree.topLevelItemCount())
                 for j in range(panel.tree.topLevelItem(i).childCount())]
        native = next(item for item in items if item.text(0) == "LoopbackProbe.py")
        lua = next(item for item in items if item.text(0) == "Relay.lua")
        panel.tree.scrollToItem(native)
        QTest.mouseClick(panel.tree.viewport(), Qt.MouseButton.LeftButton,
                         pos=panel.tree.visualItemRect(native).center())
        QTest.qWait(160)
        assert panel.preview.currentWidget() is panel.code
        assert panel.code.toPlainText() == (MODULES / "LoopbackProbe.py").read_text(encoding="utf-8")
        formats = panel.code.document().firstBlock().layout().formats()
        assert any(item.start == 0 and item.format.foreground().color().name() == COLORS["keyword"]
                   for item in formats)
        assert panel.grab().save(str(tmp_path / "preview.png"))
        panel.filter.setFocus()
        QTest.keyClicks(panel.filter, ".py")
        assert not native.isHidden() and lua.isHidden()
        panel.filter.setText("no-such-resource")
        assert all(item.isHidden() for item in items)
        panel.filter.clear()
        panel.tree.scrollToItem(lua)
        QTest.mouseClick(panel.tree.viewport(), Qt.MouseButton.LeftButton,
                         pos=panel.tree.visualItemRect(lua).center())
        assert panel.code.toPlainText() == (MODULES / "Relay.lua").read_text(encoding="utf-8")
    finally:
        panel.close()
        app.processEvents()


def test_native_build_observes_robot_stop_before_next_io(tmp_path, monkeypatch):
    source = '''
class Driver:
    def __init__(self, context): self.context = context
    def build(self, data):
        self.context.call("sleep_ms", 100)
        self.context.call("uart_open", "loop://", 9600)
        return {"result": "OK"}
    def call(self, data): return {"result": "OK"}
    def destroy(self, data):
        self.context.call("sleep_ms", 1)
        return {"result": "OK"}
'''
    robot = make_robot(tmp_path, source)
    operations = []
    original = robot.hal.call

    def trace(operation, *args, **kwargs):
        operations.append(operation)
        if operation == "sleep_ms":
            robot.stop_event.set()
        return original(operation, *args, **kwargs)

    monkeypatch.setattr(robot.hal, "call", trace)
    with pytest.raises(BudgetExceeded):
        robot.active()
    assert robot.state == "Inactive"
    assert "uart_open" not in operations
    assert not robot.hal._handles


def test_native_unbudgeted_read_observes_robot_stop(tmp_path):
    with make_robot(tmp_path) as robot:
        robot.stop_event.set()
        with pytest.raises(BudgetExceeded):
            robot.registry["dev"].read()


@pytest.mark.parametrize("base, expression", [
    ("int", "{'value': Mutable(5)}"),
    ("str", "{'value': Mutable('text')}"),
    ("float", "{'value': Mutable(1.5)}"),
    ("str", "{Mutable('key'): 1}"),
])
def test_native_results_reject_mutable_scalar_subclasses(tmp_path, base, expression):
    source = f'''
class Mutable({base}): pass
class Driver:
    def __init__(self, context): pass
    def build(self, data): return {{"result": "OK"}}
    def call(self, data): return {expression}
'''
    with make_robot(tmp_path, source) as robot:
        with pytest.raises(DriverError, match="Unsupported|keys must be strings"):
            robot.registry["dev"].play({})


def test_native_input_rejects_scalar_subclasses_without_copy_hooks(tmp_path):
    class Mutable(int):
        def __deepcopy__(self, memo):
            raise AssertionError("native boundary must not invoke copy hooks")

    with make_robot(tmp_path) as robot:
        with pytest.raises(DriverError, match="Unsupported"):
            robot.registry["dev"].play({"value": Mutable(5)})
