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
from pymybot.gui.protocol import (CliCall, RpcError, ServeClient, cli_args, parse_result,
                                  resolve_python, sessions_args)

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "skills" / "hardware-controller" / "assets"


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
                    module_paths=["a", "", 3], model="openai:gpt-4o",
                    vars={"user": "alice"}, allow_hardware=True, allow_actions=True, timeout=30,
                    session_log=False)
    cfg.store(path)
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert "task" not in stored and "allow_hardware" not in stored and "allow_actions" not in stored
    assert "vars" not in stored
    assert stored["module_paths"] == ["a"]
    assert stored["session_log"] is False
    loaded = GuiConfig.load(path)
    assert loaded.workspace == str(tmp_path) and loaded.timeout == 30
    assert loaded.session_log is False
    assert loaded.vars == {}
    assert loaded.allow_hardware is False and loaded.allow_actions is False


def test_config_keeps_tool_preferences_but_drops_grants(tmp_path):
    path = tmp_path / "settings.json"
    cfg = GuiConfig(workspace=str(tmp_path), mcp_config="mcp.json",
                    enable_file_tools=True, enable_shell=True,
                    allow_file_writes=True, allow_mcp_tools=True,
                    max_history_bytes=8 * 1024 * 1024,
                    max_context_tokens=32768, context_reserve_tokens=1024)
    cfg.store(path)
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert stored["enable_file_tools"] is True and stored["enable_shell"] is True
    assert "allow_file_writes" not in stored
    assert "allow_mcp_tools" not in stored
    loaded = GuiConfig.load(path)
    assert loaded.max_history_bytes == 8 * 1024 * 1024
    assert loaded.max_context_tokens == 32768 and loaded.context_reserve_tokens == 1024
    assert loaded.enable_file_tools and loaded.enable_shell
    assert not loaded.allow_file_writes and not loaded.allow_mcp_tools


def test_config_rejects_hostile_values(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"timeout": "soon", "api_key_env": "bad name",
                                "workspace": 5, "python": "x" * 9000}), encoding="utf-8")
    cfg = GuiConfig.load(path)
    assert cfg.timeout == 180 and cfg.api_key_env == ""
    assert cfg.workspace == "" and cfg.python == ""


def test_merge_args_prefers_explicit_flags():
    cfg = GuiConfig(workspace="/stored", model="openai:stored", module_paths=["old"])
    args = SimpleNamespace(workspace_dir="/flag", robot="r.sql", model="deepseek:chat",
                           module_path=["m1", "m2"], timeout=12)
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

    monkeypatch.setitem(sys.modules, "pymybot.agent_cli", SimpleNamespace(run_cli_agent=run_cli_agent))
    code = cli.main(["--no-gui", "--robot", str(robot), "--task", "hi", "--role", "test-role",
                     "--model", "openai:test"])
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
        if config is None:
            from pymybot.roles import create_role, load_role, role_path
            # Conversations require a role; most window tests need a usable one.
            role = load_role("test-role") if role_path("test-role").exists() else create_role("test-role")
            config = GuiConfig(workspace=str(ROOT), robot=str(ASSETS / "robots" / "relay-test.sql"),
                               role=role.name)
        with monkeypatch.context() as patch:
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


def test_role_selector_binds_agent_params_and_reset(app_factory, monkeypatch, tmp_path):
    from pymybot.roles import create_role

    monkeypatch.setenv("MYBOT_HOME", str(tmp_path / "home"))
    role = create_role("tech")
    config = GuiConfig(workspace=str(ROOT), robot=str(ASSETS / "robots" / "relay-test.sql"),
                       role=role.name, skills_dir="global-skills", mcp_config="global-mcp.json")
    gui, app = app_factory(config=config)
    assert app.role_box.currentData() == "tech"
    assert app.context_entries["skills_dir"].text() == str(role.skills_dir)
    assert not app.context_entries["skills_dir"].isEnabled()
    params = app._agent_params()
    assert "task" not in params
    assert params["role"] == "tech"
    assert params["workspaceDir"] == str(role.workspace_dir)
    assert "skillsDir" not in params and "mcpConfig" not in params

    client = attach_client(app)
    app.new_conversation()
    assert client.requests[-1] == ("agent.reset", {"clearHistory": True, "role": "tech"})


def test_autonomy_requires_a_role(app_factory):
    _, app = app_factory(config=GuiConfig(workspace=str(ROOT)))
    client = attach_client(app)
    app.start_button.click()
    assert client.requests == []
    assert "自主运行需要角色" in app.chat.toPlainText()


def test_delete_role_closes_the_conversation_and_removes_the_directory(ui, qapp, monkeypatch):
    from pymybot.roles import role_path

    _, app = ui
    client = attach_client(app)
    monkeypatch.setattr(app, "_message", lambda *args, **kwargs: True)
    root = role_path("test-role")
    assert root.is_dir() and app.delete_role_button.isEnabled()
    app.delete_role_button.click()
    assert client.requests[-1] == ("agent.reset", {})
    client.futures[-1].set_result({})
    assert qt_wait(qapp, lambda: not root.exists())
    assert app.cfg.role == ""
    assert not app.delete_role_button.isEnabled()


def test_new_role_falls_back_to_default_skills(app_factory, monkeypatch, tmp_path):
    gui, app = app_factory(config=GuiConfig(workspace=str(ROOT)))
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(gui.QInputDialog, "getText",
                        lambda *args, **kwargs: ("role-with-skills", True))
    assert not app.cfg.role
    app.new_role()
    assert app.cfg.role == "role-with-skills"
    assert (tmp_path / "home" / "roles" / "role-with-skills" / "workspace").is_dir()
    target = (tmp_path / "home" / "roles" / "role-with-skills" / "skills"
              / "hardware-controller" / "SKILL.md")
    assert target.is_file()


def test_window_builds_with_robot_context(ui):
    gui, app = ui
    assert isinstance(app, gui.QMainWindow)
    assert app.start_button.isEnabled() and not app.stop_button.isEnabled()
    assert "未启动" in app.status_state.text()
    assert [app.notebook.tabText(i) for i in range(2)] == ["对话", "日志"]


def color_contrast(first, second):
    def luminance(color):
        rgb = (color.redF(), color.greenF(), color.blueF())
        linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
        return sum(c * weight for c, weight in zip(linear, (0.2126, 0.7152, 0.0722)))

    values = sorted((luminance(first), luminance(second)))
    return (values[1] + 0.05) / (values[0] + 0.05)


@pytest.mark.parametrize("dark_system", [False, True])
def test_theme_is_readable_without_changing_system_palette(app_factory, qapp, dark_system):
    from PySide6.QtGui import QColor, QPalette

    original = qapp.palette()
    system = QPalette(original)
    if dark_system:
        for role in (QPalette.ColorRole.Window, QPalette.ColorRole.Base, QPalette.ColorRole.Button):
            system.setColor(role, QColor("#202020"))
        for role in (QPalette.ColorRole.WindowText, QPalette.ColorRole.Text, QPalette.ColorRole.ButtonText):
            system.setColor(role, QColor("#eeeeee"))
    qapp.setPalette(system)
    dialogs = []
    try:
        gui, app = app_factory()
        dialogs = [gui.SettingsDialog(app, app.cfg, str(ROOT)), gui.ToolDialog(app, "run", "{}")]
        for dialog in dialogs:
            dialog.show()
        qapp.processEvents()
        assert qapp.palette() == system
        assert app.font().pointSizeF() >= 10
        for widget in [app, *dialogs]:
            palette = widget.palette()
            assert palette.color(QPalette.ColorRole.Window).lightnessF() > 0.9
            assert color_contrast(palette.windowText().color(), palette.window().color()) >= 4.5
        for widget in (app.chat, app.log,
                       dialogs[0].entries["model"], dialogs[1].arguments):
            for group in (QPalette.ColorGroup.Active, QPalette.ColorGroup.Inactive):
                palette = widget.palette()
                assert color_contrast(palette.color(group, QPalette.ColorRole.Text),
                                      palette.color(group, QPalette.ColorRole.Base)) >= 4.5
                assert color_contrast(palette.color(group, QPalette.ColorRole.HighlightedText),
                                      palette.color(group, QPalette.ColorRole.Highlight)) >= 4.5
        for color in gui.PALETTE.values():
            assert color_contrast(QColor(color), app.chat.palette().base().color()) >= 4.5
        for label in app.findChildren(gui.QLabel):
            assert color_contrast(label.palette().windowText().color(), QColor("#f3f5f8")) >= 4.5
        for enabled in (True, False):
            app.start_button.setEnabled(enabled)
            app.stop_button.setEnabled(enabled)
            qapp.processEvents()
            for button in (app.start_button, app.stop_button):
                palette = button.palette()
                assert color_contrast(palette.buttonText().color(), palette.button().color()) >= 4.5
        assert dialogs[1].deny_button.isDefault()
        assert not dialogs[1].approve_button.autoDefault()
    finally:
        for dialog in dialogs:
            dialog.close()
            dialog.deleteLater()
        qapp.setPalette(original)


def test_chat_lines_and_deltas_form_one_transcript(ui):
    _, app = ui
    app._chat_line("你：你好", "user")
    app._chat_delta("第一段")
    app._chat_delta("接续")
    app._chat_line("→ list_hardware {}", "tool")
    app._chat_delta("结论")
    assert app.chat.toPlainText().strip().splitlines() == ["你：你好", "第一段接续", "→ list_hardware {}", "结论"]


def test_assistant_markdown_is_rendered_without_loading_html(ui):
    gui, app = ui
    app._chat_delta("**粗体**\n\n- 甲\n- 乙")
    app._chat_line("[完成]", "system")
    bold = app.chat.document().find("粗体")
    assert not bold.isNull()
    assert bold.charFormat().fontWeight() == gui.QFont.Weight.Bold
    assert "**粗体**" not in app.chat.toPlainText()
    assert not app.chat.openLinks() and not app.chat.openExternalLinks()

    text = '<img src="file:///etc/passwd"><b>not HTML</b> & entity'
    app._chat_delta(text)
    app._chat_line("[完成]", "system")
    assert text in app.chat.toPlainText()


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

    def save(dialog, test):
        assert isinstance(dialog, gui.SettingsDialog)
        dialog.entries["model"].setText("openai:test")
        dialog.entries["vars"].setPlainText("user=alice\npass=secret\nbad line")
        dialog.session_log.setChecked(False)
        test.mouseClick(dialog.buttons.button(gui.QDialogButtonBox.StandardButton.Save), gui.Qt.MouseButton.LeftButton)

    interact(save)
    app.open_settings()
    assert restarted == [True]
    assert app.cfg.model == "openai:test"
    assert app.cfg.vars == {"user": "alice", "pass": "secret"}
    assert "openai:test" in app.model_label.text()
    stored = json.loads((tmp_path / "settings.json").read_text())
    assert stored["session_log"] is False
    assert "vars" not in stored
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
    interact(lambda dialog, test: test.mouseClick(
        dialog.buttons.button(gui.QDialogButtonBox.StandardButton.Save), gui.Qt.MouseButton.LeftButton))
    app.open_settings()
    assert "已应用" in app.status_notice.text() and "写入失败" in app.status_notice.text()


def test_start_sends_agent_start_without_a_task(ui):
    _, app = ui
    client = attach_client(app)
    app.start_button.click()
    assert len(client.requests) == 1 and client.requests[0][0] == "agent.start"
    assert "task" not in client.requests[0][1]
    assert not app.start_button.isEnabled() and not app.new_button.isEnabled()
    assert app.stop_button.isEnabled()


def test_request_includes_current_paths_variables_and_budgets(ui):
    _, app = ui
    client = attach_client(app)
    app.context_entries["skills_dir"].setText("skills")
    app.cfg.vars = {"user": "alice"}
    app.start_button.click()
    params = client.requests[0][1]
    assert params["role"] == "test-role"
    assert "skillsDir" not in params and "mcpConfig" not in params
    assert "modulePaths" not in params
    assert params["vars"] == {"user": "alice"}
    assert params["robot"] == app._robot_path()
    assert params["allowShell"] is True
    assert params["timeout"] == app.cfg.timeout
    assert "maxRequests" not in params and "maxToolCalls" not in params


def test_abort_button_targets_the_server_not_the_agent_turn(ui, qapp):
    _, app = ui
    client = attach_client(app)
    app.start_button.click()
    app.abort_button.click()

    assert client.requests[-1] == ("abort", {})
    client.futures[-1].set_result({"state": "Aborted", "safe_failures": []})
    assert qt_wait(qapp, lambda: "急停完成" in app.status_notice.text())


def test_start_without_a_server_queues_start(ui, monkeypatch):
    _, app = ui
    started = []
    monkeypatch.setattr(app, "_start_server", lambda: started.append(True))
    app.start_autonomy()
    assert app.pending_start is True and started == [True]
    app.stop_autonomy()
    assert app.pending_start is False


@pytest.mark.parametrize("cancel", [False, True])
def test_startup_sends_only_the_queued_start(ui, monkeypatch, cancel):
    _, app = ui
    monkeypatch.setattr(app, "_start_server", lambda: None)
    app.start_autonomy()
    assert app.pending_start is True
    if cancel:
        app.stop_autonomy()
    client = FakeClient()
    app._server_started(app.generation, (client, {"agent": True, "protocol": 1}), None)
    assert app.pending_start is False
    assert len(client.requests) == (0 if cancel else 1)
    if not cancel:
        assert client.requests[0][0] == "agent.start"
        assert "task" not in client.requests[0][1]


def test_stop_and_reset_native_buttons(ui, qapp):
    _, app = ui
    client = attach_client(app)
    app.start_button.click()
    app.stop_button.click()
    assert [entry[0] for entry in client.requests] == ["agent.start", "agent.stop"]
    client.futures[0].set_result({"state": "running"})
    client.futures[1].set_result({"state": "stopped", "running": False})
    assert qt_wait(qapp, lambda: not app.busy)
    assert "[已停止]" in app.chat.toPlainText()
    app.new_button.click()
    assert client.requests[-1] == ("agent.reset", {"clearHistory": True, "role": "test-role"})
    client.futures[-1].set_result({})
    assert qt_wait(qapp, lambda: "新对话，硬件已释放" in app.chat.toPlainText())
    transcript = app.chat.toPlainText()
    assert "hello" not in transcript and "[已停止]" not in transcript


def test_new_conversation_queues_reset_until_server_is_ready(ui, qapp, monkeypatch):
    _, app = ui
    monkeypatch.setattr(app, "_start_server", lambda: None)
    app._chat_line("旧问题", "user")
    app.pending_start = True
    app.new_button.click()
    assert app.pending_reset is True
    client = FakeClient()
    app._server_started(app.generation, (client, {"agent": True, "protocol": 1}), None)
    assert app.pending_reset is False and app.pending_start is False
    assert client.requests[-1] == ("agent.reset", {"clearHistory": True, "role": "test-role"})
    client.futures[-1].set_result({})
    assert qt_wait(qapp, lambda: "新对话，硬件已释放" in app.chat.toPlainText())
    assert "旧问题" not in app.chat.toPlainText()


def test_stale_generations_and_reused_turn_ids_are_ignored(ui):
    _, app = ui
    attach_client(app)
    app.generation = 5
    app.run_id = 1
    app._set_busy(True)
    app._on_notify(4, "agent.event", {"id": 1, "event": {"type": "text_delta", "text": "stale"}})
    app._on_request(4, "s1", "confirm", {})
    app._start_done(4, 1, {"state": "running"}, None)
    app._on_reset(4, None)
    app._on_serve_exit(4, 1)
    assert app.busy and app.run_id == 1 and app.chat.toPlainText() == ""
    app._on_notify(5, "agent.event", {"id": 1, "event": {"type": "text_delta", "text": "current"}})
    app._start_done(5, 1, {"state": "running"}, None)
    assert app.chat.toPlainText().startswith("current\n")
    assert "自主循环运行中" in app.chat.toPlainText() and app.busy


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
    assert not app.isVisible()
    # Closing must not wait for the initialize request's five-second guard;
    # leave headroom for scheduling on loaded CI workers.
    assert time.monotonic() - start < 4
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


def test_workspace_and_directory_choosers(app_factory, monkeypatch, tmp_path):
    gui, app = app_factory(config=GuiConfig(workspace=str(ROOT)))
    restarted = []
    monkeypatch.setattr(app, "_restart_server", lambda: restarted.append(True))
    monkeypatch.setattr(gui.QFileDialog, "getExistingDirectory", lambda *args: str(tmp_path))
    app.pick_workspace()
    assert app.cfg.workspace == str(tmp_path) and app.cfg.robot == ""
    assert restarted == [True]
    monkeypatch.setattr(gui.QFileDialog, "getExistingDirectory", lambda *args: "")
    app.pick_workspace()
    assert app.cfg.robot == "" and restarted == [True]


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
    monkeypatch.setenv("MYBOT_GUI_SPLASH", "0")
    monkeypatch.setattr(gui, "config_home", lambda: tmp_path)

    def close_window():
        for window in qapp.topLevelWidgets():
            if isinstance(window, gui.App) and window.isVisible():
                window.close()

    gui.QTimer.singleShot(20, close_window)
    assert gui.run_gui(SimpleNamespace(workspace_dir=str(tmp_path))) == {"closed": True}


# -- management console -----------------------------------------------------
def test_sessions_args_builds_safe_commands():
    assert sessions_args() == ["-m", "pymybot", "sessions"]
    assert sessions_args(delete=["a"], dry_run=True) == [
        "-m", "pymybot", "sessions", "--delete=a", "--dry-run"]
    assert sessions_args(prune=True, keep=3, older_than=7, yes=True) == [
        "-m", "pymybot", "sessions", "--prune", "--keep=3", "--older-than=7", "--yes"]
    for kwargs in ({"prune": True, "delete": ["a"], "yes": True},
                   {"delete": ["a"], "dry_run": True, "yes": True},
                   {"delete": ["a"]},
                   {"delete": [""], "yes": True}):
        with pytest.raises(ValueError):
            sessions_args(**kwargs)


def test_settings_cover_backend_budgets(ui):
    gui, app = ui
    dialog = gui.SettingsDialog(app, app.cfg, app.cfg.workspace, "")
    try:
        assert dialog.entries["mcp_config"].text() == app.cfg.mcp_config
        assert dialog.history_bytes.value() == app.cfg.max_history_bytes // 1024
        dialog.history_bytes.setValue(4096)
        dialog.max_context_enabled.setChecked(True)
        dialog.max_context_tokens.setValue(32768)
        dialog.context_reserve_tokens.setValue(1024)
        dialog._save()
        assert dialog.values["max_history_bytes"] == 4096 * 1024
        assert dialog.values["max_context_tokens"] == 32768
        assert dialog.values["context_reserve_tokens"] == 1024
    finally:
        dialog.close()


def test_start_enables_all_tools_without_approval(ui):
    gui, app = ui
    client = attach_client(app)
    app.cfg.mcp_config = str(ROOT / "mcp.json")
    app.context_entries["mcp_config"].setText(str(ROOT / "mcp.json"))
    app.cfg.max_context_tokens = 32768
    app.cfg.context_reserve_tokens = 1024
    app.start_button.click()
    method, params = client.requests[-1]
    assert method == "agent.start"
    assert "task" not in params
    assert params["workspaceDir"] == app._workspace_root()
    assert params["allowFileWrites"] is True
    assert params["enableShell"] is True
    assert params["allowMcpTools"] is True
    assert params["enableWeb"] is True and params["allowWeb"] is True
    assert params["allowActions"] is False and params["allowHardware"] is True
    assert params["maxHistoryBytes"] == app.cfg.max_history_bytes
    assert params["maxContextTokens"] == 32768
    assert params["contextReserveTokens"] == 1024


def test_clear_chat_requires_confirmation(ui, interact):
    gui, app = ui
    app._chat_line("要清空的内容", "user")

    def confirm(dialog, test):
        assert isinstance(dialog, gui.QMessageBox)
        test.mouseClick(dialog.button(gui.QMessageBox.StandardButton.Ok),
                        gui.Qt.MouseButton.LeftButton)

    interact(confirm)
    app.clear_chat()
    assert app.chat.toPlainText() == ""


def test_resource_panel_previews_cached_scripts_and_skills(qapp, tmp_path):
    from pymybot.gui.dialogs import ResourcePanel

    scripts = tmp_path / "scripts"
    scripts.mkdir()
    action = scripts / "demo.mt"
    action.write_text("@Action\nrelay0.test;\n1;\n@\n", encoding="utf-8")
    skill = tmp_path / "skills" / "demo"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text(
        "---\nname: demo\ndescription: demo skill\n---\n# 标题\n正文\n", encoding="utf-8")

    panel = ResourcePanel()
    try:
        panel.set_roots(scripts, tmp_path / "skills")
        panel.reload()
        assert panel.tree.topLevelItemCount() >= 2
        found = []
        for group_index in range(panel.tree.topLevelItemCount()):
            group = panel.tree.topLevelItem(group_index)
            for child_index in range(group.childCount()):
                found.append(group.child(child_index))
        script_item = next(item for item in found if item.text(0) == "demo.mt")
        panel.tree.setCurrentItem(script_item)
        panel._on_select()
        assert panel.preview.currentWidget() is panel.code
        assert "@Action" in panel.code.toPlainText()
        panel.index.read(panel._selected())
        mtime = Path(script_item.toolTip(0)).stat().st_mtime
        assert panel.index._cache[str(script_item.toolTip(0))][0] == mtime

        panel.filter.setText("demo.mt")
        assert not script_item.isHidden()
        panel.filter.setText("no-such-resource")
        assert script_item.isHidden()
    finally:
        panel.deleteLater()


def test_mcp_dialog_validates_hides_secrets_and_saves(qapp, tmp_path):
    from pymybot.gui.dialogs import McpConfigDialog

    path = tmp_path / "mcp.json"
    path.write_text(json.dumps({"mcpServers": {"demo": {
        "command": "python", "args": ["-m", "demo"], "env": {"TOKEN": "s3cret"}}}}),
        encoding="utf-8")
    dialog = McpConfigDialog(None, str(path), base_dir=str(tmp_path))
    try:
        assert dialog.table.rowCount() == 1
        assert dialog.table.item(0, 3).text() == "TOKEN"
        assert "s3cret" not in dialog.status.text() and "校验通过" in dialog.status.text()
        dialog.editor.setPlainText('{"mcpServers": {"bad name!": {"command": "python"}}}')
        assert dialog.validate() is None and "校验失败" in dialog.status.text()
        dialog.editor.setPlainText(json.dumps({"mcpServers": {"x": {
            "command": "python", "args": []}}}))
        dialog.save()
        assert dialog.saved_path == str(path)
        assert json.loads(path.read_text(encoding="utf-8"))["mcpServers"]["x"]["command"] == "python"
    finally:
        dialog.deleteLater()


def _fake_session(root, name, robot, started):
    directory = root / name
    directory.mkdir(parents=True)
    (directory / "meta.json").write_text(json.dumps({
        "started_at": started, "robot": robot, "model": "openai:test", "mode": "serve",
        "pid": 0, "version": "0.3.1"}), encoding="utf-8")
    (directory / "transcript.jsonl").write_text(
        '{"type":"session_start"}\n{"type":"session_end"}\n', encoding="utf-8")
    return directory


def test_sessions_dialog_lists_filters_deletes_and_prunes(qapp, tmp_path):
    from pymybot.gui.dialogs import SessionsDialog

    root = tmp_path / "sessions"
    first = _fake_session(root, "20261028-090000-12345678", "robots/a.sql", "2026-10-28T09:00:00")
    second = _fake_session(root, "20261029-120000-abcdef12", "robots/b.sql", "2026-10-29T12:00:00")
    dialog = SessionsDialog(None, root=root, confirm=lambda *_: True)
    try:
        assert dialog.table.rowCount() == 2
        dialog.filter.setText("b.sql")
        assert dialog.table.isRowHidden(0) is True or dialog.table.isRowHidden(1) is True
        dialog.filter.clear()
        dialog.table.selectRow(0)
        dialog.delete()
        assert len(list(root.iterdir())) == 1
        dialog.keep.setValue(1)
        dialog.prune(True)
        assert "预览" in dialog.status.text()
        dialog.prune(False)
        assert "没有可清理" in dialog.status.text()
    finally:
        dialog.deleteLater()


def test_doctor_dialog_renders_injected_payload(qapp):
    from pymybot.gui.dialogs import DoctorDialog

    payload = {"version": "0.3.1", "python": "3.14", "platform": "linux", "healthy": True,
               "checks": [{"name": "mcp", "label": "MCP", "status": "ok", "version": "1.30"}]}
    dialog = DoctorDialog(None, doctor=lambda: payload)
    try:
        assert dialog.table.rowCount() == 1
        assert "健康" in dialog.summary.text()
        assert dialog.table.item(0, 1).text() == "ok"
    finally:
        dialog.deleteLater()


def test_command_dialog_builds_argv_and_renders_contract(qapp, tmp_path):
    from pymybot.gui.dialogs import CommandDialog

    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "a.mt").write_text("@Action\n@\n", encoding="utf-8")
    dialog = CommandDialog(None, python=sys.executable, cwd=str(tmp_path),
                           robot=str(tmp_path / "robot.sql"),
                           scripts_dir=str(scripts), timeout=30)
    try:
        dialog.command.setCurrentIndex(dialog.command.findData("run"))
        dialog.script.setCurrentText("a.mt")
        dialog.timeout.setValue(5)
        argv = dialog.build_argv()
        assert argv[:3] == ["-m", "pymybot", "run"]
        assert f"--robot={tmp_path / 'robot.sql'}" in argv
        assert "--input=a.mt" in argv and "--timeout=5.0" in argv

        dialog._done({"code": 0, "json": {"ok": True, "command": "run", "outputs": [1]},
                      "duration_ms": 12})
        assert "outputs" in dialog.output.toPlainText()
        assert "退出码 0" in dialog.status.text()

        dialog.command.setCurrentIndex(dialog.command.findData("doctor"))
        assert dialog.build_argv() == ["-m", "pymybot", "doctor"]

        calls = []
        dialog.command.setCurrentIndex(dialog.command.findData("sample"))
        dialog.variable.setText("v0")
        dialog.hardware.setChecked(True)
        dialog.runner = lambda argv, cwd: calls.append(argv) or {"code": 0, "json": {"ok": True}}
        dialog.confirm = lambda title, text: False
        dialog.run()
        assert calls == [] and dialog.run_button.isEnabled()

        dialog.command.setCurrentIndex(dialog.command.findData("sample"))
        dialog.hardware.setChecked(False)
        dialog.runner = lambda argv, cwd: (calls.append(argv) or
                                          {"code": 0, "json": {"ok": True}, "duration_ms": 1})
        dialog.run()
        for _ in range(100):
            qapp.processEvents()
            if calls:
                break
        assert calls and "--name=v0" in calls[0]
    finally:
        dialog.deleteLater()


# -- entry screen and branding ---------------------------------------------
def test_logo_renders_from_svg(qapp):
    from pymybot.gui.branding import logo_icon, logo_pixmap

    pixmap = logo_pixmap(64)
    assert not pixmap.isNull() and pixmap.width() == 64
    assert not logo_icon().isNull()


def test_splash_shows_real_status_and_waits_for_entry(qapp):
    from pymybot.gui.splash import SplashScreen

    events = []
    splash = SplashScreen(lambda: ("初始化：启动中", "提示文字"))
    splash.entered.connect(lambda: events.append("entered"))
    splash.cancelled.connect(lambda: events.append("cancelled"))
    try:
        assert not splash.logo.pixmap().isNull()
        assert "启动中" in splash.status.text()
        splash.refresh_status()
        assert splash.hint.text() == "提示文字"
        splash.enter()
        splash.enter()
        assert events == ["entered"]
    finally:
        splash.close()

    cancelled = []
    splash = SplashScreen()
    splash.cancelled.connect(lambda: cancelled.append(True))
    try:
        splash.close()
        assert cancelled == [True]
    finally:
        splash.deleteLater()


def test_splash_can_be_disabled(monkeypatch):
    from types import SimpleNamespace

    from pymybot.gui import app as gui_app

    monkeypatch.delenv("MYBOT_GUI_SPLASH", raising=False)
    assert gui_app._splash_enabled(SimpleNamespace()) is True
    assert gui_app._splash_enabled(SimpleNamespace(no_splash=True)) is False
    monkeypatch.setenv("MYBOT_GUI_SPLASH", "0")
    assert gui_app._splash_enabled(SimpleNamespace()) is False


def test_load_role_history_populates_chat(ui):
    from pymybot.roles import role_path, write_history

    _, app = ui
    role_dir = role_path(app.cfg.role)
    turns = [
        [{"type": "human", "data": {"content": "你好"}},
         {"type": "ai", "data": {"content": "你好！有什么可以帮你的？"}}],
        [{"type": "human", "data": {"content": "查看硬件"}},
         {"type": "ai", "data": {"content": "好的，正在列出硬件。"}}],
    ]
    write_history(role_dir / "history.json", turns)
    app._load_role_history()
    text = app.chat.toPlainText()
    assert "你：你好" in text
    assert "你好！有什么可以帮你的？" in text
    assert "你：查看硬件" in text
    assert "好的，正在列出硬件。" in text


def test_load_role_history_shows_summary_notice(ui):
    from pymybot.roles import role_path, write_history

    _, app = ui
    role_dir = role_path(app.cfg.role)
    turns = [
        [{"type": "human", "data": {"content": "最近一轮"}},
         {"type": "ai", "data": {"content": "最近的回复"}}],
    ]
    write_history(role_dir / "history.json", turns,
                  cold="[早期摘要]", warm=["[轮次1]", "[轮次2]"])
    app._load_role_history()
    text = app.chat.toPlainText()
    assert "[之前有 2 轮以上的对话已压缩为摘要]" in text
    assert "你：最近一轮" in text


def test_load_role_history_warm_only_notice(ui):
    from pymybot.roles import role_path, write_history

    _, app = ui
    role_dir = role_path(app.cfg.role)
    write_history(role_dir / "history.json", [], warm=["[轮次1]", "[轮次2]", "[轮次3]"])
    app._load_role_history()
    text = app.chat.toPlainText()
    assert "[之前有 3 轮对话已压缩为摘要]" in text


def test_load_role_history_empty_does_not_alter_chat(ui):
    _, app = ui
    app._chat_line("[已有内容]", "system")
    before = app.chat.toPlainText()
    app._load_role_history()
    assert app.chat.toPlainText() == before


def test_load_role_history_no_role_is_noop(ui):
    _, app = ui
    app.cfg.role = ""
    app._chat_line("[已有内容]", "system")
    before = app.chat.toPlainText()
    app._load_role_history()
    assert app.chat.toPlainText() == before


def test_load_role_history_renders_markdown(ui):
    from pymybot.roles import role_path, write_history

    gui, app = ui
    role_dir = role_path(app.cfg.role)
    turns = [
        [{"type": "human", "data": {"content": "格式测试"}},
         {"type": "ai", "data": {"content": "**粗体**回复"}}],
    ]
    write_history(role_dir / "history.json", turns)
    app._load_role_history()
    bold = app.chat.document().find("粗体")
    assert not bold.isNull()
    assert bold.charFormat().fontWeight() == gui.QFont.Weight.Bold


def test_role_switch_loads_new_history(ui):
    from pymybot.roles import create_role, delete_role, role_path, write_history

    _, app = ui
    other = create_role("history-other")
    try:
        turns_a = [[{"type": "human", "data": {"content": "角色A"}},
                     {"type": "ai", "data": {"content": "A的回复"}}]]
        turns_b = [[{"type": "human", "data": {"content": "角色B"}},
                     {"type": "ai", "data": {"content": "B的回复"}}]]
        write_history(role_path(app.cfg.role) / "history.json", turns_a)
        write_history(role_path("history-other") / "history.json", turns_b)

        app._load_role_history()
        assert "你：角色A" in app.chat.toPlainText()

        app._load_role_list()
        idx = app.role_box.findData("history-other")
        assert idx >= 0
        app.role_box.setCurrentIndex(idx)
        app.on_role_changed()
        text = app.chat.toPlainText()
        assert "你：角色B" in text
        assert "角色A" not in text
    finally:
        delete_role("history-other")


def test_start_skips_a_missing_structure_file(ui):
    _, app = ui
    client = attach_client(app)
    app.cfg.robot = "/nonexistent/robot.sql"
    app.start_button.click()
    assert client.requests[-1][0] == "agent.start"
    assert "robot" not in client.requests[-1][1]
    assert "结构文件不存在" in app.status_notice.text()
