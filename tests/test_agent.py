"""Real PydanticAI loops with deterministic models; no external API requests."""
import asyncio
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
import signal
import sys
import threading
from types import SimpleNamespace

import pytest

pytest.importorskip("pydantic_ai")

from pydantic_ai import models
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import DeltaToolCall, FunctionModel
from pydantic_ai.exceptions import UsageLimitExceeded

import pymybot.agent as agent_module
from pymybot.agent import (AgentConfig, AgentSession, AgentBudgetExceeded, AgentInterrupted,
                           AgentConfigurationError, SYSTEM_PROMPT, confirm_console, create_model)


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", False)
    for key in list(os.environ):
        if key.startswith(("MYBOT_", "OPENAI_", "DEEPSEEK_", "ANTHROPIC_")):
            monkeypatch.delenv(key)


class FakeExecutor:
    def __init__(self):
        self.stop_event = threading.Event()
        self.calls = []
        self.closed = False
        self.records = []

    async def start(self):
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
            return ModelResponse(parts=[ToolCallPart("list_hardware", {}, "call-1")])
        receipts = [p for m in messages for p in m.parts if isinstance(p, ToolReturnPart)]
        assert receipts[-1].tool_call_id == "call-1"
        assert receipts[-1].content["ok"]
        return ModelResponse(parts=[TextPart("机器人已列出")])

    async def scenario():
        session = AgentSession(executor, FunctionModel(respond))
        try:
            result = await session.ask("列出硬件")
            assert result["output"] == "机器人已列出"
            assert result["usage"]["requests"] == 2
            assert result["usage"]["tool_calls"] == 1
            assert session.events == [{"tool": "list_hardware", "ok": True, "executed": False, "state": "completed"}]
        finally:
            await session.close()
    asyncio.run(scenario())
    assert executor.closed and len(executor.calls) == 1
    assert all(t.name not in {"read_variables", "capture_image", "run_command", "apply_sql",
                             "shell", "list_files", "read_file", "write_file", "edit_file"}
               for t in seen[0][1].function_tools)


def test_stream_events_order_and_content():
    executor = FakeExecutor()
    model = scripted_model([ToolCallPart("list_hardware", {})], [TextPart("流水输出")])
    events = []

    async def scenario():
        session = AgentSession(executor, model, on_event=events.append)
        try:
            result = await session.ask("list")
            assert result["output"] == "流水输出"
            assert session.events == [{"tool": "list_hardware", "ok": True, "executed": False,
                                       "state": "completed"}]
        finally:
            await session.close()
    asyncio.run(scenario())
    assert events == [
        {"type": "tool_call", "tool": "list_hardware", "arguments": {}},
        {"type": "tool_result", "tool": "list_hardware", "ok": True, "executed": False, "state": "completed"},
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


def test_streaming_timeout_is_enforced_between_deltas():
    executor = FakeExecutor()

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("slow")])

    async def stream(messages, info):
        yield "sl"
        await asyncio.sleep(10)
        yield "ow"  # pragma: no cover - the watchdog must fire first

    async def scenario():
        session = AgentSession(executor, FunctionModel(respond, stream_function=stream),
                               AgentConfig(timeout=0.05), on_event=lambda event: None)
        try:
            with pytest.raises(AgentBudgetExceeded):
                await session.ask("slow")
        finally:
            await session.close()
    asyncio.run(scenario())


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


@pytest.mark.parametrize("allow,confirm_result,expected", [(False, None, 0), (False, False, 0),
                                                           (False, True, 1), (True, None, 1)])
def test_io_approval_is_host_owned(allow, confirm_result, expected):
    executor = FakeExecutor()
    model = scripted_model([ToolCallPart("run_action_script", {"script": "action.mt"})], [TextPart("done")])
    confirmations = []

    async def confirm(name, arguments):
        confirmations.append((name, arguments))
        return confirm_result

    async def scenario():
        session = AgentSession(executor, model, AgentConfig(allow_actions=allow),
                               confirm=confirm if confirm_result is not None else None)
        await session.ask("execute")
        assert session.events[0]["executed"] is bool(expected)
    asyncio.run(scenario())
    assert len(executor.calls) == expected
    if allow:
        assert confirmations == []


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
        agent_module.make_agent(scripted_model([TextPart("unused")]), enable_shell=True)


@pytest.mark.parametrize("args", [{"script": 123}, {"script": "action.mt", "unexpected": True}])
def test_invalid_model_arguments_never_dispatch(args):
    executor = FakeExecutor()
    model = scripted_model([ToolCallPart("run_action_script", args)])

    async def scenario():
        session = AgentSession(executor, model, AgentConfig(allow_actions=True))
        with pytest.raises(Exception):
            await session.ask("execute")
    asyncio.run(scenario())
    assert executor.calls == [] and executor.stop_event.is_set()


def test_images_are_binary_content_not_base64_text():
    executor = FakeExecutor()
    async def capture(name, arguments, *, timeout):
        return {"ok": True, "executed": True, "state": "completed", "data": {"format": "png"},
                "image": {"data": b"test-image", "media_type": "image/png"}}
    executor.call = capture
    calls = 0

    async def respond(messages, info):
        nonlocal calls
        calls += 1
        if calls == 1:
            return ModelResponse(parts=[ToolCallPart("capture_image", {"name": "camera"})])
        receipts = [p for m in messages for p in m.parts if isinstance(p, ToolReturnPart)]
        assert "image" not in receipts[-1].content
        prompts = [p.content for m in messages for p in m.parts if isinstance(p, UserPromptPart)]
        assert any(getattr(item, "data", None) == b"test-image"
                   for prompt in prompts if isinstance(prompt, list) for item in prompt)
        return ModelResponse(parts=[TextPart("image received")])

    async def scenario():
        session = AgentSession(executor, FunctionModel(respond), AgentConfig(allow_actions=True), camera_vars=("camera",))
        assert (await session.ask("look"))["output"] == "image received"
    asyncio.run(scenario())


def test_action_script_images_reach_the_model_as_binary():
    executor = FakeExecutor()

    async def run_script(name, arguments, *, timeout):
        return {"ok": True, "executed": True, "state": "completed",
                "data": {"outputs": [{"result": "OK", "image_index": 0}]},
                "images": [{"data": b"frame-bytes", "media_type": "image/jpeg"}]}
    executor.call = run_script
    calls = 0

    async def respond(messages, info):
        nonlocal calls
        calls += 1
        if calls == 1:
            return ModelResponse(parts=[ToolCallPart("run_action_script", {"script": "shoot.mt"})])
        receipts = [p for m in messages for p in m.parts if isinstance(p, ToolReturnPart)]
        assert receipts[-1].content["data"]["outputs"][0]["image_index"] == 0
        assert "images" not in receipts[-1].content
        prompts = [p.content for m in messages for p in m.parts if isinstance(p, UserPromptPart)]
        assert any(getattr(item, "data", None) == b"frame-bytes"
                   for prompt in prompts if isinstance(prompt, list) for item in prompt)
        return ModelResponse(parts=[TextPart("frame received")])

    async def scenario():
        session = AgentSession(executor, FunctionModel(respond), AgentConfig(allow_actions=True))
        assert (await session.ask("拍一张"))["output"] == "frame received"
    asyncio.run(scenario())


def test_parallel_model_calls_are_executed_serially():
    executor = FakeExecutor()
    order = []
    async def call(name, arguments, *, timeout):
        order.append(("start", name))
        await asyncio.sleep(0.01)
        order.append(("end", name))
        return {"ok": True, "executed": False, "state": "completed", "data": {}}
    executor.call = call
    model = scripted_model([ToolCallPart("list_hardware", {}), ToolCallPart("list_action_scripts", {})], [TextPart("done")])
    asyncio.run(AgentSession(executor, model).ask("list"))
    assert order == [("start", "list_hardware"), ("end", "list_hardware"),
                     ("start", "list_action_scripts"), ("end", "list_action_scripts")]


@pytest.mark.parametrize("config", [AgentConfig(request_limit=2), AgentConfig(tool_calls_limit=2)])
def test_usage_limits_stop_infinite_model_loop(config):
    executor = FakeExecutor()
    async def respond(messages, info):
        return ModelResponse(parts=[ToolCallPart("list_hardware", {})])
    with pytest.raises(UsageLimitExceeded):
        asyncio.run(AgentSession(executor, FunctionModel(respond), config).ask("list forever"))
    assert len(executor.calls) <= 2 and executor.stop_event.is_set()


def test_wall_clock_timeout_cancels_network_wait():
    executor = FakeExecutor()
    finished = []
    async def respond(messages, info):
        try:
            await asyncio.sleep(10)
            return ModelResponse(parts=[TextPart("late")])
        finally:
            finished.append(True)
    with pytest.raises(AgentBudgetExceeded):
        asyncio.run(AgentSession(executor, FunctionModel(respond), AgentConfig(timeout=0.04)).ask("wait"))
    assert finished and executor.stop_event.is_set() and not executor.calls


def test_stop_event_cancels_model_before_dispatch():
    executor = FakeExecutor()
    async def respond(messages, info):
        executor.stop_event.set()
        await asyncio.sleep(10)
        return ModelResponse(parts=[TextPart("late")])
    with pytest.raises(AgentInterrupted):
        asyncio.run(AgentSession(executor, FunctionModel(respond)).ask("wait"))
    assert not executor.calls


def test_approval_wait_obeys_task_budget():
    executor = FakeExecutor()
    async def confirm(name, arguments):
        await asyncio.sleep(10)
        return True
    model = scripted_model([ToolCallPart("run_action_script", {"script": "action.mt"})])
    with pytest.raises(AgentBudgetExceeded):
        asyncio.run(AgentSession(executor, model, AgentConfig(timeout=0.04), confirm=confirm).ask("execute"))
    assert not executor.calls


def test_history_prunes_complete_turns():
    executor = FakeExecutor()
    history_sizes = []
    async def respond(messages, info):
        # The first turn is gone by the fourth request, but safety rules must remain.
        assert SYSTEM_PROMPT in info.instructions
        history_sizes.append(len([p for m in messages for p in m.parts if isinstance(p, UserPromptPart)]))
        return ModelResponse(parts=[TextPart("done")])
    async def scenario():
        session = AgentSession(executor, FunctionModel(respond), AgentConfig(history_turns=2))
        for i in range(4):
            await session.ask(str(i))
        assert len(session.turns) == 2
    asyncio.run(scenario())
    assert history_sizes == [1, 2, 3, 3]


def test_failed_start_never_sends_model_request():
    executor = FakeExecutor()
    async def fail_start():
        return {"ok": False, "executed": False, "state": "not_executed"}
    executor.start = fail_start
    async def forbidden(messages, info):
        pytest.fail("Invalid robot startup reached model")
    with pytest.raises(AgentConfigurationError):
        asyncio.run(AgentSession(executor, FunctionModel(forbidden)).ask("hello"))


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
        return ModelResponse(parts=[ToolCallPart("list_hardware", {})])
    session = AgentSession(executor, FunctionModel(respond))
    with pytest.raises(AgentInterrupted):
        asyncio.run(session.ask("list"))
    assert requests == [True]
    assert session.events[-1]["state"] == receipt_state


def test_model_request_hook_checks_stop_even_outside_ask():
    executor = FakeExecutor()
    async def forbidden(messages, info):
        pytest.fail("Stopped session reached the model")
    async def scenario():
        session = AgentSession(executor, FunctionModel(forbidden))
        executor.cancel()
        with pytest.raises(AgentInterrupted):
            await session.agent.run("hello", deps=session)
    asyncio.run(scenario())


class FakeTTY(io.StringIO):
    def isatty(self):
        return True


@pytest.mark.parametrize("long", [False, True])
def test_console_approval_never_hides_arguments(monkeypatch, capsys, long):
    stdin = FakeTTY("y\n")
    monkeypatch.setattr(sys, "stdin", stdin)
    arguments = {"script": "action.mt", "vars": {"text": "x" * 2100 if long else "a\x1b[2Jb"}}
    approved = asyncio.run(confirm_console("run_action_script", arguments, threading.Event()))
    output = capsys.readouterr()
    assert not output.out and "\x1b" not in output.err
    if long:
        assert not approved and stdin.tell() == 0
        assert "too long" in output.err
    else:
        assert approved and repr(agent_module.dumps(arguments)) in output.err


@pytest.mark.parametrize("name,args,warning", [
    ("shell", {"command": "exit 0"}, "NOT sandboxed"),
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
    model = scripted_model([ToolCallPart("run_action_script", {"script": "action.mt"})], [TextPart("done")])
    install_cli_fakes(monkeypatch, executor, model, SimpleNamespace(close=close_client))
    code = cli.main(["--robot", "unused.sql", "--task", "execute", "--allow-actions"])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert code == 1 and not payload["ok"] and closed == ["executor", "client"]
    assert len(captured.out.splitlines()) == 1 and "SECRET" not in captured.out + captured.err
    assert payload["tool_events"] == [{"tool": "run_action_script", "ok": not primary_failure,
                                      "executed": True, "state": "unknown" if primary_failure else "completed"}]
    expected = {"executor": ["ValueError"], "client": ["OSError"], "both": ["ValueError", "OSError"]}
    assert payload["cleanup_errors"] == expected[cleanup_failure]
    if primary_failure:
        assert "outcome is unknown" in payload["error"]["message"]


def test_interactive_cli_confirms_and_emits_only_final_json(monkeypatch, capsys):
    from pymybot import cli
    executor = FakeExecutor()
    closed = []
    async def close_client():
        closed.append(True)
    model = scripted_model([ToolCallPart("run_action_script", {"script": "action.mt"})], [TextPart("已完成")])
    install_cli_fakes(monkeypatch, executor, model, SimpleNamespace(close=close_client))
    monkeypatch.setattr(sys, "stdin", FakeTTY("执行动作\ny\n/exit\n"))
    code = cli.main(["--robot", "unused.sql"])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert code == 0 and len(captured.out.splitlines()) == 1
    assert payload["turns"] == 1 and payload["output"] == "已完成"
    assert "Approve run_action_script" in captured.err and "已完成" in captured.err
    assert len(executor.calls) == 1 and executor.closed and closed == [True]


def test_interactive_cli_streams_to_stderr_and_does_not_reprint(monkeypatch, capsys):
    from pymybot import cli
    executor = FakeExecutor()
    model = scripted_model([ToolCallPart("list_hardware", {})], [TextPart("AAAA BBBB")])
    install_cli_fakes(monkeypatch, executor, model, SimpleNamespace(close=lambda: asyncio.sleep(0)))
    monkeypatch.setattr(sys, "stdin", FakeTTY("list\n/exit\n"))
    code = cli.main(["--robot", "unused.sql"])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert code == 0 and len(captured.out.splitlines()) == 1
    assert payload["turns"] == 1 and payload["output"] == "AAAA BBBB"
    # Tool progress and text deltas stream live on stderr; adjacent pieces join
    # into the full text exactly once (a reprint after streaming would double it).
    assert "→ list_hardware(" in captured.err and "⇦ list_hardware completed" in captured.err
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


@pytest.mark.parametrize("outcome", ["success", "fault", "interrupt", "timeout"])
def test_cli_real_sdk_model_loop_and_virtual_robot(tmp_path, monkeypatch, capsys, outcome):
    from pymybot import cli
    from pymybot.robot import Robot
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", True)  # Only the loopback fake below.
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    path = tmp_path / "robot.sql"
    path.write_text("CREATE TABLE dummy(name String); INSERT INTO dummy(name) VALUES('dev');", encoding="utf-8")
    (tmp_path / "action.mt").write_text("@Action\ndev.echo;\n9;\n@\n", encoding="utf-8")
    ran = []
    now, offset = agent_module.time.monotonic, [0]
    monkeypatch.setattr(agent_module, "time", SimpleNamespace(monotonic=lambda: now() + offset[0]))
    original = Robot.run
    def run(self, *args, **kwargs):
        ran.append(True)
        if outcome == "interrupt":
            # Exercise the CLI's installed handler without delivering an OS signal to pytest.
            signal.getsignal(signal.SIGINT)(signal.SIGINT, None)
        if outcome == "timeout":
            offset[0] += 200
        if outcome != "success":
            raise RuntimeError("SECRET failed driver")
        return original(self, *args, **kwargs)
    monkeypatch.setattr(Robot, "run", run)
    def respond(body, count):
        assert body["model"] == "test" and body["parallel_tool_calls"] is False
        if count == 1:
            assert any(t["function"]["name"] == "run_action_script" for t in body["tools"])
            return completion({"role": "assistant", "content": None, "tool_calls": [
                {"id": "action-1", "type": "function", "function": {
                    "name": "run_action_script", "arguments": '{"script":"action.mt"}'}}]}, tool=True)
        receipt = next(m for m in body["messages"] if m["role"] == "tool")
        assert json.loads(receipt["content"])["data"]["outputs"][0]["echo"] == 9
        return completion({"role": "assistant", "content": "虚拟动作完成"})
    with fake_openai(respond) as (url, requests):
        code = cli.main(["--robot", str(path), "--scripts-dir", str(tmp_path), "--task", "执行动作",
                         "--model", "openai:test", "--base-url", url, "--allow-actions"])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert len(captured.out.splitlines()) == 1 and ran == [True]
    assert "SECRET" not in captured.out + captured.err
    if outcome != "success":
        assert code == (130 if outcome == "interrupt" else 1) and not payload["ok"] and len(requests) == 1
        assert payload["tool_events"][-1]["state"] == "unknown"
        assert payload["error"]["type"] == {"fault": "AgentError", "interrupt": "KeyboardInterrupt",
                                             "timeout": "AgentBudgetExceeded"}[outcome]
    else:
        assert code == 0 and payload["output"] == "虚拟动作完成" and len(requests) == 2
        assert payload["tool_events"][-1]["state"] == "completed"


def test_cli_workspace_tools_real_execution(tmp_path, monkeypatch, capsys):
    from pymybot import cli
    from pymybot.robot import Robot

    robot = tmp_path / "robot.sql"
    robot.write_text("CREATE TABLE Vars(name String,value Number);", encoding="utf-8")
    calls = iter([
        ToolCallPart("write_file", {"path": "note.txt", "content": "before\n"}),
        ToolCallPart("edit_file", {"path": "note.txt", "old_string": "before", "new_string": "after"}),
        ToolCallPart("read_file", {"path": "note.txt"}),
        ToolCallPart("shell", {"command": "echo shell-ok"}),
        TextPart("completed"),
    ])
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
    code = cli.main(["--robot", str(robot), "--scripts-dir", str(tmp_path),
                     "--workspace-dir", str(tmp_path), "--enable-shell", "--allow-shell",
                     "--allow-file-writes", "--task", "write, edit, read and run shell"])
    captured = capsys.readouterr()
    assert code == 0 and len(captured.out.splitlines()) == 1, captured.out + captured.err
    assert json.loads(captured.out)["output"] == "completed"
    assert (tmp_path / "note.txt").read_text(encoding="utf-8") == "after\n"
    assert receipts[2]["data"]["content"] == "after\n"
    assert receipts[3]["data"]["exit_code"] == 0
    assert "shell-ok" in receipts[3]["data"]["stdout"]
    assert "NOT sandboxed" in captured.err


def test_provider_error_is_sanitized_and_not_retried(tmp_path, monkeypatch, capsys):
    from pymybot import cli
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", True)
    monkeypatch.setenv("OPENAI_API_KEY", "offline-fake-key")
    path = tmp_path / "robot.sql"
    path.write_text("CREATE TABLE Vars(name String,value Number);", encoding="utf-8")
    with fake_openai(lambda *_: (500, {"error": {"message": "SECRET must not leak", "type": "server_error"}})) as (url, requests):
        code = cli.main(["--robot", str(path), "--scripts-dir", str(tmp_path), "--task", "hello",
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
        code = cli.main(["--robot", str(path), "--scripts-dir", str(tmp_path), "--task", "hello",
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


@pytest.mark.parametrize("provider,key", [("openai", "OPENAI_API_KEY"), ("deepseek", "DEEPSEEK_API_KEY"),
                                          ("anthropic", "ANTHROPIC_API_KEY")])
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
