"""Dual-mode routing must work even when PydanticAI is not installed."""
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
    code = cli.main(list(map(str, args)))
    captured = capsys.readouterr()
    assert len(captured.out.splitlines()) == 1
    return code, json.loads(captured.out), captured.err


@pytest.fixture
def no_agent_import(monkeypatch):
    original = builtins.__import__
    def guarded(name, *args, **kwargs):
        if name == "agent" or name.startswith(("pydantic", "openai", "anthropic")):
            raise ModuleNotFoundError("blocked optional dependency", name="pydantic_ai")
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
    code, result, _ = invoke(capsys, "--robot", files[0], "--task", "list hardware", "--model", "openai:test")
    assert code == 1 and result["ok"] is False
    assert "pymybot[agent]" in result["error"]["message"]
    assert "--no-agent" in result["error"]["message"]


@pytest.mark.parametrize("extra", [
    ["--no-agent"], ["--no-agent", "--task", "hello"],
    ["--task", ""], ["--max-requests", "0"], ["--max-tool-calls", "0"],
    ["--timeout", "nan"], ["--var", "name=value"],
])
def test_invalid_mode_options_fail_before_optional_import(files, capsys, no_agent_import, extra):
    code, result, _ = invoke(capsys, "--robot", files[0], *extra)
    assert code == 2 and result["error"]["type"] == "UsageError"


def test_input_is_not_implicitly_a_model_task(files, capsys, no_agent_import):
    code, result, _ = invoke(capsys, "--robot", files[0], "--input", files[1])
    assert code == 2 and "--no-agent" in result["error"]["message"]


def test_non_tty_requires_task(files, capsys, monkeypatch, no_agent_import):
    monkeypatch.setattr(sys, "stdin", SimpleNamespace(isatty=lambda: False))
    code, result, _ = invoke(capsys, "--robot", files[0])
    assert code == 2 and "--task" in result["error"]["message"]


@pytest.mark.parametrize("prefix", [[], ["agent"]])
def test_default_and_explicit_agent_routing(files, capsys, monkeypatch, prefix):
    called = []
    async def run_cli_agent(args, stop):
        called.append(args)
        return {"mode": "agent", "output": "offline mock", "tool_events": []}
    monkeypatch.setitem(sys.modules, "pymybot.agent", SimpleNamespace(run_cli_agent=run_cli_agent))
    code, result, _ = invoke(capsys, *prefix, "--robot", files[0], "--task", "列出硬件",
                             "--model", "openai:test", "--read-var", "dev")
    assert code == 0 and result["mode"] == "agent" and result["output"] == "offline mock"
    assert called[0].read_var == ["dev"] and called[0].allow_hardware is False
    assert called[0].allow_actions is False


def test_repeated_camera_var_collects_every_name(files, capsys, monkeypatch):
    called = []
    async def run_cli_agent(args, stop):
        called.append(args)
        return {"mode": "agent", "output": "offline mock", "tool_events": []}
    monkeypatch.setitem(sys.modules, "pymybot.agent", SimpleNamespace(run_cli_agent=run_cli_agent))
    code, _, _ = invoke(capsys, "--robot", files[0], "--task", "看", "--model", "openai:test",
                        "--camera-var", "front", "--camera-var", "rear")
    assert code == 0 and called[0].camera_var == ["front", "rear"]


def test_camera_var_names_are_validated(files):
    with pytest.raises(ScriptError):
        cli.parse_args(["--robot", str(files[0]), "--task", "t", "--model", "openai:test",
                        "--camera-var", "bad name"])


def test_flag_like_task_text_not_removed(files):
    args = cli.parse_args(["--robot", str(files[0]), "--task=--no-agent"])
    assert args.command == "agent" and args.task == "--no-agent"


def test_agent_interrupt_has_exit_130(files, capsys, monkeypatch):
    async def run_cli_agent(args, stop):
        raise KeyboardInterrupt
    monkeypatch.setitem(sys.modules, "pymybot.agent", SimpleNamespace(run_cli_agent=run_cli_agent))
    code, result, _ = invoke(capsys, "--robot", files[0], "--task", "wait")
    assert code == 130 and result["ok"] is False
