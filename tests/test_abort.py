import threading
import time
from pathlib import Path

import pytest

from pymybot.errors import BudgetExceeded, ScriptError
from pymybot.robot import Robot


DRIVER = '''
import time
from pathlib import Path


class Driver:
    def __init__(self, context):
        self.context = context

    def _event(self, data, event):
        with Path(data["log"]).open("a", encoding="utf-8") as stream:
            stream.write(f"{data['tag']} {event} mode={data.get('mode')} reason={data.get('reason')}\\n")

    def build(self, data):
        self._event(data, "build")
        return {"result": "OK"}

    def call(self, data):
        self._event(data, "call")
        for _ in range(500):
            self.context.check()
            time.sleep(0.01)
        return {"result": "OK"}

    def safe(self, data):
        self.context.check()
        if data["tag"] == "bad":
            raise RuntimeError("synthetic safe failure")
        self._event(data, "safe")
        return {"result": "OK"}

    def destroy(self, data):
        self._event(data, "destroy")
        return {"result": "OK"}
'''


@pytest.fixture
def abort_robot(tmp_path):
    modules = tmp_path / "modules"
    modules.mkdir()
    (modules / "Probe.py").write_text(DRIVER, encoding="utf-8")
    log = (tmp_path / "events.log").as_posix()
    sql = (
        "CREATE TABLE Probe(name String, tag String, log String); "
        f"INSERT INTO Probe(name, tag, log) VALUES ('a', 'a', '{log}'); "
        f"INSERT INTO Probe(name, tag, log) VALUES ('b', 'b', '{log}');"
    )
    robot = Robot(sql, module_paths=[modules])
    return robot, Path(log)


def events(log):
    return [line.split(" ", 1) for line in Path(log).read_text(encoding="utf-8").splitlines()]


def event_tags(log, event):
    return [tag for tag, rest in events(log) if rest.startswith(event + " ")]


def test_abort_runs_safe_in_reverse_then_destroys_and_latches(abort_robot):
    robot, log = abort_robot
    robot.active()

    receipt = robot.abort("operator-test")

    assert receipt["state"] == "Aborted"
    assert receipt["aborted"] is True
    assert receipt["reason"] == "operator-test"
    assert receipt["safe_failures"] == []
    assert robot.state == "Aborted"
    assert event_tags(log, "safe") == ["b", "a"]
    assert event_tags(log, "destroy") == ["b", "a"]
    assert all("mode=safe" in rest and "reason=operator-test" in rest
               for _, rest in events(log) if rest.startswith("safe "))
    with pytest.raises(ScriptError, match="aborted"):
        robot.active()
    assert robot.abort("again") == receipt
    robot.deactivate()


def test_abort_wakes_a_cooperative_action(abort_robot):
    robot, log = abort_robot
    robot.active()
    failure = []

    def run():
        try:
            robot.run("@Action\na.wait;\n1;\n@\n", timeout=30)
        except BaseException as exc:
            failure.append(exc)

    thread = threading.Thread(target=run)
    thread.start()
    time.sleep(0.1)
    started = time.monotonic()
    robot.abort("stop-action")
    thread.join(5)

    assert not thread.is_alive()
    assert time.monotonic() - started < 3
    assert len(failure) == 1 and isinstance(failure[0], BudgetExceeded)
    assert any(rest.startswith("safe ") and "reason=stop-action" in rest for _, rest in events(log))


def test_lua_safe_hook_receives_mode_and_reason(tmp_path, capsys):
    modules = tmp_path / "modules"
    modules.mkdir()
    (modules / "LuaProbe.lua").write_text('''
function build(data) return {result="OK"} end
function call(data) return {result="OK"} end
function safe(data)
    print("LUA-SAFE " .. tostring(data.mode) .. " " .. tostring(data.reason))
    return {result="OK"}
end
function destroy(data) return {result="OK"} end
''', encoding="utf-8")
    robot = Robot("CREATE TABLE LuaProbe(name String); INSERT INTO LuaProbe(name) VALUES ('lua0');",
                  module_paths=[modules])
    robot.active()
    receipt = robot.abort("lua-stop")
    assert receipt["safe_failures"] == []
    assert "LUA-SAFE safe lua-stop" in capsys.readouterr().err


def test_safe_failure_is_reported_but_destroy_still_runs(tmp_path):
    modules = tmp_path / "modules"
    modules.mkdir()
    (modules / "Probe.py").write_text(DRIVER, encoding="utf-8")
    log = (tmp_path / "events.log").as_posix()
    sql = (
        "CREATE TABLE Probe(name String, tag String, log String); "
        f"INSERT INTO Probe(name, tag, log) VALUES ('bad', 'bad', '{log}');"
    )
    robot = Robot(sql, module_paths=[modules])
    robot.active()

    receipt = robot.abort("safe-failure")

    assert receipt["state"] == "Aborted"
    assert len(receipt["safe_failures"]) == 1
    assert "bad" in receipt["safe_failures"][0]
    assert event_tags(log, "destroy") == ["bad"]
    assert robot.state == "Aborted"
