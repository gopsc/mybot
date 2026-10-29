"""Offline evaluation matrix for the agent harness (no provider or network)."""
from __future__ import annotations

import asyncio
import threading

import pytest

from pymybot.agent_intent import classify_intent

pytest.importorskip("pydantic_ai")

from pydantic_ai.messages import ModelResponse, TextPart  # noqa: E402
from pydantic_ai.models.function import FunctionModel  # noqa: E402

from pymybot.agent import AgentConfig, AgentSession  # noqa: E402


class _Executor:
    def __init__(self, *, robot=None, scripts=None):
        self.stop_event = threading.Event()
        self.calls = []
        self.records = []
        self.robot_path = robot
        self.scripts_dir = scripts
        self.workspace_dir = None
        self.skills = None
        self.module_paths = ()

    async def start(self, *, deadline=None):
        return {"ok": True}

    async def call(self, name, arguments, *, timeout):
        self.calls.append((name, arguments))
        return {"ok": True, "executed": False, "state": "completed", "data": {}}

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        return None


async def _respond(messages, info):
    return ModelResponse(parts=[TextPart("done")])


def _model():
    return FunctionModel(_respond)


def _run(coro):
    return asyncio.run(coro)


def test_loop_guard_blocks_the_fourth_identical_call():
    executor = _Executor()

    async def scenario():
        session = AgentSession(executor, _model(), AgentConfig())
        try:
            results = [await session.dispatch("list_hardware", {}) for _ in range(4)]
            assert [item["ok"] for item in results] == [True, True, True, False]
            assert results[3]["state"] == "not_executed"
            assert "Identical tool call repeated" in results[3]["error"]
            assert len(executor.calls) == 3
        finally:
            await session.close()

    _run(scenario())


def test_loop_guard_resets_when_the_call_changes():
    executor = _Executor()

    async def scenario():
        session = AgentSession(executor, _model(), AgentConfig())
        try:
            for _ in range(3):
                assert (await session.dispatch("list_hardware", {}))["ok"]
            assert (await session.dispatch("list_action_scripts", {}))["ok"]
            assert (await session.dispatch("list_hardware", {}))["ok"]
            assert len(executor.calls) == 5
        finally:
            await session.close()

    _run(scenario())


def test_intent_matrix_allows_only_the_matching_tool_family():
    executor = _Executor()

    async def scenario():
        session = AgentSession(executor, _model(), AgentConfig(allow_actions=True))
        try:
            session.intent = classify_intent("列出硬件", "inspect")
            denied = await session.dispatch("run_action_script", {"script": "x.mt"})
            assert denied["state"] == "not_executed" and "outside the active intent" in denied["error"]
            assert executor.calls == []
            session.intent = classify_intent("运行自检", "control")
            allowed = await session.dispatch("run_action_script", {"script": "x.mt"})
            assert allowed["ok"] and executor.calls[-1][0] == "run_action_script"
        finally:
            await session.close()

    _run(scenario())


def test_prompt_and_project_context_reach_the_model(tmp_path):
    profile = tmp_path / "profile.md"
    profile.write_text("PROFILE-CONSTRAINT", encoding="utf-8")
    robot = tmp_path / "relay-test.sql"
    robot.write_text("CREATE TABLE Relay (name String);", encoding="utf-8")
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "relay-test.mt").write_text("x", encoding="utf-8")

    async def scenario():
        session = AgentSession(_Executor(robot=robot, scripts=scripts), _model(),
                               AgentConfig(prompt_file=str(profile)))
        try:
            return session
        finally:
            await session.close()

    session = _run(scenario())
    raw = (session.agent._instructions() if callable(session.agent._instructions)
           else session.agent._instructions)
    instructions = "\n".join(getattr(item, "instruction", str(item)) for item in raw)
    assert "[SOUL]" in instructions and "[OPERATOR]\nPROFILE-CONSTRAINT" in instructions
    assert "relay-test.mt" in instructions and "relay-test.sql" in instructions
