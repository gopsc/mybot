"""Dual-mode routing must work even when LangGraph is not installed."""
import builtins
import json
import sys
from types import SimpleNamespace

import pytest

from pymybot import cli
from pymybot.errors import ScriptError


@pytest.fixture
def files(tmp_path):
    robot = tmp_path / "robot.sql"
    robot.write_text("CREATE TABLE dummy(name String); INSERT INTO dummy(name) VALUES('dev');", encoding="utf-8")
    script = tmp_path / "action.mt"
    script.write_text("@Action\ndev.echo;\n9;\n@\n", encoding="utf-8")
    return robot, script


def invoke(capsys, *args):
    code = cli.main(["--no-gui", *map(str, args)])
    captured = capsys.readouterr()
    assert len(captured.out.splitlines()) == 1
    return code, json.loads(captured.out), captured.err


@pytest.fixture
def no_agent_import(monkeypatch):
    original = builtins.__import__
    def guarded(name, *args, **kwargs):
        if name == "agent" or name == "agent_cli" or name.startswith(("langchain", "langgraph", "openai", "anthropic", "httpx2")):
            raise ModuleNotFoundError("blocked optional dependency", name="langgraph")
        return original(name, *args, **kwargs)
    monkeypatch.setattr(builtins, "__import__", guarded)


@pytest.mark.parametrize("prefix", [[], ["agent"]])
def test_no_agent_runs_without_model_dependencies(files, capsys, no_agent_import, monkeypatch, prefix):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("MYBOT_MODEL", "invalid:ignored")
    robot, script = files
    code, result, _ = invoke(capsys, *prefix, "--no-agent", "--robot", robot, "--input", script)
    assert code == 0 and result["command"] == "run"
    assert result["outputs"][0]["echo"] == 9


@pytest.mark.parametrize("prefix", [["hardware"], ["--no-agent", "hardware"], ["hardware", "--no-agent"]])
def test_existing_commands_always_bypass_agent(files, capsys, no_agent_import, prefix):
    code, result, _ = invoke(capsys, *prefix, "--robot", files[0])
    assert code == 0 and result["activated"] is False


def test_missing_optional_dependency_is_actionable_not_fallback(files, capsys, no_agent_import):
    code, result, _ = invoke(capsys, "--task", "list hardware", "--role", "test-role",
                             "--model", "openai:test")
    assert code == 1 and result["ok"] is False
    assert "pymybot[agent]" in result["error"]["message"]
    assert "--no-agent" in result["error"]["message"]


def test_agent_requires_a_role(files, capsys, no_agent_import):
    code, result, _ = invoke(capsys, "--task", "list hardware")
    assert code == 2 and result["error"]["type"] == "UsageError"
    assert "--role" in result["error"]["message"]
    assert "roles create" in result["error"]["message"]


@pytest.mark.parametrize("extra", [
    ["--no-agent"], ["--no-agent", "--task", "hello"],
    ["--task", ""], ["--max-requests", "0"], ["--max-tool-calls", "0"],
    ["--timeout", "nan"],
])
def test_invalid_mode_options_fail_before_optional_import(files, capsys, no_agent_import, extra):
    role = [] if "--no-agent" in extra else ["--role", "test-role"]
    code, result, _ = invoke(capsys, *role, *extra)
    assert code == 2 and result["error"]["type"] == "UsageError"


def test_agent_rejects_robot_and_structure_options(files):
    for extra in (["--robot", str(files[0])], ["--module-path", "modules"],
                  ["--var", "user=alice"], ["--var-env", "pass=PYMYBOT_TEST_PASS"]):
        with pytest.raises(cli.UsageError, match="no longer loads a structure"):
            cli.parse_args(["--no-gui", "--task", "t", "--role", "test-role", *extra])


def test_agent_accepts_context_token_budget(files, capsys, monkeypatch):
    called = []

    async def run_cli_agent(args, stop):
        called.append(args)
        return {"mode": "agent", "output": "offline mock", "tool_events": []}

    monkeypatch.setitem(sys.modules, "pymybot.agent_cli", SimpleNamespace(run_cli_agent=run_cli_agent))
    code, _, _ = invoke(capsys, "--task", "t", "--role", "test-role",
                        "--max-context-tokens", "32768", "--context-reserve-tokens", "1024")
    assert code == 0
    assert called[0].max_context_tokens == 32768 and called[0].context_reserve_tokens == 1024


def test_input_is_not_implicitly_a_model_task(files, capsys, no_agent_import):
    code, result, _ = invoke(capsys, "--input", files[1], "--role", "test-role")
    assert code == 2 and "--no-agent" in result["error"]["message"]


@pytest.mark.parametrize("prefix", [[], ["agent"]])
def test_default_and_explicit_agent_routing(files, capsys, monkeypatch, prefix):
    called = []
    async def run_cli_agent(args, stop):
        called.append(args)
        return {"mode": "agent", "output": "offline mock", "tool_events": []}
    monkeypatch.setitem(sys.modules, "pymybot.agent_cli", SimpleNamespace(run_cli_agent=run_cli_agent))
    code, result, _ = invoke(capsys, *prefix, "--task", "列出硬件",
                             "--role", "test-role", "--model", "openai:test")
    assert code == 0 and result["mode"] == "agent" and result["output"] == "offline mock"
    assert not hasattr(called[0], "allow_hardware")
    assert called[0].allow_actions is False


def test_flag_like_task_text_not_removed(files):
    args = cli.parse_args(["--no-gui", "--task=--no-agent", "--role", "test-role"])
    assert args.command == "agent" and args.task == "--no-agent"


@pytest.mark.parametrize("extra,message", [
    (["--no-agent", "--input", "a.mt", "--workspace-dir", "."], "--no-agent cannot"),
    (["--no-agent", "--input", "a.mt", "--enable-shell"], "--no-agent cannot"),
    (["--no-agent", "--input", "a.mt", "--allow-file-writes"], "--no-agent cannot"),
    (["--workspace-dir", "."], "--role owns its workspace"),
    (["--skills-dir", "skills"], "--role owns its skills"),
    (["--mcp-config", "mcp.json"], "--role owns its skills"),
])
def test_role_owns_workspace_skills_and_mcp(files, no_agent_import, extra, message):
    with pytest.raises(cli.UsageError, match=message):
        cli.parse_args(["--no-gui", "--task", "test", "--role", "test-role", *extra])


def test_role_workspace_enables_shell_and_file_writes(files):
    args = cli.parse_args(["--no-gui", "--task", "test", "--role", "test-role",
                           "--enable-shell", "--allow-file-writes"])
    assert args.role == "test-role" and args.workspace_dir is None
    assert args.enable_shell and args.allow_file_writes
    assert not args.allow_actions and not hasattr(args, "allow_hardware")
    defaults = cli.parse_args(["--no-gui", "--task", "test", "--role", "test-role",
                               "--allow-actions"])
    assert defaults.workspace_dir is None and not defaults.enable_shell
    assert not defaults.allow_file_writes


def test_agent_interrupt_has_exit_130(files, capsys, monkeypatch):
    async def run_cli_agent(args, stop):
        raise KeyboardInterrupt
    monkeypatch.setitem(sys.modules, "pymybot.agent_cli", SimpleNamespace(run_cli_agent=run_cli_agent))
    code, result, _ = invoke(capsys, "--task", "wait", "--role", "test-role")
    assert code == 130 and result["ok"] is False


def test_no_session_log_flag(files):
    args = cli.parse_args(["--no-gui", "--task", "t", "--role", "test-role",
                           "--no-session-log"])
    assert args.no_session_log is True
    default = cli.parse_args(["--no-gui", "--task", "t", "--role", "test-role"])
    assert default.no_session_log is False


def test_serve_can_disable_session_log():
    args = cli.parse_args(["serve", "--no-session-log"])
    assert args.command == "serve" and args.no_session_log is True
