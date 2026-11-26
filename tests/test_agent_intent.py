"""Agent-harness phase 2: deterministic intent routing and tool gating."""
from __future__ import annotations

import asyncio
import threading

import pytest

from pymybot.agent_intent import INTENTS, TOOLS_BY_INTENT, classify_intent

pytest.importorskip("pydantic_ai")

from pymybot.agent import AgentConfig, AgentConfigurationError, AgentSession  # noqa: E402


class _Executor:
    def __init__(self):
        self.stop_event = threading.Event()
        self.calls = []
        self.records = []

    async def start(self, *, deadline=None):
        return {"ok": True}

    async def call(self, name, arguments, *, timeout):
        self.calls.append((name, arguments))
        return {"ok": True, "executed": False, "state": "completed", "data": {}}

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        return None


@pytest.mark.parametrize("text,expected", [
    ("列出硬件和结构", "inspect"),
    ("运行继电器自检", "control"),
    ("修改 relay-test.mt 并补全注释", "author"),
    ("为什么报错", "diagnose"),
    ("你好", "chat"),
])
def test_chinese_intent_classification(text, expected):
    decision = classify_intent(text)
    assert decision.name == expected
    if expected == "chat":
        assert not decision.restricted
    else:
        assert decision.restricted and decision.confidence >= 0.55


def test_english_intent_classification():
    assert classify_intent("list the declared hardware").name == "inspect"
    assert classify_intent("run the relay self test").name == "control"
    assert classify_intent("fix the broken script").name == "author"
    assert classify_intent("why did the action fail").name == "diagnose"


def test_mixed_request_unions_tool_sets():
    decision = classify_intent("write a script and run it with shell")
    assert decision.name == "author"
    assert {"write_file", "edit_file", "run_action_script", "shell"} <= decision.tools
    assert decision.max_requests == 8 and decision.max_tool_calls == 20


def test_no_keywords_stays_unrestricted():
    decision = classify_intent("hello there")
    assert decision.name == "chat" and not decision.restricted
    assert decision.allows("shell") and decision.allows("write_file")


def test_operator_override_and_off():
    forced = classify_intent("hello", "control")
    assert forced.name == "control" and forced.confidence == 1.0
    assert forced.allows("run_action_script") and not forced.allows("write_file")
    disabled = classify_intent("run the robot", "off")
    assert disabled.name == "off" and not disabled.restricted
    assert disabled.allows("shell")


def test_agent_config_rejects_unknown_intent():
    with pytest.raises(AgentConfigurationError):
        AgentConfig(intent_mode="sometimes")


def test_dispatch_denies_tool_outside_intent():
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.messages import ModelResponse, TextPart
    from pydantic_ai.models.function import FunctionModel

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    executor = _Executor()

    async def scenario():
        session = AgentSession(executor, FunctionModel(respond), AgentConfig(intent_mode="inspect"),
                               workspace=True, enable_shell=True)
        try:
            session.intent = classify_intent("列出硬件", "inspect")
            result = await session.dispatch("run_action_script", {"script": "x.mt"})
            assert result["state"] == "not_executed" and not result["ok"]
            assert "outside the active intent" in result["error"]
            assert executor.calls == []
            return result
        finally:
            await session.close()

    assert asyncio.run(scenario())["executed"] is False


def test_agent_result_reports_intent():
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.messages import ModelResponse, TextPart
    from pydantic_ai.models.function import FunctionModel

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(_Executor(), FunctionModel(respond), AgentConfig())
        try:
            return await session.ask("列出硬件")
        finally:
            await session.close()

    result = asyncio.run(scenario())
    assert result["intent"]["name"] == "inspect"
    assert result["intent"]["restricted"] is True
    assert "list_hardware" in result["intent"]["allowed_tools"]


def test_cli_and_gui_config_expose_intent(tmp_path):
    from pymybot.cli import parse_args
    from pymybot.gui.config import GuiConfig

    args = parse_args(["agent", "--robot", "x.sql", "--task", "hi", "--intent", "control"])
    assert args.intent == "control"
    gui = parse_args(["gui", "--intent", "author"])
    assert gui.intent == "author"
    path = tmp_path / "settings.json"
    GuiConfig(intent_mode="diagnose").store(path)
    assert GuiConfig.load(path).intent_mode == "diagnose"
    assert GuiConfig(intent_mode="bogus").sanitized().intent_mode == "auto"
    assert set(INTENTS) == {"chat", "inspect", "control", "author", "diagnose"}
