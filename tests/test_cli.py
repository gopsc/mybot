"""Local CLI integration tests: real SQL/Lua, fakes only at device boundaries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading

import pytest

from pymybot import cli
from pymybot.errors import DriverError
from pymybot.hal import HALManager
from pymybot.robot import Robot
from pymybot.security import MAX_BODY, SecurityError, checked_text, dumps, read_file

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
VIRTUAL_SQL = """
CREATE TABLE Relay(name String);
INSERT INTO Relay(name) VALUES('relay0');
CREATE TABLE dummy(name String);
INSERT INTO dummy(name) VALUES('dev');
"""
ACTION = "@Action\nrelay0.test dev.echo;\n7 9;\n@\n"
PHYSICAL_SQL = "CREATE TABLE I2C(name String,path String); INSERT INTO I2C(name,path) VALUES('bus','/dev/i2c-99');"


def test_version_flag_prints_the_package_version(capsys):
    with pytest.raises(SystemExit) as exc:
        cli.parse_args(["--version"])
    assert exc.value.code == 0
    assert capsys.readouterr().out.strip() == f"pymybot {cli.__version__}"


def test_doctor_reports_dependencies_and_assets(capsys):
    code = cli.main(["doctor"])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0 and payload["ok"] is True and payload["command"] == "doctor"
    assert payload["healthy"] is True
    checks = {item["name"]: item["status"] for item in payload["checks"]}
    assert checks["lupa"] == "ok"
    assert checks["sqlparse"] == "ok"
    assert checks["mcp"] in {"ok", "warning"}
    assert "PySide6.QtWidgets" not in checks and "tkinter" not in checks
    if sys.platform.startswith("linux"):
        # smbus2 is a base dependency; spidev stays an opt-in extra.
        assert checks["smbus2"] == "ok"
        assert checks["spidev"] in {"ok", "warning"}
    assert set(payload["assets"]) == {"modules", "robots", "scripts"}
    assert payload["assets"]["modules"]["files"] > 0
    assert payload["assets"]["robots"]["files"] > 0
    assert payload["assets"]["scripts"]["files"] > 0


def test_self_contained_skill_entrypoint_reports_healthy():
    script = ROOT / "scripts" / "hardware_controller.py"
    result = subprocess.run([sys.executable, "-I", str(script), "doctor"], cwd=ROOT,
                            capture_output=True, text=True, timeout=60)
    payload = json.loads(result.stdout)
    assert result.returncode == 0 and payload["healthy"] is True
    assert payload["assets"]["scripts"]["files"] > 0


def test_doctor_reports_standard_lua_fallback(monkeypatch, capsys):
    import pymybot.runtime as runtime
    monkeypatch.setattr(runtime, "LUA_BACKEND", "Lua 5.4")
    monkeypatch.setattr(runtime, "LUA_FFI", False)
    code = cli.main(["doctor"])
    payload = json.loads(capsys.readouterr().out)
    checks = {item["name"]: item for item in payload["checks"]}
    assert code == 0 and payload["healthy"] is True
    assert checks["lupa"]["backend"] == "Lua 5.4"
    assert checks["lua.ffi"]["status"] == "warning"


@pytest.mark.parametrize("module, status", [("serial", "missing"), ("mcp", "warning")])
def test_doctor_reports_import_failure(monkeypatch, capsys, module, status):
    real = cli.importlib.import_module

    def fake(name, package=None):
        if name == module:
            raise ImportError("missing shared library")
        return real(name, package)

    monkeypatch.setattr(cli.importlib, "import_module", fake)
    code = cli.main(["doctor"])
    payload = json.loads(capsys.readouterr().out)
    check = next(item for item in payload["checks"] if item["name"] == module)
    assert code == 0 and check["status"] == status and check["error"] == "ImportError"
    assert payload["healthy"] is (status == "warning")
    if module == "mcp":
        assert "pymybot[mcp]" in check["hint"]


@pytest.mark.parametrize("module, required", [("smbus2", True), ("spidev", False)])
def test_doctor_checks_linux_bus_modules(monkeypatch, capsys, module, required):
    monkeypatch.setattr(cli.sys, "platform", "linux")
    real = cli.importlib.import_module

    def fake(name, package=None):
        if name == module:
            raise ImportError("missing shared library")
        if name in {"smbus2", "spidev"}:
            return object()
        return real(name, package)

    monkeypatch.setattr(cli.importlib, "import_module", fake)
    code = cli.main(["doctor"])
    payload = json.loads(capsys.readouterr().out)
    check = next(item for item in payload["checks"] if item["name"] == module)
    assert code == 0
    assert check["status"] == ("missing" if required else "warning")
    assert payload["healthy"] is (not required)
    assert module in check["hint"]


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch):
    for key in list(os.environ):
        if key != "MYBOT_HOME" and key.startswith(("BOT4CJ_", "PYMYBOT_", "MYBOT_")):
            monkeypatch.delenv(key)


@pytest.fixture
def workspace(tmp_path):
    (tmp_path / "robot.sql").write_text(VIRTUAL_SQL, encoding="utf-8")
    (tmp_path / "physical.sql").write_text(PHYSICAL_SQL, encoding="utf-8")
    (tmp_path / "action.mt").write_text(ACTION, encoding="utf-8")
    return tmp_path


def run_cli(workspace, *args):
    return subprocess.run([sys.executable, "-m", "pymybot", *map(str, args)], cwd=workspace,
                          env=dict(os.environ, PYTHONPATH=str(ROOT / "scripts")), input="", encoding="utf-8",
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
    ("CREATE TABLE Missing(name String); INSERT INTO Missing(name) VALUES('dev');",
     "Driver module not found: Missing.py or Missing.lua"),
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


def test_struct_real_cli_read_and_assignment(workspace):
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
    result = run_cli(workspace, "run", "--robot", "robot.sql", "--input", "struct.mt")
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


@pytest.mark.parametrize("command", ["check", "run"])
@pytest.mark.parametrize("body", ["@Trigger\ntrigger;\nf;\n@\n", "@Reflex\nname dev.echo;\nf 1;\n@\n"])
def test_removed_mt_syntax_is_rejected_before_cli_activation(workspace, monkeypatch, capsys, command, body):
    monkeypatch.setattr(Robot, "active", forbid)
    path = workspace / "removed.mt"
    path.write_text("@if(1<0)\n" + body + "@\n", encoding="utf-8")
    code, result, _ = invoke(capsys, command, "--robot", workspace / "robot.sql", "--input", path)
    assert code == 1 and result["error"]["type"] == "ScriptError"


def test_nested_reflex_static_check_does_not_activate(workspace, monkeypatch, capsys):
    monkeypatch.setattr(Robot, "active", forbid)
    path = workspace / "nested-reflex.mt"
    path.write_text('''@Reflex(step)
@Vars
name value;
x 1;
@
dev.echo;
$(x);
@Action
@if(x>0)
dev.echo;
$(x+1);
@
@
@
@Action
step.x;
2;
@
''', encoding="utf-8")
    code, result, _ = invoke(capsys, "check", "--robot", workspace / "robot.sql", "--input", path)
    assert code == 0 and result["activated"] is False
    assert result["action_blocks"] == ["Reflex(step)", "Action"]


@pytest.mark.parametrize("newline", ["\n", "\r\n"], ids=["lf", "crlf"])
@pytest.mark.parametrize("included", [False, True], ids=["direct", "include"])
def test_nested_controls_check_and_run_real_cli(workspace, monkeypatch, capsys, newline, included):
    path = workspace / "nested-controls.mt"
    script = '''@Vars
name value;
outer 0;
inner 0;
@
@Reflex(step)
dev.echo;
$(value);
@
@if(outer==0)
@while(outer<2)
dev.echo dev.capture;
0 $inner=echo;
@while(inner<2)
@if(inner==0)
dev.echo;
100;
@
@Action
step.value step.capture;
$(inner+1) $inner=echo;
@
@
dev.echo dev.capture;
$(outer+1) $outer=echo;
@
@
'''
    path.write_bytes(script.replace("\n", newline).encode("utf-8"))
    if included:
        path = workspace / "entry.mt"
        path.write_text("@Include\npath;\nnested-controls.mt;\n@\n", encoding="utf-8")
    monkeypatch.setattr(Robot, "active", forbid)
    code, checked, _ = invoke(capsys, "check", "--robot", workspace / "robot.sql", "--input", path)
    assert code == 0 and checked["activated"] is False
    assert checked["action_blocks"] == ["Vars", "Reflex(step)", "if(outer==0)"]
    result = run_cli(workspace, "run", "--robot", "robot.sql", "--input", path, "--timeout", "5")
    assert result.returncode == 0, result.stderr
    assert len(result.stdout.splitlines()) == 1
    payload = json.loads(result.stdout)
    assert payload["ok"] is True
    assert [item["echo"] for item in payload["outputs"]] == [0, 100, 1, 2, 1, 0, 100, 1, 2, 2]
    assert [item["count"] for item in payload["outputs"]] == list(range(1, 11))


@pytest.mark.parametrize("in_fragment", [False, True])
def test_top_level_merge_rejects_later_nested_actions(workspace, monkeypatch, capsys, in_fragment):
    monkeypatch.setattr(Robot, "active", forbid)
    plain = "@Action\ndev.echo;\n1;\n@\n"
    nested = "@Action\n@if(1>0)\ndev.echo;\n2;\n@\n@\n"
    fragment = workspace / "fragment.mt"
    fragment.write_text(plain + nested if in_fragment else plain, encoding="utf-8")
    path = workspace / "merge.mt"
    path.write_text(("" if in_fragment else plain + nested) + "@Merge\npath;\nfragment.mt;\n@\n", encoding="utf-8")
    code, result, _ = invoke(capsys, "check", "--robot", workspace / "robot.sql", "--input", path)
    assert code == 1 and result["error"]["type"] == "ScriptError"
    assert "plain @Action" in result["error"]["message"]


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
    for file in (ROOT / "scripts" / "pymybot").glob("*.py"):
        shutil.copyfile(file, package / file.name)
    scripts = package / "assets" / "scripts"
    scripts.mkdir(parents=True)
    (scripts / "wheel.mt").write_text("# only packaged copy")
    result = subprocess.run([sys.executable, "-m", "pymybot", "scripts"], cwd=workspace,
                            env=dict(os.environ, PYTHONPATH=str(install)), capture_output=True, encoding="utf-8", timeout=10)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["scripts"] == ["wheel.mt"]


@pytest.fixture
def asset_root(tmp_path, monkeypatch):
    root = tmp_path / "assets"
    for kind in ("robots", "modules", "scripts"):
        (root / kind).mkdir(parents=True)
    monkeypatch.setattr(cli, "asset_path", lambda name: root / name)
    return root


def test_assets_list_reports_each_kind(asset_root, capsys):
    (asset_root / "robots" / "a.sql").write_text("x", encoding="utf-8")
    (asset_root / "modules" / "lib").mkdir()
    (asset_root / "modules" / "lib" / "b.lua").write_text("x", encoding="utf-8")
    (asset_root / "modules" / "c.py").write_text("x", encoding="utf-8")
    (asset_root / "scripts" / "d.mt").write_text("x", encoding="utf-8")
    code, result, _ = invoke(capsys, "assets", "list")
    assert code == 0 and result["activated"] is False
    assert result["assets"]["robots"]["files"] == ["a.sql"]
    assert result["assets"]["modules"]["files"] == ["c.py", "lib/b.lua"]
    assert result["assets"]["scripts"]["files"] == ["d.mt"]
    code, result, _ = invoke(capsys, "assets", "list", "--kind", "robots")
    assert code == 0 and result["kind"] == "robots" and result["files"] == ["a.sql"]


def test_assets_write_read_delete_roundtrip(asset_root, capsys):
    sql = "CREATE TABLE Demo(name String);"
    code, result, _ = invoke(capsys, "assets", "write", "--kind", "robots",
                             "--path", "demo.sql", "--content", sql)
    assert code == 0 and result["created"] is True and result["path"] == "demo.sql"
    code, result, _ = invoke(capsys, "assets", "write", "--kind", "robots",
                             "--path", "demo.sql", "--content", sql)
    assert code == 2 and result["error"]["type"] == "UsageError"
    code, result, _ = invoke(capsys, "assets", "write", "--kind", "robots",
                             "--path", "demo.sql", "--content", "SELECT 1;", "--force")
    assert code == 0 and result["overwritten"] is True
    code, result, _ = invoke(capsys, "assets", "read", "--kind", "robots", "--path", "demo.sql")
    assert code == 0 and result["content"] == "SELECT 1;"
    code, result, _ = invoke(capsys, "assets", "delete", "--kind", "robots", "--path", "demo.sql")
    assert code == 2 and result["error"]["type"] == "UsageError"
    code, result, _ = invoke(capsys, "assets", "delete", "--kind", "robots",
                             "--path", "demo.sql", "--yes")
    assert code == 0 and result["deleted"] is True
    assert not (asset_root / "robots" / "demo.sql").exists()


def test_assets_reject_traversal_and_bad_suffix(asset_root, capsys):
    code, result, _ = invoke(capsys, "assets", "write", "--kind", "robots",
                             "--path", "../evil.sql", "--content", "x")
    assert code == 2 and result["error"]["type"] == "UsageError"
    code, result, _ = invoke(capsys, "assets", "write", "--kind", "robots",
                             "--path", "demo.txt", "--content", "x")
    assert code == 2 and result["error"]["type"] == "UsageError"
    code, result, _ = invoke(capsys, "assets", "read", "--kind", "robots", "--path", "missing.sql")
    assert code == 2 and result["error"]["type"] == "UsageError"


def test_robot_and_input_resolve_under_asset_root(asset_root):
    (asset_root / "robots" / "r.sql").write_text(VIRTUAL_SQL, encoding="utf-8")
    (asset_root / "scripts" / "s.mt").write_text(ACTION, encoding="utf-8")
    args = cli.parse_args(["check", "--robot", "r.sql", "--input", "s.mt"])
    assert args.robot == str(asset_root / "robots" / "r.sql")
    assert args.input == str(asset_root / "scripts" / "s.mt")
    absolute = str(asset_root / "robots" / "r.sql")
    args = cli.parse_args(["check", "--robot", absolute])
    assert args.robot == absolute


def test_robot_relative_existing_cwd_wins(asset_root, monkeypatch, tmp_path):
    cwd = tmp_path / "cwd"
    cwd.mkdir()
    (cwd / "local.sql").write_text(VIRTUAL_SQL, encoding="utf-8")
    monkeypatch.chdir(cwd)
    args = cli.parse_args(["check", "--robot", "local.sql"])
    assert args.robot == "local.sql"


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
         "--name", "b", "--module-path", str(modules), "--module-path", str(ASSETS / "modules")],
        cwd=workspace, env=dict(os.environ, PYTHONPATH=str(ROOT / "scripts")), input="", encoding="utf-8",
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
    env.update(PYTHONPATH=str(ROOT / "scripts"), PYTHONIOENCODING="gbk")
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


def test_var_env_reads_environment_at_run_time(workspace, capsys, monkeypatch):
    (workspace / "action.mt").write_text("@Action\ntarget.param;\n$(word);\n@\n", encoding="utf-8")
    monkeypatch.setenv("PYMYBOT_TEST_WORD", "hello from env")
    code, result, _ = invoke(capsys, "run", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt",
                             "--var", "target=dev", "--var", "param=echo",
                             "--var-env", "word=PYMYBOT_TEST_WORD")
    assert code == 0 and result["outputs"][0]["echo"] == "hello from env"


def test_var_env_requires_the_named_environment_variable(workspace, capsys, monkeypatch):
    monkeypatch.delenv("PYMYBOT_TEST_ABSENT", raising=False)
    code, result, _ = invoke(capsys, "run", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt",
                             "--var-env", "word=PYMYBOT_TEST_ABSENT")
    assert code == 2 and result["error"]["type"] == "UsageError"
    assert "PYMYBOT_TEST_ABSENT" in result["error"]["message"]


def test_var_and_var_env_names_must_be_distinct(workspace, capsys, monkeypatch):
    monkeypatch.setenv("PYMYBOT_TEST_WORD", "other")
    code, result, _ = invoke(capsys, "run", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt",
                             "--var", "word=first", "--var-env", "word=PYMYBOT_TEST_WORD")
    assert code == 2 and result["error"]["type"] == "UsageError"


@pytest.mark.parametrize("binding", ["word", "word=BAD NAME", "word=B=C", "bad.name=OK"])
def test_invalid_var_env_bindings_are_usage_errors(workspace, capsys, binding):
    code, result, _ = invoke(capsys, "run", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt",
                             "--var-env", binding)
    assert code == 2 and result["error"]["type"] == "UsageError"


def test_var_overrides_vars_row_during_validation(workspace, capsys):
    (workspace / "vars.sql").write_text(
        "CREATE TABLE Vars(name String, value String); INSERT INTO Vars(name, value) VALUES('n','');",
        encoding="utf-8")
    code, result, _ = invoke(capsys, "check", "--robot", workspace / "vars.sql")
    assert code == 1 and result["error"]["type"] == "ScriptError"
    code, result, _ = invoke(capsys, "check", "--robot", workspace / "vars.sql", "--var", "n=3")
    assert code == 0 and result["valid"] is True


@pytest.mark.parametrize("binding", ["missing-equals", "bad.name=value", "=value"])
def test_invalid_vars_are_usage_errors(workspace, capsys, binding):
    code, result, _ = invoke(capsys, "run", "--robot", workspace / "robot.sql", "--input", workspace / "action.mt", "--var", binding)
    assert code == 2 and result["error"]["type"] == "UsageError"


def test_virtual_bus_does_not_reach_physical_hal(workspace, monkeypatch, capsys):
    (workspace / "robot.sql").write_text(PHYSICAL_SQL.replace("/dev/i2c-99", "virt-cli"))
    original = HALManager._bus_open

    def checked(self, kind, path, baud=None, virtual=False):
        assert kind == "i2c" and path == "virt-cli"
        handle = original(self, kind, path, baud, virtual)
        assert self._handles[handle].backend == "virtual"
        return handle

    monkeypatch.setattr(HALManager, "_bus_open", checked)
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


def test_module_paths_passed_through(workspace, monkeypatch, capsys):
    constructed = []
    class ObservedRobot(Robot):
        def __init__(self, text, **kwargs):
            constructed.append(kwargs)
            super().__init__(text, **kwargs)
    monkeypatch.setattr(cli, "Robot", ObservedRobot)
    code, _, _ = invoke(capsys, "sample", "--robot", workspace / "robot.sql", "--name", "dev",
                         "--module-path", workspace, "--module-path", ASSETS / "modules",
                         "--allow-hardware")
    assert code == 0
    assert constructed[0]["allow_hardware"] is True
    assert constructed[0]["module_paths"] == [str(workspace), str(ASSETS / "modules")]


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


def test_signal_stop_uses_abort_instead_of_plain_deactivate(workspace, monkeypatch):
    calls = []

    class FakeRobot:
        def __init__(self, *args, **kwargs):
            self.state = "Active"
            self.tables = {}

        def _validate(self, tables):
            return {}

        def active(self):
            return self

        def run(self, *args, **kwargs):
            return []

        def abort(self, reason):
            calls.append(reason)
            return {"state": "Aborted"}

        def deactivate(self):
            calls.append("deactivate")

    monkeypatch.setattr(cli, "Robot", FakeRobot)
    args = cli.parse_args(["run", "--robot", str(workspace / "robot.sql"),
                           "--input", str(workspace / "action.mt")])
    stop = threading.Event()
    stop.set()

    result = cli.execute(args, stop)

    assert result == {"outputs": []}
    assert calls == ["cli-signal"]


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
    assert "mcp" in help_result.stdout
    assert "--no-gui" not in help_result.stdout and "--no-agent" not in help_result.stdout
    assert "--mcp-backend" not in help_result.stdout
    sample_help = run_cli(workspace, "sample", "--help")
    assert "activation itself may write" in sample_help.stdout
    # A bare invocation is an argparse error: JSON envelope on stdout, diagnosis on stderr.
    bare = run_cli(workspace)
    assert bare.returncode == 2
    payload = json.loads(bare.stdout)
    assert payload["ok"] is False and payload["error"]["type"] == "UsageError"
    assert "required" in payload["error"]["message"]
    assert bare.stderr
    for args in [["run"], ["check", "--robot", "absent.sql"]]:
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


def test_windowed_build_replaces_missing_console_streams():
    original_out, original_err = sys.stdout, sys.stderr
    try:
        sys.stdout = sys.stderr = None
        cli.utf8_streams()
        assert sys.stdout is not None and sys.stderr is not None
    finally:
        replaced_out, replaced_err = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = original_out, original_err
        for stream in (replaced_out, replaced_err):
            if stream not in (None, original_out, original_err):
                stream.close()
