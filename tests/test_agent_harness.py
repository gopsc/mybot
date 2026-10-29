"""Agent-harness phase 1: layered prompts and bounded project context."""
from __future__ import annotations

import asyncio
import os
import threading

import pytest

from pymybot.agent_context import ProjectContext
from pymybot.agent_prompt import (MAX_OPERATOR_PROMPT, build_instructions,
                                  read_operator_prompt)
from pymybot.security import SecurityError


def test_prompt_layers_keep_priority_order_and_stable_digest():
    result = build_instructions("SOUL-RULE", operator="operator rule",
                                project="project facts", guide="guide text")
    assert result.text.startswith("[SOUL]\nSOUL-RULE")
    assert (result.text.index("[OPERATOR]") < result.text.index("[PROJECT CONTEXT]")
            < result.text.index("[GUIDE]"))
    assert result.sections == ("SOUL", "OPERATOR", "PROJECT CONTEXT", "GUIDE")
    assert result.truncated == ()
    assert len(result.digest) == 16
    assert result.text == build_instructions("SOUL-RULE", operator="operator rule",
                                             project="project facts", guide="guide text").text


def test_prompt_budget_truncates_optional_layers_but_never_soul():
    result = build_instructions("S", operator="O" * 200, project="P" * 200,
                                guide="G" * 200, budget=120)
    assert "[SOUL]\nS" in result.text
    assert len(result.text.encode("utf-8")) <= 120
    assert result.truncated
    assert result.sections[0] == "SOUL"


def test_prompt_budget_must_fit_soul():
    with pytest.raises(ValueError):
        build_instructions("S" * 200, budget=20)


def test_operator_prompt_reads_utf8(tmp_path):
    path = tmp_path / "profile.md"
    path.write_text("  中文约束  \n", encoding="utf-8")
    assert read_operator_prompt(str(path)) == "中文约束"


def test_operator_prompt_rejects_invalid_files(tmp_path):
    with pytest.raises(SecurityError):
        read_operator_prompt(str(tmp_path / "missing.md"))
    with pytest.raises(SecurityError):
        read_operator_prompt(str(tmp_path))
    nul = tmp_path / "nul.md"
    nul.write_bytes(b"a\x00b")
    with pytest.raises(SecurityError):
        read_operator_prompt(str(nul))
    binary = tmp_path / "binary.md"
    binary.write_bytes(b"\xff\xfe")
    with pytest.raises(SecurityError):
        read_operator_prompt(str(binary))
    big = tmp_path / "big.md"
    big.write_bytes(b"x" * (MAX_OPERATOR_PROMPT + 1))
    with pytest.raises(SecurityError):
        read_operator_prompt(str(big))


def test_project_context_lists_inventory_and_caches(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    (workspace / "docs").mkdir()
    (workspace / "notes.txt").write_text("hello", encoding="utf-8")
    robots = tmp_path / "robots"
    robots.mkdir()
    robot = robots / "relay-test.sql"
    robot.write_text("CREATE TABLE Relay (name String);", encoding="utf-8")
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "relay-test.mt").write_text("x", encoding="utf-8")
    modules = tmp_path / "modules"
    modules.mkdir()
    (modules / "Relay.lua").write_text("return {}", encoding="utf-8")

    context = ProjectContext(workspace=workspace, robot=robot, scripts=scripts,
                             module_paths=[modules], budget=4096)
    first = context.render()
    assert "Workspace top level:" in first.text
    assert "- dir: docs" in first.text
    assert "relay-test.sql" in first.text
    assert "relay-test.mt" in first.text
    assert "Relay.lua" in first.text
    assert first.digest and not first.truncated
    assert context.render() is first  # mtime cache

    os.utime(scripts, ns=(1, 1))
    (scripts / "second.mt").write_text("x", encoding="utf-8")
    os.utime(scripts, ns=(2, 2))
    assert "second.mt" in context.render().text


def test_project_context_budget_zero_is_empty(tmp_path):
    (tmp_path / "a.txt").write_text("x", encoding="utf-8")
    result = ProjectContext(workspace=tmp_path, budget=0).render()
    assert result.text == "" and result.entries == 0


class _Executor:
    def __init__(self, robot, scripts):
        self.robot_path = robot
        self.scripts_dir = scripts
        self.workspace_dir = None
        self.skills = None
        self.module_paths = ()
        self.stop_event = threading.Event()
        self.records = []

    async def start(self, *, deadline=None):
        return {"ok": True}

    async def call(self, name, arguments, *, timeout):
        return {"ok": True, "executed": False, "state": "completed", "data": {}}

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        return None


def test_agent_session_injects_operator_prompt_and_context(tmp_path):
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.models.function import FunctionModel
    from pydantic_ai.messages import ModelResponse, TextPart

    from pymybot.agent import AgentConfig, AgentSession

    profile = tmp_path / "profile.md"
    profile.write_text("PROFILE-CONSTRAINT", encoding="utf-8")
    robot = tmp_path / "relay-test.sql"
    robot.write_text("CREATE TABLE Relay (name String);", encoding="utf-8")
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "relay-test.mt").write_text("x", encoding="utf-8")
    seen = {}

    async def respond(messages, info):
        seen["instructions"] = info.instructions
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(_Executor(robot, scripts), FunctionModel(respond),
                               AgentConfig(prompt_file=str(profile)))
        try:
            return await session.ask("hi")
        finally:
            await session.close()

    assert asyncio.run(scenario())["output"] == "ok"
    instructions = str(seen["instructions"])
    assert "[OPERATOR]\nPROFILE-CONSTRAINT" in instructions
    assert "relay-test.mt" in instructions
    assert "relay-test.sql" in instructions


def test_cli_accepts_prompt_and_context_flags(tmp_path):
    from pymybot.cli import parse_args

    profile = tmp_path / "profile.md"
    args = parse_args(["agent", "--robot", "x.sql", "--task", "hi",
                       "--prompt-file", str(profile), "--context-bytes", "0"])
    assert args.prompt_file == str(profile)
    assert args.context_bytes == 0
    gui = parse_args(["gui", "--prompt-file", str(profile), "--context-bytes", "1024"])
    assert gui.prompt_file == str(profile) and gui.context_bytes == 1024


def test_gui_config_persists_prompt_and_context(tmp_path):
    from pymybot.gui.config import GuiConfig

    path = tmp_path / "settings.json"
    GuiConfig(prompt_file="profile.md", context_bytes=8 * 1024).store(path)
    loaded = GuiConfig.load(path)
    assert loaded.prompt_file == "profile.md"
    assert loaded.context_bytes == 8 * 1024
    assert GuiConfig(context_bytes=10 ** 9).sanitized().context_bytes == 4 * 1024
