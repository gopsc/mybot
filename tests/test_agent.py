"""Real LangGraph loops with deterministic models; no external API requests."""
import asyncio
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
import signal
import sys
import threading
import time
from types import SimpleNamespace

import pytest

pytest.importorskip("langchain")

from agent_fakes import models
from agent_fakes import ModelResponse, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from agent_fakes import DeltaToolCall, FunctionModel

import pymybot.agent as agent_module
from pymybot.agent import (AgentConfig, AgentSession, AgentBudgetExceeded, AgentInterrupted,
                           AgentConfigurationError, confirm_console, create_model)
from pymybot.paths import asset_path


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", False)
    for key in list(os.environ):
        if key != "MYBOT_HOME" and key.startswith(("MYBOT_", "OPENAI_", "DEEPSEEK_", "ANTHROPIC_")):
            monkeypatch.delenv(key)
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")


class FakeExecutor:
    def __init__(self):
        self.stop_event = threading.Event()
        self.calls = []
        self.closed = False
        self.records = []

    async def start(self, *, deadline=None):
        return {"robot": "test", "hardware": [{"name": "dev", "type": "dummy"}]}

    async def call(self, name, arguments, *, timeout):
        self.calls.append((name, arguments, timeout))
        return {"ok": True, "executed": name not in {"list_hardware", "query_sql"},
                "state": "completed", "data": {"value": 7}}

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        self.closed = True


def scripted_model(*parts):
    responses = iter(parts)

    async def respond(messages, info):
        return ModelResponse(parts=next(responses))

    async def stream(messages, info):
        # Each request runs exactly one of respond/stream, so both share the iterator.
        # Items are bare parts or lists of parts; respond wraps them in a ModelResponse.
        item = next(responses)
        for part in (item if isinstance(item, list) else [item]):
            if isinstance(part, TextPart):
                text = part.content
                middle = len(text) // 2
                for piece in (text[:middle], text[middle:]):
                    if piece:
                        yield piece
            else:
                json_args = part.args if isinstance(part.args, str) else json.dumps(part.args)
                yield {0: DeltaToolCall(name=part.tool_name, json_args=json_args,
                                        tool_call_id=part.tool_call_id)}
    return FunctionModel(respond, stream_function=stream)


def test_real_tool_loop_and_receipts():
    executor = FakeExecutor()
    seen = []

    async def respond(messages, info):
        seen.append((messages, info))
        if len(seen) == 1:
            return ModelResponse(parts=[ToolCallPart("list_files", {}, "call-1")])
        receipts = [p for m in messages for p in m.parts if isinstance(p, ToolReturnPart)]
        assert receipts[-1].tool_call_id == "call-1"
        assert receipts[-1].content["ok"]
        return ModelResponse(parts=[TextPart("已列出")])

    async def scenario():
        session = AgentSession(executor, FunctionModel(respond), workspace=True)
        try:
            result = await session.ask("列出文件")
            assert result["output"] == "已列出"
            assert result["usage"]["requests"] == 2
            assert result["usage"]["tool_calls"] == 1
            assert session.events == [{"tool": "list_files", "ok": True, "executed": True,
                                       "state": "completed"}]
        finally:
            await session.close()
    asyncio.run(scenario())
    assert executor.closed and len(executor.calls) == 1
    names = {tool.name for tool in seen[0][1].function_tools}
    assert {"read_prompt", "update_prompt", "list_files"} <= names
    assert {"list_cameras", "capture_camera"} <= names
    assert not names & {"list_hardware", "list_action_scripts", "query_sql",
                        "run_action_script", "read_variables"}

def test_stream_events_order_and_content():
    executor = FakeExecutor()
    model = scripted_model([ToolCallPart("list_files", {})], [TextPart("流水输出")])
    events = []

    async def scenario():
        session = AgentSession(executor, model, workspace=True, on_event=events.append)
        try:
            result = await session.ask("list")
            assert result["output"] == "流水输出"
            assert session.events == [{"tool": "list_files", "ok": True, "executed": True,
                                       "state": "completed"}]
        finally:
            await session.close()
    asyncio.run(scenario())
    assert events[0]["type"] == "prompt_version"
    assert len(events[0]["hash"]) == 16
    assert events[1:] == [
        {"type": "tool_call", "tool": "list_files", "arguments": {"path": "."}},
        {"type": "tool_result", "tool": "list_files", "ok": True, "executed": True, "state": "completed"},
        {"type": "text_delta", "text": "流水"},
        {"type": "text_delta", "text": "输出"},
    ]

def test_streaming_is_opt_in_and_non_streamed_models_still_work():
    executor = FakeExecutor()

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(executor, FunctionModel(respond))  # No stream_function, no on_event.
        try:
            assert (await session.ask("hi"))["output"] == "ok"
        finally:
            await session.close()
    asyncio.run(scenario())


def test_stream_renderer_neutralizes_controls_in_text_and_tool_labels():
    buffer = io.StringIO()
    renderer = agent_module.StreamRenderer(stream=buffer)
    renderer({"type": "text_delta", "text": "a\x1b[2Jb\x07c\x9bd\nnext\tok"})
    renderer({"type": "tool_call", "tool": "evil\x1b]0;pwn\x07", "arguments": {"x": 1}})
    renderer({"type": "tool_result", "tool": "evil\x1b]0;pwn\x07",
              "ok": True, "state": "done\x1b[2J"})
    renderer.end_turn()
    output = buffer.getvalue()
    assert all(ord(ch) >= 0x20 or ch in "\n\t" for ch in output)
    assert "a" in output and "next\tok" in output
    assert "\\x1b" in output and "\\x07" in output and "\\x9b" in output


def test_stream_renderer_neutralizes_and_truncates_tool_arguments():
    buffer = io.StringIO()
    renderer = agent_module.StreamRenderer(stream=buffer)
    renderer({"type": "text_delta", "text": "部分回复"})
    renderer({"type": "tool_call", "tool": "run_action_script",
              "arguments": {"script": "a\x1b[2Jb.mt"}})
    renderer({"type": "tool_call", "tool": "query_sql", "arguments": {"sql": "x" * 300}})
    renderer({"type": "tool_result", "tool": "query_sql", "ok": True, "state": "completed"})
    streamed = renderer.end_turn()
    output = buffer.getvalue()
    assert streamed and "\x1b" not in output and "部分回复\n" in output
    assert "→ run_action_script(" in output and "⇦ query_sql completed" in output
    assert all(len(line) <= 140 for line in output.splitlines())


def test_run_skill_executes_without_approval():
    from pymybot.agent_skills import SkillsLibrary

    executor = FakeExecutor()
    model = scripted_model(
        [ToolCallPart("run_skill", {"skill": "hardware-controller", "action": "doctor"})],
        [TextPart("done")])
    confirmations = []

    async def confirm(name, arguments):
        confirmations.append((name, arguments))
        return True

    async def scenario():
        session = AgentSession(
            executor, model, AgentConfig(intent_mode="diagnose"),
            confirm=confirm, skills=SkillsLibrary(asset_path("skills")))
        try:
            await session.ask("诊断控制器")
            return session.events[0]
        finally:
            await session.close()

    event = asyncio.run(scenario())
    assert confirmations == []
    assert event["executed"] is True
    assert len(executor.calls) == 1

def test_agent_run_skill_end_to_end():
    from pymybot.agent_executor import RobotExecutor
    from pymybot.agent_skills import SkillsLibrary

    executor = RobotExecutor(
        asset_path("robots") / "relay-test.sql", scripts_dir=asset_path("scripts"),
        skills=SkillsLibrary(asset_path("skills")), allow_hardware=False)
    model = scripted_model(
        [ToolCallPart("run_skill", {"skill": "hardware-controller", "action": "doctor"})],
        [TextPart("done")])

    async def confirm(name, arguments):
        return name == "run_skill"

    async def scenario():
        session = AgentSession(executor, model, AgentConfig(intent_mode="diagnose"), confirm=confirm,
                               skills=SkillsLibrary(asset_path("skills")))
        try:
            return await session.ask("诊断控制器")
        finally:
            await session.close()

    result = asyncio.run(scenario())
    assert result["output"] == "done"
    assert executor.records[-1]["tool"] == "run_skill"
    assert executor.records[-1]["state"] == "completed"


def test_agent_uses_skills_without_a_robot(tmp_path):
    from pymybot.agent_executor import RobotExecutor
    from pymybot.agent_skills import SkillsLibrary

    skills = SkillsLibrary(asset_path("skills"))
    executor = RobotExecutor(None, skills=skills, workspace_dir=str(tmp_path))
    model = scripted_model([ToolCallPart("run_skill", {
        "skill": "hardware-controller", "action": "hardware",
        "arguments": {"robot": {"scope": "skill_assets", "path": "robots/relay-test.sql"}},
    })], [TextPart("done")])

    async def confirm(name, arguments):
        return name == "run_skill"

    async def scenario():
        session = AgentSession(executor, model, confirm=confirm, skills=skills, workspace=True)
        try:
            assert "list_hardware" not in {tool.name for tool in session.tools}
            result = await session.ask("list hardware via the skill")
            assert result["output"] == "done"
            assert executor.records[-1]["tool"] == "run_skill"
            assert executor.records[-1]["state"] == "completed"
        finally:
            await session.close()

    asyncio.run(scenario())


@pytest.mark.parametrize("tool,arguments,permission", [
    ("shell", {"command": "exit 0"}, "allow_shell"),
    ("write_file", {"path": "a.txt", "content": "new"}, "allow_file_writes"),
    ("edit_file", {"path": "a.txt", "old_string": "old", "new_string": "new"}, "allow_file_writes"),
])
@pytest.mark.parametrize("mode,expected", [("none", False), ("deny", False), ("confirm", True),
                                          ("actions", False), ("other", False), ("preapprove", True)])
def test_workspace_approvals_are_independent(tool, arguments, permission, mode, expected):
    executor = FakeExecutor()
    flags = {}
    if mode == "actions":
        flags["allow_actions"] = True
    elif mode == "preapprove":
        flags[permission] = True
    elif mode == "other":
        flags["allow_file_writes" if permission == "allow_shell" else "allow_shell"] = True
    confirmations = []

    async def confirm(name, args):
        confirmations.append((name, args))
        return mode == "confirm"

    async def scenario():
        model = scripted_model([ToolCallPart(tool, arguments)], [TextPart("done")])
        session = AgentSession(executor, model, AgentConfig(**flags), workspace=True, enable_shell=True,
                               confirm=confirm if mode in {"confirm", "deny"} else None)
        try:
            await session.ask("test")
            assert session.events[0]["executed"] is expected
            assert len(executor.calls) == int(expected)
            if mode in {"confirm", "deny"}:
                assert confirmations[0][0] == tool
            else:
                assert not confirmations
        finally:
            await session.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("workspace,enable_shell", [(False, False), (True, False), (True, True)])
def test_workspace_tool_registration(workspace, enable_shell):
    async def respond(messages, info):
        names = {tool.name for tool in info.function_tools}
        assert ({"list_files", "read_file", "write_file", "edit_file"} <= names) is workspace
        assert ("shell" in names) is enable_shell
        return ModelResponse(parts=[TextPart("done")])

    async def scenario():
        session = AgentSession(FakeExecutor(), FunctionModel(respond), workspace=workspace,
                               enable_shell=enable_shell)
        try:
            await session.ask("test")
        finally:
            await session.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("tool,arguments", [("list_files", {}), ("read_file", {"path": "a.txt"})])
def test_workspace_reads_do_not_require_action_approval(tool, arguments):
    executor = FakeExecutor()

    async def scenario():
        session = AgentSession(executor, scripted_model([ToolCallPart(tool, arguments)], [TextPart("done")]),
                               workspace=True)
        try:
            await session.ask("read")
            assert len(executor.calls) == 1
        finally:
            await session.close()
    asyncio.run(scenario())


def test_shell_registration_requires_workspace():
    with pytest.raises(AgentConfigurationError, match="workspace"):
        AgentSession(FakeExecutor(), scripted_model([TextPart("unused")]), enable_shell=True)


@pytest.mark.parametrize("args", [{"script": 123}, {"script": "action.mt", "unexpected": True}])
def test_invalid_model_arguments_never_dispatch(args):
    executor = FakeExecutor()
    model = scripted_model([ToolCallPart("run_skill", args)])

    async def scenario():
        session = AgentSession(executor, model, AgentConfig(allow_actions=True))
        with pytest.raises(Exception):
            await session.ask("execute")
    asyncio.run(scenario())
    assert executor.calls == [] and executor.stop_event.is_set()

def test_multiple_gated_calls_resume_by_interrupt_id():
    executor = FakeExecutor()
    approvals = []

    async def confirm(name, arguments):
        approvals.append(arguments["path"])
        return True

    model = scripted_model([
        ToolCallPart("write_file", {"path": "a.txt", "content": "a"}, "a"),
        ToolCallPart("write_file", {"path": "b.txt", "content": "b"}, "b"),
    ], [TextPart("done")])

    async def scenario():
        session = AgentSession(executor, model, workspace=True, confirm=confirm)
        try:
            result = await session.ask("写两个文件")
            assert result["output"] == "done"
            assert result["usage"]["tool_calls"] == 2
        finally:
            await session.close()

    asyncio.run(scenario())
    assert sorted(approvals) == ["a.txt", "b.txt"]
    assert sorted(arguments["path"] for _name, arguments, _timeout in executor.calls) == ["a.txt", "b.txt"]

def test_parallel_model_calls_are_executed_serially():
    executor = FakeExecutor()
    order = []

    async def call(name, arguments, *, timeout):
        order.append(("start", name))
        await asyncio.sleep(0.01)
        order.append(("end", name))
        return {"ok": True, "executed": False, "state": "completed", "data": {}}

    executor.call = call
    model = scripted_model([ToolCallPart("list_files", {}),
                            ToolCallPart("read_file", {"path": "a.txt"})], [TextPart("done")])
    asyncio.run(AgentSession(executor, model, workspace=True).ask("list"))
    assert order == [("start", "list_files"), ("end", "list_files"),
                     ("start", "read_file"), ("end", "read_file")]

def test_stop_event_cancels_model_before_dispatch():
    executor = FakeExecutor()
    async def respond(messages, info):
        executor.stop_event.set()
        await asyncio.sleep(10)
        return ModelResponse(parts=[TextPart("late")])
    with pytest.raises(AgentInterrupted):
        asyncio.run(AgentSession(executor, FunctionModel(respond)).ask("wait"))
    assert not executor.calls


def test_history_keeps_all_turns():
    executor = FakeExecutor()
    history_sizes = []
    async def respond(messages, info):
        assert (asset_path("prompts") / "010_core.md").read_text(encoding="utf-8").strip() in info.instructions
        history_sizes.append(len([p for m in messages for p in m.parts if isinstance(p, UserPromptPart)]))
        return ModelResponse(parts=[TextPart("done")])
    async def scenario():
        session = AgentSession(executor, FunctionModel(respond), AgentConfig())
        for i in range(4):
            await session.ask(str(i))
        assert len(session.turns) == 4
    asyncio.run(scenario())
    assert history_sizes == [1, 2, 3, 4]


def test_failed_start_never_sends_model_request():
    executor = FakeExecutor()
    async def fail_start(*, deadline=None):
        return {"ok": False, "executed": False, "state": "not_executed"}
    executor.start = fail_start
    async def forbidden(messages, info):
        pytest.fail("Invalid robot startup reached model")
    with pytest.raises(AgentConfigurationError):
        asyncio.run(AgentSession(executor, FunctionModel(forbidden)).ask("hello"))


def test_history_byte_budget_is_bounded():
    assert AgentConfig(history_bytes=64 * 1024).history_bytes == 64 * 1024
    with pytest.raises(AgentConfigurationError, match="history_bytes"):
        AgentConfig(history_bytes=1024)
    with pytest.raises(AgentConfigurationError, match="history_bytes"):
        AgentConfig(history_bytes=65 * 1024 * 1024)


def test_context_budget_prunes_old_turns_inside_tool_loop(monkeypatch):
    executor = FakeExecutor()
    requests = []
    calls = 0

    async def respond(messages, info):
        nonlocal calls
        calls += 1
        requests.append(messages)
        if calls == 2:
            return ModelResponse(parts=[ToolCallPart("list_files", {}, "context-call")])
        return ModelResponse(parts=[TextPart("done")])

    monkeypatch.setattr(agent_module, "estimate_request_tokens",
                        lambda messages, tools=(): 1000 * len(messages))

    async def scenario():
        config = AgentConfig(max_context_tokens=8192, context_reserve_tokens=0)
        session = AgentSession(executor, FunctionModel(respond), config, workspace=True)
        try:
            await session.ask("old")
            assert (await session.ask("new"))["output"] == "done"
            assert len(session.turns) == 1
        finally:
            await session.close()

    asyncio.run(scenario())
    final_prompts = [part.content for message in requests[-1] for part in message.parts
                     if isinstance(part, UserPromptPart)]
    receipts = [part for message in requests[-1] for part in message.parts
                if isinstance(part, ToolReturnPart)]
    assert "old" not in final_prompts and "new" in final_prompts
    assert [part.tool_call_id for part in receipts] == ["context-call"]

def test_context_budget_rejects_oversized_current_turn_before_model(monkeypatch):
    executor = FakeExecutor()
    called = []

    async def forbidden(messages, info):
        called.append(True)
        return ModelResponse(parts=[TextPart("unreachable")])

    monkeypatch.setattr(agent_module, "estimate_request_tokens", lambda messages, tools=(): 5000)
    config = AgentConfig(max_context_tokens=8192, context_reserve_tokens=1024)
    session = AgentSession(executor, FunctionModel(forbidden), config)
    with pytest.raises(AgentBudgetExceeded, match="only 3072 remain"):
        asyncio.run(session.ask("current turn alone is too large"))
    assert called == [] and session.turns == [] and executor.stop_event.is_set()


def test_context_budget_real_estimator_supports_model_request():
    config = AgentConfig(max_context_tokens=32768)

    async def scenario():
        session = AgentSession(FakeExecutor(), scripted_model([TextPart("done")]), config)
        try:
            assert (await session.ask("hello"))["output"] == "done"
        finally:
            await session.close()

    asyncio.run(scenario())


def test_context_token_configuration_is_validated():
    assert AgentConfig(max_context_tokens=None).max_context_tokens is None
    assert AgentConfig(max_context_tokens=8192).context_reserve_tokens == 2048
    with pytest.raises(AgentConfigurationError, match="max_context_tokens"):
        AgentConfig(max_context_tokens=4096)
    with pytest.raises(AgentConfigurationError, match="context_reserve_tokens"):
        AgentConfig(context_reserve_tokens=-1)


@pytest.mark.parametrize("receipt_state", ["completed", "not_executed"])
def test_stop_during_tool_preserves_receipt_without_another_request(receipt_state):
    executor = FakeExecutor()
    requests = []

    async def call(name, arguments, *, timeout):
        executor.stop_event.set()
        return {"ok": receipt_state == "completed", "executed": False, "state": receipt_state}

    executor.call = call

    async def respond(messages, info):
        requests.append(True)
        assert len(requests) == 1, "A stopped turn must not make another model request"
        return ModelResponse(parts=[ToolCallPart("list_files", {})])

    session = AgentSession(executor, FunctionModel(respond), workspace=True)
    with pytest.raises(AgentInterrupted):
        asyncio.run(session.ask("list"))
    assert requests == [True]
    assert session.events[-1]["state"] == receipt_state

def test_model_request_hook_checks_stop_even_outside_ask():
    executor = FakeExecutor()
    async def forbidden(messages, info):
        pytest.fail("Stopped session reached the model")
    async def scenario():
        from langchain_core.messages import HumanMessage, SystemMessage

        session = AgentSession(executor, FunctionModel(forbidden))
        executor.cancel()
        graph = session._build_graph()
        with pytest.raises(AgentInterrupted):
            await graph.ainvoke(
                {"messages": [SystemMessage("s"), HumanMessage("hello")]},
                {"configurable": {"thread_id": "stop-test"}})
    asyncio.run(scenario())


class FakeTTY(io.StringIO):
    def isatty(self):
        return True


@pytest.mark.parametrize("long", [False, True])
def test_console_approval_never_hides_arguments(monkeypatch, capsys, long):
    stdin = FakeTTY("y\n")
    monkeypatch.setattr(sys, "stdin", stdin)
    arguments = {"script": "action.mt", "vars": {"text": "x" * 2100 if long else "a\x1b[2Jb"}}
    approved = asyncio.run(confirm_console("run_skill", arguments, threading.Event()))
    output = capsys.readouterr()
    assert not output.out and "\x1b" not in output.err
    if long:
        assert not approved and stdin.tell() == 0
        assert "too long" in output.err
    else:
        assert approved and repr(agent_module.dumps(arguments)) in output.err


@pytest.mark.parametrize("name,args,warning", [
    ("shell", {"command": "exit 0"}, "sandbox"),
    ("write_file", {"path": "note.txt", "content": "text"}, "changes workspace files"),
    ("edit_file", {"path": "note.txt", "old_string": "a", "new_string": "b"}, "changes workspace files"),
])
def test_workspace_console_approval_displays_scope(monkeypatch, capsys, name, args, warning):
    monkeypatch.setattr(sys, "stdin", FakeTTY("y\n"))
    assert asyncio.run(confirm_console(name, args, threading.Event()))
    output = capsys.readouterr()
    assert warning in output.err
    assert repr(agent_module.dumps(args)) in output.err


def install_cli_fakes(monkeypatch, executor, model, client):
    def factory(*args, stop_event, **kwargs):
        executor.stop_event = stop_event
        return executor
    monkeypatch.setattr(agent_module, "RobotExecutor", factory)
    monkeypatch.setattr(agent_module, "create_model", lambda _: (model, client))


@pytest.mark.parametrize("primary_failure", [False, True])
@pytest.mark.parametrize("cleanup_failure", ["executor", "client", "both"])
def test_cli_cleanup_failures_preserve_receipts_and_primary_error(monkeypatch, capsys, primary_failure, cleanup_failure):
    from pymybot import cli
    executor = FakeExecutor()
    closed = []

    async def close_executor():
        closed.append("executor")
        if cleanup_failure in {"executor", "both"}:
            raise ValueError("SECRET executor cleanup")

    async def close_client():
        closed.append("client")
        if cleanup_failure in {"client", "both"}:
            raise OSError("SECRET client cleanup")

    executor.close = close_executor
    if primary_failure:
        async def unknown_call(name, arguments, *, timeout):
            return {"ok": False, "executed": True, "state": "unknown"}
        executor.call = unknown_call
    model = scripted_model([ToolCallPart("list_skills", {})], [TextPart("done")])
    install_cli_fakes(monkeypatch, executor, model, SimpleNamespace(close=close_client))
    code = cli.main(["--no-gui", "--robot", "unused.sql", "--task", "list skills"])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert code == 1 and not payload["ok"] and closed == ["executor", "client"]
    assert len(captured.out.splitlines()) == 1 and "SECRET" not in captured.out + captured.err
    assert payload["tool_events"] == [{"tool": "list_skills", "ok": not primary_failure,
                                      "executed": True, "state": "unknown" if primary_failure else "completed"}]
    expected = {"executor": ["ValueError"], "client": ["OSError"], "both": ["ValueError", "OSError"]}
    assert payload["cleanup_errors"] == expected[cleanup_failure]
    if primary_failure:
        assert "outcome is unknown" in payload["error"]["message"]

def test_interactive_cli_confirms_and_emits_only_final_json(monkeypatch, capsys, tmp_path):
    from pymybot import cli
    executor = FakeExecutor()
    closed = []

    async def close_client():
        closed.append(True)

    model = scripted_model([ToolCallPart("install_skill", {"path": "cli-created"})],
        [TextPart("已完成")])
    install_cli_fakes(monkeypatch, executor, model, SimpleNamespace(close=close_client))
    monkeypatch.setattr(sys, "stdin", FakeTTY("创建技能\ny\n/exit\n"))
    code = cli.main(["--no-gui", "--robot", "unused.sql", "--workspace-dir", str(tmp_path)])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert code == 0 and len(captured.out.splitlines()) == 1
    assert payload["turns"] == 1 and payload["output"] == "已完成"
    assert "Approve install_skill" in captured.err and "已完成" in captured.err
    assert len(executor.calls) == 1 and executor.closed and closed == [True]

def test_interactive_cli_streams_to_stderr_and_does_not_reprint(monkeypatch, capsys):
    from pymybot import cli
    executor = FakeExecutor()
    model = scripted_model([ToolCallPart("list_skills", {})], [TextPart("AAAA BBBB")])
    install_cli_fakes(monkeypatch, executor, model, SimpleNamespace(close=lambda: asyncio.sleep(0)))
    monkeypatch.setattr(sys, "stdin", FakeTTY("list\n/exit\n"))
    code = cli.main(["--no-gui", "--robot", "unused.sql"])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert code == 0 and len(captured.out.splitlines()) == 1
    assert payload["turns"] == 1 and payload["output"] == "AAAA BBBB"
    assert "→ list_skills(" in captured.err and "⇦ list_skills completed" in captured.err
    assert captured.err.count("AAAA BBBB") == 1

@contextmanager
def fake_openai(respond):
    """Explicit local fake of Chat Completions, including actual SDK serialization."""
    requests = []
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(body)
            status, payload = respond(body, len(requests))
            if status == 200 and body.get("stream"):
                raw = sse_body(payload)
                self.send_response(status)
                self.send_header("Content-Type", "text/event-stream")
            else:
                raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _chunk(model, delta, finish_reason=None):
    return {"id": "offline-stream", "object": "chat.completion.chunk", "created": 1, "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}]}


def sse_body(payload):
    """Serialize a Chat Completions payload as the SSE chunk stream the SDK expects."""
    choice = payload["choices"][0]
    message = choice["message"]
    chunks = [_chunk(payload["model"], {"role": "assistant"})]
    if message.get("tool_calls"):
        chunks.append(_chunk(payload["model"], {"tool_calls": [
            {"index": 0, "id": call["id"], "type": "function",
             "function": {"name": call["function"]["name"], "arguments": call["function"]["arguments"]}}
            for call in message["tool_calls"]]}))
    else:
        content = message.get("content") or ""
        middle = max(1, len(content) // 2)
        for piece in (content[:middle], content[middle:]):
            if piece:
                chunks.append(_chunk(payload["model"], {"content": piece}))
    chunks.append(_chunk(payload["model"], {}, choice["finish_reason"]))
    final = _chunk(payload["model"], {})
    final["choices"] = []
    final["usage"] = payload.get("usage")
    chunks.append(final)
    return "".join(f"data: {json.dumps(c, ensure_ascii=False)}\n\n" for c in chunks).encode("utf-8") + b"data: [DONE]\n\n"


def completion(message, *, tool=False):
    return 200, {"id": "offline-completion", "object": "chat.completion", "created": 1, "model": "test",
                 "choices": [{"index": 0, "message": message,
                              "finish_reason": "tool_calls" if tool else "stop"}],
                 "usage": {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30}}


def test_cli_real_sdk_model_loop_with_generic_tools(tmp_path, monkeypatch, capsys):
    from pymybot import cli
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    (tmp_path / "note.txt").write_text("hello", encoding="utf-8")

    def respond(body, count):
        assert body["model"] == "test" and body["parallel_tool_calls"] is False
        roles = [m["role"] for m in body["messages"]]
        assert roles[0] == "system" and roles.count("system") == 1
        if count == 1:
            return completion({"role": "assistant", "content": None, "tool_calls": [
                {"id": "files-1", "type": "function", "function": {
                    "name": "list_files", "arguments": "{}"}}]}, tool=True)
        receipt = next(m for m in body["messages"] if m["role"] == "tool")
        assert "note.txt" in receipt["content"]
        return completion({"role": "assistant", "content": "文件已列出"})

    with fake_openai(respond) as (url, requests):
        code = cli.main(["--no-gui", "agent", "--task", "list files", "--model", "openai:test",
                         "--base-url", url, "--workspace-dir", str(tmp_path)])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert code == 0 and payload["output"] == "文件已列出" and len(requests) == 2
    assert payload["tool_events"][-1]["state"] == "completed"
    assert payload["tool_events"][-1]["tool"] == "list_files"

def test_custom_endpoint_reconnects_instead_of_reusing_keepalive(tmp_path, monkeypatch, capsys):
    """Self-hosted servers may silently drop idle connections; a reused one fails with retries off."""
    from pymybot import cli
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", True)  # Only the loopback fake below.
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    path = tmp_path / "robot.sql"
    path.write_text("CREATE TABLE dummy(name String);", encoding="utf-8")
    ports = []
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"  # Offer keep-alive.
        def log_message(self, *args):
            pass
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            ports.append(self.client_address[1])
            message = ({"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function",
                        "function": {"name": "list_hardware", "arguments": "{}"}}]}
                       if len(ports) == 1 else {"role": "assistant", "content": "done"})
            raw = sse_body(completion(message, tool=len(ports) == 1)[1])
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
    thread.start()
    try:
        code = cli.main(["--no-gui", "--robot", str(path), "--task", "列出硬件", "--model", "openai-chat:test",
                         "--base-url", f"http://127.0.0.1:{server.server_port}/v1"])
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    assert code == 0 and json.loads(capsys.readouterr().out)["output"] == "done"
    assert len(ports) == 2 and ports[0] != ports[1]


def test_cli_workspace_tools_real_execution(tmp_path, monkeypatch, capsys):
    from pymybot import cli, sandbox
    from pymybot.robot import Robot

    robot = tmp_path / "robot.sql"
    robot.write_text("CREATE TABLE Vars(name String,value Number);", encoding="utf-8")
    # Protected prompts require usable bubblewrap for the agent shell, so hosts
    # without namespaces exercise file tools only instead of an unisolated shell.
    shell = sandbox.bwrap_usable()
    requests = [
        ToolCallPart("write_file", {"path": "note.txt", "content": "before\n"}),
        ToolCallPart("edit_file", {"path": "note.txt", "old_string": "before", "new_string": "after"}),
        ToolCallPart("read_file", {"path": "note.txt"}),
    ]
    if shell:
        requests.append(ToolCallPart("shell", {"command": "echo shell-ok"}))
    calls = iter([*requests, TextPart("completed")])
    receipts = []

    async def respond(messages, info):
        returns = [part for message in messages for part in message.parts if isinstance(part, ToolReturnPart)]
        if returns:
            receipts.append(returns[-1].content)
            assert receipts[-1]["ok"], receipts[-1]
        return ModelResponse(parts=[next(calls)])

    async def stream(messages, info):
        response = await respond(messages, info)
        for part in response.parts:
            if isinstance(part, TextPart):
                yield part.content
            else:
                yield {0: DeltaToolCall(name=part.tool_name, json_args=json.dumps(part.args),
                                        tool_call_id=part.tool_call_id)}

    def forbidden_activation(*args, **kwargs):
        pytest.fail("Workspace tools must not activate hardware")
    monkeypatch.setattr(Robot, "active", forbidden_activation)
    monkeypatch.setattr(agent_module, "create_model", lambda _: (FunctionModel(respond, stream_function=stream), None))
    flags = ["--enable-shell", "--allow-shell"] if shell else []
    code = cli.main(["--no-gui", "--robot", str(robot), "--scripts-dir", str(tmp_path),
                     "--workspace-dir", str(tmp_path), *flags,
                     "--allow-file-writes", "--task", "write, edit, read and run shell"])
    captured = capsys.readouterr()
    assert code == 0 and len(captured.out.splitlines()) == 1, captured.out + captured.err
    assert json.loads(captured.out)["output"] == "completed"
    assert (tmp_path / "note.txt").read_text(encoding="utf-8") == "after\n"
    assert receipts[2]["data"]["content"] == "after\n"
    if shell:
        assert receipts[3]["data"]["exit_code"] == 0
        assert "shell-ok" in receipts[3]["data"]["stdout"]
        assert "Shell enabled:" in captured.err


def test_provider_error_is_sanitized_and_not_retried(tmp_path, monkeypatch, capsys):
    from pymybot import cli
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", True)
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    path = tmp_path / "robot.sql"
    path.write_text("CREATE TABLE Vars(name String,value Number);", encoding="utf-8")
    with fake_openai(lambda *_: (500, {"error": {"message": "SECRET must not leak", "type": "server_error"}})) as (url, requests):
        code = cli.main(["--no-gui", "--robot", str(path), "--scripts-dir", str(tmp_path), "--task", "hello",
                         "--model", "openai:test", "--base-url", url])
    captured = capsys.readouterr()
    assert code == 1 and len(requests) == 1
    assert "SECRET" not in captured.out + captured.err
    assert json.loads(captured.out)["ok"] is False


def test_unusable_skills_root_fails_as_configuration_before_any_request(tmp_path, monkeypatch, capsys):
    from pymybot import cli
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", True)
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    path = tmp_path / "robot.sql"
    path.write_text("CREATE TABLE Vars(name String,value Number);", encoding="utf-8")

    def forbid(*_):
        pytest.fail("skills root must be validated before a model request is sent")

    with fake_openai(forbid) as (url, requests):
        code = cli.main(["--no-gui", "--robot", str(path), "--scripts-dir", str(tmp_path), "--task", "hello",
                         "--skills-dir", str(tmp_path / "absent"),
                         "--model", "openai:test", "--base-url", url])
    captured = capsys.readouterr()
    assert requests == []
    assert code == 1
    assert json.loads(captured.out)["error"]["type"] == "AgentConfigurationError"
    assert "Skills root does not exist" in captured.err


@pytest.mark.parametrize("model", ["", "gpt-example", "unknown:x", "openai:"])
def test_explicit_model_required(model):
    with pytest.raises(AgentConfigurationError):
        create_model(AgentConfig(model=model))


def test_model_rejection_message_lists_every_accepted_provider():
    with pytest.raises(AgentConfigurationError) as exc:
        create_model(AgentConfig(model="unknown:x"))
    message = str(exc.value)
    for provider in agent_module.PROVIDERS:
        assert f"{provider}:MODEL" in message


def test_missing_key_does_not_echo_other_secrets(monkeypatch):
    monkeypatch.setenv("UNRELATED_TOKEN", "secret-must-not-appear")
    with pytest.raises(AgentConfigurationError, match="OPENAI_API_KEY") as exc:
        create_model(AgentConfig(model="openai:test"))
    assert "secret-must-not-appear" not in str(exc.value)


@pytest.mark.parametrize("base_url", ["http://example.com/v1", "https://user:password@example.com", "https://example.com?token=secret"])
def test_endpoint_rejects_credentials_and_remote_plaintext(base_url):
    with pytest.raises(AgentConfigurationError) as exc:
        create_model(AgentConfig(model="openai:test", base_url=base_url))
    assert "password" not in str(exc.value) and "secret" not in str(exc.value)


@pytest.mark.parametrize("provider,key", sorted(agent_module.PROVIDER_KEY_ENV.items()))
def test_provider_clients_disable_automatic_retries(monkeypatch, provider, key):
    monkeypatch.setenv(key, "offline-test-key")
    async def scenario():
        model, client = create_model(AgentConfig(model=f"{provider}:test"))
        try:
            assert client.max_retries == 0
            assert model.model_name == "test"
        finally:
            await client.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("provider", agent_module.PROVIDERS)
@pytest.mark.parametrize("base_url", [None, "https://model.invalid/v1//"], ids=["default", "custom"])
@pytest.mark.parametrize("status,redirect", [
    pytest.param(200, None, id="success"),
    pytest.param(307, "same-origin", id="307-same-origin"),
    pytest.param(308, "cross-origin", id="308-cross-origin"),
])
def test_provider_http_requests_do_not_follow_redirects(monkeypatch, provider, base_url, status, redirect):
    """Intercept the real SDK transport and prove a 3xx never produces a second request."""
    import httpx2 as httpx
    from langchain_core.messages import HumanMessage

    key, prompt = "offline-synthetic-api-key", "synthetic-private-prompt"
    monkeypatch.setenv(agent_module.PROVIDER_KEY_ENV[provider], key)
    default_url = {"openai": "https://api.openai.com/v1", "openai-chat": "https://api.openai.com/v1",
                   "deepseek": "https://api.deepseek.com/v1", "anthropic": "https://api.anthropic.com"}
    route = "v1/messages" if provider == "anthropic" else "chat/completions"
    endpoint = f"{(base_url or default_url[provider]).rstrip('/')}/{route}"
    destination = "/redirected" if redirect == "same-origin" else "https://redirect.invalid/redirected"
    if provider == "anthropic":
        payload = {"id": "offline-message", "type": "message", "role": "assistant", "model": "test",
                   "content": [{"type": "text", "text": "done"}], "stop_reason": "end_turn",
                   "stop_sequence": None, "usage": {"input_tokens": 20, "output_tokens": 10}}
    else:
        _, payload = completion({"role": "assistant", "content": "done"})
    requests = []

    def respond(request):
        requests.append(request)
        if redirect and len(requests) == 1:
            return httpx.Response(status, headers={"Location": destination}, json={"error": "redirect"})
        return httpx.Response(200, json=payload)

    transport = httpx.MockTransport(respond)
    monkeypatch.setattr(httpx.AsyncClient, "_transport_for_url", lambda self, url: transport)

    async def scenario():
        config = AgentConfig(model=f"{provider}:test", base_url=base_url, timeout=7 if base_url else 180)
        model, client = create_model(config)
        try:
            assert requests == []  # Construction must not probe the endpoint.
            error = result = None
            try:
                result = await model.ainvoke([HumanMessage(prompt)])
            except Exception as exc:
                error = exc
            assert [(request.method, str(request.url.copy_with(query=None)))
                    for request in requests] == [("POST", endpoint)]
            body = json.loads(requests[0].content)
            assert body["model"] == "test" and prompt in requests[0].content.decode("utf-8")
            assert client.max_retries == 0
            if redirect:
                assert error is not None and result is None
            else:
                assert error is None and "done" in str(result.content)
        finally:
            await client.close()
    asyncio.run(scenario())


def test_failure_names_endpoint_and_status_but_not_body():
    describe = agent_module.describe_failure

    class HTTPFailure(Exception):
        status_code = 500

    assert describe(HTTPFailure("SECRET"), "http://127.0.0.1:8080/v1/") == (
        "HTTPFailure: HTTP 500 from http://127.0.0.1:8080/v1/")
    try:
        raise RuntimeError("SECRET") from ConnectionRefusedError("SECRET")
    except RuntimeError as exc:
        assert describe(exc, "https://h/v1/") == "RuntimeError (ConnectionRefusedError) from https://h/v1/"
    wrapped = OSError("SECRET")
    wrapped.__cause__ = ConnectionResetError("SECRET")
    try:
        raise RuntimeError("SECRET") from wrapped
    except RuntimeError as exc:
        assert describe(exc) == "RuntimeError (OSError <- ConnectionResetError)"
    assert describe(RuntimeError("SECRET")) == "RuntimeError"


@pytest.mark.parametrize("provider", ["openai-chat", "anthropic"])
def test_base_url_trailing_slashes_do_not_double_the_request_path(monkeypatch, provider):
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "offline-fake-key")
    _, client = create_model(AgentConfig(model=f"{provider}:m", base_url="http://127.0.0.1:8080/v1//"))
    assert str(client.base_url) == "http://127.0.0.1:8080/v1/"


@pytest.mark.parametrize("provider,url", [("openai-chat", "http://127.0.0.1:8080/v1/chat/completions"),
                                          ("anthropic", "http://127.0.0.1:8080/v1/v1/messages")])
def test_failure_endpoint_is_the_request_url(monkeypatch, provider, url):
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "offline-fake-key")
    _, client = create_model(AgentConfig(model=f"{provider}:m", base_url="http://127.0.0.1:8080/v1/"))
    assert agent_module.request_endpoint(client) == f"POST {url}"
    assert agent_module.request_endpoint(object()) is None


def test_cli_agent_writes_transcript(monkeypatch, capsys, tmp_path):
    from pymybot import cli

    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    monkeypatch.setenv("MYBOT_SESSION_LOG", "1")
    executor = FakeExecutor()
    model = scripted_model([TextPart("done")])
    install_cli_fakes(monkeypatch, executor, model, SimpleNamespace(close=lambda: asyncio.sleep(0)))

    code = cli.main(["--no-gui", "--robot", "unused.sql", "--model", "openai:test", "--task", "hello"])
    captured = capsys.readouterr()
    assert code == 0 and "session log:" in captured.err
    sessions = list((tmp_path / "sessions").iterdir())
    assert len(sessions) == 1
    events = [json.loads(line) for line in
              (sessions[0] / "transcript.jsonl").read_text(encoding="utf-8").splitlines()]
    assert [event["type"] for event in events] == [
        "session_start", "user", "intent", "prompt_version", "assistant", "usage", "prompt_update", "session_end"]
    assert events[1]["text"] == "hello"
    assert events[2]["name"] == "chat"
    assert events[3]["layers"].keys() == {"0", "10", "97", "98", "99", "100"}
    assert events[4]["text"] == "done"
    assert events[6]["actor"] == "stats"
    meta = json.loads((sessions[0] / "meta.json").read_text(encoding="utf-8"))
    assert meta["model"] == "openai:test"
