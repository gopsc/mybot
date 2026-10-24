"""GUI plumbing: argv building, result parsing, the serve client and the window shell.

Robot behaviour is not re-tested here: the window never executes robot code.
"""
import json
import sys
import time
import tkinter as tk
from pathlib import Path
from types import SimpleNamespace

import pytest

from pymybot import cli
from pymybot.gui import protocol as gui_protocol
from pymybot.gui.config import GuiConfig, merge_args
from pymybot.gui.protocol import CliCall, RpcError, ServeClient, cli_args, parse_result, resolve_python

ROOT = Path(__file__).resolve().parents[1]


# -- argv building ----------------------------------------------------------
def test_check_arguments_use_equals_form():
    args = cli_args("check", robot="robots/a.sql", script="scripts/a.mt")
    assert args == ["-m", "pymybot", "check", "--robot=robots/a.sql", "--input=scripts/a.mt"]


def test_activating_commands_carry_timeout_and_opt_in():
    args = cli_args("run", robot="r.sql", script="s.mt", timeout=30, allow_hardware=True)
    assert "--timeout=30" in args and "--allow-hardware" in args
    plain = cli_args("run", robot="r.sql", script="s.mt", timeout=30)
    assert "--allow-hardware" not in plain


def test_check_never_carries_hardware_opt_in():
    args = cli_args("check", robot="r.sql", allow_hardware=True)
    assert "--allow-hardware" not in args


def test_sample_arguments_and_validation():
    args = cli_args("sample", robot="r.sql", name="th0", count=3, interval_ms=20, timeout=10)
    assert args[-3:] == ["--name=th0", "--count=3", "--interval-ms=20"]
    assert "--timeout=10" in args
    with pytest.raises(ValueError):
        cli_args("sample", robot="r.sql")


@pytest.mark.parametrize("command", ["check", "run", "query", "apply-sql", "sample"])
def test_each_command_requires_its_inputs(command):
    with pytest.raises(ValueError):
        cli_args(command)


def test_scripts_command_takes_no_robot():
    assert cli_args("scripts") == ["-m", "pymybot", "scripts"]
    assert cli_args("scripts", scripts_dir="scripts")[-1] == "--scripts-dir=scripts"


def test_unknown_flag_like_text_stays_one_argument():
    args = cli_args("query", robot="r.sql", sql="-- comment\nSHOW TABLES;")
    assert args.count("--sql=-- comment\nSHOW TABLES;") == 1


# -- output parsing ---------------------------------------------------------
def test_parse_result_reads_the_last_json_line():
    stdout = 'progress\n{"ok": true, "command": "check"}\n'
    assert parse_result(stdout) == {"ok": True, "command": "check"}


@pytest.mark.parametrize("stdout", ["", "noise\n", '{"command": "x"}\n'])
def test_parse_result_ignores_foreign_lines(stdout):
    assert parse_result(stdout) is None


# -- config -----------------------------------------------------------------
def test_config_roundtrip_drops_runtime_grants(tmp_path):
    path = tmp_path / "settings.json"
    cfg = GuiConfig(workspace=str(tmp_path), robot="robots/a.sql", task="hello",
                    module_paths=["a", "", 3], model="openai:gpt-4o", read_vars=["v0", "bad name"],
                    allow_hardware=True, allow_actions=True, timeout=30)
    cfg.store(path)
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert "task" not in stored and "allow_hardware" not in stored and "allow_actions" not in stored
    assert stored["module_paths"] == ["a"] and stored["read_vars"] == ["v0"]
    loaded = GuiConfig.load(path)
    assert loaded.workspace == str(tmp_path) and loaded.timeout == 30
    assert loaded.allow_hardware is False and loaded.allow_actions is False


def test_config_rejects_hostile_values(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"timeout": "soon", "max_requests": 0, "api_key_env": "bad name",
                                "workspace": 5, "python": "x" * 9000}), encoding="utf-8")
    cfg = GuiConfig.load(path)
    assert cfg.timeout == 180 and cfg.max_requests == 8 and cfg.api_key_env == ""
    assert cfg.workspace == "" and cfg.python == ""


def test_merge_args_prefers_explicit_flags():
    cfg = GuiConfig(workspace="/stored", model="openai:stored", module_paths=["old"])
    args = SimpleNamespace(workspace_dir="/flag", robot="r.sql", model="deepseek:chat",
                           module_path=["m1", "m2"], read_var=[], timeout=12)
    merged = merge_args(cfg, args)
    assert merged.workspace == "/flag" and merged.model == "deepseek:chat"
    assert merged.module_paths == ["m1", "m2"] and merged.timeout == 12


# -- serve client -----------------------------------------------------------
STUB_SERVER = r'''
import json
import sys

pending = None


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    ident = message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": ident,
              "result": {"protocol": 1, "version": "0", "agent": True,
                         "status": {"state": "Inactive", "busy": None, "agent": False}}})
    elif method == "probe":
        pending = ident
        send({"jsonrpc": "2.0", "method": "session",
              "params": {"state": "Active", "busy": None, "agent": True}})
        send({"jsonrpc": "2.0", "id": "s1", "method": "confirm",
              "params": {"tool": "run_action_script", "arguments": {"script": "a.mt"}}})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": ident, "result": {}})
        break
    elif ident == "s1":
        send({"jsonrpc": "2.0", "id": pending,
              "result": {"approved": (message.get("result") or {}).get("approved")}})
        pending = None
'''


def wait_for(predicate, timeout=20.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def test_serve_client_notifications_and_client_requests(tmp_path):
    script = tmp_path / "stub.py"
    script.write_text(STUB_SERVER, encoding="utf-8")
    events, requests = [], []
    client = ServeClient(
        sys.executable,
        tmp_path,
        python_args=[str(script)],
        on_notify=lambda method, params: events.append((method, params)),
        on_request=lambda ident, method, params: requests.append((ident, method, params)),
    )
    try:
        info = client.request("initialize", timeout=30)
        assert info["protocol"] == 1 and info["agent"] is True
        _, future = client.start_request("probe")
        assert wait_for(lambda: bool(requests)), "server did not ask the client"
        ident, method, params = requests[0]
        assert (ident, method) == ("s1", "confirm")
        client.respond(ident, {"approved": True})
        assert future.result(20) == {"approved": True}
        assert events and events[0][0] == "session" and events[0][1]["agent"] is True
    finally:
        client.stop(grace=5)


def test_serve_client_reports_missing_interpreter(tmp_path):
    with pytest.raises(OSError):
        ServeClient(str(tmp_path / "definitely-missing-python"), tmp_path)


def test_serve_client_rejects_requests_after_exit(tmp_path):
    script = tmp_path / "stub.py"
    script.write_text(STUB_SERVER, encoding="utf-8")
    client = ServeClient(sys.executable, tmp_path, python_args=[str(script)])
    client.stop(grace=5)
    with pytest.raises(RpcError) as error:
        client.request("initialize", timeout=5)
    assert error.value.code == gui_protocol.EXITED


# -- one-shot CLI process ---------------------------------------------------
def test_cli_call_parses_json_and_streams_stderr(tmp_path):
    robot = tmp_path / "robot.sql"
    robot.write_text("CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('t0');", encoding="utf-8")
    lines = []
    call = CliCall(resolve_python(str(ROOT), ""), cli_args("check", robot=str(robot)), ROOT,
                   on_stderr=lines.append)
    result = call.wait()
    assert result.code == 0 and result.json["ok"] is True and result.json["valid"] is True
    assert result.stderr == "".join(lines)


def test_cli_call_reports_usage_errors(tmp_path):
    call = CliCall(resolve_python(str(ROOT), ""), cli_args("query", robot="missing.sql", sql="SHOW TABLES;"), ROOT)
    result = call.wait()
    assert result.code == 1 and result.json["ok"] is False
    assert "pymybot:" in result.stderr


# -- entry routing ----------------------------------------------------------
def test_default_entry_is_the_gui(monkeypatch, capsys):
    import pymybot.gui as gui

    called = []
    monkeypatch.setattr(gui, "run_gui", lambda args: called.append(args.command) or {"closed": True})
    code = cli.main([])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0 and payload["command"] == "gui" and called == ["gui"]


def test_no_gui_keeps_the_terminal_agent(monkeypatch, capsys, tmp_path):
    robot = tmp_path / "robot.sql"
    robot.write_text("CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('t0');", encoding="utf-8")
    called = []

    async def run_cli_agent(args, stop):
        called.append(args)
        return {"mode": "agent", "output": "offline", "tool_events": []}

    monkeypatch.setitem(sys.modules, "pymybot.agent", SimpleNamespace(run_cli_agent=run_cli_agent))
    code = cli.main(["--no-gui", "--robot", str(robot), "--task", "hi", "--model", "openai:test"])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0 and payload["mode"] == "agent" and called[0].command == "agent"


def test_no_gui_after_a_subcommand_still_selects_the_cli(monkeypatch, capsys, tmp_path):
    robot = tmp_path / "robot.sql"
    robot.write_text("CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('t0');", encoding="utf-8")
    code = cli.main(["--no-gui", "hardware", "--robot", str(robot)])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0 and payload["command"] == "hardware" and payload["activated"] is False


def test_top_level_no_agent_selects_the_cli_controller(capsys, tmp_path):
    """--no-agent cannot mean anything to the GUI, so it implies --no-gui."""
    robot = tmp_path / "robot.sql"
    robot.write_text("CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('t0');", encoding="utf-8")
    script = tmp_path / "action.mt"
    script.write_text("@Action\nt0.delay;\n5;\n@\n", encoding="utf-8")
    code = cli.main(["--no-agent", "--robot", str(robot), "--input", str(script)])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0 and payload["command"] == "run"
    assert payload["outputs"] == [{"slept": 5, "result": "OK"}]


def test_missing_display_is_actionable(monkeypatch, capsys):
    import pymybot.gui as gui

    def unavailable(args):
        raise gui.GuiUnavailable("no display name and no $DISPLAY environment variable")

    monkeypatch.setattr(gui, "run_gui", unavailable)
    code = cli.main([])
    payload = json.loads(capsys.readouterr().out)
    assert code == 1 and payload["ok"] is False
    assert "--no-gui" in payload["error"]["message"]


# -- window shell -----------------------------------------------------------
@pytest.fixture
def tk_root():
    pytest.importorskip("tkinter")
    try:
        root = tk.Tk()
    except tk.TclError as exc:  # headless CI
        pytest.skip(f"no Tk display: {exc}")
    root.withdraw()
    yield root
    try:
        root.destroy()
    except tk.TclError:
        pass


def build_app(monkeypatch, tk_root, tmp_path):
    from pymybot.gui import app as gui_app

    monkeypatch.setattr(gui_app.App, "_start_server", lambda self: None)
    monkeypatch.setattr(gui_app.App, "_refresh_hardware", lambda self: None)
    config = GuiConfig(workspace=str(ROOT), robot=str(ROOT / "robots" / "relay-test.sql"))
    instance = gui_app.App(tk_root, config, tmp_path / "settings.json")
    tk_root.update()
    return gui_app, instance


def test_window_builds_with_robot_context(monkeypatch, tk_root, tmp_path):
    _, app = build_app(monkeypatch, tk_root, tmp_path)
    assert app.robot_box.get() == "robots/relay-test.sql"
    assert app.send_button.instate(["!disabled"])
    assert "未启动" in app.status_state.cget("text")


def test_chat_lines_and_deltas_form_one_transcript(monkeypatch, tk_root, tmp_path):
    _, app = build_app(monkeypatch, tk_root, tmp_path)
    app._chat_line("你：你好", "user")
    app._chat_delta("第一段")
    app._chat_delta("接续")
    app._chat_line("→ list_hardware {}", "tool")
    app._chat_delta("结论")
    text = app.chat.get("1.0", "end").strip()
    assert text.splitlines() == ["你：你好", "第一段接续", "→ list_hardware {}", "结论"]


def test_oversized_tool_arguments_are_denied(monkeypatch, tk_root, tmp_path):
    gui_app, app = build_app(monkeypatch, tk_root, tmp_path)
    warnings = []
    monkeypatch.setattr(gui_app.messagebox, "showwarning", lambda *a, **k: warnings.append(a))
    approved = app._ask_tool({"tool": "run_action_script", "arguments": {"script": "s" * 5000}})
    assert approved is False and warnings
    assert "已拒绝" in app.chat.get("1.0", "end")


def test_confirm_request_round_trips_to_the_server(monkeypatch, tk_root, tmp_path):
    gui_app, app = build_app(monkeypatch, tk_root, tmp_path)

    class FakeDialog:
        def __init__(self, parent, tool, arguments):
            self.approved = True
            self.top = tk.Toplevel(parent)
            self.top.withdraw()
            self.top.after(1, self.top.destroy)

    monkeypatch.setattr(gui_app, "ToolDialog", FakeDialog)
    replies = []
    app.serve = SimpleNamespace(respond=lambda ident, result: replies.append((ident, result)))
    app._on_request(app.generation, "s1", "confirm",
                    {"tool": "run_action_script", "arguments": {"script": "a.mt"}})
    assert replies == [("s1", {"approved": True})]


def test_permission_toggle_never_persists(monkeypatch, tk_root, tmp_path):
    _, app = build_app(monkeypatch, tk_root, tmp_path)
    app.hardware_var.set(True)
    app._save()
    stored = json.loads((tmp_path / "settings.json").read_text(encoding="utf-8"))
    assert "allow_hardware" not in stored and "allow_actions" not in stored


def test_composer_sends_without_a_server_and_remembers_the_task(monkeypatch, tk_root, tmp_path):
    _, app = build_app(monkeypatch, tk_root, tmp_path)
    started = []
    monkeypatch.setattr(app, "_start_server", lambda: started.append(True))
    app.task_box.insert("1.0", "列出硬件")
    app.send_task()
    assert app.pending_task == "列出硬件" and started == [True]
