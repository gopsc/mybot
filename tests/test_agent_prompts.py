import asyncio
import json
import threading
from pathlib import Path

import pytest

pytest.importorskip("pydantic_ai")
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart
from pydantic_ai.models.function import DeltaToolCall, FunctionModel

from pymybot.agent import AgentConfig, AgentConfigurationError, AgentSession
from pymybot.prompts import PromptLibrary
from pymybot.session_log import SessionLog


class Executor:
    def __init__(self):
        self.stop_event = threading.Event()
        self.calls = []
        self.robot_path = Path("/private/workspace/robot.sql")

    async def start(self, *, deadline=None):
        return {"robot": str(self.robot_path), "hardware": []}

    async def call(self, name, arguments, *, timeout):
        self.calls.append((name, arguments))
        return {"ok": True, "executed": False, "state": "completed", "data": {}}

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        pass


def text_model():
    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("done")])
    return FunctionModel(respond)


def test_prompt_update_is_hot_within_and_between_turns():
    seen, approvals = [], []

    async def confirm(name, arguments):
        approvals.append((name, arguments))
        return True

    async def respond(messages, info):
        seen.append(info.instructions)
        if len(seen) == 1:
            return ModelResponse(parts=[ToolCallPart("update_prompt", {
                "layer": "97", "content": "Speak concisely: HOT-SOUL", "reason": "Operator asked"})])
        assert "HOT-SOUL" in info.instructions
        if len(seen) == 2:
            receipts = [p for m in messages for p in m.parts if isinstance(p, ToolReturnPart)]
            assert receipts[-1].content["ok"]
        return ModelResponse(parts=[TextPart("done")])

    async def scenario():
        session = AgentSession(Executor(), FunctionModel(respond), AgentConfig(auto_stats=False), confirm=confirm)
        try:
            first = await session.ask("修改 SOUL")
            second = await session.ask("hello again")
            assert first["prompt_version"]["layers"]["97"] == second["prompt_version"]["layers"]["97"]
            assert "HOT-SOUL" in session.prompt_snapshot.text
        finally:
            await session.close()

    asyncio.run(scenario())
    assert len(seen) == 3
    assert len(approvals) == 1 and approvals[0][0] == "prompt:update_prompt"
    assert "+Speak concisely: HOT-SOUL" in approvals[0][1]["diff"]


def test_operator_edits_reload_without_restarting():
    seen = []

    async def respond(messages, info):
        seen.append(info.instructions)
        return ModelResponse(parts=[TextPart("done")])

    async def scenario():
        session = AgentSession(Executor(), FunctionModel(respond), AgentConfig(auto_stats=False))
        try:
            await session.ask("hello")
            session.prompts.update("98", "OPERATOR-CHANGED", reason="test")
            await session.ask("hello again")
        finally:
            await session.close()

    asyncio.run(scenario())
    assert "OPERATOR-CHANGED" not in seen[0]
    assert "OPERATOR-CHANGED" in seen[1]


@pytest.mark.parametrize("approved", [False, True])
def test_prompt_approval_is_separate_and_rate_limited(approved):
    approvals = []

    async def confirm(name, arguments):
        approvals.append(name)
        return approved

    async def scenario():
        config = AgentConfig(allow_actions=True, allow_file_writes=True, allow_shell=True, auto_stats=False)
        session = AgentSession(Executor(), text_model(), config, confirm=confirm)
        try:
            before = session.prompts.read("98")["sha256"]
            first = await session.dispatch("update_prompt", {"layer": "98", "content": "new", "reason": "requested"})
            assert first["ok"] is approved
            second = await session.dispatch("update_prompt", {"layer": "97", "content": "other", "reason": "requested"})
            assert not second["ok"] and "limit" in second["error"]
            assert (session.prompts.read("98")["sha256"] != before) is approved
        finally:
            await session.close()

    asyncio.run(scenario())
    assert approvals == ["prompt:update_prompt"]


@pytest.mark.parametrize("layer", ["0", "10", "100", "../98", 98, []])
def test_invalid_agent_prompt_layers_never_reach_approval(layer):
    async def confirm(name, arguments):
        pytest.fail("Invalid layer must not request approval")

    async def scenario():
        session = AgentSession(Executor(), text_model(), confirm=confirm)
        try:
            for tool, args in (("read_prompt", {"layer": layer}),
                               ("update_prompt", {"layer": layer, "content": "oops", "reason": "bad"})):
                result = await session.dispatch(tool, args)
                assert result["state"] == "not_executed" and not result["executed"]
        finally:
            await session.close()

    asyncio.run(scenario())


def test_update_conflict_during_approval_preserves_operator_edit():
    async def scenario():
        async def confirm(name, arguments):
            session.prompts.update("97", "operator wins", reason="operator changed concurrently")
            return True

        session = AgentSession(Executor(), text_model(), confirm=confirm)
        try:
            result = await session.dispatch("update_prompt", {"layer": "97", "content": "agent", "reason": "requested"})
            assert not result["ok"] and not result["executed"]
            assert session.prompts.read("97")["content"] == "operator wins"
        finally:
            await session.close()

    asyncio.run(scenario())


def test_prompt_tool_transcripts_and_stream_events_redact_content():
    async def scenario():
        calls = 0

        async def respond(messages, info):
            nonlocal calls
            calls += 1
            if calls == 1:
                return ModelResponse(parts=[ToolCallPart("read_prompt", {"layer": "98"})])
            if calls == 2:
                return ModelResponse(parts=[ToolCallPart("update_prompt", {
                    "layer": "98", "content": "NEW-PRIVATE-USER", "reason": "Requested preference"})])
            return ModelResponse(parts=[TextPart("done")])

        async def confirm(name, arguments):
            assert "NEW-PRIVATE-USER" in arguments["diff"]
            return True

        async def stream(messages, info):
            response = await respond(messages, info)
            for part in response.parts:
                if isinstance(part, TextPart):
                    yield part.content
                else:
                    yield {0: DeltaToolCall(name=part.tool_name, json_args=json.dumps(part.args))}

        log = SessionLog(mode="test")
        events = []
        session = AgentSession(Executor(), FunctionModel(respond, stream_function=stream), AgentConfig(auto_stats=False),
                               confirm=confirm, session_log=log, on_event=events.append)
        session.prompts.update("98", "OLD-PRIVATE-USER", reason="seed")
        try:
            await session.ask("remember my preference")
        finally:
            await session.close()
        transcript = (log.path / "transcript.jsonl").read_text(encoding="utf-8")
        assert "OLD-PRIVATE-USER" not in transcript and "NEW-PRIVATE-USER" not in transcript
        assert "NEW-PRIVATE-USER" not in json.dumps(events)
        records = [json.loads(line) for line in transcript.splitlines()]
        assert any(r["type"] == "prompt_approval" and r["approved"] for r in records)
        assert any(r["type"] == "prompt_version" and len(r["layers"]) == 6 for r in records)

    asyncio.run(scenario())


def test_stats_are_bounded_host_metadata_and_can_be_disabled(monkeypatch):
    monkeypatch.setenv("FAKE_API_KEY", "secret-never-include")

    async def scenario(auto_stats):
        session = AgentSession(Executor(), text_model(), AgentConfig(auto_stats=auto_stats))
        try:
            before = session.prompts.read("99")["sha256"]
            await session.ask("do not copy USER-CONTENT-SECRET into stats")
            after = session.prompts.read("99")
            assert (after["sha256"] != before) is auto_stats
            if auto_stats:
                assert '"robot":"robot.sql"' in after["content"]
                assert '"tool_calls":0' in after["content"]
                for private in ("secret-never-include", "USER-CONTENT-SECRET", "/private/workspace"):
                    assert private not in after["content"]
        finally:
            await session.close()

    asyncio.run(scenario(True))
    asyncio.run(scenario(False))


def test_stats_conflict_is_best_effort(capsys):
    async def scenario():
        async def respond(messages, info):
            session.prompts.update("99", "operator stats", reason="concurrent operator edit")
            return ModelResponse(parts=[TextPart("done")])
        session = AgentSession(Executor(), FunctionModel(respond))
        try:
            assert (await session.ask("hello"))["output"] == "done"
            assert session.prompts.read("99")["content"] == "operator stats"
        finally:
            await session.close()

    asyncio.run(scenario())
    assert "STATS update failed" in capsys.readouterr().err


@pytest.mark.parametrize("content,reason", [("x\x00y", "bad"), ("界" * 3000, "oversized"), ("text", "")])
def test_invalid_prompt_content_is_rejected_before_approval(content, reason):
    async def confirm(name, arguments):
        pytest.fail("Invalid content must not request approval")

    async def scenario():
        session = AgentSession(Executor(), text_model(), confirm=confirm)
        try:
            before = session.prompts.read("97")["sha256"]
            result = await session.dispatch("update_prompt", {"layer": "97", "content": content, "reason": reason})
            assert not result["ok"] and not result["executed"]
            assert session.prompts.read("97")["sha256"] == before
        finally:
            await session.close()

    asyncio.run(scenario())


def test_prompt_update_requires_available_approval_even_with_auto_actions():
    async def scenario():
        session = AgentSession(Executor(), text_model(), AgentConfig(allow_actions=True, allow_file_writes=True))
        try:
            result = await session.dispatch("update_prompt", {"layer": "98", "content": "new", "reason": "requested"})
            assert result["state"] == "not_executed" and "approval" in result["error"]
        finally:
            await session.close()

    asyncio.run(scenario())


def test_session_prompt_update_limit_spans_turns():
    approvals = []

    async def confirm(name, arguments):
        approvals.append(name)
        return False

    async def scenario():
        session = AgentSession(Executor(), text_model(), confirm=confirm)
        try:
            for turn in range(21):
                session._turn = turn
                result = await session.dispatch("update_prompt", {
                    "layer": "97", "content": str(turn), "reason": "requested"})
            assert "20 per session" in result["error"]
        finally:
            await session.close()

    asyncio.run(scenario())
    assert len(approvals) == 20


def test_tampered_safety_blocks_session_and_next_request():
    library = PromptLibrary()
    library.ensure_home()
    safety = next(item["file"] for item in library.layers if item["id"] == "0")
    (library.home / safety).write_text("tampered", encoding="utf-8")
    with pytest.raises(AgentConfigurationError, match="prompt"):
        AgentSession(Executor(), text_model())
    library.restore(missing_only=False)

    async def scenario():
        session = AgentSession(Executor(), text_model())
        (library.home / safety).write_text("tampered", encoding="utf-8")
        try:
            with pytest.raises(AgentConfigurationError):
                await session.ask("hello")
            assert session.context is None
        finally:
            await session.close()

    asyncio.run(scenario())
