"""Tests for tiered memory compression: summarizer, transitions, context builder."""
from __future__ import annotations

import asyncio
import json

import pytest

pytest.importorskip("langchain")

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage

from pymybot.agent import AgentConfig, AgentSession
from pymybot.agent_memory import aggregate_cold, summarize_turn


class _Executor:
    def __init__(self):
        self.stop_event = __import__("threading").Event()

    async def start(self, *, deadline=None):
        return {"ok": True}

    async def call(self, name, arguments, *, timeout):
        return {"ok": True, "executed": False, "state": "completed", "data": {}}

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        pass


class _FakeModel:
    def __init__(self, responses):
        self._responses = list(responses)
        self._index = 0

    async def __call__(self, messages, **kwargs):
        from pydantic_ai.messages import ModelResponse, TextPart
        resp = self._responses[self._index]
        self._index += 1
        return resp

    async def close(self):
        pass


def test_summarize_turn_extracts_key_info():
    turn = [
        HumanMessage(content="列出所有硬件设备"),
        AIMessage(content="", tool_calls=[{"name": "list_hardware", "args": {}, "id": "call-1"}]),
        ToolMessage(content='{"devices": ["relay", "sensor"]}', tool_call_id="call-1"),
        AIMessage(content="找到2个设备：relay和sensor"),
    ]
    summary = summarize_turn(turn, turn_index=1)
    assert "Turn 1" in summary
    assert "列出所有硬件设备" in summary
    assert "list_hardware" in summary
    assert "✓" in summary
    assert "找到2个设备" in summary


def test_summarize_turn_handles_tool_failure():
    turn = [
        HumanMessage(content="run test"),
        AIMessage(content="", tool_calls=[{"name": "shell", "args": {"cmd": "fail"}, "id": "c1"}]),
        ToolMessage(content='{"ok": false, "error": "command failed"}', tool_call_id="c1"),
        AIMessage(content="命令执行失败"),
    ]
    summary = summarize_turn(turn)
    assert "shell(✗)" in summary


def test_summarize_turn_truncates_long_text():
    long_prompt = "x" * 200
    turn = [HumanMessage(content=long_prompt), AIMessage(content="ok")]
    summary = summarize_turn(turn)
    assert "…" in summary
    assert len(summary) < 200


def test_aggregate_cold_merges_summaries():
    summaries = [
        "[Turn 1] 用户: list. 工具: shell(✓). 回复: done",
        "[Turn 2] 用户: run. 工具: list_hardware(✓). 回复: ok",
    ]
    cold = aggregate_cold(summaries, turn_count=2)
    assert "历史 2 轮" in cold
    assert "shell(✓)" in cold
    assert "list_hardware(✓)" in cold


def test_aggregate_cold_empty_returns_none():
    assert aggregate_cold([], turn_count=0) is None
    assert aggregate_cold([]) is None


def test_tier_transition_hot_to_warm():
    from agent_fakes import FunctionModel, ModelResponse, TextPart

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(_Executor(), FunctionModel(respond),
                               AgentConfig(hot_turns=2, warm_turns=5, auto_stats=False, intent_mode="off"))
        try:
            for i in range(4):
                await session.ask(f"prompt {i}")
            assert len(session.turns) == 2
            assert len(session._warm_summaries) == 2
            assert session._cold_summary is None
        finally:
            await session.close()

    asyncio.run(scenario())


def test_tier_transition_warm_to_cold():
    from agent_fakes import FunctionModel, ModelResponse, TextPart

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(_Executor(), FunctionModel(respond),
                               AgentConfig(hot_turns=1, warm_turns=2, auto_stats=False, intent_mode="off"))
        try:
            for i in range(5):
                await session.ask(f"prompt {i}")
            assert len(session.turns) == 1
            assert len(session._warm_summaries) == 2
            assert session._cold_summary is not None
            assert "历史" in session._cold_summary
        finally:
            await session.close()

    asyncio.run(scenario())


def test_build_context_messages_includes_tiers():
    from agent_fakes import FunctionModel, ModelResponse, TextPart

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(_Executor(), FunctionModel(respond),
                               AgentConfig(hot_turns=1, warm_turns=2, auto_stats=False, intent_mode="off"))
        try:
            for i in range(3):
                await session.ask(f"prompt {i}")
            messages = session._build_context_messages("current")
            system_msgs = [m for m in messages if isinstance(m, SystemMessage)]
            assert len(system_msgs) >= 1
            human_msgs = [m for m in messages if isinstance(m, HumanMessage)]
            assert human_msgs[-1].content == "current"
        finally:
            await session.close()

    asyncio.run(scenario())


def test_trim_messages_drops_cold_first():
    from agent_fakes import FunctionModel, ModelResponse, TextPart

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(_Executor(), FunctionModel(respond),
                               AgentConfig(hot_turns=1, warm_turns=1, auto_stats=False, intent_mode="off"))
        try:
            for i in range(5):
                await session.ask(f"prompt {i}")
            assert session._cold_summary is not None
            messages = session._build_context_messages("new")
            cold_index = next((i for i, m in enumerate(messages)
                               if isinstance(m, SystemMessage) and "[历史" in (m.content or "")), None)
            assert cold_index is not None and cold_index == 0
        finally:
            await session.close()

    asyncio.run(scenario())


def test_config_validates_hot_warm_turns():
    with pytest.raises(Exception):
        AgentConfig(hot_turns=0)
    with pytest.raises(Exception):
        AgentConfig(hot_turns=100)
    with pytest.raises(Exception):
        AgentConfig(warm_turns=-1)
    with pytest.raises(Exception):
        AgentConfig(warm_turns=500)
    config = AgentConfig(hot_turns=5, warm_turns=20)
    assert config.hot_turns == 5
    assert config.warm_turns == 20


def test_history_v3_save_and_load(tmp_path):
    from pymybot.roles import create_role, read_history, write_history

    role = create_role("tier-test", root=tmp_path / "roles")
    turns = [[{"type": "human", "data": {"content": "hi"}}]]
    write_history(role.history_file, turns, cold="[历史 5 轮]", warm=["[Turn 1] summary"])
    loaded_turns, cold, warm = read_history(role.history_file)
    assert loaded_turns == turns
    assert cold == "[历史 5 轮]"
    assert warm == ["[Turn 1] summary"]


def test_history_v2_upgrade(tmp_path):
    from pymybot.roles import create_role, read_history

    role = create_role("v2-test", root=tmp_path / "roles")
    v2_data = {"version": 2, "turns": [[{"type": "human", "data": {"content": "old"}}]]}
    role.history_file.write_text(json.dumps(v2_data), encoding="utf-8")
    turns, cold, warm = read_history(role.history_file)
    assert len(turns) == 1
    assert cold is None
    assert warm == []


def test_clear_history_resets_tiers():
    from agent_fakes import FunctionModel, ModelResponse, TextPart

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(_Executor(), FunctionModel(respond),
                               AgentConfig(hot_turns=1, warm_turns=1, auto_stats=False, intent_mode="off"))
        try:
            for i in range(3):
                await session.ask(f"prompt {i}")
            assert session._warm_summaries or session._cold_summary
            session.clear_history()
            assert session.turns == []
            assert session._warm_summaries == []
            assert session._cold_summary is None
        finally:
            await session.close()

    asyncio.run(scenario())
