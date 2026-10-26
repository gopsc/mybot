"""GUI plumbing: argv building, result parsing, the serve client and the window shell.

Robot behaviour is not re-tested here: the window never executes robot code.
"""
import json
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import Future
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
                    allow_hardware=True, allow_actions=True, timeout=30, session_log=False)
    cfg.store(path)
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert "task" not in stored and "allow_hardware" not in stored and "allow_actions" not in stored
    assert stored["module_paths"] == ["a"] and stored["read_vars"] == ["v0"]
    assert stored["session_log"] is False
    loaded = GuiConfig.load(path)
    assert loaded.workspace == str(tmp_path) and loaded.timeout == 30
    assert loaded.session_log is False
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


def test_frozen_gui_uses_the_sibling_cli(monkeypatch, tmp_path):
    gui = tmp_path / "mybot-gui"
    cli = tmp_path / ("pymybot.exe" if os.name == "nt" else "pymybot")
    gui.write_text("", encoding="utf-8")
    cli.write_text("", encoding="utf-8")
    monkeypatch.setattr(gui_protocol.sys, "frozen", True, raising=False)
    monkeypatch.setattr(gui_protocol.sys, "executable", str(gui))

    assert gui_protocol.resolve_python(str(tmp_path), "") == str(cli)
    assert gui_protocol._frozen_args(str(cli), ["-m", "pymybot", "serve"]) == ["serve"]
    assert gui_protocol._frozen_args("/usr/bin/python", ["-m", "pymybot", "serve"]) == [
        "-m", "pymybot", "serve"]


def test_gui_package_and_protocol_import_without_qt():
    script = '''
import importlib.abc
import sys
from types import SimpleNamespace
class NoQt(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "PySide6" or fullname.startswith("PySide6."):
            raise ModuleNotFoundError("PySide6 unavailable", name=fullname)
sys.meta_path.insert(0, NoQt())
import pymybot.gui as gui
from pymybot.gui import config, protocol
from pymybot import cli
assert "pymybot.gui.app" not in sys.modules
assert not any(name.startswith("PySide6") for name in sys.modules)
try:
    gui.run_gui(SimpleNamespace())
except gui.GuiUnavailable as exc:
    assert "PySide6" in str(exc) and "pymybot[gui]" in str(exc)
    assert "--no-gui" in str(exc)
else:
    raise AssertionError("missing Qt was not reported")
'''
    result = subprocess.run([sys.executable, "-c", script], cwd=ROOT, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr


# -- native window ----------------------------------------------------------
@pytest.fixture(scope="session")
def qapp():
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("QT_QPA_PLATFORM", "offscreen")
        application = QApplication.instance() or QApplication([])
        application.setQuitOnLastWindowClosed(False)
        yield application


class FakeClient:
    def __init__(self, *args, **kwargs):
        self.alive = True
        self.requests = []
        self.replies = []
        self.cancelled = []
        self.futures = []
        self.stopped = threading.Event()
        self.options = kwargs

    def request(self, method, timeout=None):
        return {"protocol": 1, "agent": True}

    def start_request(self, method, params):
        self.requests.append((method, params))
        future = Future()
        self.futures.append(future)
        return len(self.requests), future

    def respond(self, ident, result):
        self.replies.append((ident, result))

    def cancel(self, ident):
        self.cancelled.append(ident)

    def stop(self, grace=1):
        self.alive = False
        for future in self.futures:
            if not future.done():
                future.set_exception(RpcError("stopped", code=gui_protocol.CANCELLED))
        self.stopped.set()


@pytest.fixture
def app_factory(monkeypatch, qapp, tmp_path):
    from pymybot.gui import app as gui_app

    instances = []
    monkeypatch.setattr(gui_app, "ServeClient", FakeClient)

    def build(config_path=None, config=None):
        config = config or GuiConfig(workspace=str(ROOT), robot=str(ROOT / "robots" / "relay-test.sql"))
        with monkeypatch.context() as patch:
            patch.setattr(gui_app.App, "_refresh_hardware", lambda self: None)
            instance = gui_app.App(config, config_path or tmp_path / "settings.json")
        instance._start_timer.stop()
        instance.show()
        instance.activateWindow()
        qapp.processEvents()
        instances.append(instance)
        return gui_app, instance

    yield build
    for instance in instances:
        instance.shutdown()
        instance.close()
        instance.wait_for_shutdown()
        instance.deleteLater()
    qapp.processEvents()


@pytest.fixture
def ui(app_factory):
    return app_factory()


@pytest.fixture
def interact(qapp):
    from PySide6.QtCore import QTimer
    from PySide6.QtTest import QTest

    failures = []

    def schedule(action):
        def run():
            dialog = qapp.activeModalWidget()
            try:
                assert dialog is not None, "expected a real modal widget"
                action(dialog, QTest)
            except BaseException as exc:
                failures.append(exc)
                if dialog is not None:
                    dialog.reject()
        QTimer.singleShot(0, run)

    yield schedule
    assert not failures, failures


def qt_wait(qapp, predicate, timeout=3000):
    from PySide6.QtTest import QTest

    deadline = time.monotonic() + timeout / 1000
    while time.monotonic() < deadline:
        qapp.processEvents()
        if predicate():
            return True
        QTest.qWait(10)
    return False


def attach_client(app):
    client = FakeClient()
    app.serve = client
    app.agent_available = True
    return client


def test_window_builds_with_robot_context(ui):
    gui, app = ui
    assert isinstance(app, gui.QMainWindow)
    assert app.robot_box.currentText() == "robots/relay-test.sql"
    assert app.send_button.isEnabled() and not app.stop_button.isEnabled()
    assert "未启动" in app.status_state.text()
    assert [app.notebook.tabText(i) for i in range(2)] == ["对话", "日志"]


def test_chat_lines_and_deltas_form_one_transcript(ui):
    _, app = ui
    app._chat_line("你：你好", "user")
    app._chat_delta("第一段")
    app._chat_delta("接续")
    app._chat_line("→ list_hardware {}", "tool")
    app._chat_delta("结论")
    assert app.chat.toPlainText().strip().splitlines() == ["你：你好", "第一段接续", "→ list_hardware {}", "结论"]


def test_streaming_and_logs_are_colored_plain_text(ui):
    gui, app = ui
    text = '<img src="file:///etc/passwd"><b>not HTML</b> & entity'
    app._chat_line(text, "user")
    app._chat_delta(text)
    app._log(text)
    assert app.chat.toPlainText() == text + "\n" + text
    assert app.log.toPlainText() == text + "\n"
    cursor = app.chat.textCursor()
    cursor.setPosition(1)
    assert cursor.charFormat().foreground().color().name() == gui.PALETTE["user"]
    cursor.movePosition(gui.QTextCursor.MoveOperation.End)
    assert cursor.charFormat().foreground().color().name() == gui.PALETTE["assistant"]
    assert app.chat.isReadOnly() and app.log.isReadOnly()


@pytest.mark.parametrize("decision", ["approve", "deny", "close", "escape"])
def test_confirm_request_round_trips_to_the_server(ui, interact, decision):
    gui, app = ui
    client = attach_client(app)

    def choose(dialog, test):
        assert isinstance(dialog, gui.ToolDialog)
        assert dialog.arguments.isReadOnly()
        assert '"script": "<b>a.mt</b>"' in dialog.arguments.toPlainText()
        if decision == "close":
            dialog.close()
        elif decision == "escape":
            test.keyClick(dialog, gui.Qt.Key.Key_Escape)
        else:
            button = dialog.approve_button if decision == "approve" else dialog.deny_button
            test.mouseClick(button, gui.Qt.MouseButton.LeftButton)

    interact(choose)
    app._on_request(app.generation, "s1", "confirm",
                    {"tool": "run_action_script", "arguments": {"script": "<b>a.mt</b>"}})
    assert client.replies == [("s1", {"approved": decision == "approve"})]


def test_oversized_tool_arguments_are_denied(ui, interact):
    gui, app = ui
    client = attach_client(app)

    def dismiss(dialog, test):
        assert isinstance(dialog, gui.QMessageBox)
        assert "参数过长" in dialog.windowTitle()
        assert dialog.textFormat() == gui.Qt.TextFormat.PlainText
        test.mouseClick(dialog.button(gui.QMessageBox.StandardButton.Ok), gui.Qt.MouseButton.LeftButton)

    interact(dismiss)
    app._on_request(app.generation, "s1", "confirm",
                    {"tool": "<b>run</b>", "arguments": {"script": "s" * 5000}})
    assert client.replies == [("s1", {"approved": False})]
    assert "已拒绝（参数过长）" in app.chat.toPlainText()


@pytest.mark.parametrize("invalidate", ["restart", "exit", "close", "replace"])
def test_approval_never_replies_to_a_replacement(ui, interact, invalidate):
    gui, app = ui
    old = attach_client(app)
    replacement = FakeClient()
    generation = app.generation

    def replace(dialog, test):
        if invalidate == "restart":
            app._restart_server()
        elif invalidate == "exit":
            app._on_serve_exit(generation, 1)
        elif invalidate == "close":
            app.close()
        app.serve = replacement
        test.mouseClick(dialog.approve_button, gui.Qt.MouseButton.LeftButton)

    interact(replace)
    app._on_request(generation, "s1", "confirm", {"tool": "run", "arguments": {}})
    assert old.replies == [] and replacement.replies == []
    app.serve = None
    old.stop()


def test_settings_save_reports_success_and_failure(app_factory, tmp_path):
    _, app = app_factory()
    assert app._save() is True
    assert "设置已写入" in app.log.toPlainText()
    assert (tmp_path / "settings.json").is_file()
    _, failing = app_factory(config_path=tmp_path)
    assert failing._save() is False
    assert "设置保存失败" in failing.log.toPlainText()
    assert "配置写入失败" in failing.status_notice.text()


def test_settings_dialog_save_updates_controls_and_restarts(ui, interact, monkeypatch, tmp_path):
    gui, app = ui
    restarted = []
    monkeypatch.setattr(app, "_restart_server", lambda: restarted.append(True))
    monkeypatch.setattr(app, "_refresh_hardware", lambda: None)

    def save(dialog, test):
        assert isinstance(dialog, gui.SettingsDialog)
        dialog.entries["model"].setText("openai:test")
        dialog.entries["module_paths"].setPlainText("modules\n extra \n")
        dialog.entries["read_vars"].setText("v0,v0,bad name,v1")
        dialog.entries["camera_vars"].setText("camera0")
        dialog.entries["scripts_dir"].setText("scripts")
        dialog.timeout.setValue(12.5)
        dialog.requests.setValue(3)
        dialog.tools.setValue(5)
        dialog.session_log.setChecked(False)
        test.mouseClick(dialog.buttons.button(gui.QDialogButtonBox.StandardButton.Save), gui.Qt.MouseButton.LeftButton)

    interact(save)
    app.open_settings()
    assert restarted == [True]
    assert app.cfg.model == "openai:test" and app.cfg.module_paths == ["modules", "extra"]
    assert app.timeout_box.value() == 12.5 and app.requests_box.value() == 3 and app.tools_box.value() == 5
    assert app.read_vars_entry.text() == "v0,v1" and app.camera_vars_entry.text() == "camera0"
    assert app.context_entries["scripts_dir"].text() == "scripts"
    assert "openai:test" in app.model_label.text()
    stored = json.loads((tmp_path / "settings.json").read_text())
    assert stored["session_log"] is False and stored["timeout"] == 12.5
    assert "设置已保存" in app.status_notice.text()


@pytest.mark.parametrize("cancel", ["button", "escape", "close"])
def test_settings_cancel_does_not_apply(ui, interact, tmp_path, cancel):
    gui, app = ui
    original = app.cfg.model

    def dismiss(dialog, test):
        dialog.entries["model"].setText("must-not-save")
        dialog.session_log.setChecked(False)
        if cancel == "button":
            test.mouseClick(dialog.buttons.button(gui.QDialogButtonBox.StandardButton.Cancel), gui.Qt.MouseButton.LeftButton)
        elif cancel == "escape":
            test.keyClick(dialog, gui.Qt.Key.Key_Escape)
        else:
            dialog.close()

    interact(dismiss)
    app.open_settings()
    assert app.cfg.model == original and app.cfg.session_log is True
    assert not (tmp_path / "settings.json").exists()


def test_settings_failure_notice_after_modal_save(app_factory, interact, monkeypatch, tmp_path):
    gui, app = app_factory(config_path=tmp_path)
    monkeypatch.setattr(app, "_refresh_hardware", lambda: None)
    interact(lambda dialog, test: test.mouseClick(
        dialog.buttons.button(gui.QDialogButtonBox.StandardButton.Save), gui.Qt.MouseButton.LeftButton))
    app.open_settings()
    assert "已应用" in app.status_notice.text() and "写入失败" in app.status_notice.text()


def test_permission_toggle_never_persists(ui, tmp_path):
    from PySide6.QtTest import QTest

    gui, app = ui
    QTest.mouseClick(app.hardware_toggle, gui.Qt.MouseButton.LeftButton)
    QTest.mouseClick(app.actions_toggle, gui.Qt.MouseButton.LeftButton)
    assert app.hardware_toggle.isChecked() and app.actions_toggle.isChecked()
    assert "允许硬件" in app.status_busy.text() and "自动批准动作" in app.status_busy.text()
    app._save()
    stored = json.loads((tmp_path / "settings.json").read_text())
    assert "allow_hardware" not in stored and "allow_actions" not in stored
    assert not GuiConfig.load(tmp_path / "settings.json").allow_hardware


@pytest.mark.parametrize("allow", [True, False])
def test_hardware_permission_is_confirmed_before_each_turn(ui, interact, allow):
    gui, app = ui
    client = attach_client(app)
    app.hardware_toggle.setChecked(True)
    app.actions_toggle.setChecked(True)
    app.task_box.setPlainText("列出硬件")

    def decide(dialog, test):
        assert isinstance(dialog, gui.QMessageBox)
        assert dialog.windowTitle() == "确认硬件权限"
        button = gui.QMessageBox.StandardButton.Ok if allow else gui.QMessageBox.StandardButton.Cancel
        test.mouseClick(dialog.button(button), gui.Qt.MouseButton.LeftButton)

    interact(decide)
    app.send_task()
    if allow:
        assert client.requests[0][1]["allowHardware"] is True
        assert client.requests[0][1]["allowActions"] is True
        app._turn_done(app.generation, app.turn_id, {}, None)
        app.task_box.setPlainText("第二轮")
        interact(decide)
        app.send_task()
        assert len(client.requests) == 2
    else:
        assert not client.requests and app.task_box.toPlainText() == "列出硬件"


def test_hardware_confirmation_cannot_authorize_replacement(ui, interact):
    gui, app = ui
    old = attach_client(app)
    new = FakeClient()
    app.hardware_toggle.setChecked(True)
    app.task_box.setPlainText("列出硬件")

    def replace(dialog, test):
        app.generation += 1
        app.serve = new
        test.mouseClick(dialog.button(gui.QMessageBox.StandardButton.Ok), gui.Qt.MouseButton.LeftButton)

    interact(replace)
    app.send_task()
    assert not old.requests and not new.requests
    assert app.task_box.toPlainText() == "列出硬件"


@pytest.mark.parametrize("key", ["Key_Return", "Key_Enter"])
def test_ctrl_enter_sends_with_native_shortcut(ui, qapp, key):
    from PySide6.QtTest import QTest

    gui, app = ui
    client = attach_client(app)
    app.task_box.setPlainText("列出硬件")
    app.task_box.setFocus()
    assert qt_wait(qapp, app.task_box.hasFocus)
    QTest.keyClick(app.task_box, getattr(gui.Qt.Key, key), gui.Qt.KeyboardModifier.ControlModifier)
    assert len(client.requests) == 1 and client.requests[0][0] == "agent.ask"
    assert client.requests[0][1]["task"] == "列出硬件"
    assert client.requests[0][1]["allowHardware"] is False
    assert app.task_box.toPlainText() == ""
    assert not app.send_button.isEnabled() and not app.new_button.isEnabled()
    assert app.stop_button.isEnabled()


def test_request_includes_current_paths_variables_and_budgets(ui):
    _, app = ui
    client = attach_client(app)
    app.context_entries["skills_dir"].setText("skills")
    app.context_entries["camera_src_dir"].setText("images")
    app.context_entries["module_paths"].setText(os.pathsep.join(["modules", "other"]))
    app.read_vars_entry.setText("v0，v1,v0,bad name")
    app.camera_vars_entry.setText("cam")
    app.timeout_box.setValue(2.5)
    app.requests_box.setValue(2)
    app.tools_box.setValue(4)
    app.task_box.setPlainText("hello")
    app.send_button.click()
    params = client.requests[0][1]
    assert params["skillsDir"] == str(ROOT / "skills")
    assert params["cameraSrcDir"] == str(ROOT / "images")
    assert params["modulePaths"] == [str(ROOT / "modules"), str(ROOT / "other")]
    assert params["readVars"] == ["v0", "v1"] and params["cameraVars"] == ["cam"]
    assert (params["timeout"], params["maxRequests"], params["maxToolCalls"]) == (2.5, 2, 4)


def test_composer_sends_without_a_server_and_remembers_the_task(ui, monkeypatch):
    _, app = ui
    started = []
    monkeypatch.setattr(app, "_start_server", lambda: started.append(True))
    app.task_box.setPlainText("列出硬件")
    app.send_task()
    assert app.pending_task == "列出硬件" and started == [True]
    assert app.stop_button.isEnabled()
    app.stop_button.click()
    assert app.pending_task == "" and not app.stop_button.isEnabled()


@pytest.mark.parametrize("cancel", [False, True])
def test_startup_sends_only_the_queued_task_and_preserves_new_draft(ui, monkeypatch, cancel):
    _, app = ui
    monkeypatch.setattr(app, "_start_server", lambda: None)
    app.task_box.setPlainText("queued task")
    app.send_task()
    app.task_box.setPlainText("unsent draft")
    if cancel:
        app.stop_button.click()
    client = FakeClient()
    app._server_started(app.generation, (client, {"agent": True, "protocol": 1}), None)
    assert app.task_box.toPlainText() == "unsent draft"
    assert app.pending_task == ""
    assert len(client.requests) == (0 if cancel else 1)
    if not cancel:
        assert client.requests[0][1]["task"] == "queued task"


def test_stop_and_reset_native_buttons(ui, qapp):
    _, app = ui
    client = attach_client(app)
    app.task_box.setPlainText("hello")
    app.send_button.click()
    app.stop_button.click()
    assert client.cancelled == [1]
    client.futures[0].set_exception(RpcError("cancelled", code=gui_protocol.CANCELLED))
    assert qt_wait(qapp, lambda: not app.busy)
    assert "[已停止]" in app.chat.toPlainText()
    app.new_button.click()
    assert client.requests[-1] == ("agent.reset", {})
    client.futures[-1].set_result({})
    assert qt_wait(qapp, lambda: "新对话，硬件已释放" in app.chat.toPlainText())


def test_stale_generations_and_reused_turn_ids_are_ignored(ui):
    _, app = ui
    attach_client(app)
    app.generation = 5
    app.turn_id = 1
    app._set_busy(True)
    app._on_notify(4, "agent.event", {"id": 1, "event": {"type": "text_delta", "text": "stale"}})
    app._on_request(4, "s1", "confirm", {})
    app._turn_done(4, 1, {"output": "stale"}, None)
    app._on_reset(4, None)
    app._on_serve_exit(4, 1)
    assert app.busy and app.turn_id == 1 and app.chat.toPlainText() == ""
    app._on_notify(5, "agent.event", {"id": 1, "event": {"type": "text_delta", "text": "current"}})
    app._turn_done(5, 1, {"output": "not duplicated", "usage": {"requests": 2}}, None)
    assert app.chat.toPlainText().startswith("current\n[完成 · 请求 2")
    assert "not duplicated" not in app.chat.toPlainText() and not app.busy


def test_callbacks_are_marshaled_to_qt_thread(ui, qapp):
    from PySide6.QtCore import QThread

    _, app = ui
    threads = []
    worker = threading.Thread(target=lambda: app.post(lambda: threads.append(QThread.currentThread())))
    worker.start()
    worker.join()
    assert threads == []
    assert qt_wait(qapp, lambda: bool(threads))
    assert threads == [qapp.thread()]


def test_restart_while_starting_defers_until_old_launch_returns(ui, monkeypatch, qapp):
    gui, app = ui
    initialized, release = threading.Event(), threading.Event()
    clients = []

    class StartingClient(FakeClient):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            clients.append(self)

        def request(self, method, timeout=None):
            if len(clients) == 1:
                initialized.set()
                assert release.wait(5)
            return super().request(method, timeout)

    monkeypatch.setattr(gui, "ServeClient", StartingClient)
    app._start_server()
    try:
        assert initialized.wait(2)
        app._set_busy(True)
        app.turn_id = 1
        app._restart_server()
        app._restart_server()
        assert app.starting and app._restart_pending and not app.busy and app.turn_id is None
        assert len(clients) == 1 and not app._start_timer.isActive()
    finally:
        release.set()
    assert qt_wait(qapp, lambda: app.serve is not None)
    assert len(clients) == 2 and clients[0].stopped.is_set()
    assert clients[0] not in app._clients
    assert app.serve is clients[1] and not app._restart_pending


def test_finished_lifecycle_workers_are_released(ui):
    _, app = ui
    for _ in range(4):
        app._background(lambda: None, lifecycle=True)
        app.wait_for_shutdown()
        assert len(app._lifecycle_workers) == 1


def test_restart_stops_an_existing_client_before_the_replacement(ui, monkeypatch, qapp):
    gui, app = ui
    stopping, release = threading.Event(), threading.Event()

    class SlowStop(FakeClient):
        def stop(self, grace=1):
            stopping.set()
            assert release.wait(5)
            super().stop(grace)

    old = app.serve = SlowStop()
    app._restart_server()
    try:
        assert stopping.wait(2)
        app._restart_server()
        app._start_server()
        assert app._retiring and app.serve is None and not app.starting
    finally:
        release.set()
    assert qt_wait(qapp, lambda: app.serve is not None)
    assert old.stopped.is_set() and isinstance(app.serve, FakeClient)


def test_close_during_initialize_stops_child_without_pumping(ui, monkeypatch):
    gui, app = ui
    initialized = threading.Event()
    clients = []

    class StartingClient(FakeClient):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            clients.append(self)

        def request(self, method, timeout=None):
            initialized.set()
            assert self.stopped.wait(5)
            raise RpcError("closed")

    monkeypatch.setattr(gui, "ServeClient", StartingClient)
    app._start_server()
    assert initialized.wait(2)
    start = time.monotonic()
    app.close()
    assert not app.isVisible() and time.monotonic() - start < 1
    assert clients[0].stopped.wait(2)
    app.wait_for_shutdown()
    assert not app._pump_timer.isActive() and not app._start_timer.isActive()
    assert app.serve is None and not app._restart_pending


def test_close_before_client_constructor_finishes_stops_late_child(ui, monkeypatch):
    gui, app = ui
    constructing, release = threading.Event(), threading.Event()
    clients = []

    class LateClient(FakeClient):
        def __init__(self, *args, **kwargs):
            constructing.set()
            assert release.wait(5)
            super().__init__(*args, **kwargs)
            clients.append(self)

    monkeypatch.setattr(gui, "ServeClient", LateClient)
    app._start_server()
    try:
        assert constructing.wait(2)
        app._restart_server()
        app.close()
        assert not app.isVisible()
    finally:
        release.set()
    app.wait_for_shutdown()
    assert len(clients) == 1 and clients[0].stopped.is_set()
    assert not app._restart_pending and not app._start_timer.isActive()


def test_close_after_initialize_before_callback_stops_registered_child(ui):
    _, app = ui
    app._start_server()
    app.wait_for_shutdown()
    assert app.starting and not app.queue.empty()
    clients = list(app._clients)
    app.close()
    app.wait_for_shutdown()
    assert all(client.stopped.is_set() for client in clients)
    assert app.serve is None and not app.isVisible()


def test_close_while_retiring_never_starts_replacement(ui, qapp):
    _, app = ui
    old = attach_client(app)
    app._restart_server()
    app.close()
    app.wait_for_shutdown()
    assert qt_wait(qapp, lambda: old.stopped.is_set())
    assert app.serve is None and not app._start_timer.isActive()
    app._retired(None, None)
    app._schedule_start()
    app._restart_server()
    app._start_server()
    assert app.serve is None and not app._start_timer.isActive()


@pytest.mark.parametrize("confirm", [False, True])
def test_busy_close_can_cancel_or_shut_down(ui, interact, confirm):
    gui, app = ui
    client = attach_client(app)
    app._set_busy(True)
    button = gui.QMessageBox.StandardButton.Ok if confirm else gui.QMessageBox.StandardButton.Cancel
    interact(lambda dialog, test: test.mouseClick(dialog.button(button), gui.Qt.MouseButton.LeftButton))
    app.close()
    assert app.isVisible() is not confirm
    assert app._stopping is confirm
    if confirm:
        assert client.stopped.wait(2)
    else:
        assert not client.stopped.is_set()


def test_close_stops_real_serve_process_without_ui_callback(ui, tmp_path):
    _, app = ui
    script = tmp_path / "stub.py"
    script.write_text(STUB_SERVER, encoding="utf-8")
    client = ServeClient(sys.executable, tmp_path, python_args=[str(script)])
    assert client.request("initialize", timeout=5)["agent"]
    app.serve = client
    try:
        app.close()
        app.wait_for_shutdown()
        assert client._proc.wait(timeout=3) == 0
        assert not app.isVisible()
    finally:
        client.stop(grace=1)


def test_session_logging_flag_reaches_server(ui, monkeypatch, qapp):
    gui, app = ui
    app.cfg.session_log = False
    app._start_server()
    assert qt_wait(qapp, lambda: app.serve is not None)
    assert app.serve.options["python_args"] == ("-m", "pymybot", "serve", "--no-session-log")


def test_workspace_sql_and_directory_choosers(ui, monkeypatch, tmp_path):
    gui, app = ui
    robot = tmp_path / "outside.sql"
    robot.write_text("-- structure", encoding="utf-8")
    monkeypatch.setattr(app, "_refresh_hardware", lambda: None)
    restarted = []
    monkeypatch.setattr(app, "_restart_server", lambda: restarted.append(True))
    monkeypatch.setattr(gui.QFileDialog, "getExistingDirectory", lambda *args: str(tmp_path))
    app.pick_workspace()
    assert app.cfg.workspace == str(tmp_path) and app.cfg.robot == str(robot)
    assert restarted == [True]
    external = ROOT / "robots" / "relay-test.sql"
    monkeypatch.setattr(gui.QFileDialog, "getOpenFileName", lambda *args: (str(external), "SQL (*.sql)"))
    app.pick_robot()
    assert app.cfg.robot == str(external) and app.robot_box.currentData() == str(external)
    app._browse_into(app.context_entries["scripts_dir"])
    assert app.cfg.scripts_dir == str(tmp_path)
    monkeypatch.setattr(gui.QFileDialog, "getExistingDirectory", lambda *args: "")
    app.pick_workspace()
    assert app.cfg.robot == str(external) and restarted == [True]


def test_hardware_tree_ignores_outdated_results(ui, monkeypatch):
    _, app = ui
    callbacks = []
    monkeypatch.setattr(app, "_background", lambda work, done, **kwargs: callbacks.append(done))
    app._refresh_hardware()
    app._refresh_hardware()
    stale = SimpleNamespace(json={"ok": True, "hardware": [{"name": "stale"}]})
    current = SimpleNamespace(json={"ok": True, "hardware": [{"name": "v0", "type": "Timer", "metadata": {"x": 1}}]})
    callbacks[0](stale, None)
    assert app.hardware_tree.topLevelItemCount() == 0
    callbacks[1](current, None)
    assert app.hardware_tree.topLevelItemCount() == 1
    item = app.hardware_tree.topLevelItem(0)
    assert [item.text(i) for i in range(3)] == ["v0", "Timer", '{"x": 1}']
    assert app.hardware_note.text() == "1 个变量（未激活）"


def test_missing_display_fails_before_qapplication(ui, monkeypatch):
    gui, _ = ui
    from pymybot.gui import GuiUnavailable

    monkeypatch.setattr(gui.sys, "platform", "linux")
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "QT_QPA_PLATFORM"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(gui, "QApplication", lambda *a: pytest.fail("QApplication must not be touched"))
    with pytest.raises(GuiUnavailable, match="No graphical display"):
        gui.run_gui(SimpleNamespace())
    for platform in ("offscreen", "minimal"):
        monkeypatch.setenv("QT_QPA_PLATFORM", platform)
        gui._check_display()


def test_run_gui_uses_existing_qapplication_and_returns_closed(ui, monkeypatch, qapp, tmp_path):
    gui, _ = ui
    monkeypatch.setattr(gui, "config_home", lambda: tmp_path)
    monkeypatch.setattr(gui.App, "_refresh_hardware", lambda self: None)

    def close_window():
        for window in qapp.topLevelWidgets():
            if isinstance(window, gui.App) and window.isVisible():
                window.close()

    gui.QTimer.singleShot(20, close_window)
    assert gui.run_gui(SimpleNamespace(workspace_dir=str(tmp_path))) == {"closed": True}
