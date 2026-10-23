"""Executor safety tests use asyncio.run, without an asyncio pytest plugin."""
import asyncio
import base64
import os
from pathlib import Path
import struct
import subprocess
import sys
import threading
import time
from types import SimpleNamespace
import zlib

import pytest

import pymybot.agent_executor as executor_module
from pymybot.agent_executor import MAX_IMAGE_BASE64, MAX_IMAGES, MAX_TEXT, RobotExecutor
from pymybot.errors import BudgetExceeded
from pymybot.hardware import Budget, Registry
from pymybot.hal import HALManager
from pymybot.matrix import parse_matrices
from pymybot.robot import Robot
from pymybot.security import dumps

ROOT = Path(__file__).resolve().parents[1]
SQL = """
CREATE TABLE Relay(name String); INSERT INTO Relay(name) VALUES('sensor');
CREATE TABLE Camera(name String); INSERT INTO Camera(name) VALUES('camera');
INSERT INTO Camera(name) VALUES('other_camera');
CREATE TABLE Vars(name String,value Number); INSERT INTO Vars(name,value) VALUES('number',1);
CREATE TABLE Alias(name String,alias String); INSERT INTO Alias(name,alias) VALUES('alias','sensor');
"""
ACTION = "@Action\nsensor.test;\n1;\n@\n"


def png_bytes():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00")) + chunk(b"IEND", b""))


@pytest.fixture
def setup(tmp_path):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "action.mt").write_text(ACTION, encoding="utf-8")
    robot_path = tmp_path / "dummy.sql"
    robot_path.write_text(SQL, encoding="utf-8")
    trace = []
    made = []
    options = SimpleNamespace(active=None, run=None, read=None, cleanup=None, query=None,
                              image=HALManager._image_result(png_bytes(), "png", (1, 1), "fake"))

    class Variable:
        kind = "lua"

        def __init__(self, name):
            self.name = name
            self.budget = object()
            self.previous = self.budget

        def read(self):
            trace.append(("read:" + self.name, threading.get_ident()))
            assert isinstance(self.budget, Budget)
            assert all(v.budget is self.budget for v in made[0].registry.values())
            if options.read:
                return options.read(self)
            if "camera" in self.name:
                return options.image
            return {"result": "OK", "value": 7}

    class FakeRobot(Robot):
        def __init__(self, sql_text, **kwargs):
            trace.append(("init", threading.get_ident()))
            super().__init__(sql_text, **kwargs)
            made.append(self)

        def _validate(self, tables):
            trace.append(("validate", threading.get_ident()))
            return self._rows(tables)

        def _rows(self, tables):
            trace.append(("rows", threading.get_ident()))
            return super()._rows(tables)

        def active(self):
            trace.append(("active", threading.get_ident()))
            self.state = "Active"
            self.registry = Registry()
            for name in ("sensor", "camera", "other_camera"):
                self.registry.add(Variable(name))
            if options.active:
                options.active(self)
            return self

        def run(self, script, *, base_dir, vars, timeout):
            trace.append(("run", threading.get_ident()))
            self.last_run = (script, base_dir, vars, timeout)
            if options.run:
                return options.run(self)
            return [{"result": "OK", "value": 1}]

        def query_sql(self, sql):
            trace.append(("query", threading.get_ident()))
            return options.query() if options.query else super().query_sql(sql)

        def deactivate(self):
            trace.append(("deactivate", threading.get_ident()))
            if options.cleanup:
                options.cleanup(self)
            self.state = "Inactive"

    def factory(**kwargs):
        defaults = dict(scripts_dir=scripts, allow_hardware=False, read_vars=("sensor",), camera_vars=("camera",),
                        robot_factory=FakeRobot)
        defaults.update(kwargs)
        return RobotExecutor(robot_path, **defaults)

    return SimpleNamespace(factory=factory, scripts=scripts, path=robot_path, trace=trace,
                           made=made, options=options)


def rejected(result):
    assert result["ok"] is False
    assert result["executed"] is False
    assert result["state"] == "not_executed"


def unknown(result, kind=None):
    assert result["ok"] is False
    assert result["executed"] is True
    assert result["state"] == "unknown"
    assert "do not retry" in result["error"]["message"]
    assert "SECRET" not in dumps(result)
    if kind:
        assert result["error"]["type"] == kind


def test_static_context_and_single_owner(setup):
    async def scenario():
        ex = setup.factory()
        context = await ex.start()
        assert context["robot"] == "dummy"
        assert context["scripts"] == ["action.mt"]
        assert {v["name"] for v in context["hardware"]} == {"sensor", "camera", "other_camera"}
        for name, args in [("list_hardware", {}), ("list_action_scripts", {}),
                           ("query_sql", {"sql": "SHOW TABLES;"})]:
            result = await ex.call(name, args)
            assert result["ok"] and result["state"] == "completed" and not result["executed"]
        assert not any(name == "active" for name, _ in setup.trace)
        await ex.close()
        assert {ident for _, ident in setup.trace} == {ex.owner_thread_id}
        assert ex.owner_thread_id != threading.get_ident()
        assert setup.trace[-1][0] == "deactivate"
        assert all(set(record) == {"tool", "state", "ok", "executed"} for record in ex.records)
    asyncio.run(scenario())


@pytest.mark.parametrize("tool,args", [
    ("list_files", {}), ("read_file", {"path": "action.mt"}),
    ("write_file", {"path": "created.txt", "content": "test"}),
    ("edit_file", {"path": "action.mt", "old_string": "1", "new_string": "2"}),
    ("shell", {"command": "exit 0"}),
])
def test_workspace_capability_is_enforced_in_executor(setup, tool, args):
    async def scenario():
        ex = setup.factory()
        try:
            rejected(await ex.call(tool, args))
            assert not ex.faulted
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_workspace_tools_do_not_activate_robot(setup):
    async def scenario():
        ex = setup.factory(workspace_dir=setup.scripts)
        try:
            context = await ex.start()
            assert context["workspace"]["root"] == str(setup.scripts)
            assert context["workspace"]["shell_enabled"] is False
            assert (await ex.call("list_files", {}))["ok"]
            created = await ex.call("write_file", {"path": "note.txt", "content": "旧内容\n"})
            assert created["ok"] and created["executed"] and created["state"] == "completed"
            edited = await ex.call("edit_file", {"path": "note.txt", "old_string": "旧", "new_string": "新"})
            assert edited["ok"] and edited["executed"]
            result = await ex.call("read_file", {"path": "note.txt"})
            assert result["ok"] and not result["executed"]
            assert result["data"]["content"] == "新内容\n"
            rejected(await ex.call("write_file", {"path": "note.txt", "content": "overwrite"}))
            rejected(await ex.call("shell", {"command": "exit 0"}))
            assert not ex.faulted
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_agent_created_action_is_available_to_robot_tool(setup):
    async def scenario():
        ex = setup.factory(workspace_dir=setup.scripts)
        try:
            assert (await ex.call("write_file", {"path": "created.mt", "content": ACTION}))["ok"]
            assert "created.mt" in (await ex.call("list_action_scripts", {}))["data"]["scripts"]
            result = await ex.call("run_action_script", {"script": "created.mt"})
            assert result["ok"] and result["executed"]
            assert setup.made[0].allow_hardware is False
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("exit_code", [0, 7])
def test_shell_exit_status_is_completed_not_unknown(setup, exit_code):
    async def scenario():
        ex = setup.factory(workspace_dir=setup.scripts, enable_shell=True)
        try:
            result = await ex.call("shell", {"command": f"exit {exit_code}"})
            assert result["ok"] is (exit_code == 0)
            assert result["executed"] and result["state"] == "completed"
            assert result["data"]["exit_code"] == exit_code
            assert not ex.faulted
            assert (await ex.call("list_files", {}))["ok"]
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("byte", [0, 1, 255])
def test_shell_large_escaped_output_preserves_exit_status(setup, byte):
    import shlex
    command = [sys.executable, "-c",
               f"import os; os.write(1,bytes([{byte}])*200000); os.write(2,bytes([{byte}])*200000); raise SystemExit(7)"]
    command = subprocess.list2cmdline(command) if os.name == "nt" else shlex.join(command)

    async def scenario():
        ex = setup.factory(workspace_dir=setup.scripts, enable_shell=True)
        try:
            result = await ex.call("shell", {"command": command})
            assert not result["ok"] and result["state"] == "completed"
            assert result["data"]["exit_code"] == 7
            assert result["data"]["stdout"] and result["data"]["stderr"]
            assert result["data"]["truncated"]
            assert len(dumps(result).encode("utf-8")) <= MAX_TEXT
            assert not ex.faulted
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_shell_interruption_latches_unknown_receipt(setup, monkeypatch):
    began = threading.Event()
    original = executor_module.Workspace.call

    def observed(workspace, name, arguments, check, started):
        def mark_started():
            started()
            began.set()
        return original(workspace, name, arguments, check, mark_started)
    monkeypatch.setattr(executor_module.Workspace, "call", observed)
    command = subprocess.list2cmdline([sys.executable, "-c", "import time; time.sleep(30)"])
    if os.name != "nt":
        import shlex
        command = shlex.join([sys.executable, "-c", "import time; time.sleep(30)"])

    async def scenario():
        ex = setup.factory(workspace_dir=setup.scripts, enable_shell=True)
        try:
            task = asyncio.create_task(ex.call("shell", {"command": command}, timeout=10))
            assert await asyncio.to_thread(began.wait, 5)
            ex.cancel()
            unknown(await asyncio.wait_for(task, 5), "BudgetExceeded")
            assert ex.faulted and ex.interrupted
            rejected(await ex.call("list_files", {}))
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_workspace_side_effect_failure_latches_executor(setup, monkeypatch):
    def broken(workspace, name, arguments, check, started):
        started()
        raise OSError("SECRET filesystem failure")
    monkeypatch.setattr(executor_module.Workspace, "call", broken)

    async def scenario():
        ex = setup.factory(workspace_dir=setup.scripts)
        try:
            unknown(await ex.call("write_file", {"path": "a", "content": "x"}), "OSError")
            assert ex.faulted
            rejected(await ex.call("list_hardware", {}))
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_read_budget_restored_and_activation_once(setup):
    async def scenario():
        ex = setup.factory()
        try:
            for _ in range(2):
                result = await ex.call("read_variables", {"names": ["sensor"]})
                assert result["data"]["sensor"]["value"] == 7
                assert result["ok"] and result["executed"]
                assert all(v.budget is v.previous for v in setup.made[0].registry.values())
            assert [name for name, _ in setup.trace].count("active") == 1
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("name,args", [
    ("shell", {}), ("apply_sql", {"sql": "DROP TABLE Relay;"}),
    ("list_hardware", {"extra": 1}), ("list_action_scripts", {"path": "."}),
    ("query_sql", {"sql": "DROP TABLE Relay;"}),
    ("query_sql", {"sql": "SHOW TABLES; DELETE FROM Relay;"}), ("query_sql", {"sql": 1}),
    ("run_action_script", {"script": "action.mt", "inline": ACTION}),
    ("run_action_script", {"script": "action.mt", "vars": {"x": 1}}),
    ("run_action_script", {"script": "action.mt", "vars": {"bad.name": "x"}}),
    ("run_action_script", {}), ("run_action_script", {"script": 1}),
    ("read_variables", {"names": "sensor"}), ("read_variables", {"names": []}),
    ("read_variables", {"names": ["sensor", "sensor"]}),
    ("read_variables", {"names": ["missing"]}), ("read_variables", {"names": ["bad.name"]}),
    ("read_variables", {"names": ["sensor"], "timeout": 1}),
    ("capture_image", {"name": "other_camera"}), ("capture_image", {"name": "sensor"}),
    ("capture_image", {"name": "camera", "src": "secret.png"}),
    ("list_hardware", []), (None, {}),
])
def test_schema_closed_before_activation(setup, name, args):
    async def scenario():
        ex = setup.factory()
        try:
            rejected(await ex.call(name, args))
            assert not any(name == "active" for name, _ in setup.trace)
            assert not ex.faulted
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("variable", ["camera", "number", "alias", "missing"])
def test_read_kind_and_whitelist_preflight(setup, variable):
    async def scenario():
        ex = setup.factory(read_vars=(variable, "sensor"))
        try:
            rejected(await ex.call("read_variables", {"names": ["sensor", variable]}))
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_read_not_whitelisted_and_camera_wrong_declaration(setup):
    async def scenario():
        ex = setup.factory(read_vars=(), camera_vars=("sensor",))
        try:
            rejected(await ex.call("read_variables", {"names": ["sensor"]}))
            rejected(await ex.call("capture_image", {"name": "sensor"}))
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("name,args", [("run_action_script", {"script": "action.mt"}),
                                       ("read_variables", {"names": ["sensor"]}),
                                       ("capture_image", {"name": "camera"})])
def test_hardware_gate_is_forwarded_without_disabling_virtual_io(setup, name, args):
    async def scenario():
        ex = setup.factory(allow_hardware=False)
        try:
            assert "robot" in await ex.start()
            assert (await ex.call(name, args))["ok"]
            assert setup.made[0].allow_hardware is False
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("path", ["../action.mt", "/action.mt", "C:/action.mt", "C:action.mt",
                                  "sub\\action.mt", "./action.mt", "sub/../action.mt", "action.txt",
                                  "sub//action.mt", "", "action.mt:stream", "action.mt\x00"])
def test_path_rejection(setup, path):
    async def scenario():
        ex = setup.factory()
        try:
            rejected(await ex.call("run_action_script", {"script": path}))
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("text", ["@Action\nsensor.test;\n1 2;\n@", "@Include\npath;\n../secret.mt;\n@",
                                   "@Merge\npath;\nmissing.mt;\n@"])
def test_script_parse_and_include_precheck(setup, text):
    (setup.scripts / "bad.mt").write_text(text, encoding="utf-8")
    async def scenario():
        ex = setup.factory()
        try:
            rejected(await ex.call("run_action_script", {"script": "bad.mt"}))
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_include_snapshot_cannot_change_during_activation(setup):
    (setup.scripts / "action.mt").write_text("@Include\npath;\nfragment.mt;\n@", encoding="utf-8")
    fragment = setup.scripts / "fragment.mt"
    fragment.write_text(ACTION, encoding="utf-8")
    setup.options.active = lambda _: fragment.write_text(ACTION.replace("1;", "99;"), encoding="utf-8")
    async def scenario():
        ex = setup.factory()
        try:
            assert (await ex.call("run_action_script", {"script": "action.mt"}))["ok"]
            frozen = setup.made[0].last_run[0]
            assert "Include" not in frozen and parse_matrices(frozen) == parse_matrices(ACTION)
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("replacement", ["directory", "symlink"])
def test_root_replacement_rejected(setup, replacement):
    async def scenario():
        ex = setup.factory()
        try:
            await ex.start()
            old = setup.scripts.with_name("old-scripts")
            setup.scripts.rename(old)
            if replacement == "directory":
                setup.scripts.mkdir()
                (setup.scripts / "action.mt").write_text(ACTION, encoding="utf-8")
            else:
                from conftest import usable_symlink
                if not usable_symlink(setup.scripts, old):
                    pytest.skip("Symlinks unavailable")
            rejected(await ex.call("run_action_script", {"script": "action.mt"}))
            rejected(await ex.call("list_action_scripts", {}))
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_symlink_file_and_directory_rejected(setup):
    from conftest import usable_symlink
    link = setup.scripts / "link.mt"
    if not usable_symlink(link, setup.scripts / "action.mt"):
        pytest.skip("Symlinks unavailable")
    directory = setup.scripts / "linked"
    if not usable_symlink(directory, setup.scripts):
        pytest.skip("Directory symlinks unavailable")
    async def scenario():
        ex = setup.factory()
        try:
            for path in ("link.mt", "linked/action.mt"):
                rejected(await ex.call("run_action_script", {"script": path}))
            result = await ex.call("list_action_scripts", {})
            assert result["data"]["scripts"] == ["action.mt"]
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_windows_junction_attribute_rejected(setup, monkeypatch):
    original = Path.lstat
    target = setup.scripts / "action.mt"
    def lstat(path, *args, **kwargs):
        info = original(path, *args, **kwargs)
        if path == target:
            return SimpleNamespace(st_mode=info.st_mode, st_file_attributes=0x400)
        return info
    monkeypatch.setattr(Path, "lstat", lstat)
    async def scenario():
        ex = setup.factory()
        try:
            rejected(await ex.call("run_action_script", {"script": "action.mt"}))
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("included", [False, True])
def test_file_identity_changed_after_read(setup, monkeypatch, included):
    target = setup.scripts / ("fragment.mt" if included else "action.mt")
    if included:
        target.write_text(ACTION, encoding="utf-8")
        (setup.scripts / "action.mt").write_text("@Include\npath;\nfragment.mt;\n@", encoding="utf-8")
    original = os.fdopen
    class Stream:
        def __init__(self, real):
            self.real = real
        def __enter__(self):
            self.real.__enter__()
            return self
        def __exit__(self, *args):
            return self.real.__exit__(*args)
        def fileno(self):
            return self.real.fileno()
        def read(self, count):
            value = self.real.read(count)
            if value.replace(b"\r\n", b"\n") == ACTION.encode():
                target.write_text(ACTION + "# changed after read\n", encoding="utf-8")
            return value
    monkeypatch.setattr(os, "fdopen", lambda *a, **kw: Stream(original(*a, **kw)))
    async def scenario():
        ex = setup.factory()
        try:
            rejected(await ex.call("run_action_script", {"script": "action.mt"}))
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("phase,error", [("active", RuntimeError), ("run", RuntimeError),
                                         ("read", BudgetExceeded)])
def test_uncertain_failure_latches_and_cleans_up(setup, phase, error):
    def fail(_):
        raise error("SECRET driver and file contents")
    setattr(setup.options, phase, fail)
    async def scenario():
        ex = setup.factory()
        try:
            tool, args = (("read_variables", {"names": ["sensor"]}) if phase == "read"
                          else ("run_action_script", {"script": "action.mt"}))
            result = await ex.call(tool, args)
            unknown(result, error.__name__)
            assert ex.faulted and not ex.interrupted
            assert setup.made[0].state == "Inactive"
            assert any(name == "deactivate" for name, _ in setup.trace)
            if phase == "read":
                assert all(v.budget is v.previous for v in setup.made[0].registry.values())
            count = len(setup.trace)
            rejected(await ex.call(tool, args))
            rejected(await ex.call("list_hardware", {}))
            assert len(setup.trace) == count
            assert "SECRET" not in dumps(ex.records)
        finally:
            await ex.close()
        assert {ident for _, ident in setup.trace} == {ex.owner_thread_id}
    asyncio.run(scenario())


def test_driver_error_result_is_unknown_without_message_leak(setup):
    setup.options.read = lambda _: {"result": "ERR", "message": "SECRET"}
    async def scenario():
        ex = setup.factory()
        try:
            unknown(await ex.call("read_variables", {"names": ["sensor"]}))
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_stop_before_dispatch_does_not_activate(setup):
    async def scenario():
        stop = threading.Event()
        ex = setup.factory(stop_event=stop)
        await ex.start()
        ex.cancel()
        assert stop.is_set()
        rejected(await ex.call("run_action_script", {"script": "action.mt"}))
        assert not ex.faulted
        assert not any(name == "active" for name, _ in setup.trace)
        await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("timeout", [0, -1, float("nan"), float("inf"), True, "10"])
def test_invalid_timeout(setup, timeout):
    async def scenario():
        ex = setup.factory()
        try:
            rejected(await ex.call("run_action_script", {"script": "action.mt"}, timeout=timeout))
            assert not setup.made
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("phase", ["prepare", "active", "run", "read"])
def test_deadline_covers_preparation_activation_and_native_io(setup, monkeypatch, phase):
    clock = [time.monotonic()]
    monkeypatch.setattr(executor_module, "time", SimpleNamespace(monotonic=lambda: clock[0]))
    def expire(_):
        clock[0] += 10
        return {"result": "OK"}
    if phase == "prepare":
        original = executor_module.parse_matrices
        def parse(text):
            result = original(text)
            clock[0] += 10
            return result
        monkeypatch.setattr(executor_module, "parse_matrices", parse)
    else:
        setattr(setup.options, phase, expire)
    async def scenario():
        ex = setup.factory()
        try:
            await ex.start()
            tool, args = (("read_variables", {"names": ["sensor"]}) if phase == "read"
                          else ("run_action_script", {"script": "action.mt"}))
            result = await ex.call(tool, args, timeout=5)
            if phase == "prepare":
                rejected(result)
                assert not ex.faulted
            else:
                unknown(result, "BudgetExceeded")
                assert ex.faulted
            if phase == "active":
                assert not any(name == "run" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_queue_deadline_and_argument_snapshot(setup, monkeypatch):
    clock = [time.monotonic()]
    monkeypatch.setattr(executor_module, "time", SimpleNamespace(monotonic=lambda: clock[0]))
    entered, release = threading.Event(), threading.Event()
    def block(_):
        entered.set()
        assert release.wait(5)
        clock[0] += 10
        return []
    setup.options.run = block
    async def scenario():
        ex = setup.factory()
        try:
            first = asyncio.create_task(ex.call("run_action_script", {"script": "action.mt"}, timeout=100))
            assert await asyncio.to_thread(entered.wait, 5)
            args = {"script": "action.mt", "vars": {"word": "before"}}
            expired = asyncio.create_task(ex.call("run_action_script", args, timeout=5))
            later = asyncio.create_task(ex.call("run_action_script", args, timeout=100))
            await asyncio.sleep(0)
            args["vars"]["word"] = "after"
            args["script"] = "../bad.mt"
            release.set()
            assert (await first)["ok"]
            rejected(await expired)
            assert (await later)["ok"]
            assert setup.made[0].last_run[2] == {"word": "before"}
            assert setup.made[0].last_run[3] < 100
            assert [name for name, _ in setup.trace].count("run") == 2
        finally:
            release.set()
            await ex.close()
    asyncio.run(scenario())


def test_cancelled_call_waits_for_native_io_and_cleanup(setup):
    entered, release = threading.Event(), threading.Event()
    def block(_):
        entered.set()
        assert release.wait(5)
        return []
    setup.options.run = block
    async def scenario():
        ex = setup.factory()
        try:
            task = asyncio.create_task(ex.call("run_action_script", {"script": "action.mt"}))
            assert await asyncio.to_thread(entered.wait, 5)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
            task.cancel()  # Repeated cancellation must not detach the worker.
            await asyncio.sleep(0)
            release.set()
            unknown(await task, "BudgetExceeded")
            assert ex.faulted and ex.interrupted and setup.made[0].state == "Inactive"
        finally:
            release.set()
            await ex.close()
    asyncio.run(scenario())


def test_close_is_queued_shielded_and_loop_stays_live(setup):
    entered, release = threading.Event(), threading.Event()
    cleaning, finish = threading.Event(), threading.Event()
    def block(_):
        entered.set()
        assert release.wait(5)
        return []
    def cleanup(_):
        cleaning.set()
        assert finish.wait(5)
    setup.options.run, setup.options.cleanup = block, cleanup
    async def scenario():
        ex = setup.factory()
        task = asyncio.create_task(ex.call("run_action_script", {"script": "action.mt"}))
        try:
            assert await asyncio.to_thread(entered.wait, 5)
            closer = asyncio.create_task(ex.close())
            await asyncio.sleep(0)
            assert not cleaning.is_set()
            rejected(await ex.call("list_hardware", {}))
            release.set()
            assert (await task)["ok"]
            assert await asyncio.to_thread(cleaning.wait, 5)
            closer.cancel()
            await asyncio.sleep(0)
            assert not closer.done()
            closer.cancel()
            await asyncio.sleep(0)
            finish.set()
            with pytest.raises(asyncio.CancelledError):
                await closer
            assert setup.made[0].state == "Inactive"
            assert {ident for _, ident in setup.trace} == {ex.owner_thread_id}
            await ex.close()
        finally:
            release.set()
            finish.set()
            await ex.close()
    asyncio.run(scenario())


def test_wait_on_cancelled_future_terminates_instead_of_spinning(setup, monkeypatch):
    shield = asyncio.shield
    calls = []
    def bounded_shield(future):
        calls.append(True)
        assert len(calls) == 1, "A cancelled Future must not be awaited in a busy loop"
        return shield(future)
    async def scenario():
        ex = setup.factory()
        future = asyncio.get_running_loop().create_future()
        future.cancel()
        try:
            with monkeypatch.context() as patch:
                patch.setattr(asyncio, "shield", bounded_shield)
                with pytest.raises(asyncio.CancelledError):
                    await ex._wait(future)
            assert ex.stop_event.is_set()
        finally:
            await ex.close()
    asyncio.run(scenario())
    assert calls == [True]


def test_loop_shutdown_cancellation_still_joins_owner(tmp_path):
    path = tmp_path / "robot.sql"
    path.write_text("CREATE TABLE Vars(name String,value Number);", encoding="utf-8")
    # Isolate the historical infinite-await regression so a failure cannot hang pytest.
    code = r'''
import asyncio
import sys
import threading
from pymybot.agent_executor import RobotExecutor

async def main():
    ex = RobotExecutor(sys.argv[1], scripts_dir=sys.argv[2])
    await ex.start()
    loop = asyncio.get_running_loop()
    entered, release = asyncio.Event(), threading.Event()
    cleaned = []
    original = ex._robot.deactivate
    def deactivate():
        loop.call_soon_threadsafe(entered.set)
        assert release.wait(3)
        original()
        cleaned.append(threading.get_ident())
    ex._robot.deactivate = deactivate
    closer = asyncio.create_task(ex.close())
    await entered.wait()
    timer = threading.Timer(0.05, release.set)
    timer.start()
    return ex, closer, cleaned, timer

ex, closer, cleaned, timer = asyncio.run(main())
timer.join()
assert closer.cancelled()
assert cleaned == [ex.owner_thread_id]
assert all(not thread.is_alive() for thread in ex._pool._threads)
'''
    result = subprocess.run([sys.executable, "-c", code, str(path), str(tmp_path)],
                            cwd=ROOT, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr


def test_cleanup_error_sanitized_and_pool_shutdown(setup):
    def fail(_):
        raise RuntimeError("SECRET cleanup text")
    setup.options.cleanup = fail
    async def scenario():
        ex = setup.factory()
        await ex.start()
        with pytest.raises(RuntimeError) as caught:
            await ex.close()
        assert "SECRET" not in str(caught.value)
        assert ex.faulted
        rejected(await ex.call("list_hardware", {}))
    asyncio.run(scenario())


def test_image_binary_field_and_no_duplicate_base64(setup):
    async def scenario():
        ex = setup.factory()
        try:
            result = await ex.call("capture_image", {"name": "camera"})
            assert result["ok"] and result["executed"]
            assert result["image"] == {"data": png_bytes(), "media_type": "image/png"}
            assert "base64" not in result["data"] and "b64" not in result["data"]
            assert base64.b64encode(png_bytes()).decode() not in dumps(ex.records)
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("change", [
    {"b64": "!invalid!", "base64": "!invalid!"}, {"format": "jpeg"}, {"mime": "text/html"},
    {"b64": "AAAA", "base64": "AAAA"}, {"base64": "mismatch"},
    {"b64": "A" * (MAX_IMAGE_BASE64 + 4), "base64": "A" * (MAX_IMAGE_BASE64 + 4)},
])
def test_invalid_images_fault_after_capture(setup, change):
    setup.options.image.update(change)
    async def scenario():
        ex = setup.factory()
        try:
            unknown(await ex.call("capture_image", {"name": "camera"}))
            assert ex.faulted
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_action_script_images_are_lifted_to_binary(setup):
    setup.options.run = lambda _: [{"result": "OK", "value": 1}, dict(setup.options.image)]
    async def scenario():
        ex = setup.factory()
        try:
            result = await ex.call("run_action_script", {"script": "action.mt"})
            assert result["ok"] and result["executed"] and result["state"] == "completed"
            assert result["images"] == [{"data": png_bytes(), "media_type": "image/png"}]
            outputs = result["data"]["outputs"]
            assert outputs[0] == {"result": "OK", "value": 1}
            assert outputs[1]["image_index"] == 0
            assert "b64" not in outputs[1] and "base64" not in outputs[1]
            encoded = base64.b64encode(png_bytes()).decode()
            assert encoded not in dumps(result["data"]) and encoded not in dumps(ex.records)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_action_script_image_cap_is_reported_not_dropped(setup):
    setup.options.run = lambda _: [dict(setup.options.image) for _ in range(MAX_IMAGES + 2)]
    async def scenario():
        ex = setup.factory()
        try:
            result = await ex.call("run_action_script", {"script": "action.mt"})
            assert result["ok"] and len(result["images"]) == MAX_IMAGES
            assert result["data"]["images_omitted"] == 2
            outputs = result["data"]["outputs"]
            assert [item["image_index"] for item in outputs[:MAX_IMAGES]] == list(range(MAX_IMAGES))
            assert all("image_omitted" in item for item in outputs[MAX_IMAGES:])
            assert not any("b64" in item or "base64" in item for item in outputs)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_multiple_cameras_can_be_allowlisted(setup):
    async def scenario():
        ex = setup.factory(camera_vars=("camera", "other_camera"))
        try:
            for name in ("camera", "other_camera"):
                result = await ex.call("capture_image", {"name": name})
                assert result["ok"] and result["image"] == {"data": png_bytes(), "media_type": "image/png"}
            rejected(await ex.call("capture_image", {"name": "sensor"}))
            assert not ex.faulted
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_text_and_list_output_bounds(setup):
    setup.options.query = lambda: '"\\\n中文' * MAX_TEXT
    setup.options.run = lambda _: [{"result": "OK"}] * 1001
    async def scenario():
        ex = setup.factory()
        try:
            result = await ex.call("query_sql", {"sql": "SHOW TABLES;"})
            assert result["ok"] and result["truncated"]
            assert len(dumps(result).encode("utf-8")) <= MAX_TEXT
            result = await ex.call("run_action_script", {"script": "action.mt"})
            assert result["truncated"] and len(result["data"]["outputs"]) == 1000
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_script_listing_limit(setup):
    for index in range(1001):
        (setup.scripts / f"{index:04}.mt").touch()
    async def scenario():
        ex = setup.factory()
        try:
            result = await ex.call("list_action_scripts", {})
            assert len(result["data"]["scripts"]) == 1000
            assert result["data"]["truncated"]
            assert len((await ex.start())["scripts"]) == 1000
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_real_relay_action_and_read(tmp_path):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "relay.mt").write_text("@Action\nrelay0.test;\n1;\n@", encoding="utf-8")
    async def scenario():
        ex = RobotExecutor(ROOT / "robots" / "relay-test.sql", scripts_dir=scripts,
                           module_paths=[ROOT / "modules"], allow_hardware=False, read_vars=("relay0",))
        try:
            assert (await ex.start())["robot"] == "relay-test"
            result = await ex.call("run_action_script", {"script": "relay.mt"})
            assert result["ok"] and result["data"]["outputs"][-1]["slept"] == 1
            result = await ex.call("read_variables", {"names": ["relay0"]})
            assert result["ok"] and result["data"]["relay0"]["delay"] == 0
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_real_camera_file_source_and_jpeg(tmp_path):
    import io
    from PIL import Image
    buffer = io.BytesIO()
    Image.new("RGB", (3, 2)).save(buffer, "JPEG")
    encoded = buffer.getvalue()
    (tmp_path / "image.jpg").write_bytes(encoded)
    robot_path = tmp_path / "camera.sql"
    robot_path.write_text("CREATE TABLE Camera(name String,src String); "
                          "INSERT INTO Camera(name,src) VALUES('cam','image.jpg');", encoding="utf-8")
    async def scenario():
        ex = RobotExecutor(robot_path, scripts_dir=tmp_path, camera_src_root=tmp_path,
                           camera_vars=("cam",), allow_hardware=False)
        try:
            result = await ex.call("capture_image", {"name": "cam"})
            assert result["ok"]
            assert result["image"] == {"data": encoded, "media_type": "image/jpeg"}
            assert result["data"]["width"] == 3 and "b64" not in result["data"]
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("allow", [False, True])
def test_physical_boundary_never_silently_simulates(tmp_path, monkeypatch, allow):
    path = tmp_path / "physical.sql"
    path.write_text("CREATE TABLE I2C(name String,path String); "
                    "INSERT INTO I2C(name,path) VALUES('bus','/dev/i2c-test');", encoding="utf-8")
    calls = []
    def unavailable(self, path):
        calls.append(path)
        raise OSError("test unavailable, no real hardware access")
    monkeypatch.setattr(HALManager, "_i2c_open", unavailable)
    async def scenario():
        ex = RobotExecutor(path, scripts_dir=tmp_path, read_vars=("bus",), allow_hardware=allow)
        try:
            result = await ex.call("read_variables", {"names": ["bus"]})
            unknown(result)
            assert ex.faulted
        finally:
            await ex.close()
    asyncio.run(scenario())
    assert calls == (["/dev/i2c-test"] if allow else [])


def test_remaining_budget_rechecked_after_last_path_check(setup, monkeypatch):
    clock = [time.monotonic()]
    monkeypatch.setattr(executor_module, "time", SimpleNamespace(monotonic=lambda: clock[0]))
    original = executor_module._Scripts.check
    def check(scripts, path=None):
        original(scripts, path)
        if any(name == "active" for name, _ in setup.trace):
            clock[0] += 10
    monkeypatch.setattr(executor_module._Scripts, "check", check)
    async def scenario():
        ex = setup.factory()
        try:
            unknown(await ex.call("run_action_script", {"script": "action.mt"}, timeout=5), "BudgetExceeded")
            assert not any(name == "run" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_root_replaced_during_activation_faults_without_run(setup):
    def replace(_):
        setup.scripts.rename(setup.scripts.with_name("old-scripts"))
        setup.scripts.mkdir()
    setup.options.active = replace
    async def scenario():
        ex = setup.factory()
        try:
            unknown(await ex.call("run_action_script", {"script": "action.mt"}))
            assert ex.faulted
            assert not any(name == "run" for name, _ in setup.trace)
        finally:
            await ex.close()
    asyncio.run(scenario())


def test_cancel_while_queued_prevents_dispatch(setup):
    entered, release = threading.Event(), threading.Event()
    def block():
        entered.set()
        assert release.wait(5)
        return "static"
    setup.options.query = block
    async def scenario():
        ex = setup.factory()
        try:
            first = asyncio.create_task(ex.call("query_sql", {"sql": "SHOW TABLES;"}))
            assert await asyncio.to_thread(entered.wait, 5)
            queued = asyncio.create_task(ex.call("run_action_script", {"script": "action.mt"}))
            await asyncio.sleep(0)
            ex.cancel()
            release.set()
            rejected(await queued)
            rejected(await first)
            assert not ex.faulted
            assert not any(name == "active" for name, _ in setup.trace)
        finally:
            release.set()
            await ex.close()
    asyncio.run(scenario())


def test_include_merge_and_control_frozen_for_real_robot(tmp_path):
    (tmp_path / "main.mt").write_text(
        "@Include\npath;\nbody.mt;\n@", encoding="utf-8")
    (tmp_path / "body.mt").write_text(
        "@Vars\nname value;\nx 1;\n@\n@if(x==1)\n@Merge\npath;\nfragment.mt;\n@\n"
        "@Action\nrelay0.test;\n1;\n@\n@", encoding="utf-8")
    (tmp_path / "fragment.mt").write_text("@Action\ntimer-0.delay;\n1;\n@", encoding="utf-8")
    async def scenario():
        ex = RobotExecutor(ROOT / "robots" / "relay-test.sql", scripts_dir=tmp_path, allow_hardware=False)
        try:
            result = await ex.call("run_action_script", {"script": "main.mt"})
            assert result["ok"], result
            assert len(result["data"]["outputs"]) == 2
        finally:
            await ex.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("directive", ["Include", "Merge"])
def test_struct_json_and_mutation_survive_agent_snapshot(tmp_path, directive):
    (tmp_path / "main.mt").write_text(f"@{directive}\npath;\npart.mt;\n@\n", encoding="utf-8")
    (tmp_path / "part.mt").write_text('''@Struct(state)
{"count":0,"device":"relay0","parameter":"test","text":"literal # ; @ with spaces"}
@
@while(state.count<3)
@Action
$(state.device).$(state.parameter) relay0.capture;
$(state.count+1) $state.count=slept;
@
@
''' if directive == "Include" else '''@Struct(state)
{"count":1,"text":"literal # ; @ with spaces"}
@
@Action
relay0.test relay0.capture;
$(state.count) $state.count=slept;
$(state.count+1) -;
@
''', encoding="utf-8")

    async def scenario():
        executor = RobotExecutor(ROOT / "robots" / "relay-test.sql", scripts_dir=tmp_path)
        try:
            for _ in range(2):
                result = await executor.call("run_action_script", {"script": "main.mt"})
                assert result["ok"], result
                expected = [1, 2, 3] if directive == "Include" else [1, 2]
                assert [v["slept"] for v in result["data"]["outputs"]] == expected
        finally:
            await executor.close()
    asyncio.run(scenario())


def test_struct_invalid_json_rejected_before_agent_activation(tmp_path, monkeypatch):
    (tmp_path / "main.mt").write_text('@Struct(state)\n{"x":NaN}\n@\n', encoding="utf-8")
    monkeypatch.setattr(Robot, "active", lambda self: pytest.fail("Invalid JSON must not activate the robot"))

    async def scenario():
        executor = RobotExecutor(ROOT / "robots" / "relay-test.sql", scripts_dir=tmp_path)
        try:
            result = await executor.call("run_action_script", {"script": "main.mt"})
            assert result["ok"] is False and result["executed"] is False
            assert result["state"] == "not_executed"
            assert not executor.faulted
        finally:
            await executor.close()
    asyncio.run(scenario())


def test_real_daemon_keeps_its_independent_worker(tmp_path, synthetic_modules):
    robot_path = tmp_path / "daemon.sql"
    robot_path.write_text(
        "CREATE TABLE Daemon(name String,chunk String,proto String,driver String,addr Number,fields String);"
        "INSERT INTO Daemon(name,chunk,proto,driver,addr,fields) "
        "VALUES('sample','lib/sensor_daemon.lua','virt','SyntheticI2C',49,'TAG:f');", encoding="utf-8")
    made = []
    class ObservedRobot(Robot):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            made.append(self)
    async def scenario():
        ex = RobotExecutor(robot_path, scripts_dir=tmp_path, module_paths=synthetic_modules,
                           read_vars=("sample",), allow_hardware=False, robot_factory=ObservedRobot)
        try:
            result = await ex.call("read_variables", {"names": ["sample"]}, timeout=10)
            assert result["ok"], result
            assert result["data"]["sample"]["values"] == [7]
            assert made[0].registry["sample"]._thread.ident != ex.owner_thread_id
        finally:
            await ex.close()
        assert made[0].registry["sample"]._done.is_set()
    asyncio.run(scenario())
