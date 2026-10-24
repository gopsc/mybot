"""Local CLI integration tests: real SQL/Lua, fakes only at device boundaries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from pymybot import cli
from pymybot.errors import DriverError
from pymybot.hal import HALManager
from pymybot.robot import Robot
from pymybot.security import MAX_BODY, SecurityError, checked_text, dumps, read_file

ROOT = Path(__file__).resolve().parents[1]
VIRTUAL_SQL = """
CREATE TABLE Relay(name String);
INSERT INTO Relay(name) VALUES('relay0');
CREATE TABLE dummy(name String);
INSERT INTO dummy(name) VALUES('dev');
"""
ACTION = "@Action\nrelay0.test dev.echo;\n7 9;\n@\n"
PHYSICAL_SQL = "CREATE TABLE I2C(name String,path String); INSERT INTO I2C(name,path) VALUES('bus','/dev/i2c-99');"


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch):
    for key in list(os.environ):
        if key.startswith(("BOT4CJ_", "PYMYBOT_", "MYBOT_")):
            monkeypatch.delenv(key)


@pytest.fixture
def workspace(tmp_path):
    (tmp_path / "robot.sql").write_text(VIRTUAL_SQL, encoding="utf-8")
    (tmp_path / "physical.sql").write_text(PHYSICAL_SQL, encoding="utf-8")
    (tmp_path / "action.mt").write_text(ACTION, encoding="utf-8")
    return tmp_path


def run_cli(workspace, *args):
    return subprocess.run([sys.executable, "-m", "pymybot", *map(str, args)], cwd=workspace,
                          env=dict(os.environ, PYTHONPATH=str(ROOT)), input="", encoding="utf-8",
                          capture_output=True, timeout=10)


def invoke(capsys, *args):
    code = cli.main(list(map(str, args)))
    captured = capsys.readouterr()
    assert len(captured.out.splitlines()) == 1
    return code, json.loads(captured.out), captured.err


def forbid(*args, **kwargs):
    pytest.fail("Static/virtual CLI reached hardware or executed Lua")


@pytest.mark.parametrize("command, extra", [
    ("check", []), ("check", ["--input", "action.mt"]),
    ("hardware", []), ("query", ["--sql", "SELECT * FROM I2C;"]),
])
def test_static_commands_never_activate(workspace, monkeypatch, capsys, command, extra):
    from pymybot.runtime import LuaState
    monkeypatch.chdir(workspace)
    monkeypatch.setattr(Robot, "active", forbid)
    monkeypatch.setattr(Robot, "deactivate", forbid)
    monkeypatch.setattr(LuaState, "__init__", forbid)
    monkeypatch.setattr(HALManager, "call", forbid)
    code, result, _ = invoke(capsys, command, "--robot", workspace / "physical.sql", *extra)
    assert code == 0 and result["ok"] and result["activated"] is False
    if command == "hardware":
        assert result["hardware"] == [{"name": "bus", "type": "I2C", "metadata": {"path": "/dev/i2c-99"}}]
    elif command == "query":
        assert "/dev/i2c-99" in result["output"]


@pytest.mark.parametrize("sql, message", [
    ("this is not SQL", ""),
    ("CREATE TABLE Missing(name String); INSERT INTO Missing(name) VALUES('dev');", "Lua module not found"),
    ("CREATE TABLE Relay(name String,source String); INSERT INTO Relay(name,source) VALUES('dev','$absent');", "undefined"),
    ("CREATE TABLE Relay(name String,controller String); INSERT INTO Relay(name,controller) VALUES('dev','absent');", "defined before"),
])
def test_static_validation_failures(workspace, monkeypatch, capsys, sql, message):
    monkeypatch.setattr(Robot, "active", forbid)
    (workspace / "robot.sql").write_text(sql, encoding="utf-8")
    code, result, _ = invoke(capsys, "check", "--robot", workspace / "robot.sql")
    assert code == 1 and not result["ok"]
    assert message in result["error"]["message"]


def test_query_rejects_mutation_without_activation(workspace, monkeypatch, capsys):
    monkeypatch.setattr(Robot, "active", forbid)
    code, result, _ = invoke(capsys, "query", "--robot", workspace / "robot.sql", "--sql", "DROP TABLE dummy;")
    assert code == 1 and "only SELECT" in result["error"]["message"]


@pytest.mark.parametrize("command", ["run", "--no-agent"])
def test_struct_real_cli_read_and_assignment(workspace, command):
    (workspace / "struct.mt").write_text('''@Struct(state)
{"count":0,"values":[2],"text":"a b # ; @"}
@
@while(state.count<3)
@Action
dev.echo dev.capture;
$(state.values[0]+state.count) $state.count=count;
@
@
@Action
dev.echo;
$(state.text);
@
''', encoding="utf-8")
    result = run_cli(workspace, "--no-gui", command, "--robot", "robot.sql", "--input", "struct.mt")
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert [v["echo"] for v in payload["outputs"]] == [2, 3, 4, "a b # ; @"]
    assert len(result.stdout.splitlines()) == 1


@pytest.mark.parametrize("command", ["check", "run"])
def test_struct_invalid_json_is_rejected_before_cli_activation(workspace, monkeypatch, capsys, command):
    monkeypatch.setattr(Robot, "active", forbid)
    (workspace / "struct.mt").write_text('@Struct(state)\n{"value":Infinity}\n@\n', encoding="utf-8")
    code, result, _ = invoke(capsys, command, "--robot", workspace / "robot.sql", "--input", workspace / "struct.mt")
    assert code == 1 and result["error"]["type"] == "ScriptError"


def test_struct_static_check_does_not_activate(workspace, monkeypatch, capsys):
    monkeypatch.setattr(Robot, "active", forbid)
    (workspace / "struct.mt").write_text('@Struct(state)\n{"value":2}\n@\n@Action\ndev.echo;\n$(state.value);\n@\n', encoding="utf-8")
    code, result, _ = invoke(capsys, "check", "--robot", workspace / "robot.sql", "--input", workspace / "struct.mt")
    assert code == 0 and result["activated"] is False
    assert result["action_blocks"] == ["Struct(state)", "Action"]


def test_include_base_is_input_parent(workspace, capsys):
    directory = workspace / "nested scripts"
    directory.mkdir()
    (directory / "part.mt").write_text(ACTION, encoding="utf-8")
    path = directory / "entry.mt"
    path.write_text("@Include\npath;\npart.mt;\n@\n", encoding="utf-8")
    for command in ("check", "run"):
        code, result, _ = invoke(capsys, command, "--robot", workspace / "robot.sql", "--input", path)
        assert code == 0 and result["ok"]
        if command == "run":
            assert result["outputs"][1]["echo"] == 9
        else:
            assert result["action_blocks"] == ["Action"]


@pytest.mark.parametrize("fragment", ["absent.mt", "../action.mt", "/tmp/action.mt", "bad.lua", "action.mt"])
@pytest.mark.parametrize("command", ["check", "run"])
def test_bad_includes_fail_before_activation(workspace, monkeypatch, capsys, fragment, command):
    monkeypatch.setattr(Robot, "active", forbid)
    (workspace / "action.mt").write_text(f"@Include\npath;\n{fragment};\n@\n", encoding="utf-8")
    code, result, _ = invoke(capsys, command, "--robot", workspace / "robot.sql", "--input", workspace / "action.mt")
    assert code == 1 and result["error"]["type"] == "ScriptError"


def test_scripts_only_lists_relative_mt_without_lua(workspace, monkeypatch, capsys):
    root = workspace / "scripts"
    (root / "nested").mkdir(parents=True)
    (root / "a.mt").write_text("not parsed")
    (root / "nested" / "b.mt").write_text("not parsed")
    (root / "danger.lua").write_text("error('must never execute')")
    monkeypatch.setattr(Robot, "__init__", forbid)
    code, result, _ = invoke(capsys, "scripts", "--scripts-dir", root)
    assert code == 0 and result["scripts"] == ["a.mt", "nested/b.mt"]
    assert result["scripts_dir"] == str(root)
    code, result, _ = invoke(capsys, "scripts", "--scripts-dir", root / "missing")
    assert code == 1 and not result["ok"]


def test_scripts_default_source_and_installed_package(workspace, capsys):
    code, result, _ = invoke(capsys, "scripts")
    assert code == 0 and "relay-test.mt" in result["scripts"]
    # Emulate a wheel's extracted layout, with no sibling source/scripts tree.
    install = workspace / "installed"
    package = install / "pymybot"
    package.mkdir(parents=True)
    for file in (ROOT / "pymybot").glob("*.py"):
        shutil.copyfile(file, package / file.name)
    scripts = package / "assets" / "scripts"
    scripts.mkdir(parents=True)
    (scripts / "wheel.mt").write_text("# only packaged copy")
    result = subprocess.run([sys.executable, "-m", "pymybot", "scripts"], cwd=workspace,
                            env=dict(os.environ, PYTHONPATH=str(install)), capture_output=True, encoding="utf-8", timeout=10)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["scripts"] == ["wheel.mt"]


def test_real_virtual_relay_dummy_json_and_stderr(workspace):
    result = run_cli(workspace, "run", "--robot", "robot.sql", "--input", "action.mt")
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["outputs"] == [{"delay": 7}, {"result": "OK", "count": 1, "echo": 9}]
    assert len(result.stdout.splitlines()) == 1
    assert "Relay:" in result.stderr and "Dummy served 1" in result.stderr


def test_faulthandler_cannot_break_json_on_lua_errors(workspace):
    # Windows LuaJIT raises Lua errors as SEH exception 0xE24C4A02, which CPython's
    # faulthandler mistakes for a crash: it dumps every thread's stack mid-unwind and
    # can segfault the process. The CLI must neutralise it; elsewhere this is a no-op.
    modules = workspace / "modules"
    modules.mkdir()
    (modules / "Boom.lua").write_text('function build(data) error("boom") end\n', encoding="utf-8")
    (workspace / "boom.sql").write_text(
        "CREATE TABLE Boom(name String); INSERT INTO Boom(name) VALUES('b');", encoding="utf-8")
    result = subprocess.run(
        [sys.executable, "-X", "faulthandler", "-m", "pymybot", "sample", "--robot", "boom.sql",
         "--name", "b", "--module-path", str(modules), "--module-path", str(ROOT / "modules")],
        cwd=workspace, env=dict(os.environ, PYTHONPATH=str(ROOT)), input="", encoding="utf-8",
        capture_output=True, timeout=10)
    assert result.returncode == 1, result.stderr
    assert len(result.stdout.splitlines()) == 1
    payload = json.loads(result.stdout)
    assert payload["ok"] is False and "boom" in payload["error"]["message"]
    assert "Windows fatal exception" not in result.stderr


def test_output_streams_are_utf8_whatever_the_locale(workspace):
    # Windows pipes default to the ANSI code page (GBK on zh-CN), so Chinese results
    # reached consumers as GBK bytes and characters outside the code page crashed
    # print() before any JSON was written. PYTHONIOENCODING reproduces that on every
    # platform; both streams must still be UTF-8.
    env = {k: v for k, v in os.environ.items() if k != "PYTHONUTF8"}
    env.update(PYTHONPATH=str(ROOT), PYTHONIOENCODING="gbk")
    (workspace / "emoji.sql").write_text(
        "CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('timer-0');"
        "CREATE TABLE Relay(name String, controller String, note String);"
        "INSERT INTO Relay(name, controller, note) VALUES('relay0', 'timer-0', '\u2705');", encoding="utf-8")
    (workspace / "relay.mt").write_text("@Action\nrelay0.test;\n1;\n@\n", encoding="utf-8")
    def cli_bytes(*args):
        result = subprocess.run([sys.executable, "-m", "pymybot", *args], cwd=workspace, env=env,
                                input=b"", capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        return json.loads(result.stdout.decode("utf-8")), result.stderr.decode("utf-8")
    applied, _ = cli_bytes("apply-sql", "--robot", "robot.sql", "--sql", "INSERT INTO dummy(name) VALUES('second');")
    assert applied["output"].startswith("已生效")
    hardware, _ = cli_bytes("hardware", "--robot", "emoji.sql")
    assert hardware["hardware"][1]["metadata"]["note"] == "\u2705"
    ran, diagnostics = cli_bytes("run", "--robot", "emoji.sql", "--input", "relay.mt", "--timeout", "10")
    assert ran["ok"] is True and "note=\u2705" in diagnostics


def test_vars_are_repeated_text_bindings(workspace, capsys):
    (workspace / "action.mt").write_text("@Action\ntarget.param;\n$(word);\n@\n", encoding="utf-8")
    code, result, _ = invoke(capsys, "run", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt",
                             "--var", "target=dev", "--var", "param=echo", "--var", "word=hello=世界")
    assert code == 0 and result["outputs"][0]["echo"] == "hello=世界"


@pytest.mark.parametrize("binding", ["missing-equals", "bad.name=value", "=value"])
def test_invalid_vars_are_usage_errors(workspace, capsys, binding):
    code, result, _ = invoke(capsys, "run", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt", "--var", binding)
    assert code == 2 and result["error"]["type"] == "UsageError"


def test_virtual_bus_does_not_reach_physical_hal(workspace, monkeypatch, capsys):
    (workspace / "robot.sql").write_text(PHYSICAL_SQL.replace("/dev/i2c-99", "virt-cli"))
    monkeypatch.setattr(HALManager, "_i2c_open", forbid)
    code, result, _ = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "bus")
    assert code == 0 and result["samples"][0]["result"] == "OK"


@pytest.mark.parametrize("command, extra", [
    ("run", ["--input", "action.mt"]), ("sample", ["--name", "bus"]),
    ("apply-sql", ["--sql", "CREATE TABLE Vars(name String,value String);"]),
])
def test_physical_refused_by_default_and_flag_reaches_boundary(workspace, monkeypatch, capsys, command, extra):
    monkeypatch.chdir(workspace)
    monkeypatch.setattr(HALManager, "_i2c_open", forbid)
    args = [command, "--robot", workspace / "physical.sql", *extra]
    code, result, _ = invoke(capsys, *args)
    assert code == 1 and not result["ok"]
    assert "allow-hardware" in result["error"]["message"]
    calls = []
    def unavailable(self, path):
        calls.append(path)
        raise OSError("test device unavailable")
    monkeypatch.setattr(HALManager, "_i2c_open", unavailable)
    code, result, _ = invoke(capsys, *args, "--allow-hardware")
    assert code == 1 and not result["ok"]  # Never silently substitute a virtual bus.
    assert calls == ["/dev/i2c-99"]


def test_module_and_camera_paths_passed_through(workspace, monkeypatch, capsys):
    constructed = []
    class ObservedRobot(Robot):
        def __init__(self, text, **kwargs):
            constructed.append(kwargs)
            super().__init__(text, **kwargs)
    monkeypatch.setattr(cli, "Robot", ObservedRobot)
    code, _, _ = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "dev",
                         "--module-path", workspace, "--module-path", ROOT / "modules",
                         "--camera-src-dir", workspace, "--allow-hardware")
    assert code == 0
    assert constructed[0]["allow_hardware"] is True
    assert constructed[0]["module_paths"] == [str(workspace), str(ROOT / "modules")]
    assert constructed[0]["camera_src_root"] == str(workspace)


def test_real_sample_counts_and_cleanup(workspace, capsys):
    code, result, diagnostics = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "dev",
                                       "--count", "3", "--interval-ms", "1", "--timeout", "1")
    assert code == 0 and [sample["count"] for sample in result["samples"]] == [1, 2, 3]
    assert "Dummy served 3" in diagnostics


def test_daemon_sampling_waits_for_nonempty_distinct_samples(capsys, synthetic_modules):
    path = synthetic_modules[0] / "synthetic.sql"
    path.write_text('''
CREATE TABLE Daemon(name String,chunk String,proto String,driver String,addr Number,fields String);
INSERT INTO Daemon(name,chunk,proto,driver,addr,fields) VALUES('sample0','lib/sensor_daemon.lua','virt','SyntheticI2C',49,'COUNT:f');
''', encoding="utf-8")
    code, result, _ = invoke(capsys, "sample", "--robot", path,
                             "--module-path", synthetic_modules[0], "--module-path", synthetic_modules[1],
                             "--name", "sample0", "--count", "3", "--timeout", "3")
    assert code == 0
    samples = result["samples"]
    assert all(sample["count"] > 0 and sample["nvals"] == 1 for sample in samples)
    counts = [sample["count"] for sample in samples]
    assert counts == sorted(set(counts)) and len(counts) == 3
    assert all(sample["values"] == [40960 + sample["count"]] for sample in samples)


@pytest.mark.parametrize("extra", [
    ["--count", "0"], ["--count", "1001"], ["--count", "1.5"],
    ["--interval-ms", "-1"], ["--interval-ms", "60001"],
    ["--timeout", "0"], ["--timeout", "-1"], ["--timeout", "nan"], ["--timeout", "inf"],
    ["--timeout", "3601"], ["--count", "2", "--interval-ms", "1000", "--timeout", "1"],
])
def test_sampling_bounds_precede_activation(workspace, monkeypatch, capsys, extra):
    monkeypatch.setattr(Robot, "active", forbid)
    code, result, _ = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "dev", *extra)
    assert code == 2 and result["error"]["type"] == "UsageError"


def test_unknown_sample_does_not_activate(workspace, monkeypatch, capsys):
    monkeypatch.setattr(Robot, "active", forbid)
    code, result, _ = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "absent")
    assert code == 1 and "not defined" in result["error"]["message"]


@pytest.mark.parametrize("body, error", [
    ('return {result="ERR", message="sample failed"}', "sample failed"),
    ("while true do end", "timed out"),
])
def test_real_sample_failure_and_timeout_cleanup(workspace, capsys, body, error):
    (workspace / "Probe.lua").write_text(f'''
function build(d) return {{result="OK"}} end
function read(d) {body} end
function destroy(d) print("probe destroyed"); return {{result="OK"}} end
''')
    (workspace / "robot.sql").write_text("CREATE TABLE Probe(name String); INSERT INTO Probe(name) VALUES('dev');")
    code, result, diagnostics = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "dev",
                                       "--module-path", workspace, "--timeout", "0.02")
    assert code == 1 and error in result["error"]["message"]
    assert "probe destroyed" in diagnostics


@pytest.mark.parametrize("command, extra, method", [
    ("run", ["--input", "action.mt"], "run"),
    ("sample", ["--name", "dev"], "sample"),
    ("apply-sql", ["--sql", "DROP TABLE dummy;"], "apply_sql"),
])
@pytest.mark.parametrize("partial", [False, True])
def test_every_action_cleans_up_on_partial_or_operation_failure(workspace, monkeypatch, capsys, command, extra, method, partial):
    monkeypatch.chdir(workspace)
    robots = []
    class ObservedRobot(Robot):
        def active(self):
            robots.append(self)
            super().active()
            if partial:
                raise DriverError("partial activation failure")
            if method == "sample":
                self.registry.require("dev").read = lambda: fail()
            return self
        def deactivate(self):
            self.cleanup_called = True
            return super().deactivate()
    def fail(*args, **kwargs):
        raise DriverError("operation failure")
    if not partial and method != "sample":
        monkeypatch.setattr(ObservedRobot, method, fail)
    monkeypatch.setattr(cli, "Robot", ObservedRobot)
    code, result, _ = invoke(capsys, command, "--robot", workspace / "robot.sql", *extra)
    assert code == 1 and not result["ok"]
    assert robots[0].cleanup_called and robots[0].state == "Inactive"
    assert robots[0].registry.require("dev").runtime is None


def test_teardown_error_is_not_reported_as_success(workspace, monkeypatch, capsys):
    real_deactivate = Robot.deactivate
    def fail_cleanup(self):
        real_deactivate(self)
        raise DriverError("teardown failed")
    monkeypatch.setattr(Robot, "deactivate", fail_cleanup)
    code, result, _ = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "dev")
    assert code == 1 and result["error"]["message"] == "teardown failed"


def test_apply_sql_is_ephemeral_and_cleans_up(workspace, capsys):
    path = workspace / "robot.sql"
    before = path.read_bytes()
    code, result, diagnostics = invoke(capsys, "apply-sql", "--robot", path, "--sql", "INSERT INTO dummy(name) VALUES('second');")
    assert code == 0 and result["ok"]
    assert diagnostics.count("Dummy served 0") == 2
    assert path.read_bytes() == before


@pytest.mark.parametrize("flag", ["--mcp-backend", "--mcp-port", "--tcp", "--agent-shell", "--audit-log", "--config", "--allow-hard"])
def test_no_legacy_backend_flags_or_abbreviations(workspace, flag):
    result = run_cli(workspace, "check", "--robot", "robot.sql", flag)
    assert result.returncode == 2
    assert json.loads(result.stdout)["error"]["type"] == "UsageError"


def test_help_errors_and_module_entrypoint(workspace):
    help_result = run_cli(workspace, "--help")
    assert help_result.returncode == 0 and "FFI" in help_result.stdout
    assert "malicious-code isolation" in help_result.stdout
    assert "--no-gui" in help_result.stdout
    assert "MCP" not in help_result.stdout
    sample_help = run_cli(workspace, "sample", "--help")
    assert "activation itself may write" in sample_help.stdout
    # The GUI is the default entry, so a bare invocation is not a usage error.
    for args in [["--no-gui"], ["run"], ["check", "--robot", "absent.sql"]]:
        result = run_cli(workspace, *args)
        assert result.returncode != 0 and json.loads(result.stdout)["ok"] is False
        assert result.stderr


@pytest.mark.parametrize("data", [
    pytest.param(b"\xff", id="invalid-utf8"),
    pytest.param(b"\0", id="nul-byte"),
    pytest.param(b"x" * (MAX_BODY + 1), id="oversized"),
])
@pytest.mark.parametrize("target", ["robot.sql", "action.mt"])
def test_bad_or_oversized_utf8_inputs(workspace, capsys, data, target):
    (workspace / target).write_bytes(data)
    code, result, _ = invoke(capsys, "check", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt")
    assert code == 1 and not result["ok"]


def test_text_sql_limit_and_json_helpers(workspace, capsys):
    code, result, _ = invoke(capsys, "query", "--robot", workspace / "robot.sql", "--sql", "x" * (MAX_BODY + 1))
    assert code == 1 and "byte limit" in result["error"]["message"]
    assert json.loads(dumps({"text": "世界"})) == {"text": "世界"}
    with pytest.raises(ValueError):
        dumps({"bad": float("nan")})
    with pytest.raises(SecurityError):
        read_file(workspace)
    assert checked_text("x" * MAX_BODY) == "x" * MAX_BODY
